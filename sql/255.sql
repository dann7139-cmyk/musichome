-- ============================================================
-- sql/255.sql
--
-- ARQUITECTURA FINAL DEL SISTEMA DE VERIFICACIÓN DE GRUPOS
--
-- PRERREQUISITO OBLIGATORIO:
--   Ejecutar 255_preflight.sql PRIMERO.
--   La sección 10 del preflight debe mostrar ✅ en todo antes de continuar.
--
-- ESTRUCTURA:
--   FASE 1 — SQL puro, seguro, desplegable en cualquier momento.
--             No requiere cambios de frontend.
--   FASE 3 — Hardening de permisos.
--             SOLO ejecutar después de desplegar Fase 2 (frontend migrado).
--
-- Ver 255_design_review.md para arquitectura completa, matriz de
-- compatibilidad por pantalla y checklist GO/NO-GO.
--
-- ROLLBACK: sql/255_rollback.sql
-- ============================================================


-- ══════════════════════════════════════════════════════════════════════════════
-- ▐▌ FASE 1 — SQL puro                                                       ▐▌
-- ▐▌ Seguro: las RPCs nuevas coexisten con el código legacy sin conflicto.   ▐▌
-- ▐▌ El frontend puede seguir usando los flujos actuales durante Fase 1.     ▐▌
-- ══════════════════════════════════════════════════════════════════════════════


-- ─────────────────────────────────────────────────────────────────────────────
-- § F1-1  Deduplicación y limpieza de verification_requests
--
-- Criterio (en orden de prioridad):
--   a) Si un grupo tiene draft + pending: eliminar todos los drafts.
--      El pending es la solicitud activa.
--   b) Si un grupo tiene más de un pending: conservar el más reciente
--      (submitted_at DESC, id DESC). Eliminar el resto.
--   c) Si un grupo tiene más de un draft: conservar el más reciente.
--      Eliminar el resto.
--
-- Las filas approved/rejected NO se tocan.
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

  -- b) Para cada grupo con múltiples pending: eliminar todos excepto el más reciente
  DELETE FROM public.verification_requests
  WHERE status = 'pending'
    AND id NOT IN (
      SELECT DISTINCT ON (group_id) id
      FROM   public.verification_requests
      WHERE  status = 'pending'
      ORDER BY group_id, submitted_at DESC NULLS LAST, id DESC
    );
  GET DIAGNOSTICS v_deleted_dup_pending = ROW_COUNT;

  -- c) Para cada grupo con múltiples draft: eliminar todos excepto el más reciente
  DELETE FROM public.verification_requests
  WHERE status = 'draft'
    AND id NOT IN (
      SELECT DISTINCT ON (group_id) id
      FROM   public.verification_requests
      WHERE  status = 'draft'
      ORDER BY group_id, submitted_at DESC NULLS LAST, id DESC
    );
  GET DIAGNOSTICS v_deleted_dup_draft = ROW_COUNT;

  RAISE NOTICE '[255 F1-1] Limpieza completada.';
  RAISE NOTICE '[255 F1-1]   drafts eliminados por pending activo:  %', v_deleted_drafts_with_pending;
  RAISE NOTICE '[255 F1-1]   pendings duplicados eliminados:        %', v_deleted_dup_pending;
  RAISE NOTICE '[255 F1-1]   drafts duplicados eliminados:          %', v_deleted_dup_draft;
END;
$$;


-- ─────────────────────────────────────────────────────────────────────────────
-- § F1-2  Índices parciales de unicidad
--
-- uidx_vr_group_pending — máximo 1 pending por grupo
-- uidx_vr_group_draft   — máximo 1 draft por grupo
--
-- Si la deduplicación de F1-1 se ejecutó correctamente, estos índices
-- se crearán sin conflicto (validado en sección 9 del preflight).
-- ─────────────────────────────────────────────────────────────────────────────

