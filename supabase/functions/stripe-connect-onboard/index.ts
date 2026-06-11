// ═══════════════════════════════════════════════════════════════════
// stripe-connect-onboard  –  Supabase Edge Function
// Genera el link de onboarding de Stripe Express para un grupo.
// Usa fetch directo (sin SDK) para máxima compatibilidad con Deno.
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
    // ── Stripe key ──────────────────────────────────────────────────
    const stripeKey = Deno.env.get('STRIPE_SECRET_KEY');
    if (!stripeKey) return jsonResponse({ error: 'STRIPE_SECRET_KEY no configurado' }, 500);

    // ── Autenticar ──────────────────────────────────────────────────
    const authHeader = req.headers.get('Authorization') ?? '';
    const jwt = authHeader.replace('Bearer ', '').trim();
    if (!jwt) return jsonResponse({ error: 'No autorizado' }, 401);

    const { data: { user }, error: authErr } = await supabase.auth.getUser(jwt);
    if (authErr || !user) return jsonResponse({ error: 'No autorizado' }, 401);

    // ── Leer body ───────────────────────────────────────────────────
    const { group_id } = await req.json();
    if (!group_id) return jsonResponse({ error: 'group_id es requerido' }, 400);

    // ── Verificar ownership ─────────────────────────────────────────
    const { data: group, error: groupErr } = await supabase
      .from('groups')
      .select('id, owner_id, stripe_account_id, stripe_onboarding_completed')
      .eq('id', group_id)
      .single();

    if (groupErr || !group) return jsonResponse({ error: 'Grupo no encontrado' }, 404);
    if (group.owner_id !== user.id) return jsonResponse({ error: 'Sin permiso' }, 403);
    if (!group.stripe_account_id) {
      return jsonResponse({ error: 'El grupo no tiene cuenta Stripe. Crea una primero.' }, 400);
    }
    if (group.stripe_onboarding_completed) {
      // Generar login link al portal Express para que el usuario gestione su cuenta
      const loginRes = await fetch(
        `https://api.stripe.com/v1/accounts/${group.stripe_account_id}/login_links`,
        { method: 'POST', headers: { Authorization: `Bearer ${stripeKey}` } },
      );
      const loginData = await loginRes.json();
      const loginUrl = loginRes.ok ? loginData.url : null;
      return jsonResponse({ already_completed: true, login_url: loginUrl });
    }

    // ── Crear Account Link via fetch directo ────────────────────────
    const linkRes = await fetch('https://api.stripe.com/v1/account_links', {
      method: 'POST',
      headers: {
        Authorization:  `Bearer ${stripeKey}`,
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: new URLSearchParams({
        account:     group.stripe_account_id,
        type:        'account_onboarding',
        refresh_url: 'https://stripe.com',
        return_url:  'https://stripe.com',
      }),
    });

    const linkData = await linkRes.json();
    if (!linkRes.ok) {
      console.error('[stripe-connect-onboard] Error Stripe:', JSON.stringify(linkData));
      return jsonResponse({ error: linkData?.error?.message ?? 'Error al crear link' }, 502);
    }

    console.log(`[stripe-connect-onboard] Link generado para cuenta ${group.stripe_account_id}`);

    return jsonResponse({
      url:               linkData.url,
      expires_at:        linkData.expires_at,
      already_completed: false,
    });

  } catch (err: any) {
    console.error('[stripe-connect-onboard] Error interno:', err);
    return jsonResponse({ error: err.message ?? 'Error interno' }, 500);
  }
});
