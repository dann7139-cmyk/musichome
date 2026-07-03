-- ════════════════════════════════════════════════════════════════════
-- sql/363_remove_break_type_c.sql
--
-- Objetivo: Eliminar el tipo 'C' (20 min descanso) de la base de datos.
-- El tipo 'C' fue eliminado de la UI en commits previos:
--   - calculations.ts (case 'C' del switch, BREAK_SURCHARGE_FIXED)
--   - EventTimerScreen.tsx / BookingScreen.tsx (BREAK_OPTIONS)
--   - models.ts (BreakType = 'A' | 'B' | 'D')
--
-- Tablas con CHECK constraint (A|B|C|D → A|B|D):
--   1. public.packages     — break_type TEXT DEFAULT 'A' CHECK(...)
--   2. public.reservations — break_type TEXT CHECK(...)
--   3. public.quotes       — break_type TEXT NOT NULL DEFAULT 'A' CHECK(...)
--
-- Tabla sin constraint (solo migración de datos):
--   4. public.event_timer_states — break_type TEXT NOT NULL (sin CHECK)
--
-- Estrategia de migración:
--   PASO 1 — Migrar filas con 'C' → 'B' en las 4 tablas.
--            Lógica: C (20 min único a la mitad) ≈ B (15 min único a la mitad).
--            El cliente no nota la diferencia — ambos son un solo descanso.
--   PASO 2 — DROP constraints existentes (búsqueda dinámica por pg_constraint
--            para no depender del nombre auto-generado de PostgreSQL).
--   PASO 3 — ADD constraints nuevas: solo ('A','B','D') NOT VALID.
--            NOT VALID: valida solo nuevos INSERTs/UPDATEs; no revalida
--            filas históricas (no las hay con 'C' tras el PASO 1).
--
-- Compatible con: sql/01_tablas_base.sql, sql/33_cotizaciones.sql
-- Requiere: Bloques 1 ya aplicados (models.ts, UI limpia).
-- ════════════════════════════════════════════════════════════════════

BEGIN;

-- ════════════════════════════════════════════════════════════════════
-- PASO 1: Migrar filas existentes con break_type = 'C' → 'B'
-- ════════════════════════════════════════════════════════════════════

UPDATE public.packages
SET    break_type = 'B'
WHERE  break_type = 'C';

UPDATE public.reservations
SET    break_type = 'B'
WHERE  break_type = 'C';

UPDATE public.quotes
SET    break_type = 'B'
WHERE  break_type = 'C';


-- ════════════════════════════════════════════════════════════════════
-- PASO 2: DROP constraints existentes (búsqueda dinámica)
--
-- Buscamos por pg_constraint cualquier CHECK sobre break_type en las
-- 3 tablas afectadas. No hardcodeamos el nombre para que funcione
-- aunque el auto-nombre difiera entre entornos.
-- event_timer_states NO tiene CHECK → no se toca.
-- ════════════════════════════════════════════════════════════════════

DO $$
DECLARE
  v_cname TEXT;
  v_tables TEXT[] := ARRAY['packages', 'reservations', 'quotes'];
  v_table  TEXT;
BEGIN
  FOREACH v_table IN ARRAY v_tables LOOP
    SELECT c.conname INTO v_cname
    FROM   pg_constraint c
    JOIN   pg_class t       ON t.oid = c.conrelid
    JOIN   pg_namespace n   ON n.oid = t.relnamespace
    WHERE  t.relname  = v_table
      AND  n.nspname  = 'public'
      AND  c.contype  = 'c'
      AND  pg_get_constraintdef(c.oid) LIKE '%break_type%'
    LIMIT 1;

    IF v_cname IS NOT NULL THEN
      EXECUTE 'ALTER TABLE public.' || quote_ident(v_table)
           || ' DROP CONSTRAINT ' || quote_ident(v_cname);
      RAISE NOTICE '[363] DROP %.% ✅', v_table, v_cname;
    ELSE
      RAISE NOTICE '[363] %.break_type: sin constraint previo, OK', v_table;
    END IF;

    v_cname := NULL;
  END LOOP;
END;
$$;

