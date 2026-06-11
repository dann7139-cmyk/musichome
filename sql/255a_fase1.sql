-- ============================================================
-- sql/255a_fase1.sql — FASE 1
--
-- Seguro: coexiste con el frontend actual sin romper nada.
-- Ejecutar DESPUÉS de confirmar que 255_preflight.sql muestra ✅ en sección 10.
--
-- Después de este script: probar el flujo KYC en la app.
-- Cuando confirmes que funciona: ejecutar 255b_fase3.sql.
-- ROLLBACK: sql/255_rollback.sql
-- ============================================================


-- ─────────────────────────────────────────────────────────────────────────────
-- § F1-1  Deduplicación y limpieza de verification_requests
-- ─────────────────────────────────────────────────────────────────────────────

DO $$
DECLARE
  v_deleted_drafts_with_pending INT;
  v_deleted_dup_pending         INT;
  v_deleted_dup_draft           INT;
BEGIN
  -- a) Eliminar drafts de grupos que ya tienen un pending activo
  DELETE FROM public.verification_requests
  WHERE status = 'draft'
    AND group_id IN (
      SELECT group_id
      FROM   public.verification_requests
      WHERE  status = 'pending'
    );
  GET DIAGNOSTICS v_deleted_drafts_with_pending = ROW_COUNT;

  -- b) Para cada grupo con múltiples pending: conservar el más reciente
  DELETE FROM public.verification_requests
  WHERE status = 'pending'
    AND id NOT IN (
      SELECT DISTINCT ON (group_id) id
      FROM   public.verification_requests
      WHERE  status = 'pending'
      ORDER BY group_id, submitted_at DESC NULLS LAST, id DESC
    );
  GET DIAGNOSTICS v_deleted_dup_pending = ROW_COUNT;

  -- c) Para cada grupo con múltiples draft: conservar el más reciente
  DELETE FROM public.verification_requests
  WHERE status = 'draft'
    AND id NOT IN (
      SELECT DISTINCT ON (group_id) id
      FROM   public.verification_requests
      WHERE  status = 'draft'
      ORDER BY group_id, submitted_at DESC NULLS LAST, id DESC
    );
  GET DIAGNOSTICS v_deleted_dup_draft = ROW_COUNT;

  RAISE NOTICE '[255a F1-1] drafts eliminados por pending activo:  %', v_deleted_drafts_with_pending;
  RAISE NOTICE '[255a F1-1] pendings duplicados eliminados:        %', v_deleted_dup_pending;
  RAISE NOTICE '[255a F1-1] drafts duplicados eliminados:          %', v_deleted_dup_draft;
END;
$$;


-- ─────────────────────────────────────────────────────────────────────────────
-- § F1-2  Índices parciales de unicidad
-- ─────────────────────────────────────────────────────────────────────────────

CREATE UNIQUE INDEX IF NOT EXISTS uidx_vr_group_pending
  ON public.verification_requests (group_id)
  WHERE status = 'pending';

CREATE UNIQUE INDEX IF NOT EXISTS uidx_vr_group_draft
  ON public.verification_requests (group_id)
  WHERE status = 'draft';


-- ─────────────────────────────────────────────────────────────────────────────
-- § F1-3  DROP funciones de código muerto
-- ─────────────────────────────────────────────────────────────────────────────

DROP FUNCTION IF EXISTS public.submit_verification_session(UUID, TEXT, TEXT, TEXT, TEXT);
DROP FUNCTION IF EXISTS public.admin_review_verification(UUID, TEXT, TEXT);


