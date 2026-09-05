// ═══════════════════════════════════════════════════════════════════
// create-mp-preference — DESACTIVADO (auditoría 2026-08-08). Stripe y
// Conekta son los únicos proveedores activos de Daricefy. Confirma que
// el corte ocurre ANTES de leer MERCADOPAGO_ACCESS_TOKEN, antes de crear
// el cliente de Supabase, antes de buscar la reserva y antes de crear
// cualquier preferencia de pago. CERO red real.
//
// Correr: deno test --allow-env --allow-read supabase/functions/create-mp-preference/index.test.ts
// ═══════════════════════════════════════════════════════════════════

import { assertEquals } from 'https://deno.land/std@0.208.0/testing/asserts.ts';

// Deliberadamente SIN SUPABASE_URL/SERVICE_KEY/MERCADOPAGO_ACCESS_TOKEN —
// si el guard no cortara primero, createClient('', '') u otra lectura
// fallaría de todas formas, pero queremos probar que ni siquiera se llega
// ahí: cualquier fetch real sería un fallo de la prueba (ver mock abajo).

function mockFetchThatThrowsOnAnyCall() {
  return async (input: string | URL): Promise<Response> => {
    const url = typeof input === 'string' ? input : input.toString();
    throw new Error(`[mockFetch] create-mp-preference está desactivado — NO debe llamar a nada, pero intentó: ${url}`);
  };
}

Deno.test('create-mp-preference: POST autenticado con reservation_id válido → provider_disabled, CERO red (ni Supabase ni MercadoPago)', async () => {
  const original = globalThis.fetch;
  globalThis.fetch = mockFetchThatThrowsOnAnyCall() as typeof fetch;
  try {
    const mod = await import(`./index.ts?t=${Date.now()}${Math.random()}`);
    const req = new Request('https://mock.local/create-mp-preference', {
      method: 'POST',
      headers: { Authorization: 'Bearer fake.jwt.token', 'Content-Type': 'application/json' },
      body: JSON.stringify({ reservation_id: 'res-1' }),
    });
    const res = await mod.handleRequest(req);
    const json = await res.json();
    assertEquals(json.error, 'Mercado Pago ya no es un proveedor activo de Daricefy.');
    assertEquals(json.code, 'provider_disabled');
  } finally {
    globalThis.fetch = original;
  }
});

Deno.test('create-mp-preference: sin Authorization header → igual corta en provider_disabled ANTES del chequeo de auth (el guard es lo primero)', async () => {
  const original = globalThis.fetch;
  globalThis.fetch = mockFetchThatThrowsOnAnyCall() as typeof fetch;
  try {
    const mod = await import(`./index.ts?t=${Date.now()}${Math.random()}`);
    const req = new Request('https://mock.local/create-mp-preference', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({}),
    });
    const res = await mod.handleRequest(req);
    const json = await res.json();
    assertEquals(json.code, 'provider_disabled');
  } finally {
    globalThis.fetch = original;
  }
});

Deno.test('create-mp-preference: OPTIONS (preflight CORS) sigue respondiendo normal', async () => {
  const original = globalThis.fetch;
  globalThis.fetch = mockFetchThatThrowsOnAnyCall() as typeof fetch;
  try {
    const mod = await import(`./index.ts?t=${Date.now()}${Math.random()}`);
    const req = new Request('https://mock.local/create-mp-preference', { method: 'OPTIONS' });
    const res = await mod.handleRequest(req);
    assertEquals(res.status, 200);
    assertEquals(await res.text(), 'ok');
  } finally {
    globalThis.fetch = original;
  }
});

console.log('\n[create-mp-preference disabled tests] listo — cero red real, cero secrets leídos.');
