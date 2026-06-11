"use client";

import { useEffect, useState, useCallback, Suspense } from "react";
import { useRouter, useSearchParams } from "next/navigation";
import Image from "next/image";
import Navbar from "@/components/Navbar";
import { supabase } from "@/lib/supabase";
import type { GroupLocation } from "@/components/AdminMap";

// Leaflet map: carga dinámica (no SSR) para evitar errores de window
import dynamic2 from "next/dynamic";
const AdminMap = dynamic2(() => import("@/components/AdminMap"), { ssr: false });

type Tab = "overview" | "ads" | "groups" | "users" | "reservations" | "media" | "map";

interface PendingAd {
  id: string; type: string; title: string; status: string;
  created_at: string; target_location_type: string | null;
  advertiser_id: string;
  profiles: { name: string; email: string } | null;
}
interface GroupRow {
  id: string; name: string; city: string | null;
  is_active: boolean | null; verification_status: string;
  rating: number | null;
  total_reviews: number | null; created_at: string;
  is_verified: boolean | null;
}
interface UserRow {
  id: string; name: string; email: string;
  role: string; city: string | null; created_at: string;
}
interface ReservationRow {
  id: string; event_date: string; status: string;
  payment_status: string; total_price: number; created_at: string;
  groups: { name: string } | null;
  profiles: { name: string } | null;
}
interface MediaRow {
  id: string; name: string; city: string | null;
  avatar_url: string | null; banner_url: string | null;
  is_active: boolean | null; verification_status: string;
  created_at: string;
}

const STATUS_COLOR: Record<string, string> = {
  active:               "text-brand-green bg-brand-green/10",
  pending:              "text-yellow-400 bg-yellow-400/10",
  pending_review:       "text-yellow-400 bg-yellow-400/10",
  pending_verification: "text-orange-400 bg-orange-400/10",
  completed:            "text-brand-green bg-brand-green/10",
  confirmed:            "text-brand-green bg-brand-green/10",
  rejected:             "text-red-400 bg-red-400/10",
  cancelled:            "text-red-400 bg-red-400/10",
  expired:              "text-brand-muted bg-brand-card2",
};

// ── Error box para mostrar errores de query visiblemente ─────────────────────
function QueryError({ errors }: { errors: Record<string, string | null> }) {
  const active = Object.entries(errors).filter(([, v]) => v);
  if (active.length === 0) return null;
  return (
    <div className="mb-4 rounded-xl border border-red-500/20 bg-red-500/5 p-4">
      <p className="mb-2 text-sm font-semibold text-red-400">⚠️ Error al cargar datos:</p>
      {active.map(([k, v]) => (
        <p key={k} className="text-xs text-red-400">{k}: {v}</p>
      ))}
      <p className="mt-2 text-xs text-brand-muted">
        Posible causa: el usuario admin no tiene fila en la tabla profiles. Ver instrucciones abajo.
      </p>
    </div>
  );
}

