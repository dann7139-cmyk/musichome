// ═══════════════════════════════════════════════════════════════════
// create-plus-conekta-order  —  Supabase Edge Function (Conekta, MX)
//
// PAGO ÚNICO ANUAL de Verificación Plus: crea una orden Conekta con
// Checkout HOSTED (tarjeta, SPEI u OXXO) por 1 año de Plus.
// La suscripción RECURRENTE mensual/anual sigue siendo Stripe
// (create-plus-subscription) — esto es la alternativa sin renovación
// automática, pagable en efectivo.
//
// La activación la hace conekta-webhook (fuente de verdad) llamando a
// activate_plus con vencimiento a 365 días (o extendiendo el actual).
//
// Body (autenticado, dueño del grupo): { group_id }
// Respuesta: { ok, order_id, checkout_url }
// Requiere: CONEKTA_PRIVATE_KEY en Supabase Secrets.
// ═══════════════════════════════════════════════════════════════════

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

// Precio del año de Plus. ⚠️ Debe coincidir con el precio anual mostrado
// en PlusScreen.tsx ($1,499 MXN). Autoritativo: este archivo.
const PLUS_ANNUAL_MXN = 1499;

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

    // ── Autenticar ────────────────────────────────────────────────────
    const authHeader = req.headers.get('Authorization') ?? '';
    const jwt = authHeader.replace('Bearer ', '').trim();
    if (!jwt) return jsonResponse({ error: 'No autorizado' }, 401);
    const { data: authData, error: authErr } = await admin.auth.getUser(jwt);
    if (authErr || !authData?.user) return jsonResponse({ error: 'Token inválido' }, 401);
    const user = authData.user;

    // ── Body + grupo (solo el DUEÑO puede comprar su Plus) ────────────
    const { group_id } = await req.json().catch(() => ({})) as { group_id?: string };
    if (!group_id) return jsonResponse({ error: 'group_id requerido' }, 400);

    const { data: grp, error: grpErr } = await admin
      .from('groups')
      .select('id, name, owner_id, is_plus_active, plus_expires_at')
      .eq('id', group_id)
      .single();
    if (grpErr || !grp) return jsonResponse({ error: 'Grupo no encontrado' }, 404);
    if (grp.owner_id !== user.id) return jsonResponse({ error: 'Sin permiso' }, 403);

    // ── Datos del comprador para Conekta ──────────────────────────────
    const { data: profile } = await admin
      .from('profiles').select('full_name, phone').eq('id', user.id).single();

    const rawPhone = String(profile?.phone ?? '').replace(/\D/g, '');
    const e164Phone =
      rawPhone.length === 10                              ? `+52${rawPhone}` :
      rawPhone.length === 12 && rawPhone.startsWith('52')  ? `+${rawPhone}` :
      rawPhone.length === 13 && rawPhone.startsWith('521') ? `+52${rawPhone.slice(3)}` :
      '+525555555555';

    // ── Crear orden HostedPayment (tarjeta, SPEI u OXXO en una sola página) ──
    const auth = btoa(`${privateKey}:`);
    const orderBody = {
      currency: 'MXN',
      customer_info: {
        name:  profile?.full_name ?? 'Grupo Daricefy',
        email: user.email ?? 'grupo@daricefy.com',
        phone: e164Phone,
      },
      line_items: [
        {
          name:       `Verificación Plus — 1 año (${grp.name ?? 'grupo'})`,
          unit_price: PLUS_ANNUAL_MXN * 100,   // centavos
          quantity:   1,
        },
      ],
      checkout: {
        type: 'HostedPayment',
        allowed_payment_methods: ['card', 'bank_transfer', 'cash'],
        success_url: 'https://daricefy.com/pago-ok',
        failure_url: 'https://daricefy.com/pago-error',
      },
      // El webhook distingue esta orden de una reserva por plus_group_id
      metadata: { type: 'plus_annual', plus_group_id: group_id },
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
      console.error('[create-plus-conekta-order] Error Conekta:', JSON.stringify(data));
      return jsonResponse({ error: data?.details?.[0]?.message ?? 'Error creando orden Conekta' }, 502);
    }

    const checkoutUrl = data?.checkout?.url ?? null;
    if (!checkoutUrl) {
      console.error('[create-plus-conekta-order] Sin checkout.url:', JSON.stringify(data?.checkout));
      return jsonResponse({ error: 'Conekta no devolvió checkout.url' }, 502);
    }

    console.log(`[create-plus-conekta-order] order=${data?.id} group=${group_id} amount=${PLUS_ANNUAL_MXN}`);

    return jsonResponse({ ok: true, order_id: data?.id ?? null, checkout_url: checkoutUrl });

  } catch (err: any) {
    console.error('[create-plus-conekta-order] Error:', err);
    return jsonResponse({ error: err.message ?? 'Error interno' }, 500);
  }
});
