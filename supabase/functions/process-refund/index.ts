// ═══════════════════════════════════════════════════════════════════
// process-refund  –  Supabase Edge Function  (P1F: capa de claims)
// Emite un reembolso real y revierte el wallet del grupo, protegido por
// provider_refund_claims (claim atómico ANTES de cualquier HTTP externo).
//
// Detección de proveedor por el id guardado en reservations.mp_payment_id:
//   · 'pi_...'  → Stripe (flujo actual de cobro — PaymentIntent)
//   · 'ord_...' → Conekta
//   · numérico  → MercadoPago (legacy)
//
// POST (autenticado como admin o cliente dueño pre-evento):
//   { reservation_id, refund_amount?, idempotency_key?, mode? }
//     · mode 'full' (default) → reembolso total/parcial + reversión completa
//       de wallet (process_refund_reversal). Para no-show/admin/disputa.
//       NOTA: la capa SQL (process_refund_reversal) SOLO acepta el monto
//       EXACTO de total_price — un refund_amount parcial en mode 'full'
//       es rechazado con 'partial_refund_not_supported' DESPUÉS de que el
//       proveedor ya emitió el dinero si no se valida antes (ver claim).
//     · mode 'cancellation' → C2a: el monto a reembolsar lo calcula el
//       servidor (compute_cancellation_charge, tiers por proximidad),
//       IGNORA refund_amount del cliente, y liquida con settle_cancellation
//       (el grupo conserva su compensación, Daricefy su parte).
//     · mode 'group_cancellation' → el grupo cancela: reembolso 100% al
//       cliente + strike (settle_group_cancellation).
//
// Idempotencia — capa doble:
//   1. provider_refund_claims (claim_reservation_refund) — candado atómico
//      por (provider, provider_payment_id) mientras status esté en
//      ('processing','provider_succeeded'). Se crea/verifica ANTES de
//      cualquier llamada HTTP al proveedor: nunca existe una ventana donde
//      el proveedor reciba el refund sin que el claim ya exista.
//   2. Idempotency-Key (Stripe) / X-Idempotency-Key (MercadoPago) derivada
//      del claim (`claim-{claim_id}`) — estable durante TODO el ciclo de
//      vida de ese claim, incluidos reintentos legítimos tras timeout.
//      Conekta no ofrece un mecanismo equivalente — ver needs_verification.
//
// Máquina de estados de provider_refund_claims:
//   processing → provider_succeeded → done   (éxito)
//   processing → provider_failed             (proveedor rechazó, claro)
//   processing (needs_verification=true)     (Conekta: sin respuesta o 5xx
//                                              — NUNCA se reintenta el HTTP
//                                              automáticamente; requiere
//                                              verificación manual admin)
//
// Respuesta: { ok, provider, refund_id, amount, reservation_id, mode, breakdown? }
// Los fallos se auditan en payment_event_logs (refund_failed).
// ═══════════════════════════════════════════════════════════════════

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

function jsonRes(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}

// Mapea los códigos de rechazo de claim_reservation_refund a respuestas
// HTTP claras. El frontend actual solo revisa `data.error` (string) y/o
// `data.ok===false`, así que el mensaje humano es lo que importa para
// compatibilidad; `code` es nuevo y aditivo (nadie lo consume todavía).
const CLAIM_ERROR_MAP: Record<string, { status: number; message: string }> = {
  not_authorized:                     { status: 403, message: 'Sin permiso para emitir reembolso' },
  invalid_mode:                       { status: 400, message: 'Modo de reembolso inválido' },
  invalid_amount:                     { status: 400, message: 'Monto de reembolso inválido' },
  invalid_provider:                   { status: 400, message: 'Proveedor de pago inválido' },
  invalid_payment_id:                 { status: 400, message: 'ID de pago inválido' },
  not_found:                          { status: 404, message: 'Reserva no encontrada' },
  unsupported_currency:               { status: 422, message: 'Moneda de la reserva no soportada para reembolso' },
  payment_not_eligible:               { status: 422, message: 'La reserva no tiene un pago confirmado' },
  payout_status_not_eligible:         { status: 422, message: 'Esta reserva ya fue reembolsada o el pago ya fue liberado' },
  open_dispute_blocks_refund:         { status: 409, message: 'No se puede reembolsar: hay una disputa abierta para esta reserva' },
  manual_payment_already_transferred: { status: 409, message: 'Ya se transfirió dinero al grupo manualmente — requiere reconciliación manual del administrador' },
  refund_already_in_progress:         { status: 409, message: 'Ya hay un reembolso en proceso para esta reserva — espera unos segundos y reintenta' },
  temporary_retry:                    { status: 409, message: 'Operación concurrente detectada — reintenta en unos segundos' },
};

