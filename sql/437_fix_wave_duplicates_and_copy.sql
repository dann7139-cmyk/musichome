-- ============================================================
-- sql/437_fix_wave_duplicates_and_copy.sql
-- Arregla las notificaciones de olas de matching (_notify_matching_wave):
--
--   BUG 1 (duplicado con el dispatch): al crear una exprés, el trigger
--   del dispatch ya manda push "⚡ Solicitud Express para ti" al grupo,
--   y la ola de matching le insertaba ADEMÁS "⚡ Nueva solicitud express
--   disponible" → dos notificaciones simultáneas por la misma solicitud.
--   FIX: la ola se salta a los grupos que ya tienen express_dispatch.
--
--   BUG 2 (filas idénticas dobles): sin dedupe, un mismo dueño podía
--   recibir la misma notificación 2+ veces (p.ej. dos grupos suyos en el
--   mismo lote). FIX: máx 1 notificación por usuario por solicitud.
--
--   BUG 3 (copy engañoso — cierra el P3 pendiente): las solicitudes
--   PROGRAMADAS decían "⚡ Nueva solicitud express disponible". FIX:
--   ahora dicen "📅 Nueva solicitud programada disponible" (el routing
--   del frontend ya las abre en las tarjetas 📅 de OpenRequests).
--
--   EXTRA: respeta el toggle exprés del grupo (availability), alineado
--   con la decisión de producto de sql/432b, y elimina la doble llamada
--   a get_best_matching_groups (el estado se arma con lo realmente
--   procesado en el loop).
--
-- Redefinición COMPLETA construida sobre el functiondef REAL de prod
-- (pegado por el usuario 2026-07-05) — no sobre el archivo del repo.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public._notify_matching_wave(p_request_id uuid, p_wave integer)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_req        RECORD;
  v_state      RECORD;
  v_row        RECORD;
  v_count      INT := 0;
  v_batch_size INT;
  v_title      TEXT;
  v_body       TEXT;
  v_is_express BOOLEAN;
  v_new_ids    UUID[] := '{}';
BEGIN
  SELECT * INTO v_req
  FROM public.event_requests
  WHERE id = p_request_id AND status = 'open';

  IF NOT FOUND THEN RETURN 0; END IF;

  SELECT * INTO v_state
  FROM public.request_matching_state
  WHERE request_id = p_request_id;

  -- Tamaño de lote: 3 en la ola 1, 5 en olas siguientes
  v_batch_size := CASE WHEN p_wave = 1 THEN 3 ELSE 5 END;

  -- [437] Copy según el tipo real de la solicitud (is_express de sql/217).
  -- Vía jsonb: tolera boolean/texto e incluso que la columna no exista
  -- (en ese caso NULL → se trata como programada).
  v_is_express := COALESCE(to_jsonb(v_req)->>'is_express', '') IN ('true', 't');

  IF v_is_express THEN
    v_title := '⚡ Nueva solicitud express disponible';
    v_body  := 'Evento de ' || v_req.hours || 'h el ' ||
               TO_CHAR(v_req.event_date, 'DD Mon') ||
               ' en ' || COALESCE(v_req.location_city, 'tu zona') ||
               '. ¡Sé el primero en aceptar!';
  ELSE
    v_title := '📅 Nueva solicitud programada disponible';
    v_body  := 'Evento de ' || v_req.hours || 'h el ' ||
               TO_CHAR(v_req.event_date, 'DD Mon') ||
               ' en ' || COALESCE(v_req.location_city, 'tu zona') ||
               '. Revisa los detalles y cotiza.';
  END IF;

  FOR v_row IN
    SELECT * FROM public.get_best_matching_groups(
      p_request_id,
      v_batch_size,
      0,
      COALESCE(v_state.notified_group_ids, '{}')
    )
  LOOP
    -- Marcar como procesado SIEMPRE (aunque se salte la notificación),
    -- para que las olas siguientes no lo reintenten
    v_new_ids := v_new_ids || v_row.group_id;

    -- [437] El dispatch exprés ya le mandó "⚡ Solicitud Express para ti"
    CONTINUE WHEN EXISTS (
      SELECT 1 FROM public.express_dispatches ed
      WHERE ed.request_id = p_request_id
        AND ed.group_id   = v_row.group_id
    );

    -- [437] Toggle exprés del grupo apagado/ocupado → no molestar
    CONTINUE WHEN EXISTS (
      SELECT 1 FROM public.groups g
      WHERE g.id = v_row.group_id
        AND COALESCE(g.availability, 'available') <> 'available'
    );

    -- [437] Dedupe: máx 1 notificación por usuario por solicitud
    CONTINUE WHEN EXISTS (
      SELECT 1 FROM public.notifications n
      WHERE n.user_id = v_row.owner_id
        AND n.data->>'request_id' = p_request_id::TEXT
    );

    INSERT INTO public.notifications (user_id, type, title, body, data)
    VALUES (
      v_row.owner_id,
      'booking',
      v_title,
      v_body,
      jsonb_build_object(
        'request_id',      p_request_id,
        'screen',          'OpenRequests',
        'matching_score',  ROUND(v_row.matching_score::NUMERIC, 0),
        'distance_km',     v_row.distance_km,
        'wave',            p_wave
      )
    );
    v_count := v_count + 1;
  END LOOP;

  -- Actualizar estado de matching con lo realmente procesado en el loop
  -- (antes se llamaba get_best_matching_groups una 2ª vez — podía divergir)
  UPDATE public.request_matching_state
  SET current_wave       = p_wave,
      last_wave_sent_at  = NOW(),
      notified_group_ids = COALESCE(notified_group_ids, '{}') ||
                           COALESCE(v_new_ids, '{}'),
      status_message     = CASE
        WHEN p_wave = 1 THEN 'Notificando a los mejores grupos para tu evento...'
        WHEN p_wave = 2 THEN 'Encontrando el mejor grupo para tu evento...'
        ELSE                 'Ampliando la búsqueda de grupos disponibles...'
      END
  WHERE request_id = p_request_id;

  RETURN v_count;
END;
$function$;

COMMIT;

-- ── Verificaciones ────────────────────────────────────────────────────────────
-- V1: los tres candados están en la definición
SELECT
  routine_definition LIKE '%express_dispatches%'                    AS salta_ya_despachados,
  routine_definition LIKE '%COALESCE(g.availability%'               AS respeta_toggle,
  routine_definition LIKE '%n.data->>''request_id''%'               AS dedupe_por_usuario,
  routine_definition LIKE '%Nueva solicitud programada disponible%' AS copy_programada
FROM information_schema.routines
WHERE routine_schema = 'public' AND routine_name = '_notify_matching_wave';
-- Esperado: true | true | true | true

-- V2 (funcional): crea una solicitud exprés de prueba y verifica que llegue
-- UNA sola notificación ("⚡ para ti" del dispatch, sin la de "disponible"):
-- SELECT type, title, COUNT(*) FROM notifications
-- WHERE created_at > NOW() - INTERVAL '10 minutes' AND title ILIKE '%express%'
-- GROUP BY type, title;

SELECT '437_fix_wave_duplicates_and_copy.sql ejecutado ✅' AS status;
