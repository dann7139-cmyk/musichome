-- ═══════════════════════════════════════════════════════════════════════════
-- sql/403_group_equipment_columns.sql
--
-- Agrega 12 columnas de equipo y logística a la tabla public.groups.
-- get_my_group() retorna SETOF public.groups → columnas nuevas disponibles
-- automáticamente sin modificar la RPC.
--
-- Idempotente: IF NOT EXISTS en ADD COLUMN; DO $$ EXCEPTION en constraints.
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

-- ── 1. Columnas ───────────────────────────────────────────────────────────────

ALTER TABLE public.groups
  ADD COLUMN IF NOT EXISTS has_sound             BOOLEAN  NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS sound_capacity_max    INTEGER           DEFAULT NULL,
  ADD COLUMN IF NOT EXISTS has_lighting          BOOLEAN  NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS lighting_level        TEXT              DEFAULT NULL,
  ADD COLUMN IF NOT EXISTS has_stage             BOOLEAN  NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS stage_sizes_available TEXT[]   NOT NULL DEFAULT '{}',
  ADD COLUMN IF NOT EXISTS has_led_screen        BOOLEAN  NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS led_sizes_available   TEXT[]   NOT NULL DEFAULT '{}',
  ADD COLUMN IF NOT EXISTS power_amps            INTEGER           DEFAULT NULL,
  ADD COLUMN IF NOT EXISTS needs_parking         BOOLEAN  NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS setup_minutes         INTEGER           DEFAULT NULL,
  ADD COLUMN IF NOT EXISTS includes_text         TEXT              DEFAULT NULL;

-- ── 2. Constraints de validación (idempotentes con DO $$) ─────────────────────

DO $$ BEGIN
  ALTER TABLE public.groups
    ADD CONSTRAINT chk_groups_lighting_level
    CHECK (lighting_level IS NULL OR lighting_level IN ('simple', 'pro', 'premium'));
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
  ALTER TABLE public.groups
    ADD CONSTRAINT chk_groups_sound_capacity_positive
    CHECK (sound_capacity_max IS NULL OR sound_capacity_max > 0);
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
  ALTER TABLE public.groups
    ADD CONSTRAINT chk_groups_setup_minutes_positive
    CHECK (setup_minutes IS NULL OR setup_minutes >= 0);
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
  ALTER TABLE public.groups
    ADD CONSTRAINT chk_groups_power_amps_positive
    CHECK (power_amps IS NULL OR power_amps > 0);
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

COMMIT;

-- ── Verificación ──────────────────────────────────────────────────────────────
SELECT column_name, data_type, column_default, is_nullable
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name   = 'groups'
  AND column_name IN (
    'has_sound','sound_capacity_max','has_lighting','lighting_level',
    'has_stage','stage_sizes_available','has_led_screen','led_sizes_available',
    'power_amps','needs_parking','setup_minutes','includes_text'
  )
ORDER BY column_name;

SELECT '403_group_equipment_columns.sql ✅ — 12 columnas de equipo en groups' AS status;
