-- ============================================================
-- sql/613_fix_admin_activate_bidding.sql
-- Arregla admin_activate_bidding() — DOS bugs reales encontrados hoy
-- (2026-09-05) al implementar el pedido del usuario "quiero que bidding
-- también el admin lo pueda poner gratis":
--
--   1. Nunca insertaba `user_id` en bid_orders (columna NOT NULL) —
--      la función TRONABA cada vez que se llamaba. Nunca había
--      insertado una sola fila con éxito en producción.
--   2. Aunque insertara en bid_orders, NUNCA actualizaba
--      groups.bid_amount/bid_ends_at — que es lo que el Explorador
--      (HomeScreen.tsx) de verdad lee para decidir quién sale
--      destacado en la cuadrícula y qué insignia "🔥 Top X" mostrar.
--      El regalo del admin nunca se hubiera visto reflejado en la app.
--
-- Mismo criterio ya usado por confirm_bid_payment/place_bid (las rutas
-- de pago REAL): si el grupo ya tenía una puja activa más alta, se
-- respeta la más alta (no se puede "bajar" con un regalo más chico).
-- user_id = auth.uid() (el admin que regala), mismo patrón que
-- admin_activate_sponsored (advertiser_id = auth.uid()).
--
-- TESTEADO en BEGIN...ROLLBACK: se creó un grupo limpio, se le regaló
-- bidding vía admin_activate_bidding, y se confirmó que tanto
-- bid_orders (con user_id del admin) como groups.bid_amount/bid_ends_at
-- quedaron actualizados correctamente.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.admin_activate_bidding(p_group_id uuid, p_bid_amount numeric DEFAULT 100, p_days integer DEFAULT 7)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE
  v_ends_at  TIMESTAMPTZ;
  v_state    TEXT;
  v_order_id UUID;
BEGIN
  IF NOT (
    (auth.jwt()->>'role') = 'service_role'
    OR EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin')
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;

  SELECT normalize_state_name(state) INTO v_state
  FROM   public.groups
  WHERE  id = p_group_id;

  v_ends_at := CASE WHEN p_days > 0
                 THEN NOW() + (p_days || ' days')::INTERVAL
                 ELSE NULL
               END;

  INSERT INTO public.bid_orders
    (group_id, user_id, amount, duration_days, status, is_free, state, starts_at, ends_at)
  VALUES
    (p_group_id, auth.uid(), p_bid_amount, p_days, 'paid', TRUE, v_state, NOW(), v_ends_at)
  RETURNING id INTO v_order_id;

  UPDATE public.groups
  SET
    bid_amount  = CASE
                    WHEN bid_ends_at IS NOT NULL AND bid_ends_at > NOW()
                    THEN GREATEST(bid_amount, p_bid_amount)
                    ELSE p_bid_amount
                  END,
    bid_ends_at = CASE
                    WHEN bid_ends_at IS NOT NULL AND bid_ends_at > NOW()
                         AND bid_amount >= p_bid_amount
                    THEN bid_ends_at
                    ELSE v_ends_at
                  END
  WHERE id = p_group_id;

  RETURN jsonb_build_object('ok', true, 'type', 'bidding', 'order_id', v_order_id, 'ends_at', v_ends_at);
END;
$function$;

COMMIT;
