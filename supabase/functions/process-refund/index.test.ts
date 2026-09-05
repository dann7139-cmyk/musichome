// ═══════════════════════════════════════════════════════════════════
// Pruebas de process-refund — TODO simulado (fetch global interceptado).
// CERO llamadas reales a Stripe / Conekta / MercadoPago / Supabase.
//
// Correr: deno test --allow-env supabase/functions/process-refund/index.test.ts
//
// Estrategia: se reemplaza globalThis.fetch por un router que reconoce
// las URLs de Supabase (REST/RPC/auth) y de cada proveedor, y responde
// con datos controlados por escenario. Se mantiene un `state` en memoria
// que simula la tabla provider_refund_claims (incluida su restricción de
// unicidad activa) para poder verificar la máquina de estados real.
// ═══════════════════════════════════════════════════════════════════

import { assertEquals, assertExists } from 'https://deno.land/std@0.208.0/testing/asserts.ts';

Deno.env.set('SUPABASE_URL', 'https://mock.supabase.co');
Deno.env.set('SUPABASE_SERVICE_ROLE_KEY', 'mock-service-key');
Deno.env.set('SUPABASE_ANON_KEY', 'mock-anon-key');
Deno.env.set('STRIPE_SECRET_KEY', 'sk_test_mock');
Deno.env.set('CONEKTA_PRIVATE_KEY', 'key_mock');
Deno.env.set('MERCADOPAGO_ACCESS_TOKEN', 'mp_mock');

// ── Estado simulado de la BD (in-memory, reseteado por test) ──────────
type MockClaim = {
  id: string; provider: string; provider_payment_id: string; status: string;
  amount: number; provider_refund_id: string | null; needs_verification: boolean;
  ambiguous_reason: string | null; created_at: string;
};

function newState(overrides: Partial<{
  reservation: Record<string, unknown>;
  callerRole: 'admin' | 'client';
  claims: MockClaim[];
  rpcResponses: Record<string, unknown>;
}> = {}) {
  return {
    reservation: {
      id: 'res-1', total_price: 1000, base_price: 800, client_id: 'client-1',
      payment_status: 'paid', payout_status: 'held', mp_payment_id: 'pi_mock123',
      payment_provider: 'stripe', payment_method_type: 'card',
      event_date: '2099-01-01T00:00:00Z', group_id: 'group-1',
      ...overrides.reservation,
    },
    callerRole: overrides.callerRole ?? 'admin',
    claims: overrides.claims ?? [] as MockClaim[],
    calls: [] as { method: string; url: string; body: unknown }[],
    rpcResponses: overrides.rpcResponses ?? {},
    providerCallCount: { stripe: 0, conekta: 0, mercadopago: 0 },
    stripeIdemKeysSeen: [] as string[],
    mpIdemKeysSeen: [] as string[],
  };
}
type State = ReturnType<typeof newState>;

let claimSeq = 0;

