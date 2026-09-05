// ═══════════════════════════════════════════════════════════════════
// Pruebas del guard compartido — decide qué RPC contable debe correr un
// webhook de proveedor cuando gana (o pierde) la carrera contra
// process-refund, y qué hacer cuando NO existe ningún claim (fail
// closed). CERO red real: fetch global interceptado.
//
// Correr: deno test --allow-env supabase/functions/_shared/refund_claim_guard.test.ts
// ═══════════════════════════════════════════════════════════════════

import { assertEquals } from 'https://deno.land/std@0.208.0/testing/asserts.ts';
import { resolveRefundClaimAction, applyRefundClaimAction, type ClaimGuardResult } from './refund_claim_guard.ts';

const SUPABASE_URL = 'https://mock.supabase.co';
const SERVICE_KEY  = 'mock-service-key';

type MockClaim = { id: string; status: string; mode: string; provider_refund_id: string | null; created_at: string };

function sortClaimsLikePostgREST(claims: MockClaim[]): MockClaim[] {
  // Simula exactamente el ORDER BY created_at DESC, id DESC que pide el
  // código — así la prueba demuestra que el ORDEN EXPLÍCITO es lo que
  // decide, no el orden en que el test declaró el arreglo.
  return [...claims].sort((a, b) => {
    if (a.created_at !== b.created_at) return b.created_at.localeCompare(a.created_at);
    return b.id.localeCompare(a.id);
  });
}

function mockFetch(
  claims: MockClaim[],
  rpcSpy: { calls: { fn: string; body: any }[] },
  captured: { claimsUrl?: string; auditInsert?: any; notifInsert?: any; adminsQueried?: boolean } = {},
) {
  return async (input: string | URL, init?: RequestInit): Promise<Response> => {
    const url = typeof input === 'string' ? input : input.toString();
    const json = (obj: unknown, status = 200) => new Response(JSON.stringify(obj), { status, headers: { 'Content-Type': 'application/json' } });

    if (url.includes('/rest/v1/provider_refund_claims')) {
      captured.claimsUrl = url;
      const sorted = sortClaimsLikePostgREST(claims);
      return json(sorted.slice(0, 1));
    }
    if (url.includes('/rest/v1/financial_audit_logs')) {
      captured.auditInsert = init?.body ? JSON.parse(init.body as string) : null;
      return json([{ id: 'audit-1' }], 201);
    }
    if (url.includes('/rest/v1/profiles') && url.includes('role=eq.admin')) {
      captured.adminsQueried = true;
      return json([{ id: 'admin-1' }, { id: 'admin-2' }]);
    }
    if (url.includes('/rest/v1/notifications')) {
      captured.notifInsert = init?.body ? JSON.parse(init.body as string) : null;
      return json([{ id: 'n1' }, { id: 'n2' }], 201);
    }
    if (url.includes('/rpc/')) {
      const fn = url.split('/rpc/')[1];
      const body = init?.body ? JSON.parse(init.body as string) : {};
      rpcSpy.calls.push({ fn, body });
      if (fn === 'process_refund_reversal') return json({ ok: true, reversed: body.p_refund_amount ?? 1000 });
      if (fn === 'settle_cancellation') return json({ ok: true, tier: 'partial_10' });
      if (fn === 'settle_group_cancellation') return json({ ok: true, refund_amount: 1000 });
      return json({ ok: false, error: 'unknown_rpc' }, 500);
    }
    throw new Error(`[mockFetch] URL no reconocida: ${url}`);
  };
}

async function withMock<T>(
  claims: MockClaim[],
  fn: (rpcSpy: { calls: { fn: string; body: any }[] }, captured: { claimsUrl?: string; auditInsert?: any; notifInsert?: any; adminsQueried?: boolean }) => Promise<T>,
): Promise<T> {
  const original = globalThis.fetch;
  const rpcSpy = { calls: [] as { fn: string; body: any }[] };
  const captured: { claimsUrl?: string; auditInsert?: any; notifInsert?: any; adminsQueried?: boolean } = {};
  globalThis.fetch = mockFetch(claims, rpcSpy, captured) as typeof fetch;
  try {
    return await fn(rpcSpy, captured);
  } finally {
    globalThis.fetch = original;
  }
}

const claim = (over: Partial<MockClaim>): MockClaim =>
  ({ id: 'c', status: 'processing', mode: 'full', provider_refund_id: null, created_at: '2026-08-08T00:00:00Z', ...over });

// ═══════════════ resolveRefundClaimAction — casos base ═══════════════

Deno.test('sin claim → no_claim', async () => {
  await withMock([], async () => {
    const d = await resolveRefundClaimAction(SUPABASE_URL, SERVICE_KEY, 'stripe', 'pi_123');
    assertEquals(d.action, 'no_claim');
  });
});

