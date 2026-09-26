-- ═══════════════════════════════════════════════════════════════════════
-- 672 — Emparejamiento de género compuesto ("Norteño/Sierreño")
-- ═══════════════════════════════════════════════════════════════════════
-- Petición real (2026-09-20): "un grupo puede poner dos generos, por decir
-- norteño/sierreño... ahi que aparescan". groups.genre siempre fue texto
-- libre — ahora la app permite guardar más de un estilo separados por "/"
-- (ver AdminProviderApplicationsScreen.tsx / GroupsScreen.tsx). Varias
-- funciones del servidor comparaban ese campo con "=" exacto, así que un
-- grupo con género compuesto NUNCA calzaba con nada:
--
--   · dispatch_express_request(): un grupo "Norteño/Sierreño" JAMÁS
--     recibía un Express de "Sierreño" ni de "Norteño" — bug más grave,
--     el grupo quedaba invisible para el despacho en vivo.
--   · group_category_key(): además de la comparación exacta, su lista de
--     "grupo musical" estaba desincronizada de providerCategories.ts desde
--     el 2026-09-16/17 (le faltaban Sierreño/Norteño-Banda/Conjunto y le
--     sobraban Corridos Tumbados/Grupero/Huapango/Ranchero/Grupos
--     musicales, ya quitados allá). Afecta la exclusión de categoría propia
--     en anuncios de perfil (get_profile_ads, sql/626) y el filtro de
--     categoría del admin al regalar Destacado/Recomendado (sql/610).
--   · get_surge_factor(): el indicador de demanda por género tampoco
--     contaba grupos/solicitudes de un género compuesto.
--
-- genre_matches(a, b) es la única fuente nueva: separa ambos lados por "/",
-- sin distinguir mayúsculas/espacios, y dice si comparten algún estilo —
-- funciona igual para un género simple (arreglo de 1) que para uno
-- compuesto. Espejo exacto de genreMatches() en
-- src/constants/providerCategories.ts.
--
-- Sandbox-probado con BEGIN/ROLLBACK antes de aplicar (incluye los 2 grupos
-- Sierreño reales). Rollback: 672_multi_genre_matching_ROLLBACK.sql.
-- ═══════════════════════════════════════════════════════════════════════

BEGIN;

-- ── genre_matches: separa por "/", compara sin mayúsculas ni espacios ────
CREATE OR REPLACE FUNCTION public.genre_matches(a text, b text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
SET search_path TO 'public'
AS $function$
  SELECT a IS NOT NULL AND b IS NOT NULL AND EXISTS (
    SELECT 1
    FROM unnest(string_to_array(a, '/')) AS pa
    CROSS JOIN unnest(string_to_array(b, '/')) AS pb
    WHERE lower(trim(pa)) = lower(trim(pb))
  );
$function$;

-- ── genre_category_key: categoría de UN género (espejo de la lista real
--    de providerCategories.ts, sincronizada 2026-09-20) ───────────────────
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
    WHEN p_genre = 'Comida' THEN 'comida'
    WHEN p_genre = ANY(ARRAY[
      'Escenarios','Generadores eléctricos','Inflables acuáticos','Plantas de luz',
      'Renta de brincolines','Renta de mesas','Renta de sillas','Renta de toldos','Tarimas'
    ]) THEN 'renta'
    WHEN p_genre = ANY(ARRAY['Fotografía','Drones','Cabina 360','Cabina fotográfica']) THEN 'fotografos'
    ELSE NULL
  END;
$function$;

-- ── group_category_key: ahora revisa CADA estilo separado por "/" y
--    devuelve la categoría del primero que resuelva ────────────────────────
CREATE OR REPLACE FUNCTION public.group_category_key(p_group_id uuid)
RETURNS text
LANGUAGE sql
STABLE
SET search_path TO 'public'
AS $function$
  SELECT (
    SELECT public.genre_category_key(trim(part))
    FROM public.groups g, unnest(string_to_array(g.genre, '/')) AS part
    WHERE g.id = p_group_id
      AND public.genre_category_key(trim(part)) IS NOT NULL
    LIMIT 1
  );
$function$;

-- ── dispatch_express_request: el ÚNICO cambio real es la línea del WHERE
--    que comparaba el género — el resto del cuerpo queda BYTE IDÉNTICO al
--    que ya estaba en producción. ────────────────────────────────────────
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
      public.genre_matches(g.genre, v_request.genre)
      AND (
        lower(trim(g.city))  = lower(trim(v_request.location_city))
        OR lower(trim(g.state)) = lower(trim(v_request.location_estado))
      )
      AND g.is_active = true
      AND g.suspended_at IS NULL
      -- [457] Toggle exprés del grupo: offline Y busy excluyen; NULL sigue recibiendo
      AND COALESCE(g.availability, 'available') = 'available'
      AND NOT EXISTS (
        SELECT 1 FROM public.express_dispatches ed
        WHERE ed.request_id = p_request_id
          AND ed.group_id   = g.id
      )
      -- [432] (i) El grupo bloqueó HOY (fecha local CDMX)
      AND NOT EXISTS (
        SELECT 1 FROM public.group_unavailability gu
        WHERE gu.group_id = g.id
          AND gu.date = (NOW() AT TIME ZONE 'America/Mexico_City')::date
      )
      -- [432] (ii) El grupo está tocando en este momento
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

-- ── get_surge_factor: mismos 2 puntos de comparación, ahora con
--    genre_matches en vez de ILIKE exacto. Resto BYTE IDÉNTICO. ──────────
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
  -- ── Solicitudes abiertas (aún no aceptadas, no expiradas) ─────────────────
  SELECT COUNT(*) INTO v_open_requests
  FROM public.event_requests
  WHERE status = 'open'
    AND expires_at > now()
    AND (p_genre IS NULL OR public.genre_matches(p_genre, genre))
    AND (p_city  IS NULL OR location_city ILIKE p_city);

  -- ── Grupos disponibles del mismo género ───────────────────────────────────
  SELECT COUNT(*) INTO v_available_groups
  FROM public.groups
  WHERE is_active = true
    AND (p_genre IS NULL OR public.genre_matches(p_genre, genre));

  -- ── Calcular factor ───────────────────────────────────────────────────────
  -- Máximo 15% sobre precio base → nunca excesivo frente al mercado
  v_raw_factor   := v_open_requests::NUMERIC / GREATEST(1, v_available_groups);
  v_surge_factor := LEAST(1.15, GREATEST(1.0, ROUND(v_raw_factor, 2)));

  -- ── Determinar nivel y mensaje ────────────────────────────────────────────
  -- Mensajes orientados al valor percibido, no a "alta demanda"
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

COMMIT;
