-- ============================================================
-- sql/347_test_event_reminder_2h.sql
--
-- Script de prueba para el cron event-reminder-2h (*/15 UTC).
--
-- PRE-REQUISITO OBLIGATORIO: sql/346 debe estar ejecutado antes
-- de este script. Sin él, el INSERT del cron falla silenciosamente
-- por la constraint notifications_type_check.
--
-- USO:
--   BLOQUE A → ejecutar ahora (crea la reserva de prueba)
--   BLOQUE B → ejecutar ~15 min después (verifica la notificación)
--   BLOQUE C → ejecutar al terminar (limpia datos)
--
-- ⚠️  Evita correr este script entre 19:00 y 22:00 hora Ciudad de México
--     (00:00-03:00 UTC). En ese rango el cálculo de event_date puede quedar
--     fuera del pre-filtro CURRENT_DATE de la función.
-- ============================================================


-- ════════════════════════════════════════════════════════════
-- BLOQUE A — PREPARACIÓN E INSERT (ejecutar ahora)
-- ════════════════════════════════════════════════════════════

-- ── A0: Verificar que sql/346 fue aplicado ────────────────────────────────────
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM   pg_constraint
    WHERE  conname   = 'notifications_type_check'
      AND  conrelid  = 'public.notifications'::regclass
      AND  pg_get_constraintdef(oid) LIKE '%event_reminder_2h%'
  ) THEN
    RAISE EXCEPTION
      E'[347] PRE-REQUISITO FALLIDO\n'
      'La constraint notifications_type_check NO incluye event_reminder_2h.\n'
      'Ejecuta sql/346_fix_notifications_constraint_and_quote_type.sql primero.';
  END IF;
  RAISE NOTICE '[347] Constraint OK — event_reminder_2h en lista ✅';
END;
$$;

-- ── A1: Ver timing antes de insertar ─────────────────────────────────────────
-- Muestra: hora actual MX, cuándo dispara el segundo próximo cron,
-- y a qué hora quedará el evento de prueba (en MX y UTC).
-- "Segundo próximo cron" = saltar uno para tener ~15 min de margen.
WITH cron2 AS (
  SELECT
    date_trunc('hour', NOW())
      + INTERVAL '1 minute'
        * ((EXTRACT(MINUTE FROM NOW())::INT / 15 + 2) * 15)
    AS fire_at
)
SELECT
  (NOW() AT TIME ZONE 'America/Mexico_City')::TIME(0)               AS ahora_mx,
  NOW()::TIME(0)                                                      AS ahora_utc,
  (fire_at AT TIME ZONE 'America/Mexico_City')::TIME(0)              AS cron_dispara_mx,
  fire_at::TIME(0)                                                    AS cron_dispara_utc,
  ((fire_at + INTERVAL '120 min')
    AT TIME ZONE 'America/Mexico_City')::TIME(0)                     AS evento_mx,
  (fire_at + INTERVAL '120 min')::TIME(0)                            AS evento_utc,
  ((fire_at + INTERVAL '120 min')
    AT TIME ZONE 'America/Mexico_City')::DATE                        AS event_date,
  ((fire_at + INTERVAL '120 min')
    AT TIME ZONE 'America/Mexico_City')::TIME(0)                     AS event_time
FROM cron2;

-- Salida esperada:
--   ahora_mx        → hora actual en Ciudad de México
--   cron_dispara_mx → cuándo corre el cron (esperar hasta esa hora)
--   event_date/time → los valores que se insertarán en la reserva

-- ── A-PRE: Encontrar un grupo sin conflicto en la fecha del test ─────────────
-- El trigger prevent_double_booking chequea group_id + event_date.
-- Necesitamos un grupo sin reserva activa en la fecha que calculará A2.
-- ⚡ Anota el group_id que vas a usar antes de correr el INSERT.
WITH target_date AS (
  SELECT (
    (
      date_trunc('hour', NOW())
        + INTERVAL '1 minute' * ((EXTRACT(MINUTE FROM NOW())::INT / 15 + 2) * 15)
        + INTERVAL '120 minutes'
    ) AT TIME ZONE 'America/Mexico_City'
  )::DATE AS fecha
)
SELECT
  g.id         AS group_id,   -- ← usa cualquiera de estos en A2
  g.name       AS group_name,
  t.fecha      AS event_date_del_test
FROM   public.groups g
CROSS  JOIN target_date t
WHERE  NOT EXISTS (
  SELECT 1
  FROM   public.reservations r
  WHERE  r.group_id   = g.id
    AND  r.event_date = t.fecha
    AND  r.status NOT IN ('cancelled', 'rejected', 'expired')
)
ORDER  BY g.created_at DESC
LIMIT  5;
-- Si devuelve 0 filas: todos los grupos tienen reserva ese día.
-- En ese caso habla con el dev — necesita Option A (usuarios ficticios via auth.users).

