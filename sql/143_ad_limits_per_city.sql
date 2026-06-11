-- ════════════════════════════════════════════════════════════════════════════
-- 143_ad_limits_per_city.sql
-- Cambia los límites de anuncios de GLOBAL a POR CIUDAD.
--
-- ANTES (133_ad_system_upgrade.sql):
--   banner_home=8, sponsored_group=5, profile_ad=10  (globales)
--
-- DESPUÉS (este archivo):
--   banner_home=3 por ciudad, sponsored_group=10 por ciudad,
--   profile_ad=20 por ciudad.
--
-- LÓGICA DE CONTEO POR CIUDAD:
--   · Anuncios city/multi_city: cuentan en cada ciudad de target_locations.
--     Al aprobar uno nuevo, se verifica que ninguna de sus ciudades destino
--     ya tenga v_max anuncios activos del mismo tipo.
--   · Anuncios nacionales: aparecen en todas las ciudades.
--     Se aplica un límite global independiente (no bloquea slots de ciudad).
--   · sponsored_group: el "alcance" es la ciudad del propio grupo.
--     Se cuenta cuántos grupos patrocinados activos hay en esa ciudad.
--
-- NO modifica: reject_ad, toggle_ad, delete_ad, expire_advertisements,
--              get_active_banner_ads, get_profile_ads, create_advertisement_order.
--
-- Ejecutar DESPUÉS de 142_event_reminder_notifications.sql
-- ════════════════════════════════════════════════════════════════════════════


