-- ROLLBACK de sql/668 — regresa admin_activate_recommendation a la
-- versión rota (sin price_per_day). NO se recomienda: dejaría "Recomendado"
-- otra vez fallando siempre con error de columna NOT NULL.

CREATE OR REPLACE FUNCTION public.admin_activate_recommendation(p_group_id uuid, p_days integer DEFAULT 7)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_ends_at  TIMESTAMPTZ;
  v_city     TEXT;
  v_state    TEXT;
  v_order_id UUID;
BEGIN
  IF NOT (
    (auth.jwt()->>'role') = 'service_role'
    OR EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin')
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;

  SELECT normalize_state_name(state), city
  INTO   v_state, v_city
  FROM   public.groups
  WHERE  id = p_group_id;

  v_ends_at := CASE WHEN p_days > 0
                 THEN NOW() + (p_days || ' days')::INTERVAL
                 ELSE NULL
               END;

  INSERT INTO public.recommendation_orders
    (group_id, amount, duration_days, status, is_free, city, state, starts_at, ends_at)
  VALUES
    (p_group_id, 0, p_days, 'paid', TRUE, v_city, v_state, NOW(), v_ends_at)
  RETURNING id INTO v_order_id;

  RETURN jsonb_build_object('ok', true, 'type', 'recommendation', 'order_id', v_order_id, 'ends_at', v_ends_at);
END;
$function$;
