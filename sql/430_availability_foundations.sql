-- ============================================================
-- sql/430_availability_foundations.sql
-- LOTE 1 · Cimientos del calendario de disponibilidad
--
--   1. Columna `reason` en group_unavailability (la UI de
--      AvailabilityScreen ya la captura; sin la columna el INSERT
--      tronaba y el grupo no podía bloquear fechas).
--   2. Limpieza de RLS: había políticas ALL con qual=true →
--      CUALQUIER usuario podía insertar/borrar bloqueos de CUALQUIER
--      grupo (sabotaje de una línea). Canónicas: lectura pública,
--      escritura solo owner.
--   3. RPC get_group_busy_days: días/horas ocupados SIN exponer datos
--      privados (la RLS de reservations bloquea — correctamente — la
--      lectura de extraños; este RPC devuelve solo fecha/hora/horas).
--   4. Candado server-side en create_booking_with_event (sobre la
--      DEFINICIÓN VIGENTE pegada de prod, no de archivos viejos):
--      date_blocked / date_taken + advisory lock anti-carreras.
--
-- La columna de la tabla es `date` (confirmado en prod) — el frontend
-- se corrige en este mismo lote (blocked_date era el nombre roto).
-- ============================================================

-- ── PRE-CHECKS (corre antes; si algo no cuadra, DETENTE) ──────────────────────
-- P1: schema actual de la tabla
SELECT column_name, data_type FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'group_unavailability'
ORDER BY ordinal_position;
-- Esperado: id, group_id, date (y aún SIN reason)

-- P2: políticas actuales (para ver qué se va a limpiar)
SELECT policyname, cmd, qual, with_check FROM pg_policies
WHERE tablename = 'group_unavailability';


BEGIN;

-- ══════════════════════════════════════════════════════════════
-- 1. Columna reason
-- ══════════════════════════════════════════════════════════════
ALTER TABLE public.group_unavailability
  ADD COLUMN IF NOT EXISTS reason TEXT;

-- ══════════════════════════════════════════════════════════════
-- 2. RLS canónica (drop de TODAS las conocidas + 4 limpias)
-- ══════════════════════════════════════════════════════════════
ALTER TABLE public.group_unavailability ENABLE ROW LEVEL SECURITY;

-- Redundantes / peligrosas detectadas en prod
DROP POLICY IF EXISTS "group_unavailability_all"          ON public.group_unavailability;
DROP POLICY IF EXISTS "unavail_all"                       ON public.group_unavailability;
DROP POLICY IF EXISTS "client_read"                       ON public.group_unavailability;
DROP POLICY IF EXISTS "select_all"                        ON public.group_unavailability;
-- Nombres reales adicionales encontrados en prod (remate 430b)
DROP POLICY IF EXISTS "group_unavailability_client_read"  ON public.group_unavailability;
DROP POLICY IF EXISTS "unavail_select_all"                ON public.group_unavailability;
DROP POLICY IF EXISTS "unavail_write_owner"               ON public.group_unavailability;
-- group_unavailability_admin_all SE CONSERVA (admin-scoped, soporte)
-- Las de sql/07 (owner-only select quedó superada por lectura pública)
DROP POLICY IF EXISTS "group_unavailability_group_select" ON public.group_unavailability;
DROP POLICY IF EXISTS "group_unavailability_group_insert" ON public.group_unavailability;
DROP POLICY IF EXISTS "group_unavailability_group_delete" ON public.group_unavailability;
DROP POLICY IF EXISTS "group_unavailability_group_update" ON public.group_unavailability;

-- Canónicas
CREATE POLICY "unavail_public_read"
  ON public.group_unavailability FOR SELECT
  USING (true);  -- los clientes necesitan ver los días bloqueados

CREATE POLICY "unavail_owner_insert"
  ON public.group_unavailability FOR INSERT
  WITH CHECK (
    EXISTS (SELECT 1 FROM public.groups WHERE id = group_id AND owner_id = auth.uid())
  );

CREATE POLICY "unavail_owner_update"
  ON public.group_unavailability FOR UPDATE
  USING (
    EXISTS (SELECT 1 FROM public.groups WHERE id = group_id AND owner_id = auth.uid())
  );

CREATE POLICY "unavail_owner_delete"
  ON public.group_unavailability FOR DELETE
  USING (
    EXISTS (SELECT 1 FROM public.groups WHERE id = group_id AND owner_id = auth.uid())
  );

-- ══════════════════════════════════════════════════════════════
-- 3. get_group_busy_days — ocupación sin datos privados
-- ══════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.get_group_busy_days(
  p_group_id UUID,
  p_from     DATE,
  p_to       DATE
)
RETURNS TABLE (
  event_date  DATE,
  event_time  TIME,
  hours_count NUMERIC
)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'unauthorized: sesión requerida';
  END IF;

  RETURN QUERY
    SELECT r.event_date, r.event_time, r.hours_count
    FROM   reservations r
    WHERE  r.group_id   = p_group_id
      AND  r.event_date BETWEEN p_from AND p_to
      AND  r.status IN ('pending','pending_payment','pending_group_confirmation',
                        'confirmed','in_progress')
    ORDER BY r.event_date, r.event_time;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_group_busy_days(UUID, DATE, DATE) TO authenticated;

