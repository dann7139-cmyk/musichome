-- ============================================================
-- sql/330_fix_sponsored_groups_upsert.sql
--
-- FIX de admin_activate_sponsored ("+Gratis → Destacado"):
-- la tabla sponsored_groups (sql/117) no coincide con lo que el
-- RPC de sql/187 asume. Tres defectos encadenados:
--
--   1. No existe la columna updated_at
--      → "column updated_at of relation sponsored_groups does not exist"
--   2. No hay UNIQUE en group_id (solo índice normal)
--      → el ON CONFLICT (group_id) fallaría después
--   3. ends_at es NOT NULL
--      → la duración "Sin límite" (NULL) violaría la constraint
--
-- Solución:
--   • Agregar updated_at
--   • Deduplicar y crear UNIQUE INDEX en group_id
--   • Redefinir el RPC: "sin límite" = NOW() + 100 años
--     (evita NULLs que romperían los rankings que filtran ends_at > NOW())
-- ============================================================

-- ── 1. Columna updated_at ─────────────────────────────────────────────────────

ALTER TABLE public.sponsored_groups
  ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW();

-- ── 2. Dedupe + UNIQUE en group_id (requerido por ON CONFLICT) ────────────────
-- Si un grupo tiene varias filas, se conserva la más reciente.

DELETE FROM public.sponsored_groups a
USING public.sponsored_groups b
WHERE a.group_id = b.group_id
  AND a.id <> b.id
  AND (a.created_at < b.created_at
       OR (a.created_at = b.created_at AND a.id < b.id));

CREATE UNIQUE INDEX IF NOT EXISTS uq_sponsored_groups_group
  ON public.sponsored_groups (group_id);

-- ── 3. RPC admin_activate_sponsored — compatible con el esquema real ──────────

CREATE OR REPLACE FUNCTION public.admin_activate_sponsored(
  p_group_id UUID,
  p_days     INT DEFAULT 7
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_ends_at TIMESTAMPTZ;
BEGIN
  IF NOT (
    (auth.jwt()->>'role') = 'service_role'
    OR EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin')
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;

  -- ends_at es NOT NULL en sponsored_groups: "sin límite" = +100 años.
  v_ends_at := CASE WHEN p_days > 0
                 THEN NOW() + (p_days || ' days')::INTERVAL
                 ELSE NOW() + INTERVAL '100 years'
               END;

  INSERT INTO public.sponsored_groups (group_id, advertiser_id, starts_at, ends_at, is_active)
  VALUES (p_group_id, auth.uid(), NOW(), v_ends_at, TRUE)
  ON CONFLICT (group_id) DO UPDATE
    SET is_active  = TRUE,
        starts_at  = NOW(),
        ends_at    = EXCLUDED.ends_at,
        updated_at = NOW();

  RETURN jsonb_build_object('ok', true, 'type', 'sponsored', 'ends_at', v_ends_at);
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_activate_sponsored(UUID, INT) TO authenticated;

-- ── Verificación ──────────────────────────────────────────────────────────────
DO $$
BEGIN
  RAISE NOTICE '[330] sponsored_groups: updated_at + UNIQUE(group_id) ✅';
  RAISE NOTICE '[330] admin_activate_sponsored: upsert compatible con esquema real ✅';
END;
$$;

SELECT '330_fix_sponsored_groups_upsert.sql ejecutado ✅' AS status;
