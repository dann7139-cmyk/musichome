-- ════════════════════════════════════════════════════════════════════════════
-- 158_city_status_system.sql
-- Sistema de estado por ciudad para escalar la app de forma controlada.
--
-- Estados:
--   inactive  → ciudad no visible en onboarding
--   seeding   → pocos grupos, descuentos, alta promoción
--   growing   → sistema normal, precios dinámicos activos
--   saturated → alta demanda, precios más altos
-- ════════════════════════════════════════════════════════════════════════════

-- ── 1. Columna de estado en cities ───────────────────────────────────────────

ALTER TABLE public.cities
  ADD COLUMN IF NOT EXISTS status           TEXT    NOT NULL DEFAULT 'inactive'
    CHECK (status IN ('inactive','seeding','growing','saturated')),
  ADD COLUMN IF NOT EXISTS activated_at     TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS seeding_ends_at  TIMESTAMPTZ,   -- cuándo deja de ser seeding automáticamente
  ADD COLUMN IF NOT EXISTS price_multiplier NUMERIC(4,2)   NOT NULL DEFAULT 1.00;

CREATE INDEX IF NOT EXISTS idx_cities_status ON public.cities(status);

-- ── 2. Métricas por ciudad (tabla liviana, se actualiza por trigger) ──────────

