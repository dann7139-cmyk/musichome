-- ============================================================
-- sql/597_referral_reward_currency_aware.sql
-- ✅ APLICADO A PRODUCCIÓN 2026-09-02. Probado antes en transacción
-- autoreversible: grupo MX recibe $100 MXN, grupo US recibe $5 USD (no
-- $100 mal etiquetado), reintento no duplica el bono — 0 residuo
-- verificado. Aplicado para real después, verificado con
-- pg_get_functiondef que la rama USD quedó en la función en vivo.
--
-- PETICIÓN REAL DEL USUARIO (2026-09-02): el bono de $100 por referido
-- convertido (trg_referral_reward_on_payment, sql/546) estaba fijo en
-- pesos SIN IMPORTAR el país del grupo — si un grupo de Estados Unidos
-- refería a un cliente, se le acreditaban "100" a su billetera igual,
-- pero la transacción quedaba etiquetada 'MXN' aunque su billetera es de
-- USD. Nunca pasó en la vida real (0 grupos no-MXN con referidos
-- premiados, verificado antes de escribir esto) pero es un hueco real.
--
-- Mismo patrón que ya usa gift_catalog_prices: monto FIJO Y DISTINTO por
-- moneda (no conversión automática por tipo de cambio — mismo criterio
-- de "processor fees/FX jamás se estiman", números redondos y claros).
-- $100 MXN de bono → $5 USD de bono (aprox. equivalente, número redondo).
-- Mercados HOY activos: MXN (default) y USD — ver countries reales en
-- producción. Si mañana se abre Canadá con CAD, agregar esa rama aparte.
--
-- Solo cambia trg_referral_reward_on_payment(): agrega la moneda real del
-- GRUPO (groups.country_id → countries.currency_code, mismo patrón usado
-- en client_get_my_events/admin_get_event_detail de sql/585) y usa el
-- monto correspondiente. Nada más de la función cambia — mismas
-- protecciones (candado FOR UPDATE, no duplicar recompensa, etc.)
-- ============================================================

-- ── 1) Prueba en transacción autoreversible ─────────────────────────
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
  v_currency     TEXT := 'MXN';
  v_reward       NUMERIC := 100;   -- bono por referido convertido (MXN default)
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

  -- sql/597 — moneda real del grupo (mismo patrón que sql/585 para quotes)
  SELECT COALESCE(c.currency_code, 'MXN') INTO v_currency
  FROM public.groups g
  LEFT JOIN public.countries c ON c.id = g.country_id
  WHERE g.id = v_ref.group_id;

  IF v_currency = 'USD' THEN
    v_reward := 5;
  ELSE
    v_currency := 'MXN';
    v_reward   := 100;
  END IF;

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
     'Bono por referido convertido', v_gw_bal_after, v_currency);

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
      || v_reward::TEXT || ' ' || v_currency || ' a tu billetera.',
    jsonb_build_object(
      'screen',        'GroupDashboard',
      'referral_id',   v_ref.id,
      'reward_amount', v_reward,
      'currency_code', v_currency
    )
  );

  RETURN NEW;

EXCEPTION WHEN OTHERS THEN
  RETURN NEW;
END;
$function$;

DO $test$
DECLARE
  v_client_mx  UUID;
  v_client_us  UUID;
  v_group_mx   UUID;
  v_group_us   UUID;
  v_owner_mx   UUID;
  v_owner_us   UUID;
  v_country_mx UUID;
  v_country_us UUID;
  v_res_mx     UUID;
  v_res_us     UUID;
  v_wt         RECORD;
