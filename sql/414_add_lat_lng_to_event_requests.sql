-- ════════════════════════════════════════════════════════════════════
-- sql/414_add_lat_lng_to_event_requests.sql
--
-- PROBLEMA:
--   event_requests nunca tuvo columnas latitude/longitude.
--   GuidedRequestScreen las insertaba pero Supabase las ignoraba.
--   IncomingExpressScreen caía siempre al lookup por nombre de ciudad
--   → todos los eventos aparecían en el centro de la ciudad.
--
-- FIX:
--   1. Agregar latitude/longitude a event_requests
--   2. Copiar event_lat/event_lng como fallback en filas existentes
--
-- Seguro de correr múltiples veces (idempotente).
-- ════════════════════════════════════════════════════════════════════

ALTER TABLE public.event_requests
  ADD COLUMN IF NOT EXISTS latitude  DOUBLE PRECISION DEFAULT NULL,
  ADD COLUMN IF NOT EXISTS longitude DOUBLE PRECISION DEFAULT NULL;

-- Para solicitudes ya existentes sin lat/lng, copiar event_lat/event_lng
-- como aproximación (posición GPS del cliente al crear la solicitud)
UPDATE public.event_requests
SET
  latitude  = event_lat,
  longitude = event_lng
WHERE latitude  IS NULL
  AND longitude IS NULL
  AND event_lat IS NOT NULL
  AND event_lng IS NOT NULL;

-- Índice para búsquedas geoespaciales futuras
CREATE INDEX IF NOT EXISTS idx_er_coords
  ON public.event_requests (latitude, longitude)
  WHERE latitude IS NOT NULL;

-- Verificación
SELECT
  COUNT(*)                                       AS total,
  COUNT(*) FILTER (WHERE latitude IS NOT NULL)   AS con_coords,
  COUNT(*) FILTER (WHERE latitude IS NULL)       AS sin_coords
FROM public.event_requests
WHERE status IN ('open', 'en_negociacion')
  AND created_at > NOW() - INTERVAL '7 days';

SELECT '414_add_lat_lng_to_event_requests ✅' AS status;