CREATE UNIQUE INDEX IF NOT EXISTS uidx_vr_group_pending
  ON public.verification_requests (group_id)
  WHERE status = 'pending';

CREATE UNIQUE INDEX IF NOT EXISTS uidx_vr_group_draft
  ON public.verification_requests (group_id)
  WHERE status = 'draft';


-- ─────────────────────────────────────────────────────────────────────────────
-- § F1-3  DROP funciones de código muerto (cero callers confirmados)
--
-- submit_verification_session y admin_review_verification fueron creadas en
-- sql/185_kyc_antifraud.sql. Ningún archivo de frontend ni Edge Function
-- las llama. Ver 255_design_review.md § A.
-- ─────────────────────────────────────────────────────────────────────────────

DROP FUNCTION IF EXISTS public.submit_verification_session(UUID, TEXT, TEXT, TEXT, TEXT);
DROP FUNCTION IF EXISTS public.admin_review_verification(UUID, TEXT, TEXT);


-- ─────────────────────────────────────────────────────────────────────────────
-- § F1-4  RPCs nuevas
-- ─────────────────────────────────────────────────────────────────────────────


-- ── start_group_verification ──────────────────────────────────────────────────
--
-- Idempotente: crea un draft o retorna el draft existente.
-- Bloquea si ya hay un pending activo o el grupo está aprobado.
-- Caller: VerificationScreen (group owner).

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

  -- Pending activo: no crear otro draft
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

  -- Draft existente: retornar idempotentemente
  SELECT id INTO v_existing
  FROM   public.verification_requests
  WHERE  group_id = p_group_id AND status = 'draft'
  ORDER BY submitted_at DESC NULLS LAST, id DESC
  LIMIT  1;

  IF FOUND THEN
    RETURN jsonb_build_object('ok', true, 'attempt_id', v_existing.id, 'created', false);
  END IF;

  -- Crear nuevo draft
  INSERT INTO public.verification_requests (group_id, status, submitted_at)
  VALUES (p_group_id, 'draft', now())
  RETURNING id INTO v_new_id;

  RETURN jsonb_build_object('ok', true, 'attempt_id', v_new_id, 'created', true);
END;
$$;


-- ── update_verification_document ──────────────────────────────────────────────
--
-- Guarda el path del documento en la fila draft.
-- Caller: VerificationScreen (tras upload a storage).

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


-- ── complete_verification_liveness ────────────────────────────────────────────
--
-- Marca liveness_verified = TRUE en la fila draft.
-- Caller: VerificationScreen (tras completar el círculo animado).

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


-- ── submit_verification_request ───────────────────────────────────────────────
--
-- Transiciona draft → pending.
-- Valida: documento subido, liveness completado, elegibilidad del perfil.
-- Actualiza groups.verification_status = 'pending'.
-- Caller: VerificationScreen (botón "Enviar solicitud").
--
-- Nota Fase 1: el trigger sync_verification_status sigue activo y también
-- actualizará groups.verification_status cuando el status de vr cambia.
-- El UPDATE explícito en groups es un no-op hasta Fase 3 (cuando el trigger
-- se elimina y este UPDATE es el único mecanismo).

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

  -- Elegibilidad del grupo (nombre, género, foto, descripción, paquete activo)
  SELECT eligible, missing_requirements
  INTO   v_eligible, v_missing
  FROM   public.compute_group_eligibility(v_group_id);

  IF NOT COALESCE(v_eligible, FALSE) THEN
    RETURN jsonb_build_object(
      'ok',     false,
      'error',  'profile_incomplete',
      'missing', v_missing
    );
  END IF;

  -- Transición draft → pending
  UPDATE public.verification_requests
  SET    status       = 'pending',
         submitted_at = now()
  WHERE  id = p_attempt_id;

  -- Sincronización explícita (único mecanismo activo en Fase 3)
  UPDATE public.groups
  SET    verification_status = 'pending'
  WHERE  id = v_group_id;

  RETURN jsonb_build_object('ok', true, 'attempt_id', p_attempt_id);
