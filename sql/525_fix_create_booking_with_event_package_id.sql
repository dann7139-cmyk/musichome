-- ============================================================
-- sql/525_fix_create_booking_with_event_package_id.sql
--
-- PROBLEMA: create_booking_with_event() hace
--   INSERT INTO reservations (..., package_id, ...) VALUES (..., p_package_id, ...)
-- pero reservations.package_id NO EXISTE — la tabla `packages` fue
-- erradicada (~2026-07-02, ver memoria de proyecto + sql/445, que corrigió
-- un rezago equivalente en mark_abandoned_reservations). Esta RPC quedó
-- como otro rezago de esa limpieza: cualquier ejecución real del INSERT
-- lanza `column "package_id" of relation "reservations" does not exist`
-- (SQLSTATE 42703).
--
-- ALCANCE MÍNIMO AUTORIZADO (2026-07-30):
--   • Se conserva p_package_id en la firma, EXACTAMENTE en su posición
--     actual (3er parámetro, UUID, sin default) — no se cambia el orden
--     ni los tipos de ningún parámetro. No se toca BookingScreen.tsx.
--   • Se elimina ÚNICAMENTE `package_id` de la lista de columnas del
--     INSERT INTO reservations y `p_package_id` de la posición
--     correspondiente en VALUES.
--   • Nada más cambia: el candado de disponibilidad (advisory lock +
--     date_blocked), flow_version, el INSERT a events, RAISE NOTICE, y
--     el jsonb de retorno quedan byte-idénticos.
--   • No se tocan tablas, datos, triggers, constraints ni otros RPC.
--   • No se reactiva ni conecta BookingScreen a ninguna navegación —
--     confirmado en el pre-reporte: ningún navigate('Booking', ...) real
--     existe hoy en el código; el impacto actual de este bug es
--     dormido, no un incidente activo.
--   • No se hace ninguna otra limpieza relacionada con `packages`.
--
-- Firma confirmada IDÉNTICA a la versión actual en producción (verificado
-- vía pg_get_function_identity_arguments antes de escribir este archivo):
--   p_client_id uuid, p_group_id uuid, p_package_id uuid, p_event_date date,
--   p_event_time time without time zone, p_address text, p_total_price numeric,
--   p_notes text, p_break_type text, p_base_price numeric,
--   p_installment_plan text, p_installment_months integer,
--   p_installment_monthly_amount numeric, p_payment_mode text
--
-- Rollback: sql/525_fix_create_booking_with_event_package_id_ROLLBACK.sql
-- — restaura la definición actual byte a byte (capturada vía
-- pg_get_functiondef en producción antes de este cambio).
--
-- EN REVISIÓN — no ejecutado.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.create_booking_with_event(
  p_client_id                   UUID,
  p_group_id                    UUID,
  p_package_id                  UUID,   -- [525] conservado SOLO por compatibilidad
                                         -- con la llamada existente de
                                         -- BookingScreen.tsx — ya NO se
                                         -- escribe en ninguna columna
                                         -- (reservations.package_id no existe).
  p_event_date                  DATE,
  p_event_time                  TIME,
  p_address                     TEXT,
  p_total_price                 NUMERIC,
  p_notes                       TEXT    DEFAULT NULL,
  p_break_type                  TEXT    DEFAULT NULL,
  p_base_price                  NUMERIC DEFAULT NULL,
  p_installment_plan            TEXT    DEFAULT NULL,
  p_installment_months          INT     DEFAULT NULL,
  p_installment_monthly_amount  NUMERIC DEFAULT NULL,
  p_payment_mode                TEXT    DEFAULT 'full'
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE
  v_event_id       UUID;
  v_reservation_id UUID;
  v_flow_version   TEXT;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext(p_group_id::text || p_event_date::text));

  IF EXISTS (
    SELECT 1 FROM group_unavailability
    WHERE group_id = p_group_id AND date = p_event_date
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'date_blocked');
  END IF;

  v_flow_version := CASE
    WHEN p_payment_mode = 'full' THEN 'full_payment_v2'
    ELSE 'legacy'
  END;
  INSERT INTO public.events (client_id, event_date, event_time, address, status)
  VALUES (p_client_id, p_event_date, p_event_time, p_address, 'active')
  RETURNING id INTO v_event_id;
  -- [525] `package_id` removido de esta lista de columnas — la tabla
  -- `packages` y esta FK fueron erradicadas, la columna no existe.
  INSERT INTO public.reservations (
    event_id, group_id, client_id,
    event_date, event_time, address, notes, break_type,
    total_price, base_price, status,
    payment_mode, flow_version,
    installment_plan, installment_months, installment_monthly_amount
  )
  VALUES (
    v_event_id, p_group_id, p_client_id,
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

-- ── VERIFICACIÓN ──────────────────────────────────────────────────
-- Esperado: firma idéntica a la de antes del parche (misma cuenta y
-- orden de parámetros), y el cuerpo ya NO referencia package_id como
-- columna del INSERT (aunque el parámetro p_package_id sigue existiendo
-- en la firma, por eso NO se puede usar un ILIKE '%package_id%' simple
-- — se verifica la ausencia específica del patrón de columna/INSERT).
SELECT
  pg_get_function_identity_arguments(oid) AS firma,
  (pg_get_functiondef(oid) ILIKE '%event_id, group_id, client_id,%')      AS insert_sin_package_id,
  (pg_get_functiondef(oid) NOT ILIKE '%event_id, group_id, package_id, client_id,%') AS ya_no_columna_vieja,
  (pg_get_functiondef(oid) ILIKE '%p_package_id%')                        AS conserva_parametro_firma
FROM pg_proc
WHERE pronamespace = 'public'::regnamespace AND proname = 'create_booking_with_event';
-- Esperado: firma igual a la documentada arriba; las 3 columnas booleanas en true.

SELECT '525_fix_create_booking_with_event_package_id ejecutado ✅' AS status;
