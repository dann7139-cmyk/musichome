-- 616_gift_reveal_all_tiers_ROLLBACK.sql
-- Revierte confirm_gift_payment a que los regalos de catálogo fijo (no
-- "Otro monto") naveguen directo a 'Wallet' en vez de 'GiftReveal'.

CREATE OR REPLACE FUNCTION public.confirm_gift_payment(p_group_gift_id uuid, p_conekta_order_id text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_gift          RECORD;
  v_gw            RECORD;
  v_admin_id      UUID;
  v_gw_bal_after  NUMERIC(14,2);
  v_group_owner   UUID;
  v_group_name    TEXT;
  v_gift_catalog  RECORD;
  v_sender_name   TEXT;
  v_recipient     UUID;
  v_notif_title   TEXT;
  v_notif_body    TEXT;
  v_notif_screen  TEXT;
  v_catalog_price NUMERIC;
  v_is_custom     BOOLEAN;
  v_is_tip        BOOLEAN;
  v_currency_sym  TEXT;
  v_sender_title  TEXT;
  v_sender_body   TEXT;
  v_wt_desc       TEXT;
  v_gift_label    TEXT;
BEGIN
  SELECT * INTO v_gift FROM public.group_gifts WHERE id = p_group_gift_id FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'group_gift no encontrado: %', p_group_gift_id;
  END IF;

  IF v_gift.status = 'paid' THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'already_paid');
  END IF;

  IF v_gift.currency_code NOT IN ('MXN', 'USD') THEN
    RAISE EXCEPTION 'unsupported_currency: %', v_gift.currency_code;
  END IF;

  UPDATE public.group_gifts
  SET status = 'paid', paid_at = NOW(), payment_ref = p_conekta_order_id
  WHERE id = p_group_gift_id;

  SELECT owner_id INTO v_group_owner FROM public.groups WHERE id = v_gift.group_id;
  SELECT name INTO v_group_name FROM public.groups WHERE id = v_gift.group_id;
  SELECT full_name INTO v_sender_name FROM public.profiles WHERE id = v_gift.sender_id;
  SELECT * INTO v_gift_catalog FROM public.gift_catalog WHERE id = v_gift.gift_id;

  SELECT amount INTO v_catalog_price
  FROM public.gift_catalog_prices
  WHERE gift_id = v_gift.gift_id AND currency_code = v_gift.currency_code;
  v_is_custom := v_catalog_price IS NOT NULL AND v_gift.amount > v_catalog_price;
  v_is_tip    := v_gift.reservation_id IS NOT NULL;
  v_currency_sym := CASE v_gift.currency_code WHEN 'USD' THEN 'US$' ELSE '$' END;
  v_gift_label := CASE WHEN v_is_custom THEN 'Regalo sorpresa' ELSE COALESCE(v_gift_catalog.name, 'Regalo') END;

  v_wt_desc := (CASE WHEN v_is_tip THEN 'Propina de evento (' || v_gift_label || ')' ELSE v_gift_label END)
    || ' de ' || COALESCE(v_sender_name, 'un fan');

  PERFORM public.ensure_group_wallet(v_gift.group_id);
  SELECT * INTO v_gw FROM public.group_wallets WHERE group_id = v_gift.group_id FOR UPDATE;

  IF v_gift.currency_code = 'USD' THEN
    v_gw_bal_after := COALESCE(v_gw.available_balance_usd, 0) + v_gift.group_amount;
    UPDATE public.group_wallets
    SET available_balance_usd = v_gw_bal_after,
        total_earned_usd      = COALESCE(total_earned_usd, 0) + v_gift.group_amount,
        total_gift_income_usd = COALESCE(total_gift_income_usd, 0) + v_gift.group_amount,
        updated_at            = NOW()
    WHERE id = v_gw.id;
  ELSE
    v_gw_bal_after := COALESCE(v_gw.available_balance, 0) + v_gift.group_amount;
    UPDATE public.group_wallets
    SET available_balance = v_gw_bal_after,
        total_earned      = COALESCE(total_earned, 0) + v_gift.group_amount,
        total_gift_income = COALESCE(total_gift_income, 0) + v_gift.group_amount,
        updated_at        = NOW()
    WHERE id = v_gw.id;
  END IF;

  INSERT INTO public.wallet_transactions
    (group_wallet_id, group_id, type, amount, gift_id, description, balance_after, currency_code)
  VALUES
    (v_gw.id, v_gift.group_id, 'gift_income', v_gift.group_amount, v_gift.id,
     v_wt_desc, v_gw_bal_after, v_gift.currency_code);

  v_admin_id := public.get_platform_admin_id();
  IF v_admin_id IS NOT NULL THEN
    INSERT INTO public.wallets (user_id) VALUES (v_admin_id) ON CONFLICT (user_id) DO NOTHING;

    IF v_gift.currency_code = 'USD' THEN
      UPDATE public.wallets
      SET available_balance_usd    = COALESCE(available_balance_usd, 0) + v_gift.platform_amount,
          total_earned_usd         = COALESCE(total_earned_usd, 0) + v_gift.platform_amount,
          total_gift_commission_usd = COALESCE(total_gift_commission_usd, 0) + v_gift.platform_amount,
          updated_at               = NOW()
      WHERE user_id = v_admin_id;
    ELSE
      UPDATE public.wallets
      SET available_balance     = available_balance + v_gift.platform_amount,
          total_earned          = COALESCE(total_earned, 0) + v_gift.platform_amount,
          total_gift_commission = COALESCE(total_gift_commission, 0) + v_gift.platform_amount,
          updated_at            = NOW()
      WHERE user_id = v_admin_id;
    END IF;

    INSERT INTO public.wallet_transactions
      (user_id, type, amount, gift_id, description, currency_code)
    VALUES
      (v_admin_id, 'commission', v_gift.platform_amount, v_gift.id,
       'Comisión por regalo', v_gift.currency_code);
  END IF;

  IF v_is_custom THEN
    v_notif_title  := CASE WHEN v_is_tip THEN '🎁 ¡Recibiste una propina sorpresa!' ELSE '🎁 ¡Recibiste un regalo sorpresa!' END;
    v_notif_body   := COALESCE(v_sender_name, 'Alguien')
      || (CASE WHEN v_is_tip THEN ' te dio una propina sorpresa por el evento. ' ELSE ' te mandó un regalo sorpresa. ' END)
      || 'Tócalo para descubrir cuánto fue.';
    v_notif_screen := 'GiftReveal';
  ELSE
    v_notif_title  := CASE WHEN v_is_tip THEN '🎁 ¡Recibiste una propina!' ELSE '🎁 ¡Recibiste un regalo!' END;
    v_notif_body   := COALESCE(v_sender_name, 'Alguien') || ' ' ||
      (CASE WHEN v_is_tip THEN 'te dio propina por el evento: ' ELSE '' END) ||
      CASE v_gift_catalog.name
        WHEN 'Corazón'  THEN CASE WHEN v_is_tip THEN 'Corazón ❤️.' ELSE 'te mandó un Corazón ❤️.' END
        WHEN 'Fuego'    THEN CASE WHEN v_is_tip THEN 'Fuego 🔥.' ELSE 'te mandó un Fuego 🔥.' END
        WHEN 'Rayo'     THEN CASE WHEN v_is_tip THEN 'Rayo ⚡.' ELSE 'te mandó un Rayo ⚡.' END
        WHEN 'Diamante' THEN CASE WHEN v_is_tip THEN 'Diamante 💎.' ELSE 'te regaló un Diamante 💎.' END
        WHEN 'Corona'   THEN CASE WHEN v_is_tip THEN 'Corona 👑.' ELSE 'te coronó 👑.' END
        WHEN 'Trofeo'   THEN CASE WHEN v_is_tip THEN 'Trofeo 🏆.' ELSE 'te dio el Trofeo 🏆.' END
        ELSE (CASE WHEN v_is_tip THEN '' ELSE 'te regaló ' END) || v_gift_catalog.emoji || ' ' || v_gift_catalog.name || '.'
      END;
    v_notif_screen := 'Wallet';
  END IF;

  v_sender_title := COALESCE(v_group_name, 'El grupo') || ' te dice ¡Gracias! 💚';

  IF v_is_custom THEN
    v_sender_body := 'Queremos agradecerte de manera muy especial por tu generoso apoyo de '
      || v_currency_sym || v_gift.amount || ' ' || v_gift.currency_code
      || ' 🌟. Gracias por creer en nuestra música — significa muchísimo para nosotros.';
  ELSE
    v_sender_body := CASE v_gift_catalog.name
      WHEN 'Corazón'  THEN '¡Gracias por tu Corazón ❤️! Tu apoyo nos ayuda a seguir haciendo música en vivo.'
      WHEN 'Fuego'    THEN '¡Gracias por tu Fuego 🔥! Cada regalo como este nos motiva a seguir tocando.'
      WHEN 'Rayo'     THEN '¡Gracias por tu Rayo ⚡! Se siente muchísimo tu apoyo.'
      WHEN 'Diamante' THEN '¡Gracias por tu Diamante 💎! Tu generosidad significa mucho para nosotros.'
      WHEN 'Corona'   THEN '¡Nos coronaste 👑! Gracias de corazón por tu apoyo.'
      WHEN 'Trofeo'   THEN 'Queremos agradecerte de manera muy especial por tu Trofeo 🏆. Tu apoyo hace una diferencia real en nuestra música — ¡gracias por creer en nosotros!'
      ELSE '¡Gracias por tu ' || v_gift_catalog.emoji || ' ' || v_gift_catalog.name || '! Tu apoyo significa mucho para nosotros.'
    END;
  END IF;

  FOR v_recipient IN
    SELECT DISTINCT recipient FROM (
      SELECT v_group_owner AS recipient
      UNION
      SELECT ji.invited_user_id
      FROM public.job_invitations ji
      WHERE ji.group_id = v_gift.group_id
        AND ji.status = 'accepted'
        AND ji.invitation_type IN ('membership', 'job')
        AND ji.event_id IS NULL
    ) recipients
    WHERE recipient IS NOT NULL AND recipient != v_gift.sender_id
  LOOP
    INSERT INTO public.notifications (user_id, type, title, body, data)
    VALUES (
      v_recipient, 'system',
      v_notif_title,
      v_notif_body,
      jsonb_build_object('screen', v_notif_screen, 'gift_id', v_gift.id)
    );
  END LOOP;

  INSERT INTO public.notifications (user_id, type, title, body, data)
  VALUES (
    v_gift.sender_id, 'system',
    v_sender_title,
    v_sender_body,
    jsonb_build_object('screen', 'GroupDetail', 'group_id', v_gift.group_id, 'gift_id', v_gift.id)
  );

  IF v_gift_catalog.notify_admin AND v_admin_id IS NOT NULL THEN
    INSERT INTO public.notifications (user_id, type, title, body, data)
    VALUES (
      v_admin_id, 'system',
      '🎆 Regalo grande enviado',
      COALESCE(v_sender_name, 'Alguien') || ' mandó ' || v_gift_catalog.emoji || ' ' || v_gift_catalog.name
        || ' ($' || v_gift.amount || ' ' || v_gift.currency_code || ').',
      jsonb_build_object('screen', 'AdminFinancial', 'gift_id', v_gift.id)
    );
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'group_amount', v_gift.group_amount,
    'platform_amount', v_gift.platform_amount,
    'currency', v_gift.currency_code
  );
END;
$function$;