-- ══════════════════════════════════════════════════════════════
-- 4. create_booking_with_event con candado de disponibilidad
--    (definición VIGENTE de prod + validación antepuesta;
--     todo lo demás byte a byte)
-- ══════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.create_booking_with_event(
  p_client_id                  uuid,
  p_group_id                   uuid,
  p_package_id                 uuid,
  p_event_date                 date,
  p_event_time                 time without time zone,
  p_address                    text,
  p_total_price                numeric,
  p_notes                      text    DEFAULT NULL::text,
  p_break_type                 text    DEFAULT NULL::text,
  p_base_price                 numeric DEFAULT NULL::numeric,
  p_installment_plan           text    DEFAULT NULL::text,
  p_installment_months         integer DEFAULT NULL::integer,
  p_installment_monthly_amount numeric DEFAULT NULL::numeric,
  p_payment_mode               text    DEFAULT 'full'::text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_event_id       UUID;
  v_reservation_id UUID;
  v_flow_version   TEXT;
BEGIN
  -- [430] CANDADO DE DISPONIBILIDAD (día-nivel), a prueba de carreras:
  -- el lock serializa dos clientes reservando el mismo grupo+fecha a la vez.
  PERFORM pg_advisory_xact_lock(hashtext(p_group_id::text || p_event_date::text));

  IF EXISTS (
    SELECT 1 FROM group_unavailability
    WHERE group_id = p_group_id AND date = p_event_date
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'date_blocked');
  END IF;

  IF EXISTS (
    SELECT 1 FROM reservations
    WHERE group_id   = p_group_id
      AND event_date = p_event_date
      AND status IN ('pending','pending_payment','pending_group_confirmation',
                     'confirmed','in_progress')
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'date_taken');
  END IF;

  -- ── A partir de aquí: definición vigente sin cambios ──
  v_flow_version := CASE
    WHEN p_payment_mode = 'full' THEN 'full_payment_v2'
    ELSE 'legacy'
  END;
  INSERT INTO public.events (client_id, event_date, event_time, address, status)
  VALUES (p_client_id, p_event_date, p_event_time, p_address, 'active')
  RETURNING id INTO v_event_id;
  INSERT INTO public.reservations (
    event_id, group_id, package_id, client_id,
    event_date, event_time, address, notes, break_type,
    total_price, base_price, status,
    payment_mode, flow_version,
    installment_plan, installment_months, installment_monthly_amount
  )
  VALUES (
    v_event_id, p_group_id, p_package_id, p_client_id,
    p_event_date, p_event_time, p_address, p_notes, p_break_type,
    p_total_price, p_base_price, 'pending_payment',
    p_payment_mode, v_flow_version,
    p_installment_plan, p_installment_months, p_installment_monthly_amount
  )
  RETURNING id INTO v_reservation_id;
  RAISE NOTICE '[CREATE_BOOKING] reservation=% mode=% msi=%',
    v_reservation_id, p_payment_mode, COALESCE(p_installment_plan, '1_pago');
  RETURN jsonb_build_object(
    'reservation_id', v_reservation_id,
    'event_id',       v_event_id
  );
END;
$function$;

COMMIT;

-- ── Verificaciones ────────────────────────────────────────────────────────────
-- V1: reason existe
SELECT column_name FROM information_schema.columns
WHERE table_name = 'group_unavailability' AND column_name = 'reason';
-- Esperado: 1 fila

-- V2: exactamente 5 políticas (4 canónicas + admin_all que se conserva)
SELECT policyname, cmd FROM pg_policies
WHERE tablename = 'group_unavailability' ORDER BY policyname;
-- Esperado: group_unavailability_admin_all(ALL), unavail_owner_delete(DELETE),
--           unavail_owner_insert(INSERT), unavail_owner_update(UPDATE),
--           unavail_public_read(SELECT) — y NADA más

-- V3: el candado está en el RPC vigente
SELECT
  routine_definition LIKE '%date_blocked%'             AS candado_bloqueo,
  routine_definition LIKE '%date_taken%'               AS candado_ocupado,
  routine_definition LIKE '%pg_advisory_xact_lock%'    AS anti_carreras,
  routine_definition LIKE '%full_payment_v2%'          AS logica_vigente_intacta
FROM information_schema.routines
WHERE routine_schema = 'public' AND routine_name = 'create_booking_with_event';
-- Esperado: true | true | true | true

-- V4: busy days funciona (como cualquier usuario autenticado)
-- BEGIN;
-- SELECT set_config('request.jwt.claims', json_build_object(
--   'sub', (SELECT id::text FROM profiles LIMIT 1), 'role','authenticated')::text, true);
-- SELECT * FROM get_group_busy_days(
--   (SELECT group_id FROM reservations LIMIT 1), CURRENT_DATE - 30, CURRENT_DATE + 365);
-- ROLLBACK;

SELECT '430_availability_foundations.sql ejecutado ✅' AS status;
