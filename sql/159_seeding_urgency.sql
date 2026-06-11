-- ════════════════════════════════════════════════════════════════════════════
-- 159_seeding_urgency.sql
-- Urgencia real para ciudades en estado 'seeding':
--   • Contador de slots de lanzamiento (primeros X grupos)
--   • Notificación inmediata + seguimiento a 24 h
--   • Transición automática seeding → growing con nuevos umbrales
-- ════════════════════════════════════════════════════════════════════════════

-- ── 1. Columna seeding_max_groups en cities ───────────────────────────────
-- Define cuántos grupos pueden acceder al precio de lanzamiento (-30%).
-- Por defecto 20. El admin puede subir o bajar según demanda real.

ALTER TABLE public.cities
  ADD COLUMN IF NOT EXISTS seeding_max_groups INT NOT NULL DEFAULT 20;

-- ── 2. RPC: get_seeding_launch_slots ─────────────────────────────────────
-- Devuelve los slots de precio de lanzamiento disponibles para una ciudad.
-- Retorna ok=false si la ciudad no está en seeding.

CREATE OR REPLACE FUNCTION public.get_seeding_launch_slots(p_city TEXT)
RETURNS JSONB
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(
    (
      SELECT jsonb_build_object(
        'ok',               true,
        'city',             c.name,
        'slots_total',      c.seeding_max_groups,
        'slots_used',       COALESCE(m.active_groups, 0),
        'slots_available',  GREATEST(0, c.seeding_max_groups - COALESCE(m.active_groups, 0)),
        'ends_at',          c.seeding_ends_at
      )
      FROM public.cities c
      LEFT JOIN public.city_metrics m ON m.city_name = lower(trim(c.name))
      WHERE lower(trim(c.name)) = lower(trim(p_city))
        AND c.status = 'seeding'
        AND c.is_active = TRUE
      LIMIT 1
    ),
    jsonb_build_object('ok', false)
  );
$$;

GRANT EXECUTE ON FUNCTION public.get_seeding_launch_slots(TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_seeding_launch_slots(TEXT) TO anon;

-- ── 3. Actualizar activate_city: texto de notificación correcto ───────────

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
  IF NOT EXISTS (
    SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin'
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'forbidden');
  END IF;

  v_normalized := lower(trim(p_city));

  INSERT INTO public.cities (name, is_active, status, activated_at, seeding_ends_at, price_multiplier, seeding_max_groups)
  VALUES (v_normalized, TRUE, 'seeding', now(), now() + INTERVAL '60 days', 0.70, 20)
  ON CONFLICT (name) DO UPDATE
    SET status             = 'seeding',
        is_active          = TRUE,
        activated_at       = COALESCE(cities.activated_at, now()),
        seeding_ends_at    = now() + INTERVAL '60 days',
        price_multiplier   = 0.70,
        seeding_max_groups = COALESCE(cities.seeding_max_groups, 20)
  RETURNING id INTO v_city_id;

  INSERT INTO public.city_metrics (city_name)
  VALUES (v_normalized)
  ON CONFLICT (city_name) DO NOTHING;

  -- Notificación inmediata: "sé de los primeros"
  INSERT INTO public.notifications (user_id, title, body, type, data)
  SELECT
    p.id,
    '🚀 Nueva ciudad disponible',
    'Sé de los primeros en posicionarte en ' || p_city || ' — precio de lanzamiento -30%, solo por tiempo limitado.',
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

-- ── 4. Función: notify_seeding_followup ───────────────────────────────────
-- Enviar seguimiento 24 h después de activación, si la ciudad sigue en seeding.
-- Invocar vía pg_cron: SELECT cron.schedule('seeding-followup','0 * * * *',
--   'SELECT public.notify_seeding_followup()');

CREATE OR REPLACE FUNCTION public.notify_seeding_followup()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_sent INT := 0;
BEGIN
  INSERT INTO public.notifications (user_id, title, body, type, data)
  SELECT
    p.id,
    '🔥 Aún hay lugares disponibles',
    'Todavía puedes posicionarte con precio de lanzamiento en ' || c.name || ' — no dejes que otros te ganen el lugar.',
    'city_seeding_followup',
    jsonb_build_object('city', lower(trim(c.name)))
  FROM public.cities c
  INNER JOIN public.groups g  ON lower(trim(g.city)) = lower(trim(c.name))
  INNER JOIN public.profiles p ON p.id = g.owner_id
  WHERE c.status = 'seeding'
    -- ventana: entre 23 h y 25 h desde activación (cron cada hora)
    AND c.activated_at BETWEEN now() - INTERVAL '25 hours' AND now() - INTERVAL '23 hours'
    AND p.role = 'group'
    -- no enviar a grupos que ya tienen bid activo (ya compraron)
    AND NOT EXISTS (
      SELECT 1 FROM public.groups g2
      WHERE g2.owner_id = p.id
        AND g2.bid_amount > 0
        AND g2.bid_ends_at > now()
    );

  GET DIAGNOSTICS v_sent = ROW_COUNT;
  RETURN jsonb_build_object('ok', true, 'notifications_sent', v_sent);
END;
$$;

GRANT EXECUTE ON FUNCTION public.notify_seeding_followup() TO service_role;

-- ── 5. Actualizar transition_city_statuses: nuevos umbrales ───────────────
-- Antes: grupos > 5 AND reservas > 10
-- Ahora: grupos_activos > 15 AND bids_activos > 5
-- Esto da más tiempo al estado seeding (precio de lanzamiento activo más tiempo).

CREATE OR REPLACE FUNCTION public.transition_city_statuses()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_updated INT := 0;
BEGIN
  -- seeding → growing cuando:
  --   grupos verificados > 15 AND bids activos > 5
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
                 AND g.is_verified = TRUE) > 15
              AND
              (SELECT COUNT(*) FROM public.groups g
               WHERE lower(trim(g.city)) = lower(trim(c.name))
                 AND g.bid_amount > 0
                 AND g.bid_ends_at > now()) > 5
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

-- ── 6. Verificación ───────────────────────────────────────────────────────

SELECT name, status, price_multiplier, seeding_max_groups, seeding_ends_at
FROM   public.cities
WHERE  status = 'seeding'
ORDER  BY activated_at DESC;

SELECT '159_seeding_urgency.sql ejecutado ✅' AS status;
