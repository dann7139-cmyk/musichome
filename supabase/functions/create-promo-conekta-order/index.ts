// ═══════════════════════════════════════════════════════════════════
// create-promo-conekta-order  —  Supabase Edge Function (Conekta, MX)
//
// Cobra PUBLICIDAD con Conekta (tarjeta, SPEI u OXXO) vía Checkout
// HOSTED. Una sola función para los tres tipos:
//   · kind='ad'  → advertisements  (banner_home / sponsored_group / profile_ad)
//   · kind='bid' → bid_orders      (posicionamiento)
//   · kind='rec' → recommendation_orders (recomendados)
//
// El MONTO sale SIEMPRE de la fila en BD (server-side, nunca del
// cliente). La confirmación la hace conekta-webhook (fuente de verdad)
// llamando a los MISMOS RPCs que Stripe (mark_ad_payment /
// confirm_bid_payment / confirm_recommendation_payment — idempotentes).
//
// Body (autenticado, dueño de la orden): { kind, id }
// Respuesta: { ok, order_id, checkout_url }
// ═══════════════════════════════════════════════════════════════════

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

function jsonResponse(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });

  const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? '';
  const SERVICE_KEY  = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
  const privateKey   = Deno.env.get('CONEKTA_PRIVATE_KEY') ?? '';

  const admin = createClient(SUPABASE_URL, SERVICE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  try {
    if (!privateKey) return jsonResponse({ error: 'CONEKTA_PRIVATE_KEY no configurado' }, 500);

    // ── Autenticar (verificación criptográfica real) ──────────────────
    const authHeader = req.headers.get('Authorization') ?? '';
    const jwt = authHeader.replace('Bearer ', '').trim();
    if (!jwt) return jsonResponse({ error: 'No autorizado' }, 401);
    const { data: authData, error: authErr } = await admin.auth.getUser(jwt);
    if (authErr || !authData?.user) return jsonResponse({ error: 'Token inválido' }, 401);
    const user = authData.user;

    // ── Body ──────────────────────────────────────────────────────────
    const { kind, id } = await req.json().catch(() => ({})) as { kind?: string; id?: string };
    if (!id || !kind || !['ad', 'bid', 'rec'].includes(kind)) {
      return jsonResponse({ error: 'kind (ad|bid|rec) e id requeridos' }, 400);
    }

    // ── Cargar la orden: monto SERVER-SIDE + dueño + status ───────────
    let amountMxn = 0;
    let lineName  = '';

    if (kind === 'ad') {
      const { data: ad } = await admin
        .from('advertisements')
        .select('id, type, title, advertiser_id, status, effective_price')
        .eq('id', id).single();
      if (!ad) return jsonResponse({ error: 'Anuncio no encontrado' }, 404);
      if (ad.advertiser_id !== user.id) return jsonResponse({ error: 'Sin permiso' }, 403);
      if (ad.status !== 'pending_payment') return jsonResponse({ error: 'Este anuncio ya no está pendiente de pago.' }, 400);
      amountMxn = Number(ad.effective_price ?? 0);
      lineName  = `Publicidad — ${ad.title ?? ad.type}`;
    } else if (kind === 'bid') {
      const { data: order } = await admin
        .from('bid_orders')
        .select('id, user_id, amount, duration_days, status')
        .eq('id', id).single();
      if (!order) return jsonResponse({ error: 'Orden no encontrada' }, 404);
      if (order.user_id !== user.id) return jsonResponse({ error: 'Sin permiso' }, 403);
      if (order.status !== 'pending_payment') return jsonResponse({ error: 'Esta orden ya no está pendiente de pago.' }, 400);
      amountMxn = Number(order.amount ?? 0);
      lineName  = `Posicionamiento — ${order.duration_days} día(s)`;
    } else {
      const { data: order } = await admin
        .from('recommendation_orders')
        .select('id, group_id, amount, duration_days, status')
        .eq('id', id).single();
      if (!order) return jsonResponse({ error: 'Orden no encontrada' }, 404);
      const { data: grp } = await admin
        .from('groups').select('owner_id').eq('id', order.group_id).single();
      if (grp?.owner_id !== user.id) return jsonResponse({ error: 'Sin permiso' }, 403);
      if (order.status !== 'pending_payment') return jsonResponse({ error: 'Esta orden ya no está pendiente de pago.' }, 400);
      amountMxn = Number(order.amount ?? 0);
      lineName  = `Recomendado — ${order.duration_days} día(s)`;
    }

    if (!(amountMxn > 0)) return jsonResponse({ error: 'Monto inválido en la orden' }, 400);

    // ── Datos del comprador ───────────────────────────────────────────
    const { data: profile } = await admin
      .from('profiles').select('full_name, phone').eq('id', user.id).single();

    const rawPhone = String(profile?.phone ?? '').replace(/\D/g, '');
    const e164Phone =
      rawPhone.length === 10                              ? `+52${rawPhone}` :
      rawPhone.length === 12 && rawPhone.startsWith('52')  ? `+${rawPhone}` :
      rawPhone.length === 13 && rawPhone.startsWith('521') ? `+52${rawPhone.slice(3)}` :
      '+525555555555';

    // ── Crear orden HostedPayment ─────────────────────────────────────
    const auth = btoa(`${privateKey}:`);
    const orderBody = {
      currency: 'MXN',
      customer_info: {
        name:  profile?.full_name ?? 'Anunciante Daricefy',
        email: user.email ?? 'anunciante@daricefy.com',
        phone: e164Phone,
      },
      line_items: [
        { name: lineName, unit_price: Math.round(amountMxn * 100), quantity: 1 },
      ],
      checkout: {
        type: 'HostedPayment',
        allowed_payment_methods: ['card', 'bank_transfer', 'cash'],
        success_url: 'https://daricefy.com/pago-ok',
        failure_url: 'https://daricefy.com/pago-error',
      },
      // conekta-webhook enruta con promo_kind + promo_id
      metadata: { type: 'promo', promo_kind: kind, promo_id: id },
    };

    const conektaRes = await fetch('https://api.conekta.io/orders', {
      method: 'POST',
      headers: {
        'Accept':        'application/vnd.conekta-v2.1.0+json',
        'Content-Type':  'application/json',
        'Authorization': `Basic ${auth}`,
      },
      body: JSON.stringify(orderBody),
    });
    const data = await conektaRes.json() as any;

    if (!conektaRes.ok) {
      console.error('[create-promo-conekta-order] Error Conekta:', JSON.stringify(data));
      return jsonResponse({ error: data?.details?.[0]?.message ?? 'Error creando orden Conekta' }, 502);
    }

    const checkoutUrl = data?.checkout?.url ?? null;
    if (!checkoutUrl) {
      return jsonResponse({ error: 'Conekta no devolvió checkout.url' }, 502);
    }

    console.log(`[create-promo-conekta-order] order=${data?.id} kind=${kind} id=${id} amount=${amountMxn}`);

    return jsonResponse({ ok: true, order_id: data?.id ?? null, checkout_url: checkoutUrl });

  } catch (err: any) {
    console.error('[create-promo-conekta-order] Error:', err);
    return jsonResponse({ error: err.message ?? 'Error interno' }, 500);
  }
});