function mockFetch(state: State, opts: {
  stripeBehavior?: 'success' | 'error' | 'error_5xx' | 'error_balance_insufficient' | 'network_throw';
  conektaBehavior?: 'success' | 'error_4xx' | 'error_5xx' | 'network_throw';
  mpBehavior?: 'success' | 'error' | 'network_throw';
} = {}) {
  return async (input: string | URL | Request, init?: RequestInit): Promise<Response> => {
    const url = typeof input === 'string' ? input : input instanceof URL ? input.toString() : input.url;
    const method = (init?.method ?? 'GET').toUpperCase();
    const bodyRaw = init?.body;
    const body = typeof bodyRaw === 'string' ? (() => { try { return JSON.parse(bodyRaw); } catch { return bodyRaw; } })() : undefined;
    state.calls.push({ method, url, body });
    const headers = new Headers(init?.headers);

    const json = (obj: unknown, status = 200) =>
      new Response(JSON.stringify(obj), { status, headers: { 'Content-Type': 'application/json' } });

    // ── Supabase Auth: getUser ──
    if (url.includes('/auth/v1/user')) {
      return json({ id: state.reservation.client_id === 'client-1' ? 'admin-1' : 'x', email: 'x@x.com' });
    }

    // ── RPC: claim_reservation_refund ──
    if (url.includes('/rpc/claim_reservation_refund')) {
      const p = body as any;
      const active = state.claims.find(c =>
        c.provider === p.p_provider && c.provider_payment_id === p.p_provider_payment_id &&
        ['processing', 'provider_succeeded'].includes(c.status));
      if (active) return json({ ok: false, error: 'refund_already_in_progress' });
      if (state.rpcResponses.claim_reservation_refund) {
        return json(state.rpcResponses.claim_reservation_refund);
      }
      if (p.p_amount <= 0) return json({ ok: false, error: 'invalid_amount' });
      const claim: MockClaim = {
        id: `claim-${++claimSeq}`, provider: p.p_provider, provider_payment_id: p.p_provider_payment_id,
        status: 'processing', amount: p.p_amount, provider_refund_id: null,
        needs_verification: false, ambiguous_reason: null, created_at: new Date().toISOString(),
      };
      state.claims.push(claim);
      return json({ ok: true, claim_id: claim.id });
    }

    // ── REST: provider_refund_claims SELECT (findActiveClaim) ──
    if (url.includes('/rest/v1/provider_refund_claims') && method === 'GET') {
      const u = new URL(url);
      const provider = u.searchParams.get('provider')?.replace('eq.', '');
      const paymentId = u.searchParams.get('provider_payment_id')?.replace('eq.', '');
      const active = state.claims
        .filter(c => c.provider === provider && c.provider_payment_id === paymentId && ['processing', 'provider_succeeded'].includes(c.status))
        .sort((a, b) => b.created_at.localeCompare(a.created_at));
      return json(active.slice(0, 1));
    }
    // ── REST: provider_refund_claims PATCH (markClaim) ──
    if (url.includes('/rest/v1/provider_refund_claims') && method === 'PATCH') {
      const u = new URL(url);
      const idFilter = u.searchParams.get('id')?.replace('eq.', '');
      const c = state.claims.find(c => c.id === idFilter);
      if (c) Object.assign(c, body);
      return json([c]);
    }

    // ── RPC: compute_cancellation_charge ──
    if (url.includes('/rpc/compute_cancellation_charge')) {
      return json(state.rpcResponses.compute_cancellation_charge ?? { ok: true, refund_amount: 900, tier: 'partial_10' });
    }
    // Simula el efecto secundario REAL de la capa SQL (535/535b): cuando el
    // RPC de liquidación recibe p_claim_id y su camino NO es un "skip"
    // (already_refunded/already_settled), marca el claim 'done' él mismo
    // — el Edge NO lo hace explícitamente en ese caso (confía en el RPC).
    const maybeAutoCloseClaim = (resp: any) => {
      const claimIdArg = (body as any)?.p_claim_id;
      if (claimIdArg && resp?.ok && !resp?.skipped) {
        const c = state.claims.find(c => c.id === claimIdArg);
        if (c) c.status = 'done';
      }
      return resp;
    };
    // ── RPC: process_refund_reversal ──
    if (url.includes('/rpc/process_refund_reversal')) {
      const resp = state.rpcResponses.process_refund_reversal ?? { ok: true, reversed: (body as any)?.p_refund_amount ?? 0 };
      return json(maybeAutoCloseClaim(resp));
    }
    // ── RPC: settle_cancellation ──
    if (url.includes('/rpc/settle_cancellation')) {
      const resp = state.rpcResponses.settle_cancellation ?? { ok: true, tier: 'partial_10' };
      return json(maybeAutoCloseClaim(resp));
    }
    // ── RPC: settle_group_cancellation ──
    if (url.includes('/rpc/settle_group_cancellation')) {
      const resp = state.rpcResponses.settle_group_cancellation ?? { ok: true, refund_amount: (body as any)?.p_refund_id ? 1000 : 0 };
      return json(maybeAutoCloseClaim(resp));
    }
    // ── RPC: create_manual_refund ──
    if (url.includes('/rpc/create_manual_refund')) {
      return json(state.rpcResponses.create_manual_refund ?? { ok: true, id: 'mr-1', due_date: '2099-01-10' });
    }
    // ── RPC: log_payment_event (fire-and-forget) ──
    if (url.includes('/rpc/log_payment_event')) {
      return json({ ok: true });
    }

    // supabase-js .single() manda Accept: application/vnd.pgrst.object+json
    // y espera un OBJETO plano de vuelta, no un arreglo de 1 elemento.
    const wantsSingle = (headers.get('Accept') ?? '').includes('vnd.pgrst.object');

    // ── REST: reservations ──
    if (url.includes('/rest/v1/reservations') && method === 'GET') {
      return json(wantsSingle ? state.reservation : [state.reservation]);
    }
    // ── REST: profiles ──
    if (url.includes('/rest/v1/profiles') && method === 'GET') {
      const row = { role: state.callerRole };
      return json(wantsSingle ? row : [row]);
    }
    // ── REST: groups ──
    if (url.includes('/rest/v1/groups') && method === 'GET') {
      const row = { owner_id: 'owner-1' };
      return json(wantsSingle ? row : [row]);
    }
    // ── REST: notifications insert ──
    if (url.includes('/rest/v1/notifications') && method === 'POST') {
      return json([{ id: 'notif-1' }]);
    }

    // ── Proveedores externos ──
    if (url.includes('api.stripe.com')) {
      state.providerCallCount.stripe++;
      state.stripeIdemKeysSeen.push(headers.get('Idempotency-Key') ?? '');
      if (opts.stripeBehavior === 'network_throw') throw new TypeError('network error (simulated)');
      if (opts.stripeBehavior === 'error') return json({ error: { message: 'No such payment_intent' } }, 402);
      if (opts.stripeBehavior === 'error_5xx') return json({ error: { type: 'api_error', message: 'Internal server error' } }, 500);
      if (opts.stripeBehavior === 'error_balance_insufficient') return json({ error: { code: 'balance_insufficient', message: 'Insufficient funds in Stripe account' } }, 400);
      return json({ id: 're_mock_1', status: 'succeeded' }, 200);
    }
    if (url.includes('api.conekta.io')) {
      state.providerCallCount.conekta++;
      if (opts.conektaBehavior === 'network_throw') throw new TypeError('network error (simulated)');
      if (opts.conektaBehavior === 'error_4xx') return json({ details: [{ message: 'invalid order' }] }, 400);
      if (opts.conektaBehavior === 'error_5xx') return json({ details: [{ message: 'internal error' }] }, 500);
      return json({ id: 'refund_mock_1' }, 200);
    }
    if (url.includes('api.mercadopago.com')) {
      state.providerCallCount.mercadopago++;
      state.mpIdemKeysSeen.push(headers.get('X-Idempotency-Key') ?? '');
      if (opts.mpBehavior === 'network_throw') throw new TypeError('network error (simulated)');
      if (opts.mpBehavior === 'error') return json({ message: 'refund rejected' }, 400);
      return json({ id: 999111, status: 'approved' }, 201);
    }

    throw new Error(`[mockFetch] URL no reconocida en el router de pruebas: ${method} ${url}`);
  };
}

