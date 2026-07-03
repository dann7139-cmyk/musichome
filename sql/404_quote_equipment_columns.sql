-- ═══════════════════════════════════════════════════════════════════════════
-- sql/404_quote_equipment_columns.sql
--
-- Agrega columnas de equipo solicitado por el cliente en public.quotes.
-- Nomenclatura consistente con needs_sound (ya existente):
--   needs_lighting, needs_stage, needs_led
--
-- También actualiza el constraint de needs_sound para aceptar los nuevos
-- valores del wizard (v2), manteniendo backward compat con valores viejos.
--
-- Idempotente: IF NOT EXISTS en ADD COLUMN; DO $$ EXCEPTION en constraints.
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

-- ── 1. Nuevas columnas (opcionales, NULL = cliente no especificó) ──────────────

ALTER TABLE public.quotes
  ADD COLUMN IF NOT EXISTS needs_lighting TEXT DEFAULT NULL,
  ADD COLUMN IF NOT EXISTS needs_stage    TEXT DEFAULT NULL,
  ADD COLUMN IF NOT EXISTS needs_led      TEXT DEFAULT NULL;

-- ── 2. Actualizar constraint de needs_sound para valores v2 ───────────────────
-- Valores v2: no_group_brings | si_50 | si_100 | si_200
-- Backward compat: si | no | ya_tengo (datos existentes)

ALTER TABLE public.quotes
  DROP CONSTRAINT IF EXISTS chk_needs_sound;

DO $$ BEGIN
  ALTER TABLE public.quotes
    ADD CONSTRAINT chk_needs_sound
    CHECK (needs_sound IS NULL OR needs_sound IN (
      'no_group_brings', 'si_50', 'si_100', 'si_200',
      'si', 'no', 'ya_tengo'
    ));
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- ── 3. Constraints para nuevas columnas ──────────────────────────────────────

DO $$ BEGIN
  ALTER TABLE public.quotes
    ADD CONSTRAINT chk_needs_lighting
    CHECK (needs_lighting IS NULL OR needs_lighting IN ('no', 'simple', 'pro', 'premium'));
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
  ALTER TABLE public.quotes
    ADD CONSTRAINT chk_needs_stage
    CHECK (needs_stage IS NULL OR needs_stage IN ('no', 'small', 'medium', 'wedding'));
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
  ALTER TABLE public.quotes
    ADD CONSTRAINT chk_needs_led
    CHECK (needs_led IS NULL OR needs_led IN ('no', 'medium', 'large', 'xl'));
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

COMMIT;

-- ── Verificación ──────────────────────────────────────────────────────────────
SELECT column_name, data_type, column_default, is_nullable
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name   = 'quotes'
  AND column_name IN ('needs_sound', 'needs_lighting', 'needs_stage', 'needs_led')
ORDER BY column_name;

SELECT '404_quote_equipment_columns.sql ✅ — needs_lighting/stage/led + constraint needs_sound v2' AS status;
