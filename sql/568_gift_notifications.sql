-- ============================================================
-- sql/568_gift_notifications.sql — FASE 3: notificaciones de regalos
--
-- Solo AGREGA pasos al final de confirm_gift_payment() (sql/567) — el
-- crédito al wallet del grupo y la comisión del admin quedan BYTE
-- IDÉNTICOS a como ya están funcionando, no se toca esa parte.
--
-- 1. Grupo + talento permanente: SIEMPRE se notifican (mismo criterio
--    de "integrante permanente" que ya usa GroupDetailScreen.tsx para
--    likes/comentarios: job_invitations aceptado, membership/job, sin
--    event_id).
--
-- 2. Admin: SOLO para regalos marcados como notify_admin=TRUE en el
--    catálogo (por ahora solo "Concierto VIP", el más caro) — así no
--    se le manda una notificación al admin por CADA regalito de $10 de
--    CADA grupo, que con muchos grupos activos sería un caos, como
--    pidió el usuario explícitamente.
--
-- 3. total_gift_income[_usd] (grupo) y total_gift_commission[_usd]
--    (admin): contador dedicado, aparte de total_earned — así el stat
--    "cuánto he ganado en regalos" es EXACTO y no depende de la lista
--    de wallet_transactions, que get_my_wallet() limita a las últimas
--    50 filas. Mismo objeto que ya devuelve get_my_wallet() (SELECT
--    to_jsonb(gw) / to_jsonb(w)) — cualquier columna nueva ya viaja
--    sola al frontend, sin tocar esa función.
-- ============================================================

ALTER TABLE public.gift_catalog
  ADD COLUMN IF NOT EXISTS notify_admin BOOLEAN NOT NULL DEFAULT FALSE;

ALTER TABLE public.group_wallets
  ADD COLUMN IF NOT EXISTS total_gift_income     NUMERIC NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS total_gift_income_usd NUMERIC NOT NULL DEFAULT 0;

ALTER TABLE public.wallets
  ADD COLUMN IF NOT EXISTS total_gift_commission     NUMERIC NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS total_gift_commission_usd NUMERIC NOT NULL DEFAULT 0;

UPDATE public.gift_catalog SET notify_admin = TRUE WHERE name = 'Concierto VIP';

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
      COALESCE(v_sender_name, 'Alguien') || ' te regaló ' || v_gift_catalog.emoji || ' ' || v_gift_catalog.name || '.',
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

SELECT '568_gift_notifications.sql ejecutado ✅' AS status;
