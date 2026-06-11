-- ============================================================
-- 138 – Revert: remove 'bidding' from advertisements system
-- ============================================================
-- Posicionamiento (bidding) se mantiene como sistema separado
-- sobre la tabla groups (bid_amount, bid_ends_at).
-- No pasa por advertisements ni requiere aprobación admin.
-- ============================================================

-- 1. Restaurar constraint a solo los 3 tipos válidos
DO $$
DECLARE r RECORD;
BEGIN
  FOR r IN
    SELECT conname FROM pg_constraint
    WHERE conrelid = 'public.advertisements'::regclass AND contype = 'c'
  LOOP
    EXECUTE format('ALTER TABLE public.advertisements DROP CONSTRAINT IF EXISTS %I', r.conname);
  END LOOP;
END $$;

ALTER TABLE public.advertisements
  ADD CONSTRAINT advertisements_type_check
  CHECK (type IN ('banner_home', 'sponsored_group', 'profile_ad'));

-- 2. Restaurar approve_ad sin soporte bidding
CREATE OR REPLACE FUNCTION public.approve_ad(p_id UUID, p_duration_days INT DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_ad    public.advertisements%ROWTYPE;
  v_limit INT;
  v_count INT;
  v_days  INT;
BEGIN
  SELECT * INTO v_ad FROM public.advertisements WHERE id = p_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_found');
  END IF;

  v_days := COALESCE(p_duration_days,
    CASE v_ad.type
      WHEN 'banner_home'     THEN 7
      WHEN 'sponsored_group' THEN 30
      WHEN 'profile_ad'      THEN 14
      ELSE 7
    END
  );

  v_limit := CASE v_ad.type
    WHEN 'banner_home'     THEN 3
    WHEN 'sponsored_group' THEN 10
    WHEN 'profile_ad'      THEN 20
    ELSE 5
  END;

  SELECT COUNT(*) INTO v_count
  FROM public.advertisements
  WHERE type = v_ad.type AND status = 'active' AND id != p_id;

  IF v_count >= v_limit THEN
    RETURN jsonb_build_object(
      'ok', false, 'error', 'limit_reached',
      'type', v_ad.type, 'count', v_count, 'limit', v_limit
    );
  END IF;

  UPDATE public.advertisements
  SET status    = 'active',
      starts_at = NOW(),
      ends_at   = NOW() + (v_days || ' days')::INTERVAL,
      updated_at = NOW()
  WHERE id = p_id;

  -- Para sponsored_group: activar registro en sponsored_groups
  IF v_ad.type = 'sponsored_group' THEN
    UPDATE public.sponsored_groups
    SET is_active = true
    WHERE id = (
      SELECT id FROM public.sponsored_groups
      WHERE advertiser_id = v_ad.advertiser_id
        AND is_active = false
        AND ends_at > NOW()
      ORDER BY created_at DESC
      LIMIT 1
    );
  END IF;

  RETURN jsonb_build_object('ok', true);
END;
$$;

GRANT EXECUTE ON FUNCTION public.approve_ad(UUID, INT) TO authenticated;

COMMENT ON FUNCTION public.approve_ad IS
  'Aprueba un anuncio (banner_home, sponsored_group, profile_ad). Bidding es sistema separado.';
