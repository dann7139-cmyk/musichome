-- ============================================================
-- sql/409_fix_upcoming_events_packages_join.sql
-- A1 · notify_upcoming_events: quitar LEFT JOIN a public.packages
--
-- Problema: la versión vigente (sql/343:131) hace LEFT JOIN
--   public.packages y selecciona p.name AS package_name, pero esa
--   columna NUNCA se usa en el cuerpo. Si la tabla packages no existe
--   en producción, la función truena completa en cada corrida del cron
--   (cada hora al :30) → ninguna notificación de 24h se envía, en
--   silencio.
--
-- ⚠️ PRE-CHECK — correr ANTES que el CREATE OR REPLACE:
--   SELECT to_regclass('public.packages');
--   · NULL      → packages NO existe: este fix es urgente, corre el resto.
--   · 'packages'→ la tabla SÍ existe: el fix sigue siendo seguro (la
--     columna no se usa), pero REPORTA antes de correr, según lo acordado.
-- ============================================================

SELECT to_regclass('public.packages') AS packages_existe;  -- ver nota arriba

CREATE OR REPLACE FUNCTION public.notify_upcoming_events()
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_res      RECORD;
  v_event_ts TIMESTAMPTZ;
BEGIN
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
    JOIN  public.groups g ON g.id = r.group_id
    WHERE r.status           = 'confirmed'
      AND r.event_started_at IS NULL
      -- Pre-filtro barato por fecha
      AND r.event_date BETWEEN CURRENT_DATE AND CURRENT_DATE + 2
      -- Idempotencia
      AND NOT EXISTS (
        SELECT 1 FROM public.notifications
        WHERE data->>'reservation_id' = r.id::text
          AND type = 'event_upcoming_24h'
      )
  LOOP

    BEGIN
      v_event_ts := (
        v_res.event_date::text || 'T' || LEFT(v_res.event_time::text, 5) || ':00'
      )::TIMESTAMP AT TIME ZONE 'America/Mexico_City';
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING '[notify_upcoming_events] Fecha inválida en reserva %', v_res.id;
      CONTINUE;
    END;

    -- Ventana: entre 23 h y 25 h antes del evento
    IF v_event_ts NOT BETWEEN NOW() + INTERVAL '23 hours' AND NOW() + INTERVAL '25 hours' THEN
      CONTINUE;
    END IF;

    -- Notificar cliente
    IF v_res.client_id IS NOT NULL THEN
      INSERT INTO public.notifications (user_id, type, title, body, data)
      VALUES (
        v_res.client_id, 'event_upcoming_24h',
        '📅 Tu evento es mañana',
        'Mañana llega ' || v_res.group_name || '. ¿Ya tienes todo listo para recibirlos?',
        jsonb_build_object('reservation_id', v_res.id, 'screen', 'ClientReservations')
      );
    END IF;

    -- Notificar grupo
    IF v_res.owner_id IS NOT NULL THEN
      INSERT INTO public.notifications (user_id, type, title, body, data)
      VALUES (
        v_res.owner_id, 'event_upcoming_24h',
        '📅 Tienes un evento mañana',
        'Recuerda confirmar hora de llegada con el cliente. Evento: ' || v_res.event_date::text,
        jsonb_build_object('reservation_id', v_res.id, 'screen', 'GroupDashboard')
      );
    END IF;

  END LOOP;
END;
$$;

GRANT EXECUTE ON FUNCTION public.notify_upcoming_events() TO service_role;

-- ── Verificación: la función ya no referencia packages ────────────────────────
SELECT routine_definition NOT LIKE '%packages%' AS sin_packages
FROM   information_schema.routines
WHERE  routine_schema = 'public'
  AND  routine_name   = 'notify_upcoming_events';
-- Esperado: true

SELECT '409_fix_upcoming_events_packages_join.sql ejecutado ✅' AS status;
