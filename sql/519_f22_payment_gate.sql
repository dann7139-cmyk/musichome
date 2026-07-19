-- ============================================================
-- sql/519_f22_payment_gate.sql — F2.2: GATE DE PAGOS v2
-- (Diseño v4 aprobado 2026-07-18 + 3 precisiones finales)
--
-- QUÉ CREA (nada más):
--   1. payment_attempts   — captura INMUTABLE del checkout (fuente de verdad
--                           del importe esperado; la escriben los EFs de
--                           checkout, NO este archivo).
--   2. payment_receipts   — registro idempotente de cada pago recibido.
--                           UNIQUE(provider, provider_payment_id).
--   3. refund_intents     — INTENCIÓN de reembolso (el dinero lo mueve el
--                           admin/worker después, nunca esta transacción).
--                           UNIQUE(provider, provider_payment_id).
--   4. payment_config     — ventanas de webhook tardío por método +
--                           fecha de retiro del camino legacy. Editable
--                           sin migración.
--   5. chk_payment_status_v4 — agrega 'paid_blocked' al CHECK existente.
--   6. can_schedule()     — validación de disponibilidad COMPARTIDA
--                           (F2.3 le añadirá traslado POR DENTRO).
--   7. confirm_reservation_payment_v2() — la RPC del gate.
--
-- QUÉ NO HACE:
--   · NO toca confirm_full_payment_and_credit_wallet (rollback vivo).
--   · NO toca webhooks ni EFs (eso viene después, aparte).
--   · NO ejecuta servicios externos (cero llamadas fuera de la BD).
--   · NO estima processor fees EN NINGÚN PUNTO: real o NULL.
--   · NO modifica datos existentes (solo el CHECK, sin tocar filas).
--   · date_taken sigue ACTIVO (can_schedule lo incluye como regla (b);
--     se retira en F2.5). Dos eventos por día siguen deshabilitados.
--
-- IDENTIDADES NORMALIZADAS (precisión #2):
--   payment_attempts.provider_order_id  = Stripe PaymentIntent (pi_...)
--                                         | Conekta Order (ord_...)
--   payment_receipts.provider_payment_id = Stripe Charge (ch_...)
--                                         | Conekta Charge de la orden
--   payment_receipts.provider_order_id   = referencia al intento original
--   Cadena verificable: receipt → attempt → reserva → importe/moneda.
--
-- CAMBIO DOCUMENTADO vs RPC vieja: la wallet del admin ahora se acredita
-- con el BRUTO contractual (comisión + MSI). El neto real solo existe
-- cuando el fee del procesador está CAPTURADO (payment_receipts); si no,
-- la UI muestra "No capturado". Se elimina la estimación 3.6%+$3.
-- ============================================================

BEGIN;

-- ────────────────────────────────────────────────────────────
-- 1. payment_attempts — captura inmutable del checkout
--    Flujo del EF de checkout (precisión #3):
--      a) INSERT status='creating' con client_key idempotente propia
--         (los EFs reutilizan su Idempotency-Key actual, p.ej.
--         'pi_<reservation>_<centavos>').
--      b) crear PI/orden en el proveedor CON esa misma clave.
--      c) UPDATE → provider_order_id + status='created'.
--      d) SOLO entonces se devuelve el checkout al cliente.
--    Si (c) falla tras crear el objeto externo: reintento con la MISMA
--    client_key → el UNIQUE recupera la fila 'creating' y se reconcilia;
--    jamás se crea un segundo PI/orden ni se entrega referencia sin
--    captura local confirmada.
-- ────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS payment_attempts (
  id                    UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  provider              TEXT        NOT NULL CHECK (provider IN ('stripe','conekta')),
  client_key            TEXT        NOT NULL,
  provider_order_id     TEXT,
  reservation_id        UUID        NOT NULL REFERENCES reservations(id) ON DELETE CASCADE,
  expected_amount_minor BIGINT      NOT NULL CHECK (expected_amount_minor > 0),
  currency              TEXT        NOT NULL,
  method                TEXT        NOT NULL,          -- 'card' | 'spei' | 'cash'
  discount_minor        BIGINT      NOT NULL DEFAULT 0,
  msi_months            INT         NOT NULL DEFAULT 1,
  msi_fee_minor         BIGINT      NOT NULL DEFAULT 0,
  status                TEXT        NOT NULL DEFAULT 'creating'
    CHECK (status IN ('creating','created','consumed','abandoned')),
  expires_at            TIMESTAMPTZ,
  created_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT uq_attempt_client_key UNIQUE (provider, client_key),
  CONSTRAINT chk_attempt_created_has_ref
    CHECK (status <> 'created' OR provider_order_id IS NOT NULL)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_attempt_provider_order
  ON payment_attempts (provider, provider_order_id)
  WHERE provider_order_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_attempt_reservation
  ON payment_attempts (reservation_id);

ALTER TABLE payment_attempts ENABLE ROW LEVEL SECURITY;
-- Sin políticas: solo service_role (bypassa RLS). Nadie más lee/escribe.

-- ────────────────────────────────────────────────────────────
-- 2. payment_receipts — un pago recibido = una fila, exactamente una
-- ────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS payment_receipts (
  id                     UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  provider               TEXT        NOT NULL CHECK (provider IN ('stripe','conekta')),
  provider_payment_id    TEXT        NOT NULL,   -- Stripe ch_ / Conekta charge
  provider_order_id      TEXT,                   -- Stripe pi_ / Conekta ord_
  attempt_id             UUID        REFERENCES payment_attempts(id),
  reservation_id         UUID        REFERENCES reservations(id) ON DELETE SET NULL,
  amount_minor           BIGINT      NOT NULL CHECK (amount_minor >= 0),
  currency               TEXT        NOT NULL,
  method                 TEXT,
  result                 TEXT        NOT NULL DEFAULT 'processing',
  money_state            TEXT        NOT NULL DEFAULT 'recorded'
    CHECK (money_state IN ('recorded','credited','blocked_refund_pending')),
  -- FEE: real o NULL. PROHIBIDO estimar (regla financiera Daricefy).
  processor_fee_minor    BIGINT,
  processor_fee_status   TEXT        NOT NULL DEFAULT 'not_captured'
    CHECK (processor_fee_status IN ('captured','not_captured')),
  fee_source             TEXT,       -- 'stripe_balance_txn' | 'conekta_order' | 'manual_admin'
  legacy_without_attempt BOOLEAN     NOT NULL DEFAULT FALSE,
  raw_meta               JSONB,
  created_at             TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at             TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT uq_receipt_payment UNIQUE (provider, provider_payment_id),
  CONSTRAINT chk_receipt_fee_coherente CHECK (
    (processor_fee_status = 'captured'     AND processor_fee_minor IS NOT NULL) OR
    (processor_fee_status = 'not_captured' AND processor_fee_minor IS NULL)
  )
);

CREATE INDEX IF NOT EXISTS idx_receipt_reservation ON payment_receipts (reservation_id);
CREATE INDEX IF NOT EXISTS idx_receipt_order       ON payment_receipts (provider, provider_order_id);

ALTER TABLE payment_receipts ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS pr_admin_select ON payment_receipts;
CREATE POLICY pr_admin_select ON payment_receipts FOR SELECT USING (
  EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
);

-- ────────────────────────────────────────────────────────────
-- 3. refund_intents — intención de reembolso de dinero BLOQUEADO
--    (pre-confirmación). Disjunto de manual_refunds/process-refund,
--    que siguen cubriendo cancelaciones de pagos YA acreditados.
--    Un pago bloqueado nunca se confirma → nunca habrá un segundo
--    reembolso legítimo sobre él → UNIQUE(provider, payment_id) basta.
-- ────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS refund_intents (
  id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  provider            TEXT        NOT NULL CHECK (provider IN ('stripe','conekta')),
  provider_payment_id TEXT        NOT NULL,
  receipt_id          UUID        REFERENCES payment_receipts(id),
  reservation_id      UUID        REFERENCES reservations(id) ON DELETE SET NULL,
  client_id           UUID        REFERENCES profiles(id),
  amount_minor        BIGINT      NOT NULL CHECK (amount_minor > 0),
  currency            TEXT        NOT NULL,
  refund_type         TEXT        NOT NULL DEFAULT 'full'
    CHECK (refund_type IN ('full','excess')),
  reason              TEXT        NOT NULL,   -- código del contrato que lo originó
  status              TEXT        NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending','processing','done','cancelled')),
  processed_by        UUID,
  processed_at        TIMESTAMPTZ,
  notes               TEXT,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT uq_refund_intent UNIQUE (provider, provider_payment_id)
);

CREATE INDEX IF NOT EXISTS idx_refund_intent_status ON refund_intents (status);

ALTER TABLE refund_intents ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS ri_admin_select ON refund_intents;
CREATE POLICY ri_admin_select ON refund_intents FOR SELECT USING (
  EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
);

-- ────────────────────────────────────────────────────────────
-- 4. payment_config — ventanas configurables sin migración
-- ────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS payment_config (
  key         TEXT        PRIMARY KEY,
  value       TEXT        NOT NULL,
  description TEXT,
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE payment_config ENABLE ROW LEVEL SECURITY;
-- Sin políticas: solo service_role.

INSERT INTO payment_config (key, value, description) VALUES
  ('late_window_hours_card', '24',
   'Horas máx. tras crear el intento para aceptar webhook tardío (tarjeta)'),
  ('late_window_hours_spei', '72',
   'Horas máx. para aceptar webhook tardío (SPEI)'),
  ('late_window_hours_cash', '72',
   'Horas máx. para aceptar webhook tardío (OXXO/efectivo)'),
  ('legacy_attempt_cutoff', '2026-08-31',
   'Fecha de retiro del camino legacy_without_attempt (pagos creados antes del deploy de F2.2)')
ON CONFLICT (key) DO NOTHING;

-- ────────────────────────────────────────────────────────────
-- 5. payment_status: agregar 'paid_blocked' (v3 → v4)
--    Columna TEXT + CHECK (verificado en sql/204). No toca filas.
-- ────────────────────────────────────────────────────────────
DO $$ BEGIN
  ALTER TABLE reservations DROP CONSTRAINT IF EXISTS chk_payment_status_v3;
EXCEPTION WHEN OTHERS THEN NULL; END; $$;
DO $$ BEGIN
  ALTER TABLE reservations DROP CONSTRAINT IF EXISTS chk_payment_status_v4;
EXCEPTION WHEN OTHERS THEN NULL; END; $$;

ALTER TABLE reservations
  ADD CONSTRAINT chk_payment_status_v4 CHECK (
    payment_status IN (
      'unpaid', 'pending', 'pending_payment',
      'deposit_pending', 'deposit_paid', 'remaining_pending',
      'fully_paid', 'paid',
      'payment_failed', 'refunded', 'cancelled',
      'paid_blocked'
    )
  );

-- ────────────────────────────────────────────────────────────
-- 6. can_schedule — validación de disponibilidad COMPARTIDA
--    ⚠️ Llamar SIEMPRE con pg_advisory_xact_lock(hashtext(group_id::text))
--       YA tomado (mismo carril que los triggers de F1).
--    Devuelve NULL si está disponible, o el motivo:
--      'date_blocked'      — bloqueo manual del grupo ese día
--      'date_taken_legacy' — regla legado 1 evento/día (SE RETIRA EN F2.5)
--      'daily_limit'       — ya hay 2 eventos ese día local (cuenta completed)
--      'time_overlap'      — el rango choca con otro evento ocupante
--    F2.3 añadirá la validación de TRASLADO aquí dentro (sin llamadas
--    externas en transacción). Nadie debe duplicar estas reglas fuera.
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.can_schedule(
  p_group_id   UUID,
  p_event_date DATE,
  p_range      TSTZRANGE,
  p_exclude    UUID DEFAULT NULL
)
RETURNS TEXT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  -- (a) Bloqueo manual del día
  IF EXISTS (
    SELECT 1 FROM group_unavailability gu
    WHERE gu.group_id = p_group_id AND gu.date = p_event_date
  ) THEN
    RETURN 'date_blocked';
  END IF;

  -- (b) LEGADO date_taken — intacto hasta F2.5 (mismos estados que sql/434)
  IF EXISTS (
    SELECT 1 FROM reservations r
    WHERE r.group_id = p_group_id
      AND r.event_date = p_event_date
      AND (p_exclude IS NULL OR r.id <> p_exclude)
      AND r.status IN ('pending','pending_payment','pending_group_confirmation',
                       'confirmed','in_progress')
  ) THEN
    RETURN 'date_taken_legacy';
  END IF;

  -- (c) Límite 2 eventos/día local (completed SÍ cuenta)
  IF public.count_events_local_day(p_group_id, p_event_date, p_exclude) >= 2 THEN
    RETURN 'daily_limit';
  END IF;

  -- (d) Traslape duro de rangos ocupantes
  IF p_range IS NOT NULL AND EXISTS (
    SELECT 1 FROM reservations r
    WHERE r.group_id = p_group_id
      AND (p_exclude IS NULL OR r.id <> p_exclude)
      AND r.status = ANY (public.estados_que_ocupan())
      AND r.busy_range IS NOT NULL
      AND r.busy_range && p_range
  ) THEN
    RETURN 'time_overlap';
  END IF;

  RETURN NULL;  -- disponible
END;
$$;

REVOKE ALL ON FUNCTION public.can_schedule(UUID, DATE, TSTZRANGE, UUID)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.can_schedule(UUID, DATE, TSTZRANGE, UUID)
  TO service_role;

-- ────────────────────────────────────────────────────────────
-- 7. confirm_reservation_payment_v2 — el gate
--
-- ORDEN DE LOCKS (único, en toda la plataforma):
--   1. leer group_id (SELECT simple, sin lock)
--   2. pg_advisory_xact_lock(hashtext(group_id::text))
--   3. SELECT ... FOR UPDATE de la reserva
--   4. re-verificar group_id (si cambió → temporary_retry, cero efectos)
--
-- CONTRATO DE RESULTADOS (campo 'result' del JSONB):
--   confirmed | already_processed | payment_blocked_refund_pending |
--   terminal_reservation | amount_mismatch | overpayment_refund_pending |
--   currency_mismatch | payment_identity_conflict | capture_missing |
--   late_payment_outside_window | temporary_lock_timeout | temporary_retry
--   (excepción no capturada = technical_error del lado del webhook → 500)
--
-- MATRIZ HTTP (idéntica Stripe/Conekta, la aplica el webhook):
--   200 (no reintenta): confirmed, already_processed,
--        payment_blocked_refund_pending, terminal_reservation,
--        amount_mismatch, overpayment_refund_pending, currency_mismatch,
--        payment_identity_conflict, capture_missing,
--        late_payment_outside_window
--   500 (reintenta, CERO efectos escritos): temporary_lock_timeout,
--        temporary_retry, technical_error
--
-- PRECISIÓN #1: payment_identity_conflict = SOLO auditoría + admin.
--   No muta ninguna reserva, no toca el receipt original, no crea
--   reembolso. El resultado financiero original del payment_id se
--   conserva. Reembolsar requiere decisión humana.
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.confirm_reservation_payment_v2(
  p_provider            TEXT,             -- 'stripe' | 'conekta'
  p_provider_order_id   TEXT,             -- pi_... | ord_...
  p_provider_payment_id TEXT,             -- ch_... | charge de Conekta
  p_reservation_id      UUID,             -- de la metadata del proveedor
  p_amount_minor        BIGINT,           -- cobrado, en unidades menores
  p_currency            TEXT,             -- 'MXN' | 'USD' | 'CAD'
  p_method              TEXT    DEFAULT NULL,
  p_fee_minor           BIGINT  DEFAULT NULL,  -- fee REAL o NULL. Nunca estimado.
  p_fee_source          TEXT    DEFAULT NULL,  -- 'stripe_balance_txn' | 'conekta_order'
  p_legacy_expected     JSONB   DEFAULT NULL   -- SOLO pagos pre-F2.2 sin attempt:
                                               -- {amount_minor, currency, reservation_id}
                                               -- derivado del objeto RE-CONSULTADO al proveedor
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_attempt        RECORD;
  v_res            RECORD;
  v_group_id       UUID;
  v_receipt_id     UUID;
  v_existing       RECORD;
  v_expected_minor BIGINT;
  v_expected_cur   TEXT;
  v_is_legacy      BOOLEAN := FALSE;
  v_currency       TEXT;
  v_result         TEXT;
  v_reason         TEXT;
  v_block_paysts   BOOLEAN := TRUE;   -- ¿marcar payment_status='paid_blocked'?
  v_window_h       INT;
  v_method_key     TEXT;
  v_range          TSTZRANGE;
  v_sched          TEXT;
  v_earnings       NUMERIC;
  v_service_fee    NUMERIC;
  v_msi_fee        NUMERIC;
  v_admin_bruto    NUMERIC;
  v_admin_id       UUID;
  v_wallet_id      UUID;
  v_fee_pesos      NUMERIC;
BEGIN
  -- Timeout de espera de locks: excedido → excepción capturable →
  -- temporary_lock_timeout (500, reintento). statement_timeout externo
  -- queda como tope duro no capturable (→ technical_error/500).
  PERFORM set_config('lock_timeout', '5000', TRUE);

  -- Validación interna de parámetros (no confiar en el llamador)
  IF p_provider NOT IN ('stripe','conekta')
     OR COALESCE(TRIM(p_provider_payment_id), '') = ''
     OR p_amount_minor IS NULL OR p_amount_minor < 0
     OR UPPER(COALESCE(p_currency,'')) NOT IN ('MXN','USD','CAD') THEN
    RAISE EXCEPTION 'confirm_reservation_payment_v2: parámetros inválidos (provider=%, payment=%, amount=%, currency=%)',
      p_provider, p_provider_payment_id, p_amount_minor, p_currency;
  END IF;
  v_currency := UPPER(p_currency);

  -- ── A. Resolver el importe esperado (captura inmutable) ──────────
  SELECT * INTO v_attempt
  FROM payment_attempts
  WHERE provider = p_provider AND provider_order_id = p_provider_order_id;

  IF FOUND THEN
    v_expected_minor := v_attempt.expected_amount_minor;
    v_expected_cur   := UPPER(v_attempt.currency);
    v_method_key     := COALESCE(v_attempt.method, p_method, 'card');

    -- Identidad intento ↔ metadata del pago
    IF v_attempt.reservation_id IS DISTINCT FROM p_reservation_id THEN
      INSERT INTO payment_receipts
        (provider, provider_payment_id, provider_order_id, attempt_id,
         reservation_id, amount_minor, currency, method,
         result, money_state, raw_meta)
      VALUES
        (p_provider, p_provider_payment_id, p_provider_order_id, v_attempt.id,
         NULL, p_amount_minor, v_currency, p_method,
         'payment_identity_conflict', 'recorded',
         jsonb_build_object('metadata_reservation', p_reservation_id,
                            'attempt_reservation', v_attempt.reservation_id))
      ON CONFLICT (provider, provider_payment_id) DO NOTHING;

      INSERT INTO financial_audit_logs
        (entity_type, entity_id, action, actor_id, actor_role, amount, notes)
      VALUES ('payment', v_attempt.reservation_id, 'payment_identity_conflict',
        NULL, 'system', p_amount_minor / 100.0,
        format('SEVERIDAD ALTA: pago %s/%s con metadata reserva=%s pero intento reserva=%s. Sin mutaciones, sin reembolso automático. Requiere revisión humana.',
          p_provider, p_provider_payment_id, p_reservation_id, v_attempt.reservation_id));

      INSERT INTO notifications (user_id, type, title, body, data)
      SELECT p.id, 'reservation', '🚨 Conflicto de identidad de pago',
        format('El pago %s (%s) no coincide con su intento de checkout. NO se movió dinero. Revisa el panel financiero.',
          p_provider_payment_id, p_provider),
        jsonb_build_object('screen', 'AdminFinancial',
                           'provider_payment_id', p_provider_payment_id)
      FROM profiles p WHERE p.role = 'admin';

      RETURN jsonb_build_object('result', 'payment_identity_conflict');
    END IF;

  ELSE
    -- Sin attempt: camino LEGACY (pagos creados antes del deploy F2.2)
    IF p_legacy_expected IS NOT NULL
       AND (p_legacy_expected->>'amount_minor') IS NOT NULL
       AND NOW() < COALESCE(
             (SELECT value::DATE FROM payment_config
              WHERE key = 'legacy_attempt_cutoff'), DATE '2026-08-31') THEN
      v_is_legacy      := TRUE;
      v_expected_minor := (p_legacy_expected->>'amount_minor')::BIGINT;
      v_expected_cur   := UPPER(COALESCE(p_legacy_expected->>'currency', v_currency));
      v_method_key     := COALESCE(p_method, 'card');

      IF (p_legacy_expected->>'reservation_id')::UUID IS DISTINCT FROM p_reservation_id THEN
        RAISE EXCEPTION 'legacy_expected inconsistente con p_reservation_id';
      END IF;

      INSERT INTO financial_audit_logs
        (entity_type, entity_id, action, actor_id, actor_role, amount, notes)
      VALUES ('payment', p_reservation_id, 'legacy_without_attempt',
        NULL, 'system', p_amount_minor / 100.0,
        format('Pago %s/%s procesado SIN captura local (creado pre-F2.2). Esperado tomado del objeto re-consultado al proveedor. Camino con fecha de retiro (payment_config.legacy_attempt_cutoff).',
          p_provider, p_provider_payment_id));
    ELSE
      -- Sin captura y sin snapshot legacy válido (o cutoff vencido):
      -- NO se puede validar → auditoría + admin. Sin reembolso automático
      -- (el dinero podría corresponder legítimamente a otra cosa).
      INSERT INTO payment_receipts
        (provider, provider_payment_id, provider_order_id, reservation_id,
         amount_minor, currency, method, result, money_state, raw_meta)
      VALUES
        (p_provider, p_provider_payment_id, p_provider_order_id,
         (SELECT id FROM reservations WHERE id = p_reservation_id),
         p_amount_minor, v_currency, p_method,
         'capture_missing', 'recorded',
         jsonb_build_object('metadata_reservation', p_reservation_id))
      ON CONFLICT (provider, provider_payment_id) DO NOTHING;

      INSERT INTO financial_audit_logs
        (entity_type, entity_id, action, actor_id, actor_role, amount, notes)
      VALUES ('payment', p_reservation_id, 'capture_missing',
        NULL, 'system', p_amount_minor / 100.0,
        format('SEVERIDAD ALTA: pago %s/%s sin captura de checkout ni snapshot legacy verificable. Sin mutaciones, sin reembolso automático. Resolución manual.',
          p_provider, p_provider_payment_id));

      INSERT INTO notifications (user_id, type, title, body, data)
      SELECT p.id, 'reservation', '🚨 Pago sin captura de checkout',
        format('Llegó el pago %s (%s) y no existe registro del intento. NO se movió dinero. Revisa el panel financiero.',
          p_provider_payment_id, p_provider),
        jsonb_build_object('screen', 'AdminFinancial',
                           'provider_payment_id', p_provider_payment_id)
      FROM profiles p WHERE p.role = 'admin';

      RETURN jsonb_build_object('result', 'capture_missing');
    END IF;
  END IF;

  -- ── B. ORDEN DE LOCKS ────────────────────────────────────────────
  SELECT group_id INTO v_group_id FROM reservations WHERE id = p_reservation_id;
  IF NOT FOUND THEN
    -- Metadata apunta a una reserva inexistente → identidad inconsistente
    INSERT INTO payment_receipts
      (provider, provider_payment_id, provider_order_id, attempt_id,
       amount_minor, currency, method, result, money_state,
       legacy_without_attempt, raw_meta)
    VALUES
      (p_provider, p_provider_payment_id, p_provider_order_id,
       CASE WHEN v_is_legacy THEN NULL ELSE v_attempt.id END,
       p_amount_minor, v_currency, p_method,
       'payment_identity_conflict', 'recorded', v_is_legacy,
       jsonb_build_object('metadata_reservation', p_reservation_id,
                          'motivo', 'reserva_inexistente'))
    ON CONFLICT (provider, provider_payment_id) DO NOTHING;

    INSERT INTO financial_audit_logs
      (entity_type, entity_id, action, actor_id, actor_role, amount, notes)
    VALUES ('payment', NULL, 'payment_identity_conflict', NULL, 'system',
      p_amount_minor / 100.0,
      format('SEVERIDAD ALTA: pago %s/%s con metadata de reserva inexistente %s. Sin reembolso automático.',
        p_provider, p_provider_payment_id, p_reservation_id));

    INSERT INTO notifications (user_id, type, title, body, data)
    SELECT p.id, 'reservation', '🚨 Conflicto de identidad de pago',
      format('El pago %s apunta a una reserva inexistente. Revisa el panel financiero.', p_provider_payment_id),
      jsonb_build_object('screen', 'AdminFinancial')
    FROM profiles p WHERE p.role = 'admin';

    RETURN jsonb_build_object('result', 'payment_identity_conflict');
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext(v_group_id::text));  -- mismo carril que F1

  SELECT * INTO v_res FROM reservations WHERE id = p_reservation_id FOR UPDATE;

  IF v_res.group_id IS DISTINCT FROM v_group_id THEN
    -- Cambió de grupo entre la lectura y el lock (jamás debería pasar):
    -- resultado controlado, cero efectos; el reintento del proveedor
    -- entrará ya con el grupo correcto.
    RETURN jsonb_build_object('result', 'temporary_retry');
  END IF;

  -- ── C. Idempotencia: reclamar el pago (precisiones #1 y #4/v4) ───
  INSERT INTO payment_receipts
    (provider, provider_payment_id, provider_order_id, attempt_id,
     reservation_id, amount_minor, currency, method,
     result, money_state, legacy_without_attempt)
  VALUES
    (p_provider, p_provider_payment_id, p_provider_order_id,
     CASE WHEN v_is_legacy THEN NULL ELSE v_attempt.id END,
     p_reservation_id, p_amount_minor, v_currency, COALESCE(p_method, v_method_key),
     'processing', 'recorded', v_is_legacy)
  ON CONFLICT (provider, provider_payment_id) DO NOTHING
  RETURNING id INTO v_receipt_id;

  IF v_receipt_id IS NULL THEN
    -- Ya existe un receipt para este payment_id → leerlo y decidir
    SELECT * INTO v_existing
    FROM payment_receipts
    WHERE provider = p_provider AND provider_payment_id = p_provider_payment_id;

    IF v_existing.reservation_id IS NOT DISTINCT FROM p_reservation_id
       AND v_existing.amount_minor = p_amount_minor
       AND v_existing.currency = v_currency THEN
      RETURN jsonb_build_object('result', 'already_processed',
                                'receipt_id', v_existing.id,
                                'prior_result', v_existing.result);
    END IF;

    -- Identidad inconsistente: el pago YA pertenece al receipt original.
    -- Solo auditoría + admin. Sin crédito nuevo, sin reembolso, sin tocar
    -- ninguna reserva ni el receipt original.
    INSERT INTO financial_audit_logs
      (entity_type, entity_id, action, actor_id, actor_role, amount, notes)
    VALUES ('payment', v_existing.reservation_id, 'payment_identity_conflict',
      NULL, 'system', p_amount_minor / 100.0,
      format('SEVERIDAD ALTA: payment_id %s/%s ya registrado (reserva=%s, %s %s, resultado=%s); llegó de nuevo con reserva=%s, %s %s. Se conserva el resultado original. Sin reembolso automático.',
        p_provider, p_provider_payment_id,
        v_existing.reservation_id, v_existing.amount_minor, v_existing.currency,
        v_existing.result,
        p_reservation_id, p_amount_minor, v_currency));

    INSERT INTO notifications (user_id, type, title, body, data)
    SELECT p.id, 'reservation', '🚨 Conflicto de identidad de pago',
      format('El pago %s llegó asociado a otra reserva o con datos distintos. Se conservó el registro original; NO se movió dinero. Revisa el panel financiero.',
        p_provider_payment_id),
      jsonb_build_object('screen', 'AdminFinancial',
                         'provider_payment_id', p_provider_payment_id,
                         'receipt_id', v_existing.id)
    FROM profiles p WHERE p.role = 'admin';

    RETURN jsonb_build_object('result', 'payment_identity_conflict',
                              'receipt_id', v_existing.id);
  END IF;

  -- ── D. Cascada de decisión (tabla v4 §4) ─────────────────────────
  v_result := NULL;
  v_reason := NULL;

  -- D1. Moneda
  IF v_currency <> v_expected_cur THEN
    v_result := 'currency_mismatch';
    v_reason := format('moneda recibida %s ≠ esperada %s', v_currency, v_expected_cur);

  -- D2. Importe exacto en unidades menores, tolerancia CERO
  ELSIF p_amount_minor < v_expected_minor THEN
    v_result := 'amount_mismatch';
    v_reason := format('recibido %s < esperado %s (unidades menores)', p_amount_minor, v_expected_minor);
  ELSIF p_amount_minor > v_expected_minor THEN
    v_result := 'overpayment_refund_pending';
    v_reason := format('recibido %s > esperado %s (unidades menores) — política: bloqueo total', p_amount_minor, v_expected_minor);

  -- D3. Reserva terminal
  ELSIF v_res.status IN ('cancelled', 'rejected') THEN
    v_result := 'terminal_reservation';
    v_reason := format('reserva en estado terminal %s al llegar el pago', v_res.status);

  -- D4. Reserva ya pagada con OTRO payment_id (cobro duplicado)
  ELSIF v_res.payment_status IN ('paid', 'fully_paid') THEN
    v_result := 'payment_blocked_refund_pending';
    v_reason := format('reserva ya pagada (pago original %s); este cobro %s es duplicado y se devuelve íntegro',
      COALESCE(v_res.mp_payment_id, 's/ref'), p_provider_payment_id);
    v_block_paysts := FALSE;  -- la reserva quedó BIEN pagada: no se toca

  -- D5. Expirada: ¿revive?
  ELSIF v_res.status = 'expired' THEN
    v_window_h := COALESCE(
      (SELECT value::INT FROM payment_config
       WHERE key = 'late_window_hours_' || COALESCE(v_method_key, 'card')), 24);

    IF v_is_legacy OR v_attempt.created_at < NOW() - make_interval(hours => v_window_h) THEN
      v_result := 'late_payment_outside_window';
      v_reason := format('pago tardío fuera de la ventana de %s h para método %s', v_window_h, v_method_key);
    ELSE
      v_range := COALESCE(v_res.busy_range,
        public.make_busy_range(v_res.event_date, v_res.event_time,
          COALESCE(v_res.event_tz, 'America/Mexico_City'),
          v_res.hours_count,
          COALESCE((SELECT SUM(eh.hours_added) FROM extra_hours eh
                    WHERE eh.reservation_id = v_res.id), 0)::INT));
      v_sched := public.can_schedule(v_group_id, v_res.event_date, v_range, v_res.id);
      IF v_sched IS NOT NULL THEN
        v_result := 'payment_blocked_refund_pending';
        v_reason := format('disponibilidad perdida al revivir (%s)', v_sched);
      END IF;
      -- v_sched NULL → revive: cae al flujo de confirmación
    END IF;

  -- D6. Estados vivos no pagados → validación preventiva
  ELSE
    v_range := COALESCE(v_res.busy_range,
      public.make_busy_range(v_res.event_date, v_res.event_time,
        COALESCE(v_res.event_tz, 'America/Mexico_City'),
        v_res.hours_count,
        COALESCE((SELECT SUM(eh.hours_added) FROM extra_hours eh
                  WHERE eh.reservation_id = v_res.id), 0)::INT));
    v_sched := public.can_schedule(v_group_id, v_res.event_date, v_range, v_res.id);
    IF v_sched IS NOT NULL THEN
      v_result := 'payment_blocked_refund_pending';
      v_reason := format('disponibilidad perdida (%s)', v_sched);
    END IF;
  END IF;

  -- ── E. RAMA BLOQUEADA: paid_blocked + reembolso íntegro en cola ──
  IF v_result IS NOT NULL THEN
    IF v_block_paysts THEN
      UPDATE reservations SET
        payment_status = 'paid_blocked',
        mp_payment_id  = p_provider_payment_id,
        updated_at     = NOW()
      WHERE id = p_reservation_id;
      -- status (ciclo de la reserva) NO se toca: máquinas separadas.
    END IF;

    UPDATE payment_receipts SET
      result              = v_result,
      money_state         = 'blocked_refund_pending',
      processor_fee_minor = p_fee_minor,
      processor_fee_status = CASE WHEN p_fee_minor IS NULL THEN 'not_captured' ELSE 'captured' END,
      fee_source          = CASE WHEN p_fee_minor IS NULL THEN NULL ELSE p_fee_source END,
      raw_meta            = jsonb_build_object('reason', v_reason),
      updated_at          = NOW()
    WHERE id = v_receipt_id;

    INSERT INTO refund_intents
      (provider, provider_payment_id, receipt_id, reservation_id, client_id,
       amount_minor, currency, refund_type, reason)
    VALUES
      (p_provider, p_provider_payment_id, v_receipt_id, p_reservation_id,
       v_res.client_id, p_amount_minor, v_currency, 'full', v_result)
    ON CONFLICT (provider, provider_payment_id) DO NOTHING;

    INSERT INTO financial_audit_logs
      (entity_type, entity_id, action, actor_id, actor_role, amount, notes)
    VALUES ('reservation', p_reservation_id, 'payment_blocked', NULL, 'system',
      p_amount_minor / 100.0,
      format('[%s] %s — pago=%s/%s. Dinero NO acreditado; reembolso íntegro en cola (refund_intents).',
        v_result, v_reason, p_provider, p_provider_payment_id));

    INSERT INTO notifications (user_id, type, title, body, data)
    SELECT p.id, 'reservation', '🚨 Pago bloqueado — requiere reembolso',
      format('Reserva %s: %s. El dinero quedó BLOQUEADO (no se acreditó al grupo). Procesa el reembolso desde el panel financiero.',
        COALESCE(v_res.folio, p_reservation_id::TEXT), v_reason),
      jsonb_build_object('screen', 'AdminFinancial', 'reservation_id', p_reservation_id)
    FROM profiles p WHERE p.role = 'admin';

    INSERT INTO notifications (user_id, type, title, body, data)
    VALUES (v_res.client_id, 'payment', 'Recibimos tu pago — será reembolsado',
      format('Tu pago de la reserva %s no pudo aplicarse (%s). Te devolveremos el monto completo; te avisaremos cuando el reembolso esté en camino.',
        COALESCE(v_res.folio, ''),
        CASE WHEN v_result IN ('amount_mismatch','overpayment_refund_pending','currency_mismatch')
             THEN 'el importe no coincidió con tu orden'
             ELSE 'la reserva ya no estaba disponible' END),
      jsonb_build_object('screen', 'Reservations', 'reservation_id', p_reservation_id));

    RETURN jsonb_build_object('result', v_result, 'receipt_id', v_receipt_id,
                              'reason', v_reason);
  END IF;

  -- ── F. CONFIRMAR + ACREDITAR (réplica de 509 SIN estimación de fee) ─
  v_earnings    := COALESCE(v_res.base_price, ROUND(v_res.total_price / 1.20, 2));
  v_service_fee := COALESCE(v_res.service_fee_amount,
                     v_res.total_price - ROUND(v_res.total_price / 1.20, 2));
  v_msi_fee     := COALESCE(v_res.msi_fee_amount, 0);
  v_admin_bruto := v_service_fee + v_msi_fee;
  v_fee_pesos   := CASE WHEN p_fee_minor IS NULL THEN NULL ELSE p_fee_minor / 100.0 END;

  PERFORM ensure_group_wallet(v_group_id);
  SELECT id INTO v_wallet_id FROM group_wallets WHERE group_id = v_group_id;

  IF v_currency = 'USD' THEN
    UPDATE group_wallets SET
      pending_balance_usd = pending_balance_usd + v_earnings,
      total_earned_usd    = total_earned_usd    + v_earnings,
      updated_at          = NOW()
    WHERE id = v_wallet_id;
  ELSE
    UPDATE group_wallets SET
      pending_balance = pending_balance + v_earnings,
      total_earned    = total_earned    + v_earnings,
      updated_at      = NOW()
    WHERE id = v_wallet_id;
  END IF;

  UPDATE reservations SET
    status              = CASE WHEN status IN ('pending','pending_payment',
                                               'pending_group_confirmation',
                                               'accepted','expired')
                               THEN 'confirmed' ELSE status END,
    payment_status      = 'paid',
    payout_status       = 'held',
    held_at             = NOW(),
    mp_payment_id       = p_provider_payment_id,
    payment_provider    = p_provider,
    payment_method_type = COALESCE(p_method, v_method_key, payment_method_type),
    stripe_fee_amount   = COALESCE(v_fee_pesos, stripe_fee_amount),  -- real o intacto; NUNCA estimado
    service_fee_amount  = v_service_fee,
    group_earnings      = v_earnings,
    updated_at          = NOW()
  WHERE id = p_reservation_id;
  -- Los triggers F1 + constraint de exclusión + date_taken legado actúan
  -- aquí como ÚLTIMA BARRERA. Ya pre-validamos con can_schedule bajo el
  -- mismo advisory lock: si aun así saltan, es una anomalía real → la
  -- transacción entera aborta → el webhook responde 500 y se reintenta.

  INSERT INTO wallet_transactions (
    group_wallet_id, group_id, type, amount,
    reservation_id, description, balance_after, currency_code
  )
  SELECT gw.id, gw.group_id, 'credit_pending', v_earnings,
    p_reservation_id,
    format('Pago confirmado — reserva %s', p_reservation_id),
    CASE WHEN v_currency = 'USD' THEN gw.pending_balance_usd ELSE gw.pending_balance END,
    v_currency
  FROM group_wallets gw WHERE gw.id = v_wallet_id;

  -- Admin: BRUTO contractual (comisión + MSI). Sin fee estimado: el neto
  -- real solo existe cuando el fee esté CAPTURADO en payment_receipts.
  SELECT id INTO v_admin_id FROM profiles WHERE role = 'admin' ORDER BY created_at LIMIT 1;
  IF v_admin_id IS NOT NULL THEN
    INSERT INTO wallets (user_id, available_balance, pending_balance, total_earned)
    VALUES (v_admin_id, 0, 0, 0)
    ON CONFLICT (user_id) DO NOTHING;

    IF v_currency = 'USD' THEN
      UPDATE wallets SET
        available_balance_usd = available_balance_usd + v_admin_bruto,
        total_earned_usd      = COALESCE(total_earned_usd, 0) + v_admin_bruto,
        updated_at            = NOW()
      WHERE user_id = v_admin_id;
    ELSE
      UPDATE wallets SET
        available_balance = available_balance + v_admin_bruto,
        total_earned      = COALESCE(total_earned, 0) + v_admin_bruto,
        updated_at        = NOW()
      WHERE user_id = v_admin_id;
    END IF;

    INSERT INTO wallet_transactions (user_id, type, amount, reservation_id, description, currency_code)
    VALUES (v_admin_id, 'platform_income', v_admin_bruto, p_reservation_id,
      format('Comisión $%s + MSI $%s = $%s bruto — fee procesador: %s — reserva %s',
        v_service_fee::TEXT, v_msi_fee::TEXT, v_admin_bruto::TEXT,
        COALESCE('$' || v_fee_pesos::TEXT, 'No capturado'),
        p_reservation_id),
      v_currency);
  END IF;

  INSERT INTO financial_audit_logs
    (entity_type, entity_id, action, actor_id, actor_role, amount, notes)
  VALUES ('reservation', p_reservation_id, 'hold', NULL, 'system', v_earnings,
    format('v2 currency=%s group=%s svc=%s msi=%s fee=%s pago=%s/%s%s',
      v_currency, v_earnings, v_service_fee, v_msi_fee,
      COALESCE(v_fee_pesos::TEXT, 'not_captured'),
      p_provider, p_provider_payment_id,
      CASE WHEN v_res.status = 'expired' THEN ' [REVIVIDA dentro de ventana]' ELSE '' END));

  INSERT INTO notifications (user_id, type, title, body, data)
  SELECT g.owner_id, 'payment',
    '💰 Pago confirmado — retenido hasta el evento',
    format('El cliente pagó tu evento del %s. $%s %s quedaron reservados y se liberan cuando el grupo llegue y al terminar el evento.',
      v_res.event_date::TEXT, to_char(v_earnings, 'FM999,999,990'), v_currency),
    jsonb_build_object('reservation_id', p_reservation_id, 'amount', v_earnings, 'screen', 'Wallet')
  FROM groups g
  WHERE g.id = v_group_id AND g.owner_id IS NOT NULL;

  -- Cerrar receipt + consumir intento
  UPDATE payment_receipts SET
    result               = 'confirmed',
    money_state          = 'credited',
    processor_fee_minor  = p_fee_minor,
    processor_fee_status = CASE WHEN p_fee_minor IS NULL THEN 'not_captured' ELSE 'captured' END,
    fee_source           = CASE WHEN p_fee_minor IS NULL THEN NULL ELSE p_fee_source END,
    updated_at           = NOW()
  WHERE id = v_receipt_id;

  IF NOT v_is_legacy THEN
    UPDATE payment_attempts SET status = 'consumed', updated_at = NOW()
    WHERE id = v_attempt.id;
  END IF;

  RETURN jsonb_build_object(
    'result',         'confirmed',
    'receipt_id',     v_receipt_id,
    'currency',       v_currency,
    'group_earnings', v_earnings,
    'admin_bruto',    v_admin_bruto,
    'processor_fee',  v_fee_pesos,          -- NULL = "No capturado"
    'revived',        (v_res.status = 'expired')
  );

EXCEPTION
  WHEN lock_not_available THEN
    -- lock_timeout excedido: el bloque EXCEPTION revierte TODO lo del
    -- cuerpo → cero efectos. El webhook responde 500 y el proveedor
    -- reintenta. Un timeout JAMÁS se convierte en reembolso.
    RETURN jsonb_build_object('result', 'temporary_lock_timeout');
END;
$$;

-- ── Seguridad (v4 §8): SOLO service_role ─────────────────────
REVOKE ALL ON FUNCTION public.confirm_reservation_payment_v2(
  TEXT, TEXT, TEXT, UUID, BIGINT, TEXT, TEXT, BIGINT, TEXT, JSONB)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.confirm_reservation_payment_v2(
  TEXT, TEXT, TEXT, UUID, BIGINT, TEXT, TEXT, BIGINT, TEXT, JSONB)
  TO service_role;

COMMIT;

-- ── VERIFICACIÓN (correr después del COMMIT) ─────────────────
SELECT
  (SELECT COUNT(*) FROM pg_tables
   WHERE tablename IN ('payment_attempts','payment_receipts',
                       'refund_intents','payment_config'))       AS tablas_4,
  (SELECT COUNT(*) FROM pg_proc
   WHERE proname IN ('can_schedule','confirm_reservation_payment_v2')) AS funcs_2,
  (SELECT COUNT(*) FROM pg_constraint
   WHERE conname = 'chk_payment_status_v4')                      AS check_v4_1,
  (SELECT COUNT(*) FROM payment_config)                          AS config_seeds_4,
  (SELECT COUNT(*) FROM pg_constraint
   WHERE conname IN ('uq_receipt_payment','uq_refund_intent',
                     'uq_attempt_client_key'))                   AS uniques_3;
-- Esperado: 4 · 2 · 1 · 4 · 3

SELECT '519_f22_payment_gate.sql ejecutado ✅ (RPC creada, AÚN SIN USO: los webhooks siguen en la vía vieja)' AS status;
