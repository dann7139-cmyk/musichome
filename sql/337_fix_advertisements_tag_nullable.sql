-- ============================================================
-- sql/337_fix_advertisements_tag_nullable.sql
--
-- El tag en anuncios gratis del admin es opcional.
-- create_free_ad inserta NULL cuando no viene p_tag — el
-- NOT NULL constraint lo rechaza con error de violación.
-- Solución: quitar la restricción NOT NULL en tag.
-- ============================================================

ALTER TABLE public.advertisements
  ALTER COLUMN tag DROP NOT NULL;

-- Verificación
DO $$
DECLARE v_nullable TEXT;
BEGIN
  SELECT is_nullable INTO v_nullable
  FROM information_schema.columns
  WHERE table_schema = 'public' AND table_name = 'advertisements' AND column_name = 'tag';
  IF v_nullable = 'YES' THEN
    RAISE NOTICE '[337] advertisements.tag ahora es nullable ✅';
  ELSE
    RAISE EXCEPTION '[337] ERROR: tag sigue NOT NULL — revisar permisos';
  END IF;
END;
$$;

SELECT '337_fix_advertisements_tag_nullable.sql ejecutado ✅' AS status;
