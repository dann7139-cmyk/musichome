-- ============================================================
-- sql/573_gift_catalog_simbolos.sql — Catálogo de regalos "Símbolos"
--
-- Renombra los 6 regalos existentes a la nueva línea visual (Corazón,
-- Fuego, Rayo, Diamante, Corona, Trofeo) — mismos ids, mismos precios,
-- mismo orden (sort_order 1-6 ya coincide exacto con el precio
-- ascendente), solo cambia name/emoji. No se toca gift_catalog_prices
-- ni group_gifts — las filas ya pagadas siguen apuntando al mismo
-- gift_id de siempre, solo que ahora ese id se llama distinto.
--
-- También actualiza confirm_gift_payment (sql/567 → 568) SOLO en el
-- texto de la notificación al grupo — un copy propio por regalo en vez
-- del genérico "te regaló {emoji} {name}". El crédito al wallet del
-- grupo, la comisión del admin y la notificación al admin (regalo caro)
-- quedan BYTE IDÉNTICOS a como ya están funcionando.
-- ============================================================

UPDATE public.gift_catalog SET name = 'Corazón', emoji = '❤️'  WHERE id = 'cae0d21b-c49e-4ef6-855f-c4f4c8291240'; -- antes "Nota musical" 🎵
UPDATE public.gift_catalog SET name = 'Fuego',   emoji = '🔥'  WHERE id = 'c8f6cbde-70e2-4db6-9574-bce4e49e2897'; -- antes "Micrófono" 🎤
UPDATE public.gift_catalog SET name = 'Rayo',    emoji = '⚡'  WHERE id = '7c99d911-f9ff-4a83-ab29-03622b7d5aab'; -- antes "Batería" 🥁
UPDATE public.gift_catalog SET name = 'Diamante', emoji = '💎' WHERE id = 'fd095519-7f41-4454-aebb-a27df1874b86'; -- antes "Guitarra" 🎸
UPDATE public.gift_catalog SET name = 'Corona',  emoji = '👑'  WHERE id = '7bf6411a-2d67-4781-a959-69308b485f44'; -- antes "Trofeo de oro" 🏆
UPDATE public.gift_catalog SET name = 'Trofeo',  emoji = '🏆'  WHERE id = 'c08fee20-1bb8-4214-a457-b1805cdfe7e4'; -- antes "Concierto VIP" 🎆 (sigue con notify_admin=TRUE)

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
  v_gift_catalog  RECORD;
  v_sender_name   TEXT;
  v_recipient     UUID;
  v_notif_body    TEXT;
BEGIN
  SELECT * INTO v_gift FROM public.group_gifts WHERE id = p_group_gift_id FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'group_gift no encontrado: %', p_group_gift_id;
  END IF;

  -- Idempotencia: reenvíos del webhook no acreditan ni notifican dos veces.
  IF v_gift.status = 'paid' THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'already_paid');
  END IF;

  IF v_gift.currency_code NOT IN ('MXN', 'USD') THEN
    RAISE EXCEPTION 'unsupported_currency: %', v_gift.currency_code;
  END IF;

  UPDATE public.group_gifts
  SET status = 'paid', paid_at = NOW(), payment_ref = p_conekta_order_id
  WHERE id = p_group_gift_id;

  -- ── Acreditar al grupo (60%) ────────────────────────────────────────
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
     'Regalo recibido', v_gw_bal_after, v_gift.currency_code);

  -- ── Comisión Daricefy (40%) — directo a available, sin pending ──────
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

  -- ── 🔔 Notificar al grupo + talento permanente (SIEMPRE) ────────────
  SELECT owner_id INTO v_group_owner FROM public.groups WHERE id = v_gift.group_id;
  SELECT full_name INTO v_sender_name FROM public.profiles WHERE id = v_gift.sender_id;
  SELECT * INTO v_gift_catalog FROM public.gift_catalog WHERE id = v_gift.gift_id;

  -- Copy propio por regalo (catálogo "Símbolos", sql/573) — antes era
  -- genérico "te regaló {emoji} {name}" para los 6. Fallback genérico
  -- si algún día se agrega un regalo nuevo sin copy dedicado.
  v_notif_body := COALESCE(v_sender_name, 'Alguien') || ' ' || CASE v_gift_catalog.name
    WHEN 'Corazón'  THEN 'te mandó un Corazón ❤️.'
    WHEN 'Fuego'    THEN 'te mandó un Fuego 🔥.'
    WHEN 'Rayo'     THEN 'te mandó un Rayo ⚡.'
    WHEN 'Diamante' THEN 'te regaló un Diamante 💎.'
    WHEN 'Corona'   THEN 'te coronó 👑.'
    WHEN 'Trofeo'   THEN 'te dio el Trofeo 🏆.'
    ELSE 'te regaló ' || v_gift_catalog.emoji || ' ' || v_gift_catalog.name || '.'
  END;

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
      '🎁 ¡Recibiste un regalo!',
      v_notif_body,
      jsonb_build_object('screen', 'Dashboard', 'gift_id', v_gift.id)
    );
  END LOOP;

  -- ── 🔔 Notificar al admin SOLO si el regalo está marcado (evita spam) ─
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

SELECT '573_gift_catalog_simbolos.sql ejecutado ✅' AS status;
