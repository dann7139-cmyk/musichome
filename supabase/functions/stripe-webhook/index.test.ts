// ═══════════════════════════════════════════════════════════════════
// Prueba END-TO-END de stripe-webhook (no solo el guard compartido).
// Usa la firma REAL de Stripe (HMAC-SHA256, misma fórmula que
// stripe.webhooks.constructEventAsync verifica) construida localmente
// con Web Crypto — CERO llamadas reales a Stripe ni a Supabase: todo
// fetch queda interceptado por un mock que solo reconoce URLs propias
// y lanza si algo intenta salir a un dominio real no listado.
//
// Cobertura pedida por el usuario:
//  - firma Stripe válida (HMAC real, verificada por el SDK real)
//  - charge.refunded Y charge.refund.updated (las dos formas que el
//    código realmente consume)
//  - claim mode=full      → process_refund_reversal
//  - claim mode=cancellation     → settle_cancellation
//  - claim mode=group_cancellation → settle_group_cancellation
//  - claim status=done    → ninguna RPC
//  - sin claim             → FAIL CLOSED (punto 1 del reporte)
//  - firma inválida        → 401, cero RPC financiera
//
// Correr: deno test --allow-env --allow-net supabase/functions/stripe-webhook/index.test.ts
// ═══════════════════════════════════════════════════════════════════

import { assertEquals, assert } from 'https://deno.land/std@0.208.0/testing/asserts.ts';

Deno.env.set('SUPABASE_URL', 'https://mock.supabase.co');
Deno.env.set('SUPABASE_SERVICE_ROLE_KEY', 'mock-service-key');
Deno.env.set('STRIPE_SECRET_KEY', 'sk_test_mock_not_real');
const WEBHOOK_SECRET = 'whsec_test_mock_secret_for_local_signature_only';
Deno.env.set('STRIPE_WEBHOOK_SECRET', WEBHOOK_SECRET);

// ── Firma Stripe real (misma fórmula que usa el SDK para verificar) ──
async function buildStripeSignature(payload: string, secret: string, timestamp: number): Promise<string> {
  const signedPayload = `${timestamp}.${payload}`;
  const key = await crypto.subtle.importKey(
    'raw', new TextEncoder().encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign'],
  );
  const sigBuf = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(signedPayload));
  const sigHex = Array.from(new Uint8Array(sigBuf)).map((b) => b.toString(16).padStart(2, '0')).join('');
  return `t=${timestamp},v1=${sigHex}`;
}

function chargeRefundedEvent(piId: string, chargeId: string, refundId: string, amountCentavos: number) {
  return {
    id: 'evt_test_1', object: 'event', api_version: '2023-10-16', created: Math.floor(Date.now() / 1000),
    livemode: false, pending_webhooks: 1, request: { id: null, idempotency_key: null },
    type: 'charge.refunded',
    data: {
      object: {
        id: chargeId, object: 'charge', payment_intent: piId, amount_refunded: amountCentavos,
        refunds: { object: 'list', data: [{ id: refundId, amount: amountCentavos, payment_intent: piId }] },
      },
    },
  };
}

function chargeRefundUpdatedEvent(piId: string, refundId: string, amountCentavos: number) {
  // charge.refund.updated: el objeto del evento ES el refund directo (no un charge envolvente).
  return {
    id: 'evt_test_2', object: 'event', api_version: '2023-10-16', created: Math.floor(Date.now() / 1000),
    livemode: false, pending_webhooks: 1, request: { id: null, idempotency_key: null },
    type: 'charge.refund.updated',
    data: {
      object: { id: refundId, object: 'refund', payment_intent: piId, amount: amountCentavos },
    },
  };
}

type MockClaim = { id: string; status: string; mode: string; provider_refund_id: string | null };
type Captured = { rpcCalls: { fn: string; body: any }[]; auditInsert?: any; notifInsert?: any; claimsQueried: number; unrecognized: string[] };

function acceptsSingle(init?: RequestInit): boolean {
  const h = new Headers(init?.headers ?? {});
  return h.get('accept') === 'application/vnd.pgrst.object+json';
}

function mockFetch(opts: { reservation: { id: string; total_price: number } | null; claims: MockClaim[] }, cap: Captured) {
  return async (input: string | URL, init?: RequestInit): Promise<Response> => {
    const url = typeof input === 'string' ? input : input.toString();
    const json = (obj: unknown, status = 200) => new Response(JSON.stringify(obj), { status, headers: { 'Content-Type': 'application/json' } });

    if (url.includes('/rest/v1/reservations')) {
      if (!opts.reservation) return acceptsSingle(init) ? new Response('', { status: 406 }) : json([]);
      return acceptsSingle(init) ? json(opts.reservation) : json([opts.reservation]);
    }
    if (url.includes('/rest/v1/provider_refund_claims')) {
      cap.claimsQueried++;
      return json(opts.claims.slice(0, 1));
    }
    if (url.includes('/rest/v1/financial_audit_logs')) {
      cap.auditInsert = init?.body ? JSON.parse(init.body as string) : null;
      return json([{ id: 'audit-1' }], 201);
    }
    if (url.includes('/rest/v1/profiles') && url.includes('role=eq.admin')) {
      return json([{ id: 'admin-1' }, { id: 'admin-2' }]);
    }
    if (url.includes('/rest/v1/notifications')) {
      cap.notifInsert = init?.body ? JSON.parse(init.body as string) : null;
      return json([{ id: 'n1' }], 201);
    }
    if (url.includes('/rpc/')) {
      const fn = url.split('/rpc/')[1];
      const body = init?.body ? JSON.parse(init.body as string) : {};
      cap.rpcCalls.push({ fn, body });
      return json({ ok: true });
    }
    cap.unrecognized.push(url);
    throw new Error(`[mockFetch] URL fuera del allow-list — posible fuga a red real: ${url}`);
  };
}

