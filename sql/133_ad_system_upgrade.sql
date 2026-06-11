-- ════════════════════════════════════════════════════════════════════════════
-- 133_ad_system_upgrade.sql
-- Sistema automático de publicidad: controles de admin, audit log y seguridad.
--
-- IMPLEMENTA:
--   1. ad_audit_log              — historial de acciones sobre anuncios
--   2. approve_ad                — retorna JSONB, límites por tipo, audit log,
--                                  activa sponsored_groups
--   3. reject_ad                 — retorna JSONB, audit log
--   4. toggle_ad                 — retorna JSONB, audit log, pausa sponsored_groups
--   5. delete_ad                 — nuevo RPC con audit log
--   6. expire_advertisements     — audit log masivo al expirar
--   7. get_active_banner_ads     — prioridad por precio DESC + duration_seconds
--   8. get_profile_ads           — retorna link_type/link_id (sin URLs externas)
--   9. create_advertisement_order— reemplaza versiones anteriores:
--                                  · sin p_link_url / p_button_url
--                                  · solo link_type ∈ {'none','group'}
--                                  · valida existencia del grupo si link_type='group'
--  10. Actualiza CHECK constraint de link_type en advertisements
--
-- Ejecutar DESPUÉS de 132_ad_media_duration.sql
-- ════════════════════════════════════════════════════════════════════════════


-- ── 1. Tabla ad_audit_log ─────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.ad_audit_log (
  id           UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  ad_id        UUID        REFERENCES public.advertisements(id) ON DELETE SET NULL,
  action       TEXT        NOT NULL, -- 'approved','rejected','paused','resumed','deleted','expired'
  performed_by UUID        REFERENCES auth.users(id) ON DELETE SET NULL,
  performed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  details      JSONB
);

CREATE INDEX IF NOT EXISTS idx_audit_ad_id   ON public.ad_audit_log (ad_id);
CREATE INDEX IF NOT EXISTS idx_audit_action  ON public.ad_audit_log (action, performed_at DESC);

ALTER TABLE public.ad_audit_log ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "audit_admin_read"    ON public.ad_audit_log;
DROP POLICY IF EXISTS "audit_system_insert" ON public.ad_audit_log;

CREATE POLICY "audit_admin_read" ON public.ad_audit_log FOR SELECT USING (
  EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin')
);
CREATE POLICY "audit_system_insert" ON public.ad_audit_log FOR INSERT WITH CHECK (true);


-- ── 2. Actualizar CHECK de link_type: quitar 'url' ────────────────────────────

DO $$
DECLARE r RECORD;
BEGIN
  FOR r IN
    SELECT conname FROM pg_constraint
    WHERE  conrelid = 'public.advertisements'::regclass
      AND  contype  = 'c'
      AND  conname  ILIKE '%link_type%'
  LOOP
    EXECUTE 'ALTER TABLE public.advertisements DROP CONSTRAINT ' || quote_ident(r.conname);
  END LOOP;
END;
$$;

ALTER TABLE public.advertisements
  ADD CONSTRAINT advertisements_link_type_check
    CHECK (link_type IN ('none', 'group'));


-- ── 3. approve_ad — JSONB return + límites + audit log ───────────────────────
-- Límites simultáneos por tipo: banner_home=8, sponsored_group=5, profile_ad=10

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
  v_days   INT;
  v_ad     RECORD;
  v_count  INT;
  v_max    INT;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Unauthorized');
  END IF;

  SELECT a.*, ap.duration_days AS pkg_days, ap.price AS pkg_price
  INTO   v_ad
  FROM   public.advertisements a
  LEFT JOIN public.ad_packages ap ON ap.id = a.package_id
  WHERE  a.id = p_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'ad_not_found');
  END IF;

  v_days := COALESCE(p_duration_days, v_ad.pkg_days, 7);

  -- Verificar límite por tipo
  v_max := CASE v_ad.type
    WHEN 'banner_home'     THEN 8
    WHEN 'sponsored_group' THEN 5
    WHEN 'profile_ad'      THEN 10
    ELSE 99
  END;

  SELECT COUNT(*) INTO v_count
  FROM   public.advertisements
  WHERE  type = v_ad.type AND status = 'active';

  IF v_count >= v_max THEN
    RETURN jsonb_build_object(
      'ok',    false,
      'error', 'limit_reached',
      'limit', v_max,
      'count', v_count,
      'type',  v_ad.type
    );
  END IF;

  -- Activar el anuncio
  UPDATE public.advertisements
  SET    status      = 'active',
         approved_at = now(),
         approved_by = auth.uid(),
         starts_at   = COALESCE(starts_at, now()),
         ends_at     = COALESCE(ends_at,   now() + (v_days || ' days')::INTERVAL),
         updated_at  = now()
  WHERE  id = p_id;

  -- Para sponsored_group: activar el registro correspondiente
  IF v_ad.type = 'sponsored_group' THEN
    UPDATE public.sponsored_groups
    SET    is_active = true,
           starts_at = now(),
           ends_at   = now() + (v_days || ' days')::INTERVAL
    WHERE  advertiser_id = v_ad.advertiser_id
      AND  package_id    = v_ad.package_id
      AND  is_active     = false;
  END IF;

  -- Audit log
  INSERT INTO public.ad_audit_log (ad_id, action, performed_by, details)
  VALUES (p_id, 'approved', auth.uid(),
    jsonb_build_object(
      'title',         v_ad.title,
      'type',          v_ad.type,
      'duration_days', v_days,
      'ends_at',       now() + (v_days || ' days')::INTERVAL
    )
  );

  RETURN jsonb_build_object('ok', true, 'duration_days', v_days);
