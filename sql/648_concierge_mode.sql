-- ============================================================================
-- sql/648_concierge_mode.sql
-- Modo conserjería: grupos que aún no confían en Daricefy y no quieren
-- manejar su propia cuenta. Daniel (o el admin_ops de su país) recibe la
-- solicitud de cotización, llama al grupo por teléfono, y pone el precio
-- él mismo desde AdminManagedQuotesScreen. El grupo sigue teniendo cuenta
-- normal — nada más que por ahora Daniel es su intermediario. Cuando el
-- cliente paga, Daniel recibe aviso para volver a llamarle al grupo y
-- confirmar la tocada.
--
-- NOTA: estas 5 piezas ya fueron aplicadas en producción directamente
-- (2026-09-13, sesión de conserjería) antes de escribir este archivo —
-- se documentan aquí ahora, tal cual quedaron vivas, para no romper la
-- disciplina de sql/ aunque el orden de esta vez haya sido al revés.
-- Sandbox-probadas antes de aplicar (ver sql/602 checks [32]-[34]).
-- ============================================================================

-- 1) Columna nueva en groups — aditiva, sin default riesgoso.
ALTER TABLE public.groups
  ADD COLUMN IF NOT EXISTS concierge_mode boolean NOT NULL DEFAULT false;

-- ----------------------------------------------------------------------------
-- 2) notify_quote_request — reemplaza la notificación manual que antes vivía
--    a mano en QuoteFormScreen.tsx. Si el grupo NO está en modo conserjería,
--    comportamiento cero-cambio (dueño + integrantes aceptados). Si SÍ está
--    en modo conserjería, notifica a admin completo (respetando mute de
--    país) + admin_ops del país del grupo — mismo patrón de sql/631/642.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.notify_quote_request(p_quote_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_quote        RECORD;
  v_group        RECORD;
  v_client_name  TEXT;
  v_country      TEXT;
  v_member_id    UUID;
BEGIN
  SELECT * INTO v_quote FROM public.quotes WHERE id = p_quote_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'quote_not_found'); END IF;
  IF v_quote.client_id <> auth.uid() THEN RETURN jsonb_build_object('ok', false, 'error', 'not_owner'); END IF;

  SELECT g.id, g.owner_id, g.name, g.country, g.concierge_mode, po.phone AS owner_phone
  INTO v_group
  FROM public.groups g
  LEFT JOIN public.profiles po ON po.id = g.owner_id
  WHERE g.id = v_quote.group_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'group_not_found'); END IF;

  SELECT full_name INTO v_client_name FROM public.profiles WHERE id = v_quote.client_id;

  IF NOT v_group.concierge_mode THEN
    IF v_group.owner_id IS NOT NULL THEN
      INSERT INTO public.notifications (user_id, type, title, body, data)
      VALUES (
        v_group.owner_id, 'new_quote_request',
        '📋 Nueva solicitud de cotización',
        format('%s quiere contratarte para un evento de %s horas.', COALESCE(v_client_name,'Un cliente'), COALESCE(v_quote.duration_hours::text, '—')),
        jsonb_build_object('group_id', v_group.id, 'quote_id', p_quote_id)
      );

      FOR v_member_id IN
        SELECT ji.invited_user_id FROM public.job_invitations ji
        WHERE ji.group_id = v_group.id AND ji.invitation_type = 'membership' AND ji.status = 'accepted'
      LOOP
        INSERT INTO public.notifications (user_id, type, title, body, data)
        VALUES (v_member_id, 'new_quote_request', '📋 Nueva solicitud de cotización',
          'Su grupo tiene una nueva solicitud de cotización.',
          jsonb_build_object('group_id', v_group.id, 'quote_id', p_quote_id));
      END LOOP;

      FOR v_member_id IN
        SELECT ji.invited_user_id FROM public.job_invitations ji
        WHERE ji.group_id = v_group.id AND ji.invitation_type = 'event' AND ji.status = 'accepted'
      LOOP
        INSERT INTO public.notifications (user_id, type, title, body, data)
        VALUES (v_member_id, 'new_quote_request', '📋 Nueva solicitud de cotización',
          'Su grupo tiene una nueva solicitud de cotización.',
          jsonb_build_object('group_id', v_group.id, 'quote_id', p_quote_id));
      END LOOP;
    END IF;
  ELSE
    v_country := public.country_code_of(v_group.country);
    INSERT INTO public.notifications (user_id, type, title, body, data)
    SELECT p.id, 'new_quote_request',
      '📞 Cotización para llamar — ' || v_group.name,
      format('%s pidió cotización a %s (aún no maneja su cuenta). Llama al %s para darle el precio.',
        COALESCE(v_client_name, 'Un cliente'), v_group.name, COALESCE(v_group.owner_phone, 'sin teléfono')),
      jsonb_build_object('quote_id', p_quote_id, 'group_id', v_group.id, 'group_phone', v_group.owner_phone, 'screen', 'AdminManagedQuotes')
    FROM public.profiles p
    WHERE (p.role = 'admin' AND NOT public.admin_is_country_muted(v_group.country, p.id))
       OR (p.role = 'admin_ops' AND p.admin_country_scope = v_country);
  END IF;

  RETURN jsonb_build_object('ok', true);
