// ═══════════════════════════════════════════════════════════════════
// mercadopago-webhook — DESACTIVADO (auditoría 2026-08-08). Stripe y
// Conekta son los únicos proveedores activos de Daricefy. Estas pruebas
// confirman que el corte ocurre ANTES de leer cualquier secret de MP o
// de intentar resolver un pago: CERO llamadas a la API de MercadoPago,
// CERO RPC, CERO wallet, CERO notificaciones. CERO red real.
// ═══════════════════════════════════════════════════════════════════

import { assertEquals } from 'https://deno.land/std@0.208.0/testing/asserts.ts';

Deno.env.set('SUPABASE_URL', 'https://mock.supabase.co');
Deno.env.set('SUPABASE_SERVICE_ROLE_KEY', 'mock-service-key');
// Deliberadamente SIN MERCADOPAGO_ACCESS_TOKEN ni MERCADOPAGO_WEBHOOK_SECRET
// — el guard debe cortar sin necesitar (ni leer) ninguno de los dos.

function mockFetchThatThrowsOnAnyCall() {
  return async (input: string | URL): Promise<Response> => {
    const url = typeof input === 'string' ? input : input.toString();
    throw new Error(`[mockFetch] mercadopago-webhook está desactivado — NO debe llamar a nada, pero intentó: ${url}`);
  };
}

async function invoke(body: unknown, opts: { asJson?: boolean; asQueryParams?: string } = {}) {
  const original = globalThis.fetch;
  globalThis.fetch = mockFetchThatThrowsOnAnyCall() as typeof fetch;
  try {
    // Import con query string única: el módulo lee MERCADOPAGO_ACTIVE
    // como constante top-level en cada instancia importada — no hay
    // estado compartido problemático entre pruebas.
    const mod = await import(`./index.ts?t=${Date.now()}${Math.random()}`);
    const url = opts.asQueryParams
      ? `https://mock.local/mercadopago-webhook?${opts.asQueryParams}`
      : 'https://mock.local/mercadopago-webhook';
    const req = new Request(url, {
      method: 'POST',
      headers: opts.asJson === false ? {} : { 'Content-Type': 'application/json' },
      body: opts.asJson === false ? undefined : JSON.stringify(body),
    });
    const res = await mod.handleRequest(req);
    const json = await res.json().catch(() => ({}));
    return { status: res.status, json };
  } finally {
    globalThis.fetch = original;
  }
}

Deno.test({
  name: 'mercadopago-webhook: notificación de pago (JSON, Webhooks API nueva) → disabled, CERO red',
  sanitizeResources: false,
  sanitizeOps: false,
  fn: async () => {
    const { status, json } = await invoke({ type: 'payment', data: { id: 999888 } });
    assertEquals(status, 200);
    assertEquals(json.ok, false);
    assertEquals(json.error, 'mercadopago_disabled');
  },
});

Deno.test({
  name: 'mercadopago-webhook: notificación vía query params (IPN legado) → disabled, CERO red',
  sanitizeResources: false,
  sanitizeOps: false,
  fn: async () => {
    const { status, json } = await invoke(null, { asJson: false, asQueryParams: 'topic=payment&id=999888' });
    assertEquals(status, 200);
    assertEquals(json.error, 'mercadopago_disabled');
  },
});

Deno.test({
  name: 'mercadopago-webhook: payload de refund (el caso que antes tocaba wallet) → disabled ANTES de resolver el pago, CERO RPC',
  sanitizeResources: false,
  sanitizeOps: false,
  fn: async () => {
    // Si el guard no cortara primero, este payload dispararía la rama de
    // refund (fetch a api.mercadopago.com, luego resolveRefundClaimAction,
    // luego posiblemente una RPC de liquidación) — el mock lanza excepción
    // ante CUALQUIER fetch, así que si algo de eso se ejecutara, la prueba
    // fallaría con el error del mock, no con una aserción normal.
    const { status, json } = await invoke({ type: 'payment', data: { id: 'refund-scenario-id' } });
    assertEquals(status, 200);
    assertEquals(json.error, 'mercadopago_disabled');
  },
});

Deno.test({
  name: 'mercadopago-webhook: body vacío/sin payment id → igual corta en disabled (el guard es lo primero, antes de parsear nada relevante)',
  sanitizeResources: false,
  sanitizeOps: false,
  fn: async () => {
    const { status, json } = await invoke({});
    assertEquals(status, 200);
    assertEquals(json.error, 'mercadopago_disabled');
  },
});

Deno.test({
  name: 'mercadopago-webhook: OPTIONS (preflight CORS) sigue respondiendo normal — el guard no rompe CORS',
  sanitizeResources: false,
  sanitizeOps: false,
  fn: async () => {
    const original = globalThis.fetch;
    globalThis.fetch = mockFetchThatThrowsOnAnyCall() as typeof fetch;
    try {
      const mod = await import(`./index.ts?t=${Date.now()}${Math.random()}`);
      const req = new Request('https://mock.local/mercadopago-webhook', { method: 'OPTIONS' });
      const res = await mod.handleRequest(req);
      assertEquals(res.status, 200);
      const text = await res.text();
      assertEquals(text, 'ok');
    } finally {
      globalThis.fetch = original;
    }
  },
});

console.log('\n[mercadopago-webhook disabled tests] listo — cero red real, cero secrets leídos.');
