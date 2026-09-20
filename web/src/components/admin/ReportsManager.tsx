"use client";

/**
 * ReportsManager — paridad con AdminReportsScreen.tsx ("Centro de
 * Inteligencia") de la app (petición real 2026-09-18: "déjalo listo todo
 * como lo veo en mi app"). Mismas RPC exactas: admin_reports_dashboard,
 * admin_country_compare, admin_rankings, admin_alerts,
 * admin_pending_country_list, admin_set_country. Monedas siempre
 * separadas, cero estimaciones — mismas reglas que la app.
 *
 * Exportar: Excel llama la MISMA función `generate-report` que la app
 * (misma hoja de cálculo real). El PDF en la app usa expo-print — aquí,
 * en vez de replicar esa librería nativa, se arma una vista imprimible
 * con los MISMOS datos ya cargados en pantalla (mismo patrón ya usado
 * para el PDF de demanda cruzada) y se usa "Guardar como PDF" del propio
 * navegador — mismo resultado final, sin depender de nada nativo.
 */

import { useCallback, useEffect, useState } from "react";
import { supabase } from "@/lib/supabase";
import { Spinner, EmptyBox } from "./ui";

const RANGES = [
  { key: "30d", label: "30 días", days: 30 },
  { key: "90d", label: "90 días", days: 90 },
  { key: "year", label: "1 año", days: 365 },
  { key: "all", label: "Todo", days: 0 },
];
const COUNTRIES = ["México", "Estados Unidos", "Canadá"];
const CC_OF_COUNTRY: Record<string, string> = { "México": "MX", "Estados Unidos": "US", "Canadá": "CA" };
const FLAG: Record<string, string> = { "México": "🇲🇽", "Estados Unidos": "🇺🇸", "Canadá": "🇨🇦" };
const CURRENCY_COUNTRY: Record<string, string> = { MXN: "🇲🇽 México", USD: "🇺🇸 Estados Unidos", CAD: "🇨🇦 Canadá" };
const TABS = [
  { key: "resumen", label: "Resumen" },
  { key: "finanzas", label: "Finanzas" },
  { key: "eventos", label: "Eventos" },
  { key: "paises", label: "Países" },
  { key: "rankings", label: "Rankings" },
  { key: "alertas", label: "Alertas" },
];

const money = (n: number | null | undefined) => `$${Number(n ?? 0).toLocaleString("es-MX", { minimumFractionDigits: 2 })}`;

function Kpi({ label, value, detail, gold }: { label: string; value: string; detail?: string; gold?: boolean }) {
  return (
    <div className={`rounded-xl border p-3 ${gold ? "border-yellow-400/30 bg-yellow-400/5" : "border-brand-border bg-brand-card"}`}>
      <p className="text-[11px] text-brand-muted">{label}</p>
      <p className={`text-lg font-bold ${gold ? "text-yellow-400" : "text-white"}`}>{value}</p>
      {detail && <p className="text-[10px] text-brand-muted">{detail}</p>}
    </div>
  );
}

