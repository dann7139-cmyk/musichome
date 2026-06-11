-- ============================================================
-- sql/251_patch_verification_fixes.sql
--
-- Patch de producción sobre sql/249:
--
--  1. admin_set_profile_verified — cuando p_verified = FALSE
--     establece verification_status = 'rejected' (no 'none')
--     para que ClientVerificationScreen muestre el card de rechazo
--     y la nota del administrador al usuario.
--
--  2. admin_get_user_contact — agrega SET search_path = public
--     (recomendación de seguridad Supabase para SECURITY DEFINER).
--
-- Ambas son CREATE OR REPLACE — idempotentes, sin pérdida de datos.
-- ============================================================

-- ── 1. admin_set_profile_verified (patch: 'rejected' al rechazar) ─────────────

CREATE OR REPLACE FUNCTION public.admin_set_profile_verified(
  p_user_id  UUID,
  p_verified BOOLEAN,
  p_note     TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_id  UUID;
  v_user_name TEXT;
  v_user_role TEXT;
BEGIN
  SELECT id INTO v_admin_id
  FROM public.profiles
  WHERE id = auth.uid() AND role = 'admin';

  IF v_admin_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;

  SELECT full_name, role INTO v_user_name, v_user_role
  FROM public.profiles
  WHERE id = p_user_id;

  IF v_user_name IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'user_not_found');
  END IF;

  IF v_user_role NOT IN ('client', 'talent') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_role');
  END IF;

  UPDATE public.profiles
  SET
    admin_verified           = p_verified,
    -- 'approved' al verificar, 'rejected' al rechazar (antes era 'none')
    -- Esto permite que ClientVerificationScreen muestre el card de rechazo
    -- y la nota del admin cuando verification_status = 'rejected'.
    verification_status      = CASE WHEN p_verified THEN 'approved' ELSE 'rejected' END,
    verification_admin_notes = COALESCE(p_note, verification_admin_notes),
    verification_reviewed_at = NOW()
  WHERE id = p_user_id;

  RETURN jsonb_build_object('ok', true, 'verified', p_verified, 'user', v_user_name, 'role', v_user_role);
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_set_profile_verified(UUID, BOOLEAN, TEXT)
  TO authenticated, service_role;

-- ── 2. admin_get_user_contact (patch: SET search_path = public) ───────────────

CREATE OR REPLACE FUNCTION public.admin_get_user_contact(p_user_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_id UUID;
  v_email    TEXT;
  v_phone    TEXT;
BEGIN
  SELECT id INTO v_admin_id
  FROM public.profiles
  WHERE id = auth.uid() AND role = 'admin';

  IF v_admin_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;

  -- auth.users con schema explícito — accesible desde SECURITY DEFINER
  -- aunque search_path = public, la referencia auth.users es directa
  SELECT email INTO v_email
  FROM auth.users
  WHERE id = p_user_id;

  SELECT phone INTO v_phone
  FROM public.profiles
  WHERE id = p_user_id;

  RETURN jsonb_build_object(
    'ok',    true,
    'email', v_email,
    'phone', v_phone
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_get_user_contact(UUID)
  TO authenticated, service_role;

-- ── Verificación ──────────────────────────────────────────────────────────────

DO $$
BEGIN
  RAISE NOTICE '[251] admin_set_profile_verified actualizada: rechazar → verification_status=rejected ✅';
  RAISE NOTICE '[251] admin_get_user_contact actualizada: SET search_path = public ✅';
END;
$$;

SELECT '251_patch_verification_fixes.sql aplicado correctamente ✅' AS status;
