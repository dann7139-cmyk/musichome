-- ============================================================
-- sql/497_promo_subscriptions.sql
-- 🔁 SUSCRIPCIONES de publicidad (pedido 2026-07-16):
--    · Recomendado: suscripción SEMANAL $399 (mismo precio que el
--      paquete de 7 días) — cada cobro semanal crea una orden pagada.
--    · Destacado (sponsored_group): suscripción MENSUAL al precio del
--      anuncio — cada cobro extiende el destacado 30 días.
--
--  El webhook de Stripe (invoice.paid con metadata promo_sub_kind)
--  llama estos RPCs. Ambos son IDEMPOTENTES por payment_id: el
--  reenvío del webhook no duplica órdenes ni ingresos.
--
--  NO toca reservas, wallets de grupos, GPS ni liberaciones.
-- ============================================================

BEGIN;

-- ── 1. Renovación semanal del RECOMENDADO ────────────────────────────
CREATE OR REPLACE FUNCTION public.renew_recommendation_subscription(
  p_group_id   UUID,
  p_payment_id TEXT,
  p_amount     NUMERIC
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_group    RECORD;
  v_start    TIMESTAMPTZ;
  v_order_id UUID;
  v_admin    RECORD;
BEGIN
  -- Idempotencia: este cobro ya generó su orden
  IF EXISTS (
    SELECT 1 FROM recommendation_orders WHERE stripe_payment_id = p_payment_id
  ) THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'already_processed');
  END IF;

  SELECT id, name, city, state, owner_id INTO v_group
  FROM groups WHERE id = p_group_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'group_not_found');
  END IF;

  -- El nuevo periodo arranca donde termina el actual (si sigue vivo)
  SELECT GREATEST(NOW(), COALESCE(MAX(ends_at), NOW()))
  INTO   v_start
  FROM   recommendation_orders
  WHERE  group_id = p_group_id AND status = 'paid' AND ends_at > NOW();

  INSERT INTO recommendation_orders
    (group_id, amount, price_per_day, duration_days, status,
     stripe_payment_id, starts_at, ends_at, city, state)
  VALUES
    (p_group_id, p_amount, ROUND(p_amount / 7, 2), 7, 'paid',
     p_payment_id, v_start, v_start + INTERVAL '7 days', v_group.city, v_group.state)
  RETURNING id INTO v_order_id;

  -- Ingreso a wallet de admin (idempotente por reference_id)
  FOR v_admin IN SELECT id FROM profiles WHERE role = 'admin' LOOP
    INSERT INTO wallets (user_id) VALUES (v_admin.id) ON CONFLICT (user_id) DO NOTHING;

    WITH inserted AS (
      INSERT INTO wallet_transactions
        (user_id, amount, type, status, reference_id, description)
      VALUES (
        v_admin.id, p_amount, 'recommendation_income', 'completed',
        'recsub_' || p_payment_id,
        'Recomendado (suscripción semanal): ' || COALESCE(v_group.name, p_group_id::TEXT)
      )
      ON CONFLICT (reference_id) DO NOTHING
      RETURNING amount, user_id
    )
    UPDATE wallets w
    SET available_balance = w.available_balance + i.amount,
        total_earned      = w.total_earned      + i.amount,
        updated_at        = NOW()
    FROM inserted i
    WHERE w.user_id = i.user_id;
  END LOOP;

  -- Avisar al dueño
  IF v_group.owner_id IS NOT NULL THEN
    INSERT INTO notifications (user_id, type, title, body, data)
    VALUES (v_group.owner_id, 'reservation',
      '⭐ Recomendación renovada',
      'Tu grupo sigue en "Recomendado para ti" 7 días más. Se renueva solo cada semana — puedes cancelar cuando quieras.',
      jsonb_build_object('screen', 'GroupReservations'));
  END IF;

  RETURN jsonb_build_object('ok', true, 'order_id', v_order_id, 'starts_at', v_start);
END;
$$;

GRANT EXECUTE ON FUNCTION public.renew_recommendation_subscription(UUID, TEXT, NUMERIC)
  TO service_role;

