-- ════════════════════════════════════════════════════════════════════
-- 192_performance_and_flow_fixes.sql
--
-- OBJETIVO: Dos fixes críticos de rendimiento y lógica de negocio.
--
-- 1. expire_advertisements — reescrita con:
--      · pg_try_advisory_xact_lock → solo 1 proceso a la vez
--      · INSERT...SELECT batch (no FOR loop row-by-row)
--      · No se llama inline en get_active_banner_ads (ver punto 1c)
--
-- 2. create_advertisement_order — usa 'pending_payment' como estado
--    inicial. El anuncio solo pasa a 'pending_review' cuando
--    mark_ad_payment confirma el pago real de Stripe.
--
-- 3. get_active_banner_ads — elimina el PERFORM expire_advertisements()
--    (ahora la expiración la maneja el cron, no cada request del Home).
--
-- Requiere: 191_security_fixes.sql
-- ════════════════════════════════════════════════════════════════════


-- ════════════════════════════════════════════════════════════════════
-- 1. expire_advertisements — optimizada
-- ════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.expire_advertisements()
RETURNS INT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_count INT := 0;
BEGIN
  -- Advisory lock: si otro proceso ya está expirando, salir sin hacer nada.
  -- Evita que 500 usuarios abriendo el Home disparen 500 UPDATEs concurrentes.
  -- El lock se libera automáticamente al terminar la transacción.
  IF NOT pg_try_advisory_xact_lock(9876543210) THEN
    RETURN 0;
  END IF;

  -- Audit log en batch — 1 INSERT para todos los que van a expirar.
  -- Antes era un FOR LOOP con 1 INSERT por fila (ineficiente con muchos anuncios).
  INSERT INTO public.ad_audit_log (ad_id, action, performed_by, details)
  SELECT
    id,
    'expired',
    NULL,
    jsonb_build_object(
      'title',    title,
      'type',     type,
      'ended_at', ends_at
    )
  FROM public.advertisements
  WHERE status IN ('active', 'approved')
    AND ends_at IS NOT NULL
    AND ends_at < now();

  -- Expirar anuncios en batch
  UPDATE public.advertisements
  SET    status     = 'expired',
         updated_at = now()
  WHERE  status IN ('active', 'approved')
    AND  ends_at IS NOT NULL
    AND  ends_at < now();
  GET DIAGNOSTICS v_count = ROW_COUNT;

  -- Desactivar sponsored_groups expirados
  UPDATE public.sponsored_groups
  SET    is_active = false
  WHERE  is_active = true
    AND  ends_at IS NOT NULL
    AND  ends_at < now();

  -- Expirar bid_orders vencidos
  UPDATE public.bid_orders
  SET    status     = 'expired',
         updated_at = now()
  WHERE  status = 'paid'
    AND  ends_at IS NOT NULL
    AND  ends_at < now();

  -- Limpiar bid_amount en grupos cuya puja expiró
  UPDATE public.groups
  SET    bid_amount  = 0,
         bid_ends_at = NULL
  WHERE  bid_ends_at IS NOT NULL
    AND  bid_ends_at < now();

  RETURN v_count;
END;
$$;

GRANT EXECUTE ON FUNCTION public.expire_advertisements() TO service_role;
-- Ya no necesita 'authenticated' — solo el cron (service_role) la llama.
REVOKE EXECUTE ON FUNCTION public.expire_advertisements() FROM authenticated;


-- ════════════════════════════════════════════════════════════════════
-- 1c. get_active_banner_ads — eliminar PERFORM expire_advertisements()
--     La expiración es responsabilidad del cron, no de cada request.
-- ════════════════════════════════════════════════════════════════════

DROP FUNCTION IF EXISTS public.get_active_banner_ads(TEXT, TEXT);

