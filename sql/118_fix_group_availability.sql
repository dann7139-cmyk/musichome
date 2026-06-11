-- ════════════════════════════════════════════════════════════════════════════
-- 118_fix_group_availability.sql
-- Asegura que el sistema de disponibilidad express del grupo esté completo:
--   1. Columna groups.availability (available / busy / offline)
--   2. RPC set_group_availability() — el dueño actualiza su estado
--   3. Índice para búsquedas rápidas por estado
--
-- Idempotente: puede ejecutarse múltiples veces sin error.
-- Ejecutar DESPUÉS de 117_advertising_system.sql
-- ════════════════════════════════════════════════════════════════════════════


-- ── 1. Columna availability en groups ─────────────────────────────────────

ALTER TABLE public.groups
  ADD COLUMN IF NOT EXISTS availability TEXT
    NOT NULL DEFAULT 'available'
    CHECK (availability IN ('available', 'busy', 'offline'));

-- Índice para consultas de disponibilidad
CREATE INDEX IF NOT EXISTS idx_groups_availability
  ON public.groups (availability)
  WHERE is_active = true;


-- ── 2. RPC: set_group_availability ────────────────────────────────────────
-- El dueño del grupo actualiza su estado de disponibilidad express.
-- Retorna: { ok: true, availability: 'available'|'busy'|'offline' }
--       o: { ok: false, error: 'invalid_availability'|'no_group_found' }

DROP FUNCTION IF EXISTS public.set_group_availability(TEXT);
CREATE OR REPLACE FUNCTION public.set_group_availability(p_availability TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_group_id UUID;
BEGIN
  -- Validar valor
  IF p_availability NOT IN ('available', 'busy', 'offline') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_availability');
  END IF;

  -- Buscar el grupo del dueño autenticado
  SELECT id INTO v_group_id
  FROM public.groups
  WHERE owner_id = auth.uid()
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_group_found');
  END IF;

  -- Actualizar
  UPDATE public.groups
  SET    availability = p_availability
  WHERE  id = v_group_id;

  RETURN jsonb_build_object('ok', true, 'availability', p_availability);
END;
$$;

GRANT EXECUTE ON FUNCTION public.set_group_availability(TEXT) TO authenticated;


-- ── 3. RLS: el dueño puede leer y actualizar su propio grupo ──────────────
-- Nota: la mayoría de proyectos ya tienen RLS en groups.
-- Solo agrega la política si no existe una equivalente.

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE tablename = 'groups' AND policyname = 'groups_owner_update'
  ) THEN
    EXECUTE '
      CREATE POLICY "groups_owner_update" ON public.groups
        FOR UPDATE USING (owner_id = auth.uid());
    ';
  END IF;
END;
$$;


-- ── 4. Verificar que los grupos existentes tengan el valor por defecto ─────

UPDATE public.groups
SET availability = 'available'
WHERE availability IS NULL;


SELECT '118_fix_group_availability.sql ejecutado ✅' AS status;
SELECT 'Columna: groups.availability (available/busy/offline)' AS schema;
SELECT 'RPC: set_group_availability(p_availability TEXT) → JSONB' AS rpc;
