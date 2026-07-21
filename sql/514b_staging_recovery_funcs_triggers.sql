-- ============================================================
-- sql/514b_staging_recovery_funcs_triggers.sql — PARCHE DE RECUPERACIÓN
--
-- Solo para el escenario diagnosticado en la Preview Branch de staging
-- (2026-07-21): columnas event_tz/busy_range presentes, pero las
-- funciones/triggers de F1 ausentes y el candado de 516 sin aplicar —
-- estado idéntico al que dejó sql/517 (rollback) antes de la
-- reaplicación en producción. Probablemente la rama se aprovisionó
-- desde un snapshot tomado en esa ventana.
--
-- Contenido: SUBCONJUNTO estricto de sql/514 (mismas 9 funciones, mismos
-- 4 triggers, mismo backfill, byte-idéntico donde se solapa) + el
-- candado de sql/516. NO incluye ADD COLUMN ni CREATE INDEX de 514
-- porque ya están presentes (eran no-op de todas formas).
--
-- Confirmado que sql/514 es 100% idempotente (ADD COLUMN IF NOT EXISTS,
-- CREATE INDEX IF NOT EXISTS, CREATE OR REPLACE FUNCTION, DROP TRIGGER
-- IF EXISTS + CREATE, backfill guardado por IS NULL) — re-ejecutar el
-- archivo completo sin editar produce el MISMO resultado que este
-- parche. Este archivo existe solo como alternativa más angosta, a
-- elección del usuario.
--
-- sql/516 tiene UNA sentencia no idempotente (ADD CONSTRAINT sin
-- IF NOT EXISTS) — pero el diagnóstico confirmó candado_516=0: esta es
-- la primera aplicación real, sin riesgo de duplicado.
-- ============================================================

BEGIN;

-- ── 1. Listas de estados (ÚNICA fuente) ──────────────────────
CREATE OR REPLACE FUNCTION public.estados_que_ocupan()
RETURNS TEXT[] LANGUAGE sql IMMUTABLE AS $$
  SELECT ARRAY['pending','pending_payment','pending_group_confirmation',
               'accepted','confirmed','in_progress','live'];
$$;

CREATE OR REPLACE FUNCTION public.estados_que_cuentan_limite()
RETURNS TEXT[] LANGUAGE sql IMMUTABLE AS $$
  SELECT public.estados_que_ocupan() || ARRAY['completed'];
$$;

-- ── 2. Zona horaria por evento (IANA) ────────────────────────
CREATE OR REPLACE FUNCTION public.tz_for_event(p_state TEXT, p_country TEXT)
RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN p_state IN ('Baja California')                         THEN 'America/Tijuana'
    WHEN p_state IN ('Sonora')                                  THEN 'America/Hermosillo'
    WHEN p_state IN ('Quintana Roo')                            THEN 'America/Cancun'
    WHEN p_state IN ('Baja California Sur','Sinaloa','Nayarit') THEN 'America/Mazatlan'
    WHEN p_state IN ('Chihuahua')                               THEN 'America/Chihuahua'
    WHEN p_state IN ('California','Washington','Oregon','Nevada') THEN 'America/Los_Angeles'
    WHEN p_state IN ('Arizona')                                   THEN 'America/Phoenix'
    WHEN p_state IN ('Utah','Colorado','New Mexico','Montana','Idaho','Wyoming') THEN 'America/Denver'
    WHEN p_state IN ('Texas','Illinois','Missouri','Minnesota','Wisconsin','Iowa','Oklahoma',
                     'Kansas','Nebraska','Arkansas','Louisiana','Mississippi','Alabama',
                     'Tennessee','North Dakota','South Dakota')   THEN 'America/Chicago'
    WHEN p_state IN ('Alaska')                                    THEN 'America/Anchorage'
    WHEN p_state IN ('Hawaii')                                    THEN 'Pacific/Honolulu'
    WHEN p_country = 'Estados Unidos'                             THEN 'America/New_York'
    WHEN p_state IN ('British Columbia','Yukon')                  THEN 'America/Vancouver'
    WHEN p_state IN ('Alberta','Northwest Territories')           THEN 'America/Edmonton'
    WHEN p_state IN ('Saskatchewan')                              THEN 'America/Regina'
    WHEN p_state IN ('Manitoba','Nunavut')                        THEN 'America/Winnipeg'
    WHEN p_state IN ('Ontario','Quebec')                          THEN 'America/Toronto'
    WHEN p_state IN ('Nova Scotia','New Brunswick','Prince Edward Island') THEN 'America/Halifax'
    WHEN p_state IN ('Newfoundland and Labrador')                 THEN 'America/St_Johns'
    WHEN p_country = 'Canadá'                                     THEN 'America/Toronto'
    ELSE 'America/Mexico_City'
  END;
