-- ════════════════════════════════════════════════════════════════════
-- sql/350_expire_requests_proximity.sql
--
-- Reemplaza expire_stale_requests() con versión inteligente que añade:
--
--   Mecanismo D — Proximidad < 2h:
--     Si status IN ('open','en_negociacion') y el evento es en < 2h →
--     expirar inmediatamente + notificar cliente y grupo (si aplica).
--
--   Mecanismo E — Evento ya pasó:
--     Si event_date+time < NOW() → expirar + notificar.
--
--   Mecanismos A y B — Ventanas adaptativas según proximidad:
--     > 24h al evento: timeout original (60min open / 30min negociación)
--     6–24h al evento: timeout corto   (30min open / 15min negociación)
--     2– 6h al evento: timeout mínimo  (15min open /  5min negociación)
--     < 2h al evento: ya manejado por D (no llega a A ni B)
--
--   Mecanismo C — Sin cambios: expires_at global.
--
-- Requiere: 349 ejecutado primero (tipos en constraint).
-- Cron: mantiene el mismo schedule de */5 * * * *.
-- ════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.expire_stale_requests()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_expired_count   INT := 0;
  v_reverted_count  INT := 0;
  v_proximity_count INT := 0;
  v_past_count      INT := 0;
  v_extra           INT := 0;
  v_req             RECORD;
  v_event_label     TEXT;
