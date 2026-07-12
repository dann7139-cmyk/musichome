// ═══════════════════════════════════════════════════════════════════
// process-refund  –  Supabase Edge Function  (C1: bi-proveedor)
// Emite un reembolso real y revierte el wallet del grupo.
//
// Detección de proveedor por el id guardado en reservations.mp_payment_id:
//   · 'pi_...'  → Stripe (flujo actual de cobro — PaymentIntent)
//   · numérico  → MercadoPago (legacy)
//
// POST (autenticado como admin o cliente dueño pre-evento):
//   { reservation_id, refund_amount?, idempotency_key?, mode? }
//     · mode 'full' (default) → reembolso total/parcial + reversión completa
//       de wallet (process_refund_reversal). Para no-show/admin/disputa.
//     · mode 'cancellation' → C2a: el monto a reembolsar lo calcula el
//       servidor (compute_cancellation_charge, tiers por proximidad),
//       IGNORA refund_amount del cliente, y liquida con settle_cancellation
//       (el grupo conserva su compensación, Daricefy su parte).
//     · idempotency_key opcional ('dispute-{id}', 'cancel-{id}', 'noshow-{id}').
//       Default: 'refund-{reservation_id}-{centavos}' — reintentar con el
//       mismo monto NUNCA duplica el reembolso (Stripe lo garantiza).
//
// Respuesta: { ok, provider, refund_id, amount, reservation_id, mode, breakdown? }
// Los fallos se auditan en payment_event_logs (refund_failed).
// ═══════════════════════════════════════════════════════════════════

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

