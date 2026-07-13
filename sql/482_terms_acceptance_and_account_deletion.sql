-- ============================================================
-- sql/482_terms_acceptance_and_account_deletion.sql
-- 📜 Cumplimiento de tiendas y legal:
--
--  1. profiles.terms_accepted_at — registro de CUÁNDO aceptó el usuario
--     los Términos y el Aviso de privacidad (clickwrap del registro).
--     Backfill: usuarios existentes quedan con su created_at (aceptaron
--     al usar la app conforme a los términos por uso).
--  2. RPC request_account_deletion — "Eliminar mi cuenta" desde Perfil.
--     Apple lo EXIGE (guideline 5.1.1v). Modelo marketplace:
--       • Bloqueado si hay eventos activos o dinero en juego (debe
--         resolverlos primero — protege a la contraparte).
--       • Anonimiza los datos personales del perfil de inmediato y
--         desactiva la cuenta; los registros financieros se conservan
--         (obligación legal/fiscal, así lo dice el Aviso de privacidad).
--       • Notifica al admin para completar la baja de auth en el panel.
-- ============================================================

BEGIN;

-- ────────────────────────────────────────────────────────────
-- 1) Registro de aceptación de términos
-- ────────────────────────────────────────────────────────────
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS terms_accepted_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS deleted_at        TIMESTAMPTZ;

UPDATE public.profiles
SET terms_accepted_at = created_at
WHERE terms_accepted_at IS NULL;

-- ────────────────────────────────────────────────────────────
-- 2) Eliminar cuenta (iniciada por el usuario)
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.request_account_deletion()
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_uid    UUID := auth.uid();
  v_role   TEXT;
  v_gid    UUID;
  v_active INT;
  v_money  NUMERIC := 0;
  v_admin  UUID;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unauthorized');
  END IF;

  SELECT role INTO v_role FROM profiles WHERE id = v_uid;
  SELECT id INTO v_gid FROM groups WHERE owner_id = v_uid LIMIT 1;

  -- 🔒 Guard: sin eventos activos ni dinero pendiente
  SELECT COUNT(*) INTO v_active FROM reservations
  WHERE (client_id = v_uid OR group_id = v_gid)
    AND status IN ('pending', 'pending_payment', 'pending_group_confirmation',
                   'accepted', 'confirmed', 'in_progress');
  IF v_active > 0 THEN
    RETURN jsonb_build_object('ok', false, 'error',
      format('Tienes %s evento(s) activo(s). Cancélalos o espera a que terminen antes de eliminar tu cuenta.', v_active));
  END IF;

  IF v_gid IS NOT NULL THEN
    SELECT COALESCE(available_balance, 0) + COALESCE(pending_balance, 0)
    INTO v_money FROM group_wallets WHERE group_id = v_gid;
    IF COALESCE(v_money, 0) > 0 THEN
      RETURN jsonb_build_object('ok', false, 'error',
        format('Tu wallet tiene $%s pendientes. Retíralos antes de eliminar tu cuenta.',
               to_char(v_money, 'FM999,999,990')));
    END IF;
  END IF;

  -- Anonimizar datos personales de inmediato (lo financiero se conserva)
  UPDATE profiles SET
    full_name  = 'Usuario eliminado',
    phone      = NULL,
    avatar_url = NULL,
    deleted_at = NOW(),
    updated_at = NOW()
  WHERE id = v_uid;

  -- Desactivar su grupo y sacarlo del explorador
  IF v_gid IS NOT NULL THEN
    UPDATE groups SET is_active = FALSE, updated_at = NOW() WHERE id = v_gid;
  END IF;

  -- Sacarlo de bolsa de trabajo e invitaciones
  UPDATE job_board_profiles SET is_visible = FALSE WHERE user_id = v_uid;
  UPDATE job_invitations SET status = 'rejected'
  WHERE invited_user_id = v_uid AND status = 'pending';

  -- Avisar al admin para completar la baja de auth en el panel Supabase
  SELECT id INTO v_admin FROM profiles WHERE role = 'admin' ORDER BY created_at LIMIT 1;
  IF v_admin IS NOT NULL THEN
    INSERT INTO notifications (user_id, type, title, body, data)
    VALUES (v_admin, 'admin',
      '🗑️ Solicitud de eliminación de cuenta',
      format('El usuario %s (%s) solicitó eliminar su cuenta. Sus datos personales ya fueron anonimizados — completa la baja de auth en el panel de Supabase.',
             v_uid, COALESCE(v_role, '—')),
      jsonb_build_object('user_id', v_uid, 'screen', 'AdminVerifications'));
  END IF;

  RETURN jsonb_build_object('ok', true);
END;
$$;

GRANT EXECUTE ON FUNCTION public.request_account_deletion() TO authenticated;

COMMIT;

-- ── VERIFICACIÓN ──────────────────────────────────────────────────────────────
SELECT column_name FROM information_schema.columns
WHERE table_name = 'profiles' AND column_name IN ('terms_accepted_at', 'deleted_at');
-- Esperado: 2 filas

SELECT proname FROM pg_proc WHERE proname = 'request_account_deletion';
-- Esperado: 1 fila

SELECT '482_terms_acceptance_and_account_deletion.sql ejecutado ✅' AS status;
