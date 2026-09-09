-- sql/630_admin_ops_verification_scope.sql
--
-- Fase 1 (cola 3/3: Verificación/KYC) del admin con alcance por país.
--
-- Hallazgo real durante el diseño: a diferencia de las otras 2 colas,
-- las listas de verificación pendiente NUNCA se leían por un RPC — la
-- pantalla actual (VerificationsScreen) consulta `verification_requests`
-- y `profiles` DIRECTO desde el cliente. Eso es seguro para el admin
-- completo por la política RLS `verreq_admin_all`, pero NO se puede
-- acotar por país con una política RLS nueva para admin_ops: `profiles`
-- ya tiene `profiles_authenticated_read` con qual=true (CUALQUIER usuario
-- autenticado puede leer CUALQUIER perfil completo — necesario para que
-- la app muestre nombres/fotos de otros usuarios en toda la plataforma).
-- Las políticas RLS son permisivas (se combinan con OR): agregar una
-- política admin_ops más restrictiva no reduciría nada, porque la de
-- "true" ya lo permite todo. Por eso, para admin_ops, las listas de
-- verificación tienen que salir de un RPC nuevo (que sí puede negar
-- acceso de verdad), no de una consulta directa a la tabla.
--
-- Nuevo: admin_get_pending_group_verifications, admin_get_pending_profile_verifications.
-- Modificado: admin_review_group_verification, admin_set_profile_verified
-- (mismo patrón de re-verificación de país en las acciones que las otras 2 colas).
BEGIN;

-- ── 1/4 (nuevo): admin_get_pending_group_verifications ──────────────────
CREATE OR REPLACE FUNCTION public.admin_get_pending_group_verifications(p_limit integer DEFAULT 50)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_role TEXT;
  v_result      JSONB;
BEGIN
  SELECT role INTO v_caller_role FROM profiles WHERE id = auth.uid();
  IF v_caller_role NOT IN ('admin', 'admin_ops') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;

  SELECT jsonb_build_object(
    'ok', true,
    'items', COALESCE(jsonb_agg(x.item ORDER BY x.submitted_at ASC), '[]'::jsonb)
  )
  INTO v_result
  FROM (
    SELECT
      vr.submitted_at,
      jsonb_build_object(
        'id',                vr.id,
        'group_id',          vr.group_id,
        'group_name',        g.name,
        'document_url',      vr.document_url,
        'selfie_url',        vr.selfie_url,
        'liveness_verified', vr.liveness_verified,
        'submitted_at',      vr.submitted_at,
        'country_code',      country_code_of(g.country),
        'country',           COALESCE(g.country, 'México'),
        'state',             g.state,
        'city',              g.city
      ) AS item
    FROM verification_requests vr
    JOIN groups g ON g.id = vr.group_id
    WHERE vr.status = 'pending'
      AND (v_caller_role = 'admin' OR country_code_of(g.country) = admin_ops_country())
    LIMIT p_limit
  ) x;

  RETURN v_result;
END;
$function$;

-- ── 2/4 (nuevo): admin_get_pending_profile_verifications ────────────────
CREATE OR REPLACE FUNCTION public.admin_get_pending_profile_verifications(p_role text DEFAULT NULL, p_limit integer DEFAULT 50)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_role TEXT;
  v_result      JSONB;
BEGIN
  SELECT role INTO v_caller_role FROM profiles WHERE id = auth.uid();
  IF v_caller_role NOT IN ('admin', 'admin_ops') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;
  IF p_role IS NOT NULL AND p_role NOT IN ('client', 'talent') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_role');
  END IF;

  SELECT jsonb_build_object(
    'ok', true,
    'items', COALESCE(jsonb_agg(x.item ORDER BY x.submitted_at ASC), '[]'::jsonb)
  )
  INTO v_result
  FROM (
    SELECT
      p.verification_submitted_at AS submitted_at,
      jsonb_build_object(
        'id',                p.id,
        'full_name',         p.full_name,
        'role',              p.role,
        'submitted_at',      p.verification_submitted_at,
        'country_code',      country_code_of(p.country),
        'country',           COALESCE(p.country, 'México'),
        'state',             p.state,
        'city',              p.city
      ) AS item
    FROM profiles p
    WHERE p.role IN ('client', 'talent')
      AND p.verification_status = 'pending'
      AND (p_role IS NULL OR p.role = p_role)
      AND (v_caller_role = 'admin' OR country_code_of(p.country) = admin_ops_country())
    LIMIT p_limit
  ) x;

  RETURN v_result;
END;
$function$;

-- ── 3/4: admin_review_group_verification (acción) ───────────────────────
CREATE OR REPLACE FUNCTION public.admin_review_group_verification(p_attempt_id uuid, p_approved boolean, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_role TEXT;
  v_group_id    UUID;
  v_status      TEXT;
BEGIN
  SELECT role INTO v_caller_role
  FROM   public.profiles
  WHERE  id = auth.uid();

  IF v_caller_role NOT IN ('admin', 'admin_ops') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;

  SELECT group_id, status INTO v_group_id, v_status
  FROM   public.verification_requests
  WHERE  id = p_attempt_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'attempt_not_found');
  END IF;

  -- [630] admin_ops: el grupo de la solicitud debe ser de su país de alcance
  IF v_caller_role = 'admin_ops' AND NOT EXISTS (
    SELECT 1 FROM public.groups g WHERE g.id = v_group_id
      AND country_code_of(g.country) = admin_ops_country()
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
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
$function$;

-- ── 4/4: admin_set_profile_verified (acción) ─────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_set_profile_verified(p_user_id uuid, p_verified boolean, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_role TEXT;
  v_admin_id  UUID;
  v_user_name TEXT;
  v_user_role TEXT;
  v_user_country TEXT;
BEGIN
  SELECT id, role INTO v_admin_id, v_caller_role
  FROM public.profiles
  WHERE id = auth.uid();

  IF v_caller_role NOT IN ('admin', 'admin_ops') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;

  SELECT full_name, role, country INTO v_user_name, v_user_role, v_user_country
  FROM public.profiles
  WHERE id = p_user_id;

  IF v_user_name IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'user_not_found');
  END IF;

  IF v_user_role NOT IN ('client', 'talent') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_role');
  END IF;

  -- [630] admin_ops: el perfil a verificar debe ser de su país de alcance
  IF v_caller_role = 'admin_ops' AND country_code_of(v_user_country) <> admin_ops_country() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;

  UPDATE public.profiles
  SET
    admin_verified           = p_verified,
    verification_status      = CASE WHEN p_verified THEN 'approved' ELSE 'rejected' END,
    verification_admin_notes = COALESCE(p_note, verification_admin_notes),
    verification_reviewed_at = NOW()
  WHERE id = p_user_id;

  RETURN jsonb_build_object('ok', true, 'verified', p_verified, 'user', v_user_name, 'role', v_user_role);
END;
$function$;

COMMIT;
