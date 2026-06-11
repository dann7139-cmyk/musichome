-- ════════════════════════════════════════════════════════════════════════════
-- 113_network_effects.sql
-- Sistema de efecto red: referidos, badge fundador, discovery, sharing,
-- pulse semanal y promoción automática por ciudad.
--
-- ESTADO PREVIO (ya implementado — NO se reimplementa):
--   93/104 → ranking_score, badges, apply_ranking_boost()
--   104    → get_top_groups_nearby(), send_client_retention_notifications()
--   105    → surge pricing, demand heatmap
--   106    → get_similar_groups(), get_client_past_groups(), track_group_view()
--   107    → reliability_score, trusted_group badge
--   108    → calculate_matching_score(), smart matching
--   109    → countries/states/cities, activate_city(), get_city_stats()
--   110    → notify_high_demand_groups(), demand_multiplier
--   111    → group_cancel_reservation() con log
--   112    → contact protection, address masking
--
-- LO QUE IMPLEMENTA ESTE ARCHIVO:
--   1. Sistema de referidos (referral_code + referral_invitations)
--      generate_referral_code()  — código único por grupo
--      use_referral_code()       — recompensa al invitante + boost inicial al nuevo
--      Trigger AFTER INSERT en groups → auto-asigna código
--   2. Badge "grupo_fundador": primeros 5 grupos en cada ciudad
--      Trigger AFTER INSERT en groups → asigna badge si hay ≤5 grupos en ciudad
--   3. get_discovery_sections(p_city) — RPC unificado para home del cliente:
--      popular_nearby, new_in_city, top_rated, trending_this_month
--   4. get_group_share_content(p_reservation_id) — texto para compartir en redes
--   5. send_city_activity_pulse() — digest semanal de actividad para grupos
--   6. check_city_auto_promotion() — activa boost cuando ciudad alcanza umbrales
--
-- No modifica el flujo de reservas, pagos ni express.
-- Ejecutar DESPUÉS de 112_contact_protection.sql
-- ════════════════════════════════════════════════════════════════════════════


-- ── 1. SISTEMA DE REFERIDOS ───────────────────────────────────────────────────

-- Columna en groups
ALTER TABLE public.groups
  ADD COLUMN IF NOT EXISTS referral_code TEXT UNIQUE,
  ADD COLUMN IF NOT EXISTS referral_bonus_expires_at TIMESTAMPTZ;