-- ── A2: INSERT reserva de prueba ──────────────────────────────────────────────
-- Sin placeholders — selecciona grupo y cliente automáticamente.
-- El subquery de group_id elige el primer grupo sin reserva activa en la fecha del test.
-- Si devuelve "null value in column group_id" → no hay ningún grupo libre ese día
-- (ejecuta A-PRE para confirmarlo y avisa al dev).
INSERT INTO public.reservations (
  client_id,
  group_id,
  status,
  payment_status,
  payout_status,
  event_date,
  event_time,
  total_price,
  address,
  notes
)
SELECT
  (SELECT id FROM public.profiles WHERE role = 'client' LIMIT 1),
  (
    SELECT g.id
    FROM   public.groups g
    WHERE  NOT EXISTS (
      SELECT 1
      FROM   public.reservations r
      WHERE  r.group_id   = g.id
        AND  r.event_date = (target.event_ts_mx)::DATE
        AND  r.status NOT IN ('cancelled', 'rejected', 'expired')
    )
    ORDER  BY g.created_at DESC
    LIMIT  1
  ),
  'confirmed',
  'paid',
  'held',
  (target.event_ts_mx)::DATE,
  (target.event_ts_mx)::TIME,
  1000.00,
  'Dirección de prueba — borrar después del test',
  '_TEST_event_reminder_2h'
FROM (
  SELECT (
    date_trunc('hour', NOW())
      + INTERVAL '1 minute'
        * ((EXTRACT(MINUTE FROM NOW())::INT / 15 + 2) * 15)
      + INTERVAL '120 minutes'
  ) AT TIME ZONE 'America/Mexico_City' AS event_ts_mx
) AS target
RETURNING
  id          AS reserva_test_id,   -- ← COPIA ESTE UUID PARA LOS BLOQUES B Y C
  event_date,
  event_time,
  group_id;

-- ⚡ Anota el UUID de reserva_test_id.
-- El cron buscará esta reserva en la próxima ejecución alineada.


-- ════════════════════════════════════════════════════════════
-- BLOQUE B — VERIFICACIÓN (ejecutar ~15 min después)
-- ════════════════════════════════════════════════════════════
-- Sustituye '<UUID>' por el id que devolvió BLOQUE A.

/*
SELECT
  n.id,
  n.type,
  n.title,
  n.body,
  n.created_at AT TIME ZONE 'America/Mexico_City' AS creado_mx,
  n.user_id,
  p.role
FROM   public.notifications n
JOIN   public.profiles       p ON p.id = n.user_id
WHERE  n.type = 'event_reminder_2h'
  AND  n.data->>'reservation_id' = '<UUID>'   -- ← pega el UUID aquí
ORDER  BY n.created_at DESC;
*/

-- Resultado esperado:
--   3 filas: una para client, una para el dueño del grupo, una por integrante aceptado.
--   Si 0 filas → revisar BLOQUE A0 (constraint) y logs del cron.


-- ════════════════════════════════════════════════════════════
-- BLOQUE C — CLEANUP (ejecutar al terminar)
-- ════════════════════════════════════════════════════════════
-- ⚠️  ORDEN OBLIGATORIO: primero leer (C0), luego borrar (C1).
--     Sustituye '<UUID>' con el reserva_test_id del BLOQUE A2.

/*
-- C0. LEER PRIMERO — confirma que el cron creó la notificación ANTES de borrar.
--     0 filas = el cron falló o no encontró la reserva → diagnosticar antes de limpiar.
SELECT id, type, title, created_at, user_id
FROM   public.notifications
WHERE  data->>'reservation_id' = '<UUID>'
ORDER  BY created_at;

-- C1. Solo después de leer C0 (o si ya terminaste el diagnóstico):

-- Borrar recordatorios generados por el cron
DELETE FROM public.notifications
WHERE  type = 'event_reminder_2h'
  AND  data->>'reservation_id' = '<UUID>';

-- Borrar notificación booking_received del trigger AFTER INSERT
DELETE FROM public.notifications
WHERE  type = 'booking_received'
  AND  data->>'reservation_id' = '<UUID>';

-- Borrar reserva (doble check en notes para evitar borrados accidentales)
DELETE FROM public.reservations
WHERE  id    = '<UUID>'::UUID
  AND  notes = '_TEST_event_reminder_2h';

-- C2. Verificar limpieza completa (ambas columnas deben ser 0)
SELECT
  (SELECT COUNT(*) FROM public.notifications WHERE data->>'reservation_id' = '<UUID>') AS notifs_restantes,
  (SELECT COUNT(*) FROM public.reservations  WHERE id = '<UUID>'::UUID)               AS reserva_restante;
*/

SELECT '347_test_event_reminder_2h.sql listo ✅' AS status;
