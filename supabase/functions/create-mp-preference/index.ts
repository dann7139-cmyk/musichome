// ═══════════════════════════════════════════════════════════════════
// create-mp-preference  –  Supabase Edge Function
// Crea una preferencia de pago en MercadoPago para el anticipo 50%.
//
// POST (autenticado):  { reservation_id: string }
// Respuesta:           { ok, preference_id, init_point, sandbox_init_point, deposit, total_price }
// ═══════════════════════════════════════════════════════════════════

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

function jsonRes(body: Record<string, unknown>) {
  return new Response(JSON.stringify(body), {
    status: 200,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}

// Mercado Pago desactivado (auditoría 2026-08-08) — Stripe y Conekta son
// los únicos proveedores activos de Daricefy. Tipado como `boolean` (no
// literal `false`) a propósito: evita que TypeScript marque el resto de
// esta función como código muerto y pierda el narrowing de tipos.
const MERCADOPAGO_ACTIVE: boolean = false;

// Exportado además de registrado con Deno.serve más abajo, únicamente
// para poder importarlo desde pruebas locales sin desplegar ni levantar
// un servidor HTTP real — cero cambio de comportamiento en producción.
export async function handleRequest(req: Request): Promise<Response> {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });

  // Corte explícito ANTES de leer MERCADOPAGO_ACCESS_TOKEN o crear
  // cualquier preferencia de pago: cero llamada a la API de Mercado Pago.
  if (!MERCADOPAGO_ACTIVE) {
    return jsonRes({ error: 'Mercado Pago ya no es un proveedor activo de Daricefy.', code: 'provider_disabled' });
  }

  // Env vars y cliente dentro del handler (evita crash al inicializar módulo)
  const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? '';
  const SERVICE_KEY  = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';

  // Cliente admin con service role (bypasea RLS)
  const admin = createClient(SUPABASE_URL, SERVICE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  try {
    // ── Autenticar: verificar firma con Supabase Auth (no decodificar a ciegas) ──
    // [Corregido 2026-09-11] Antes se leía el payload del JWT con atob() sin
    // validar la firma — un token fabricado (payload editado, firma inválida)
    // pasaba igual. admin.auth.getUser() sí valida criptográficamente contra
    // Supabase Auth, igual que el resto de las Edge Functions de pago.
    const authHeader = req.headers.get('Authorization');
    if (!authHeader?.startsWith('Bearer ')) {
      return jsonRes({ error: 'No autorizado: sin header' });
    }
    const token = authHeader.slice(7);

    const { data: authData, error: authErr } = await admin.auth.getUser(token);
    if (authErr || !authData?.user) {
      return jsonRes({ error: 'No autorizado: token inválido' });
    }
    const user = { id: authData.user.id, email: authData.user.email ?? '' };

    // ── Body ──────────────────────────────────────────────────────────
    const body = await req.json().catch(() => ({}));
    const { reservation_id } = body as { reservation_id?: string };
    if (!reservation_id) return jsonRes({ error: 'reservation_id requerido' });

    // ── Reserva ───────────────────────────────────────────────────────
    const { data: reservation, error: resErr } = await admin
      .from('reservations')
      .select('id,total_price,client_id,status,payment_status,payment_mode,group_id,installment_months,installment_plan')
      .eq('id', reservation_id)
      .single();

    if (resErr || !reservation) {
      console.error('[MP] Reservation error:', resErr?.message);
      return jsonRes({ error: 'Reserva no encontrada' });
    }
    if (reservation.client_id !== user.id) return jsonRes({ error: 'Sin permiso' });
    if (!['pending', 'accepted', 'confirmed'].includes(reservation.status)) {
      return jsonRes({ error: 'La reserva no está lista para pagar' });
    }
    if (['paid', 'deposit_paid', 'fully_paid'].includes(reservation.payment_status)) {
      return jsonRes({ error: 'Esta reserva ya fue pagada' });
    }

    // ── Nombre del grupo ──────────────────────────────────────────────
    let groupName = 'Grupo musical';
    if (reservation.group_id) {
      const { data: grp } = await admin
        .from('groups')
        .select('name')
        .eq('id', reservation.group_id)
        .single();
      groupName = grp?.name ?? groupName;
    }

    // ── Token MercadoPago ──────────────────────────────────────────────
    const mpToken = Deno.env.get('MERCADOPAGO_ACCESS_TOKEN')
      ?? Deno.env.get('mercadopago_access_token')
      ?? null;
    if (!mpToken) return jsonRes({ error: 'MercadoPago no está configurado en el servidor' });

    const totalPrice  = (reservation.total_price as number) ?? 0;
    const paymentMode = (reservation.payment_mode as string | null) ?? 'full';
    // Backward compat: reservas antiguas con payment_mode='deposit' siguen pagando 50%
    const chargeAmount = paymentMode === 'deposit'
      ? Math.round(totalPrice * 0.5)
      : totalPrice;
    const webhookUrl = `${SUPABASE_URL}/functions/v1/mercadopago-webhook`;

    // MSI: si el cliente seleccionó meses sin intereses, se configura
    // en la preferencia para que MP lo presente al momento del pago.
    // Los bancos participantes en México aplican el MSI automáticamente.
    // El grupo siempre recibe el monto completo — el banco/MP asume el costo.
    const installmentMonths = (reservation.installment_months as number | null) ?? 1;
    const installmentPlan   = (reservation.installment_plan as string | null) ?? '1_pago';

    if (installmentMonths > 1) {
      console.log(`[MSI_SELECTED] reservation=${reservation_id} months=${installmentMonths} plan=${installmentPlan} amount=$${chargeAmount} MXN`);
    } else {
      console.log(`[MSI_NOT_AVAILABLE] reservation=${reservation_id} single_payment=$${chargeAmount} MXN mode=${paymentMode}`);
    }

    const paymentMethods = installmentMonths > 1
      ? {
          installments:         installmentMonths,
          default_installments: installmentMonths,
        }
      : {
          installments: 1,
        };

    const itemTitle = paymentMode === 'deposit'
      ? `Anticipo 50% · ${groupName}`
      : `Reserva · ${groupName}`;

    // ── Crear preferencia MP ──────────────────────────────────────────
    const prefBody = {
      items: [{
        id:          reservation_id,
        title:       itemTitle,
        description: `Reserva de evento con ${groupName}`,
        quantity:    1,
        unit_price:  chargeAmount,
        currency_id: 'MXN',
      }],
      payment_methods:      paymentMethods,
      external_reference:   reservation_id,
      notification_url:     webhookUrl,
      back_urls: {
        success: `${SUPABASE_URL}/functions/v1/mp-back?status=success&reservation_id=${reservation_id}`,
        failure: `${SUPABASE_URL}/functions/v1/mp-back?status=failure&reservation_id=${reservation_id}`,
        pending: `${SUPABASE_URL}/functions/v1/mp-back?status=pending&reservation_id=${reservation_id}`,
      },
      auto_return:          'approved',
      statement_descriptor: 'DARICEFY',
      metadata: {
        reservation_id,
        client_id:        user.id,
        payment_mode:     paymentMode,
        installment_plan: reservation.installment_plan ?? '1_pago',
      },
    };

    const mpRes = await fetch('https://api.mercadopago.com/checkout/preferences', {
      method:  'POST',
      headers: { Authorization: `Bearer ${mpToken}`, 'Content-Type': 'application/json' },
      body:    JSON.stringify(prefBody),
    });
    const mpData = await mpRes.json() as any;
    if (!mpRes.ok) {
      console.error('[MP] Error creando preferencia:', JSON.stringify(mpData));
      return jsonRes({ error: mpData?.message ?? 'Error al crear preferencia de pago en MercadoPago' });
    }

    // ── Guardar preference_id y payment_mode ──────────────────────────
    await admin
      .from('reservations')
      .update({ mp_preference_id: mpData.id, payment_mode: paymentMode })
      .eq('id', reservation_id);

    if (installmentMonths > 1) {
      console.log(`[MSI_APPLIED] preference_id=${mpData.id} reservation=${reservation_id} months=${installmentMonths} plan=${installmentPlan}`);
    }
    console.log(`[CREATE_MP_PREFERENCE] Created: ${mpData.id} | mode=${paymentMode} | charge=$${chargeAmount} MXN | MSI: ${installmentMonths > 1 ? `${installmentMonths} cuotas` : 'pago único'}`);

    return jsonRes({
      ok:                 true,
      preference_id:      mpData.id,
      init_point:         mpData.init_point,
      sandbox_init_point: mpData.sandbox_init_point,
      charge_amount:      chargeAmount,
      total_price:        totalPrice,
      payment_mode:       paymentMode,
    });

  } catch (e: unknown) {
    const msg = e instanceof Error ? e.message : 'Error interno';
    console.error('[create-mp-preference] Error:', msg);
    return jsonRes({ error: msg });
  }
}

if (import.meta.main) {
  Deno.serve(handleRequest);
}
