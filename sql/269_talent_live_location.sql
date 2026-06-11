-- ============================================================
-- sql/269_talent_live_location.sql
--
-- GPS en tiempo real para talentos:
--   - Tabla talent_locations (separada de job_board_profiles)
--     para actualizaciones frecuentes sin tocar el perfil.
--   - RPC update_my_talent_location — talento llama desde app
--     al abrir el dashboard / periódicamente.
--   - RLS: cada talento solo puede escribir su propia fila.
--   - get_talent_locations — admin lee todas las ubicaciones
--     con datos del perfil (solo service_role / admin).
-- ============================================================

-- ── 1. Tabla de ubicaciones en vivo ──────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.talent_locations (
  user_id    UUID PRIMARY KEY REFERENCES public.profiles(id) ON DELETE CASCADE,
  lat        DOUBLE PRECISION NOT NULL,
  lng        DOUBLE PRECISION NOT NULL,
  city       TEXT,
  state      TEXT,
  status     TEXT NOT NULL DEFAULT 'active'
               CHECK (status IN ('active', 'offline')),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_talent_locations_updated
  ON public.talent_locations (updated_at DESC);

-- ── 2. RLS ────────────────────────────────────────────────────────────────────

ALTER TABLE public.talent_locations ENABLE ROW LEVEL SECURITY;

-- El talento solo ve/edita su propia fila
DROP POLICY IF EXISTS "talent_own_location" ON public.talent_locations;
CREATE POLICY "talent_own_location" ON public.talent_locations
  FOR ALL
  USING  (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);

-- Admin puede leer todo
DROP POLICY IF EXISTS "admin_read_talent_locations" ON public.talent_locations;
CREATE POLICY "admin_read_talent_locations" ON public.talent_locations
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.profiles
      WHERE id = auth.uid() AND role = 'admin'
    )
  );

-- ── 3. RPC: talento actualiza su ubicación desde la app ──────────────────────

CREATE OR REPLACE FUNCTION public.update_my_talent_location(
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
  -- Solo talentos (o job_board profiles) pueden llamar esto
  IF NOT EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id = auth.uid()
      AND role IN ('talent', 'artist', 'musician')
  ) AND NOT EXISTS (
    SELECT 1 FROM public.job_board_profiles
    WHERE user_id = auth.uid() AND is_visible = TRUE
  ) THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  INSERT INTO public.talent_locations (user_id, lat, lng, city, state, status, updated_at)
  VALUES (auth.uid(), p_lat, p_lng, p_city, p_state, 'active', NOW())
  ON CONFLICT (user_id) DO UPDATE
    SET lat        = EXCLUDED.lat,
        lng        = EXCLUDED.lng,
        city       = COALESCE(EXCLUDED.city, talent_locations.city),
        state      = COALESCE(EXCLUDED.state, talent_locations.state),
        status     = 'active',
        updated_at = NOW();

  -- También sincroniza job_board_profiles si tiene perfil ahí
  UPDATE public.job_board_profiles
    SET lat = p_lat, lng = p_lng
  WHERE user_id = auth.uid();
END;
$$;

GRANT EXECUTE ON FUNCTION public.update_my_talent_location(DOUBLE PRECISION, DOUBLE PRECISION, TEXT, TEXT)
  TO authenticated;

-- ── 4. RPC: talento marca offline al cerrar la app ────────────────────────────

CREATE OR REPLACE FUNCTION public.set_talent_offline()
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE public.talent_locations
    SET status = 'offline', updated_at = NOW()
  WHERE user_id = auth.uid();
END;
$$;

GRANT EXECUTE ON FUNCTION public.set_talent_offline()
  TO authenticated;

-- ── 5. Vista admin: talentos con ubicación + perfil ───────────────────────────

CREATE OR REPLACE FUNCTION public.get_talent_locations()
RETURNS TABLE (
  user_id      UUID,
  full_name    TEXT,
  avatar_url   TEXT,
  instrument   TEXT,
  availability TEXT,
  lat          DOUBLE PRECISION,
  lng          DOUBLE PRECISION,
  city         TEXT,
  state        TEXT,
  status       TEXT,
  updated_at   TIMESTAMPTZ
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    tl.user_id,
    p.full_name,
    p.avatar_url,
    COALESCE(jbp.instrument_or_role, '—') AS instrument,
    COALESCE(jbp.availability_status, 'unknown') AS availability,
    tl.lat,
    tl.lng,
    tl.city,
    tl.state,
    tl.status,
    tl.updated_at
  FROM public.talent_locations tl
  JOIN public.profiles p ON p.id = tl.user_id
  LEFT JOIN public.job_board_profiles jbp ON jbp.user_id = tl.user_id
  WHERE tl.updated_at > NOW() - INTERVAL '24 hours'  -- solo los activos en últimas 24h
  ORDER BY
    CASE tl.status WHEN 'active' THEN 0 ELSE 1 END ASC,
    tl.updated_at DESC;
$$;

GRANT EXECUTE ON FUNCTION public.get_talent_locations()
  TO authenticated, service_role;

-- ── 6. Realtime en talent_locations ───────────────────────────────────────────

ALTER TABLE public.talent_locations REPLICA IDENTITY FULL;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND tablename = 'talent_locations'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.talent_locations;
  END IF;
END;
$$;

-- ── Verificación ──────────────────────────────────────────────────────────────
DO $$
BEGIN
  RAISE NOTICE '[269] talent_locations tabla creada ✅';
  RAISE NOTICE '[269] update_my_talent_location RPC creado ✅';
  RAISE NOTICE '[269] get_talent_locations RPC creado ✅';
  RAISE NOTICE '[269] Realtime habilitado en talent_locations ✅';
END;
$$;

SELECT '269_talent_live_location.sql: GPS en tiempo real para talentos ✅' AS status;
