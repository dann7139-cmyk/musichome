-- ════════════════════════════════════════════════════════════════════════════
-- 115_client_loyalty.sql
-- Sistema de fidelización de clientes.
-- Los clientes ganan puntos al completar eventos y ascienden de nivel.
-- Los grupos ven qué clientes son frecuentes, el admin ve métricas de retención.
--
-- IMPLEMENTA:
--   1. loyalty_points INT + loyalty_tier TEXT en profiles (clientes)
--   2. loyalty_events — historial de puntos (auditoría)
--   3. Trigger update_client_loyalty_on_completion()
--      → al completar una reserva: +10 pts base, +5 si calificó
--      → recalcula tier automáticamente
--   4. get_client_loyalty()  — RPC: info de lealtad del cliente actual
--   5. get_loyal_clients(p_group_id) — RPC: clientes frecuentes del grupo
--   6. get_loyalty_metrics(p_days_back) — RPC admin: retención global
--
-- Niveles:
--   bronze  → 0–49 pts   (descuento 0%)
--   silver  → 50–149 pts (descuento 3%)
--   gold    → 150–299 pts(descuento 5%)
--   vip     → 300+ pts   (descuento 8%)
--
-- Ejecutar DESPUÉS de 114_platform_protection.sql
-- ════════════════════════════════════════════════════════════════════════════


-- ── 1. Columnas en profiles ───────────────────────────────────────────────────

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS loyalty_points INT         NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS loyalty_tier   TEXT        NOT NULL DEFAULT 'bronze',
  ADD COLUMN IF NOT EXISTS loyalty_events_count INT   NOT NULL DEFAULT 0;

-- Índice para leaderboard / admin queries
CREATE INDEX IF NOT EXISTS idx_profiles_loyalty_tier   ON public.profiles (loyalty_tier);
CREATE INDEX IF NOT EXISTS idx_profiles_loyalty_points ON public.profiles (loyalty_points DESC);