function AdminDashboardInner() {
  const router     = useRouter();
  const params     = useSearchParams();
  const initialTab = (params.get("tab") as Tab | null) ?? "overview";

  const [tab,         setTab]         = useState<Tab>(initialTab);
  const [tabMenuOpen, setTabMenuOpen] = useState(false);
  const [authorized,  setAuthorized]  = useState(false);
  const [loading,     setLoading]     = useState(true);
  const [queryErrors, setQueryErrors] = useState<Record<string, string | null>>({});

  // Overview stats
  const [stats, setStats] = useState({
    totalGroups: 0, activeGroups: 0, totalClients: 0,
    totalRevenue: 0, pendingAds: 0, pendingVerif: 0,
    totalReservations: 0, completedReservations: 0,
  });

  // Tab data
  const [pendingAds,   setPendingAds]   = useState<PendingAd[]>([]);
  const [allAds,       setAllAds]       = useState<PendingAd[]>([]);
  const [groups,       setGroups]       = useState<GroupRow[]>([]);
  const [users,        setUsers]        = useState<UserRow[]>([]);
  const [reservations, setReservations] = useState<ReservationRow[]>([]);
  const [media,        setMedia]        = useState<MediaRow[]>([]);
  const [locations,    setLocations]    = useState<GroupLocation[]>([]);
  const [approving,    setApproving]    = useState<string | null>(null);

  // ── Sync tab → URL ────────────────────────────────────────────────────────
  const changeTab = useCallback((newTab: Tab) => {
    setTab(newTab);
    setTabMenuOpen(false);
    const url = new URL(window.location.href);
    url.searchParams.set("tab", newTab);
    window.history.pushState({}, "", url.toString());
  }, []);

  // ── Auth check + UPSERT profiles row (root cause fix) ────────────────────
  useEffect(() => {
    supabase.auth.getSession().then(async ({ data: { session } }) => {
      if (!session) { router.replace("/login"); return; }

      const { data: prof } = await supabase
        .from("profiles").select("role, id").eq("id", session.user.id).single();

      const role = (prof as { role: string } | null)?.role
        ?? session.user.user_metadata?.role;

      if (role !== "admin") { router.replace("/"); return; }

      // ── CRÍTICO: asegurar que la fila profiles exista ─────────────────
      // is_admin() en Supabase consulta profiles. Sin esta fila, todas
      // las queries retornan vacío aunque el usuario sea admin en auth.
      if (!prof) {
        console.log("[Admin] Sin fila en profiles → creando perfil admin...");
        const { error: upsertErr } = await supabase.from("profiles").upsert({
          id:    session.user.id,
          email: session.user.email ?? "",
          name:  session.user.user_metadata?.name ?? session.user.email ?? "Admin",
          role:  "admin",
        });
        if (upsertErr) {
          console.error("[Admin] Error al crear perfil:", upsertErr.message);
        } else {
          console.log("[Admin] Perfil admin creado ✓");
        }
      }

      setAuthorized(true);
      loadOverview();
    });
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // ── Data loaders ──────────────────────────────────────────────────────────
  const loadOverview = useCallback(async () => {
    setLoading(true);
    const [
      { data: grpAll,  error: e1 },
      { count: totalC, error: e2 },
      { data: revData, error: e3 },
      { data: pendAds, error: e4 },
      { data: pendGrps,error: e5 },
      { count: totalRes,error:e6 },
    ] = await Promise.all([
      supabase.from("groups").select("id, is_active"),
      supabase.from("profiles").select("id", { count: "exact" }).eq("role", "client"),
      supabase.from("reservations").select("total_price, status"),
      supabase.from("advertisements").select("id").eq("status", "pending_review"),
      supabase.from("groups").select("id").eq("verification_status", "pending"),
      supabase.from("reservations").select("id", { count: "exact" }),
    ]);

    // Log errores para diagnóstico
    const errs = { groups: e1?.message??null, profiles: e2?.message??null,
      reservations: e3?.message??null, ads: e4?.message??null };
    setQueryErrors(errs);
    const anyErr = Object.values(errs).some(Boolean);
    if (anyErr) {
      console.error("[Admin overview] Query errors:", errs);
    } else {
      console.log("[Admin overview] OK →", {
        grupos: grpAll?.length, clientes: totalC,
        reservas: totalRes, adsP: pendAds?.length
      });
    }

    const activeG   = (grpAll ?? []).filter((g: any) => g.is_active === true).length;
    const revenue   = (revData ?? [])
      .filter((r: any) => r.status === "completed")
      .reduce((s: number, r: any) => s + (r.total_price ?? 0), 0);
    const completed = (revData ?? []).filter((r: any) => r.status === "completed").length;

    setStats({
      totalGroups:           grpAll?.length ?? 0,
      activeGroups:          activeG,
      totalClients:          totalC ?? 0,
      totalRevenue:          revenue,
      pendingAds:            pendAds?.length ?? 0,
      pendingVerif:          pendGrps?.length ?? 0,
      totalReservations:     totalRes ?? 0,
      completedReservations: completed,
    });
    setLoading(false);
  }, []);

  const loadAds = useCallback(async () => {
    const { data, error } = await supabase
      .from("advertisements")
      .select("id, type, title, status, created_at, target_location_type, advertiser_id, profiles(name, email)")
      .order("created_at", { ascending: false })
      .limit(30);
    if (error) console.error("[Admin ads]", error.message);
    const rows = (data as unknown as PendingAd[]) ?? [];
    setAllAds(rows);
    setPendingAds(rows.filter(a => a.status === "pending_review"));
  }, []);

  const loadGroups = useCallback(async () => {
    const { data, error } = await supabase
      .from("groups")
      .select("id, name, city, is_active, verification_status, rating, total_reviews, created_at, is_verified")
      .order("created_at", { ascending: false })
      .limit(40);
    if (error) console.error("[Admin groups]", error.message);
    setGroups((data as GroupRow[]) ?? []);
  }, []);

  const loadUsers = useCallback(async () => {
    const { data, error } = await supabase
      .from("profiles")
      .select("id, name, email, role, city, created_at")
      .order("created_at", { ascending: false })
      .limit(40);
    if (error) console.error("[Admin users]", error.message);
    setUsers((data as UserRow[]) ?? []);
  }, []);

  const loadReservations = useCallback(async () => {
    const { data, error } = await supabase
      .from("reservations")
      .select("id, event_date, status, payment_status, total_price, created_at, groups(name), profiles(name)")
      .order("created_at", { ascending: false })
      .limit(40);
    if (error) console.error("[Admin reservations]", error.message);
    setReservations((data as unknown as ReservationRow[]) ?? []);
  }, []);

  const loadMedia = useCallback(async () => {
    const { data, error } = await supabase
      .from("groups")
      .select("id, name, city, avatar_url, banner_url, is_active, verification_status, created_at")
      .or("avatar_url.not.is.null,banner_url.not.is.null")
      .order("created_at", { ascending: false })
      .limit(40);
    if (error) console.error("[Admin media]", error.message);
    setMedia((data as MediaRow[]) ?? []);
  }, []);

  const loadMap = useCallback(async () => {
    const { data, error } = await supabase
      .from("group_locations")
      .select("group_id, lat, lng, city, status, last_seen, groups(name, city)")
      .order("last_seen", { ascending: false });
    if (error) console.error("[Admin map]", error.message);
    setLocations((data as unknown as GroupLocation[]) ?? []);
  }, []);

  useEffect(() => {
    if (!authorized) return;
    if (tab === "ads")          loadAds();
    if (tab === "groups")       loadGroups();
    if (tab === "users")        loadUsers();
    if (tab === "reservations") loadReservations();
    if (tab === "media")        loadMedia();
    if (tab === "map")          loadMap();
  }, [tab, authorized, loadAds, loadGroups, loadUsers, loadReservations, loadMedia, loadMap]);

  // ── Actions ───────────────────────────────────────────────────────────────
  const approveAd = async (id: string) => {
    setApproving(id);
    const { error } = await supabase.rpc("approve_ad", { p_id: id });
    if (error) console.error("[approveAd]", error.message);
    setApproving(null);
    loadAds(); loadOverview();
  };
  const rejectAd = async (id: string) => {
    await supabase.rpc("reject_ad", { p_id: id, p_reason: "Rechazado desde admin web" });
    loadAds(); loadOverview();
  };
  const approveGroup = async (id: string) => {
    await supabase.from("groups").update({ is_active: true, verification_status: "approved", is_verified: true }).eq("id", id);
    loadGroups(); loadOverview();
  };
  const rejectGroup = async (id: string) => {
    await supabase.from("groups").update({ verification_status: "rejected", is_active: false }).eq("id", id);
    loadGroups();
  };

  if (!authorized || loading) {
    return (
      <div className="min-h-screen bg-brand-bg">
        <Navbar />
        <div className="flex min-h-[60vh] flex-col items-center justify-center gap-3">
          <div className="h-10 w-10 animate-spin rounded-full border-2 border-brand-border border-t-brand-green" />
          <p className="text-xs text-brand-muted">Verificando sesión y permisos…</p>
        </div>
      </div>
    );
  }

  const TABS: { key: Tab; label: string; icon: string; badge?: number }[] = [
    { key: "overview",     label: "Resumen",   icon: "📊" },
    { key: "ads",          label: "Anuncios",  icon: "📢", badge: stats.pendingAds   },
    { key: "groups",       label: "Grupos",    icon: "🎸", badge: stats.pendingVerif  },
    { key: "users",        label: "Usuarios",  icon: "👥" },
    { key: "reservations", label: "Reservas",  icon: "📅" },
    { key: "media",        label: "Medios",    icon: "🖼️" },
    { key: "map",          label: "Mapa",      icon: "🗺️" },
  ];

  const currentTab = TABS.find(t => t.key === tab)!;

  return (
    <div className="min-h-screen bg-brand-bg">
      <Navbar />
      <main className="mx-auto max-w-7xl px-4 pb-20 pt-24 sm:px-6 lg:px-8">

        {/* ── Header ───────────────────────────────────────────────── */}
        <div className="mb-6 flex flex-wrap items-center justify-between gap-3">
          <div>
            <h1 className="text-xl font-extrabold text-white sm:text-2xl">
              Panel de administración
            </h1>
            <p className="text-sm text-brand-muted">DARICEFY · Admin</p>
          </div>
          <span className="rounded-full bg-brand-green/15 px-3 py-1.5 text-xs font-semibold text-brand-green">
            ● Sistema activo
          </span>
        </div>

        {/* ── Errores de query visibles ────────────────────────────── */}
        <QueryError errors={queryErrors} />

        {/* ── Instrucciones si hay errores de permisos ─────────────── */}
        {Object.values(queryErrors).some(Boolean) && (
          <div className="mb-6 rounded-2xl border border-brand-border bg-brand-card p-5 text-sm">
            <p className="mb-2 font-semibold text-white">📋 Cómo solucionar:</p>
            <p className="mb-1 text-brand-muted">Ejecuta este SQL en Supabase → SQL Editor:</p>
            <pre className="mt-2 overflow-x-auto rounded-lg bg-brand-card2 p-3 text-xs text-brand-green">
{`INSERT INTO public.profiles (id, email, name, role)
VALUES (auth.uid(), current_user, 'Admin', 'admin')
ON CONFLICT (id) DO UPDATE SET role = 'admin';`}
            </pre>
          </div>
        )}

        {/* ── NAVEGACIÓN MÓVIL: dropdown ────────────────────────────── */}
        <div className="relative mb-6 sm:hidden">
          <button
            onClick={() => setTabMenuOpen(!tabMenuOpen)}
            className="flex h-12 w-full items-center justify-between rounded-xl border border-brand-border bg-brand-card px-4 text-sm font-medium text-white"
          >
            <span className="flex items-center gap-2.5">
              <span className="text-base">{currentTab.icon}</span>
              <span>{currentTab.label}</span>
              {currentTab.badge ? (
                <span className="rounded-full bg-yellow-400/20 px-2 py-0.5 text-xs font-bold text-yellow-400">
                  {currentTab.badge}
                </span>
              ) : null}
            </span>
            <span className={`text-brand-muted transition-transform duration-200 ${tabMenuOpen ? "rotate-180" : ""}`}>▾</span>
          </button>

          {tabMenuOpen && (
            <>
              <div className="fixed inset-0 z-10" onClick={() => setTabMenuOpen(false)} />
              <div className="absolute left-0 right-0 top-[calc(100%+6px)] z-20 overflow-hidden rounded-xl border border-brand-border bg-brand-card shadow-2xl shadow-black/60">
                {TABS.map((t, i) => (
                  <button
                    key={t.key}
                    onClick={() => changeTab(t.key)}
                    className={`flex w-full items-center gap-3 px-4 py-3.5 text-sm font-medium transition-colors ${
                      i < TABS.length - 1 ? "border-b border-brand-border" : ""
                    } ${tab === t.key ? "bg-brand-green/10 text-brand-green" : "text-brand-muted active:bg-brand-card2"}`}
                  >
                    <span className="text-base">{t.icon}</span>
                    <span>{t.label}</span>
                    {t.badge ? (
                      <span className="ml-auto rounded-full bg-yellow-400/20 px-2.5 py-0.5 text-xs font-bold text-yellow-400">
                        {t.badge}
                      </span>
                    ) : null}
                    {tab === t.key && <span className="ml-auto text-xs text-brand-green">✓</span>}
                  </button>
                ))}
              </div>
            </>
          )}
        </div>

        {/* ── NAVEGACIÓN DESKTOP: pills ─────────────────────────────── */}
        <div className="mb-6 hidden sm:flex gap-1 overflow-x-auto rounded-xl border border-brand-border bg-brand-card p-1 [scrollbar-width:none] [&::-webkit-scrollbar]:hidden">
          {TABS.map((t) => (
            <button
              key={t.key}
              onClick={() => changeTab(t.key)}
              className={`flex shrink-0 items-center gap-1.5 rounded-lg px-4 py-2.5 text-sm font-medium transition-all ${
                tab === t.key ? "bg-brand-green text-black" : "text-brand-muted hover:text-white"
              }`}
            >
              <span className="text-sm">{t.icon}</span>
              {t.label}
              {t.badge ? (
                <span className={`rounded-full px-1.5 py-0.5 text-[11px] font-bold ${
                  tab === t.key ? "bg-black/20 text-black" : "bg-yellow-400/20 text-yellow-400"
                }`}>
                  {t.badge}
                </span>
              ) : null}
            </button>
          ))}
        </div>

        {/* ═══ OVERVIEW ═══════════════════════════════════════════════ */}
        {tab === "overview" && (
          <div className="space-y-5">
            <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
              {[
                { val: stats.totalGroups,           label: "Grupos totales",   color: "text-white",       icon: "🎸" },
                { val: stats.activeGroups,          label: "Grupos activos",   color: "text-brand-green", icon: "✅" },
                { val: stats.totalClients,          label: "Clientes",         color: "text-blue-400",    icon: "👥" },
                { val: `$${stats.totalRevenue.toLocaleString("es-MX")}`,
                                                    label: "Ingresos totales", color: "text-brand-green", icon: "💰" },
                { val: stats.totalReservations,     label: "Reservas",         color: "text-white",       icon: "📅" },
                { val: stats.completedReservations, label: "Completadas",      color: "text-brand-green", icon: "🎵" },
                { val: stats.pendingAds,            label: "Anuncios pend.",   color: "text-yellow-400",  icon: "📢" },
                { val: stats.pendingVerif,          label: "Verif. pend.",     color: "text-orange-400",  icon: "🔍" },
              ].map((s) => (
                <div key={s.label} className="rounded-2xl border border-brand-border bg-brand-card p-4">
                  <div className="mb-2 text-xl">{s.icon}</div>
                  <p className={`truncate text-xl font-extrabold sm:text-2xl ${s.color}`}>{s.val}</p>
                  <p className="mt-1 text-xs text-brand-muted">{s.label}</p>
                </div>
              ))}
            </div>

            {(stats.pendingAds > 0 || stats.pendingVerif > 0) && (
              <div className="rounded-2xl border border-yellow-400/20 bg-yellow-400/5 p-5">
                <p className="mb-3 text-sm font-semibold text-yellow-400">⚠️ Acciones requeridas</p>
                <div className="flex flex-col gap-3 sm:flex-row sm:flex-wrap">
                  {stats.pendingAds > 0 && (
                    <button onClick={() => changeTab("ads")}
                      className="w-full rounded-xl bg-yellow-400/20 px-4 py-3 text-sm font-medium text-yellow-400 hover:bg-yellow-400/30 sm:w-auto">
                      {stats.pendingAds} anuncio{stats.pendingAds > 1 ? "s" : ""} por aprobar →
                    </button>
                  )}
                  {stats.pendingVerif > 0 && (
                    <button onClick={() => changeTab("groups")}
                      className="w-full rounded-xl bg-orange-400/20 px-4 py-3 text-sm font-medium text-orange-400 hover:bg-orange-400/30 sm:w-auto">
                      {stats.pendingVerif} grupo{stats.pendingVerif > 1 ? "s" : ""} por verificar →
                    </button>
                  )}
                </div>
              </div>
            )}
          </div>
        )}

        {/* ═══ ANUNCIOS ════════════════════════════════════════════════ */}
        {tab === "ads" && (
          <div className="space-y-4">
            {pendingAds.length > 0 && (
              <div className="rounded-2xl border border-yellow-400/20 bg-yellow-400/5 p-4">
                <p className="mb-3 text-sm font-semibold text-yellow-400">
                  {pendingAds.length} anuncio{pendingAds.length > 1 ? "s" : ""} pendiente{pendingAds.length > 1 ? "s" : ""} de aprobación
                </p>
                <div className="space-y-3">
                  {pendingAds.map((ad) => (
                    <div key={ad.id} className="rounded-xl border border-brand-border bg-brand-card p-4">
                      <div className="mb-4 flex items-start justify-between gap-3">
                        <div className="min-w-0 flex-1">
                          <p className="truncate font-semibold text-white">{ad.title}</p>
                          <p className="mt-0.5 truncate text-xs text-brand-muted">{ad.type} · {ad.target_location_type ?? "national"}</p>
                          <p className="mt-0.5 truncate text-xs text-brand-muted">
                            {(ad.profiles as { email: string } | null)?.email ?? "—"}
                          </p>
                          <p className="mt-0.5 text-xs text-brand-muted">{new Date(ad.created_at).toLocaleDateString("es-MX")}</p>
                        </div>
                        <span className="shrink-0 rounded-full bg-yellow-400/15 px-2.5 py-1 text-xs font-medium text-yellow-400">Pendiente</span>
                      </div>
                      <div className="flex gap-3">
                        <button onClick={() => approveAd(ad.id)} disabled={approving === ad.id}
                          className="flex-1 rounded-xl bg-brand-green py-3 text-sm font-bold text-black disabled:opacity-50">
                          {approving === ad.id ? "…" : "✓ Aprobar"}
                        </button>
                        <button onClick={() => rejectAd(ad.id)}
                          className="flex-1 rounded-xl border border-red-500/30 bg-red-500/5 py-3 text-sm font-medium text-red-400">
                          ✕ Rechazar
                        </button>
                      </div>
                    </div>
                  ))}
                </div>
              </div>
            )}

            <h3 className="text-sm font-semibold text-brand-muted">Todos los anuncios ({allAds.length})</h3>
            {allAds.length === 0 && <p className="py-8 text-center text-sm text-brand-muted">Sin anuncios registrados.</p>}
            <div className="space-y-2">
              {allAds.map((ad) => (
                <div key={ad.id} className="flex items-center gap-3 rounded-xl border border-brand-border bg-brand-card px-4 py-3">
                  <div className="min-w-0 flex-1">
                    <p className="truncate text-sm font-semibold text-white">{ad.title}</p>
                    <p className="truncate text-xs text-brand-muted">{ad.type} · {ad.target_location_type ?? "national"}</p>
                  </div>
                  <span className={`shrink-0 rounded-full px-2.5 py-1 text-xs font-medium ${STATUS_COLOR[ad.status] ?? "text-brand-muted bg-brand-card2"}`}>
                    {ad.status}
                  </span>
                </div>
              ))}
            </div>
          </div>
        )}

        {/* ═══ GRUPOS ══════════════════════════════════════════════════ */}
        {tab === "groups" && (
          <div className="space-y-3">
            {groups.filter(g => g.verification_status === "pending").length > 0 && (
              <div className="mb-4 rounded-2xl border border-orange-400/20 bg-orange-400/5 p-4">
                <p className="mb-3 text-sm font-semibold text-orange-400">Grupos pendientes de verificación</p>
                <div className="space-y-3">
                  {groups.filter(g => g.verification_status === "pending").map(g => (
                    <div key={g.id} className="rounded-xl border border-brand-border bg-brand-card p-4">
                      <div className="mb-3">
                        <p className="font-semibold text-white">{g.name}</p>
                        <p className="text-xs text-brand-muted">{g.city ?? "Sin ciudad"} · {new Date(g.created_at).toLocaleDateString("es-MX")}</p>
                      </div>
                      <div className="flex flex-col gap-2 sm:flex-row">
                        <button onClick={() => approveGroup(g.id)}
                          className="flex-1 rounded-xl bg-brand-green py-3 text-sm font-bold text-black">✓ Verificar grupo</button>
                        <button onClick={() => rejectGroup(g.id)}
                          className="flex-1 rounded-xl border border-red-500/30 bg-red-500/5 py-3 text-sm font-medium text-red-400">✕ Rechazar</button>
                      </div>
                    </div>
                  ))}
                </div>
              </div>
            )}

            <h3 className="text-sm font-semibold text-brand-muted">Todos los grupos ({groups.length})</h3>
            {groups.length === 0 && <p className="py-8 text-center text-sm text-brand-muted">Sin grupos registrados.</p>}
            <div className="space-y-2">
              {groups.map(g => (
                <div key={g.id} className="flex items-center gap-3 rounded-xl border border-brand-border bg-brand-card px-4 py-3">
                  <div className="min-w-0 flex-1">
                    <div className="flex items-center gap-1.5">
                      <p className="truncate font-semibold text-white">{g.name}</p>
                      {g.is_verified && <span className="shrink-0 text-xs text-brand-green">✓</span>}
                    </div>
                    <p className="truncate text-xs text-brand-muted">
                      {g.city ?? "—"} · ★ {g.rating?.toFixed(1) ?? "—"} ({g.total_reviews ?? 0})
                    </p>
                  </div>
                  <span className={`shrink-0 rounded-full px-2.5 py-1 text-xs font-medium ${STATUS_COLOR[g.verification_status] ?? "text-brand-muted bg-brand-card2"}`}>
                    {g.is_active ? "active" : g.verification_status}
                  </span>
                </div>
              ))}
            </div>
          </div>
        )}

        {/* ═══ USUARIOS ════════════════════════════════════════════════ */}
        {tab === "users" && (
          <div className="space-y-2">
            <h3 className="mb-3 text-sm font-semibold text-brand-muted">Todos los usuarios ({users.length})</h3>
            {users.length === 0 && <p className="py-8 text-center text-sm text-brand-muted">Sin usuarios registrados.</p>}
            {users.map(u => (
              <div key={u.id} className="flex items-center gap-3 rounded-xl border border-brand-border bg-brand-card px-4 py-3">
                <div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-full bg-brand-card2 text-sm font-bold text-white">
                  {u.name?.charAt(0)?.toUpperCase() ?? "?"}
                </div>
                <div className="min-w-0 flex-1">
                  <p className="truncate font-semibold text-white">{u.name}</p>
                  <p className="truncate text-xs text-brand-muted">{u.email}</p>
                  {u.city && <p className="truncate text-xs text-brand-muted">{u.city}</p>}
                </div>
                <span className={`shrink-0 rounded-full px-2.5 py-1 text-xs font-medium ${
                  u.role === "admin"  ? "text-red-400 bg-red-400/10"      :
                  u.role === "group"  ? "text-blue-400 bg-blue-400/10"    :
                  u.role === "talent" ? "text-purple-400 bg-purple-400/10" :
                  "text-brand-green bg-brand-green/10"
                }`}>
                  {u.role}
                </span>
              </div>
            ))}
          </div>
        )}

        {/* ═══ RESERVAS ════════════════════════════════════════════════ */}
        {tab === "reservations" && (
          <div className="space-y-2">
            <h3 className="mb-3 text-sm font-semibold text-brand-muted">Últimas reservas ({reservations.length})</h3>
            {reservations.length === 0 && <p className="py-8 text-center text-sm text-brand-muted">Sin reservas registradas.</p>}
            {reservations.map(r => (
              <div key={r.id} className="flex items-center gap-3 rounded-xl border border-brand-border bg-brand-card px-4 py-3">
                <div className="min-w-0 flex-1">
                  <p className="truncate font-semibold text-white">{(r.groups as any)?.name ?? "—"}</p>
                  <p className="truncate text-xs text-brand-muted">
                    {(r.profiles as any)?.name ?? "—"} · {new Date(r.event_date).toLocaleDateString("es-MX")}
                  </p>
                </div>
                <div className="flex shrink-0 flex-col items-end gap-1">
                  <span className={`rounded-full px-2.5 py-1 text-xs font-medium ${STATUS_COLOR[r.status] ?? "text-brand-muted bg-brand-card2"}`}>
                    {r.status}
                  </span>
                  <span className="text-xs font-bold text-white">${r.total_price.toLocaleString("es-MX")}</span>
                </div>
              </div>
            ))}
          </div>
        )}

        {/* ═══ MEDIOS ══════════════════════════════════════════════════ */}
        {tab === "media" && (
          <div className="space-y-4">
            <div className="flex items-center justify-between">
              <h3 className="text-sm font-semibold text-brand-muted">Medios de grupos ({media.length})</h3>
              <button onClick={loadMedia} className="rounded-lg border border-brand-border px-3 py-2 text-xs text-brand-muted hover:text-white">↻ Actualizar</button>
            </div>
            {media.length === 0 ? (
              <div className="rounded-2xl border border-brand-border bg-brand-card p-10 text-center">
                <p className="text-4xl">🖼️</p>
                <p className="mt-3 text-sm text-brand-muted">Ningún grupo ha subido imágenes todavía.</p>
              </div>
            ) : (
              <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-3">
                {media.map(m => (
                  <div key={m.id} className="overflow-hidden rounded-2xl border border-brand-border bg-brand-card">
                    {m.banner_url ? (
                      <div className="relative h-36 w-full bg-brand-card2">
                        <Image src={m.banner_url} alt={`Banner de ${m.name}`} fill className="object-cover" unoptimized />
                      </div>
                    ) : (
                      <div className="flex h-36 items-center justify-center bg-brand-card2">
                        <span className="text-4xl opacity-20">🎸</span>
                      </div>
                    )}
                    <div className="flex items-center gap-3 p-4">
                      {m.avatar_url ? (
                        <div className="relative h-11 w-11 shrink-0 overflow-hidden rounded-full border border-brand-border">
                          <Image src={m.avatar_url} alt={m.name} fill className="object-cover" unoptimized />
                        </div>
                      ) : (
                        <div className="flex h-11 w-11 shrink-0 items-center justify-center rounded-full border border-brand-border bg-brand-card2 text-sm font-bold text-white">
                          {m.name?.charAt(0)?.toUpperCase() ?? "?"}
                        </div>
                      )}
                      <div className="min-w-0 flex-1">
                        <p className="truncate font-semibold text-white">{m.name}</p>
                        <p className="truncate text-xs text-brand-muted">{m.city ?? "Sin ciudad"}</p>
                      </div>
                      <span className={`shrink-0 rounded-full px-2.5 py-1 text-xs font-medium ${STATUS_COLOR[m.verification_status] ?? "text-brand-muted bg-brand-card2"}`}>
                        {m.is_active ? "active" : m.verification_status}
                      </span>
                    </div>
                    <div className="flex gap-3 border-t border-brand-border px-4 py-2.5">
                      <span className={`text-xs ${m.avatar_url ? "text-brand-green" : "text-brand-muted"}`}>{m.avatar_url ? "✓" : "○"} Avatar</span>
                      <span className="text-brand-border">·</span>
                      <span className={`text-xs ${m.banner_url ? "text-brand-green" : "text-brand-muted"}`}>{m.banner_url ? "✓" : "○"} Banner</span>
                    </div>
                  </div>
                ))}
              </div>
            )}
          </div>
        )}

        {/* ═══ MAPA ════════════════════════════════════════════════════ */}
        {tab === "map" && (
          <div className="space-y-4">
            <div className="flex items-center justify-between">
              <div>
                <h3 className="text-base font-semibold text-white">Mapa de grupos</h3>
                <p className="text-xs text-brand-muted">Ubicaciones reportadas por los grupos · tiempo real</p>
              </div>
              <button onClick={loadMap} className="rounded-lg border border-brand-border px-3 py-2 text-xs text-brand-muted hover:text-white">↻ Actualizar</button>
            </div>
            <AdminMap locations={locations} />
          </div>
        )}

      </main>
    </div>
  );
}

export default function AdminDashboard() {
  return (
    <Suspense fallback={
      <div className="min-h-screen bg-brand-bg">
        <Navbar />
        <div className="flex min-h-[60vh] items-center justify-center">
          <div className="h-10 w-10 animate-spin rounded-full border-2 border-brand-border border-t-brand-green" />
        </div>
      </div>
    }>
      <AdminDashboardInner />
    </Suspense>
  );
}
