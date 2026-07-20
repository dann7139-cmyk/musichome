-- ============================================================
-- sql/521_admin_payment_resolution.sql — F2.2: RESOLUCIÓN ADMIN DE PAGOS
-- (Diseño v5 aprobado 2026-07-19 — ⚠️ EN REVISIÓN: NO PEGAR hasta autorización)
--
-- QUÉ HACE:
--   1. admin_payment_evidence — evidencia INMUTABLE técnica (RLS, REVOKE,
--      trigger defensivo, versionado, hashes) + register_payment_evidence.
--   2. payment_attempts: + group_base_minor / platform_fee_minor (nullable,
--      SIN backfill — snapshot contractual solo para checkouts futuros).
--   3. payment_receipts: + resolution / resolved_* / dismiss_reason_code /
--      canonical_receipt_id / settlement_status (backfill determinista,
--      aborta ante ambigüedad) + CHECK de coherencia.
--   4. refund_intents: + claimed_by / claimed_at / transfer_reference /
--      receipt_path (ciclo claim→done con takeover por timeout).
--   5. markup20_base_minor() + _apply_confirmed_credit() — fórmula y
--      acreditación en UN solo lugar (cero duplicación). SIN grants:
--      inejecutables por API (ni service_role).
--   6. REFACTOR de confirm_reservation_payment_v2 (misma firma):
--      sección F delegada al helper + gate CAD→bloqueo íntegro
--      (currency_unsupported_wallet) + settlement en rama bloqueada.
--      ⚠️ OBLIGATORIO re-correr sql/520 después: debe seguir 21/21.
--   7. resolve_payment_receipt (credit/refund/dismiss) +
--      admin_complete_refund_intent (claim/release/done) +
--      admin_pending_receipts (reporte de conciliación).
--
-- QUÉ NO HACE: no toca checkout ni webhooks; no ejecuta reembolsos externos;
-- no estima fees; no acredita CAD (sin ledger CAD no hay crédito);
-- date_taken sigue activo.
-- ============================================================

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ────────────────────────────────────────────────────────────
-- 1. FÓRMULA markup20 — una sola implementación, todo BIGINT
--    base = round_half_up(net / 1.2) = (net×5 + 3) DIV 6
--    El residuo y el descuento los absorbe SIEMPRE platform_fee (por resta).
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.markup20_base_minor(p_net_minor BIGINT)
RETURNS BIGINT LANGUAGE sql IMMUTABLE AS
$$ SELECT (p_net_minor * 5 + 3) / 6 $$;

REVOKE ALL ON FUNCTION public.markup20_base_minor(BIGINT)
  FROM PUBLIC, anon, authenticated, service_role;

-- ────────────────────────────────────────────────────────────
-- 2. Snapshot contractual en payment_attempts (nullable, SIN backfill)
-- ────────────────────────────────────────────────────────────
ALTER TABLE payment_attempts ADD COLUMN IF NOT EXISTS group_base_minor    BIGINT;
ALTER TABLE payment_attempts ADD COLUMN IF NOT EXISTS platform_fee_minor  BIGINT;

-- ────────────────────────────────────────────────────────────
-- 3. admin_payment_evidence — inmutable TÉCNICAMENTE
-- ────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS admin_payment_evidence (
  id                   UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  provider             TEXT        NOT NULL CHECK (provider IN ('stripe','conekta')),
  provider_payment_id  TEXT        NOT NULL,
  provider_order_id    TEXT,
  reservation_id       UUID        REFERENCES reservations(id) ON DELETE SET NULL,
  captured             BOOLEAN     NOT NULL,      -- ¿el proveedor confirma dinero capturado?
  amount_minor         BIGINT      NOT NULL CHECK (amount_minor >= 0),
  currency             TEXT        NOT NULL,      -- ÚNICA moneda por fila
  discount_minor       BIGINT      NOT NULL DEFAULT 0 CHECK (discount_minor >= 0),
  msi_fee_minor        BIGINT      NOT NULL DEFAULT 0 CHECK (msi_fee_minor >= 0),
  group_base_minor     BIGINT      CHECK (group_base_minor >= 0),
  platform_fee_minor   BIGINT      CHECK (platform_fee_minor >= 0),
  formula_version      TEXT        NOT NULL DEFAULT 'markup20'
    CHECK (formula_version IN ('markup20')),      -- catálogo cerrado: fórmula no editable
  consulted_at         TIMESTAMPTZ NOT NULL,      -- cuándo se consultó al proveedor
  payload              JSONB       NOT NULL,      -- payload normalizado del proveedor
  field_sources        JSONB       NOT NULL,      -- origen exacto de cada campo contractual
  snapshot_sha256      TEXT        NOT NULL,      -- calculado SERVER-SIDE
  evidence_file_path   TEXT,                      -- ruta única evidence/{id}/... (no sobrescribible)
  evidence_file_sha256 TEXT,
  note                 TEXT        NOT NULL,
  version              INT         NOT NULL DEFAULT 1 CHECK (version >= 1),
  supersedes           UUID        REFERENCES admin_payment_evidence(id),
  created_by           UUID        NOT NULL REFERENCES profiles(id),
  created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT uq_evidence_version UNIQUE (provider, provider_payment_id, version),
  -- Invariante: si hubo captura y hay desglose, los componentes SUMAN el total
  CONSTRAINT chk_evidence_composition CHECK (
    NOT captured
    OR group_base_minor IS NULL
    OR (platform_fee_minor IS NOT NULL
        AND group_base_minor + platform_fee_minor + msi_fee_minor = amount_minor)
  ),
  CONSTRAINT chk_evidence_file_hash CHECK (
    evidence_file_path IS NULL OR evidence_file_sha256 IS NOT NULL
  )
);

ALTER TABLE admin_payment_evidence ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS ape_admin_select ON admin_payment_evidence;
CREATE POLICY ape_admin_select ON admin_payment_evidence FOR SELECT USING (
  EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
);
-- SIN políticas de UPDATE/DELETE, y además:
REVOKE UPDATE, DELETE ON admin_payment_evidence
  FROM PUBLIC, anon, authenticated, service_role;

-- Trigger defensivo: inmutable aunque un GRANT accidental futuro lo permita
CREATE OR REPLACE FUNCTION public.evidence_immutable_guard()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'evidence_immutable: admin_payment_evidence no admite % — corrige con una NUEVA versión (supersedes)', TG_OP;
END $$;

DROP TRIGGER IF EXISTS trg_evidence_immutable ON admin_payment_evidence;
CREATE TRIGGER trg_evidence_immutable
  BEFORE UPDATE OR DELETE ON admin_payment_evidence
  FOR EACH ROW EXECUTE FUNCTION public.evidence_immutable_guard();

-- Bucket privado, rutas únicas, SOLO INSERT (sin UPDATE = sin sobrescritura)
INSERT INTO storage.buckets (id, name, public)
VALUES ('payment-evidence', 'payment-evidence', false)
ON CONFLICT (id) DO NOTHING;

DROP POLICY IF EXISTS pe_admin_insert ON storage.objects;
CREATE POLICY pe_admin_insert ON storage.objects FOR INSERT WITH CHECK (
  bucket_id = 'payment-evidence'
  AND EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
);
DROP POLICY IF EXISTS pe_admin_select ON storage.objects;
CREATE POLICY pe_admin_select ON storage.objects FOR SELECT USING (
  bucket_id = 'payment-evidence'
  AND EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
);

