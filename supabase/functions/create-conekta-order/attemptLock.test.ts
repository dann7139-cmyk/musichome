// ═══════════════════════════════════════════════════════════════════
// attemptLock.test.ts — pruebas de concurrencia del mecanismo de
// exclusión de create-conekta-order.
//
// Ejecutar con:  deno test supabase/functions/create-conekta-order/attemptLock.test.ts
//
// El mock simula la BD real con un objeto mutable compartido. Cada
// método del mock es `async` pero NO hace ningún `await` antes de leer
// y escribir `row` — por eso el compare-and-swap se ejecuta de un tirón
// dentro de un solo microtask de JS, sin que otra promesa concurrente
// pueda intercalarse a la mitad. Esto reproduce fielmente la garantía
// real de Postgres: los UPDATE concurrentes sobre la MISMA fila se
// serializan por el row lock — como mucho uno de ellos ve la condición
// WHERE cumplida. La atomicidad de una sola fila ya estáademostrada
// por separado con curl/PostgREST reales en la Preview Branch (F2.2
// gate, guiones A/B/C); aquí se prueba el ALGORITMO de claimAttempt(),
// no la primitiva de Postgres en la que se apoya.
// ═══════════════════════════════════════════════════════════════════

import { assertEquals, assert } from 'https://deno.land/std@0.208.0/assert/mod.ts';
import { claimAttempt, type AttemptRow, type AttemptStore } from './attemptLock.ts';

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
let idSeq = 0;

function makeMockStore() {
  let row: AttemptRow | null = null;
  let insertAttempts = 0;

  const store: AttemptStore = {
    async insertCreating() {
      insertAttempts++;
      if (row) return null; // simula el UNIQUE(provider, client_key)
      row = { id: `mock_${++idSeq}`, status: 'creating', provider_order_id: null, updated_at: new Date().toISOString() };
      return { ...row };
    },
    async read() {
      return row ? { ...row } : null;
    },
    async casFromAbandonedToCreating(id) {
      if (row && row.id === id && row.status === 'abandoned') {
        row = { ...row, status: 'creating', updated_at: new Date().toISOString() };
        return { ...row };
      }
      return null;
    },
    async casFromStaleCreatingToCreating(id, staleBeforeIso) {
      if (row && row.id === id && row.status === 'creating' && row.updated_at < staleBeforeIso) {
        row = { ...row, updated_at: new Date().toISOString() };
        return { ...row };
      }
      return null;
    },
    async finalizeCreated(id, providerOrderId) {
      if (row && row.id === id) row = { ...row, status: 'created', provider_order_id: providerOrderId };
    },
    async markAbandoned(id) {
      if (row && row.id === id) row = { ...row, status: 'abandoned', updated_at: new Date().toISOString() };
    },
  };

  return {
    store,
    _debug: () => ({ row, insertAttempts }),
    _seedStaleCreating(ageMs: number) {
      row = { id: `mock_${++idSeq}`, status: 'creating', provider_order_id: null,
              updated_at: new Date(Date.now() - ageMs).toISOString() };
      return row;
    },
  };
}

// ── T1: doble clic exacto — exactamente UNA llamada al proveedor ────
Deno.test('doble clic: orders.create se llama exactamente una vez; la otra reutiliza', async () => {
  const { store } = makeMockStore();
  let externalCalls = 0;

  async function simulateRequest(): Promise<'own-created' | 'reused' | 'conflict'> {
    const claim = await claimAttempt(store, { pollMs: 5, maxWaitMs: 500, staleMs: 5000 });
    if (claim.kind === 'own') {
      externalCalls++;
      await sleep(20); // simula la latencia real de la API de Conekta
      await store.finalizeCreated(claim.row.id, 'ord_test_doble_clic');
      return 'own-created';
    }
    if (claim.kind === 'reuse') return 'reused';
    return 'conflict';
  }

  const results = (await Promise.all([simulateRequest(), simulateRequest()])).sort();

  assertEquals(externalCalls, 1, 'orders.create NUNCA debe llamarse más de una vez');
  assertEquals(results, ['own-created', 'reused']);
});

// ── T2: tres invocaciones concurrentes (triple clic / 3 pestañas) ───
Deno.test('tres invocaciones concurrentes: exactamente una crea, ninguna llamada duplicada', async () => {
  const { store } = makeMockStore();
  let externalCalls = 0;

  async function simulateRequest() {
    const claim = await claimAttempt(store, { pollMs: 5, maxWaitMs: 800, staleMs: 5000 });
    if (claim.kind === 'own') {
      externalCalls++;
      await sleep(15);
      await store.finalizeCreated(claim.row.id, 'ord_test_triple');
      return 'own';
    }
    return claim.kind;
  }

  const results = await Promise.all([simulateRequest(), simulateRequest(), simulateRequest()]);

  assertEquals(externalCalls, 1);
  assertEquals(results.filter((r) => r === 'own').length, 1);
  assertEquals(results.filter((r) => r === 'reuse').length, 2);
});