-- ─────────────────────────────────────────────────────────────────────────────
-- § F1-4  RPCs nuevas
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.start_group_verification(
  p_group_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_owner_id UUID;
  v_vstatus  TEXT;
  v_existing RECORD;
  v_new_id   UUID;
BEGIN
  SELECT owner_id, verification_status
  INTO   v_owner_id, v_vstatus
  FROM   public.groups
  WHERE  id = p_group_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'group_not_found');
  END IF;
  IF v_owner_id IS DISTINCT FROM auth.uid() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_owner');
  END IF;
  IF v_vstatus = 'approved' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'already_approved');
  END IF;

  SELECT id INTO v_existing
  FROM   public.verification_requests
  WHERE  group_id = p_group_id AND status = 'pending'
  LIMIT  1;

  IF FOUND THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'pending_exists',
      'attempt_id', v_existing.id
    );
  END IF;

  SELECT id INTO v_existing
  FROM   public.verification_requests
  WHERE  group_id = p_group_id AND status = 'draft'
  ORDER BY submitted_at DESC NULLS LAST, id DESC
  LIMIT  1;

  IF FOUND THEN
    RETURN jsonb_build_object('ok', true, 'attempt_id', v_existing.id, 'created', false);
  END IF;

  INSERT INTO public.verification_requests (group_id, status, submitted_at)
  VALUES (p_group_id, 'draft', now())
  RETURNING id INTO v_new_id;

  RETURN jsonb_build_object('ok', true, 'attempt_id', v_new_id, 'created', true);
END;
$$;


CREATE OR REPLACE FUNCTION public.update_verification_document(
  p_attempt_id    UUID,
  p_document_path TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_status   TEXT;
  v_owner_id UUID;
BEGIN
  SELECT vr.status, g.owner_id
  INTO   v_status, v_owner_id
  FROM   public.verification_requests vr
  JOIN   public.groups g ON g.id = vr.group_id
  WHERE  vr.id = p_attempt_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'attempt_not_found');
  END IF;
  IF v_owner_id IS DISTINCT FROM auth.uid() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_owner');
  END IF;
  IF v_status <> 'draft' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'attempt_not_draft');
  END IF;
  IF p_document_path IS NULL OR trim(p_document_path) = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_path');
  END IF;

  UPDATE public.verification_requests
  SET    document_url = p_document_path
  WHERE  id = p_attempt_id;

  RETURN jsonb_build_object('ok', true);
END;
$$;


CREATE OR REPLACE FUNCTION public.complete_verification_liveness(
  p_attempt_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_status   TEXT;
  v_owner_id UUID;
BEGIN
  SELECT vr.status, g.owner_id
  INTO   v_status, v_owner_id
  FROM   public.verification_requests vr
  JOIN   public.groups g ON g.id = vr.group_id
  WHERE  vr.id = p_attempt_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'attempt_not_found');
  END IF;
  IF v_owner_id IS DISTINCT FROM auth.uid() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_owner');
  END IF;
  IF v_status <> 'draft' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'attempt_not_draft');
  END IF;

  UPDATE public.verification_requests
  SET    liveness_verified = TRUE
  WHERE  id = p_attempt_id;

  RETURN jsonb_build_object('ok', true);
END;
$$;


CREATE OR REPLACE FUNCTION public.submit_verification_request(
  p_attempt_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_group_id     UUID;
  v_status       TEXT;
  v_owner_id     UUID;
  v_document_url TEXT;
  v_liveness     BOOLEAN;
  v_eligible     BOOLEAN;
  v_missing      TEXT[];
BEGIN
  SELECT vr.group_id, vr.status, g.owner_id, vr.document_url, vr.liveness_verified
  INTO   v_group_id, v_status, v_owner_id, v_document_url, v_liveness
  FROM   public.verification_requests vr
  JOIN   public.groups g ON g.id = vr.group_id
  WHERE  vr.id = p_attempt_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'attempt_not_found');
  END IF;
  IF v_owner_id IS DISTINCT FROM auth.uid() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_owner');
  END IF;
  IF v_status <> 'draft' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'attempt_not_draft');
  END IF;
  IF v_document_url IS NULL OR trim(v_document_url) = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'document_required');
  END IF;
  IF NOT COALESCE(v_liveness, FALSE) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'liveness_required');
  END IF;

  SELECT eligible, missing_requirements
  INTO   v_eligible, v_missing
  FROM   public.compute_group_eligibility(v_group_id);

  IF NOT COALESCE(v_eligible, FALSE) THEN
    RETURN jsonb_build_object(
      'ok',      false,
      'error',   'profile_incomplete',
      'missing', v_missing
    );
  END IF;

  UPDATE public.verification_requests
  SET    status       = 'pending',
         submitted_at = now()
  WHERE  id = p_attempt_id;

  UPDATE public.groups
  SET    verification_status = 'pending'
  WHERE  id = v_group_id;

  RETURN jsonb_build_object('ok', true, 'attempt_id', p_attempt_id);
