-- ============================================================
-- sql/479_finish_guard_and_noshow_cron.sql
-- 🔒 Auditoría 2026-07-12 — 3 fixes de servidor:
--
--  1. complete_event v2: el evento SOLO termina cuando se cumple el
--     tiempo (contratado + horas extra). Nadie lo finaliza a mano:
--     el botón "Finalizar evento" fue retirado de la app y este guard
--     rechaza cualquier llamada antes de tiempo (tolerancia 10 min).
--     Antes un grupo podía finalizar al minuto 1 y liberar el 100%.
--  2. mark_abandoned_reservations v3 (no-shows):
--     a) incluye status 'accepted' — las reservas pagadas de la app
--        viven en 'accepted', el filtro solo-'confirmed' hacía que
--        NUNCA se detectara un no-show (mismo bug que sql/472).
--     b) notifica a los admins por cada no-show detectado (antes era
--        silencioso — la cola se llenaba sin que nadie se enterara).
--  3. cron.schedule para mark_abandoned_reservations (*/30 min) —
--     la función existía desde sql/383 pero NUNCA fue agendada.
--
-- NO toca: liberaciones, wallet, GPS, strikes, reembolsos.
-- ============================================================

BEGIN;

-- ────────────────────────────────────────────────────────────
-- 1) complete_event v2 — guard de finalización temprana
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION complete_event(
  p_reservation_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_id   UUID := auth.uid();
  v_res         RECORD;
  v_duration    INT;
  v_required    INT;   -- minutos que DEBE durar: contratados + extras (75 min c/u)
  v_extras      NUMERIC := 0;
BEGIN
  IF v_caller_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unauthorized: sesión requerida');
  END IF;

  SELECT r.status, r.event_started_at, r.hours_count, r.folio, r.group_id,
         q.duration_hours AS quote_hours, g.owner_id, g.name AS gname
  INTO   v_res
  FROM   reservations r
  JOIN   groups g ON g.id = r.group_id
  LEFT   JOIN quotes q ON q.id = r.quote_id
  WHERE  r.id = p_reservation_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Reserva no encontrada');
  END IF;
  IF v_res.owner_id <> v_caller_id THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unauthorized: solo el grupo puede finalizar el evento');
  END IF;

  -- Idempotente
  IF v_res.status = 'completed' THEN
    RETURN jsonb_build_object('ok', true, 'completed_at', NOW(), 'note', 'already_completed');
  END IF;

  -- 🔒 Guard: no se puede finalizar un evento que no ha iniciado
  IF v_res.event_started_at IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'El evento aún no ha iniciado.');
  END IF;

  -- Horas extra aceptadas/pagadas extienden la duración (75 min por hora:
  -- 60 de música + 15 de descanso — mismo cálculo que el temporizador)
  SELECT COALESCE(SUM(hours_added), 0) INTO v_extras
  FROM extra_hours
  WHERE reservation_id = p_reservation_id
    AND status IN ('accepted', 'paid');

  v_duration := GREATEST(0, EXTRACT(EPOCH FROM (NOW() - v_res.event_started_at))::INT / 60);
  v_required := GREATEST(60, COALESCE(v_res.hours_count, v_res.quote_hours, 3)::INT * 60)
                + (v_extras * 75)::INT;

  -- 🔒 Guard: el evento termina SOLO cuando el tiempo se cumple.
  -- Nadie (ni grupo ni cliente) finaliza a mano — la app llama esto en el
  -- auto-stop del temporizador. Tolerancia de 10 min por desfase de relojes.
  IF v_duration < (v_required - 10) THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', format('El evento aún no termina: van %s min de %s. El evento finaliza automáticamente al cumplirse el tiempo.',
                      v_duration, v_required)
    );
  END IF;

  UPDATE reservations
  SET status                   = 'completed',
      event_ended_at           = NOW(),
      actual_duration_minutes  = COALESCE(actual_duration_minutes, v_duration),
      updated_at               = NOW()
  WHERE id = p_reservation_id;

  RETURN jsonb_build_object(
    'ok',           true,
    'completed_at', NOW(),
    'duration_min', v_duration
  );
