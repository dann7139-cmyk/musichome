// ═══════════════════════════════════════════════════════════════════
// Guard compartido — evita que stripe-webhook / mercadopago-webhook
// apliquen la RPC contable EQUIVOCADA cuando ganan la carrera contra
// process-refund (P1F, ver sql/535*).
//
// process-refund SIEMPRE crea un provider_refund_claims ANTES de llamar
// al proveedor, con su `mode` correcto ('full' | 'cancellation' |
// 'group_cancellation'). Si el webhook del proveedor llega primero (o
// mientras process-refund sigue en vuelo) y solo conoce "hubo un
// refund", NO debe asumir que es un refund 'full' — debe consultar el
// claim y usar la MISMA semántica que process-refund habría usado.
//
// settle_cancellation / settle_group_cancellation recalculan el monto
// internamente (compute_cancellation_charge) — no dependen de un monto
// que el webhook les pase, así que basta con reservation_id + claim_id
// para completar la operación correcta de forma segura e idempotente
// (ambas RPC ya tienen su propio skip si status='cancelled' AND
// payout_status='refunded').
//
// SIN CLAIM → FAIL CLOSED (decisión 2026-08-08, ver reporte). Auditado:
// process-refund es la ÚNICA ruta en todo el código (frontend y Edge
// Functions) que llama a las APIs de refund de Stripe/Conekta/MP o a
// las 3 RPC de liquidación — y SIEMPRE crea el claim antes del HTTP al
// proveedor. Un webhook de refund sin claim solo puede venir de: (a) un
// refund emitido a mano fuera de la app (dashboard del proveedor,
// proceso administrativo externo), o (b) un webhook tardío/reintentado
// de una operación PRE-P1F cuyo modo real (full/cancellation/
// group_cancellation) no quedó registrado en ningún lado — incluyendo
// el caso conocido de reservas que el bug pre-P1F (rpcResult.ok nunca
// verificado) pudo haber dejado con el proveedor ya reembolsado pero la
// contabilización sin completar. En NINGUNO de estos casos hay forma de
// determinar el modo con certeza, así que NO se ejecuta ninguna RPC
// contable automáticamente: se registra en financial_audit_logs, se
// notifica al admin, y se responde 200 al proveedor (para no generar
// reintentos infinitos) sin mover wallet.
// ═══════════════════════════════════════════════════════════════════

export type ProviderName = 'stripe' | 'conekta' | 'mercadopago';

export type ClaimGuardResult =
  | { action: 'no_claim' }
  | { action: 'already_done'; claimId: string }
  | { action: 'run_full'; claimId: string }
  | { action: 'run_cancellation'; claimId: string; refundId: string | null }
  | { action: 'run_group_cancellation'; claimId: string; refundId: string | null };

/**
 * Busca el claim MÁS RECIENTE (cualquier estado) para (provider,
 * provider_payment_id) y decide qué debe hacer el webhook. Orden 100%
 * determinista: created_at DESC con id DESC como desempate explícito —
 * nunca depende del orden físico/por-defecto de PostgREST, ni siquiera
 * si dos claims llegaran a compartir el mismo created_at (p.ej. creados
 * en la misma transacción).
 */
export async function resolveRefundClaimAction(
  supabaseUrl: string,
  serviceKey: string,
  provider: ProviderName,
  providerPaymentId: string,
): Promise<ClaimGuardResult> {
  const headers = {
    Authorization: `Bearer ${serviceKey}`,
    apikey:        serviceKey,
    'Content-Type': 'application/json',
  };
  const url = `${supabaseUrl}/rest/v1/provider_refund_claims`
    + `?select=id,status,mode,provider_refund_id,created_at`
    + `&provider=eq.${encodeURIComponent(provider)}`
    + `&provider_payment_id=eq.${encodeURIComponent(providerPaymentId)}`
    + `&order=created_at.desc,id.desc&limit=1`;

  const res = await fetch(url, { headers });
  const rows = await res.json().catch(() => []) as any[];
  const claim = Array.isArray(rows) && rows.length ? rows[0] : null;

  if (!claim) return { action: 'no_claim' };
  if (claim.status === 'done') return { action: 'already_done', claimId: claim.id };
  if (claim.mode === 'cancellation') {
    return { action: 'run_cancellation', claimId: claim.id, refundId: claim.provider_refund_id ?? null };
  }
  if (claim.mode === 'group_cancellation') {
    return { action: 'run_group_cancellation', claimId: claim.id, refundId: claim.provider_refund_id ?? null };
  }
  return { action: 'run_full', claimId: claim.id };
}

export type ApplyOutcome =
  | { ok: true; skipped?: boolean; rpc: string; result: any }
  | { ok: false; rpc: string; result: any }
  | { ok: true; rpc: 'none_fail_closed'; result: { logged: boolean; notified: boolean } };

