-- ═══════════════════════════════════════════════════════════════════════
-- 673 — Categoría "Comida" renombrada a "Amenidades y Snacks" con más
--        estilos (Comida, Barra de mixología, Snacks y botanas, Café y
--        postres)
-- ═══════════════════════════════════════════════════════════════════════
-- Petición real (2026-09-20): "en categorías... quiero que diga Amenidades
-- y Snacks... cuando le aprieten sale: Comida - Barra de mixología".
-- providerCategories.ts (app) y genreCategories.ts (web) ya traen la nueva
-- lista COMIDA_GENRES = ['Comida','Barra de mixología','Snacks y botanas',
-- 'Café y postres'] — este archivo sincroniza el servidor con esa lista en
-- las 4 funciones que antes comparaban contra el literal 'Comida' a solas:
--
--   · genre_category_key() (sql/672): clasifica un estilo en su categoría.
--   · group_default_break_type(): decide qué categorías NO llevan tandas/
--     descansos (comida no toca por horas, es servicio de contrato).
--   · client_get_event_time_conflicts(): categorías exentas del choque de
--     horario entre proveedores del mismo evento (sql/585).
--   · complete_event(): categorías que necesitan código de "servicio
--     terminado" en vez de esperar que se cumplan las horas (sql/639).
--
-- genre_in_list(genre, lista) es la pieza nueva: separa `genre` por "/"
-- (grupos con más de un estilo, sql/672) y revisa si ALGUNA parte está en
-- la lista — antes cada función comparaba el campo completo contra un
-- solo valor o un ARRAY con "=", lo que ya no alcanza si el grupo tiene
-- más de un estilo.
--
-- Sandbox-probado con BEGIN/ROLLBACK antes de aplicar. Rollback:
-- 673_comida_amenidades_snacks_ROLLBACK.sql.
-- ═══════════════════════════════════════════════════════════════════════

BEGIN;

CREATE OR REPLACE FUNCTION public.genre_in_list(p_genre text, p_list text[])
RETURNS boolean
LANGUAGE sql
IMMUTABLE
SET search_path TO 'public'
AS $function$
  SELECT EXISTS (
    SELECT 1 FROM unnest(string_to_array(COALESCE(p_genre,''), '/')) AS part
    WHERE trim(part) = ANY(p_list)
  );
$function$;

-- ── genre_category_key: rama 'comida' ahora acepta los 4 estilos ─────────
CREATE OR REPLACE FUNCTION public.genre_category_key(p_genre text)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path TO 'public'
AS $function$
  SELECT CASE
    WHEN p_genre = ANY(ARRAY[
      'Norteño','Sierreño','Norteño-Banda','Versátil','Banda','Mariachi','Rock',
      'Bachata','Balada','Blues','Bolero','Conjunto','Country','Cuartetos','Cumbia',
      'Danzón','Electrónica','Folklore','Gospel','Hip Hop','Jazz','Marimba','Merengue',
      'Pop','R&B','Reggaeton','Salsa','Sextetos','Son Jarocho','Tango','Tríos',
      'Tropical','Trova','Vallenato',
      'Americana','Appalachian','Bluegrass','Cajun','Classical','Dance','Disco','Folk',
      'Funk','Indie','Klezmer','Metal','Motown','Punk','Soul','Southern Rock','Swing','Zydeco'
    ]) THEN 'grupo'
    WHEN p_genre = 'Solistas' THEN 'solista'
    WHEN p_genre = 'DJ' THEN 'dj'
    WHEN p_genre = 'Comediante' THEN 'comediante'
    WHEN p_genre = 'Maestro de Ceremonias' THEN 'mc'
    WHEN p_genre = ANY(ARRAY['Espectáculo','Payasos','Mago','Personajes','Animación']) THEN 'espectaculo'
    WHEN p_genre = ANY(ARRAY[
      'Sonido / Iluminación','Sonido','Iluminación','Cabinas DJ',
      'Iluminación profesional','Micrófonos','Pantallas LED','Proyectores','Sonido profesional'
    ]) THEN 'luzSonido'
    WHEN p_genre = ANY(ARRAY['Comida','Barra de mixología','Snacks y botanas','Café y postres']) THEN 'comida'
    WHEN p_genre = ANY(ARRAY[
      'Escenarios','Generadores eléctricos','Inflables acuáticos','Plantas de luz',
      'Renta de brincolines','Renta de mesas','Renta de sillas','Renta de toldos','Tarimas'
    ]) THEN 'renta'
    WHEN p_genre = ANY(ARRAY['Fotografía','Drones','Cabina 360','Cabina fotográfica']) THEN 'fotografos'
    ELSE NULL
  END;