$$;

-- ── 3. Rango duro (UTC) ───────────────────────────────────────
CREATE OR REPLACE FUNCTION public.make_busy_range(
  p_event_date DATE,
  p_event_time TIME,
  p_tz         TEXT,
  p_hours      NUMERIC,
  p_extras     INT
)
RETURNS TSTZRANGE LANGUAGE sql IMMUTABLE AS $$
  SELECT tstzrange(
    ((p_event_date + COALESCE(p_event_time, TIME '17:00'))
       AT TIME ZONE COALESCE(p_tz, 'America/Mexico_City')) - INTERVAL '30 minutes',
    ((p_event_date + COALESCE(p_event_time, TIME '17:00'))
       AT TIME ZONE COALESCE(p_tz, 'America/Mexico_City'))
      + (GREATEST(COALESCE(p_hours, 3), 1) * INTERVAL '1 hour')
      + (GREATEST(COALESCE(p_extras, 0), 0) * INTERVAL '75 minutes')
      + INTERVAL '45 minutes',
    '[)'
  );
$$;

-- ── 4. Conteo del límite diario ───────────────────────────────
CREATE OR REPLACE FUNCTION public.count_events_local_day(
  p_group_id UUID,
  p_date     DATE,
  p_exclude  UUID DEFAULT NULL
)
RETURNS INT LANGUAGE sql STABLE AS $$
  SELECT COUNT(*)::INT
  FROM reservations r
  WHERE r.group_id = p_group_id
    AND r.event_date = p_date
    AND r.status = ANY (public.estados_que_cuentan_limite())
    AND (p_exclude IS NULL OR r.id <> p_exclude);
$$;

-- ── 5. Trigger que MANTIENE el rango ──────────────────────────
CREATE OR REPLACE FUNCTION public.set_reservation_busy_range()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
  v_extras INT;
  v_state  TEXT;
  v_ctry   TEXT;
BEGIN
  IF NEW.event_date IS NULL THEN
    RETURN NEW;
  END IF;

  IF NEW.event_tz IS NULL THEN
    SELECT g.state, g.country INTO v_state, v_ctry FROM groups g WHERE g.id = NEW.group_id;
    NEW.event_tz := public.tz_for_event(v_state, v_ctry);
  END IF;

  SELECT COALESCE(SUM(eh.hours_added), 0)::INT INTO v_extras FROM extra_hours eh
  WHERE eh.reservation_id = NEW.id AND eh.status IN ('accepted','paid');

  NEW.busy_range := public.make_busy_range(
    NEW.event_date, NEW.event_time, NEW.event_tz, NEW.hours_count, v_extras);
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_set_busy_range ON public.reservations;
DROP TRIGGER IF EXISTS trg_01_set_busy_range ON public.reservations;
CREATE TRIGGER trg_01_set_busy_range
  BEFORE INSERT OR UPDATE OF event_date, event_time, hours_count, event_tz, status, updated_at
  ON public.reservations
  FOR EACH ROW EXECUTE FUNCTION public.set_reservation_busy_range();

CREATE OR REPLACE FUNCTION public.recompute_range_on_extra()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  UPDATE reservations SET updated_at = NOW()
  WHERE id = COALESCE(NEW.reservation_id, OLD.reservation_id);
  RETURN COALESCE(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS trg_recompute_range_on_extra ON public.extra_hours;
CREATE TRIGGER trg_recompute_range_on_extra
  AFTER INSERT OR UPDATE OF status OR DELETE
  ON public.extra_hours
  FOR EACH ROW EXECUTE FUNCTION public.recompute_range_on_extra();

-- ── 6. Trigger v2 — BARRERA ANTI-BYPASS ───────────────────────
CREATE OR REPLACE FUNCTION public.enforce_group_availability()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
  v_entrando_ocupante BOOLEAN;
BEGIN
  IF NEW.group_id IS NULL OR NEW.event_date IS NULL THEN
    RETURN NEW;
  END IF;

  v_entrando_ocupante :=
    NEW.status = ANY (public.estados_que_ocupan())
    AND (TG_OP = 'INSERT'
         OR OLD.status IS DISTINCT FROM NEW.status
         OR OLD.event_date IS DISTINCT FROM NEW.event_date
         OR OLD.group_id  IS DISTINCT FROM NEW.group_id);

  IF NOT v_entrando_ocupante THEN
    RETURN NEW;
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext(NEW.group_id::text));

  IF EXISTS (
    SELECT 1 FROM group_unavailability gu
    WHERE gu.group_id = NEW.group_id AND gu.date = NEW.event_date
  ) THEN
    RAISE EXCEPTION 'date_blocked';
  END IF;

  IF EXISTS (
    SELECT 1 FROM reservations r
    WHERE r.group_id = NEW.group_id
      AND r.event_date = NEW.event_date
      AND r.id <> NEW.id
      AND r.status IN ('pending','pending_payment','pending_group_confirmation',
                       'confirmed','in_progress')
  ) THEN
    RAISE EXCEPTION 'date_taken';
  END IF;

  IF public.count_events_local_day(NEW.group_id, NEW.event_date, NEW.id) >= 2 THEN
    RAISE EXCEPTION 'daily_event_limit';
  END IF;

  IF NEW.busy_range IS NOT NULL AND EXISTS (
    SELECT 1 FROM reservations r
    WHERE r.group_id = NEW.group_id
      AND r.id <> NEW.id
      AND r.status = ANY (public.estados_que_ocupan())
      AND r.busy_range && NEW.busy_range
  ) THEN
    RAISE EXCEPTION 'time_overlap';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_enforce_group_availability ON public.reservations;