/**
 * Ejecuta la RPC correcta según lo que decidió resolveRefundClaimAction.
 * Para 'no_claim': FAIL CLOSED — NO se ejecuta ninguna RPC contable.
 * Se registra en financial_audit_logs y se notifica a los admins con
 * los datos suficientes para reconciliar manualmente (provider,
 * provider_payment_id, reservation_id, monto, referencia de refund).
 */
export async function applyRefundClaimAction(
  supabaseUrl: string,
  serviceKey: string,
  reservationId: string,
  fallbackRefundId: string | null,
  fallbackRefundAmount: number | null,
  decision: ClaimGuardResult,
  noClaimContext?: { provider: ProviderName; providerPaymentId: string },
): Promise<ApplyOutcome> {
  const headers = {
    Authorization: `Bearer ${serviceKey}`,
    apikey:        serviceKey,
    'Content-Type': 'application/json',
    Prefer:        'return=representation',
  };
  const call = async (fn: string, body: Record<string, unknown>): Promise<ApplyOutcome> => {
    const r = await fetch(`${supabaseUrl}/rest/v1/rpc/${fn}`, { method: 'POST', headers, body: JSON.stringify(body) });
    const result = await r.json().catch(() => ({}));
    const ok = r.ok && result?.ok !== false;
    return ok ? { ok: true, skipped: !!result?.skipped, rpc: fn, result } : { ok: false, rpc: fn, result };
  };

  switch (decision.action) {
    case 'already_done':
      // Defensivo: los webhooks ya filtran este caso antes de llamar
      // aquí (no ejecutan nada), pero si algún caller futuro no lo
      // hiciera, no debe moverse nada tampoco.
      return { ok: true, skipped: true, rpc: 'none_already_done', result: { claimId: decision.claimId } };
    case 'run_full':
      return call('process_refund_reversal', {
        p_reservation_id: reservationId,
        p_mp_refund_id:   fallbackRefundId,
        p_refund_amount:  fallbackRefundAmount,
        p_claim_id:       decision.claimId,
      });
    case 'run_cancellation':
      return call('settle_cancellation', {
        p_reservation_id: reservationId,
        p_refund_id:       decision.refundId ?? fallbackRefundId,
        p_claim_id:        decision.claimId,
      });
    case 'run_group_cancellation':
      return call('settle_group_cancellation', {
        p_reservation_id: reservationId,
        p_refund_id:       decision.refundId ?? fallbackRefundId,
        p_claim_id:        decision.claimId,
      });
    case 'no_claim': {
      const provider = noClaimContext?.provider ?? 'unknown';
      const providerPaymentId = noClaimContext?.providerPaymentId ?? 'unknown';
      const notes = `Webhook de ${provider} reportó un reembolso para provider_payment_id=${providerPaymentId} `
        + `(reserva ${reservationId}) SIN provider_refund_claims asociado — no se puede determinar con certeza si `
        + `es full/cancellation/group_cancellation. FAIL CLOSED: no se ejecutó ninguna RPC contable. `
        + `refund_ref=${fallbackRefundId ?? 'n/a'} amount=${fallbackRefundAmount ?? 'n/a'}. Requiere reconciliación manual.`;

      const auditRes = await fetch(`${supabaseUrl}/rest/v1/financial_audit_logs`, {
        method: 'POST', headers,
        body: JSON.stringify({
          entity_type: 'reservation', entity_id: reservationId,
          action: 'refund_webhook_no_claim', actor_role: 'system',
          amount: fallbackRefundAmount, notes,
        }),
      });
      const logged = auditRes.ok;

      const adminsRes = await fetch(`${supabaseUrl}/rest/v1/profiles?select=id&role=eq.admin`, { headers });
      const admins = await adminsRes.json().catch(() => []) as any[];
      let notified = false;
      if (Array.isArray(admins) && admins.length) {
        const notifRows = admins.map((a: any) => ({
          user_id: a.id, type: 'admin',
          title: '🚨 Reembolso recibido sin claim — requiere reconciliación',
          body:  `${provider} reportó un reembolso (ref ${fallbackRefundId ?? 'n/a'}, $${fallbackRefundAmount ?? '?'}) para la reserva ${reservationId} sin registro de claim. No se movió wallet automáticamente. Verifica y liquida manualmente.`,
          data:  { reservation_id: reservationId, provider, provider_payment_id: providerPaymentId, screen: 'AdminFinancial' },
        }));
        const notifRes = await fetch(`${supabaseUrl}/rest/v1/notifications`, {
          method: 'POST', headers, body: JSON.stringify(notifRows),
        });
        notified = notifRes.ok;
      }

      return { ok: true, rpc: 'none_fail_closed', result: { logged, notified } };
    }
  }
}
