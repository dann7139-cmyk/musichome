import * as Print from 'expo-print';
import * as Sharing from 'expo-sharing';
import { getLogoDataUri, brandHeaderHtml, BRAND_HEADER_CSS } from './pdfBranding';

/**
 * Reporte ejecutivo (admin) / de desempeño (grupo) — mismo estilo formal
 * que el PDF de visa (sql/657/658): logo real, fondo claro, tablas.
 * Reemplaza al viejo generador server-side con pdf-lib (texto plano sin
 * logo). Los NÚMEROS vienen exactamente de los mismos RPCs de siempre
 * (admin_reports_dashboard/admin_country_compare/admin_rankings/
 * admin_alerts o group_performance_dashboard) — solo cambió cómo se
 * dibuja el documento, ninguna cifra ni regla de negocio.
 *
 * Reglas que se preservan tal cual el generador anterior:
 * · Monedas (MXN/USD/CAD) JAMÁS se suman — una sección por moneda.
 * · Fees de procesador sin capturar → "No capturado", nunca estimados.
 * · Modo grupo: SOLO "tu ganancia" — cero comisión de Daricefy, cero
 *   total del cliente, cero fees de procesador.
 */

const esc = (v: unknown): string =>
  String(v ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

const money = (n: any, currency?: string) =>
  n == null ? '—' : `$${Number(n).toLocaleString('es-MX', { maximumFractionDigits: 0 })}${currency ? ` ${currency}` : ''}`;

const MONTH_ES = ['ene', 'feb', 'mar', 'abr', 'may', 'jun', 'jul', 'ago', 'sep', 'oct', 'nov', 'dic'];
const monthLabel = (yyyymm: string) => MONTH_ES[(parseInt(String(yyyymm).split('-')[1] ?? '1', 10) - 1) % 12] ?? yyyymm;

const BASE_CSS = `
  * { box-sizing: border-box; }
  body {
    font-family: -apple-system, Roboto, 'Helvetica Neue', Arial, sans-serif;
    color: #1a1a1a; margin: 0; padding: 36px 40px;
    font-size: 12px; line-height: 1.5;
  }
  ${BRAND_HEADER_CSS}
  .doc-title { font-size: 11px; color: #666; margin-top: 2px; }

  h1 { font-size: 17px; margin: 0 0 4px; color: #0a0a0a; }
  .subtitle { font-size: 12px; color: #555; margin-bottom: 4px; }
  .meta { font-size: 10px; color: #888; margin-bottom: 2px; }

  h2 { font-size: 12px; text-transform: uppercase; letter-spacing: 0.5px; color: #00A344; border-bottom: 2px solid #e6f7ec; padding-bottom: 5px; margin: 22px 0 10px; }
  h3 { font-size: 12.5px; color: #0a0a0a; margin: 12px 0 6px; }

  table { width: 100%; border-collapse: collapse; margin-bottom: 4px; }
  th { text-align: left; font-size: 9.5px; text-transform: uppercase; letter-spacing: 0.3px; color: #777; border-bottom: 2px solid #eee; padding: 6px 5px; }
  td { padding: 6px 5px; border-bottom: 1px solid #f0f0f0; font-size: 11px; vertical-align: top; }
  td.r { text-align: right; font-weight: 600; }

  .kv-table td:first-child { color: #555; width: 62%; }
  .kv-table td:last-child { text-align: right; font-weight: 700; color: #0a0a0a; }

  .empty { font-size: 11px; color: #999; font-style: italic; padding: 6px 0; }

  .summary-grid { display: flex; flex-wrap: wrap; gap: 10px; margin-bottom: 8px; }
  .summary-box { border: 1px solid #e6e6e6; border-radius: 8px; padding: 8px 14px; text-align: center; min-width: 90px; }
  .summary-box .n { font-size: 17px; font-weight: 800; color: #0a0a0a; }
  .summary-box .l { font-size: 9px; color: #777; text-transform: uppercase; letter-spacing: 0.3px; margin-top: 2px; }

  .bars { display: flex; align-items: flex-end; gap: 8px; height: 90px; margin: 10px 0 4px; }
  .bar-col { flex: 1; display: flex; flex-direction: column; align-items: center; justify-content: flex-end; height: 100%; }
  .bar-val { font-size: 8px; color: #777; margin-bottom: 3px; }
  .bar { width: 100%; max-width: 34px; background: #00C853; border-radius: 3px 3px 0 0; }
  .bar-label { font-size: 8.5px; color: #888; margin-top: 4px; }

  .rank-item { display: flex; justify-content: space-between; padding: 5px 0; border-bottom: 1px solid #f3f3f3; font-size: 11px; }
  .rank-item .name { color: #1a1a1a; }
  .rank-item .val { font-weight: 700; color: #0a0a0a; }

  .alert-row { display: flex; justify-content: space-between; padding: 6px 10px; background: #FFF8E1; border-radius: 6px; margin-bottom: 5px; font-size: 11px; }
  .alert-row .n { font-weight: 800; color: #B26A00; }

  .footer { margin-top: 26px; padding-top: 12px; border-top: 1px solid #e6e6e6; font-size: 9px; color: #999; }
  .page-break { page-break-before: always; }
`;

function section(title: string, inner: string): string {
  return `<h2>${esc(title)}</h2>${inner}`;
}
function kvTable(rows: [string, string][]): string {
  if (rows.length === 0) return `<div class="empty">Sin datos en este periodo.</div>`;
  return `<table class="kv-table">${rows.map(([k, v]) => `<tr><td>${esc(k)}</td><td>${esc(v)}</td></tr>`).join('')}</table>`;
}
function barsHtml(items: { label: string; value: number }[]): string {
  if (items.length === 0) return `<div class="empty">Sin datos de tendencia en este periodo.</div>`;
  const max = Math.max(...items.map(i => i.value), 1);
  return `<div class="bars">${items.map(it => `
    <div class="bar-col">
      <div class="bar-val">${money(it.value)}</div>
      <div class="bar" style="height:${Math.max(3, Math.round((it.value / max) * 100))}%"></div>
      <div class="bar-label">${esc(it.label)}</div>
    </div>`).join('')}</div>`;
}
function rankList(title: string, items: any[] | undefined, fmt: (v: any) => string): string {
  const list = (items ?? []).slice(0, 5);
  const body = list.length === 0
    ? `<div class="empty">Sin datos en este periodo.</div>`
    : list.map((it, i) => `<div class="rank-item"><span class="name">${i + 1}. ${esc(it.name)}${it.state ? ` (${esc(it.state)})` : ''}</span><span class="val">${esc(fmt(it.value))}</span></div>`).join('');
  return `<h3>${esc(title)}</h3>${body}`;
}

export interface DaricefyReportPayload {
  mode: 'admin' | 'group';
  from: string;
  to: string;
  filtersLabel: string;
  subtitle: string;
  data: any;
  compare?: any;
  rankings?: any;
  alerts?: any;
  wallet?: any;
}

function buildAdminHtml(opts: DaricefyReportPayload, logoDataUri: string): string {
  const d = opts.data ?? {};
  const curs = d.currencies ?? [];
  const ev = d.events ?? {};
  const com = d.community ?? {};
  const countries = opts.compare?.countries ?? [];
  const trend = d.trend ?? [];
  const trendCurs = [...new Set(trend.map((t: any) => t.moneda))] as string[];
  const al = opts.alerts ?? {};
  const alertRows: [string, number][] = [
    ['Retiros pendientes de grupos', al.retiros_pendientes],
    ['Pagos retenidos más de 3 días', al.pagos_retenidos_viejos],
    ['Disputas abiertas', al.disputas_abiertas],
    ['Reembolsos manuales pendientes', al.reembolsos_pendientes],
    ['Eventos sin cerrar', al.eventos_sin_cerrar],
    ['Grupos suspendidos', al.grupos_suspendidos],
    ['Registros sin país', al.sin_pais],
    ['Cobros sin fee de procesador capturado', al.fees_no_capturados],
  ];
  const activeAlerts = alertRows.filter(([, n]) => Number(n) > 0);

  const financeSections = curs.length === 0
    ? section('Resumen financiero', `<div class="empty">Sin cobros en este periodo con los filtros aplicados.</div>`)
    : curs.map((cur: any) => section(`Resumen financiero · ${cur.moneda}`, kvTable([
        ['Ingreso bruto (cuánto vendimos)', money(cur.total_cobrado, cur.moneda)],
        ['Ganancia neta Daricefy (comisión − procesadores)', money(cur.neto_estimado)],
        ['Comisión real de procesadores', `${money(cur.fees_reales)} (${cur.fees_no_capturados} no capturados)`],
        ['Dinero para grupos', money(cur.dinero_grupos)],
        ['Pendiente por pagar a grupos', money(cur.pendiente_grupos)],
        ['Pagado a grupos', money(cur.pagado_grupos)],
        ['Reembolsos', `${money(cur.reembolsado)} (${cur.reembolsos})`],
      ]))).join('');

  return `
${brandHeaderHtml(logoDataUri, 'Reporte ejecutivo de la plataforma')}
<h1>${esc(opts.subtitle)}</h1>
<div class="meta">Periodo: ${esc(opts.from)} a ${esc(opts.to)} · Filtros: ${esc(opts.filtersLabel)}</div>
<div class="meta">Generado: ${esc(new Date().toLocaleString('es-MX', { timeZone: 'America/Mexico_City' }))} (hora de México)</div>

${financeSections}

${section('Eventos', (ev.total ?? 0) === 0
  ? `<div class="empty">Sin eventos en este periodo con los filtros aplicados.</div>`
  : `<div class="summary-grid">
      <div class="summary-box"><div class="n">${ev.total ?? 0}</div><div class="l">Total</div></div>
      <div class="summary-box"><div class="n">${ev.completados ?? 0}</div><div class="l">Completados</div></div>
      <div class="summary-box"><div class="n">${ev.proximos ?? 0}</div><div class="l">Próximos</div></div>
      <div class="summary-box"><div class="n">${ev.cancelados ?? 0}</div><div class="l">Cancelados</div></div>
      <div class="summary-box"><div class="n">${ev.no_shows ?? 0}</div><div class="l">No-shows</div></div>
      <div class="summary-box"><div class="n">${ev.reembolsados ?? 0}</div><div class="l">Reembolsados</div></div>
    </div>
    <div class="meta">Cancelaciones: ${ev.cancel_cliente ?? 0} por el cliente · ${ev.cancel_grupo ?? 0} por el grupo</div>`)}

${section('Comunidad', (com.grupos?.length ?? 0) === 0 && (com.talentos?.length ?? 0) === 0
  ? `<div class="empty">Sin registros de comunidad con los filtros aplicados.</div>`
  : kvTable([
      ...(com.grupos ?? []).map((g: any): [string, string] => [`Grupos activos · ${g.pais}`, `${g.activos} (+${g.nuevos} nuevos)`]),
      ...(com.talentos ?? []).map((t: any): [string, string] => [`Talentos · ${t.pais}`, String(t.activos)]),
      ['Nuevos registros en el periodo', String(com.nuevos_registros ?? 0)],
    ]))}

${section('Comparativa por países', countries.length === 0
  ? `<div class="empty">Sin datos de países.</div>`
  : `<table><thead><tr><th>País</th><th>Grupos</th><th>Talentos</th><th>Eventos</th><th>Ingresos</th><th>Rating</th></tr></thead><tbody>
      ${countries.map((c: any) => `<tr><td>${esc(c.pais)}</td><td>${c.grupos}</td><td>${c.talentos}</td><td>${c.eventos}</td><td class="r">${money(c.ingresos, c.moneda)}</td><td class="r">${c.rating != null ? `${Number(c.rating).toFixed(1)}/5` : 'Sin reseñas'}</td></tr>`).join('')}
    </tbody></table>`)}

${section('Tendencia mensual (ingreso bruto)', trend.length === 0
  ? `<div class="empty">Sin datos de tendencia en este periodo.</div>`
  : trendCurs.map(tc => `<h3>Moneda: ${esc(tc)}</h3>${barsHtml(trend.filter((t: any) => t.moneda === tc).map((t: any) => ({ label: monthLabel(t.mes), value: Number(t.total) })))}`).join(''))}

<div class="page-break"></div>
${brandHeaderHtml(logoDataUri, 'Reporte ejecutivo de la plataforma · Rankings')}

${section('Rankings · Grupos', [
    rankList('Más eventos completados', opts.rankings?.groups_events, v => String(v)),
    rankList('Más ingresos (su ganancia)', opts.rankings?.groups_income, v => money(v)),
    rankList('Mejor calificación', opts.rankings?.groups_rating, v => `${Number(v).toFixed(1)}/5`),
    rankList('Mayor crecimiento vs periodo anterior', opts.rankings?.groups_growth, v => String(v)),
  ].join(''))}

${section('Rankings · Talentos', [
    rankList('Más contratados', opts.rankings?.talents_hired, v => String(v)),
    rankList('Mejor calificación', opts.rankings?.talents_rating, v => `${Number(v).toFixed(1)}/5`),
    rankList('Más eventos realizados', opts.rankings?.talents_events, v => String(v)),
  ].join(''))}

${section('Rankings · Ciudades', [
    rankList('Más eventos', opts.rankings?.cities_events, v => String(v)),
    rankList('Más ingresos', opts.rankings?.cities_income, v => money(v)),
    rankList('Mayor crecimiento', opts.rankings?.cities_growth, v => String(v)),
  ].join(''))}

${section('Alertas (toda la plataforma)', activeAlerts.length === 0
  ? `<div class="empty">Todo en orden: nada requiere atención.</div>`
  : activeAlerts.map(([lb, n]) => `<div class="alert-row"><span>${esc(lb)}</span><span class="n">${n} — requiere atención</span></div>`).join(''))}

<div class="footer">Las monedas (MXN/USD/CAD) se reportan por separado y nunca se suman. Comisiones de procesador: solo montos reales, nunca estimados.</div>
`;
}

function buildGroupHtml(opts: DaricefyReportPayload, logoDataUri: string): string {
  const d = opts.data ?? {};
  const rt = d.rating ?? {};
  const ev = d.events ?? {};
  const stars = d.stars ?? {};
  const starItems = ['5', '4', '3', '2', '1'].map(k => ({ label: `${k} estrellas`, n: Number(stars[k] ?? 0) }));
  const monies = d.money ?? [];
  const cities = d.cities ?? [];
  const pays = d.payments ?? [];
  const revs = d.reviews ?? [];
  const trend = d.trend ?? [];

  return `
${brandHeaderHtml(logoDataUri, 'Reporte de desempeño')}
<h1>${esc(opts.subtitle)}</h1>
<div class="meta">Periodo: ${esc(opts.from)} a ${esc(opts.to)} · ${esc(opts.filtersLabel)}</div>
<div class="meta">Generado: ${esc(new Date().toLocaleString('es-MX', { timeZone: 'America/Mexico_City' }))} (hora de México)</div>

${section('Desempeño', kvTable([
    ['Calificación promedio', `${Number(rt.promedio ?? 0).toFixed(1)}/5 (${rt.resenas ?? 0} reseñas)`],
    ...starItems.map((s): [string, string] => [s.label, String(s.n)]),
  ]))}

${section('Eventos', `<div class="summary-grid">
    <div class="summary-box"><div class="n">${ev.realizados ?? 0}</div><div class="l">Realizados</div></div>
    <div class="summary-box"><div class="n">${ev.proximos ?? 0}</div><div class="l">Próximos</div></div>
    <div class="summary-box"><div class="n">${ev.cancel_cliente ?? 0}</div><div class="l">Cancel. cliente</div></div>
    <div class="summary-box"><div class="n">${ev.cancel_tuyos ?? 0}</div><div class="l">Cancel. tuyas</div></div>
    <div class="summary-box"><div class="n">${ev.no_shows ?? 0}</div><div class="l">No-shows</div></div>
  </div>
  <div class="meta">Tasa de finalización: ${ev.completion_rate != null ? `${ev.completion_rate}%` : 'Sin eventos cerrados aún'}</div>`)}

${monies.length === 0
  ? section('Tus ganancias', `<div class="empty">Sin cobros en este periodo.</div>`)
  : monies.map((m: any) => section(`Tus ganancias · ${m.moneda}`, kvTable([
      ['Ganancia total', money(m.total, m.moneda)],
      ['Pendiente (se libera al finalizar)', money(m.pendiente)],
      ['Pagado', money(m.pagado)],
      ...(opts.wallet ? [['Disponible para retirar', money(opts.wallet.available_balance)] as [string, string]] : []),
    ]))).join('')}

${section('Tendencia mensual (tu ganancia)', barsHtml(trend.map((t: any) => ({ label: monthLabel(t.mes), value: Number(t.total) }))))}

${section('Ciudades donde trabajaste', cities.length === 0
  ? `<div class="empty">Sin eventos completados con ciudad registrada.</div>`
  : kvTable(cities.map((c: any): [string, string] => [c.ciudad, `${c.eventos} eventos`])))}

<div class="page-break"></div>
${brandHeaderHtml(logoDataUri, 'Reporte de desempeño · Historial')}

${section('Historial de pagos y retiros', pays.length === 0
  ? `<div class="empty">Sin movimientos en este periodo.</div>`
  : kvTable(pays.map((p: any): [string, string] => {
      const fecha = String(p.fecha ?? '').substring(0, 10);
      if (p.tipo === 'retiro') {
        return [`Retiro · ${fecha}${p.cuenta ? ` · ${p.cuenta}` : ''}`,
          `${money(p.amount)} · ${p.estado === 'completed' ? 'Pagado' : p.estado === 'pending' ? 'Pendiente' : p.estado}${p.ref ? ` · Ref ${p.ref}` : ''}`];
      }
      return [`${p.label} · ${fecha}${p.rating ? ` · ${p.rating}/5` : ''}`,
        `${money(p.amount)} · ${p.estado === 'released' ? 'Liberado' : p.estado === 'held' ? 'Pendiente' : p.estado}`];
    })))}

${section('Comentarios recientes de clientes', revs.length === 0
  ? `<div class="empty">Aún sin comentarios con texto.</div>`
  : revs.map((rv: any) => `
      <div style="margin-bottom:10px;">
        <div style="font-weight:700; font-size:11px;">${esc(rv.cliente)} · ${esc(rv.rating)}/5 · ${esc(String(rv.fecha ?? '').substring(0, 10))}</div>
        <div style="font-size:11px; color:#555; font-style:italic;">"${esc(rv.comment)}"</div>
      </div>`).join(''))}

<div class="footer">Reporte generado por Daricefy — solo tus ganancias, nunca información financiera de la plataforma.</div>
`;
}

export async function exportDaricefyReportPdf(opts: DaricefyReportPayload): Promise<void> {
  const logoDataUri = await getLogoDataUri();
  const body = opts.mode === 'admin' ? buildAdminHtml(opts, logoDataUri) : buildGroupHtml(opts, logoDataUri);
  const html = `<!doctype html><html><head><meta charset="utf-8"><style>${BASE_CSS}</style></head><body>${body}</body></html>`;

  const { uri } = await Print.printToFileAsync({ html, base64: false });
  if (await Sharing.isAvailableAsync()) {
    await Sharing.shareAsync(uri, { mimeType: 'application/pdf', dialogTitle: opts.subtitle, UTI: 'com.adobe.pdf' });
  }
}
