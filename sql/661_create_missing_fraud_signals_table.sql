-- ============================================================================
-- sql/661_create_missing_fraud_signals_table.sql
--
-- fraud_signals nunca se había creado, aunque guard_quote_spam() (trigger
-- antifraude de cotizaciones, activo desde hace tiempo) ya intenta escribir
-- ahí al detectar 15+ cotizaciones en 24h de un mismo cliente. Nadie lo
-- había notado porque ningún cliente real había llegado a ese límite —
-- se descubrió corriendo la suite de regresión sql/602 (que sí genera más
-- de 15 cotizaciones para la misma cuenta de prueba). Sin esta tabla, un
-- cliente real que llegue a ese límite vería un error crudo de Postgres
-- ("relation fraud_signals does not exist") en vez del mensaje esperado
-- "Alcanzaste el límite de cotizaciones por hoy. Intenta de nuevo mañana."
-- ============================================================================

CREATE TABLE public.fraud_signals (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid REFERENCES public.profiles(id) ON DELETE CASCADE,
  signal_type text NOT NULL,
  severity text NOT NULL,
  description text,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.fraud_signals ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS fraud_signals_admin_select ON public.fraud_signals;
CREATE POLICY fraud_signals_admin_select ON public.fraud_signals
FOR SELECT USING (
  EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = auth.uid() AND p.role = 'admin')
);
