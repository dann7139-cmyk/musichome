-- ─────────────────────────────────────────────────────────────────────────────
-- 183_security_atomicity_audit.sql
-- Cierre de huecos críticos detectados en validación técnica:
--   1. financial_audit_logs — tabla de auditoría financiera
--   2. approve_extra_hour_payment_atomic — RPC atómica con FOR UPDATE + auditoría
--   3. Fix confirm_cash_extra_payment — verificación de ownership de grupo
--   4. Fix deduct_extra_from_client_balance — verificación de ownership (legacy)
--   5. Fix get_client_available_balance — permite cliente Y miembros del grupo
--   6. Restringir reservation_financial_summary — solo service_role/admin
--   7. admin_financial_summary — RPC segura para admin
--   8. verification_level — columna en grupos
--   9. Índices de performance faltantes
--  10. Idempotencia: UNIQUE en mp_payment_id
-- ─────────────────────────────────────────────────────────────────────────────

-- ── 1. Tabla de auditoría financiera ─────────────────────────────────────────
--
-- Cada movimiento financiero (aprobación de hora extra, descuento de saldo,
-- confirmación de efectivo) queda registrado con balances antes/después.
-- Solo funciones SECURITY DEFINER insertan aquí; no hay INSERT público.

CREATE TABLE IF NOT EXISTS financial_audit_logs (
  id                UUID        DEFAULT gen_random_uuid() PRIMARY KEY,
  actor_id          UUID        REFERENCES auth.users(id),
  action            TEXT        NOT NULL,
  amount            NUMERIC(12,2),
  reservation_id    UUID        REFERENCES reservations(id),
  extra_hour_id     UUID,
  payment_intent_id TEXT,
  before_balance    NUMERIC(12,2),
  after_balance     NUMERIC(12,2),
  metadata          JSONB       DEFAULT '{}',
  created_at        TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_fal_reservation_id ON financial_audit_logs(reservation_id);
CREATE INDEX IF NOT EXISTS idx_fal_actor_id       ON financial_audit_logs(actor_id);
CREATE INDEX IF NOT EXISTS idx_fal_action         ON financial_audit_logs(action);
CREATE INDEX IF NOT EXISTS idx_fal_created_at     ON financial_audit_logs(created_at DESC);

ALTER TABLE financial_audit_logs ENABLE ROW LEVEL SECURITY;

-- Solo admins leen la auditoría; nadie inserta directamente
DROP POLICY IF EXISTS fal_admin_select ON financial_audit_logs;
CREATE POLICY fal_admin_select ON financial_audit_logs
  FOR SELECT
  USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
  );

-- ── 2. RPC atómica: aprobar hora extra ───────────────────────────────────────
--
-- REEMPLAZA las dos operaciones separadas en ClientExtraHoursScreen:
--   (a) UPDATE extra_hours SET status = 'paid'
--   (b) deduct_extra_from_client_balance
--
-- Garantías:
--   - FOR UPDATE en ambas filas: sin race conditions ni doble-click
--   - Idempotente: si ya está 'paid', retorna ok+skipped sin error
--   - Verifica ownership: solo el cliente de la reserva puede aprobar
--   - Verifica saldo antes de descontar
--   - Inserta auditoría en la misma transacción

