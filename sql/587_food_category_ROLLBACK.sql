-- Rollback de sql/587 — elimina la categoría "Comida" SOLO si ningún grupo
-- real la está usando todavía (protección explícita contra dejar
-- proveedores reales sin categoría visible).

BEGIN;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.groups WHERE genre = 'Comida') THEN
    RAISE EXCEPTION 'No se puede revertir: hay grupos reales con genre=Comida. Revisar manualmente antes de continuar.';
  END IF;
  DELETE FROM public.categories WHERE name = 'Comida' AND parent_id IS NULL;
END $$;

COMMIT;

SELECT '587_food_category_ROLLBACK ✅' AS status;