-- ── 2. Renovación mensual del DESTACADO (sponsored_group) ────────────
CREATE OR REPLACE FUNCTION public.renew_sponsored_subscription(
  p_ad_id      UUID,
  p_payment_id TEXT,
  p_amount     NUMERIC
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_ad     RECORD;
  v_admin  RECORD;
  v_base   TIMESTAMPTZ;
  v_first  BOOLEAN;
BEGIN
  -- Idempotencia: este cobro ya se acreditó
  IF EXISTS (
    SELECT 1 FROM wallet_transactions WHERE reference_id = 'sponsub_' || p_payment_id
  ) THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'already_processed');
  END IF;

  SELECT * INTO v_ad FROM advertisements WHERE id = p_ad_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'ad_not_found');
  END IF;
  IF v_ad.type <> 'sponsored_group' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_sponsored');
  END IF;

  v_first := (v_ad.status = 'pending_payment');

  IF v_first THEN
    -- Primer cobro de la suscripción: pasa a revisión del admin
    -- (approve_ad lo activará respetando los 30 días pagados)
    UPDATE advertisements
    SET status = 'pending_review', mp_payment_id = p_payment_id, updated_at = NOW()
    WHERE id = p_ad_id;
  ELSE
    -- Renovación: extender 30 días desde donde termine el periodo actual
    v_base := GREATEST(COALESCE(v_ad.ends_at, NOW()), NOW());
    UPDATE advertisements
    SET status     = 'active',
        starts_at  = COALESCE(starts_at, NOW()),
        ends_at    = v_base + INTERVAL '30 days',
        updated_at = NOW()
    WHERE id = p_ad_id;

    UPDATE sponsored_groups
    SET is_active = true,
        ends_at   = v_base + INTERVAL '30 days'
    WHERE advertiser_id = v_ad.advertiser_id
      AND id = (
        SELECT id FROM sponsored_groups
        WHERE advertiser_id = v_ad.advertiser_id
        ORDER BY created_at DESC LIMIT 1
      );
  END IF;

  -- Ingreso a wallet de admin (idempotente por reference_id)
  FOR v_admin IN SELECT id FROM profiles WHERE role = 'admin' LOOP
    INSERT INTO wallets (user_id) VALUES (v_admin.id) ON CONFLICT (user_id) DO NOTHING;

    WITH inserted AS (
      INSERT INTO wallet_transactions
        (user_id, amount, type, status, reference_id, description)
      VALUES (
        v_admin.id, p_amount, 'ad_income', 'completed',
        'sponsub_' || p_payment_id,
        'Destacado (suscripción mensual): ' || COALESCE(v_ad.title, p_ad_id::TEXT)
      )
      ON CONFLICT (reference_id) DO NOTHING
      RETURNING amount, user_id
    )
    UPDATE wallets w
    SET available_balance = w.available_balance + i.amount,
        total_earned      = w.total_earned      + i.amount,
        updated_at        = NOW()
    FROM inserted i
    WHERE w.user_id = i.user_id;
  END LOOP;

  -- Avisar al dueño
  IF v_ad.advertiser_id IS NOT NULL THEN
    INSERT INTO notifications (user_id, type, title, body, data)
    VALUES (v_ad.advertiser_id, 'reservation',
      CASE WHEN v_first THEN '🌟 Pago recibido — Destacado en revisión'
           ELSE '🌟 Destacado renovado' END,
      CASE WHEN v_first THEN 'Tu pago se acreditó. Tu anuncio de Destacado pasa a revisión y se activa al aprobarse.'
           ELSE 'Tu grupo sigue Destacado 30 días más. Se renueva solo cada mes — puedes cancelar cuando quieras.' END,
      jsonb_build_object('screen', 'GroupReservations'));
  END IF;

  RETURN jsonb_build_object('ok', true, 'first', v_first);
END;
$$;

GRANT EXECUTE ON FUNCTION public.renew_sponsored_subscription(UUID, TEXT, NUMERIC)
  TO service_role;

COMMIT;

-- ── VERIFICACIÓN ──────────────────────────────────────────────────────────────
SELECT proname FROM pg_proc
WHERE proname IN ('renew_recommendation_subscription', 'renew_sponsored_subscription');
-- Esperado: 2 filas

SELECT '497_promo_subscriptions.sql ejecutado ✅' AS status;
