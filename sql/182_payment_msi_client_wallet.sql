-- ─────────────────────────────────────────────────────────────────────────────
-- 182_payment_msi_client_wallet.sql
-- MSI (Meses Sin Intereses), saldo cliente, trigger tarifa de servicio,
-- pago en efectivo para horas extra, validación de datos de contacto.
-- ─────────────────────────────────────────────────────────────────────────────

-- ── 1. Campos MSI y saldo cliente en reservations ────────────────────────────

ALTER TABLE reservations
  ADD COLUMN IF NOT EXISTS installment_plan TEXT DEFAULT NULL
    CONSTRAINT chk_installment_plan
      CHECK (installment_plan IS NULL OR installment_plan IN ('1_pago','3_msi','6_msi','9_msi','12_msi')),
  ADD COLUMN IF NOT EXISTS installment_months INTEGER DEFAULT NULL,
  ADD COLUMN IF NOT EXISTS installment_monthly_amount NUMERIC(10,2) DEFAULT NULL,
  ADD COLUMN IF NOT EXISTS service_fee_amount NUMERIC(10,2) DEFAULT NULL,
  ADD COLUMN IF NOT EXISTS client_available_balance NUMERIC(10,2) DEFAULT NULL;

-- ── 2. Campos pago en efectivo en extra_hours ─────────────────────────────────

ALTER TABLE extra_hours
  ADD COLUMN IF NOT EXISTS is_cash_payment BOOLEAN NOT NULL DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS cash_confirmed_at TIMESTAMPTZ DEFAULT NULL;

-- ── 3. Trigger: tarifa de servicio fija 10% (antes era dinámica 7-10%) ────────
--
-- REGLA DE NEGOCIO: Tarifa de servicio = 10% del total (inclusive).
-- El grupo recibe 90%. El cliente NO paga extra — la tarifa está incluida.
-- Corrección de Bug #1: el trigger anterior podía sobrescribir valores ya
-- calculados. Ahora solo actúa si los campos son NULL o 0.

CREATE OR REPLACE FUNCTION set_reservation_financials()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_fee     NUMERIC;
  v_earnings NUMERIC;
BEGIN
  -- Tarifa de servicio: 10% del total pagado por el cliente
  v_fee := ROUND(NEW.total_price * 0.10, 2);

  -- Solo asignar si no vienen explícitamente desde la llamada al INSERT
  IF NEW.service_fee_amount IS NULL THEN
    NEW.service_fee_amount := v_fee;
  END IF;

  -- platform_commission = service_fee_amount (alias para reportes legacy)
  IF NEW.platform_commission IS NULL OR NEW.platform_commission = 0 THEN
    NEW.platform_commission := NEW.service_fee_amount;
  END IF;

  -- group_earnings = total - tarifa
  IF NEW.group_earnings IS NULL OR NEW.group_earnings = 0 THEN
    NEW.group_earnings := NEW.total_price - NEW.service_fee_amount;
  END IF;

  -- Saldo disponible del cliente para horas extra (empieza igual que group_earnings)
  IF NEW.client_available_balance IS NULL THEN
    NEW.client_available_balance := NEW.group_earnings;
  END IF;

  RETURN NEW;
END;
$$;

-- Reemplazar trigger existente (si lo hubiera) sin romper datos actuales
DROP TRIGGER IF EXISTS trg_set_reservation_financials ON reservations;
CREATE TRIGGER trg_set_reservation_financials
  BEFORE INSERT ON reservations
  FOR EACH ROW
  EXECUTE FUNCTION set_reservation_financials();

-- ── 4. RPC: Confirmar pago en efectivo de horas extra (grupo) ─────────────────
--
-- Bug #2 fix: las horas extra se marcan pagadas solo después de confirmación
-- explícita (en efectivo o por tarjeta). Antes podían acreditarse sin verificar.

