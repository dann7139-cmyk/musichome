-- ============================================================
-- sql/246_talent_profile_columns.sql
--
-- Agrega columnas de perfil profesional a job_board_profiles:
--   video_url, city, musical_styles, social_instagram, social_tiktok
--
-- Actualiza search_talents RPC para devolver las nuevas columnas.
-- Backward compatible: todas las columnas son NULLABLE.
--
-- PREREQUISITO DE STORAGE:
--   Antes de ejecutar este script, crear el bucket 'talent-videos'
--   en Supabase Dashboard → Storage → New Bucket:
--     Name: talent-videos
--     Public: ON  ← importante para URLs públicas
--
-- Orden de ejecución: después de sql/245.
-- No toca: pagos, timers, Stripe, realtime, reservas.
-- ============================================================

-- ── 1. Nuevas columnas en job_board_profiles ─────────────────────────────────

ALTER TABLE public.job_board_profiles
  ADD COLUMN IF NOT EXISTS video_url        TEXT    DEFAULT NULL,
  ADD COLUMN IF NOT EXISTS city             TEXT    DEFAULT NULL,
  ADD COLUMN IF NOT EXISTS musical_styles   TEXT[]  DEFAULT NULL,
  ADD COLUMN IF NOT EXISTS social_instagram TEXT    DEFAULT NULL,
  ADD COLUMN IF NOT EXISTS social_tiktok    TEXT    DEFAULT NULL;

-- ── 2. Políticas RLS para el bucket talent-videos ────────────────────────────
-- Solo se crean si el bucket ya existe (idempotente).

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM storage.buckets WHERE id = 'talent-videos') THEN
    RAISE WARNING '[246] El bucket "talent-videos" NO existe. Créalo en el dashboard (Storage → New Bucket → Public: ON) y luego re-ejecuta este bloque.';
  ELSE
    -- Subida: solo el dueño puede subir a su propia carpeta {uid}/...
    IF NOT EXISTS (
      SELECT 1 FROM pg_policies
      WHERE policyname = 'talent-videos upload'
        AND tablename  = 'objects'
        AND schemaname = 'storage'
    ) THEN
      EXECUTE $p$
        CREATE POLICY "talent-videos upload" ON storage.objects
        FOR INSERT TO authenticated
        WITH CHECK (
          bucket_id = 'talent-videos'
          AND (storage.foldername(name))[1] = auth.uid()::text
        );
      $p$;
      RAISE NOTICE '[246] Política upload creada ✅';
    END IF;

    -- Actualización: solo el dueño
    IF NOT EXISTS (
      SELECT 1 FROM pg_policies
      WHERE policyname = 'talent-videos update'
        AND tablename  = 'objects'
        AND schemaname = 'storage'
    ) THEN
      EXECUTE $p$
        CREATE POLICY "talent-videos update" ON storage.objects
        FOR UPDATE TO authenticated
        USING (
          bucket_id = 'talent-videos'
          AND (storage.foldername(name))[1] = auth.uid()::text
        );
      $p$;
      RAISE NOTICE '[246] Política update creada ✅';
    END IF;

    -- Eliminación: solo el dueño
    IF NOT EXISTS (
      SELECT 1 FROM pg_policies
      WHERE policyname = 'talent-videos delete'
        AND tablename  = 'objects'
        AND schemaname = 'storage'
    ) THEN
      EXECUTE $p$
        CREATE POLICY "talent-videos delete" ON storage.objects
        FOR DELETE TO authenticated
        USING (
          bucket_id = 'talent-videos'
          AND (storage.foldername(name))[1] = auth.uid()::text
        );
      $p$;
      RAISE NOTICE '[246] Política delete creada ✅';
    END IF;

    RAISE NOTICE '[246] Bucket talent-videos y políticas RLS configurados ✅';
  END IF;
END;
$$;

-- ── 3. Actualizar search_talents — agrega nuevas columnas al RETURNS TABLE ───
-- PostgreSQL no permite CREATE OR REPLACE cuando cambia el RETURNS TABLE.
-- DROP + CREATE garantiza que la firma anterior queda reemplazada limpiamente.
-- El GRANT se re-aplica después del CREATE.

