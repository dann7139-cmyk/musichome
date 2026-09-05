// ═══════════════════════════════════════════════════════════════════
// conekta-webhook  —  Supabase Edge Function (Conekta, MX)
//
// Fuente de verdad del pago. En `order.paid`:
//   1. verifyConektaPayment(orderId) → RE-CONSULTA la orden en la API de
//      Conekta (no confía en el payload) y confirma que está PAGADA.
//      ⇩ Encapsulado a propósito: mañana se puede cambiar por verificación
//        de firma oficial de Conekta SIN tocar el resto del webhook.
//   2. confirm_full_payment_and_credit_wallet(...) — la MISMA RPC que Stripe.
//      Es IDEMPOTENTE (guard payment_status IN paid/fully_paid + FOR UPDATE),
//      así que reenvíos de order.paid NUNCA acreditan dos veces.
//   3. reservations.payment_provider = 'conekta'.
//
// NO toca wallet, GPS, liberaciones ni anti-fraude — solo dispara la misma
// acreditación. Deploy con Verify JWT = OFF (Conekta no manda JWT).
// ═══════════════════════════════════════════════════════════════════

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, digest',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? '';
const SERVICE_KEY  = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
const PRIVATE_KEY  = Deno.env.get('CONEKTA_PRIVATE_KEY') ?? '';

const serviceHeaders: Record<string, string> = {
  Authorization:  `Bearer ${SERVICE_KEY}`,
  apikey:         SERVICE_KEY,
  'Content-Type': 'application/json',
};

// ── Verificación de pago (ENCAPSULADA) ───────────────────────────────
// v1: re-consulta la orden en Conekta y confirma que está pagada.
// Futuro: reemplazar el cuerpo por verificación de firma sin tocar el webhook.
async function verifyConektaPayment(orderId: string): Promise<{
  paid: boolean; amountCentavos: number; reservationId: string | null; methodType: string | null;
  feeCentavos: number | null; plusGroupId: string | null;
  promoKind: string | null; promoId: string | null;
  giftOrderId: string | null;
  chargeId: string | null; currency: string;
}> {
  const auth = btoa(`${PRIVATE_KEY}:`);
  const res = await fetch(`https://api.conekta.io/orders/${orderId}`, {
    headers: {
      'Accept':        'application/vnd.conekta-v2.1.0+json',
      'Authorization': `Basic ${auth}`,
    },
  });
  if (!res.ok) {
    console.error('[conekta-webhook] verify: no se pudo consultar la orden', orderId, res.status);
    return { paid: false, amountCentavos: 0, reservationId: null, methodType: null, feeCentavos: null, plusGroupId: null, promoKind: null, promoId: null, giftOrderId: null, chargeId: null, currency: 'MXN' };
  }
  const order = await res.json() as any;

  // Método real con el que se pagó (card / spei / cash). Los reembolsos por
  // API solo existen para tarjeta; SPEI/efectivo van a la cola manual.
  const charge  = order?.charges?.data?.[0] ?? {};
  const rawType = String(charge?.payment_method?.type ?? '').toLowerCase();
  const methodType =
    rawType.includes('spei') || rawType.includes('bank')            ? 'spei' :
    rawType.includes('cash') || rawType.includes('oxxo')            ? 'cash' :
    rawType.includes('card')                                        ? 'card' :
    rawType || null;

  // 💰 Comisión REAL de Conekta (Fase 0.3 — cero estimaciones): el charge
  // trae `fee` en centavos. Si Conekta no lo manda, queda null → la BD
  // conserva NULL y los reportes lo muestran como "No capturado".
  const rawFee = Number(charge?.fee);
  const feeCentavos = Number.isFinite(rawFee) && rawFee > 0 ? rawFee : null;

  return {
    paid:          order?.payment_status === 'paid',
    amountCentavos: Number(order?.amount ?? 0),
    reservationId: order?.metadata?.reservation_id ?? null,
    methodType,
    feeCentavos,
    // 🏆 Orden de Verificación Plus anual (create-plus-conekta-order)
    plusGroupId:   order?.metadata?.plus_group_id ?? null,
    // 📣 Orden de publicidad (create-promo-conekta-order): ad | bid | rec
    promoKind:     order?.metadata?.promo_kind ?? null,
    promoId:       order?.metadata?.promo_id ?? null,
    // 🎁 Orden de regalo/donación a un grupo (create-gift-order)
    giftOrderId:   order?.metadata?.gift_order_id ?? null,
    // F2.2: identidad normalizada — provider_payment_id del gate = el
    // CHARGE (no la orden). charge.id existe aun sin fee capturado.
    chargeId:      charge?.id ?? null,
    currency:      String(order?.currency ?? 'MXN').toUpperCase(),
  };
}

