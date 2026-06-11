// ═══════════════════════════════════════════════════════════════════
// create-portal-session  –  Supabase Edge Function (Stripe)
//
// Genera una sesión del Stripe Customer Portal para que el grupo
// pueda gestionar su suscripción Plus (cancelar, actualizar tarjeta,
// ver historial de pagos) sin que la app maneje datos de pago directamente.
//
// Requisito previo: el Customer Portal debe estar habilitado en
// Stripe Dashboard → Settings → Billing → Customer portal.
//
// POST (autenticado): { group_id: string }
// Respuesta:          { ok: true, url: string }
// ═══════════════════════════════════════════════════════════════════

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin':  '*',
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

  const SUPABASE_URL = Deno.env.get('SUPABASE_URL')              ?? '';
  const SERVICE_KEY  = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
  const STRIPE_KEY   = Deno.env.get('STRIPE_SECRET_KEY')         ?? '';

  if (!STRIPE_KEY) return jsonRes({ error: 'STRIPE_SECRET_KEY no configurado' }, 500);

  const admin = createClient(SUPABASE_URL, SERVICE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  try {
    // ── Autenticar ────────────────────────────────────────────────────
    const authHeader = req.headers.get('Authorization');
    if (!authHeader?.startsWith('Bearer ')) return jsonRes({ error: 'No autorizado' }, 401);
    const token = authHeader.slice(7);

    let userId: string;
    try {
      const parts   = token.split('.');
      const pad     = (s: string) => s + '='.repeat((4 - s.length % 4) % 4);
      const payload = JSON.parse(atob(pad(parts[1].replace(/-/g, '+').replace(/_/g, '/'))));
      if (!payload.sub) throw new Error('no sub');
      userId = payload.sub;
    } catch {
      return jsonRes({ error: 'Token inválido' }, 401);
    }

    // ── Body ──────────────────────────────────────────────────────────
    const body     = await req.json().catch(() => ({}));
    const { group_id } = body as { group_id?: string };
    if (!group_id) return jsonRes({ error: 'group_id requerido' });

    // ── Verificar ownership del grupo ─────────────────────────────────
    const { data: group } = await admin
      .from('groups')
      .select('id, owner_id')
      .eq('id', group_id)
      .single();

    if (!group)                   return jsonRes({ error: 'Grupo no encontrado' });
    if (group.owner_id !== userId) return jsonRes({ error: 'Sin permiso sobre este grupo' });

    // ── Obtener stripe_customer_id del perfil ─────────────────────────
    const { data: profile } = await admin
      .from('profiles')
      .select('stripe_customer_id')
      .eq('id', userId)
      .single();

    const customerId = profile?.stripe_customer_id;
    if (!customerId) {
      return jsonRes({
        error: 'No tienes una cuenta de pagos registrada. Activa Plus primero.',
      });
    }

    // ── Crear sesión del Customer Portal ──────────────────────────────
    // return_url: deep link que reabre la app al salir del portal.
    // Stripe redirige a esta URL cuando el usuario toca "← Volver".
    const returnUrl = 'daricefy://plus';

    const portalRes = await fetch('https://api.stripe.com/v1/billing_portal/sessions', {
      method: 'POST',
      headers: {
        Authorization:  `Bearer ${STRIPE_KEY}`,
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: new URLSearchParams({
        customer:   customerId,
        return_url: returnUrl,
      }),
    });

    const session = await portalRes.json();

    if (!portalRes.ok) {
      console.error('[Portal] Error al crear sesión:', JSON.stringify(session));

      // El Customer Portal no está habilitado en Stripe Dashboard
      if (session?.error?.code === 'resource_missing') {
        return jsonRes({
          error:   'portal_not_configured',
          message: 'El portal de pagos aún no está configurado. Contacta al soporte.',
        });
      }

      return jsonRes({ error: 'Error al generar el portal. Intenta de nuevo.' }, 500);
    }

    console.log(`[Portal] Sesión creada: customer=${customerId} group=${group_id}`);
    return jsonRes({ ok: true, url: session.url as string });

  } catch (err) {
    console.error('[Portal] Error inesperado:', err);
    return jsonRes({ error: 'Error interno del servidor' }, 500);
  }
});
