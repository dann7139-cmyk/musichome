-- ============================================================
-- sql/260_test_talent_data.sql
--
-- Datos de prueba para la pantalla AdminTalentsScreen.
-- Solo para desarrollo / beta — NO ejecutar en producción real.
--
-- Busca perfiles existentes con role='talent' o role='client'
-- y les crea (o actualiza) un job_board_profile para que
-- aparezcan en la lista de talentos del admin.
--
-- Si ya existen entradas en job_board_profiles para esos usuarios
-- el INSERT hace UPSERT (ON CONFLICT DO UPDATE) — no duplica.
--
-- ROLLBACK:
--   DELETE FROM public.job_board_profiles
--   WHERE user_id IN (
--     SELECT id FROM public.profiles
--     WHERE email IN ('talent@music10.com')
--   );
-- ============================================================

DO $$
DECLARE
  v_uid   UUID;
  v_count INT := 0;
BEGIN
  -- ── Buscar y registrar TODOS los profiles con role='talent' ────────────────
  FOR v_uid IN
    SELECT id FROM public.profiles WHERE role = 'talent'
  LOOP
    INSERT INTO public.job_board_profiles (
      user_id,
      instrument_or_role,
      bio,
      experience_years,
      rating,
      total_jobs,
      availability_status,
      is_visible
    )
    VALUES (
      v_uid,
      'Músico',
      'Perfil de talento registrado en la plataforma.',
      0,
      5.0,
      0,
      'available',
      true
    )
    ON CONFLICT (user_id)
    DO UPDATE SET
      is_visible = true,
      availability_status = EXCLUDED.availability_status;

    v_count := v_count + 1;
    RAISE NOTICE 'job_board_profile creado/actualizado para user_id: %', v_uid;
  END LOOP;

  IF v_count = 0 THEN
    RAISE NOTICE 'No se encontraron perfiles con role=talent. Verifica que existan usuarios con ese rol.';
  ELSE
    RAISE NOTICE '% perfil(es) de talento procesado(s) ✅', v_count;
  END IF;
END;
$$;


-- ── Verificación: muestra los talentos disponibles ────────────────────────────

SELECT
  p.id,
  p.full_name,
  p.role,
  p.city,
  p.state,
  p.verification_status,
  p.admin_verified,
  jbp.instrument_or_role,
  jbp.availability_status,
  jbp.is_visible
FROM public.profiles p
LEFT JOIN public.job_board_profiles jbp ON jbp.user_id = p.id
WHERE p.role = 'talent'
   OR jbp.user_id IS NOT NULL
ORDER BY p.role, p.full_name;


SELECT '260_test_talent_data.sql aplicado correctamente ✅' AS status;
