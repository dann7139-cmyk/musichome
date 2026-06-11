-- ════════════════════════════════════════════════════════════════════
-- 51_quotes_upgrade.sql
-- Agrega columnas faltantes a la tabla quotes:
--   • num_personas       (cuántas personas asistirán)
--   • num_integrantes    (cuántos músicos en el grupo)
--   • price_per_hour     (precio/hora definido por el grupo)
--   • commission_pct     (% calculado dinámicamente)
--   • overtime_1h_price  (precio 1 hora extra — obligatorio)
--   • overtime_2h_price  (precio 2 horas extra — obligatorio)
--   • overtime_3h_price  (precio 3 horas extra — obligatorio)
--   • member_distribution (JSON: distribución entre integrantes)
--   • quote_id en reservations (referencia a la cotización)
-- Cambia duración mínima de 1 a 3 horas.
-- ════════════════════════════════════════════════════════════════════

-- ── 1. Campos del cliente ─────────────────────────────────────────────
ALTER TABLE public.quotes
  ADD COLUMN IF NOT EXISTS num_personas    INTEGER CHECK (num_personas > 0);

-- ── 2. Campos de respuesta del grupo ─────────────────────────────────
ALTER TABLE public.quotes
  ADD COLUMN IF NOT EXISTS num_integrantes    INTEGER CHECK (num_integrantes > 0),
  ADD COLUMN IF NOT EXISTS price_per_hour     NUMERIC(10,2),
  ADD COLUMN IF NOT EXISTS commission_pct     NUMERIC(6,4),
  ADD COLUMN IF NOT EXISTS overtime_1h_price  NUMERIC(10,2),
  ADD COLUMN IF NOT EXISTS overtime_2h_price  NUMERIC(10,2),
  ADD COLUMN IF NOT EXISTS overtime_3h_price  NUMERIC(10,2),
  ADD COLUMN IF NOT EXISTS member_distribution JSONB DEFAULT '[]'::jsonb;

-- ── 3. Mínimo 3 horas ────────────────────────────────────────────────
-- Eliminar constraint viejo y crear el nuevo
ALTER TABLE public.quotes DROP CONSTRAINT IF EXISTS quotes_duration_hours_check;
ALTER TABLE public.quotes ADD CONSTRAINT quotes_duration_hours_check
  CHECK (duration_hours BETWEEN 3 AND 12);

-- ── 4. Referencia de cotización en reservations ───────────────────────
ALTER TABLE public.reservations
  ADD COLUMN IF NOT EXISTS quote_id UUID REFERENCES public.quotes(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_reservations_quote ON public.reservations(quote_id)
  WHERE quote_id IS NOT NULL;

-- ── 5. Vista para cálculo dinámico de comisión ────────────────────────
CREATE OR REPLACE VIEW public.quotes_summary AS
SELECT
  q.*,
  -- Comisión en porcentaje
  CASE WHEN COALESCE(q.total_amount, 0) > 0
    THEN ROUND((q.commission_amount / q.total_amount) * 100, 2)
    ELSE 0
  END AS commission_pct_display,
  -- Total calculado desde price_per_hour
  CASE WHEN q.price_per_hour IS NOT NULL AND q.duration_hours IS NOT NULL
    THEN (q.price_per_hour * q.duration_hours) + COALESCE(q.travel_cost, 0)
    ELSE COALESCE(q.total_amount, 0)
  END AS total_preview
FROM public.quotes q;

SELECT '51_quotes_upgrade: OK ✅' AS status;
