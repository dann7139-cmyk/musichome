-- ════════════════════════════════════════════════════════════════════
-- sql/413_fix_express_notifications_routing.sql
--
-- PROBLEMA:
--   Las notificaciones follow-up del grupo (sql/103):
--     +2 min "⏰ Tienes una solicitud pendiente"
--     +5 min "🔥 ¡Esta solicitud podría irse a otro grupo!"
--   tienen type='booking' y screen='OpenRequests'.
--   AppNavigator no las enrutaba a ningún lado → el grupo no llegaba
--   al dashboard con el carousel Uber-style.
--
--   Además, send_express_followups() solo busca notificaciones de
--   wave (type='booking'). Pero después del dispatch express, el
--   grupo también puede haber recibido type='express_dispatch'.
--   Esta versión amplía la búsqueda para incluir ambos tipos.
--
-- FIX (código ya aplicado en navigation/AppNavigator.tsx):
--   screen === 'OpenRequests' + role === 'group' → GroupHome + reviveAll
--
-- FIX SQL (este archivo):
--   1. send_express_followups — busca también express_dispatch
--      para enviar follow-ups a grupos que solo recibieron esa push.
--   2. Retroactivo: crear dispatches para solicitudes open/en_negociacion
--      recientes que no tienen dispatches todavía (caso "lala").
--
-- Seguro de correr múltiples veces (idempotente).
-- ════════════════════════════════════════════════════════════════════

-- ── 1. Ampliar send_express_followups para incluir express_dispatch ───────────
CREATE OR REPLACE FUNCTION public.send_express_followups()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_notif   RECORD;
  v_count   INT := 0;
BEGIN

  -- ── Follow-up nivel 1: +2 minutos ─────────────────────────────────────────
  -- Busca notificaciones booking o express_dispatch sin followup_level
  -- y con solicitud aún activa (open o en_negociacion).
  FOR v_notif IN
    SELECT DISTINCT ON (n.user_id, req_id)
      n.user_id,
      COALESCE(n.data->>'request_id', n.data->>'event_request_id') AS req_id
    FROM public.notifications n
    JOIN public.event_requests er
      ON er.id = COALESCE(n.data->>'request_id', n.data->>'event_request_id')::UUID
    WHERE n.type IN ('booking', 'express_dispatch')
      AND (n.data->>'followup_level') IS NULL
      AND n.created_at BETWEEN NOW() - INTERVAL '4 minutes'
                           AND NOW() - INTERVAL '2 minutes'
      AND er.status IN ('open', 'en_negociacion')
      AND NOT EXISTS (
        SELECT 1 FROM public.notifications n2
        WHERE n2.user_id = n.user_id
          AND COALESCE(n2.data->>'request_id', n2.data->>'event_request_id') =
              COALESCE(n.data->>'request_id', n.data->>'event_request_id')
          AND n2.data->>'followup_level' = '1'
      )
    ORDER BY n.user_id, req_id, n.created_at
  LOOP
    INSERT INTO public.notifications (user_id, type, title, body, data)
    VALUES (
      v_notif.user_id,
      'booking',
      '⏰ Tienes una solicitud pendiente',
      'Tienes una solicitud disponible cerca de ti. ¡Revísala antes de que otro grupo la tome!',
      jsonb_build_object(
        'request_id',     v_notif.req_id,
        'screen',         'OpenRequests',
        'followup_level', '1'
      )
    );
    v_count := v_count + 1;
  END LOOP;

  -- ── Follow-up nivel 2: +5 minutos ─────────────────────────────────────────
  FOR v_notif IN
    SELECT DISTINCT ON (n.user_id, req_id)
      n.user_id,
      COALESCE(n.data->>'request_id', n.data->>'event_request_id') AS req_id
    FROM public.notifications n
    JOIN public.event_requests er
      ON er.id = COALESCE(n.data->>'request_id', n.data->>'event_request_id')::UUID
    WHERE n.type IN ('booking', 'express_dispatch')
      AND (n.data->>'followup_level') IS NULL
      AND n.created_at BETWEEN NOW() - INTERVAL '8 minutes'
                           AND NOW() - INTERVAL '5 minutes'
      AND er.status IN ('open', 'en_negociacion')
      AND NOT EXISTS (
        SELECT 1 FROM public.notifications n2
        WHERE n2.user_id = n.user_id
          AND COALESCE(n2.data->>'request_id', n2.data->>'event_request_id') =
              COALESCE(n.data->>'request_id', n.data->>'event_request_id')
          AND n2.data->>'followup_level' = '2'
      )
    ORDER BY n.user_id, req_id, n.created_at
  LOOP
    INSERT INTO public.notifications (user_id, type, title, body, data)
    VALUES (
      v_notif.user_id,
      'booking',
      '🔥 ¡Esta solicitud podría irse a otro grupo!',
      'Esta solicitud podría asignarse a otro grupo si no respondes pronto. ¡Ábrela ahora y sé el primero!',
      jsonb_build_object(
        'request_id',     v_notif.req_id,
        'screen',         'OpenRequests',
        'followup_level', '2'
      )
    );
    v_count := v_count + 1;
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'sent', v_count);

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

-- ── 2. Retroactivo: crear dispatches para solicitudes recientes sin dispatch ───
-- Esto cubre el caso de solicitudes enviadas antes de que GuidedRequestScreen
-- llamara dispatch_express_request (ej. la solicitud de "lala").
DO $$
DECLARE
  v_req  RECORD;
  v_res  JSONB;
  v_ok   INT := 0;
BEGIN
  FOR v_req IN
    SELECT er.id, er.genre, er.location_city, er.location_estado
    FROM public.event_requests er
    WHERE er.status IN ('open', 'en_negociacion')
      AND er.created_at > NOW() - INTERVAL '24 hours'
      AND NOT EXISTS (
        SELECT 1 FROM public.express_dispatches ed
        WHERE ed.request_id = er.id
      )
    ORDER BY er.created_at DESC
  LOOP
    BEGIN
      SELECT public.dispatch_express_request(v_req.id) INTO v_res;
      IF (v_res->>'ok')::BOOLEAN THEN
        v_ok := v_ok + 1;
        RAISE NOTICE '✅ Dispatch creado para solicitud % (%)', v_req.id, v_req.genre;
      ELSE
        RAISE NOTICE '⚠️  No se pudo dispatch % — %', v_req.id, v_res->>'error';
      END IF;
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE '❌ Error en dispatch % — %', v_req.id, SQLERRM;
    END;
  END LOOP;

  RAISE NOTICE '🎉 Dispatches retroactivos creados: %', v_ok;
END;
$$;

-- ── Verificación ──────────────────────────────────────────────────────────────
SELECT
  er.id,
  er.genre,
  er.status,
  er.created_at,
  COUNT(ed.id) AS dispatches
FROM public.event_requests er
LEFT JOIN public.express_dispatches ed ON ed.request_id = er.id
WHERE er.status IN ('open', 'en_negociacion')
  AND er.created_at > NOW() - INTERVAL '24 hours'
GROUP BY er.id, er.genre, er.status, er.created_at
ORDER BY er.created_at DESC;

SELECT '413_fix_express_notifications_routing ✅' AS status;