function RankList({ title, items, fmt, extra }: { title: string; items: any[]; fmt: (v: any) => string; extra?: (x: any) => string }) {
  return (
    <div className="rounded-xl border border-brand-border bg-brand-card p-3">
      <p className="mb-2 text-xs font-semibold text-white">{title}</p>
      {!items || items.length === 0 ? (
        <p className="text-xs text-brand-muted">Sin datos en este rango</p>
      ) : (
        <div className="space-y-1.5">
          {items.map((it: any, i: number) => (
            <div key={i} className="flex items-center gap-2 text-sm">
              <span className="w-4 text-brand-green">{i + 1}</span>
              <div className="min-w-0 flex-1">
                <p className="truncate text-white">{it.name}</p>
                {(it.state || extra) && <p className="truncate text-[11px] text-brand-muted">{[it.state, extra?.(it)].filter(Boolean).join(" · ")}</p>}
              </div>
              <span className="font-semibold text-white">{fmt(it.value)}</span>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}

export default function ReportsManager() {
  const [tab, setTab] = useState("resumen");
  const [country, setCountry] = useState<string | null>(null);
  const [range, setRange] = useState("90d");
  const [data, setData] = useState<any>(null);
  const [compare, setCompare] = useState<any>(null);
  const [rankings, setRankings] = useState<any>(null);
  const [alerts, setAlerts] = useState<any>(null);
  const [loading, setLoading] = useState(true);
  const [exporting, setExporting] = useState(false);
  const [pendOpen, setPendOpen] = useState(false);
  const [pendItems, setPendItems] = useState<any[]>([]);

  const fromDate = useCallback(() => {
    const r = RANGES.find((x) => x.key === range) ?? RANGES[1];
    return r.days > 0 ? new Date(Date.now() - r.days * 86400000).toISOString().slice(0, 10) : null;
  }, [range]);

  const load = useCallback(async () => {
    const from = fromDate();
    const [dRes, cRes, rRes, aRes] = await Promise.all([
      supabase.rpc("admin_reports_dashboard", { p_from: from, p_to: null, p_country: country, p_state: null, p_city: null }),
      supabase.rpc("admin_country_compare", { p_from: from, p_to: null }),
      supabase.rpc("admin_rankings", { p_from: from, p_to: null, p_country: country, p_state: null, p_limit: 5 }),
      supabase.rpc("admin_alerts"),
    ]);
    if ((dRes.data as any)?.ok) setData(dRes.data);
    if ((cRes.data as any)?.ok) setCompare(cRes.data);
    if ((rRes.data as any)?.ok) setRankings(rRes.data);
    if ((aRes.data as any)?.ok) setAlerts(aRes.data);
    setLoading(false);
  }, [country, fromDate]);

  useEffect(() => { setLoading(true); load(); }, [load]);

  const openPending = async () => {
    const { data: d } = await supabase.rpc("admin_pending_country_list");
    setPendItems((d as any)?.ok ? (d as any).items ?? [] : []);
    setPendOpen(true);
  };
  const assignCountry = async (item: any, co: string) => {
    const { data: r } = await supabase.rpc("admin_set_country", { p_entity: item.entity, p_id: item.id, p_country: co });
    if ((r as any)?.ok) { setPendItems((prev) => prev.filter((x) => x.id !== item.id)); load(); }
    else window.alert((r as any)?.error ?? "No se pudo asignar.");
  };

  const currencies: any[] = data?.currencies ?? [];
  const ev = data?.events ?? {};
  const com = data?.community ?? {};
  const cancelRate = ev.total > 0 ? Math.round((ev.cancelados / ev.total) * 100) : 0;
  const pendTotal = (compare?.pendientes?.grupos ?? 0) + (compare?.pendientes?.talentos ?? 0);
  const alertKeys = ["retiros_pendientes", "fees_no_capturados", "sin_pais", "grupos_suspendidos", "disputas_abiertas", "reembolsos_pendientes", "eventos_sin_cerrar", "pagos_retenidos_viejos", "eventos_multi_grupo_revisar"];
  const alertCount = alerts ? alertKeys.reduce((s, k) => s + (Number(alerts[k]) > 0 ? 1 : 0), 0) : 0;

  const runExportExcel = async () => {
    setExporting(true);
    try {
      const { data: { session } } = await supabase.auth.getSession();
      if (!session) throw new Error("Sesión expirada.");
      const { data: res, error } = await supabase.functions.invoke("generate-report", {
        body: { mode: "admin", format: "xlsx", country: country ? (CC_OF_COUNTRY[country] ?? "all") : "all", state: null, from: fromDate() ?? "2000-01-01", to: new Date().toISOString().slice(0, 10) },
        headers: { Authorization: `Bearer ${session.access_token}` },
      });
      if (error) throw new Error(error.message);
      if ((res as any)?.error) throw new Error((res as any).error);
      const url = (res as any)?.url;
      if (!url) throw new Error("No se generó el archivo.");
      window.open(url, "_blank");
    } catch (e: any) {
      window.alert(e?.message ?? "No se pudo exportar.");
    } finally {
      setExporting(false);
    }
  };

  // PDF — arma la vista imprimible con los datos YA cargados en pantalla
  // (mismo patrón que el PDF de demanda cruzada de Operación → Visa).
  const runExportPdf = () => {
    const win = window.open("", "_blank");
    if (!win) { window.alert("Tu navegador bloqueó la ventana — permite pop-ups para descargar el PDF."); return; }
    const scope = country ? `${FLAG[country] ?? ""} ${country}` : "🌎 Todos los países";
    const rangeLabel = RANGES.find((r) => r.key === range)?.label ?? "";
    const moneyRows = currencies.map((cur: any) => `
      <h3>💰 ${CURRENCY_COUNTRY[cur.moneda] ?? cur.moneda} · ${cur.moneda}</h3>
      <table>
        <tr><td>Vendido</td><td>${money(cur.total_cobrado)}</td></tr>
        <tr><td>Ganancia neta</td><td>${money(cur.neto_estimado)}</td></tr>
        <tr><td>Por pagar a grupos</td><td>${money(cur.pendiente_grupos)}</td></tr>
        <tr><td>Ya pagado a grupos</td><td>${money(cur.pagado_grupos)}</td></tr>
        <tr><td>Comisión de procesador</td><td>${money(cur.fees_reales)}</td></tr>
        <tr><td>Reembolsado</td><td>${money(cur.reembolsado)} (${cur.reembolsos ?? 0})</td></tr>
      </table>`).join("");
    const countryRows = (compare?.countries ?? []).map((c: any) => `
      <tr><td>${c.pais}</td><td>${c.grupos}</td><td>${c.talentos}</td><td>${c.eventos}</td><td>${money(c.ingresos)} ${c.moneda}</td></tr>
    `).join("");
    win.document.write(`<!doctype html><html><head><meta charset="utf-8"><title>Reporte Daricefy</title>
      <style>
        body{font-family:system-ui,-apple-system,sans-serif;color:#111;padding:32px;max-width:800px;margin:0 auto;}
        h1{font-size:22px;margin-bottom:2px;} h2{font-size:15px;color:#555;margin-top:0;font-weight:normal;}
        h3{font-size:14px;margin:20px 0 6px;}
        table{width:100%;border-collapse:collapse;margin-bottom:10px;font-size:13px;}
        td,th{border-bottom:1px solid #ddd;padding:6px 8px;text-align:left;}
        .foot{margin-top:30px;font-size:11px;color:#999;}
      </style></head><body>
      <h1>📊 Reporte Daricefy</h1>
      <h2>${scope} · ${rangeLabel} · ${data?.from ?? ""} — ${data?.to ?? ""}</h2>
      ${moneyRows || "<p>Sin datos financieros en este rango.</p>"}
      <h3>🌎 Comparativa por país</h3>
      <table><tr><th>País</th><th>Grupos</th><th>Talentos</th><th>Eventos</th><th>Ingresos</th></tr>${countryRows}</table>
      <h3>🗓 Eventos</h3>
      <table>
        <tr><td>Total</td><td>${ev.total ?? 0}</td></tr>
        <tr><td>Completados</td><td>${ev.completados ?? 0}</td></tr>
        <tr><td>Próximos</td><td>${ev.proximos ?? 0}</td></tr>
        <tr><td>Cancelados</td><td>${ev.cancelados ?? 0} (${cancelRate}%)</td></tr>
        <tr><td>No-shows</td><td>${ev.no_shows ?? 0}</td></tr>
      </table>
      <p class="foot">Generado automáticamente por Daricefy.</p>
      <script>window.onload = () => window.print();</script>
      </body></html>`);
    win.document.close();
  };

  if (loading) return <Spinner />;

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <h3 className="text-base font-semibold text-white">📊 Centro de Inteligencia</h3>
        <div className="flex gap-2">
          <button onClick={runExportPdf} className="rounded-lg border border-brand-border px-3 py-2 text-xs font-medium text-brand-muted hover:text-white">📄 PDF</button>
          <button onClick={runExportExcel} disabled={exporting} className="rounded-lg bg-brand-green px-3 py-2 text-xs font-bold text-black disabled:opacity-50">{exporting ? "…" : "📊 Excel"}</button>
        </div>
      </div>

      <div className="flex flex-wrap gap-2">
        {TABS.map((t) => (
          <button key={t.key} onClick={() => setTab(t.key)} className={`rounded-full px-3 py-1.5 text-xs font-medium ${tab === t.key ? "bg-brand-green text-black" : "border border-brand-border text-brand-muted"}`}>
            {t.label}{t.key === "alertas" && alertCount > 0 ? ` (${alertCount})` : ""}
          </button>
        ))}
      </div>

      {tab !== "paises" && (
        <div className="flex flex-wrap gap-2">
          <button onClick={() => setCountry(null)} className={`rounded-full px-3 py-1.5 text-xs font-medium ${!country ? "bg-brand-green text-black" : "border border-brand-border text-brand-muted"}`}>🌎 Todos</button>
          {COUNTRIES.map((c) => (
            <button key={c} onClick={() => setCountry(c)} className={`rounded-full px-3 py-1.5 text-xs font-medium ${country === c ? "bg-brand-green text-black" : "border border-brand-border text-brand-muted"}`}>{FLAG[c]} {c}</button>
          ))}
        </div>
      )}
      {tab === "paises" && <p className="text-xs text-brand-muted">Esta pestaña siempre compara los 3 países a la vez.</p>}

      <div className="flex flex-wrap gap-2">
        {RANGES.map((r) => (
          <button key={r.key} onClick={() => setRange(r.key)} className={`rounded-full px-3 py-1.5 text-xs font-medium ${range === r.key ? "bg-brand-green/20 text-brand-green" : "border border-brand-border text-brand-muted"}`}>{r.label}</button>
        ))}
      </div>

      {tab === "resumen" && (
        <div className="space-y-4">
          {alertCount > 0 && (
            <button onClick={() => setTab("alertas")} className="w-full rounded-xl border border-red-400/40 bg-red-400/5 p-3 text-left text-sm font-semibold text-red-400">
              🚨 {alertCount} cosa{alertCount !== 1 ? "s" : ""} requiere{alertCount === 1 ? "" : "n"} tu atención
            </button>
          )}
          {pendTotal > 0 && (
            <button onClick={openPending} className="w-full rounded-xl border border-yellow-400/40 bg-yellow-400/5 p-3 text-left text-sm font-semibold text-yellow-400">
              🏳️ {pendTotal} registros sin país asignado
            </button>
          )}
          {currencies.length === 0 ? <EmptyBox icon="💰" text="Sin datos financieros en este rango" /> : (
            <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
              {currencies.map((cur: any) => (
                <Kpi key={cur.moneda} label={`Vendido · ${cur.moneda}`} value={money(cur.total_cobrado)} detail={`${cur.eventos_cobrados} eventos`} />
              ))}
            </div>
          )}
          <p className="text-sm font-semibold text-white">🌎 ¿Cómo va cada país?</p>
          <div className="grid gap-3 sm:grid-cols-3">
            {(compare?.countries ?? []).map((c: any) => (
              <div key={c.pais} className="rounded-xl border border-brand-border bg-brand-card p-3">
                <p className="mb-1 text-sm font-semibold text-white">{c.pais === "País no definido" ? "🏳️" : FLAG[c.pais] ?? "🌎"} {c.pais}</p>
                <p className="text-xs text-brand-muted">{c.grupos} grupos · {c.talentos} talentos · {c.eventos} eventos</p>
                <p className="mt-1 font-bold text-brand-green">{money(c.ingresos)} {c.moneda}</p>
              </div>
            ))}
          </div>
        </div>
      )}

      {tab === "finanzas" && (
        currencies.length === 0 ? <EmptyBox icon="💰" text="Sin datos financieros en este rango" /> : (
          <div className="space-y-4">
            {currencies.map((cur: any) => (
              <div key={cur.moneda}>
                <p className="mb-2 text-sm font-semibold text-white">💰 {CURRENCY_COUNTRY[cur.moneda] ?? cur.moneda} · {cur.moneda}</p>
                <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
                  <Kpi gold label="Vendido" value={money(cur.total_cobrado)} detail={`${cur.eventos_cobrados} eventos cobrados`} />
                  <Kpi gold label="Ganancia neta" value={money(cur.neto_estimado)} />
                  <Kpi label="Por pagar a grupos" value={money(cur.pendiente_grupos)} />
                  <Kpi label="Ya pagado a grupos" value={money(cur.pagado_grupos)} />
                  <Kpi label="Dinero de grupos" value={money(cur.dinero_grupos)} />
                  <Kpi label="Comisión de procesador" value={money(cur.fees_reales)} detail={cur.fees_no_capturados > 0 ? `${cur.fees_no_capturados} sin capturar` : "todas reales"} />
                  <Kpi label="Reembolsado" value={money(cur.reembolsado)} detail={`${cur.reembolsos ?? 0} reembolsos`} />
                </div>
              </div>
            ))}
          </div>
        )
      )}

      {tab === "eventos" && (
        <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
          <Kpi label="Total del rango" value={String(ev.total ?? 0)} />
          <Kpi label="Completados" value={String(ev.completados ?? 0)} detail={ev.total > 0 ? `${Math.round(((ev.completados ?? 0) / ev.total) * 100)}%` : undefined} />
          <Kpi label="Próximos" value={String(ev.proximos ?? 0)} />
          <Kpi label="Cancelados" value={String(ev.cancelados ?? 0)} detail={`${cancelRate}% · cliente ${ev.cancel_cliente ?? 0} / grupo ${ev.cancel_grupo ?? 0}`} />
          <Kpi label="No-shows" value={String(ev.no_shows ?? 0)} />
          <Kpi label="Reembolsados" value={String(ev.reembolsados ?? 0)} />
        </div>
      )}

      {tab === "paises" && (
        <div className="space-y-4">
          <button onClick={openPending} className="w-full rounded-xl border border-yellow-400/40 bg-yellow-400/5 p-3 text-left text-sm font-semibold text-yellow-400">
            🏳️ Registros pendientes de clasificar: {pendTotal} {pendTotal > 0 ? "— corregir →" : "— todo clasificado ✅"}
          </button>
          <div className="grid gap-3 sm:grid-cols-3">
            {(compare?.countries ?? []).map((c: any) => (
              <div key={c.pais} className="rounded-xl border border-brand-border bg-brand-card p-3">
                <p className="mb-1 text-sm font-semibold text-white">{c.pais === "País no definido" ? "🏳️" : FLAG[c.pais] ?? "🌎"} {c.pais}</p>
                <p className="text-xs text-brand-muted">{c.grupos} grupos · {c.talentos} talentos · {c.eventos} eventos</p>
                <p className="mt-1 font-bold text-brand-green">{money(c.ingresos)} {c.moneda}</p>
                {c.rating != null && <p className="text-xs text-yellow-400">★ {Number(c.rating).toFixed(1)}</p>}
              </div>
            ))}
          </div>
          <p className="text-sm font-semibold text-white">👥 Detalle</p>
          <div className="space-y-1.5 text-sm">
            {(com.grupos ?? []).map((g: any) => (
              <div key={`g-${g.pais}`} className="flex justify-between rounded-lg border border-brand-border bg-brand-card px-3 py-2">
                <span className="text-white">{FLAG[g.pais] ?? "🏳️"} Grupos activos · {g.pais}</span>
                <span className="text-brand-muted">{g.activos}{g.nuevos > 0 ? ` (+${g.nuevos} nuevos)` : ""}</span>
              </div>
            ))}
            {(com.talentos ?? []).map((t: any) => (
              <div key={`t-${t.pais}`} className="flex justify-between rounded-lg border border-brand-border bg-brand-card px-3 py-2">
                <span className="text-white">🎤 Talentos · {t.pais}</span>
                <span className="text-brand-muted">{t.activos}{t.nuevos > 0 ? ` (+${t.nuevos} nuevos)` : ""}</span>
              </div>
            ))}
          </div>
        </div>
      )}

      {tab === "rankings" && (
        <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
          <RankList title="🏆 Grupos · más eventos" items={rankings?.groups_events} fmt={(v) => String(v)} />
          <RankList title="🏆 Grupos · más ingresos" items={rankings?.groups_income} fmt={money} />
          <RankList title="🏆 Grupos · mejor calificación" items={rankings?.groups_rating} fmt={(v) => `★ ${Number(v).toFixed(1)}`} extra={(x) => `${x.extra} reseñas`} />
          <RankList title="🎤 Talentos · más contratados" items={rankings?.talents_hired} fmt={(v) => String(v)} />
          <RankList title="🎤 Talentos · mejor calificación" items={rankings?.talents_rating} fmt={(v) => `★ ${Number(v).toFixed(1)}`} extra={(x) => `${x.extra} reseñas`} />
          <RankList title="🏙 Ciudades · más eventos" items={rankings?.cities_events} fmt={(v) => String(v)} />
          <RankList title="🏙 Ciudades · más ingresos" items={rankings?.cities_income} fmt={money} />
        </div>
      )}

      {tab === "alertas" && (
        !alerts ? <Spinner /> : alertCount === 0 ? (
          <div className="rounded-xl border border-brand-green/30 bg-brand-green/5 p-6 text-center">
            <p className="font-semibold text-brand-green">✅ Todo bien</p>
            <p className="text-xs text-brand-muted">No hay nada urgente ahora mismo.</p>
          </div>
        ) : (
          <div className="space-y-2">
            {[
              [alerts.retiros_pendientes, "💸", "Retiros pendientes"],
              [alerts.pagos_retenidos_viejos, "⏳", "Pagos retenidos hace tiempo"],
              [alerts.disputas_abiertas, "⚖️", "Disputas abiertas"],
              [alerts.reembolsos_pendientes, "↩️", "Reembolsos pendientes"],
              [alerts.eventos_sin_cerrar, "🕐", "Eventos sin cerrar"],
              [alerts.eventos_multi_grupo_revisar, "🔊", "Eventos multi-proveedor para revisar"],
              [alerts.grupos_suspendidos, "🚫", "Grupos suspendidos"],
              [alerts.fees_no_capturados, "🧾", "Comisiones sin capturar"],
            ].filter(([n]) => Number(n) > 0).map(([n, icon, label]: any) => (
              <div key={label} className="flex items-center justify-between rounded-xl border border-red-400/30 bg-red-400/5 px-4 py-3">
                <span className="text-sm text-white">{icon} {label}</span>
                <span className="rounded-full bg-red-400/20 px-2.5 py-1 text-xs font-bold text-red-400">{n}</span>
              </div>
            ))}
            {alerts.sin_pais > 0 && (
              <button onClick={openPending} className="flex w-full items-center justify-between rounded-xl border border-red-400/30 bg-red-400/5 px-4 py-3 text-left">
                <span className="text-sm text-white">🏳️ Sin país asignado</span>
                <span className="rounded-full bg-red-400/20 px-2.5 py-1 text-xs font-bold text-red-400">{alerts.sin_pais}</span>
              </button>
            )}
          </div>
        )
      )}

      {pendOpen && (
        <div className="fixed inset-0 z-50 flex items-end justify-center bg-black/60 p-4 sm:items-center" onClick={() => setPendOpen(false)}>
          <div onClick={(e) => e.stopPropagation()} className="max-h-[80vh] w-full max-w-md overflow-y-auto rounded-2xl border border-brand-border bg-brand-card p-5">
            <h3 className="mb-1 text-lg font-bold text-white">🏳️ Pendientes de clasificar ({pendItems.length})</h3>
            <p className="mb-3 text-xs text-brand-muted">Elige un país para cada uno — nunca se asigna solo.</p>
            {pendItems.length === 0 ? (
              <p className="py-8 text-center text-brand-green">✅ Todo clasificado</p>
            ) : (
              <div className="space-y-2">
                {pendItems.map((item) => (
                  <div key={`${item.entity}-${item.id}`} className="rounded-lg border border-brand-border p-2.5">
                    <p className="text-sm text-white">{item.entity === "group" ? "🎸" : "🎤"} {item.name ?? "Sin nombre"}</p>
                    <p className="mb-2 text-[11px] text-brand-muted">{item.entity === "group" ? "Grupo" : "Talento"}{item.state ? ` · ${item.state}` : ""}{item.city ? ` · ${item.city}` : ""}</p>
                    <div className="flex gap-1.5">
                      {COUNTRIES.map((c) => (
                        <button key={c} onClick={() => assignCountry(item, c)} className="flex-1 rounded-lg border border-brand-border py-1 text-xs text-brand-muted hover:border-brand-green hover:text-brand-green">{FLAG[c]}</button>
                      ))}
                    </div>
                  </div>
                ))}
              </div>
            )}
          </div>
        </div>
      )}
    </div>
  );
}
