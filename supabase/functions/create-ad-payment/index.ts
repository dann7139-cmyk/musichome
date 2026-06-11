// ═══════════════════════════════════════════════════════════════════
// create-ad-payment  –  Supabase Edge Function (Stripe)
// Crea un PaymentIntent en Stripe para un anuncio publicitario.
//
// POST (autenticado):  { ad_id: string }
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
    // ── Autenticar — verificación criptográfica real con Supabase ────
    const authHeader = req.headers.get('Authorization');
    if (!authHeader?.startsWith('Bearer ')) {
      return jsonRes({ error: 'No autorizado: sin header' });
    }
    const token = authHeader.slice(7);

    const { data: authData, error: authError } = await admin.auth.getUser(token);
    if (authError || !authData.user) {
      console.error('[create-ad-payment] Auth error:', authError?.message);
      return jsonRes({ error: 'No autorizado: token inválido o expirado' });
    }
    const user = { id: authData.user.id, email: authData.user.email ?? '' };

    // ── Body ──────────────────────────────────────────────────────────
    const body = await req.json().catch(() => ({}));
    const { ad_id } = body as { ad_id?: string };
    if (!ad_id) return jsonRes({ error: 'ad_id requerido' });

    // ── Obtener anuncio ───────────────────────────────────────────────
    const { data: ad, error: adErr } = await admin
      .from('advertisements')
      .select('id, type, title, advertiser_id, package_id, status, effective_price')
      .eq('id', ad_id)
      .single();

    if (adErr || !ad) return jsonRes({ error: 'Anuncio no encontrado' });
    if (ad.advertiser_id !== user.id) return jsonRes({ error: 'Sin permiso' });
    if (!['pending_review', 'pending_payment'].includes(ad.status)) {
      return jsonRes({ error: 'Este anuncio no está pendiente de pago' });
    }

    // ── Obtener precio ────────────────────────────────────────────────
    let amount = 0;
    let packageName = 'Paquete publicitario';

    if (ad.effective_price && Number(ad.effective_price) > 0) {
      amount = Number(ad.effective_price);
    }

    if (amount <= 0 && ad.package_id) {
      const { data: pkg } = await admin
        .from('ad_packages')
        .select('price, name')
        .eq('id', ad.package_id)
        .single();

      if (pkg) {
        amount      = Number(pkg.price) ?? 0;
        packageName = pkg.name ?? packageName;
      }
    }

    if (amount <= 0) return jsonRes({ error: 'El paquete no tiene precio configurado' });

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
        console.error('[Stripe-Ad] Error creando customer:', JSON.stringify(cust));
        return jsonRes({ error: 'Error al crear perfil de pago' });
      }
      stripeCustomerId = cust.id;
      await admin.from('profiles').update({ stripe_customer_id: stripeCustomerId }).eq('id', user.id);
    }

    // ── Crear PaymentIntent ───────────────────────────────────────────
    const amountCentavos = Math.round(amount * 100);

    const typeLabel: Record<string, string> = {
      banner_home:      'Banner en inicio',
      sponsored_group:  'Grupo destacado',
      profile_ad:       'Anuncio en perfil',
    };

    const piBody = new URLSearchParams({
      amount:                               String(amountCentavos),
      currency:                             'mxn',
      customer:                             stripeCustomerId,
      description:                          `${typeLabel[ad.type] ?? 'Publicidad'} – "${ad.title}"`,
      'automatic_payment_methods[enabled]': 'true',
      'metadata[ad_id]':                    ad_id,
      'metadata[user_id]':                  user.id,
      'metadata[type]':                     ad.type,
      'metadata[package]':                  packageName,
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
      console.error('[Stripe-Ad] Error:', JSON.stringify(stripeData));
      return jsonRes({ error: stripeData?.error?.message ?? 'Error al crear pago en Stripe' });
    }

    // ── Guardar payment_intent_id en el anuncio ───────────────────────
    await admin
      .from('advertisements')
      .update({ mp_payment_id: stripeData.id })
      .eq('id', ad_id);

    console.log(`[Stripe-Ad] PaymentIntent ${stripeData.id} | ad_id: ${ad_id} | $${amount} MXN`);

    return jsonRes({
      ok:                true,
      client_secret:     stripeData.client_secret,
      payment_intent_id: stripeData.id,
      amount,
    });

  } catch (e: unknown) {
    const msg = e instanceof Error ? e.message : 'Error interno';
    console.error('[create-ad-payment] Error:', msg);
    return jsonRes({ error: msg });
  }
});
