// ═══════════════════════════════════════════════════════════════════
// stripe-webhook  –  Supabase Edge Function
// Requiere: STRIPE_SECRET_KEY, STRIPE_WEBHOOK_SECRET en Supabase Secrets
// ═══════════════════════════════════════════════════════════════════

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import Stripe from 'https://esm.sh/stripe@14?target=deno&no-check=1';

const supabase = createClient(
  Deno.env.get('SUPABASE_URL')!,
  Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
);

Deno.serve(async (req) => {
  const sigHeader     = req.headers.get('stripe-signature') ?? '';
  const webhookSecret = Deno.env.get('STRIPE_WEBHOOK_SECRET') ?? '';
  const stripeKey     = Deno.env.get('STRIPE_SECRET_KEY') ?? '';
  const body          = await req.text();

  if (!stripeKey) {
    console.error('[Stripe Webhook] STRIPE_SECRET_KEY no configurado');
    return new Response('Internal Error', { status: 500 });
  }

  const stripe = new Stripe(stripeKey, {
    apiVersion: '2023-10-16',
    httpClient: Stripe.createFetchHttpClient(),
  });

  // ── Verificar firma ──────────────────────────────────────────────
  let event: Stripe.Event;
  try {
    event = await stripe.webhooks.constructEventAsync(body, sigHeader, webhookSecret);
  } catch (err: any) {
    console.error('[Stripe Webhook] Firma inválida:', err.message);
    return new Response('Unauthorized', { status: 401 });
  }

  console.log(`[Stripe Webhook] Evento: ${event.type}`);

  // ── account.updated ─────────────────────────────────────────────
  // Dispara cada vez que Stripe modifica cualquier campo de la cuenta.
  // SIEMPRE evalúa el estado actual completo (no asumas "completado" por recibir el evento).
  if (event.type === 'account.updated') {
    const acct = event.data.object as Stripe.Account;

    // Misma lógica de producción que verify-stripe-account
    const currentlyDue: string[] = (acct as any).requirements?.currently_due ?? [];
    const pastDue:      string[] = (acct as any).requirements?.past_due        ?? [];

    const detailsSubmitted = !!acct.details_submitted;
    const noBlockingReqs   = currentlyDue.length === 0 && pastDue.length === 0;
    const onboardingDone   = detailsSubmitted && noBlockingReqs;
    const payoutsReady     = !!(acct.charges_enabled && acct.payouts_enabled);

    console.log(
      `[account.updated] ${acct.id}: ` +
      `details_submitted=${detailsSubmitted} ` +
      `currently_due=${currentlyDue.length} payouts=${acct.payouts_enabled}`,
    );

    if (onboardingDone) {
      // Actualizar grupos
      await supabase
        .from('groups')
        .update({ stripe_onboarding_completed: true })
        .eq('stripe_account_id', acct.id);

      // Actualizar perfiles individuales
      const profileUpdate: Record<string, unknown> = { stripe_onboarding_completed: true };
      if (payoutsReady) profileUpdate.stripe_payouts_enabled = true;

      const { error: profErr } = await supabase
        .from('profiles')
        .update(profileUpdate)
        .eq('stripe_account_id', acct.id);

      if (profErr) {
        // Fallback si stripe_payouts_enabled no existe aún (SQL 47 no ejecutado)
        await supabase
          .from('profiles')
          .update({ stripe_onboarding_completed: true })
          .eq('stripe_account_id', acct.id);
      }
    } else if (payoutsReady && detailsSubmitted) {
      // Stripe aprobó payouts pero aún hay documentos en revisión (pending_verification).
      // Solo actualizar stripe_payouts_enabled.
      await supabase
        .from('profiles')
        .update({ stripe_payouts_enabled: true })
        .eq('stripe_account_id', acct.id);
    }

    return new Response('OK', { status: 200 });
  }

  // ── account.application.authorized ──────────────────────────────
  // Fired when a connected account authorizes your platform.
  // No necesita acción DB — la cuenta ya existe en nuestro sistema.
  // Útil para logging / auditoría.
  if (event.type === 'account.application.authorized') {
    const acct = event.data.object as any;
    console.log(`[account.application.authorized] Cuenta ${acct.id} autorizó la plataforma.`);
    return new Response('OK', { status: 200 });
  }

  // ── payment_intent.succeeded ────────────────────────────────────
  if (event.type === 'payment_intent.succeeded') {
    const pi = event.data.object as Stripe.PaymentIntent;

    // ── ¿Es pago de recomendación? ────────────────────────────────
    const recOrderId = pi.metadata?.rec_order_id;
    if (recOrderId) {
      console.log(`[Stripe Webhook] Recomendación confirmada: order_id=${recOrderId}`);

      const { error: recErr } = await supabase.rpc('confirm_recommendation_payment', {
        p_order_id:      recOrderId,
        p_mp_payment_id: pi.id,   // guardamos el Stripe PI id como referencia
      });

      if (recErr) {
        console.error('[Stripe Webhook] Error confirm_recommendation_payment:', recErr.message);
        return new Response('DB Error', { status: 500 });
      }

      console.log(`[Stripe Webhook] Recomendación activada: order_id=${recOrderId}`);
      return new Response('OK', { status: 200 });
    }

    // ── ¿Es pago de bidding? ─────────────────────────────────────
    const bidOrderId = pi.metadata?.bid_order_id;
    if (bidOrderId) {
      console.log(`[Stripe Webhook] Bid confirmado: order_id=${bidOrderId}`);

      const { error: bidErr } = await supabase.rpc('confirm_bid_payment', {
        p_order_id:      bidOrderId,
        p_mp_payment_id: pi.id,
      });

      if (bidErr) {
        console.error('[Stripe Webhook] Error confirm_bid_payment:', bidErr.message);
        return new Response('DB Error', { status: 500 });
      }

      console.log(`[Stripe Webhook] Bid activado: order_id=${bidOrderId}`);
      return new Response('OK', { status: 200 });
    }

    // ── ¿Es pago de anuncio? ──────────────────────────────────────
    const adId = pi.metadata?.ad_id;
    if (adId) {
      console.log(`[Stripe Webhook] Anuncio confirmado: ad_id=${adId}`);

      await supabase.rpc('mark_ad_payment', {
        p_ad_id:         adId,
        p_mp_payment_id: pi.id,
      });

      return new Response('OK', { status: 200 });
    }

    // ── ¿Es pago de reserva? ──────────────────────────────────────
    const reservationId = pi.metadata?.reservation_id;

    if (!reservationId) {
      console.error('[Stripe Webhook] Sin metadata reconocida en payment_intent:', pi.id);
      return new Response('OK', { status: 200 });
    }

    const paymentMethodId = typeof pi.payment_method === 'string'
      ? pi.payment_method
      : (pi.payment_method as any)?.id ?? null;

    const { error } = await supabase
      .from('reservations')
      .update({
        status:                   'confirmed',
        payment_status:           'deposit_paid',
        payment_intent_id:        pi.id,
        stripe_payment_method_id: paymentMethodId,
      })
      .eq('id', reservationId)
      .not('status', 'in', '("cancelled","rejected","expired","completed")');

    if (error) {
      console.error('[Stripe Webhook] Error actualizando reserva:', error.message);
      return new Response('DB Error', { status: 500 });
    }

    console.log(`[Stripe Webhook] Reserva ${reservationId} → confirmed | pm=${paymentMethodId}`);

    // ── Notificar al grupo que el anticipo fue pagado ─────────────────
    try {
      const { data: res2 } = await supabase
        .from('reservations')
        .select('group_id, event_date, groups(owner_id)')
        .eq('id', reservationId)
        .single();

      const groupId = res2?.group_id;
      const ownerId = (res2?.groups as any)?.owner_id;
      const amount  = pi.amount / 100;

      if (groupId && ownerId) {
        const notifBody = `El cliente pagó el anticipo de $${amount.toLocaleString('es-MX')} MXN. Ya pueden confirmar el evento.`;
        const notifData = { reservation_id: reservationId };

        const notifications: any[] = [
          { user_id: ownerId, type: 'deposit_paid', title: '💰 Anticipo recibido', body: notifBody, data: notifData },
        ];

        const { data: members } = await supabase
          .from('job_invitations')
          .select('invited_user_id')
          .eq('group_id', groupId)
          .in('invitation_type', ['membership', 'job'])
          .eq('status', 'accepted');

        (members ?? []).forEach((m: any) => {
          notifications.push({ user_id: m.invited_user_id, type: 'deposit_paid', title: '💰 Anticipo recibido', body: notifBody, data: notifData });
        });

        await supabase.from('notifications').insert(notifications);
        console.log(`[Stripe Webhook] Notificados ${notifications.length} miembros del grupo ${groupId}`);
      }
    } catch (notifErr: any) {
      // No-fatal: el pago ya se confirmó, la notificación es best-effort
      console.error('[Stripe Webhook] Error enviando notificación:', notifErr.message);
    }
  }

  return new Response('OK', { status: 200 });
});
