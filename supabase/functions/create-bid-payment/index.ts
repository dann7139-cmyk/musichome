// ═══════════════════════════════════════════════════════════════════
// create-bid-payment  –  Supabase Edge Function (Stripe)
// Crea un PaymentIntent en Stripe para una orden de posicionamiento (bidding).
//
// POST (autenticado):  { order_id: string }
// Respuesta:           { ok, client_secret, payment_intent_id, amount }
// ═══════════════════════════════════════════════════════════════════

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

function jsonRes(body: Record<string, unknown>) {
  return new Response(JSON.stringify(body), {
    status: 200,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });

  const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? '';
  const SERVICE_KEY  = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';

  const admin = createClient(SUPABASE_URL, SERVICE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  try {
    // ── Autenticar ────────────────────────────────────────────────────
    const authHeader = req.headers.get('Authorization');
    if (!authHeader?.startsWith('Bearer ')) {
      return jsonRes({ error: 'No autorizado: sin header' });
    }
    const token = authHeader.slice(7);

    // 🔒 Verificación criptográfica REAL del JWT (antes solo se decodificaba
    // el payload sin validar la firma — un token forjado pasaba los checks)
    const { data: authData, error: authError } = await admin.auth.getUser(token);
    if (authError || !authData.user) {
      return jsonRes({ error: 'No autorizado: token inválido o expirado' });
    }
    const user = { id: authData.user.id, email: authData.user.email ?? '' };

    // ── Body ──────────────────────────────────────────────────────────
    const body = await req.json().catch(() => ({}));
    const { order_id } = body as { order_id?: string };
    if (!order_id) return jsonRes({ error: 'order_id requerido' });

    // ── Obtener orden ─────────────────────────────────────────────────
    const { data: order, error: orderErr } = await admin
      .from('bid_orders')
      .select('id, group_id, user_id, package_id, amount, duration_days, status')
      .eq('id', order_id)
      .single();

    if (orderErr || !order) return jsonRes({ error: 'Orden no encontrada' });
    if (order.user_id !== user.id) return jsonRes({ error: 'Sin permiso' });
    if (order.status !== 'pending_payment') {
      return jsonRes({ error: 'Esta orden ya fue procesada' });
    }

    // ── Obtener grupo ─────────────────────────────────────────────────
    const { data: grp, error: grpErr } = await admin
      .from('groups')
      .select('name, owner_id')
      .eq('id', order.group_id)
      .single();

    if (grpErr || !grp) return jsonRes({ error: 'Grupo no encontrado' });

    // ── Stripe secret key ─────────────────────────────────────────────
    const stripeKey = Deno.env.get('STRIPE_SECRET_KEY');
    if (!stripeKey) return jsonRes({ error: 'STRIPE_SECRET_KEY no configurado en el servidor' });

    // ── Obtener o crear Stripe Customer ───────────────────────────────
    const { data: profile } = await admin
      .from('profiles')
      .select('stripe_customer_id, full_name')
      .eq('id', user.id)
      .single();

    let stripeCustomerId: string = profile?.stripe_customer_id ?? '';

    if (!stripeCustomerId) {
      const custRes = await fetch('https://api.stripe.com/v1/customers', {
        method: 'POST',
        headers: {
          Authorization:  `Bearer ${stripeKey}`,
          'Content-Type': 'application/x-www-form-urlencoded',
        },
        body: new URLSearchParams({
          email:               user.email ?? '',
          name:                profile?.full_name ?? '',
          'metadata[user_id]': user.id,
        }),
      });
      const cust = await custRes.json();
      if (!custRes.ok) {
        console.error('[Stripe-Bid] Error creando customer:', JSON.stringify(cust));
        return jsonRes({ error: 'Error al crear perfil de pago' });
      }
      stripeCustomerId = cust.id;
      await admin.from('profiles').update({ stripe_customer_id: stripeCustomerId }).eq('id', user.id);
    }

    // ── Nombre del paquete ────────────────────────────────────────────
    let packageName = 'Posicionamiento personalizado';
    if (order.package_id) {
      const { data: pkg } = await admin
        .from('bid_packages')
        .select('name')
        .eq('id', order.package_id)
        .single();
      if (pkg?.name) packageName = pkg.name;
    }

    // ── Crear PaymentIntent ───────────────────────────────────────────
    const amount         = Number(order.amount);
    const amountCentavos = Math.round(amount * 100);

    const piBody = new URLSearchParams({
      amount:                               String(amountCentavos),
      currency:                             'mxn',
      customer:                             stripeCustomerId,
      description:                          `⬆️ Bidding · ${packageName} – ${grp.name} · ${order.duration_days}d`,
      'automatic_payment_methods[enabled]': 'true',
      'metadata[bid_order_id]':             order_id,
      'metadata[group_id]':                 order.group_id,
      'metadata[user_id]':                  user.id,
      'metadata[duration_days]':            String(order.duration_days),
    });

    const stripeRes = await fetch('https://api.stripe.com/v1/payment_intents', {
      method: 'POST',
      headers: {
        Authorization:  `Bearer ${stripeKey}`,
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: piBody,
    });

    const stripeData = await stripeRes.json();

    if (!stripeRes.ok) {
      console.error('[Stripe-Bid] Error:', JSON.stringify(stripeData));
      return jsonRes({ error: stripeData?.error?.message ?? 'Error al crear pago en Stripe' });
    }

    console.log(`[Stripe-Bid] PaymentIntent ${stripeData.id} | order_id: ${order_id} | $${amount} MXN`);

    return jsonRes({
      ok:                true,
      client_secret:     stripeData.client_secret,
      payment_intent_id: stripeData.id,
      amount,
    });

  } catch (e: unknown) {
    const msg = e instanceof Error ? e.message : 'Error interno';
    console.error('[create-bid-payment] Error:', msg);
    return jsonRes({ error: msg });
  }
});