END;
$$;


-- ── admin_review_group_verification ───────────────────────────────────────────
--
-- Aprueba o rechaza una solicitud de verificación de grupo.
-- Actualiza atomicamente: verification_requests + groups.
-- Reemplaza los direct UPDATEs de VerificationsScreen.tsx:123-139.
-- Caller: VerificationsScreen (tab Grupos).

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

  -- Actualizar la solicitud
  UPDATE public.verification_requests
  SET    status      = CASE WHEN p_approved THEN 'approved' ELSE 'rejected' END,
         admin_notes = p_notes,
         reviewed_at = now()
  WHERE  id = p_attempt_id;

  -- Actualizar el grupo
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


-- ── admin_review_profile_verification ────────────────────────────────────────
--
-- Wrapper de admin_set_profile_verified con interfaz consistente.
-- Permite a VerificationsScreen usar la misma forma de llamado para grupos y perfiles.

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


-- ── evaluate_group_verification ───────────────────────────────────────────────
--
-- Solo lectura. Combina compute_group_eligibility + estado actual de
-- verification_requests para dar al frontend toda la info en una llamada.
-- Caller: VerificationScreen (carga inicial).

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

  -- Solicitud más relevante: pending > draft > historial reciente
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
    'ok',                 true,
    'verification_status', COALESCE(v_vstatus, 'none'),
    'is_verified',        COALESCE(v_is_verified, false),
    'admin_verified',     COALESCE(v_admin_verified, false),
    'eligible',           COALESCE(v_eligible, false),
    'missing',            COALESCE(v_missing, '{}'),
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


-- ── evaluate_profile_verification ────────────────────────────────────────────
--
-- Solo lectura. Estado de verificación + elegibilidad para un perfil.
-- Caller: ClientVerificationScreen (carga inicial).

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
-- § F1-5  GRANTs para las RPCs nuevas
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
-- § F1-6  Verificación de Fase 1
-- ─────────────────────────────────────────────────────────────────────────────

DO $$
DECLARE
  v_fn TEXT;
  v_fn_count INT;
  v_idx_count INT;
BEGIN
  -- Funciones nuevas
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
    RAISE EXCEPTION '[255 F1] Solo % de 8 RPCs nuevas encontradas ❌', v_fn_count;
  END IF;
  RAISE NOTICE '[255 F1] 8 RPCs nuevas: todas presentes ✅';

  -- Funciones de código muerto eliminadas
  SELECT COUNT(*) INTO v_fn_count
  FROM   pg_proc p
  JOIN   pg_namespace ns ON ns.oid = p.pronamespace
  WHERE  ns.nspname = 'public'
    AND  proname IN ('submit_verification_session', 'admin_review_verification');

  IF v_fn_count > 0 THEN
    RAISE WARNING '[255 F1] % función(es) de código muerto todavía existen ⚠️ (puede ser por overloads distintos)', v_fn_count;
  ELSE
    RAISE NOTICE '[255 F1] Funciones de código muerto: eliminadas ✅';
  END IF;

  -- Índices parciales
  SELECT COUNT(*) INTO v_idx_count
  FROM   pg_indexes
  WHERE  schemaname = 'public'
    AND  tablename  = 'verification_requests'
    AND  indexname  IN ('uidx_vr_group_pending', 'uidx_vr_group_draft');

  IF v_idx_count < 2 THEN
    RAISE EXCEPTION '[255 F1] Solo % de 2 índices parciales encontrados ❌', v_idx_count;
  END IF;
  RAISE NOTICE '[255 F1] Índices parciales de unicidad: presentes ✅';

  -- Sin duplicados pending/draft post-limpieza
  IF EXISTS (
    SELECT group_id FROM public.verification_requests
    WHERE status = 'pending'
    GROUP BY group_id HAVING COUNT(*) > 1
  ) THEN
    RAISE EXCEPTION '[255 F1] Todavía existen grupos con múltiples pending ❌';
  END IF;
  IF EXISTS (
    SELECT group_id FROM public.verification_requests
    WHERE status = 'draft'
    GROUP BY group_id HAVING COUNT(*) > 1
  ) THEN
    RAISE EXCEPTION '[255 F1] Todavía existen grupos con múltiples draft ❌';
  END IF;
  RAISE NOTICE '[255 F1] Unicidad de pending/draft: verificada ✅';

  RAISE NOTICE '[255 F1] ════════════════════════════════════════';
  RAISE NOTICE '[255 F1] FASE 1 COMPLETADA ✅';
  RAISE NOTICE '[255 F1] Próximo paso: desplegar Fase 2 (frontend).';
  RAISE NOTICE '[255 F1] Ver 255_design_review.md § D (Fase 2).';
  RAISE NOTICE '[255 F1] SOLO después del frontend: ejecutar FASE 3.';
  RAISE NOTICE '[255 F1] ════════════════════════════════════════';
