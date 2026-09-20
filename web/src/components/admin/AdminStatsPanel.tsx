"use client";

/**
 * AdminStatsPanel — "Estadísticas" del admin completo en la web (petición
 * real: "que jale todo, nomás los pagos eso no importa"). Usa las mismas
 * 8 RPC de inteligencia que ya calcula el servidor para StatsScreen.tsx
 * (app móvil) — nada de dinero se mueve aquí, solo lectura.
 *
 * Fuera de esta pieza (backlog, requiere combinar 3 tablas más del lado
 * del cliente igual que la app): "Top grupos que pagan" (ads+bids+
 * recomendaciones combinados) y el desglose de wallet por tipo de ingreso.
 */

import { useCallback, useEffect, useState } from "react";
import { supabase } from "@/lib/supabase";
import { Spinner, Section } from "./ui";

const money = (n: number | null | undefined) => `$${Number(n ?? 0).toLocaleString("es-MX", { maximumFractionDigits: 0 })}`;

export default function AdminStatsPanel() {
  const [loading, setLoading] = useState(true);
  const [platform, setPlatform] = useState<any>(null);
  const [monthly, setMonthly] = useState<any[]>([]);
  const [topEarnings, setTopEarnings] = useState<any[]>([]);
  const [topRating, setTopRating] = useState<any[]>([]);
  const [riskGroups, setRiskGroups] = useState<any[]>([]);
  const [topCities, setTopCities] = useState<any[]>([]);
  const [gaps, setGaps] = useState<any[]>([]);
  const [loyalty, setLoyalty] = useState<any>(null);
  const [visits, setVisits] = useState<any>(null);

  const load = useCallback(async () => {
    const [
      platformRes, monthlyRes, earningsRes, ratingRes, riskRes, citiesRes, gapsRes, loyaltyRes, visitsRes,
    ] = await Promise.all([
      supabase.rpc("get_admin_platform_stats", { p_days_back: 30 }),
      supabase.rpc("get_platform_monthly_stats", { p_months: 6 }),
      supabase.rpc("get_top_groups_earnings", { p_limit: 5, p_country: null, p_state: null }),
      supabase.rpc("get_top_groups_rating", { p_limit: 5, p_country: null, p_state: null }),
      supabase.rpc("get_risk_groups", { p_limit: 5 }),
      supabase.rpc("get_events_by_city", { p_limit: 8 }),
      supabase.rpc("get_platform_gaps", { p_days_back: 30, p_limit: 8 }),
      supabase.rpc("get_loyalty_metrics", { p_days_back: 30 }),
      supabase.rpc("get_web_visit_stats"),
    ]);
    setPlatform((platformRes.data as any) ?? null);
    setMonthly(monthlyRes.data ?? []);
    setTopEarnings(earningsRes.data ?? []);
    setTopRating(ratingRes.data ?? []);
    setRiskGroups(riskRes.data ?? []);
    setTopCities(citiesRes.data ?? []);
    setGaps((gapsRes.data as any)?.gaps ?? []);
    setVisits((visitsRes.data as any)?.ok ? visitsRes.data : null);
    setLoyalty((loyaltyRes.data as any)?.[0] ?? null);
    setLoading(false);
  }, []);

  useEffect(() => { load(); }, [load]);

  if (loading) return <Spinner />;
  const maxMonthly = Math.max(...monthly.map((m) => Number(m.events ?? 0)), 1);

  return (
    <div className="space-y-6">
      {/* ── KPIs últimos 30 días ────────────────────────────────────────── */}
      {platform && (
        <div className="grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
          <Kpi icon="🎸" label="Grupos activos" value={String(platform.active_groups ?? 0)} sub={`${platform.new_groups ?? 0} nuevos en 30 días`} color="text-brand-green" />
          <Kpi icon="📅" label="Reservas nuevas (30d)" value={String(platform.new_reservations ?? 0)} sub={`${platform.completions ?? 0} completadas`} color="text-blue-400" />
          <Kpi icon="👥" label="Clientes nuevos (30d)" value={String(platform.new_clients ?? 0)} sub={`${platform.cancellations ?? 0} cancelaciones`} color="text-yellow-400" />
          <Kpi icon="⚡" label="Solicitudes Express" value={String(platform.express_requests ?? 0)} sub={`${(platform.express_conversion ?? 0).toFixed?.(0) ?? platform.express_conversion ?? 0}% conversión`} color="text-purple-400" />
        </div>
      )}

      {/* ── Visitas a la web (sql/663) ────────────────────────────────────── */}
      {visits && (
        <div className="rounded-2xl border border-brand-border bg-brand-card p-5">
          <h3 className="mb-4 text-sm font-semibold text-brand-muted">🌐 Visitas a la web</h3>
          <div className="mb-4 grid grid-cols-2 gap-3 sm:grid-cols-4">
            <Kpi icon="📆" label="Hoy" value={String(visits.views_today ?? 0)} sub="" color="text-brand-green" />
            <Kpi icon="🗓️" label="Últimos 7 días" value={String(visits.views_7d ?? 0)} sub="" color="text-blue-400" />
            <Kpi icon="👥" label="Sesiones únicas (30d)" value={String(visits.unique_sessions_30d ?? 0)} sub={`${visits.views_30d ?? 0} vistas en 30d`} color="text-purple-400" />
            <Kpi icon="📈" label="Total histórico" value={String(visits.total_views ?? 0)} sub="" color="text-yellow-400" />
          </div>
          {(visits.top_paths ?? []).length > 0 && (
            <div>
              <p className="mb-2 text-xs font-semibold uppercase tracking-wide text-brand-muted">Páginas más visitadas (30 días)</p>
              <div className="space-y-1.5">
                {visits.top_paths.map((p: any, i: number) => (
                  <div key={i} className="flex items-center justify-between text-sm">
                    <span className="truncate text-white">{p.path}</span>
                    <span className="shrink-0 font-bold text-brand-green">{p.views}</span>
                  </div>
                ))}
              </div>
            </div>
          )}
        </div>
      )}

      {/* ── Tendencia mensual ───────────────────────────────────────────── */}
      {monthly.length > 0 && (
        <div className="rounded-2xl border border-brand-border bg-brand-card p-5">
          <h3 className="mb-4 text-sm font-semibold text-brand-muted">📊 Eventos por mes (últimos 6 meses)</h3>
          <div className="flex h-32 items-end justify-between gap-2">
            {monthly.map((m, i) => (
              <div key={i} className="flex flex-1 flex-col items-center gap-1">
                {Number(m.events) > 0 && <span className="text-xs font-bold text-white">{m.events}</span>}
                <div className="flex w-full items-end" style={{ height: "80px" }}>
                  <div className="w-full rounded-t-md bg-gradient-to-t from-brand-green to-emerald-400" style={{ height: `${Math.max((Number(m.events ?? 0) / maxMonthly) * 100, 4)}%` }} />
                </div>
                <span className="text-[10px] text-brand-muted">{m.period}</span>
              </div>
            ))}
          </div>
        </div>
      )}

      {/* ── Top grupos: ingresos + calificación ──────────────────────────── */}
      <div className="grid gap-4 lg:grid-cols-2">
        <Section title="🏆 Top grupos por ingresos" count={topEarnings.length}>
          {topEarnings.length === 0 ? <Empty /> : (
            <div className="space-y-2">
              {topEarnings.map((g, i) => (
                <Row key={i} left={g.group_name} sub={`${g.group_state ?? "—"}, ${g.group_country ?? "—"} · ${g.event_count} eventos`} right={money(g.total_earnings)} rightColor="text-brand-green" />
              ))}
            </div>
          )}
        </Section>
        <Section title="⭐ Top grupos por calificación" count={topRating.length}>
          {topRating.length === 0 ? <Empty /> : (
            <div className="space-y-2">
              {topRating.map((g, i) => (
                <Row key={i} left={g.group_name} sub={`${g.group_state ?? "—"}, ${g.group_country ?? "—"} · ${g.total_reviews} reseñas`} right={`★ ${Number(g.rating).toFixed(1)}`} rightColor="text-yellow-400" />
              ))}
            </div>
          )}
        </Section>
      </div>

      {/* ── Riesgo + ciudades ─────────────────────────────────────────────── */}
      <div className="grid gap-4 lg:grid-cols-2">
        <Section title="⚠️ Grupos con más cancelaciones" count={riskGroups.length}>
          {riskGroups.length === 0 ? <Empty text="Sin grupos en riesgo — buena señal." /> : (
            <div className="space-y-2">
              {riskGroups.map((g, i) => (
                <Row key={i} left={g.group_name} sub="" right={`${g.cancellation_count} cancelaciones`} rightColor="text-red-400" />
              ))}
            </div>
          )}
        </Section>
        <Section title="📍 Eventos por ciudad" count={topCities.length}>
          {topCities.length === 0 ? <Empty /> : (
            <div className="space-y-2">
              {topCities.map((c, i) => (
                <Row key={i} left={c.city ?? "Sin ciudad"} sub="" right={`${c.event_count} eventos`} rightColor="text-blue-400" />
              ))}
            </div>
          )}
        </Section>
      </div>

      {/* ── Huecos de mercado (demanda sin oferta) ───────────────────────── */}
      <Section title="🔍 Huecos de mercado (30 días)" count={gaps.length}>
        {gaps.length === 0 ? <Empty text="Sin huecos detectados en los últimos 30 días." /> : (
          <div className="space-y-2">
            {gaps.map((g, i) => (
              <div key={i} className="rounded-xl border border-brand-border bg-brand-card px-4 py-3 text-sm text-white">
                {Object.entries(g).map(([k, v]) => `${k}: ${v}`).join(" · ")}
              </div>
            ))}
          </div>
        )}
      </Section>

      {/* ── Lealtad de clientes ───────────────────────────────────────────── */}
      {loyalty && (
        <div className="rounded-2xl border border-brand-border bg-brand-card p-5">
          <h3 className="mb-4 text-sm font-semibold text-brand-muted">💚 Lealtad de clientes (30 días)</h3>
          <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
            <Kpi icon="🥈" label="Silver" value={String(loyalty.silver_clients ?? 0)} sub="" color="text-gray-300" />
            <Kpi icon="🥇" label="Gold" value={String(loyalty.gold_clients ?? 0)} sub="" color="text-yellow-400" />
            <Kpi icon="💎" label="VIP" value={String(loyalty.vip_clients ?? 0)} sub="" color="text-purple-400" />
            <Kpi icon="🔁" label="Tasa de repetición" value={`${Number(loyalty.repeat_rate_pct ?? 0).toFixed(0)}%`} sub={`${Number(loyalty.avg_events_per_client ?? 0).toFixed(1)} eventos/cliente`} color="text-brand-green" />
          </div>
        </div>
      )}
    </div>
  );
}

function Kpi({ icon, label, value, sub, color }: { icon: string; label: string; value: string; sub: string; color: string }) {
  return (
    <div className="rounded-2xl border border-brand-border bg-brand-card p-4">
      <div className="mb-2 text-xl">{icon}</div>
      <p className="text-xs text-brand-muted">{label}</p>
      <p className={`truncate text-2xl font-extrabold ${color}`}>{value}</p>
      {sub && <p className="mt-1 text-xs text-brand-muted">{sub}</p>}
    </div>
  );
}

function Row({ left, sub, right, rightColor }: { left: string; sub: string; right: string; rightColor: string }) {
  return (
    <div className="flex items-center justify-between rounded-xl border border-brand-border bg-brand-card px-4 py-3">
      <div className="min-w-0">
        <p className="truncate text-sm font-semibold text-white">{left}</p>
        {sub && <p className="truncate text-xs text-brand-muted">{sub}</p>}
      </div>
      <span className={`shrink-0 text-sm font-bold ${rightColor}`}>{right}</span>
    </div>
  );
}

function Empty({ text = "Sin datos todavía." }: { text?: string }) {
  return <p className="rounded-xl border border-brand-border bg-brand-card px-4 py-6 text-center text-sm text-brand-muted">{text}</p>;
}
