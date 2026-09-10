// ═══════════════════════════════════════════════════════════════════
// create-gift-payment-intent  —  Supabase Edge Function (Stripe)
//
// Cobra un REGALO/DONACIÓN a un grupo con Stripe (PaymentSheet), SOLO
// tarjeta — pago único, confirmación instantánea para animar el emoji.
//
// Es la copia 1:1 de create-gift-order (Conekta) pero con Stripe como
// procesador. Se usa mientras Conekta no tenga tarjetas habilitadas
// (~90 días desde la aprobación de la cuenta, 2026-09-09). Cuando
// Conekta habilite tarjeta: GiftPickerModal.tsx → GIFTS_VIA_STRIPE = false
// y todo vuelve a create-gift-order sin tocar esta función.
//
// El MONTO sale SIEMPRE del catálogo en BD (server-side, nunca del
// cliente) y la moneda sale del país del grupo — mismo criterio que
// create-gift-order y currencyForCountry() en el resto de la app.
//
// La confirmación la hace stripe-webhook (payment_intent.succeeded →
// rama gift_order_id) llamando a confirm_gift_payment (idempotente,
// agnóstica del proveedor — el 2º parámetro solo se guarda como
// payment_ref de texto). Misma RPC que usa conekta-webhook.
//
// Body (autenticado): { group_id, gift_id, post_id?, custom_amount?, reservation_id? }
// Respuesta: { ok, client_secret, payment_intent_id, gift_order_id }
// Requiere: STRIPE_SECRET_KEY en Supabase Secrets
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

// 'Estados Unidos' y 'Canadá' cobran en USD (Canadá no tiene columna de
// saldo en CAD todavía en group_wallets — mientras se hace esa migración
// completa, se le trata como USD en vez de caer por error a pesos
// mexicanos). Cualquier otro país, MXN. Mismo criterio que create-gift-order.
function currencyForGroupCountry(country: string | null): 'MXN' | 'USD' {
  return country === 'Estados Unidos' || country === 'Canadá' ? 'USD' : 'MXN';
}