END;
$$;

GRANT EXECUTE ON FUNCTION public.approve_ad(UUID, INT) TO authenticated;


-- ── 4. reject_ad — retorna JSONB + audit log ─────────────────────────────────

DROP FUNCTION IF EXISTS public.reject_ad(UUID, TEXT);
CREATE OR REPLACE FUNCTION public.reject_ad(p_id UUID, p_reason TEXT DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_title TEXT;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Unauthorized');
  END IF;

  SELECT title INTO v_title FROM public.advertisements WHERE id = p_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'ad_not_found');
  END IF;

  UPDATE public.advertisements
  SET    status = 'rejected', rejection_reason = p_reason, updated_at = now()
  WHERE  id = p_id;

  INSERT INTO public.ad_audit_log (ad_id, action, performed_by, details)
  VALUES (p_id, 'rejected', auth.uid(),
    jsonb_build_object('title', v_title, 'reason', p_reason)
  );

  RETURN jsonb_build_object('ok', true);
END;
$$;

GRANT EXECUTE ON FUNCTION public.reject_ad(UUID, TEXT) TO authenticated;


-- ── 5. toggle_ad — retorna JSONB + audit log ─────────────────────────────────

DROP FUNCTION IF EXISTS public.toggle_ad(UUID);
CREATE OR REPLACE FUNCTION public.toggle_ad(p_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_ad         RECORD;
  v_new_status TEXT;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Unauthorized');
  END IF;

  SELECT id, title, status, type, advertiser_id, package_id
  INTO   v_ad
  FROM   public.advertisements WHERE id = p_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'ad_not_found');
  END IF;

  v_new_status := CASE WHEN v_ad.status = 'active' THEN 'paused' ELSE 'active' END;

  UPDATE public.advertisements
  SET    status = v_new_status, updated_at = now()
  WHERE  id = p_id;

  -- Para sponsored_group: reflejar pausa/reactivación
  IF v_ad.type = 'sponsored_group' THEN
    UPDATE public.sponsored_groups
    SET    is_active = (v_new_status = 'active')
    WHERE  advertiser_id = v_ad.advertiser_id
      AND  package_id    = v_ad.package_id;
  END IF;

  INSERT INTO public.ad_audit_log (ad_id, action, performed_by, details)
  VALUES (
    p_id,
    CASE WHEN v_new_status = 'paused' THEN 'paused' ELSE 'resumed' END,
    auth.uid(),
    jsonb_build_object('title', v_ad.title, 'new_status', v_new_status)
  );

  RETURN jsonb_build_object('ok', true, 'status', v_new_status);
END;
$$;

GRANT EXECUTE ON FUNCTION public.toggle_ad(UUID) TO authenticated;


-- ── 6. delete_ad — nuevo RPC con audit log ───────────────────────────────────

DROP FUNCTION IF EXISTS public.delete_ad(UUID);
CREATE OR REPLACE FUNCTION public.delete_ad(p_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_title     TEXT;
  v_type      TEXT;
  v_advertiser UUID;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Unauthorized');
  END IF;

  SELECT title, type, advertiser_id
  INTO   v_title, v_type, v_advertiser
  FROM   public.advertisements WHERE id = p_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'ad_not_found');
  END IF;

  -- Audit log antes de borrar (FK ON DELETE SET NULL preservará la fila)
  INSERT INTO public.ad_audit_log (ad_id, action, performed_by, details)
  VALUES (p_id, 'deleted', auth.uid(),
    jsonb_build_object(
      'title',         v_title,
      'type',          v_type,
      'advertiser_id', v_advertiser
    )
  );

  DELETE FROM public.advertisements WHERE id = p_id;

  RETURN jsonb_build_object('ok', true);