END;
$$;


-- ══════════════════════════════════════════════════════════════════════════════
-- ▐▌ FASE 3 — Hardening de permisos                                          ▐▌
-- ▐▌                                                                          ▐▌
-- ▐▌  ⚠️  DETENTE AQUÍ  ⚠️                                                   ▐▌
-- ▐▌                                                                          ▐▌
-- ▐▌  NO ejecutar esta sección hasta confirmar que Fase 2 (frontend)          ▐▌
-- ▐▌  está desplegada y funcionando correctamente.                            ▐▌
-- ▐▌                                                                          ▐▌
-- ▐▌  Checklist de Fase 2 (ver 255_design_review.md § D):                    ▐▌
-- ▐▌  ☐ VerificationScreen usa start_group_verification RPC                  ▐▌
-- ▐▌  ☐ VerificationScreen usa update_verification_document RPC              ▐▌
-- ▐▌  ☐ VerificationScreen usa complete_verification_liveness RPC            ▐▌
-- ▐▌  ☐ VerificationScreen usa submit_verification_request RPC               ▐▌
-- ▐▌  ☐ VerificationScreen NO hace direct UPDATE en groups (línea 325)       ▐▌
-- ▐▌  ☐ VerificationsScreen usa admin_review_group_verification RPC          ▐▌
-- ▐▌  ☐ VerificationsScreen filtra .neq('status','draft') en fetchGroups     ▐▌
-- ▐▌  ☐ Prueba E2E: grupo completa flujo → admin aprueba → badge aparece     ▐▌
-- ▐▌                                                                          ▐▌
-- ══════════════════════════════════════════════════════════════════════════════


-- ─────────────────────────────────────────────────────────────────────────────
-- § F3-1  DROP TRIGGER + FUNCTION sync_group_verification
--
-- El trigger sync_verification_status sincronizaba groups cuando cambiaba
-- el status de verification_requests. Las RPCs nuevas hacen esto explícitamente
-- con SECURITY DEFINER, por lo que el trigger es redundante y conflictivo.
--
-- El trigger es SECURITY INVOKER: escribe en groups usando los permisos del
-- caller. Tras el REVOKE de F3-2, los callers authenticated ya no podrán
-- escribir esos campos → el trigger fallaría. Por eso se elimina primero.
-- ─────────────────────────────────────────────────────────────────────────────

DROP TRIGGER IF EXISTS sync_verification_status
  ON public.verification_requests;

DROP FUNCTION IF EXISTS public.sync_group_verification();