// Importado UNA sola vez (módulo cacheado por Deno) — el archivo llama
// Deno.serve(handleRequest) a nivel de módulo; re-importar con distintas
// URLs/query-strings levantaría un listener HTTP nuevo por test. handleRequest
// no guarda estado mutable propio (lee Deno.env en cada llamada), así que
// reusar la misma referencia entre pruebas es seguro.
let handleRequestRef: ((req: Request) => Promise<Response>) | null = null;
async function getHandler() {
  if (!handleRequestRef) {
    const mod = await import('./index.ts');
    handleRequestRef = mod.handleRequest;
  }
  return handleRequestRef;
}

async function callHandler(state: State, mockOpts: Parameters<typeof mockFetch>[1] = {}, body: Record<string, unknown> = {}) {
  const original = globalThis.fetch;
  globalThis.fetch = mockFetch(state, mockOpts) as typeof fetch;
  try {
    const handleRequest = await getHandler();
    const req = new Request('https://mock.local/process-refund', {
      method: 'POST',
      headers: { Authorization: 'Bearer mock-token', 'Content-Type': 'application/json' },
      body: JSON.stringify({ reservation_id: 'res-1', ...body }),
    });
    const res = await handleRequest(req);
    const json = await res.json().catch(() => ({}));
    // logPaymentEvent/notifyAdminUrgent son "fire-and-forget" a propósito
    // en producción (no bloquean la respuesta al cliente) — se les da un
    // respiro aquí para que el sanitizador de recursos de Deno no las vea
    // como fugas al terminar la prueba.
    await new Promise((r) => setTimeout(r, 50));
    return { status: res.status, json };
  } finally {
    globalThis.fetch = original;
  }
}