END;
$$;

GRANT EXECUTE ON FUNCTION public.delete_ad(UUID) TO authenticated;


-- ── 7. expire_advertisements — audit log al expirar ──────────────────────────

CREATE OR REPLACE FUNCTION public.expire_advertisements()
RETURNS INT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_count INT;
  v_ad    RECORD;
BEGIN
  -- Insertar audit log para cada anuncio que va a expirar
  FOR v_ad IN
    SELECT id, title, type, ends_at
    FROM   public.advertisements
    WHERE  status IN ('active', 'approved')
      AND  ends_at IS NOT NULL
      AND  ends_at < now()
  LOOP
    INSERT INTO public.ad_audit_log (ad_id, action, performed_by, details)
    VALUES (
      v_ad.id, 'expired', NULL,
      jsonb_build_object(
        'title',    v_ad.title,
        'type',     v_ad.type,
        'ended_at', v_ad.ends_at
      )
    );
  END LOOP;

  UPDATE public.advertisements
  SET    status = 'expired', updated_at = now()
  WHERE  status IN ('active', 'approved')
    AND  ends_at IS NOT NULL
    AND  ends_at < now();
  GET DIAGNOSTICS v_count = ROW_COUNT;

  UPDATE public.sponsored_groups
  SET    is_active = false
  WHERE  is_active = true AND ends_at < now();

  RETURN v_count;
END;
$$;

GRANT EXECUTE ON FUNCTION public.expire_advertisements() TO authenticated;


-- ── 8. get_active_banner_ads — prioridad por precio + duration_seconds ────────

DROP FUNCTION IF EXISTS public.get_active_banner_ads(TEXT);
CREATE OR REPLACE FUNCTION public.get_active_banner_ads(p_city TEXT DEFAULT NULL)
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
  order_index      INT
)
LANGUAGE plpgsql
SECURITY DEFINER STABLE
SET search_path = public
AS $$
BEGIN
  PERFORM public.expire_advertisements();
  RETURN QUERY
  SELECT a.id, a.title, a.subtitle, a.tag, a.button_text,
         a.media_url, a.media_type, a.media_offset,
         a.link_type, a.link_id,
         a.duration_seconds,
         a.order_index
  FROM   public.advertisements a
  LEFT JOIN public.ad_packages pkg ON pkg.id = a.package_id
  WHERE  a.type   = 'banner_home'
    AND  a.status = 'active'
    AND  (a.starts_at IS NULL OR a.starts_at <= now())
    AND  (a.ends_at   IS NULL OR a.ends_at   >  now())
    AND  (
      a.target_location_type IS NULL
      OR a.target_location_type = 'national'
      OR p_city IS NULL
      OR (a.target_locations IS NOT NULL
          AND a.target_locations @> jsonb_build_array(p_city))
    )
  ORDER BY
    COALESCE(pkg.price, 0) DESC,
    a.order_index ASC,
    a.starts_at ASC;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_active_banner_ads(TEXT) TO anon, authenticated;


-- ── 9. get_profile_ads — link_type/link_id, sin URLs externas ────────────────

DROP FUNCTION IF EXISTS public.get_profile_ads(UUID, TEXT);
CREATE OR REPLACE FUNCTION public.get_profile_ads(
  p_group_id UUID,
  p_city     TEXT DEFAULT NULL
)
RETURNS TABLE (
  id          UUID,
  title       TEXT,
  subtitle    TEXT,
  button_text TEXT,
  media_url   TEXT,
  media_type  TEXT,
  link_type   TEXT,
  link_id     UUID
)
LANGUAGE plpgsql
SECURITY DEFINER STABLE
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT a.id, a.title, a.subtitle, a.button_text,
         a.media_url, a.media_type,
         a.link_type, a.link_id
  FROM   public.advertisements a
  WHERE  a.type   = 'profile_ad'
    AND  a.status = 'active'
    AND  (a.target_group_id IS NULL OR a.target_group_id = p_group_id)
    AND  (a.starts_at IS NULL OR a.starts_at <= now())
    AND  (a.ends_at   IS NULL OR a.ends_at   >  now())
    AND  (
      a.target_location_type IS NULL
      OR a.target_location_type = 'national'
      OR p_city IS NULL
      OR (a.target_locations IS NOT NULL
          AND a.target_locations @> jsonb_build_array(p_city))
    )
  ORDER  BY a.order_index
  LIMIT  1;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_profile_ads(UUID, TEXT) TO authenticated;


