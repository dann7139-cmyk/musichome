-- ════════════════════════════════════════════════════════════════════
-- 52_group_locations.sql
-- Tabla de ubicación en tiempo real de grupos (para mapa Admin).
-- El DashboardScreen del grupo actualiza esta tabla al cargar.
-- Realtime habilitado para el mapa en vivo del admin.
-- ════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS public.group_locations (
  group_id    UUID PRIMARY KEY REFERENCES public.groups(id) ON DELETE CASCADE,
  lat         DOUBLE PRECISION NOT NULL,
  lng         DOUBLE PRECISION NOT NULL,
  country     TEXT,
  city        TEXT,
  status      TEXT NOT NULL DEFAULT 'offline'
              CHECK (status IN ('offline', 'active', 'in_event')),
  last_seen   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Índices para filtrar por estado y país
CREATE INDEX IF NOT EXISTS idx_group_locations_status  ON public.group_locations(status);
CREATE INDEX IF NOT EXISTS idx_group_locations_country ON public.group_locations(country);
CREATE INDEX IF NOT EXISTS idx_group_locations_seen    ON public.group_locations(last_seen DESC);

-- RLS
ALTER TABLE public.group_locations ENABLE ROW LEVEL SECURITY;

-- El grupo actualiza solo su propia ubicación
DROP POLICY IF EXISTS "group_upsert_own_location" ON public.group_locations;
CREATE POLICY "group_upsert_own_location" ON public.group_locations
  FOR ALL
  USING (
    EXISTS (SELECT 1 FROM public.groups WHERE id = group_id AND owner_id = auth.uid())
  )
  WITH CHECK (
    EXISTS (SELECT 1 FROM public.groups WHERE id = group_id AND owner_id = auth.uid())
  );

-- Admin ve todo
DROP POLICY IF EXISTS "admin_read_all_locations" ON public.group_locations;
CREATE POLICY "admin_read_all_locations" ON public.group_locations
  FOR SELECT
  USING (
    EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin')
  );

-- Realtime para el mapa en vivo
ALTER TABLE public.group_locations REPLICA IDENTITY FULL;
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime'
      AND schemaname = 'public'
      AND tablename = 'group_locations'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.group_locations;
  END IF;
END $$;

SELECT '52_group_locations: OK ✅' AS status;