CREATE OR REPLACE FUNCTION approve_extra_hour_payment_atomic(
  p_extra_hour_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_extra          RECORD;
  v_reservation    RECORD;
  v_caller_id      UUID    := auth.uid();
  v_before_balance NUMERIC;
  v_after_balance  NUMERIC;
  v_action         TEXT;
BEGIN
  -- Verificar sesión activa
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'unauthorized: sesión requerida';
  END IF;

  -- Bloquear fila de hora extra (previene race condition / doble-click)
  SELECT * INTO v_extra
  FROM extra_hours
  WHERE id = p_extra_hour_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Hora extra no encontrada: %', p_extra_hour_id;
  END IF;

  -- Idempotencia: si ya fue pagada no hacemos nada (retorna éxito)
  IF v_extra.status = 'paid' THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'already_paid');
  END IF;

  IF v_extra.status = 'rejected' THEN
    RAISE EXCEPTION 'Esta hora extra fue rechazada y no puede aprobarse';
  END IF;

  -- Bloquear fila de reserva (evita modificaciones concurrentes del saldo)
  SELECT * INTO v_reservation
  FROM reservations
  WHERE id = v_extra.reservation_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Reserva no encontrada para esta hora extra';
  END IF;

  -- Verificar ownership: el caller debe ser el cliente de la reserva
  IF v_reservation.client_id != v_caller_id THEN
    RAISE EXCEPTION 'unauthorized: solo el cliente de la reserva puede aprobar horas extra';
  END IF;

  v_before_balance := COALESCE(v_reservation.client_available_balance, 0);

  IF v_extra.is_cash_payment THEN
    -- Efectivo: solo marcar paid, sin tocar saldo digital
    UPDATE extra_hours SET status = 'paid' WHERE id = p_extra_hour_id;
    v_after_balance := v_before_balance;
    v_action        := 'extra_approved_cash';
  ELSE
    -- Segunda verificación de saldo (primera es en frontend)
    IF v_before_balance < COALESCE(v_extra.total_extra_cost, 0) THEN
      RAISE EXCEPTION 'Saldo insuficiente: disponible=$%, requerido=$%',
        v_before_balance, v_extra.total_extra_cost;
    END IF;

    -- Marcar paid Y descontar saldo en la MISMA transacción
    UPDATE extra_hours
    SET status = 'paid'
    WHERE id = p_extra_hour_id;

    UPDATE reservations
    SET client_available_balance =
          GREATEST(0, COALESCE(client_available_balance, 0) - COALESCE(v_extra.total_extra_cost, 0))
    WHERE id = v_reservation.id
    RETURNING client_available_balance INTO v_after_balance;

    v_action := 'extra_approved_balance';
  END IF;

  -- Auditoría en la misma transacción (si falla, todo hace rollback)
  INSERT INTO financial_audit_logs (
    actor_id, action, amount, reservation_id, extra_hour_id,
    before_balance, after_balance
  ) VALUES (
    v_caller_id, v_action,
    COALESCE(v_extra.total_extra_cost, 0),
    v_reservation.id, p_extra_hour_id,
    v_before_balance,
    COALESCE(v_after_balance, v_before_balance)
  );

  RETURN jsonb_build_object(
    'ok',             true,
    'skipped',        false,
    'is_cash',        v_extra.is_cash_payment,
    'amount',         COALESCE(v_extra.total_extra_cost, 0),
    'before_balance', v_before_balance,
    'after_balance',  COALESCE(v_after_balance, v_before_balance)
  );
END;
$$;

-- ── 3. Fix: confirm_cash_extra_payment — verificar ownership de grupo ─────────
--
-- Bug original: solo verificaba que la reserva existía, no que el caller
-- pertenece al grupo de esa reserva. Cualquier usuario autenticado podía
-- confirmar efectivo de cualquier grupo.

