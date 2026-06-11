-- ═══════════════════════════════════════════════════════════════════════════════
-- 92_security_protections.sql
-- Faltante 11: Idempotencia para webhooks (payment_id en payment_transactions)
-- Faltante 12: Política de cancelación con reembolso por tiempo
-- Faltante 13: Detección de abuso (violaciones de contacto y cancelaciones)
-- ═══════════════════════════════════════════════════════════════════════════════

-- ────────────────────────────────────────────────────────────────────────────
-- FALTANTE 11: IDEMPOTENCIA DE PAGOS
-- El sistema ya tiene wallet_distributed + mp_payment_id en reservations.
-- Aquí agregamos payment_id en payment_transactions para deduplicar webhooks.
-- ────────────────────────────────────────────────────────────────────────────

ALTER TABLE payment_transactions
  ADD COLUMN IF NOT EXISTS payment_id TEXT;

-- Índice único: si el mismo payment_id ya existe, el INSERT falla silenciosamente
CREATE UNIQUE INDEX IF NOT EXISTS idx_pt_payment_id
  ON payment_transactions(payment_id)
  WHERE payment_id IS NOT NULL;

-- Función auxiliar para edge functions: verificar si un pago ya fue procesado
CREATE OR REPLACE FUNCTION is_payment_already_processed(p_payment_id TEXT)
RETURNS BOOLEAN LANGUAGE sql SECURITY DEFINER AS $$
  SELECT EXISTS (
    SELECT 1 FROM payment_transactions WHERE payment_id = p_payment_id
  );
$$;

GRANT EXECUTE ON FUNCTION is_payment_already_processed(TEXT) TO authenticated, service_role;

-- ────────────────────────────────────────────────────────────────────────────
-- FALTANTE 12: POLÍTICA DE CANCELACIÓN CON REEMBOLSO
-- ────────────────────────────────────────────────────────────────────────────

-- ── Tabla de registros de cancelación ────────────────────────────────────────
CREATE TABLE IF NOT EXISTS cancellation_records (
  id                UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  reservation_id    UUID        REFERENCES reservations(id) ON DELETE SET NULL,
  user_id           UUID        REFERENCES profiles(id) ON DELETE SET NULL,
  cancelled_at      TIMESTAMPTZ DEFAULT now(),
  hours_until_event NUMERIC,
  refund_policy     TEXT        CHECK (refund_policy IN ('full', 'partial', 'none', 'not_paid')),
  refund_amount     NUMERIC     DEFAULT 0,
  refund_status     TEXT        DEFAULT 'pending'
                                CHECK (refund_status IN ('pending','processed','not_applicable')),
  reason            TEXT,
  event_date        DATE,
  event_total       NUMERIC
);

ALTER TABLE cancellation_records ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "cr_admin_all" ON cancellation_records;
DROP POLICY IF EXISTS "cr_user_own"  ON cancellation_records;

CREATE POLICY "cr_admin_all" ON cancellation_records FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin'));

CREATE POLICY "cr_user_own" ON cancellation_records FOR SELECT TO authenticated
  USING (auth.uid() = user_id);

CREATE INDEX IF NOT EXISTS idx_cr_user_id ON cancellation_records(user_id);
CREATE INDEX IF NOT EXISTS idx_cr_cancelled_at ON cancellation_records(cancelled_at DESC);

-- ── RPC: consultar política antes de cancelar (para mostrar en UI) ─────────────

CREATE OR REPLACE FUNCTION get_cancellation_policy(p_reservation_id UUID)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_res           RECORD;
  v_hours_until   NUMERIC;
  v_refund_pct    NUMERIC := 0;
  v_refund_policy TEXT    := 'none';
  v_refund_amount NUMERIC := 0;
  v_deposit_paid  NUMERIC := 0;