END;
$$;


CREATE OR REPLACE FUNCTION public.admin_review_group_verification(
  p_attempt_id UUID,
  p_approved   BOOLEAN,
  p_notes      TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_role TEXT;
  v_group_id    UUID;
  v_status      TEXT;
BEGIN
  SELECT role INTO v_caller_role
  FROM   public.profiles
  WHERE  id = auth.uid();

  IF v_caller_role <> 'admin' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;

  SELECT group_id, status INTO v_group_id, v_status
  FROM   public.verification_requests
  WHERE  id = p_attempt_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'attempt_not_found');
  END IF;
  IF v_status <> 'pending' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'attempt_not_pending');
  END IF;

  UPDATE public.verification_requests
  SET    status      = CASE WHEN p_approved THEN 'approved' ELSE 'rejected' END,
         admin_notes = p_notes,
         reviewed_at = now()
  WHERE  id = p_attempt_id;

  IF p_approved THEN
    UPDATE public.groups
    SET    is_verified         = TRUE,
           admin_verified      = TRUE,
           verification_status = 'approved'
    WHERE  id = v_group_id;
  ELSE
    UPDATE public.groups
    SET    is_verified         = FALSE,
           admin_verified      = FALSE,
           verification_status = 'rejected'
    WHERE  id = v_group_id;
  END IF;

  RETURN jsonb_build_object('ok', true, 'group_id', v_group_id);
END;
$$;


