-- ════════════════════════════════════════════════════════════════════
-- sql/357_disable_orphan_groups.sql
--
-- Desactiva grupos sin dueño (owner_id IS NULL).
-- Origen: seed data insertado manualmente en Supabase Dashboard
-- durante pruebas iniciales. Nunca tuvieron profile asociado o
-- su auth user fue eliminado sin CASCADE a groups.
--
-- Impacto: 4 grupos fantasma detectados en auditoría (Fase 1).
-- Se desactivan en lugar de borrar para conservar historial.
-- ════════════════════════════════════════════════════════════════════

UPDATE public.groups
SET    is_active = FALSE,
       updated_at = NOW()
WHERE  owner_id IS NULL;

-- ── Verificación ─────────────────────────────────────────────────────────────
-- Esperado: 0

SELECT
  COUNT(*) FILTER (WHERE owner_id IS NULL AND is_active = TRUE)  AS grupos_activos_sin_dueno,
  COUNT(*) FILTER (WHERE owner_id IS NULL AND is_active = FALSE) AS grupos_inactivos_sin_dueno,
  COUNT(*) FILTER (WHERE owner_id IS NULL)                       AS total_sin_dueno
FROM public.groups;
