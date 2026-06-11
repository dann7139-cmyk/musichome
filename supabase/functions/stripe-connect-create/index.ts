// ═══════════════════════════════════════════════════════════════════
// stripe-connect-create  –  Supabase Edge Function
// Crea una cuenta Stripe Express para un grupo y guarda el ID.
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

    // ── Leer body ───────────────────────────────────────────────────
    const { group_id } = await req.json();
    if (!group_id) return jsonResponse({ error: 'group_id es requerido' }, 400);

    // ── Verificar ownership del grupo ───────────────────────────────
    const { data: group, error: groupErr } = await supabase
      .from('groups')
      .select('id, name, owner_id, stripe_account_id, stripe_onboarding_completed')
      .eq('id', group_id)
      .single();

    if (groupErr || !group) return jsonResponse({ error: 'Grupo no encontrado' }, 404);
    if (group.owner_id !== user.id) return jsonResponse({ error: 'Sin permiso' }, 403);

    // ── Idempotente: si ya tiene cuenta, devolver ───────────────────
    if (group.stripe_account_id) {
      return jsonResponse({
        stripe_account_id:           group.stripe_account_id,
        stripe_onboarding_completed: group.stripe_onboarding_completed,
        already_exists:              true,
      });
    }

    // ── Stripe secret key ───────────────────────────────────────────
    const stripeKey = Deno.env.get('STRIPE_SECRET_KEY');
    if (!stripeKey) return jsonResponse({ error: 'STRIPE_SECRET_KEY no configurado' }, 500);

    // ── Obtener email del owner ─────────────────────────────────────
    const { data: ownerProfile } = await supabase
      .from('profiles')
      .select('full_name')
      .eq('id', user.id)
      .single();

    // ── Crear cuenta Stripe Express ─────────────────────────────────
    const acctBody = new URLSearchParams({
      type:                                    'express',
      country:                                 'MX',
      email:                                   user.email ?? '',
      'capabilities[transfers][requested]':    'true',
      business_type:                           'individual',
      'business_profile[name]':                group.name ?? '',
      'metadata[group_id]':                    group_id,
      'metadata[owner_id]':                    user.id,
      'metadata[owner_name]':                  ownerProfile?.full_name ?? '',
    });

    const acctRes = await fetch('https://api.stripe.com/v1/accounts', {
      method: 'POST',
      headers: {
        Authorization:  `Bearer ${stripeKey}`,
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: acctBody,
    });

    const acctData = await acctRes.json();

    if (!acctRes.ok) {
      console.error('[stripe-connect-create] Error Stripe:', JSON.stringify(acctData));
      return jsonResponse({ error: acctData?.error?.message ?? 'Error al crear cuenta en Stripe' }, 502);
    }

    console.log(`[stripe-connect-create] Cuenta creada: ${acctData.id} para grupo ${group_id}`);

    // ── Guardar stripe_account_id en el grupo ───────────────────────
    const { error: updateErr } = await supabase
      .from('groups')
      .update({ stripe_account_id: acctData.id })
      .eq('id', group_id);

    if (updateErr) {
      console.error('[stripe-connect-create] Error guardando account_id:', updateErr.message);
      return jsonResponse({ error: 'Cuenta creada pero no se pudo guardar. Intenta de nuevo.' }, 500);
    }

    return jsonResponse({
      stripe_account_id:           acctData.id,
      stripe_onboarding_completed: false,
      already_exists:              false,
    });

  } catch (err: any) {
    console.error('[stripe-connect-create] Error interno:', err);
    return jsonResponse({ error: err.message ?? 'Error interno' }, 500);
  }
});
