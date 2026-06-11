-- ════════════════════════════════════════════════════════════════════════════
-- 121_fix_sponsored_groups.sql
-- Corrige approve_ad() para manejar compras duplicadas correctamente:
--
--   • ON CONFLICT DO NOTHING → ON CONFLICT DO UPDATE (extiende ends_at)
--   • Elimina la restricción innecesaria de package_id en el UPDATE
--   • Cuando ya existe un sponsored_group activo, prolonga ends_at en lugar
--     de ignorar el nuevo pago.
--
-- Ejecutar DESPUÉS de 120_fix_profile_ads_and_packages.sql
-- ════════════════════════════════════════════════════════════════════════════

-- Asegurar que existe un UNIQUE constraint en sponsored_groups(group_id, advertiser_id)
-- para que ON CONFLICT funcione correctamente.
ALTER TABLE public.sponsored_groups
  DROP CONSTRAINT IF EXISTS sponsored_groups_group_advertiser_unique;

ALTER TABLE public.sponsored_groups
  ADD CONSTRAINT sponsored_groups_group_advertiser_unique
    UNIQUE (group_id, advertiser_id);


-- ── approve_ad() corregido ────────────────────────────────────────────────

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
  SELECT a.*, ap.duration_days AS pkg_days
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

  -- Para sponsored_group: activar/extender el registro en sponsored_groups
  IF v_ad.type = 'sponsored_group' AND v_ad.link_id IS NOT NULL THEN
    INSERT INTO public.sponsored_groups (
      group_id, advertiser_id, package_id,
      starts_at, ends_at, is_active
    ) VALUES (
      v_ad.link_id, v_ad.advertiser_id, v_ad.package_id,
      now(),
      now() + (v_days || ' days')::INTERVAL,
      true
    )
    ON CONFLICT (group_id, advertiser_id) DO UPDATE SET
      -- Si ya tiene tiempo restante, extender desde ends_at actual; si no, desde ahora
      ends_at    = GREATEST(
                     public.sponsored_groups.ends_at,
                     now()
                   ) + (v_days || ' days')::INTERVAL,
      starts_at  = CASE
                     WHEN public.sponsored_groups.is_active = false
                     THEN now()
                     ELSE public.sponsored_groups.starts_at
                   END,
      is_active  = true,
      package_id = v_ad.package_id;
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION public.approve_ad(UUID, INT) TO authenticated;


SELECT '121_fix_sponsored_groups.sql ejecutado ✅' AS status;
SELECT 'approve_ad() ahora extiende ends_at en compras duplicadas en lugar de ignorarlas' AS note;
