-- ============================================================
-- sql/518_f2_indexes.sql — F2.1: ÍNDICES OBLIGATORIOS
-- (Ajuste obligatorio #2 de la auditoría crítica, 2026-07-19)
--
-- SOLO crea 2 índices. No toca datos, RPCs, webhooks ni frontend.
--
-- ⚠️ SIN transacción a propósito: CREATE INDEX CONCURRENTLY no
--    puede correr dentro de BEGIN/COMMIT. Cada índice se construye
--    SIN bloquear escrituras de producción (lecturas y reservas
--    siguen fluyendo mientras se crea).
--
-- Decisión de diseño (desviación explicada): el índice 1 NO es
-- parcial. Motivo: (a) el conteo del límite diario filtra por
-- estados_que_cuentan_limite() (incluye 'completed'), así que un
-- parcial de solo-ocupantes no le serviría; (b) un predicado
-- parcial que llama una función es una trampa a futuro — si la
-- lista de estados cambia, el índice quedaría desalineado en
-- silencio. Un btree simple (group_id, event_date) sirve a TODOS
-- los consumidores y sigue siendo diminuto.
-- ============================================================

-- ── Índice 1: reservas por grupo + fecha ─────────────────────
-- Acelera: count_events_local_day (límite diario), date_taken
-- legado, get_group_busy_days, vecinos anterior/siguiente de F2.
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_res_group_event_date
  ON public.reservations (group_id, event_date);

-- ── Índice 2: extras por reserva ─────────────────────────────
-- Acelera: el SUM(hours_added) del trigger de rango (corre en cada
-- update de reserva) y los joins de extras en timer/reportes.
-- Es la FK sin índice detectada en la auditoría (Postgres no
-- indexa FKs automáticamente).
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_extra_hours_reservation
  ON public.extra_hours (reservation_id);

-- ── VERIFICACIÓN ──────────────────────────────────────────────────────────────
SELECT indexname, indexdef
FROM pg_indexes
WHERE indexname IN ('idx_res_group_event_date', 'idx_extra_hours_reservation');
-- Esperado: 2 filas

-- Salud del build concurrente (si una fila sale aquí, el build
-- quedó INVÁLIDO y hay que rehacerlo — ver rollback):
SELECT c.relname AS indice_invalido
FROM pg_class c
JOIN pg_index i ON i.indexrelid = c.oid
WHERE c.relname IN ('idx_res_group_event_date', 'idx_extra_hours_reservation')
  AND NOT i.indisvalid;
-- Esperado: 0 filas

SELECT '518_f2_indexes.sql ejecutado ✅' AS status;

-- ── ROLLBACK EXACTO (solo si decides quitarlos) ──────────────
-- DROP INDEX CONCURRENTLY IF EXISTS public.idx_res_group_event_date;
-- DROP INDEX CONCURRENTLY IF EXISTS public.idx_extra_hours_reservation;
-- (Si la verificación de "inválido" regresó filas: DROP del inválido
--  y volver a correr este archivo — CONCURRENTLY interrumpido deja
--  el índice marcado inválido, nunca corrupto.)
