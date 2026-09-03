-- ============================================================
-- sql/597_referral_reward_currency_aware_ROLLBACK.sql
-- JAMÁS correr salvo emergencia deliberada.
-- Revierte sql/597: regresa trg_referral_reward_on_payment() a la
-- versión anterior (bono fijo $100, siempre etiquetado 'MXN').
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.trg_referral_reward_on_payment()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_ref          RECORD;
  v_owner_id     UUID;
  v_reward       NUMERIC := 100;
  v_gw           RECORD;
  v_gw_bal_after NUMERIC(14,2);
BEGIN
  IF NEW.payment_status NOT IN ('deposit_paid', 'fully_paid') THEN
    RETURN NEW;
  END IF;
  IF OLD.payment_status IN ('deposit_paid', 'fully_paid') THEN
    RETURN NEW;
  END IF;

  SELECT re.id, re.group_id
  INTO   v_ref
  FROM   public.referral_events re
  WHERE  re.client_id    = NEW.client_id
    AND  re.reward_given = FALSE
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN NEW;
  END IF;

  SELECT owner_id INTO v_owner_id
  FROM   public.groups WHERE id = v_ref.group_id;

  PERFORM public.ensure_group_wallet(v_ref.group_id);
  SELECT * INTO v_gw FROM public.group_wallets WHERE group_id = v_ref.group_id FOR UPDATE;

  v_gw_bal_after := COALESCE(v_gw.available_balance, 0) + v_reward;

  UPDATE public.group_wallets
  SET available_balance = v_gw_bal_after,
      total_earned      = COALESCE(total_earned, 0) + v_reward,
      updated_at         = NOW()
  WHERE id = v_gw.id;

  INSERT INTO public.wallet_transactions
    (group_wallet_id, group_id, type, amount, reservation_id, description, balance_after, currency_code)
  VALUES
    (v_gw.id, v_ref.group_id, 'adjustment', v_reward, NEW.id,
     'Bono por referido convertido', v_gw_bal_after, 'MXN');

  UPDATE public.referral_events
  SET    status         = 'rewarded',
         reward_given   = TRUE,
         reservation_id = NEW.id,
         converted_at   = NOW()
  WHERE  id = v_ref.id;

  INSERT INTO public.notifications (user_id, type, title, body, data)
  VALUES (
    v_owner_id,
    'referral_reward',
    '¡Referido convertido! 🎉',
    'Un cliente que invitaste realizó su primera reserva. Se acreditaron $'
      || v_reward::TEXT || ' a tu billetera.',
    jsonb_build_object(
      'screen',        'GroupDashboard',
      'referral_id',   v_ref.id,
      'reward_amount', v_reward
    )
  );

  RETURN NEW;

EXCEPTION WHEN OTHERS THEN
  RETURN NEW;
END;
$function$;

COMMIT;

SELECT '597_referral_reward_currency_aware — REVERTIDO' AS status;
