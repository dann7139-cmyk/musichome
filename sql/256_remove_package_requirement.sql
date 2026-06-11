-- ============================================================
-- sql/256_remove_package_requirement.sql
--
-- Elimina el requisito "paquete activo" de compute_group_eligibility.
--
-- CONTEXTO:
--   El criterio active_package fue incluido en sql/254 como
--   requisito de elegibilidad para la verificación de grupos.
--   La decisión de negocio es que la verificación de identidad
--   (KYC) no debe depender de si el grupo tiene paquetes
--   publicados. Ambas cosas son independientes.
--
-- CAMBIOS:
--   • compute_group_eligibility — elimina c_pkg (active_package).
--     Criterios restantes: name, genre, profile_image, description.
--
-- IMPACTO EN RPCS EXISTENTES:
--   • submit_verification_request llama compute_group_eligibility.
--     Grupos sin paquetes activos ya no serán rechazados por esta
--     validación.
--   • evaluate_group_verification también la llama. El campo
--     'missing' de su respuesta ya no incluirá 'active_package'.
--   • compute_profile_eligibility no se modifica.
--
-- IDEMPOTENTE: Sí (CREATE OR REPLACE).
-- ROLLBACK: Re-ejecutar sql/254_compute_eligibility_functions.sql.
-- ============================================================


-- ─────────────────────────────────────────────────────────────────────────────
-- § 1  compute_group_eligibility — sin active_package
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.compute_group_eligibility(
  p_group_id UUID
)
RETURNS TABLE(
  eligible             BOOLEAN,
  missing_requirements TEXT[]
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH crit AS (
    SELECT
      CASE WHEN g.name          IS NULL OR trim(g.name)          = ''
           THEN 'name'::TEXT          END AS c_name,
      CASE WHEN g.genre         IS NULL OR trim(g.genre)         = ''
           THEN 'genre'::TEXT         END AS c_genre,
      CASE WHEN g.profile_image IS NULL OR trim(g.profile_image) = ''
           THEN 'profile_image'::TEXT END AS c_photo,
      CASE WHEN g.description   IS NULL OR trim(g.description)   = ''
           THEN 'description'::TEXT   END AS c_desc
    FROM public.groups g
    WHERE g.id = p_group_id
  )
  SELECT
    (c_name IS NULL AND c_genre IS NULL AND c_photo IS NULL AND c_desc IS NULL) AS eligible,
    array_remove(ARRAY[c_name, c_genre, c_photo, c_desc], NULL) AS missing_requirements
  FROM crit;
$$;

GRANT EXECUTE ON FUNCTION public.compute_group_eligibility(UUID)
  TO authenticated, service_role;


-- ─────────────────────────────────────────────────────────────────────────────
-- § 2  Verificación
-- ─────────────────────────────────────────────────────────────────────────────

DO $$
DECLARE
  v_fn_exists BOOLEAN;
BEGIN
  -- 1. La función existe
  SELECT EXISTS (
    SELECT 1 FROM pg_proc p
    JOIN   pg_namespace ns ON ns.oid = p.pronamespace
    WHERE  ns.nspname = 'public'
      AND  proname    = 'compute_group_eligibility'
  ) INTO v_fn_exists;

  IF NOT v_fn_exists THEN
    RAISE EXCEPTION '[256] compute_group_eligibility no encontrada ❌';
  END IF;
  RAISE NOTICE '[256] compute_group_eligibility: existe ✅';

  -- 2. El cuerpo ya no contiene la variable c_pkg (eliminada junto con active_package)
  IF EXISTS (
    SELECT 1 FROM pg_proc p
    JOIN   pg_namespace ns ON ns.oid = p.pronamespace
    WHERE  ns.nspname = 'public'
      AND  proname    = 'compute_group_eligibility'
      AND  prosrc     LIKE '%c_pkg%'
  ) THEN
    RAISE EXCEPTION '[256] La función todavía contiene c_pkg (active_package no fue eliminado) ❌';
  END IF;
  RAISE NOTICE '[256] c_pkg ausente — active_package eliminado correctamente ✅';

  -- 3. Llamada de prueba con UUID inexistente — no debe lanzar error
  PERFORM public.compute_group_eligibility('00000000-0000-0000-0000-000000000000');
  RAISE NOTICE '[256] Llamada con UUID inexistente: sin error ✅';

  RAISE NOTICE '[256] compute_group_eligibility actualizada correctamente ✅';
END;
$$;


SELECT '256_remove_package_requirement.sql aplicado correctamente ✅' AS status;