// ── T3: intento atascado ('creating' viejo) permite takeover ────────
Deno.test('intento atascado (creating stale): otro invocador puede tomar el control', async () => {
  const { store, _seedStaleCreating } = makeMockStore();
  _seedStaleCreating(60_000); // 60s de antigüedad simulada — muy por encima del staleMs de la prueba

  const claim = await claimAttempt(store, { pollMs: 5, maxWaitMs: 500, staleMs: 50 });

  assertEquals(claim.kind, 'own', 'debe poder tomar el control de un intento atascado');
});

Deno.test('creating FRESCO (no stale): NO se permite takeover — se espera hasta el deadline', async () => {
  const { store, _seedStaleCreating } = makeMockStore();
  _seedStaleCreating(0); // recién creado

  const claim = await claimAttempt(store, { pollMs: 10, maxWaitMs: 60, staleMs: 5000 });

  assertEquals(claim.kind, 'conflict', 'un creating fresco no debe poder tomarse — solo esperar');
});

// ── T4: estado 'abandoned' → reintento seguro INMEDIATO ─────────────
Deno.test('abandoned permite reintento inmediato, sin esperar el timeout de stale', async () => {
  const { store } = makeMockStore();
  const inserted = await store.insertCreating();
  await store.markAbandoned(inserted!.id);

  const t0 = Date.now();
  // staleMs deliberadamente ENORME: si el código esperara el timeout de
  // stale para un 'abandoned', esta prueba tardaría segundos y fallaría
  // por el assert de tiempo de abajo.
  const claim = await claimAttempt(store, { pollMs: 5, maxWaitMs: 2000, staleMs: 20_000 });
  const elapsedMs = Date.now() - t0;

  assertEquals(claim.kind, 'own');
  assert(elapsedMs < 200, `abandoned debe tomarse casi de inmediato (tardó ${elapsedMs}ms)`);
});

// ── T5: si el dueño nunca termina, el que espera recibe 'conflict' ──
// (nunca crea una orden en paralelo solo porque el dueño se demoró)
Deno.test('dueño que nunca finaliza: el que espera recibe conflict, jamás crea en paralelo', async () => {
  const { store } = makeMockStore();
  let externalCalls = 0;

  async function ownerThatNeverFinishes() {
    const claim = await claimAttempt(store, { pollMs: 5, maxWaitMs: 100_000, staleMs: 100_000 });
    if (claim.kind === 'own') externalCalls++; // deliberadamente NO llama finalizeCreated
  }
  async function waiter() {
    return await claimAttempt(store, { pollMs: 5, maxWaitMs: 60, staleMs: 100_000 });
  }

  const [, waiterResult] = await Promise.all([ownerThatNeverFinishes(), waiter()]);

  assertEquals(externalCalls, 1);
  assertEquals(waiterResult.kind, 'conflict');
});

// ── T6: recuperación tras 'abandoned' bajo carrera — solo UNO gana el takeover
Deno.test('carrera sobre un intento abandoned: solo uno de dos releedores gana el takeover', async () => {
  const { store } = makeMockStore();
  const inserted = await store.insertCreating();
  await store.markAbandoned(inserted!.id);

  let externalCalls = 0;
  async function simulateRetry() {
    const claim = await claimAttempt(store, { pollMs: 5, maxWaitMs: 500, staleMs: 20_000 });
    if (claim.kind === 'own') {
      externalCalls++;
      await sleep(15);
      await store.finalizeCreated(claim.row.id, 'ord_test_retry');
      return 'own';
    }
    return claim.kind;
  }

  const results = await Promise.all([simulateRetry(), simulateRetry()]);

  assertEquals(externalCalls, 1, 'el takeover de un abandoned también debe ser exclusivo');
  assertEquals(results.filter((r) => r === 'own').length, 1);
});

// ── T7: stress — 10 invocaciones concurrentes, siempre exactamente 1 creación
Deno.test('stress: 10 invocaciones concurrentes → exactamente 1 llamada externa', async () => {
  const { store } = makeMockStore();
  let externalCalls = 0;

  async function simulateRequest() {
    const claim = await claimAttempt(store, { pollMs: 5, maxWaitMs: 1000, staleMs: 5000 });
    if (claim.kind === 'own') {
      externalCalls++;
      await sleep(25);
      await store.finalizeCreated(claim.row.id, 'ord_test_stress');
    }
    return claim.kind;
  }

  const results = await Promise.all(Array.from({ length: 10 }, () => simulateRequest()));

  assertEquals(externalCalls, 1, 'con 10 invocaciones concurrentes, orders.create se llama UNA sola vez');
  assertEquals(results.filter((r) => r === 'own').length, 1);
  assertEquals(results.filter((r) => r === 'reuse').length, 9);
});
