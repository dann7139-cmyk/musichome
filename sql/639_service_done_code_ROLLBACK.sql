-- sql/639_service_done_code_ROLLBACK.sql
BEGIN;

DROP FUNCTION IF EXISTS public.complete_event(uuid, text);

CREATE OR REPLACE FUNCTION public.complete_event(p_reservation_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_id   UUID := auth.uid();
  v_res         RECORD;
  v_duration    INT;
  v_required    INT;
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

  IF v_res.status = 'completed' THEN
    RETURN jsonb_build_object('ok', true, 'completed_at', NOW(), 'note', 'already_completed');
  END IF;

  IF v_res.event_started_at IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'El evento aún no ha iniciado.');
  END IF;

  SELECT COALESCE(SUM(hours_added), 0) INTO v_extras
  FROM extra_hours
  WHERE reservation_id = p_reservation_id
    AND status IN ('accepted', 'paid');

  v_duration := GREATEST(0, EXTRACT(EPOCH FROM (NOW() - v_res.event_started_at))::INT / 60);
  v_required := GREATEST(60, COALESCE(v_res.hours_count, v_res.quote_hours, 3)::INT * 60)
                + (v_extras * 75)::INT;

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
$function$;

CREATE OR REPLACE FUNCTION public.trg_fn_set_arrival_code()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.arrival_code IS NULL THEN
    NEW.arrival_code := generate_unique_arrival_code();
  END IF;
  RETURN NEW;
END;
$$;

DROP FUNCTION IF EXISTS public.generate_unique_service_code();

ALTER TABLE public.reservations DROP COLUMN IF EXISTS service_done_code;

COMMIT;

SELECT '639_service_done_code_ROLLBACK.sql ejecutado ✅' AS status;
