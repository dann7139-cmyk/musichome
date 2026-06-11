-- ============================================================
-- sql/262_drop_city_requirement.sql
--
-- Quita la validación obligatoria de city en grupos y talentos.
-- Los grupos/talentos ahora solo requieren state + country.
-- ============================================================

-- Reemplazar el trigger normalize_group_city para que no exija city
CREATE OR REPLACE FUNCTION normalize_group_city()
RETURNS TRIGGER AS $$
BEGIN
  -- Ya no se exige city; solo se normaliza si viene vacío → NULL
  IF NEW.city IS NOT NULL AND trim(NEW.city) = '' THEN
    NEW.city := NULL;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Hacer city nullable en groups (por si tiene NOT NULL)
ALTER TABLE public.groups
  ALTER COLUMN city DROP NOT NULL;

-- Hacer city nullable en profiles también
ALTER TABLE public.profiles
  ALTER COLUMN city DROP NOT NULL;

-- Verificar que el trigger ya existe (se actualiza con CREATE OR REPLACE arriba)
-- Si el trigger no existía, crearlo
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger
    WHERE tgname = 'trg_normalize_group_city'
      AND tgrelid = 'public.groups'::regclass
  ) THEN
    CREATE TRIGGER trg_normalize_group_city
      BEFORE INSERT OR UPDATE ON public.groups
      FOR EACH ROW EXECUTE FUNCTION normalize_group_city();
  END IF;
END;
$$;
