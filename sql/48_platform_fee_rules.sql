-- ════════════════════════════════════════════════════════════════════
-- 48_platform_fee_rules.sql
-- Tabla de reglas de comisión dinámica por tramos de precio.
-- La app puede leer estas reglas para calcular la comisión exacta.
-- Por ahora: comisión fija $200/hora (definida en trigger SQL 34).
-- Esta tabla permite configurar reglas futuras sin deploy.
-- ════════════════════════════════════════════════════════════════════

-- ── 1. Tabla ─────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.platform_fee_rules (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  name            TEXT        NOT NULL,           -- ej. "Comisión estándar"
  fee_type        TEXT        NOT NULL DEFAULT 'per_hour'
                              CHECK (fee_type IN ('per_hour', 'percentage', 'fixed')),
  amount          NUMERIC(12,2) NOT NULL,          -- valor de la comisión
  min_price       NUMERIC(12,2) DEFAULT 0,         -- precio mínimo de reserva para aplicar
  max_price       NUMERIC(12,2),                   -- precio máximo (NULL = sin límite)
  is_active       BOOLEAN     NOT NULL DEFAULT TRUE,
  applies_to      TEXT        NOT NULL DEFAULT 'all'
                              CHECK (applies_to IN ('all', 'group', 'talent')),
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ── 2. RLS ────────────────────────────────────────────────────────────
ALTER TABLE public.platform_fee_rules ENABLE ROW LEVEL SECURITY;

-- Todos los usuarios autenticados pueden leer las reglas activas
CREATE POLICY "authenticated_read_fee_rules" ON public.platform_fee_rules
  FOR SELECT
  USING (auth.role() = 'authenticated' AND is_active = TRUE);

-- Solo admins pueden modificar
CREATE POLICY "admin_manage_fee_rules" ON public.platform_fee_rules
  FOR ALL
  USING (EXISTS (
    SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin'
  ));

-- ── 3. Regla inicial: $200 MXN por hora ──────────────────────────────
INSERT INTO public.platform_fee_rules (name, fee_type, amount, applies_to)
VALUES ('Comisión estándar $200/hora', 'per_hour', 200, 'all')
ON CONFLICT DO NOTHING;

-- ── 4. Trigger: updated_at automático ────────────────────────────────
CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_fee_rules_updated_at ON public.platform_fee_rules;
CREATE TRIGGER trg_fee_rules_updated_at
  BEFORE UPDATE ON public.platform_fee_rules
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

SELECT '48_platform_fee_rules: OK ✅' AS status;