-- ────────────────────────────────────────────────────────────
-- 4. register_payment_evidence — el snapshot lo firma el SERVIDOR
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.register_payment_evidence(
  p_provider            TEXT,
  p_provider_payment_id TEXT,
  p_provider_order_id   TEXT,
  p_reservation_id      UUID,
  p_captured            BOOLEAN,
  p_amount_minor        BIGINT,
  p_currency            TEXT,
  p_discount_minor      BIGINT,
  p_msi_fee_minor       BIGINT,
  p_group_base_minor    BIGINT,     -- NULL si no hay desglose verificable
  p_platform_fee_minor  BIGINT,
  p_consulted_at        TIMESTAMPTZ,
  p_payload             JSONB,
  p_field_sources       JSONB,
  p_evidence_file_path  TEXT,
  p_evidence_file_sha256 TEXT,
  p_note                TEXT,
  p_supersedes          UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_version INT;
  v_id      UUID;
  v_net     BIGINT;
  v_hash    TEXT;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;
  IF COALESCE(TRIM(p_note), '') = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'note_required');
  END IF;
  IF p_provider NOT IN ('stripe','conekta')
     OR COALESCE(TRIM(p_provider_payment_id),'') = ''
     OR UPPER(COALESCE(p_currency,'')) NOT IN ('MXN','USD','CAD')
     OR p_amount_minor IS NULL OR p_amount_minor < 0
     OR p_payload IS NULL OR p_field_sources IS NULL
     OR p_consulted_at IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_params');
  END IF;

  -- ANTI-FABRICACIÓN: si hay desglose, DEBE cuadrar con la fórmula del contrato
  IF p_captured AND p_group_base_minor IS NOT NULL THEN
    v_net := p_amount_minor - COALESCE(p_msi_fee_minor,0) + COALESCE(p_discount_minor,0);
    IF p_group_base_minor <> public.markup20_base_minor(v_net) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'composition_not_contractual',
        'expected_base_minor', public.markup20_base_minor(v_net));
    END IF;
    IF p_group_base_minor + COALESCE(p_platform_fee_minor,-1) + COALESCE(p_msi_fee_minor,0)
       <> p_amount_minor THEN
      RETURN jsonb_build_object('ok', false, 'error', 'composition_sum_mismatch');
    END IF;
  END IF;

  SELECT COALESCE(MAX(version),0) + 1 INTO v_version
  FROM admin_payment_evidence
  WHERE provider = p_provider AND provider_payment_id = p_provider_payment_id;

  IF v_version = 1 AND p_supersedes IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'supersedes_invalid',
      'detail', 'No existe evidencia previa que corregir');
  END IF;
  IF v_version > 1 THEN
    IF p_supersedes IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'error', 'supersedes_required',
        'detail', 'Ya existe evidencia previa: la corrección debe referenciarla');
    END IF;
    -- supersedes debe ser la VERSIÓN PREVIA del MISMO pago
    IF NOT EXISTS (
      SELECT 1 FROM admin_payment_evidence e
      WHERE e.id = p_supersedes
        AND e.provider = p_provider
        AND e.provider_payment_id = p_provider_payment_id
        AND e.version = v_version - 1
    ) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'supersedes_invalid',
        'detail', format('supersedes debe ser la versión %s de %s/%s',
          v_version - 1, p_provider, p_provider_payment_id));
    END IF;
  END IF;

  -- Hash del snapshot calculado por el SERVIDOR (el admin no lo provee)
  v_hash := encode(digest(convert_to(
    jsonb_build_object(
      'provider', p_provider, 'payment_id', p_provider_payment_id,
      'order_id', p_provider_order_id, 'reservation_id', p_reservation_id,
      'captured', p_captured, 'amount_minor', p_amount_minor,
      -- valores NORMALIZADOS (los mismos que se almacenan) para que el hash
      -- sea siempre recomputable desde la fila
      'currency', UPPER(p_currency), 'discount_minor', COALESCE(p_discount_minor, 0),
      'msi_fee_minor', COALESCE(p_msi_fee_minor, 0), 'group_base_minor', p_group_base_minor,
      'platform_fee_minor', p_platform_fee_minor,
      'consulted_at', p_consulted_at, 'payload', p_payload,
      'field_sources', p_field_sources
    )::text, 'UTF8'), 'sha256'), 'hex');

  INSERT INTO admin_payment_evidence
    (provider, provider_payment_id, provider_order_id, reservation_id, captured,
     amount_minor, currency, discount_minor, msi_fee_minor,
     group_base_minor, platform_fee_minor, consulted_at, payload, field_sources,
     snapshot_sha256, evidence_file_path, evidence_file_sha256, note,
     version, supersedes, created_by)
  VALUES
    (p_provider, p_provider_payment_id, p_provider_order_id, p_reservation_id, p_captured,
     p_amount_minor, UPPER(p_currency), COALESCE(p_discount_minor,0), COALESCE(p_msi_fee_minor,0),
     p_group_base_minor, p_platform_fee_minor, p_consulted_at, p_payload, p_field_sources,
     v_hash, p_evidence_file_path, p_evidence_file_sha256, p_note,
     v_version, p_supersedes, auth.uid())
  RETURNING id INTO v_id;

  INSERT INTO financial_audit_logs
    (entity_type, entity_id, action, actor_id, actor_role, amount, notes)
  VALUES ('payment_evidence', v_id, 'evidence_registered', auth.uid(), 'admin',
    p_amount_minor / 100.0,
    format('pago=%s/%s v%s captured=%s sha256=%s nota=%s',
      p_provider, p_provider_payment_id, v_version, p_captured, v_hash, p_note));

  RETURN jsonb_build_object('ok', true, 'evidence_id', v_id,
                            'version', v_version, 'snapshot_sha256', v_hash);
END $$;

