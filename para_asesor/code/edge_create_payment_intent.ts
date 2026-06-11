// ═══════════════════════════════════════════════════════════════════
// create-payment-intent  –  Supabase Edge Function (Stripe)
// Crea un PaymentIntent en Stripe usando fetch directo (sin SDK).
// Crea/reutiliza un Stripe Customer y guarda la tarjeta para el
// cobro automático del 50% restante al finalizar el evento.
// Requiere: STRIPE_SECRET_KEY en Supabase Secrets
// ═══════════════════════════════════════════════════════════════════

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const supabase = createClient(
  Deno.env.get('SUPABASE_URL')!,
  Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
);

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

function jsonResponse(body: Record<string, unknown>, _status = 200) {
  return new Response(JSON.stringify(body), {
    status: 200,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
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
    const { reservation_id } = await req.json();
    if (!reservation_id) return jsonResponse({ error: 'reservation_id es requerido' }, 400);

    // ── Leer la reserva ─────────────────────────────────────────────
    const { data: res, error: resErr } = await supabase
      .from('reservations')
      .select('id, total_price, client_id, status, group:groups(name)')
      .eq('id', reservation_id)
      .single();

    if (resErr || !res) return jsonResponse({ error: 'Reserva no encontrada' }, 404);
    if (res.client_id !== user.id) return jsonResponse({ error: 'Sin permiso' }, 403);
    const terminalStatuses = ['cancelled', 'rejected', 'expired', 'completed'];
    if (terminalStatuses.includes(res.status)) {
      return jsonResponse({ error: 'Esta reserva ya no puede procesarse.' }, 400);
    }

    // ── Stripe secret key ───────────────────────────────────────────
    const stripeKey = Deno.env.get('STRIPE_SECRET_KEY');
    if (!stripeKey) return jsonResponse({ error: 'STRIPE_SECRET_KEY no configurado.' }, 500);

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
      const cust = await custRes.json();
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

    // ── Calcular monto ──────────────────────────────────────────────
    const totalPrice     = res.total_price ?? 0;
    const depositAmount  = Math.round((totalPrice * 50) / 100);
    const depositMXN     = Math.max(depositAmount, 10); // mínimo Stripe 10 MXN
    const amountCentavos = depositMXN * 100;
    const remainingAmount = totalPrice - depositAmount;

    const groupName = (res.group as any)?.name ?? 'Grupo musical';

    // ── Crear PaymentIntent con setup_future_usage = off_session ────
    // off_session guarda la tarjeta para cobrar el 50% restante sin
    // intervención del cliente cuando el evento finalice.
    const piBody = new URLSearchParams({
      amount:                               String(amountCentavos),
      currency:                             'mxn',
      customer:                             stripeCustomerId,
      description:                          `Anticipo 50% – ${groupName}`,
      setup_future_usage:                   'off_session',
      'automatic_payment_methods[enabled]': 'true',
      'metadata[reservation_id]':           reservation_id,
      'metadata[client_id]':                user.id,
      'metadata[deposit_percent]':          '50',
      'metadata[full_price]':               String(totalPrice),
      'metadata[remaining_amount]':         String(remainingAmount),
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
      console.error('[Stripe] Error:', JSON.stringify(stripeData));
      return jsonResponse({ error: stripeData?.error?.message ?? 'Error al crear PaymentIntent en Stripe' }, 502);
    }

    console.log(`[Stripe] PaymentIntent ${stripeData.id} | ${amountCentavos} centavos | customer=${stripeCustomerId}`);

    return jsonResponse({
      client_secret:     stripeData.client_secret,
      payment_intent_id: stripeData.id,
      deposit:           depositMXN,
      full_price:        totalPrice,
    });

  } catch (err: any) {
    console.error('Error interno:', err);
    return jsonResponse({ error: err.message ?? 'Error interno' }, 500);
  }
});
