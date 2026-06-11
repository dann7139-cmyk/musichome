-- ════════════════════════════════════════════════════════════════════
-- 195_add_coordinates_to_requests.sql
--
-- Añade columnas latitude / longitude a:
--   - event_requests  (solicitudes express)
--   - quotes          (cotizaciones personalizadas)
--
-- Útil para mostrar el pin exacto en el mapa del grupo y calcular
-- distancia con mayor precisión que solo ciudad/estado.
-- ════════════════════════════════════════════════════════════════════

-- event_requests
ALTER TABLE public.event_requests
  ADD COLUMN IF NOT EXISTS latitude  DOUBLE PRECISION DEFAULT NULL,
  ADD COLUMN IF NOT EXISTS longitude DOUBLE PRECISION DEFAULT NULL;

CREATE INDEX IF NOT EXISTS idx_event_requests_coords
  ON public.event_requests(latitude, longitude)
  WHERE latitude IS NOT NULL AND longitude IS NOT NULL;

-- quotes
ALTER TABLE public.quotes
  ADD COLUMN IF NOT EXISTS latitude  DOUBLE PRECISION DEFAULT NULL,
  ADD COLUMN IF NOT EXISTS longitude DOUBLE PRECISION DEFAULT NULL;

CREATE INDEX IF NOT EXISTS idx_quotes_coords
  ON public.quotes(latitude, longitude)
  WHERE latitude IS NOT NULL AND longitude IS NOT NULL;

SELECT '195_add_coordinates_to_requests.sql ejecutado ✅' AS status;
