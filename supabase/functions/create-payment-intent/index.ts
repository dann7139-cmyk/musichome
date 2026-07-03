// ═══════════════════════════════════════════════════════════════════
// create-payment-intent  –  Supabase Edge Function (Stripe)
//
// Crea un PaymentIntent por el monto total + MSI fee (si aplica).
// El grupo siempre recibe group_earnings (sin MSI fee).
// El MSI fee queda como revenue adicional de DARICEFY.
//
// Body: { reservation_id, msi_months? }
// Requiere: STRIPE_SECRET_KEY en Supabase Secrets
// ═══════════════════════════════════════════════════════════════════

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { MSI_FEE_RATES } from '../_shared/constants.ts';

const supabase = createClient(
  Deno.env.get('SUPABASE_URL')!,
  Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
);

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


function calcMsiFee(totalPrice: number, months: number): number {
  if (months <= 1) return 0;
  return Math.round(totalPrice * (MSI_FEE_RATES[months] ?? 0));
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });

  try {
    // ── Autenticar al usuario llamante ──────────────────────────────
    const authHeader = req.headers.get('Authorization') ?? '';
    const jwt = authHeader.replace('Bearer ', '').trim();
    if (!jwt) return jsonResponse({ error: 'No autorizado' }, 401);

    const { data: { user }, error: authErr } = await supabase.auth.getUser(jwt);
    if (authErr || !user) return jsonResponse({ error: 'No autorizado' }, 401);

    // ── Leer body ───────────────────────────────────────────────────
    const body = await req.json();
    const { reservation_id, msi_months: bodyMsiMonths } = body;
    if (!reservation_id) return jsonResponse({ error: 'reservation_id es requerido' }, 400);

    // ── Leer la reserva ─────────────────────────────────────────────
    const { data: res, error: resErr } = await supabase
      .from('reservations')
      .select('id, total_price, base_price, client_id, status, payment_status, msi_months, event_country, currency_code, group:groups(name)')
      .eq('id', reservation_id)
      .single();

    if (resErr || !res) return jsonResponse({ error: 'Reserva no encontrada' }, 404);
    if (res.client_id !== user.id) return jsonResponse({ error: 'Sin permiso' }, 403);

    const terminalStatuses = ['cancelled', 'rejected', 'expired', 'completed'];
    if (terminalStatuses.includes(res.status)) {
      return jsonResponse({ error: 'Esta reserva ya no puede procesarse.' }, 400);
    }
    if (['paid', 'fully_paid'].includes(res.payment_status ?? '')) {
      return jsonResponse({ error: 'Esta reserva ya fue pagada.' }, 400);
    }

    // ── Stripe secret key ───────────────────────────────────────────
    const stripeKey = Deno.env.get('STRIPE_SECRET_KEY');
    if (!stripeKey) return jsonResponse({ error: 'STRIPE_SECRET_KEY no configurado.' }, 500);

    // ── Detectar moneda por país del evento ─────────────────────────
    // MX → mxn  |  US → usd
    // MSI solo aplica en MXN (producto México de Stripe).
    const stripeCurrency = (res.event_country === 'US' || res.currency_code === 'USD') ? 'usd' : 'mxn';
    const isUsd          = stripeCurrency === 'usd';

    // ── Determinar MSI months ───────────────────────────────────────
    // MSI exclusivo de MXN. Para USD forzar 1 pago.
    let msiMonths: number = isUsd ? 1 : (bodyMsiMonths ?? res.msi_months ?? 1);
    const totalPrice      = res.total_price ?? 0;
    const msiFeeAmount    = isUsd ? 0 : calcMsiFee(totalPrice, msiMonths);
    const chargeAmount    = totalPrice + msiFeeAmount;
    // Mínimo: 50 centavos de la moneda correspondiente (Stripe exige $0.50 USD, ~$10 MXN)
    const minCentavos     = isUsd ? 50 : 1000;
    const amountCentavos  = Math.max(Math.round(chargeAmount * 100), minCentavos);

    // ── Guardar MSI en la reserva (service_role bypassa RLS) ────────
    if (msiMonths > 1 || msiFeeAmount > 0) {
      await supabase
        .from('reservations')
        .update({ msi_months: msiMonths, msi_fee_amount: msiFeeAmount })
        .eq('id', reservation_id);
      console.log(`[PI] MSI guardado: reservation=${reservation_id} msi_months=${msiMonths} msi_fee=${msiFeeAmount}`);
    }

    // ── Obtener o crear Stripe Customer para este usuario ───────────
    const { data: profile } = await supabase
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
      const cust = await custRes.json() as any;
      if (!custRes.ok) {
        console.error('[Stripe] Error creando customer:', JSON.stringify(cust));
        return jsonResponse({ error: 'Error al crear perfil de pago' }, 502);
      }
      stripeCustomerId = cust.id;
      await supabase
        .from('profiles')
        .update({ stripe_customer_id: stripeCustomerId })
        .eq('id', user.id);
      console.log(`[Stripe] Customer creado: ${stripeCustomerId}`);
    }

    const groupName = (res.group as any)?.name ?? 'Grupo musical';

    // ── Crear PaymentIntent ─────────────────────────────────────────
    const piBody = new URLSearchParams({
      amount:                     String(amountCentavos),
      currency:                   stripeCurrency,
      customer:                   stripeCustomerId,
      description:                `Pago total – ${groupName}`,
      'metadata[reservation_id]': reservation_id,
      'metadata[client_id]':      user.id,
      'metadata[payment_mode]':   msiMonths > 1 ? 'full_msi' : 'full',
      'metadata[total_price]':    String(totalPrice),
      'metadata[msi_months]':     String(msiMonths),
      'metadata[msi_fee_amount]': String(msiFeeAmount),
      'metadata[currency]':       stripeCurrency,
    });

    // MSI solo en MXN. Installments habilitados solo para tarjetas mexicanas.
    if (!isUsd) {
      piBody.set('payment_method_options[card][installments][enabled]', 'true');
    }

    // payment_method_types: tarjeta para MSI MXN; automático para todo lo demás.
    if (msiMonths > 1) {
      piBody.set('payment_method_types[]', 'card');
    } else {
      piBody.set('automatic_payment_methods[enabled]', 'true');
    }

    // Idempotency-Key garantiza que si el cliente llama dos veces con el mismo
    // reservation_id, Stripe reutiliza el PaymentIntent existente en lugar de
    // crear uno nuevo — elimina el riesgo de doble cargo.
    const stripeRes = await fetch('https://api.stripe.com/v1/payment_intents', {
      method: 'POST',
      headers: {
        Authorization:      `Bearer ${stripeKey}`,
        'Content-Type':     'application/x-www-form-urlencoded',
        'Idempotency-Key':  `pi_${reservation_id}_${amountCentavos}`,
      },
      body: piBody,
    });

    const stripeData = await stripeRes.json() as any;

    if (!stripeRes.ok) {
      console.error('[Stripe] Error:', JSON.stringify(stripeData));
      return jsonResponse({ error: stripeData?.error?.message ?? 'Error al crear PaymentIntent en Stripe' }, 502);
    }

    console.log(
      `[Stripe] PI ${stripeData.id} | base=${totalPrice} msi_fee=${msiFeeAmount} total=${chargeAmount} ` +
      `centavos=${amountCentavos} | msi=${msiMonths}m | customer=${stripeCustomerId}`
    );

    return jsonResponse({
      client_secret:     stripeData.client_secret,
      payment_intent_id: stripeData.id,
      total_price:       totalPrice,
      msi_fee_amount:    msiFeeAmount,
      charge_amount:     chargeAmount,
      amount_centavos:   amountCentavos,
      msi_months:        msiMonths,
      currency:          stripeCurrency,
    });

  } catch (err: any) {
    console.error('Error interno:', err);
    return jsonResponse({ error: err.message ?? 'Error interno' }, 500);
  }
});