// Exportado (además de registrado con Deno.serve más abajo) únicamente
// para poder importarlo desde pruebas locales (index.test.ts) sin
// necesidad de desplegar ni de un servidor HTTP real — cero cambio de
// comportamiento en producción.
export async function handleRequest(req: Request): Promise<Response> {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });

  const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? '';
  const SERVICE_KEY  = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
  const mpToken      = Deno.env.get('MERCADOPAGO_ACCESS_TOKEN')
    ?? Deno.env.get('mercadopago_access_token')
    ?? '';
  const stripeKey    = Deno.env.get('STRIPE_SECRET_KEY') ?? '';
  const conektaKey   = Deno.env.get('CONEKTA_PRIVATE_KEY') ?? '';
  // Clave pública (publishable/anon) — NO es secreta, ya vive expuesta en
  // src/config/supabase.ts dentro del bundle de la app cliente. Se usa
  // ÚNICAMENTE para reenviar el JWT del llamante real a
  // claim_reservation_refund, cuyo modelo de permisos depende de
  // auth.uid() (admin / cliente dueño / dueño del grupo) — si se llamara
  // con la service-role key, auth.uid() sería NULL y la función SIEMPRE
  // rechazaría con 'not_authorized'. Puede sobreescribirse con la variable
  // de entorno SUPABASE_ANON_KEY si se prefiere no hardcodearla.
  const ANON_KEY     = Deno.env.get('SUPABASE_ANON_KEY')
    ?? 'sb_publishable_hVxM5hR57omduY44QPKbZQ_q6mBgeIX';

  // admin client (service_role) — used for DB operations and JWT verification
  const admin = createClient(SUPABASE_URL, SERVICE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const serviceHeaders: Record<string, string> = {
    Authorization:  `Bearer ${SERVICE_KEY}`,
    apikey:         SERVICE_KEY,
    'Content-Type': 'application/json',
    Prefer:         'return=representation',
  };

  // Auditoría compartida (éxitos y fallos) — fire-and-forget
  const logPaymentEvent = (paymentId: string, reservationId: string, eventType: string, amount: number, notes: string) => {
    fetch(`${SUPABASE_URL}/rest/v1/rpc/log_payment_event`, {
      method:  'POST',
      headers: serviceHeaders,
      body:    JSON.stringify({
        p_mp_payment_id:  paymentId,
        p_external_ref:   reservationId,
        p_reservation_id: reservationId,
        p_mp_status:      eventType === 'refund_issued' ? 'refunded'
                        : eventType === 'refund_manual_pending' ? 'manual_pending'
                        : 'refund_failed',
        p_mp_amount:      amount,
        p_event_type:     eventType,
        p_notes:          notes,
      }),
    }).catch((e: unknown) => console.error('[log_payment_event]', e));
  };

  // Alerta urgente al admin — usada en los casos donde el dinero YA salió
  // pero algo internamente quedó pendiente (contabilización o verificación
  // manual de Conekta). Fire-and-forget, nunca bloquea la respuesta.
  const notifyAdminUrgent = (title: string, body: string, data: Record<string, unknown>) => {
    admin.from('profiles').select('id').eq('role', 'admin').then(({ data: admins }) => {
      const rows = (admins ?? []).map((a: any) => ({ user_id: a.id, type: 'admin', title, body, data }));
      if (rows.length) admin.from('notifications').insert(rows).then(() => {}, () => {});
    });
  };

  try {
    // ── Autenticar (verificación criptográfica via Supabase Auth) ─────
    const authHeader = req.headers.get('Authorization');
    if (!authHeader?.startsWith('Bearer ')) {
      return jsonRes({ error: 'No autorizado' }, 401);
    }
    const token = authHeader.slice(7);

    const { data: authData, error: authErr } = await admin.auth.getUser(token);
    if (authErr || !authData?.user) {
      console.warn('[process-refund] JWT rejected:', authErr?.message ?? 'no user');
      return jsonRes({ error: 'Token inválido o expirado' }, 401);
    }
    const callerId = authData.user.id;

    // Headers para llamar RPCs que dependen de auth.uid() del LLAMANTE REAL
    // (solo claim_reservation_refund por ahora) — a diferencia de
    // serviceHeaders (service_role, para todo lo demás, sin cambios).
    const userHeaders: Record<string, string> = {
      Authorization:  `Bearer ${token}`,
      apikey:         ANON_KEY,
      'Content-Type': 'application/json',
      Prefer:         'return=representation',
    };

    // ── Body ──────────────────────────────────────────────────────────
    const body = await req.json().catch(() => ({})) as {
      reservation_id?:  string;
      refund_amount?:   number;
      idempotency_key?: string;
      mode?:            'full' | 'cancellation' | 'group_cancellation';
      clabe?:           string;
      account_holder?:  string;
      bank_name?:       string;
    };
    const { reservation_id, refund_amount } = body;
    const mode = body.mode ?? 'full';
    if (!reservation_id) return jsonRes({ error: 'reservation_id requerido' }, 400);

    // ── Cargar reserva ────────────────────────────────────────────────
    const { data: reservation, error: resErr } = await admin
      .from('reservations')
      .select('id,total_price,base_price,client_id,payment_status,payout_status,mp_payment_id,payment_provider,payment_method_type,event_date,group_id,currency_code')
      .eq('id', reservation_id)
      .single();

    if (resErr || !reservation) return jsonRes({ error: 'Reserva no encontrada' }, 404);

    // ── Permisos ──────────────────────────────────────────────────────
    const { data: callerProfile } = await admin
      .from('profiles')
      .select('role')
      .eq('id', callerId)
      .single();

    const isAdmin  = callerProfile?.role === 'admin';
    const isClient = (reservation.client_id as string) === callerId;
    const isPre    = new Date(reservation.event_date as string) > new Date();

    if (mode === 'group_cancellation') {
      const { data: grp } = await admin
        .from('groups')
        .select('owner_id')
        .eq('id', reservation.group_id)
        .single();
      const isGroupOwner = grp?.owner_id === callerId;
      if (!isAdmin && !isGroupOwner) {
        return jsonRes({ error: 'Solo el dueño del grupo puede cancelar como grupo' }, 403);
      }
      if (!isAdmin && !isPre) {
        return jsonRes({ error: 'El evento ya pasó — no se puede cancelar' }, 422);
      }
    } else if (!isAdmin && !(isClient && isPre)) {
      return jsonRes({ error: 'Sin permiso para emitir reembolso' }, 403);
    }

    // ── Validaciones ──────────────────────────────────────────────────
    const paymentId = String(reservation.mp_payment_id ?? '');
    if (!paymentId) {
      return jsonRes({ error: 'No hay pago registrado para esta reserva' }, 422);
    }
    const provider  = String((reservation as any).payment_provider ?? '');
    const isConekta = provider === 'conekta' || paymentId.startsWith('ord_');
    const isStripe  = !isConekta && (provider === 'stripe' || paymentId.startsWith('pi_'));

    // Proveedores activos: ÚNICAMENTE Stripe y Conekta (Mercado Pago
    // desactivado — auditoría 2026-08-08, cero pagos históricos reales).
    // Deliberadamente NO hay fallback: un payment_id/provider que no
    // matchea Stripe ni Conekta NUNCA se asume Mercado Pago — se rechaza
    // explícito, antes de crear claim, antes de cualquier RPC financiera,
    // antes de cualquier llamada HTTP a un proveedor.
    if (!isStripe && !isConekta) {
      console.warn(`[REFUND_PROVIDER_DISABLED] reservation=${reservation_id} provider="${provider}" payment_id="${paymentId}"`);
      return jsonRes({ error: 'Proveedor de pago no soportado', code: 'provider_disabled' }, 422);
    }
    const providerName: 'stripe' | 'conekta' = isStripe ? 'stripe' : 'conekta';

    if (!['paid', 'fully_paid', 'deposit_paid'].includes(reservation.payment_status as string)) {
      return jsonRes({ error: 'La reserva no tiene un pago confirmado' }, 422);
    }
    if (reservation.payout_status === 'refunded') {
      return jsonRes({ error: 'Esta reserva ya fue reembolsada' }, 422);
    }
    if (reservation.payout_status === 'released') {
      return jsonRes({ error: 'No se puede reembolsar: el pago ya fue liberado al grupo' }, 422);
    }

    const totalPrice = reservation.total_price as number;

    // ── Monto a reembolsar ────────────────────────────────────────────
    let amountToRef: number;
    let cancellationCharge: any = null;
    if (mode === 'group_cancellation') {
      amountToRef = totalPrice;
    } else if (mode === 'cancellation') {
      const { data: charge, error: chargeErr } = await admin
        .rpc('compute_cancellation_charge', { p_reservation_id: reservation_id });
      if (chargeErr || !charge?.ok) {
        return jsonRes({ error: charge?.error ?? chargeErr?.message ?? 'No se pudo calcular el cargo' }, 422);
      }
      cancellationCharge = charge;
      amountToRef = Number(charge.refund_amount);
      if (amountToRef <= 0) {
        // Sin monto que reembolsar (tier not_paid) → no hay HTTP a
        // proveedor, no aplica claim (claim_reservation_refund exige
        // amount>0 por diseño). settle_cancellation ya es idempotente por
        // sí sola (status='cancelled' AND payout_status='refunded' → skip).
        const { data: settled, error: settleErr } = await admin
          .rpc('settle_cancellation', { p_reservation_id: reservation_id, p_refund_id: null });
        if (settleErr || settled?.ok === false) {
          return jsonRes({ error: settled?.error ?? settleErr?.message ?? 'No se pudo liquidar' }, 422);
        }
        return jsonRes({ ok: true, mode, provider: 'none', refund_id: null, amount: 0, reservation_id, breakdown: cancellationCharge });
      }
    } else {
      amountToRef = refund_amount ?? totalPrice;
    }

    if (amountToRef <= 0) {
      return jsonRes({ error: 'El monto del reembolso debe ser mayor a $0' }, 422);
    }
    if (amountToRef > totalPrice) {
      return jsonRes({ error: `El reembolso ($${amountToRef}) excede el total ($${totalPrice})` }, 422);
    }

    console.log(`[REFUND_INIT] reservation=${reservation_id} provider=${providerName} payment=${paymentId} amount=$${amountToRef} by=${isAdmin ? 'admin' : 'client'}`);

    // ═══════════════════════════════════════════════════════════════
    // CLAIM — obtener uno activo existente o crear uno nuevo. SIEMPRE
    // antes de cualquier llamada HTTP a Stripe/Conekta/MercadoPago.
    // ═══════════════════════════════════════════════════════════════
    async function findActiveClaim(): Promise<any | null> {
      const { data } = await admin
        .from('provider_refund_claims')
        .select('*')
        .eq('provider', providerName)
        .eq('provider_payment_id', paymentId)
        .in('status', ['processing', 'provider_succeeded'])
        .order('created_at', { ascending: false })
        .limit(1);
      return (data && data[0]) ?? null;
    }
    async function markClaim(claimId: string, patch: Record<string, unknown>) {
      await admin.from('provider_refund_claims')
        .update({ ...patch, updated_at: new Date().toISOString() })
        .eq('id', claimId);
    }

    const existingClaim = await findActiveClaim();
    let claimId: string;
    let reusedProviderSucceeded = false;

    if (existingClaim) {
      claimId = existingClaim.id;
      // Reusa el MISMO monto con el que se creó el claim original — nunca
      // recalcular (los tiers de cancelación son sensibles al tiempo; un
      // reintento horas después podría calcular un tier distinto).
      amountToRef = Number(existingClaim.amount);

      if (existingClaim.status === 'provider_succeeded') {
        reusedProviderSucceeded = true; // saltar HTTP, ir directo a liquidar
      } else if (existingClaim.status === 'processing') {
        if (isConekta) {
          // Conekta no ofrece idempotencia oficial — no hay forma segura de
          // saber si el intento anterior llegó a procesarse en su lado.
          // NUNCA se reintenta el HTTP automáticamente.
          return jsonRes({
            error: 'Hay un reembolso con Conekta pendiente de verificación manual para esta reserva. Un administrador debe confirmar el estado directamente con Conekta antes de continuar.',
            code:  'refund_verification_pending',
          }, 409);
        }
        // Stripe / MercadoPago: SÍ es seguro reintentar el HTTP reusando
        // este mismo claim con la MISMA Idempotency-Key — el proveedor
        // garantiza que no se duplica el cobro/reembolso.
      }
    } else {
      const claimRes = await fetch(`${SUPABASE_URL}/rest/v1/rpc/claim_reservation_refund`, {
        method:  'POST',
        headers: userHeaders,
        body:    JSON.stringify({
          p_reservation_id:      reservation_id,
          p_mode:                mode,
          p_amount:              amountToRef,
          p_provider:            providerName,
          p_provider_payment_id: paymentId,
        }),
      });
      const claimData = await claimRes.json().catch(() => ({} as any));
      if (!claimRes.ok || claimData?.ok !== true) {
        const errCode = claimData?.error ?? 'claim_failed';
        const mapped = CLAIM_ERROR_MAP[errCode] ?? { status: 502, message: claimData?.error ?? 'No se pudo iniciar el reembolso' };
        console.error('[REFUND_CLAIM_REJECTED]', errCode, JSON.stringify(claimData));
        return jsonRes({ error: mapped.message, code: errCode }, mapped.status);
      }
      claimId = claimData.claim_id;
      console.log(`[REFUND_CLAIM_CREATED] claim=${claimId} reservation=${reservation_id} provider=${providerName} amount=$${amountToRef}`);
    }

    const idemKey = `claim-${claimId}`;
    const methodType = String((reservation as any).payment_method_type ?? '').toLowerCase();

    // ── Ruta MANUAL (SPEI/efectivo por Conekta) ───────────────────────
    // Sin HTTP a proveedor: el claim pasa a provider_succeeded de inmediato
    // (salvo que ya lo estuviera por un intento previo cuya contabilización
    // haya fallado — entonces solo se reintenta la parte de liquidación).
    const settleManual = async (apiError: string | null): Promise<Response> => {
      if (!reusedProviderSucceeded) {
        await markClaim(claimId, { status: 'provider_succeeded', provider_refund_id: 'manual-pending' });
      }

      let settleResult: any;
      if (mode === 'cancellation' || mode === 'group_cancellation') {
        const settleFn = mode === 'group_cancellation' ? 'settle_group_cancellation' : 'settle_cancellation';
        const r = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${settleFn}`, {
          method: 'POST', headers: serviceHeaders,
          body: JSON.stringify({ p_reservation_id: reservation_id, p_refund_id: 'manual-pending', p_claim_id: claimId }),
        });
        settleResult = await r.json();
      } else {
        const r = await fetch(`${SUPABASE_URL}/rest/v1/rpc/process_refund_reversal`, {
          method: 'POST', headers: serviceHeaders,
          body: JSON.stringify({
            p_reservation_id: reservation_id,
            p_mp_refund_id:   'manual-pending',
            p_refund_amount:  amountToRef,
            p_claim_id:       claimId,
          }),
        });
        settleResult = await r.json();
      }

      if (!settleResult?.ok) {
        console.error('[REFUND_ACCOUNTING_FAILED][manual]', JSON.stringify(settleResult));
        notifyAdminUrgent(
          '🚨 Reembolso manual: falló la contabilización',
          `La reserva ${reservation_id} quedó marcada como reembolso manual pero la liquidación en base de datos falló: ${settleResult?.error ?? 'desconocido'}. Reintentar el mismo request es seguro (no se duplica).`,
          { reservation_id, screen: 'AdminFinancial' },
        );
        return jsonRes({
          error: 'El reembolso manual quedó registrado pero no se pudo completar la contabilización interna. Reintenta — no se duplicará.',
          code:  'accounting_pending',
        }, 500);
      }
      if (settleResult.skipped) {
        await markClaim(claimId, { status: 'done' });
      }

      // Encolar el reembolso manual (idempotente: 1 por reserva)
      const { data: mr, error: mrErr } = await admin.rpc('create_manual_refund', {
        p_reservation_id: reservation_id,
        p_amount:         amountToRef,
        p_method:         ['spei', 'cash'].includes(methodType) ? methodType : 'unknown',
        p_clabe:          body.clabe ?? null,
        p_account_holder: body.account_holder ?? null,
        p_bank_name:      body.bank_name ?? null,
        p_api_error:      apiError,
      });
      if (mrErr || mr?.ok === false) {
        console.error('[REFUND_MANUAL] create_manual_refund falló:', mrErr?.message ?? JSON.stringify(mr));
        return jsonRes({ error: mr?.error ?? mrErr?.message ?? 'No se pudo registrar el reembolso manual' }, 500);
      }
      if (!settleResult.skipped) {
        await markClaim(claimId, { status: 'done' });
      }
      const dueDate = mr?.due_date ?? null;

      logPaymentEvent(paymentId, reservation_id, 'refund_manual_pending', amountToRef,
        `Reembolso manual ${methodType || 'unknown'} encolado (due ${dueDate})` +
        (apiError ? ` — API error original: ${apiError}` : ''));

      const last4 = body.clabe ? ` a tu cuenta terminación ${String(body.clabe).slice(-4)}` : '';
      const introTxt = mode === 'group_cancellation'
        ? 'El grupo canceló tu evento — recuperas el 100% de tu pago.'
        : 'Tu reserva fue cancelada.';
      const bankTxt = body.clabe
        ? `se enviará por transferencia bancaria${last4} en un máximo de 5 días hábiles.`
        : 'se enviará por transferencia bancaria en un máximo de 5 días hábiles — te contactaremos para confirmar tu cuenta.';
      await admin.from('notifications').insert({
        user_id: reservation.client_id,
        type:    'payment',
        title:   '💸 Reembolso en proceso',
        body:    `${introTxt} Como pagaste por ${methodType === 'cash' ? 'efectivo' : 'transferencia'}, tu reembolso de $${Number(amountToRef).toLocaleString('es-MX')} MXN ${bankTxt}`,
        data:    { reservation_id, screen: 'Reservations', manual_refund_id: mr?.id ?? null },
      });

      return jsonRes({
        ok: true, mode, provider: 'conekta', refund_mode: 'manual_pending',
        refund_id: null, amount: amountToRef, due_date: dueDate, reservation_id,
        breakdown: cancellationCharge,
      });
    };

    if (isConekta && ['spei', 'cash'].includes(methodType)) {
      return await settleManual(null);
    }

    // ── Emitir el reembolso según proveedor (se salta si ya se reusó un
    // claim que llegó a provider_succeeded en un intento anterior) ──────
    let refundId = '';

    if (reusedProviderSucceeded) {
      refundId = String(existingClaim.provider_refund_id ?? '');
      console.log(`[REFUND_REUSE_CLAIM] claim=${claimId} ya provider_succeeded, reintentando solo contabilización`);
    } else if (isStripe) {
      if (!stripeKey) return jsonRes({ error: 'STRIPE_SECRET_KEY no configurado' }, 500);

      const amountCentavos = Math.round(amountToRef * 100);
      const form = new URLSearchParams();
      form.set('payment_intent', paymentId);
      form.set('amount', String(amountCentavos));
      form.set('metadata[reservation_id]', reservation_id!);
      form.set('metadata[issued_by]', isAdmin ? 'admin' : mode === 'group_cancellation' ? 'group' : 'client');

      let stripeRes: Response;
      try {
        stripeRes = await fetch('https://api.stripe.com/v1/refunds', {
          method:  'POST',
          headers: {
            Authorization:     `Bearer ${stripeKey}`,
            'Content-Type':    'application/x-www-form-urlencoded',
            'Idempotency-Key': idemKey,
          },
          body: form,
        });
      } catch (netErr: any) {
        // Sin respuesta de Stripe. A diferencia de Conekta, SÍ es seguro
        // reintentar: la Idempotency-Key es estable (derivada del claim) y
        // Stripe garantiza no duplicar. Se deja el claim en 'processing'
        // (NO provider_failed) para que el siguiente intento reuse este
        // mismo claim y la misma key.
        console.error('[REFUND_NETWORK_ERROR] Stripe:', netErr?.message ?? netErr);
        await markClaim(claimId, { ambiguous_reason: `network_error: ${netErr?.message ?? netErr}` });
        return jsonRes({
          error: 'No se pudo confirmar la respuesta de Stripe — reintenta en unos segundos, es seguro (misma operación, no se duplica).',
          code:  'provider_timeout',
        }, 504);
      }

      const stripeData = await stripeRes.json() as any;

      if (!stripeRes.ok) {
        const errCode = String(stripeData?.error?.code ?? '');
        const msg = stripeData?.error?.message ?? 'Error al procesar reembolso en Stripe';
        console.error('[REFUND_ERROR] Stripe refund failed:', JSON.stringify(stripeData));

        // Ambiguo — NUNCA provider_failed, NUNCA reintento automático:
        //   · 5xx: error interno de Stripe, no hay garantía de que no haya
        //     alcanzado a procesar el refund antes de fallar (mismo
        //     razonamiento que ya se aplicaba a Conekta 5xx).
        //   · balance_insufficient: la cuenta de Stripe de la plataforma no
        //     tiene fondos — no es un rechazo del cliente ni algo que se
        //     resuelva reintentando, requiere que un admin fondee la cuenta.
        // Evidencia: docs.stripe.com/error-codes lista 'balance_insufficient'
        // como código real; docs.stripe.com/refunds confirma que refunds
        // fallidos exponen la razón en el status/decline — ninguno de los
        // dos casos es un rechazo "claro" equivalente a un 4xx de validación.
        const isBalanceIssue = errCode === 'balance_insufficient';
        if (stripeRes.status >= 500 || isBalanceIssue) {
          await markClaim(claimId, { needs_verification: true, ambiguous_reason: `stripe_${stripeRes.status}_${errCode || 'no_code'}: ${msg}` });
          notifyAdminUrgent(
            isBalanceIssue
              ? '🚨 Reembolso Stripe — fondos insuficientes en la cuenta'
              : '🚨 Reembolso Stripe — verificación manual requerida (5xx)',
            isBalanceIssue
              ? `Stripe rechazó el reembolso de la reserva ${reservation_id} por fondos insuficientes en la cuenta de la plataforma ($${amountToRef}). Se requiere fondear la cuenta antes de reintentar. Claim: ${claimId}.`
              : `Stripe respondió con error de servidor (${stripeRes.status}) al reembolsar la reserva ${reservation_id}. Verifica directamente en el dashboard de Stripe antes de reintentar. Claim: ${claimId}.`,
            { reservation_id, claim_id: claimId, screen: 'AdminFinancial' },
          );
          await admin.from('notifications').insert({
            user_id: reservation.client_id,
            type:    'payment',
            title:   '⏳ Verificando tu reembolso',
            body:    'Estamos confirmando tu reembolso con el proveedor de pago. Puede tardar unas horas — te avisamos en cuanto se confirme.',
            data:    { reservation_id, screen: 'Reservations' },
          });
          logPaymentEvent(paymentId, reservation_id, 'refund_failed', amountToRef,
            `Stripe ${stripeRes.status} ambiguo (${errCode || 'sin código'}, verificación pendiente): ${msg}`);
          return jsonRes({
            error: isBalanceIssue
              ? 'No se pudo procesar tu reembolso — requiere revisión administrativa antes de continuar.'
              : 'No pudimos confirmar la respuesta de Stripe — requiere verificación manual de un administrador antes de continuar.',
            code:  'refund_verification_pending',
          }, 504);
        }

        // 4xx claro — rechazo real de Stripe, no ambiguo (comportamiento sin cambios)
        await markClaim(claimId, { status: 'provider_failed', ambiguous_reason: msg });
        logPaymentEvent(paymentId, reservation_id, 'refund_failed', amountToRef, `Stripe: ${msg}`);
        return jsonRes({ error: msg, provider: 'stripe' }, 502);
      }

      refundId = String(stripeData.id);
      await markClaim(claimId, { status: 'provider_succeeded', provider_refund_id: refundId });
      console.log(`[REFUND_ISSUED] stripe_refund=${refundId} reservation=${reservation_id} amount=$${amountToRef} idem=${idemKey}`);

    } else if (isConekta) {
      if (!conektaKey) return jsonRes({ error: 'CONEKTA_PRIVATE_KEY no configurado' }, 500);
      const amountCentavos = Math.round(amountToRef * 100);
      const auth = btoa(`${conektaKey}:`);

      let ckRes: Response;
      try {
        ckRes = await fetch(`https://api.conekta.io/orders/${paymentId}/refunds`, {
          method:  'POST',
          headers: {
            'Accept':        'application/vnd.conekta-v2.1.0+json',
            'Content-Type':  'application/json',
            'Authorization': `Basic ${auth}`,
          },
          body: JSON.stringify({ reason: 'requested_by_client', amount: amountCentavos }),
        });
      } catch (netErr: any) {
        // Conekta NO tiene idempotency key oficial: no sabemos si el
        // refund se procesó del otro lado. NO se marca provider_failed
        // (podría re-intentarse y duplicar) ni provider_succeeded (no lo
        // confirmamos). Se marca needs_verification y el claim se queda
        // 'processing' — el índice único bloquea cualquier reintento
        // automático hasta que un admin verifique manualmente contra
        // Conekta y mueva el estado a mano.
        console.error('[REFUND_NETWORK_ERROR] Conekta:', netErr?.message ?? netErr);
        await markClaim(claimId, { needs_verification: true, ambiguous_reason: `network_error: ${netErr?.message ?? netErr}` });
        notifyAdminUrgent(
          '🚨 Reembolso Conekta — verificación manual requerida',
          `No se pudo confirmar si Conekta procesó el reembolso de la reserva ${reservation_id} (orden ${paymentId}, $${amountToRef}). Verifica directamente en el dashboard de Conekta antes de reintentar. Claim: ${claimId}.`,
          { reservation_id, claim_id: claimId, screen: 'AdminFinancial' },
        );
        await admin.from('notifications').insert({
          user_id: reservation.client_id,
          type:    'payment',
          title:   '⏳ Verificando tu reembolso',
          body:    'Estamos confirmando tu reembolso con el proveedor de pago. Puede tardar unas horas — te avisamos en cuanto se confirme.',
          data:    { reservation_id, screen: 'Reservations' },
        });
        return jsonRes({
          error: 'No se pudo confirmar si Conekta procesó el reembolso — requiere verificación manual de un administrador antes de continuar.',
          code:  'refund_verification_pending',
        }, 504);
      }

      const ckData = await ckRes.json() as any;
      if (!ckRes.ok) {
        const msg = ckData?.details?.[0]?.message ?? 'Error al procesar reembolso en Conekta';
        console.error('[REFUND_ERROR] Conekta refund failed:', JSON.stringify(ckData));

        if (ckRes.status >= 500) {
          // 5xx: Conekta SÍ respondió, pero con error de servidor — no hay
          // garantía de que no haya alcanzado a procesar el refund antes de
          // fallar. Mismo tratamiento conservador que "sin respuesta".
          await markClaim(claimId, { needs_verification: true, ambiguous_reason: `http_${ckRes.status}: ${msg}` });
          notifyAdminUrgent(
            '🚨 Reembolso Conekta — verificación manual requerida (5xx)',
            `Conekta respondió con error de servidor (${ckRes.status}) al reembolsar la reserva ${reservation_id}. Verifica directamente en el dashboard de Conekta antes de reintentar. Claim: ${claimId}.`,
            { reservation_id, claim_id: claimId, screen: 'AdminFinancial' },
          );
          await admin.from('notifications').insert({
            user_id: reservation.client_id,
            type:    'payment',
            title:   '⏳ Verificando tu reembolso',
            body:    'Estamos confirmando tu reembolso con el proveedor de pago. Puede tardar unas horas — te avisamos en cuanto se confirme.',
            data:    { reservation_id, screen: 'Reservations' },
          });
          logPaymentEvent(paymentId, reservation_id, 'refund_failed', amountToRef, `Conekta 5xx (verificación pendiente): ${msg}`);
          return jsonRes({
            error: 'Conekta respondió con un error de servidor — no podemos confirmar si el reembolso se procesó. Requiere verificación manual de un administrador.',
            code:  'refund_verification_pending',
          }, 504);
        }

        // 4xx: Conekta validó y rechazó ANTES de procesar — claramente no
        // se movió dinero. Seguro marcar provider_failed (libera el
        // candado para un reintento limpio con un nuevo claim).
        await markClaim(claimId, { status: 'provider_failed', ambiguous_reason: msg });
        logPaymentEvent(paymentId, reservation_id, 'refund_failed', amountToRef, `Conekta: ${msg}`);

        // Red de seguridad ya existente: método no reembolsable por API →
        // cola manual (el claim ya quedó provider_failed arriba; se abre
        // uno NUEVO propio del camino manual dentro de settleManual).
        if (methodType !== 'card') {
          console.warn('[REFUND_FALLBACK] método no reembolsable por API → cola manual');
          const manualClaim = await findActiveClaim();
          if (manualClaim) {
            claimId = manualClaim.id;
            reusedProviderSucceeded = manualClaim.status === 'provider_succeeded';
          } else {
            const claimRes2 = await fetch(`${SUPABASE_URL}/rest/v1/rpc/claim_reservation_refund`, {
              method: 'POST', headers: userHeaders,
              body: JSON.stringify({
                p_reservation_id: reservation_id, p_mode: mode, p_amount: amountToRef,
                p_provider: providerName, p_provider_payment_id: paymentId,
              }),
            });
            const claimData2 = await claimRes2.json().catch(() => ({} as any));
            if (claimData2?.ok !== true) {
              // No se pudo abrir un claim nuevo para el camino manual — NO
              // reusar el claimId viejo (ya quedó provider_failed arriba,
              // reusarlo lo regresaría incorrectamente a provider_succeeded).
              const errCode = claimData2?.error ?? 'claim_failed';
              const mapped = CLAIM_ERROR_MAP[errCode] ?? { status: 502, message: 'No se pudo iniciar el reembolso manual' };
              console.error('[REFUND_FALLBACK_CLAIM_REJECTED]', errCode, JSON.stringify(claimData2));
              return jsonRes({ error: mapped.message, code: errCode }, mapped.status);
            }
            claimId = claimData2.claim_id;
            reusedProviderSucceeded = false;
          }
          return await settleManual(msg);
        }
        return jsonRes({ error: msg, provider: 'conekta' }, 502);
      }

      refundId = String(ckData?.id ?? ckData?.charges?.data?.[0]?.id ?? `conekta-refund-${reservation_id}`);
      await markClaim(claimId, { status: 'provider_succeeded', provider_refund_id: refundId });
      console.log(`[REFUND_ISSUED] conekta_refund=${refundId} reservation=${reservation_id} amount=$${amountToRef}`);

    } else {
      // ── MercadoPago (legacy) ─────────────────────────────────────────
      let mpRefundRes: Response;
      try {
        mpRefundRes = await fetch(
          `https://api.mercadopago.com/v1/payments/${paymentId}/refunds`,
          {
            method:  'POST',
            headers: {
              Authorization:        `Bearer ${mpToken}`,
              'Content-Type':       'application/json',
              'X-Idempotency-Key':  idemKey,
            },
            body: JSON.stringify({ amount: amountToRef }),
          },
        );
      } catch (netErr: any) {
        // MercadoPago sí soporta X-Idempotency-Key oficialmente — mismo
        // razonamiento que Stripe: seguro reintentar reusando el claim.
        console.error('[REFUND_NETWORK_ERROR] MercadoPago:', netErr?.message ?? netErr);
        await markClaim(claimId, { ambiguous_reason: `network_error: ${netErr?.message ?? netErr}` });
        return jsonRes({
          error: 'No se pudo confirmar la respuesta de MercadoPago — reintenta en unos segundos, es seguro (misma operación, no se duplica).',
          code:  'provider_timeout',
        }, 504);
      }

      const mpRefund = await mpRefundRes.json() as any;

      if (!mpRefundRes.ok) {
        const msg = mpRefund?.message ?? 'Error al procesar reembolso en MercadoPago';
        console.error('[REFUND_ERROR] MP refund failed:', JSON.stringify(mpRefund));
        await markClaim(claimId, { status: 'provider_failed', ambiguous_reason: msg });
        logPaymentEvent(paymentId, reservation_id, 'refund_failed', amountToRef, `MP: ${msg}`);
        return jsonRes({ error: msg, provider: 'mercadopago' }, 502);
      }

      refundId = String(mpRefund.id);
      await markClaim(claimId, { status: 'provider_succeeded', provider_refund_id: refundId });
      console.log(`[REFUND_ISSUED] mp_refund_id=${refundId} reservation=${reservation_id} amount=$${amountToRef} idem=${idemKey}`);
    }

    // ── Liquidar en la BD (atómico via RPC, con p_claim_id) ───────────
    // cancellation → settle_cancellation. group_cancellation → settle_
    // group_cancellation. full → process_refund_reversal.
    let rpcResult: any;
    if (mode === 'cancellation' || mode === 'group_cancellation') {
      const settleFn = mode === 'group_cancellation' ? 'settle_group_cancellation' : 'settle_cancellation';
      const settleRes = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${settleFn}`, {
        method:  'POST',
        headers: serviceHeaders,
        body:    JSON.stringify({ p_reservation_id: reservation_id, p_refund_id: refundId, p_claim_id: claimId }),
      });
      rpcResult = await settleRes.json();
      console.log(`[${settleFn}]`, JSON.stringify(rpcResult));
    } else {
      const rpcRes = await fetch(`${SUPABASE_URL}/rest/v1/rpc/process_refund_reversal`, {
        method:  'POST',
        headers: serviceHeaders,
        body:    JSON.stringify({
          p_reservation_id: reservation_id,
          p_mp_refund_id:   refundId,
          p_refund_amount:  amountToRef,
          p_claim_id:       claimId,
        }),
      });
      rpcResult = await rpcRes.json();
      console.log('[process_refund_reversal]', JSON.stringify(rpcResult));
    }

    // ══ Verificación OBLIGATORIA del resultado del RPC. El proveedor YA
    // emitió el dinero en este punto — si la contabilización SQL falla,
    // NUNCA se vuelve a llamar al proveedor (el claim queda en
    // 'provider_succeeded', no 'done'); un reintento del mismo request
    // reusará este claim y solo reintentará esta liquidación. ══
    if (!rpcResult?.ok) {
      console.error('[REFUND_ACCOUNTING_FAILED] provider succeeded, DB settlement failed', JSON.stringify(rpcResult));
      logPaymentEvent(paymentId, reservation_id, 'refund_failed', amountToRef,
        `Proveedor reembolsó (${refundId}) pero la contabilización SQL falló: ${rpcResult?.error ?? 'unknown'} — reintentar es seguro, NO se volverá a cobrar al proveedor`);
      notifyAdminUrgent(
        '🚨 Reembolso emitido por el proveedor — contabilización pendiente',
        `El proveedor (${providerName}) ya reembolsó $${amountToRef} para la reserva ${reservation_id} (ref ${refundId}), pero la contabilización interna falló: ${rpcResult?.error ?? 'desconocido'}. Reintentar el mismo reembolso es seguro. Claim: ${claimId}.`,
        { reservation_id, claim_id: claimId, screen: 'AdminFinancial' },
      );
      return jsonRes({
        error: 'El reembolso se procesó con el proveedor pero no se pudo completar la contabilización interna. Reintenta — no se generará un doble reembolso.',
        code:  'accounting_pending',
        provider_refund_id: refundId,
      }, 500);
    }

    // El RPC marca el claim 'done' internamente SOLO en su camino principal
    // (no en el atajo de "ya estaba liquidado" / already_refunded /
    // already_settled — p.ej. si un webhook async de Stripe/MP ganó la
    // carrera). Si vino por ese atajo, el estado real SÍ está liquidado:
    // cerramos el claim aquí explícitamente para no dejarlo atorado.
    if (rpcResult.skipped) {
      await markClaim(claimId, { status: 'done' });
    }

    // ── Audit log ─────────────────────────────────────────────────────
    logPaymentEvent(
      paymentId, reservation_id, 'refund_issued', amountToRef,
      `Refund ${isStripe ? 'Stripe' : isConekta ? 'Conekta' : 'MP'}:${refundId} by ${isAdmin ? 'admin' : 'client'}(${callerId}) claim=${claimId}`,
    );

    // ── Notificar al cliente ──────────────────────────────────────────
    // mode='full' ya no notifica aquí: sql/539 movió esa notificación
    // DENTRO de process_refund_reversal (solo se dispara en su camino de
    // éxito real, nunca en `skipped` — evita el duplicado que existía
    // antes, donde este insert corría SIEMPRE que rpcResult.ok, sin
    // revisar rpcResult.skipped).
    // 'cancellation'/'group_cancellation' siguen notificando aquí (sus
    // RPC — sql/535c/538 — no se tocaron, según lo acordado), pero ahora
    // SÍ respetan `skipped` por la misma razón.
    if (mode !== 'full' && !rpcResult.skipped) {
      const resCurrency = (reservation as any).currency_code === 'USD' ? 'USD' : 'MXN';
      await admin.from('notifications').insert({
        user_id: reservation.client_id,
        type:    'payment',
        title:   '💸 Reembolso emitido',
        body:    (mode === 'group_cancellation'
          ? `El grupo canceló tu evento — recuperas el 100%. Se emitió un reembolso de $${Number(amountToRef).toLocaleString('es-MX')} ${resCurrency} a tu método de pago; aparecerá en tu cuenta en 3-10 días hábiles.`
          : `Se emitió un reembolso de $${Number(amountToRef).toLocaleString('es-MX')} ${resCurrency}. Aparecerá en tu cuenta en 3-10 días hábiles.`),
        data:    { reservation_id, screen: 'Reservations' },
      });
    }

    return jsonRes({
      ok:            true,
      mode,
      provider:      isStripe ? 'stripe' : isConekta ? 'conekta' : 'mercadopago',
      refund_id:     refundId,
      amount:        amountToRef,
      reservation_id,
      breakdown:     cancellationCharge,
    });

  } catch (e: unknown) {
    const msg = e instanceof Error ? e.message : 'Error interno';
    console.error('[process-refund] Error:', msg);
    return jsonRes({ error: msg }, 500);
  }
}

// import.meta.main es true SOLO cuando este archivo corre como entrypoint
// real (el runtime de Supabase Edge Functions lo carga así) — cuando lo
// importa index.test.ts, es false, así que las pruebas nunca levantan un
// servidor HTTP de verdad. Cero cambio de comportamiento en producción.
if (import.meta.main) {
  Deno.serve(handleRequest);
}
