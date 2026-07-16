// ═══════════════════════════════════════════════════════════════════
// generate-report — Supabase Edge Function
//
// 📊 Genera reportes Excel (.xlsx) reales en el servidor:
//   · mode 'group' → el GRUPO descarga SU reporte. El group_id se deriva
//     del JWT en el servidor (jamás del cliente). Regla de privacidad:
//     solo "Tu ganancia" — NUNCA total del cliente, comisiones Daricefy
//     ni fees de procesadores.
//   · mode 'admin' → el ADMIN descarga el reporte completo con filtros
//     (país, fechas, y avanzados: estado, ciudad, método, procesador,
//     estado del evento). Fórmulas canónicas = sql/490. Monedas JAMÁS
//     sumadas entre sí. Fees: solo reales; faltantes = "No capturado".
//
// El archivo se sube al bucket privado 'reports' y se regresa una URL
// firmada (1 h). CLABEs enmascaradas (****1234). Sin llaves ni tokens.
//
// Body: { mode: 'group'|'admin', from?: 'YYYY-MM-DD', to?: 'YYYY-MM-DD',
//         country?: 'all'|'MX'|'US'|'CA',
//         state?, city?, method?, provider?, event_status? }
// ═══════════════════════════════════════════════════════════════════

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import * as XLSX from 'https://esm.sh/xlsx@0.18.5';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_KEY  = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const admin = createClient(SUPABASE_URL, SERVICE_KEY);

