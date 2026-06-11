-- ============================================================
-- sql/252_fix_admin_set_group_verified_rejected.sql
--
-- FIX: admin_set_group_verified — cuando p_verified = FALSE
-- ahora establece verification_status = 'rejected' en lugar
-- de dejar el valor existente sin cambiar.
--
-- CONTEXTO DEL BUG (sql/249):
--   El CASE en el UPDATE tenía:
--     ELSE verification_status  -- dejaba 'pending' al rechazar
--   Esto hacía que un grupo rechazado permaneciera con
--   verification_status = 'pending' en el cuerpo de la función.
--
-- POR QUÉ NO ERA VISIBLE EN PRODUCCIÓN:
--   El trigger sync_verification_status (sql/02_triggers_y_funciones.sql)
--   dispara AFTER INSERT en verification_requests. Como la función
--   inserta status='rejected', el trigger sobreescribe el campo
--   con 'rejected' automáticamente, compensando el bug.
--   Este trigger permanece activo hasta sql/255.
--
-- CAMBIO EXACTO:
--   Antes: ELSE verification_status
--   Ahora: ELSE 'rejected'
--   Un solo carácter de diferencia en la lógica de negocio.
--
-- ALCANCE:
--   Solo se modifica admin_set_group_verified.
--   Sin cambios de schema. Sin backfill. Sin otros efectos.
--   La doble escritura (función + trigger) es idempotente
--   hasta que sync_verification_status se elimine en sql/255.
--
-- FIRMA IDÉNTICA: no rompe callers existentes.
-- SECURITY DEFINER + search_path: sin cambios.
-- GRANT: idéntico a sql/249.
--
-- ROLLBACK:
--   Revertir con sql/252_rollback.sql (ELSE verification_status).
--   No hay pérdida de datos: la función no almacena nada por sí misma.
--   Los grupos ya en 'rejected' conservan ese valor tras el rollback.
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
      ELSE 'rejected'
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

-- ── Verificación ──────────────────────────────────────────────────────────────

DO $$
DECLARE
  v_body TEXT;
BEGIN
  SELECT prosrc INTO v_body
  FROM pg_proc
  JOIN pg_namespace ON pg_namespace.oid = pg_proc.pronamespace
  WHERE proname = 'admin_set_group_verified'
    AND nspname  = 'public';

  IF v_body IS NULL THEN
    RAISE EXCEPTION '[252] admin_set_group_verified no encontrada ❌';
  END IF;

  IF v_body NOT LIKE '%ELSE ''rejected''%' THEN
    RAISE EXCEPTION '[252] El fix no se aplicó correctamente — ELSE rejected no encontrado ❌';
  END IF;

  IF v_body LIKE '%ELSE verification_status%' THEN
    RAISE EXCEPTION '[252] El cuerpo antiguo sigue presente — ELSE verification_status aún existe ❌';
  END IF;

  RAISE NOTICE '[252] admin_set_group_verified: p_verified=FALSE → verification_status=rejected ✅';
END;
$$;

SELECT '252_fix_admin_set_group_verified_rejected.sql aplicado correctamente ✅' AS status;
