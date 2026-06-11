-- ============================================================
-- sql/270_client_live_location.sql
--
-- GPS en tiempo real para clientes:
--   - Tabla client_locations para actualizaciones desde la app.
--   - RPC update_my_client_location — cliente llama al abrir app.
--   - RPC set_client_offline — cliente llama al cerrar app.
--   - get_client_locations — admin lee todas con datos de perfil.
--   - RLS: cada cliente solo puede escribir su propia fila.
-- ============================================================

-- ── 1. Tabla de ubicaciones en vivo ──────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.client_locations (
  user_id    UUID PRIMARY KEY REFERENCES public.profiles(id) ON DELETE CASCADE,
  lat        DOUBLE PRECISION NOT NULL,
  lng        DOUBLE PRECISION NOT NULL,
  city       TEXT,
  state      TEXT,
  status     TEXT NOT NULL DEFAULT 'active'
               CHECK (status IN ('active', 'offline')),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_client_locations_updated
  ON public.client_locations (updated_at DESC);

-- ── 2. RLS ────────────────────────────────────────────────────────────────────

ALTER TABLE public.client_locations ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "client_own_location" ON public.client_locations;
CREATE POLICY "client_own_location" ON public.client_locations
  FOR ALL
  USING  (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "admin_read_client_locations" ON public.client_locations;
CREATE POLICY "admin_read_client_locations" ON public.client_locations
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.profiles
      WHERE id = auth.uid() AND role = 'admin'
    )
  );

-- ── 3. RPC: cliente actualiza su ubicación ────────────────────────────────────

CREATE OR REPLACE FUNCTION public.update_my_client_location(
  p_lat   DOUBLE PRECISION,
  p_lng   DOUBLE PRECISION,
  p_city  TEXT DEFAULT NULL,
  p_state TEXT DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id = auth.uid() AND role IN ('client', 'user')
  ) THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  INSERT INTO public.client_locations (user_id, lat, lng, city, state, status, updated_at)
  VALUES (auth.uid(), p_lat, p_lng, p_city, p_state, 'active', NOW())
  ON CONFLICT (user_id) DO UPDATE
    SET lat        = EXCLUDED.lat,
        lng        = EXCLUDED.lng,
        city       = COALESCE(EXCLUDED.city,  client_locations.city),
        state      = COALESCE(EXCLUDED.state, client_locations.state),
        status     = 'active',
        updated_at = NOW();
END;
$$;

GRANT EXECUTE ON FUNCTION public.update_my_client_location(DOUBLE PRECISION, DOUBLE PRECISION, TEXT, TEXT)
  TO authenticated;

-- ── 4. RPC: cliente marca offline ─────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.set_client_offline()
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE public.client_locations
    SET status = 'offline', updated_at = NOW()
  WHERE user_id = auth.uid();
END;
$$;

GRANT EXECUTE ON FUNCTION public.set_client_offline()
  TO authenticated;

-- ── 5. Vista admin: clientes con ubicación + perfil ───────────────────────────

CREATE OR REPLACE FUNCTION public.get_client_locations()
RETURNS TABLE (
  user_id    UUID,
  full_name  TEXT,
  avatar_url TEXT,
  city       TEXT,
  state      TEXT,
  status     TEXT,
  updated_at TIMESTAMPTZ
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    cl.user_id,
    p.full_name,
    p.avatar_url,
    cl.city,
    cl.state,
    cl.status,
    cl.updated_at
  FROM public.client_locations cl
  JOIN public.profiles p ON p.id = cl.user_id
  WHERE cl.updated_at > NOW() - INTERVAL '24 hours'
  ORDER BY
    CASE cl.status WHEN 'active' THEN 0 ELSE 1 END ASC,
    cl.updated_at DESC;
$$;

GRANT EXECUTE ON FUNCTION public.get_client_locations()
  TO authenticated, service_role;

-- ── 6. Realtime ───────────────────────────────────────────────────────────────

ALTER TABLE public.client_locations REPLICA IDENTITY FULL;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND tablename = 'client_locations'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.client_locations;
  END IF;
END;
$$;

DO $$
BEGIN
  RAISE NOTICE '[270] client_locations tabla creada ✅';
  RAISE NOTICE '[270] update_my_client_location RPC creado ✅';
  RAISE NOTICE '[270] get_client_locations RPC creado ✅';
  RAISE NOTICE '[270] Realtime habilitado en client_locations ✅';
END;
$$;

SELECT '270_client_live_location.sql: GPS en tiempo real para clientes ✅' AS status;