END;
$$;

GRANT EXECUTE ON FUNCTION complete_event(UUID) TO authenticated;

-- ────────────────────────────────────────────────────────────
-- 2) mark_abandoned_reservations v3 — incluye 'accepted' + avisa a admins
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.mark_abandoned_reservations()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_count INTEGER := 0;
  v_row   RECORD;
  v_admin UUID;
BEGIN
  FOR v_row IN
    WITH marked AS (
      UPDATE reservations AS r
      SET
        status            = 'cancelled',
        cancelled_at      = NOW(),
        cancelled_by      = NULL,           -- NULL = sistema
        cancel_reason     = 'no_show_grupo',
        cancellation_type = 'system_auto',
        payout_status     = 'blocked'
      FROM (
        SELECT
          res.id,
          (
            (res.event_date + COALESCE(res.event_time, '23:59:00'::TIME))
              AT TIME ZONE 'America/Mexico_City'
            + COALESCE(res.hours_count, qte.duration_hours, 4) * INTERVAL '1 hour'
            + INTERVAL '30 minutes'
          ) AS ends_at
        FROM reservations res
        LEFT JOIN quotes qte ON qte.id = res.quote_id
        -- [479] 'accepted' incluido: las reservas pagadas viven ahí
        WHERE res.status            IN ('confirmed', 'accepted')
          AND res.payment_status    IN ('paid', 'deposit_paid', 'fully_paid')
          AND res.group_arrived_at  IS NULL
      ) sub
      WHERE r.id = sub.id
        AND sub.ends_at < NOW()
      RETURNING r.id, r.folio, r.group_id, r.event_date
    )
    SELECT m.*, g.name AS gname FROM marked m LEFT JOIN groups g ON g.id = m.group_id
  LOOP
    v_count := v_count + 1;
    -- [479] Avisar a los admins — antes la detección era silenciosa
    FOR v_admin IN SELECT id FROM profiles WHERE role = 'admin' LOOP
      INSERT INTO notifications (user_id, type, title, body, data)
      VALUES (v_admin, 'admin',
        '🚨 No-show detectado',
        format('%s no llegó a su evento del %s (folio %s). El pago quedó bloqueado — resuélvelo en la cola de no-shows.',
               COALESCE(v_row.gname, 'Un grupo'), to_char(v_row.event_date, 'DD/MM'),
               COALESCE(v_row.folio, v_row.id::text)),
        jsonb_build_object('reservation_id', v_row.id, 'screen', 'AdminHome'));
    END LOOP;
  END LOOP;

  RETURN v_count;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.mark_abandoned_reservations() TO authenticated;

COMMIT;

-- ────────────────────────────────────────────────────────────
-- 3) Cron cada 30 min — la función nunca había sido agendada
-- ────────────────────────────────────────────────────────────
DO $$ BEGIN
  PERFORM cron.unschedule('mark-abandoned-reservations');
EXCEPTION WHEN OTHERS THEN NULL;
END; $$;

SELECT cron.schedule(
  'mark-abandoned-reservations',
  '*/30 * * * *',
  $$SELECT public.mark_abandoned_reservations();$$
);

-- ── VERIFICACIÓN ──────────────────────────────────────────────────────────────
SELECT prosrc LIKE '%aún no termina%' AS guard_tiempo_completo,
       prosrc LIKE '%extra_hours%'    AS considera_extras
FROM pg_proc WHERE proname = 'complete_event';
-- Esperado: true | true

SELECT prosrc LIKE '%''accepted''%' AS detecta_accepted,
       prosrc LIKE '%No-show detectado%' AS avisa_admin
FROM pg_proc WHERE proname = 'mark_abandoned_reservations';
-- Esperado: true | true

SELECT jobname, schedule FROM cron.job WHERE jobname = 'mark-abandoned-reservations';
-- Esperado: 1 fila, */30 * * * *

SELECT '479_finish_guard_and_noshow_cron.sql ejecutado ✅' AS status;
