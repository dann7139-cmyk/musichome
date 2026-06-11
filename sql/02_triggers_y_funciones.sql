-- ============================================================
-- DARICEFY - 02_triggers_y_funciones.sql
-- Ejecutar SEGUNDO en Supabase SQL Editor
-- ============================================================

-- ─────────────────────────────────────────────────
-- 1. TRIGGER: Crear perfil automáticamente al registrarse
-- ─────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO public.profiles (id, email, full_name, role)
  VALUES (
    NEW.id,
    NEW.email,
    COALESCE(NEW.raw_user_meta_data->>'full_name', 'Usuario'),
    COALESCE(NEW.raw_user_meta_data->>'role', 'client')
  )
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW
  EXECUTE FUNCTION public.handle_new_user();

-- ─────────────────────────────────────────────────
-- 2. TRIGGER: Calcular comisión automáticamente al crear reserva
-- ─────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.calculate_commission()
RETURNS TRIGGER AS $$
DECLARE
  v_commission_rate DECIMAL;
BEGIN
  -- Buscar comisión del país del grupo
  SELECT c.commission_rate INTO v_commission_rate
  FROM public.groups g
  JOIN public.countries c ON g.country_id = c.id
  WHERE g.id = NEW.group_id;

  -- Si no tiene país asignado, usar 10% por defecto
  IF v_commission_rate IS NULL THEN
    v_commission_rate := 10.0;
  END IF;

  -- Calcular comisión y ganancia del grupo
  NEW.platform_commission := ROUND((NEW.total_price * v_commission_rate) / 100.0, 2);
  NEW.group_earnings := NEW.total_price - NEW.platform_commission;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS set_commission_before_insert ON public.reservations;
CREATE TRIGGER set_commission_before_insert
  BEFORE INSERT ON public.reservations
  FOR EACH ROW
  EXECUTE FUNCTION public.calculate_commission();

-- ─────────────────────────────────────────────────
-- 3. TRIGGER: Actualizar updated_at automáticamente
-- ─────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS set_updated_at_profiles ON public.profiles;
CREATE TRIGGER set_updated_at_profiles
  BEFORE UPDATE ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

DROP TRIGGER IF EXISTS set_updated_at_groups ON public.groups;
CREATE TRIGGER set_updated_at_groups
  BEFORE UPDATE ON public.groups
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

DROP TRIGGER IF EXISTS set_updated_at_reservations ON public.reservations;
CREATE TRIGGER set_updated_at_reservations
  BEFORE UPDATE ON public.reservations
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- ─────────────────────────────────────────────────
-- 4. TRIGGER: Actualizar rating del grupo al agregar reseña
-- ─────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.update_group_rating()
RETURNS TRIGGER AS $$
BEGIN
  UPDATE public.groups
  SET
    rating = (
      SELECT ROUND(AVG(rating::DECIMAL), 2)
      FROM public.reviews
      WHERE group_id = NEW.group_id
    ),
    total_reviews = (
      SELECT COUNT(*) FROM public.reviews WHERE group_id = NEW.group_id
    )
  WHERE id = NEW.group_id;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS update_rating_after_review ON public.reviews;
CREATE TRIGGER update_rating_after_review
  AFTER INSERT OR UPDATE ON public.reviews
  FOR EACH ROW EXECUTE FUNCTION public.update_group_rating();

-- ─────────────────────────────────────────────────
-- 5. TRIGGER: Actualizar estado de verificación del grupo
-- ─────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.sync_group_verification()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.status = 'approved' THEN
    UPDATE public.groups
    SET is_verified = TRUE, verification_status = 'approved'
    WHERE id = NEW.group_id;
  ELSIF NEW.status = 'rejected' THEN
    UPDATE public.groups
    SET is_verified = FALSE, verification_status = 'rejected'
    WHERE id = NEW.group_id;
  ELSIF NEW.status = 'pending' THEN
    UPDATE public.groups
    SET verification_status = 'pending'
    WHERE id = NEW.group_id;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS sync_verification_status ON public.verification_requests;
CREATE TRIGGER sync_verification_status
  AFTER INSERT OR UPDATE ON public.verification_requests
  FOR EACH ROW EXECUTE FUNCTION public.sync_group_verification();

-- ─────────────────────────────────────────────────
-- 6. FUNCIÓN: Calcular precio por hora de un paquete
-- ─────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.get_price_per_hour(package_id UUID)
RETURNS DECIMAL AS $$
  SELECT ROUND(price / duration_hours, 2) FROM public.packages WHERE id = package_id;
$$ LANGUAGE SQL STABLE;

SELECT 'Triggers y funciones creados correctamente ✅' AS status;
