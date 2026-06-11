// ═══════════════════════════════════════════════════════════════════
// release-deposit-payout  –  Supabase Edge Function
// Transfiere el primer 50% de las ganancias al grupo (y al referidor
// si aplica) cuando el evento se marca como INICIADO.
// Solo el dueño del grupo puede llamarlo.
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

function jsonResponse(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}

async function stripeTransfer(
  stripeKey: string,
  amountCentavos: number,
  destination: string,
  transferGroup: string,
  type: string,
): Promise<{ id: string } | null> {
  if (amountCentavos < 100) {
    console.warn(`[release-deposit-payout] Monto < 100 centavos para ${type}, omitiendo`);
    return null;
  }

  const body = new URLSearchParams({
    amount:            String(amountCentavos),
    currency:          'mxn',
    destination:       destination,
    transfer_group:    transferGroup,
    'metadata[type]':  type,
  });

  const res = await fetch('https://api.stripe.com/v1/transfers', {
    method: 'POST',
    headers: {
      Authorization:  `Bearer ${stripeKey}`,
      'Content-Type': 'application/x-www-form-urlencoded',
    },
    body,
  });

  const data = await res.json();

  if (!res.ok) {
    console.error(`[release-deposit-payout] Error transfer ${type}:`, JSON.stringify(data));
    return null;
  }

  console.log(`[release-deposit-payout] Transfer ${type}: ${data.id} | ${amountCentavos} centavos → ${destination}`);
  return data;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });

  try {
    // ── Autenticar ──────────────────────────────────────────────────
    const authHeader = req.headers.get('Authorization') ?? '';
    const jwt = authHeader.replace('Bearer ', '').trim();
    if (!jwt) return jsonResponse({ error: 'No autorizado' }, 401);

    const { data: { user }, error: authErr } = await supabase.auth.getUser(jwt);
    if (authErr || !user) return jsonResponse({ error: 'No autorizado' }, 401);

    // ── Leer body ───────────────────────────────────────────────────
    const { reservation_id } = await req.json();
    if (!reservation_id) return jsonResponse({ error: 'reservation_id es requerido' }, 400);

    // ── Leer la reserva con datos del grupo ─────────────────────────
    const { data: res, error: resErr } = await supabase
      .from('reservations')
      .select(`
        id, group_id, group_earnings, status, deposit_transfer_id,
        group:groups (
          id, owner_id, name,
          stripe_account_id, stripe_onboarding_completed
        )
      `)
      .eq('id', reservation_id)
      .single();

    if (resErr || !res) return jsonResponse({ error: 'Reserva no encontrada' }, 404);

    const group = res.group as any;

    // Solo el dueño del grupo puede liberar el pago
    if (group?.owner_id !== user.id) return jsonResponse({ error: 'Sin permiso' }, 403);

    // El evento debe estar en curso
    if (res.status !== 'in_progress') {
      return jsonResponse({ error: 'El evento debe estar en curso para liberar el pago' }, 400);
    }

    // Idempotente: si ya se hizo la primera transferencia, devolver OK
    if (res.deposit_transfer_id) {
      return jsonResponse({
        success:     true,
        already_paid: true,
        transfer_id: res.deposit_transfer_id,
        message:     'El anticipo ya fue transferido.',
      });
    }

    // Verificar que el grupo tiene cuenta Stripe conectada y completada
    if (!group?.stripe_account_id) {
      return jsonResponse({
        success: false,
        reason:  'no_stripe_account',
        message: 'El grupo no tiene una cuenta Stripe Connect. Conecta tu cuenta primero.',
      });
    }

    if (!group?.stripe_onboarding_completed) {
      return jsonResponse({
        success: false,
        reason:  'onboarding_incomplete',
        message: 'El onboarding de Stripe no está completo. Completa la verificación primero.',
      });
    }

    const stripeKey = Deno.env.get('STRIPE_SECRET_KEY');
    if (!stripeKey) return jsonResponse({ error: 'STRIPE_SECRET_KEY no configurado' }, 500);

    // ── Calcular montos ─────────────────────────────────────────────
    // El referido se paga al final (charge-remaining), no en el anticipo.
    const groupEarnings = res.group_earnings ?? 0;
    const firstHalf     = groupEarnings * 0.5;
    const groupNet      = firstHalf;

    console.log(`[release-deposit-payout] Reserva ${reservation_id}: ganancias=${groupEarnings} | primera_mitad=${firstHalf} | grupo_neto=${groupNet}`);

    // ── Transfer al grupo ───────────────────────────────────────────
    const groupTransfer = await stripeTransfer(
      stripeKey,
      Math.round(groupNet * 100),
      group.stripe_account_id,
      reservation_id,
      'deposit_group',
    );

    if (!groupTransfer) {
      return jsonResponse({
        success: false,
        reason:  'transfer_failed',
        message: 'Error al transferir al grupo. Intenta de nuevo.',
      });
    }

    // ── Actualizar reserva ──────────────────────────────────────────
    await supabase
      .from('reservations')
      .update({ deposit_transfer_id: groupTransfer.id })
      .eq('id', reservation_id);

    // ── Notificar al dueño del grupo ────────────────────────────────
    await supabase.from('notifications').insert([{
      user_id: user.id,
      type:    'deposit_received',
      title:   '💰 ¡Anticipo liberado!',
      body:    `Se transfirió el 50% de tus ganancias del evento en curso. $${groupNet.toFixed(2)} MXN`,
      data:    { reservation_id },
    }]);

    return jsonResponse({
      success:     true,
      transfer_id: groupTransfer.id,
      group_net:   groupNet,
    });

  } catch (err: any) {
    console.error('[release-deposit-payout] Error interno:', err);
    return jsonResponse({ error: err.message ?? 'Error interno' }, 500);
  }
});