DROP TRIGGER IF EXISTS trg_02_enforce_group_availability ON public.reservations;
CREATE TRIGGER trg_02_enforce_group_availability
  BEFORE INSERT OR UPDATE OF group_id, event_date, event_time, status
  ON public.reservations
  FOR EACH ROW EXECUTE FUNCTION public.enforce_group_availability();

-- ── 7. Bloqueo manual no puede pisar reservas ocupantes ───────
CREATE OR REPLACE FUNCTION public.block_vs_reservations()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext(NEW.group_id::text));
  IF EXISTS (
    SELECT 1 FROM reservations r
    WHERE r.group_id = NEW.group_id
      AND r.event_date = NEW.date
      AND r.status = ANY (public.estados_que_ocupan())
  ) THEN
    RAISE EXCEPTION 'block_conflicts_reservations';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_block_vs_reservations ON public.group_unavailability;
CREATE TRIGGER trg_block_vs_reservations
  BEFORE INSERT OR UPDATE ON public.group_unavailability
  FOR EACH ROW EXECUTE FUNCTION public.block_vs_reservations();

-- ── 8. Backfill ADITIVO (solo llena columnas NUEVAS que llegaron
--       vacías porque las funciones no existían hasta ahora) ──────
UPDATE public.reservations r
SET event_tz = public.tz_for_event(g.state, g.country)
FROM public.groups g
WHERE g.id = r.group_id AND r.event_tz IS NULL;

UPDATE public.reservations r
SET busy_range = public.make_busy_range(
      r.event_date, r.event_time, r.event_tz, r.hours_count,
      (SELECT COALESCE(SUM(eh.hours_added), 0)::INT FROM extra_hours eh
       WHERE eh.reservation_id = r.id AND eh.status IN ('accepted','paid')))
WHERE r.event_date IS NOT NULL AND r.busy_range IS NULL;

-- ── 9. [516] Pre-verificación dura + candado de motor ─────────
DO $$
DECLARE v_conflictos INT;
BEGIN
  SELECT COUNT(*) INTO v_conflictos
  FROM reservations a
  JOIN reservations b
    ON b.group_id = a.group_id AND b.id > a.id
   AND a.busy_range && b.busy_range
  WHERE a.status = ANY (public.estados_que_ocupan())
    AND b.status = ANY (public.estados_que_ocupan());
  IF v_conflictos > 0 THEN
    RAISE EXCEPTION 'ABORTADO: % traslape(s) entre ocupantes tras el backfill — revisar antes de continuar', v_conflictos;
  END IF;
END $$;

CREATE EXTENSION IF NOT EXISTS btree_gist;

ALTER TABLE public.reservations
  ADD CONSTRAINT excl_group_busy_range
  EXCLUDE USING gist (group_id WITH =, busy_range WITH &&)
  WHERE (status = ANY (public.estados_que_ocupan()) AND busy_range IS NOT NULL);

COMMIT;

-- ── VERIFICACIÓN ──────────────────────────────────────────────────────────────
SELECT proname FROM pg_proc WHERE proname IN
  ('estados_que_ocupan','estados_que_cuentan_limite','tz_for_event',
   'make_busy_range','count_events_local_day','set_reservation_busy_range',
   'recompute_range_on_extra','enforce_group_availability','block_vs_reservations');
-- Esperado: 9 filas

SELECT COUNT(*) AS ocupantes_sin_rango
FROM reservations
WHERE status = ANY (estados_que_ocupan())
  AND event_date IS NOT NULL AND busy_range IS NULL;
-- Esperado: 0

SELECT conname, contype FROM pg_constraint WHERE conname = 'excl_group_busy_range';
-- Esperado: 1 fila, contype 'x'

SELECT '514b_staging_recovery ejecutado ✅ — F1 completo en staging' AS status;
