-- ════════════════════════════════════════════════════════════════════
-- 188_state_filter_profiles.sql
--
-- OBJETIVO: Persistir el estado del usuario en profiles para que
-- el filtro por estado funcione sin depender del GPS en cada sesión.
--
-- Antes:
--   profiles.state NO existía → detectedState solo venía del GPS
--   → Si GPS fallaba, p_state era NULL → RPCs devolvían grupos de todos
--   los estados/países → BOGOTÁ aparecía en JALISCO
--
-- Ahora:
--   profiles.state persiste en DB → se carga en cada sesión
--   → El filtro siempre funciona aunque no haya GPS
--
-- Cambios:
--   1. profiles.state TEXT — columna para el estado del usuario
--   2. update_my_location(p_city, p_state) — guarda ciudad Y estado
--   3. Normalización: estados en minúsculas sin espacios extra
--   4. Trigger normalize en profiles.state al escribir
--
-- Requiere: 187_admin_free_activations.sql
-- ════════════════════════════════════════════════════════════════════


-- ── 1. Columnas city y state en profiles ────────────────────────────────────
-- city puede no existir si el perfil se creó sin ella; la agregamos aquí.

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS city  TEXT;

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS state TEXT;

-- Normalizar filas ya existentes
UPDATE public.profiles
SET state = public.normalize_state_name(state)
WHERE state IS NOT NULL
  AND state <> public.normalize_state_name(state);

UPDATE public.profiles
SET city = LOWER(TRIM(city))
WHERE city IS NOT NULL
  AND city <> LOWER(TRIM(city));


-- ── 2. Trigger: normalizar city y state al escribir ──────────────────────────
-- Nota: NO usar "OF state, city" porque requiere que ambas columnas existan
-- en el momento de crear el trigger. Usamos la forma genérica FOR EACH ROW.

CREATE OR REPLACE FUNCTION public.normalize_profile_location()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.state IS NOT NULL THEN
    NEW.state := public.normalize_state_name(NEW.state);
  END IF;
  IF NEW.city IS NOT NULL THEN
    NEW.city := LOWER(TRIM(NEW.city));
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS trg_normalize_profile_location ON public.profiles;
CREATE TRIGGER trg_normalize_profile_location
  BEFORE INSERT OR UPDATE ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION public.normalize_profile_location();


-- ── 3. update_my_location — guarda ciudad Y estado ──────────────────────────
-- Reemplaza update_my_city para también persistir el estado.
-- update_my_city queda como alias backward-compat.

DROP FUNCTION IF EXISTS public.update_my_location(TEXT, TEXT);
CREATE OR REPLACE FUNCTION public.update_my_location(
  p_city  TEXT DEFAULT NULL,
  p_state TEXT DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid UUID := auth.uid();
BEGIN
  IF v_uid IS NULL THEN RETURN; END IF;

  UPDATE public.profiles
  SET
    city      = COALESCE(NULLIF(TRIM(COALESCE(p_city,  '')), ''), city),
    state     = COALESCE(NULLIF(TRIM(COALESCE(p_state, '')), ''), state),
    updated_at = NOW()
  WHERE id = v_uid;

  RAISE NOTICE '[update_my_location] uid=% city=% state=%', v_uid, p_city, p_state;
END;
$$;

GRANT EXECUTE ON FUNCTION public.update_my_location(TEXT, TEXT) TO authenticated;

-- Alias: update_my_city sigue funcionando sin cambios (backward compat)
DROP FUNCTION IF EXISTS public.update_my_city(TEXT);
CREATE OR REPLACE FUNCTION public.update_my_city(p_city TEXT)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM public.update_my_location(p_city := p_city);
END;
$$;

GRANT EXECUTE ON FUNCTION public.update_my_city(TEXT) TO authenticated;


-- ── 4. Índice para búsquedas por estado ──────────────────────────────────────

CREATE INDEX IF NOT EXISTS idx_profiles_state
  ON public.profiles (state)
  WHERE state IS NOT NULL;


-- ── Verificación ──────────────────────────────────────────────────────────────

SELECT id, full_name, city, state, role
FROM public.profiles
ORDER BY created_at DESC
LIMIT 10;

SELECT
  state,
  COUNT(*) AS perfiles
FROM public.profiles
WHERE state IS NOT NULL
GROUP BY state
ORDER BY perfiles DESC;

SELECT '188_state_filter_profiles.sql ejecutado ✅' AS status;