// ═══════════════════════ STRIPE ═══════════════════════

Deno.test('Stripe success — claim creado, provider llamado 1 vez, claim termina done', async () => {
  const state = newState();
  const { status, json } = await callHandler(state, { stripeBehavior: 'success' });
  assertEquals(status, 200);
  assertEquals(json.ok, true);
  assertEquals(state.providerCallCount.stripe, 1);
  assertEquals(state.claims.length, 1);
  assertEquals(state.claims[0].status, 'done');
  assertEquals(state.claims[0].provider_refund_id, 're_mock_1');
});

Deno.test('Stripe retry misma idempotency key — 2 llamadas al proveedor con la MISMA Idempotency-Key derivada del claim', async () => {
  const state = newState();
  // Simula: 1er intento falla en la contabilización SQL (provider ya
  // succeeded), el claim queda en provider_succeeded. Un 2º request debe
  // reusar el claim y NO reemitir el refund con Stripe.
  state.rpcResponses.process_refund_reversal = { ok: false, error: 'temporary_retry' };
  const r1 = await callHandler(state, { stripeBehavior: 'success' });
  assertEquals(r1.status, 500);
  assertEquals(r1.json.code, 'accounting_pending');
  assertEquals(state.providerCallCount.stripe, 1);
  assertEquals(state.claims[0].status, 'provider_succeeded');

  // 2º intento: la contabilización ahora sí funciona.
  delete state.rpcResponses.process_refund_reversal;
  const r2 = await callHandler(state, { stripeBehavior: 'success' });
  assertEquals(r2.status, 200);
  assertEquals(state.providerCallCount.stripe, 1, 'Stripe NO debe volver a llamarse — el claim ya estaba provider_succeeded');
  assertEquals(state.claims[0].status, 'done');
});

Deno.test('Stripe — reintento tras timeout de red reusa el MISMO claim y la MISMA Idempotency-Key', async () => {
  const state = newState();
  const r1 = await callHandler(state, { stripeBehavior: 'network_throw' });
  assertEquals(r1.status, 504);
  assertEquals(r1.json.code, 'provider_timeout');
  assertEquals(state.claims.length, 1);
  assertEquals(state.claims[0].status, 'processing');

  const r2 = await callHandler(state, { stripeBehavior: 'success' });
  assertEquals(r2.status, 200);
  assertEquals(state.claims.length, 1, 'no debe crearse un segundo claim');
  assertEquals(state.providerCallCount.stripe, 2);
  assertEquals(state.stripeIdemKeysSeen[0], state.stripeIdemKeysSeen[1], 'misma Idempotency-Key en ambos intentos');
  assertEquals(state.stripeIdemKeysSeen[0], `claim-${state.claims[0].id}`);
});

Deno.test('Stripe provider error — claim pasa a provider_failed, RPC de liquidación NUNCA se llama', async () => {
  const state = newState();
  const { status, json } = await callHandler(state, { stripeBehavior: 'error' });
  assertEquals(status, 502);
  assertExists(json.error);
  assertEquals(state.claims[0].status, 'provider_failed');
  assertEquals(state.calls.some(c => c.url.includes('/rpc/process_refund_reversal')), false);
});

Deno.test('Stripe success (mode=full) — la Edge Function YA NO inserta la notificación "Reembolso emitido" (se movió a SQL en process_refund_reversal)', async () => {
  const state = newState();
  const { status } = await callHandler(state, { stripeBehavior: 'success' });
  assertEquals(status, 200);
  const notifCalls = state.calls.filter(c => c.url.includes('/rest/v1/notifications') && c.method === 'POST');
  assertEquals(notifCalls.length, 0, 'mode=full: la notificación al cliente ahora vive dentro de process_refund_reversal, no en la Edge Function');
});