BEGIN
  SELECT * INTO v_res
  FROM reservations
  WHERE id = p_reservation_id
    AND client_id = auth.uid();

  IF NOT FOUND THEN
    RETURN json_build_object('ok', false, 'error', 'reservation_not_found');
  END IF;

  -- Calcular horas hasta el evento
  v_hours_until := EXTRACT(EPOCH FROM (
    (v_res.event_date::TIMESTAMP + COALESCE(v_res.event_time::INTERVAL, INTERVAL '0'))
    - NOW()
  )) / 3600;

  -- Calcular cuánto pagó el cliente hasta ahora
  IF v_res.payment_status = 'fully_paid' THEN
    v_deposit_paid := COALESCE(v_res.total_price, 0);
  ELSIF v_res.payment_status IN ('deposit_paid', 'deposit_pending') THEN
    v_deposit_paid := ROUND(COALESCE(v_res.total_price, 0) * 0.5, 2);
  ELSE
    v_deposit_paid := 0;
  END IF;

  -- Aplicar política de reembolso
  IF v_deposit_paid = 0 THEN
    v_refund_policy := 'not_paid';
    v_refund_amount := 0;
  ELSIF v_hours_until > 48 THEN
    v_refund_policy := 'full';
    v_refund_pct    := 100;
    v_refund_amount := v_deposit_paid;
  ELSIF v_hours_until > 24 THEN
    v_refund_policy := 'partial';
    v_refund_pct    := 50;
    v_refund_amount := ROUND(v_deposit_paid * 0.5, 2);
  ELSE
    v_refund_policy := 'none';
    v_refund_pct    := 0;
    v_refund_amount := 0;
  END IF;

  RETURN json_build_object(
    'ok',             true,
    'hours_until',    ROUND(v_hours_until, 1),
    'refund_policy',  v_refund_policy,
    'refund_pct',     v_refund_pct,
    'refund_amount',  v_refund_amount,
    'deposit_paid',   v_deposit_paid,
    'event_date',     v_res.event_date,
    'total_price',    v_res.total_price
  );
END;
$$;

GRANT EXECUTE ON FUNCTION get_cancellation_policy(UUID) TO authenticated;

-- ── RPC: cancelar reserva con política de reembolso ───────────────────────────

