-- ============================================================
-- sql/252_rollback.sql
--
-- Revierte sql/252_fix_admin_set_group_verified_rejected.sql
--
-- Restaura el comportamiento original de sql/249:
-- cuando p_verified = FALSE, verification_status queda sin
-- cambiar (el trigger sync_verification_status lo corrige).
--
-- CUÁNDO USAR:
--   Solo si se detecta comportamiento inesperado tras aplicar
--   sql/252. En condiciones normales no debería ser necesario.
--
-- IMPACTO DEL ROLLBACK:
--   - La función vuelve al estado de sql/249.
--   - Grupos ya guardados con 'rejected' conservan ese valor.
--   - Futuros rechazos dejarán verification_status sin cambiar
--     en el cuerpo de la función, pero sync_verification_status
--     lo corregirá via trigger (comportamiento previo).
--   - Sin pérdida de datos.
-- ============================================================

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
  v_admin_id   UUID;
  v_group_name TEXT;
BEGIN
  SELECT id INTO v_admin_id
  FROM public.profiles
  WHERE id = auth.uid() AND role = 'admin';

  IF v_admin_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;

  SELECT name INTO v_group_name
  FROM public.groups
  WHERE id = p_group_id;

  IF v_group_name IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'group_not_found');
  END IF;

  UPDATE public.groups
  SET
    admin_verified      = p_verified,
    is_verified         = p_verified,
    verification_status = CASE
      WHEN p_verified THEN 'approved'
      ELSE verification_status
    END
  WHERE id = p_group_id;

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

SELECT '252_rollback.sql aplicado — admin_set_group_verified revertida a sql/249 ✅' AS status;
