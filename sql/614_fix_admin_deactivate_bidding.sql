-- ============================================================
-- sql/614_fix_admin_deactivate_bidding.sql
-- Segunda mitad del arreglo de sql/613: admin_deactivate_group() para
-- p_type='bidding' solo marcaba bid_orders como 'expired', pero nunca
-- limpiaba groups.bid_amount/bid_ends_at — que es lo único que el
-- Explorador (HomeScreen.tsx) de verdad lee. Sin esto, "desactivar" un
-- Bidding regalado por el admin NO quitaba el destacado real de la app,
-- se quedaba hasta que expirara solo por fecha.
--
-- TESTEADO en BEGIN...ROLLBACK: activar con admin_activate_bidding,
-- confirmar bid_amount>0, desactivar con admin_deactivate_group,
-- confirmar bid_amount=0 y bid_ends_at=NULL. Pasó.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.admin_deactivate_group(p_group_id uuid, p_type text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
BEGIN
  IF NOT (
    (auth.jwt()->>'role') = 'service_role'
    OR EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin')
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;

  IF p_type = 'sponsored' THEN
    UPDATE public.sponsored_groups
    SET is_active = FALSE, ends_at = NOW()
    WHERE group_id = p_group_id AND is_active = TRUE;

  ELSIF p_type = 'recommendation' THEN
    UPDATE public.recommendation_orders
    SET status = 'expired', ends_at = NOW()
    WHERE group_id = p_group_id AND is_free = TRUE AND status = 'paid';

  ELSIF p_type = 'bidding' THEN
    UPDATE public.bid_orders
    SET status = 'expired', ends_at = NOW()
    WHERE group_id = p_group_id AND is_free = TRUE AND status = 'paid';

    UPDATE public.groups
    SET bid_amount = 0, bid_ends_at = NULL
    WHERE id = p_group_id;

  ELSE
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_type');
  END IF;

  RETURN jsonb_build_object('ok', true, 'type', p_type, 'group_id', p_group_id);
END;
$function$;

COMMIT;
