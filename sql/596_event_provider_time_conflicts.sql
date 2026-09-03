-- ============================================================
-- sql/596_event_provider_time_conflicts.sql
-- ✅ APLICADO A PRODUCCIÓN 2026-09-01. Probado antes en transacción
-- autoreversible (BEGIN...ROLLBACK): comida excluida correctamente,
-- cotización rechazada no cuenta, un grupo no ve su propia cotización
-- como choque, evento inexistente devuelve error limpio — 0 residuo
-- verificado tras el rollback. Aplicado para real después; ACL
-- verificada: solo authenticated/service_role/postgres tienen EXECUTE,
-- anon NO (sin el descuido de sql/591 con el grant PUBLIC por defecto).
--
-- PETICIÓN REAL DEL USUARIO (2026-09-01): que no choquen las horas de
-- dos proveedores en el MISMO evento compartido (event_id). Ejemplo:
-- si el grupo A toca 1pm-4pm, el grupo B no debería poder elegir una
-- hora que se encime — pero SÍ puede empezar justo cuando el otro
-- termina (son grupos independientes, no la misma tocada, así que no
-- se exige colchón de traslado como con el propio calendario de un
-- mismo grupo). Excepción explícita del usuario: "la comida esa si es
-- a la hora que sea y brincolines o muebles esas dos últimas no llevan
-- temporizador" — Comida, renta de brincolines/inflables y renta de
-- mesas/sillas quedan EXCLUIDOS del choque (ni bloquean a otros, ni se
-- les aplica el choque a ellos). El resto de renta (escenarios,
-- generadores, plantas de luz, toldos, tarimas) NO se excluyó porque
-- el usuario no lo mencionó explícitamente — queda abierto si en el
-- futuro pide ampliar la excepción.
--
-- Nueva RPC de solo lectura: client_get_event_time_conflicts(p_event_id,
-- p_exclude_group_id) — devuelve los horarios ya tomados por OTROS
-- proveedores "con temporizador" del mismo evento (cotizaciones
-- pending/accepted; rejected no cuenta), para que el cliente los vea
-- al elegir hora para un 2º/3º proveedor. Solo el cliente dueño del
-- evento puede consultarlo (mismo patrón de ownership que
-- client_get_event_sound_context, sql/585).
-- ============================================================

-- ── 1) Prueba en transacción autoreversible (función + datos) ──────
BEGIN;