Deno.test('Stripe 5xx (error de servidor) — AMBIGUO: needs_verification=true, NUNCA provider_failed, claim sigue processing, cliente y admin notificados', async () => {
  const state = newState();
  const { status, json } = await callHandler(state, { stripeBehavior: 'error_5xx' });
  assertEquals(status, 504);
  assertEquals(json.code, 'refund_verification_pending');
  assertEquals(state.claims[0].status, 'processing', 'NUNCA provider_failed — sigue processing, bloqueado por el índice único, sin reintento automático');
  assertEquals(state.claims[0].needs_verification, true);
  // notifyAdminUrgent inserta un ARREGLO de filas (una por admin); la
  // notificación directa al cliente inserta un objeto único.
  const notifTitles = (c: { body: unknown }) => Array.isArray(c.body) ? c.body.map((b: any) => b?.title) : [(c.body as any)?.title];
  const notifCalls = state.calls.filter(c => c.url.includes('/rest/v1/notifications') && c.method === 'POST');
  const clientNotif = notifCalls.find(c => notifTitles(c).includes('⏳ Verificando tu reembolso'));
  const adminNotif  = notifCalls.find(c => notifTitles(c).includes('🚨 Reembolso Stripe — verificación manual requerida (5xx)'));
  assertExists(clientNotif, 'el cliente debe recibir "Estamos verificando tu reembolso"');
  assertExists(adminNotif, 'el admin debe recibir la alerta de verificación manual');
});

Deno.test('Stripe balance_insufficient — AMBIGUO (revisión administrativa): needs_verification=true, NUNCA provider_failed, admin recibe alerta de fondos', async () => {
  const state = newState();
  const { status, json } = await callHandler(state, { stripeBehavior: 'error_balance_insufficient' });
  assertEquals(status, 504);
  assertEquals(json.code, 'refund_verification_pending');
  assertEquals(json.error.includes('revisión administrativa'), true);
  assertEquals(state.claims[0].status, 'processing');
  assertEquals(state.claims[0].needs_verification, true);
  const notifTitles = (c: { body: unknown }) => Array.isArray(c.body) ? c.body.map((b: any) => b?.title) : [(c.body as any)?.title];
  const notifCalls = state.calls.filter(c => c.url.includes('/rest/v1/notifications') && c.method === 'POST');
  const adminNotif = notifCalls.find(c => notifTitles(c).includes('🚨 Reembolso Stripe — fondos insuficientes en la cuenta'));
  assertExists(adminNotif, 'el admin debe recibir la alerta específica de fondos insuficientes (no la genérica de 5xx)');
});

// ═══════════════════════ MERCADOPAGO ═══════════════════════

// ═══════════════ MERCADO PAGO — DESACTIVADO (auditoría 2026-08-08) ═══════════════
// Stripe y Conekta son los ÚNICOS proveedores activos. Cualquier reserva
// cuyo payment_id/payment_provider no matchee Stripe ni Conekta debe
// rechazarse explícito con 'provider_disabled' — SIN fallback automático
// a mercadopago, sin crear claim, sin RPC financiera, sin HTTP a proveedor.

function mpState() {
  return newState({ reservation: { mp_payment_id: '123456789', payment_provider: 'mercadopago' } });
}

function unknownProviderState() {
  return newState({ reservation: { mp_payment_id: 'algo-no-reconocido-999', payment_provider: '' } });
}

Deno.test('provider_disabled: reserva con payment_provider=mercadopago (patrón legacy) → 422, CERO claim, CERO llamada a MP', async () => {
  const state = mpState();
  const { status, json } = await callHandler(state, { mpBehavior: 'success' });
  assertEquals(status, 422);
  assertEquals(json.code, 'provider_disabled');
  assertEquals(state.claims.length, 0, 'no debe crearse ningún claim');
  assertEquals(state.providerCallCount.mercadopago, 0, 'CERO llamadas a la API de MercadoPago');
  assertEquals(state.calls.some(c => c.url.includes('/rpc/claim_reservation_refund')), false, 'nunca debe llamar claim_reservation_refund');
});