REVOKE ALL ON FUNCTION public.register_payment_evidence(
  TEXT,TEXT,TEXT,UUID,BOOLEAN,BIGINT,TEXT,BIGINT,BIGINT,BIGINT,BIGINT,
  TIMESTAMPTZ,JSONB,JSONB,TEXT,TEXT,TEXT,UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.register_payment_evidence(
  TEXT,TEXT,TEXT,UUID,BOOLEAN,BIGINT,TEXT,BIGINT,BIGINT,BIGINT,BIGINT,
  TIMESTAMPTZ,JSONB,JSONB,TEXT,TEXT,TEXT,UUID) TO authenticated, service_role;

-- ────────────────────────────────────────────────────────────
-- 5. Columnas nuevas en payment_receipts + BACKFILL determinista
-- ────────────────────────────────────────────────────────────
ALTER TABLE payment_receipts ADD COLUMN IF NOT EXISTS resolution TEXT
  CHECK (resolution IN ('credited_manual','refund_queued','dismissed'));
ALTER TABLE payment_receipts ADD COLUMN IF NOT EXISTS resolved_by UUID;
ALTER TABLE payment_receipts ADD COLUMN IF NOT EXISTS resolved_at TIMESTAMPTZ;
ALTER TABLE payment_receipts ADD COLUMN IF NOT EXISTS resolution_note TEXT;
ALTER TABLE payment_receipts ADD COLUMN IF NOT EXISTS dismiss_reason_code TEXT
  CHECK (dismiss_reason_code IN
    ('test_event','duplicate_of_canonical','provider_no_capture','garbage_no_money'));
ALTER TABLE payment_receipts ADD COLUMN IF NOT EXISTS canonical_receipt_id UUID
  REFERENCES payment_receipts(id);
ALTER TABLE payment_receipts ADD COLUMN IF NOT EXISTS settlement_status TEXT
  NOT NULL DEFAULT 'unsettled';

-- Backfill determinista (aborta ante CUALQUIER combinación ambigua)
DO $$
DECLARE
  v_total     INT;
  v_mapeados  INT;
  v_ambiguos  TEXT;
BEGIN
  SELECT COUNT(*) INTO v_total FROM payment_receipts;

  UPDATE payment_receipts SET settlement_status = 'credited'
  WHERE money_state = 'credited';

  UPDATE payment_receipts pr SET settlement_status = 'refund_completed'
  WHERE pr.money_state = 'blocked_refund_pending'
    AND EXISTS (SELECT 1 FROM refund_intents ri
                WHERE ri.provider = pr.provider
                  AND ri.provider_payment_id = pr.provider_payment_id
                  AND ri.status = 'done');

  UPDATE payment_receipts pr SET settlement_status = 'refund_pending'
  WHERE pr.money_state = 'blocked_refund_pending'
    AND pr.settlement_status = 'unsettled'
    AND EXISTS (SELECT 1 FROM refund_intents ri
                WHERE ri.provider = pr.provider
                  AND ri.provider_payment_id = pr.provider_payment_id
                  AND ri.status IN ('pending','processing'));

  -- money_state='recorded' se queda en 'unsettled' (resolution aún no existe
  -- para filas históricas: la columna nace en esta migración)

  -- Ambigüedades: blocked sin intent utilizable, o intent cancelado huérfano
  SELECT string_agg(pr.id::text, ', ') INTO v_ambiguos
  FROM payment_receipts pr
  WHERE pr.money_state = 'blocked_refund_pending'
    AND pr.settlement_status = 'unsettled';
  IF v_ambiguos IS NOT NULL THEN
    RAISE EXCEPTION 'MIGRACIÓN ABORTADA: receipts bloqueados sin intent mapeable (revisión humana): %', v_ambiguos;
  END IF;

  SELECT COUNT(*) INTO v_mapeados FROM payment_receipts
  WHERE settlement_status IN ('credited','refund_pending','refund_completed','unsettled');
  IF v_mapeados <> v_total THEN
    RAISE EXCEPTION 'MIGRACIÓN ABORTADA: % receipts fuera del mapeo (total %)', v_total - v_mapeados, v_total;
  END IF;

  RAISE NOTICE 'Backfill settlement_status OK: % receipts mapeados', v_total;
END $$;

-- CHECK de coherencia (6 valores = 5 finales + 1 transitorio operativo)
ALTER TABLE payment_receipts DROP CONSTRAINT IF EXISTS chk_receipt_settlement;
ALTER TABLE payment_receipts ADD CONSTRAINT chk_receipt_settlement CHECK (
  (settlement_status = 'credited'          AND money_state = 'credited') OR
  (settlement_status IN ('refund_pending','refund_completed')
                                           AND money_state = 'blocked_refund_pending') OR
  (settlement_status IN ('no_capture_verified','duplicate_linked')
                                           AND money_state = 'recorded'
                                           AND resolution = 'dismissed') OR
  (settlement_status = 'unsettled'         AND money_state = 'recorded')
);

-- ────────────────────────────────────────────────────────────
-- 6. Ciclo claim→done en refund_intents + timeout configurable
-- ────────────────────────────────────────────────────────────
ALTER TABLE refund_intents ADD COLUMN IF NOT EXISTS claimed_by         UUID;
ALTER TABLE refund_intents ADD COLUMN IF NOT EXISTS claimed_at         TIMESTAMPTZ;
ALTER TABLE refund_intents ADD COLUMN IF NOT EXISTS transfer_reference TEXT;
ALTER TABLE refund_intents ADD COLUMN IF NOT EXISTS receipt_path       TEXT;

INSERT INTO payment_config (key, value, description) VALUES
  ('refund_claim_timeout_minutes', '60',
   'Minutos tras los cuales un intent en processing se considera atorado y admite takeover')
ON CONFLICT (key) DO NOTHING;

-- ────────────────────────────────────────────────────────────
-- 7. _apply_confirmed_credit — LA acreditación, en un solo lugar
--    SIN grants (ni service_role): solo invocable internamente por las
--    RPC SECURITY DEFINER del mismo owner. Inejecutable por API.
--    Defensa en profundidad: toma sus propios locks (re-entrantes) y
--    ABORTA con excepción (rollback total) ante cualquier invariante roto.
--    Fuente de montos: EVIDENCIA (manual) > SNAPSHOT del attempt
--    (autoritativo cuando existe) > campos de reserva (SOLO compatibilidad
--    con attempts históricos sin snapshot — jamás sustituye un snapshot).
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public._apply_confirmed_credit(
  p_receipt_id     UUID,
  p_reservation_id UUID,
  p_provider       TEXT,
  p_payment_id     TEXT,
  p_method         TEXT,
  p_fee_minor      BIGINT,
  p_fee_source     TEXT,
  p_attempt_id     UUID,
  p_manual         BOOLEAN DEFAULT FALSE,
  p_actor          UUID    DEFAULT NULL,
  p_evidence_id    UUID    DEFAULT NULL,
  p_note           TEXT    DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_group_id    UUID;
  v_res         RECORD;
  v_receipt     RECORD;
  v_att         RECORD;
  v_ev          RECORD;
  v_currency    TEXT;
  v_earnings    NUMERIC;
  v_service_fee NUMERIC;
  v_msi_fee     NUMERIC;
  v_admin_bruto NUMERIC;
  v_fee_pesos   NUMERIC;
  v_admin_id    UUID;
  v_wallet_id   UUID;
  v_revived     BOOLEAN;
  v_fuente      TEXT;
BEGIN
  -- Orden universal de locks (re-entrante si el llamador ya los tiene)
  SELECT group_id INTO v_group_id FROM reservations WHERE id = p_reservation_id;
  IF v_group_id IS NULL THEN
    RAISE EXCEPTION '_credit_assert: reserva % inexistente', p_reservation_id;
  END IF;
  PERFORM pg_advisory_xact_lock(hashtext(v_group_id::text));

  SELECT * INTO v_res FROM reservations WHERE id = p_reservation_id FOR UPDATE;

  -- ASSERTS financieros (mal uso = excepción = rollback total, jamás parcial)
  IF v_res.status IN ('cancelled','rejected') THEN
    RAISE EXCEPTION '_credit_assert: reserva % terminal (%)', p_reservation_id, v_res.status;
  END IF;
  IF v_res.payment_status IN ('paid','fully_paid') THEN
    RAISE EXCEPTION '_credit_assert: reserva % ya pagada', p_reservation_id;
  END IF;

  SELECT * INTO v_receipt FROM payment_receipts WHERE id = p_receipt_id FOR UPDATE;
  IF NOT FOUND OR v_receipt.money_state <> 'recorded' OR v_receipt.resolution IS NOT NULL THEN
    RAISE EXCEPTION '_credit_assert: receipt % no acreditable (state=%, resolution=%)',
      p_receipt_id, v_receipt.money_state, v_receipt.resolution;
  END IF;
  IF p_manual AND p_evidence_id IS NULL THEN
    RAISE EXCEPTION '_credit_assert: crédito manual sin evidencia';
  END IF;

  v_currency := UPPER(COALESCE(v_res.currency_code, 'MXN'));
  v_revived  := (v_res.status = 'expired');

  -- Fuente de montos (jerarquía; sin ida y vuelta NUMERIC↔centavos)
  IF p_evidence_id IS NOT NULL THEN
    SELECT * INTO v_ev FROM admin_payment_evidence WHERE id = p_evidence_id;
    IF NOT FOUND OR NOT v_ev.captured OR v_ev.group_base_minor IS NULL THEN
      RAISE EXCEPTION '_credit_assert: evidencia % sin composición capturada', p_evidence_id;
    END IF;
    v_earnings    := v_ev.group_base_minor   / 100.0;
    v_service_fee := v_ev.platform_fee_minor / 100.0;
    v_msi_fee     := v_ev.msi_fee_minor      / 100.0;
    v_fuente      := 'evidence:' || p_evidence_id;
  ELSE
    IF p_attempt_id IS NOT NULL THEN
      SELECT * INTO v_att FROM payment_attempts WHERE id = p_attempt_id;
    END IF;
    IF p_attempt_id IS NOT NULL AND FOUND AND v_att.group_base_minor IS NOT NULL THEN
      -- SNAPSHOT contractual del checkout = fuente AUTORITATIVA
      v_earnings    := v_att.group_base_minor   / 100.0;
      v_service_fee := v_att.platform_fee_minor / 100.0;
      v_msi_fee     := v_att.msi_fee_minor      / 100.0;
      v_fuente      := 'attempt_snapshot';
    ELSE
      -- SOLO compatibilidad: attempts históricos sin snapshot (comportamiento
      -- probado en 520). Nunca sustituye un snapshot válido.
      v_earnings    := COALESCE(v_res.base_price, ROUND(v_res.total_price / 1.20, 2));
      v_service_fee := COALESCE(v_res.service_fee_amount,
                         v_res.total_price - ROUND(v_res.total_price / 1.20, 2));
      v_msi_fee     := COALESCE(v_res.msi_fee_amount, 0);
      v_fuente      := 'reservation_compat';
    END IF;
  END IF;

  v_admin_bruto := v_service_fee + v_msi_fee;
  v_fee_pesos   := CASE WHEN p_fee_minor IS NULL THEN NULL ELSE p_fee_minor / 100.0 END;

  PERFORM ensure_group_wallet(v_group_id);
  SELECT id INTO v_wallet_id FROM group_wallets WHERE group_id = v_group_id;

  -- CASE EXPLÍCITO por moneda — el ELSE JAMÁS es "MXN por defecto"
  CASE v_currency
    WHEN 'MXN' THEN
      UPDATE group_wallets SET
        pending_balance = pending_balance + v_earnings,
        total_earned    = total_earned    + v_earnings,
        updated_at      = NOW()
      WHERE id = v_wallet_id;
    WHEN 'USD' THEN
      UPDATE group_wallets SET
        pending_balance_usd = pending_balance_usd + v_earnings,
        total_earned_usd    = total_earned_usd    + v_earnings,
        updated_at          = NOW()
      WHERE id = v_wallet_id;
    ELSE
      -- CAD u otra: SIN ledger autorizado → prohibido acreditar (los
      -- llamadores deben haberlo bloqueado antes; esto es la última barrera)
      RAISE EXCEPTION '_credit_assert: moneda % sin wallet autorizada — crédito prohibido', v_currency;
  END CASE;

  UPDATE reservations SET
    status              = CASE WHEN status IN ('pending','pending_payment',
                                               'pending_group_confirmation',
                                               'accepted','expired')
                               THEN 'confirmed' ELSE status END,
    payment_status      = 'paid',
    payout_status       = 'held',
    held_at             = NOW(),
    mp_payment_id       = p_payment_id,
    payment_provider    = p_provider,
    payment_method_type = COALESCE(p_method, payment_method_type),
    stripe_fee_amount   = COALESCE(v_fee_pesos, stripe_fee_amount),  -- real o intacto; NUNCA estimado
    service_fee_amount  = v_service_fee,
    group_earnings      = v_earnings,
    updated_at          = NOW()
  WHERE id = p_reservation_id;
  -- Triggers F1 + exclusión + date_taken legado = última barrera de agenda.

  INSERT INTO wallet_transactions (
    group_wallet_id, group_id, type, amount,
    reservation_id, description, balance_after, currency_code
  )
  SELECT gw.id, gw.group_id, 'credit_pending', v_earnings,
    p_reservation_id,
    format('Pago confirmado — reserva %s', p_reservation_id),
    CASE v_currency WHEN 'USD' THEN gw.pending_balance_usd ELSE gw.pending_balance END,
    v_currency
  FROM group_wallets gw WHERE gw.id = v_wallet_id;

  -- Admin: BRUTO contractual (comisión + MSI); fee jamás estimado
  SELECT id INTO v_admin_id FROM profiles WHERE role = 'admin' ORDER BY created_at LIMIT 1;
  IF v_admin_id IS NOT NULL THEN
    INSERT INTO wallets (user_id, available_balance, pending_balance, total_earned)
    VALUES (v_admin_id, 0, 0, 0)
    ON CONFLICT (user_id) DO NOTHING;

    CASE v_currency
      WHEN 'MXN' THEN
        UPDATE wallets SET
          available_balance = available_balance + v_admin_bruto,
          total_earned      = COALESCE(total_earned, 0) + v_admin_bruto,
          updated_at        = NOW()
        WHERE user_id = v_admin_id;
      WHEN 'USD' THEN
        UPDATE wallets SET
          available_balance_usd = available_balance_usd + v_admin_bruto,
          total_earned_usd      = COALESCE(total_earned_usd, 0) + v_admin_bruto,
          updated_at            = NOW()
        WHERE user_id = v_admin_id;
      ELSE
        RAISE EXCEPTION '_credit_assert: moneda % sin wallet admin autorizada', v_currency;
    END CASE;

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
  VALUES ('reservation', p_reservation_id, 'hold',
    p_actor, CASE WHEN p_manual THEN 'admin' ELSE 'system' END, v_earnings,
    format('%s currency=%s group=%s svc=%s msi=%s fee=%s fuente=%s pago=%s/%s%s%s',
      CASE WHEN p_manual THEN 'manual_credit' ELSE 'v2' END,
      v_currency, v_earnings, v_service_fee, v_msi_fee,
      COALESCE(v_fee_pesos::TEXT, 'not_captured'), v_fuente,
      p_provider, p_payment_id,
      CASE WHEN v_revived THEN ' [REVIVIDA]' ELSE '' END,
      CASE WHEN p_note IS NOT NULL THEN ' nota=' || p_note ELSE '' END));

  -- Señal de conflicto (auditable): la reserva viva difiere del snapshot usado
  IF v_fuente <> 'reservation_compat'
     AND v_res.base_price IS NOT NULL
     AND ROUND(v_res.base_price * 100)::BIGINT <> ROUND(v_earnings * 100)::BIGINT THEN
    INSERT INTO financial_audit_logs
      (entity_type, entity_id, action, actor_id, actor_role, amount, notes)
    VALUES ('reservation', p_reservation_id, 'snapshot_reservation_drift',
      p_actor, CASE WHEN p_manual THEN 'admin' ELSE 'system' END, v_earnings,
      format('reserva_viva base=%s vs snapshot base=%s — el snapshot MANDA',
        v_res.base_price, v_earnings));
  END IF;

  INSERT INTO notifications (user_id, type, title, body, data)
  SELECT g.owner_id, 'payment',
    '💰 Pago confirmado — retenido hasta el evento',
    format('El cliente pagó tu evento del %s. $%s %s quedaron reservados y se liberan cuando el grupo llegue y al terminar el evento.',
      v_res.event_date::TEXT, to_char(v_earnings, 'FM999,999,990'), v_currency),
    jsonb_build_object('reservation_id', p_reservation_id, 'amount', v_earnings, 'screen', 'Wallet')
  FROM groups g
  WHERE g.id = v_group_id AND g.owner_id IS NOT NULL;

  UPDATE payment_receipts SET
    result               = CASE WHEN p_manual THEN result ELSE 'confirmed' END,
    money_state          = 'credited',
    settlement_status    = 'credited',
    reservation_id       = p_reservation_id,   -- vínculo definitivo (conflictos re-vinculados)
    processor_fee_minor  = p_fee_minor,
    processor_fee_status = CASE WHEN p_fee_minor IS NULL THEN 'not_captured' ELSE 'captured' END,
    fee_source           = CASE WHEN p_fee_minor IS NULL THEN NULL ELSE p_fee_source END,
    resolution           = CASE WHEN p_manual THEN 'credited_manual' ELSE resolution END,
    resolved_by          = CASE WHEN p_manual THEN p_actor ELSE resolved_by END,
    resolved_at          = CASE WHEN p_manual THEN NOW() ELSE resolved_at END,
    resolution_note      = CASE WHEN p_manual THEN p_note ELSE resolution_note END,
    updated_at           = NOW()
  WHERE id = p_receipt_id;

  IF p_attempt_id IS NOT NULL THEN
    UPDATE payment_attempts SET status = 'consumed', updated_at = NOW()
    WHERE id = p_attempt_id;
  END IF;

  RETURN jsonb_build_object(
    'currency', v_currency, 'group_earnings', v_earnings,
    'admin_bruto', v_admin_bruto, 'processor_fee', v_fee_pesos,
    'fuente', v_fuente, 'revived', v_revived
  );
END $$;

-- INEJECUTABLE por API: cero grants (ni service_role)
REVOKE ALL ON FUNCTION public._apply_confirmed_credit(
  UUID,UUID,TEXT,TEXT,TEXT,BIGINT,TEXT,UUID,BOOLEAN,UUID,UUID,TEXT)
  FROM PUBLIC, anon, authenticated, service_role;

-- ────────────────────────────────────────────────────────────
-- 8. REFACTOR confirm_reservation_payment_v2 (misma firma)
--    Cambios EXACTOS vs sql/519: (a) cascada D inicia con gate CAD →
--    currency_unsupported_wallet (bloqueo íntegro); (b) rama bloqueada
--    marca settlement_status='refund_pending'; (c) sección F delegada a
--    _apply_confirmed_credit(). TODO lo demás idéntico.
--    ⚠️ Tras aplicar: re-correr sql/520 → DEBE seguir 21/21.
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.confirm_reservation_payment_v2(
  p_provider            TEXT,
  p_provider_order_id   TEXT,
  p_provider_payment_id TEXT,
  p_reservation_id      UUID,
  p_amount_minor        BIGINT,
  p_currency            TEXT,
  p_method              TEXT    DEFAULT NULL,
  p_fee_minor           BIGINT  DEFAULT NULL,
  p_fee_source          TEXT    DEFAULT NULL,
  p_legacy_expected     JSONB   DEFAULT NULL
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
  v_block_paysts   BOOLEAN := TRUE;
  v_window_h       INT;
  v_method_key     TEXT;
  v_range          TSTZRANGE;
  v_sched          TEXT;
  v_apply          JSONB;
BEGIN
  PERFORM set_config('lock_timeout', '5000', TRUE);

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

  PERFORM pg_advisory_xact_lock(hashtext(v_group_id::text));

  SELECT * INTO v_res FROM reservations WHERE id = p_reservation_id FOR UPDATE;

  IF v_res.group_id IS DISTINCT FROM v_group_id THEN
    RETURN jsonb_build_object('result', 'temporary_retry');
  END IF;

  -- ── C. Idempotencia: reclamar el pago ────────────────────────────
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

  -- ── D. Cascada de decisión ───────────────────────────────────────
  v_result := NULL;
  v_reason := NULL;

  -- D0. [521] Moneda sin wallet autorizada: CAD se bloquea ÍNTEGRO.
  --     Prohibido el ELSE-como-MXN: sin ledger CAD no hay crédito.
  IF v_currency = 'CAD' THEN
    v_result := 'currency_unsupported_wallet';
    v_reason := 'moneda CAD sin wallet/ledger autorizado — bloqueo íntegro y reembolso';

  -- D1. Moneda vs esperada
  ELSIF v_currency <> v_expected_cur THEN
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
    v_block_paysts := FALSE;

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
    END IF;

    UPDATE payment_receipts SET
      result              = v_result,
      money_state         = 'blocked_refund_pending',
      settlement_status   = 'refund_pending',                       -- [521]
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
        CASE WHEN v_result IN ('amount_mismatch','overpayment_refund_pending',
                               'currency_mismatch','currency_unsupported_wallet')
             THEN 'el importe o la moneda no coincidieron con tu orden'
             ELSE 'la reserva ya no estaba disponible' END),
      jsonb_build_object('screen', 'Reservations', 'reservation_id', p_reservation_id));

    RETURN jsonb_build_object('result', v_result, 'receipt_id', v_receipt_id,
                              'reason', v_reason);
  END IF;

  -- ── F. CONFIRMAR + ACREDITAR — delegado al helper compartido [521] ─
  v_apply := public._apply_confirmed_credit(
    v_receipt_id, p_reservation_id, p_provider, p_provider_payment_id,
    COALESCE(p_method, v_method_key), p_fee_minor, p_fee_source,
    CASE WHEN v_is_legacy THEN NULL ELSE v_attempt.id END,
    FALSE, NULL, NULL, NULL);

  RETURN jsonb_build_object('result', 'confirmed', 'receipt_id', v_receipt_id)
         || v_apply;

EXCEPTION
  WHEN lock_not_available THEN
    RETURN jsonb_build_object('result', 'temporary_lock_timeout');
END;
$$;

REVOKE ALL ON FUNCTION public.confirm_reservation_payment_v2(
  TEXT, TEXT, TEXT, UUID, BIGINT, TEXT, TEXT, BIGINT, TEXT, JSONB)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.confirm_reservation_payment_v2(
  TEXT, TEXT, TEXT, UUID, BIGINT, TEXT, TEXT, BIGINT, TEXT, JSONB)
  TO service_role;

-- ────────────────────────────────────────────────────────────
-- 9. resolve_payment_receipt — credit / refund / dismiss
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.resolve_payment_receipt(
  p_receipt_id          UUID,
  p_action              TEXT,               -- 'credit' | 'refund' | 'dismiss'
  p_note                TEXT,
  p_confirm             TEXT,               -- payment_id EXACTO (todas las acciones)
  p_reservation_id      UUID    DEFAULT NULL,   -- credit: obligatorio
  p_reservation_confirm UUID    DEFAULT NULL,   -- credit: doble confirmación
  p_amount_confirm      BIGINT  DEFAULT NULL,   -- credit
  p_currency_confirm    TEXT    DEFAULT NULL,   -- credit
  p_dismiss_reason      TEXT    DEFAULT NULL,
  p_canonical_receipt_id UUID   DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_r        RECORD;
  v_ev       RECORD;
  v_res      RECORD;
  v_group_id UUID;
  v_range    TSTZRANGE;
  v_sched    TEXT;
  v_apply    JSONB;
  v_canon    RECORD;
BEGIN
  PERFORM set_config('lock_timeout', '5000', TRUE);

  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin') THEN
    RETURN jsonb_build_object('ok', false, 'result', 'not_admin');
  END IF;
  IF p_action NOT IN ('credit','refund','dismiss') THEN
    RETURN jsonb_build_object('ok', false, 'result', 'invalid_action');
  END IF;
  IF COALESCE(TRIM(p_note), '') = '' THEN
    RETURN jsonb_build_object('ok', false, 'result', 'note_required');
  END IF;

  SELECT * INTO v_r FROM payment_receipts WHERE id = p_receipt_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'result', 'receipt_not_found');
  END IF;

  -- Doble confirmación nivel 1: payment_id exacto (todas las acciones)
  IF p_confirm IS DISTINCT FROM v_r.provider_payment_id THEN
    RETURN jsonb_build_object('ok', false, 'result', 'confirm_mismatch');
  END IF;

  IF v_r.money_state <> 'recorded'
     OR v_r.result NOT IN ('capture_missing','payment_identity_conflict') THEN
    RETURN jsonb_build_object('ok', false, 'result', 'not_resolvable_state',
      'money_state', v_r.money_state, 'receipt_result', v_r.result);
  END IF;

  -- ══ CREDIT ═══════════════════════════════════════════════════════
  IF p_action = 'credit' THEN
    -- Evidencia vigente OBLIGATORIA (versión más alta)
    SELECT * INTO v_ev FROM admin_payment_evidence
    WHERE provider = v_r.provider AND provider_payment_id = v_r.provider_payment_id
    ORDER BY version DESC LIMIT 1;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('ok', false, 'result', 'evidence_required');
    END IF;
    IF NOT v_ev.captured OR v_ev.group_base_minor IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'result', 'evidence_required',
        'detail', 'evidencia sin captura confirmada o sin desglose contractual verificable — solo refund/dismiss');
    END IF;

    -- Reserva explícita + doble confirmación cuádruple
    IF p_reservation_id IS NULL
       OR v_ev.reservation_id IS DISTINCT FROM p_reservation_id
       OR p_reservation_confirm IS DISTINCT FROM p_reservation_id THEN
      RETURN jsonb_build_object('ok', false, 'result', 'confirm_mismatch',
        'detail', 'reservation_id explícito debe igualar la evidencia y su confirmación');
    END IF;
    IF p_amount_confirm IS DISTINCT FROM v_r.amount_minor
       OR UPPER(COALESCE(p_currency_confirm,'')) IS DISTINCT FROM v_r.currency THEN
      RETURN jsonb_build_object('ok', false, 'result', 'confirm_mismatch',
        'detail', 'monto/moneda confirmados no coinciden con el receipt');
    END IF;

    -- La verdad del dinero: receipt == evidencia, tolerancia CERO
    IF v_r.amount_minor <> v_ev.amount_minor OR v_r.currency <> v_ev.currency THEN
      RETURN jsonb_build_object('ok', false, 'result', 'amount_mismatch_manual',
        'receipt_minor', v_r.amount_minor, 'evidence_minor', v_ev.amount_minor);
    END IF;
    IF v_r.currency = 'CAD' THEN
      RETURN jsonb_build_object('ok', false, 'result', 'currency_unsupported_wallet');
    END IF;

    -- Este payment_id no puede estar acreditado en NINGUNA otra reserva
    IF EXISTS (SELECT 1 FROM reservations r2
               WHERE r2.mp_payment_id = v_r.provider_payment_id
                 AND r2.payment_status IN ('paid','fully_paid')
                 AND r2.id <> p_reservation_id) THEN
      INSERT INTO financial_audit_logs
        (entity_type, entity_id, action, actor_id, actor_role, amount, notes)
      VALUES ('payment', p_reservation_id, 'already_credited_elsewhere',
        auth.uid(), 'admin', v_r.amount_minor / 100.0,
        format('SEVERIDAD ALTA: intento de crédito manual de %s/%s pero ya está acreditado en otra reserva.',
          v_r.provider, v_r.provider_payment_id));
      RETURN jsonb_build_object('ok', false, 'result', 'already_credited_elsewhere');
    END IF;

    -- Locks en orden universal + validaciones de reserva
    SELECT group_id INTO v_group_id FROM reservations WHERE id = p_reservation_id;
    IF v_group_id IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'result', 'reservation_missing');
    END IF;
    PERFORM pg_advisory_xact_lock(hashtext(v_group_id::text));
    SELECT * INTO v_res FROM reservations WHERE id = p_reservation_id FOR UPDATE;
    IF v_res.status IN ('cancelled','rejected') THEN
      RETURN jsonb_build_object('ok', false, 'result', 'reservation_terminal');
    END IF;
    IF v_res.payment_status IN ('paid','fully_paid') THEN
      RETURN jsonb_build_object('ok', false, 'result', 'reservation_already_paid');
    END IF;

    -- Receipt bajo lock: ¿alguien lo resolvió mientras tanto?
    SELECT * INTO v_r FROM payment_receipts WHERE id = p_receipt_id FOR UPDATE;
    IF v_r.resolution IS NOT NULL OR v_r.money_state <> 'recorded' THEN
      RETURN jsonb_build_object('ok', false, 'result', 'already_resolved',
        'resolution', v_r.resolution, 'settlement', v_r.settlement_status);
    END IF;

    -- Disponibilidad completa (misma función compartida del gate)
    v_range := COALESCE(v_res.busy_range,
      public.make_busy_range(v_res.event_date, v_res.event_time,
        COALESCE(v_res.event_tz, 'America/Mexico_City'),
        v_res.hours_count,
        COALESCE((SELECT SUM(eh.hours_added) FROM extra_hours eh
                  WHERE eh.reservation_id = v_res.id), 0)::INT));
    v_sched := public.can_schedule(v_group_id, v_res.event_date, v_range, v_res.id);
    IF v_sched IS NOT NULL THEN
      RETURN jsonb_build_object('ok', false, 'result', 'availability_lost',
        'reason', v_sched);
    END IF;

    v_apply := public._apply_confirmed_credit(
      p_receipt_id, p_reservation_id, v_r.provider, v_r.provider_payment_id,
      v_r.method, v_r.processor_fee_minor, v_r.fee_source,
      NULL, TRUE, auth.uid(), v_ev.id, p_note);

    INSERT INTO financial_audit_logs
      (entity_type, entity_id, action, actor_id, actor_role, amount, notes)
    VALUES ('payment', p_reservation_id, 'manual_credit', auth.uid(), 'admin',
      v_r.amount_minor / 100.0,
      format('Crédito manual %s/%s → reserva %s con evidencia %s (v%s, sha=%s). Vínculo previo del receipt: %s. Nota: %s',
        v_r.provider, v_r.provider_payment_id, p_reservation_id,
        v_ev.id, v_ev.version, v_ev.snapshot_sha256,
        COALESCE(v_r.reservation_id::text, 'NULL'), p_note));

    RETURN jsonb_build_object('ok', true, 'result', 'credited') || v_apply;
  END IF;

  -- ══ REFUND ═══════════════════════════════════════════════════════
  IF p_action = 'refund' THEN
    SELECT * INTO v_r FROM payment_receipts WHERE id = p_receipt_id FOR UPDATE;
    IF v_r.resolution IS NOT NULL OR v_r.money_state <> 'recorded' THEN
      RETURN jsonb_build_object('ok', false, 'result', 'already_resolved',
        'resolution', v_r.resolution);
    END IF;

    INSERT INTO refund_intents
      (provider, provider_payment_id, receipt_id, reservation_id, client_id,
       amount_minor, currency, refund_type, reason)
    VALUES
      (v_r.provider, v_r.provider_payment_id, v_r.id, v_r.reservation_id,
       (SELECT client_id FROM reservations WHERE id = v_r.reservation_id),
       v_r.amount_minor, v_r.currency, 'full', 'manual_resolution')
    ON CONFLICT (provider, provider_payment_id) DO NOTHING;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('ok', false, 'result', 'already_refund_queued');
    END IF;

    UPDATE payment_receipts SET
      money_state       = 'blocked_refund_pending',
      settlement_status = 'refund_pending',
      resolution        = 'refund_queued',
      resolved_by       = auth.uid(),
      resolved_at       = NOW(),
      resolution_note   = p_note,
      updated_at        = NOW()
    WHERE id = p_receipt_id;

    INSERT INTO financial_audit_logs
      (entity_type, entity_id, action, actor_id, actor_role, amount, notes)
    VALUES ('payment', v_r.reservation_id, 'manual_refund_queued', auth.uid(), 'admin',
      v_r.amount_minor / 100.0,
      format('Reembolso manual en cola: %s/%s. Nota: %s',
        v_r.provider, v_r.provider_payment_id, p_note));

    RETURN jsonb_build_object('ok', true, 'result', 'refund_queued');
  END IF;

  -- ══ DISMISS (estrictamente restringido) ══════════════════════════
  IF p_dismiss_reason NOT IN
     ('test_event','duplicate_of_canonical','provider_no_capture','garbage_no_money') THEN
    RETURN jsonb_build_object('ok', false, 'result', 'invalid_action',
      'detail', 'dismiss_reason_code inválido');
  END IF;

  -- Evidencia vigente obligatoria para TODO dismiss
  SELECT * INTO v_ev FROM admin_payment_evidence
  WHERE provider = v_r.provider AND provider_payment_id = v_r.provider_payment_id
  ORDER BY version DESC LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'result', 'evidence_required');
  END IF;

  IF p_dismiss_reason = 'duplicate_of_canonical' THEN
    IF p_canonical_receipt_id IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'result', 'invalid_action',
        'detail', 'canonical_receipt_id obligatorio para duplicados');
    END IF;
    SELECT * INTO v_canon FROM payment_receipts WHERE id = p_canonical_receipt_id;
    IF NOT FOUND OR v_canon.settlement_status NOT IN ('credited','refund_completed') THEN
      RETURN jsonb_build_object('ok', false, 'result', 'invalid_action',
        'detail', 'el receipt canónico debe existir y estar conciliado (credited/refund_completed)');
    END IF;
  ELSE
    -- Dinero capturado real NO se puede desestimar
    IF v_ev.captured THEN
      RETURN jsonb_build_object('ok', false, 'result', 'captured_money_cannot_be_dismissed');
    END IF;
  END IF;

  SELECT * INTO v_r FROM payment_receipts WHERE id = p_receipt_id FOR UPDATE;
  IF v_r.resolution IS NOT NULL OR v_r.money_state <> 'recorded' THEN
    RETURN jsonb_build_object('ok', false, 'result', 'already_resolved',
      'resolution', v_r.resolution);
  END IF;

  UPDATE payment_receipts SET
    resolution           = 'dismissed',
    dismiss_reason_code  = p_dismiss_reason,
    canonical_receipt_id = p_canonical_receipt_id,
    settlement_status    = CASE WHEN p_dismiss_reason = 'duplicate_of_canonical'
                                THEN 'duplicate_linked' ELSE 'no_capture_verified' END,
    resolved_by          = auth.uid(),
    resolved_at          = NOW(),
    resolution_note      = p_note,
    updated_at           = NOW()
  WHERE id = p_receipt_id;

  INSERT INTO financial_audit_logs
    (entity_type, entity_id, action, actor_id, actor_role, amount, notes)
  VALUES ('payment', v_r.reservation_id, 'receipt_dismissed', auth.uid(), 'admin',
    v_r.amount_minor / 100.0,
    format('Dismiss %s/%s motivo=%s canonico=%s evidencia=%s(v%s). Nota: %s',
      v_r.provider, v_r.provider_payment_id, p_dismiss_reason,
      COALESCE(p_canonical_receipt_id::text,'—'), v_ev.id, v_ev.version, p_note));

  RETURN jsonb_build_object('ok', true, 'result', 'dismissed',
    'settlement', CASE WHEN p_dismiss_reason = 'duplicate_of_canonical'
                       THEN 'duplicate_linked' ELSE 'no_capture_verified' END);

