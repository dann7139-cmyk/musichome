-- ============================================================
-- sql/437b_wave_retry_busy_groups.sql
-- Fix de la revisión sobre sql/437: los grupos saltados por el
-- toggle (availability <> 'available') se marcaban en
-- notified_group_ids ANTES de los guards, quedando excluidos de
-- TODAS las olas futuras de esa solicitud — un grupo "busy" esta
-- noche jamás se enteraba del evento del próximo mes.
--
-- Matiz correcto por caso:
--   · ya despachado (exprés)   → SÍ marcar (ya recibió "⚡ para ti")
--   · ya notificado (dedupe)   → SÍ marcar (ya sabe de la solicitud)
--   · toggle apagado/ocupado   → NO marcar (reintentarlo en olas
--     siguientes cuando vuelva a estar disponible)
--
-- Redefinición COMPLETA (reemplaza a la de 437; mismo functiondef
-- base de prod pegado por el usuario 2026-07-05).
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

  -- Copy según el tipo real de la solicitud (is_express de sql/217).
  -- Vía jsonb: tolera boolean/texto e incluso que la columna no exista.
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
    -- [437b] Toggle apagado/ocupado → saltar SIN marcar: las olas
    -- siguientes lo reintentan cuando vuelva a 'available'
    CONTINUE WHEN EXISTS (
      SELECT 1 FROM public.groups g
      WHERE g.id = v_row.group_id
        AND COALESCE(g.availability, 'available') <> 'available'
    );

    -- De aquí en adelante el grupo YA SABE de la solicitud por otra vía
    -- (o va a saber ahora) → marcar como procesado
    v_new_ids := v_new_ids || v_row.group_id;

    -- El dispatch exprés ya le mandó "⚡ Solicitud Express para ti"
    CONTINUE WHEN EXISTS (
      SELECT 1 FROM public.express_dispatches ed
      WHERE ed.request_id = p_request_id
        AND ed.group_id   = v_row.group_id
    );

    -- Dedupe: máx 1 notificación por usuario por solicitud
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
-- V1: el guard de toggle va ANTES del marcado (los busy NO se marcan) y los
--     demás candados siguen presentes
SELECT
  POSITION('COALESCE(g.availability' IN routine_definition)
    < POSITION('v_new_ids := v_new_ids' IN routine_definition) AS toggle_antes_de_marcar,
  routine_definition LIKE '%express_dispatches%'                    AS salta_ya_despachados,
  routine_definition LIKE '%n.data->>''request_id''%'               AS dedupe_por_usuario,
  routine_definition LIKE '%Nueva solicitud programada disponible%' AS copy_programada
FROM information_schema.routines
WHERE routine_schema = 'public' AND routine_name = '_notify_matching_wave';
-- Esperado: true | true | true | true

SELECT '437b_wave_retry_busy_groups.sql ejecutado ✅' AS status;
