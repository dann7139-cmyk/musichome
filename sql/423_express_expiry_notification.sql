-- ============================================================
-- sql/423_express_expiry_notification.sql
-- Sección C de expire_stale_requests(): avisar al cliente cuando
-- su solicitud EXPRÉS expira por expires_at (24h, sql/371)
--
-- ANTES (sql/375:116-120): UPDATE masivo silencioso.
-- AHORA: loop FOR (mismo patrón que las secciones A y B) que expira
--   una por una y, SI la solicitud es exprés (express_window_until
--   IS NOT NULL), notifica al cliente:
--     type  = 'booking'  ← ya está en el constraint (verificado en la
--             lista vigente de sql/421) y ya tiene case en el handler
--             (NotificationsScreen: 'booking' → revive carrusel/Home
--             según rol) → cero cambios de constraint ni de frontend
--     título "⏳ Tu solicitud exprés expiró"
--     cuerpo "Ningún grupo respondió a tiempo. Puedes crear una nueva."
--     data: event_request_id, event_date, reason, screen 'Home'
--   Dedupe: NOT EXISTS por event_request_id + reason='express_expired'.
--   Las NO exprés que lleguen a C siguen expirando sin notif (fuera
--   del alcance pedido — normalmente mueren antes vía sección A, que
--   sí avisa).
--
-- Secciones A y B: copiadas BYTE A BYTE de sql/375. Nada más cambia.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.expire_stale_requests()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_expired_count   INT := 0;
  v_reverted_count  INT := 0;
  v_req             RECORD;
  v_extra           INT := 0;
BEGIN

  -- ── A. Expirar solicitudes `open` sin actividad por más de 60 min ──────────
  --      EXCLUYE requests Express (express_window_until IS NOT NULL).
  --      Los Express solo expiran vía sección C (expires_at).
  FOR v_req IN
    SELECT er.id, er.group_id, er.client_id, er.event_date
    FROM   public.event_requests er
    WHERE  er.status                = 'open'
      AND  er.updated_at            < NOW() - INTERVAL '1 hour'
      AND  er.express_window_until IS NULL          -- ← FIX: no tocar Express
  LOOP
    UPDATE public.event_requests
    SET    status = 'expired'
    WHERE  id = v_req.id;

    IF v_req.client_id IS NOT NULL THEN
      INSERT INTO public.notifications
        (user_id, type, title, body, data)
      VALUES
        (v_req.client_id,
         'booking',
         '⏳ Solicitud expirada',
         'Tu solicitud de evento no recibió respuesta a tiempo y fue cancelada automáticamente.',
         jsonb_build_object(
           'event_request_id', v_req.id,
           'event_date',       v_req.event_date,
           'screen',           'Home'
         ));
    END IF;

    IF v_req.group_id IS NOT NULL THEN
      INSERT INTO public.notifications
        (user_id, type, title, body, data)
      SELECT
        g.owner_id,
        'booking',
        '⏳ Solicitud expirada automáticamente',
        'Una solicitud sin actividad fue expirada tras 1 hora.',
        jsonb_build_object(
          'event_request_id', v_req.id,
          'event_date',       v_req.event_date,
          'screen',           'Reservations'
        )
      FROM public.groups g
      WHERE g.id = v_req.group_id;
    END IF;

    v_expired_count := v_expired_count + 1;
  END LOOP;

  -- ── B. Revertir `en_negociacion` → `open` si el cliente no respondió en 30 min
  FOR v_req IN
    SELECT er.id, er.client_id, er.event_date
    FROM   public.event_requests er
    WHERE  er.status     = 'en_negociacion'
      AND  er.updated_at < NOW() - INTERVAL '30 minutes'
  LOOP
    UPDATE public.event_requests
    SET    status               = 'open',
           negotiating_group_id = NULL
    WHERE  id = v_req.id;

    IF v_req.client_id IS NOT NULL THEN
      INSERT INTO public.notifications
        (user_id, type, title, body, data)
      VALUES
        (v_req.client_id,
         'booking',
         '💬 La oferta expiró — solicitud reabierta',
         'No respondiste a la propuesta del grupo a tiempo. Tu solicitud volvió a estar disponible.',
         jsonb_build_object(
           'event_request_id', v_req.id,
           'event_date',       v_req.event_date,
           'screen',           'Home'
         ));
    END IF;

    v_reverted_count := v_reverted_count + 1;
  END LOOP;

  -- ── C. Expirar todo lo que ya pasó su expires_at ──────────────────────────
  --      [423] Ahora en loop: las EXPRÉS avisan al cliente al expirar.
  --      Las no-exprés siguen expirando sin notif (mueren antes vía A).
  FOR v_req IN
    SELECT er.id, er.client_id, er.event_date, er.express_window_until
    FROM   public.event_requests er
    WHERE  er.status NOT IN ('expired', 'accepted', 'cancelled')
      AND  er.expires_at IS NOT NULL
      AND  er.expires_at < NOW()
  LOOP
    UPDATE public.event_requests
    SET    status = 'expired'
    WHERE  id = v_req.id;

    -- Notificar SOLO exprés, con dedupe
    IF v_req.express_window_until IS NOT NULL
       AND v_req.client_id IS NOT NULL
       AND NOT EXISTS (
         SELECT 1 FROM public.notifications
         WHERE data->>'event_request_id' = v_req.id::text
           AND data->>'reason'           = 'express_expired'
       )
    THEN
      INSERT INTO public.notifications
        (user_id, type, title, body, data)
      VALUES
        (v_req.client_id,
         'booking',
         '⏳ Tu solicitud exprés expiró',
         'Ningún grupo respondió a tiempo. Puedes crear una nueva.',
         jsonb_build_object(
           'event_request_id', v_req.id,
           'event_date',       v_req.event_date,
           'reason',           'express_expired',
           'screen',           'Home'
         ));
    END IF;

    v_extra := v_extra + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'ok',            true,
    'expired_stale', v_expired_count,
    'expired_old',   v_extra,
    'reverted_open', v_reverted_count,
    'ran_at',        NOW()
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.expire_stale_requests() TO service_role;

COMMIT;

-- ── Verificaciones ────────────────────────────────────────────────────────────
-- V1: la sección C ahora es loop con la notif exprés
SELECT
  routine_definition LIKE '%Tu solicitud exprés expiró%'      AS notif_expres_ok,
  routine_definition LIKE '%express_expired%'                 AS dedupe_ok,
  routine_definition LIKE '%express_window_until IS NULL%'    AS seccion_a_intacta
FROM information_schema.routines
WHERE routine_schema = 'public' AND routine_name = 'expire_stale_requests';
-- Esperado: true | true | true

-- V2: 'booking' sigue permitido en el constraint (por si acaso)
SELECT pg_get_constraintdef(c.oid) LIKE '%''booking''%' AS booking_ok
FROM   pg_constraint c
WHERE  c.conname  = 'notifications_type_check'
  AND  c.conrelid = 'public.notifications'::regclass;
-- Esperado: true

SELECT '423_express_expiry_notification.sql ejecutado ✅' AS status;