DROP FUNCTION IF EXISTS client_cancel_reservation(UUID);
CREATE OR REPLACE FUNCTION client_cancel_reservation(p_reservation_id UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_res           RECORD;
  v_owner_id      UUID;
  v_hours_until   NUMERIC;
  v_refund_policy TEXT := 'none';
  v_refund_amount NUMERIC := 0;
  v_deposit_paid  NUMERIC := 0;
BEGIN
  SELECT * INTO v_res
  FROM reservations
  WHERE id = p_reservation_id
    AND client_id = auth.uid();

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Reserva no encontrada o sin permiso';
  END IF;

  IF v_res.status NOT IN (
    'pending', 'pending_payment', 'pending_group_confirmation', 'accepted', 'confirmed'
  ) THEN
    RAISE EXCEPTION 'No se puede cancelar una reserva con estado: %', v_res.status;
  END IF;

  -- Calcular horas hasta el evento
  v_hours_until := EXTRACT(EPOCH FROM (
    (v_res.event_date::TIMESTAMP + COALESCE(v_res.event_time::INTERVAL, INTERVAL '0'))
    - NOW()
  )) / 3600;

  -- Determinar cuánto pagó el cliente
  IF v_res.payment_status = 'fully_paid' THEN
    v_deposit_paid := COALESCE(v_res.total_price, 0);
  ELSIF v_res.payment_status IN ('deposit_paid', 'deposit_pending') THEN
    v_deposit_paid := ROUND(COALESCE(v_res.total_price, 0) * 0.5, 2);
  ELSE
    v_deposit_paid := 0;
  END IF;

  -- Política de reembolso
  IF v_deposit_paid = 0 THEN
    v_refund_policy := 'not_paid';
  ELSIF v_hours_until > 48 THEN
    v_refund_policy := 'full';
    v_refund_amount := v_deposit_paid;
  ELSIF v_hours_until > 24 THEN
    v_refund_policy := 'partial';
    v_refund_amount := ROUND(v_deposit_paid * 0.5, 2);
  ELSE
    v_refund_policy := 'none';
    v_refund_amount := 0;
  END IF;

  -- Cancelar
  UPDATE reservations
  SET status = 'cancelled'
  WHERE id = p_reservation_id;

  -- Registrar cancelación
  INSERT INTO cancellation_records (
    reservation_id, user_id, hours_until_event,
    refund_policy, refund_amount, refund_status,
    event_date, event_total
  ) VALUES (
    p_reservation_id, auth.uid(), v_hours_until,
    v_refund_policy, v_refund_amount,
    CASE WHEN v_refund_amount > 0 THEN 'pending' ELSE 'not_applicable' END,
    v_res.event_date, v_res.total_price
  );

  -- Notificar al dueño del grupo
  SELECT owner_id INTO v_owner_id FROM groups WHERE id = v_res.group_id;
  IF v_owner_id IS NOT NULL THEN
    INSERT INTO notifications (user_id, type, title, message, reference_id)
    VALUES (
      v_owner_id, 'reservation',
      '❌ Reserva cancelada',
      'El cliente canceló la reserva del ' || v_res.event_date ||
        CASE WHEN v_refund_amount > 0
          THEN '. Se procesará reembolso de $' || v_refund_amount::TEXT || '.'
          ELSE '.'
        END,
      p_reservation_id
    );
  END IF;

  -- Notificar al admin si hay reembolso pendiente
  IF v_refund_amount > 0 THEN
    INSERT INTO notifications (user_id, type, title, message, reference_id)
    SELECT id, 'financial',
      '💸 Reembolso pendiente por cancelación',
      'Cliente canceló evento del ' || v_res.event_date ||
        '. Reembolso a procesar: $' || v_refund_amount::TEXT || ' (' ||
        CASE v_refund_policy WHEN 'full' THEN '100%' WHEN 'partial' THEN '50%' END || ').',
      p_reservation_id
    FROM profiles WHERE role = 'admin';
  END IF;

  -- Detección de abuso: si el cliente tiene ≥3 cancelaciones en 30 días, notificar al admin
  IF (
    SELECT COUNT(*) FROM cancellation_records
    WHERE user_id = auth.uid()
      AND cancelled_at >= NOW() - INTERVAL '30 days'
  ) >= 3 THEN
    INSERT INTO notifications (user_id, type, title, message)
    SELECT id, 'admin_alert',
      '⚠️ Usuario con múltiples cancelaciones',
      'El usuario ' || auth.uid()::TEXT || ' tiene 3 o más cancelaciones en los últimos 30 días.',
      NULL
    FROM profiles WHERE role = 'admin';
  END IF;

  RETURN jsonb_build_object(
    'ok',             true,
    'refund_policy',  v_refund_policy,
    'refund_amount',  v_refund_amount,
    'hours_until',    ROUND(v_hours_until, 1)
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION client_cancel_reservation(UUID) TO authenticated;

-- ────────────────────────────────────────────────────────────────────────────
-- FALTANTE 13: DETECCIÓN DE ABUSO EN MENSAJES
-- contact_violation_logs ya existe (42_contact_safety.sql)
-- Aquí agregamos función para detectar usuarios con múltiples violaciones
-- ────────────────────────────────────────────────────────────────────────────

-- Función que admin puede llamar para obtener usuarios con violaciones repetidas
CREATE OR REPLACE FUNCTION get_users_with_repeated_violations(p_min_violations INT DEFAULT 3)
RETURNS TABLE (
  user_id       UUID,
  full_name     TEXT,
  violation_count BIGINT,
  last_violation  TIMESTAMPTZ,
  violation_types TEXT
) LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin') THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  RETURN QUERY
  SELECT
    cvl.user_id,
    p.full_name,
    COUNT(*)            AS violation_count,
    MAX(cvl.created_at) AS last_violation,
    STRING_AGG(DISTINCT cvl.violation_type, ', ') AS violation_types
  FROM contact_violation_logs cvl
  LEFT JOIN profiles p ON p.id = cvl.user_id
  WHERE cvl.created_at >= NOW() - INTERVAL '30 days'
  GROUP BY cvl.user_id, p.full_name
  HAVING COUNT(*) >= p_min_violations
  ORDER BY violation_count DESC;
END;
$$;

GRANT EXECUTE ON FUNCTION get_users_with_repeated_violations(INT) TO authenticated;

-- Función para que el admin obtenga el historial de cancelaciones de un usuario
CREATE OR REPLACE FUNCTION get_user_cancellation_history(p_user_id UUID)
RETURNS TABLE (
  event_date     DATE,
  hours_until    NUMERIC,
  refund_policy  TEXT,
  refund_amount  NUMERIC,
  cancelled_at   TIMESTAMPTZ
) LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin') THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  RETURN QUERY
  SELECT cr.event_date, cr.hours_until_event, cr.refund_policy,
         cr.refund_amount, cr.cancelled_at
  FROM cancellation_records cr
  WHERE cr.user_id = p_user_id
  ORDER BY cr.cancelled_at DESC;
END;
$$;

GRANT EXECUTE ON FUNCTION get_user_cancellation_history(UUID) TO authenticated;

SELECT '92_security_protections: idempotencia + política de cancelación + detección de abuso ✅' AS status;
