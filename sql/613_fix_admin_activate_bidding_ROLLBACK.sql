-- ROLLBACK de sql/613_fix_admin_activate_bidding.sql
-- Solo correr en emergencia deliberada. Regresa admin_activate_bidding
-- a la versión rota (nunca insertaba user_id, nunca actualizaba
-- groups.bid_amount/bid_ends_at) — no hay razón real para querer esto,
-- se deja solo por consistencia con el resto de la disciplina de sql/.

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
    (group_id, amount, duration_days, status, is_free, state, starts_at, ends_at)
  VALUES
    (p_group_id, p_bid_amount, p_days, 'paid', TRUE, v_state, NOW(), v_ends_at)
  RETURNING id INTO v_order_id;

  RETURN jsonb_build_object('ok', true, 'type', 'bidding', 'order_id', v_order_id, 'ends_at', v_ends_at);
END;
$function$;

COMMIT;