EXCEPTION
  WHEN lock_not_available THEN
    RETURN jsonb_build_object('ok', false, 'result', 'lock_timeout_retry');
END;
$$;

REVOKE ALL ON FUNCTION public.resolve_payment_receipt(
  UUID,TEXT,TEXT,TEXT,UUID,UUID,BIGINT,TEXT,TEXT,UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.resolve_payment_receipt(
  UUID,TEXT,TEXT,TEXT,UUID,UUID,BIGINT,TEXT,TEXT,UUID) TO authenticated, service_role;

-- ────────────────────────────────────────────────────────────
-- 10. admin_complete_refund_intent — claim / release / done
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_complete_refund_intent(
  p_intent_id          UUID,
  p_action             TEXT,           -- 'claim' | 'release' | 'done'
  p_transfer_reference TEXT DEFAULT NULL,
  p_receipt_path       TEXT DEFAULT NULL,
  p_note               TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_i        RECORD;
  v_timeout  INT;
  v_stale    BOOLEAN;
BEGIN
  PERFORM set_config('lock_timeout', '5000', TRUE);

  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin') THEN
    RETURN jsonb_build_object('ok', false, 'result', 'not_admin');
  END IF;
  IF p_action NOT IN ('claim','release','done') THEN
    RETURN jsonb_build_object('ok', false, 'result', 'invalid_action');
  END IF;

  SELECT * INTO v_i FROM refund_intents WHERE id = p_intent_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'result', 'intent_not_found');
  END IF;
  IF v_i.status = 'done' THEN
    RETURN jsonb_build_object('ok', true, 'result', 'already_sent',
      'transfer_reference', v_i.transfer_reference);
  END IF;
  IF v_i.status = 'cancelled' THEN
    RETURN jsonb_build_object('ok', false, 'result', 'not_resolvable_state');
  END IF;

  v_timeout := COALESCE((SELECT value::INT FROM payment_config
                         WHERE key='refund_claim_timeout_minutes'), 60);
  v_stale := (v_i.status = 'processing'
              AND v_i.claimed_at < NOW() - make_interval(mins => v_timeout));

  IF p_action = 'claim' THEN
    IF v_i.status = 'processing' AND NOT v_stale
       AND v_i.claimed_by IS DISTINCT FROM auth.uid() THEN
      RETURN jsonb_build_object('ok', false, 'result', 'claimed_by_other',
        'claimed_by', v_i.claimed_by, 'claimed_at', v_i.claimed_at);
    END IF;
    UPDATE refund_intents SET
      status = 'processing', claimed_by = auth.uid(), claimed_at = NOW()
    WHERE id = p_intent_id;
    INSERT INTO financial_audit_logs
      (entity_type, entity_id, action, actor_id, actor_role, amount, notes)
    VALUES ('refund_intent', p_intent_id,
      CASE WHEN v_stale THEN 'refund_claim_takeover' ELSE 'refund_claimed' END,
      auth.uid(), 'admin', v_i.amount_minor / 100.0,
      format('pago=%s/%s%s', v_i.provider, v_i.provider_payment_id,
        CASE WHEN v_stale
             THEN format(' — TAKEOVER: reclamante anterior %s desde %s', v_i.claimed_by, v_i.claimed_at)
             ELSE '' END));
    RETURN jsonb_build_object('ok', true, 'result', 'intent_processing',
      'takeover', v_stale);
  END IF;

  IF p_action = 'release' THEN
    IF v_i.status <> 'processing' THEN
      RETURN jsonb_build_object('ok', false, 'result', 'not_resolvable_state');
    END IF;
    IF v_i.claimed_by IS DISTINCT FROM auth.uid() AND NOT v_stale THEN
      RETURN jsonb_build_object('ok', false, 'result', 'claimed_by_other');
    END IF;
    UPDATE refund_intents SET
      status = 'pending', claimed_by = NULL, claimed_at = NULL
    WHERE id = p_intent_id;
    INSERT INTO financial_audit_logs
      (entity_type, entity_id, action, actor_id, actor_role, amount, notes)
    VALUES ('refund_intent', p_intent_id, 'refund_released', auth.uid(), 'admin',
      v_i.amount_minor / 100.0,
      format('pago=%s/%s nota=%s', v_i.provider, v_i.provider_payment_id, COALESCE(p_note,'—')));
    RETURN jsonb_build_object('ok', true, 'result', 'intent_released');
  END IF;

  -- done
  IF v_i.status <> 'processing' THEN
    RETURN jsonb_build_object('ok', false, 'result', 'not_resolvable_state',
      'detail', 'debe reclamarse (claim) antes de marcar done');
  END IF;
  IF v_i.claimed_by IS DISTINCT FROM auth.uid() AND NOT v_stale THEN
    RETURN jsonb_build_object('ok', false, 'result', 'claimed_by_other');
  END IF;
  IF COALESCE(TRIM(p_transfer_reference), '') = '' THEN
    RETURN jsonb_build_object('ok', false, 'result', 'reference_required');
  END IF;

  UPDATE refund_intents SET
    status = 'done',
    transfer_reference = p_transfer_reference,
    receipt_path       = COALESCE(p_receipt_path, receipt_path),
    processed_by       = auth.uid(),
    processed_at       = NOW()
  WHERE id = p_intent_id;

  UPDATE payment_receipts SET
    settlement_status = 'refund_completed', updated_at = NOW()
  WHERE id = v_i.receipt_id;

  INSERT INTO financial_audit_logs
    (entity_type, entity_id, action, actor_id, actor_role, amount, notes)
  VALUES ('refund_intent', p_intent_id, 'refund_completed', auth.uid(), 'admin',
    v_i.amount_minor / 100.0,
    format('pago=%s/%s ref=%s comprobante=%s',
      v_i.provider, v_i.provider_payment_id, p_transfer_reference,
      COALESCE(p_receipt_path,'—')));

  IF v_i.client_id IS NOT NULL THEN
    INSERT INTO notifications (user_id, type, title, body, data)
    VALUES (v_i.client_id, 'payment', '✅ Tu reembolso fue enviado',
      format('Enviamos tu reembolso de $%s %s por transferencia. Referencia: %s.',
        to_char(v_i.amount_minor / 100.0, 'FM999,999,990.00'), v_i.currency,
        p_transfer_reference),
      jsonb_build_object('screen', 'Reservations',
                         'reservation_id', v_i.reservation_id,
                         'refund_intent_id', p_intent_id));
  END IF;

  RETURN jsonb_build_object('ok', true, 'result', 'intent_sent');

EXCEPTION
  WHEN lock_not_available THEN
    RETURN jsonb_build_object('ok', false, 'result', 'lock_timeout_retry');
END;
$$;

REVOKE ALL ON FUNCTION public.admin_complete_refund_intent(UUID,TEXT,TEXT,TEXT,TEXT)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_complete_refund_intent(UUID,TEXT,TEXT,TEXT,TEXT)
  TO authenticated, service_role;

-- ────────────────────────────────────────────────────────────
-- 11. admin_pending_receipts — reporte de conciliación
--     Todo receipt sin estado final (unsettled / refund_pending) es
--     partida abierta y aparece SIEMPRE, resuelto o no del lado UI.
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_pending_receipts()
RETURNS TABLE (
  receipt_id          UUID,
  provider            TEXT,
  provider_payment_id TEXT,
  provider_order_id   TEXT,
  amount_minor        BIGINT,
  currency            TEXT,
  receipt_result      TEXT,
  money_state         TEXT,
  settlement_status   TEXT,
  resolution          TEXT,
  reservation_id      UUID,
  folio               TEXT,
  client_name         TEXT,
  has_evidence        BOOLEAN,
  intent_id           UUID,
  intent_status       TEXT,
  intent_claimed_by   UUID,
  created_at          TIMESTAMPTZ
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE profiles.id = auth.uid() AND role = 'admin') THEN
    RAISE EXCEPTION 'Solo administradores';
  END IF;
  RETURN QUERY
  SELECT pr.id, pr.provider, pr.provider_payment_id, pr.provider_order_id,
         pr.amount_minor, pr.currency, pr.result, pr.money_state,
         pr.settlement_status, pr.resolution,
         pr.reservation_id, r.folio, p.full_name,
         EXISTS (SELECT 1 FROM admin_payment_evidence e
                 WHERE e.provider = pr.provider
                   AND e.provider_payment_id = pr.provider_payment_id),
         ri.id, ri.status, ri.claimed_by,
         pr.created_at
  FROM payment_receipts pr
  LEFT JOIN reservations r   ON r.id = pr.reservation_id
  LEFT JOIN profiles p       ON p.id = r.client_id
  LEFT JOIN refund_intents ri ON ri.provider = pr.provider
                             AND ri.provider_payment_id = pr.provider_payment_id
  WHERE pr.settlement_status IN ('unsettled','refund_pending')
  ORDER BY pr.created_at;
END $$;

REVOKE ALL ON FUNCTION public.admin_pending_receipts() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_pending_receipts() TO authenticated, service_role;

COMMIT;

-- ── VERIFICACIÓN (correr después del COMMIT) ─────────────────
SELECT
  (SELECT COUNT(*) FROM pg_tables WHERE tablename = 'admin_payment_evidence')       AS tabla_evidencia_1,
  (SELECT COUNT(*) FROM pg_proc WHERE proname IN
    ('markup20_base_minor','_apply_confirmed_credit','register_payment_evidence',
     'resolve_payment_receipt','admin_complete_refund_intent','admin_pending_receipts')) AS funcs_6,
  (SELECT COUNT(*) FROM pg_trigger WHERE tgname = 'trg_evidence_immutable')          AS trigger_inmutable_1,
  (SELECT COUNT(*) FROM information_schema.columns
   WHERE table_name='payment_receipts'
     AND column_name IN ('resolution','settlement_status','dismiss_reason_code',
                         'canonical_receipt_id'))                                    AS cols_receipts_4,
  (SELECT COUNT(*) FROM information_schema.columns
   WHERE table_name='payment_attempts'
     AND column_name IN ('group_base_minor','platform_fee_minor'))                   AS cols_attempts_2,
  (SELECT COUNT(*) FROM information_schema.columns
   WHERE table_name='refund_intents'
     AND column_name IN ('claimed_by','claimed_at','transfer_reference','receipt_path')) AS cols_intents_4,
  (SELECT COUNT(*) FROM payment_config WHERE key='refund_claim_timeout_minutes')     AS config_timeout_1,
  (SELECT public.markup20_base_minor(10001))                                         AS base_10001_es_8334,
  (SELECT public.markup20_base_minor(10003))                                         AS base_10003_es_8336;
-- Esperado: 1 · 6 · 1 · 4 · 2 · 4 · 1 · 8334 · 8336

SELECT '521_admin_payment_resolution.sql ejecutado ✅ — OBLIGATORIO: re-correr sql/520 (debe dar 21/21)' AS status;
