// ═══════════════════════════════════════════════════════════════════
// create-promo-subscription  —  Supabase Edge Function (Stripe)
//
// SUSCRIPCIONES de publicidad con renovación automática:
//   · kind='rec'       → Recomendado SEMANAL $399 MXN (mismo precio que
//                        el paquete de 7 días). group_id requerido.
//   · kind='sponsored' → Destacado MENSUAL al precio del anuncio
//                        (effective_price). ad_id requerido (el anuncio
//                        sponsored_group ya creado, pending_payment).
//
// Sin trial: el primer cobro es HOY (PaymentIntent + PaymentSheet).
// stripe-webhook (invoice.paid + metadata promo_sub_kind) activa/renueva
// vía renew_recommendation_subscription / renew_sponsored_subscription
// (sql/497, idempotentes).
//
// Los Prices de Stripe se auto-crean con lookup_key — no hay que tocar
// el dashboard.
//
// Body (autenticado): { kind: 'rec'|'sponsored', group_id?, ad_id? }
// Respuesta: { ok, payment_intent_client_secret, subscription_id }
// ═══════════════════════════════════════════════════════════════════

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const REC_WEEKLY_MXN = 399;   // ⚠️ igual al paquete de 7 días de RecommendationScreen

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

// Busca un Price por lookup_key; si no existe lo crea (producto incluido).
async function getOrCreatePrice(
  stripeKey: string,
  lookupKey: string,
  unitAmountCentavos: number,
  interval: 'week' | 'month',
  productName: string,
): Promise<string | null> {
  const headers = {
    Authorization:  `Bearer ${stripeKey}`,
    'Content-Type': 'application/x-www-form-urlencoded',
  };

  const q = new URLSearchParams({ 'lookup_keys[]': lookupKey, active: 'true', limit: '1' });
  const found = await fetch(`https://api.stripe.com/v1/prices?${q}`, { headers });
  const foundData = await found.json();
  if (found.ok && foundData?.data?.length > 0) return foundData.data[0].id;

  const createBody = new URLSearchParams({
    currency:                'mxn',
    unit_amount:             String(unitAmountCentavos),
    'recurring[interval]':   interval,
    lookup_key:              lookupKey,
    'product_data[name]':    productName,
  });
  const created = await fetch('https://api.stripe.com/v1/prices', {
    method: 'POST', headers, body: createBody,
  });
  const createdData = await created.json();
  if (!created.ok) {
    console.error('[promo-sub] Error creando price:', JSON.stringify(createdData));
    return null;
  }
  return createdData.id;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });

  const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? '';
  const SERVICE_KEY  = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
  const STRIPE_KEY   = Deno.env.get('STRIPE_SECRET_KEY') ?? '';

  if (!STRIPE_KEY) return jsonRes({ error: 'STRIPE_SECRET_KEY no configurado' }, 500);

  const admin = createClient(SUPABASE_URL, SERVICE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  try {
    // ── Autenticar (verificación real) ────────────────────────────────
    const authHeader = req.headers.get('Authorization') ?? '';
    const jwt = authHeader.replace('Bearer ', '').trim();
    if (!jwt) return jsonRes({ error: 'No autorizado' }, 401);
    const { data: authData, error: authErr } = await admin.auth.getUser(jwt);
    if (authErr || !authData?.user) return jsonRes({ error: 'Token inválido' }, 401);
    const user = authData.user;

    // ── Body ──────────────────────────────────────────────────────────
    const { kind, group_id, ad_id } = await req.json().catch(() => ({})) as {
      kind?: string; group_id?: string; ad_id?: string;
    };
    if (!kind || !['rec', 'sponsored'].includes(kind)) {
      return jsonRes({ error: 'kind debe ser "rec" o "sponsored"' }, 400);
    }

    // ── Resolver monto + validar dueño (todo server-side) ─────────────
    let priceId: string | null = null;
    const metadata: Record<string, string> = { promo_sub_kind: kind, owner_id: user.id };

    if (kind === 'rec') {
      if (!group_id) return jsonRes({ error: 'group_id requerido' }, 400);
      const { data: grp } = await admin
        .from('groups').select('id, owner_id, name').eq('id', group_id).single();
      if (!grp) return jsonRes({ error: 'Grupo no encontrado' }, 404);
      if (grp.owner_id !== user.id) return jsonRes({ error: 'Sin permiso' }, 403);

      // 🚦 Cupo: máx. 10 grupos recomendados por estado (sql/500). Las
      // renovaciones de quien ya tiene lugar nunca se bloquean.
      const { data: avail } = await admin.rpc('check_recommendation_availability', {
        p_group_id: group_id,
      });
      if (avail && avail.ok === false) {
        return jsonRes({ error: 'Por ahora no hay lugares de Recomendado en tu estado. Se liberan cuando vencen las campañas activas — intenta más tarde.' });
      }

      metadata.rec_group_id = group_id;
      priceId = await getOrCreatePrice(
        STRIPE_KEY,
        `daricefy_rec_weekly_${REC_WEEKLY_MXN * 100}`,
        REC_WEEKLY_MXN * 100,
        'week',
        'Daricefy — Recomendado (semanal)',
      );
    } else {
      if (!ad_id) return jsonRes({ error: 'ad_id requerido' }, 400);
      const { data: ad } = await admin
        .from('advertisements')
        .select('id, type, title, advertiser_id, status, effective_price')
        .eq('id', ad_id).single();
      if (!ad) return jsonRes({ error: 'Anuncio no encontrado' }, 404);
      if (ad.advertiser_id !== user.id) return jsonRes({ error: 'Sin permiso' }, 403);
      if (ad.type !== 'sponsored_group') return jsonRes({ error: 'El anuncio no es de tipo Destacado' }, 400);
      if (ad.status !== 'pending_payment') return jsonRes({ error: 'Este anuncio ya no está pendiente de pago.' }, 400);

      const amountMxn = Number(ad.effective_price ?? 0);
      if (!(amountMxn > 0)) return jsonRes({ error: 'Monto inválido en el anuncio' }, 400);

      metadata.sponsored_ad_id = ad_id;
      const centavos = Math.round(amountMxn * 100);
      priceId = await getOrCreatePrice(
        STRIPE_KEY,
        `daricefy_sponsored_monthly_${centavos}`,
        centavos,
        'month',
        'Daricefy — Destacado (mensual)',
      );
    }

    if (!priceId) return jsonRes({ error: 'No se pudo preparar el precio de la suscripción' }, 502);

    // ── Obtener o crear Stripe Customer ───────────────────────────────
    const { data: profile } = await admin
      .from('profiles').select('stripe_customer_id, full_name').eq('id', user.id).single();

    let stripeCustomerId: string = profile?.stripe_customer_id ?? '';
    if (!stripeCustomerId) {
      const custRes = await fetch('https://api.stripe.com/v1/customers', {
        method: 'POST',
        headers: {
          Authorization:  `Bearer ${STRIPE_KEY}`,
          'Content-Type': 'application/x-www-form-urlencoded',
        },
        body: new URLSearchParams({
          email:               user.email ?? '',
          name:                profile?.full_name ?? '',
          'metadata[user_id]': user.id,
        }),
      });
      const cust = await custRes.json();
      if (!custRes.ok) return jsonRes({ error: 'Error al crear perfil de pago' });
      stripeCustomerId = cust.id;
      await admin.from('profiles').update({ stripe_customer_id: stripeCustomerId }).eq('id', user.id);
    }

    // ── Crear la suscripción (SIN trial: primer cobro HOY) ────────────
    const subParams = new URLSearchParams({
      customer:          stripeCustomerId,
      'items[0][price]': priceId,
      payment_behavior:  'default_incomplete',
      'payment_settings[save_default_payment_method]': 'on_subscription',
      'expand[]':        'latest_invoice.payment_intent',
    });
    for (const [k, v] of Object.entries(metadata)) {
      subParams.set(`metadata[${k}]`, v);
    }

    const subRes = await fetch('https://api.stripe.com/v1/subscriptions', {
      method: 'POST',
      headers: {
        Authorization:  `Bearer ${STRIPE_KEY}`,
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: subParams,
    });
    const sub = await subRes.json();
    if (!subRes.ok) {
      console.error('[promo-sub] Error creando subscription:', JSON.stringify(sub));
      return jsonRes({ error: sub?.error?.message ?? 'Error al crear suscripción' });
    }

    const clientSecret: string | null =
      sub.latest_invoice?.payment_intent?.client_secret ?? null;
    if (!clientSecret) {
      return jsonRes({ error: 'No se recibió el token de pago' });
    }

    console.log(`[promo-sub] sub=${sub.id} kind=${kind} user=${user.id}`);

    return jsonRes({
      ok:                            true,
      payment_intent_client_secret:  clientSecret,
      subscription_id:               sub.id,
    });

  } catch (e: unknown) {
    const msg = e instanceof Error ? e.message : 'Error interno';
    console.error('[create-promo-subscription] Error:', msg);
    return jsonRes({ error: msg }, 500);
  }
});
