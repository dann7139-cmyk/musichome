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

    // ── 🎁 Prueba gratis UNA sola vez por dueño ───────────────────────
    // Si ya tuvo una suscripción que llegó a trial/activa (aunque haya
    // cancelado o fallado el cobro), la nueva suscripción cobra desde el
    // día 1 — evita farmear 7 días gratis cancelando y resuscribiendo.
    // ('incomplete' no cuenta: nunca capturó tarjeta ni gozó el trial.)
    const { data: prevSubs } = await admin
      .from('plus_subscriptions')
      .select('id')
      .eq('owner_id', user.id)
      .in('status', ['trialing', 'active', 'past_due', 'cancelled'])
      .limit(1);
    const hadTrial = (prevSubs?.length ?? 0) > 0;

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

    // ── Crear Stripe Subscription ─────────────────────────────────────
    // Primera vez: trial de 7 días → SetupIntent (captura tarjeta, cobra al
    // día 8). Ya usó su trial: SIN trial → PaymentIntent (cobra HOY).
    // payment_behavior=default_incomplete: no se activa hasta pagar/capturar.
    const subParams = new URLSearchParams({
      customer:                           stripeCustomerId,
      'items[0][price]':                  priceId,
      payment_behavior:                   'default_incomplete',
      // Forzado explícito: si queda en 'send_invoice' (por default de la
      // cuenta o del customer), Stripe finaliza la factura sin generar
      // NINGÚN payment_intent/confirmation_secret para tarjeta — encaja
      // exacto con "invoice=open pero sin pi ni confSecret" que se vio.
      collection_method:                  'charge_automatically',
      'payment_settings[save_default_payment_method]': 'on_subscription',
      'metadata[group_id]':               group_id,
      'metadata[owner_id]':               user.id,
      'metadata[entity_type]':            'group',
      'metadata[plan]':                   plan,
      'metadata[currency]':               currency,
    });
    if (hadTrial) {
      subParams.append('expand[]', 'latest_invoice.payment_intent');
    } else {
      subParams.set('trial_period_days', '7');
      subParams.append('expand[]', 'pending_setup_intent');
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
      console.error('[Plus] Error creando subscription:', JSON.stringify(sub));
      return jsonRes({ error: sub?.error?.message ?? 'Error al crear suscripción en Stripe' });
    }

    // 🆕 Stripe reemplazó invoice.payment_intent por invoice.confirmation_secret
    // en versiones recientes de la API de Billing — el campo viejo ya no se
    // llena (por eso salía "invoice=object(open) pi=undefined": la factura
    // sí existe, solo que ya no expone payment_intent directo). Cuando
    // confirmation_secret.type='payment_intent', su client_secret es
    // exactamente el mismo formato que necesita el PaymentSheet.
    const extractSecrets = (s: any) => ({
      setupSecret: s.pending_setup_intent?.client_secret ?? null,
      paySecret:
        s.latest_invoice?.payment_intent?.client_secret ??
        (s.latest_invoice?.confirmation_secret?.type === 'payment_intent'
          ? s.latest_invoice.confirmation_secret.client_secret
          : null) ?? null,
    });

    let { setupSecret: setupIntentClientSecret, paySecret: paymentIntentClientSecret } = extractSecrets(sub);
    let diagSource: any = sub;

    // 🔁 Reintento de respaldo por si Stripe sí tarda en generar el invoice
    // en algún caso — no debería hacer falta con confirmation_secret, pero
    // se deja como red de seguridad.
    if (!setupIntentClientSecret && !paymentIntentClientSecret) {
      console.warn('[Plus] Sin client_secret en la respuesta inicial — reintentando con espera.', {
        subscription_id: sub.id,
        hadTrial,
        latest_invoice: sub.latest_invoice,
        pending_setup_intent: sub.pending_setup_intent,
        status: sub.status,
      });

      const expandParams = new URLSearchParams();
      expandParams.append('expand[]', 'latest_invoice.payment_intent');
      expandParams.append('expand[]', 'pending_setup_intent');

      for (const delayMs of [1500, 2500, 3000]) {
        await new Promise(resolve => setTimeout(resolve, delayMs));

        const refetchRes = await fetch(
          `https://api.stripe.com/v1/subscriptions/${sub.id}?${expandParams.toString()}`,
          { headers: { Authorization: `Bearer ${STRIPE_KEY}` } },
        );
        const refetched = await refetchRes.json();

        if (!refetchRes.ok) {
          console.error('[Plus] Reintento GET falló:', JSON.stringify(refetched));
          continue;
        }

        diagSource = refetched;
        const secrets = extractSecrets(refetched);
        setupIntentClientSecret = secrets.setupSecret;
        paymentIntentClientSecret = secrets.paySecret;

        if (setupIntentClientSecret || paymentIntentClientSecret) {
          console.log(`[Plus] client_secret recuperado tras espera de ${delayMs}ms — sub=${sub.id}`);
          break;
        }
      }
    }

    // 🛠️ Último recurso: esta cuenta de Stripe no está generando el
    // payment_intent/confirmation_secret automático de la factura (se
    // descartó send_invoice y confirmation_secret — sigue sin aparecer por
    // razones de la cuenta que no controlamos desde aquí). En vez de
    // seguir dependiendo de eso, se crea el cobro EXPLÍCITAMENTE nosotros
    // mismos por el monto exacto de la factura, y se le avisa a Stripe que
    // esa factura quedó pagada (paid_out_of_band) en cuanto el cliente
    // pague — eso dispara customer.subscription.updated → activate_plus,
    // la MISMA ruta que ya usan las renovaciones automáticas.
    if (!setupIntentClientSecret && !paymentIntentClientSecret && diagSource.latest_invoice?.id && diagSource.latest_invoice?.amount_due > 0) {
      console.warn('[Plus] Invoice sin payment_intent/confirmation_secret — creando PaymentIntent manual.', {
        subscription_id: sub.id, invoice_id: diagSource.latest_invoice.id, amount_due: diagSource.latest_invoice.amount_due,
      });

      const piRes = await fetch('https://api.stripe.com/v1/payment_intents', {
        method: 'POST',
        headers: {
          Authorization:  `Bearer ${STRIPE_KEY}`,
          'Content-Type': 'application/x-www-form-urlencoded',
        },
        body: new URLSearchParams({
          amount:   String(diagSource.latest_invoice.amount_due),
          currency: currency,
          customer: stripeCustomerId,
          'automatic_payment_methods[enabled]': 'true',
          setup_future_usage: 'off_session',
          'metadata[plus_group_id]':        group_id,
          'metadata[plus_invoice_id]':       diagSource.latest_invoice.id,
          'metadata[plus_subscription_id]':  sub.id,
        }),
      });
      const pi = await piRes.json();

      if (piRes.ok && pi.client_secret) {
        paymentIntentClientSecret = pi.client_secret;
        console.log(`[Plus] PaymentIntent manual creado: ${pi.id} para invoice=${diagSource.latest_invoice.id}`);
      } else {
        console.error('[Plus] Error creando PaymentIntent manual:', JSON.stringify(pi));
      }
    }

    if (!setupIntentClientSecret && !paymentIntentClientSecret) {
      console.error('[Plus] Sin client_secret tras reintento — subscription:', sub.id, 'hadTrial:', hadTrial,
        'latest_invoice:', JSON.stringify(diagSource.latest_invoice), 'pending_setup_intent:', JSON.stringify(diagSource.pending_setup_intent));

      // 🔎 Diagnóstico temporal en el propio mensaje de error — no tenemos
      // acceso a los logs del servidor desde aquí, así que el Alert que ve
      // el usuario ya trae lo necesario para encontrar la causa exacta.
      const invType = typeof diagSource.latest_invoice;
      const invStatus = invType === 'object' ? (diagSource.latest_invoice?.status ?? 'sin status') : diagSource.latest_invoice ?? 'null';
      const piType = invType === 'object' ? typeof diagSource.latest_invoice?.payment_intent : 'n/a';
      const confSecretType = invType === 'object' ? (diagSource.latest_invoice?.confirmation_secret?.type ?? 'ausente') : 'n/a';
      const setupType = typeof diagSource.pending_setup_intent;
      const collMethod = diagSource.collection_method ?? 'n/a';
      const amountDue = invType === 'object' ? (diagSource.latest_invoice?.amount_due ?? 'n/a') : 'n/a';
      const diag = `sub=${diagSource.status} coll=${collMethod} hadTrial=${hadTrial} invoice=${invType}(${invStatus}) due=${amountDue} pi=${piType} confSecret=${confSecretType} setup=${setupType}`;

      return jsonRes({ error: `No se recibió el token de configuración de pago. [${diag}]` });
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

    console.log(`[Plus] Subscription ${sub.id} | group=${group_id} | plan=${plan} | currency=${currency} | trial=${!hadTrial}`);

    return jsonRes({
      ok:                            true,
      setup_intent_client_secret:    setupIntentClientSecret,
      payment_intent_client_secret:  paymentIntentClientSecret,
      trial:                         !hadTrial,
      subscription_id:               sub.id,
    });

  } catch (e: unknown) {
    const msg = e instanceof Error ? e.message : 'Error interno';
    console.error('[create-plus-subscription] Error:', msg);
    return jsonRes({ error: msg }, 500);
  }
});