-- ── 10. create_advertisement_order — solo link_type ∈ {'none','group'} ────────
-- Eliminar todas las sobrecargas anteriores

DROP FUNCTION IF EXISTS public.create_advertisement_order(TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,UUID,UUID,TEXT,TEXT,TEXT,TEXT,JSONB);
DROP FUNCTION IF EXISTS public.create_advertisement_order(TEXT,TEXT,UUID,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT[],INT);

CREATE OR REPLACE FUNCTION public.create_advertisement_order(
  p_type             TEXT,
  p_title            TEXT,
  p_package_id       UUID,
  p_subtitle         TEXT    DEFAULT NULL,
  p_button_text      TEXT    DEFAULT 'Contratar',
  p_media_url        TEXT    DEFAULT NULL,
  p_media_type       TEXT    DEFAULT 'none',
  p_link_type        TEXT    DEFAULT 'none',
  p_link_id          UUID    DEFAULT NULL,
  p_location_type    TEXT    DEFAULT 'national',
  p_locations        TEXT[]  DEFAULT NULL,
  p_duration_seconds INT     DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id  UUID := auth.uid();
  v_pkg      RECORD;
  v_ad_id    UUID;
  v_group_id UUID;
  v_loc_type TEXT;
BEGIN
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'No autenticado');
  END IF;

  -- Validar link_type
  IF p_link_type NOT IN ('none', 'group') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'link_type_invalid');
  END IF;

  -- Validar grupo si link_type='group'
  IF p_link_type = 'group' THEN
    IF p_link_id IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'error', 'link_id_required_for_group');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.groups WHERE id = p_link_id) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'group_not_found');
    END IF;
  END IF;

  -- Validar paquete
  SELECT * INTO v_pkg FROM public.ad_packages
  WHERE id = p_package_id AND is_active = true;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Paquete no encontrado o inactivo');
  END IF;

  -- Normalizar location_type
  v_loc_type := COALESCE(NULLIF(p_location_type, ''), 'national');

  -- Para sponsored_group: resolver grupo del anunciante automáticamente
  IF p_type = 'sponsored_group' THEN
    SELECT id INTO v_group_id FROM public.groups
    WHERE owner_id = v_user_id LIMIT 1;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('ok', false, 'error', 'group_not_found');
    END IF;
  END IF;

  INSERT INTO public.advertisements (
    advertiser_id, package_id, type,
    title, subtitle, button_text,
    media_url, media_type, duration_seconds,
    link_type, link_id,
    target_location_type, target_locations,
    status
  ) VALUES (
    v_user_id, p_package_id, p_type,
    p_title, p_subtitle, COALESCE(p_button_text, 'Contratar'),
    p_media_url, p_media_type, p_duration_seconds,
    CASE WHEN p_type = 'sponsored_group' THEN 'group' ELSE p_link_type END,
    CASE WHEN p_type = 'sponsored_group' THEN v_group_id ELSE p_link_id END,
    v_loc_type,
    CASE WHEN v_loc_type = 'national' THEN NULL
         ELSE to_jsonb(p_locations) END,
    'pending_review'
  )
  RETURNING id INTO v_ad_id;

  -- Para sponsored_group: crear registro en sponsored_groups (inactivo hasta aprobar)
  IF p_type = 'sponsored_group' AND v_group_id IS NOT NULL THEN
    INSERT INTO public.sponsored_groups (
      group_id, advertiser_id, package_id,
      starts_at, ends_at, is_active
    ) VALUES (
      v_group_id, v_user_id, p_package_id,
      now(), now() + (COALESCE(v_pkg.duration_days, 7) || ' days')::INTERVAL,
      false
    ) ON CONFLICT DO NOTHING;
  END IF;

  RETURN jsonb_build_object(
    'ok',     true,
    'ad_id',  v_ad_id,
    'amount', COALESCE(v_pkg.price, 0),
    'type',   p_type
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.create_advertisement_order(TEXT,TEXT,UUID,TEXT,TEXT,TEXT,TEXT,TEXT,UUID,TEXT,TEXT[],INT) TO authenticated;


SELECT '133_ad_system_upgrade.sql ejecutado ✅' AS status;
SELECT 'Nueva tabla: ad_audit_log' AS info
UNION ALL SELECT 'RPCs actualizados: approve_ad (JSONB+límites), reject_ad, toggle_ad, delete_ad'
UNION ALL SELECT 'RPCs actualizados: expire_advertisements (audit), get_active_banner_ads (precio+duration)'
UNION ALL SELECT 'RPCs actualizados: get_profile_ads (link_type+link_id), create_advertisement_order (sin URLs)'
UNION ALL SELECT 'Constraint: link_type solo permite none|group';