END;
$function$;

-- ----------------------------------------------------------------------------
-- 3) admin_respond_quote — el admin (completo o admin_ops de ese país) pone
--    el precio que el grupo le dio por teléfono. Usa calculate_final_price
--    (única fuente de verdad del markup 20%) y hace el mismo UPDATE/
--    notificación que hoy hace el grupo mismo en GroupQuoteDetailScreen —
--    el cliente no nota ninguna diferencia.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_respond_quote(p_quote_id uuid, p_base_price numeric, p_travel_cost numeric DEFAULT 0, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_role TEXT;
  v_quote       RECORD;
  v_group       RECORD;
  v_calc        JSONB;
  v_group_total NUMERIC;
  v_total       NUMERIC;
  v_member_id   UUID;
BEGIN
  SELECT role INTO v_caller_role FROM public.profiles WHERE id = auth.uid();
  IF v_caller_role NOT IN ('admin', 'admin_ops') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;

  IF p_base_price IS NULL OR p_base_price <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_base_price');
  END IF;

  SELECT * INTO v_quote FROM public.quotes WHERE id = p_quote_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'quote_not_found'); END IF;
  IF v_quote.status <> 'pending' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'quote_not_pending', 'status', v_quote.status);
  END IF;

  SELECT id, owner_id, name, country, concierge_mode INTO v_group
  FROM public.groups WHERE id = v_quote.group_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'group_not_found'); END IF;

  IF NOT v_group.concierge_mode THEN
    RETURN jsonb_build_object('ok', false, 'error', 'group_not_in_concierge_mode');
  END IF;

  IF v_caller_role = 'admin_ops'
     AND public.country_code_of(v_group.country) <> public.admin_ops_country() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;

  -- El markup 20% aplica sobre base+traslado combinados — mismo criterio que
  -- usa el grupo mismo al responder su propia cotización en
  -- GroupQuoteDetailScreen (calcClientPrice(base+travel), no solo base).
  -- Corrección 2026-09-13 (revisión de Parte 1 antes de manual testing):
  -- la primera versión marcaba el traslado sin comisión (base*1.20 +
  -- travel), cobrándole de menos al cliente y perdiendo comisión real cada
  -- vez que había costo de traslado (confirmado con caso real: base=8000,
  -- travel=500 daba total_amount=10100 en vez de 10200).
  v_group_total := p_base_price + COALESCE(p_travel_cost, 0);
  v_calc  := public.calculate_final_price(v_group_total);
  v_total := (v_calc->>'final_price')::numeric;

  UPDATE public.quotes SET
    status            = 'quoted',
    base_price        = p_base_price,
    travel_cost       = COALESCE(p_travel_cost, 0),
    commission_amount = (v_calc->>'commission_amount')::numeric,
    commission_pct    = 20,
    total_amount      = v_total,
    group_earnings    = v_group_total,
    group_notes       = p_notes,
    updated_at        = NOW()
  WHERE id = p_quote_id;

  INSERT INTO public.notifications (user_id, type, title, body, data)
  VALUES (
    v_quote.client_id, 'quote_received',
    '📋 Recibiste una cotización',
    format('%s respondió tu solicitud. Total: $%s.', v_group.name, to_char(v_total, 'FM999,999,990.00')),
    jsonb_build_object('quote_id', p_quote_id)
  );

  FOR v_member_id IN
    SELECT ji.invited_user_id FROM public.job_invitations ji
    WHERE ji.group_id = v_group.id AND ji.invitation_type = 'membership' AND ji.status = 'accepted'
  LOOP
    INSERT INTO public.notifications (user_id, type, title, body, data)
    VALUES (v_member_id, 'quote_sent_to_client', '📋 Se envió una cotización',
      format('Se le envió una cotización de $%s al cliente.', to_char(v_total, 'FM999,999,990.00')),
      jsonb_build_object('quote_id', p_quote_id));
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'total_amount', v_total, 'group_earnings', v_group_total);
END;
$function$;

