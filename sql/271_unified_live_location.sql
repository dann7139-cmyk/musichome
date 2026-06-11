-- ============================================================
-- sql/271_unified_live_location.sql
--
-- RPC única para actualizar ubicación en vivo desde la app.
-- Detecta el rol del usuario y escribe en la tabla correcta:
--   - role=group   → group_locations (busca por owner_id)
--   - role=talent/artist/musician → talent_locations
--   - role=client/user → client_locations
--
-- También marca offline al salir (set_me_offline).
-- ============================================================

-- ── 1. update_my_live_location ────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.update_my_live_location(
  p_lat   DOUBLE PRECISION,
  p_lng   DOUBLE PRECISION,
  p_city  TEXT DEFAULT NULL,
  p_state TEXT DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_role TEXT;
  v_group_id UUID;
BEGIN
  SELECT role INTO v_role FROM public.profiles WHERE id = auth.uid();
  IF v_role IS NULL THEN RETURN; END IF;

  IF v_role = 'group' THEN
    -- Buscar el grupo que administra este usuario
    SELECT id INTO v_group_id FROM public.groups WHERE owner_id = auth.uid() LIMIT 1;
    IF v_group_id IS NULL THEN RETURN; END IF;

    INSERT INTO public.group_locations (group_id, lat, lng, city, status, last_seen)
    VALUES (v_group_id, p_lat, p_lng, p_city, 'active', NOW())
    ON CONFLICT (group_id) DO UPDATE
      SET lat       = EXCLUDED.lat,
          lng       = EXCLUDED.lng,
          city      = COALESCE(EXCLUDED.city, group_locations.city),
          status    = 'active',
          last_seen = NOW();

  ELSIF v_role IN ('talent', 'artist', 'musician') THEN
    INSERT INTO public.talent_locations (user_id, lat, lng, city, state, status, updated_at)
    VALUES (auth.uid(), p_lat, p_lng, p_city, p_state, 'active', NOW())
    ON CONFLICT (user_id) DO UPDATE
      SET lat        = EXCLUDED.lat,
          lng        = EXCLUDED.lng,
          city       = COALESCE(EXCLUDED.city,  talent_locations.city),
          state      = COALESCE(EXCLUDED.state, talent_locations.state),
          status     = 'active',
          updated_at = NOW();

    -- Sincroniza también job_board_profiles
    UPDATE public.job_board_profiles
      SET lat = p_lat, lng = p_lng
    WHERE user_id = auth.uid();

  ELSIF v_role IN ('client', 'user') THEN
    INSERT INTO public.client_locations (user_id, lat, lng, city, state, status, updated_at)
    VALUES (auth.uid(), p_lat, p_lng, p_city, p_state, 'active', NOW())
    ON CONFLICT (user_id) DO UPDATE
      SET lat        = EXCLUDED.lat,
          lng        = EXCLUDED.lng,
          city       = COALESCE(EXCLUDED.city,  client_locations.city),
          state      = COALESCE(EXCLUDED.state, client_locations.state),
          status     = 'active',
          updated_at = NOW();
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION public.update_my_live_location(DOUBLE PRECISION, DOUBLE PRECISION, TEXT, TEXT)
  TO authenticated;

-- ── 2. set_me_offline — se llama al cerrar sesión o desactivar GPS ────────────

CREATE OR REPLACE FUNCTION public.set_me_offline()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_role TEXT;
  v_group_id UUID;
BEGIN
  SELECT role INTO v_role FROM public.profiles WHERE id = auth.uid();
  IF v_role IS NULL THEN RETURN; END IF;

  IF v_role = 'group' THEN
    SELECT id INTO v_group_id FROM public.groups WHERE owner_id = auth.uid() LIMIT 1;
    IF v_group_id IS NOT NULL THEN
      UPDATE public.group_locations SET status = 'offline', last_seen = NOW()
      WHERE group_id = v_group_id;
    END IF;

  ELSIF v_role IN ('talent', 'artist', 'musician') THEN
    UPDATE public.talent_locations SET status = 'offline', updated_at = NOW()
    WHERE user_id = auth.uid();

  ELSIF v_role IN ('client', 'user') THEN
    UPDATE public.client_locations SET status = 'offline', updated_at = NOW()
    WHERE user_id = auth.uid();
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION public.set_me_offline()
  TO authenticated;

DO $$
BEGIN
  RAISE NOTICE '[271] update_my_live_location RPC unificado ✅';
  RAISE NOTICE '[271] set_me_offline RPC creado ✅';
END;
$$;

SELECT '271_unified_live_location.sql: RPC unificado de ubicación en vivo ✅' AS status;