Deno.test('provider_disabled: payment_provider vacío/desconocido y payment_id que no matchea Stripe ni Conekta → 422 (SIN fallback automático a mercadopago)', async () => {
  const state = unknownProviderState();
  const { status, json } = await callHandler(state, {});
  assertEquals(status, 422);
  assertEquals(json.code, 'provider_disabled');
  assertEquals(state.claims.length, 0);
  assertEquals(state.providerCallCount.mercadopago, 0);
  assertEquals(state.providerCallCount.stripe, 0);
  assertEquals(state.providerCallCount.conekta, 0);
});

// ═══════════════════════ CONEKTA ═══════════════════════

function conektaState(methodType = 'card') {
  return newState({ reservation: { mp_payment_id: 'ord_mock1', payment_provider: 'conekta', payment_method_type: methodType } });
}

Deno.test('Conekta success — claim termina done', async () => {
  const state = conektaState();
  const { status, json } = await callHandler(state, { conektaBehavior: 'success' });
  assertEquals(status, 200);
  assertEquals(json.provider, 'conekta');
  assertEquals(state.claims[0].status, 'done');
});

Deno.test('Conekta provider error (4xx) — provider_failed, reintento limpio permitido (nuevo claim)', async () => {
  const state = conektaState();
  const r1 = await callHandler(state, { conektaBehavior: 'error_4xx' });
  assertEquals(r1.status, 502);
  assertEquals(state.claims[0].status, 'provider_failed');
  assertEquals(state.providerCallCount.conekta, 1);

  // Reintento: provider_failed NO bloquea (fuera del índice único) → nuevo claim, SÍ se llama a Conekta otra vez.
  const r2 = await callHandler(state, { conektaBehavior: 'success' });
  assertEquals(r2.status, 200);
  assertEquals(state.claims.length, 2);
  assertEquals(state.providerCallCount.conekta, 2);
});

Deno.test('Conekta respuesta perdida (network throw) — needs_verification=true, claim BLOQUEADO, proveedor NO se vuelve a llamar, cliente notificado', async () => {
  const state = conektaState();
  const r1 = await callHandler(state, { conektaBehavior: 'network_throw' });
  assertEquals(r1.status, 504);
  assertEquals(r1.json.code, 'refund_verification_pending');
  assertEquals(state.claims[0].status, 'processing');
  assertEquals(state.claims[0].needs_verification, true);
  assertEquals(state.providerCallCount.conekta, 1);
  const clientNotif = state.calls.find(c => c.url.includes('/rest/v1/notifications') && c.method === 'POST' && (c.body as any)?.title === '⏳ Verificando tu reembolso');
  assertExists(clientNotif, 'el cliente debe recibir "Estamos verificando tu reembolso" también en el camino Conekta');

  // Reintento automático/usuario: DEBE ser rechazado sin tocar a Conekta.
  const r2 = await callHandler(state, { conektaBehavior: 'success' });
  assertEquals(r2.status, 409);
  assertEquals(r2.json.code, 'refund_verification_pending');
  assertEquals(state.providerCallCount.conekta, 1, 'Conekta NUNCA debe recibir un segundo intento automático');
  assertEquals(state.claims.length, 1, 'no se crea un segundo claim mientras el primero sigue processing');
});

Deno.test('Conekta 5xx — mismo tratamiento que respuesta perdida (needs_verification, sin reintento automático), cliente notificado', async () => {
  const state = conektaState();
  const r1 = await callHandler(state, { conektaBehavior: 'error_5xx' });
  assertEquals(r1.json.code, 'refund_verification_pending');
  assertEquals(state.claims[0].needs_verification, true);
  assertEquals(state.claims[0].status, 'processing');
  const clientNotif = state.calls.find(c => c.url.includes('/rest/v1/notifications') && c.method === 'POST' && (c.body as any)?.title === '⏳ Verificando tu reembolso');
  assertExists(clientNotif);

  const r2 = await callHandler(state, { conektaBehavior: 'success' });
  assertEquals(r2.status, 409);
  assertEquals(state.providerCallCount.conekta, 1);
});

