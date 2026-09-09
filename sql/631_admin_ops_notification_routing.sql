-- sql/631_admin_ops_notification_routing.sql
--
-- Fase 1 (enrutamiento de alertas) del admin con alcance por país.
--
-- Las 3 funciones que generan las alertas que alimentan las 3 colas ya
-- construidas (no-shows, pagos, propinas) mandaban la notificación a
-- TODOS los perfiles role='admin' sin distinguir país. Ahora:
--   - Un admin_ops (US) recibe la alerta SOLO si el evento/grupo es de
--     su país de alcance.
--   - La cuenta admin completa sigue recibiendo TODO por defecto — salvo
--     que haya apagado un país en admin_muted_countries (el interruptor
--     nuevo de sql/627, vacío por defecto = cero cambio de comportamiento).
--
-- Alcance de esta fase: solo las 3 alertas directamente ligadas a las
-- colas que ya construimos (no-show, cobro de grupo, cobro de propinas).
-- Otras alertas de admin (disputas, tickets, strikes, etc.) quedan igual
-- que hoy — no forman parte del pedido actual, se puede extender después
-- con el mismo patrón.
BEGIN;

-- ── 1/3: mark_abandoned_reservations (detecta no-show → alerta) ─────────
CREATE OR REPLACE FUNCTION public.mark_abandoned_reservations()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_count   INTEGER := 0;
  v_row     RECORD;
  v_admin   UUID;
  v_country TEXT;
BEGIN
  FOR v_row IN
    WITH marked AS (
      UPDATE reservations AS r
      SET
        status            = 'cancelled',
        cancelled_at      = NOW(),
        cancelled_by      = NULL,
        cancel_reason     = 'no_show_grupo',
        cancellation_type = 'system_auto',
        payout_status     = 'blocked'
      FROM (
        SELECT
          res.id,
          (
            (res.event_date + COALESCE(res.event_time, '23:59:00'::TIME))
              AT TIME ZONE 'America/Mexico_City'
            + COALESCE(res.hours_count, qte.duration_hours, 4) * INTERVAL '1 hour'
            + INTERVAL '30 minutes'
          ) AS ends_at
        FROM reservations res
        LEFT JOIN quotes qte ON qte.id = res.quote_id
        WHERE res.status            IN ('confirmed', 'accepted')
          AND res.payment_status    IN ('paid', 'deposit_paid', 'fully_paid')
          AND res.group_arrived_at  IS NULL
      ) sub
      WHERE r.id = sub.id
        AND sub.ends_at < NOW()
      RETURNING r.id, r.folio, r.group_id, r.event_date
    )
    SELECT m.*, g.name AS gname, g.country AS gcountry FROM marked m LEFT JOIN groups g ON g.id = m.group_id
  LOOP
    v_count := v_count + 1;
    v_country := country_code_of(v_row.gcountry);  -- [631]
    -- [631] admin completo (salvo que haya apagado este país) + admin_ops de este país
    FOR v_admin IN
      SELECT id FROM profiles
      WHERE (role = 'admin' AND NOT (v_country = ANY(COALESCE(admin_muted_countries, '{}'))))
         OR (role = 'admin_ops' AND admin_country_scope = v_country)
    LOOP
      INSERT INTO notifications (user_id, type, title, body, data)
      VALUES (v_admin, 'admin',
        '🚨 No-show detectado',
        format('%s no llegó a su evento del %s (folio %s). El pago quedó bloqueado — resuélvelo en la cola de no-shows.',
               COALESCE(v_row.gname, 'Un grupo'), to_char(v_row.event_date, 'DD/MM'),
               COALESCE(v_row.folio, v_row.id::text)),
        jsonb_build_object('reservation_id', v_row.id, 'screen', 'AdminHome'));
    END LOOP;
  END LOOP;

  RETURN v_count;
END;
$function$;

-- ── 2/3: group_request_payment (grupo pide su pago → alerta) ────────────
CREATE OR REPLACE FUNCTION public.group_request_payment(p_reservation_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_res      RECORD;
  v_saldo    NUMERIC;
  v_existing RECORD;
  v_new_id   UUID;
  v_country  TEXT;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_authenticated');
  END IF;

  SELECT r.*, g.owner_id, g.country AS group_country INTO v_res
  FROM reservations r JOIN groups g ON g.id = r.group_id
  WHERE r.id = p_reservation_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_found');
  END IF;

  IF v_res.owner_id <> auth.uid() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_owner');
  END IF;

  IF v_res.status <> 'completed' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'reservation_status_not_eligible', 'status', v_res.status);
  END IF;

  IF v_res.payout_status <> 'released' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_released');
  END IF;

  IF EXISTS (SELECT 1 FROM disputes WHERE reservation_id = p_reservation_id AND status IN ('open','under_review')) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'open_dispute_blocks_payment');
  END IF;

  SELECT v_res.group_earnings - COALESCE(SUM(amount), 0) INTO v_saldo
  FROM group_reservation_payments WHERE reservation_id = p_reservation_id;
  IF v_saldo IS NULL OR v_saldo <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_balance_due');
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM wallets w
    WHERE w.user_id = v_res.owner_id
      AND w.bank_clabe IS NOT NULL AND length(w.bank_clabe) = 18 AND w.bank_clabe ~ '^\d{18}$'
      AND w.bank_name IS NOT NULL AND length(trim(w.bank_name)) > 0
      AND w.account_holder IS NOT NULL AND length(trim(w.account_holder)) > 0
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'missing_bank_data');
  END IF;

  SELECT * INTO v_existing FROM group_payment_requests
  WHERE reservation_id = p_reservation_id AND status = 'pending';
  IF FOUND THEN
    RETURN jsonb_build_object('ok', true, 'already_requested', true, 'request_id', v_existing.id);
  END IF;

  BEGIN
    INSERT INTO group_payment_requests (reservation_id, group_id, requested_by, status)
    VALUES (p_reservation_id, v_res.group_id, auth.uid(), 'pending')
    RETURNING id INTO v_new_id;
  EXCEPTION WHEN unique_violation THEN
    SELECT id INTO v_new_id FROM group_payment_requests
    WHERE reservation_id = p_reservation_id AND status = 'pending';
    RETURN jsonb_build_object('ok', true, 'already_requested', true, 'request_id', v_new_id);
  END;

  v_country := country_code_of(v_res.group_country);  -- [631]

  INSERT INTO notifications (user_id, type, title, body, data)
  SELECT p.id, 'payment', '📢 Grupo solicita su pago',
    format('%s solicita el pago de su evento del %s%s.',
      (SELECT name FROM groups WHERE id = v_res.group_id),
      v_res.event_date,
      CASE WHEN v_res.folio IS NOT NULL THEN format(' (folio %s)', v_res.folio) ELSE '' END),
    jsonb_build_object('reservation_id', p_reservation_id, 'screen', 'AdminFinancial')
  FROM profiles p
  WHERE (p.role = 'admin' AND NOT (v_country = ANY(COALESCE(p.admin_muted_countries, '{}'))))  -- [631]
     OR (p.role = 'admin_ops' AND p.admin_country_scope = v_country);                          -- [631]

  RETURN jsonb_build_object('ok', true, 'already_requested', false, 'request_id', v_new_id);