const cors = {
  'Access-Control-Allow-Origin':  '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const jsonRes = (body: Record<string, unknown>, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

// ── Helpers ───────────────────────────────────────────────────────────
const COUNTRY_CODE: Record<string, string> = {
  'méxico': 'MX', 'mexico': 'MX', 'mx': 'MX',
  'estados unidos': 'US', 'usa': 'US', 'us': 'US', 'united states': 'US', 'eeuu': 'US', 'ee.uu.': 'US',
  'canadá': 'CA', 'canada': 'CA', 'ca': 'CA',
};
const codeOf = (country?: string | null) => {
  if (!country) return 'MX';
  const k = String(country).trim().toLowerCase();
  return COUNTRY_CODE[k] ?? String(country).trim().substring(0, 2).toUpperCase();
};
const COUNTRY_NAME: Record<string, string> = { MX: 'México', US: 'Estados Unidos', CA: 'Canadá' };
const CURRENCY_OF: Record<string, string> = { MX: 'MXN', US: 'USD', CA: 'CAD' };

const maskClabe = (c?: string | null) => (c ? `****${String(c).slice(-4)}` : '—');
const money = (n: any) => (n == null ? null : Math.round(Number(n) * 100) / 100);
const NO_CAP = 'No capturado';

const PROVIDER_LABEL = (provider?: string | null, method?: string | null) => {
  const p = (provider ?? '').toLowerCase();
  const m = (method ?? '').toLowerCase();
  if (p === 'conekta') {
    if (m === 'card') return 'Conekta Tarjeta';
    if (m === 'spei') return 'Conekta SPEI';
    if (m === 'cash') return 'Conekta Efectivo (OXXO)';
    if (m === 'bnpl') return 'BNPL (Conekta)';
    return 'Conekta';
  }
  if (p === 'stripe') return m === 'card_msi' ? 'Stripe (MSI)' : 'Stripe';
  if (p === 'mercadopago') return 'MercadoPago';
  return p ? p : '—';
};

const STATUS_ES: Record<string, string> = {
  completed: 'Completado', in_progress: 'En curso', accepted: 'Pagado',
  confirmed: 'Confirmado', cancelled: 'Cancelado', rejected: 'Rechazado',
  pending: 'Pendiente', pending_payment: 'Por pagar', expired: 'Expirado',
};

// Hoja con encabezados, anchos y autofiltro
function makeSheet(headers: string[], rows: any[][], widths?: number[]) {
  const ws = XLSX.utils.aoa_to_sheet([headers, ...rows]);
  ws['!cols'] = (widths ?? headers.map(() => 16)).map(w => ({ wch: w }));
  const lastCol = XLSX.utils.encode_col(headers.length - 1);
  ws['!autofilter'] = { ref: `A1:${lastCol}${rows.length + 1}` };
  return ws;
}

// Bloque de metadatos al inicio de la hoja Resumen
function metaRows(titulo: string, from: string, to: string): any[][] {
  const now = new Date().toLocaleString('es-MX', { timeZone: 'America/Mexico_City' });
  return [
    [titulo],
    [`Generado: ${now} (hora de México)`],
    [`Periodo: ${from} a ${to}`],
    ['⚠️ Las monedas (MXN/USD/CAD) se reportan POR SEPARADO y nunca se suman entre sí.'],
    [''],
  ];
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  try {
    // ── Auth ─────────────────────────────────────────────────────────
    const jwt = (req.headers.get('Authorization') ?? '').replace('Bearer ', '').trim();
    if (!jwt) return jsonRes({ error: 'No autorizado' }, 401);
    const { data: { user }, error: authErr } = await admin.auth.getUser(jwt);
    if (authErr || !user) return jsonRes({ error: 'No autorizado' }, 401);

    const { data: profile } = await admin.from('profiles').select('role, full_name').eq('id', user.id).single();
    const role = profile?.role ?? null;

    const body = await req.json().catch(() => ({})) as any;
    const mode: 'group' | 'admin' = body.mode === 'admin' ? 'admin' : 'group';
    const from: string = body.from ?? '2000-01-01';
    const to:   string = body.to   ?? new Date().toISOString().substring(0, 10);

    // 🔒 Seguridad en el SERVIDOR (no en botones):
    if (mode === 'admin' && role !== 'admin') {
      return jsonRes({ error: 'Solo administradores' }, 403);
    }

    const wb = XLSX.utils.book_new();
    let filename = '';

    // ═════════════════════ REPORTE DEL GRUPO ═════════════════════════
    if (mode === 'group') {
      // El group_id SIEMPRE se deriva del token — nunca del body
      const { data: grp } = await admin
        .from('groups')
        .select('id, name, country, state, city, rating, total_reviews')
        .eq('owner_id', user.id)
        .limit(1)
        .maybeSingle();
      if (!grp) return jsonRes({ error: 'No se encontró tu grupo' }, 404);

      const cc = codeOf(grp.country);
      const currency = CURRENCY_OF[cc] ?? 'MXN';

      const [{ data: resvs }, { data: reviews }, { data: wallet }, { data: withdrawals }] = await Promise.all([
        admin.from('reservations')
          // 🔒 SOLO group_earnings — jamás total_price/comisiones/fees
          .select('folio, event_date, event_time, address, event_city, status, payment_status, payout_status, group_earnings, cancelled_by, cancel_reason, created_at')
          .eq('group_id', grp.id)
          .gte('event_date', from).lte('event_date', to)
          .order('event_date', { ascending: false }),
        admin.from('reviews')
          .select('reservation_id, rating, comment, created_at')
          .eq('group_id', grp.id),
        admin.from('group_wallets')
          .select('pending_balance, available_balance, total_earned, pending_balance_usd, available_balance_usd, total_earned_usd')
          .eq('group_id', grp.id).maybeSingle(),
        admin.from('withdrawals')
          .select('amount, status, transfer_reference, receipt_path, bank_clabe, created_at, processed_at')
          .eq('user_id', user.id)
          .order('created_at', { ascending: false }),
      ]);

      const rows = resvs ?? [];
      const revByRes: Record<string, any> = {};
      (reviews ?? []).forEach((rv: any) => { if (rv.reservation_id) revByRes[rv.reservation_id] = rv; });

      const completados = rows.filter(r => r.status === 'completed');
      const proximos    = rows.filter(r => ['accepted', 'confirmed', 'in_progress'].includes(r.status) );
      const cancelCli   = rows.filter(r => r.status === 'cancelled' && r.cancelled_by === 'client');
      const cancelGrp   = rows.filter(r => r.status === 'cancelled' && r.cancelled_by === 'group');
      const noShows     = rows.filter(r => r.cancel_reason === 'no_show_grupo');
      const ganado      = rows.filter(r => ['paid', 'fully_paid', 'deposit_paid'].includes(r.payment_status ?? ''))
                              .reduce((s, r) => s + Number(r.group_earnings ?? 0), 0);
      const stars = [1, 2, 3, 4, 5].map(n => (reviews ?? []).filter((rv: any) => rv.rating === n).length);
      const ciudades = [...new Set(rows.map(r => r.event_city).filter(Boolean))];
      const wPend = (withdrawals ?? []).filter(w => ['pending', 'processing'].includes(w.status));
      const wDone = (withdrawals ?? []).filter(w => w.status === 'completed');

      // Hoja 1 — Resumen
      const resumen: any[][] = [
        ...metaRows(`REPORTE DE ${String(grp.name ?? 'GRUPO').toUpperCase()} — Daricefy`, from, to),
        ['Grupo',              grp.name ?? '—'],
        ['País',               COUNTRY_NAME[cc] ?? grp.country ?? '—'],
        ['Estado/Provincia',   grp.state ?? '—'],
        ['Ciudad base',        grp.city ?? '—'],
        ['Moneda',             currency],
        [''],
        ['── EVENTOS ──'],
        ['Total de eventos',           rows.length],
        ['Completados',                completados.length],
        ['Próximos',                   proximos.length],
        ['Cancelados por el cliente',  cancelCli.length],
        ['Cancelados por el grupo',    cancelGrp.length],
        ['No-shows',                   noShows.length],
        ['% de finalización',          rows.length ? `${Math.round((completados.length / rows.length) * 100)}%` : '—'],
        ['Ciudades trabajadas',        ciudades.length ? ciudades.join(', ') : '—'],
        [''],
        ['── CALIFICACIONES ──'],
        ['Calificación promedio', grp.rating ?? '—'],
        ['Total de reseñas',      grp.total_reviews ?? (reviews ?? []).length],
        ['★★★★★', stars[4]], ['★★★★', stars[3]], ['★★★', stars[2]], ['★★', stars[1]], ['★', stars[0]],
        [''],
        ['── TU DINERO ──'],
        [`Ganancias del periodo (${currency})`, money(ganado)],
        ['Pendiente de liberar',   money(currency === 'USD' ? wallet?.pending_balance_usd : wallet?.pending_balance) ?? 0],
        ['Disponible para retirar', money(currency === 'USD' ? wallet?.available_balance_usd : wallet?.available_balance) ?? 0],
        ['Total ganado histórico',  money(currency === 'USD' ? wallet?.total_earned_usd : wallet?.total_earned) ?? 0],
        ['Retiros pendientes',      wPend.length],
        ['Retiros completados',     wDone.length],
      ];
      XLSX.utils.book_append_sheet(wb, makeSheet(['REPORTE'], resumen, [34, 40]), 'Resumen');

      // Hoja 2 — Eventos (detalle)
      XLSX.utils.book_append_sheet(wb, makeSheet(
        ['Folio', 'Fecha', 'Ciudad', 'Estado del evento', 'Tu ganancia', 'Estado del pago', 'Calificación', 'Comentario del cliente'],
        rows.map((r: any) => {
          const rv = revByRes[r.id] ?? Object.values(revByRes).find((x: any) => false);
          const review = (reviews ?? []).find((x: any) => x.reservation_id === (r as any).id);
          return [
            r.folio ?? '—',
            r.event_date ?? '—',
            r.event_city ?? '—',
            r.cancel_reason === 'no_show_grupo' ? 'No-show' : (STATUS_ES[r.status] ?? r.status),
            money(r.group_earnings) ?? 0,
            r.payout_status === 'released' ? 'Liberada' : r.payout_status === 'held' ? 'En custodia' : (r.payout_status ?? '—'),
            review?.rating ?? '—',
            review?.comment ?? '—',
          ];
        }),
        [16, 12, 16, 16, 14, 14, 12, 50],
      ), 'Eventos');

      // Hoja 3 — Retiros (CLABE enmascarada)
      XLSX.utils.book_append_sheet(wb, makeSheet(
        ['Fecha solicitud', 'Monto', 'Estado', 'Referencia', 'Comprobante', 'Cuenta', 'Fecha pago'],
        (withdrawals ?? []).map((w: any) => [
          String(w.created_at ?? '').substring(0, 10),
          money(w.amount) ?? 0,
          w.status === 'completed' ? 'Pagado' : w.status === 'pending' ? 'Pendiente' : w.status,
          w.transfer_reference ?? '—',
          w.receipt_path ? 'Disponible en la app' : '—',
          maskClabe(w.bank_clabe),
          w.processed_at ? String(w.processed_at).substring(0, 10) : '—',
        ]),
        [14, 12, 12, 20, 20, 12, 12],
      ), 'Retiros');

      filename = `reporte_${String(grp.name ?? 'grupo').replace(/[^a-zA-Z0-9]/g, '_')}_${from}_a_${to}.xlsx`;
    }

    // ═════════════════════ REPORTE DEL ADMIN ═════════════════════════
    if (mode === 'admin') {
      const countrySel: string = body.country ?? 'all';   // all | MX | US | CA

      // Eventos del periodo (por fecha de creación/pago, hora MX aproximada por date)
      let q = admin.from('reservations')
        .select('id, folio, created_at, event_date, event_time, event_city, status, payment_status, payout_status, total_price, msi_fee_amount, group_earnings, base_price, service_fee_amount, commission_amount, stripe_fee_amount, currency_code, payment_provider, payment_method_type, cancel_reason, cancelled_by, admin_no_show_resolution, group:groups(name, country, state, city), client:profiles!client_id(full_name)')
        .gte('created_at', `${from}T00:00:00`)
        .lte('created_at', `${to}T23:59:59`)
        .order('created_at', { ascending: false })
        .limit(5000);
      if (body.event_status) q = q.eq('status', body.event_status);
      if (body.provider)     q = q.eq('payment_provider', body.provider);
      if (body.method)       q = q.eq('payment_method_type', body.method);
      const { data: allRows } = await q;

      let rows = (allRows ?? []).map((r: any) => ({ ...r, cc: codeOf(r.group?.country) }));
      if (countrySel !== 'all') rows = rows.filter(r => r.cc === countrySel);
      if (body.state) rows = rows.filter(r => (r.group?.state ?? '').toLowerCase() === String(body.state).toLowerCase());
      if (body.city)  rows = rows.filter(r => (r.group?.city ?? '').toLowerCase() === String(body.city).toLowerCase());

      // Fórmulas canónicas (= sql/490) por moneda dentro de un set de filas
      const summarize = (set: any[]) => {
        const paid = set.filter(r => ['paid', 'fully_paid', 'deposit_paid'].includes(r.payment_status ?? ''));
        const byCur: Record<string, any> = {};
        for (const r of paid) {
          const cur = r.currency_code ?? 'MXN';
          const b = byCur[cur] ??= { cobrado: 0, grupos: 0, pendiente: 0, pagado: 0, comision: 0, fees: 0, sinFee: 0, neto: 0 };
          const cobrado  = Number(r.total_price ?? 0) + Number(r.msi_fee_amount ?? 0);
          const deGrupos = Number(r.group_earnings ?? r.base_price ?? Math.round((Number(r.total_price ?? 0) / 1.20) * 100) / 100);
          const comision = Number(r.service_fee_amount ?? r.commission_amount ?? (Number(r.total_price ?? 0) - deGrupos)) + Number(r.msi_fee_amount ?? 0);
          b.cobrado += cobrado; b.grupos += deGrupos; b.comision += comision;
          if (r.payout_status === 'held')     b.pendiente += deGrupos;
          if (r.payout_status === 'released') b.pagado    += deGrupos;
          if (r.stripe_fee_amount != null) b.fees += Number(r.stripe_fee_amount); else b.sinFee += 1;
        }
        Object.values(byCur).forEach((b: any) => { b.neto = b.comision - b.fees; });
        const refunded = set.filter(r => r.payment_status === 'refunded');
        return {
          byCur,
          total: set.length,
          completados: set.filter(r => r.status === 'completed').length,
          proximos:    set.filter(r => ['accepted', 'confirmed', 'in_progress'].includes(r.status)).length,
          cancelados:  set.filter(r => r.status === 'cancelled').length,
          noShows:     set.filter(r => r.cancel_reason === 'no_show_grupo').length,
          reembolsados: refunded.length,
        };
      };

      const statBlock = (label: string, s: ReturnType<typeof summarize>): any[][] => {
        const out: any[][] = [
          [`── ${label} ──`],
          ['Total de eventos', s.total], ['Completados', s.completados], ['Próximos', s.proximos],
          ['Cancelados', s.cancelados], ['No-shows', s.noShows], ['Reembolsados', s.reembolsados],
        ];
        for (const [cur, b] of Object.entries(s.byCur) as any) {
          out.push(
            [`— Dinero en ${cur} —`],
            ['Total cobrado a clientes', money(b.cobrado)],
            ['Dinero de los grupos',     money(b.grupos)],
            ['· Pendiente por pagar',    money(b.pendiente)],
            ['· Ya pagado a grupos',     money(b.pagado)],
            ['Comisión Daricefy (bruta)', money(b.comision)],
            ['Comisiones reales de procesadores', money(b.fees)],
            ['Operaciones con fee "No capturado"', b.sinFee],
            ['Ingreso neto estimado',    money(b.neto)],
          );
        }
        out.push(['']);
        return out;
      };

      // Grupos y talentos (estadísticas)
      const [{ data: allGroups }, { count: talentCount }, { data: openDisputes }] = await Promise.all([
        admin.from('groups').select('name, country, state, city, rating, total_reviews, is_active, strike_count, created_at'),
        admin.from('job_board_profiles').select('user_id', { count: 'exact', head: true }).eq('is_visible', true),
        admin.from('disputes').select('id, status').in('status', ['open', 'under_review']),
      ]);
      const groupsAll = (allGroups ?? []).map((g: any) => ({ ...g, cc: codeOf(g.country) }));
      const groupsSel = countrySel === 'all' ? groupsAll : groupsAll.filter(g => g.cc === countrySel);
      const eventCountByGroup: Record<string, number> = {};
      rows.forEach(r => { const n = r.group?.name; if (n) eventCountByGroup[n] = (eventCountByGroup[n] ?? 0) + 1; });
      const topEventos = Object.entries(eventCountByGroup).sort((a, b) => b[1] - a[1]).slice(0, 10);
      const topRated = groupsSel.filter(g => (g.total_reviews ?? 0) > 0)
        .sort((a, b) => (b.rating ?? 0) - (a.rating ?? 0)).slice(0, 10);
      const nuevosGrupos = groupsSel.filter(g => (g.created_at ?? '') >= `${from}` && (g.created_at ?? '') <= `${to}T23:59:59`).length;
      const avgRating = groupsSel.length
        ? Math.round((groupsSel.reduce((s, g) => s + Number(g.rating ?? 0), 0) / groupsSel.length) * 100) / 100 : 0;

      // Hoja: Resumen (global o del país)
      const titulo = countrySel === 'all'
        ? 'REPORTE GLOBAL — Daricefy'
        : `REPORTE ${COUNTRY_NAME[countrySel] ?? countrySel} — Daricefy`;
      const resumen: any[][] = [...metaRows(titulo, from, to)];
      if (countrySel === 'all') {
        resumen.push(...statBlock('RESUMEN GLOBAL (todas las operaciones)', summarize(rows)));
        for (const cc of ['MX', 'US', 'CA']) {
          resumen.push(...statBlock(`${COUNTRY_NAME[cc]} (${CURRENCY_OF[cc]})`, summarize(rows.filter(r => r.cc === cc))));
        }
      } else {
        resumen.push(...statBlock(`${COUNTRY_NAME[countrySel] ?? countrySel}`, summarize(rows)));
      }
      resumen.push(
        ['── PLATAFORMA ──'],
        ['Grupos activos',            groupsSel.filter(g => g.is_active).length],
        ['Talentos activos',          talentCount ?? 0],
        ['Grupos nuevos en el periodo', nuevosGrupos],
        ['Calificación promedio de grupos', avgRating || '—'],
        ['Disputas abiertas',         (openDisputes ?? []).length],
      );
      XLSX.utils.book_append_sheet(wb, makeSheet(['REPORTE'], resumen, [38, 22]), 'Resumen');

      // Hoja: Eventos (detalle con procesador y fee real)
      XLSX.utils.book_append_sheet(wb, makeSheet(
        ['Folio', 'Fecha evento', 'País', 'Estado', 'Ciudad', 'Grupo', 'Cliente', 'Estado', 'Moneda', 'Total cobrado', 'Del grupo', 'Comisión Daricefy', 'Procesador', 'Fee procesador', 'Payout'],
        rows.map((r: any) => {
          const cobrado = Number(r.total_price ?? 0) + Number(r.msi_fee_amount ?? 0);
          const deGrupos = Number(r.group_earnings ?? r.base_price ?? Math.round((Number(r.total_price ?? 0) / 1.20) * 100) / 100);
          return [
            r.folio ?? '—', r.event_date ?? '—',
            COUNTRY_NAME[r.cc] ?? r.cc, r.group?.state ?? '—', r.group?.city ?? '—',
            r.group?.name ?? '—', r.client?.full_name ?? '—',
            r.cancel_reason === 'no_show_grupo' ? 'No-show' : (STATUS_ES[r.status] ?? r.status),
            r.currency_code ?? 'MXN',
            money(cobrado), money(deGrupos), money(cobrado - deGrupos),
            PROVIDER_LABEL(r.payment_provider, r.payment_method_type),
            r.stripe_fee_amount != null ? money(r.stripe_fee_amount) : NO_CAP,
            r.payout_status ?? '—',
          ];
        }),
        [16, 12, 12, 14, 14, 20, 18, 12, 8, 13, 12, 14, 18, 13, 10],
      ), 'Eventos');

      // Hoja: Pagos a grupos (retiros) — CLABE enmascarada
      const { data: wds } = await admin.from('withdrawals')
        .select('amount, status, transfer_reference, receipt_path, bank_clabe, bank_name, created_at, processed_at, user_id')
        .gte('created_at', `${from}T00:00:00`).lte('created_at', `${to}T23:59:59`)
        .order('created_at', { ascending: false }).limit(2000);
      const { data: ownersGroups } = await admin.from('groups').select('owner_id, name, country');
      const grpByOwner: Record<string, any> = {};
      (ownersGroups ?? []).forEach((g: any) => { grpByOwner[g.owner_id] ??= g; });
      let wdRows = (wds ?? []).map((w: any) => ({ ...w, g: grpByOwner[w.user_id] }));
      if (countrySel !== 'all') wdRows = wdRows.filter(w => codeOf(w.g?.country) === countrySel);
      XLSX.utils.book_append_sheet(wb, makeSheet(
        ['Fecha', 'Grupo', 'País', 'Monto', 'Estado', 'Referencia', 'Comprobante', 'Banco', 'Cuenta', 'Fecha pago'],
        wdRows.map((w: any) => [
          String(w.created_at ?? '').substring(0, 10),
          w.g?.name ?? '—', COUNTRY_NAME[codeOf(w.g?.country)] ?? '—',
          money(w.amount) ?? 0,
          w.status === 'completed' ? 'Pagado' : w.status,
          w.transfer_reference ?? '—',
          w.receipt_path ? 'Sí' : '—',
          w.bank_name ?? '—', maskClabe(w.bank_clabe),
          w.processed_at ? String(w.processed_at).substring(0, 10) : '—',
        ]),
        [12, 20, 12, 12, 12, 20, 12, 14, 12, 12],
      ), 'Pagos a grupos');

      // Hoja: Reembolsos (manuales con monto real + automáticos)
      const { data: mrs } = await admin.from('manual_refunds')
        .select('folio, amount, payment_method, status, clabe, transfer_reference, receipt_path, created_at, processed_at, reservation:reservations(currency_code, group:groups(country))')
        .gte('created_at', `${from}T00:00:00`).lte('created_at', `${to}T23:59:59`)
        .order('created_at', { ascending: false }).limit(2000);
      let mrRows = (mrs ?? []);
      if (countrySel !== 'all') mrRows = mrRows.filter((m: any) => codeOf(m.reservation?.group?.country) === countrySel);
      const autoRefunds = rows.filter(r => r.payment_status === 'refunded');
      XLSX.utils.book_append_sheet(wb, makeSheet(
        ['Tipo', 'Folio', 'Fecha', 'Moneda', 'Monto', 'Método', 'Estado', 'Referencia', 'Comprobante', 'Cuenta'],
        [
          ...mrRows.map((m: any) => [
            'Manual', m.folio ?? '—', String(m.created_at ?? '').substring(0, 10),
            m.reservation?.currency_code ?? 'MXN', money(m.amount) ?? 0,
            m.payment_method === 'cash' ? 'Efectivo (OXXO)' : m.payment_method === 'spei' ? 'SPEI' : m.payment_method,
            m.status === 'sent' ? 'Enviado' : m.status, m.transfer_reference ?? '—',
            m.receipt_path ? 'Sí' : '—', maskClabe(m.clabe),
          ]),
          ...autoRefunds.map((r: any) => [
            'Automático', r.folio ?? '—', String(r.created_at ?? '').substring(0, 10),
            r.currency_code ?? 'MXN',
            money(Number(r.total_price ?? 0) + Number(r.msi_fee_amount ?? 0)),
            PROVIDER_LABEL(r.payment_provider, r.payment_method_type),
            'Reembolsado', r.id, '—', '—',
          ]),
        ],
        [11, 16, 12, 8, 12, 18, 12, 24, 12, 12],
      ), 'Reembolsos');

      // Hoja: No-shows
      const nsRows = rows.filter(r => r.cancel_reason === 'no_show_grupo');
      XLSX.utils.book_append_sheet(wb, makeSheet(
        ['Folio', 'Fecha evento', 'País', 'Grupo', 'Cliente', 'Moneda', 'Monto evento', 'Resolución', 'Payout'],
        nsRows.map((r: any) => [
          r.folio ?? '—', r.event_date ?? '—', COUNTRY_NAME[r.cc] ?? r.cc,
          r.group?.name ?? '—', r.client?.full_name ?? '—',
          r.currency_code ?? 'MXN', money(Number(r.total_price ?? 0)),
          r.admin_no_show_resolution === 'refunded_100' ? 'Reembolso 100% + strike'
            : r.admin_no_show_resolution === 'no_refund' ? 'Sin reembolso + strike'
            : r.admin_no_show_resolution === 'reviewed' ? 'Revisado sin acción'
            : 'Pendiente de resolver',
          r.payout_status ?? '—',
        ]),
        [16, 12, 12, 20, 18, 8, 12, 24, 10],
      ), 'No-shows');

      // Hoja: Grupos y talentos
      XLSX.utils.book_append_sheet(wb, makeSheet(
        ['Grupo', 'País', 'Estado', 'Ciudad', 'Activo', 'Rating', 'Reseñas', 'Strikes', 'Eventos en periodo'],
        groupsSel.map((g: any) => [
          g.name ?? '—', COUNTRY_NAME[g.cc] ?? g.cc, g.state ?? '—', g.city ?? '—',
          g.is_active ? 'Sí' : 'No', g.rating ?? '—', g.total_reviews ?? 0,
          g.strike_count ?? 0, eventCountByGroup[g.name] ?? 0,
        ]),
        [22, 12, 14, 14, 8, 8, 8, 8, 16],
      ), 'Grupos y talentos');

      const tag = countrySel === 'all' ? 'global' : countrySel;
      filename = `daricefy_reporte_${tag}_${from}_a_${to}.xlsx`;
    }

    // ── Generar, subir y firmar ───────────────────────────────────────
    const buf = XLSX.write(wb, { type: 'array', bookType: 'xlsx' }) as ArrayBuffer;
    const path = `${user.id}/${Date.now()}_${filename}`;
    const { error: upErr } = await admin.storage.from('reports').upload(path, buf, {
      contentType: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      upsert: true,
    });
    if (upErr) return jsonRes({ error: `No se pudo guardar el reporte: ${upErr.message}` }, 500);

    const { data: signed } = await admin.storage.from('reports').createSignedUrl(path, 3600);
    if (!signed?.signedUrl) return jsonRes({ error: 'No se pudo firmar la descarga' }, 500);

    return jsonRes({ ok: true, url: signed.signedUrl, filename });
  } catch (e) {
    const msg = e instanceof Error ? e.message : 'Error interno';
    console.error('[generate-report]', msg);
    return jsonRes({ error: msg }, 500);
  }
});