async function runWebhook(body: string, sig: string, opts: { reservation: { id: string; total_price: number } | null; claims: MockClaim[] }) {
  const original = globalThis.fetch;
  const cap: Captured = { rpcCalls: [], claimsQueried: 0, unrecognized: [] };
  globalThis.fetch = mockFetch(opts, cap) as typeof fetch;
  try {
    const { handleRequest } = await import(`./index.ts?t=${Date.now()}${Math.random()}`);
    const req = new Request('https://mock.local/stripe-webhook', {
      method: 'POST', headers: { 'stripe-signature': sig }, body,
    });
    const res = await handleRequest(req);
    await new Promise((r) => setTimeout(r, 20));
    return { res, cap };
  } finally {
    globalThis.fetch = original;
  }
}

// ═══════════════ Firma válida — enrutamiento por modo ═══════════════

Deno.test({
  name: 'stripe-webhook: firma válida + charge.refunded + claim mode=full → process_refund_reversal',
  // El SDK de Stripe arranca un interval interno por cada `new Stripe(...)`
  // (una instancia por request, como en producción) que el sanitizador de
  // recursos de Deno marca como "leak" aunque no sea un bug de este código
  // — comportamiento conocido del SDK, no de la lógica que se está probando.
  sanitizeResources: false,
  sanitizeOps: false,
  fn: async () => {
    const payload = JSON.stringify(chargeRefundedEvent('pi_full_1', 'ch_full_1', 're_full_1', 100000));
    const ts = Math.floor(Date.now() / 1000);
    const sig = await buildStripeSignature(payload, WEBHOOK_SECRET, ts);

    const { res, cap } = await runWebhook(payload, sig, {
      reservation: { id: 'res-full-1', total_price: 1000 },
      claims: [{ id: 'claim-full-1', status: 'processing', mode: 'full', provider_refund_id: null }],
    });

    assertEquals(res.status, 200);
    assertEquals(cap.rpcCalls.length, 1);
    assertEquals(cap.rpcCalls[0].fn, 'process_refund_reversal');
    assertEquals(cap.rpcCalls[0].body.p_claim_id, 'claim-full-1');
    assertEquals(cap.rpcCalls[0].body.p_reservation_id, 'res-full-1');
  },
});

Deno.test({
  name: 'stripe-webhook: firma válida + charge.refund.updated (refund directo) + claim mode=cancellation → settle_cancellation',
  sanitizeResources: false,
  sanitizeOps: false,
  fn: async () => {
    const payload = JSON.stringify(chargeRefundUpdatedEvent('pi_canc_1', 're_canc_1', 30000));
    const ts = Math.floor(Date.now() / 1000);
    const sig = await buildStripeSignature(payload, WEBHOOK_SECRET, ts);

    const { res, cap } = await runWebhook(payload, sig, {
      reservation: { id: 'res-canc-1', total_price: 1000 },
      claims: [{ id: 'claim-canc-1', status: 'provider_succeeded', mode: 'cancellation', provider_refund_id: 're_canc_1' }],
    });

    assertEquals(res.status, 200);
    assertEquals(cap.rpcCalls.length, 1);
    assertEquals(cap.rpcCalls[0].fn, 'settle_cancellation');
    assertEquals(cap.rpcCalls[0].body.p_claim_id, 'claim-canc-1');
    assert(!cap.rpcCalls.some((c) => c.fn === 'process_refund_reversal'), 'NUNCA debe usar la RPC genérica cuando el claim es de cancelación');
  },
});

Deno.test({
  name: 'stripe-webhook: firma válida + charge.refunded + claim mode=group_cancellation → settle_group_cancellation',
  sanitizeResources: false,
  sanitizeOps: false,
  fn: async () => {
    const payload = JSON.stringify(chargeRefundedEvent('pi_gc_1', 'ch_gc_1', 're_gc_1', 50000));
    const ts = Math.floor(Date.now() / 1000);
    const sig = await buildStripeSignature(payload, WEBHOOK_SECRET, ts);

    const { res, cap } = await runWebhook(payload, sig, {
      reservation: { id: 'res-gc-1', total_price: 2000 },
      claims: [{ id: 'claim-gc-1', status: 'processing', mode: 'group_cancellation', provider_refund_id: null }],
    });

    assertEquals(res.status, 200);
    assertEquals(cap.rpcCalls.length, 1);
    assertEquals(cap.rpcCalls[0].fn, 'settle_group_cancellation');
    assertEquals(cap.rpcCalls[0].body.p_claim_id, 'claim-gc-1');
  },
});