END;
$function$;

-- ── 3/3: group_request_gift_payout (grupo pide cobrar propinas → alerta) ─
CREATE OR REPLACE FUNCTION public.group_request_gift_payout()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_group_id    UUID;
  v_owner_id    UUID;
  v_group_country TEXT;
  v_unpaid_mxn  NUMERIC := 0;
  v_unpaid_usd  NUMERIC := 0;
  v_amount      NUMERIC;
  v_currency    TEXT;
  v_existing    RECORD;
  v_new_id      UUID;
  v_country     TEXT;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_authenticated');
  END IF;

  SELECT id, owner_id, country INTO v_group_id, v_owner_id, v_group_country FROM groups WHERE owner_id = auth.uid();
  IF v_group_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_group');
  END IF;

  SELECT * INTO v_existing FROM public.group_gift_payout_requests
  WHERE group_id = v_group_id AND status = 'pending';
  IF FOUND THEN
    RETURN jsonb_build_object('ok', true, 'already_requested', true, 'request_id', v_existing.id,
      'amount', v_existing.amount, 'currency', v_existing.currency_code);
  END IF;

  SELECT unpaid INTO v_unpaid_mxn FROM public.group_unpaid_gift_balance(v_group_id) WHERE currency_code = 'MXN';
  SELECT unpaid INTO v_unpaid_usd FROM public.group_unpaid_gift_balance(v_group_id) WHERE currency_code = 'USD';

  IF COALESCE(v_unpaid_mxn, 0) >= 200 THEN
    v_amount := v_unpaid_mxn; v_currency := 'MXN';
  ELSIF COALESCE(v_unpaid_usd, 0) >= 12 THEN
    v_amount := v_unpaid_usd; v_currency := 'USD';
  ELSE
    RETURN jsonb_build_object('ok', false, 'error', 'below_minimum',
      'unpaid_mxn', COALESCE(v_unpaid_mxn, 0), 'unpaid_usd', COALESCE(v_unpaid_usd, 0),
      'threshold_mxn', 200, 'threshold_usd', 12);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM wallets w
    WHERE w.user_id = v_owner_id
      AND w.bank_clabe IS NOT NULL AND length(w.bank_clabe) = 18 AND w.bank_clabe ~ '^\d{18}$'
      AND w.bank_name IS NOT NULL AND length(trim(w.bank_name)) > 0
      AND w.account_holder IS NOT NULL AND length(trim(w.account_holder)) > 0
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'missing_bank_data');
  END IF;

  BEGIN
    INSERT INTO public.group_gift_payout_requests (group_id, requested_by, amount, currency_code, status)
    VALUES (v_group_id, auth.uid(), v_amount, v_currency, 'pending')
    RETURNING id INTO v_new_id;
  EXCEPTION WHEN unique_violation THEN
    SELECT id, amount, currency_code INTO v_new_id, v_amount, v_currency
    FROM public.group_gift_payout_requests WHERE group_id = v_group_id AND status = 'pending';
    RETURN jsonb_build_object('ok', true, 'already_requested', true, 'request_id', v_new_id,
      'amount', v_amount, 'currency', v_currency);
  END;

  v_country := country_code_of(v_group_country);  -- [631]

  INSERT INTO notifications (user_id, type, title, body, data)
  SELECT p.id, 'payment', '🎁 Grupo solicita cobrar sus propinas',
    format('%s solicita el pago de $%s %s en propinas/regalos acumulados.',
      (SELECT name FROM groups WHERE id = v_group_id), v_amount, v_currency),
    jsonb_build_object('group_id', v_group_id, 'screen', 'AdminFinancial')
  FROM profiles p
  WHERE (p.role = 'admin' AND NOT (v_country = ANY(COALESCE(p.admin_muted_countries, '{}'))))  -- [631]
     OR (p.role = 'admin_ops' AND p.admin_country_scope = v_country);                          -- [631]

  RETURN jsonb_build_object('ok', true, 'already_requested', false, 'request_id', v_new_id,
    'amount', v_amount, 'currency', v_currency);
END;
$function$;

COMMIT;
