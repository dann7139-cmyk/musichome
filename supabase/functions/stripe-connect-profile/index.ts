// ═══════════════════════════════════════════════════════════════════
// stripe-connect-profile  –  Supabase Edge Function
// Crea cuenta Stripe Express para usuario individual (talent/miembro)
// y devuelve URL de onboarding. Usa fetch directo (sin SDK).
// Requiere: STRIPE_SECRET_KEY en Supabase Secrets
// ═══════════════════════════════════════════════════════════════════

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const supabase = createClient(
  Deno.env.get('SUPABASE_URL')!,
  Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
);

const corsHeaders = {
  'Access-Control-Allow-Origin':  '*',
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

    // ── Leer perfil ─────────────────────────────────────────────────
    const { data: profile, error: profErr } = await supabase
      .from('profiles')
      .select('id, full_name, stripe_account_id, stripe_onboarding_completed')
      .eq('id', user.id)
      .single();

    if (profErr || !profile) return jsonResponse({ error: 'Perfil no encontrado' }, 404);

    if (profile.stripe_onboarding_completed) {
      // Generar login link al portal Express para que el usuario gestione su cuenta
      const loginRes = await fetch(
        `https://api.stripe.com/v1/accounts/${profile.stripe_account_id}/login_links`,
        { method: 'POST', headers: { Authorization: `Bearer ${stripeKey}` } },
      );
      const loginData = await loginRes.json();
      const loginUrl = loginRes.ok ? loginData.url : null;
      return jsonResponse({ already_completed: true, stripe_account_id: profile.stripe_account_id, login_url: loginUrl });
    }

    let accountId: string = profile.stripe_account_id;

    // ── Crear cuenta Express si no existe ───────────────────────────
    if (!accountId) {
      const acctRes = await fetch('https://api.stripe.com/v1/accounts', {
        method:  'POST',
        headers: {
          Authorization:  `Bearer ${stripeKey}`,
          'Content-Type': 'application/x-www-form-urlencoded',
        },
        body: new URLSearchParams({
          type:                                 'express',
          country:                              'MX',
          'capabilities[transfers][requested]': 'true',
          business_type:                        'individual',
          'metadata[user_id]':                  user.id,
          'metadata[source]':                   'daricefy_profile',
        }),
      });

      const acctData = await acctRes.json();
      if (!acctRes.ok) {
        console.error('[stripe-connect-profile] Error creando cuenta:', JSON.stringify(acctData));
        return jsonResponse({ error: acctData?.error?.message ?? 'Error creando cuenta Stripe' }, 500);
      }

      accountId = acctData.id;
      console.log(`[stripe-connect-profile] Cuenta creada: ${accountId} para user ${user.id}`);

      const { error: updateErr } = await supabase
        .from('profiles')
        .update({ stripe_account_id: accountId })
        .eq('id', user.id);

      if (updateErr) {
        console.error('[stripe-connect-profile] Error guardando stripe_account_id:', updateErr.message);
        return jsonResponse({ error: 'Error guardando cuenta' }, 500);
      }
    }

    // ── Generar URL de onboarding ────────────────────────────────────
    const linkRes = await fetch('https://api.stripe.com/v1/account_links', {
      method:  'POST',
      headers: {
        Authorization:  `Bearer ${stripeKey}`,
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: new URLSearchParams({
        account:     accountId,
        type:        'account_onboarding',
        refresh_url: 'https://stripe.com',
        return_url:  'https://stripe.com',
      }),
    });

    const linkData = await linkRes.json();
    if (!linkRes.ok) {
      console.error('[stripe-connect-profile] Error generando link:', JSON.stringify(linkData));
      return jsonResponse({ error: linkData?.error?.message ?? 'Error generando link' }, 500);
    }

    console.log(`[stripe-connect-profile] Onboarding URL generada para user ${user.id}`);

    return jsonResponse({
      url:               linkData.url,
      stripe_account_id: accountId,
      expires_at:        linkData.expires_at,
    });

  } catch (err: any) {
    console.error('[stripe-connect-profile] Error interno:', err);
    return jsonResponse({ error: err.message ?? 'Error interno' }, 500);
  }
});
