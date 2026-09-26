-- ═══════════════════════════════════════════════════════════════════════════
-- ROLLBACK de sql/685 — SOLO en caso de reversión deliberada
-- ═══════════════════════════════════════════════════════════════════════════
--
-- Restaura client_get_my_events() EXACTAMENTE a la versión que estaba viva en
-- producción antes de sql/685 (capturada vía pg_get_functiondef contra
-- sqgzyipqpewzbnfrtdqk el 2026-09-25, antes de aplicar el parche) y elimina la
-- RPC nueva.
--
-- NUNCA BORRAR events.updated_at, ni en el bloque destructivo de abajo (por eso
-- no aparece ahí): esa columna no es "nueva funcionalidad", es la que el trigger
-- set_updated_at_events esperaba desde siempre. Borrarla vuelve a romper TODO
-- UPDATE sobre public.events con 42703 'record "new" has no field "updated_at"'.
--
-- NO BORRA LAS 8 COLUMNAS NUEVAS, a propósito:
--   · Dejarlas es inofensivo — son nullable, sin DEFAULT, y ninguna función ni
--     política existente las lee después de este rollback.
--   · Borrarlas DESTRUYE datos que el cliente ya escribió (nombre del evento,
--     presupuesto, invitados...) y no se pueden recuperar.
-- Si de verdad se quieren quitar, está abajo el bloque comentado. Leer la
-- advertencia antes de descomentarlo.
--
-- Si también se aplicó sql/686, correr PRIMERO 686_ROLLBACK: la versión vieja
-- de client_get_my_events() que se restaura aquí ya no manda provider_limit, y
-- eventBuilder.ts caería a su constante local de respaldo (20) mientras los
-- candados de la base seguirían en 20 — coherente, pero es más limpio revertir
-- el límite primero.
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

DROP FUNCTION IF EXISTS public.client_update_event_details(UUID, TEXT, TEXT, INTEGER, NUMERIC, TEXT, TEXT, TEXT, TEXT);

CREATE OR REPLACE FUNCTION public.client_get_my_events()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_result jsonb;
BEGIN
  IF auth.uid() IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'not_authenticated'); END IF;

  SELECT jsonb_build_object('ok', true, 'items', COALESCE(jsonb_agg(x.item ORDER BY x.event_date DESC), '[]'::jsonb))
  INTO v_result
  FROM (
    SELECT e.event_date, jsonb_build_object(
      'event_id', e.id, 'event_date', e.event_date, 'event_time', e.event_time, 'address', e.address,
      'providers', (
        SELECT COALESCE(jsonb_agg(x2.item ORDER BY x2.created_at), '[]'::jsonb) FROM (
          SELECT r.created_at, jsonb_build_object(
            'reservation_id', r.id, 'group_id', r.group_id, 'group_name', g.name,
            'status', r.status, 'payment_status', r.payment_status, 'total_price', r.total_price,
            'currency_code', r.currency_code
          ) AS item
          FROM public.reservations r JOIN public.groups g ON g.id = r.group_id
          WHERE r.event_id = e.id
          UNION ALL
          SELECT q.created_at, jsonb_build_object(
            'reservation_id', 'quote-' || q.id, 'group_id', q.group_id, 'group_name', g2.name,
            'status', q.status, 'payment_status', NULL, 'total_price', q.total_amount,
            'currency_code', (SELECT c.currency_code FROM public.countries c WHERE c.id = g2.country_id)
          ) AS item
          FROM public.quotes q JOIN public.groups g2 ON g2.id = q.group_id
          WHERE q.event_id = e.id AND q.status IN ('pending', 'quoted')
        ) x2
      )
    ) AS item
    FROM public.events e
    WHERE e.client_id = auth.uid()
  ) x;

  RETURN v_result;
END;
$function$;

COMMIT;

-- ═══════════════════════════════════════════════════════════════════════════
-- BLOQUE DESTRUCTIVO — NO descomentar salvo que se acepte perder datos reales
-- ═══════════════════════════════════════════════════════════════════════════
-- Esto BORRA permanentemente lo que los clientes hayan capturado en esos 8
-- campos. Revisar antes qué se perdería:
--   SELECT count(*) FROM public.events
--    WHERE name IS NOT NULL OR event_type IS NOT NULL OR guest_count IS NOT NULL
--       OR budget_max IS NOT NULL OR end_time IS NOT NULL
--       OR event_municipio IS NOT NULL OR event_estado IS NOT NULL;
--
-- BEGIN;
-- ALTER TABLE public.events
--   DROP CONSTRAINT IF EXISTS events_event_type_check,
--   DROP CONSTRAINT IF EXISTS events_guest_count_check,
--   DROP CONSTRAINT IF EXISTS events_budget_max_check,
--   DROP CONSTRAINT IF EXISTS events_budget_currency_check;
-- ALTER TABLE public.events
--   DROP COLUMN IF EXISTS name,
--   DROP COLUMN IF EXISTS event_type,
--   DROP COLUMN IF EXISTS guest_count,
--   DROP COLUMN IF EXISTS budget_max,
--   DROP COLUMN IF EXISTS budget_currency,
--   DROP COLUMN IF EXISTS end_time,
--   DROP COLUMN IF EXISTS event_municipio,
--   DROP COLUMN IF EXISTS event_estado;
-- COMMIT;
