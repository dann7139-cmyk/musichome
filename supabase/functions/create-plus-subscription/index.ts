// ═══════════════════════════════════════════════════════════════════
// create-plus-subscription  –  Supabase Edge Function (Stripe)
//
// Crea una Stripe Subscription con trial de 7 días para Verificación Plus.
// Usa SetupIntent en lugar de PaymentIntent: no cobra al usuario en el día 1.
// El cobro ocurre al día 8 automáticamente si no cancela.
//
// POST (autenticado): { group_id: string, plan: 'monthly' | 'annual' }
// Respuesta:          { ok, setup_intent_client_secret, subscription_id }
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

// Mapa de Price IDs por plan y moneda.
// Configurar en Supabase Secrets antes del deploy.
function resolvePriceId(plan: string, currency: string): string | null {
  const key = `STRIPE_PLUS_GROUP_${currency.toUpperCase()}_${plan.toUpperCase()}`;
  return Deno.env.get(key) ?? null;
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
    // ── Autenticar ────────────────────────────────────────────────────
    const authHeader = req.headers.get('Authorization');
    if (!authHeader?.startsWith('Bearer ')) return jsonRes({ error: 'No autorizado' }, 401);
    const token = authHeader.slice(7);

    let user: { id: string; email: string };
    try {
      const parts   = token.split('.');
      const pad     = (s: string) => s + '='.repeat((4 - s.length % 4) % 4);
      const payload = JSON.parse(atob(pad(parts[1].replace(/-/g, '+').replace(/_/g, '/'))));
      if (!payload.sub) throw new Error('no sub');
      user = { id: payload.sub, email: payload.email ?? '' };
    } catch {
      return jsonRes({ error: 'Token inválido' }, 401);
    }

    // ── Body ──────────────────────────────────────────────────────────
    const body = await req.json().catch(() => ({}));
    const { group_id, plan } = body as { group_id?: string; plan?: string };

    if (!group_id) return jsonRes({ error: 'group_id requerido' });
    if (!plan || !['monthly', 'annual'].includes(plan)) {
      return jsonRes({ error: 'plan debe ser "monthly" o "annual"' });
    }

    // ── Verificar ownership ───────────────────────────────────────────
    const { data: group, error: grpErr } = await admin
      .from('groups')
      .select('id, name, owner_id, country, is_plus_active')
      .eq('id', group_id)
      .single();

    if (grpErr || !group) return jsonRes({ error: 'Grupo no encontrado' });
    if (group.owner_id !== user.id) return jsonRes({ error: 'Sin permiso sobre este grupo' });
    if (group.is_plus_active) return jsonRes({ error: 'Plus ya está activo en este grupo' });

    // ── Determinar moneda ─────────────────────────────────────────────
    const currency = group.country === 'Estados Unidos' ? 'usd' : 'mxn';

    // ── Resolver Price ID ─────────────────────────────────────────────
    const priceId = resolvePriceId(plan, currency);
    if (!priceId) {
      return jsonRes({ error: `Price ID no configurado para plan=${plan} currency=${currency}` });
    }

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
          Authorization:  `Bearer ${STRIPE_KEY}`,
          'Content-Type': 'application/x-www-form-urlencoded',
        },
        body: new URLSearchParams({
          email:               user.email,
          name:                profile?.full_name ?? '',
          'metadata[user_id]': user.id,
        }),
      });
      const cust = await custRes.json();
      if (!custRes.ok) {
        console.error('[Plus] Error creando customer:', JSON.stringify(cust));
        return jsonRes({ error: 'Error al crear perfil de pago' });
      }
      stripeCustomerId = cust.id;
      await admin.from('profiles').update({ stripe_customer_id: stripeCustomerId }).eq('id', user.id);
    }

    // ── Crear Stripe Subscription con trial de 7 días ─────────────────
    // payment_behavior=default_incomplete: la suscripción no se activa hasta
    // que el SetupIntent capture la tarjeta.
    // expand[]=pending_setup_intent: devuelve el client_secret para el frontend.
    const subParams = new URLSearchParams({
      customer:                           stripeCustomerId,
      'items[0][price]':                  priceId,
      trial_period_days:                  '7',
      payment_behavior:                   'default_incomplete',
      'payment_settings[save_default_payment_method]': 'on_subscription',
      'expand[]':                         'pending_setup_intent',
      'metadata[group_id]':               group_id,
      'metadata[owner_id]':               user.id,
      'metadata[entity_type]':            'group',
      'metadata[plan]':                   plan,
      'metadata[currency]':               currency,
    });

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
      console.error('[Plus] Error creando subscription:', JSON.stringify(sub));
      return jsonRes({ error: sub?.error?.message ?? 'Error al crear suscripción en Stripe' });
    }

    const setupIntentClientSecret: string | null =
      sub.pending_setup_intent?.client_secret ?? null;

    if (!setupIntentClientSecret) {
      console.error('[Plus] Sin pending_setup_intent en subscription:', sub.id);
      return jsonRes({ error: 'No se recibió el token de configuración de pago' });
    }

    // ── Guardar en plus_subscriptions ─────────────────────────────────
    const trialEnd = sub.trial_end
      ? new Date(sub.trial_end * 1000).toISOString()
      : null;

    const { error: dbErr } = await admin.from('plus_subscriptions').insert({
      group_id:               group_id,
      owner_id:               user.id,
      stripe_subscription_id: sub.id,
      stripe_customer_id:     stripeCustomerId,
      status:                 'incomplete',
      trial_ends_at:          trialEnd,
    });

    if (dbErr) {
      console.error('[Plus] Error guardando suscripción en DB:', dbErr.message);
      // No bloquear — Stripe tiene el registro. El webhook lo sincronizará.
    }

    console.log(`[Plus] Subscription ${sub.id} | group=${group_id} | plan=${plan} | currency=${currency}`);

    return jsonRes({
      ok:                          true,
      setup_intent_client_secret:  setupIntentClientSecret,
      subscription_id:             sub.id,
    });

  } catch (e: unknown) {
    const msg = e instanceof Error ? e.message : 'Error interno';
    console.error('[create-plus-subscription] Error:', msg);
    return jsonRes({ error: msg }, 500);
  }
});
