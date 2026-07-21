-- ============================================================
-- sql/521b_fix_pgcrypto_search_path.sql — PARCHE de sql/521
--
-- Causa: pgcrypto en Supabase casi siempre vive en el esquema
-- "extensions", no en "public". register_payment_evidence() tenía
-- SET search_path = public → digest() no se encontraba aunque la
-- extensión SÍ está instalada (el CREATE EXTENSION IF NOT EXISTS de
-- 521 fue un no-op porque ya existía en "extensions").
--
-- QUÉ HACE: CREATE OR REPLACE de UNA sola función — idéntica a la de
-- 521 salvo `SET search_path = public, extensions`. No toca tablas,
-- datos, permisos adicionales ni ninguna otra función. Idempotente y
-- sin riesgo: solo redefine el cuerpo de la RPC.
--
-- No requiere re-ejecutar sql/521 completo.
-- ============================================================

BEGIN;

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
  p_group_base_minor    BIGINT,
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
-- ÚNICO CAMBIO vs sql/521: + extensions en el search_path
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions
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

  v_hash := encode(digest(convert_to(
    jsonb_build_object(
      'provider', p_provider, 'payment_id', p_provider_payment_id,
      'order_id', p_provider_order_id, 'reservation_id', p_reservation_id,
      'captured', p_captured, 'amount_minor', p_amount_minor,
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

COMMIT;

-- ── VERIFICACIÓN ──────────────────────────────────────────────
SELECT prosrc LIKE '%search_path=public, extensions%'
       OR pg_get_functiondef(oid) LIKE '%SET search_path TO ''public, extensions''%'
       AS search_path_incluye_extensions
FROM pg_proc WHERE proname = 'register_payment_evidence';

-- Prueba funcional mínima (auto-contenida, sin dejar rastro):
DO $$
DECLARE v_hash TEXT;
BEGIN
  PERFORM set_config('search_path', 'public, extensions', TRUE);
  v_hash := encode(digest('smoke_test'::bytea, 'sha256'), 'hex');
  RAISE NOTICE 'digest() resuelto correctamente, hash=%', v_hash;
END $$;

SELECT '521b_fix_pgcrypto_search_path.sql ejecutado ✅' AS status;
