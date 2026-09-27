-- ═══════════════════════════════════════════════════════════════════════════
-- sql/692 — Fase 2 "Mi Evento": RPC de lectura del dashboard
-- ═══════════════════════════════════════════════════════════════════════════
--
-- ADITIVO Y DE SOLO LECTURA. Una función nueva. NO modifica ninguna tabla,
-- ninguna función existente, ningún dato y ninguna política.
--
-- POR QUÉ UNA FUNCIÓN NUEVA Y NO EXTENDER client_get_my_events():
--   · client_get_my_events() la consumen ya 2 pantallas (eventBuilder.ts y el
--     flujo de "¿es para tu evento?"). Meterle totales por moneda y el género de
--     cada proveedor la vuelve más pesada para todos sus llamadores.
--   · El dashboard necesita UN evento, no la lista.
--   · Separarlas permite cambiar el dashboard sin arriesgar el "carrito".
--
-- ═══════════════════════════════════════════════════════════════════════════
-- FÓRMULA FINANCIERA — estados REALES, no condiciones vagas
-- ═══════════════════════════════════════════════════════════════════════════
-- Valores reales de reservations.status (CHECK reservations_status_check):
--   pending, in_progress, rejected, pending_payment,
--   pending_provider_confirmation, pending_group_confirmation, accepted,
--   confirmed, completed, cancelled, expired
--
-- CONTRATADO = los que representan una contratación viva o ya cumplida:
--   pending, pending_payment, pending_provider_confirmation,
--   pending_group_confirmation, accepted, confirmed, in_progress, completed
-- EXCLUIDOS explícitamente: rejected, cancelled, expired — ya no representan
-- nada contratado.
--
-- NOTA sobre estados_que_ocupan(): NO se usa aquí a propósito. Esa función
-- existe para el candado de "cuántos proveedores ocupan un evento" y EXCLUYE
-- 'completed' (un evento terminado ya no ocupa lugar) e incluye 'live', que no
-- existe en el CHECK de reservations.status. Para dinero, un evento completado
-- SÍ está contratado y SÍ está pagado, así que la lista de arriba es distinta a
-- propósito.
--
-- Valores reales de payment_status (CHECK chk_payment_status_v4):
--   unpaid, pending, pending_payment, deposit_pending, deposit_paid,
--   remaining_pending, fully_paid, paid, payment_failed, refunded, cancelled,
--   paid_blocked
--
-- PAGADO = dinero realmente entrado, por fila:
--   payment_status IN ('paid','fully_paid')  -> total_price
--   payment_status IN ('deposit_paid','remaining_pending')
--                                            -> COALESCE(deposit_paid, deposit_amount, 0)
--   cualquier otro                           -> 0
--
-- Por que 'remaining_pending' entra ahi: lo escribe la edge function
-- charge-remaining cuando el evento ya termino y el cobro del 50% restante
-- fallo. En ese punto el anticipo del 50% YA se cobro (esta en deposit_amount,
-- que escribe set_booking_expiration) y status queda en 'completed', o sea
-- SI cuenta como contratado. Tratarlo como 0 le diria al cliente que debe el
-- total cuando solo debe la mitad. Nota: isPaid() de src/utils/calculations.ts
-- tampoco lo incluye, pero esa funcion responde "¿esta pagada?" (booleano para
-- habilitar UI), no "¿cuanto dinero entro?".
--
-- 'deposit_paid' (columna numerica) hoy no la escribe NADIE — ni una funcion de
-- BD, ni la app, ni una edge function. La que se llena de verdad es
-- deposit_amount, via set_booking_expiration(p_reservation_id, p_deposit_amount).
-- El COALESCE respeta deposit_paid por si algun dia se usa, y cae a
-- deposit_amount, que es la real. Si ninguna tiene monto, reporta 0: preferimos
-- quedarnos cortos en "pagado" antes que decirle al cliente que pago mas de lo
-- que pago.
--
-- REEMBOLSOS PARCIALES (verificado contra la BD real 2026-09-27): no pueden
-- ensuciar esta cuenta. 'refunded' solo lo escribe process_refund_reversal, que
-- RECHAZA explicitamente los parciales ('partial_refund_not_supported' cuando
-- p_refund_amount <> total_price), asi que 'refunded' siempre significa que
-- regreso el total -> pagado 0 es el neto correcto. Los reembolsos por politica
-- de cancelacion (settle_cancellation / settle_group_cancellation) NO tocan
-- payment_status: ponen status='cancelled', y como los totales filtran
-- contratado Y pagado con la MISMA lista de estados, esas filas aportan 0 a las
-- dos columnas y solo aparecen como historial. refund_type='excess' existe en el
-- CHECK pero ninguna funcion lo produce todavia.
-- Un anticipo NO convierte la reserva entera en pagada: cuenta solo el monto.
-- 'refunded' y 'cancelled' -> 0 (el dinero regresó).
-- 'paid_blocked' -> 0 a propósito: confirm_reservation_payment_v2 lo pone junto
-- con payment_receipts.money_state='blocked_refund_pending', o sea el dinero
-- entró pero YA tiene reembolso íntegro en cola. Mismo criterio que isPaid() de
-- src/utils/calculations.ts, que tampoco lo cuenta como pagado.
--
-- PENDIENTE = contratado - pagado, con piso en 0 por moneda (un anticipo mal
-- capturado que superara el total no debe producir un negativo).
--
-- MONEDAS: NUNCA se suman. Se agrupa por currency_code de cada reserva
-- (COALESCE al código del país del grupo, y 'MXN' como último recurso, igual
-- que hace create_booking_with_event). Si el evento tuviera dos monedas, salen
-- dos bloques independientes.
--
-- events.total_price NO se lee ni se escribe: no es fuente financiera.
-- NO se incluyen regalos, propinas, horas extra ni reembolsos parciales: viven
-- en otras tablas con su propio ciclo y moneda. El dashboard dice explícitamente
-- que los totales son "de las reservas".
--
-- Orden: correr DESPUÉS de sql/691. Probar con sql/693 (autorevertible).
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

