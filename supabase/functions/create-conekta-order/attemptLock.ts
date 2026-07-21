// ═══════════════════════════════════════════════════════════════════
// attemptLock.ts — exclusión mutua sobre payment_attempts (Conekta)
//
// Objetivo: que orders.create de Conekta se llame EXACTAMENTE una vez
// por client_key, incluso bajo doble clic / dos pestañas / reintento
// de red — sin depender solo de que el gate contenga el daño después.
//
// Mecanismo (sin migración: 'abandoned' ya existe en el CHECK de
// payment_attempts.status desde sql/519):
//   1. INSERT status='creating' — el UNIQUE(provider,client_key) decide
//      quién es dueño. Ganador → procede a crear en el proveedor.
//   2. Perdedor: NO cae a crear una orden — entra a un ciclo de
//      espera/relectura (poll) durante una ventana corta.
//   3. Si aparece status='created', reutiliza directamente.
//   4. Si status='creating' lleva más de STALE_CREATING_MS sin
//      refrescarse (posible caída a mitad del checkout), intenta un
//      takeover controlado vía UPDATE...WHERE status='creating' AND
//      updated_at < umbral — un compare-and-swap de una sola fila:
//      Postgres serializa los UPDATE concurrentes sobre la misma fila,
//      así que como mucho UNA de las llamadas concurrentes puede
//      afectar la fila; las demás reciben 0 filas y vuelven a releer.
//   5. Si status='abandoned' (el proveedor falló la vez anterior),
//      el takeover es INMEDIATO — no espera el timeout de stale.
//   6. Si se agota MAX_WAIT_MS sin resolución, se devuelve 'conflict'
//      (409 controlado) — JAMÁS se crea una orden en paralelo.
// ═══════════════════════════════════════════════════════════════════

export const POLL_INTERVAL_MS   = 400;
export const MAX_WAIT_MS        = 12_000;
export const STALE_CREATING_MS  = 20_000;

export type AttemptStatus = 'creating' | 'created' | 'consumed' | 'abandoned';

export interface AttemptRow {
  id: string;
  status: AttemptStatus;
  provider_order_id: string | null;
  updated_at: string; // ISO
}

// Contrato mínimo que necesita el algoritmo — implementado por
// makeSupabaseAttemptStore() contra la BD real, o por un mock en tests.
export interface AttemptStore {
  insertCreating(): Promise<AttemptRow | null>; // null = conflicto (ya existe)
  read(): Promise<AttemptRow | null>;
  casFromAbandonedToCreating(id: string): Promise<AttemptRow | null>;
  casFromStaleCreatingToCreating(id: string, staleBeforeIso: string): Promise<AttemptRow | null>;
  finalizeCreated(id: string, providerOrderId: string): Promise<void>;
  markAbandoned(id: string): Promise<void>;
}

export type ClaimResult =
  | { kind: 'own'; row: AttemptRow }      // dueño exclusivo: llamar al proveedor
  | { kind: 'reuse'; row: AttemptRow }    // ya hay orden creada: reutilizar
  | { kind: 'conflict' };                 // nadie resolvió a tiempo: 409, reintentar

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

export async function claimAttempt(
  store: AttemptStore,
  opts: { pollMs?: number; maxWaitMs?: number; staleMs?: number } = {},
): Promise<ClaimResult> {
  const pollMs    = opts.pollMs    ?? POLL_INTERVAL_MS;
  const maxWaitMs = opts.maxWaitMs ?? MAX_WAIT_MS;
  const staleMs   = opts.staleMs   ?? STALE_CREATING_MS;

  // 1) Intentar ganar la creación directamente.
  const inserted = await store.insertCreating();
  if (inserted) return { kind: 'own', row: inserted };

  // 2) Perdimos la carrera de INSERT — esperar/releer, JAMÁS crear en paralelo.
  const deadline = Date.now() + maxWaitMs;
  while (true) {
    const row = await store.read();

    if (!row) {
      // Desapareció entre lecturas (no debería ocurrir en operación normal;
      // cubre la ventana teórica de un DELETE externo) — reintentar el INSERT.
      const retryInsert = await store.insertCreating();
      if (retryInsert) return { kind: 'own', row: retryInsert };
    } else if (row.status === 'created' && row.provider_order_id) {
      return { kind: 'reuse', row };
    } else if (row.status === 'abandoned') {
      // Reintento seguro INMEDIATO — no se espera el timeout de stale.
      const claimed = await store.casFromAbandonedToCreating(row.id);
      if (claimed) return { kind: 'own', row: claimed };
      // Alguien más ganó el takeover en el mismo instante — releer.
    } else if (row.status === 'creating') {
      const ageMs = Date.now() - new Date(row.updated_at).getTime();
      if (ageMs > staleMs) {
        const staleBeforeIso = new Date(Date.now() - staleMs).toISOString();
        const claimed = await store.casFromStaleCreatingToCreating(row.id, staleBeforeIso);
        if (claimed) return { kind: 'own', row: claimed };
        // Perdimos el takeover contra otro releedor — seguir esperando.
      }
    }

    if (Date.now() > deadline) return { kind: 'conflict' };
    await sleep(pollMs);
  }
}

// ── Implementación real contra Supabase (usada por index.ts) ────────
export function makeSupabaseAttemptStore(
  admin: any,
  provider: 'conekta',
  clientKey: string,
  insertFields: {
    reservation_id: string;
    expected_amount_minor: number;
    currency: string;
    method: string;
    discount_minor: number;
    msi_months: number;
    msi_fee_minor: number;
  },
): AttemptStore {
  return {
    async insertCreating() {
      const { data, error } = await admin
        .from('payment_attempts')
        .insert({ provider, client_key: clientKey, status: 'creating', ...insertFields })
        .select()
        .single();
      if (error) return null; // conflicto por UNIQUE(provider, client_key)
      return data as AttemptRow;
    },
    async read() {
      const { data } = await admin
        .from('payment_attempts')
        .select('*')
        .eq('provider', provider)
        .eq('client_key', clientKey)
        .maybeSingle();
      return (data as AttemptRow) ?? null;
    },
    async casFromAbandonedToCreating(id: string) {
      const { data } = await admin
        .from('payment_attempts')
        .update({ status: 'creating', updated_at: new Date().toISOString() })
        .eq('id', id)
        .eq('status', 'abandoned') // compare-and-swap: solo si SIGUE abandoned
        .select()
        .maybeSingle();
      return (data as AttemptRow) ?? null;
    },
    async casFromStaleCreatingToCreating(id: string, staleBeforeIso: string) {
      const { data } = await admin
        .from('payment_attempts')
        .update({ status: 'creating', updated_at: new Date().toISOString() })
        .eq('id', id)
        .eq('status', 'creating')       // compare-and-swap doble condición:
        .lt('updated_at', staleBeforeIso) // sigue 'creating' Y sigue viejo
        .select()
        .maybeSingle();
      return (data as AttemptRow) ?? null;
    },
    async finalizeCreated(id: string, providerOrderId: string) {
      await admin
        .from('payment_attempts')
        .update({ provider_order_id: providerOrderId, status: 'created' })
        .eq('id', id);
    },
    async markAbandoned(id: string) {
      // Estado de error retry-safe: el PRÓXIMO releedor puede tomar el
      // control de inmediato, sin esperar STALE_CREATING_MS.
      await admin
        .from('payment_attempts')
        .update({ status: 'abandoned', updated_at: new Date().toISOString() })
        .eq('id', id);
    },
  };
}
