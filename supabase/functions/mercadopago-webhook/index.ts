// ═══════════════════════════════════════════════════════════════════
// mercadopago-webhook  –  Supabase Edge Function (sin supabase-js)
// Recibe notificaciones de Mercado Pago (IPN / Webhooks API).
//
// Cuando un pago es aprobado:
//   1. Obtiene detalles del pago desde la API de MP.
//   2. Llama a mp_credit_pending_earnings → acredita pending_balance.
//   3. Notifica al cliente y dueño del grupo.
//
// URL pública (sin auth):
//   https://<project>.supabase.co/functions/v1/mercadopago-webhook
// ═══════════════════════════════════════════════════════════════════

import { resolveRefundClaimAction, applyRefundClaimAction } from '../_shared/refund_claim_guard.ts';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, GET, OPTIONS',
};

function ok(msg = 'ok') {
  return new Response(JSON.stringify({ ok: true, message: msg }), {
    status: 200,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}

function err(msg: string) {
  return new Response(JSON.stringify({ ok: false, error: msg }), {
    status: 200,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}

// Verifica x-signature de MercadoPago (HMAC-SHA256).
// Formato del header: "ts=<timestamp>,v1=<hex_hash>"
// El mensaje firmado es: "id:<payment_id>;request-id:<uuid>;ts:<timestamp>;"
// Retorna true si la firma es válida o si el secret no está configurado (modo permisivo).
async function verifyMPSignature(
  req: Request,
  rawBody: string,
  paymentId: string | null,
): Promise<boolean> {
  const secret = Deno.env.get('MERCADOPAGO_WEBHOOK_SECRET');
  if (!secret) {
    // Sin secret configurado: loguear y continuar (no bloquear en dev/staging)
    console.warn('[WEBHOOK_SIG] MERCADOPAGO_WEBHOOK_SECRET not set — skipping signature check');
    return true;
  }

  const xSignature  = req.headers.get('x-signature') ?? '';
  const xRequestId  = req.headers.get('x-request-id') ?? '';

  if (!xSignature) {
    console.error('[INVALID_WEBHOOK_SIGNATURE] Missing x-signature header');
    return false;
  }

  // Extraer ts y v1 del header
  const parts: Record<string, string> = {};
  for (const part of xSignature.split(',')) {
    const [k, v] = part.split('=');
    if (k && v) parts[k.trim()] = v.trim();
  }
  const { ts, v1: receivedHash } = parts;
  if (!ts || !receivedHash) {
    console.error('[INVALID_WEBHOOK_SIGNATURE] Malformed x-signature:', xSignature);
    return false;
  }

  // Construir el mensaje a verificar
  const manifest = `id:${paymentId ?? ''};request-id:${xRequestId};ts:${ts};`;

  const keyBytes  = new TextEncoder().encode(secret);
  const msgBytes  = new TextEncoder().encode(manifest);
  const cryptoKey = await crypto.subtle.importKey(
    'raw', keyBytes, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign'],
  );
  const sigBuffer  = await crypto.subtle.sign('HMAC', cryptoKey, msgBytes);
  const computedHash = Array.from(new Uint8Array(sigBuffer))
    .map(b => b.toString(16).padStart(2, '0'))
    .join('');

  if (computedHash !== receivedHash) {
    console.error('[INVALID_WEBHOOK_SIGNATURE] Hash mismatch. expected=%s received=%s ts=%s',
      computedHash, receivedHash, ts);
    return false;
  }

  return true;
}

// Mercado Pago desactivado (auditoría 2026-08-08) — Stripe y Conekta son
// los únicos proveedores activos de Daricefy. Tipado como `boolean` (no
// literal `false`) a propósito: evita que TypeScript marque el resto de
// esta función como código muerto y pierda el narrowing de tipos que ya
// dependía del control de flujo existente.
const MERCADOPAGO_ACTIVE: boolean = false;

export async function handleRequest(req: Request): Promise<Response> {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });

  // Corte explícito ANTES de leer cualquier secret
  // (MERCADOPAGO_ACCESS_TOKEN/MERCADOPAGO_WEBHOOK_SECRET — ninguno de los
  // dos debe configurarse) o de intentar resolver un pago: cero RPC, cero
  // wallet, cero notificaciones financieras. 200 para que MP (si algo
  // llegara a llamar) no reintente.
  if (!MERCADOPAGO_ACTIVE) {
    return new Response(JSON.stringify({ ok: false, error: 'mercadopago_disabled', message: 'Mercado Pago ya no es un proveedor activo de Daricefy.' }), {
      status: 200,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }

  const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? '';
  const SERVICE_KEY  = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';

  const adminHeaders: Record<string, string> = {
    Authorization:  `Bearer ${SERVICE_KEY}`,
    apikey:         SERVICE_KEY,
    'Content-Type': 'application/json',
    Accept:         'application/json',
    Prefer:         'return=representation',
  };

  try {
    const urlObj = new URL(req.url);
    let paymentId: string | null = null;

    // Leer body una sola vez para no consumir el stream dos veces
    const rawBody = req.method === 'POST' ? await req.text() : '';

    // ── Formato 1: JSON body (Webhooks API nueva) ─────────────────────
    if (req.method === 'POST') {
      const contentType = req.headers.get('content-type') ?? '';
      if (contentType.includes('application/json')) {
        try {
          const body = JSON.parse(rawBody);
          console.log('Webhook body:', JSON.stringify(body));
          if (body.type === 'payment' && body.data?.id) {
            paymentId = String(body.data.id);
          }
          if (!paymentId && body.action?.startsWith('payment.') && body.data?.id) {
            paymentId = String(body.data.id);
          }
        } catch (_) { /* ignore parse errors */ }
      }
    }

    // ── Formato 2: Query params (IPN legado) ──────────────────────────
    if (!paymentId) {
      const topic = urlObj.searchParams.get('topic') ?? urlObj.searchParams.get('type');
      const id    = urlObj.searchParams.get('id');
      if ((topic === 'payment' || topic === 'merchant_order') && id) {
        paymentId = id;
      }
    }

    if (!paymentId) return ok('No payment notification, ignoring');

    // ── Verificar firma HMAC-SHA256 de MercadoPago ────────────────────
    const sigValid = await verifyMPSignature(req, rawBody, paymentId);
    if (!sigValid) {
      // Retorna 200 a MP para que no reintente, pero no procesa
      return err('Invalid webhook signature');
    }

    console.log('Processing payment ID:', paymentId);

    // ── Token MP ──────────────────────────────────────────────────────
    const mpToken = Deno.env.get('MERCADOPAGO_ACCESS_TOKEN')
      ?? Deno.env.get('mercadopago_access_token')
      ?? null;
    if (!mpToken) {
      console.error('MP token not configured');
      return err('Token not configured');
    }

    // ── Consultar pago en MP ──────────────────────────────────────────
    const mpRes = await fetch(`https://api.mercadopago.com/v1/payments/${paymentId}`, {
      headers: { Authorization: `Bearer ${mpToken}` },
    });
    if (!mpRes.ok) {
      const errText = await mpRes.text();
      console.error('MP API error:', mpRes.status, errText);
      return err('MP API error');
    }

    const payment = await mpRes.json() as any;
    const externalRefRaw = payment.external_reference as string | null;
    console.log(`Payment status="${payment.status}" | ref="${externalRefRaw}" | id=${paymentId}`);

    if (!externalRefRaw) {
      console.error('[PAYMENT_NO_REF] No external_reference in payment', paymentId);
      return ok('No reference, ignoring');
    }
    const externalRef: string = externalRefRaw;

    // ── Pagos rechazados / cancelados ─────────────────────────────────────────
    // Solo aplica a reservas (no a bid_, rec_, ad_)
    const FAILED_STATUSES  = ['rejected', 'cancelled', 'charged_back'];
    const PENDING_STATUSES = ['pending', 'in_process', 'authorized'];

    if (FAILED_STATUSES.includes(payment.status)) {
      console.log(`[PAYMENT_REJECTED] MP payment ${paymentId} status="${payment.status}" ref="${externalRef}"`);
      const isReservation = !externalRef.startsWith('bid_')
        && !externalRef.startsWith('rec_')
        && !externalRef.startsWith('ad_');
      if (isReservation) {
        await fetch(`${SUPABASE_URL}/rest/v1/reservations?id=eq.${externalRef}`, {
          method:  'PATCH',
          headers: adminHeaders,
          body:    JSON.stringify({ payment_status: 'payment_failed', updated_at: new Date().toISOString() }),
        });
        console.log(`[PAYMENT_REJECTED] Reservation ${externalRef} marked as payment_failed`);
      }
      return ok(`Payment ${payment.status} — reservation marked as payment_failed`);
    }

    if (PENDING_STATUSES.includes(payment.status)) {
      console.log(`[PAYMENT_PENDING] MP payment ${paymentId} status="${payment.status}" ref="${externalRef}" — awaiting confirmation`);
      return ok(`Payment pending — no action yet`);
    }

    if (payment.status === 'refunded') {
      console.log(`[PAYMENT_REFUNDED] MP payment ${paymentId} ref="${externalRef}" amount=$${payment.transaction_amount}`);
      const isReservation = !externalRef.startsWith('bid_')
        && !externalRef.startsWith('rec_')
        && !externalRef.startsWith('ad_');
      if (isReservation) {
        // P1F: NUNCA asumir que este refund es 'full'. Se consulta el
        // claim (creado por process-refund ANTES de llamar a MercadoPago)
        // para saber si en realidad es una cancelación de cliente o de
        // grupo — y en ese caso completar settle_cancellation/
        // settle_group_cancellation directamente (nunca la RPC genérica),
        // sin importar si este webhook ganó la carrera contra
        // process-refund o llegó después.
        const decision = await resolveRefundClaimAction(SUPABASE_URL, SERVICE_KEY, 'mercadopago', paymentId);

        if (decision.action === 'already_done') {
          console.log(`[MP Webhook] claim=${decision.claimId} ya estaba 'done' — idempotente, sin cambios (reserva=${externalRef})`);
        } else {
          const outcome = await applyRefundClaimAction(
            SUPABASE_URL, SERVICE_KEY, externalRef, null, payment.transaction_amount ?? null, decision,
            { provider: 'mercadopago', providerPaymentId: paymentId },
          );
          if (!outcome.ok) {
            console.error(`[MP Webhook] Error ${outcome.rpc} (decision=${decision.action}):`, JSON.stringify(outcome.result));
          } else if (outcome.rpc === 'none_fail_closed') {
            console.warn(`[MP Webhook] FAIL CLOSED — sin claim, sin RPC contable ejecutada (reserva=${externalRef}) logged=${outcome.result.logged} notified=${outcome.result.notified}`);
          } else {
            const skipped = 'skipped' in outcome && outcome.skipped;
            console.log(`[MP Webhook] ${outcome.rpc}${skipped ? ' (skip, ya liquidado por otra vía)' : ''}: reserva=${externalRef} decision=${decision.action}`, JSON.stringify(outcome.result));
          }
        }

        fetch(`${SUPABASE_URL}/rest/v1/rpc/log_payment_event`, {
          method:  'POST',
          headers: adminHeaders,
          body:    JSON.stringify({
            p_mp_payment_id:  String(payment.id),
            p_external_ref:   externalRef,
            p_reservation_id: externalRef,
            p_mp_status:      'refunded',
            p_mp_amount:      payment.transaction_amount ?? null,
            p_event_type:     'webhook_refunded',
          }),
        }).catch((e: unknown) => console.error('[log_payment_event]', e));
      }
      return ok('Payment refunded — wallet reversed');
    }

    if (payment.status !== 'approved') {
      console.log(`[PAYMENT_UNKNOWN] MP payment ${paymentId} status="${payment.status}" ref="${externalRef}"`);
      return ok(`Unknown payment status "${payment.status}" — ignoring`);
    }

    console.log(`[PAYMENT_APPROVED] MP payment ${paymentId} amount=$${payment.transaction_amount} ref="${externalRef}"`);

    // ── ¿Es pago de posicionamiento (bid)? ────────────────────────────
    if (externalRef.startsWith('bid_')) {
      const orderId = externalRef.slice(4);
      console.log('Processing bid payment for order:', orderId);

      const rpcRes = await fetch(`${SUPABASE_URL}/rest/v1/rpc/confirm_bid_payment`, {
        method:  'POST',
        headers: adminHeaders,
        body:    JSON.stringify({ p_order_id: orderId, p_mp_payment_id: String(payment.id) }),
      });
      const rpcResult = await rpcRes.json() as any;
      console.log('confirm_bid_payment result:', JSON.stringify(rpcResult));

      if (rpcResult?.skipped) return ok('Bid already activated (idempotent)');
      if (!rpcResult?.ok) return ok(`Bid payment error: ${rpcResult?.error ?? 'unknown'}`);

      return ok('Bid payment processed');
    }

    // ── ¿Es pago de recomendación? ───────────────────────────────────
    if (externalRef.startsWith('rec_')) {
      const orderId = externalRef.slice(4);
      console.log('Processing recommendation payment for order:', orderId);

      const rpcRes = await fetch(`${SUPABASE_URL}/rest/v1/rpc/confirm_recommendation_payment`, {
        method:  'POST',
        headers: adminHeaders,
        body:    JSON.stringify({ p_order_id: orderId, p_mp_payment_id: String(payment.id) }),
      });
      const rpcResult = await rpcRes.json() as any;
      console.log('confirm_recommendation_payment result:', JSON.stringify(rpcResult));

      if (rpcResult?.skipped) return ok('Recommendation already activated (idempotent)');
      if (!rpcResult?.ok) return ok(`Recommendation payment error: ${rpcResult?.error ?? 'unknown'}`);

      return ok('Recommendation payment processed');
    }

    // ── ¿Es pago de anuncio? ─────────────────────────────────────────
    if (externalRef.startsWith('ad_')) {
      const adId = externalRef.slice(3);
      console.log('Processing ad payment for ad:', adId);

      await fetch(`${SUPABASE_URL}/rest/v1/advertisements?id=eq.${adId}`, {
        method:  'PATCH',
        headers: adminHeaders,
        body:    JSON.stringify({ status: 'pending_review', mp_payment_id: String(payment.id) }),
      });

      return ok('Ad payment processed');
    }

    const reservationId = externalRef;

    // ── Obtener estado actual de la reserva ───────────────────────────
    const resStatusRes = await fetch(
      `${SUPABASE_URL}/rest/v1/reservations?id=eq.${reservationId}&select=payment_status,payment_mode,client_id,event_date,total_price,group_id,installment_months,installment_plan`,
      { headers: adminHeaders },
    );
    const resStatusArr = await resStatusRes.json() as any[];
    const reservation = resStatusArr?.[0] ?? null;
    const currentPaymentStatus = reservation?.payment_status ?? null;
    const paymentMode = reservation?.payment_mode ?? 'deposit'; // backward compat

    console.log('payment_status:', currentPaymentStatus, '| payment_mode:', paymentMode);

    // Idempotencia: ya procesado
    if (['paid', 'fully_paid', 'deposit_paid'].includes(currentPaymentStatus)) {
      console.log(`[PAYMENT_DUPLICATE_IGNORED] MP payment ${paymentId} already processed for reservation ${reservationId} (status: ${currentPaymentStatus})`);
      return ok('Already processed (idempotent)');
    }

    // ── Reconciliación financiera ─────────────────────────────────────────────
    const mpAmount       = (payment.transaction_amount as number) ?? null;
    const expectedAmount = (reservation.total_price as number) ?? null;

    if (mpAmount !== null && expectedAmount !== null) {
      const diff = Math.abs(mpAmount - expectedAmount);
      if (diff > 1) {
        console.error(`[PAYMENT_MISMATCH] reservation=${reservationId} expected=$${expectedAmount} received=$${mpAmount} diff=$${diff.toFixed(2)} mp_id=${paymentId}`);
      }
    }

    // Registrar evento en payment_event_logs (async — no bloquea flujo)
    fetch(`${SUPABASE_URL}/rest/v1/rpc/log_payment_event`, {
      method:  'POST',
      headers: adminHeaders,
      body:    JSON.stringify({
        p_mp_payment_id:     String(payment.id),
        p_external_ref:      reservationId,
        p_reservation_id:    reservationId,
        p_mp_status:         'approved',
        p_mp_amount:         mpAmount,
        p_expected_amount:   expectedAmount,
        p_payment_mode:      reservation.payment_mode ?? paymentMode,
        p_installment_months: reservation.installment_months ?? null,
        p_installment_plan:  reservation.installment_plan ?? null,
        p_event_type:        'approved',
      }),
    }).catch((e: unknown) => console.error('[log_payment_event] error:', e));

    let rpcResult: any;

    if (paymentMode === 'full') {
      // ── Pago completo: wallet profesional ────────────────────────────
      const rpcRes = await fetch(`${SUPABASE_URL}/rest/v1/rpc/confirm_full_payment_and_credit_wallet`, {
        method:  'POST',
        headers: adminHeaders,
        body:    JSON.stringify({
          p_reservation_id: reservationId,
          p_mp_payment_id:  String(payment.id),
          p_amount_paid:    payment.transaction_amount ?? null,
        }),
      });
      rpcResult = await rpcRes.json() as any;
      console.log('confirm_full_payment_and_credit_wallet result:', JSON.stringify(rpcResult));
    } else {
      // ── Pago de anticipo (legacy): flow original ──────────────────────
      const isDeposit = currentPaymentStatus !== 'deposit_paid';
      const rpcRes = await fetch(`${SUPABASE_URL}/rest/v1/rpc/mp_credit_pending_earnings`, {
        method:  'POST',
        headers: adminHeaders,
        body:    JSON.stringify({
          p_reservation_id: reservationId,
          p_payment_id:     String(payment.id),
          p_amount_paid:    payment.transaction_amount ?? null,
          p_is_deposit:     isDeposit,
        }),
      });
      rpcResult = await rpcRes.json() as any;
      console.log('mp_credit_pending_earnings result:', JSON.stringify(rpcResult));
    }

    if (rpcResult?.skipped) {
      console.log(`[PAYMENT_DUPLICATE_IGNORED] RPC skipped for reservation ${reservationId} — already processed`);
      return ok('Already processed (idempotent)');
    }

    // ── Notificaciones ────────────────────────────────────────────────
    if (reservation) {
      const amountPaid = payment.transaction_amount ?? reservation.total_price ?? 0;
      const eventDate  = reservation.event_date ?? '';
      const amountFmt  = Number(amountPaid).toLocaleString('es-MX');

      let ownerId: string | null = null;
      let groupName = 'el grupo';
      if (reservation.group_id) {
        const grpRes = await fetch(
          `${SUPABASE_URL}/rest/v1/groups?id=eq.${reservation.group_id}&select=owner_id,name`,
          { headers: adminHeaders },
        );
        const grpArr = await grpRes.json() as any[];
        ownerId   = grpArr?.[0]?.owner_id ?? null;
        groupName = grpArr?.[0]?.name ?? groupName;
      }

      const clientTitle = paymentMode === 'full'
        ? '✅ Pago confirmado'
        : '✅ Anticipo confirmado';
      const clientBody  = paymentMode === 'full'
        ? `Tu pago de $${amountFmt} MXN fue confirmado. ¡Tu evento del ${eventDate} con ${groupName} está asegurado!`
        : `Tu anticipo de $${amountFmt} MXN fue confirmado. ¡Tu evento del ${eventDate} está asegurado!`;

      const notifs: any[] = [
        {
          user_id: reservation.client_id,
          type:    'payment',
          title:   clientTitle,
          body:    clientBody,
          data:    { reservation_id: reservationId, screen: 'Reservations' },
        },
      ];

      if (ownerId) {
        notifs.push({
          user_id: ownerId,
          type:    'payment',
          title:   '💰 Pago recibido',
          body:    `El cliente pagó $${amountFmt} MXN para el evento del ${eventDate}. El dinero se acreditará a tu billetera al finalizar el evento.`,
          data:    { reservation_id: reservationId, screen: 'Wallet' },
        });
      }

      await fetch(`${SUPABASE_URL}/rest/v1/notifications`, {
        method:  'POST',
        headers: adminHeaders,
        body:    JSON.stringify(notifs),
      });
    }

    console.log('[PAYMENT_DONE] Webhook processed. Reservation:', reservationId, '| mode:', paymentMode);
    return ok('Payment processed');

  } catch (e: unknown) {
    const msg = e instanceof Error ? e.message : 'Internal error';
    console.error('Webhook internal error:', msg);
    return err(msg);
  }
}

if (import.meta.main) {
  Deno.serve(handleRequest);
}
