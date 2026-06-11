-- ════════════════════════════════════════════════════════════════════════════
-- 106_airbnb_conversions.sql
-- Mejoras de conversión y retención inspiradas en Airbnb
--
-- ESTADO DEL SISTEMA (ya implementado — no se re-implementa):
--   104 → send_client_retention_notifications() — notificaciones 24h/7d/30d
--   104 → get_group_scarcity()                 — reservas semanales/mensuales
--
-- LO QUE IMPLEMENTA ESTE ARCHIVO:
--   1. get_client_past_groups()      — sección "Reserva nuevamente" en la app
--   2. get_similar_groups()          — "Grupos similares" en perfil del grupo
--   3. group_profile_views           — tabla liviana de vistas de perfil
--      track_group_view()            — registra cada visita al perfil
--      get_group_activity_snapshot() — combina escasez + viewers en 1 RPC
--
-- No modifica flujo de reservas, pagos ni solicitudes express.
-- Ejecutar DESPUÉS de 105_uber_marketplace.sql
-- ════════════════════════════════════════════════════════════════════════════


-- ────────────────────────────────────────────────────────────────────────────
-- PARTE 1: "RESERVA NUEVAMENTE" — Repeat Booking
-- ────────────────────────────────────────────────────────────────────────────
-- RPC para poblar la sección "Reserva nuevamente" en la pantalla del cliente.
-- Devuelve grupos que el cliente ya contrató, ordenados por más reciente.
-- Incluye: info del grupo + última fecha contratada + total de eventos juntos.
--
-- Nota: las notificaciones 24h/7d/30d ya están implementadas en 104.
--       Esta función solo proporciona los datos para la UI.
-- ────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.get_client_past_groups(
  p_limit INT DEFAULT 10
)
RETURNS TABLE (
  group_id        UUID,
  name            TEXT,
  genre           TEXT,
  city            TEXT,
  average_rating  NUMERIC,
  total_reviews   INT,
  ranking_score   NUMERIC,
  badges          TEXT[],
  availability    TEXT,
  last_booked     DATE,         -- fecha del último evento con este grupo
  times_booked    BIGINT,       -- cuántas veces lo ha contratado este cliente
  last_genre      TEXT,         -- género de la última reserva (para el contexto)
  can_rebook      BOOLEAN       -- true si el grupo está activo y disponible
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT
    g.id                                          AS group_id,
    g.name,
    g.genre,
    g.city,
    g.average_rating,
    g.total_reviews,
    g.ranking_score,
    g.badges,
    COALESCE(g.availability, 'available')         AS availability,
    MAX(r.event_date)                             AS last_booked,
    COUNT(r.id)                                   AS times_booked,
    g.genre                                       AS last_genre,
    (g.is_active AND COALESCE(g.availability, 'available') != 'offline') AS can_rebook
  FROM public.reservations r
  JOIN public.groups g ON g.id = r.group_id
  WHERE r.client_id = auth.uid()
    AND r.status IN ('completed', 'confirmed', 'deposit_paid')
  GROUP BY
    g.id, g.name, g.genre, g.city,
    g.average_rating, g.total_reviews, g.ranking_score,
    g.badges, g.availability, g.is_active
  ORDER BY
    MAX(r.event_date) DESC   -- más reciente primero
  LIMIT p_limit;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_client_past_groups(INT) TO authenticated;


-- ────────────────────────────────────────────────────────────────────────────
-- PARTE 2: GRUPOS SIMILARES — Recommendations
-- ────────────────────────────────────────────────────────────────────────────
-- Muestra en el perfil de un grupo la sección "Grupos similares".
-- Algoritmo de similitud:
--   • Mismo género          → filtro obligatorio
--   • Misma ciudad          → puntaje alto
--   • Buena calificación    → puntaje según rating
--   • Activo y disponible   → filtro obligatorio
--   • No es el mismo grupo  → filtro obligatorio
--
-- Orden final: similarity_score DESC, ranking_score DESC
-- ────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.get_similar_groups(
  p_group_id UUID,
  p_limit    INT DEFAULT 6
)
RETURNS TABLE (
  group_id         UUID,
  name             TEXT,
  genre            TEXT,
  city             TEXT,
  average_rating   NUMERIC,
  total_reviews    INT,
  ranking_score    NUMERIC,
  badges           TEXT[],
  availability     TEXT,
  similarity_score NUMERIC   -- solo para debugging; el frontend puede ignorarlo
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_source RECORD;
BEGIN
  -- Cargar datos del grupo de referencia
  SELECT genre, city, average_rating
  INTO   v_source
  FROM   public.groups
  WHERE  id = p_group_id;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  RETURN QUERY
  SELECT
    g.id,
    g.name,
    g.genre,
    g.city,
    g.average_rating,
    g.total_reviews,
    g.ranking_score,
    g.badges,
    COALESCE(g.availability, 'available'),
    -- Fórmula de similitud (0–10):
    --   misma ciudad   → +4.0
    --   rating ≥ 4.5   → +3.0  | ≥ 4.0 → +2.0 | ≥ 3.0 → +1.0
    --   ranking_score  → hasta +3.0 (normalizado sobre 5)
    ROUND((
      CASE WHEN LOWER(TRIM(g.city)) = LOWER(TRIM(v_source.city)) THEN 4.0 ELSE 0.0 END
      + CASE
          WHEN COALESCE(g.average_rating, 0) >= 4.5 THEN 3.0
          WHEN COALESCE(g.average_rating, 0) >= 4.0 THEN 2.0
          WHEN COALESCE(g.average_rating, 0) >= 3.0 THEN 1.0
          ELSE 0.0
        END
      + (COALESCE(g.ranking_score, 0) / 5.0 * 3.0)
    )::NUMERIC, 2)                                       AS similarity_score
  FROM public.groups g
  WHERE g.id        != p_group_id             -- excluir el mismo grupo
    AND g.genre      = v_source.genre          -- mismo género (obligatorio)
    AND g.is_active  = TRUE
    AND COALESCE(g.availability, 'available') != 'offline'
    AND COALESCE(g.average_rating, 0) >= 3.0  -- mínimo calidad aceptable
  ORDER BY
    similarity_score DESC,
    g.ranking_score  DESC
  LIMIT p_limit;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_similar_groups(UUID, INT) TO authenticated, anon;


-- ────────────────────────────────────────────────────────────────────────────
-- PARTE 3: VISTAS DE PERFIL + ACTIVIDAD EN TIEMPO REAL
-- ────────────────────────────────────────────────────────────────────────────
-- Tabla liviana que registra visitas a perfiles de grupos.
-- Permite mostrar "X clientes están viendo este grupo ahora."
--
-- Diseño:
--   • 1 fila por (group_id, viewer_id) — ON CONFLICT actualiza last_viewed
--   • Las vistas expiran de la consulta a los 30 minutos ("ahora")
--   • Se limpian filas viejas via cron diario
-- ────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.group_profile_views (
  group_id    UUID        NOT NULL REFERENCES public.groups(id) ON DELETE CASCADE,
  viewer_id   UUID        NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  last_viewed TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (group_id, viewer_id)
);

ALTER TABLE public.group_profile_views ENABLE ROW LEVEL SECURITY;

-- Solo autenticados pueden registrar su vista
DROP POLICY IF EXISTS "gpv_insert_self" ON public.group_profile_views;
CREATE POLICY "gpv_insert_self" ON public.group_profile_views
  FOR INSERT TO authenticated
  WITH CHECK (viewer_id = auth.uid());

-- Pueden actualizar su propia vista
DROP POLICY IF EXISTS "gpv_update_self" ON public.group_profile_views;
CREATE POLICY "gpv_update_self" ON public.group_profile_views
  FOR UPDATE TO authenticated
  USING (viewer_id = auth.uid());

-- El dueño del grupo puede ver quién vio su perfil; todos pueden ver counts
DROP POLICY IF EXISTS "gpv_read" ON public.group_profile_views;
CREATE POLICY "gpv_read" ON public.group_profile_views
  FOR SELECT TO authenticated
  USING (true);

CREATE INDEX IF NOT EXISTS idx_gpv_group_time
  ON public.group_profile_views(group_id, last_viewed DESC);

-- ── track_group_view() ───────────────────────────────────────────────────
-- El frontend llama esto cuando el cliente abre el perfil de un grupo.
-- UPSERT: actualiza last_viewed si ya existe, inserta si no.

CREATE OR REPLACE FUNCTION public.track_group_view(p_group_id UUID)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  INSERT INTO public.group_profile_views (group_id, viewer_id, last_viewed)
  VALUES (p_group_id, auth.uid(), NOW())
  ON CONFLICT (group_id, viewer_id)
  DO UPDATE SET last_viewed = NOW();
$$;

GRANT EXECUTE ON FUNCTION public.track_group_view(UUID) TO authenticated;

-- ── get_group_activity_snapshot() ────────────────────────────────────────
-- RPC principal para la sección de urgencia/escasez en el perfil del grupo.
-- Combina:
--   • Datos de reservas recientes (de get_group_scarcity en 104)
--   • Viewers activos (últimos 30 min)
--   • Mensaje generado listo para mostrar en la UI
--
-- El frontend llama esto al abrir un perfil de grupo y muestra los badges.
-- ─────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.get_group_activity_snapshot(p_group_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_scarcity         JSONB;
  v_active_viewers   INT;
  v_weekly_bookings  INT;
  v_monthly_bookings INT;
  v_is_weekend_busy  BOOLEAN;
  v_total_bookings   INT;
  v_badges           JSONB[] := ARRAY[]::JSONB[];
  v_primary_message  TEXT;
  v_secondary_message TEXT;
BEGIN
  -- ── Viewers activos (últimos 30 minutos) ─────────────────────────────────
  SELECT COUNT(DISTINCT viewer_id) INTO v_active_viewers
  FROM public.group_profile_views
  WHERE group_id  = p_group_id
    AND last_viewed > NOW() - INTERVAL '30 minutes'
    AND viewer_id != auth.uid();    -- no contarse a sí mismo

  -- ── Datos de reservas recientes ──────────────────────────────────────────
  SELECT COUNT(*) INTO v_weekly_bookings
  FROM public.reservations
  WHERE group_id = p_group_id
    AND status IN ('confirmed', 'deposit_paid', 'in_progress', 'completed')
    AND event_date >= CURRENT_DATE - 7;

  SELECT COUNT(*) INTO v_monthly_bookings
  FROM public.reservations
  WHERE group_id = p_group_id
    AND status IN ('confirmed', 'deposit_paid', 'in_progress', 'completed')
    AND event_date >= CURRENT_DATE - 30;

  SELECT COUNT(*) INTO v_total_bookings
  FROM public.reservations
  WHERE group_id = p_group_id
    AND status IN ('confirmed', 'deposit_paid', 'in_progress', 'completed');

  -- ¿Popular en fines de semana? (últimos 60 días)
  SELECT (COUNT(*) >= 3) INTO v_is_weekend_busy
  FROM public.reservations
  WHERE group_id = p_group_id
    AND status IN ('confirmed', 'deposit_paid', 'completed')
    AND event_date >= CURRENT_DATE - 60
    AND EXTRACT(DOW FROM event_date) IN (5, 6, 0);

  -- ── Construir badges (máximo 3 mensajes, de mayor a menor urgencia) ──────

  -- Badge 1: viewers activos (urgencia en tiempo real)
  IF v_active_viewers >= 2 THEN
    v_badges := array_append(v_badges, jsonb_build_object(
      'type',    'viewers',
      'message', v_active_viewers::TEXT || ' clientes están viendo este grupo ahora.',
      'icon',    'eye'
    ));
  ELSIF v_active_viewers = 1 THEN
    v_badges := array_append(v_badges, jsonb_build_object(
      'type',    'viewers',
      'message', 'Otro cliente está viendo este grupo ahora.',
      'icon',    'eye'
    ));
  END IF;

  -- Badge 2: reservas recientes (prueba social)
  IF v_weekly_bookings >= 3 THEN
    v_badges := array_append(v_badges, jsonb_build_object(
      'type',    'bookings',
      'message', 'Este grupo ha sido reservado ' || v_weekly_bookings || ' veces esta semana.',
      'icon',    'calendar'
    ));
  ELSIF v_monthly_bookings >= 4 THEN
    v_badges := array_append(v_badges, jsonb_build_object(
      'type',    'bookings',
      'message', 'Este grupo ha sido reservado ' || v_monthly_bookings || ' veces este mes.',
      'icon',    'calendar'
    ));
  END IF;

  -- Badge 3: patrón de fin de semana (escasez anticipada)
  IF v_is_weekend_busy AND EXTRACT(DOW FROM CURRENT_DATE) IN (3, 4) THEN  -- miércoles o jueves
    v_badges := array_append(v_badges, jsonb_build_object(
      'type',    'scarcity',
      'message', 'Este grupo suele llenarse los fines de semana. ¡Reserva con tiempo!',
      'icon',    'fire'
    ));
  ELSIF v_is_weekend_busy THEN
    v_badges := array_append(v_badges, jsonb_build_object(
      'type',    'scarcity',
      'message', 'Este grupo suele llenarse los fines de semana.',
      'icon',    'fire'
    ));
  END IF;

  -- Badge 4: milestone de eventos totales (solo si no hay otros badges)
  IF array_length(v_badges, 1) IS NULL AND v_total_bookings >= 10 THEN
    v_badges := array_append(v_badges, jsonb_build_object(
      'type',    'milestone',
      'message', v_total_bookings::TEXT || ' eventos completados con éxito.',
      'icon',    'star'
    ));
  END IF;

  RETURN jsonb_build_object(
    'ok',              true,
    'active_viewers',  v_active_viewers,
    'weekly_bookings', v_weekly_bookings,
    'monthly_bookings',v_monthly_bookings,
    'total_bookings',  v_total_bookings,
    'is_weekend_busy', v_is_weekend_busy,
    'badges',          to_jsonb(v_badges)    -- array de badges para la UI
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_group_activity_snapshot(UUID) TO authenticated, anon;


-- ────────────────────────────────────────────────────────────────────────────
-- LIMPIEZA AUTOMÁTICA DE VISTAS ANTIGUAS
-- ────────────────────────────────────────────────────────────────────────────
-- Las vistas con más de 24 horas ya no son relevantes para "viendo ahora".
-- Limpiar diariamente para mantener la tabla liviana.

DO $$ BEGIN PERFORM cron.unschedule('cleanup-profile-views'); EXCEPTION WHEN OTHERS THEN NULL; END; $$;
SELECT cron.schedule(
  'cleanup-profile-views',
  '0 4 * * *',     -- diario a las 4am
  $$ DELETE FROM public.group_profile_views WHERE last_viewed < NOW() - INTERVAL '24 hours'; $$
);


-- ════════════════════════════════════════════════════════════════════════════
-- USO DESDE EL FRONTEND
-- ════════════════════════════════════════════════════════════════════════════
--
-- 1. Sección "Reserva nuevamente" (pantalla Home / Mis Reservas del cliente):
--    supabase.rpc('get_client_past_groups', { p_limit: 10 })
--    → [{ group_id, name, genre, last_booked, times_booked, can_rebook, ... }]
--    Mostrar como carrusel horizontal: "Grupos que ya has contratado"
--
-- 2. Sección "Grupos similares" (GroupDetail screen, al final):
--    supabase.rpc('get_similar_groups', { p_group_id: id, p_limit: 6 })
--    → [{ group_id, name, genre, average_rating, ... }]
--    Mostrar como grid 2x3 o lista horizontal
--
-- 3. Badges de actividad (GroupDetail screen, debajo del nombre del grupo):
--    Al abrir GroupDetail, llamar en paralelo:
--
--    // Registrar la visita
--    supabase.rpc('track_group_view', { p_group_id: id })
--
--    // Obtener badges de urgencia
--    supabase.rpc('get_group_activity_snapshot', { p_group_id: id })
--    → { badges: [{ type, message, icon }, ...], active_viewers, ... }
--
--    Mostrar cada badge como una pill pequeña debajo de la calificación:
--    👁 "2 clientes están viendo este grupo ahora."
--    📅 "Reservado 4 veces esta semana."
--    🔥 "Suele llenarse los fines de semana."
--
-- 4. Notificaciones de seguimiento post-evento:
--    Ya implementadas en 104 → send_client_retention_notifications()
--    Se envían automáticamente a las 24h, 7d y 30d post-evento.
-- ════════════════════════════════════════════════════════════════════════════

SELECT '106_airbnb_conversions: past_groups + similar_groups + activity_snapshot ✅' AS status;
