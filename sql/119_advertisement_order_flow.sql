-- ════════════════════════════════════════════════════════════════════════════
-- 119_advertisement_order_flow.sql
-- Completa el flujo comercial del sistema de publicidad:
--
--   1. Estado 'pending_payment' en advertisements
--   2. Campo mp_payment_id para trazabilidad de pago
--   3. create_advertisement_order() — el cliente crea su anuncio
--   4. approve_ad() actualizado — activa sponsored_groups automáticamente
--   5. pg_cron para expiración cada hora
--   6. get_my_advertisement_orders() — el cliente ve sus anuncios
--
-- Ejecutar DESPUÉS de 118_fix_group_availability.sql
-- ════════════════════════════════════════════════════════════════════════════


-- ── 1. Ampliar el CHECK de status para incluir pending_payment ─────────────

-- Supabase no permite DROP CONSTRAINT directamente si existe un CHECK implícito
-- en la columna; usamos ALTER para reemplazarlo.
ALTER TABLE public.advertisements
  DROP CONSTRAINT IF EXISTS advertisements_status_check;

ALTER TABLE public.advertisements
  ADD CONSTRAINT advertisements_status_check
    CHECK (status IN (
      'pending_payment',   -- creado, esperando confirmación de pago
      'pending_review',    -- pagado, esperando revisión del admin
      'approved',          -- aprobado, esperará starts_at
      'active',            -- activo y visible
      'paused',            -- pausado manualmente
      'rejected',          -- rechazado por admin
      'expired'            -- venció automáticamente
    ));


-- ── 2. Columna mp_payment_id para trazabilidad ─────────────────────────────

ALTER TABLE public.advertisements
  ADD COLUMN IF NOT EXISTS mp_payment_id TEXT;

ALTER TABLE public.advertisements
  ADD COLUMN IF NOT EXISTS button_url TEXT;         -- URL al presionar el botón CTA


-- ── 3. RPC: create_advertisement_order ────────────────────────────────────
-- Crea el registro de anuncio con status = 'pending_review' (flujo optimista).
-- El pago se confirma por webhook; el admin no aprueba si no hay pago.
--
-- Para sponsored_group: también inserta en sponsored_groups con is_active=false.

