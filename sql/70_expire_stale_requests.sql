-- ════════════════════════════════════════════════════════════════════
-- 70_expire_stale_requests.sql
-- Auto-expiración de solicitudes de evento inactivas.
--
-- Reglas:
--   · open          → expired  si han pasado 60 min desde created_at
--   · en_negociacion → open    si el cliente no respondió en 30 min
--   · Cualquier estado         → expired si ya pasó su expires_at
--
-- Requiere pg_cron habilitado en Supabase (extensión).
-- Ejecutar DESPUÉS de 66_negotiation_flow.sql
-- ════════════════════════════════════════════════════════════════════

-- ── 0. Agregar updated_at a event_requests si no existe ──────────────────────
ALTER TABLE public.event_requests
  ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW();

-- Índice compuesto para que el cron no haga seq-scan
CREATE INDEX IF NOT EXISTS idx_er_status_updated
  ON public.event_requests (status, updated_at)
  WHERE status IN ('open', 'en_negociacion');

CREATE INDEX IF NOT EXISTS idx_er_expires_open
  ON public.event_requests (expires_at)
  WHERE expires_at IS NOT NULL
    AND status NOT IN ('expired', 'accepted', 'cancelled');

-- Trigger para mantener updated_at actualizado automáticamente
CREATE OR REPLACE FUNCTION public.set_event_request_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := NOW();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_er_updated_at ON public.event_requests;
CREATE TRIGGER trg_er_updated_at
  BEFORE UPDATE ON public.event_requests
  FOR EACH ROW EXECUTE FUNCTION public.set_event_request_updated_at();

-- ── 1. Función principal ──────────────────────────────────────────────────────
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
  FOR v_req IN
    SELECT er.id, er.group_id, er.client_id, er.event_date
    FROM   public.event_requests er
    WHERE  er.status     = 'open'
      AND  er.updated_at < NOW() - INTERVAL '1 hour'
  LOOP
    UPDATE public.event_requests
    SET    status = 'expired'
    WHERE  id = v_req.id;

    -- Notificar al cliente
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

    -- Notificar al dueño del grupo si había uno asignado
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
    SET    status              = 'open',
           negotiating_group_id = NULL
    WHERE  id = v_req.id;

    -- Recordar al cliente que hay una oferta esperando
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
  UPDATE public.event_requests
  SET    status = 'expired'
  WHERE  status NOT IN ('expired', 'accepted', 'cancelled')
    AND  expires_at IS NOT NULL
    AND  expires_at < NOW();

  GET DIAGNOSTICS v_extra = ROW_COUNT;

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

-- ── 2. Programar con pg_cron cada 5 minutos ───────────────────────────────────
--    Requiere: activar pg_cron en Supabase Dashboard → Database → Extensions
--
--    Alternativa sin pg_cron: crear Supabase Edge Function con schedule de 5 min
--    que llame: await supabase.rpc('expire_stale_requests')

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    -- Borrar job anterior solo si ya existe
    IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'expire_stale_requests') THEN
      PERFORM cron.unschedule('expire_stale_requests');
    END IF;
    -- Crear job nuevo
    PERFORM cron.schedule(
      'expire_stale_requests',
      '*/5 * * * *',
      'SELECT public.expire_stale_requests()'
    );
  END IF;
END;
$$;

SELECT '70_expire_stale_requests: auto-expiración programada cada 5 min ✅' AS status;
