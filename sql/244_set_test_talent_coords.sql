-- ============================================================
-- sql/244_set_test_talent_coords.sql
--
-- Asigna coordenadas de prueba a los talentos visibles que aún
-- no tienen lat/lng, para poder probar el badge de distancia.
--
-- REQUIERE haber ejecutado sql/242_add_talent_location.sql primero.
-- Solo toca filas donde lat IS NULL → idempotente.
--
-- Coordenadas de ejemplo usadas:
--   CDMX centro:  19.4326, -99.1332
--   Monterrey:    25.6866, -100.3161
--   Guadalajara:  20.6597, -103.3496
--
-- En producción cada talento debe ingresar su propia ubicación
-- desde su perfil. Este SQL es solo para pruebas de desarrollo.
-- ============================================================

-- Primer talento visible sin coords → CDMX
UPDATE public.job_board_profiles
SET lat = 19.4326, lng = -99.1332
WHERE is_visible = TRUE
  AND lat IS NULL
  AND user_id = (
    SELECT user_id FROM public.job_board_profiles
    WHERE is_visible = TRUE AND lat IS NULL
    ORDER BY created_at ASC
    LIMIT 1
  );

-- Segundo talento visible sin coords → Monterrey
UPDATE public.job_board_profiles
SET lat = 25.6866, lng = -100.3161
WHERE is_visible = TRUE
  AND lat IS NULL
  AND user_id = (
    SELECT user_id FROM public.job_board_profiles
    WHERE is_visible = TRUE AND lat IS NULL
    ORDER BY created_at ASC
    LIMIT 1
  );

-- Tercer talento visible sin coords → Guadalajara
UPDATE public.job_board_profiles
SET lat = 20.6597, lng = -103.3496
WHERE is_visible = TRUE
  AND lat IS NULL
  AND user_id = (
    SELECT user_id FROM public.job_board_profiles
    WHERE is_visible = TRUE AND lat IS NULL
    ORDER BY created_at ASC
    LIMIT 1
  );

-- Verificación
DO $$
DECLARE
  v_count INT;
BEGIN
  SELECT COUNT(*) INTO v_count
  FROM public.job_board_profiles
  WHERE is_visible = TRUE AND lat IS NOT NULL;

  RAISE NOTICE '[244] Talentos visibles con coordenadas: %', v_count;

  IF v_count = 0 THEN
    RAISE WARNING '[244] Ningún talento tiene coordenadas. Verifica que sql/242 fue ejecutado primero.';
  END IF;
END;
$$;

SELECT '244_set_test_talent_coords.sql: coordenadas de prueba asignadas ✅' AS status;
