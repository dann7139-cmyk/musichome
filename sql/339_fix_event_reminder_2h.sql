-- ============================================================
-- sql/339_fix_event_reminder_2h.sql
--
-- PROBLEMA CONFIRMADO (cron.job_run_details):
--   "invalid input syntax for type timestamp with time zone:
--    2026-05-22T20:00:00:00-06:00"
--
-- CAUSA:
--   La versión VIVA en Supabase de send_event_reminders_2h usa
--   `event_time::text` sin LEFT(5), produciendo:
--     event_date||'T'||'20:00:00'||':00-06:00' = '…T20:00:00:00-06:00'
--   La versión del archivo 243 (con LEFT 5) nunca se aplicó, o fue
--   sobreescrita por otra versión.
--   Una sola fila con este formato tumba todo el batch (el CAST está
--   en el WHERE del FOR loop, no hay EXCEPTION por fila).
--
-- FIX:
--   1. Mover el filtro de ventana temporal FUERA del WHERE (solo filtra
--      por event_date, no por event_time) → el FOR loop escanea menos filas.
--   2. Parsear la timestamp POR FILA dentro de un bloque BEGIN/EXCEPTION.
--   3. Usar AT TIME ZONE 'America/Mexico_City' en lugar de ':00-06:00'
--      hardcodeado → sobrevive horario de verano (UTC-5 vs UTC-6).
--   4. Filas inválidas: RAISE WARNING (aparece en cron.job_run_details)
--      y CONTINUE al siguiente registro.
-- ============================================================


-- ══════════════════════════════════════════════════════════════
-- PASO 0 — DIAGNÓSTICO (ejecuta este SELECT ANTES de correr el fix)
--   Muestra todas las reservas activas con su timestamp en los dos
--   formatos (old = sin LEFT 5, new = con LEFT 5) para que puedas
--   ver exactamente cuáles filas habrían fallado.
-- ══════════════════════════════════════════════════════════════
/*
SELECT
  r.id,
  r.event_date,
  r.event_time,
  r.event_time::text                                                            AS time_raw,
  length(r.event_time::text)                                                    AS time_raw_len,
  -- Formato que produce la versión ROTA (sin LEFT 5):
  r.event_date::text || 'T' || r.event_time::text        || ':00-06:00'        AS ts_malformed,
  -- Formato que produce la versión CORREGIDA (con LEFT 5):
  r.event_date::text || 'T' || LEFT(r.event_time::text, 5) || ':00-06:00'     AS ts_fixed
FROM  public.reservations r
WHERE r.status IN ('confirmed', 'pending_payment', 'accepted')
  AND r.event_time IS NOT NULL
  AND r.event_started_at IS NULL
ORDER BY r.event_date, r.event_time;
*/

-- Para ver SOLO las filas que habrían causado el error
-- (aquellas cuyo event_time tiene más de 5 caracteres en la parte HH:MM):
/*
SELECT
  r.id,
  r.event_date,
  r.event_time,
  r.event_time::text AS time_raw,
  length(r.event_time::text) AS time_raw_len,
  r.event_date::text || 'T' || r.event_time::text || ':00-06:00' AS ts_que_falla
FROM  public.reservations r
WHERE r.status IN ('confirmed', 'pending_payment', 'accepted')
  AND r.event_time IS NOT NULL
  AND r.event_started_at IS NULL
  AND length(r.event_time::text) > 5   -- TIME normal es 'HH:MM:SS' (8 chars);
                                        -- la versión sin LEFT 5 concatena todo
ORDER BY r.event_date;
*/


-- ══════════════════════════════════════════════════════════════
-- PASO 1 — Reescribir send_event_reminders_2h con resiliencia
-- ══════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.send_event_reminders_2h()
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_res        RECORD;
  v_member     RECORD;
  v_event_ts   TIMESTAMPTZ;
  v_bad_rows   INT := 0;
  v_sent_rows  INT := 0;