$function$;

-- ── group_default_break_type: agrega los 3 estilos nuevos de "comida" a
--    la lista sin-tandas; ahora usa genre_in_list para ser robusto ante un
--    grupo con más de un estilo. Resto del cuerpo sin cambios. ───────────
CREATE OR REPLACE FUNCTION public.group_default_break_type(p_group_id uuid)
RETURNS text
LANGUAGE sql
STABLE
SET search_path TO 'public'
AS $function$
  SELECT CASE
    WHEN public.genre_in_list(g.genre, ARRAY[
      'Comediante', 'Comida', 'Barra de mixología', 'Snacks y botanas', 'Café y postres',
      'Maestro de Ceremonias',
      'Renta de brincolines', 'Inflables acuáticos',
      'Renta de mesas', 'Renta de sillas',
      'Fotografía', 'Drones', 'Cabina 360', 'Cabina fotográfica'
    ]) THEN 'D'
    ELSE NULL
  END
  FROM public.groups g WHERE g.id = p_group_id;
$function$;

-- ── client_get_event_time_conflicts: mismas categorías exentas de choque
--    de horario + los 3 estilos nuevos. Resto BYTE IDÉNTICO. ─────────────
CREATE OR REPLACE FUNCTION public.client_get_event_time_conflicts(p_event_id uuid, p_exclude_group_id uuid DEFAULT NULL::uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_client_id UUID;
  v_ranges    jsonb;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_authenticated');
  END IF;

  SELECT client_id INTO v_client_id FROM public.events WHERE id = p_event_id;
  IF v_client_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'event_not_found');
  END IF;
  IF v_client_id <> auth.uid() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'event_not_owned_by_client');
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'group_name', g.name,
           'time',       q.event_time,
           'hours',      q.duration_hours
         ) ORDER BY q.event_time), '[]'::jsonb)
    INTO v_ranges
  FROM public.quotes q
  JOIN public.groups g ON g.id = q.group_id
  WHERE q.event_id = p_event_id
    AND q.status IN ('pending', 'accepted')
    AND q.event_time IS NOT NULL
    AND (p_exclude_group_id IS NULL OR q.group_id <> p_exclude_group_id)
    AND NOT public.genre_in_list(g.genre, ARRAY[
      'Comida', 'Barra de mixología', 'Snacks y botanas', 'Café y postres',
      'Renta de brincolines', 'Inflables acuáticos',
      'Renta de mesas', 'Renta de sillas'
    ]);

  RETURN jsonb_build_object('ok', true, 'ranges', v_ranges);
END;
$function$;

-- ── complete_event: mismas categorías que necesitan código de "servicio
--    terminado" + los 3 estilos nuevos. Resto BYTE IDÉNTICO. ────────────
CREATE OR REPLACE FUNCTION public.complete_event(p_reservation_id uuid, p_service_code text DEFAULT NULL::text)
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

  v_needs_code := public.genre_in_list(v_res.genre, ARRAY[
    'Comida', 'Barra de mixología', 'Snacks y botanas', 'Café y postres',
    'Fotografía', 'Renta de mesas', 'Renta de sillas',
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
