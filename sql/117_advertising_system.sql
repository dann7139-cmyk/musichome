-- ════════════════════════════════════════════════════════════════════════════
-- 117_advertising_system.sql
-- Sistema completo de publicidad pagada para Daricefy.
--
-- IMPLEMENTA:
--   1. ad_packages           — paquetes con precio y duración
--   2. advertisements        — anuncios con flujo de aprobación
--   3. sponsored_groups      — grupos que pagan para aparecer en Destacados
--   4. expire_advertisements()  — expiración automática
--   5. get_active_banner_ads()  — anuncios activos para el home
--   6. get_profile_ads(id)      — anuncio para perfil de grupo
--   7. get_sponsored_group_ids()— grupos patrocinados activos
--   8. get_pending_ads()        — admin: ver todos los anuncios
--   9. approve_ad(id, días)     — admin: aprobar
--  10. reject_ad(id, razón)     — admin: rechazar
--  11. toggle_ad(id)            — admin: pausar / reactivar
--  12. RLS policies
--
-- Ejecutar DESPUÉS de 116_zone_activity_notifications.sql
-- ════════════════════════════════════════════════════════════════════════════


-- ── 1. Paquetes de publicidad ──────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.ad_packages (
  id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  name          TEXT        NOT NULL,
  type          TEXT        NOT NULL CHECK (type IN ('banner_home', 'sponsored_group', 'profile_ad')),
  duration_days INT         NOT NULL,
  price         NUMERIC(10,2) NOT NULL DEFAULT 0,
  description   TEXT,
  is_active     BOOLEAN     NOT NULL DEFAULT true,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Paquetes por defecto
INSERT INTO public.ad_packages (name, type, duration_days, price, description) VALUES
  ('Banner Home — 1 semana',    'banner_home',     7,  299.00, 'Tu anuncio en la pantalla principal durante 7 días'),
  ('Banner Home — 2 semanas',   'banner_home',     14, 499.00, 'Tu anuncio en la pantalla principal durante 14 días'),
  ('Banner Home — 1 mes',       'banner_home',     30, 899.00, 'Tu anuncio en la pantalla principal durante 30 días'),
  ('Grupo Destacado — 3 días',  'sponsored_group',  3, 149.00, 'Aparece primero en "Destacados" durante 3 días'),
  ('Grupo Destacado — 7 días',  'sponsored_group',  7, 249.00, 'Aparece primero en "Destacados" durante 7 días'),
  ('Grupo Destacado — 15 días', 'sponsored_group', 15, 399.00, 'Aparece primero en "Destacados" durante 15 días'),
  ('Grupo Destacado — 30 días', 'sponsored_group', 30, 699.00, 'Aparece primero en "Destacados" durante 30 días'),
  ('Anuncio en Perfil — 1 sem', 'profile_ad',       7, 199.00, 'Tu anuncio aparece en perfiles de grupos — 7 días'),
  ('Anuncio en Perfil — 1 mes', 'profile_ad',      30, 599.00, 'Tu anuncio aparece en perfiles de grupos — 30 días')
ON CONFLICT DO NOTHING;


-- ── 2. Tabla de anuncios ───────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.advertisements (
  id               UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  advertiser_id    UUID        REFERENCES auth.users(id) ON DELETE SET NULL,
  package_id       UUID        REFERENCES public.ad_packages(id) ON DELETE SET NULL,
  type             TEXT        NOT NULL CHECK (type IN ('banner_home', 'sponsored_group', 'profile_ad')),

  -- Contenido visual
  title            TEXT        NOT NULL,
  subtitle         TEXT,
  tag              TEXT        NOT NULL DEFAULT 'PUBLICIDAD',
  button_text      TEXT        NOT NULL DEFAULT 'Contactar',
  media_url        TEXT,
  media_type       TEXT        NOT NULL DEFAULT 'none' CHECK (media_type IN ('none', 'image', 'video')),
  media_offset     INT         DEFAULT 50,

  -- Enlace destino
  link_type        TEXT        NOT NULL DEFAULT 'none' CHECK (link_type IN ('none', 'group', 'url')),
  link_id          UUID,        -- group_id si link_type = 'group'
  link_url         TEXT,        -- URL externa

  -- Solo para profile_ad: qué perfil de grupo (NULL = todos los grupos)
  target_group_id  UUID        REFERENCES public.groups(id) ON DELETE CASCADE,

  -- Ciclo de vida
  status           TEXT        NOT NULL DEFAULT 'pending_review'
                               CHECK (status IN ('pending_review','approved','active','paused','rejected','expired')),
  rejection_reason TEXT,
  starts_at        TIMESTAMPTZ,
  ends_at          TIMESTAMPTZ,

  -- Métricas
  order_index      INT         NOT NULL DEFAULT 0,
  impressions      BIGINT      NOT NULL DEFAULT 0,
  clicks           BIGINT      NOT NULL DEFAULT 0,

  -- Auditoría
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  approved_at      TIMESTAMPTZ,
  approved_by      UUID        REFERENCES auth.users(id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS idx_ads_type_status  ON public.advertisements (type, status);
CREATE INDEX IF NOT EXISTS idx_ads_ends_at      ON public.advertisements (ends_at);
CREATE INDEX IF NOT EXISTS idx_ads_target_group ON public.advertisements (target_group_id);


-- ── 3. Grupos patrocinados ─────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.sponsored_groups (
  id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  group_id      UUID        NOT NULL REFERENCES public.groups(id) ON DELETE CASCADE,
  advertiser_id UUID        REFERENCES auth.users(id) ON DELETE SET NULL,
  package_id    UUID        REFERENCES public.ad_packages(id) ON DELETE SET NULL,
  starts_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  ends_at       TIMESTAMPTZ NOT NULL,
  is_active     BOOLEAN     NOT NULL DEFAULT true,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_sponsored_ends ON public.sponsored_groups (ends_at, is_active);
CREATE INDEX IF NOT EXISTS idx_sponsored_grp  ON public.sponsored_groups (group_id);


-- ── 4. Trigger updated_at ─────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public._ads_set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END;
$$;

DROP TRIGGER IF EXISTS trg_ads_updated_at ON public.advertisements;
CREATE TRIGGER trg_ads_updated_at
  BEFORE UPDATE ON public.advertisements
  FOR EACH ROW EXECUTE FUNCTION public._ads_set_updated_at();


-- ── 5. Expiración automática ───────────────────────────────────────────────
-- Llama esta función periódicamente (pg_cron o en cada carga de la app).

CREATE OR REPLACE FUNCTION public.expire_advertisements()
RETURNS INT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_count INT;
BEGIN
  UPDATE public.advertisements
  SET    status = 'expired', updated_at = now()
  WHERE  status IN ('active', 'approved')
    AND  ends_at IS NOT NULL
    AND  ends_at < now();
  GET DIAGNOSTICS v_count = ROW_COUNT;

  UPDATE public.sponsored_groups
  SET is_active = false
  WHERE is_active = true AND ends_at < now();

  RETURN v_count;
END;
$$;

GRANT EXECUTE ON FUNCTION public.expire_advertisements() TO authenticated;


-- ── 6. RPC: get_active_banner_ads() ───────────────────────────────────────

DROP FUNCTION IF EXISTS public.get_active_banner_ads();
CREATE OR REPLACE FUNCTION public.get_active_banner_ads()
RETURNS TABLE (
  id           UUID,
  title        TEXT,
  subtitle     TEXT,
  tag          TEXT,
  button_text  TEXT,
  media_url    TEXT,
  media_type   TEXT,
  media_offset INT,
  link_type    TEXT,
  link_id      UUID,
  link_url     TEXT,
  order_index  INT
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
         a.link_type, a.link_id, a.link_url, a.order_index
  FROM   public.advertisements a
  WHERE  a.type   = 'banner_home'
    AND  a.status = 'active'
    AND  (a.starts_at IS NULL OR a.starts_at <= now())
    AND  (a.ends_at   IS NULL OR a.ends_at   >  now())
  ORDER  BY a.order_index, a.created_at;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_active_banner_ads() TO anon, authenticated;


-- ── 7. RPC: get_profile_ads(p_group_id) ───────────────────────────────────

DROP FUNCTION IF EXISTS public.get_profile_ads(UUID);
CREATE OR REPLACE FUNCTION public.get_profile_ads(p_group_id UUID)
RETURNS TABLE (
  id          UUID,
  title       TEXT,
  subtitle    TEXT,
  button_text TEXT,
  media_url   TEXT,
  media_type  TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER STABLE
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT a.id, a.title, a.subtitle, a.button_text, a.media_url, a.media_type
  FROM   public.advertisements a
  WHERE  a.type   = 'profile_ad'
    AND  a.status = 'active'
    AND  (a.target_group_id IS NULL OR a.target_group_id = p_group_id)
    AND  (a.starts_at IS NULL OR a.starts_at <= now())
    AND  (a.ends_at   IS NULL OR a.ends_at   >  now())
  ORDER  BY a.order_index
  LIMIT  1;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_profile_ads(UUID) TO authenticated;


-- ── 8. RPC: get_sponsored_group_ids() ─────────────────────────────────────

DROP FUNCTION IF EXISTS public.get_sponsored_group_ids();
CREATE OR REPLACE FUNCTION public.get_sponsored_group_ids()
RETURNS TABLE (group_id UUID, ends_at TIMESTAMPTZ)
LANGUAGE plpgsql
SECURITY DEFINER STABLE
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT DISTINCT sg.group_id, sg.ends_at
  FROM   public.sponsored_groups sg
  WHERE  sg.is_active = true
    AND  sg.ends_at   > now()
  ORDER  BY sg.ends_at DESC;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_sponsored_group_ids() TO authenticated;


-- ── 9. Admin: get_pending_ads() ────────────────────────────────────────────

DROP FUNCTION IF EXISTS public.get_pending_ads();
CREATE OR REPLACE FUNCTION public.get_pending_ads()
RETURNS TABLE (
  id               UUID,
  type             TEXT,
  title            TEXT,
  subtitle         TEXT,
  tag              TEXT,
  media_url        TEXT,
  media_type       TEXT,
  status           TEXT,
  rejection_reason TEXT,
  package_name     TEXT,
  advertiser_email TEXT,
  order_index      INT,
  impressions      BIGINT,
  clicks           BIGINT,
  created_at       TIMESTAMPTZ,
  starts_at        TIMESTAMPTZ,
  ends_at          TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER STABLE
SET search_path = public
AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin') THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  PERFORM public.expire_advertisements();

  RETURN QUERY
  SELECT  a.id, a.type, a.title, a.subtitle, a.tag,
          a.media_url, a.media_type, a.status, a.rejection_reason,
          p.name   AS package_name,
          u.email  AS advertiser_email,
          a.order_index, a.impressions, a.clicks,
          a.created_at, a.starts_at, a.ends_at
  FROM    public.advertisements  a
  LEFT JOIN public.ad_packages  p ON p.id = a.package_id
  LEFT JOIN auth.users          u ON u.id = a.advertiser_id
  ORDER BY
    CASE a.status
      WHEN 'pending_review' THEN 0
      WHEN 'active'         THEN 1
      WHEN 'approved'       THEN 2
      WHEN 'paused'         THEN 3
      ELSE 4
    END,
    a.created_at DESC;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_pending_ads() TO authenticated;


-- ── 10. Admin: approve_ad(id, días) ───────────────────────────────────────

DROP FUNCTION IF EXISTS public.approve_ad(UUID, INT);
CREATE OR REPLACE FUNCTION public.approve_ad(
  p_id           UUID,
  p_duration_days INT DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_days INT;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin') THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  SELECT COALESCE(p_duration_days, ap.duration_days, 7) INTO v_days
  FROM   public.advertisements a
  LEFT JOIN public.ad_packages ap ON ap.id = a.package_id
  WHERE  a.id = p_id;

  UPDATE public.advertisements
  SET    status      = 'active',
         approved_at = now(),
         approved_by = auth.uid(),
         starts_at   = COALESCE(starts_at, now()),
         ends_at     = COALESCE(ends_at,   now() + (v_days || ' days')::INTERVAL),
         updated_at  = now()
  WHERE  id = p_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.approve_ad(UUID, INT) TO authenticated;


-- ── 11. Admin: reject_ad(id, reason) ──────────────────────────────────────

DROP FUNCTION IF EXISTS public.reject_ad(UUID, TEXT);
CREATE OR REPLACE FUNCTION public.reject_ad(p_id UUID, p_reason TEXT DEFAULT NULL)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin') THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;
  UPDATE public.advertisements
  SET status = 'rejected', rejection_reason = p_reason, updated_at = now()
  WHERE id = p_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.reject_ad(UUID, TEXT) TO authenticated;


-- ── 12. Admin: toggle_ad(id) — pausa / reactiva ───────────────────────────

DROP FUNCTION IF EXISTS public.toggle_ad(UUID);
CREATE OR REPLACE FUNCTION public.toggle_ad(p_id UUID)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_new_status TEXT;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin') THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  SELECT CASE WHEN status = 'active' THEN 'paused' ELSE 'active' END
  INTO   v_new_status
  FROM   public.advertisements WHERE id = p_id;

  UPDATE public.advertisements
  SET status = v_new_status, updated_at = now()
  WHERE id = p_id;

  RETURN v_new_status;
END;
$$;

GRANT EXECUTE ON FUNCTION public.toggle_ad(UUID) TO authenticated;


-- ── 13. Admin: set_ad_order(id, order_index) ──────────────────────────────

DROP FUNCTION IF EXISTS public.set_ad_order(UUID, INT);
CREATE OR REPLACE FUNCTION public.set_ad_order(p_id UUID, p_order INT)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin') THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;
  UPDATE public.advertisements SET order_index = p_order, updated_at = now() WHERE id = p_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.set_ad_order(UUID, INT) TO authenticated;


-- ── 14. RLS ────────────────────────────────────────────────────────────────

ALTER TABLE public.ad_packages      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.advertisements   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sponsored_groups ENABLE ROW LEVEL SECURITY;

-- ad_packages: lectura pública
DROP POLICY IF EXISTS "ad_packages_read" ON public.ad_packages;
CREATE POLICY "ad_packages_read" ON public.ad_packages FOR SELECT USING (true);

-- advertisements: el anunciante ve los suyos + admins ven todos + activos son públicos
DROP POLICY IF EXISTS "ads_select"        ON public.advertisements;
DROP POLICY IF EXISTS "ads_insert"        ON public.advertisements;
DROP POLICY IF EXISTS "ads_update_owner"  ON public.advertisements;

CREATE POLICY "ads_select" ON public.advertisements FOR SELECT USING (
  status = 'active'
  OR advertiser_id = auth.uid()
  OR EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin')
);

CREATE POLICY "ads_insert" ON public.advertisements FOR INSERT WITH CHECK (
  advertiser_id = auth.uid()
  OR EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin')
);

CREATE POLICY "ads_update_owner" ON public.advertisements FOR UPDATE USING (
  advertiser_id = auth.uid()
  OR EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin')
);

-- sponsored_groups
DROP POLICY IF EXISTS "spon_read"   ON public.sponsored_groups;
DROP POLICY IF EXISTS "spon_insert" ON public.sponsored_groups;

CREATE POLICY "spon_read"   ON public.sponsored_groups FOR SELECT USING (
  is_active = true OR advertiser_id = auth.uid()
  OR EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin')
);
CREATE POLICY "spon_insert" ON public.sponsored_groups FOR INSERT WITH CHECK (
  advertiser_id = auth.uid()
  OR EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin')
);


-- ── 15. pg_cron (si está disponible) ──────────────────────────────────────
-- SELECT cron.schedule('expire-ads', '0 * * * *', 'SELECT public.expire_advertisements()');


SELECT '117_advertising_system.sql ejecutado ✅' AS status;
SELECT 'Tablas: ad_packages, advertisements, sponsored_groups' AS tables;
SELECT 'RPCs: get_active_banner_ads, get_profile_ads, get_sponsored_group_ids, get_pending_ads, approve_ad, reject_ad, toggle_ad' AS rpcs;
