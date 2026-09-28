-- ═══════════════════════════════════════════════════════════════════════════
-- ROLLBACK de 711 — devuelve `notify_wave_1` SIN frontera de autorización
-- ═══════════════════════════════════════════════════════════════════════════
-- ⚠️  Correrlo vuelve a permitir que cualquier `authenticated` lance la ola de
-- una solicitud ajena (y deje la ajena en `wave_already_started`). Solo tiene
-- sentido si el gate rompe un flujo real que no se detectó.
--
-- Cuerpo restaurado tal como estaba tras sql/704 (md5 del cuerpo en produccion:
-- cff1e818611c0d77fde4f4a8efe16837 — puede diferir por CRLF/LF sin cambiar la
-- semántica). La ACL que se restaura es la de sql/708 (sin PUBLIC, sin anon):
-- este rollback **no** reabre el acceso anónimo.
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

CREATE OR REPLACE FUNCTION public.notify_wave_1(
  p_request_id           UUID,
  p_event_lat            DOUBLE PRECISION DEFAULT NULL::double precision,
  p_event_lng            DOUBLE PRECISION DEFAULT NULL::double precision,
  p_radius_km            DOUBLE PRECISION DEFAULT 50,
  p_use_radius_expansion BOOLEAN          DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_req            RECORD;
  v_sent           INT;
  v_urgent         BOOLEAN;
  v_initial_radius DOUBLE PRECISION;
BEGIN
  SELECT * INTO v_req FROM public.event_requests WHERE id = p_request_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'request_not_found');
  END IF;

  IF v_req.current_wave > 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'wave_already_started');
  END IF;

  v_initial_radius := CASE WHEN p_use_radius_expansion THEN 5.0 ELSE p_radius_km END;

  v_urgent := (
    v_req.event_date::TIMESTAMP +
    COALESCE((v_req.event_time)::INTERVAL, INTERVAL '0') - NOW()
  ) < INTERVAL '6 hours';

  UPDATE public.event_requests
  SET event_lat            = p_event_lat,
      event_lng            = p_event_lng,
      radius_km            = v_initial_radius,
      use_radius_expansion = p_use_radius_expansion,
      current_wave         = 1,
      wave1_sent_at        = NOW()
  WHERE id = p_request_id;

  SELECT * INTO v_req FROM public.event_requests WHERE id = p_request_id;

  -- Top 3 (quick matching) — suficiente para primera respuesta rápida
  v_sent := _send_wave(v_req, 0, 3, v_urgent);

  UPDATE public.event_requests
  SET notified_count = notified_count + v_sent
  WHERE id = p_request_id;

  RETURN jsonb_build_object(
    'ok',                   true,
    'wave',                 1,
    'notified',             v_sent,
    'urgent',               v_urgent,
    'initial_radius_km',    v_initial_radius,
    'use_radius_expansion', p_use_radius_expansion
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$function$;

REVOKE EXECUTE ON FUNCTION
  public.notify_wave_1(UUID, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION, BOOLEAN) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION
  public.notify_wave_1(UUID, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION, BOOLEAN) FROM anon;
GRANT EXECUTE ON FUNCTION
  public.notify_wave_1(UUID, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION, BOOLEAN)
  TO authenticated, service_role;

COMMENT ON FUNCTION public.notify_wave_1(UUID, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION, BOOLEAN) IS
  'ROLLBACK de sql/711: sin frontera de autorizacion. Conserva la ACL de sql/708 (sin PUBLIC, sin anon).';

NOTIFY pgrst, 'reload schema';

COMMIT;