CREATE OR REPLACE FUNCTION public.client_get_event_time_conflicts(
  p_event_id          UUID,
  p_exclude_group_id  UUID DEFAULT NULL
) RETURNS jsonb
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
    AND COALESCE(g.genre, '') NOT IN (
      'Comida', 'Renta de brincolines', 'Inflables acuáticos',
      'Renta de mesas', 'Renta de sillas'
    );

  RETURN jsonb_build_object('ok', true, 'ranges', v_ranges);
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.client_get_event_time_conflicts(UUID, UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.client_get_event_time_conflicts(UUID, UUID) TO authenticated;

DO $test$
DECLARE
  v_client   UUID := gen_random_uuid();
  v_event    UUID;
  v_group_a  UUID; -- Banda (con temporizador), toca 1pm-4pm
  v_group_b  UUID; -- Banda (con temporizador) — la que consulta, excluida de su propio resultado
  v_group_c  UUID; -- Comida (exenta) a la misma hora que A
  v_country  UUID;
  v_result   jsonb;
  v_ranges   jsonb;
BEGIN
  SELECT id INTO v_country FROM public.countries LIMIT 1;

  INSERT INTO public.profiles (id, full_name, role)
    VALUES (v_client, 'Test Cliente 596', 'client');

  INSERT INTO public.events (id, client_id, event_date, event_time, address, status)
    VALUES (gen_random_uuid(), v_client, CURRENT_DATE + 30, '13:00', 'Dirección de prueba', 'active')
    RETURNING id INTO v_event;

  INSERT INTO public.groups (id, name, genre, country_id)
    VALUES (gen_random_uuid(), 'Test Grupo A 596', 'Banda', v_country) RETURNING id INTO v_group_a;
  INSERT INTO public.groups (id, name, genre, country_id)
    VALUES (gen_random_uuid(), 'Test Grupo B 596', 'Norteño', v_country) RETURNING id INTO v_group_b;
  INSERT INTO public.groups (id, name, genre, country_id)
    VALUES (gen_random_uuid(), 'Test Comida 596', 'Comida', v_country) RETURNING id INTO v_group_c;

  -- Grupo A: cotización pendiente 1pm, 3h — debe contar como choque
  INSERT INTO public.quotes (id, group_id, client_id, event_id, event_date, event_time, duration_hours, status,
    event_type, event_address, event_municipio, event_estado, venue_covered, venue_size, needs_sound)
    VALUES (gen_random_uuid(), v_group_a, v_client, v_event, CURRENT_DATE + 30, '13:00', 3, 'pending',
      'boda', 'Dir', 'Muni', 'Edo', 'si', 'salon_mediano', 'no_group_brings');
  -- Comida a la misma hora — NO debe contar (exenta)
  INSERT INTO public.quotes (id, group_id, client_id, event_id, event_date, event_time, duration_hours, status,
    event_type, event_address, event_municipio, event_estado, venue_covered, venue_size, needs_sound)
    VALUES (gen_random_uuid(), v_group_c, v_client, v_event, CURRENT_DATE + 30, '13:00', 3, 'pending',
      'boda', 'Dir', 'Muni', 'Edo', 'si', 'salon_mediano', 'no_group_brings');
  -- Otra cotización de A, RECHAZADA, a las 6pm — NO debe contar (rejected)
  INSERT INTO public.quotes (id, group_id, client_id, event_id, event_date, event_time, duration_hours, status,
    event_type, event_address, event_municipio, event_estado, venue_covered, venue_size, needs_sound)
    VALUES (gen_random_uuid(), v_group_a, v_client, v_event, CURRENT_DATE + 30, '18:00', 2, 'rejected',
      'boda', 'Dir', 'Muni', 'Edo', 'si', 'salon_mediano', 'no_group_brings');

  -- 1) Sin sesión (auth.uid() NULL en SQL directo) → ok:false not_authenticated
  v_result := public.client_get_event_time_conflicts(v_event, v_group_b);
  ASSERT v_result->>'ok' = 'false' AND v_result->>'error' = 'not_authenticated',
    'FAIL sin auth: ' || v_result::text;

  -- 2) Simular sesión del cliente dueño vía set_config (mismo truco usado en pruebas previas)
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_client::text, 'role', 'authenticated')::text, true);
  PERFORM set_config('role', 'authenticated', true);

  v_result := public.client_get_event_time_conflicts(v_event, v_group_b);
  ASSERT v_result->>'ok' = 'true', 'FAIL con auth debe ok:true: ' || v_result::text;
  v_ranges := v_result->'ranges';
  ASSERT jsonb_array_length(v_ranges) = 1,
    'FAIL debe traer exactamente 1 rango (solo Grupo A pending, sin comida ni rejected): ' || v_ranges::text;
  ASSERT v_ranges->0->>'group_name' = 'Test Grupo A 596',
    'FAIL el único rango debe ser el de Grupo A: ' || v_ranges::text;
  ASSERT v_ranges->0->>'time' = '13:00', 'FAIL hora incorrecta: ' || v_ranges::text;
  ASSERT (v_ranges->0->>'hours')::int = 3, 'FAIL horas incorrectas: ' || v_ranges::text;

  -- 3) Excluir al propio Grupo A de su propio resultado (no debe chocar contra sí mismo)
  v_result := public.client_get_event_time_conflicts(v_event, v_group_a);
  ASSERT jsonb_array_length(v_result->'ranges') = 0,
    'FAIL Grupo A no debe ver su propia cotización como choque: ' || v_result::text;

  -- 4) Evento inexistente → event_not_found
  v_result := public.client_get_event_time_conflicts(gen_random_uuid(), NULL);
  ASSERT v_result->>'error' = 'event_not_found', 'FAIL evento inexistente: ' || v_result::text;

  RAISE EXCEPTION 'ROLLBACK_TEST_OK — todas las pruebas pasaron';
END;
$test$;

ROLLBACK;

-- ── 2) Aplicación real (función queda permanente) ───────────────────
BEGIN;

CREATE OR REPLACE FUNCTION public.client_get_event_time_conflicts(
  p_event_id          UUID,
  p_exclude_group_id  UUID DEFAULT NULL
) RETURNS jsonb
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
    AND COALESCE(g.genre, '') NOT IN (
      'Comida', 'Renta de brincolines', 'Inflables acuáticos',
      'Renta de mesas', 'Renta de sillas'
    );

  RETURN jsonb_build_object('ok', true, 'ranges', v_ranges);
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.client_get_event_time_conflicts(UUID, UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.client_get_event_time_conflicts(UUID, UUID) TO authenticated;

COMMIT;

SELECT '596_event_provider_time_conflicts — APLICADO A PRODUCCIÓN 2026-09-01' AS status;