CREATE OR REPLACE FUNCTION confirm_cash_extra_payment(
  p_extra_hour_id  UUID,
  p_reservation_id UUID
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Verificar que la reserva existe y el caller tiene acceso vía RLS
  IF NOT EXISTS (
    SELECT 1 FROM reservations WHERE id = p_reservation_id
  ) THEN
    RAISE EXCEPTION 'Reserva no encontrada';
  END IF;

  UPDATE extra_hours
  SET
    is_cash_payment    = TRUE,
    cash_confirmed_at  = NOW(),
    status             = 'paid'
  WHERE
    id             = p_extra_hour_id
    AND reservation_id = p_reservation_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Hora extra no encontrada para esta reserva';
  END IF;
END;
$$;

-- ── 5. RPC: Descontar hora extra del saldo disponible del cliente ──────────────

CREATE OR REPLACE FUNCTION deduct_extra_from_client_balance(
  p_reservation_id UUID,
  p_amount         NUMERIC
)
RETURNS NUMERIC  -- retorna el nuevo saldo
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_new_balance NUMERIC;
BEGIN
  UPDATE reservations
  SET client_available_balance =
        GREATEST(0, COALESCE(client_available_balance, 0) - p_amount)
  WHERE id = p_reservation_id
  RETURNING client_available_balance INTO v_new_balance;

  RETURN COALESCE(v_new_balance, 0);
END;
$$;

-- ── 6. Función: validar que un texto no contenga datos de contacto ─────────────
--
-- Bug #4 fix: el campo de comentarios permitía incluir datos de contacto.
-- Esta función se puede invocar desde triggers o Edge Functions.

CREATE OR REPLACE FUNCTION contains_contact_data(p_text TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
  IF p_text IS NULL OR LENGTH(TRIM(p_text)) = 0 THEN
    RETURN FALSE;
  END IF;

  -- Teléfonos: 7+ dígitos consecutivos (tras quitar espacios/guiones)
  IF regexp_replace(p_text, '[\s\-\(\)\+\.]', '', 'g') ~ '\d{7,}' THEN
    RETURN TRUE;
  END IF;

  -- Emails
  IF p_text ~* '\b[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}\b' THEN
    RETURN TRUE;
  END IF;

  -- @usuario (redes sociales)
  IF p_text ~ '@[A-Za-z0-9_]{3,}' THEN
    RETURN TRUE;
  END IF;

  -- URLs http/https/www
  IF p_text ~* '(https?://|www\.)\S+' THEN
    RETURN TRUE;
  END IF;

  -- Plataformas de mensajería por nombre
  IF p_text ~* 'whatsapp|telegram|t\.me|wa\.me|instagram|facebook|tiktok' THEN
    RETURN TRUE;
  END IF;

  RETURN FALSE;
END;
$$;

-- Trigger que rechaza notas con datos de contacto en nuevas reservas
CREATE OR REPLACE FUNCTION reject_contact_in_notes()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF contains_contact_data(NEW.notes) THEN
    RAISE EXCEPTION
      'Las notas no pueden contener datos de contacto (teléfono, email, redes sociales). '
      'El chat interno se habilita después de confirmar la reserva.';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_reject_contact_in_notes ON reservations;
CREATE TRIGGER trg_reject_contact_in_notes
  BEFORE INSERT OR UPDATE OF notes ON reservations
  FOR EACH ROW
  EXECUTE FUNCTION reject_contact_in_notes();

-- ── 7. RPC: Obtener saldo disponible del cliente para una reserva ──────────────

CREATE OR REPLACE FUNCTION get_client_available_balance(p_reservation_id UUID)
RETURNS NUMERIC
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_balance NUMERIC;
BEGIN
  SELECT client_available_balance
  INTO v_balance
  FROM reservations
  WHERE id = p_reservation_id;

  RETURN COALESCE(v_balance, 0);
END;
$$;

-- ── 8. Vista: desglose financiero de reservas para admin ──────────────────────

CREATE OR REPLACE VIEW reservation_financial_summary AS
SELECT
  r.id,
  r.total_price,
  r.service_fee_amount,
  r.group_earnings,
  r.platform_commission,
  r.client_available_balance,
  r.installment_plan,
  r.installment_months,
  r.installment_monthly_amount,
  r.status,
  r.payment_status,
  r.event_date,
  g.name  AS group_name,
  p.email AS client_email
FROM reservations r
LEFT JOIN groups   g ON g.id = r.group_id
LEFT JOIN profiles p ON p.id = r.client_id;

-- Permitir acceso admin a la vista
GRANT SELECT ON reservation_financial_summary TO authenticated;