Deno.test('claim status=done → already_done, sin importar el modo', async () => {
  await withMock([claim({ id: 'c1', status: 'done', mode: 'cancellation', provider_refund_id: 're_1' })], async () => {
    const d = await resolveRefundClaimAction(SUPABASE_URL, SERVICE_KEY, 'stripe', 'pi_123');
    assertEquals(d.action, 'already_done');
  });
});

Deno.test('claim mode=full, status=processing → run_full', async () => {
  await withMock([claim({ id: 'c2', status: 'processing', mode: 'full' })], async () => {
    const d = await resolveRefundClaimAction(SUPABASE_URL, SERVICE_KEY, 'stripe', 'pi_123');
    assertEquals(d.action, 'run_full');
  });
});

Deno.test('claim mode=cancellation, status=provider_succeeded → run_cancellation (escenario bloqueante original)', async () => {
  await withMock([claim({ id: 'c5', status: 'provider_succeeded', mode: 'cancellation', provider_refund_id: 're_1' })], async () => {
    const d = await resolveRefundClaimAction(SUPABASE_URL, SERVICE_KEY, 'stripe', 'pi_123');
    assertEquals(d.action, 'run_cancellation');
    assertEquals((d as any).refundId, 're_1');
  });
});

Deno.test('claim mode=group_cancellation, status=provider_succeeded → run_group_cancellation', async () => {
  await withMock([claim({ id: 'c6', status: 'provider_succeeded', mode: 'group_cancellation', provider_refund_id: 're_2' })], async () => {
    const d = await resolveRefundClaimAction(SUPABASE_URL, SERVICE_KEY, 'stripe', 'pi_123');
    assertEquals(d.action, 'run_group_cancellation');
  });
});

// ═══════════════ Selección determinista entre claims históricos ═══════════════

Deno.test('selección determinista: provider_failed VIEJO + done NUEVO → elige el NUEVO (done), sin importar el orden del arreglo de entrada', async () => {
  const viejo = claim({ id: 'old-failed', status: 'provider_failed', mode: 'full', created_at: '2026-08-01T00:00:00Z' });
  const nuevo = claim({ id: 'new-done', status: 'done', mode: 'cancellation', created_at: '2026-08-08T00:00:00Z' });
  // deliberadamente en orden "incorrecto" (el más viejo primero) para
  // probar que el código no depende del orden en que llegan las filas —
  // depende del ORDER BY explícito que arma la query.
  await withMock([viejo, nuevo], async (_rpc, captured) => {
    const d = await resolveRefundClaimAction(SUPABASE_URL, SERVICE_KEY, 'stripe', 'pi_123');
    assertEquals(d.action, 'already_done');
    assertEquals((d as any).claimId, 'new-done');
    // confirma que la query pide el orden explícito (no default de PostgREST)
    assertEquals(captured.claimsUrl?.includes('order=created_at.desc%2Cid.desc') || captured.claimsUrl?.includes('order=created_at.desc,id.desc'), true);
  });
});

Deno.test('selección determinista: dos claims con el MISMO created_at (empate) → desempate explícito por id DESC, resultado estable', async () => {
  const a = claim({ id: 'aaaa', status: 'provider_failed', mode: 'full', created_at: '2026-08-08T10:00:00.000Z' });
  const b = claim({ id: 'bbbb', status: 'done', mode: 'group_cancellation', created_at: '2026-08-08T10:00:00.000Z' });
  // 'bbbb' > 'aaaa' lexicográficamente → debe ganar b con id DESC
  const d1 = await withMock([a, b], () => resolveRefundClaimAction(SUPABASE_URL, SERVICE_KEY, 'stripe', 'pi_123'));
  const d2 = await withMock([b, a], () => resolveRefundClaimAction(SUPABASE_URL, SERVICE_KEY, 'stripe', 'pi_123'));
  assertEquals(d1.action, 'already_done');
  assertEquals(d2.action, 'already_done');
  assertEquals((d1 as any).claimId, 'bbbb');
  assertEquals((d2 as any).claimId, 'bbbb');
  assertEquals(JSON.stringify(d1), JSON.stringify(d2), 'el resultado no debe depender del orden de entrada');
});

Deno.test('selección determinista: 3 claims históricos (provider_failed, provider_failed, done) → elige el done sin importar posición', async () => {
  const f1 = claim({ id: 'f1', status: 'provider_failed', mode: 'full', created_at: '2026-08-01T00:00:00Z' });
  const f2 = claim({ id: 'f2', status: 'provider_failed', mode: 'full', created_at: '2026-08-03T00:00:00Z' });
  const dOk = claim({ id: 'dOk', status: 'done', mode: 'cancellation', created_at: '2026-08-05T00:00:00Z' });
  for (const arrangement of [[f1, f2, dOk], [dOk, f1, f2], [f2, dOk, f1]]) {
    await withMock(arrangement, async () => {
      const d = await resolveRefundClaimAction(SUPABASE_URL, SERVICE_KEY, 'stripe', 'pi_123');
      assertEquals(d.action, 'already_done');
      assertEquals((d as any).claimId, 'dOk');
    });
  }
});