CREATE OR REPLACE FUNCTION public.get_active_banner_ads(
  p_city  TEXT DEFAULT NULL,
  p_state TEXT DEFAULT NULL
)
RETURNS TABLE (
  id               UUID,
  title            TEXT,
  subtitle         TEXT,
  tag              TEXT,
  button_text      TEXT,
  media_url        TEXT,
  media_type       TEXT,
  media_offset     INT,
  link_type        TEXT,
  link_id          UUID,
  duration_seconds INT,
  order_index      INT,
  is_free          BOOLEAN
)
LANGUAGE plpgsql
SECURITY DEFINER STABLE
SET search_path = public
AS $$
BEGIN
  -- Sin PERFORM expire_advertisements() — el cron lo maneja cada 5 minutos.
  -- Esto evita contención de locks en producción con alta concurrencia.
  RETURN QUERY
  SELECT
    a.id, a.title, a.subtitle, a.tag, a.button_text,
    a.media_url, a.media_type, a.media_offset,
    a.link_type, a.link_id,
    a.duration_seconds, a.order_index,
    a.is_free
  FROM   public.advertisements a
  LEFT JOIN public.ad_packages pkg ON pkg.id = a.package_id
  WHERE  a.type   = 'banner_home'
    AND  a.status = 'active'
    AND  (a.starts_at IS NULL OR a.starts_at <= now())
    AND  (a.ends_at   IS NULL OR a.ends_at   >  now())  -- filtro inline (no UPDATE)
    AND  (
      a.target_location_type IS NULL
      OR a.target_location_type = 'national'
      OR p_city IS NULL
      OR (a.target_locations IS NOT NULL
          AND a.target_locations @> jsonb_build_array(p_city))
    )
    AND  (
      p_state IS NULL
      OR (a.target_states IS NULL AND a.target_state IS NULL)
      OR (a.target_states IS NOT NULL
          AND normalize_state_name(p_state) = ANY(a.target_states))
      OR (a.target_states IS NULL AND a.target_state IS NOT NULL
          AND a.target_state = normalize_state_name(p_state))
    )
  ORDER BY
    a.is_free ASC,
    COALESCE(pkg.price, 0) DESC,
    a.order_index ASC,
    a.starts_at   ASC;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_active_banner_ads(TEXT, TEXT) TO anon, authenticated;


-- ════════════════════════════════════════════════════════════════════
-- 2. create_advertisement_order — estado inicial 'pending_payment'
--    Solo mark_ad_payment (vía webhook) lo mueve a 'pending_review'.
-- ════════════════════════════════════════════════════════════════════

DROP FUNCTION IF EXISTS public.create_advertisement_order(TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,UUID,TEXT,UUID,TEXT,JSONB,INT,TEXT,INT,NUMERIC,TEXT,TEXT[]);

