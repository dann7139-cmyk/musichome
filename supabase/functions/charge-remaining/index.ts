// ═══════════════════════════════════════════════════════════════════
// charge-remaining  –  Supabase Edge Function (Stripe)
// MODELO A: cobra el 50% restante (off_session) y distribuye el 100%
// de group_earnings entre todos al finalizar el evento.
// release-deposit-payout ya NO se usa (no hay pago parcial al inicio).
//   • Dueño del grupo  → group_earnings - miembros - talentos invitados
//   • Integrantes permanentes → proposed_payment_amount (event_id IS NULL)
//   • Talentos invitados al evento → proposed_payment_amount (event_id match)
//   • Referido (si existe) → $50/hora = commission_amount × 0.25
// Requiere: STRIPE_SECRET_KEY en Supabase Secrets
// ═══════════════════════════════════════════════════════════════════

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const supabase = createClient(
  Deno.env.get('SUPABASE_URL')!,
  Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  { auth: { persistSession: false, autoRefreshToken: false } },
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

async function stripeTransfer(
  stripeKey: string,
  amountCentavos: number,
  destination: string,
  transferGroup: string,
  type: string,
): Promise<{ id: string } | null> {
  if (amountCentavos < 100) return null;
  if (!destination) return null;

  const res = await fetch('https://api.stripe.com/v1/transfers', {
    method: 'POST',
    headers: {
      Authorization:  `Bearer ${stripeKey}`,
      'Content-Type': 'application/x-www-form-urlencoded',
    },
    body: new URLSearchParams({
      amount:           String(amountCentavos),
      currency:         'mxn',
      destination,
      transfer_group:   transferGroup,
      'metadata[type]': type,
    }),
  });

  const data = await res.json();
  if (!res.ok) {
    console.error(`[charge-remaining] Error transfer ${type}:`, JSON.stringify(data));
    return null;
  }
  console.log(`[charge-remaining] Transfer ${type}: ${data.id} | ${amountCentavos} centavos → ${destination}`);
  return data;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });

  try {
    // ── Autenticar: solo el dueño del grupo puede llamar esto ───────
    const authHeader = req.headers.get('Authorization') ?? '';
    const jwt = authHeader.replace('Bearer ', '').trim();
    if (!jwt) return jsonResponse({ error: 'No autorizado' }, 401);

    const { data: { user }, error: authErr } = await supabase.auth.getUser(jwt);
    if (authErr || !user) return jsonResponse({ error: 'No autorizado' }, 401);

    const { reservation_id } = await req.json();
    if (!reservation_id) return jsonResponse({ error: 'reservation_id es requerido' }, 400);

    // ── Leer la reserva ─────────────────────────────────────────────
    const { data: res, error: resErr } = await supabase
      .from('reservations')
      .select(`
        id, group_id, event_id,
        total_price, group_earnings, commission_amount,
        client_id, status, payment_status,
        stripe_payment_method_id, payout_completed, final_transfer_id,
        group:groups(
          id, name, owner_id,
          stripe_account_id, stripe_onboarding_completed,
          referred_by_user_id
        )
      `)
      .eq('id', reservation_id)
      .single();

    if (resErr || !res) return jsonResponse({ error: 'Reserva no encontrada' }, 404);

    const group        = res.group as any;
    const groupOwnerId = group?.owner_id;
    if (groupOwnerId !== user.id) return jsonResponse({ error: 'Sin permiso' }, 403);

    if (res.status !== 'in_progress') {
      return jsonResponse({ error: 'El evento debe estar en curso para cobrar el saldo' }, 400);
    }
    if (res.payment_status === 'fully_paid') {
      return jsonResponse({ error: 'Este evento ya fue pagado completamente' }, 400);
    }

    const stripeKey = Deno.env.get('STRIPE_SECRET_KEY');
    if (!stripeKey) return jsonResponse({ error: 'STRIPE_SECRET_KEY no configurado' }, 500);

    // ── Obtener Stripe Customer del cliente ─────────────────────────
    const { data: clientProfile } = await supabase
      .from('profiles')
      .select('stripe_customer_id')
      .eq('id', res.client_id)
      .single();

    const stripeCustomerId    = clientProfile?.stripe_customer_id ?? null;
    const stripePaymentMethod = res.stripe_payment_method_id ?? null;
    const groupName           = group?.name ?? 'Grupo musical';

    if (!stripeCustomerId || !stripePaymentMethod) {
      await supabase.from('notifications').insert([{
        user_id: res.client_id,
        type:    'payment',
        title:   '💳 Pago pendiente del evento',
        body:    `Tu evento con ${groupName} finalizó. Por favor paga el saldo restante.`,
        data:    { reservation_id },
      }]);
      await supabase.from('reservations').update({
        status:                    'completed',
        client_confirmed_complete: true,
        payment_status:            'remaining_pending',
        event_ended_at:            new Date().toISOString(),
      }).eq('id', reservation_id);

      return jsonResponse({
        success: false,
        reason:  'no_payment_method',
        message: 'El cliente no tiene tarjeta guardada. Se le envió una notificación.',
      });
    }

    // ── Calcular monto restante del cliente ─────────────────────────
    const totalPrice        = res.total_price ?? 0;
    const remainingAmount   = totalPrice - Math.round((totalPrice * 50) / 100);
    const remainingCentavos = Math.max(remainingAmount * 100, 1000);

    // ── Cobrar off-session ──────────────────────────────────────────
    const piBody = new URLSearchParams({
      amount:                     String(remainingCentavos),
      currency:                   'mxn',
      customer:                   stripeCustomerId,
      payment_method:             stripePaymentMethod,
      confirm:                    'true',
      off_session:                'true',
      description:                `Saldo 50% restante – ${groupName}`,
      'metadata[reservation_id]': reservation_id,
      'metadata[client_id]':      String(res.client_id),
      'metadata[charge_type]':    'remaining_50',
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

    if (!stripeRes.ok || stripeData?.status === 'requires_action' || stripeData?.status === 'requires_payment_method') {
      const stripeError = stripeData?.error?.message ?? `Pago requiere acción adicional (${stripeData?.status ?? 'error'})`;
      console.error('[charge-remaining] Error Stripe:', JSON.stringify(stripeData));

      await supabase.from('notifications').insert([{
        user_id: res.client_id,
        type:    'payment',
        title:   '⚠️ Pago fallido – Acción requerida',
        body:    `No pudimos cobrar el saldo restante de tu evento con ${groupName}. Actualiza tu método de pago.`,
        data:    { reservation_id },
      }]);
      await supabase.from('reservations').update({
        status:                    'completed',
        client_confirmed_complete: true,
        payment_status:            'remaining_pending',
        event_ended_at:            new Date().toISOString(),
      }).eq('id', reservation_id);

      return jsonResponse({ success: false, reason: 'charge_failed', message: stripeError });
    }

    if (stripeData?.status !== 'succeeded') {
      console.warn(`[charge-remaining] PI ${stripeData?.id} en estado inesperado: ${stripeData?.status}`);
      return jsonResponse({ success: false, reason: 'unexpected_status', message: `Estado del pago: ${stripeData?.status}` });
    }

    console.log(`[charge-remaining] PI ${stripeData.id} | ${remainingCentavos} centavos`);

    // ── Campos base para actualizar la reserva ──────────────────────
    const reservationUpdate: Record<string, unknown> = {
      status:                    'completed',
      client_confirmed_complete: true,
      payment_status:            'fully_paid',
      event_ended_at:            new Date().toISOString(),
    };

    // ── DISTRIBUCIÓN DE PAGOS (idempotente) ─────────────────────────
    if (!res.payout_completed && group?.stripe_account_id && group?.stripe_onboarding_completed) {

      const groupEarnings    = res.group_earnings    ?? 0;
      const commissionAmount = res.commission_amount ?? 0;
      // Modelo A: el 100% de group_earnings se distribuye al finalizar.
      // release-deposit-payout NO se invoca al inicio del evento.

      // ─ 1. Cargar integrantes permanentes del grupo ─────────────────
      const { data: memberRows } = await supabase
        .from('job_invitations')
        .select(`
          invited_user_id, proposed_payment_amount,
          invited_user:profiles(stripe_account_id, stripe_onboarding_completed, full_name)
        `)
        .eq('group_id', res.group_id)
        .is('event_id', null)
        .eq('status', 'accepted');

      // ─ 2. Cargar talentos invitados al evento ──────────────────────
      const { data: talentRows } = res.event_id
        ? await supabase
            .from('job_invitations')
            .select(`
              invited_user_id, proposed_payment_amount,
              invited_user:profiles(stripe_account_id, stripe_onboarding_completed, full_name)
            `)
            .eq('group_id', res.group_id)
            .eq('event_id', res.event_id)
            .eq('status', 'accepted')
        : { data: [] as any[] };

      // ─ 3. Calcular cuánto se distribuye entre integrantes y talentos
      const memberTotal = (memberRows ?? []).reduce((s: number, r: any) => s + (r.proposed_payment_amount ?? 0), 0);
      const talentTotal = (talentRows ?? []).reduce((s: number, r: any) => s + (r.proposed_payment_amount ?? 0), 0);

      // ─ 4. Dueño recibe el resto de group_earnings (100% Modelo A) ──
      const ownerNet = Math.max(groupEarnings - memberTotal - talentTotal, 0);

      // ─ 5. Referido: $50/hora = comisión × 0.25  (sale de la comisión, no de group_earnings)
      // Bloquear auto-referido: el referidor no puede ser el mismo que el dueño del grupo
      const selfReferral = group.referred_by_user_id === groupOwnerId;
      const referralAmount = (commissionAmount > 0 && group.referred_by_user_id && !selfReferral)
        ? (commissionAmount / 200) * 50
        : 0;
      if (selfReferral && group.referred_by_user_id) {
        console.warn(`[charge-remaining] Auto-referido bloqueado para grupo ${group.id}`);
      }

      console.log(
        `[charge-remaining] Reserva ${reservation_id}:\n` +
        `  group_earnings=${groupEarnings} (100% – Modelo A)\n` +
        `  members=${memberTotal} | talents=${talentTotal} | owner_net=${ownerNet}\n` +
        `  commission=${commissionAmount} | referral=${referralAmount}`
      );

      // ─ 6. Transfer al dueño del grupo ─────────────────────────────
      const ownerTransfer = await stripeTransfer(
        stripeKey,
        Math.round(ownerNet * 100),
        group.stripe_account_id,
        reservation_id,
        'final_group',
      );
      if (ownerTransfer) {
        reservationUpdate.final_transfer_id = ownerTransfer.id;
        reservationUpdate.payout_completed  = true;
      }
      await supabase.from('connected_payouts').insert({
        user_id:            group.owner_id,
        reservation_id,
        stripe_transfer_id: ownerTransfer?.id ?? null,
        amount:             ownerNet,
        payout_type:        'final_group',
        status:             ownerTransfer ? 'completed' : 'failed',
      });

      // ─ 7. Transfer a integrantes permanentes ──────────────────────
      for (const inv of (memberRows ?? [])) {
        const m   = inv.invited_user as any;
        const amt = inv.proposed_payment_amount ?? 0;
        if (!m?.stripe_account_id || !m?.stripe_onboarding_completed || amt < 1) continue;

        const tf = await stripeTransfer(
          stripeKey, Math.round(amt * 100),
          m.stripe_account_id, reservation_id, 'member',
        );
        await supabase.from('connected_payouts').insert({
          user_id:            inv.invited_user_id,
          reservation_id,
          stripe_transfer_id: tf?.id ?? null,
          amount:             amt,
          payout_type:        'member',
          status:             tf ? 'completed' : 'failed',
        });
        if (tf) console.log(`[charge-remaining] Integrante ${m.full_name}: $${amt} MXN → ${tf.id}`);
      }

      // ─ 8. Transfer a talentos invitados al evento ──────────────────
      for (const inv of (talentRows ?? [])) {
        const t   = inv.invited_user as any;
        const amt = inv.proposed_payment_amount ?? 0;
        if (!t?.stripe_account_id || !t?.stripe_onboarding_completed || amt < 1) continue;

        const tf = await stripeTransfer(
          stripeKey, Math.round(amt * 100),
          t.stripe_account_id, reservation_id, 'talent_invited',
        );
        await supabase.from('connected_payouts').insert({
          user_id:            inv.invited_user_id,
          reservation_id,
          stripe_transfer_id: tf?.id ?? null,
          amount:             amt,
          payout_type:        'talent_invited',
          status:             tf ? 'completed' : 'failed',
        });
        if (tf) console.log(`[charge-remaining] Talento ${t.full_name}: $${amt} MXN → ${tf.id}`);
      }

      // ─ 9. Transfer al referido ($50/hora, sale de la comisión) ─────
      if (referralAmount >= 1) {
        const { data: referrer } = await supabase
          .from('profiles')
          .select('stripe_account_id, stripe_onboarding_completed, full_name')
          .eq('id', group.referred_by_user_id)
          .single();

        if (referrer?.stripe_account_id && referrer?.stripe_onboarding_completed) {
          const refTf = await stripeTransfer(
            stripeKey, Math.round(referralAmount * 100),
            referrer.stripe_account_id, reservation_id, 'final_referral',
          );
          await supabase.from('connected_payouts').insert({
            user_id:            group.referred_by_user_id,
            reservation_id,
            stripe_transfer_id: refTf?.id ?? null,
            amount:             referralAmount,
            payout_type:        'final_referral',
            status:             refTf ? 'completed' : 'failed',
          });
          if (refTf) console.log(`[charge-remaining] Referido ${referrer.full_name}: $${referralAmount} MXN → ${refTf.id}`);
        } else {
          console.warn(`[charge-remaining] Referido sin cuenta Stripe activa, omitiendo`);
        }
      }

    } else if (res.payout_completed) {
      console.log(`[charge-remaining] Payouts ya completados para reserva ${reservation_id}`);
    } else {
      console.warn(`[charge-remaining] Grupo sin Stripe Connect activo, payout omitido para ${reservation_id}`);
    }

    // ── Guardar actualización de la reserva ─────────────────────────
    await supabase.from('reservations').update(reservationUpdate).eq('id', reservation_id);

    // ── Notificaciones ──────────────────────────────────────────────
    await supabase.from('notifications').insert([
      {
        user_id: res.client_id,
        type:    'payment_released',
        title:   '✅ Pago completado',
        body:    `Se cobró el saldo restante de tu evento con ${groupName}. ¡Gracias!`,
        data:    { reservation_id },
      },
      {
        user_id: groupOwnerId,
        type:    'deposit_received',
        title:   '💰 Pago final recibido',
        body:    `El saldo restante fue cobrado y transferido a tu cuenta bancaria.`,
        data:    { reservation_id },
      },
    ]);

    return jsonResponse({ success: true, payment_intent_id: stripeData.id });

  } catch (err: any) {
    console.error('[charge-remaining] Error interno:', err);
    return jsonResponse({ error: err.message ?? 'Error interno' }, 500);
  }
});