BEGIN
  SELECT id INTO v_country_mx FROM public.countries WHERE currency_code = 'MXN' LIMIT 1;
  SELECT id INTO v_country_us FROM public.countries WHERE currency_code = 'USD' LIMIT 1;

  -- Owners + grupos de prueba (uno MX, uno US)
  v_owner_mx := gen_random_uuid();
  v_owner_us := gen_random_uuid();
  INSERT INTO public.profiles (id, full_name, role) VALUES
    (v_owner_mx, 'Test Owner MX 597', 'group'),
    (v_owner_us, 'Test Owner US 597', 'group');

  INSERT INTO public.groups (id, owner_id, name, genre, country_id, referral_code)
    VALUES (gen_random_uuid(), v_owner_mx, 'Test Grupo MX 597', 'Banda', v_country_mx, 'TESTMX597')
    RETURNING id INTO v_group_mx;
  INSERT INTO public.groups (id, owner_id, name, genre, country_id, referral_code)
    VALUES (gen_random_uuid(), v_owner_us, 'Test Grupo US 597', 'Banda', v_country_us, 'TESTUS597')
    RETURNING id INTO v_group_us;

  -- Clientes referidos, ya con evento registrado (reward_given=false)
  v_client_mx := gen_random_uuid();
  v_client_us := gen_random_uuid();
  INSERT INTO public.profiles (id, full_name, role) VALUES
    (v_client_mx, 'Test Cliente MX 597', 'client'),
    (v_client_us, 'Test Cliente US 597', 'client');

  INSERT INTO public.referral_events (group_id, client_id, referral_code)
    VALUES (v_group_mx, v_client_mx, 'TESTMX597');
  INSERT INTO public.referral_events (group_id, client_id, referral_code)
    VALUES (v_group_us, v_client_us, 'TESTUS597');

  -- Reserva del cliente MX pasa a fully_paid → debe disparar el trigger
  INSERT INTO public.reservations (id, client_id, group_id, event_date, event_time, address, total_price, status, payment_status)
    VALUES (gen_random_uuid(), v_client_mx, v_group_mx, CURRENT_DATE + 10, '18:00', 'Dir MX', 1000, 'pending', 'unpaid')
    RETURNING id INTO v_res_mx;
  UPDATE public.reservations SET payment_status = 'fully_paid' WHERE id = v_res_mx;

  INSERT INTO public.reservations (id, client_id, group_id, event_date, event_time, address, total_price, status, payment_status)
    VALUES (gen_random_uuid(), v_client_us, v_group_us, CURRENT_DATE + 10, '18:00', 'Dir US', 1000, 'pending', 'unpaid')
    RETURNING id INTO v_res_us;
  UPDATE public.reservations SET payment_status = 'fully_paid' WHERE id = v_res_us;

  -- Verificar transacción MX: 100 MXN
  SELECT * INTO v_wt FROM public.wallet_transactions
    WHERE reservation_id = v_res_mx AND description = 'Bono por referido convertido';
  ASSERT FOUND, 'FAIL: no se generó wallet_transaction para el grupo MX';
  ASSERT v_wt.amount = 100, 'FAIL monto MX: ' || v_wt.amount::text;
  ASSERT v_wt.currency_code = 'MXN', 'FAIL moneda MX: ' || v_wt.currency_code;

  -- Verificar transacción US: 5 USD (NO 100 mal etiquetado)
  SELECT * INTO v_wt FROM public.wallet_transactions
    WHERE reservation_id = v_res_us AND description = 'Bono por referido convertido';
  ASSERT FOUND, 'FAIL: no se generó wallet_transaction para el grupo US';
  ASSERT v_wt.amount = 5, 'FAIL monto US (debía ser 5, no 100): ' || v_wt.amount::text;
  ASSERT v_wt.currency_code = 'USD', 'FAIL moneda US: ' || v_wt.currency_code;

  -- Verificar que no se duplica si el pago se vuelve a marcar fully_paid
  UPDATE public.reservations SET payment_status = 'deposit_paid' WHERE id = v_res_us;
  UPDATE public.reservations SET payment_status = 'fully_paid' WHERE id = v_res_us;
  ASSERT (SELECT COUNT(*) FROM public.wallet_transactions
          WHERE reservation_id = v_res_us AND description = 'Bono por referido convertido') = 1,
    'FAIL: se duplicó el bono en un reintento';

  RAISE EXCEPTION 'ROLLBACK_TEST_OK — bono MX=100 MXN, US=5 USD, sin duplicados';
END;
$test$;

ROLLBACK;

-- ── 2) Aplicación real ───────────────────────────────────────────────
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
  v_currency     TEXT := 'MXN';
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

  SELECT COALESCE(c.currency_code, 'MXN') INTO v_currency
  FROM public.groups g
  LEFT JOIN public.countries c ON c.id = g.country_id
  WHERE g.id = v_ref.group_id;

  IF v_currency = 'USD' THEN
    v_reward := 5;
  ELSE
    v_currency := 'MXN';
    v_reward   := 100;
  END IF;

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
     'Bono por referido convertido', v_gw_bal_after, v_currency);

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
      || v_reward::TEXT || ' ' || v_currency || ' a tu billetera.',
    jsonb_build_object(
      'screen',        'GroupDashboard',
      'referral_id',   v_ref.id,
      'reward_amount', v_reward,
      'currency_code', v_currency
    )
  );

  RETURN NEW;

EXCEPTION WHEN OTHERS THEN
  RETURN NEW;
END;
$function$;

COMMIT;

SELECT '597_referral_reward_currency_aware — APLICADO A PRODUCCIÓN 2026-09-02' AS status;
