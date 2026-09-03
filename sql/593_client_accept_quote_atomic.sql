-- ============================================================
-- sql/593_client_accept_quote_atomic.sql
-- ✅ APLICADO A PRODUCCIÓN 2026-09-01 con autorización explícita del
-- usuario. Probado en transacción autorevertible (8 escenarios: fresco,
-- reintento idempotente, dueño ajeno rechazado, regalo+MSI, candado de
-- 3 grupos con error limpio, cotización legacy sin event_id) — 2 bugs
-- reales encontrados y corregidos ANTES de desplegar (cast TEXT→TIME
-- faltante que habría roto TODA aceptación; precedencia de event_id
-- incorrecta que habría desactivado el candado de 3 grupos). App
-- actualizada: ClientQuoteDetailScreen.tsx y QuotePaymentScreen.tsx
-- ahora llaman esta RPC en vez de insert+update por separado.
--
-- HALLAZGO REAL (encontrado 2026-09-01 en el recorrido de los 3 roles,
-- preexistente, NO introducido por sql/585-592).
--
--   ClientQuoteDetailScreen.tsx y QuotePaymentScreen.tsx (modo "cotización
--   nueva") crean la reserva y marcan la cotización como 'accepted' en DOS
--   llamadas separadas, sin transacción. La segunda (`quotes.update`) no
--   revisa si falló. Si la conexión se corta justo entre ambas (común en
--   móvil), la cotización queda sin marcar mientras la reserva ya existe
--   — y como la pantalla vuelve a leer el estado real al reenfocar
--   (useFocusEffect), el cliente vería el botón de pagar disponible OTRA
--   VEZ. Sin UNIQUE en reservations.quote_id, un reintento podría crear
--   una SEGUNDA reserva para la misma cotización (riesgo real: doble
--   cobro, no solo un duplicado visual).
--
-- CORRECCIÓN: una sola función SECURITY DEFINER que hace TODO el trabajo
-- de servidor en una transacción real (una llamada RPC = una transacción
-- de Postgres) — si cualquier paso falla, nada se guarda a medias.
--   - Verifica dueño real (auth.uid() = quotes.client_id) — cierra de
--     paso el mismo tipo de hueco que sql/592 cerró en
--     create_booking_with_event (aquí NUNCA existió, se construye bien
--     desde el inicio).
--   - IDEMPOTENTE: si la cotización YA está 'accepted' y ya tiene una
--     reserva real, regresa esa misma reserva en vez de crear otra — un
--     reintento después de una falla de red ya no puede duplicar nada.
--   - Reutiliza resolve_shared_event_id() (sql/585) tal cual — mismo
--     comportamiento de "reusar evento existente o crear uno nuevo",
--     cero lógica nueva duplicada.
--   - El total se toma de quotes.total_amount (el dato real del
--     servidor) — igual que hacían ambas pantallas, nunca un monto que
--     mande el cliente.
--   - Los errores de candados reales (date_blocked, daily_event_limit,
--     time_overlap, event_group_limit_reached) se atrapan DENTRO de la
--     función (mismo patrón que create_booking_with_event) y se
--     regresan como jsonb limpio {ok:false,error:'date_blocked'} — más
--     robusto que dejar que la app interprete texto crudo de Postgres.
--     La app solo necesita leer `error` del jsonb en vez de
--     `resErr.message` — mismos códigos, mismos textos ya traducidos.
--
-- QUÉ NO CAMBIA: la resolución de evento (Alert.alert de "¿es tu evento
-- del [fecha]?") sigue siendo 100% del lado de la app — es UI, no puede
-- vivir en SQL. La app solo le manda a esta función el event_id YA
-- decidido (o NULL) — mismo patrón que ya usa create_booking_with_event.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.client_accept_quote(
  p_quote_id   UUID,
  p_event_id   UUID DEFAULT NULL,
  p_msi_months INT  DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE
  v_quote RECORD;
  v_address TEXT;
  v_event_id UUID;
  v_event_time TIME;
  v_reservation_id UUID;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_authenticated');
  END IF;

  SELECT * INTO v_quote FROM public.quotes WHERE id = p_quote_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'quote_not_found');
  END IF;
  IF v_quote.client_id <> auth.uid() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_owner');
  END IF;

  -- Idempotencia: exactamente el escenario del hallazgo — un reintento
  -- tras una falla parcial anterior no debe crear una segunda reserva.
  IF v_quote.status = 'accepted' THEN
    SELECT id INTO v_reservation_id FROM public.reservations WHERE quote_id = p_quote_id LIMIT 1;
    IF v_reservation_id IS NOT NULL THEN
      RETURN jsonb_build_object(
        'ok', true, 'reservation_id', v_reservation_id,
        'event_id', v_quote.event_id, 'already_accepted', true
      );
    END IF;
    -- quote dice 'accepted' pero no hay reserva real (rastro de una falla
    -- vieja, antes de este archivo) — se deja continuar abajo para
    -- autocorregir en vez de dejar al cliente bloqueado para siempre.
  END IF;

  v_address := NULLIF(TRIM(BOTH ', ' FROM
    CONCAT_WS(', ', v_quote.event_address, v_quote.event_municipio, v_quote.event_estado)
  ), '');
  -- quotes.event_time es TEXT; reservations.event_time es TIME — hallazgo
  -- de la prueba (2026-09-01): sin este cast explícito, el INSERT de abajo
  -- fallaba con "column event_time is of type time without time zone but
  -- expression is of type text" en TODA aceptación, sin excepción.
  v_event_time := COALESCE(v_quote.event_time, '20:00')::TIME;

  -- HALLAZGO DE LA PRUEBA: si la cotización YA tiene su propio event_id
  -- (caso normal desde sql/585 — toda cotización nueva lo trae desde que
  -- se crea), ese es el dato autoritativo — se usa SIEMPRE, ignorando
  -- p_event_id. Sin esto, aceptar una cotización que ya pertenecía a un
  -- evento de 2-3 proveedores creaba un evento NUEVO sin relación, y de
  -- paso el candado real de "máximo 3 grupos" nunca llegaba a revisar el
  -- evento correcto. p_event_id solo importa para cotizaciones viejas sin
  -- event_id (de antes de sql/585) — mismo patrón que ya usa
  -- getInclusionLabel/presetEventId del lado de la app.
  -- Mismo patrón defensivo que create_booking_with_event (sql/585): las
  -- excepciones de resolve_shared_event_id se traducen a códigos jsonb
  -- limpios en vez de dejar que la app tenga que interpretar texto crudo
  -- de Postgres — más robusto, mismo vocabulario de error que ya conoce
  -- la app (date_blocked, event_group_limit_reached, etc.).
  BEGIN
    v_event_id := public.resolve_shared_event_id(
      auth.uid(), COALESCE(v_quote.event_id, p_event_id), v_quote.event_date, v_event_time, COALESCE(v_address, '')
    );
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'event_group_limit_reached%' THEN
      RETURN jsonb_build_object('ok', false, 'error', 'event_group_limit_reached');
    ELSIF SQLERRM LIKE 'event_not_owned_by_client%' THEN
      RETURN jsonb_build_object('ok', false, 'error', 'event_not_owned_by_client');
    ELSIF SQLERRM LIKE 'event_not_found%' THEN
      RETURN jsonb_build_object('ok', false, 'error', 'event_not_found');
    ELSE
      RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
    END IF;
  END;

  BEGIN
    INSERT INTO public.reservations (
      event_id, client_id, group_id, event_date, event_time, address,
      total_price, status, quote_id, notes, msi_months,
      is_gift, gift_recipient_name, gift_recipient_contact, gift_message
    ) VALUES (
      v_event_id, auth.uid(), v_quote.group_id, v_quote.event_date, v_event_time, v_address,
      v_quote.total_amount, 'accepted', v_quote.id, v_quote.comments,
      CASE WHEN COALESCE(p_msi_months, 1) > 1 THEN p_msi_months ELSE NULL END,
      v_quote.is_gift, v_quote.gift_recipient_name, v_quote.gift_recipient_contact, v_quote.gift_message
    ) RETURNING id INTO v_reservation_id;
  EXCEPTION WHEN OTHERS THEN
    -- Candados reales de sql/431/556 (trg_enforce_max_groups_per_event,
    -- date_blocked, etc.) — mismos códigos que ya traduce la app.
    IF SQLERRM LIKE '%date_blocked%' OR SQLERRM LIKE '%date_taken%' THEN
      RETURN jsonb_build_object('ok', false, 'error', 'date_blocked');
    ELSIF SQLERRM LIKE '%daily_event_limit%' THEN
      RETURN jsonb_build_object('ok', false, 'error', 'daily_event_limit');
    ELSIF SQLERRM LIKE '%time_overlap%' THEN
      RETURN jsonb_build_object('ok', false, 'error', 'time_overlap');
    ELSIF SQLERRM LIKE '%event_group_limit_reached%' THEN
      RETURN jsonb_build_object('ok', false, 'error', 'event_group_limit_reached');
    ELSE
      RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
    END IF;
  END;

  UPDATE public.quotes SET status = 'accepted' WHERE id = p_quote_id;

  RETURN jsonb_build_object('ok', true, 'reservation_id', v_reservation_id, 'event_id', v_event_id);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.client_accept_quote(UUID, UUID, INT) TO authenticated;

COMMIT;

SELECT '593_client_accept_quote_atomic — APLICADO A PRODUCCIÓN 2026-09-01' AS status;