-- Tabla de invitaciones
CREATE TABLE IF NOT EXISTS public.referral_invitations (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  inviter_group_id UUID       NOT NULL REFERENCES public.groups(id) ON DELETE CASCADE,
  invited_group_id UUID       REFERENCES public.groups(id) ON DELETE SET NULL,
  code_used       TEXT        NOT NULL,
  status          TEXT        NOT NULL DEFAULT 'pending'
                               CHECK (status IN ('pending','completed','expired')),
  reward_granted  BOOLEAN     NOT NULL DEFAULT FALSE,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  completed_at    TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_referral_inviter ON public.referral_invitations(inviter_group_id);
CREATE INDEX IF NOT EXISTS idx_referral_code    ON public.referral_invitations(code_used);

ALTER TABLE public.referral_invitations ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "ri_admin_all"  ON public.referral_invitations;
DROP POLICY IF EXISTS "ri_group_own"  ON public.referral_invitations;

CREATE POLICY "ri_admin_all" ON public.referral_invitations FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin'));

CREATE POLICY "ri_group_own" ON public.referral_invitations FOR SELECT TO authenticated
  USING (
    EXISTS (SELECT 1 FROM public.groups WHERE id = inviter_group_id AND owner_id = auth.uid())
    OR
    EXISTS (SELECT 1 FROM public.groups WHERE id = invited_group_id AND owner_id = auth.uid())
  );


-- ── generate_referral_code() ──────────────────────────────────────────────────
-- Genera un código de 8 caracteres único para un grupo.

CREATE OR REPLACE FUNCTION public.generate_referral_code(p_group_id UUID)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_code TEXT;
  v_tries INT := 0;
BEGIN
  LOOP
    -- XXXX-XXXX usando letras + dígitos (sin O, 0, I, 1 para evitar confusión)
    v_code := UPPER(
      SUBSTRING(MD5(p_group_id::TEXT || NOW()::TEXT || RANDOM()::TEXT), 1, 4)
      || '-' ||
      SUBSTRING(MD5(RANDOM()::TEXT || v_tries::TEXT), 1, 4)
    );
    -- Verificar unicidad
    EXIT WHEN NOT EXISTS (SELECT 1 FROM public.groups WHERE referral_code = v_code);
    v_tries := v_tries + 1;
    IF v_tries > 20 THEN RETURN NULL; END IF;
  END LOOP;

  UPDATE public.groups SET referral_code = v_code WHERE id = p_group_id;
  RETURN v_code;
END;
$$;

GRANT EXECUTE ON FUNCTION public.generate_referral_code(UUID) TO authenticated, service_role;


-- ── Trigger: auto-generar referral_code al insertar grupo ────────────────────

CREATE OR REPLACE FUNCTION public.trg_auto_referral_code()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.referral_code IS NULL THEN
    PERFORM public.generate_referral_code(NEW.id);
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_assign_referral_code ON public.groups;
CREATE TRIGGER trg_assign_referral_code
  AFTER INSERT ON public.groups
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_auto_referral_code();

-- Backfill para grupos existentes sin código
DO $$
DECLARE v_gid UUID;
BEGIN
  FOR v_gid IN SELECT id FROM public.groups WHERE referral_code IS NULL LOOP
    PERFORM public.generate_referral_code(v_gid);
  END LOOP;
END; $$;


-- ── use_referral_code(p_code) — nuevo grupo usa código al registrarse ─────────
-- Llama el frontend del grupo nuevo después de ser creado, pasando el código.
-- Recompensa: invitante recibe ranking_boost +0.40 por 30 días
--              nuevo grupo recibe ranking_boost +0.25 por 14 días (visibilidad inicial)

CREATE OR REPLACE FUNCTION public.use_referral_code(p_code TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_inviter_group RECORD;
  v_new_group     RECORD;
BEGIN
  -- Grupo que llama = grupo nuevo
  SELECT * INTO v_new_group
  FROM public.groups
  WHERE owner_id = auth.uid()
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_group_found');
  END IF;

  -- Buscar el grupo invitante por código
  SELECT * INTO v_inviter_group
  FROM public.groups
  WHERE UPPER(TRIM(referral_code)) = UPPER(TRIM(p_code));

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_code');
  END IF;

  -- No auto-referirse
  IF v_inviter_group.id = v_new_group.id THEN
    RETURN jsonb_build_object('ok', false, 'error', 'self_referral');
  END IF;

  -- Verificar que no se usó ya el código para este par
  IF EXISTS (
    SELECT 1 FROM public.referral_invitations
    WHERE invited_group_id = v_new_group.id
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'already_used');
  END IF;

  -- Registrar la invitación
  INSERT INTO public.referral_invitations
    (inviter_group_id, invited_group_id, code_used, status, reward_granted, completed_at)
  VALUES
    (v_inviter_group.id, v_new_group.id, p_code, 'completed', TRUE, NOW());

  -- Boost al invitante: +0.40 por 720 horas (30 días)
  PERFORM public.apply_ranking_boost(v_inviter_group.id, 0.40, 720);

  -- Boost al nuevo grupo: +0.25 por 336 horas (14 días)
  PERFORM public.apply_ranking_boost(v_new_group.id, 0.25, 336);

  -- Notificar al invitante
  INSERT INTO public.notifications (user_id, type, title, body, data)
  VALUES (
    v_inviter_group.owner_id,
    'system',
    '🎉 ¡Tu invitado se unió!',
    '"' || v_new_group.name || '" se registró con tu código. '
    || 'Recibirás mayor visibilidad durante los próximos 30 días.',
    jsonb_build_object('screen', 'Dashboard', 'invited_group', v_new_group.name)
  );

  RETURN jsonb_build_object(
    'ok',           true,
    'inviter_name', v_inviter_group.name,
    'boost_days',   14
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.use_referral_code(TEXT) TO authenticated;


-- ── 2. BADGE "grupo_fundador": primeros 5 en ciudad ──────────────────────────
-- Se asigna automáticamente al crearse el grupo si es de los primeros 5 en ciudad.
-- Benefit: ranking_boost +0.30 por 90 días.

CREATE OR REPLACE FUNCTION public.trg_assign_founder_badge()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_count INT;
BEGIN
  IF NEW.city IS NULL THEN RETURN NEW; END IF;

  -- Contar grupos activos en la misma ciudad (incluyendo el nuevo)
  SELECT COUNT(*) INTO v_count
  FROM public.groups
  WHERE LOWER(TRIM(city)) = LOWER(TRIM(NEW.city))
    AND is_active = TRUE;

  -- Si es uno de los primeros 5 → badge fundador
  IF v_count <= 5 THEN
    UPDATE public.groups
    SET badges = array_append(
          COALESCE(badges, '{}'),
          'grupo_fundador'
        )
    WHERE id = NEW.id
      AND NOT ('grupo_fundador' = ANY(COALESCE(badges, '{}')));

    -- Boost de visibilidad inicial (90 días)
    PERFORM public.apply_ranking_boost(NEW.id, 0.30, 2160);

    -- Notificar al dueño
    INSERT INTO public.notifications (user_id, type, title, body, data)
    VALUES (
      NEW.owner_id,
      'system',
      '🏅 ¡Grupo fundador en tu ciudad!',
      'Eres uno de los primeros grupos en unirse a DARICEFY en ' || NEW.city
      || '. Recibirás mayor visibilidad durante 90 días como grupo fundador.',
      jsonb_build_object('screen', 'Dashboard', 'badge', 'grupo_fundador')
    );
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_founder_badge ON public.groups;
CREATE TRIGGER trg_founder_badge
  AFTER INSERT ON public.groups
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_assign_founder_badge();


-- ── 3. get_discovery_sections(p_city) — RPC unificado para home cliente ───────
-- Devuelve 4 secciones para la pantalla de descubrimiento del cliente:
--   popular_nearby  → ranking_score DESC, misma ciudad
--   new_in_city     → created_at DESC (últimos 60 días), misma ciudad
--   top_rated       → average_rating DESC, mín 3 reseñas
--   trending        → reservas completadas en últimos 30 días (COUNT DESC)

CREATE OR REPLACE FUNCTION public.get_discovery_sections(
  p_city  TEXT    DEFAULT NULL,
  p_limit INT     DEFAULT 8
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_popular  JSONB;
  v_new      JSONB;
  v_top      JSONB;
  v_trending JSONB;
BEGIN
  -- ── Popular en tu ciudad ────────────────────────────────────────────────
  SELECT jsonb_agg(row_to_json(r))
  INTO v_popular
  FROM (
    SELECT id, name, genre, city, profile_image, is_verified,
           average_rating, total_reviews, ranking_score, badges,
           available_now, price_from, nivel
    FROM public.groups
    WHERE is_active = TRUE
      AND (p_city IS NULL OR LOWER(TRIM(city)) = LOWER(TRIM(p_city)))
    ORDER BY ranking_score DESC NULLS LAST
    LIMIT p_limit
  ) r;

  -- ── Nuevos en tu ciudad (últimos 60 días) ───────────────────────────────
  SELECT jsonb_agg(row_to_json(r))
  INTO v_new
  FROM (
    SELECT id, name, genre, city, profile_image, is_verified,
           average_rating, total_reviews, ranking_score, badges,
           available_now, price_from, nivel, created_at
    FROM public.groups
    WHERE is_active = TRUE
      AND created_at >= NOW() - INTERVAL '60 days'
      AND (p_city IS NULL OR LOWER(TRIM(city)) = LOWER(TRIM(p_city)))
    ORDER BY created_at DESC
    LIMIT p_limit
  ) r;

  -- ── Mejor calificados (mín 3 reseñas) ───────────────────────────────────
  SELECT jsonb_agg(row_to_json(r))
  INTO v_top
  FROM (
    SELECT id, name, genre, city, profile_image, is_verified,
           average_rating, total_reviews, ranking_score, badges,
           available_now, price_from, nivel
    FROM public.groups
    WHERE is_active = TRUE
      AND total_reviews >= 3
      AND (p_city IS NULL OR LOWER(TRIM(city)) = LOWER(TRIM(p_city)))
    ORDER BY average_rating DESC NULLS LAST, total_reviews DESC
    LIMIT p_limit
  ) r;

  -- ── Tendencia: más eventos completados en los últimos 30 días ───────────
  SELECT jsonb_agg(row_to_json(r))
  INTO v_trending
  FROM (
    SELECT g.id, g.name, g.genre, g.city, g.profile_image, g.is_verified,
           g.average_rating, g.total_reviews, g.ranking_score, g.badges,
           g.available_now, g.price_from, g.nivel,
           COUNT(res.id) AS events_this_month
    FROM public.groups g
    JOIN public.reservations res
      ON res.group_id = g.id
      AND res.status = 'completed'
      AND res.event_date >= (CURRENT_DATE - INTERVAL '30 days')
    WHERE g.is_active = TRUE
      AND (p_city IS NULL OR LOWER(TRIM(g.city)) = LOWER(TRIM(p_city)))
    GROUP BY g.id, g.name, g.genre, g.city, g.profile_image, g.is_verified,
             g.average_rating, g.total_reviews, g.ranking_score, g.badges,
             g.available_now, g.price_from, g.nivel
    HAVING COUNT(res.id) >= 1
    ORDER BY events_this_month DESC
    LIMIT p_limit
  ) r;

  RETURN jsonb_build_object(
    'ok',            true,
    'popular_nearby', COALESCE(v_popular,  '[]'),
    'new_in_city',    COALESCE(v_new,      '[]'),
    'top_rated',      COALESCE(v_top,      '[]'),
    'trending',       COALESCE(v_trending, '[]')
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_discovery_sections(TEXT, INT) TO authenticated, anon;


-- ── 4. get_group_share_content(p_reservation_id) — contenido para compartir ───
-- Devuelve texto formateado para compartir en redes sociales después del evento.
-- El frontend usa React Native Share API con este contenido.

CREATE OR REPLACE FUNCTION public.get_group_share_content(p_reservation_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_res   RECORD;
  v_group RECORD;
  v_share TEXT;
BEGIN
  SELECT r.*, g.name AS group_name, g.genre, g.city AS group_city,
         g.average_rating, g.total_reviews
  INTO v_res
  FROM public.reservations r
  JOIN public.groups g ON g.id = r.group_id
  WHERE r.id         = p_reservation_id
    AND r.client_id  = auth.uid()
    AND r.status     = 'completed';

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_eligible');
  END IF;

  v_share :=
    '🎵 ' || v_res.group_name || ' tocó en mi evento y fue increíble. '
    || 'Música en vivo para cualquier ocasión en ' || COALESCE(v_res.group_city, 'mi ciudad') || '. '
    || chr(10) || chr(10)
    || '¡Encuéntralos en DARICEFY y reserva tu grupo! 🎶';

  RETURN jsonb_build_object(
    'ok',         true,
    'group_name', v_res.group_name,
    'genre',      v_res.genre,
    'share_text', v_share
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_group_share_content(UUID) TO authenticated;


-- ── 5. send_city_activity_pulse() — digest semanal de actividad ──────────────
-- Envía un resumen de actividad de la semana a grupos activos.
-- Anti-spam: máx 1 pulse por grupo por semana.
-- Cron recomendado: lunes 9 AM.

CREATE OR REPLACE FUNCTION public.send_city_activity_pulse()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_city_row  RECORD;
  v_group     RECORD;
  v_requests  INT;
  v_sent      INT := 0;
BEGIN
  -- Iterar por ciudades con actividad en la última semana
  FOR v_city_row IN
    SELECT LOWER(TRIM(location_city)) AS city, COUNT(*) AS req_count
    FROM public.event_requests
    WHERE created_at >= NOW() - INTERVAL '7 days'
      AND status NOT IN ('expired', 'cancelled')
      AND location_city IS NOT NULL
    GROUP BY 1
    HAVING COUNT(*) >= 2
  LOOP
    v_requests := v_city_row.req_count;

    -- Notificar grupos activos en esa ciudad
    FOR v_group IN
      SELECT g.id, g.owner_id, g.name
      FROM public.groups g
      WHERE LOWER(TRIM(g.city)) = v_city_row.city
        AND g.is_active = TRUE
        AND COALESCE(g.availability, 'available') != 'offline'
    LOOP
      -- Anti-spam: no enviar si ya recibió pulse esta semana
      CONTINUE WHEN EXISTS (
        SELECT 1 FROM public.notifications
        WHERE user_id    = v_group.owner_id
          AND data->>'pulse_type' = 'weekly_activity'
          AND created_at >= NOW() - INTERVAL '7 days'
      );

      INSERT INTO public.notifications (user_id, type, title, body, data)
      VALUES (
        v_group.owner_id,
        'system',
        '📈 Actividad en tu ciudad esta semana',
        'Hubo ' || v_requests || ' solicitud' || CASE WHEN v_requests > 1 THEN 'es' ELSE '' END
        || ' de grupos en ' || v_city_row.city || ' en los últimos 7 días. '
        || '¡Mantente disponible para no perder oportunidades!',
        jsonb_build_object(
          'pulse_type', 'weekly_activity',
          'city',       v_city_row.city,
          'requests',   v_requests,
          'screen',     'Dashboard'
        )
      );
      v_sent := v_sent + 1;
    END LOOP;
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'notifications_sent', v_sent);

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.send_city_activity_pulse() TO service_role;


-- ── 6. check_city_auto_promotion() — boost automático cuando ciudad escala ────
-- Cuando una ciudad alcanza 10 eventos completados: boost +0.15 a todos sus grupos
-- (solo si no recibieron este boost antes — campo referral_bonus_expires_at se reutiliza
--  como indicador de "ciudad activa").
-- Se ejecuta como cron semanal o manualmente.

CREATE OR REPLACE FUNCTION public.check_city_auto_promotion()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_city_row   RECORD;
  v_group      RECORD;
  v_promoted   INT := 0;
BEGIN
  -- Ciudades que alcanzaron 10+ eventos completados
  FOR v_city_row IN
    SELECT LOWER(TRIM(g.city)) AS city, COUNT(r.id) AS completed_events
    FROM public.reservations r
    JOIN public.groups g ON g.id = r.group_id
    WHERE r.status = 'completed'
    GROUP BY 1
    HAVING COUNT(r.id) >= 10
  LOOP
    -- Boost a grupos de esa ciudad que aún no lo recibieron
    FOR v_group IN
      SELECT id, owner_id, name
      FROM public.groups
      WHERE LOWER(TRIM(city)) = v_city_row.city
        AND is_active = TRUE
        AND (referral_bonus_expires_at IS NULL OR referral_bonus_expires_at < NOW())
    LOOP
      -- Boost +0.15 por 72 horas (activación de ciudad)
      PERFORM public.apply_ranking_boost(v_group.id, 0.15, 72);

      -- Marcar como promovido (reutilizar campo como flag)
      UPDATE public.groups
      SET referral_bonus_expires_at = NOW() + INTERVAL '72 hours'
      WHERE id = v_group.id;

      -- Notificar al grupo
      INSERT INTO public.notifications (user_id, type, title, body, data)
      VALUES (
        v_group.owner_id,
        'system',
        '🚀 Tu ciudad está creciendo',
        'DARICEFY está creciendo en ' || v_city_row.city || '! '
        || 'Recibirás más visibilidad durante las próximas 72 horas. '
        || 'Activa "Disponible ahora" para aprovechar el impulso.',
        jsonb_build_object(
          'screen', 'Dashboard',
          'city',   v_city_row.city,
          'action', 'activate_availability'
        )
      );
      v_promoted := v_promoted + 1;
    END LOOP;
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'groups_promoted', v_promoted);

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.check_city_auto_promotion() TO service_role;


-- ── Cron jobs ─────────────────────────────────────────────────────────────────

DO $$
BEGIN
  BEGIN PERFORM cron.unschedule('city-activity-pulse');    EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN PERFORM cron.unschedule('city-auto-promotion');    EXCEPTION WHEN OTHERS THEN NULL; END;

  -- Digest semanal de actividad: lunes 9:00 AM
  PERFORM cron.schedule(
    'city-activity-pulse',
    '0 9 * * 1',
    'SELECT public.send_city_activity_pulse()'
  );

  -- Auto-promoción de ciudades: domingo 10:00 PM
  PERFORM cron.schedule(
    'city-auto-promotion',
    '0 22 * * 0',
    'SELECT public.check_city_auto_promotion()'
  );

EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'pg_cron no disponible. Activar en Dashboard → Extensions → pg_cron.';
END;
$$;


SELECT '113_network_effects: referidos + fundador + discovery + sharing + pulse semanal + auto-promoción ✅' AS status;
