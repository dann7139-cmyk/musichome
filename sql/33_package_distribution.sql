-- ══════════════════════════════════════════════════════════════════════════════
-- 33_package_distribution.sql
-- Tabla para definir cuánto gana cada integrante por paquete.
-- Validación: SUM(amount) no puede exceder package.price
-- Ejecutar en Supabase SQL Editor.
-- ══════════════════════════════════════════════════════════════════════════════

-- ── 0. Asegurar que packages tiene group_id ───────────────────────────────────
-- (Si la tabla fue creada antes de que se agregara esta columna, la añade de forma segura)
ALTER TABLE public.packages
  ADD COLUMN IF NOT EXISTS group_id UUID REFERENCES public.groups(id) ON DELETE CASCADE;

-- ── 1. Tabla package_member_distribution ──────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.package_member_distribution (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  package_id UUID NOT NULL REFERENCES public.packages(id)  ON DELETE CASCADE,
  user_id    UUID NOT NULL REFERENCES public.profiles(id)  ON DELETE CASCADE,
  amount     NUMERIC(10,2) NOT NULL CHECK (amount >= 0),
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  UNIQUE(package_id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_pmd_package ON public.package_member_distribution(package_id);
CREATE INDEX IF NOT EXISTS idx_pmd_user    ON public.package_member_distribution(user_id);

-- ── 2. Función de validación: suma ≤ precio del paquete ───────────────────────
CREATE OR REPLACE FUNCTION public.validate_package_distribution()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_price NUMERIC(10,2);
  v_total NUMERIC(10,2);
BEGIN
  -- Precio del paquete
  SELECT price INTO v_price
  FROM public.packages
  WHERE id = NEW.package_id;

  -- Suma de los demás registros del mismo paquete
  -- (excluye el propio registro en UPDATE)
  SELECT COALESCE(SUM(amount), 0) INTO v_total
  FROM public.package_member_distribution
  WHERE package_id = NEW.package_id
    AND CASE WHEN TG_OP = 'UPDATE' THEN id != OLD.id ELSE TRUE END;

  v_total := v_total + NEW.amount;

  IF v_total > v_price THEN
    RAISE EXCEPTION
      'La distribución excede el precio del paquete (máx: $%, asignado: $%)',
      v_price, v_total;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trigger_validate_package_distribution
  ON public.package_member_distribution;

CREATE TRIGGER trigger_validate_package_distribution
  BEFORE INSERT OR UPDATE ON public.package_member_distribution
  FOR EACH ROW EXECUTE FUNCTION public.validate_package_distribution();

-- ── 3. RLS ────────────────────────────────────────────────────────────────────
ALTER TABLE public.package_member_distribution ENABLE ROW LEVEL SECURITY;

-- Dueño del grupo: acceso total a las distribuciones de sus paquetes
DROP POLICY IF EXISTS "pmd_owner_all" ON public.package_member_distribution;
CREATE POLICY "pmd_owner_all"
  ON public.package_member_distribution FOR ALL
  USING (
    EXISTS (
      SELECT 1 FROM public.packages p
      JOIN public.groups g ON g.id = p.group_id
      WHERE p.id = package_id AND g.owner_id = auth.uid()
    )
  );

-- Integrantes: pueden ver su propia distribución
DROP POLICY IF EXISTS "pmd_member_select" ON public.package_member_distribution;
CREATE POLICY "pmd_member_select"
  ON public.package_member_distribution FOR SELECT
  USING (user_id = auth.uid());

-- Admin: acceso total
DROP POLICY IF EXISTS "pmd_admin_all" ON public.package_member_distribution;
CREATE POLICY "pmd_admin_all"
  ON public.package_member_distribution FOR ALL
  USING (
    EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin')
  );

-- ── 4. RPC helper: upsert distribución completa de un paquete ─────────────────
-- Recibe un arreglo JSON [{user_id, amount}] y reemplaza toda la distribución.
-- Valida que el total no exceda el precio antes de hacer nada.
CREATE OR REPLACE FUNCTION public.upsert_package_distribution(
  p_package_id UUID,
  p_rows       JSONB   -- [{user_id: uuid, amount: numeric}]
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_price  NUMERIC(10,2);
  v_total  NUMERIC(10,2) := 0;
  v_owner  UUID;
  rec      JSONB;
BEGIN
  -- Verificar que quien llama es dueño del grupo del paquete
  SELECT g.owner_id INTO v_owner
  FROM public.packages p
  JOIN public.groups g ON g.id = p.group_id
  WHERE p.id = p_package_id;

  IF v_owner IS DISTINCT FROM auth.uid() THEN
    RETURN json_build_object('error', 'Sin permiso');
  END IF;

  -- Precio del paquete
  SELECT price INTO v_price FROM public.packages WHERE id = p_package_id;

  -- Sumar el total propuesto
  FOR rec IN SELECT * FROM jsonb_array_elements(p_rows)
  LOOP
    v_total := v_total + (rec->>'amount')::NUMERIC;
  END LOOP;

  IF v_total > v_price THEN
    RETURN json_build_object(
      'error',
      'La distribución excede el precio del paquete (máx: $' || v_price || ', asignado: $' || v_total || ')'
    );
  END IF;

  -- Reemplazar distribución
  DELETE FROM public.package_member_distribution WHERE package_id = p_package_id;

  FOR rec IN SELECT * FROM jsonb_array_elements(p_rows)
  LOOP
    IF (rec->>'amount')::NUMERIC > 0 THEN
      INSERT INTO public.package_member_distribution (package_id, user_id, amount)
      VALUES (
        p_package_id,
        (rec->>'user_id')::UUID,
        (rec->>'amount')::NUMERIC
      );
    END IF;
  END LOOP;

  RETURN json_build_object('success', true, 'total', v_total);
END;
$$;

GRANT EXECUTE ON FUNCTION public.upsert_package_distribution(UUID, JSONB) TO authenticated;

-- ── 5. Verificación ───────────────────────────────────────────────────────────
SELECT 'package_member_distribution + validación + RLS creados ✅' AS status;
