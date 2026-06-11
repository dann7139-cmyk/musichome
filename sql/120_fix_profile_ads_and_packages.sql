-- ════════════════════════════════════════════════════════════════════════════
-- 120_fix_profile_ads_and_packages.sql
--
--   1. get_profile_ads() — agrega button_url y link_url al resultado
--   2. Re-inserta paquetes por defecto si la tabla está vacía
--
-- Ejecutar DESPUÉS de 119_advertisement_order_flow.sql
-- ════════════════════════════════════════════════════════════════════════════


-- ── 1. Actualizar get_profile_ads para devolver button_url y link_url ───────

DROP FUNCTION IF EXISTS public.get_profile_ads(UUID);
CREATE OR REPLACE FUNCTION public.get_profile_ads(p_group_id UUID)
RETURNS TABLE (
  id          UUID,
  title       TEXT,
  subtitle    TEXT,
  button_text TEXT,
  media_url   TEXT,
  media_type  TEXT,
  link_url    TEXT,
  button_url  TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER STABLE
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT a.id, a.title, a.subtitle, a.button_text,
         a.media_url, a.media_type,
         a.link_url, a.button_url
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


-- ── 2. Insertar paquetes por defecto si no existen ──────────────────────────

INSERT INTO public.ad_packages (name, type, duration_days, price, description, is_active)
SELECT * FROM (VALUES
  ('Banner Home — 1 semana',    'banner_home',     7,  299.00::NUMERIC, 'Tu anuncio en la pantalla principal durante 7 días',   true),
  ('Banner Home — 2 semanas',   'banner_home',     14, 499.00::NUMERIC, 'Tu anuncio en la pantalla principal durante 14 días',  true),
  ('Banner Home — 1 mes',       'banner_home',     30, 899.00::NUMERIC, 'Tu anuncio en la pantalla principal durante 30 días',  true),
  ('Grupo Destacado — 3 días',  'sponsored_group',  3, 149.00::NUMERIC, 'Aparece primero en "Destacados" durante 3 días',       true),
  ('Grupo Destacado — 7 días',  'sponsored_group',  7, 249.00::NUMERIC, 'Aparece primero en "Destacados" durante 7 días',       true),
  ('Grupo Destacado — 15 días', 'sponsored_group', 15, 399.00::NUMERIC, 'Aparece primero en "Destacados" durante 15 días',      true),
  ('Grupo Destacado — 30 días', 'sponsored_group', 30, 699.00::NUMERIC, 'Aparece primero en "Destacados" durante 30 días',      true),
  ('Anuncio en Perfil — 1 sem', 'profile_ad',       7, 199.00::NUMERIC, 'Tu anuncio aparece en perfiles de grupos — 7 días',   true),
  ('Anuncio en Perfil — 1 mes', 'profile_ad',      30, 599.00::NUMERIC, 'Tu anuncio aparece en perfiles de grupos — 30 días',  true)
) AS v(name, type, duration_days, price, description, is_active)
WHERE NOT EXISTS (SELECT 1 FROM public.ad_packages LIMIT 1);


SELECT '120_fix_profile_ads_and_packages.sql ejecutado ✅' AS status;
SELECT 'get_profile_ads ahora retorna button_url y link_url' AS note1;
SELECT 'Paquetes insertados si la tabla estaba vacía' AS note2;
