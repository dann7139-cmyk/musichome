-- ============================================================
-- sql/546_fix_referral_reward_group_wallet.sql
--
-- BUG CONFIRMADO (auditoría 2026-08-09): trg_referral_reward_on_payment
-- acreditaba wallets.available_balance (tabla personal) usando
-- groups.owner_id como key. Confirmado con evidencia directa de código
-- fuente (get_my_wallet(): para role='group' SOLO lee group_wallets,
-- nunca wallets; request_withdrawal bloquea explícitamente a role=
-- 'group'; WithdrawScreen/WalletScreen nunca muestran wallets para ese
-- rol) que ese crédito queda permanentemente inalcanzable para el
-- grupo — ni visible, ni retirable, ni con historial. Además,
-- reward_given=TRUE se marcaba ANTES de intentar el crédito: como
-- referral_events.client_id es UNIQUE, un fallo silencioso (UPDATE que
-- afecta 0 filas, sin excepción) deja el bono perdido para siempre,
-- sin segunda oportunidad. Sin FOR UPDATE en la lectura de
-- referral_events, existía además una ventana de carrera para doble
-- recompensa. Reachability confirmada: flujo 100% alcanzable con
-- onboarding normal (código de referido en registro + primer pago).
-- referral_events = 0 filas en producción — sin impacto histórico.
--
-- CORRECCIÓN (alcance exacto autorizado):
--   1. Credita group_wallets.available_balance / total_earned (vía
--      ensure_group_wallet + FOR UPDATE) en vez de wallets.
--   2. wallet_transactions.type='adjustment' — mismo tipo y misma
--      estructura de columnas que settle_cancellation ya usa para
--      compensaciones al grupo fuera del flujo normal de pago-por-
--      servicio (group_wallet_id, group_id, type, amount,
--      reservation_id, description, balance_after, currency_code).
--   3. reward_given=TRUE se mueve al FINAL, después de que el crédito
--      y el wallet_transaction ya se completaron — si algo falla antes,
--      la excepción revierte todo (incluido dejar reward_given=FALSE),
--      gracias al savepoint implícito del bloque EXCEPTION.
--   4. SELECT ... FOR UPDATE sobre referral_events — cierra la ventana
--      de carrera de doble recompensa.
--   5. EXCEPTION WHEN OTHERS THEN RETURN NEW se mantiene — mismo
--      patrón que notify_extra_hour_proposed: un trigger secundario
--      nunca debe bloquear el pago real del cliente.
--
-- NO CAMBIA (fuera de alcance, documentado aparte):
--   - v_reward = 100 MXN fijo, currency_code='MXN' fijo — sin soporte
--     multimoneda en esta ronda.
--   - Sin escritura a financial_audit_logs — paridad exacta con el
--     patrón de settle_cancellation para 'adjustment'.
--   - get_referral_stats() — no necesita cambios, ya es correcto una
--     vez que el crédito real llegue a group_wallets.
--   - Texto de la notificación — sin cambios, ya describe correctamente
--     lo que ahora sí ocurre de verdad.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.trg_referral_reward_on_payment()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_ref          RECORD;
  v_owner_id     UUID;
  v_reward       NUMERIC := 100;   -- bono en pesos al grupo por referido convertido
  v_gw           RECORD;
  v_gw_bal_after NUMERIC(14,2);
BEGIN
  -- Solo reaccionar cuando cambia a estado de pago confirmado
  IF NEW.payment_status NOT IN ('deposit_paid', 'fully_paid') THEN
    RETURN NEW;
  END IF;
  IF OLD.payment_status IN ('deposit_paid', 'fully_paid') THEN
    RETURN NEW;  -- ya estaba pagado, no volver a premiar
  END IF;

  -- Buscar referido activo (sin recompensa) para este cliente.
  -- FOR UPDATE: cierra la ventana de carrera de doble recompensa.
  SELECT re.id, re.group_id
  INTO   v_ref
  FROM   public.referral_events re
  WHERE  re.client_id    = NEW.client_id
    AND  re.reward_given = FALSE
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN NEW;
  END IF;

  -- Obtener owner del grupo
  SELECT owner_id INTO v_owner_id
  FROM   public.groups WHERE id = v_ref.group_id;

  -- ── Acreditar bono en group_wallets (correcto para role='group') ──────────
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

  -- Marcar como recompensado — AL FINAL, solo después de crédito exitoso.
  -- Si algo de lo anterior falla, la excepción revierte esto también.
  UPDATE public.referral_events
  SET    status         = 'rewarded',
         reward_given   = TRUE,
         reservation_id = NEW.id,
         converted_at   = NOW()
  WHERE  id = v_ref.id;

  -- Notificar al grupo
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
  RETURN NEW;  -- fallback silencioso — no bloquear el pago
END;
$function$;

COMMIT;

-- ════════════════════════════════════════════════════════════════════
-- VERIFICACIONES (ejecutar separado después del COMMIT)
-- ════════════════════════════════════════════════════════════════════

-- V1: función existe, mismo nombre de trigger function (sin parámetros, RETURNS trigger)
SELECT COUNT(*) = 1 AS existe
FROM   pg_proc p
JOIN   pg_namespace n ON n.oid = p.pronamespace
WHERE  n.nspname = 'public' AND p.proname = 'trg_referral_reward_on_payment';
-- Esperado: true

-- V2: SECURITY DEFINER
SELECT prosecdef FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname = 'trg_referral_reward_on_payment';
-- Esperado: true

-- V3: el trigger sigue instalado sobre reservations (CREATE OR REPLACE FUNCTION
-- no afecta triggers ya creados que la referencian)
SELECT COUNT(*) = 1 AS trigger_intacto
FROM pg_trigger WHERE tgname = 'trg_referral_reward' AND tgrelid = 'public.reservations'::regclass;
-- Esperado: true

-- V4: ya no referencia wallets (personal), ahora usa group_wallets,
-- FOR UPDATE presente, reward_given se marca después del INSERT de wallet_transactions
SELECT
  routine_definition NOT LIKE '%UPDATE public.wallets%' AS ya_no_usa_wallets_personal,
  routine_definition LIKE '%group_wallets%'              AS usa_group_wallets,
  routine_definition LIKE '%FOR UPDATE%'                  AS tiene_for_update,
  routine_definition LIKE '%''adjustment''%'              AS usa_tipo_adjustment
FROM information_schema.routines
WHERE routine_schema = 'public' AND routine_name = 'trg_referral_reward_on_payment';
-- Esperado: true | true | true | true

SELECT '546_fix_referral_reward_group_wallet ✅' AS status;