CREATE OR REPLACE FUNCTION public.create_advertisement_order(
  p_type             TEXT,
  p_title            TEXT,
  p_subtitle         TEXT     DEFAULT NULL,
  p_button_text      TEXT     DEFAULT 'Contratar',
  p_media_url        TEXT     DEFAULT NULL,
  p_media_type       TEXT     DEFAULT 'none',
  p_package_id       UUID     DEFAULT NULL,
  p_link_type        TEXT     DEFAULT 'none',
  p_link_id          UUID     DEFAULT NULL,
  p_location_type    TEXT     DEFAULT 'national',
  p_locations        JSONB    DEFAULT NULL,
  p_duration_seconds INT      DEFAULT NULL,
  p_youtube_url      TEXT     DEFAULT NULL,
  p_custom_days      INT      DEFAULT NULL,
  p_total_price      NUMERIC  DEFAULT NULL,
  p_target_state     TEXT     DEFAULT NULL,
  p_target_states    TEXT[]   DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id     UUID := auth.uid();
  v_ad_id       UUID;
  v_group_id    UUID;
  v_group_state TEXT;
  v_pkg         RECORD;
  v_total       NUMERIC;
  v_dur_days    INT;
  v_state_norm  TEXT;
  v_states_arr  TEXT[];
BEGIN
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_session');
  END IF;

  IF p_type NOT IN ('banner_home', 'sponsored_group', 'profile_ad') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_type: ' || COALESCE(p_type, 'null'));
  END IF;

  IF p_package_id IS NOT NULL THEN
    SELECT * INTO v_pkg FROM public.ad_packages
    WHERE id = p_package_id AND is_active = true;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('ok', false, 'error', 'package_not_found');
    END IF;
  END IF;

  -- Resolver grupo + estado del anunciante
  SELECT id, state INTO v_group_id, v_group_state
  FROM   public.groups
  WHERE  owner_id = v_user_id
  LIMIT  1;

  -- target_state (single, backward compat)
  IF p_type = 'sponsored_group' THEN
    v_state_norm := normalize_state_name(v_group_state);
  ELSE
    v_state_norm := normalize_state_name(
      COALESCE(NULLIF(TRIM(COALESCE(p_target_state, '')), ''), v_group_state)
    );
  END IF;

  -- target_states (array, solo banner/profile)
  IF p_type IN ('banner_home', 'profile_ad')
     AND p_target_states IS NOT NULL
     AND array_length(p_target_states, 1) > 0
  THEN
    SELECT ARRAY(
      SELECT normalize_state_name(s)
      FROM   unnest(p_target_states) AS s
      WHERE  TRIM(s) <> ''
    ) INTO v_states_arr;
    IF array_length(v_states_arr, 1) IS NULL THEN
      v_states_arr := NULL;
    END IF;
  END IF;

  v_total    := COALESCE(p_total_price, v_pkg.price, 0);
  v_dur_days := COALESCE(v_pkg.duration_days, p_custom_days, 7);

  INSERT INTO public.advertisements (
    advertiser_id, package_id, type, title, subtitle, button_text,
    media_url, media_type, link_type, link_id,
    target_location_type, target_locations, target_state, target_states,
    duration_seconds, youtube_url, custom_days,
    total_price, effective_price,
    status,           -- ← 'pending_payment' (cambio clave vs. antes)
    starts_at, ends_at
  ) VALUES (
    v_user_id, p_package_id, p_type, p_title, p_subtitle,
    COALESCE(p_button_text, 'Contratar'),
    p_media_url, COALESCE(p_media_type, 'none'),
    CASE WHEN p_type = 'sponsored_group' THEN 'group'
         ELSE COALESCE(p_link_type, 'none') END,
    CASE WHEN p_type = 'sponsored_group' THEN v_group_id
         ELSE p_link_id END,
    COALESCE(p_location_type, 'national'), p_locations,
    v_state_norm, v_states_arr,
    p_duration_seconds,
    CASE WHEN COALESCE(p_link_type, 'none') = 'video' THEN p_youtube_url ELSE NULL END,
    p_custom_days,
    v_total, v_total,
    'pending_payment',  -- ← antes era 'pending_review' (bug: visible en admin antes de pagar)
    NOW(),
    NOW() + (v_dur_days || ' days')::INTERVAL
  )
  RETURNING id INTO v_ad_id;

  IF p_type = 'sponsored_group' AND v_group_id IS NOT NULL THEN
    INSERT INTO public.sponsored_groups (group_id, advertiser_id, starts_at, ends_at, is_active)
    VALUES (v_group_id, v_user_id, NOW(), NOW() + (v_dur_days || ' days')::INTERVAL, false)
    ON CONFLICT DO NOTHING;
  END IF;

  RETURN jsonb_build_object(
    'ok',     true,
    'ad_id',  v_ad_id,
    'state',  v_state_norm,
    'states', v_states_arr,
    'total',  v_total
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.create_advertisement_order(
  TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,UUID,TEXT,UUID,TEXT,JSONB,INT,TEXT,INT,NUMERIC,TEXT,TEXT[]
) TO authenticated;


-- ════════════════════════════════════════════════════════════════════
-- Cron job: llamar expire_advertisements() cada 5 minutos
-- Requiere pg_cron habilitado en Supabase (Dashboard → Extensions).
-- Si no tienes pg_cron, ejecuta expire_advertisements() desde un
-- Supabase Scheduled Function (Dashboard → Edge Functions → Cron).
-- ════════════════════════════════════════════════════════════════════

-- Descomentar si tienes pg_cron habilitado:
/*
SELECT cron.schedule(
  'expire-advertisements',   -- nombre del job
  '*/5 * * * *',             -- cada 5 minutos
  $$SELECT public.expire_advertisements()$$
);
*/


-- ── Verificación ──────────────────────────────────────────────────────────────

-- Anuncios en pending_payment (creados pero no pagados aún):
SELECT id, title, type, status, created_at
FROM   public.advertisements
WHERE  status = 'pending_payment'
ORDER  BY created_at DESC
LIMIT  10;

-- Confirmar que create_advertisement_order usa 'pending_payment':
SELECT routine_name, routine_definition
FROM   information_schema.routines
WHERE  routine_schema = 'public'
  AND  routine_name   = 'create_advertisement_order'
LIMIT  1;

SELECT '192_performance_and_flow_fixes.sql ejecutado ✅' AS status;