-- ════════════════════════════════════════════════════════════════════
-- PASO 3: ADD constraints nuevas — solo ('A','B','D') NOT VALID
--
-- Nombres explícitos para facilitar DROP futuro.
-- NOT VALID: patrón estándar del proyecto (ver sql/362, sql/346).
-- ════════════════════════════════════════════════════════════════════

ALTER TABLE public.packages
  ADD CONSTRAINT packages_break_type_check
  CHECK (break_type IN ('A','B','D')) NOT VALID;

ALTER TABLE public.reservations
  ADD CONSTRAINT reservations_break_type_check
  CHECK (break_type IN ('A','B','D')) NOT VALID;

ALTER TABLE public.quotes
  ADD CONSTRAINT quotes_break_type_check
  CHECK (break_type IN ('A','B','D')) NOT VALID;

COMMIT;


-- ════════════════════════════════════════════════════════════════════
-- VERIFICACIONES (ejecutar después del COMMIT)
-- ════════════════════════════════════════════════════════════════════

-- V1: No debe haber filas con 'C' en ninguna tabla
--     Esperado: 4 filas, todas con filas_c = 0
SELECT 'packages'     AS tabla, COUNT(*) AS filas_c FROM public.packages     WHERE break_type = 'C'
UNION ALL
SELECT 'reservations' AS tabla, COUNT(*) AS filas_c FROM public.reservations WHERE break_type = 'C'
UNION ALL
SELECT 'quotes'       AS tabla, COUNT(*) AS filas_c FROM public.quotes       WHERE break_type = 'C';


-- V2: Constraints activos — deben mostrar solo 'A','B','D'
--     Esperado: 3 filas (packages, reservations, quotes),
--               definición NO contiene 'C'
SELECT t.relname    AS tabla,
       c.conname    AS constraint_name,
       pg_get_constraintdef(c.oid) AS definition
FROM   pg_constraint c
JOIN   pg_class t     ON t.oid = c.conrelid
JOIN   pg_namespace n ON n.oid = t.relnamespace
WHERE  t.relname  IN ('packages', 'reservations', 'quotes')
  AND  n.nspname  = 'public'
  AND  c.contype  = 'c'
  AND  pg_get_constraintdef(c.oid) LIKE '%break_type%'
ORDER  BY t.relname;


-- V3: Test — intentar insertar 'C' debe ser rechazado
--     Esperado: NOTICE "[V3] OK — INSERT con C rechazado correctamente ✅"
--     En PostgreSQL, CHECK se evalúa antes que FK; el check_violation
--     se dispara aunque group_id no exista en la tabla groups.
DO $$
BEGIN
  INSERT INTO public.packages (group_id, name, price, break_type, duration_hours, is_active)
  VALUES (gen_random_uuid(), '__test_v3_363__', 1, 'C', 3, FALSE);

  -- Si llegamos aquí sin excepción, el constraint no funciona
  DELETE FROM public.packages WHERE name = '__test_v3_363__';
  RAISE EXCEPTION '[V3] FALLO — C fue aceptado sin error ❌';

EXCEPTION
  WHEN check_violation THEN
    RAISE NOTICE '[V3] OK — INSERT con C rechazado correctamente ✅';
  WHEN OTHERS THEN
    -- Otro error (ej. FK) antes de llegar al CHECK — verificar constraint manualmente con V2
    RAISE NOTICE '[V3] Otro error (posible FK antes de CHECK): % — revisar V2 para confirmar constraint activo', SQLERRM;
END;
$$;


-- V4: Distribución actual de break_type por tabla
--     Esperado: solo valores A, B, D
SELECT 'packages'     AS tabla, break_type, COUNT(*) AS total FROM public.packages     GROUP BY break_type
UNION ALL
SELECT 'reservations' AS tabla, break_type, COUNT(*) AS total FROM public.reservations GROUP BY break_type
UNION ALL
SELECT 'quotes'       AS tabla, break_type, COUNT(*) AS total FROM public.quotes       GROUP BY break_type
ORDER  BY tabla, break_type;


SELECT 'sql/363_remove_break_type_c.sql ejecutado ✅' AS status;