-- ----------------------------------------------------------------------------
-- 4) admin_get_concierge_quotes — cola de cotizaciones pendientes de grupos
--    en modo conserjería. admin completo ve todas; admin_ops ve solo las
--    de su país (mismo filtro que las demás colas admin, sql/627/628).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_get_concierge_quotes(p_limit integer DEFAULT 50)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_role TEXT;
  v_result      JSONB;
BEGIN
  SELECT role INTO v_caller_role FROM profiles WHERE id = auth.uid();
  IF v_caller_role NOT IN ('admin', 'admin_ops') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;

  SELECT jsonb_build_object(
    'ok', true,
    'items', COALESCE(jsonb_agg(x.item ORDER BY x.created_at ASC), '[]'::jsonb)
  )
  INTO v_result
  FROM (
    SELECT
      q.created_at,
      jsonb_build_object(
        'quote_id',        q.id,
        'group_id',        g.id,
        'group_name',      g.name,
        'group_phone',     po.phone,
        'group_genre',     g.genre,
        'country',         COALESCE(g.country, 'México'),
        'client_name',     p.full_name,
        'client_phone',    p.phone,
        'event_date',      q.event_date,
        'event_time',      q.event_time,
        'duration_hours',  q.duration_hours,
        'event_address',   q.event_address,
        'event_municipio', q.event_municipio,
        'event_estado',    q.event_estado,
        'comments',        q.comments,
        'created_at',      q.created_at
      ) AS item
    FROM quotes q
    JOIN groups g ON g.id = q.group_id
    LEFT JOIN profiles po ON po.id = g.owner_id
    LEFT JOIN profiles p  ON p.id  = q.client_id
    WHERE q.status = 'pending'
      AND g.concierge_mode = true
      AND (v_caller_role = 'admin' OR country_code_of(g.country) = admin_ops_country())
    ORDER BY q.created_at ASC
    LIMIT p_limit
  ) x;

  RETURN v_result;
END;
$function$;