BEGIN
  -- Pre-filtro BARATO: solo reservas cuyo event_date sea hoy o mañana.
  -- El filtro preciso de ventana horaria se hace POR FILA dentro del loop,
  -- dentro de un bloque de excepción → una fila mala no detiene el batch.
  FOR v_res IN
    SELECT
      r.id,
      r.client_id,
      r.group_id,
      r.event_date,
      r.event_time,
      g.owner_id,
      g.name AS group_name
    FROM  public.reservations r
    JOIN  public.groups       g ON g.id = r.group_id
    WHERE r.status            = 'confirmed'
      AND r.event_started_at  IS NULL
      AND r.event_ended_at    IS NULL
      AND r.event_time        IS NOT NULL
      -- Pre-filtro por fecha (barato, sin cast de hora)
      AND r.event_date BETWEEN CURRENT_DATE AND CURRENT_DATE + 1
      -- Idempotencia: omitir si ya se envió el recordatorio
      AND NOT EXISTS (
        SELECT 1
        FROM   public.notifications n
        WHERE  n.data->>'reservation_id' = r.id::text
          AND  n.type = 'event_reminder_2h'
        LIMIT  1
      )
  LOOP

    -- ── Parsear timestamp por fila (resiliente) ───────────────
    BEGIN
      -- LEFT(5) → 'HH:MM' — descarta segundos y cualquier sufijo corrupto.
      -- AT TIME ZONE dinámico → correcto tanto en UTC-6 (invierno) como UTC-5 (verano).
      v_event_ts := (
        v_res.event_date::text
        || 'T'
        || LEFT(v_res.event_time::text, 5)
        || ':00'
      )::TIMESTAMP AT TIME ZONE 'America/Mexico_City';

    EXCEPTION WHEN OTHERS THEN
      v_bad_rows := v_bad_rows + 1;
      RAISE WARNING
        '[event-reminder-2h] Reserva % tiene fecha/hora inválida y será omitida. '
        'event_date=%, event_time=%, error=%',
        v_res.id, v_res.event_date, v_res.event_time, SQLERRM;
      CONTINUE;  -- Salta esta fila, sigue con las demás
    END;

    -- ── Filtrar ventana horaria precisa ───────────────────────
    -- Ventana [+110 min, +130 min] — con cron cada 15 min siempre cae al menos 1 disparo
    IF v_event_ts < NOW() + INTERVAL '110 minutes'
    OR v_event_ts > NOW() + INTERVAL '130 minutes' THEN
      CONTINUE;
    END IF;

    -- ── Notificar al cliente ──────────────────────────────────
    IF v_res.client_id IS NOT NULL THEN
      INSERT INTO public.notifications (user_id, type, title, body, data)
      VALUES (
        v_res.client_id,
        'event_reminder_2h',
        '🎵 Tu evento comienza en 2 horas',
        'Tu grupo estará llegando pronto. Asegúrate de que el lugar esté listo.',
        jsonb_build_object('reservation_id', v_res.id, 'screen', 'LiveEvent')
      );
    END IF;

    -- ── Notificar al owner del grupo ──────────────────────────
    IF v_res.owner_id IS NOT NULL THEN
      INSERT INTO public.notifications (user_id, type, title, body, data)
      VALUES (
        v_res.owner_id,
        'event_reminder_2h',
        '⏰ Evento en 2 horas — salgan con tiempo',
        'Recuerden llegar antes del inicio para preparar sonido y logística.',
        jsonb_build_object('reservation_id', v_res.id, 'screen', 'LiveEvent')
      );
    END IF;

    -- ── Notificar a integrantes aceptados (excepto owner) ─────
    FOR v_member IN
      SELECT DISTINCT ji.invited_user_id AS user_id
      FROM   public.job_invitations ji
      WHERE  ji.group_id         = v_res.group_id
        AND  ji.status           = 'accepted'
        AND  ji.invited_user_id != v_res.owner_id
    LOOP
      INSERT INTO public.notifications (user_id, type, title, body, data)
      VALUES (
        v_member.user_id,
        'event_reminder_2h',
        '⏰ Evento en 2 horas — salgan con tiempo',
        'Recuerden llegar antes del inicio para preparar sonido y logística.',
        jsonb_build_object('reservation_id', v_res.id, 'screen', 'LiveEvent')
      );
    END LOOP;

    v_sent_rows := v_sent_rows + 1;

  END LOOP;

  IF v_bad_rows > 0 THEN
    RAISE WARNING '[event-reminder-2h] % fila(s) con fecha inválida omitidas; % notificación(es) enviada(s).',
      v_bad_rows, v_sent_rows;
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION public.send_event_reminders_2h() TO service_role;


-- ══════════════════════════════════════════════════════════════
-- PASO 2 — Re-registrar el cron (por si se desconfiguró)
-- ══════════════════════════════════════════════════════════════
DO $$ BEGIN
  PERFORM cron.unschedule('event-reminder-2h');
EXCEPTION WHEN OTHERS THEN NULL;
END; $$;

SELECT cron.schedule(
  'event-reminder-2h',
  '*/15 * * * *',
  $$SELECT public.send_event_reminders_2h();$$
);


-- ── Verificación ──────────────────────────────────────────────────────────────
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'event-reminder-2h') THEN
    RAISE NOTICE '[339] Cron event-reminder-2h re-registrado ✅';
    RAISE NOTICE '[339] Cambios: LEFT(5) en event_time, AT TIME ZONE dinámico, excepción por fila ✅';
  ELSE
    RAISE WARNING '[339] ALERTA: cron event-reminder-2h NO encontrado — verifica pg_cron';
  END IF;
END;
$$;

SELECT '339_fix_event_reminder_2h.sql ejecutado ✅' AS status;
