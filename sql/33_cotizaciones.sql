-- ============================================================
-- DARICEFY - 33_cotizaciones.sql
-- Sistema de Cotización Inteligente por Distancia
-- Ejecutar en Supabase SQL Editor
-- ============================================================

-- ─────────────────────────────────────────────────────────────
-- 1. Tabla principal de cotizaciones
-- ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.quotes (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  group_id        UUID        NOT NULL REFERENCES public.groups(id)   ON DELETE CASCADE,
  client_id       UUID        NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,

  -- ── Datos del evento (capturados en el formulario) ────────
  event_type      TEXT        NOT NULL CHECK (event_type IN (
                                'fiesta_privada','boda','cumpleanos',
                                'graduacion','empresarial','otro')),
  event_address   TEXT        NOT NULL,
  event_municipio TEXT        NOT NULL,
  event_estado    TEXT        NOT NULL,
  event_date      DATE        NOT NULL,
  event_time      TEXT        NOT NULL,  -- formato 'HH:MM'
  break_type      TEXT        NOT NULL DEFAULT 'A'
                                CHECK (break_type IN ('A','B','C','D')),
  duration_hours  INTEGER     NOT NULL CHECK (duration_hours BETWEEN 1 AND 8),
  venue_covered   TEXT        NOT NULL CHECK (venue_covered IN ('si','no','no_se')),
  venue_size      TEXT        NOT NULL CHECK (venue_size IN (
                                'patio_pequeno','salon_mediano',
                                'jardin_grande','escenario_profesional')),
  needs_sound     TEXT        NOT NULL CHECK (needs_sound IN ('si','no','ya_tengo')),
  comments        TEXT,

  -- ── Estado del flujo ──────────────────────────────────────
  -- pending  → cliente envió, grupo no ha respondido
  -- quoted   → grupo puso precio, cliente decide
  -- accepted → cliente aceptó la cotización
  -- rejected → cliente rechazó o grupo declinó
  -- expired  → pasó la fecha sin respuesta
  status          TEXT        NOT NULL DEFAULT 'pending'
                                CHECK (status IN ('pending','quoted','accepted','rejected','expired')),

  -- ── Respuesta del grupo ───────────────────────────────────
  base_price      NUMERIC(10,2),
  travel_cost     NUMERIC(10,2) NOT NULL DEFAULT 0,
  extra_hour_price NUMERIC(10,2),
  commission_amount NUMERIC(10,2),  -- 10% sobre (base_price + travel_cost) calculado automáticamente
  total_amount    NUMERIC(10,2),    -- base_price + travel_cost (antes de comisión)
  group_earnings  NUMERIC(10,2),    -- total_amount * 0.90
  group_notes     TEXT,

  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Índices
CREATE INDEX IF NOT EXISTS idx_quotes_group   ON public.quotes(group_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_quotes_client  ON public.quotes(client_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_quotes_status  ON public.quotes(status);

-- ─────────────────────────────────────────────────────────────
-- 2. Trigger: actualizar updated_at automáticamente
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.touch_quotes_updated_at()
RETURNS TRIGGER AS $func$
BEGIN
  NEW.updated_at := NOW();
  RETURN NEW;
END;
$func$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS set_quotes_updated_at ON public.quotes;
CREATE TRIGGER set_quotes_updated_at
  BEFORE UPDATE ON public.quotes
  FOR EACH ROW
  EXECUTE FUNCTION public.touch_quotes_updated_at();

-- ─────────────────────────────────────────────────────────────
-- 3. RLS
-- ─────────────────────────────────────────────────────────────
ALTER TABLE public.quotes ENABLE ROW LEVEL SECURITY;

-- Admin: acceso total
CREATE POLICY "admin_all_quotes" ON public.quotes
  FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin'));

-- Grupo: ve y actualiza cotizaciones dirigidas a su grupo
CREATE POLICY "group_own_quotes" ON public.quotes
  FOR ALL TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.groups g
      WHERE g.id = quotes.group_id AND g.owner_id = auth.uid()
    )
  );

-- Cliente: ve y crea sus propias cotizaciones
CREATE POLICY "client_own_quotes" ON public.quotes
  FOR ALL TO authenticated
  USING (client_id = auth.uid());

-- ─────────────────────────────────────────────────────────────
-- 4. Activar Realtime
-- ─────────────────────────────────────────────────────────────
ALTER TABLE public.quotes REPLICA IDENTITY FULL;
ALTER PUBLICATION supabase_realtime ADD TABLE public.quotes;

SELECT 'Sistema de cotizaciones configurado correctamente ✅' AS status;
