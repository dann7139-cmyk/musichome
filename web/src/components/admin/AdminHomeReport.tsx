"use client";

/**
 * AdminHomeReport — "Resumen" del admin completo en la web, pensado para
 * verse casi igual que DashboardScreen.tsx de la app móvil (reporte +
 * acciones rápidas + alertas), acomodado para pantalla ancha de
 * escritorio. Mismas RPC/queries que la app móvil, corrigiendo 2 columnas
 * que ya no existen en el esquema real (`profiles.name` → `full_name`,
 * `disputes` no tiene `group_id` directo — se junta vía `reservations`).
 *
 * Las acciones rápidas que ya tienen una sección real en este panel web
 * navegan ahí (Anuncios, Grupos, Mapa, Operación). Las que todavía no
 * tienen pantalla propia en la web (Talentos, Estadísticas, Finanzas,
 * Reportes con Excel/PDF) muestran un aviso claro — no botones muertos.
 */

import { useCallback, useEffect, useState } from "react";
import { supabase } from "@/lib/supabase";
import { Spinner, ActionBtn, Section } from "./ui";

const money = (n: number | null | undefined) =>
  `$${Number(n ?? 0).toLocaleString("es-MX", { maximumFractionDigits: 0 })}`;

const MONTH_SHORT = ["ENE","FEB","MAR","ABR","MAY","JUN","JUL","AGO","SEP","OCT","NOV","DIC"];

const NOT_YET_WEB = new Set<string>([]);

const QUICK_ACTIONS: { key: string; icon: string; label: string; nav: string }[] = [
  { key: "verifications", icon: "🛡️", label: "Verificaciones",          nav: "ops" },
  { key: "disputes",      icon: "⚠️", label: "Disputas",                nav: "self" },
  { key: "groups",        icon: "👥", label: "Proveedores",             nav: "groups" },
  { key: "talents",       icon: "💼", label: "Talentos",                nav: "talents" },
  { key: "stats",         icon: "📊", label: "Estadísticas",            nav: "stats" },
  { key: "finances",      icon: "💰", label: "Finanzas",                nav: "finances" },
  { key: "reports",       icon: "📈", label: "Reportes",                nav: "reports" },
  { key: "liveMap",       icon: "🗺️", label: "Mapa en vivo",            nav: "map" },
  { key: "withdrawals",   icon: "🏦", label: "Retiros",                 nav: "ops" },
  { key: "ads",           icon: "📢", label: "Anuncios",                nav: "ads" },
  { key: "concierge",     icon: "📞", label: "Conserjería",             nav: "ops" },
  { key: "providers",     icon: "🆕", label: "Solicitudes proveedores", nav: "ops" },
];

