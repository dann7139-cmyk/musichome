-- ============================================================
-- sql/598_referral_stats_currency_aware_ROLLBACK.sql
-- JAMÁS correr salvo emergencia deliberada.
-- Revierte sql/598: get_referral_stats() regresa a `earned = rewarded * 100`
-- fijo, sin currency_code/reward_unit en la respuesta.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.get_referral_stats(p_group_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_total    INT;
  v_pending  INT;
  v_rewarded INT;
  v_earned   NUMERIC;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.groups
    WHERE id = p_group_id AND owner_id = auth.uid()
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unauthorized');
  END IF;

  SELECT
    COUNT(*)                                   AS total,
    COUNT(*) FILTER (WHERE NOT reward_given)   AS pending,
    COUNT(*) FILTER (WHERE reward_given)       AS rewarded
  INTO v_total, v_pending, v_rewarded
  FROM public.referral_events
  WHERE group_id = p_group_id;

  v_earned := v_rewarded * 100;

  RETURN jsonb_build_object(
    'ok',       true,
    'total',    v_total,
    'pending',  v_pending,
    'rewarded', v_rewarded,
    'earned',   v_earned
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$function$;

COMMIT;

SELECT '598_referral_stats_currency_aware — REVERTIDO' AS status;