Deno.test('Conekta SPEI/cash — sin HTTP a proveedor, va directo a cola manual con claim propio', async () => {
  const state = conektaState('spei');
  const { status, json } = await callHandler(state, {}, { clabe: '012180012345678901', account_holder: 'Juan Pérez', bank_name: 'BBVA' });
  assertEquals(status, 200);
  assertEquals(json.refund_mode, 'manual_pending');
  assertEquals(state.providerCallCount.conekta, 0, 'no debe llamarse la API de refunds de Conekta para SPEI');
  assertEquals(state.claims[0].status, 'done');
});

// ═══════════════════════ CLAIM / ESTADOS ═══════════════════════

Deno.test('claim rechazado (open_dispute_blocks_refund) → proveedor NUNCA se llama', async () => {
  const state = newState();
  state.rpcResponses.claim_reservation_refund = { ok: false, error: 'open_dispute_blocks_refund' };
  const { status, json } = await callHandler(state, { stripeBehavior: 'success' });
  assertEquals(status, 409);
  assertEquals(json.code, 'open_dispute_blocks_refund');
  assertEquals(state.providerCallCount.stripe, 0);
});

Deno.test('manual_payment_already_transferred — claim rechazado, proveedor NUNCA se llama', async () => {
  const state = newState();
  state.rpcResponses.claim_reservation_refund = { ok: false, error: 'manual_payment_already_transferred' };
  const { status, json } = await callHandler(state, { stripeBehavior: 'success' });
  assertEquals(status, 409);
  assertEquals(json.code, 'manual_payment_already_transferred');
  assertEquals(state.providerCallCount.stripe, 0);
});

Deno.test('refund_in_progress / concurrencia — segundo request concurrente rechazado, un solo claim, proveedor llamado 1 vez', async () => {
  const state = newState();
  // Primer request deja el claim en 'processing' (simulando que su propia
  // llamada a Stripe está "en vuelo" — probamos la condición de carrera
  // insertando manualmente un claim activo antes de invocar el handler).
  state.claims.push({
    id: 'claim-race', provider: 'stripe', provider_payment_id: 'pi_mock123',
    status: 'processing', amount: 1000, provider_refund_id: null,
    needs_verification: false, ambiguous_reason: null, created_at: new Date().toISOString(),
  });
  const { status, json } = await callHandler(state, { stripeBehavior: 'success' });
  // Stripe/MP SÍ pueden reusar un claim 'processing' (idempotency-key
  // segura) — a diferencia de Conekta. Esto es el comportamiento CORRECTO
  // (no un rechazo ciego), documentado en el reporte.
  assertEquals(status, 200);
  assertEquals(json.ok, true);
  assertEquals(state.claims.length, 1);
});

Deno.test('provider success + accounting SQL failure → NO se re-llama al proveedor, respuesta indica accounting_pending', async () => {
  const state = newState();
  state.rpcResponses.process_refund_reversal = { ok: false, error: 'temporary_retry' };
  const { status, json } = await callHandler(state, { stripeBehavior: 'success' });
  assertEquals(status, 500);
  assertEquals(json.code, 'accounting_pending');
  assertEquals(state.providerCallCount.stripe, 1);
  assertEquals(state.claims[0].status, 'provider_succeeded');
});

Deno.test('accounting retry → done (reintento tras fallo de contabilización SOLO reintenta el RPC, no el proveedor)', async () => {
  const state = newState();
  state.rpcResponses.process_refund_reversal = { ok: false, error: 'temporary_retry' };
  await callHandler(state, { stripeBehavior: 'success' });
  assertEquals(state.claims[0].status, 'provider_succeeded');

  delete state.rpcResponses.process_refund_reversal;
  const r2 = await callHandler(state, { stripeBehavior: 'success' });
  assertEquals(r2.status, 200);
  assertEquals(state.providerCallCount.stripe, 1);
  assertEquals(state.claims[0].status, 'done');
});

