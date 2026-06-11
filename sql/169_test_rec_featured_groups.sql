-- ════════════════════════════════════════════════════════════════════
-- 169_test_rec_featured_groups.sql
-- Crea 4 grupos de prueba para ver el carrusel Recomendados & Destacados:
--   • 2 grupos con recommendation_orders pagadas  → badge ⭐ Reco.
--   • 2 grupos en sponsored_groups activos        → badge ⭐ Dest.
--
-- ⚠️ SOLO PARA DESARROLLO — elimina estos grupos antes de producción.
-- Para limpiar: ejecuta DELETE FROM public.groups WHERE id IN (los 4 UUIDs).
-- ════════════════════════════════════════════════════════════════════

-- ── Parche 1: handle_new_group — falla si owner_id es NULL ───────────────────
CREATE OR REPLACE FUNCTION public.handle_new_group()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  IF NEW.owner_id IS NULL THEN RETURN NEW; END IF;

  INSERT INTO public.job_board_profiles (
    user_id, instrument_or_role, experience_years,
    rating, total_jobs, availability_status, is_visible
  )
  VALUES (NEW.owner_id, 'Músico', 0, 5.0, 0, 'available', false)
  ON CONFLICT (user_id) DO NOTHING;

  RETURN NEW;
END;
$$;

-- ── Parche 2: trg_assign_founder_badge — falla si owner_id es NULL ────────────
CREATE OR REPLACE FUNCTION public.trg_assign_founder_badge()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_count INT;
BEGIN
  IF NEW.city IS NULL THEN RETURN NEW; END IF;

  SELECT COUNT(*) INTO v_count
  FROM public.groups
  WHERE LOWER(TRIM(city)) = LOWER(TRIM(NEW.city))
    AND is_active = TRUE;

  IF v_count <= 5 THEN
    UPDATE public.groups
    SET badges = array_append(COALESCE(badges, '{}'), 'grupo_fundador')
    WHERE id = NEW.id
      AND NOT ('grupo_fundador' = ANY(COALESCE(badges, '{}')));

    PERFORM public.apply_ranking_boost(NEW.id, 0.30, 2160);

    -- Solo notificar si hay dueño real
    IF NEW.owner_id IS NOT NULL THEN
      INSERT INTO public.notifications (user_id, type, title, body, data)
      VALUES (
        NEW.owner_id, 'system',
        '🏅 ¡Grupo fundador en tu ciudad!',
        'Eres uno de los primeros grupos en unirse a DARICEFY en ' || NEW.city
        || '. Recibirás mayor visibilidad durante 90 días como grupo fundador.',
        jsonb_build_object('screen', 'Dashboard', 'badge', 'grupo_fundador')
      );
    END IF;
  END IF;

  RETURN NEW;
END;
$$;


DO $$
DECLARE
  g1 UUID := 'a0000000-0000-0000-0000-000000000001';
  g2 UUID := 'a0000000-0000-0000-0000-000000000002';
  g3 UUID := 'a0000000-0000-0000-0000-000000000003';
  g4 UUID := 'a0000000-0000-0000-0000-000000000004';
BEGIN

  -- ── 1. Insertar / actualizar los 4 grupos ────────────────────────
  INSERT INTO public.groups
    (id, name, genre, city, description, price_from,
     rating, total_reviews, is_verified, is_active, photo_status)
  VALUES
    (g1, 'Los Soneros del Norte',    'Norteño',    'Guadalajara',
         'Banda norteña con 10 años de trayectoria.',          4500.00, 4.8, 42, true,  true, 'none'),
    (g2, 'Mariachi Real de Jalisco', 'Mariachi',   'Guadalajara',
         'Mariachi tradicional para bodas y todo tipo de eventos.', 5500.00, 4.9, 67, true,  true, 'none'),
    (g3, 'Banda Electro Mix',        'Banda',      'Guadalajara',
         'Banda moderna con toque electrónico y covers actuales.',  3800.00, 4.7, 28, true,  true, 'none'),
    (g4, 'Trío Romántico Azul',      'Romántico',  'Guadalajara',
         'Trío con boleros y baladas románticas para eventos íntimos.', 3200.00, 4.6, 19, false, true, 'none')
  ON CONFLICT (id) DO UPDATE
    SET name          = EXCLUDED.name,
        genre         = EXCLUDED.genre,
        city          = EXCLUDED.city,
        description   = EXCLUDED.description,
        price_from    = EXCLUDED.price_from,
        rating        = EXCLUDED.rating,
        total_reviews = EXCLUDED.total_reviews,
        is_verified   = EXCLUDED.is_verified,
        is_active     = EXCLUDED.is_active,
        photo_status  = EXCLUDED.photo_status;

  -- ── 2. recommendation_orders para g1 y g2 ───────────────────────
  --    Usamos WHERE NOT EXISTS para no depender del índice único.

  -- Limpiar órdenes de prueba anteriores para estos grupos
  DELETE FROM public.recommendation_orders
  WHERE stripe_payment_id IN ('pi_test_rec_g1_dev', 'pi_test_rec_g2_dev');

  INSERT INTO public.recommendation_orders
    (group_id, duration_days, amount, price_per_day,
     status, stripe_payment_id, starts_at, ends_at, city)
  VALUES
    (g1, 7, 399.00, 57.00, 'paid',
     'pi_test_rec_g1_dev',
     NOW() - INTERVAL '1 day',
     NOW() + INTERVAL '6 days',
     'Guadalajara'),
    (g2, 3, 199.00, 66.33, 'paid',
     'pi_test_rec_g2_dev',
     NOW() - INTERVAL '1 hour',
     NOW() + INTERVAL '2 days 23 hours',
     'Guadalajara');

  -- ── 3. sponsored_groups para g3 y g4 ────────────────────────────
  --    Borra primero los registros de prueba para no duplicar.
  DELETE FROM public.sponsored_groups
  WHERE group_id IN (g3, g4)
    AND advertiser_id IS NULL;

  INSERT INTO public.sponsored_groups
    (group_id, starts_at, ends_at, is_active)
  VALUES
    (g3, NOW(), NOW() + INTERVAL '7 days', true),
    (g4, NOW(), NOW() + INTERVAL '7 days', true);

END $$;


SELECT '169_test_rec_featured_groups.sql ejecutado ✅' AS status;
SELECT 'g1 Los Soneros del Norte    → ⭐ Reco. (7 días, $399)'  AS rec1;
SELECT 'g2 Mariachi Real de Jalisco → ⭐ Reco. (3 días, $199)'  AS rec2;
SELECT 'g3 Banda Electro Mix        → ⭐ Dest. (sponsored 7d)'  AS feat1;
SELECT 'g4 Trío Romántico Azul      → ⭐ Dest. (sponsored 7d)'  AS feat2;
SELECT 'Para limpiar: DELETE FROM public.groups WHERE id LIKE ''a0000000%''' AS cleanup;
