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
    return { paid: false, amountCentavos: 0, reservationId: null, methodType: null };
  }
  const order = await res.json() as any;

  // Método real con el que se pagó (card / spei / cash). Los reembolsos por
  // API solo existen para tarjeta; SPEI/efectivo van a la cola manual.
  const rawType = String(order?.charges?.data?.[0]?.payment_method?.type ?? '').toLowerCase();
  const methodType =
    rawType.includes('spei') || rawType.includes('bank')            ? 'spei' :
    rawType.includes('cash') || rawType.includes('oxxo')            ? 'cash' :
    rawType.includes('card')                                        ? 'card' :
    rawType || null;

  return {
    paid:          order?.payment_status === 'paid',
    amountCentavos: Number(order?.amount ?? 0),
    reservationId: order?.metadata?.reservation_id ?? null,
    methodType,
  };
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
    if (!v.paid || !v.reservationId) {
      console.warn('[conekta-webhook] order.paid no verificado o sin reservation_id', orderId, v);
      // 200: no reintentar algo que no cuadra (evita loops); ya se registró.
      return new Response(JSON.stringify({ ok: false, reason: 'not_verified' }), {
        status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    // 2. Acreditar wallet — MISMA RPC que Stripe, IDEMPOTENTE.
    const rpcRes = await fetch(`${SUPABASE_URL}/rest/v1/rpc/confirm_full_payment_and_credit_wallet`, {
      method: 'POST', headers: serviceHeaders,
      body: JSON.stringify({
        p_reservation_id: v.reservationId,
        p_mp_payment_id:  orderId,               // id de Conekta como referencia (refund)
        p_amount_paid:    v.amountCentavos / 100,
        p_stripe_fee:     null,
      }),
    });
    const rpcData = await rpcRes.json().catch(() => null);
    if (!rpcRes.ok) {
      // Error real → 500 para que Conekta reintente (la RPC es idempotente).
      console.error('[conekta-webhook] Error RPC wallet:', JSON.stringify(rpcData));
      return new Response(JSON.stringify({ ok: false, error: 'rpc_failed' }), {
        status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    // 3. Marcar proveedor + método real (el refund decide su ruta con esto:
    //    tarjeta → API de Conekta; SPEI/efectivo → cola de reembolso manual)
    await fetch(`${SUPABASE_URL}/rest/v1/reservations?id=eq.${v.reservationId}`, {
      method: 'PATCH',
      headers: { ...serviceHeaders, Prefer: 'return=minimal' },
      body: JSON.stringify({ payment_provider: 'conekta', payment_method_type: v.methodType }),
    });

    console.log(`[conekta-webhook] ✅ order=${orderId} reservation=${v.reservationId} acreditado (${JSON.stringify(rpcData)})`);

    return new Response(JSON.stringify({ ok: true, reservation_id: v.reservationId }), {
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