// ── 📣 Confirmar publicidad pagada con Conekta ───────────────────────
// MISMOS RPCs (idempotentes) que usa el webhook de Stripe. Verifica que
// lo COBRADO cubra el monto de la orden antes de activar.
async function confirmPromoPayment(
  orderId: string, kind: string, id: string, paidCentavos: number,
): Promise<boolean> {
  const paidMxn = paidCentavos / 100;

  const TABLE_AMOUNT: Record<string, { table: string; col: string; rpc: string; param: string }> = {
    rec: { table: 'recommendation_orders', col: 'amount',          rpc: 'confirm_recommendation_payment', param: 'p_order_id' },
    bid: { table: 'bid_orders',            col: 'amount',          rpc: 'confirm_bid_payment',            param: 'p_order_id' },
    ad:  { table: 'advertisements',        col: 'effective_price', rpc: 'mark_ad_payment',                param: 'p_ad_id' },
  };
  const cfg = TABLE_AMOUNT[kind];
  if (!cfg) return false;

  const rowRes = await fetch(
    `${SUPABASE_URL}/rest/v1/${cfg.table}?id=eq.${id}&select=${cfg.col}`,
    { headers: serviceHeaders },
  );
  const rows = await rowRes.json().catch(() => []) as any[];
  const expected = Number(rows?.[0]?.[cfg.col]);
  if (!Number.isFinite(expected) || paidMxn < expected - 1) {  // tolerancia $1
    console.error(`[conekta-webhook] ⚠️ MISMATCH promo ${kind}/${id}: cobrado=${paidMxn} orden=${expected} — NO se activa`);
    return true;  // ack sin activar (queda en logs); no reintentar algo que no cuadra
  }

  const rpcRes = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${cfg.rpc}`, {
    method: 'POST', headers: serviceHeaders,
    body: JSON.stringify({ [cfg.param]: id, p_mp_payment_id: orderId }),
  });
  if (!rpcRes.ok) {
    console.error(`[conekta-webhook] promo: ${cfg.rpc} falló`, await rpcRes.text().catch(() => ''));
    return false;  // 500 → Conekta reintenta (RPCs idempotentes)
  }
  console.log(`[conekta-webhook] 📣 Publicidad activada kind=${kind} id=${id} order=${orderId}`);
  return true;
}

// ── 🎁 Confirmar regalo pagado con Conekta ───────────────────────────
// Mismo patrón que confirmPromoPayment: verifica que lo COBRADO cubra
// el monto de la orden (tolerancia $1) antes de acreditar, y llama a
// confirm_gift_payment (idempotente, sql/567).
async function confirmGiftPayment(
  orderId: string, giftOrderId: string, paidCentavos: number,
): Promise<boolean> {
  const paidAmount = paidCentavos / 100;

  const rowRes = await fetch(
    `${SUPABASE_URL}/rest/v1/group_gifts?id=eq.${giftOrderId}&select=amount,status`,
    { headers: serviceHeaders },
  );
  const rows = await rowRes.json().catch(() => []) as any[];
  const row = rows?.[0];
  const expected = Number(row?.amount);

  if (row?.status === 'paid') {
    console.log('[conekta-webhook] gift: ya estaba pagado (idempotente)', giftOrderId);
    return true;
  }

  if (!Number.isFinite(expected) || paidAmount < expected - 1) {
    console.error(`[conekta-webhook] ⚠️ MISMATCH gift ${giftOrderId}: cobrado=${paidAmount} orden=${expected} — NO se acredita`);
    return true;  // ack sin acreditar (queda en logs); no reintentar algo que no cuadra
  }

  const rpcRes = await fetch(`${SUPABASE_URL}/rest/v1/rpc/confirm_gift_payment`, {
    method: 'POST', headers: serviceHeaders,
    body: JSON.stringify({ p_group_gift_id: giftOrderId, p_conekta_order_id: orderId }),
  });
  if (!rpcRes.ok) {
    console.error('[conekta-webhook] gift: confirm_gift_payment falló', await rpcRes.text().catch(() => ''));
    return false;  // 500 → Conekta reintenta (RPC idempotente)
  }
  console.log(`[conekta-webhook] 🎁 Regalo acreditado gift_order=${giftOrderId} order=${orderId}`);
  return true;
}

// ── 🏆 Activar Plus anual (pago único Conekta) ───────────────────────
// Idempotente: si el grupo ya tiene esta orden como plus_subscription_id,
// el reenvío del webhook no suma otro año. Si renueva ANTES de vencer,
// el año nuevo se suma al vencimiento actual (no pierde días pagados).
async function activatePlusAnnual(orderId: string, groupId: string): Promise<boolean> {
  const subId = `conekta_${orderId}`;

  const grpRes = await fetch(
    `${SUPABASE_URL}/rest/v1/groups?id=eq.${groupId}&select=id,is_plus_active,plus_expires_at,plus_subscription_id`,
    { headers: serviceHeaders },
  );
  const rows = await grpRes.json().catch(() => []) as any[];
  const grp = rows?.[0];
  if (!grp) {
    console.error('[conekta-webhook] plus: grupo no encontrado', groupId);
    return false;
  }
  if (grp.plus_subscription_id === subId) {
    console.log('[conekta-webhook] plus: orden ya aplicada (idempotente)', orderId);
    return true;
  }

  const now  = Date.now();
  const cur  = grp.plus_expires_at ? new Date(grp.plus_expires_at).getTime() : 0;
  const base = (grp.is_plus_active && cur > now) ? cur : now;
  const expiresAt = new Date(base + 365 * 86_400_000).toISOString();

  // MISMA RPC que Stripe — activa flags y notifica "ya puedes subir 2 videos más"
  const rpcRes = await fetch(`${SUPABASE_URL}/rest/v1/rpc/activate_plus`, {
    method: 'POST', headers: serviceHeaders,
    body: JSON.stringify({
      p_group_id:   groupId,
      p_sub_id:     subId,
      p_expires_at: expiresAt,
      p_status:     'active',
    }),
  });
  if (!rpcRes.ok) {
    console.error('[conekta-webhook] plus: activate_plus falló', await rpcRes.text().catch(() => ''));
    return false;
  }
  console.log(`[conekta-webhook] 🏆 Plus anual activado group=${groupId} hasta ${expiresAt}`);
  return true;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });

  try {
    const event = await req.json().catch(() => ({})) as any;
    const type    = event?.type ?? 'unknown';
    const orderId = event?.data?.object?.id ?? null;

    // Solo nos interesa el pago confirmado. Lo demás: ack y salir.
    if (type !== 'order.paid' || !orderId) {
      return new Response(JSON.stringify({ ok: true, ignored: type }), {
        status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    // 1. Verificar contra Conekta (fuente de verdad, encapsulado)
    const v = await verifyConektaPayment(orderId);

    // 🏆 Orden de Verificación Plus anual — NO es una reserva: activa Plus y sale.
    if (v.paid && v.plusGroupId) {
      const ok = await activatePlusAnnual(orderId, v.plusGroupId);
      return new Response(JSON.stringify({ ok, plus_group_id: v.plusGroupId }), {
        status: ok ? 200 : 500,  // 500 → Conekta reintenta (activación idempotente)
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    // 📣 Orden de publicidad (banner/destacado/perfil, bid, recomendado)
    if (v.paid && v.promoKind && v.promoId) {
      const ok = await confirmPromoPayment(orderId, v.promoKind, v.promoId, v.amountCentavos);
      return new Response(JSON.stringify({ ok, promo_kind: v.promoKind, promo_id: v.promoId }), {
        status: ok ? 200 : 500,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    // 🎁 Orden de regalo/donación a un grupo — NO es una reserva: acredita y sale.
    if (v.paid && v.giftOrderId) {
      const ok = await confirmGiftPayment(orderId, v.giftOrderId, v.amountCentavos);
      return new Response(JSON.stringify({ ok, gift_order_id: v.giftOrderId }), {
        status: ok ? 200 : 500,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    if (!v.paid || !v.reservationId) {
      console.warn('[conekta-webhook] order.paid no verificado o sin reservation_id', orderId, v);
      // 200: no reintentar algo que no cuadra (evita loops); ya se registró.
      return new Response(JSON.stringify({ ok: false, reason: 'not_verified' }), {
        status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    // 2. F2.2: gate de confirmación — locks, validación preventiva,
    //    idempotencia, tolerancia cero, acreditación atómica. Reemplaza el
    //    PATCH de provider/método y el PATCH de status: el gate los fija
    //    atómicamente dentro de _apply_confirmed_credit.
    if (!v.chargeId) {
      // Sin charge no hay identidad de pago verificable — 500 para que
      // Conekta reintente (el webhook redelivery puede traer el charge).
      console.error('[conekta-webhook] order.paid sin charge id:', orderId);
      return new Response(JSON.stringify({ ok: false, error: 'missing_charge' }), {
        status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    const gateRes = await fetch(`${SUPABASE_URL}/rest/v1/rpc/confirm_reservation_payment_v2`, {
      method: 'POST', headers: serviceHeaders,
      body: JSON.stringify({
        p_provider:            'conekta',
        p_provider_order_id:   orderId,
        p_provider_payment_id: v.chargeId,
        p_reservation_id:      v.reservationId,
        p_amount_minor:        v.amountCentavos,
        p_currency:            v.currency,
        p_method:              v.methodType,
        p_fee_minor:           v.feeCentavos,
        p_fee_source:          v.feeCentavos != null ? 'conekta_order' : null,
        // Solo se usa si NO existe payment_attempts para esta orden (pagos
        // creados antes del deploy de F2.2) — fuente: la orden RE-CONSULTADA
        // en verifyConektaPayment, no la reserva.
        p_legacy_expected: {
          amount_minor:   v.amountCentavos,
          currency:       v.currency,
          reservation_id: v.reservationId,
        },
      }),
    });
    const gateData = await gateRes.json().catch(() => null);

    if (!gateRes.ok) {
      // Excepción real de la RPC → transacción abortada por completo →
      // reintentable (la Conekta reintenta order.paid).
      console.error('[conekta-webhook] Error RPC gate:', JSON.stringify(gateData));
      return new Response(JSON.stringify({ ok: false, error: 'rpc_failed' }), {
        status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    const result = gateData?.result as string | undefined;

    // Únicos códigos reintentables — CERO efectos escritos por diseño.
    if (result === 'temporary_lock_timeout' || result === 'temporary_retry') {
      console.warn(`[conekta-webhook] ${result} — Conekta reintentará`, orderId);
      return new Response(JSON.stringify({ ok: false, result }), {
        status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    console.log(`[conekta-webhook] confirm_reservation_payment_v2 → ${result} order=${orderId} reservation=${v.reservationId}`);

    // Cualquier otro resultado (blocked/mismatch/capture_missing/etc.) es
    // FINAL: ya quedó auditado + en cola si aplica. 200, sin reintento.
    return new Response(JSON.stringify({ ok: result === 'confirmed', result, reservation_id: v.reservationId }), {
      status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });

  } catch (err: any) {
    console.error('[conekta-webhook] Error:', err);
    // 500 → Conekta reintenta; la acreditación es idempotente, no hay riesgo.
    return new Response(JSON.stringify({ ok: false, error: err.message }), {
      status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }
});
