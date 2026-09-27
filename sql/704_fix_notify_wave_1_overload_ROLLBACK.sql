-- ═══════════════════════════════════════════════════════════════════════════
-- ROLLBACK de 704 — recrea la firma de 4 argumentos de `notify_wave_1`
-- ═══════════════════════════════════════════════════════════════════════════
-- ⚠️  Correrlo REINTRODUCE la ambigüedad 42725: la llamada de la app volvería a
-- fallar, porque otra vez habría dos candidatos para sus 4 claves. Solo tiene
-- sentido si se decide que la oleada 1 debe notificar al top 5 en vez del top 3;
-- en ese caso hay que correr esto Y ADEMÁS retirar la firma de 5 argumentos, o el
-- problema vuelve.
--
-- Cuerpo restaurado byte por byte como estaba en producción (oid 51474), con su
-- ACL original: EXECUTE para PUBLIC + anon + authenticated + service_role.
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

CREATE OR REPLACE FUNCTION public.notify_wave_1(
  p_request_id UUID,
  p_event_lat  DOUBLE PRECISION DEFAULT NULL::double precision,
  p_event_lng  DOUBLE PRECISION DEFAULT NULL::double precision,
  p_radius_km  DOUBLE PRECISION DEFAULT 50
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_req     RECORD;
  v_sent    INT;
  v_urgent  BOOLEAN;
BEGIN
  SELECT * INTO v_req
  FROM event_requests
  WHERE id = p_request_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'request_not_found');
  END IF;

  IF v_req.current_wave > 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'wave_already_started');
  END IF;

  -- Detectar evento urgente (< 6 horas desde ahora)
  v_urgent := (
    v_req.event_date::TIMESTAMP +
    COALESCE((v_req.event_time)::INTERVAL, INTERVAL '0')
    - NOW()
  ) < INTERVAL '6 hours';

  -- Guardar coordenadas y marcar wave 1 como enviada
  UPDATE event_requests
  SET event_lat     = p_event_lat,
      event_lng     = p_event_lng,
      radius_km     = p_radius_km,
      current_wave  = 1,
      wave1_sent_at = NOW()
  WHERE id = p_request_id;

  -- Recargar con los nuevos valores
  SELECT * INTO v_req FROM event_requests WHERE id = p_request_id;

  v_sent := _send_wave(v_req, 0, 5, v_urgent);

  UPDATE event_requests
  SET notified_count = notified_count + v_sent
  WHERE id = p_request_id;

  RETURN jsonb_build_object(
    'ok',       true,
    'wave',     1,
    'notified', v_sent,
    'urgent',   v_urgent
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.notify_wave_1(UUID, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION)
  TO PUBLIC, anon, authenticated, service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