function jsonRes(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });

  const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? '';
  const SERVICE_KEY  = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
  const mpToken      = Deno.env.get('MERCADOPAGO_ACCESS_TOKEN')
    ?? Deno.env.get('mercadopago_access_token')
    ?? '';
  const stripeKey    = Deno.env.get('STRIPE_SECRET_KEY') ?? '';
  const conektaKey   = Deno.env.get('CONEKTA_PRIVATE_KEY') ?? '';

  // admin client (service_role) — used for DB operations and JWT verification
  const admin = createClient(SUPABASE_URL, SERVICE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const serviceHeaders: Record<string, string> = {
    Authorization:  `Bearer ${SERVICE_KEY}`,
    apikey:         SERVICE_KEY,
    'Content-Type': 'application/json',
    Prefer:         'return=representation',
  };

  // Auditoría compartida (éxitos y fallos) — fire-and-forget
  const logPaymentEvent = (paymentId: string, reservationId: string, eventType: string, amount: number, notes: string) => {
    fetch(`${SUPABASE_URL}/rest/v1/rpc/log_payment_event`, {
      method:  'POST',
      headers: serviceHeaders,
      body:    JSON.stringify({
        p_mp_payment_id:  paymentId,
        p_external_ref:   reservationId,
        p_reservation_id: reservationId,
        p_mp_status:      eventType === 'refund_issued' ? 'refunded'
                        : eventType === 'refund_manual_pending' ? 'manual_pending'
                        : 'refund_failed',
        p_mp_amount:      amount,
        p_event_type:     eventType,
        p_notes:          notes,
      }),
    }).catch((e: unknown) => console.error('[log_payment_event]', e));
  };

  try {
    // ── Autenticar (verificación criptográfica via Supabase Auth) ─────
    const authHeader = req.headers.get('Authorization');
    if (!authHeader?.startsWith('Bearer ')) {
      return jsonRes({ error: 'No autorizado' }, 401);
    }
    const token = authHeader.slice(7);

    const { data: authData, error: authErr } = await admin.auth.getUser(token);
    if (authErr || !authData?.user) {
      console.warn('[process-refund] JWT rejected:', authErr?.message ?? 'no user');
      return jsonRes({ error: 'Token inválido o expirado' }, 401);
    }
    const callerId = authData.user.id;

    // ── Body ──────────────────────────────────────────────────────────
    const body = await req.json().catch(() => ({})) as {
      reservation_id?:  string;
      refund_amount?:   number;
      idempotency_key?: string;
      //   'group_cancellation' → el GRUPO cancela: reembolso 100% al cliente
      //   + strike y castigos (settle_group_cancellation, sql/480)
      mode?:            'full' | 'cancellation' | 'group_cancellation';
      // Datos bancarios del cliente para reembolso MANUAL (SPEI/efectivo)
      clabe?:           string;
      account_holder?:  string;
      bank_name?:       string;
    };
    const { reservation_id, refund_amount } = body;
    const mode = body.mode ?? 'full';
    if (!reservation_id) return jsonRes({ error: 'reservation_id requerido' }, 400);

    // ── Cargar reserva ────────────────────────────────────────────────
    const { data: reservation, error: resErr } = await admin
      .from('reservations')
      .select('id,total_price,base_price,client_id,payment_status,payout_status,mp_payment_id,payment_provider,payment_method_type,event_date,group_id')
      .eq('id', reservation_id)
      .single();

    if (resErr || !reservation) return jsonRes({ error: 'Reserva no encontrada' }, 404);

    // ── Permisos ──────────────────────────────────────────────────────
    const { data: callerProfile } = await admin
      .from('profiles')
      .select('role')
      .eq('id', callerId)
      .single();

    const isAdmin  = callerProfile?.role === 'admin';
    const isClient = (reservation.client_id as string) === callerId;
    const isPre    = new Date(reservation.event_date as string) > new Date();

    if (mode === 'group_cancellation') {
      // Solo el DUEÑO del grupo (o admin) puede cancelar como grupo
      const { data: grp } = await admin
        .from('groups')
        .select('owner_id')
        .eq('id', reservation.group_id)
        .single();
      const isGroupOwner = grp?.owner_id === callerId;
      if (!isAdmin && !isGroupOwner) {
        return jsonRes({ error: 'Solo el dueño del grupo puede cancelar como grupo' }, 403);
      }
      if (!isAdmin && !isPre) {
        return jsonRes({ error: 'El evento ya pasó — no se puede cancelar' }, 422);
      }
    } else if (!isAdmin && !(isClient && isPre)) {
      return jsonRes({ error: 'Sin permiso para emitir reembolso' }, 403);
    }

    // ── Validaciones ──────────────────────────────────────────────────
    const paymentId = String(reservation.mp_payment_id ?? '');
    if (!paymentId) {
      return jsonRes({ error: 'No hay pago registrado para esta reserva' }, 422);
    }
    // Proveedor: por columna payment_provider, con fallback al prefijo del id.
    // pi_ → Stripe | ord_ → Conekta | numérico → MercadoPago
    const provider  = String((reservation as any).payment_provider ?? '');
    const isConekta = provider === 'conekta' || paymentId.startsWith('ord_');
    const isStripe  = !isConekta && (provider === 'stripe' || paymentId.startsWith('pi_'));

    if (!['paid', 'fully_paid', 'deposit_paid'].includes(reservation.payment_status as string)) {
      return jsonRes({ error: 'La reserva no tiene un pago confirmado' }, 422);
    }

    if (reservation.payout_status === 'refunded') {
      return jsonRes({ error: 'Esta reserva ya fue reembolsada' }, 422);
    }

    if (reservation.payout_status === 'released') {
      return jsonRes({ error: 'No se puede reembolsar: el pago ya fue liberado al grupo' }, 422);
    }

    const totalPrice = reservation.total_price as number;

    // ── Monto a reembolsar ────────────────────────────────────────────
    // mode 'cancellation': el servidor manda (tiers de proximidad), se
    // ignora cualquier refund_amount del cliente. mode 'full': el que venga.
    let amountToRef: number;
    let cancellationCharge: any = null;
    if (mode === 'group_cancellation') {
      // El grupo cancela → el cliente SIEMPRE recupera el 100%
      amountToRef = totalPrice;
    } else if (mode === 'cancellation') {
      const { data: charge, error: chargeErr } = await admin
        .rpc('compute_cancellation_charge', { p_reservation_id: reservation_id });
      if (chargeErr || !charge?.ok) {
        return jsonRes({ error: charge?.error ?? chargeErr?.message ?? 'No se pudo calcular el cargo' }, 422);
      }
      cancellationCharge = charge;
      amountToRef = Number(charge.refund_amount);
      if (amountToRef <= 0) {
        // tier not_paid o reembolso 0 → no hay refund que emitir; solo liquidar
        const { data: settled, error: settleErr } = await admin
          .rpc('settle_cancellation', { p_reservation_id: reservation_id, p_refund_id: null });
        if (settleErr || settled?.ok === false) {
          return jsonRes({ error: settled?.error ?? settleErr?.message ?? 'No se pudo liquidar' }, 422);
        }
        return jsonRes({ ok: true, mode, provider: 'none', refund_id: null, amount: 0, reservation_id, breakdown: cancellationCharge });
      }
    } else {
      amountToRef = refund_amount ?? totalPrice;
    }

    if (amountToRef <= 0) {
      return jsonRes({ error: 'El monto del reembolso debe ser mayor a $0' }, 422);
    }
    if (amountToRef > totalPrice) {
      return jsonRes({ error: `El reembolso ($${amountToRef}) excede el total ($${totalPrice})` }, 422);
    }

    console.log(`[REFUND_INIT] reservation=${reservation_id} provider=${isConekta ? 'conekta' : isStripe ? 'stripe' : 'mercadopago'} payment=${paymentId} amount=$${amountToRef} by=${isAdmin ? 'admin' : 'client'}`);

    // ── Ruta MANUAL (SPEI/efectivo por Conekta) ───────────────────────
    // Conekta solo reembolsa por API los pagos con TARJETA. Para SPEI y
    // efectivo: la cancelación y la reversión de wallet se completan igual,
    // y la devolución entra a la cola manual_refunds (transferencia del
    // admin, promesa de 5 días hábiles). El cliente NUNCA ve un error.
    const methodType = String((reservation as any).payment_method_type ?? '').toLowerCase();

    const settleManual = async (apiError: string | null): Promise<Response> => {
      // 1. Liquidar en DB (idéntico al camino automático)
      let settleResult: any;
      if (mode === 'cancellation' || mode === 'group_cancellation') {
        const settleFn = mode === 'group_cancellation'
          ? 'settle_group_cancellation' : 'settle_cancellation';
        const r = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${settleFn}`, {
          method: 'POST', headers: serviceHeaders,
          body: JSON.stringify({ p_reservation_id: reservation_id, p_refund_id: 'manual-pending' }),
        });
        settleResult = await r.json();
        if (!r.ok || settleResult?.ok === false) {
          return jsonRes({ error: settleResult?.error ?? 'No se pudo liquidar la cancelación' }, 422);
        }
      } else {
        const r = await fetch(`${SUPABASE_URL}/rest/v1/rpc/process_refund_reversal`, {
          method: 'POST', headers: serviceHeaders,
          body: JSON.stringify({
            p_reservation_id: reservation_id,
            p_mp_refund_id:   'manual-pending',
            p_refund_amount:  amountToRef,
          }),
        });
        settleResult = await r.json();
      }

      // 2. Encolar el reembolso manual (idempotente: 1 por reserva)
      const { data: mr, error: mrErr } = await admin.rpc('create_manual_refund', {
        p_reservation_id: reservation_id,
        p_amount:         amountToRef,
        p_method:         ['spei', 'cash'].includes(methodType) ? methodType : 'unknown',
        p_clabe:          body.clabe ?? null,
        p_account_holder: body.account_holder ?? null,
        p_bank_name:      body.bank_name ?? null,
        p_api_error:      apiError,
      });
      if (mrErr || mr?.ok === false) {
        console.error('[REFUND_MANUAL] create_manual_refund falló:', mrErr?.message ?? JSON.stringify(mr));
        return jsonRes({ error: mr?.error ?? mrErr?.message ?? 'No se pudo registrar el reembolso manual' }, 500);
      }
      const dueDate = mr?.due_date ?? null;

      // 3. Auditoría (incluye el error original de la API si fue fallback)
      logPaymentEvent(paymentId, reservation_id, 'refund_manual_pending', amountToRef,
        `Reembolso manual ${methodType || 'unknown'} encolado (due ${dueDate})` +
        (apiError ? ` — API error original: ${apiError}` : ''));

      // 4. Notificar al cliente (promesa de 5 días hábiles)
      const last4 = body.clabe ? ` a tu cuenta terminación ${String(body.clabe).slice(-4)}` : '';
      const introTxt = mode === 'group_cancellation'
        ? 'El grupo canceló tu evento — recuperas el 100% de tu pago.'
        : 'Tu reserva fue cancelada.';
      const bankTxt = body.clabe
        ? `se enviará por transferencia bancaria${last4} en un máximo de 5 días hábiles.`
        : 'se enviará por transferencia bancaria en un máximo de 5 días hábiles — te contactaremos para confirmar tu cuenta.';
      await admin.from('notifications').insert({
        user_id: reservation.client_id,
        type:    'payment',
        title:   '💸 Reembolso en proceso',
        body:    `${introTxt} Como pagaste por ${methodType === 'cash' ? 'efectivo' : 'transferencia'}, tu reembolso de $${Number(amountToRef).toLocaleString('es-MX')} MXN ${bankTxt}`,
        data:    { reservation_id, screen: 'Reservations', manual_refund_id: mr?.id ?? null },
      });

      return jsonRes({
        ok:            true,
        mode,
        provider:      'conekta',
        refund_mode:   'manual_pending',
        refund_id:     null,
        amount:        amountToRef,
        due_date:      dueDate,
        reservation_id,
        breakdown:     cancellationCharge,
      });
    };

    if (isConekta && ['spei', 'cash'].includes(methodType)) {
      return await settleManual(null);
    }

    // ── Emitir el reembolso según proveedor ───────────────────────────
    let refundId = '';

    if (isStripe) {
      if (!stripeKey) return jsonRes({ error: 'STRIPE_SECRET_KEY no configurado' }, 500);

      // Stripe cobra/reembolsa en CENTAVOS (mismas unidades que el cobro
      // original de create-payment-intent)
      const amountCentavos = Math.round(amountToRef * 100);
      const idemKey = body.idempotency_key
        ?? (mode === 'cancellation' || mode === 'group_cancellation'
              ? `cancel-${reservation_id}`
              : `refund-${reservation_id}-${amountCentavos}`);

      const form = new URLSearchParams();
      form.set('payment_intent', paymentId);
      form.set('amount', String(amountCentavos));
      form.set('metadata[reservation_id]', reservation_id);
      form.set('metadata[issued_by]', isAdmin ? 'admin' : mode === 'group_cancellation' ? 'group' : 'client');

      const stripeRes = await fetch('https://api.stripe.com/v1/refunds', {
        method:  'POST',
        headers: {
          Authorization:     `Bearer ${stripeKey}`,
          'Content-Type':    'application/x-www-form-urlencoded',
          'Idempotency-Key': idemKey,
        },
        body: form,
      });

      const stripeData = await stripeRes.json() as any;

      if (!stripeRes.ok) {
        const msg = stripeData?.error?.message ?? 'Error al procesar reembolso en Stripe';
        console.error('[REFUND_ERROR] Stripe refund failed:', JSON.stringify(stripeData));
        logPaymentEvent(paymentId, reservation_id, 'refund_failed', amountToRef, `Stripe: ${msg}`);
        return jsonRes({ error: msg, provider: 'stripe' }, 502);
      }

      refundId = String(stripeData.id);   // re_...
      console.log(`[REFUND_ISSUED] stripe_refund=${refundId} reservation=${reservation_id} amount=$${amountToRef} idem=${idemKey}`);

    } else if (isConekta) {
      // ── Conekta ──────────────────────────────────────────────────────
      if (!conektaKey) return jsonRes({ error: 'CONEKTA_PRIVATE_KEY no configurado' }, 500);
      const amountCentavos = Math.round(amountToRef * 100);
      const auth = btoa(`${conektaKey}:`);
      const ckRes = await fetch(`https://api.conekta.io/orders/${paymentId}/refunds`, {
        method:  'POST',
        headers: {
          'Accept':        'application/vnd.conekta-v2.1.0+json',
          'Content-Type':  'application/json',
          'Authorization': `Basic ${auth}`,
        },
        body: JSON.stringify({ reason: 'requested_by_client', amount: amountCentavos }),
      });
      const ckData = await ckRes.json() as any;
      if (!ckRes.ok) {
        const msg = ckData?.details?.[0]?.message ?? 'Error al procesar reembolso en Conekta';
        console.error('[REFUND_ERROR] Conekta refund failed:', JSON.stringify(ckData));
        logPaymentEvent(paymentId, reservation_id, 'refund_failed', amountToRef, `Conekta: ${msg}`);
        // Red de seguridad: si el método NO es tarjeta (o es desconocido en
        // reservas viejas sin payment_method_type), el rechazo de la API es
        // esperado → convertir a reembolso MANUAL en lugar de atorar al
        // cliente en "Reintentar". El error original ya quedó auditado.
        if (methodType !== 'card') {
          console.warn('[REFUND_FALLBACK] método no reembolsable por API → cola manual');
          return await settleManual(msg);
        }
        return jsonRes({ error: msg, provider: 'conekta' }, 502);
      }
      refundId = String(ckData?.id ?? ckData?.charges?.data?.[0]?.id ?? `conekta-refund-${reservation_id}`);
      console.log(`[REFUND_ISSUED] conekta_refund=${refundId} reservation=${reservation_id} amount=$${amountToRef}`);

    } else {
      // ── MercadoPago (legacy) ─────────────────────────────────────────
      const mpRefundRes = await fetch(
        `https://api.mercadopago.com/v1/payments/${paymentId}/refunds`,
        {
          method:  'POST',
          headers: {
            Authorization:  `Bearer ${mpToken}`,
            'Content-Type': 'application/json',
          },
          body: JSON.stringify({ amount: amountToRef }),
        },
      );

      const mpRefund = await mpRefundRes.json() as any;

      if (!mpRefundRes.ok) {
        const msg = mpRefund?.message ?? 'Error al procesar reembolso en MercadoPago';
        console.error('[REFUND_ERROR] MP refund failed:', JSON.stringify(mpRefund));
        logPaymentEvent(paymentId, reservation_id, 'refund_failed', amountToRef, `MP: ${msg}`);
        return jsonRes({ error: msg, provider: 'mercadopago' }, 502);
      }

      refundId = String(mpRefund.id);
      console.log(`[REFUND_ISSUED] mp_refund_id=${refundId} reservation=${reservation_id} amount=$${amountToRef}`);
    }

    // ── Liquidar en la BD (atómico via RPC) ──────────────────────────
    // cancellation → settle_cancellation (grupo conserva compensación).
    // full → process_refund_reversal (reversión completa).
    let rpcResult: any;
    if (mode === 'cancellation' || mode === 'group_cancellation') {
      const settleFn = mode === 'group_cancellation'
        ? 'settle_group_cancellation' : 'settle_cancellation';
      const settleRes = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${settleFn}`, {
        method:  'POST',
        headers: serviceHeaders,
        body:    JSON.stringify({ p_reservation_id: reservation_id, p_refund_id: refundId }),
      });
      rpcResult = await settleRes.json();
      console.log(`[${settleFn}]`, JSON.stringify(rpcResult));
    } else {
      const rpcRes = await fetch(`${SUPABASE_URL}/rest/v1/rpc/process_refund_reversal`, {
        method:  'POST',
        headers: serviceHeaders,
        body:    JSON.stringify({
          p_reservation_id: reservation_id,
          p_mp_refund_id:   refundId,
          p_refund_amount:  amountToRef,
        }),
      });
      rpcResult = await rpcRes.json();
      console.log('[process_refund_reversal]', JSON.stringify(rpcResult));
    }

    // ── Audit log ─────────────────────────────────────────────────────
    logPaymentEvent(
      paymentId, reservation_id, 'refund_issued', amountToRef,
      `Refund ${isStripe ? 'Stripe' : isConekta ? 'Conekta' : 'MP'}:${refundId} by ${isAdmin ? 'admin' : 'client'}(${callerId})`,
    );

    // ── Notificar al cliente ──────────────────────────────────────────
    await admin.from('notifications').insert({
      user_id: reservation.client_id,
      type:    'payment',
      title:   '💸 Reembolso emitido',
      body:    (mode === 'group_cancellation'
        ? `El grupo canceló tu evento — recuperas el 100%. Se emitió un reembolso de $${Number(amountToRef).toLocaleString('es-MX')} MXN a tu método de pago; aparecerá en tu cuenta en 3-10 días hábiles.`
        : `Se emitió un reembolso de $${Number(amountToRef).toLocaleString('es-MX')} MXN. Aparecerá en tu cuenta en 3-10 días hábiles.`),
      data:    { reservation_id, screen: 'Reservations' },
    });

    return jsonRes({
      ok:            true,
      mode,
      provider:      isStripe ? 'stripe' : isConekta ? 'conekta' : 'mercadopago',
      refund_id:     refundId,
      amount:        amountToRef,
      reservation_id,
      breakdown:     cancellationCharge,
    });

  } catch (e: unknown) {
    const msg = e instanceof Error ? e.message : 'Error interno';
    console.error('[process-refund] Error:', msg);
    return jsonRes({ error: msg }, 500);
  }
});
