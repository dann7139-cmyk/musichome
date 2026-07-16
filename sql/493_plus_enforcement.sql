-- ============================================================
-- sql/493_plus_enforcement.sql
-- 🏆 PLUS que "jala bien" (fixes 2026-07-16):
--
--  BUG reportado: un grupo SIN Plus vigente podía subir 4-5 videos —
--  el límite (sql/492) solo miraba is_plus_active, sin checar que
--  plus_expires_at siga vigente (banderas viejas de pruebas).
--
--  1. is_group_plus(group_id): Plus EFECTIVO = activo Y no expirado.
--  2. Límite de videos usa el helper (3 sin Plus vigente, 5 con).
--  3. Cron diario expire_plus_groups(): apaga is_plus_active vencidos
--     → la insignia desaparece sola y el perfil vuelve a 3 videos
--     (el cliente ya solo ve 3: el recorte también está en la app).
--  4. get_groups_ranked_by_city devuelve is_plus_active EFECTIVO →
--     la insignia Plus se ve bien en el explorador al pagar y se cae
--     sola al vencer. (Se agrega columna al final del RETURNS TABLE —
--     compatible con los consumidores actuales.)
-- ============================================================

BEGIN;

-- ── 1. Plus efectivo ─────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.is_group_plus(p_group_id UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT COALESCE(
    (SELECT is_plus_active
        AND (plus_expires_at IS NULL OR plus_expires_at > NOW())
     FROM groups WHERE id = p_group_id),
    false
  );
$$;

GRANT EXECUTE ON FUNCTION public.is_group_plus(UUID) TO anon, authenticated;

-- ── 2. Límite de videos con Plus EFECTIVO ────────────────────
CREATE OR REPLACE FUNCTION public.guard_group_videos_limit()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_count INT;
  v_plus  BOOLEAN;
  v_max   INT;
BEGIN
  v_plus := is_group_plus(NEW.group_id);
  v_max  := CASE WHEN v_plus THEN 5 ELSE 3 END;

  SELECT COUNT(*) INTO v_count FROM group_videos
  WHERE group_id = NEW.group_id AND status <> 'rejected';

  IF v_count >= v_max THEN
    IF v_plus THEN
      RAISE EXCEPTION 'Ya tienes % videos (el máximo con Plus es 5). Elimina uno para subir otro.', v_count;
    ELSE
      RAISE EXCEPTION 'Ya tienes % videos. Con la insignia Plus desbloqueas 2 más (hasta 5).', v_count;
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

-- ── 3. Expirar Plus vencidos (cron diario) ───────────────────
CREATE OR REPLACE FUNCTION public.expire_plus_groups()
RETURNS INT LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_row   RECORD;
  v_count INT := 0;
BEGIN
  FOR v_row IN
    SELECT id, owner_id FROM groups g
    WHERE g.is_plus_active = TRUE
      AND g.plus_expires_at IS NOT NULL
      AND g.plus_expires_at < NOW()
  LOOP
    UPDATE groups SET is_plus_active = FALSE, updated_at = NOW() WHERE id = v_row.id;
    v_count := v_count + 1;
    -- Avisar al dueño (sus videos 4-5 dejan de mostrarse hasta renovar)
    SELECT owner_id INTO v_row.owner_id FROM groups WHERE id = v_row.id;
    IF v_row.owner_id IS NOT NULL THEN
      INSERT INTO notifications (user_id, type, title, body, data)
      VALUES (v_row.owner_id, 'reservation',
        '🏆 Tu insignia Plus venció',
        'Tu perfil volvió al plan básico: se muestran hasta 3 videos y la insignia Plus se ocultó. Renueva Plus para recuperar tus beneficios.',
        jsonb_build_object('screen', 'GroupReservations'));
    END IF;
  END LOOP;
  RETURN v_count;
END;
$$;

COMMIT;

DO $$ BEGIN
  PERFORM cron.unschedule('expire-plus-groups');
EXCEPTION WHEN OTHERS THEN NULL;
END; $$;
SELECT cron.schedule('expire-plus-groups', '0 6 * * *',
  $$SELECT public.expire_plus_groups();$$);

-- ── 4. Explorador: is_plus_active EFECTIVO en el ranking ─────
-- (misma función de sql/480 + columna nueva al FINAL — compatible)
DROP FUNCTION IF EXISTS public.get_groups_ranked_by_city(TEXT, TEXT, INT);
CREATE OR REPLACE FUNCTION public.get_groups_ranked_by_city(
  p_city  TEXT,
  p_state TEXT DEFAULT NULL,
  p_limit INT  DEFAULT 50
)
RETURNS TABLE (
  id                    UUID,
  name                  TEXT,
  genre                 TEXT,
  city                  TEXT,
  state                 TEXT,
  service_cities        JSONB,
  profile_image         TEXT,
  photo_status          TEXT,
  price_from            NUMERIC,
  rating                NUMERIC,
  total_reviews         INT,
  is_verified           BOOLEAN,
  verification_status   TEXT,
  is_active             BOOLEAN,
  puntos_reputacion     INT,
  bid_amount            NUMERIC,
  bid_ends_at           TIMESTAMPTZ,
  boost_score           INT,
  boost_ends_at         TIMESTAMPTZ,
  trust_score           NUMERIC,
  search_penalty        NUMERIC,
  is_high_demand        BOOLEAN,
  recent_completions    INT,
  bid_active            BOOLEAN,
  is_local              BOOLEAN,
  is_plus_active        BOOLEAN
)
LANGUAGE plpgsql
SECURITY DEFINER STABLE
SET search_path = public
AS $$
DECLARE
  v_city_norm  TEXT := CASE WHEN p_city  IS NULL THEN NULL ELSE normalize_city_name(p_city)  END;
  v_state_norm TEXT := CASE WHEN p_state IS NULL THEN NULL ELSE normalize_state_name(p_state) END;
BEGIN
  RETURN QUERY
  SELECT
    g.id, g.name, g.genre, g.city,
    g.state,
    COALESCE(g.service_cities, '[]'::JSONB),
    g.profile_image, g.photo_status, g.price_from,
    g.rating, g.total_reviews, g.is_verified, g.verification_status,
    g.is_active,
    COALESCE(g.puntos_reputacion, 0)::INT,
    COALESCE(g.bid_amount, 0::NUMERIC),
    g.bid_ends_at,
    COALESCE(g.boost_score, 0)::INT,
    g.boost_ends_at,
    COALESCE(g.trust_score, 0::NUMERIC),
    COALESCE(g.search_penalty, 0::NUMERIC),
    COALESCE(g.is_high_demand, false),
    COALESCE(g.recent_completions, 0)::INT,
    (
      g.bid_ends_at IS NOT NULL
      AND g.bid_ends_at > now()
      AND COALESCE(g.bid_amount, 0) > 0
    ) AS bid_active,
    (v_city_norm IS NULL OR normalize_city_name(g.city) = v_city_norm) AS is_local,
    -- 🏆 Plus EFECTIVO (activo Y no vencido) — la insignia del explorador
    (COALESCE(g.is_plus_active, false)
      AND (g.plus_expires_at IS NULL OR g.plus_expires_at > now())) AS is_plus_active
  FROM public.groups g
  WHERE g.is_active = true
    AND (
      v_city_norm IS NULL
      OR normalize_city_name(g.city) = v_city_norm
      OR EXISTS (
        SELECT 1
        FROM jsonb_array_elements_text(COALESCE(g.service_cities, '[]'::JSONB)) sc(city_name)
        WHERE normalize_city_name(sc.city_name) = v_city_norm
      )
    )
    AND (
      v_state_norm IS NULL
      OR g.state IS NULL
      OR normalize_state_name(g.state) = v_state_norm
    )
  ORDER BY
    (g.visibility_penalty_until IS NOT NULL AND g.visibility_penalty_until > now()) ASC,
    (v_city_norm IS NULL OR normalize_city_name(g.city) = v_city_norm) DESC,
    (g.bid_ends_at IS NOT NULL AND g.bid_ends_at > now()
      AND COALESCE(g.bid_amount, 0) > 0) DESC,
    COALESCE(g.bid_amount, 0) DESC,
    COALESCE(g.boost_score, 0) DESC,
    COALESCE(g.rating, 0) DESC,
    COALESCE(g.total_reviews, 0) DESC,
    g.created_at DESC
  LIMIT p_limit;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_groups_ranked_by_city(TEXT, TEXT, INT) TO anon, authenticated;

-- ── VERIFICACIÓN ──────────────────────────────────────────────────────────────
SELECT proname FROM pg_proc WHERE proname IN ('is_group_plus', 'expire_plus_groups');
-- Esperado: 2 filas

SELECT jobname, schedule FROM cron.job WHERE jobname = 'expire-plus-groups';
-- Esperado: 1 fila, 0 6 * * *

SELECT prosrc LIKE '%is_plus_active%' AS ranking_con_plus
FROM pg_proc WHERE proname = 'get_groups_ranked_by_city';
-- Esperado: true

-- 🧪 Si tu grupo de pruebas quedó con Plus fantasma de pruebas viejas:
-- UPDATE groups SET is_plus_active = false WHERE plus_expires_at < NOW();

SELECT '493_plus_enforcement.sql ejecutado ✅' AS status;
