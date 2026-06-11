// ═══════════════════════════════════════════════════════════════════
// process-refund  –  Supabase Edge Function
// Emite un reembolso real via MercadoPago y revierte el wallet del grupo.
//
// POST (autenticado como admin o cliente dueño pre-evento):
//   { reservation_id: string, refund_amount?: number }
//
// Respuesta:
//   { ok, refund_id, amount, reservation_id }
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

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });

  const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? '';
  const SERVICE_KEY  = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
  const mpToken      = Deno.env.get('MERCADOPAGO_ACCESS_TOKEN')
    ?? Deno.env.get('mercadopago_access_token')
    ?? '';

  // admin client (service_role) — used for DB operations and JWT verification
  const admin = createClient(SUPABASE_URL, SERVICE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const serviceHeaders: Record<string, string> = {
    Authorization:  `Bearer ${SERVICE_KEY}`,
    apikey:         SERVICE_KEY,
    'Content-Type': 'application/json',
    Prefer:         'return=representation',
  };

  try {
    // ── Autenticar (verificación criptográfica via Supabase Auth) ─────
    const authHeader = req.headers.get('Authorization');
    if (!authHeader?.startsWith('Bearer ')) {
      return jsonRes({ error: 'No autorizado' }, 401);
    }
    const token = authHeader.slice(7);

    // getUser() verifica firma, expiración y que el usuario exista en auth.users
    const { data: authData, error: authErr } = await admin.auth.getUser(token);
    if (authErr || !authData?.user) {
      console.warn('[process-refund] JWT rejected:', authErr?.message ?? 'no user');
      return jsonRes({ error: 'Token inválido o expirado' }, 401);
    }
    const callerId = authData.user.id;

    // ── Body ──────────────────────────────────────────────────────────
    const body = await req.json().catch(() => ({})) as {
      reservation_id?: string;
      refund_amount?:  number;
    };
    const { reservation_id, refund_amount } = body;
    if (!reservation_id) return jsonRes({ error: 'reservation_id requerido' }, 400);

    // ── Cargar reserva ────────────────────────────────────────────────
    const { data: reservation, error: resErr } = await admin
      .from('reservations')
      .select('id,total_price,base_price,client_id,payment_status,payout_status,mp_payment_id,event_date,group_id')
      .eq('id', reservation_id)
      .single();

    if (resErr || !reservation) return jsonRes({ error: 'Reserva no encontrada' }, 404);

    // ── Permisos ──────────────────────────────────────────────────────
    const { data: callerProfile } = await admin
      .from('profiles')
      .select('role')
      .eq('id', callerId)
      .single();

    const isAdmin  = callerProfile?.role === 'admin';
    const isClient = (reservation.client_id as string) === callerId;
    const isPre    = new Date(reservation.event_date as string) > new Date();

    if (!isAdmin && !(isClient && isPre)) {
      return jsonRes({ error: 'Sin permiso para emitir reembolso' }, 403);
    }

    // ── Validaciones ──────────────────────────────────────────────────
    if (!reservation.mp_payment_id) {
      return jsonRes({ error: 'No hay pago de MP registrado para esta reserva' }, 422);
    }

    if (!['paid', 'fully_paid', 'deposit_paid'].includes(reservation.payment_status as string)) {
      return jsonRes({ error: 'La reserva no tiene un pago confirmado' }, 422);
    }

    if (reservation.payout_status === 'refunded') {
      return jsonRes({ error: 'Esta reserva ya fue reembolsada' }, 422);
    }

    if (reservation.payout_status === 'released') {
      return jsonRes({ error: 'No se puede reembolsar: el pago ya fue liberado al grupo' }, 422);
    }

    const totalPrice  = reservation.total_price as number;
    const amountToRef = refund_amount ?? totalPrice;

    if (amountToRef <= 0) {
      return jsonRes({ error: 'El monto del reembolso debe ser mayor a $0' }, 422);
    }
    if (amountToRef > totalPrice) {
      return jsonRes({ error: `El reembolso ($${amountToRef}) excede el total ($${totalPrice})` }, 422);
    }

    // ── Llamar a MP Refunds API ───────────────────────────────────────
    console.log(`[REFUND_INIT] reservation=${reservation_id} mp_payment=${reservation.mp_payment_id} amount=$${amountToRef} by=${isAdmin ? 'admin' : 'client'}`);

    const mpRefundRes = await fetch(
      `https://api.mercadopago.com/v1/payments/${reservation.mp_payment_id}/refunds`,
      {
        method:  'POST',
        headers: {
          Authorization:  `Bearer ${mpToken}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({ amount: amountToRef }),
      },
    );

    const mpRefund = await mpRefundRes.json() as any;

    if (!mpRefundRes.ok) {
      console.error('[REFUND_ERROR] MP refund failed:', JSON.stringify(mpRefund));
      return jsonRes({
        error: mpRefund?.message ?? 'Error al procesar reembolso en MercadoPago',
      }, 502);
    }

    console.log(`[REFUND_ISSUED] mp_refund_id=${mpRefund.id} reservation=${reservation_id} amount=$${amountToRef}`);

    // ── Revertir wallet + marcar reserva (atómico via RPC) ───────────
    // p_refund_amount pasa el monto real para revertir solo lo reembolsado,
    // no siempre el base_price completo (fix para reembolsos parciales).
    const rpcRes = await fetch(`${SUPABASE_URL}/rest/v1/rpc/process_refund_reversal`, {
      method:  'POST',
      headers: serviceHeaders,
      body:    JSON.stringify({
        p_reservation_id: reservation_id,
        p_mp_refund_id:   String(mpRefund.id),
        p_refund_amount:  amountToRef,
      }),
    });
    const rpcResult = await rpcRes.json() as any;
    console.log('[process_refund_reversal]', JSON.stringify(rpcResult));

    // ── Audit log ─────────────────────────────────────────────────────
    fetch(`${SUPABASE_URL}/rest/v1/rpc/log_payment_event`, {
      method:  'POST',
      headers: serviceHeaders,
      body:    JSON.stringify({
        p_mp_payment_id:  reservation.mp_payment_id,
        p_external_ref:   reservation_id,
        p_reservation_id: reservation_id,
        p_mp_status:      'refunded',
        p_mp_amount:      amountToRef,
        p_event_type:     'refund_issued',
        p_notes:          `Refund MP:${mpRefund.id} by ${isAdmin ? 'admin' : 'client'}(${callerId})`,
      }),
    }).catch((e: unknown) => console.error('[log_payment_event]', e));

    // ── Notificar al cliente ──────────────────────────────────────────
    await admin.from('notifications').insert({
      user_id: reservation.client_id,
      type:    'payment',
      title:   '💸 Reembolso emitido',
      body:    `Se emitió un reembolso de $${Number(amountToRef).toLocaleString('es-MX')} MXN. Aparecerá en tu cuenta en 3-10 días hábiles.`,
      data:    { reservation_id, screen: 'Reservations' },
    });

    return jsonRes({
      ok:            true,
      refund_id:     mpRefund.id,
      amount:        amountToRef,
      reservation_id,
    });

  } catch (e: unknown) {
    const msg = e instanceof Error ? e.message : 'Error interno';
    console.error('[process-refund] Error:', msg);
    return jsonRes({ error: msg }, 500);
  }
});