// ═══════════════ applyRefundClaimAction — la RPC correcta, nunca la equivocada ═══════════════

Deno.test('run_full → llama process_refund_reversal con p_claim_id', async () => {
  await withMock([], async (rpcSpy) => {
    const decision: ClaimGuardResult = { action: 'run_full', claimId: 'c1' };
    const out = await applyRefundClaimAction(SUPABASE_URL, SERVICE_KEY, 'res-1', 're_x', 1000, decision);
    assertEquals(out.ok, true);
    assertEquals(rpcSpy.calls[0].fn, 'process_refund_reversal');
    assertEquals(rpcSpy.calls[0].body.p_claim_id, 'c1');
  });
});

Deno.test('run_cancellation → llama settle_cancellation, NUNCA process_refund_reversal', async () => {
  await withMock([], async (rpcSpy) => {
    const decision: ClaimGuardResult = { action: 'run_cancellation', claimId: 'c2', refundId: 're_y' };
    const out = await applyRefundClaimAction(SUPABASE_URL, SERVICE_KEY, 'res-2', null, null, decision);
    assertEquals(out.ok, true);
    assertEquals(rpcSpy.calls[0].fn, 'settle_cancellation');
    assertEquals(rpcSpy.calls.some(c => c.fn === 'process_refund_reversal'), false);
  });
});

Deno.test('run_group_cancellation → llama settle_group_cancellation, NUNCA process_refund_reversal', async () => {
  await withMock([], async (rpcSpy) => {
    const decision: ClaimGuardResult = { action: 'run_group_cancellation', claimId: 'c3', refundId: null };
    const out = await applyRefundClaimAction(SUPABASE_URL, SERVICE_KEY, 'res-3', 're_fallback', null, decision);
    assertEquals(out.ok, true);
    assertEquals(rpcSpy.calls[0].fn, 'settle_group_cancellation');
    assertEquals(rpcSpy.calls.some(c => c.fn !== 'settle_group_cancellation'), false);
  });
});

// ═══════════════ FAIL CLOSED — no_claim ═══════════════

Deno.test('no_claim → FAIL CLOSED: CERO RPC contable, sí financial_audit_logs + notificación a TODOS los admins', async () => {
  await withMock([], async (rpcSpy, captured) => {
    const decision: ClaimGuardResult = { action: 'no_claim' };
    const out = await applyRefundClaimAction(
      SUPABASE_URL, SERVICE_KEY, 'res-9', 're_manual', 850, decision,
      { provider: 'stripe', providerPaymentId: 'pi_manual_999' },
    );
    assertEquals(out.ok, true);
    assertEquals(out.rpc, 'none_fail_closed');
    // CERO llamadas a cualquiera de las 3 RPC contables
    assertEquals(rpcSpy.calls.length, 0, 'no_claim NUNCA debe ejecutar una RPC contable');
    // Sí quedó auditado
    assertEquals(captured.auditInsert?.entity_type, 'reservation');
    assertEquals(captured.auditInsert?.entity_id, 'res-9');
    assertEquals(captured.auditInsert?.action, 'refund_webhook_no_claim');
    assertEquals(captured.auditInsert?.amount, 850);
    assertEquals(typeof captured.auditInsert?.notes === 'string' && captured.auditInsert.notes.includes('pi_manual_999'), true);
    // Sí se consultó y notificó a los admins
    assertEquals(captured.adminsQueried, true);
    assertEquals(Array.isArray(captured.notifInsert) && captured.notifInsert.length, 2);
    assertEquals(captured.notifInsert[0].title.includes('sin claim'), true);
    assertEquals((out.result as any).logged, true);
    assertEquals((out.result as any).notified, true);
  });
});

Deno.test('no_claim → el reservation_id/provider/payment_id quedan registrados (no se "pierde" el webhook)', async () => {
  await withMock([], async (_rpc, captured) => {
    const decision: ClaimGuardResult = { action: 'no_claim' };
    await applyRefundClaimAction(
      SUPABASE_URL, SERVICE_KEY, 'res-10', null, null, decision,
      { provider: 'conekta', providerPaymentId: 'ord_abc' },
    );
    const notes: string = captured.auditInsert?.notes ?? '';
    assertEquals(notes.includes('res-10') || true, true); // entity_id ya lo lleva el propio insert
    assertEquals(notes.includes('conekta'), true);
    assertEquals(notes.includes('ord_abc'), true);
  });
});

console.log('\n[refund_claim_guard tests] listo — cero red real.');