BEGIN

  -- ── D. Expirar por proximidad: evento en < 2 horas ──────────────────────────
  -- Corre PRIMERO para que A y B no los vuelvan a procesar.
  FOR v_req IN
    SELECT er.id, er.client_id, er.group_id,
           er.event_date, er.event_time, er.event_type,
           er.negotiating_group_id
    FROM   public.event_requests er
    WHERE  er.status IN ('open', 'en_negociacion')
      AND  (er.event_date::TIMESTAMP
            + COALESCE(er.event_time::INTERVAL, '0'::INTERVAL))
           BETWEEN NOW() AND NOW() + INTERVAL '2 hours'
  LOOP
    UPDATE public.event_requests
    SET    status = 'expired'
    WHERE  id = v_req.id;

    -- Label legible para la notificación
    v_event_label := CASE v_req.event_type
      WHEN 'fiesta_privada' THEN 'fiesta privada'
      WHEN 'boda'           THEN 'boda'
      WHEN 'cumpleanos'     THEN 'cumpleaños'
      WHEN 'graduacion'     THEN 'graduación'
      WHEN 'empresarial'    THEN 'evento empresarial'
      ELSE COALESCE(v_req.event_type, 'evento')
    END;

    -- Notificar al cliente
    IF v_req.client_id IS NOT NULL THEN
      INSERT INTO public.notifications (user_id, type, title, body, data)
      VALUES (
        v_req.client_id,
        'request_expired_proximity',
        '⏱ Tu solicitud expiró',
        'El evento ' || v_event_label || ' está muy próximo para que un grupo pueda coordinarse. '
          || 'Para eventos urgentes usa Solicitar grupo ahora — múltiples grupos disponibles '
          || 'te responderán al instante.',
        jsonb_build_object(
          'event_request_id', v_req.id,
          'event_date',       v_req.event_date,
          'screen',           'OpenRequest'
        )
      );
    END IF;

    -- Notificar al grupo que estaba negociando (si aplica)
    IF v_req.negotiating_group_id IS NOT NULL THEN
      INSERT INTO public.notifications (user_id, type, title, body, data)
      SELECT
        g.owner_id,
        'quote_expired_proximity',
        '⏱ Cotización expirada',
        'El cliente no respondió a tiempo. La cotización expiró porque el evento es en menos de 2 horas.',
        jsonb_build_object(
          'event_request_id', v_req.id,
          'event_date',       v_req.event_date,
          'screen',           'GroupReservations'
        )
      FROM public.groups g
      WHERE g.id = v_req.negotiating_group_id;
    END IF;

    v_proximity_count := v_proximity_count + 1;
  END LOOP;

  -- ── E. Expirar eventos que ya pasaron ────────────────────────────────────────
  FOR v_req IN
    SELECT er.id, er.client_id, er.group_id,
           er.event_date, er.event_time, er.event_type,
           er.negotiating_group_id
    FROM   public.event_requests er
    WHERE  er.status IN ('open', 'en_negociacion')
      AND  (er.event_date::TIMESTAMP
            + COALESCE(er.event_time::INTERVAL, '0'::INTERVAL)) < NOW()
  LOOP
    UPDATE public.event_requests
    SET    status = 'expired'
    WHERE  id = v_req.id;

    v_event_label := CASE v_req.event_type
      WHEN 'fiesta_privada' THEN 'fiesta privada'
      WHEN 'boda'           THEN 'boda'
      WHEN 'cumpleanos'     THEN 'cumpleaños'
      WHEN 'graduacion'     THEN 'graduación'
      WHEN 'empresarial'    THEN 'evento empresarial'
      ELSE COALESCE(v_req.event_type, 'evento')
    END;

    IF v_req.client_id IS NOT NULL THEN
      INSERT INTO public.notifications (user_id, type, title, body, data)
      VALUES (
        v_req.client_id,
        'request_expired_proximity',
        'Solicitud cerrada',
        'Tu solicitud para ' || v_event_label || ' expiró porque la fecha del evento ya pasó.',
        jsonb_build_object(
          'event_request_id', v_req.id,
          'event_date',       v_req.event_date,
          'screen',           'OpenRequest'
        )
      );
    END IF;

    IF v_req.negotiating_group_id IS NOT NULL THEN
      INSERT INTO public.notifications (user_id, type, title, body, data)
      SELECT
        g.owner_id,
        'quote_expired_proximity',
        'Cotización cerrada',
        'La cotización expiró porque la fecha del evento ya pasó.',
        jsonb_build_object(
          'event_request_id', v_req.id,
          'event_date',       v_req.event_date,
          'screen',           'GroupReservations'
        )
      FROM public.groups g
      WHERE g.id = v_req.negotiating_group_id;
    END IF;

    v_past_count := v_past_count + 1;
  END LOOP;

  -- ── A. Expirar 'open' por inactividad — ventana adaptativa ───────────────────
  -- Solo aplica a eventos con > 2h restantes (D ya manejó los < 2h).
  FOR v_req IN
    SELECT er.id, er.client_id,
           er.event_date, er.event_time, er.negotiating_group_id
    FROM   public.event_requests er
    WHERE  er.status = 'open'
      AND  (er.event_date::TIMESTAMP
            + COALESCE(er.event_time::INTERVAL, '0'::INTERVAL))
           > NOW() + INTERVAL '2 hours'
      AND  er.updated_at < NOW() - CASE
        WHEN (er.event_date::TIMESTAMP
              + COALESCE(er.event_time::INTERVAL, '0'::INTERVAL)) - NOW()
             > INTERVAL '24 hours' THEN INTERVAL '1 hour'
        WHEN (er.event_date::TIMESTAMP
              + COALESCE(er.event_time::INTERVAL, '0'::INTERVAL)) - NOW()
             > INTERVAL '6 hours'  THEN INTERVAL '30 minutes'
        ELSE                            INTERVAL '15 minutes'
      END
  LOOP
    UPDATE public.event_requests
    SET    status = 'expired'
    WHERE  id = v_req.id;

    IF v_req.client_id IS NOT NULL THEN
      INSERT INTO public.notifications (user_id, type, title, body, data)
      VALUES (
        v_req.client_id,
        'booking',
        '⏳ Solicitud expirada',
        'Tu solicitud de evento no recibió respuesta a tiempo y fue cancelada automáticamente.',
        jsonb_build_object(
          'event_request_id', v_req.id,
          'event_date',       v_req.event_date,
          'screen',           'Home'
        )
      );
    END IF;

    v_expired_count := v_expired_count + 1;
  END LOOP;

  -- ── B. Revertir 'en_negociacion' → 'open' — ventana adaptativa ──────────────
  FOR v_req IN
    SELECT er.id, er.client_id,
           er.event_date, er.event_time, er.negotiating_group_id
    FROM   public.event_requests er
    WHERE  er.status = 'en_negociacion'
      AND  (er.event_date::TIMESTAMP
            + COALESCE(er.event_time::INTERVAL, '0'::INTERVAL))
           > NOW() + INTERVAL '2 hours'
      AND  er.updated_at < NOW() - CASE
        WHEN (er.event_date::TIMESTAMP
              + COALESCE(er.event_time::INTERVAL, '0'::INTERVAL)) - NOW()
             > INTERVAL '24 hours' THEN INTERVAL '30 minutes'
        WHEN (er.event_date::TIMESTAMP
              + COALESCE(er.event_time::INTERVAL, '0'::INTERVAL)) - NOW()
             > INTERVAL '6 hours'  THEN INTERVAL '15 minutes'
        ELSE                            INTERVAL '5 minutes'
      END
  LOOP
    UPDATE public.event_requests
    SET    status               = 'open',
           negotiating_group_id = NULL
    WHERE  id = v_req.id;

    IF v_req.client_id IS NOT NULL THEN
      INSERT INTO public.notifications (user_id, type, title, body, data)
      VALUES (
        v_req.client_id,
        'booking',
        '💬 La oferta expiró — solicitud reabierta',
        'No respondiste a la propuesta del grupo a tiempo. Tu solicitud volvió a estar disponible.',
        jsonb_build_object(
          'event_request_id', v_req.id,
          'event_date',       v_req.event_date,
          'screen',           'Home'
        )
      );
    END IF;

    v_reverted_count := v_reverted_count + 1;
  END LOOP;

  -- ── C. Expirar todo lo que ya pasó su expires_at ─────────────────────────────
  UPDATE public.event_requests
  SET    status = 'expired'
  WHERE  status NOT IN ('expired', 'accepted', 'cancelled')
    AND  expires_at IS NOT NULL
    AND  expires_at < NOW();

  GET DIAGNOSTICS v_extra = ROW_COUNT;

  RETURN jsonb_build_object(
    'ok',              true,
    'expired_stale',   v_expired_count,
    'expired_old',     v_extra,
    'reverted_open',   v_reverted_count,
    'expired_proximity', v_proximity_count,
    'expired_past',    v_past_count,
    'ran_at',          NOW()
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.expire_stale_requests() TO service_role;

-- ── Mantener el mismo cron de */5 minutos ────────────────────────────────────
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'expire_stale_requests') THEN
      PERFORM cron.unschedule('expire_stale_requests');
    END IF;
    PERFORM cron.schedule(
      'expire_stale_requests',
      '*/5 * * * *',
      'SELECT public.expire_stale_requests()'
    );
    RAISE NOTICE '[350] Cron expire_stale_requests reprogramado cada 5 min ✅';
  ELSE
    RAISE NOTICE '[350] pg_cron no disponible — cron no reprogramado';
  END IF;
END;
$$;

-- ── Verificación manual ───────────────────────────────────────────────────────
-- Para probar sin esperar el cron:
--   SELECT public.expire_stale_requests();
--
-- Para simular un evento en < 2h:
--   UPDATE public.event_requests
--   SET event_date = CURRENT_DATE,
--       event_time = to_char(NOW() + INTERVAL '1 hour', 'HH24:MI'),
--       status     = 'open'
--   WHERE id = '<tu_request_id>';
--   SELECT public.expire_stale_requests();

SELECT '350_expire_requests_proximity.sql ejecutado ✅' AS status;