Deno.test({
  name: 'stripe-webhook: claim status=done → idempotente, CERO RPC contable (ni la genérica ni las de settle)',
  sanitizeResources: false,
  sanitizeOps: false,
  fn: async () => {
    const payload = JSON.stringify(chargeRefundedEvent('pi_done_1', 'ch_done_1', 're_done_1', 100000));
    const ts = Math.floor(Date.now() / 1000);
    const sig = await buildStripeSignature(payload, WEBHOOK_SECRET, ts);

    const { res, cap } = await runWebhook(payload, sig, {
      reservation: { id: 'res-done-1', total_price: 1000 },
      claims: [{ id: 'claim-done-1', status: 'done', mode: 'full', provider_refund_id: 're_done_1' }],
    });

    assertEquals(res.status, 200);
    assertEquals(cap.claimsQueried, 1, 'sí debe consultar el claim para saber que ya está done');
    assertEquals(cap.rpcCalls.length, 0, 'claim done → no debe tocar ninguna RPC contable');
  },
});

// ═══════════════ Sin claim → FAIL CLOSED (punto 1 del reporte) ═══════════════

Deno.test({
  name: 'stripe-webhook: SIN claim → FAIL CLOSED: cero RPC contable, sí financial_audit_logs + notificación admin, reserva NO se pierde',
  sanitizeResources: false,
  sanitizeOps: false,
  fn: async () => {
    const payload = JSON.stringify(chargeRefundedEvent('pi_noclaim_1', 'ch_noclaim_1', 're_noclaim_1', 75000));
    const ts = Math.floor(Date.now() / 1000);
    const sig = await buildStripeSignature(payload, WEBHOOK_SECRET, ts);

    const { res, cap } = await runWebhook(payload, sig, {
      reservation: { id: 'res-noclaim-1', total_price: 750 },
      claims: [], // sin ningún claim para este provider_payment_id
    });

    assertEquals(res.status, 200);
    assertEquals(cap.rpcCalls.length, 0, 'sin claim → CERO RPC contable, ni siquiera process_refund_reversal');
    assert(cap.auditInsert, 'debe quedar registrado en financial_audit_logs');
    assertEquals(cap.auditInsert.action, 'refund_webhook_no_claim');
    assertEquals(cap.auditInsert.entity_id, 'res-noclaim-1');
    assertEquals(cap.auditInsert.amount, 750); // 75000 centavos / 100
    assert(cap.auditInsert.notes.includes('pi_noclaim_1'), 'las notas deben incluir el payment_intent para reconciliar');
    assert(cap.auditInsert.notes.includes('stripe'), 'las notas deben identificar el proveedor');
    assert(Array.isArray(cap.notifInsert) && cap.notifInsert.length === 2, 'debe notificar a TODOS los admins encontrados');
  },
});

// ═══════════════ Firma inválida → rechazo total ═══════════════

Deno.test({
  name: 'stripe-webhook: firma inválida → 401, CERO llamadas a Supabase (ni claims, ni RPC, ni auditoría)',
  sanitizeResources: false,
  sanitizeOps: false,
  fn: async () => {
    const payload = JSON.stringify(chargeRefundedEvent('pi_bad_sig', 'ch_bad_sig', 're_bad_sig', 100000));
    const badSig = 't=1700000000,v1=' + '0'.repeat(64); // hex válido en forma, pero HMAC incorrecto

    const { res, cap } = await runWebhook(payload, badSig, {
      reservation: { id: 'res-bad-sig-1', total_price: 1000 },
      claims: [{ id: 'claim-x', status: 'processing', mode: 'full', provider_refund_id: null }],
    });

    assertEquals(res.status, 401);
    assertEquals(cap.rpcCalls.length, 0);
    assertEquals(cap.claimsQueried, 0, 'con firma inválida no debe siquiera llegar a consultar el claim');
    assertEquals(cap.auditInsert, undefined);
    assertEquals(cap.notifInsert, undefined);
    assertEquals(cap.unrecognized.length, 0, 'no debe haber intentado salir a ninguna URL no reconocida');
  },
});

Deno.test({
  name: 'stripe-webhook: header stripe-signature ausente → 401, CERO llamadas a Supabase',
  sanitizeResources: false,
  sanitizeOps: false,
  fn: async () => {
    const payload = JSON.stringify(chargeRefundedEvent('pi_no_sig', 'ch_no_sig', 're_no_sig', 100000));
    const { res, cap } = await runWebhook(payload, '', {
      reservation: { id: 'res-no-sig-1', total_price: 1000 },
      claims: [],
    });
    assertEquals(res.status, 401);
    assertEquals(cap.rpcCalls.length, 0);
    assertEquals(cap.claimsQueried, 0);
  },
});

console.log('\n[stripe-webhook end-to-end tests] listo — firma real verificada por el SDK real, cero red real.');
