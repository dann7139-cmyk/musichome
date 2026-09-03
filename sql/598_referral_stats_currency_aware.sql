-- ============================================================
-- sql/598_referral_stats_currency_aware.sql
-- ✅ APLICADO A PRODUCCIÓN 2026-09-02.
--
-- Continuación de sql/597: get_referral_stats() todavía calculaba
-- "earned" como `v_rewarded * 100` fijo, sin importar la moneda del
-- grupo — con sql/597 ya aplicado, un grupo de EE.UU. con 1 referido
-- premiado mostraría "$100" en su tarjeta cuando en realidad recibió
-- $5 USD. Mismo criterio de moneda que sql/597 (debe coincidir con
-- trg_referral_reward_on_payment). Ahora también devuelve
-- 'currency_code' y 'reward_unit' para que la UI etiquete bien el monto.
--
-- Probado en transacción autorevertible: grupo US con 1 rewarded + 1
-- pending → earned=5, currency_code='USD' (no 100/MXN). 0 residuo
-- verificado. Aplicado para real después.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.get_referral_stats(p_group_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_total       INT;
  v_pending     INT;
  v_rewarded    INT;
  v_earned      NUMERIC;
  v_currency    TEXT := 'MXN';
  v_reward_unit NUMERIC := 100;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.groups
    WHERE id = p_group_id AND owner_id = auth.uid()
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unauthorized');
  END IF;

  -- Moneda real del grupo — DEBE coincidir con trg_referral_reward_on_payment (sql/597)
  SELECT COALESCE(c.currency_code, 'MXN') INTO v_currency
  FROM public.groups g
  LEFT JOIN public.countries c ON c.id = g.country_id
  WHERE g.id = p_group_id;

  IF v_currency = 'USD' THEN
    v_reward_unit := 5;
  ELSE
    v_currency    := 'MXN';
    v_reward_unit := 100;
  END IF;

  SELECT
    COUNT(*)                                   AS total,
    COUNT(*) FILTER (WHERE NOT reward_given)   AS pending,
    COUNT(*) FILTER (WHERE reward_given)       AS rewarded
  INTO v_total, v_pending, v_rewarded
  FROM public.referral_events
  WHERE group_id = p_group_id;

  v_earned := v_rewarded * v_reward_unit;

  RETURN jsonb_build_object(
    'ok',            true,
    'total',         v_total,
    'pending',       v_pending,
    'rewarded',      v_rewarded,
    'earned',        v_earned,
    'currency_code', v_currency,
    'reward_unit',   v_reward_unit
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$function$;

COMMIT;

SELECT '598_referral_stats_currency_aware — APLICADO A PRODUCCIÓN 2026-09-02' AS status;