-- ----------------------------------------------------------------------------
-- 5) _apply_confirmed_credit — CREATE OR REPLACE preservando el 100% de la
--    lógica original (choke point único de "un pago se acaba de confirmar",
--    sql/519+). Único bloque nuevo: al final, si el grupo está en modo
--    conserjería, avisa a admin/admin_ops de su país para que llamen al
--    grupo y confirmen la tocada — aditivo, no toca ninguna rama de dinero.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._apply_confirmed_credit(p_receipt_id uuid, p_reservation_id uuid, p_provider text, p_payment_id text, p_method text, p_fee_minor bigint, p_fee_source text, p_attempt_id uuid, p_manual boolean DEFAULT false, p_actor uuid DEFAULT NULL::uuid, p_evidence_id uuid DEFAULT NULL::uuid, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_group_id    UUID;
  v_res         RECORD;
  v_receipt     RECORD;
  v_att         RECORD;
  v_ev          RECORD;
  v_currency    TEXT;
  v_earnings    NUMERIC;
  v_service_fee NUMERIC;
  v_msi_fee     NUMERIC;
  v_admin_bruto NUMERIC;
  v_fee_pesos   NUMERIC;
  v_admin_id    UUID;
  v_wallet_id   UUID;
  v_revived     BOOLEAN;
  v_fuente      TEXT;
  v_concierge     BOOLEAN;
  v_group_country TEXT;
  v_group_name    TEXT;
  v_group_phone   TEXT;
  v_cc            TEXT;
BEGIN
  SELECT group_id INTO v_group_id FROM reservations WHERE id = p_reservation_id;
  IF v_group_id IS NULL THEN
    RAISE EXCEPTION '_credit_assert: reserva % inexistente', p_reservation_id;
  END IF;
  PERFORM pg_advisory_xact_lock(hashtext(v_group_id::text));

  SELECT * INTO v_res FROM reservations WHERE id = p_reservation_id FOR UPDATE;

  IF v_res.status IN ('cancelled','rejected') THEN
    RAISE EXCEPTION '_credit_assert: reserva % terminal (%)', p_reservation_id, v_res.status;
  END IF;
  IF v_res.payment_status IN ('paid','fully_paid') THEN
    RAISE EXCEPTION '_credit_assert: reserva % ya pagada', p_reservation_id;
  END IF;

  SELECT * INTO v_receipt FROM payment_receipts WHERE id = p_receipt_id FOR UPDATE;
  IF NOT FOUND OR v_receipt.money_state <> 'recorded' OR v_receipt.resolution IS NOT NULL THEN
    RAISE EXCEPTION '_credit_assert: receipt % no acreditable (state=%, resolution=%)',
      p_receipt_id, v_receipt.money_state, v_receipt.resolution;
  END IF;
  IF p_manual AND p_evidence_id IS NULL THEN
    RAISE EXCEPTION '_credit_assert: crédito manual sin evidencia';
  END IF;

  v_currency := UPPER(COALESCE(v_res.currency_code, 'MXN'));
  v_revived  := (v_res.status = 'expired');

  IF p_evidence_id IS NOT NULL THEN
    SELECT * INTO v_ev FROM admin_payment_evidence WHERE id = p_evidence_id;
    IF NOT FOUND OR NOT v_ev.captured OR v_ev.group_base_minor IS NULL THEN
      RAISE EXCEPTION '_credit_assert: evidencia % sin composición capturada', p_evidence_id;
    END IF;
    v_earnings    := v_ev.group_base_minor   / 100.0;
    v_service_fee := v_ev.platform_fee_minor / 100.0;
    v_msi_fee     := v_ev.msi_fee_minor      / 100.0;
    v_fuente      := 'evidence:' || p_evidence_id;
  ELSE
    IF p_attempt_id IS NOT NULL THEN
      SELECT * INTO v_att FROM payment_attempts WHERE id = p_attempt_id;
    END IF;
    IF p_attempt_id IS NOT NULL AND FOUND AND v_att.group_base_minor IS NOT NULL THEN
      v_earnings    := v_att.group_base_minor   / 100.0;
      v_service_fee := v_att.platform_fee_minor / 100.0;
      v_msi_fee     := v_att.msi_fee_minor      / 100.0;
      v_fuente      := 'attempt_snapshot';
    ELSE
      v_earnings    := COALESCE(v_res.base_price, ROUND(v_res.total_price / 1.20, 2));
      v_service_fee := COALESCE(v_res.service_fee_amount,
                         v_res.total_price - ROUND(v_res.total_price / 1.20, 2));
      v_msi_fee     := COALESCE(v_res.msi_fee_amount, 0);
      v_fuente      := 'reservation_compat';
    END IF;
  END IF;

  v_admin_bruto := v_service_fee + v_msi_fee;
  v_fee_pesos   := CASE WHEN p_fee_minor IS NULL THEN NULL ELSE p_fee_minor / 100.0 END;

  PERFORM ensure_group_wallet(v_group_id);
  SELECT id INTO v_wallet_id FROM group_wallets WHERE group_id = v_group_id;

  CASE v_currency
    WHEN 'MXN' THEN
      UPDATE group_wallets SET
        pending_balance = pending_balance + v_earnings,
        total_earned    = total_earned    + v_earnings,
        updated_at      = NOW()
      WHERE id = v_wallet_id;
    WHEN 'USD' THEN
      UPDATE group_wallets SET
        pending_balance_usd = pending_balance_usd + v_earnings,
        total_earned_usd    = total_earned_usd    + v_earnings,
        updated_at          = NOW()
      WHERE id = v_wallet_id;
    ELSE
      RAISE EXCEPTION '_credit_assert: moneda % sin wallet autorizada — crédito prohibido', v_currency;
  END CASE;

  UPDATE reservations SET
    status              = CASE WHEN status IN ('pending','pending_payment',
                                               'pending_group_confirmation',
                                               'accepted','expired')
                               THEN 'confirmed' ELSE status END,
    payment_status      = 'paid',
    payout_status       = 'held',
    held_at             = NOW(),
    mp_payment_id       = p_payment_id,
    payment_provider    = p_provider,
    payment_method_type = COALESCE(p_method, payment_method_type),
    stripe_fee_amount   = COALESCE(v_fee_pesos, stripe_fee_amount),
    service_fee_amount  = v_service_fee,
    group_earnings      = v_earnings,
    updated_at          = NOW()
  WHERE id = p_reservation_id;

  INSERT INTO wallet_transactions (
    group_wallet_id, group_id, type, amount,
    reservation_id, description, balance_after, currency_code
  )
  SELECT gw.id, gw.group_id, 'credit_pending', v_earnings,
    p_reservation_id,
    format('Pago confirmado — reserva %s', p_reservation_id),
    CASE v_currency WHEN 'USD' THEN gw.pending_balance_usd ELSE gw.pending_balance END,
    v_currency
  FROM group_wallets gw WHERE gw.id = v_wallet_id;

  SELECT id INTO v_admin_id FROM profiles WHERE role = 'admin' ORDER BY created_at LIMIT 1;
  IF v_admin_id IS NOT NULL THEN
    INSERT INTO wallets (user_id, available_balance, pending_balance, total_earned)
    VALUES (v_admin_id, 0, 0, 0)
    ON CONFLICT (user_id) DO NOTHING;

    CASE v_currency
      WHEN 'MXN' THEN
        UPDATE wallets SET
          available_balance = available_balance + v_admin_bruto,
          total_earned      = COALESCE(total_earned, 0) + v_admin_bruto,
          updated_at        = NOW()
        WHERE user_id = v_admin_id;
      WHEN 'USD' THEN
        UPDATE wallets SET
          available_balance_usd = available_balance_usd + v_admin_bruto,
          total_earned_usd      = COALESCE(total_earned_usd, 0) + v_admin_bruto,
          updated_at            = NOW()
        WHERE user_id = v_admin_id;
      ELSE
        RAISE EXCEPTION '_credit_assert: moneda % sin wallet admin autorizada', v_currency;
    END CASE;

    INSERT INTO wallet_transactions (user_id, type, amount, reservation_id, description, currency_code)
    VALUES (v_admin_id, 'platform_income', v_admin_bruto, p_reservation_id,
      format('Comisión $%s + MSI $%s = $%s bruto — fee procesador: %s — reserva %s',
        v_service_fee::TEXT, v_msi_fee::TEXT, v_admin_bruto::TEXT,
        COALESCE('$' || v_fee_pesos::TEXT, 'No capturado'),
        p_reservation_id),
      v_currency);
  END IF;

  INSERT INTO financial_audit_logs
    (entity_type, entity_id, action, actor_id, actor_role, amount, notes)
  VALUES ('reservation', p_reservation_id, 'hold',
    p_actor, CASE WHEN p_manual THEN 'admin' ELSE 'system' END, v_earnings,
    format('%s currency=%s group=%s svc=%s msi=%s fee=%s fuente=%s pago=%s/%s%s%s',
      CASE WHEN p_manual THEN 'manual_credit' ELSE 'v2' END,
      v_currency, v_earnings, v_service_fee, v_msi_fee,
      COALESCE(v_fee_pesos::TEXT, 'not_captured'), v_fuente,
      p_provider, p_payment_id,
      CASE WHEN v_revived THEN ' [REVIVIDA]' ELSE '' END,
      CASE WHEN p_note IS NOT NULL THEN ' nota=' || p_note ELSE '' END));

  IF v_fuente <> 'reservation_compat'
     AND v_res.base_price IS NOT NULL
     AND ROUND(v_res.base_price * 100)::BIGINT <> ROUND(v_earnings * 100)::BIGINT THEN
    INSERT INTO financial_audit_logs
      (entity_type, entity_id, action, actor_id, actor_role, amount, notes)
    VALUES ('reservation', p_reservation_id, 'snapshot_reservation_drift',
      p_actor, CASE WHEN p_manual THEN 'admin' ELSE 'system' END, v_earnings,
      format('reserva_viva base=%s vs snapshot base=%s — el snapshot MANDA',
        v_res.base_price, v_earnings));
  END IF;

  INSERT INTO notifications (user_id, type, title, body, data)
  SELECT g.owner_id, 'payment',
    '💰 Pago confirmado — retenido hasta el evento',
    format('El cliente pagó tu evento del %s. $%s %s quedaron reservados y se liberan cuando el grupo llegue y al terminar el evento.',
      v_res.event_date::TEXT, to_char(v_earnings, 'FM999,999,990'), v_currency),
    jsonb_build_object('reservation_id', p_reservation_id, 'amount', v_earnings, 'screen', 'Wallet')
  FROM groups g
  WHERE g.id = v_group_id AND g.owner_id IS NOT NULL;

  SELECT g.concierge_mode, g.country, g.name, po.phone
  INTO v_concierge, v_group_country, v_group_name, v_group_phone
  FROM groups g LEFT JOIN profiles po ON po.id = g.owner_id
  WHERE g.id = v_group_id;

  IF v_concierge THEN
    v_cc := country_code_of(v_group_country);
    INSERT INTO notifications (user_id, type, title, body, data)
    SELECT p.id, 'payment',
      '✅ Pagaron — confirma con ' || v_group_name,
      format('El cliente ya pagó el evento del %s. Llama a %s al %s para confirmarles la tocada.',
        v_res.event_date::TEXT, v_group_name, COALESCE(v_group_phone, 'sin teléfono')),
      jsonb_build_object('reservation_id', p_reservation_id, 'screen', 'AdminManagedQuotes')
    FROM profiles p
    WHERE (p.role = 'admin' AND NOT admin_is_country_muted(v_group_country, p.id))
       OR (p.role = 'admin_ops' AND p.admin_country_scope = v_cc);
  END IF;

  UPDATE payment_receipts SET
    result               = CASE WHEN p_manual THEN result ELSE 'confirmed' END,
    money_state          = 'credited',
    settlement_status    = 'credited',
    reservation_id       = p_reservation_id,
    processor_fee_minor  = p_fee_minor,
    processor_fee_status = CASE WHEN p_fee_minor IS NULL THEN 'not_captured' ELSE 'captured' END,
    fee_source           = CASE WHEN p_fee_minor IS NULL THEN NULL ELSE p_fee_source END,
    resolution           = CASE WHEN p_manual THEN 'credited_manual' ELSE resolution END,
    resolved_by          = CASE WHEN p_manual THEN p_actor ELSE resolved_by END,
    resolved_at          = CASE WHEN p_manual THEN NOW() ELSE resolved_at END,
    resolution_note      = CASE WHEN p_manual THEN p_note ELSE resolution_note END,
    updated_at           = NOW()
  WHERE id = p_receipt_id;

  IF p_attempt_id IS NOT NULL THEN
    UPDATE payment_attempts SET status = 'consumed', updated_at = NOW()
    WHERE id = p_attempt_id;
  END IF;

  RETURN jsonb_build_object(
    'currency', v_currency, 'group_earnings', v_earnings,
    'admin_bruto', v_admin_bruto, 'processor_fee', v_fee_pesos,
    'fuente', v_fuente, 'revived', v_revived
  );
END $function$;