DROP FUNCTION IF EXISTS public.search_talents(TEXT, TEXT, DOUBLE PRECISION, DOUBLE PRECISION);

CREATE FUNCTION public.search_talents(
  p_role         TEXT             DEFAULT NULL,
  p_availability TEXT             DEFAULT NULL,
  p_lat          DOUBLE PRECISION DEFAULT NULL,
  p_lng          DOUBLE PRECISION DEFAULT NULL
)
RETURNS TABLE (
  id                  UUID,
  user_id             UUID,
  full_name           TEXT,
  avatar_url          TEXT,
  instrument_or_role  TEXT,
  bio                 TEXT,
  experience_years    INTEGER,
  rating              NUMERIC,
  total_jobs          INTEGER,
  availability_status TEXT,
  distance_km         NUMERIC,
  created_at          TIMESTAMP WITH TIME ZONE,
  video_url           TEXT,
  city                TEXT,
  musical_styles      TEXT[],
  social_instagram    TEXT,
  social_tiktok       TEXT
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    jbp.id,
    jbp.user_id,
    p.full_name,
    p.avatar_url,
    jbp.instrument_or_role,
    jbp.bio,
    jbp.experience_years,
    jbp.rating::NUMERIC,
    jbp.total_jobs,
    jbp.availability_status,
    CASE
      WHEN jbp.lat IS NOT NULL AND p_lat IS NOT NULL
        THEN ROUND(haversine_km(jbp.lat, jbp.lng, p_lat, p_lng)::NUMERIC, 1)
      ELSE NULL
    END AS distance_km,
    jbp.created_at,
    jbp.video_url,
    jbp.city,
    jbp.musical_styles,
    jbp.social_instagram,
    jbp.social_tiktok
  FROM public.job_board_profiles jbp
  JOIN public.profiles p ON p.id = jbp.user_id
  WHERE jbp.is_visible = TRUE
    -- Excluir talentos que ya son integrantes permanentes de un grupo
    AND NOT EXISTS (
      SELECT 1
      FROM public.job_invitations jinv
      WHERE jinv.invited_user_id = jbp.user_id
        AND jinv.status          = 'accepted'
        AND jinv.event_id        IS NULL
    )
    AND (p_role         IS NULL OR jbp.instrument_or_role ILIKE '%' || p_role || '%')
    AND (p_availability IS NULL OR jbp.availability_status = p_availability)
  ORDER BY
    CASE WHEN jbp.lat IS NOT NULL AND p_lat IS NOT NULL THEN 0 ELSE 1 END ASC,
    CASE
      WHEN jbp.lat IS NOT NULL AND p_lat IS NOT NULL
        THEN haversine_km(jbp.lat, jbp.lng, p_lat, p_lng)
      ELSE 99999.0
    END ASC,
    jbp.availability_status ASC,
    jbp.rating              DESC,
    jbp.total_jobs          DESC;
$$;

GRANT EXECUTE ON FUNCTION public.search_talents(TEXT, TEXT, DOUBLE PRECISION, DOUBLE PRECISION)
  TO authenticated, service_role;

-- ── Verificación ──────────────────────────────────────────────────────────────
DO $$
DECLARE
  v_cols TEXT;
BEGIN
  SELECT string_agg(column_name, ', ' ORDER BY ordinal_position)
  INTO   v_cols
  FROM   information_schema.columns
  WHERE  table_schema = 'public'
    AND  table_name   = 'job_board_profiles'
    AND  column_name  IN ('video_url', 'city', 'musical_styles', 'social_instagram', 'social_tiktok');

  IF v_cols IS NOT NULL THEN
    RAISE NOTICE '[246] Nuevas columnas en job_board_profiles: %', v_cols;
  ELSE
    RAISE WARNING '[246] ALERTA: columnas nuevas no encontradas';
  END IF;
END;
$$;

SELECT '246_talent_profile_columns.sql: video_url, city, musical_styles, social links agregados ✅' AS status;
