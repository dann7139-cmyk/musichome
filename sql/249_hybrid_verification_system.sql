-- ============================================================
-- sql/249_hybrid_verification_system.sql
--
-- Fase 1: Sistema híbrido de verificación (admin_verified).
--
-- CAMBIOS:
--   • ADD COLUMN admin_verified BOOLEAN a groups y profiles
--   • RPC admin_set_group_verified   — el admin verifica/desverifica un grupo
--   • RPC admin_set_profile_verified — el admin verifica/desverifica cliente o talento
--   • RPC admin_get_user_contact     — el admin lee email + teléfono de cualquier usuario
--
-- BACKWARD COMPATIBLE:
--   • No toca: is_verified, verification_status, phone_verified, id_verified
--   • No crea triggers en esta fase
--   • No crea auto_verified en esta fase
--   • Idempotente: ADD COLUMN IF NOT EXISTS, CREATE OR REPLACE
--
-- No toca: pagos, wallets, Stripe, reservas, timers, realtime, paquetes.
-- ============================================================

-- ── 1. Columna admin_verified en groups ────────────────────────────────────────

ALTER TABLE public.groups
  ADD COLUMN IF NOT EXISTS admin_verified BOOLEAN DEFAULT FALSE;

-- ── 2. Columna admin_verified en profiles ─────────────────────────────────────

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS admin_verified BOOLEAN DEFAULT FALSE;

-- ── 3. RPC admin_set_group_verified ───────────────────────────────────────────
--
-- Verifica o desverifica un grupo manualmente.
-- Actualiza admin_verified + is_verified (campo legacy — sin trigger).
-- Registra la acción en verification_requests para historial.
-- Solo accesible por usuarios con role = 'admin'.

CREATE OR REPLACE FUNCTION public.admin_set_group_verified(
  p_group_id UUID,
  p_verified  BOOLEAN,
  p_note      TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_id UUID;
  v_group_name TEXT;
BEGIN
  -- Verificar que el caller es admin
  SELECT id INTO v_admin_id
  FROM public.profiles
  WHERE id = auth.uid() AND role = 'admin';

  IF v_admin_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;

  -- Verificar que el grupo existe
  SELECT name INTO v_group_name FROM public.groups WHERE id = p_group_id;
  IF v_group_name IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'group_not_found');
  END IF;

  -- Actualizar campos en groups (admin_verified + is_verified legacy)
  UPDATE public.groups
  SET
    admin_verified      = p_verified,
    is_verified         = p_verified,
    verification_status = CASE
      WHEN p_verified THEN 'approved'
      ELSE verification_status   -- no revertir el status al desverificar
    END
  WHERE id = p_group_id;

  -- Registrar en verification_requests para historial
  INSERT INTO public.verification_requests (
    group_id,
    status,
    admin_notes,
    submitted_at,
    reviewed_at
  ) VALUES (
    p_group_id,
    CASE WHEN p_verified THEN 'approved' ELSE 'rejected' END,
    p_note,
    NOW(),
    NOW()
  );

  RETURN jsonb_build_object('ok', true, 'verified', p_verified, 'group', v_group_name);
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_set_group_verified(UUID, BOOLEAN, TEXT)
  TO authenticated, service_role;

-- ── 4. RPC admin_set_profile_verified ─────────────────────────────────────────
--
-- Verifica o desverifica un cliente o talento manualmente.
-- Actualiza admin_verified + verification_status (campo legacy).
-- NO toca id_verified — ese campo queda para compatibilidad histórica únicamente.
-- Solo accesible por usuarios con role = 'admin'.

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
  -- Verificar que el caller es admin
  SELECT id INTO v_admin_id
  FROM public.profiles
  WHERE id = auth.uid() AND role = 'admin';

  IF v_admin_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;

  -- Verificar que el usuario existe y obtener su rol
  SELECT full_name, role INTO v_user_name, v_user_role
  FROM public.profiles
  WHERE id = p_user_id;

  IF v_user_name IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'user_not_found');
  END IF;

  -- Solo aplicar a clientes y talentos (no a admins ni grupos)
  IF v_user_role NOT IN ('client', 'talent') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_role');
  END IF;

  -- Actualizar campos en profiles
  UPDATE public.profiles
  SET
    admin_verified             = p_verified,
    verification_status        = CASE WHEN p_verified THEN 'approved' ELSE 'none' END,
    verification_admin_notes   = COALESCE(p_note, verification_admin_notes),
    verification_reviewed_at   = NOW()
  WHERE id = p_user_id;

  RETURN jsonb_build_object('ok', true, 'verified', p_verified, 'user', v_user_name, 'role', v_user_role);
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_set_profile_verified(UUID, BOOLEAN, TEXT)
  TO authenticated, service_role;

-- ── 5. RPC admin_get_user_contact ─────────────────────────────────────────────
--
-- Devuelve email (de auth.users) y teléfono (de profiles) de un usuario.
-- Solo accesible por administradores.
-- El email NO está en profiles — vive en auth.users, accesible con SECURITY DEFINER.

CREATE OR REPLACE FUNCTION public.admin_get_user_contact(p_user_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_admin_id UUID;
  v_email    TEXT;
  v_phone    TEXT;
BEGIN
  -- Verificar que el caller es admin
  SELECT id INTO v_admin_id
  FROM public.profiles
  WHERE id = auth.uid() AND role = 'admin';

  IF v_admin_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;

  -- Email desde auth.users (requiere SECURITY DEFINER para acceder)
  SELECT email INTO v_email
  FROM auth.users
  WHERE id = p_user_id;

  -- Teléfono desde profiles
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

-- ── 6. Verificación final ──────────────────────────────────────────────────────

DO $$
DECLARE
  v_groups_col   BOOLEAN;
  v_profiles_col BOOLEAN;
BEGIN
  SELECT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'groups' AND column_name = 'admin_verified'
  ) INTO v_groups_col;

  SELECT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'profiles' AND column_name = 'admin_verified'
  ) INTO v_profiles_col;

  IF v_groups_col   THEN RAISE NOTICE '[249] groups.admin_verified ✅';
  ELSE RAISE WARNING '[249] groups.admin_verified NO encontrado ❌'; END IF;

  IF v_profiles_col THEN RAISE NOTICE '[249] profiles.admin_verified ✅';
  ELSE RAISE WARNING '[249] profiles.admin_verified NO encontrado ❌'; END IF;
END;
$$;

SELECT '249_hybrid_verification_system.sql ejecutado correctamente ✅' AS status;
