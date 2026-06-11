// ═══════════════════════════════════════════════════════════════════
// verify-stripe-account  –  Supabase Edge Function
// Consulta el estado REAL de la cuenta Stripe y actualiza la DB.
// Fuente de verdad para producción:
//   onboarding_complete = details_submitted && currently_due.length === 0
//   payouts_ready       = charges_enabled && payouts_enabled
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
    // ── Autenticar ──────────────────────────────────────────────────
    const authHeader = req.headers.get('Authorization') ?? '';
    const jwt = authHeader.replace('Bearer ', '').trim();
    if (!jwt) return jsonResponse({ error: 'No autorizado' }, 401);

    const { data: { user }, error: authErr } = await supabase.auth.getUser(jwt);
    if (authErr || !user) return jsonResponse({ error: 'No autorizado' }, 401);

    const body      = await req.json().catch(() => ({}));
    const { group_id } = body;

    const stripeKey = Deno.env.get('STRIPE_SECRET_KEY');
    if (!stripeKey) return jsonResponse({ error: 'STRIPE_SECRET_KEY no configurado' }, 500);

    // ── Obtener stripe_account_id ───────────────────────────────────
    let stripeAccountId: string | null = null;

    if (group_id) {
      const { data: group } = await supabase
        .from('groups')
        .select('stripe_account_id, owner_id')
        .eq('id', group_id)
        .single();
      if (group?.owner_id !== user.id) return jsonResponse({ error: 'Sin permiso' }, 403);
      stripeAccountId = group?.stripe_account_id ?? null;
    } else {
      const { data: profile } = await supabase
        .from('profiles')
        .select('stripe_account_id')
        .eq('id', user.id)
        .single();
      stripeAccountId = profile?.stripe_account_id ?? null;
    }

    if (!stripeAccountId) {
      return jsonResponse({ verified: false, reason: 'no_account' });
    }

    // ── Consultar estado real en Stripe ─────────────────────────────
    const stripeRes = await fetch(`https://api.stripe.com/v1/accounts/${stripeAccountId}`, {
      headers: { Authorization: `Bearer ${stripeKey}` },
    });
    const acct = await stripeRes.json();

    if (!stripeRes.ok) {
      console.error('[verify-stripe-account] Error Stripe:', JSON.stringify(acct));
      return jsonResponse({
        verified: false,
        reason:   'stripe_error',
        message:  acct.error?.message ?? 'Error al consultar Stripe',
      });
    }

    // ── Evaluar estado (lógica de producción) ───────────────────────
    //
    // details_submitted:
    //   true = el usuario terminó los formularios de su parte.
    //
    // currently_due:
    //   [] vacío = no hay nada pendiente → onboarding completo.
    //   Si tiene items = Stripe pide más info (CURP, RFC, comprobante).
    //
    // charges_enabled + payouts_enabled:
    //   Stripe aprobó la cuenta para operar (puede tardar horas/días).
    //   Necesario para transfers reales.
    //
    // Regla para OCULTAR el banner:
    //   details_submitted = true  AND  currently_due.length === 0
    //
    // Regla para HABILITAR pagos:
    //   charges_enabled = true  AND  payouts_enabled = true

    const currentlyDue: string[]  = acct.requirements?.currently_due  ?? [];
    const pastDue:       string[]  = acct.requirements?.past_due        ?? [];
    const pendingVerif:  string[]  = acct.requirements?.pending_verification ?? [];

    const detailsSubmitted = !!acct.details_submitted;
    const noBlockingReqs   = currentlyDue.length === 0 && pastDue.length === 0;
    const onboardingDone   = detailsSubmitted && noBlockingReqs;
    const payoutsReady     = !!(acct.charges_enabled && acct.payouts_enabled);

    console.log(
      `[verify-stripe-account] ${stripeAccountId}: ` +
      `details_submitted=${detailsSubmitted} ` +
      `currently_due=${currentlyDue.length} past_due=${pastDue.length} ` +
      `charges=${acct.charges_enabled} payouts=${acct.payouts_enabled}`,
    );

    // ── Actualizar DB si el onboarding está listo ───────────────────
    if (onboardingDone) {
      if (group_id) {
        const { error: grpErr } = await supabase
          .from('groups')
          .update({ stripe_onboarding_completed: true })
          .eq('id', group_id);
        if (grpErr) console.error('[verify-stripe-account] Error updating group:', grpErr.message);
      }

      // Actualizar perfil por stripe_account_id (para cuentas personales)
      const profileUpdate: Record<string, unknown> = { stripe_onboarding_completed: true };
      if (payoutsReady) profileUpdate.stripe_payouts_enabled = true;

      await supabase
        .from('profiles')
        .update(profileUpdate)
        .eq('stripe_account_id', stripeAccountId);

      // Para cuenta de grupo: también actualizar perfil del dueño por user_id
      if (group_id) {
        const ownerUpdate: Record<string, unknown> = { stripe_onboarding_completed: true };
        if (payoutsReady) ownerUpdate.stripe_payouts_enabled = true;
        await supabase
          .from('profiles')
          .update(ownerUpdate)
          .eq('id', user.id);
      }
    } else if (payoutsReady && detailsSubmitted) {
      // Caso especial: Stripe ya aprobó payouts pero aún hay pending_verification
      // (documentos en revisión). Actualizar stripe_payouts_enabled pero no stripe_onboarding_completed.
      await supabase
        .from('profiles')
        .update({ stripe_payouts_enabled: true })
        .eq('stripe_account_id', stripeAccountId);
      if (group_id) {
        await supabase
          .from('profiles')
          .update({ stripe_payouts_enabled: true })
          .eq('id', user.id);
      }
    }

    return jsonResponse({
      // El cliente usa 'verified' para decidir si ocultar el banner
      verified:           onboardingDone,
      payouts_ready:      payoutsReady,
      // Campos raw de Stripe para que el cliente muestre mensajes precisos
      details_submitted:  detailsSubmitted,
      charges_enabled:    acct.charges_enabled   ?? false,
      payouts_enabled:    acct.payouts_enabled    ?? false,
      currently_due:      currentlyDue,
      past_due:           pastDue,
      pending_verification: pendingVerif,
      // Mensaje de ayuda si hay requerimientos pendientes
      pending_message: !detailsSubmitted
        ? 'Completa el formulario de verificación de Stripe.'
        : currentlyDue.length > 0
          ? `Stripe requiere información adicional: ${currentlyDue.slice(0, 2).join(', ')}${currentlyDue.length > 2 ? '...' : ''}`
          : pastDue.length > 0
            ? 'Hay información vencida. Vuelve a verificar tu cuenta.'
            : null,
    });

  } catch (err: any) {
    console.error('[verify-stripe-account] Error interno:', err);
    return jsonResponse({ error: err.message ?? 'Error interno' }, 500);
  }
});
