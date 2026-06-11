-- ============================================================
-- 137 – Add 'bidding' (Posicionamiento) as valid ad type
-- ============================================================
-- Drops and recreates the check constraint on advertisements.type
-- to include the 'bidding' value used by the Posicionamiento feature.
-- ============================================================

-- 1. Drop ALL check constraints on advertisements.type (by any name)
DO $$
DECLARE
  r RECORD;
BEGIN
  FOR r IN
    SELECT conname
    FROM   pg_constraint
    WHERE  conrelid = 'public.advertisements'::regclass
      AND  contype  = 'c'
  LOOP
    EXECUTE format('ALTER TABLE public.advertisements DROP CONSTRAINT IF EXISTS %I', r.conname);
  END LOOP;
END $$;

-- 2. Add updated constraint with 'bidding' included
ALTER TABLE public.advertisements
  ADD CONSTRAINT advertisements_type_check
  CHECK (type IN (
    'banner_home',
    'sponsored_group',
    'profile_ad',
    'bidding'
  ));

-- 3. Ensure the approve_ad RPC allows bidding type (no limit cap by default)
-- If your approve_ad function has a hard-coded list of types, update it here.
-- Example update for a common pattern:
CREATE OR REPLACE FUNCTION public.approve_ad(p_id UUID, p_duration_days INT DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_ad     public.advertisements%ROWTYPE;
  v_limit  INT;
  v_count  INT;
  v_days   INT;
  v_start  TIMESTAMPTZ;
  v_end    TIMESTAMPTZ;
BEGIN
  SELECT * INTO v_ad FROM public.advertisements WHERE id = p_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_found');
  END IF;

  -- Determine active duration
  v_days := COALESCE(p_duration_days,
    CASE v_ad.type
      WHEN 'banner_home'     THEN 7
      WHEN 'sponsored_group' THEN 30
      WHEN 'profile_ad'      THEN 14
      WHEN 'bidding'         THEN COALESCE(v_ad.duration_days, 30)
      ELSE 7
    END
  );

  -- Per-type active limits (0 = unlimited)
  v_limit := CASE v_ad.type
    WHEN 'banner_home'     THEN 3
    WHEN 'sponsored_group' THEN 10
    WHEN 'profile_ad'      THEN 20
    WHEN 'bidding'         THEN 0   -- no hard cap
    ELSE 5
  END;

  IF v_limit > 0 THEN
    SELECT COUNT(*) INTO v_count
    FROM public.advertisements
    WHERE type   = v_ad.type
      AND status = 'active'
      AND id    != p_id;

    IF v_count >= v_limit THEN
      RETURN jsonb_build_object(
        'ok',    false,
        'error', 'limit_reached',
        'type',  v_ad.type,
        'count', v_count,
        'limit', v_limit
      );
    END IF;
  END IF;

  v_start := NOW();
  v_end   := v_start + (v_days || ' days')::INTERVAL;

  UPDATE public.advertisements
  SET status     = 'active',
      starts_at  = v_start,
      ends_at    = v_end,
      updated_at = NOW()
  WHERE id = p_id;

  RETURN jsonb_build_object('ok', true);
END;
$$;

COMMENT ON FUNCTION public.approve_ad IS
  'Approves an advertisement. Supports types: banner_home, sponsored_group, profile_ad, bidding.';