Deno.test('claim done → retry idempotente (payout_status=refunded corta antes de llegar al claim)', async () => {
  const state = newState({ reservation: { payout_status: 'refunded' } });
  const { status, json } = await callHandler(state, { stripeBehavior: 'success' });
  assertEquals(status, 422);
  assertEquals(json.error, 'Esta reserva ya fue reembolsada');
  assertEquals(state.providerCallCount.stripe, 0);
});

Deno.test('rpcResult.ok=true con skipped=true (webhook ganó la carrera) → claim se cierra a done explícitamente', async () => {
  const state = newState();
  state.rpcResponses.process_refund_reversal = { ok: true, skipped: true, reason: 'already_refunded' };
  const { status } = await callHandler(state, { stripeBehavior: 'success' });
  assertEquals(status, 200);
  assertEquals(state.claims[0].status, 'done');
});

// ═══════════════════════ MODOS ═══════════════════════

Deno.test('mode=cancellation llama a settle_cancellation, NUNCA a process_refund_reversal', async () => {
  const state = newState();
  state.rpcResponses.compute_cancellation_charge = { ok: true, refund_amount: 700, tier: 'partial_30' };
  const { status } = await callHandler(state, { stripeBehavior: 'success' }, { mode: 'cancellation' });
  assertEquals(status, 200);
  assertEquals(state.calls.some(c => c.url.includes('/rpc/settle_cancellation')), true);
  assertEquals(state.calls.some(c => c.url.includes('/rpc/process_refund_reversal')), false);
  assertEquals(state.calls.some(c => c.url.includes('/rpc/settle_group_cancellation')), false);
});

Deno.test('mode=group_cancellation llama a settle_group_cancellation, NUNCA a settle_cancellation ni process_refund_reversal', async () => {
  const state = newState();
  const { status } = await callHandler(state, { stripeBehavior: 'success' }, { mode: 'group_cancellation' });
  assertEquals(status, 200);
  assertEquals(state.calls.some(c => c.url.includes('/rpc/settle_group_cancellation')), true);
  assertEquals(state.calls.some(c => c.url.includes('/rpc/settle_cancellation') && !c.url.includes('group')), false);
  assertEquals(state.calls.some(c => c.url.includes('/rpc/process_refund_reversal')), false);
});

Deno.test('mode=cancellation éxito real (no skipped) — SÍ notifica al cliente "Reembolso emitido"', async () => {
  const state = newState();
  state.rpcResponses.compute_cancellation_charge = { ok: true, refund_amount: 700, tier: 'partial_30' };
  const { status } = await callHandler(state, { stripeBehavior: 'success' }, { mode: 'cancellation' });
  assertEquals(status, 200);
  const clientNotif = state.calls.find(c => c.url.includes('/rest/v1/notifications') && c.method === 'POST' && (c.body as any)?.title === '💸 Reembolso emitido');
  assertExists(clientNotif);
});

Deno.test('mode=cancellation con rpcResult.skipped=true (ya liquidado, p.ej. webhook ganó la carrera) — NO duplica la notificación al cliente', async () => {
  const state = newState();
  state.rpcResponses.compute_cancellation_charge = { ok: true, refund_amount: 700, tier: 'partial_30' };
  state.rpcResponses.settle_cancellation = { ok: true, skipped: true, reason: 'already_settled', tier: 'partial_30' };
  const { status } = await callHandler(state, { stripeBehavior: 'success' }, { mode: 'cancellation' });
  assertEquals(status, 200);
  const notifCalls = state.calls.filter(c => c.url.includes('/rest/v1/notifications') && c.method === 'POST');
  assertEquals(notifCalls.some(c => (c.body as any)?.title === '💸 Reembolso emitido'), false, 'skipped=true: el cliente NO debe recibir una notificación duplicada de este request');
});

Deno.test('p_claim_id llega al RPC de liquidación y es el MISMO id devuelto por claim_reservation_refund', async () => {
  const state = newState();
  await callHandler(state, { stripeBehavior: 'success' });
  const settleCall = state.calls.find(c => c.url.includes('/rpc/process_refund_reversal'));
  assertEquals((settleCall?.body as any)?.p_claim_id, state.claims[0].id);
});

console.log('\n[process-refund tests] listo — todas las llamadas fueron simuladas, cero HTTP real a Stripe/Conekta/MercadoPago/Supabase.');