// 40% Daricefy / 60% grupo — acordado con el usuario para regalos.
const PLATFORM_CUT = 0.40;

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });

  const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? '';
  const SERVICE_KEY  = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
  const stripeKey    = Deno.env.get('STRIPE_SECRET_KEY') ?? '';

  const admin = createClient(SUPABASE_URL, SERVICE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  try {
    if (!stripeKey) return jsonResponse({ error: 'STRIPE_SECRET_KEY no configurado' }, 500);

    // ── Autenticar ──────────────────────────────────────────────────
    const authHeader = req.headers.get('Authorization') ?? '';
    const jwt = authHeader.replace('Bearer ', '').trim();
    if (!jwt) return jsonResponse({ error: 'No autorizado' }, 401);
    const { data: authData, error: authErr } = await admin.auth.getUser(jwt);
    if (authErr || !authData?.user) return jsonResponse({ error: 'Token inválido' }, 401);
    const user = authData.user;

    // ── Body ────────────────────────────────────────────────────────
    const { group_id, gift_id, post_id, custom_amount, reservation_id } = await req.json().catch(() => ({})) as {
      group_id?: string; gift_id?: string; post_id?: string; custom_amount?: number | null; reservation_id?: string | null;
    };
    if (!group_id || !gift_id) {
      return jsonResponse({ error: 'group_id y gift_id son requeridos' }, 400);
    }

    // ── Grupo destino (para moneda + que no sea uno mismo) ────────────
    const { data: group } = await admin
      .from('groups').select('id, name, country, owner_id, is_plus_active, plus_expires_at').eq('id', group_id).single();
    if (!group) return jsonResponse({ error: 'Grupo no encontrado' }, 404);
    if (group.owner_id === user.id) {
      return jsonResponse({ error: 'No puedes regalarte a ti mismo' }, 400);
    }

    // 🏆 Recibir regalos es exclusivo de grupos con Plus vigente — mismo
    // candado que las publicaciones de fotos (sql/571).
    const plusVigente = !!group.is_plus_active &&
      (!group.plus_expires_at || new Date(group.plus_expires_at) > new Date());
    if (!plusVigente) {
      return jsonResponse({ error: 'Este grupo todavía no tiene activada la opción de recibir regalos.' }, 400);
    }

    // ── Publicación (opcional) — debe pertenecer a este grupo ─────────
    if (post_id) {
      const { data: post } = await admin
        .from('group_event_posts').select('id, group_id').eq('id', post_id).single();
      if (!post || post.group_id !== group_id) {
        return jsonResponse({ error: 'La publicación no pertenece a este grupo' }, 400);
      }
    }

    // 🎁 "Dar propina" desde la pantalla de calificar post-evento (opcional)
    // — la reservación debe ser de este cliente y de este grupo.
    if (reservation_id) {
      const { data: resv } = await admin
        .from('reservations').select('id, group_id, client_id').eq('id', reservation_id).single();
      if (!resv || resv.group_id !== group_id || resv.client_id !== user.id) {
        return jsonResponse({ error: 'La reservación no corresponde a este grupo/cliente' }, 400);
      }
    }

    // ── Precio del regalo (server-side, en la moneda del grupo) ───────
    const currency = currencyForGroupCountry(group.country);
    const { data: gift } = await admin
      .from('gift_catalog').select('id, emoji, name, active').eq('id', gift_id).single();
    if (!gift || !gift.active) return jsonResponse({ error: 'Regalo no disponible' }, 404);

    const { data: priceRow } = await admin
      .from('gift_catalog_prices')
      .select('amount')
      .eq('gift_id', gift_id).eq('currency_code', currency)
      .single();
    const basePrice = Number(priceRow?.amount ?? 0);
    if (!(basePrice > 0)) return jsonResponse({ error: 'Precio no disponible en esta moneda' }, 400);

    // "Otro monto" (2026-08-26) — el cliente puede dar más que el precio de
    // catálogo. SIEMPRE se valida server-side contra basePrice: nunca se
    // confía en un monto menor mandado desde el cliente, y se pone un tope
    // razonable para frenar errores de dedo (ej. de más).
    let amount = basePrice;
    if (custom_amount != null) {
      const requested = Number(custom_amount);
      const maxAllowed = basePrice * 50;
      if (!Number.isFinite(requested) || requested < basePrice) {
        return jsonResponse({ error: `El monto mínimo es ${basePrice} ${currency}` }, 400);
      }
      if (requested > maxAllowed) {
        return jsonResponse({ error: `El monto máximo es ${maxAllowed} ${currency}` }, 400);
      }
      amount = Math.round(requested * 100) / 100;
    }

    const groupAmount    = Math.round(amount * (1 - PLATFORM_CUT) * 100) / 100;
    const platformAmount = Math.round((amount - groupAmount) * 100) / 100;

    // ── Crear la fila pendiente ─────────────────────────────────────
    const { data: giftOrder, error: insErr } = await admin
      .from('group_gifts')
      .insert({
        group_id, post_id: post_id ?? null, sender_id: user.id, gift_id,
        reservation_id: reservation_id ?? null,
        currency_code: currency, amount, group_amount: groupAmount, platform_amount: platformAmount,
        payment_provider: 'stripe', status: 'pending',
      })
      .select('id').single();
    if (insErr || !giftOrder) {
      console.error('[create-gift-payment-intent] insert error:', insErr);
      return jsonResponse({ error: 'No se pudo crear la orden del regalo' }, 500);
    }

    // ── Crear PaymentIntent en Stripe ──────────────────────────────
    // Pago único con tarjeta (sin MSI — los regalos son montos chicos y
    // deben confirmar al instante). Stripe exige mínimo ~$0.50 USD / ~$10 MXN.
    const stripeCurrency = currency.toLowerCase(); // 'mxn' | 'usd'
    const minCentavos    = currency === 'USD' ? 50 : 1000;
    const amountCentavos = Math.max(Math.round(amount * 100), minCentavos);

    const piBody = new URLSearchParams({
      amount:                     String(amountCentavos),
      currency:                   stripeCurrency,
      description:                `🎁 ${gift.name} — ${group.name}`,
      'metadata[type]':           'gift',
      'metadata[gift_order_id]':  giftOrder.id,
      'metadata[group_id]':       group_id,
      'metadata[sender_id]':      user.id,
      'metadata[currency]':       stripeCurrency,
      'automatic_payment_methods[enabled]': 'true',
    });

    // Idempotency-Key: si el cliente llama dos veces con la misma orden de
    // regalo, Stripe reutiliza el PaymentIntent en lugar de crear otro.
    const stripeRes = await fetch('https://api.stripe.com/v1/payment_intents', {
      method: 'POST',
      headers: {
        Authorization:     `Bearer ${stripeKey}`,
        'Content-Type':    'application/x-www-form-urlencoded',
        'Idempotency-Key': `pi_gift_${giftOrder.id}`,
      },
      body: piBody,
    });
    const stripeData = await stripeRes.json() as any;

    if (!stripeRes.ok) {
      console.error('[create-gift-payment-intent] Error Stripe:', JSON.stringify(stripeData));
      return jsonResponse({ error: stripeData?.error?.message ?? 'Error creando PaymentIntent en Stripe' }, 502);
    }

    console.log(`[create-gift-payment-intent] pi=${stripeData.id} gift_order=${giftOrder.id} group=${group_id} amount=${amount} ${currency}`);

    return jsonResponse({
      ok: true,
      client_secret:     stripeData.client_secret,
      payment_intent_id: stripeData.id,
      gift_order_id:     giftOrder.id,
    });

  } catch (err: any) {
    console.error('[create-gift-payment-intent] Error:', err);
    return jsonResponse({ error: err.message ?? 'Error interno' }, 500);
  }
});
