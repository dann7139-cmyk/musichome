// ═══════════════════════════════════════════════════════════════════
// get-conekta-reference  —  Supabase Edge Function (Conekta, MX)
//
// Recupera los datos de pago pendiente de una orden Conekta (SPEI/efectivo)
// para mostrarlos EN LA APP: la página hosted de Conekta enseña la CLABE
// unos segundos y redirige, así que la app la re-muestra con esta función.
//
// Solo LECTURA — no cobra, no toca wallet ni reservas.
//
// Body: { order_id }
// Requiere: CONEKTA_PRIVATE_KEY en Supabase Secrets.
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

    const { order_id } = await req.json().catch(() => ({})) as { order_id?: string };
    if (!order_id) return jsonResponse({ error: 'order_id requerido' }, 400);

    // ── Leer la orden en Conekta ──────────────────────────────────────
    const auth = btoa(`${privateKey}:`);
    const conektaRes = await fetch(`https://api.conekta.io/orders/${order_id}`, {
      method: 'GET',
      headers: {
        'Accept':        'application/vnd.conekta-v2.1.0+json',
        'Authorization': `Basic ${auth}`,
      },
    });
    const order = await conektaRes.json() as any;
    if (!conektaRes.ok) {
      console.error('[get-conekta-reference] Error Conekta:', JSON.stringify(order));
      return jsonResponse({ error: 'No se pudo consultar la orden' }, 502);
    }

    // ── Verificar que la orden pertenece al cliente autenticado ───────
    const reservationId = order?.metadata?.reservation_id ?? null;
    if (!reservationId) return jsonResponse({ error: 'Orden sin reserva asociada' }, 404);
    const { data: res } = await admin
      .from('reservations')
      .select('id, client_id')
      .eq('id', reservationId)
      .single();
    if (!res || res.client_id !== user.id) return jsonResponse({ error: 'Sin permiso' }, 403);

    // ── Extraer los datos del cargo pendiente ─────────────────────────
    const charge = order?.charges?.data?.[0] ?? null;
    const pm     = charge?.payment_method ?? null;

    return jsonResponse({
      ok:           true,
      order_status: order?.payment_status ?? null,   // 'pending_payment' | 'paid' | ...
      method_type:  pm?.type ?? null,                // 'spei' | 'cash' | 'oxxo' | ...
      // SPEI
      clabe:        pm?.clabe ?? pm?.receiving_account_number ?? null,
      bank:         pm?.bank ?? pm?.receiving_account_bank ?? null,
      // Efectivo (OXXO / paycash)
      reference:    pm?.reference ?? null,
      barcode_url:  pm?.barcode_url ?? null,
      store_name:   pm?.store_name ?? null,
      // Comunes
      amount:       typeof charge?.amount === 'number' ? charge.amount / 100 : null, // MXN
      expires_at:   pm?.expires_at ?? charge?.expires_at ?? null,                    // unix seconds
    });
  } catch (err: any) {
    console.error('[get-conekta-reference] Error:', err);
    return jsonResponse({ error: err.message ?? 'Error interno' }, 500);
  }
});