CREATE OR REPLACE FUNCTION confirm_cash_extra_payment(
  p_extra_hour_id  UUID,
  p_reservation_id UUID
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_id UUID := auth.uid();
BEGIN
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'unauthorized: sesión requerida';
  END IF;

  -- El caller debe ser dueño del grupo o miembro activo de él
  IF NOT EXISTS (
    SELECT 1
    FROM reservations r
    JOIN groups g ON g.id = r.group_id
    LEFT JOIN job_invitations ji
      ON  ji.group_id        = g.id
      AND ji.invited_user_id = v_caller_id
      AND ji.status          = 'accepted'
      AND ji.invitation_type IN ('membership', 'job')
    WHERE r.id = p_reservation_id
      AND (g.owner_id = v_caller_id OR ji.invited_user_id IS NOT NULL)
  ) THEN
    RAISE EXCEPTION 'unauthorized: no eres parte del grupo de esta reserva';
  END IF;

  UPDATE extra_hours
  SET
    is_cash_payment   = TRUE,
    cash_confirmed_at = NOW(),
    status            = 'paid'
  WHERE
    id             = p_extra_hour_id
    AND reservation_id = p_reservation_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Hora extra no encontrada para esta reserva';
  END IF;

  -- Auditoría
  INSERT INTO financial_audit_logs (actor_id, action, reservation_id, extra_hour_id)
  VALUES (v_caller_id, 'cash_extra_confirmed', p_reservation_id, p_extra_hour_id);
END;
$$;

-- ── 4. Fix: deduct_extra_from_client_balance — agregar ownership ──────────────
--
-- Deprecado: usar approve_extra_hour_payment_atomic.
-- Se mantiene con verificación de ownership para compatibilidad.

CREATE OR REPLACE FUNCTION deduct_extra_from_client_balance(
  p_reservation_id UUID,
  p_amount         NUMERIC
)
RETURNS NUMERIC
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_id   UUID := auth.uid();
  v_new_balance NUMERIC;
BEGIN
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'unauthorized: sesión requerida';
  END IF;

  -- Solo el cliente de la reserva puede descontar su propio saldo
  IF NOT EXISTS (
    SELECT 1 FROM reservations
    WHERE id = p_reservation_id AND client_id = v_caller_id
  ) THEN
    RAISE EXCEPTION 'unauthorized: solo el cliente puede modificar su saldo';
  END IF;

  UPDATE reservations
  SET client_available_balance =
        GREATEST(0, COALESCE(client_available_balance, 0) - p_amount)
  WHERE id = p_reservation_id
  RETURNING client_available_balance INTO v_new_balance;

  RETURN COALESCE(v_new_balance, 0);
END;
$$;

-- ── 5. Fix: get_client_available_balance — cliente Y miembros del grupo ────────
--
-- Bug original: no había verificación de ownership. Cualquier usuario
-- autenticado podía consultar el saldo de cualquier reserva.
-- Ahora permite: cliente de la reserva ó dueño/miembro del grupo.

CREATE OR REPLACE FUNCTION get_client_available_balance(p_reservation_id UUID)
RETURNS NUMERIC
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_id UUID := auth.uid();
  v_balance   NUMERIC;
BEGIN
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'unauthorized: sesión requerida';
  END IF;

  -- Permitir al cliente O al grupo (dueño o miembro activo)
  IF NOT EXISTS (
    SELECT 1
    FROM reservations r
    LEFT JOIN groups g ON g.id = r.group_id
    LEFT JOIN job_invitations ji
      ON  ji.group_id        = g.id
      AND ji.invited_user_id = v_caller_id
      AND ji.status          = 'accepted'
      AND ji.invitation_type IN ('membership', 'job')
    WHERE r.id = p_reservation_id
      AND (
        r.client_id  = v_caller_id
        OR g.owner_id = v_caller_id
        OR ji.invited_user_id IS NOT NULL
      )
  ) THEN
    RAISE EXCEPTION 'unauthorized: no tienes acceso a esta reserva';
  END IF;

  SELECT client_available_balance
  INTO v_balance
  FROM reservations
  WHERE id = p_reservation_id;

  RETURN COALESCE(v_balance, 0);
END;
$$;

-- ── 6. Restringir reservation_financial_summary ───────────────────────────────
--
-- Bug original: GRANT SELECT TO authenticated permitía que cualquier usuario
-- logueado consultara emails y datos financieros de otros clientes.

REVOKE SELECT ON reservation_financial_summary FROM authenticated;
GRANT  SELECT ON reservation_financial_summary TO service_role;

-- ── 7. RPC admin para acceder al financial summary ────────────────────────────
--
-- Los admins acceden a través de esta RPC que verifica el rol antes de retornar.

CREATE OR REPLACE FUNCTION admin_financial_summary(
  p_limit  INT DEFAULT 50,
  p_offset INT DEFAULT 0
)
RETURNS TABLE (
  id                        UUID,
  total_price               NUMERIC,
  service_fee_amount        NUMERIC,
  group_earnings            NUMERIC,
  platform_commission       NUMERIC,
  client_available_balance  NUMERIC,
  installment_plan          TEXT,
  installment_months        INTEGER,
  installment_monthly_amount NUMERIC,
  status                    TEXT,
  payment_status            TEXT,
  event_date                DATE,
  group_name                TEXT,
  client_email              TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin') THEN
    RAISE EXCEPTION 'unauthorized: se requiere rol admin';
  END IF;

  RETURN QUERY
    SELECT
      rfs.id,
      rfs.total_price,
      rfs.service_fee_amount,
      rfs.group_earnings,
      rfs.platform_commission,
      rfs.client_available_balance,
      rfs.installment_plan,
      rfs.installment_months,
      rfs.installment_monthly_amount,
      rfs.status,
      rfs.payment_status,
      rfs.event_date,
      rfs.group_name,
      rfs.client_email
    FROM reservation_financial_summary rfs
    ORDER BY rfs.event_date DESC
    LIMIT p_limit OFFSET p_offset;
END;
$$;

-- ── 8. verification_level en grupos ──────────────────────────────────────────
--
-- Distingue niveles de verificación para evitar afirmar "KYC oficial"
-- mientras no exista un proveedor real (Onfido/Veriff):
--   none     = sin verificación
--   basic    = perfil completo, sin KYC de identidad
--   verified = documento + liveness enviados y aprobados por DARICEFY (actual)
--   enhanced = KYC real con proveedor externo (futuro)

ALTER TABLE groups
  ADD COLUMN IF NOT EXISTS verification_level TEXT DEFAULT 'none'
    CONSTRAINT chk_verification_level
      CHECK (verification_level IN ('none', 'basic', 'verified', 'enhanced'));

-- Sincronizar verification_level con verification_status existente
UPDATE groups
SET verification_level = CASE
  WHEN verification_status = 'approved' THEN 'verified'
  WHEN verification_status IN ('pending', 'rejected') THEN 'basic'
  ELSE 'none'
END
WHERE verification_level = 'none';

-- ── 9. Índices de performance faltantes ──────────────────────────────────────

CREATE INDEX IF NOT EXISTS idx_extra_hours_status
  ON extra_hours(status);

CREATE INDEX IF NOT EXISTS idx_extra_hours_reservation_id
  ON extra_hours(reservation_id);

CREATE INDEX IF NOT EXISTS idx_reservations_payment_status
  ON reservations(payment_status);

CREATE INDEX IF NOT EXISTS idx_reservations_payment_intent_id
  ON reservations(payment_intent_id)
  WHERE payment_intent_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_reservations_mp_preference_id
  ON reservations(mp_preference_id)
  WHERE mp_preference_id IS NOT NULL;

-- ── 10. Idempotencia del webhook: UNIQUE en mp_payment_id ─────────────────────
--
-- Evita que un webhook duplicado procese el mismo pago dos veces.
-- El DO block maneja el caso en que la columna ya exista o la constraint también.

DO $$
BEGIN
  -- Agregar columna si no existe
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name   = 'reservations'
      AND column_name  = 'mp_payment_id'
  ) THEN
    ALTER TABLE reservations ADD COLUMN mp_payment_id TEXT;
  END IF;

  -- Agregar constraint UNIQUE si no existe
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'uq_reservations_mp_payment_id'
  ) THEN
    ALTER TABLE reservations
      ADD CONSTRAINT uq_reservations_mp_payment_id UNIQUE (mp_payment_id);
  END IF;
END;
$$;

CREATE INDEX IF NOT EXISTS idx_reservations_mp_payment_id
  ON reservations(mp_payment_id)
  WHERE mp_payment_id IS NOT NULL;