DROP FUNCTION IF EXISTS public.approve_ad(UUID, INT);
CREATE OR REPLACE FUNCTION public.approve_ad(
  p_id            UUID,
  p_duration_days INT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_days       INT;
  v_ad         RECORD;
  v_count      INT;
  v_max        INT;
  v_city       TEXT;
  v_city_elem  TEXT;
  v_exceeded   BOOLEAN := false;
BEGIN
  -- ── Verificar que es admin ───────────────────────────────────────────────
  IF NOT EXISTS (
    SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin'
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Unauthorized');
  END IF;

  -- ── Cargar el anuncio + datos del paquete ────────────────────────────────
  SELECT a.*,
         ap.duration_days AS pkg_days,
         ap.price         AS pkg_price
  INTO   v_ad
  FROM   public.advertisements a
  LEFT JOIN public.ad_packages ap ON ap.id = a.package_id
  WHERE  a.id = p_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'ad_not_found');
  END IF;

  v_days := COALESCE(p_duration_days, v_ad.pkg_days, 7);

  -- ── Límites por ciudad según tipo ────────────────────────────────────────
  v_max := CASE v_ad.type
    WHEN 'banner_home'     THEN 3
    WHEN 'sponsored_group' THEN 10
    WHEN 'profile_ad'      THEN 20
    ELSE 99
  END;

  -- ╔══════════════════════════════════════════════════════════════════════╗
  -- ║  CASO 1: sponsored_group                                            ║
  -- ║  El alcance es la ciudad del grupo del anunciante.                  ║
  -- ╚══════════════════════════════════════════════════════════════════════╝
  IF v_ad.type = 'sponsored_group' THEN

    -- Obtener la ciudad del grupo que se está patrocinando
    SELECT g.city INTO v_city
    FROM   public.groups g
    JOIN   public.sponsored_groups sg ON sg.group_id = g.id
    WHERE  sg.advertiser_id = v_ad.advertiser_id
      AND  sg.package_id    = v_ad.package_id
    LIMIT 1;

    IF v_city IS NOT NULL THEN
      -- Contar grupos patrocinados activos en esa ciudad
      SELECT COUNT(*) INTO v_count
      FROM   public.sponsored_groups sg
      JOIN   public.groups g ON g.id = sg.group_id
      WHERE  sg.is_active  = true
        AND  sg.ends_at    > now()
        AND  g.city        ILIKE v_city
        AND  sg.group_id  != COALESCE(v_ad.link_id, '00000000-0000-0000-0000-000000000000'::UUID);
        -- excluye el propio grupo para no rechazar renovaciones

      IF v_count >= v_max THEN
        RETURN jsonb_build_object(
          'ok',    false,
          'error', 'limit_reached_city',
          'city',  v_city,
          'limit', v_max,
          'count', v_count,
          'type',  v_ad.type
        );
      END IF;

    ELSE
      -- Sin ciudad registrada: fallback a conteo global
      SELECT COUNT(*) INTO v_count
      FROM   public.sponsored_groups
      WHERE  is_active = true AND ends_at > now();

      IF v_count >= v_max THEN
        RETURN jsonb_build_object(
          'ok',    false,
          'error', 'limit_reached',
          'limit', v_max,
          'count', v_count,
          'type',  v_ad.type
        );
      END IF;
    END IF;

  -- ╔══════════════════════════════════════════════════════════════════════╗
  -- ║  CASO 2: banner_home / profile_ad — alcance nacional               ║
  -- ║  Límite global independiente (no bloquea slots de ciudad).         ║
  -- ╚══════════════════════════════════════════════════════════════════════╝
  ELSIF v_ad.target_location_type IS NULL
     OR v_ad.target_location_type = 'national' THEN

    -- Para anuncios nacionales: límite global propio, más generoso
    -- (no bloquea a anuncios de ciudad)
    DECLARE
      v_max_national INT := CASE v_ad.type
        WHEN 'banner_home' THEN 5
        WHEN 'profile_ad'  THEN 15
        ELSE 99
      END;
    BEGIN
      SELECT COUNT(*) INTO v_count
      FROM   public.advertisements
      WHERE  type   = v_ad.type
        AND  status = 'active'
        AND  id    != p_id
        AND  (target_location_type IS NULL OR target_location_type = 'national');

      IF v_count >= v_max_national THEN
        RETURN jsonb_build_object(
          'ok',    false,
          'error', 'limit_reached_national',
          'limit', v_max_national,
          'count', v_count,
          'type',  v_ad.type
        );
      END IF;
    END;

  -- ╔══════════════════════════════════════════════════════════════════════╗
  -- ║  CASO 3: banner_home / profile_ad — alcance ciudad / multi_ciudad  ║
  -- ║  Por cada ciudad destino del nuevo anuncio, verificar que no se    ║
  -- ║  supere v_max (contando activos nacionales + activos en esa ciudad).║
  -- ╚══════════════════════════════════════════════════════════════════════╝
  ELSE
    -- Iterar cada ciudad de target_locations del anuncio a aprobar
    FOR v_city_elem IN
      SELECT elem
      FROM   jsonb_array_elements_text(v_ad.target_locations) AS elem
    LOOP
      SELECT COUNT(*) INTO v_count
      FROM   public.advertisements a
      WHERE  a.type   = v_ad.type
        AND  a.status = 'active'
        AND  a.id    != p_id
        AND  (
          -- Anuncios nacionales → aparecen en TODAS las ciudades
          a.target_location_type IS NULL
          OR a.target_location_type = 'national'
          -- Anuncios ciudad/multi_ciudad que incluyan esta ciudad
          OR (
            a.target_locations IS NOT NULL
            AND a.target_locations @> jsonb_build_array(v_city_elem)
          )
        );

      IF v_count >= v_max THEN
        v_exceeded := true;
        RETURN jsonb_build_object(
          'ok',    false,
          'error', 'limit_reached_city',
          'city',  v_city_elem,
          'limit', v_max,
          'count', v_count,
          'type',  v_ad.type
        );
      END IF;
    END LOOP;

    -- Si target_locations está vacío o nulo a pesar del tipo: no bloquear
  END IF;

  -- ── Activar el anuncio ───────────────────────────────────────────────────
  UPDATE public.advertisements
  SET    status      = 'active',
         approved_at = now(),
         approved_by = auth.uid(),
         starts_at   = COALESCE(starts_at, now()),
         ends_at     = COALESCE(ends_at,   now() + (v_days || ' days')::INTERVAL),
         updated_at  = now()
  WHERE  id = p_id;

  -- ── Para sponsored_group: activar el registro correspondiente ───────────
  IF v_ad.type = 'sponsored_group' THEN
    UPDATE public.sponsored_groups
    SET    is_active  = true,
           starts_at  = now(),
           ends_at    = now() + (v_days || ' days')::INTERVAL
    WHERE  advertiser_id = v_ad.advertiser_id
      AND  package_id    = v_ad.package_id
      AND  is_active     = false;
  END IF;

  -- ── Audit log ────────────────────────────────────────────────────────────
  INSERT INTO public.ad_audit_log (ad_id, action, performed_by, details)
  VALUES (
    p_id,
    'approved',
    auth.uid(),
    jsonb_build_object(
      'title',             v_ad.title,
      'type',              v_ad.type,
      'duration_days',     v_days,
      'ends_at',           now() + (v_days || ' days')::INTERVAL,
      'location_type',     v_ad.target_location_type,
      'target_locations',  v_ad.target_locations
    )
  );

  RETURN jsonb_build_object('ok', true, 'duration_days', v_days);
END;
$$;

GRANT EXECUTE ON FUNCTION public.approve_ad(UUID, INT) TO authenticated;


-- ── RPC de diagnóstico: ver ocupación de slots por ciudad (solo admin) ───────
-- Útil en el panel de admin para ver qué ciudades están "llenas".

DROP FUNCTION IF EXISTS public.get_ad_slots_by_city(TEXT);
CREATE OR REPLACE FUNCTION public.get_ad_slots_by_city(p_type TEXT DEFAULT 'banner_home')
RETURNS TABLE (
  city          TEXT,
  active_count  BIGINT,
  max_slots     INT,
  slots_free    INT
)
LANGUAGE plpgsql
SECURITY DEFINER STABLE
SET search_path = public
AS $$
DECLARE
  v_max INT := CASE p_type
    WHEN 'banner_home'     THEN 3
    WHEN 'sponsored_group' THEN 10
    WHEN 'profile_ad'      THEN 20
    ELSE 99
  END;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin'
  ) THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  IF p_type = 'sponsored_group' THEN
    -- Contar por ciudad del grupo
    RETURN QUERY
    SELECT
      g.city                           AS city,
      COUNT(sg.id)                     AS active_count,
      v_max                            AS max_slots,
      (v_max - COUNT(sg.id)::INT)      AS slots_free
    FROM   public.sponsored_groups sg
    JOIN   public.groups g ON g.id = sg.group_id
    WHERE  sg.is_active = true
      AND  sg.ends_at   > now()
    GROUP BY g.city
    ORDER BY active_count DESC;

  ELSE
    -- Contar por ciudad en target_locations (expandiendo arrays)
    RETURN QUERY
    SELECT
      elem::TEXT                                  AS city,
      COUNT(*)                                    AS active_count,
      v_max                                       AS max_slots,
      (v_max - COUNT(*)::INT)                     AS slots_free
    FROM   public.advertisements a,
           jsonb_array_elements_text(a.target_locations) AS elem
    WHERE  a.type   = p_type
      AND  a.status = 'active'
      AND  a.target_location_type IN ('city', 'multi_city')
    GROUP BY elem
    ORDER BY active_count DESC;
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_ad_slots_by_city(TEXT) TO authenticated;


SELECT '143_ad_limits_per_city.sql ejecutado ✅' AS status;
SELECT 'approve_ad: límites ahora por ciudad (banner=3, sponsored=10, profile=20)' AS info;
SELECT 'Nacionales: límite global independiente (banner=5, profile=15) — no bloquean ciudades' AS info;
SELECT 'RPC diagnóstico: get_ad_slots_by_city(type) — solo admin' AS info;
