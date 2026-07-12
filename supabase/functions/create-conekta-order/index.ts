// ═══════════════════════════════════════════════════════════════════
// create-conekta-order  —  Supabase Edge Function (Conekta, MX)
//
// Crea una orden Conekta con Checkout HOSTED por el total de una reserva
// REAL, con metadata.reservation_id. Devuelve la URL hosted para abrir en
// navegador in-app. El pago se confirma vía conekta-webhook (fuente de
// verdad) → misma confirm_full_payment_and_credit_wallet que Stripe.
//
// NO toca wallet, GPS, liberaciones ni anti-fraude — solo cobra.
//
// Body: { reservation_id, method? }  method ∈ 'card'|'spei'|'cash'|'msi'
// Requiere: CONEKTA_PRIVATE_KEY en Supabase Secrets.
// ═══════════════════════════════════════════════════════════════════

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

// Descuento por pagar con SPEI. Sale del MARGEN de la plataforma, NUNCA de
// group_earnings (el grupo cobra completo). Constante configurable: cambiar
// aquí (backend, autoritativo del cobro) y en el frontend (solo display).
// ⚠️ Debe coincidir con SPEI_DISCOUNT de QuotePaymentScreen.tsx.
const SPEI_DISCOUNT = 100; // MXN

// Métodos de pago Conekta por opción del checkout Daricefy.
// 'msi' abre tarjeta; los meses (monthly_installments) se activan cuando
// habilitemos MSI en Conekta, sin tocar el frontend.
const METHOD_MAP: Record<string, string[]> = {
  card: ['card'],
  spei: ['bank_transfer'],
  cash: ['cash'],
  msi:  ['card'],
  // BNPL — token oficial confirmado en docs de Conekta (guía de activación):
  // allowed_payment_methods acepta 'bnpl'. Proveedores: Creditea, Aplazo,
  // Klarna Coppel (Azteca próximamente). Requiere ACTIVACIÓN en la cuenta
  // Conekta; mientras, el frontend lo mantiene oculto (enabled: false).
  bnpl: ['bnpl'],
};

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

    // ── Autenticar al cliente ─────────────────────────────────────────
    const authHeader = req.headers.get('Authorization') ?? '';
    const jwt = authHeader.replace('Bearer ', '').trim();
    if (!jwt) return jsonResponse({ error: 'No autorizado' }, 401);
    const { data: authData, error: authErr } = await admin.auth.getUser(jwt);
    if (authErr || !authData?.user) return jsonResponse({ error: 'Token inválido' }, 401);
    const user = authData.user;

    // ── Body + reserva ────────────────────────────────────────────────
    const { reservation_id, method } = await req.json().catch(() => ({})) as {
      reservation_id?: string; method?: string;
    };
    if (!reservation_id) return jsonResponse({ error: 'reservation_id requerido' }, 400);
    const payMethod = (method && METHOD_MAP[method]) ? method : 'card';

    const { data: res, error: resErr } = await admin
      .from('reservations')
      .select('id, total_price, client_id, status, payment_status, folio, group:groups(name)')
      .eq('id', reservation_id)
      .single();
    if (resErr || !res) return jsonResponse({ error: 'Reserva no encontrada' }, 404);
    if (res.client_id !== user.id) return jsonResponse({ error: 'Sin permiso' }, 403);

    if (['cancelled', 'rejected', 'expired', 'completed'].includes(res.status as string)) {
      return jsonResponse({ error: 'Esta reserva ya no puede procesarse.' }, 400);
    }
    if (['paid', 'fully_paid'].includes(res.payment_status ?? '')) {
      return jsonResponse({ error: 'Esta reserva ya fue pagada.' }, 400);
    }

    // Un cobro por Conekta (tarjeta/SPEI/efectivo) es SIEMPRE pago único — los
    // meses (MSI) van por Stripe. Limpiamos cualquier MSI heredado (p. ej. una
    // reserva express sembrada con msi_months) para que el webhook NO acredite
    // una comisión de financiamiento fantasma al admin. No toca group_earnings.
    await admin
      .from('reservations')
      .update({ msi_months: null, msi_fee_amount: 0 })
      .eq('id', reservation_id);

    // ── Datos del cliente para Conekta ────────────────────────────────
    const { data: profile } = await admin
      .from('profiles').select('full_name, phone').eq('id', user.id).single();

    // Teléfono en E.164 (+52XXXXXXXXXX): BNPL manda OTP por SMS y algunos
    // proveedores rechazan la orden con teléfono mal formado (los perfiles
    // guardan 10 dígitos locales sin +52).
    const rawPhone = String(profile?.phone ?? '').replace(/\D/g, '');
    const e164Phone =
      rawPhone.length === 10                            ? `+52${rawPhone}` :
      rawPhone.length === 12 && rawPhone.startsWith('52') ? `+${rawPhone}` :
      rawPhone.length === 13 && rawPhone.startsWith('521') ? `+52${rawPhone.slice(3)}` :
      '+525555555555';

    const totalPrice = res.total_price as number;
    // Descuento SPEI: el cliente paga total − $100 por transferencia. El grupo
    // cobra completo (la RPC del webhook deriva group_earnings del precio base);
    // el $100 lo absorbe el margen de la plataforma. NO tocamos wallet ni RPC.
    const discount       = payMethod === 'spei' ? SPEI_DISCOUNT : 0;
    const chargePesos    = Math.max(totalPrice - discount, 0);
    const amountCentavos = Math.max(Math.round(chargePesos * 100), 1000); // mínimo ~$10 MXN
    const groupName      = (res.group as any)?.name ?? 'Grupo musical';

    // ── Crear orden HostedPayment ─────────────────────────────────────
    const auth = btoa(`${privateKey}:`);
    const orderBody = {
      currency: 'MXN',
      customer_info: {
        name:  profile?.full_name ?? 'Cliente Daricefy',
        email: user.email ?? 'cliente@daricefy.com',
        phone: e164Phone,
      },
      line_items: [
        { name: `Evento — ${groupName}`, unit_price: amountCentavos, quantity: 1 },
      ],
      checkout: {
        type: 'HostedPayment',
        allowed_payment_methods: METHOD_MAP[payMethod],
        success_url: 'https://daricefy.com/pago-ok',
        failure_url: 'https://daricefy.com/pago-error',
      },
      metadata: { reservation_id: reservation_id, folio: res.folio ?? null, method: payMethod },
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
      console.error('[create-conekta-order] Error Conekta:', JSON.stringify(data));
      return jsonResponse({ error: data?.details?.[0]?.message ?? 'Error creando orden Conekta' }, 502);
    }

    const checkoutUrl = data?.checkout?.url ?? null;
    if (!checkoutUrl) {
      console.error('[create-conekta-order] Sin checkout.url:', JSON.stringify(data?.checkout));
      return jsonResponse({ error: 'Conekta no devolvió checkout.url' }, 502);
    }

    console.log(`[create-conekta-order] order=${data?.id} reservation=${reservation_id} method=${payMethod} amount=${amountCentavos}`);

    return jsonResponse({
      ok: true,
      order_id:      data?.id ?? null,
      checkout_url:  checkoutUrl,
      reservation_id,
    });

  } catch (err: any) {
    console.error('[create-conekta-order] Error:', err);
    return jsonResponse({ error: err.message ?? 'Error interno' }, 500);
  }
});
