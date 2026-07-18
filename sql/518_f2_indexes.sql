-- ============================================================
-- sql/518_f2_indexes.sql — F2.1: ÍNDICES OBLIGATORIOS (v2)
-- (Ajuste obligatorio #2 de la auditoría crítica, 2026-07-19)
--
-- SOLO crea 2 índices. No toca datos, RPCs, webhooks ni frontend.
--
-- v2: SIN "CONCURRENTLY" — el SQL editor de Supabase envuelve todo
-- en una transacción y CONCURRENTLY no puede correr dentro de una
-- (error 25001). Con el volumen actual el build normal tarda
-- milisegundos; el lock es imperceptible. 📌 Nota a futuro: cuando
-- la tabla tenga millones de filas, los índices nuevos se crean con
-- CONCURRENTLY desde psql/CLI (conexión directa), no desde el editor.
-- ============================================================

BEGIN;

-- ── Índice 1: reservas por grupo + fecha ─────────────────────
-- Acelera: count_events_local_day (límite diario), date_taken
-- legado, get_group_busy_days, y vecinos anterior/siguiente de F2.
-- NO parcial a propósito: el conteo del límite incluye 'completed'
-- y un predicado con función sería una trampa si la lista cambia.
CREATE INDEX IF NOT EXISTS idx_res_group_event_date
  ON public.reservations (group_id, event_date);

-- ── Índice 2: extras por reserva (FK sin índice) ─────────────
-- Acelera el SUM(hours_added) del trigger de rango (corre en cada
-- update de reserva) y los joins de extras en timer/reportes.
CREATE INDEX IF NOT EXISTS idx_extra_hours_reservation
  ON public.extra_hours (reservation_id);

COMMIT;

-- ── VERIFICACIÓN ──────────────────────────────────────────────────────────────
SELECT indexname, indexdef
FROM pg_indexes
WHERE indexname IN ('idx_res_group_event_date', 'idx_extra_hours_reservation');
-- Esperado: 2 filas

SELECT '518_f2_indexes.sql ejecutado ✅' AS status;

-- ── ROLLBACK EXACTO (solo si decides quitarlos) ──────────────
-- DROP INDEX IF EXISTS public.idx_res_group_event_date;
-- DROP INDEX IF EXISTS public.idx_extra_hours_reservation;