-- ─────────────────────────────────────────────────────────────────────────────
-- § F3-2  REVOKE + GRANT column-level en groups
--
-- REVOKE: retira el permiso de UPDATE irrestricto en groups de authenticated.
-- GRANT:  reotorga UPDATE solo sobre las columnas que el owner edita legítimamente.
--
-- Columnas EXCLUIDAS del GRANT (solo accesibles vía RPCs SECURITY DEFINER):
--   is_verified, admin_verified, verification_status
--   strike_count, last_strike_at, suspended_at, suspended_by (admin-only)
--
-- ⚠️  VERIFICAR LA LISTA ANTES DE EJECUTAR:
--   SELECT column_name FROM information_schema.columns
--   WHERE table_schema = 'public' AND table_name = 'groups'
--   ORDER BY ordinal_position;
--
-- Confirmar que NO hay columnas legítimamente editables por el owner
-- que falten en el GRANT — cualquier columna omitida dejará de
-- ser escribible desde la app hasta que se agregue.
-- ─────────────────────────────────────────────────────────────────────────────

REVOKE UPDATE ON public.groups FROM authenticated;

GRANT UPDATE (
  -- Perfil público del grupo
  name,
  genre,
  description,
  city,
  state,
  profile_image,
  promo_video,
  is_active,
  price_from,
  -- Publicidad y bidding
  bid_amount,
  -- Cobertura
  service_cities
) ON public.groups TO authenticated;


-- ─────────────────────────────────────────────────────────────────────────────
-- § F3-3  Verificación de Fase 3
-- ─────────────────────────────────────────────────────────────────────────────

DO $$
DECLARE
  v_trigger_count INT;
BEGIN
  -- Trigger eliminado
  SELECT COUNT(*) INTO v_trigger_count
  FROM   information_schema.triggers
  WHERE  trigger_schema = 'public'
    AND  event_object_table = 'verification_requests'
    AND  trigger_name = 'sync_verification_status';

  IF v_trigger_count > 0 THEN
    RAISE EXCEPTION '[255 F3] Trigger sync_verification_status todavía existe ❌';
  END IF;
  RAISE NOTICE '[255 F3] Trigger sync_verification_status: eliminado ✅';

  -- Función legacy eliminada
  IF EXISTS (
    SELECT 1 FROM pg_proc p
    JOIN pg_namespace ns ON ns.oid = p.pronamespace
    WHERE ns.nspname = 'public' AND proname = 'sync_group_verification'
  ) THEN
    RAISE EXCEPTION '[255 F3] Función sync_group_verification todavía existe ❌';
  END IF;
  RAISE NOTICE '[255 F3] Función sync_group_verification: eliminada ✅';

  -- REVOKE aplicado: authenticated NO debe tener UPDATE irrestricto en groups
  -- (Verificación indirecta: si el REVOKE se aplicó, la columna is_verified
  --  no estará en el GRANT de column-level)
  IF EXISTS (
    SELECT 1 FROM information_schema.column_privileges
    WHERE grantee   = 'authenticated'
      AND table_schema = 'public'
      AND table_name = 'groups'
      AND column_name IN ('is_verified', 'admin_verified', 'verification_status')
      AND privilege_type = 'UPDATE'
  ) THEN
    RAISE EXCEPTION '[255 F3] authenticated todavía tiene UPDATE en columnas de verificación ❌';
  END IF;
  RAISE NOTICE '[255 F3] REVOKE de columnas sensibles: verificado ✅';

  RAISE NOTICE '[255 F3] ════════════════════════════════════════';
  RAISE NOTICE '[255 F3] FASE 3 COMPLETADA ✅';
  RAISE NOTICE '[255 F3] Vulnerabilidad groups_owner_all: CERRADA.';
  RAISE NOTICE '[255 F3] is_verified, admin_verified, verification_status';
  RAISE NOTICE '[255 F3] ya NO son escribibles directamente vía API.';
  RAISE NOTICE '[255 F3] ════════════════════════════════════════';
END;
$$;


SELECT '255.sql — Fase 1 y Fase 3 aplicadas correctamente ✅' AS status;
