-- ============================================================
-- sql/502_rec_monthly_plan.sql
-- 🔁 Recomendado: plan MENSUAL además del semanal (2026-07-17)
--
--  renew_recommendation_subscription ahora recibe p_days (7 o 30)
--  para extender lo que corresponda a cada cobro:
--    · semanal  $399  → +7 días
--    · mensual $1,299 → +30 días (descuento vs 4 semanas = $1,596)
--
--  Reemplaza la versión de sql/497 (firma nueva con p_days DEFAULT 7 —
--  los cobros semanales existentes siguen funcionando igual).
-- ============================================================

BEGIN;

DROP FUNCTION IF EXISTS public.renew_recommendation_subscription(UUID, TEXT, NUMERIC);

CREATE OR REPLACE FUNCTION public.renew_recommendation_subscription(
  p_group_id   UUID,
  p_payment_id TEXT,
  p_amount     NUMERIC,
  p_days       INT DEFAULT 7
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
  v_days     INT := GREATEST(COALESCE(p_days, 7), 1);
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
    (p_group_id, p_amount, ROUND(p_amount / v_days, 2), v_days, 'paid',
     p_payment_id, v_start, v_start + (v_days || ' days')::INTERVAL,
     v_group.city, v_group.state)
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
        'Recomendado (suscripción ' || CASE WHEN v_days >= 30 THEN 'mensual' ELSE 'semanal' END
          || '): ' || COALESCE(v_group.name, p_group_id::TEXT)
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
      'Tu grupo sigue en "Recomendado para ti" ' || v_days || ' días más. Se renueva solo — puedes cancelar cuando quieras.',
      jsonb_build_object('screen', 'GroupReservations'));
  END IF;

  RETURN jsonb_build_object('ok', true, 'order_id', v_order_id,
    'starts_at', v_start, 'days', v_days);
END;
$$;

GRANT EXECUTE ON FUNCTION public.renew_recommendation_subscription(UUID, TEXT, NUMERIC, INT)
  TO service_role;

COMMIT;

-- ── VERIFICACIÓN ──────────────────────────────────────────────────────────────
SELECT prosrc LIKE '%p_days%' AS acepta_dias
FROM pg_proc WHERE proname = 'renew_recommendation_subscription';
-- Esperado: true

SELECT '502_rec_monthly_plan.sql ejecutado ✅' AS status;
