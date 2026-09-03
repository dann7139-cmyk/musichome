-- ============================================================
-- sql/581_gift_wallet_description.sql — contexto en el wallet, sin precio original
--
-- El grupo confirmó que quiere ver SU ganancia neta (nunca el precio del
-- regalo ni la comisión de Daricefy — misma regla que ya rige el resto de
-- la app). Lo único que faltaba era contexto: la fila en el wallet decía
-- genérico "Regalo recibido" sin decir cuál regalo ni quién lo mandó.
-- Ahora dice p.ej. "Fuego de Lala" o "Regalo sorpresa de Lala" — el monto
-- (amount) sigue siendo SOLO el neto del grupo (60%), nunca el precio
-- completo. Para poder armar ese texto, se adelantan los SELECT de
-- sender_name/gift_catalog/is_custom a ANTES del INSERT en
-- wallet_transactions (antes iban después, sin usarse ahí). Todo lo demás
-- (crédito, comisión, notificaciones) queda BYTE IDÉNTICO.
-- ============================================================

CREATE OR REPLACE FUNCTION public.confirm_gift_payment(
  p_group_gift_id     UUID,
  p_conekta_order_id  TEXT
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
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
  v_currency_sym  TEXT;
  v_sender_title  TEXT;
  v_sender_body   TEXT;
  v_wt_desc       TEXT;
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

  -- ── Datos para textos (grupo, quién mandó, qué regalo) — adelantado
  -- para poder armar la descripción del wallet ANTES de insertarla.
  SELECT owner_id INTO v_group_owner FROM public.groups WHERE id = v_gift.group_id;
  SELECT name INTO v_group_name FROM public.groups WHERE id = v_gift.group_id;
  SELECT full_name INTO v_sender_name FROM public.profiles WHERE id = v_gift.sender_id;
  SELECT * INTO v_gift_catalog FROM public.gift_catalog WHERE id = v_gift.gift_id;

  SELECT amount INTO v_catalog_price
  FROM public.gift_catalog_prices
  WHERE gift_id = v_gift.gift_id AND currency_code = v_gift.currency_code;
  v_is_custom := v_catalog_price IS NOT NULL AND v_gift.amount > v_catalog_price;
  v_currency_sym := CASE v_gift.currency_code WHEN 'USD' THEN 'US$' ELSE '$' END;

  v_wt_desc := (CASE WHEN v_is_custom THEN 'Regalo sorpresa' ELSE COALESCE(v_gift_catalog.name, 'Regalo') END)
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
    v_notif_title  := '🎁 ¡Recibiste un regalo sorpresa!';
    v_notif_body   := COALESCE(v_sender_name, 'Alguien') || ' te mandó un regalo sorpresa. Tócalo para descubrir cuánto fue.';
    v_notif_screen := 'GiftReveal';
  ELSE
    v_notif_title  := '🎁 ¡Recibiste un regalo!';
    v_notif_body   := COALESCE(v_sender_name, 'Alguien') || ' ' || CASE v_gift_catalog.name
      WHEN 'Corazón'  THEN 'te mandó un Corazón ❤️.'
      WHEN 'Fuego'    THEN 'te mandó un Fuego 🔥.'
      WHEN 'Rayo'     THEN 'te mandó un Rayo ⚡.'
      WHEN 'Diamante' THEN 'te regaló un Diamante 💎.'
      WHEN 'Corona'   THEN 'te coronó 👑.'
      WHEN 'Trofeo'   THEN 'te dio el Trofeo 🏆.'
      ELSE 'te regaló ' || v_gift_catalog.emoji || ' ' || v_gift_catalog.name || '.'
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
$$;

GRANT EXECUTE ON FUNCTION public.confirm_gift_payment(UUID, TEXT) TO service_role;

SELECT '581_gift_wallet_description.sql ejecutado ✅' AS status;
