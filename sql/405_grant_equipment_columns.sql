-- ═══════════════════════════════════════════════════════════════════════════
-- sql/405_grant_equipment_columns.sql
--
-- Otorga permisos UPDATE/INSERT a rol "authenticated" sobre las columnas
-- de equipo añadidas en 403 y 404.
--
-- Causa del error: ALTER TABLE ADD COLUMN no hereda grants existentes.
-- Los grants de columna pre-existentes en groups/quotes no se extienden
-- automáticamente a las columnas nuevas → 42501 permission denied.
--
-- LECCIÓN: siempre incluir GRANT en el mismo migration que ADD COLUMN.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── groups: 12 columnas nuevas (sql/403) ─────────────────────────────────────
GRANT UPDATE (
  has_sound,
  sound_capacity_max,
  has_lighting,
  lighting_level,
  has_stage,
  stage_sizes_available,
  has_led_screen,
  led_sizes_available,
  power_amps,
  needs_parking,
  setup_minutes,
  includes_text
) ON public.groups TO authenticated;

-- ── quotes: 3 columnas nuevas (sql/404) ──────────────────────────────────────
GRANT UPDATE (needs_lighting, needs_stage, needs_led) ON public.quotes TO authenticated;
GRANT INSERT (needs_lighting, needs_stage, needs_led) ON public.quotes TO authenticated;

SELECT '405_grant_equipment_columns.sql ✅ — permisos UPDATE/INSERT sobre columnas de equipo' AS status;