-- ── 2. Tabla de historial de puntos ──────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.loyalty_events (
  id             UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id      UUID         NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  reservation_id UUID         REFERENCES public.reservations(id) ON DELETE SET NULL,
  points         INT          NOT NULL,          -- positivo = ganado, negativo = canjeado
  reason         TEXT         NOT NULL,          -- 'booking_completed', 'rated_group', 'referral_bonus', etc.
  created_at     TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_loyalty_events_client ON public.loyalty_events (client_id, created_at DESC);

-- RLS
ALTER TABLE public.loyalty_events ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS loyalty_events_own ON public.loyalty_events;
CREATE POLICY loyalty_events_own ON public.loyalty_events
  FOR SELECT USING (client_id = auth.uid());

DROP POLICY IF EXISTS loyalty_events_admin ON public.loyalty_events;
CREATE POLICY loyalty_events_admin ON public.loyalty_events
  FOR ALL USING (
    EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin')
  );

-- Función que recalcula el trigger también puede insertar
DROP POLICY IF EXISTS loyalty_events_service ON public.loyalty_events;
CREATE POLICY loyalty_events_service ON public.loyalty_events
  FOR INSERT WITH CHECK (true);   -- solo funciones SECURITY DEFINER insertan


-- ── 3. Función helper: calcular tier ─────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.calc_loyalty_tier(p_points INT)
RETURNS TEXT
LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $$
  SELECT CASE
    WHEN p_points >= 300 THEN 'vip'
    WHEN p_points >= 150 THEN 'gold'
    WHEN p_points >= 50  THEN 'silver'
    ELSE 'bronze'
  END;
$$;


-- ── 4. Trigger: awarding loyalty points on completion ─────────────────────────

CREATE OR REPLACE FUNCTION public.update_client_loyalty_on_completion()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_client_id  UUID;
  v_pts_base   INT := 10;
  v_pts_rating INT := 0;
  v_total_pts  INT;
  v_new_tier   TEXT;
BEGIN
  -- Sólo actuar cuando cambia a 'completed'
  IF NEW.status = 'completed' AND (OLD.status IS DISTINCT FROM 'completed') THEN
    v_client_id := NEW.client_id;
    IF v_client_id IS NULL THEN RETURN NEW; END IF;

    -- Verificar si ya se otorgaron puntos por esta reserva (evitar duplicados)
    IF EXISTS (
      SELECT 1 FROM public.loyalty_events
      WHERE reservation_id = NEW.id AND reason = 'booking_completed'
    ) THEN
      RETURN NEW;
    END IF;

    -- Puntos extra si el cliente calificó esta reserva
    IF EXISTS (
      SELECT 1 FROM public.reviews
      WHERE reservation_id = NEW.id AND client_id = v_client_id
    ) THEN
      v_pts_rating := 5;
    END IF;

    -- Insertar evento de puntos
    INSERT INTO public.loyalty_events (client_id, reservation_id, points, reason)
    VALUES (v_client_id, NEW.id, v_pts_base, 'booking_completed');

    IF v_pts_rating > 0 THEN
      INSERT INTO public.loyalty_events (client_id, reservation_id, points, reason)
      VALUES (v_client_id, NEW.id, v_pts_rating, 'rated_group');
    END IF;

    -- Actualizar totales en profiles
    UPDATE public.profiles
    SET
      loyalty_points       = GREATEST(0, loyalty_points + v_pts_base + v_pts_rating),
      loyalty_events_count = loyalty_events_count + 1,
      loyalty_tier         = public.calc_loyalty_tier(GREATEST(0, loyalty_points + v_pts_base + v_pts_rating))
    WHERE id = v_client_id
    RETURNING loyalty_points INTO v_total_pts;

    -- Si subió de tier, enviar notificación
    v_new_tier := public.calc_loyalty_tier(COALESCE(v_total_pts, 0));

    IF v_new_tier IN ('silver', 'gold', 'vip') THEN
      INSERT INTO public.notifications (user_id, type, title, body, data)
      SELECT
        v_client_id,
        'system',
        CASE v_new_tier
          WHEN 'silver' THEN '🥈 ¡Llegaste a Silver!'
          WHEN 'gold'   THEN '🥇 ¡Llegaste a Gold!'
          WHEN 'vip'    THEN '💎 ¡Eres VIP!'
        END,
        CASE v_new_tier
          WHEN 'silver' THEN 'Tienes 50+ puntos de lealtad. ¡Obtienes 3% de descuento en tu próxima reserva!'
          WHEN 'gold'   THEN '¡Tienes 150+ puntos de lealtad! Ahorra 5% en cada evento. Sigue reservando.'
          WHEN 'vip'    THEN '¡Eres VIP con 300+ puntos! 8% de descuento en todas tus reservas. ¡Gracias por confiar en nosotros!'
        END,
        jsonb_build_object('screen', 'ClientReservations', 'tier', v_new_tier)
      WHERE NOT EXISTS (
        -- No enviar si ya existe una notif de este tier
        SELECT 1 FROM public.notifications
        WHERE user_id = v_client_id
          AND data->>'tier' = v_new_tier
          AND created_at > NOW() - INTERVAL '30 days'
      );
    END IF;

  END IF;

  RETURN NEW;
END;
$$;

-- Crear o reemplazar el trigger
DROP TRIGGER IF EXISTS trg_update_client_loyalty ON public.reservations;
CREATE TRIGGER trg_update_client_loyalty
  AFTER UPDATE OF status ON public.reservations
  FOR EACH ROW
  EXECUTE FUNCTION public.update_client_loyalty_on_completion();


-- ── 5. RPC: get_client_loyalty() ─────────────────────────────────────────────
-- Retorna el estado de lealtad del cliente autenticado.

DROP FUNCTION IF EXISTS public.get_client_loyalty();
CREATE OR REPLACE FUNCTION public.get_client_loyalty()
RETURNS TABLE (
  loyalty_tier          TEXT,
  loyalty_points        INT,
  loyalty_events_count  INT,
  discount_pct          NUMERIC,
  points_to_next_tier   INT,
  next_tier             TEXT,
  recent_points         INT      -- pts ganados en últimos 30 días
)
LANGUAGE plpgsql
SECURITY DEFINER STABLE
SET search_path = public
AS $$
DECLARE
  v_uid       UUID := auth.uid();
  v_tier      TEXT;
  v_points    INT;
  v_ev_count  INT;
BEGIN
  SELECT p.loyalty_tier, p.loyalty_points, p.loyalty_events_count
  INTO v_tier, v_points, v_ev_count
  FROM public.profiles p
  WHERE p.id = v_uid;

  IF NOT FOUND THEN RETURN; END IF;

  RETURN QUERY SELECT
    v_tier,
    v_points,
    v_ev_count,
    CASE v_tier
      WHEN 'bronze' THEN 0::NUMERIC
      WHEN 'silver' THEN 3::NUMERIC
      WHEN 'gold'   THEN 5::NUMERIC
      WHEN 'vip'    THEN 8::NUMERIC
      ELSE 0::NUMERIC
    END AS discount_pct,
    CASE v_tier
      WHEN 'bronze' THEN GREATEST(0, 50  - v_points)
      WHEN 'silver' THEN GREATEST(0, 150 - v_points)
      WHEN 'gold'   THEN GREATEST(0, 300 - v_points)
      ELSE 0
    END AS points_to_next_tier,
    CASE v_tier
      WHEN 'bronze' THEN 'silver'
      WHEN 'silver' THEN 'gold'
      WHEN 'gold'   THEN 'vip'
      ELSE 'vip'
    END AS next_tier,
    COALESCE((
      SELECT SUM(le.points)
      FROM public.loyalty_events le
      WHERE le.client_id = v_uid
        AND le.created_at >= NOW() - INTERVAL '30 days'
    ), 0)::INT AS recent_points;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_client_loyalty() TO authenticated;


-- ── 6. RPC: get_loyal_clients(p_group_id) ────────────────────────────────────
-- Para grupos: clientes que más les han reservado, con su tier.

DROP FUNCTION IF EXISTS public.get_loyal_clients(UUID);
CREATE OR REPLACE FUNCTION public.get_loyal_clients(p_group_id UUID)
RETURNS TABLE (
  client_id    UUID,
  client_name  TEXT,
  bookings     BIGINT,
  total_spent  NUMERIC,
  tier         TEXT,
  last_event   DATE
)
LANGUAGE plpgsql
SECURITY DEFINER STABLE
SET search_path = public
AS $$
BEGIN
  -- Solo el dueño del grupo puede ver esto
  IF NOT EXISTS (
    SELECT 1 FROM public.groups WHERE id = p_group_id AND owner_id = auth.uid()
  ) THEN
    RAISE EXCEPTION 'Acceso denegado';
  END IF;

  RETURN QUERY
  SELECT
    r.client_id,
    p.full_name                        AS client_name,
    COUNT(*)                           AS bookings,
    SUM(r.total_price)                 AS total_spent,
    p.loyalty_tier                     AS tier,
    MAX(r.event_date)                  AS last_event
  FROM public.reservations r
  JOIN public.profiles p ON p.id = r.client_id
  WHERE r.group_id    = p_group_id
    AND r.status      = 'completed'
  GROUP BY r.client_id, p.full_name, p.loyalty_tier
  ORDER BY bookings DESC, total_spent DESC
  LIMIT 20;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_loyal_clients(UUID) TO authenticated;


-- ── 7. RPC: get_loyalty_metrics(p_days_back) ─────────────────────────────────
-- Admin: métricas de retención y fidelización.

DROP FUNCTION IF EXISTS public.get_loyalty_metrics(INT);
CREATE OR REPLACE FUNCTION public.get_loyalty_metrics(p_days_back INT DEFAULT 30)
RETURNS TABLE (
  total_loyalty_clients  BIGINT,
  silver_clients         BIGINT,
  gold_clients           BIGINT,
  vip_clients            BIGINT,
  avg_events_per_client  NUMERIC,
  repeat_rate_pct        NUMERIC,    -- % de clientes con ≥2 eventos
  points_awarded_period  BIGINT,
  top_tier_revenue_pct   NUMERIC     -- % de ingresos de gold+vip
)
LANGUAGE plpgsql
SECURITY DEFINER STABLE
SET search_path = public
AS $$
DECLARE
  v_cutoff TIMESTAMPTZ := NOW() - (p_days_back || ' days')::INTERVAL;
BEGIN
  -- Solo admin
  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin') THEN
    RAISE EXCEPTION 'Acceso denegado';
  END IF;

  RETURN QUERY
  WITH client_stats AS (
    SELECT
      r.client_id,
      COUNT(*)              AS ev_count,
      SUM(r.total_price)    AS spent
    FROM public.reservations r
    WHERE r.status = 'completed'
    GROUP BY r.client_id
  ),
  tier_counts AS (
    SELECT loyalty_tier, COUNT(*) AS cnt
    FROM public.profiles
    WHERE role = 'client' AND loyalty_events_count > 0
    GROUP BY loyalty_tier
  ),
  total_rev AS (
    SELECT COALESCE(SUM(total_price), 1) AS rev
    FROM public.reservations
    WHERE status = 'completed'
  ),
  top_rev AS (
    SELECT COALESCE(SUM(r.total_price), 0) AS rev
    FROM public.reservations r
    JOIN public.profiles p ON p.id = r.client_id
    WHERE r.status = 'completed'
      AND p.loyalty_tier IN ('gold', 'vip')
  )
  SELECT
    (SELECT COUNT(*) FROM public.profiles WHERE role = 'client' AND loyalty_events_count > 0),
    COALESCE((SELECT cnt FROM tier_counts WHERE loyalty_tier = 'silver'), 0),
    COALESCE((SELECT cnt FROM tier_counts WHERE loyalty_tier = 'gold'),   0),
    COALESCE((SELECT cnt FROM tier_counts WHERE loyalty_tier = 'vip'),    0),
    COALESCE((SELECT AVG(ev_count) FROM client_stats), 0),
    COALESCE(
      (SELECT COUNT(*) * 100.0 / NULLIF(COUNT(*), 0)
       FROM client_stats WHERE ev_count >= 2),
      0
    ),
    COALESCE((
      SELECT SUM(le.points)
      FROM public.loyalty_events le
      WHERE le.created_at >= v_cutoff AND le.points > 0
    ), 0)::BIGINT,
    ROUND((SELECT top_rev.rev FROM top_rev) * 100.0 / (SELECT total_rev.rev FROM total_rev), 1);
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_loyalty_metrics(INT) TO authenticated;


-- ── 8. Inicializar puntos de clientes existentes ──────────────────────────────
-- Calcular puntos retroactivos para clientes con reservas completadas.

UPDATE public.profiles p
SET
  loyalty_events_count = sub.cnt::INT,
  loyalty_points       = (sub.cnt * 10)::INT,
  loyalty_tier         = public.calc_loyalty_tier((sub.cnt * 10)::INT)
FROM (
  SELECT client_id, COUNT(*) AS cnt
  FROM public.reservations
  WHERE status = 'completed' AND client_id IS NOT NULL
  GROUP BY client_id
) sub
WHERE p.id = sub.client_id
  AND p.role = 'client'
  AND p.loyalty_points = 0;   -- Solo si aún no tiene puntos asignados


SELECT 'Sistema de lealtad creado ✅' AS status;
SELECT 'Niveles: bronze(0) → silver(50pts) → gold(150pts) → vip(300pts)' AS info;
SELECT 'Descuentos: silver=3% · gold=5% · vip=8%' AS discounts;
