-- ROLLBACK de 672_multi_genre_matching.sql
-- Restaura los 3 cuerpos EXACTOS que estaban en producción antes (capturados
-- vía pg_get_functiondef antes de aplicar 672), y elimina las 2 funciones
-- nuevas (genre_matches, genre_category_key).

BEGIN;

CREATE OR REPLACE FUNCTION public.group_category_key(p_group_id uuid)
RETURNS text
LANGUAGE sql
STABLE
SET search_path TO 'public'
AS $function$
  SELECT CASE
    WHEN g.genre = ANY(ARRAY[
      'Bachata','Balada','Banda','Blues','Bolero','Corridos','Corridos Tumbados',
      'Country','Cuartetos','Cumbia','Danzón','Electrónica','Folklore','Gospel',
      'Grupero','Grupos musicales','Hip Hop','Huapango','Jazz','Mariachi','Marimba',
      'Merengue','Norteño','Pop','R&B','Ranchero','Reggaeton','Rock','Salsa',
      'Sextetos','Son Jarocho','Tango','Tríos','Tropical','Trova','Vallenato','Versátil'
    ]) THEN 'grupo'
    WHEN g.genre = 'Solistas' THEN 'solista'
    WHEN g.genre = 'DJ' THEN 'dj'
    WHEN g.genre = 'Comediante' THEN 'comediante'
    WHEN g.genre = 'Maestro de Ceremonias' THEN 'mc'
    WHEN g.genre = ANY(ARRAY['Espectáculo','Payasos','Mago','Personajes','Animación']) THEN 'espectaculo'
    WHEN g.genre = ANY(ARRAY[
      'Sonido / Iluminación','Sonido','Iluminación','Cabinas DJ',
      'Iluminación profesional','Micrófonos','Pantallas LED','Proyectores','Sonido profesional'
    ]) THEN 'luzSonido'
    WHEN g.genre = 'Comida' THEN 'comida'
    WHEN g.genre = ANY(ARRAY[
      'Escenarios','Generadores eléctricos','Inflables acuáticos','Plantas de luz',
      'Renta de brincolines','Renta de mesas','Renta de sillas','Renta de toldos','Tarimas'
    ]) THEN 'renta'
    WHEN g.genre = ANY(ARRAY['Fotografía','Drones','Cabina 360','Cabina fotográfica']) THEN 'fotografos'
    ELSE NULL
  END
  FROM public.groups g WHERE g.id = p_group_id;
$function$;

CREATE OR REPLACE FUNCTION public.dispatch_express_request(p_request_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_request         public.event_requests%ROWTYPE;
  v_group_row       RECORD;
  v_dispatched      int := 0;
  v_window_minutes  int := 180;   -- 3 h (sql/456)
  v_max_groups      int := 10;
BEGIN
  SELECT * INTO v_request
  FROM public.event_requests
  WHERE id = p_request_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'request_not_found');
  END IF;

  IF v_request.status <> 'open' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'request_not_open', 'status', v_request.status);
  END IF;

  FOR v_group_row IN
    SELECT g.id AS group_id
    FROM public.groups g
    WHERE
      g.genre = v_request.genre
      AND (
        lower(trim(g.city))  = lower(trim(v_request.location_city))
        OR lower(trim(g.state)) = lower(trim(v_request.location_estado))
      )
      AND g.is_active = true
      AND g.suspended_at IS NULL
      AND COALESCE(g.availability, 'available') = 'available'
      AND NOT EXISTS (
        SELECT 1 FROM public.express_dispatches ed
        WHERE ed.request_id = p_request_id
          AND ed.group_id   = g.id
      )
      AND NOT EXISTS (
        SELECT 1 FROM public.group_unavailability gu
        WHERE gu.group_id = g.id
          AND gu.date = (NOW() AT TIME ZONE 'America/Mexico_City')::date
      )
      AND NOT EXISTS (
        SELECT 1 FROM public.reservations r
        WHERE r.group_id = g.id
          AND r.status = 'in_progress'
      )
    ORDER BY
      (lower(trim(g.city)) = lower(trim(v_request.location_city))) DESC,
      g.is_verified DESC,
      g.rating DESC NULLS LAST
    LIMIT v_max_groups
  LOOP
    INSERT INTO public.express_dispatches (
      request_id, group_id, status, expires_at
    )
    VALUES (
      p_request_id,
      v_group_row.group_id,
      'pending_broadcast',
      NOW() + (v_window_minutes || ' minutes')::interval
    )
    ON CONFLICT DO NOTHING;

    v_dispatched := v_dispatched + 1;
  END LOOP;

  IF v_dispatched > 0 THEN
    UPDATE public.event_requests
    SET express_window_until = NOW() + (v_window_minutes || ' minutes')::interval
    WHERE id = p_request_id;
  END IF;

  RETURN jsonb_build_object(
    'ok',         true,
    'dispatched', v_dispatched,
    'request_id', p_request_id,
    'window_min', v_window_minutes
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_surge_factor(p_genre text DEFAULT NULL::text, p_city text DEFAULT NULL::text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_open_requests    INT := 0;
  v_available_groups INT := 0;
  v_raw_factor       NUMERIC;
  v_surge_factor     NUMERIC;
  v_level            TEXT;
  v_message          TEXT;
  v_client_message   TEXT;
BEGIN
  SELECT COUNT(*) INTO v_open_requests
  FROM public.event_requests
  WHERE status = 'open'
    AND expires_at > now()
    AND (p_genre IS NULL OR genre ILIKE p_genre)
    AND (p_city  IS NULL OR location_city ILIKE p_city);

  SELECT COUNT(*) INTO v_available_groups
  FROM public.groups
  WHERE is_active = true
    AND (p_genre IS NULL OR genre ILIKE p_genre);

  v_raw_factor   := v_open_requests::NUMERIC / GREATEST(1, v_available_groups);
  v_surge_factor := LEAST(1.15, GREATEST(1.0, ROUND(v_raw_factor, 2)));

  IF v_surge_factor >= 1.08 THEN
    v_level          := 'high';
    v_message        := '✨ Servicio con respaldo garantizado';
    v_client_message := 'Reserva protegida por la app · Pago seguro y garantía de servicio';
  ELSIF v_surge_factor >= 1.03 THEN
    v_level          := 'medium';
    v_message        := '✨ Reserva con respaldo de plataforma';
    v_client_message := 'Reserva protegida · Pago seguro y garantía de servicio';
  ELSE
    v_level          := 'low';
    v_message        := '';
    v_client_message := '';
  END IF;

  RETURN jsonb_build_object(
    'surge_factor',      v_surge_factor,
    'level',             v_level,
    'message',           v_message,
    'client_message',    v_client_message,
    'open_requests',     v_open_requests,
    'available_groups',  v_available_groups
  );
END;
$function$;

DROP FUNCTION IF EXISTS public.genre_category_key(text);
DROP FUNCTION IF EXISTS public.genre_matches(text, text);

COMMIT;
