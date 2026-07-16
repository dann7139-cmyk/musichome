// ═══════════════════════════════════════════════════════════════════
// stripe-webhook  –  Supabase Edge Function
// Requiere: STRIPE_SECRET_KEY, STRIPE_WEBHOOK_SECRET en Supabase Secrets
// ═══════════════════════════════════════════════════════════════════

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import Stripe from 'https://esm.sh/stripe@13?target=deno&no-check=1';

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
  // Supabase Edge Runtime no soporta Deno.core — usar SubtleCryptoProvider
  // que usa la Web Crypto API nativa del runtime.
  let event: Stripe.Event;
  try {
    event = await stripe.webhooks.constructEventAsync(
      body,
      sigHeader,
      webhookSecret,
      undefined,
      Stripe.createSubtleCryptoProvider(),
    );
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

  // ── Eventos informativos — sin acción requerida ──────────────────
  // charge.succeeded y charge.updated son consecuencias de payment_intent.succeeded;
  // ya los procesamos arriba. Devolver 200 evita el error de event loop.
  if (
    event.type === 'charge.succeeded' ||
    event.type === 'charge.updated'   ||
    event.type === 'charge.captured'
  ) {
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

    // ── ¿Es pago de hora extra? ──────────────────────────────────
    const extraHourId = pi.metadata?.extra_hour_id;
    if (extraHourId) {
      let stripeFee: number | null = null;
      try {
        const chargeId = typeof pi.latest_charge === 'string'
          ? pi.latest_charge
          : (pi.latest_charge as any)?.id ?? null;
        if (chargeId) {
          const charge = await stripe.charges.retrieve(chargeId, {
            expand: ['balance_transaction'],
          });
          const bt = charge.balance_transaction as any;
          if (bt && typeof bt.fee === 'number') {
            stripeFee = bt.fee / 100;
          }
        }
      } catch (e: any) {
        console.warn('[Webhook] No se pudo obtener stripe fee extra_hour:', e.message);
      }

      const { error: extraErr } = await supabase.rpc(
        'confirm_extra_hour_stripe_payment',
        {
          p_extra_id:          extraHourId,
          p_stripe_payment_id: pi.id,
          p_amount_paid:       pi.amount / 100,
          p_stripe_fee:        stripeFee,
        },
      );

      if (extraErr) {
        console.error('[Webhook] confirm_extra_hour_stripe_payment error:', extraErr.message);
        return new Response('DB Error', { status: 500 });
      }

      console.log(`[Webhook] Extra hour paid: ${extraHourId}`);
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

    // Guardar el payment_method en la reserva
    if (paymentMethodId) {
      await supabase
        .from('reservations')
        .update({ stripe_payment_method_id: paymentMethodId })
        .eq('id', reservationId);
    }

    // ── Obtener el fee real de Stripe desde balance_transaction ──────────────
    // El charge contiene la balance_transaction con el fee exacto cobrado.
    let stripeFeeAmount: number | null = null;
    try {
      const chargeId = typeof pi.latest_charge === 'string'
        ? pi.latest_charge
        : (pi.latest_charge as any)?.id ?? null;

      if (chargeId) {
        const charge = await stripe.charges.retrieve(chargeId, {
          expand: ['balance_transaction'],
        });
        const balanceTx = charge.balance_transaction as any;
        if (balanceTx && typeof balanceTx.fee === 'number') {
          // fee viene en centavos (MXN tiene 2 decimales)
          stripeFeeAmount = balanceTx.fee / 100;
          console.log(`[Stripe Webhook] Fee real Stripe: $${stripeFeeAmount} MXN (charge=${chargeId})`);
        }
      }
    } catch (feeErr: any) {
      console.warn('[Stripe Webhook] No se pudo obtener balance_transaction:', feeErr.message);
    }

    // Llamar al RPC de wallet — acredita pending_balance, sets payout_status='held',
    // guarda mp_payment_id (usamos esa columna para el PI id), marca payment_status='paid'
    const { data: walletResult, error: walletErr } = await supabase.rpc(
      'confirm_full_payment_and_credit_wallet',
      {
        p_reservation_id: reservationId,
        p_mp_payment_id:  pi.id,
        p_amount_paid:    pi.amount / 100,
        p_stripe_fee:     stripeFeeAmount,
      },
    );

    if (walletErr) {
      console.error('[Stripe Webhook] Error confirm_full_payment_and_credit_wallet:', walletErr.message);
      return new Response('DB Error', { status: 500 });
    }

    if (walletResult?.skipped) {
      console.log(`[Stripe Webhook] Reserva ${reservationId} ya procesada (idempotente)`);
      return new Response('OK', { status: 200 });
    }

    // Confirmar la reserva (el RPC solo cambia payment_status, no el status de
    // reserva) + registrar proveedor y método real (Fase 0.3: Stripe no los
    // escribía y los reportes por procesador quedaban ciegos para Stripe).
    // MSI real = installments del PI; tarjeta normal = 'card'.
    const stripeMethod = (pi.payment_method_options as any)?.card?.installments?.plan
      ? 'card_msi' : 'card';
    await supabase
      .from('reservations')
      .update({ status: 'confirmed', payment_provider: 'stripe', payment_method_type: stripeMethod })
      .eq('id', reservationId)
      .not('status', 'in', '("cancelled","rejected","expired","completed")');

    const amount    = pi.amount / 100;
    const eventDate = pi.metadata?.event_date ?? '';
    console.log(`[Stripe Webhook] Reserva ${reservationId} → pagada $${amount} | pm=${paymentMethodId}`);

    // ── Notificar al grupo ────────────────────────────────────────────
    try {
      const { data: res2 } = await supabase
        .from('reservations')
        .select('group_id, event_date, currency_code, groups(owner_id, name)')
        .eq('id', reservationId)
        .single();

      const groupId  = res2?.group_id;
      const ownerId  = (res2?.groups as any)?.owner_id;
      const evDate   = res2?.event_date ?? eventDate;
      const currency = (res2?.currency_code ?? 'MXN') as string;

      if (groupId && ownerId) {
        const amountFmt = amount.toLocaleString('es-MX');
        const currLabel = currency === 'USD' ? 'USD' : 'MXN';
        const notifBody = `El cliente pagó $${amountFmt} ${currLabel} para el evento del ${evDate}. Tu ganancia queda reservada y se libera 12h después del evento.`;
        const notifData = { reservation_id: reservationId, screen: 'GroupReservations' };

        const notifications: any[] = [
          { user_id: ownerId, type: 'payment', title: '✅ Cliente confirmó el pago', body: notifBody, data: notifData },
        ];

        const { data: members } = await supabase
          .from('job_invitations')
          .select('invited_user_id')
          .eq('group_id', groupId)
          .in('invitation_type', ['membership', 'job'])
          .eq('status', 'accepted');

        (members ?? []).forEach((m: any) => {
          notifications.push({ user_id: m.invited_user_id, type: 'payment', title: '✅ Cliente confirmó el pago', body: notifBody, data: notifData });
        });

        await supabase.from('notifications').insert(notifications);
      }
    } catch (notifErr: any) {
      console.error('[Stripe Webhook] Error enviando notificación:', notifErr.message);
    }
  }

  // ── charge.refund.updated ─────────────────────────────────────────
  // Stripe dispara esto cuando un reembolso es procesado.
  if (event.type === 'charge.refund.updated' || event.type === 'charge.refunded') {
    const charge = event.data.object as any;
    const refund  = charge.refunds?.data?.[0] ?? charge; // charge.refund.updated tiene el refund directo

    const piId = charge.payment_intent ?? refund.payment_intent ?? null;
    if (!piId) return new Response('OK', { status: 200 });

    // Buscar la reserva por mp_payment_id (donde guardamos el PI id)
    const { data: res } = await supabase
      .from('reservations')
      .select('id, total_price')
      .eq('mp_payment_id', piId)
      .maybeSingle();

    if (!res) {
      console.log(`[Stripe Webhook] No se encontró reserva para PI ${piId} en refund event`);
      return new Response('OK', { status: 200 });
    }

    const refundAmount = (refund.amount ?? charge.amount_refunded ?? null) != null
      ? (refund.amount ?? charge.amount_refunded) / 100
      : null;

    const { error: refErr } = await supabase.rpc('process_refund_reversal', {
      p_reservation_id: res.id,
      p_mp_refund_id:   refund.id ?? null,
      p_refund_amount:  refundAmount,
    });

    if (refErr) {
      console.error('[Stripe Webhook] Error process_refund_reversal:', refErr.message);
    } else {
      console.log(`[Stripe Webhook] Reembolso revertido: reserva=${res.id} amount=${refundAmount}`);
    }
  }

  // ── Verificación Plus — Subscriptions ────────────────────────────
  // Estos handlers gestionan el ciclo de vida de Plus.
  // activate_plus / deactivate_plus son SECURITY DEFINER y solo accesibles
  // por service_role (que es como corre este webhook).

  // customer.subscription.created — trial iniciado
  // customer.subscription.updated — cambio de estado (trialing→active, etc.)
  if (
    event.type === 'customer.subscription.created' ||
    event.type === 'customer.subscription.updated'
  ) {
    const sub    = event.data.object as any;
    const groupId = sub.metadata?.group_id as string | undefined;

    if (groupId) {
      const isActive = sub.status === 'trialing' || sub.status === 'active';

      if (isActive) {
        // Stripe 2026 API envía timestamps como string ISO o como Unix number
        const toISO = (v: any): string => {
          if (!v) return new Date(Date.now() + 7 * 24 * 60 * 60 * 1000).toISOString();
          if (typeof v === 'string') return new Date(v).toISOString();
          return new Date(v * 1000).toISOString();
        };
        const expiresAt = toISO(sub.current_period_end ?? sub.trial_end);
        const { error: actErr } = await supabase.rpc('activate_plus', {
          p_group_id:   groupId,
          p_sub_id:     sub.id,
          p_expires_at: expiresAt,
          p_status:     sub.status,
        });
        if (actErr) {
          console.error(`[Plus] activate_plus error (${event.type}):`, actErr.message);
        } else {
          console.log(`[Plus] Activado: group=${groupId} status=${sub.status} expires=${expiresAt}`);
        }
      } else if (sub.status === 'canceled' || sub.status === 'unpaid') {
        const { error: deactErr } = await supabase.rpc('deactivate_plus', { p_sub_id: sub.id });
        if (deactErr) {
          console.error(`[Plus] deactivate_plus error (${event.type}):`, deactErr.message);
        } else {
          console.log(`[Plus] Desactivado: group=${groupId} reason=${sub.status}`);
        }
      } else if (sub.status === 'past_due') {
        // Stripe reintentará el cobro automáticamente — is_plus_active NO se toca.
        // Solo se actualiza el status en plus_subscriptions para que PlusDashboardCard
        // pueda mostrar el aviso de pago pendiente al grupo.
        const { error: pdErr } = await supabase
          .from('plus_subscriptions')
          .update({ status: 'past_due' })
          .eq('stripe_subscription_id', sub.id);
        if (pdErr) {
          console.error(`[Plus] Error registrando past_due: sub=${sub.id}`, pdErr.message);
        } else {
          console.log(`[Plus] past_due registrado: group=${groupId} sub=${sub.id} — is_plus_active sin cambio`);
        }
      }
    }

    return new Response('OK', { status: 200 });
  }

  // invoice.paid — renovación automática exitosa (mes 2, mes 3, etc.)
  if (event.type === 'invoice.paid') {
    const inv   = event.data.object as any;
    const subId = inv.subscription as string | undefined;

    if (subId) {
      // Recuperar la suscripción para obtener los metadatos y la nueva fecha de expiración
      const subRes = await fetch(`https://api.stripe.com/v1/subscriptions/${subId}`, {
        headers: { Authorization: `Bearer ${stripeKey}` },
      });
      const subData = await subRes.json();
      const groupId  = subData?.metadata?.group_id as string | undefined;

      if (groupId && (subData?.current_period_end ?? subData?.trial_end)) {
        const rawEnd = subData.current_period_end ?? subData.trial_end;
        const expiresAt = typeof rawEnd === 'string'
          ? new Date(rawEnd).toISOString()
          : new Date(rawEnd * 1000).toISOString();
        const { error: actErr } = await supabase.rpc('activate_plus', {
          p_group_id:   groupId,
          p_sub_id:     subId,
          p_expires_at: expiresAt,
          p_status:     'active',
        });
        if (actErr) {
          console.error('[Plus] activate_plus error (invoice.paid):', actErr.message);
        } else {
          console.log(`[Plus] Renovado: group=${groupId} expires=${expiresAt}`);
        }
      }
    }

    return new Response('OK', { status: 200 });
  }

  // invoice.payment_failed — cobro fallido (fallo de tarjeta, fondos insuficientes)
  // FIX R1: log-only. Stripe reintentará automáticamente (Smart Retry, hasta ~4 intentos en ~14 días).
  // Desactivar aquí provocaba que el badge desapareciera en el primer intento aunque la tarjeta
  // se cobrara exitosamente en el siguiente intento.
  // La desactivación definitiva ocurre únicamente en:
  //   • customer.subscription.updated  (status = 'unpaid')  — reintentos agotados
  //   • customer.subscription.deleted                        — cancelación definitiva
  if (event.type === 'invoice.payment_failed') {
    const inv        = event.data.object as any;
    const subId      = inv.subscription as string | undefined;
    const attemptNum = inv.attempt_count ?? '?';
    console.log(`[Plus] Pago fallido intento #${attemptNum} (sub=${subId ?? 'unknown'}) — sin acción, Stripe reintentará`);
    return new Response('OK', { status: 200 });
  }

  // customer.subscription.deleted — suscripción cancelada definitivamente
  if (event.type === 'customer.subscription.deleted') {
    const sub = event.data.object as any;
    const { error: deactErr } = await supabase.rpc('deactivate_plus', { p_sub_id: sub.id });
    if (deactErr) {
      console.error('[Plus] deactivate_plus error (subscription.deleted):', deactErr.message);
    } else {
      console.log(`[Plus] Suscripción eliminada: sub=${sub.id}`);
    }

    return new Response('OK', { status: 200 });
  }

  return new Response('OK', { status: 200 });
});
