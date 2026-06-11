-- ════════════════════════════════════════════════════════════════════
-- 325_verified_plus_mvp.sql
--
-- Verificación Plus — MVP para grupos únicamente.
-- No afecta is_verified, el badge azul ni la verificación manual del admin.
--
-- 1. Columnas en groups (is_plus_active, plus_expires_at, plus_subscription_id)
-- 2. Tabla plus_subscriptions
-- 3. RPC activate_plus
-- 4. RPC deactivate_plus
-- 5. RPC get_my_plus_status
-- 6. UPDATE get_groups_ranked_by_city: boost_score → is_plus_active
--
-- Ejecutar después de 324_fix_connections_event_date.sql
-- ════════════════════════════════════════════════════════════════════

-- ── 1. Columnas en groups ─────────────────────────────────────────────────────

ALTER TABLE public.groups
  ADD COLUMN IF NOT EXISTS is_plus_active       BOOLEAN     NOT NULL DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS plus_expires_at      TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS plus_subscription_id TEXT;

-- Índice parcial: solo grupos con Plus activo
CREATE INDEX IF NOT EXISTS idx_groups_plus_active
  ON public.groups (is_plus_active, plus_expires_at)
  WHERE is_plus_active = TRUE;


-- ── 2. Tabla plus_subscriptions ───────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.plus_subscriptions (
  id                     UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  group_id               UUID        NOT NULL REFERENCES public.groups(id) ON DELETE CASCADE,
  owner_id               UUID        NOT NULL REFERENCES public.profiles(id),
  stripe_subscription_id TEXT        NOT NULL UNIQUE,
  stripe_customer_id     TEXT        NOT NULL,
  status                 TEXT        NOT NULL DEFAULT 'trialing'
                         CHECK (status IN ('trialing','active','past_due','cancelled','incomplete')),
  trial_ends_at          TIMESTAMPTZ,
  current_period_end     TIMESTAMPTZ,
  created_at             TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_plus_subs_group_id  ON public.plus_subscriptions (group_id);
CREATE INDEX IF NOT EXISTS idx_plus_subs_stripe_id ON public.plus_subscriptions (stripe_subscription_id);
CREATE INDEX IF NOT EXISTS idx_plus_subs_owner_id  ON public.plus_subscriptions (owner_id);

ALTER TABLE public.plus_subscriptions ENABLE ROW LEVEL SECURITY;

-- El dueño del grupo puede leer su propia suscripción
DROP POLICY IF EXISTS "plus_subs_owner_select" ON public.plus_subscriptions;
CREATE POLICY "plus_subs_owner_select"
  ON public.plus_subscriptions FOR SELECT
  USING (owner_id = auth.uid());

-- Service role tiene acceso total (webhook)
DROP POLICY IF EXISTS "plus_subs_service_all" ON public.plus_subscriptions;
CREATE POLICY "plus_subs_service_all"
  ON public.plus_subscriptions FOR ALL
  USING (auth.role() = 'service_role');


-- ── 3. RPC activate_plus ──────────────────────────────────────────────────────
-- Llamado por el webhook en subscription.created/updated e invoice.paid.
-- Activa el Plus en el grupo y actualiza la fecha de expiración.
-- El guard (plus_expires_at > now()) en el ranking protege ante webhooks tardíos.

DROP FUNCTION IF EXISTS public.activate_plus(UUID, TEXT, TIMESTAMPTZ, TEXT);

CREATE OR REPLACE FUNCTION public.activate_plus(
  p_group_id   UUID,
  p_sub_id     TEXT,
  p_expires_at TIMESTAMPTZ,
  p_status     TEXT DEFAULT 'active'
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Actualizar el grupo
  UPDATE public.groups
     SET is_plus_active       = TRUE,
         plus_expires_at      = p_expires_at,
         plus_subscription_id = p_sub_id
   WHERE id = p_group_id;

  -- Actualizar la suscripción
  UPDATE public.plus_subscriptions
     SET status             = p_status,
         current_period_end = p_expires_at
   WHERE stripe_subscription_id = p_sub_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.activate_plus(UUID, TEXT, TIMESTAMPTZ, TEXT)
  TO service_role;


-- ── 4. RPC deactivate_plus ────────────────────────────────────────────────────
-- Llamado por el webhook en invoice.payment_failed y subscription.deleted.

DROP FUNCTION IF EXISTS public.deactivate_plus(TEXT);

CREATE OR REPLACE FUNCTION public.deactivate_plus(
  p_sub_id TEXT
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Desactivar el grupo vinculado
  UPDATE public.groups
     SET is_plus_active = FALSE
   WHERE plus_subscription_id = p_sub_id;

  -- Marcar la suscripción como cancelada
  UPDATE public.plus_subscriptions
     SET status = 'cancelled'
   WHERE stripe_subscription_id = p_sub_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.deactivate_plus(TEXT)
  TO service_role;


-- ── 5. RPC get_my_plus_status ─────────────────────────────────────────────────
-- Para PlusScreen y Dashboard card. Solo el dueño del grupo puede llamarlo.

DROP FUNCTION IF EXISTS public.get_my_plus_status(UUID);

CREATE OR REPLACE FUNCTION public.get_my_plus_status(
  p_group_id UUID
)
RETURNS TABLE (
  is_active      BOOLEAN,
  status         TEXT,
  trial_ends_at  TIMESTAMPTZ,
  expires_at     TIMESTAMPTZ
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT
    -- Plus activo solo si el flag está en TRUE y no ha expirado
    (g.is_plus_active AND (g.plus_expires_at IS NULL OR g.plus_expires_at > NOW())) AS is_active,
    COALESCE(ps.status, 'inactive')   AS status,
    ps.trial_ends_at,
    g.plus_expires_at                 AS expires_at
  FROM public.groups g
  LEFT JOIN public.plus_subscriptions ps
    ON  ps.stripe_subscription_id = g.plus_subscription_id
    AND ps.status NOT IN ('cancelled')
  WHERE g.id = p_group_id
    AND g.owner_id = auth.uid();
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_my_plus_status(UUID)
  TO authenticated;


-- ── 6. UPDATE get_groups_ranked_by_city ───────────────────────────────────────
-- Reemplaza boost_score por is_plus_active en posición #4 del ORDER BY.
-- Jerarquía: local_match > bid_active > bid_amount > is_plus_active > rating > reviews > created_at
-- Plus solo cuenta si is_plus_active=TRUE Y plus_expires_at > now() (guard ante webhook fallido).
-- Bidding sigue intacto en posiciones #2 y #3.

DROP FUNCTION IF EXISTS public.get_groups_ranked_by_city(TEXT, INT);
DROP FUNCTION IF EXISTS public.get_groups_ranked_by_city(TEXT, TEXT, INT);

CREATE OR REPLACE FUNCTION public.get_groups_ranked_by_city(
  p_city  TEXT,
  p_state TEXT    DEFAULT NULL,
  p_limit INT     DEFAULT 60
)
RETURNS TABLE (
  id                    UUID,
  name                  TEXT,
  genre                 TEXT,
  city                  TEXT,
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
  v_state_norm TEXT := CASE WHEN p_state IS NULL THEN NULL ELSE LOWER(TRIM(p_state)) END;
BEGIN
  RETURN QUERY
  SELECT
    g.id, g.name, g.genre, g.city,
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
    COALESCE(g.is_high_demand, FALSE),
    COALESCE(g.recent_completions, 0)::INT,
    (
      g.bid_ends_at IS NOT NULL
      AND g.bid_ends_at > NOW()
      AND COALESCE(g.bid_amount, 0) > 0
    ) AS bid_active,
    (v_city_norm IS NULL OR normalize_city_name(g.city) = v_city_norm) AS is_local,
    -- Plus activo con guard de expiración: protección ante webhook fallido
    (g.is_plus_active AND (g.plus_expires_at IS NULL OR g.plus_expires_at > NOW())) AS is_plus_active
  FROM public.groups g
  WHERE g.is_active = TRUE
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
      OR LOWER(TRIM(g.state)) = v_state_norm
    )
  ORDER BY
    -- #1: Grupos locales primero (sin cambio)
    (v_city_norm IS NULL OR normalize_city_name(g.city) = v_city_norm) DESC,
    -- #2: Bidding activo (sin cambio — Bidding siempre gana sobre Plus)
    (g.bid_ends_at IS NOT NULL AND g.bid_ends_at > NOW()
      AND COALESCE(g.bid_amount, 0) > 0) DESC,
    -- #3: Mayor monto de bid (sin cambio)
    COALESCE(g.bid_amount, 0) DESC,
    -- #4: Plus activo con guard de expiración (reemplaza boost_score)
    (g.is_plus_active AND (g.plus_expires_at IS NULL OR g.plus_expires_at > NOW())) DESC,
    -- #5-7: Orgánicos (sin cambio)
    COALESCE(g.rating, 0) DESC,
    COALESCE(g.total_reviews, 0) DESC,
    g.created_at DESC
  LIMIT p_limit;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_groups_ranked_by_city(TEXT, TEXT, INT)
  TO anon, authenticated;


-- ── Verificación ──────────────────────────────────────────────────────────────

SELECT 'Columnas plus en groups:' AS check_1,
       column_name, data_type
FROM   information_schema.columns
WHERE  table_name = 'groups'
  AND  column_name IN ('is_plus_active','plus_expires_at','plus_subscription_id');

SELECT 'Tabla plus_subscriptions:' AS check_2,
       COUNT(*) AS total_rows
FROM   public.plus_subscriptions;

SELECT '325_verified_plus_mvp.sql ejecutado ✅' AS status;