DROP FUNCTION IF EXISTS public.create_advertisement_order(TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,UUID,UUID,TEXT,TEXT);
CREATE OR REPLACE FUNCTION public.create_advertisement_order(
  p_type            TEXT,
  p_title           TEXT,
  p_subtitle        TEXT         DEFAULT NULL,
  p_button_text     TEXT         DEFAULT 'Contactar',
  p_media_url       TEXT         DEFAULT NULL,
  p_media_type      TEXT         DEFAULT 'none',
  p_package_id      UUID         DEFAULT NULL,
  p_target_group_id UUID         DEFAULT NULL,   -- profile_ad: qué perfil (null=todos)
  p_link_type       TEXT         DEFAULT 'none',
  p_link_url        TEXT         DEFAULT NULL,
  p_button_url      TEXT         DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id   UUID := auth.uid();
  v_ad_id     UUID;
  v_group_id  UUID;
  v_pkg       RECORD;
BEGIN
  -- Validar usuario
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_session');
  END IF;

  -- Validar tipo
  IF p_type NOT IN ('banner_home', 'sponsored_group', 'profile_ad') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_type');
  END IF;

  -- Validar paquete (si se especifica)
  IF p_package_id IS NOT NULL THEN
    SELECT * INTO v_pkg FROM public.ad_packages
    WHERE id = p_package_id AND is_active = true;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('ok', false, 'error', 'package_not_found');
    END IF;
    IF v_pkg.type != p_type THEN
      RETURN jsonb_build_object('ok', false, 'error', 'package_type_mismatch');
    END IF;
  END IF;

  -- Para sponsored_group: resolver el grupo del anunciante
  IF p_type = 'sponsored_group' THEN
    SELECT id INTO v_group_id FROM public.groups
    WHERE owner_id = v_user_id LIMIT 1;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('ok', false, 'error', 'group_not_found');
    END IF;
  END IF;

  -- Insertar anuncio
  INSERT INTO public.advertisements (
    advertiser_id, package_id, type,
    title, subtitle, button_text, button_url,
    media_url, media_type,
    link_type, link_id, link_url,
    target_group_id,
    status
  ) VALUES (
    v_user_id, p_package_id, p_type,
    p_title, p_subtitle, p_button_text, p_button_url,
    p_media_url, p_media_type,
    CASE WHEN p_type = 'sponsored_group' THEN 'group' ELSE p_link_type END,
    CASE WHEN p_type = 'sponsored_group' THEN v_group_id ELSE NULL END,
    p_link_url,
    p_target_group_id,
    'pending_review'
  )
  RETURNING id INTO v_ad_id;

  -- Para sponsored_group: crear registro en sponsored_groups (inactivo hasta aprobar)
  IF p_type = 'sponsored_group' AND v_group_id IS NOT NULL AND v_pkg.duration_days IS NOT NULL THEN
    INSERT INTO public.sponsored_groups (
      group_id, advertiser_id, package_id,
      starts_at, ends_at, is_active
    ) VALUES (
      v_group_id, v_user_id, p_package_id,
      now(), now() + (v_pkg.duration_days || ' days')::INTERVAL,
      false   -- se activa cuando el admin aprueba el anuncio
    );
  END IF;

  RETURN jsonb_build_object(
    'ok',         true,
    'ad_id',      v_ad_id,
    'amount',     COALESCE(v_pkg.price, 0),
    'type',       p_type,
    'group_id',   v_group_id
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.create_advertisement_order(TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,UUID,UUID,TEXT,TEXT,TEXT) TO authenticated;


-- ── 4. approve_ad() actualizado — activa sponsored_groups ─────────────────

DROP FUNCTION IF EXISTS public.approve_ad(UUID, INT);
CREATE OR REPLACE FUNCTION public.approve_ad(
  p_id            UUID,
  p_duration_days INT DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_days  INT;
  v_ad    RECORD;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin') THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  -- Obtener el anuncio con su paquete
  SELECT a.*, ap.duration_days AS pkg_days, ap.type AS pkg_type
  INTO   v_ad
  FROM   public.advertisements a
  LEFT JOIN public.ad_packages ap ON ap.id = a.package_id
  WHERE  a.id = p_id;

  IF NOT FOUND THEN RAISE EXCEPTION 'Ad not found'; END IF;

  v_days := COALESCE(p_duration_days, v_ad.pkg_days, 7);

  -- Activar el anuncio
  UPDATE public.advertisements
  SET    status      = 'active',
         approved_at = now(),
         approved_by = auth.uid(),
         starts_at   = COALESCE(starts_at, now()),
         ends_at     = COALESCE(ends_at, now() + (v_days || ' days')::INTERVAL),
         updated_at  = now()
  WHERE  id = p_id;

  -- Para sponsored_group: activar el registro en sponsored_groups
  IF v_ad.type = 'sponsored_group' AND v_ad.link_id IS NOT NULL THEN
    UPDATE public.sponsored_groups
    SET    is_active  = true,
           starts_at  = now(),
           ends_at    = now() + (v_days || ' days')::INTERVAL
    WHERE  group_id      = v_ad.link_id
      AND  advertiser_id = v_ad.advertiser_id
      AND  is_active     = false
      AND  package_id    = v_ad.package_id;

    -- Si no existía el registro, insertarlo
    IF NOT FOUND THEN
      INSERT INTO public.sponsored_groups (group_id, advertiser_id, package_id, starts_at, ends_at, is_active)
      VALUES (v_ad.link_id, v_ad.advertiser_id, v_ad.package_id,
              now(), now() + (v_days || ' days')::INTERVAL, true)
      ON CONFLICT DO NOTHING;
    END IF;
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION public.approve_ad(UUID, INT) TO authenticated;


-- ── 5. RPC: get_my_advertisement_orders — el cliente ve sus anuncios ───────

DROP FUNCTION IF EXISTS public.get_my_advertisement_orders();
CREATE OR REPLACE FUNCTION public.get_my_advertisement_orders()
RETURNS TABLE (
  id               UUID,
  type             TEXT,
  title            TEXT,
  subtitle         TEXT,
  media_url        TEXT,
  media_type       TEXT,
  status           TEXT,
  rejection_reason TEXT,
  package_name     TEXT,
  price            NUMERIC,
  duration_days    INT,
  starts_at        TIMESTAMPTZ,
  ends_at          TIMESTAMPTZ,
  impressions      BIGINT,
  clicks           BIGINT,
  created_at       TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER STABLE
SET search_path = public
AS $$
BEGIN
  PERFORM public.expire_advertisements();

  RETURN QUERY
  SELECT  a.id, a.type, a.title, a.subtitle,
          a.media_url, a.media_type,
          a.status, a.rejection_reason,
          p.name   AS package_name,
          p.price,
          p.duration_days,
          a.starts_at, a.ends_at,
          a.impressions, a.clicks,
          a.created_at
  FROM    public.advertisements  a
  LEFT JOIN public.ad_packages   p ON p.id = a.package_id
  WHERE   a.advertiser_id = auth.uid()
  ORDER BY a.created_at DESC;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_my_advertisement_orders() TO authenticated;


-- ── 6. RPC: mark_ad_payment — webhook o cliente marca pago confirmado ──────
-- Llamado desde el webhook de MercadoPago (service_role) o desde el cliente.

DROP FUNCTION IF EXISTS public.mark_ad_payment(UUID, TEXT);
CREATE OR REPLACE FUNCTION public.mark_ad_payment(
  p_ad_id        UUID,
  p_mp_payment_id TEXT
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE public.advertisements
  SET    mp_payment_id = p_mp_payment_id,
         status        = CASE
                           WHEN status = 'pending_payment' THEN 'pending_review'
                           ELSE status
                         END,
         updated_at    = now()
  WHERE  id = p_ad_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.mark_ad_payment(UUID, TEXT) TO authenticated, service_role;


-- ── 7. pg_cron: expirar anuncios cada hora ─────────────────────────────────
-- Descomenta esta línea en Supabase Dashboard → Database → Cron Jobs,
-- o ejecútala directamente si pg_cron está habilitado:
--
-- SELECT cron.schedule(
--   'expire-advertisements-hourly',
--   '0 * * * *',
--   'SELECT public.expire_advertisements()'
-- );
--
-- Para verificar que cron está habilitado:
-- SELECT * FROM cron.job;


-- ── 8. Storage: bucket 'advertisements' ────────────────────────────────────
-- Ejecutar en Supabase Dashboard → Storage → New bucket:
--   Name: advertisements
--   Public: true
--   Max file size: 50 MB
--   Allowed MIME types: image/jpeg, image/png, image/webp, video/mp4, video/quicktime
--
-- O ejecutar en SQL:
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'advertisements',
  'advertisements',
  true,
  52428800,   -- 50 MB
  ARRAY['image/jpeg','image/png','image/webp','image/gif','video/mp4','video/quicktime','video/webm']
)
ON CONFLICT (id) DO NOTHING;

-- RLS para el bucket
DROP POLICY IF EXISTS "ads_media_public_read"   ON storage.objects;
DROP POLICY IF EXISTS "ads_media_owner_upload"  ON storage.objects;
DROP POLICY IF EXISTS "ads_media_owner_delete"  ON storage.objects;

CREATE POLICY "ads_media_public_read"  ON storage.objects
  FOR SELECT USING (bucket_id = 'advertisements');

CREATE POLICY "ads_media_owner_upload" ON storage.objects
  FOR INSERT WITH CHECK (
    bucket_id = 'advertisements'
    AND auth.uid()::TEXT = (storage.foldername(name))[1]
  );

CREATE POLICY "ads_media_owner_delete" ON storage.objects
  FOR DELETE USING (
    bucket_id = 'advertisements'
    AND auth.uid()::TEXT = (storage.foldername(name))[1]
  );


SELECT '119_advertisement_order_flow.sql ejecutado ✅' AS status;
SELECT 'Nuevo estado: pending_payment | RPC: create_advertisement_order, mark_ad_payment, get_my_advertisement_orders' AS rpcs;
SELECT 'approve_ad() ahora activa sponsored_groups automáticamente' AS note;
