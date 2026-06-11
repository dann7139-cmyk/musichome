-- ============================================================
-- sql/268_fix_owner_group_visibility.sql
--
-- Asegura que el grupo del dueño (da.em.ri.ce@gmail.com)
-- sea visible en el explorador de Jalisco:
--   1. is_active = true
--   2. state = 'Jalisco'
--   3. country = 'México'
-- También sincroniza profiles.state del owner.
-- ============================================================

DO $$
DECLARE
  v_uid    UUID;
  v_gid    UUID;
  v_name   TEXT;
  v_state  TEXT;
BEGIN
  -- Buscar el owner por email
  SELECT id INTO v_uid
  FROM auth.users
  WHERE email = 'da.em.ri.ce@gmail.com'
  LIMIT 1;

  IF v_uid IS NULL THEN
    RAISE NOTICE 'Usuario da.em.ri.ce@gmail.com no encontrado';
    RETURN;
  END IF;

  -- Buscar su grupo
  SELECT id, name, state INTO v_gid, v_name, v_state
  FROM public.groups
  WHERE owner_id = v_uid
  LIMIT 1;

  IF v_gid IS NULL THEN
    RAISE NOTICE 'No se encontró grupo para uid=%', v_uid;
    RETURN;
  END IF;

  RAISE NOTICE 'Grupo encontrado: id=%, name=%, state_actual=%', v_gid, v_name, v_state;

  -- Activar y fijar estado si state es null o vacío
  UPDATE public.groups
  SET
    is_active   = true,
    state       = COALESCE(NULLIF(TRIM(state), ''), 'Jalisco'),
    country     = COALESCE(NULLIF(TRIM(country), ''), 'México'),
    updated_at  = NOW()
  WHERE id = v_gid;

  RAISE NOTICE 'Grupo actualizado: is_active=true, state=Jalisco (si estaba vacío)';

  -- Sincronizar profiles.state del owner
  UPDATE public.profiles
  SET
    state      = COALESCE(NULLIF(TRIM(state), ''), 'Jalisco'),
    updated_at = NOW()
  WHERE id = v_uid
    AND (state IS NULL OR TRIM(state) = '');

  RAISE NOTICE 'Profile.state sincronizado si estaba vacío';
END;
$$;

-- Verificación
SELECT
  g.id,
  g.name,
  g.city,
  g.state,
  g.country,
  g.is_active,
  g.is_verified,
  p.full_name  AS owner_name,
  p.city       AS owner_city,
  p.state      AS owner_state
FROM public.groups g
JOIN public.profiles p ON p.id = g.owner_id
JOIN auth.users u ON u.id = g.owner_id
WHERE u.email = 'da.em.ri.ce@gmail.com';

SELECT '268_fix_owner_group_visibility.sql ejecutado ✅' AS status;
