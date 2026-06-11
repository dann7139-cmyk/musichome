-- ============================================================
-- sql/238_logistics_fields.sql
--
-- FASE 1: Campos logísticos en reservations
-- Permite validar disponibilidad por tiempo de traslado.
-- Backward compatible: columnas opcionales con DEFAULT.
-- ============================================================

ALTER TABLE public.reservations
  ADD COLUMN IF NOT EXISTS event_city    TEXT,
  ADD COLUMN IF NOT EXISTS event_state   TEXT,
  ADD COLUMN IF NOT EXISTS event_country TEXT DEFAULT 'MX',
  ADD COLUMN IF NOT EXISTS event_lat     NUMERIC,
  ADD COLUMN IF NOT EXISTS event_lng     NUMERIC;

-- Índice para queries de conflicto por grupo + fecha
CREATE INDEX IF NOT EXISTS idx_reservations_group_date_status
  ON public.reservations (group_id, event_date, status)
  WHERE status IN ('confirmed', 'accepted', 'in_progress');

-- Índice para queries por país (dashboard admin futuro)
CREATE INDEX IF NOT EXISTS idx_reservations_country
  ON public.reservations (event_country);

COMMENT ON COLUMN public.reservations.event_city    IS 'Ciudad del evento (capturado en booking)';
COMMENT ON COLUMN public.reservations.event_state   IS 'Estado del evento';
COMMENT ON COLUMN public.reservations.event_country IS 'País del evento: MX = México, US = Estados Unidos';
COMMENT ON COLUMN public.reservations.event_lat     IS 'Latitud del lugar del evento (para cálculo de traslado)';
COMMENT ON COLUMN public.reservations.event_lng     IS 'Longitud del lugar del evento';

SELECT '238_logistics_fields.sql: campos logísticos agregados ✅' AS status;