CREATE TABLE IF NOT EXISTS public.city_metrics (
  city_name            TEXT        PRIMARY KEY,
  active_groups        INT         NOT NULL DEFAULT 0,
  active_bids          INT         NOT NULL DEFAULT 0,
  active_ads           INT         NOT NULL DEFAULT 0,
  total_reservations   INT         NOT NULL DEFAULT 0,
  last_updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.city_metrics ENABLE ROW LEVEL SECURITY;
CREATE POLICY "city_metrics_public_read" ON public.city_metrics
  FOR SELECT USING (true);
CREATE POLICY "city_metrics_service_write" ON public.city_metrics
  FOR ALL USING (auth.role() = 'service_role');

-- ── 3. RPC: activate_city ─────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.activate_city(p_city TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_normalized TEXT;
  v_city_id    UUID;
BEGIN
  -- Solo admins pueden activar ciudades
  IF NOT EXISTS (
    SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin'
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'forbidden');
  END IF;

  v_normalized := lower(trim(p_city));

  -- Buscar o insertar ciudad
  INSERT INTO public.cities (name, is_active, status, activated_at, seeding_ends_at, price_multiplier)
  VALUES (v_normalized, TRUE, 'seeding', now(), now() + INTERVAL '60 days', 0.70)
  ON CONFLICT (name) DO UPDATE
    SET status           = 'seeding',
        is_active        = TRUE,
        activated_at     = COALESCE(cities.activated_at, now()),
        seeding_ends_at  = now() + INTERVAL '60 days',
        price_multiplier = 0.70
  RETURNING id INTO v_city_id;

  -- Métricas iniciales
  INSERT INTO public.city_metrics (city_name)
  VALUES (v_normalized)
  ON CONFLICT (city_name) DO NOTHING;

  -- Notificación a grupos de esa ciudad
  INSERT INTO public.notifications (user_id, title, body, type, data)
  SELECT
    p.id,
    '🚀 Tu ciudad acaba de activarse',
    'Sé de los primeros en posicionarte en ' || p_city || ' — hay muy poca competencia ahora.',
    'city_launch',
    jsonb_build_object('city', v_normalized)
  FROM public.profiles p
  INNER JOIN public.groups g ON g.owner_id = p.id
  WHERE lower(trim(g.city)) = v_normalized
    AND p.role = 'group';

  RETURN jsonb_build_object(
    'ok',       true,
    'city',     v_normalized,
    'status',   'seeding',
    'ends_at',  (now() + INTERVAL '60 days')::TEXT
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.activate_city(TEXT) TO authenticated;

-- ── 4. RPC: get_city_status ───────────────────────────────────────────────────
-- Devuelve el estado y multiplicador de precio de una ciudad.
-- Llamada desde el frontend para adaptar UI y precios.

CREATE OR REPLACE FUNCTION public.get_city_status(p_city TEXT)
RETURNS JSONB
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(
    (
      SELECT jsonb_build_object(
        'ok',              true,
        'city',            c.name,
        'status',          c.status,
        'price_multiplier', c.price_multiplier,
        'is_seeding',      c.status = 'seeding',
        'is_growing',      c.status = 'growing',
        'is_saturated',    c.status = 'saturated'
      )
      FROM public.cities c
      WHERE lower(trim(c.name)) = lower(trim(p_city))
        AND c.is_active = TRUE
      LIMIT 1
    ),
    jsonb_build_object(
      'ok',              true,
      'city',            p_city,
      'status',          'growing',   -- fallback: ciudad sin registro = growing normal
      'price_multiplier', 1.00,
      'is_seeding',      false,
      'is_growing',      true,
      'is_saturated',    false
    )
  );
$$;

GRANT EXECUTE ON FUNCTION public.get_city_status(TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_city_status(TEXT) TO anon;

-- ── 5. Función de transición automática ──────────────────────────────────────
-- Ejecutar manualmente o via pg_cron para mover ciudades entre estados.

CREATE OR REPLACE FUNCTION public.transition_city_statuses()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_updated INT := 0;
BEGIN
  -- seeding → growing cuando: grupos activos > 5 Y reservas > 10
  --   O cuando seeding_ends_at ya pasó
  WITH transitioned AS (
    UPDATE public.cities c
    SET    status           = 'growing',
           price_multiplier = 1.00
    WHERE  c.status = 'seeding'
      AND (
            c.seeding_ends_at < now()
            OR (
              (SELECT COUNT(*) FROM public.groups g
               WHERE lower(trim(g.city)) = lower(trim(c.name))
                 AND g.is_verified = TRUE) > 5
              AND
              (SELECT COUNT(*) FROM public.reservations r
               INNER JOIN public.groups gr ON gr.id = r.group_id
               WHERE lower(trim(gr.city)) = lower(trim(c.name))
                 AND r.status = 'completed') > 10
            )
          )
    RETURNING c.name
  )
  SELECT COUNT(*) INTO v_updated FROM transitioned;

  -- growing → saturated cuando: bids activos > 20 Y reservas recientes > 50
  UPDATE public.cities c
  SET    status           = 'saturated',
         price_multiplier = 1.20
  WHERE  c.status = 'growing'
    AND (
      (SELECT COUNT(*) FROM public.groups g
       WHERE lower(trim(g.city)) = lower(trim(c.name))
         AND g.bid_amount > 0
         AND g.bid_ends_at > now()) > 20
      AND
      (SELECT COUNT(*) FROM public.reservations r
       INNER JOIN public.groups gr ON gr.id = r.group_id
       WHERE lower(trim(gr.city)) = lower(trim(c.name))
         AND r.status = 'completed'
         AND r.created_at > now() - INTERVAL '30 days') > 50
    );

  -- Actualizar métricas de todas las ciudades activas
  INSERT INTO public.city_metrics (city_name, active_groups, active_bids, active_ads, total_reservations, last_updated_at)
  SELECT
    lower(trim(g.city))                                                                AS city_name,
    COUNT(DISTINCT g.id)                                                               AS active_groups,
    COUNT(DISTINCT g.id) FILTER (WHERE g.bid_amount > 0 AND g.bid_ends_at > now())    AS active_bids,
    COUNT(DISTINCT a.id) FILTER (WHERE a.status = 'active')                           AS active_ads,
    (SELECT COUNT(*) FROM public.reservations r2
     INNER JOIN public.groups g2 ON g2.id = r2.group_id
     WHERE lower(trim(g2.city)) = lower(trim(g.city))
       AND r2.status = 'completed')                                                    AS total_reservations,
    now()                                                                              AS last_updated_at
  FROM public.groups g
  LEFT JOIN public.advertisements a ON lower(trim(a.city)) = lower(trim(g.city))
  WHERE g.city IS NOT NULL
  GROUP BY lower(trim(g.city))
  ON CONFLICT (city_name) DO UPDATE
    SET active_groups      = EXCLUDED.active_groups,
        active_bids        = EXCLUDED.active_bids,
        active_ads         = EXCLUDED.active_ads,
        total_reservations = EXCLUDED.total_reservations,
        last_updated_at    = EXCLUDED.last_updated_at;

  RETURN jsonb_build_object('ok', true, 'transitioned', v_updated, 'updated_at', now()::TEXT);
END;
$$;

GRANT EXECUTE ON FUNCTION public.transition_city_statuses() TO service_role;

-- ── 6. Boost temporal en ranking para ciudades seeding ───────────────────────
-- En get_group_ranking_position: si la ciudad está en seeding,
-- los grupos con bid activo reciben +1 posición aparente (UI only).
-- Implementado en frontend leyendo city_status.

-- ── 7. Verificación final ─────────────────────────────────────────────────────

SELECT column_name, data_type, column_default
FROM   information_schema.columns
WHERE  table_schema = 'public'
  AND  table_name   = 'cities'
  AND  column_name  IN ('status', 'activated_at', 'seeding_ends_at', 'price_multiplier')
ORDER  BY column_name;

SELECT '158_city_status_system.sql ejecutado ✅' AS status;