CREATE OR REPLACE FUNCTION public.admin_review_profile_verification(
  p_profile_id UUID,
  p_approved   BOOLEAN,
  p_notes      TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_result JSONB;
BEGIN
  SELECT public.admin_set_profile_verified(
    p_user_id  => p_profile_id,
    p_verified => p_approved,
    p_note     => p_notes
  ) INTO v_result;

  RETURN v_result;
END;
$$;


CREATE OR REPLACE FUNCTION public.evaluate_group_verification(
  p_group_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_owner_id       UUID;
  v_vstatus        TEXT;
  v_is_verified    BOOLEAN;
  v_admin_verified BOOLEAN;
  v_eligible       BOOLEAN;
  v_missing        TEXT[];
  v_req            RECORD;
BEGIN
  SELECT owner_id, verification_status, is_verified, admin_verified
  INTO   v_owner_id, v_vstatus, v_is_verified, v_admin_verified
  FROM   public.groups
  WHERE  id = p_group_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'group_not_found');
  END IF;

  SELECT eligible, missing_requirements
  INTO   v_eligible, v_missing
  FROM   public.compute_group_eligibility(p_group_id);

  SELECT id, status, document_url, liveness_verified, submitted_at, admin_notes, reviewed_at
  INTO   v_req
  FROM   public.verification_requests
  WHERE  group_id = p_group_id
  ORDER BY
    CASE status
      WHEN 'pending'  THEN 0
      WHEN 'draft'    THEN 1
      WHEN 'approved' THEN 2
      ELSE 3
    END,
    submitted_at DESC NULLS LAST,
    id DESC
  LIMIT 1;

  RETURN jsonb_build_object(
    'ok',                  true,
    'verification_status', COALESCE(v_vstatus, 'none'),
    'is_verified',         COALESCE(v_is_verified, false),
    'admin_verified',      COALESCE(v_admin_verified, false),
    'eligible',            COALESCE(v_eligible, false),
    'missing',             COALESCE(v_missing, '{}'),
    'attempt', CASE
      WHEN v_req.id IS NOT NULL THEN jsonb_build_object(
        'id',                v_req.id,
        'status',            v_req.status,
        'has_document',      v_req.document_url IS NOT NULL,
        'liveness_verified', COALESCE(v_req.liveness_verified, false),
        'submitted_at',      v_req.submitted_at,
        'admin_notes',       v_req.admin_notes,
        'reviewed_at',       v_req.reviewed_at
      )
      ELSE NULL
    END
  );
END;
$$;


CREATE OR REPLACE FUNCTION public.evaluate_profile_verification(
  p_profile_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_vstatus        TEXT;
  v_admin_verified BOOLEAN;
  v_eligible       BOOLEAN;
  v_missing        TEXT[];
BEGIN
  SELECT verification_status, admin_verified
  INTO   v_vstatus, v_admin_verified
  FROM   public.profiles
  WHERE  id = p_profile_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'profile_not_found');
  END IF;

  SELECT eligible, missing_requirements
  INTO   v_eligible, v_missing
  FROM   public.compute_profile_eligibility(p_profile_id);

  RETURN jsonb_build_object(
    'ok',                  true,
    'verification_status', COALESCE(v_vstatus, 'none'),
    'admin_verified',      COALESCE(v_admin_verified, false),
    'eligible',            COALESCE(v_eligible, false),
    'missing',             COALESCE(v_missing, '{}')
  );
END;
$$;


-- ─────────────────────────────────────────────────────────────────────────────
-- § F1-5  GRANTs
-- ─────────────────────────────────────────────────────────────────────────────

GRANT EXECUTE ON FUNCTION public.start_group_verification(UUID)
  TO authenticated;

GRANT EXECUTE ON FUNCTION public.update_verification_document(UUID, TEXT)
  TO authenticated;

GRANT EXECUTE ON FUNCTION public.complete_verification_liveness(UUID)
  TO authenticated;

GRANT EXECUTE ON FUNCTION public.submit_verification_request(UUID)
  TO authenticated;

GRANT EXECUTE ON FUNCTION public.admin_review_group_verification(UUID, BOOLEAN, TEXT)
  TO authenticated, service_role;

GRANT EXECUTE ON FUNCTION public.admin_review_profile_verification(UUID, BOOLEAN, TEXT)
  TO authenticated, service_role;

GRANT EXECUTE ON FUNCTION public.evaluate_group_verification(UUID)
  TO authenticated, service_role;

GRANT EXECUTE ON FUNCTION public.evaluate_profile_verification(UUID)
  TO authenticated, service_role;


-- ─────────────────────────────────────────────────────────────────────────────
-- § F1-6  Verificación
-- ─────────────────────────────────────────────────────────────────────────────

DO $$
DECLARE
  v_fn_count  INT;
  v_idx_count INT;
BEGIN
  SELECT COUNT(*) INTO v_fn_count
  FROM   pg_proc p
  JOIN   pg_namespace ns ON ns.oid = p.pronamespace
  WHERE  ns.nspname = 'public'
    AND  proname IN (
      'start_group_verification',
      'update_verification_document',
      'complete_verification_liveness',
      'submit_verification_request',
      'admin_review_group_verification',
      'admin_review_profile_verification',
      'evaluate_group_verification',
      'evaluate_profile_verification'
    );

  IF v_fn_count < 8 THEN
    RAISE EXCEPTION '[255a] Solo % de 8 RPCs nuevas encontradas ❌', v_fn_count;
  END IF;

  SELECT COUNT(*) INTO v_idx_count
  FROM   pg_indexes
  WHERE  schemaname = 'public'
    AND  tablename  = 'verification_requests'
    AND  indexname  IN ('uidx_vr_group_pending', 'uidx_vr_group_draft');

  IF v_idx_count < 2 THEN
    RAISE EXCEPTION '[255a] Solo % de 2 índices parciales encontrados ❌', v_idx_count;
  END IF;

  IF EXISTS (
    SELECT group_id FROM public.verification_requests
    WHERE status = 'pending'
    GROUP BY group_id HAVING COUNT(*) > 1
  ) THEN
    RAISE EXCEPTION '[255a] Todavía existen grupos con múltiples pending ❌';
  END IF;

  IF EXISTS (
    SELECT group_id FROM public.verification_requests
    WHERE status = 'draft'
    GROUP BY group_id HAVING COUNT(*) > 1
  ) THEN
    RAISE EXCEPTION '[255a] Todavía existen grupos con múltiples draft ❌';
  END IF;

  RAISE NOTICE '[255a] ✅ 8/8 RPCs presentes';
  RAISE NOTICE '[255a] ✅ 2/2 índices parciales presentes';
  RAISE NOTICE '[255a] ✅ Sin duplicados pending/draft';
  RAISE NOTICE '[255a] FASE 1 COMPLETADA — probar la app, luego ejecutar 255b_fase3.sql';
END;
$$;


SELECT '255a_fase1.sql aplicado correctamente ✅' AS status;
