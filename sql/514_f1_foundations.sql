-- ============================================================
-- sql/514_f1_foundations.sql — F1 PASO 2: FUNDACIONES (ADITIVO)
--
-- Diseño v2 aprobado 2026-07-19. TODO es aditivo:
--  · NO borra ni cambia datos reales (solo llena columnas NUEVAS)
--  · NO quita el candado por día actual (sigue vivo como cinturón
--    hasta F2 — la experiencia del cliente NO cambia)
--  · NO crea el EXCLUSION CONSTRAINT (eso es sql/516, gated por la
--    auditoría 513)
--  · NO llama servicios externos desde triggers
--
-- Objetos NUEVOS:
--   columnas reservations.event_tz, reservations.busy_range
--   fn estados_que_ocupan()            (única fuente de la lista)
--   fn estados_que_cuentan_limite()    (ocupan ∪ completed — decisión cerrada)
--   fn tz_for_event(state, country)    (MX 4 zonas · US · CA)
--   fn make_busy_range(...)            (montaje 30' + dur + extras×75' + 45')
--   fn count_events_local_day(...)     (límite diario, excluible)
--   trg set_reservation_busy_range     (mantiene el rango)
--   trg recompute_range_on_extra       (extras recalculan el rango)
--   fn/trg enforce_group_availability  v2 (anti-bypass: bloqueo manual +
--        límite 2 + traslape software + LEGADO date_taken intacto;
--        ahora también dispara en cambios de STATUS)
--   trg block_vs_reservations          (bloqueo manual no pisa reservas)
-- ============================================================

BEGIN;

-- ── Columnas nuevas ──────────────────────────────────────────
ALTER TABLE public.reservations
  ADD COLUMN IF NOT EXISTS event_tz   TEXT,
  ADD COLUMN IF NOT EXISTS busy_range TSTZRANGE;

CREATE INDEX IF NOT EXISTS idx_res_busy_range
  ON public.reservations USING gist (busy_range);

-- ── 1. Listas de estados (ÚNICA fuente) ──────────────────────
CREATE OR REPLACE FUNCTION public.estados_que_ocupan()
RETURNS TEXT[] LANGUAGE sql IMMUTABLE AS $$
  SELECT ARRAY['pending','pending_payment','pending_group_confirmation',
               'accepted','confirmed','in_progress','live'];
$$;

-- Para el LÍMITE diario: completed SÍ cuenta (decisión cerrada 2026-07-19:
-- una tocada realizada es una tocada — libera el rango, no el cupo)
CREATE OR REPLACE FUNCTION public.estados_que_cuentan_limite()
RETURNS TEXT[] LANGUAGE sql IMMUTABLE AS $$
  SELECT public.estados_que_ocupan() || ARRAY['completed'];
$$;

-- ── 2. Zona horaria por evento (IANA) ────────────────────────
CREATE OR REPLACE FUNCTION public.tz_for_event(p_state TEXT, p_country TEXT)
RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    -- México (4 zonas)
    WHEN p_state IN ('Baja California')                         THEN 'America/Tijuana'
    WHEN p_state IN ('Sonora')                                  THEN 'America/Hermosillo'
    WHEN p_state IN ('Quintana Roo')                            THEN 'America/Cancun'
    WHEN p_state IN ('Baja California Sur','Sinaloa','Nayarit') THEN 'America/Mazatlan'
    WHEN p_state IN ('Chihuahua')                               THEN 'America/Chihuahua'
    -- Estados Unidos
    WHEN p_state IN ('California','Washington','Oregon','Nevada') THEN 'America/Los_Angeles'
    WHEN p_state IN ('Arizona')                                   THEN 'America/Phoenix'
    WHEN p_state IN ('Utah','Colorado','New Mexico','Montana','Idaho','Wyoming') THEN 'America/Denver'
    WHEN p_state IN ('Texas','Illinois','Missouri','Minnesota','Wisconsin','Iowa','Oklahoma',
                     'Kansas','Nebraska','Arkansas','Louisiana','Mississippi','Alabama',
                     'Tennessee','North Dakota','South Dakota')   THEN 'America/Chicago'
    WHEN p_state IN ('Alaska')                                    THEN 'America/Anchorage'
    WHEN p_state IN ('Hawaii')                                    THEN 'Pacific/Honolulu'
    WHEN p_country = 'Estados Unidos'                             THEN 'America/New_York'
    -- Canadá
    WHEN p_state IN ('British Columbia','Yukon')                  THEN 'America/Vancouver'
    WHEN p_state IN ('Alberta','Northwest Territories')           THEN 'America/Edmonton'
    WHEN p_state IN ('Saskatchewan')                              THEN 'America/Regina'
    WHEN p_state IN ('Manitoba','Nunavut')                        THEN 'America/Winnipeg'
    WHEN p_state IN ('Ontario','Quebec')                          THEN 'America/Toronto'
    WHEN p_state IN ('Nova Scotia','New Brunswick','Prince Edward Island') THEN 'America/Halifax'
    WHEN p_state IN ('Newfoundland and Labrador')                 THEN 'America/St_Johns'
    WHEN p_country = 'Canadá'                                     THEN 'America/Toronto'
    -- Default México centro
    ELSE 'America/Mexico_City'
  END;
$$;

-- ── 3. Rango duro (UTC) — montaje 30' + dur + extras×75' + 45' ──
-- (45' = desmontaje 30' + margen fijo 15'). Interpreta la hora de
-- PARED local en la tz del evento → DST correcto por fecha.
CREATE OR REPLACE FUNCTION public.make_busy_range(
  p_event_date DATE,
  p_event_time TIME,
  p_tz         TEXT,
  p_hours      INT,
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

-- ── 4. Conteo del límite diario ──────────────────────────────
-- El "día" del evento = event_date (la fecha LOCAL elegida al reservar;
-- el evento que cruza medianoche pertenece a su día de inicio).
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

-- ── 5. Trigger que MANTIENE el rango ─────────────────────────
CREATE OR REPLACE FUNCTION public.set_reservation_busy_range()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
  v_extras INT;
  v_state  TEXT;
  v_ctry   TEXT;
BEGIN
  IF NEW.event_date IS NULL THEN
    RETURN NEW;   -- sin fecha no hay rango (filas raras legacy)
  END IF;

  IF NEW.event_tz IS NULL THEN
    SELECT g.state, g.country INTO v_state, v_ctry FROM groups g WHERE g.id = NEW.group_id;
    NEW.event_tz := public.tz_for_event(v_state, v_ctry);
  END IF;

  SELECT COUNT(*) INTO v_extras FROM extra_hours eh
  WHERE eh.reservation_id = NEW.id AND eh.status IN ('accepted','paid');

  NEW.busy_range := public.make_busy_range(
    NEW.event_date, NEW.event_time, NEW.event_tz, NEW.hours_count, v_extras);
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_set_busy_range ON public.reservations;
CREATE TRIGGER trg_set_busy_range
  BEFORE INSERT OR UPDATE OF event_date, event_time, hours_count, event_tz, status
  ON public.reservations
  FOR EACH ROW EXECUTE FUNCTION public.set_reservation_busy_range();

-- Extras confirmadas recalculan el rango del padre
CREATE OR REPLACE FUNCTION public.recompute_range_on_extra()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  UPDATE reservations SET updated_at = NOW()   -- dispara trg_set_busy_range
  WHERE id = COALESCE(NEW.reservation_id, OLD.reservation_id);
  RETURN COALESCE(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS trg_recompute_range_on_extra ON public.extra_hours;
CREATE TRIGGER trg_recompute_range_on_extra
  AFTER INSERT OR UPDATE OF status OR DELETE
  ON public.extra_hours
  FOR EACH ROW EXECUTE FUNCTION public.recompute_range_on_extra();
-- Nota: trg_set_busy_range dispara en UPDATE OF status/updated? — updated_at
-- no está en su lista; se agrega columna disparadora:
DROP TRIGGER IF EXISTS trg_set_busy_range ON public.reservations;
CREATE TRIGGER trg_set_busy_range
  BEFORE INSERT OR UPDATE OF event_date, event_time, hours_count, event_tz, status, updated_at
  ON public.reservations
  FOR EACH ROW EXECUTE FUNCTION public.set_reservation_busy_range();

-- ── 6. Trigger v2 — BARRERA ANTI-BYPASS ──────────────────────
-- Mantiene INTACTO el candado legado por día (date_taken/date_blocked,
-- lista vieja de estados) — se retirará en F2 — y AGREGA:
--   · dispara también en cambios de STATUS (webhooks/reactivaciones)
--   · límite diario de 2 (completed cuenta)
--   · traslape de rangos (software, hasta que 516 active el constraint)
CREATE OR REPLACE FUNCTION public.enforce_group_availability()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
  v_entrando_ocupante BOOLEAN;
BEGIN
  IF NEW.group_id IS NULL OR NEW.event_date IS NULL THEN
    RETURN NEW;
  END IF;

  -- ¿Esta operación mete la fila al mundo "ocupante"?
  v_entrando_ocupante :=
    NEW.status = ANY (public.estados_que_ocupan())
    AND (TG_OP = 'INSERT'
         OR OLD.status IS DISTINCT FROM NEW.status
         OR OLD.event_date IS DISTINCT FROM NEW.event_date
         OR OLD.group_id  IS DISTINCT FROM NEW.group_id);

  IF NOT v_entrando_ocupante THEN
    RETURN NEW;   -- completar, cancelar, pagos, etc. pasan libres
  END IF;

  -- Carril único por grupo (serializa TODO el flujo de agenda)
  PERFORM pg_advisory_xact_lock(hashtext(NEW.group_id::text));

  -- (a) LEGADO intacto: bloqueo manual por día
  IF EXISTS (
    SELECT 1 FROM group_unavailability gu
    WHERE gu.group_id = NEW.group_id AND gu.date = NEW.event_date
  ) THEN
    RAISE EXCEPTION 'date_blocked';
  END IF;

  -- (b) LEGADO intacto: candado por día (lista vieja, se retira en F2)
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

  -- (c) NUEVO [514]: límite diario de 2 (completed cuenta)
  IF public.count_events_local_day(NEW.group_id, NEW.event_date, NEW.id) >= 2 THEN
    RAISE EXCEPTION 'daily_event_limit';
  END IF;

  -- (d) NUEVO [514]: traslape de rangos (respaldo software del constraint)
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
CREATE TRIGGER trg_enforce_group_availability
  BEFORE INSERT OR UPDATE OF group_id, event_date, event_time, status
  ON public.reservations
  FOR EACH ROW EXECUTE FUNCTION public.enforce_group_availability();

-- ── 7. Bloqueo manual no puede pisar reservas ocupantes ──────
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

-- ── 8. Backfill ADITIVO (solo llena columnas NUEVAS) ─────────
UPDATE public.reservations r
SET event_tz = public.tz_for_event(g.state, g.country)
FROM public.groups g
WHERE g.id = r.group_id AND r.event_tz IS NULL;

UPDATE public.reservations r
SET busy_range = public.make_busy_range(
      r.event_date, r.event_time, r.event_tz, r.hours_count,
      (SELECT COUNT(*)::INT FROM extra_hours eh
       WHERE eh.reservation_id = r.id AND eh.status IN ('accepted','paid')))
WHERE r.event_date IS NOT NULL AND r.busy_range IS NULL;

COMMIT;

-- ── VERIFICACIÓN ──────────────────────────────────────────────────────────────
SELECT proname FROM pg_proc WHERE proname IN
  ('estados_que_ocupan','estados_que_cuentan_limite','tz_for_event',
   'make_busy_range','count_events_local_day','set_reservation_busy_range',
   'block_vs_reservations');
-- Esperado: 7 filas

SELECT COUNT(*) AS ocupantes_sin_rango
FROM reservations
WHERE status = ANY (estados_que_ocupan())
  AND event_date IS NOT NULL AND busy_range IS NULL;
-- Esperado: 0

SELECT prosrc LIKE '%daily_event_limit%' AS trigger_v2_activo
FROM pg_proc WHERE proname = 'enforce_group_availability';
-- Esperado: true

SELECT '514_f1_foundations.sql ejecutado ✅' AS status;
