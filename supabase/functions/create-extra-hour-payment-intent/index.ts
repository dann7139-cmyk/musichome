// ═══════════════════════════════════════════════════════════════════
// create-extra-hour-payment-intent  –  Supabase Edge Function (Stripe)
//
// Crea un PaymentIntent para pago de horas extra directamente con
// Stripe + MSI. Copia adaptada de create-payment-intent.
//
// Diferencias vs create-payment-intent:
//   · Param principal: extra_hour_id (no reservation_id).
//   · MSI máximo: 9 meses (no 12). Extras son montos menores.
//   · Verifica extra.status = 'pending_payment' (grupo ya aceptó vía sql/400).
//   · Metadata incluye extra_hour_id + reservation_id.
//   · Idempotency-Key: pi_extra_${extra_hour_id}_${amount}.
//   · Guarda msi_months en extra_hours (no en reservations).
//
// Body: { extra_hour_id: UUID, msi_months?: 1 | 3 | 6 | 9 }
// Requiere: STRIPE_SECRET_KEY en Supabase Secrets
// ═══════════════════════════════════════════════════════════════════

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { MSI_FEE_RATES } from '../_shared/constants.ts';

const supabase = createClient(
  Deno.env.get('SUPABASE_URL')!,
  Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
);

const corsHeaders = {
  'Access-Control-Allow-Origin':  '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

function jsonResponse(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}

const ALLOWED_MSI_MONTHS = [1, 3, 6, 9];

function calcMsiFee(totalExtraCost: number, months: number): number {
  if (months <= 1) return 0;
  return Math.round(totalExtraCost * (MSI_FEE_RATES[months] ?? 0));
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
    const { extra_hour_id, msi_months: bodyMsiMonths } = body as {
      extra_hour_id?: string;
      msi_months?: number;
    };

    if (!extra_hour_id) return jsonResponse({ error: 'extra_hour_id es requerido' }, 400);

    // ── Leer extra_hour con datos de la reserva ─────────────────────
    const { data: extra, error: extraErr } = await supabase
      .from('extra_hours')
      .select(`
        id,
        reservation_id,
        total_extra_cost,
        group_extra_earnings,
        hours_added,
        status,
        reservation:reservations(
          id,
          client_id,
          event_country,
          currency_code,
          group:groups(name)
        )
      `)
      .eq('id', extra_hour_id)
      .single();

    if (extraErr || !extra) return jsonResponse({ error: 'Hora extra no encontrada' }, 404);

    const reservation = extra.reservation as {
      id: string;
      client_id: string;
      event_country: string | null;
      currency_code: string | null;
      group: { name: string } | null;
    } | null;

    if (!reservation) return jsonResponse({ error: 'Reserva no encontrada' }, 404);

    // ── Verificar que el llamante es el cliente ─────────────────────
    if (reservation.client_id !== user.id) {
      return jsonResponse({ error: 'Sin permiso' }, 403);
    }

    // ── Verificar estado de la hora extra ───────────────────────────
    console.log(`[EH-PI] extra=${extra_hour_id} status=${extra.status}`);
    if (extra.status !== 'pending_payment') {
      console.error(`[EH-PI] status inválido: ${extra.status} (esperado: pending_payment)`);
      return jsonResponse(
        { error: 'La hora extra no está disponible para pago.', status: extra.status },
        400,
      );
    }

    // ── Stripe secret key ───────────────────────────────────────────
    const stripeKey = Deno.env.get('STRIPE_SECRET_KEY');
    if (!stripeKey) return jsonResponse({ error: 'STRIPE_SECRET_KEY no configurado.' }, 500);

    // ── Detectar moneda por país del evento ─────────────────────────
    const stripeCurrency =
      (reservation.event_country === 'US' || reservation.currency_code === 'USD')
        ? 'usd'
        : 'mxn';
    const isUsd = stripeCurrency === 'usd';

    // ── Determinar MSI months ───────────────────────────────────────
    // MSI exclusivo de MXN. Para USD forzar 1 pago.
    let msiMonths: number = isUsd ? 1 : (bodyMsiMonths ?? 1);
    if (!ALLOWED_MSI_MONTHS.includes(msiMonths)) msiMonths = 1;

    const totalExtraCost = extra.total_extra_cost ?? 0;
    const msiFeeAmount   = isUsd ? 0 : calcMsiFee(totalExtraCost, msiMonths);
    const chargeAmount   = totalExtraCost + msiFeeAmount;
    const minCentavos    = isUsd ? 50 : 1000;
    const amountCentavos = Math.max(Math.round(chargeAmount * 100), minCentavos);

    // ── Guardar MSI choice en extra_hours ───────────────────────────
    if (msiMonths > 1 || msiFeeAmount > 0) {
      await supabase
        .from('extra_hours')
        .update({ msi_months: msiMonths, msi_fee_amount: msiFeeAmount })
        .eq('id', extra_hour_id);
      console.log(
        `[EH-PI] MSI guardado: extra=${extra_hour_id} msi_months=${msiMonths} msi_fee=${msiFeeAmount}`,
      );
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

    const groupName = reservation.group?.name ?? 'Grupo musical';
    const hoursLabel = extra.hours_added === 1 ? '1h' : `${extra.hours_added}h`;

    // ── Crear PaymentIntent ─────────────────────────────────────────
    const piBody = new URLSearchParams({
      amount:                        String(amountCentavos),
      currency:                      stripeCurrency,
      customer:                      stripeCustomerId,
      description:                   `Hora extra (${hoursLabel}) – ${groupName}`,
      'metadata[extra_hour_id]':     extra_hour_id,
      'metadata[reservation_id]':    extra.reservation_id,
      'metadata[client_id]':         user.id,
      'metadata[payment_mode]':      msiMonths > 1 ? 'extra_msi' : 'extra',
      'metadata[total_extra_cost]':  String(totalExtraCost),
      'metadata[msi_months]':        String(msiMonths),
      'metadata[msi_fee_amount]':    String(msiFeeAmount),
      'metadata[currency]':          stripeCurrency,
    });

    // MSI solo en MXN.
    if (!isUsd) {
      piBody.set('payment_method_options[card][installments][enabled]', 'true');
    }

    // Para MSI: forzar método tarjeta. Para pago único: métodos automáticos.
    if (msiMonths > 1) {
      piBody.set('payment_method_types[]', 'card');
    } else {
      piBody.set('automatic_payment_methods[enabled]', 'true');
    }

    // Idempotency-Key: reutiliza el PI si el cliente llama dos veces
    // con los mismos params, evitando doble cargo.
    const stripeRes = await fetch('https://api.stripe.com/v1/payment_intents', {
      method: 'POST',
      headers: {
        Authorization:     `Bearer ${stripeKey}`,
        'Content-Type':    'application/x-www-form-urlencoded',
        'Idempotency-Key': `pi_extra_${extra_hour_id}_${amountCentavos}`,
      },
      body: piBody,
    });

    const stripeData = await stripeRes.json() as any;

    if (!stripeRes.ok) {
      console.error('[Stripe] Error:', JSON.stringify(stripeData));
      return jsonResponse(
        { error: stripeData?.error?.message ?? 'Error al crear PaymentIntent en Stripe' },
        502,
      );
    }

    console.log(
      `[EH-PI] PI ${stripeData.id} | base=${totalExtraCost} msi_fee=${msiFeeAmount} ` +
      `total=${chargeAmount} centavos=${amountCentavos} | msi=${msiMonths}m | extra=${extra_hour_id}`,
    );

    return jsonResponse({
      client_secret:     stripeData.client_secret,
      payment_intent_id: stripeData.id,
      total_extra_cost:  totalExtraCost,
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