export default function AdminHomeReport({ onNavigateTab }: { onNavigateTab: (tab: string) => void }) {
  const [loading, setLoading] = useState(true);
  const [statusCounts, setStatusCounts] = useState({ pending: 0, confirmed: 0, in_progress: 0, completed: 0, cancelled: 0 });
  const [revenueTotal, setRevenueTotal] = useState(0);
  const [commTotal, setCommTotal] = useState(0);
  const [totalGroups, setTotalGroups] = useState(0);
  const [totalClients, setTotalClients] = useState(0);
  const [openRequests, setOpenRequests] = useState(0);
  const [monthlyBars, setMonthlyBars] = useState<{ label: string; count: number }[]>([]);
  const [topGroups, setTopGroups] = useState<{ name: string; count: number; revenue: number }[]>([]);
  const [liveEvents, setLiveEvents] = useState<any[]>([]);
  const [todayEvents, setTodayEvents] = useState<any[]>([]);
  const [pendingVerif, setPendingVerif] = useState<any[]>([]);
  const [openDisputes, setOpenDisputes] = useState<any[]>([]);
  const [pendingMedia, setPendingMedia] = useState(0);
  const [pendingAds, setPendingAds] = useState(0);
  const [pendingConcierge, setPendingConcierge] = useState(0);
  const [pendingProviderApps, setPendingProviderApps] = useState(0);
  const [noShows, setNoShows] = useState<any[]>([]);
  const [stuckEvents, setStuckEvents] = useState<any[]>([]);
  const [stuckServiceEvents, setStuckServiceEvents] = useState<any[]>([]);
  const [unverifiedPayouts, setUnverifiedPayouts] = useState<any[]>([]);
  // 2026-09-18 — petición real: "quiero que en requieren atención se vea
  // las transferencias que tengo que hacer, porque en el cel está muy
  // escondido". Antes "Requieren atención" no tenía NINGÚN conteo de
  // dinero pendiente — solo vivía como badge dentro de Operación → Pagos.
  const [pendingTransfers, setPendingTransfers] = useState(0);
  const [busyId, setBusyId] = useState<string | null>(null);

  const load = useCallback(async () => {
    const todayStr = new Date().toISOString().split("T")[0];
    const sixMonthsAgo = new Date();
    sixMonthsAgo.setMonth(sixMonthsAgo.getMonth() - 5);
    sixMonthsAgo.setDate(1);
    const fromDate = sixMonthsAgo.toISOString().split("T")[0];

    const mediaData = await supabase.from("groups").select("id", { count: "exact", head: true }).or("photo_status.eq.pending,video_status.eq.pending");
    const eventPostsData = await supabase.from("group_event_posts").select("id", { count: "exact", head: true }).eq("status", "pending");
    const carouselVideosData = await supabase.from("group_videos").select("id", { count: "exact", head: true }).eq("status", "pending");
    setPendingMedia((mediaData.count ?? 0) + (eventPostsData.count ?? 0) + (carouselVideosData.count ?? 0));

    const adsData = await supabase.from("advertisements").select("id", { count: "exact", head: true }).eq("status", "pending_review");
    setPendingAds(adsData.count ?? 0);

    const conciergeData = await supabase.rpc("admin_get_concierge_quotes", { p_limit: 500 });
    setPendingConcierge((conciergeData.data as any)?.items?.length ?? 0);
    const providerAppsData = await supabase.rpc("admin_get_provider_applications", { p_status: "pending" });
    setPendingProviderApps((providerAppsData.data as any)?.items?.length ?? 0);

    const [resAll, verData, todayData, disputeData, liveData, groupsData, clientsData, reqData] = await Promise.all([
      supabase.from("reservations").select("status, total_price, created_at, group_id, group:groups(name)"),
      supabase.from("verification_requests").select("id, group:groups(name)").eq("status", "pending").limit(5),
      supabase.from("reservations").select("id, event_time, group:groups(name), client:profiles(full_name), status").eq("event_date", todayStr).in("status", ["confirmed", "in_progress"]).order("event_time"),
      // disputes NO tiene group_id directo — se llega al grupo vía reservations (hallazgo real, ver comentario arriba)
      supabase.from("disputes").select("id, reason, created_at, reservation:reservations(group:groups(name))").eq("status", "open").limit(5),
      supabase.from("reservations").select("id, group:groups(name), client:profiles(full_name), address").eq("status", "in_progress").order("event_started_at", { ascending: false }),
      supabase.from("groups").select("id", { count: "exact", head: true }).eq("is_active", true),
      supabase.from("profiles").select("id", { count: "exact", head: true }).eq("role", "client"),
      supabase.from("event_requests").select("id", { count: "exact", head: true }).eq("status", "open"),
    ]);

    supabase.rpc("admin_finance_summary", { p_from: null, p_to: null }).then(({ data: fin }) => {
      const mxn = ((fin as any)?.currencies ?? []).find((m: any) => m.moneda === "MXN");
      if (mxn) {
        setRevenueTotal(Number(mxn.total_cobrado ?? 0));
        setCommTotal(Number(mxn.comision_daricefy ?? 0));
      }
    });

    const allRes = resAll.data ?? [];
    const counts = { pending: 0, confirmed: 0, in_progress: 0, completed: 0, cancelled: 0 } as any;
    const groupMap: Record<string, { name: string; count: number; revenue: number }> = {};
    const monthly: Record<string, number> = {};
    allRes.forEach((r: any) => {
      if (counts[r.status] !== undefined) counts[r.status]++;
      if (r.group_id) {
        if (!groupMap[r.group_id]) groupMap[r.group_id] = { name: r.group?.name ?? "—", count: 0, revenue: 0 };
        groupMap[r.group_id].count++;
        if (r.status === "completed") groupMap[r.group_id].revenue += r.total_price ?? 0;
      }
      const mo = r.created_at?.substring(0, 7);
      if (mo && mo >= fromDate.substring(0, 7)) monthly[mo] = (monthly[mo] ?? 0) + 1;
    });
    const bars = Array.from({ length: 6 }, (_, i) => {
      const d = new Date(); d.setMonth(d.getMonth() - (5 - i));
      const key = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}`;
      return { label: MONTH_SHORT[d.getMonth()], count: monthly[key] ?? 0 };
    });
    const top = Object.values(groupMap).sort((a, b) => b.count - a.count).slice(0, 5);

    setStatusCounts(counts);
    setTotalGroups(groupsData.count ?? 0);
    setTotalClients(clientsData.count ?? 0);
    setOpenRequests(reqData.count ?? 0);
    setMonthlyBars(bars);
    setTopGroups(top);
    setLiveEvents(liveData.data ?? []);
    setTodayEvents(todayData.data ?? []);
    setPendingVerif(verData.data ?? []);
    setOpenDisputes(disputeData.data ?? []);

    const [ns, stuck, stuckSvc, unver, gp, gg, wd] = await Promise.all([
      supabase.rpc("admin_get_no_shows", { p_limit: 50 }),
      supabase.rpc("admin_get_stuck_events", { p_limit: 50 }),
      supabase.rpc("admin_get_stuck_service_events", { p_limit: 50 }),
      supabase.rpc("admin_get_unverified_payouts", { p_limit: 50 }),
      supabase.rpc("admin_get_pending_group_payments", { p_limit: 50 }),
      supabase.rpc("admin_get_pending_gift_payouts"),
      supabase.rpc("admin_withdrawals_queue", { p_limit: 60 }),
    ]);
    setNoShows((ns.data as any)?.items ?? []);
    setStuckEvents((stuck.data as any)?.items ?? []);
    setStuckServiceEvents((stuckSvc.data as any)?.items ?? []);
    setUnverifiedPayouts((unver.data as any)?.items ?? []);
    const withdrawalsPending = Array.isArray(wd.data)
      ? wd.data.filter((w: any) => w.status === "pending" || w.status === "processing").length
      : 0;
    setPendingTransfers(((gp.data as any)?.items?.length ?? 0) + ((gg.data as any)?.items?.length ?? 0) + withdrawalsPending);
    setLoading(false);
  }, []);

  useEffect(() => { load(); }, [load]);

  const verifyRelease = async (ev: any) => {
    setBusyId(ev.id);
    const { data, error } = await supabase.rpc("admin_verify_arrival_and_release", { p_reservation_id: ev.id });
    setBusyId(null);
    if (error || (data as any)?.ok === false) { window.alert((data as any)?.error ?? error?.message ?? "No se pudo procesar."); return; }
    load();
  };
  const blockPayout = async (ev: any) => {
    if (!window.confirm("¿Confirmas que el grupo NO llegó? Esto bloquea el pago.")) return;
    setBusyId(ev.id);
    const { data, error } = await supabase.rpc("admin_block_unverified_payout", { p_reservation_id: ev.id });
    setBusyId(null);
    if (error || (data as any)?.ok === false) { window.alert((data as any)?.error ?? error?.message ?? "No se pudo procesar."); return; }
    load();
  };

  if (loading) return <Spinner />;

  const totalRes = Object.values(statusCounts).reduce((a, b) => a + b, 0);
  const maxBar = Math.max(...monthlyBars.map((b) => b.count), 1);
  const maxTopCount = Math.max(...topGroups.map((g) => g.count), 1);

  const ALERTS = [
    { n: pendingTransfers, label: "💸 Transferencias por hacer", color: "text-brand-green border-brand-green/40 font-bold", nav: "ops" },
    { n: statusCounts.pending, label: "Reservas", color: "text-orange-400 border-orange-400/40" },
    { n: pendingVerif.length, label: "Verif.", color: "text-blue-400 border-blue-400/40", nav: "ops" },
    { n: openDisputes.length, label: "Disputas", color: "text-red-400 border-red-400/40" },
    { n: pendingMedia, label: "Medios", color: "text-purple-400 border-purple-400/40", nav: "ops" },
    { n: pendingAds, label: "Anuncios", color: "text-teal-400 border-teal-400/40", nav: "ads" },
    { n: noShows.length, label: "No-shows", color: "text-red-400 border-red-400/40", nav: "ops" },
    { n: stuckEvents.length, label: "Atorados", color: "text-orange-400 border-orange-400/40", nav: "ops" },
    { n: stuckServiceEvents.length, label: "Sin cerrar", color: "text-orange-400 border-orange-400/40", nav: "ops" },
    { n: unverifiedPayouts.length, label: "Verificar llegada", color: "text-blue-400 border-blue-400/40" },
    { n: pendingConcierge, label: "Por llamar", color: "text-brand-green border-brand-green/40", nav: "ops" },
    { n: pendingProviderApps, label: "Solicitudes", color: "text-purple-400 border-purple-400/40", nav: "ops" },
  ].filter((a) => a.n > 0);

  return (
    <div className="space-y-6">
      {/* ── KPI CARDS ─────────────────────────────────────────────────── */}
      <div className="grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
        <KpiCard icon="💰" label="Ingresos plataforma" value={money(commTotal)} sub={`de ${money(revenueTotal)} facturados`} color="text-brand-green" />
        <KpiCard icon="📈" label="Total reservas" value={String(totalRes)} sub={`${openRequests} solicitudes abiertas`} color="text-blue-400" />
        <KpiCard icon="👥" label="Grupos activos" value={String(totalGroups)} sub={`${totalClients} clientes registrados`} color="text-yellow-400" />
        <KpiCard icon="⚡" label="Eventos hoy" value={String(todayEvents.length)} sub={`${liveEvents.length} en curso ahora`} color="text-purple-400" />
      </div>

      {/* ── ESTADOS DE RESERVA ────────────────────────────────────────── */}
      <div className="flex flex-wrap gap-2">
        {([
          ["pending", "Pendientes", "text-orange-400 bg-orange-400/10 border-orange-400/30"],
          ["confirmed", "Confirmadas", "text-brand-green bg-brand-green/10 border-brand-green/30"],
          ["in_progress", "En curso", "text-blue-400 bg-blue-400/10 border-blue-400/30"],
          ["completed", "Completadas", "text-gray-300 bg-gray-400/10 border-gray-400/30"],
          ["cancelled", "Canceladas", "text-red-400 bg-red-400/10 border-red-400/30"],
        ] as const).map(([k, label, cls]) => (
          <div key={k} className={`rounded-xl border px-4 py-2 ${cls}`}>
            <p className="text-lg font-extrabold leading-tight">{(statusCounts as any)[k]}</p>
            <p className="text-[11px] opacity-80">{label}</p>
          </div>
        ))}
      </div>

      {/* ── ACCIONES RÁPIDAS ──────────────────────────────────────────── */}
      <div>
        <h3 className="mb-3 text-sm font-semibold uppercase tracking-wide text-brand-muted">Acciones rápidas</h3>
        <div className="grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-4 xl:grid-cols-6">
          {QUICK_ACTIONS.map((a) => (
            <button
              key={a.key}
              onClick={() => {
                if (a.nav === "soon") { window.alert(`"${a.label}" todavía no tiene su propia vista en la web — por ahora, usa la app.`); return; }
                if (a.nav === "self") return; // Disputas ya se ve abajo en este mismo Resumen
                onNavigateTab(a.nav);
              }}
              className="flex flex-col items-center gap-2 rounded-2xl border border-brand-border bg-brand-card p-4 text-center transition-colors hover:border-brand-green/40"
            >
              <span className="text-2xl">{a.icon}</span>
              <span className="text-xs font-medium text-brand-muted">{a.label}</span>
            </button>
          ))}
        </div>
      </div>

      {/* ── ALERTAS ───────────────────────────────────────────────────── */}
      {ALERTS.length > 0 && (
        <div className="rounded-2xl border border-yellow-400/20 bg-yellow-400/5 p-4">
          <p className="mb-3 text-sm font-semibold text-yellow-400">⚠️ Requieren atención</p>
          <div className="flex flex-wrap gap-2">
            {ALERTS.map((a, i) => (
              <button
                key={i}
                onClick={() => a.nav && onNavigateTab(a.nav)}
                className={`rounded-xl border px-3 py-1.5 text-xs font-semibold ${a.color} ${a.nav ? "cursor-pointer hover:bg-white/5" : "cursor-default"}`}
              >
                {a.n} {a.label}
              </button>
            ))}
          </div>
        </div>
      )}

      {/* ── GRÁFICA MENSUAL + TOP GRUPOS ──────────────────────────────── */}
      <div className="grid gap-4 lg:grid-cols-2">
        <div className="rounded-2xl border border-brand-border bg-brand-card p-5">
          <h3 className="mb-4 text-sm font-semibold text-brand-muted">📊 Reservas mensuales</h3>
          <div className="flex h-40 items-end justify-between gap-2">
            {monthlyBars.map((bar, i) => (
              <div key={i} className="flex flex-1 flex-col items-center gap-1">
                {bar.count > 0 && <span className="text-xs font-bold text-white">{bar.count}</span>}
                <div className="flex w-full items-end" style={{ height: "100px" }}>
                  <div className="w-full rounded-t-md bg-gradient-to-t from-brand-green to-emerald-400" style={{ height: `${Math.max((bar.count / maxBar) * 100, 4)}%` }} />
                </div>
                <span className="text-[10px] text-brand-muted">{bar.label}</span>
              </div>
            ))}
          </div>
        </div>

        <div className="rounded-2xl border border-brand-border bg-brand-card p-5">
          <h3 className="mb-4 text-sm font-semibold text-brand-muted">Top grupos por reservas</h3>
          {topGroups.length === 0 ? <p className="text-sm text-brand-muted">Sin datos todavía.</p> : (
            <div className="space-y-3">
              {topGroups.map((g, i) => {
                const pct = (g.count / maxTopCount) * 100;
                const accent = ["#00E676", "#40C4FF", "#FFB300", "#CE93D8", "#FF7043"][i] ?? "#00E676";
                return (
                  <div key={i} className="flex items-center gap-3">
                    <span className="flex h-7 w-7 shrink-0 items-center justify-center rounded-full text-xs font-bold" style={{ backgroundColor: accent + "22", color: accent }}>{i + 1}</span>
                    <div className="min-w-0 flex-1">
                      <div className="flex items-center justify-between text-xs">
                        <span className="truncate font-medium text-white">{g.name}</span>
                        <span className="font-bold" style={{ color: accent }}>{g.count} res.</span>
                      </div>
                      <div className="mt-1 h-1.5 w-full overflow-hidden rounded-full bg-brand-card2">
                        <div className="h-full rounded-full" style={{ width: `${pct}%`, backgroundColor: accent }} />
                      </div>
                    </div>
                  </div>
                );
              })}
            </div>
          )}
        </div>
      </div>

      {/* ── EN CURSO / HOY ────────────────────────────────────────────── */}
      {(liveEvents.length > 0 || todayEvents.length > 0) && (
        <div className="grid gap-4 lg:grid-cols-2">
          {liveEvents.length > 0 && (
            <EventListCard title={`🔴 En curso (${liveEvents.length})`} items={liveEvents.map((r) => ({ title: r.group?.name ?? "—", sub: r.client?.full_name ?? "—" }))} />
          )}
          {todayEvents.length > 0 && (
            <EventListCard title="Eventos hoy" items={todayEvents.map((r) => ({ title: r.group?.name ?? "—", sub: `${r.client?.full_name ?? "—"}${r.event_time ? " · " + r.event_time : ""}` }))} />
          )}
        </div>
      )}

      {/* ── DISPUTAS / VERIFICACIONES ─────────────────────────────────── */}
      <div className="grid gap-4 lg:grid-cols-2">
        {openDisputes.length > 0 && (
          <EventListCard title="Disputas abiertas" items={openDisputes.map((d: any) => ({ title: d.reservation?.group?.name ?? "Grupo", sub: d.reason ?? "" }))} />
        )}
        {pendingVerif.length > 0 && (
          <EventListCard title="Verificaciones pendientes" items={pendingVerif.map((v: any) => ({ title: v.group?.name ?? "Grupo", sub: "Pendiente" }))} />
        )}
      </div>

      {/* ── VERIFICAR LLEGADA (pagos retenidos sin GPS) ────────────────── */}
      {unverifiedPayouts.length > 0 && (
        <Section title="🔵 Verificar llegada — pagos retenidos" count={unverifiedPayouts.length}>
          <p className="mb-3 text-xs text-brand-muted">Eventos pagados cuyo grupo nunca marcó llegada GPS. Llama para confirmar si tocó, y libera o bloquea.</p>
          <div className="grid gap-3 lg:grid-cols-2">
            {unverifiedPayouts.map((ev: any) => (
              <div key={ev.id} className="space-y-2 rounded-2xl border border-blue-400/20 bg-blue-400/5 p-4">
                <p className="font-semibold text-white">{ev.group_name ?? "—"}</p>
                <p className="text-xs text-brand-muted">{ev.client_name ?? "—"} · {ev.event_date} {ev.event_time ?? ""} · {money(ev.total_price)}</p>
                <div className="flex gap-2">
                  <ActionBtn label="Sí llegó — liberar" color="green" busy={busyId === ev.id} onClick={() => verifyRelease(ev)} />
                  <ActionBtn label="No llegó — bloquear" color="red" busy={busyId === ev.id} onClick={() => blockPayout(ev)} />
                </div>
              </div>
            ))}
          </div>
        </Section>
      )}
    </div>
  );
}

function KpiCard({ icon, label, value, sub, color }: { icon: string; label: string; value: string; sub: string; color: string }) {
  return (
    <div className="rounded-2xl border border-brand-border bg-brand-card p-4">
      <div className="mb-2 text-xl">{icon}</div>
      <p className="text-xs text-brand-muted">{label}</p>
      <p className={`truncate text-2xl font-extrabold ${color}`}>{value}</p>
      <p className="mt-1 text-xs text-brand-muted">{sub}</p>
    </div>
  );
}

function EventListCard({ title, items }: { title: string; items: { title: string; sub: string }[] }) {
  return (
    <div className="rounded-2xl border border-brand-border bg-brand-card p-5">
      <h3 className="mb-3 text-sm font-semibold text-brand-muted">{title}</h3>
      <div className="space-y-2">
        {items.map((it, i) => (
          <div key={i} className="flex items-center justify-between border-t border-brand-border pt-2 first:border-0 first:pt-0">
            <div className="min-w-0">
              <p className="truncate text-sm font-medium text-white">{it.title}</p>
              <p className="truncate text-xs text-brand-muted">{it.sub}</p>
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}