CREATE OR REPLACE FUNCTION public.client_get_event_dashboard(p_event_id UUID)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid    UUID;
  v_event  RECORD;
  v_result JSONB;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_authenticated');
  END IF;

  SELECT * INTO v_event FROM public.events WHERE id = p_event_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'event_not_found');
  END IF;
  IF v_event.client_id <> v_uid THEN
    RETURN jsonb_build_object('ok', false, 'error', 'event_not_owned_by_client');
  END IF;

  WITH
  -- ── Reservas del evento, con su moneda resuelta y su aporte a cada total ──
  res AS (
    SELECT
      r.id,
      r.group_id,
      g.name  AS group_name,
      g.genre AS group_genre,
      public.genre_category_key(g.genre) AS category_key,
      r.status,
      r.payment_status,
      r.total_price,
      r.event_date,
      r.event_time,
      r.created_at,
      COALESCE(r.currency_code, c.currency_code, 'MXN') AS currency_code,
      (r.status = ANY (ARRAY['pending','pending_payment','pending_provider_confirmation',
                             'pending_group_confirmation','accepted','confirmed',
                             'in_progress','completed'])) AS cuenta_contratado,
      CASE
        WHEN r.payment_status IN ('paid','fully_paid') THEN COALESCE(r.total_price, 0)
        -- 'remaining_pending' cuenta IGUAL que 'deposit_paid': el anticipo ya
        -- entro. Lo escribe la edge function charge-remaining cuando el evento
        -- termino y el cobro del 50% final fallo (tarjeta declinada o sin
        -- metodo guardado), dejando status='completed'. Sin esta rama el
        -- tablero le diria al cliente que debe el 100% cuando ya pago la mitad.
        WHEN r.payment_status IN ('deposit_paid','remaining_pending')
                                                      THEN COALESCE(r.deposit_paid, r.deposit_amount, 0)
        ELSE 0
      END AS monto_pagado
    FROM public.reservations r
    JOIN public.groups g       ON g.id = r.group_id
    LEFT JOIN public.countries c ON c.id = g.country_id
    WHERE r.event_id = p_event_id
  ),
  -- ── Cotizaciones aún sin respuesta/sin aceptar (no son dinero contratado) ──
  quo AS (
    SELECT
      q.id,
      q.group_id,
      g.name  AS group_name,
      g.genre AS group_genre,
      public.genre_category_key(g.genre) AS category_key,
      q.status,
      q.total_amount,
      q.event_date,
      q.event_time,
      q.created_at,
      COALESCE(c.currency_code, 'MXN') AS currency_code
    FROM public.quotes q
    JOIN public.groups g       ON g.id = q.group_id
    LEFT JOIN public.countries c ON c.id = g.country_id
    WHERE q.event_id = p_event_id
      AND q.status IN ('pending', 'quoted')
      -- Una cotización cuya reserva ya existe no se repite como pendiente.
      AND NOT EXISTS (SELECT 1 FROM public.reservations r2 WHERE r2.quote_id = q.id)
  ),
  -- ── Totales POR MONEDA (jamás sumados entre sí) ───────────────────────────
  totales AS (
    SELECT
      currency_code,
      SUM(CASE WHEN cuenta_contratado THEN COALESCE(total_price, 0) ELSE 0 END) AS contratado,
      SUM(CASE WHEN cuenta_contratado THEN monto_pagado            ELSE 0 END) AS pagado,
      COUNT(*) FILTER (WHERE cuenta_contratado)                                AS reservas_activas
    FROM res
    GROUP BY currency_code
  )
  SELECT jsonb_build_object(
    'ok', true,
    'event', jsonb_build_object(
      'event_id',        v_event.id,
      'name',            v_event.name,
      'event_type',      v_event.event_type,
      'event_date',      v_event.event_date,
      'event_time',      v_event.event_time,
      'end_time',        v_event.end_time,
      'address',         v_event.address,
      'event_municipio', v_event.event_municipio,
      'event_estado',    v_event.event_estado,
      'guest_count',     v_event.guest_count,
      'budget_max',      v_event.budget_max,
      'budget_currency', v_event.budget_currency,
      'status',          v_event.status
    ),
    'provider_limit', public.max_providers_per_event(),
    -- Proveedores DISTINTOS que ocupan lugar, con el mismo criterio que el
    -- candado de la base (estados_que_ocupan), para que el conteo que ve el
    -- cliente coincida con el que aplica el servidor al aceptar otro proveedor.
    'provider_count', (
      SELECT COUNT(DISTINCT group_id) FROM public.reservations
      WHERE event_id = p_event_id AND status = ANY (public.estados_que_ocupan())
    ),
    -- Un renglón por servicio: reservas primero, luego cotizaciones pendientes.
    'services', COALESCE((
      SELECT jsonb_agg(x.item ORDER BY x.orden, x.created_at)
      FROM (
        SELECT 1 AS orden, r.created_at, jsonb_build_object(
          'kind',           'reservation',
          'id',             r.id,
          'group_id',       r.group_id,
          'group_name',     r.group_name,
          'group_genre',    r.group_genre,
          'category_key',   r.category_key,
          'status',         r.status,
          'payment_status', r.payment_status,
          'total_price',    r.total_price,
          'paid_amount',    r.monto_pagado,
          'currency_code',  r.currency_code,
          'counts_as_contracted', r.cuenta_contratado,
          'event_date',     r.event_date,
          'event_time',     r.event_time
        ) AS item FROM res r
        UNION ALL
        SELECT 2 AS orden, q.created_at, jsonb_build_object(
          'kind',           'quote',
          'id',             q.id,
          'group_id',       q.group_id,
          'group_name',     q.group_name,
          'group_genre',    q.group_genre,
          'category_key',   q.category_key,
          'status',         q.status,
          'payment_status', NULL,
          'total_price',    q.total_amount,
          'paid_amount',    0,
          'currency_code',  q.currency_code,
          'counts_as_contracted', false,
          'event_date',     q.event_date,
          'event_time',     q.event_time
        ) AS item FROM quo q
      ) x
    ), '[]'::jsonb),
    -- Un bloque por moneda. budget_* solo se rellena en la moneda del
    -- presupuesto declarado; en las demás va NULL (no se convierte nada).
    'totals_by_currency', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'currency_code',     t.currency_code,
        'contracted',        t.contratado,
        'paid',              t.pagado,
        'pending',           GREATEST(t.contratado - t.pagado, 0),
        'active_count',      t.reservas_activas,
        'budget_max',        CASE WHEN v_event.budget_currency = t.currency_code THEN v_event.budget_max END,
        'budget_remaining',  CASE WHEN v_event.budget_currency = t.currency_code AND v_event.budget_max IS NOT NULL
                                  THEN v_event.budget_max - t.contratado END,
        'over_budget',       CASE WHEN v_event.budget_currency = t.currency_code AND v_event.budget_max IS NOT NULL
                                  THEN (t.contratado > v_event.budget_max) END
      ) ORDER BY t.currency_code)
      FROM totales t
    ), '[]'::jsonb),
    -- Presupuesto declarado, aunque todavía no haya ninguna reserva en esa
    -- moneda (si no, un evento nuevo con presupuesto no mostraría nada).
    'budget', CASE WHEN v_event.budget_max IS NULL THEN NULL ELSE jsonb_build_object(
      'budget_max',      v_event.budget_max,
      'currency_code',   v_event.budget_currency,
      'contracted',      COALESCE((SELECT t.contratado FROM totales t WHERE t.currency_code = v_event.budget_currency), 0),
      'remaining',       v_event.budget_max - COALESCE((SELECT t.contratado FROM totales t WHERE t.currency_code = v_event.budget_currency), 0),
      'over_budget',     COALESCE((SELECT t.contratado FROM totales t WHERE t.currency_code = v_event.budget_currency), 0) > v_event.budget_max
    ) END
  ) INTO v_result;

  RETURN v_result;
END;
$function$;

-- Lección de sql/591: Postgres otorga EXECUTE a PUBLIC por default. Esta RPC
-- verifica dueño internamente (auth.uid() vs events.client_id), pero se deja el
-- REVOKE explícito de todos modos.
REVOKE EXECUTE ON FUNCTION public.client_get_event_dashboard(UUID) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.client_get_event_dashboard(UUID) TO authenticated, service_role;

COMMENT ON FUNCTION public.client_get_event_dashboard(UUID) IS
  'sql/692 (Fase 2, "Mi Evento") — SOLO LECTURA. Devuelve el evento, sus servicios (reservas + cotizaciones pendientes, con género y categoría), el conteo de proveedores frente al límite, y totales POR MONEDA (contratado/pagado/pendiente). Nunca suma monedas distintas. Un anticipo cuenta solo por su monto real. No lee ni escribe events.total_price. No incluye regalos, propinas ni horas extra.';

NOTIFY pgrst, 'reload schema';

COMMIT;
