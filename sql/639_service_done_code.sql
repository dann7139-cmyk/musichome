-- sql/639_service_done_code.sql
--
-- CÓDIGO DE "SERVICIO TERMINADO" (2026-09-10) — petición del usuario.
--
-- Categorías sin duración predecible (Comida, Fotografía, Renta de mesas,
-- Renta de sillas, Renta de brincolines, Inflables acuáticos, Drones,
-- Cabina 360, Cabina fotográfica) hoy estaban forzadas a esperar las
-- HORAS CONTRATADAS COMPLETAS antes de poder cerrar el evento — igual que
-- una banda musical. No tiene sentido: comida no sabe cuánto va a tardar
-- en servir, y renta de mesas/sillas/brincolines/inflables solo necesita
-- llegar e instalar.
--
-- Solución: mismo criterio de seguridad que ya usa el código de llegada
-- (arrival_code) — un código NUEVO y DISTINTO ("servicio terminado") que
-- el cliente le da al proveedor cuando de verdad terminaron, sin límite
-- de tiempo. Se generan los dos códigos juntos al crear la reserva (igual
-- trigger), y NUNCA coinciden entre sí (si por azar salen iguales, se
-- regenera el segundo) — así el proveedor no puede "adivinar" el código
-- de cierre a partir del que ya usó para iniciar.
--
-- Música, DJ, luz y sonido, Payasos y Comediante NO cambian: siguen
-- cerrando solo cuando se cumplen las horas contratadas (el otro branch
-- de complete_event, copiado sin tocar).
-- ============================================================

BEGIN;

ALTER TABLE public.reservations ADD COLUMN IF NOT EXISTS service_done_code TEXT;

CREATE OR REPLACE FUNCTION public.generate_unique_service_code()
RETURNS TEXT LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_code   TEXT;
  v_exists BOOLEAN;
  v_tries  INT := 0;
BEGIN
  LOOP
    v_code := LPAD(FLOOR(RANDOM() * 9000 + 1000)::TEXT, 4, '0');
    SELECT EXISTS (
      SELECT 1 FROM reservations
      WHERE service_done_code = v_code
        AND event_date >= CURRENT_DATE
        AND status NOT IN ('cancelled', 'rejected', 'expired')
    ) INTO v_exists;
    EXIT WHEN NOT v_exists;
    v_tries := v_tries + 1;
    IF v_tries >= 200 THEN EXIT; END IF;
  END LOOP;
  RETURN v_code;
END;
$$;

-- Extiende el trigger existente de arrival_code (sql/380) para que también
-- genere el código de servicio terminado — un solo trigger, sin agregar otro.
CREATE OR REPLACE FUNCTION public.trg_fn_set_arrival_code()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.arrival_code IS NULL THEN
    NEW.arrival_code := generate_unique_arrival_code();
  END IF;
  IF NEW.service_done_code IS NULL THEN
    NEW.service_done_code := generate_unique_service_code();
    IF NEW.service_done_code = NEW.arrival_code THEN
      NEW.service_done_code := generate_unique_service_code();
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

-- complete_event ganaba UN solo candado (tiempo). Ahora bifurca por
-- categoría: código sin límite de tiempo, o el candado de tiempo de
-- siempre — sin tocar ese segundo camino.
DROP FUNCTION IF EXISTS public.complete_event(uuid);

CREATE OR REPLACE FUNCTION public.complete_event(p_reservation_id uuid, p_service_code text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE
  v_caller_id   UUID := auth.uid();
  v_res         RECORD;
  v_duration    INT;
  v_required    INT;
  v_extras      NUMERIC := 0;
  v_needs_code  BOOLEAN;
BEGIN
  IF v_caller_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unauthorized: sesión requerida');
  END IF;

  SELECT r.status, r.event_started_at, r.hours_count, r.folio, r.group_id,
         r.service_done_code, q.duration_hours AS quote_hours,
         g.owner_id, g.name AS gname, g.genre
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

  v_needs_code := v_res.genre = ANY(ARRAY[
    'Comida', 'Fotografía', 'Renta de mesas', 'Renta de sillas',
    'Renta de brincolines', 'Inflables acuáticos',
    'Drones', 'Cabina 360', 'Cabina fotográfica'
  ]);

  IF v_needs_code THEN
    IF p_service_code IS NULL OR v_res.service_done_code IS NULL
       OR p_service_code <> v_res.service_done_code THEN
      RETURN jsonb_build_object('ok', false, 'error', 'invalid_service_code');
    END IF;
    v_duration := GREATEST(0, EXTRACT(EPOCH FROM (NOW() - v_res.event_started_at))::INT / 60);
  ELSE
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

COMMIT;

-- ── VERIFICACIÓN ────────────────────────────────────────────
SELECT column_name FROM information_schema.columns
WHERE table_name = 'reservations' AND column_name = 'service_done_code';
-- Esperado: 1 fila

SELECT pg_get_function_identity_arguments(oid) FROM pg_proc WHERE proname = 'complete_event';
-- Esperado: "p_reservation_id uuid, p_service_code text" (1 sola fila — el
-- viejo complete_event(uuid) se dropeó)

SELECT '639_service_done_code.sql ejecutado ✅' AS status;
