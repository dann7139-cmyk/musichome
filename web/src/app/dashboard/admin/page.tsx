"use client";

import { useEffect, useState, useCallback, Suspense } from "react";
import { useRouter, useSearchParams } from "next/navigation";
import Image from "next/image";
import Navbar from "@/components/Navbar";
import { supabase, type Profile } from "@/lib/supabase";
import type { GroupLocation } from "@/components/AdminMap";
import AdminOpsPanel from "@/components/admin/AdminOpsPanel";
import AdminHomeReport from "@/components/admin/AdminHomeReport";
import { categoryForGenre, CATEGORY_LABELS } from "@/lib/genreCategories";
import { Modal, ActionBtn } from "@/components/admin/ui";
import AdsManager from "@/components/admin/AdsManager";
import TalentsManager from "@/components/admin/TalentsManager";
import FinancesManager from "@/components/admin/FinancesManager";
import ReportsManager from "@/components/admin/ReportsManager";
import AdminStatsPanel from "@/components/admin/AdminStatsPanel";

// Leaflet map: carga dinámica (no SSR) para evitar errores de window
import dynamic2 from "next/dynamic";
const AdminMap = dynamic2(() => import("@/components/AdminMap"), { ssr: false });

type Tab = "overview" | "ads" | "groups" | "users" | "reservations" | "media" | "map" | "ops" | "stats" | "talents" | "reports" | "finances";

// Bug real reportado 2026-09-19: "le aprieto a méxico y sale un estado de
// estados unidos, falta poner el país de canadá y estados unidos" — la
// primera versión adivinaba el país a partir del nombre del estado (lista
// chica a mano, sin Washington ni la mayoría de provincias canadienses),
// así que un grupo real en EE.UU. (state='Washington') caía a "México" por
// default. `groups.country` YA es una columna real y confiable (se llena
// desde ProviderApplyScreen/admin_approve_provider_application con uno de
// los 3 valores reales: México/Estados Unidos/Canadá) — se usa directo,
// sin adivinar nada.
function groupCountry(g: { country: string | null }): string {
  return g.country ?? "México";
}

interface GroupRow {
  id: string; name: string; city: string | null; genre: string | null; state: string | null; country: string | null;
  is_active: boolean | null; verification_status: string;
  rating: number | null;
  total_reviews: number | null; created_at: string;
  is_verified: boolean | null;
  // Paridad con la app (2026-09-17) — mismos dos botones que ya existen
  // en AdminGroupsScreen: Plus de cortesía y brillo de marco (sql/665).
  is_plus_active: boolean | null;
  plus_expires_at: string | null;
  plus_subscription_id: string | null;
  admin_highlight: boolean | null;
}
interface UserRow {
  id: string; full_name: string; email: string;
  role: string; city: string | null; created_at: string;
}
interface ReservationRow {
  id: string; event_date: string; status: string;
  payment_status: string; total_price: number; created_at: string;
  groups: { name: string } | null;
  profiles: { full_name: string } | null;
}
interface MediaRow {
  id: string; name: string; city: string | null;
  profile_image: string | null;
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
  // Perfil completo (rol + alcance de país + candado de dinero) — mismo
  // shape que get_my_profile() usa en la app móvil (AuthContext.tsx).
  const [myProfile,   setMyProfile]   = useState<Profile | null>(null);

  // Overview stats
  const [stats, setStats] = useState({
    totalGroups: 0, activeGroups: 0, totalClients: 0,
    totalRevenue: 0, pendingAds: 0, pendingVerif: 0,
    totalReservations: 0, completedReservations: 0,
  });

  // Tab data
  const [groups,       setGroups]       = useState<GroupRow[]>([]);
  const [users,        setUsers]        = useState<UserRow[]>([]);
  const [reservations, setReservations] = useState<ReservationRow[]>([]);
  const [media,        setMedia]        = useState<MediaRow[]>([]);
  const [locations,    setLocations]    = useState<GroupLocation[]>([]);
  // Buscadores (petición real: "que sea fácil") — filtran lo que ya se
  // cargó, sin ida y vuelta al servidor.
  const [groupSearch,  setGroupSearch]  = useState("");
  const [userSearch,   setUserSearch]   = useState("");

  // Petición real (2026-09-19): "quiero ver cuántos tengo de cada
  // categoría, divididos por estado — voy a empezar por Jalisco, después
  // Monterrey, para no hacerme bolas de lo que ya tengo y lo que me falta
  // agregar." Mismo criterio simple que ya usa TalentsManager.tsx.
  const [groupActiveCountry, setGroupActiveCountry] = useState<string | null>(null);
  const [groupActiveState,   setGroupActiveState]   = useState<string | null>(null);
  const [showGroupStats,     setShowGroupStats]     = useState(false);
  const [expandedStatCats,   setExpandedStatCats]   = useState<Set<string>>(new Set());

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

      // get_my_profile() — misma RPC que usa AuthContext.tsx de la app
      // móvil; trae role + admin_country_scope + admin_can_manage_payouts
      // en una sola llamada, sin depender de que RLS deje leer profiles
      // directo con .select().
      const { data: profRows } = await supabase.rpc("get_my_profile");
      const prof = (Array.isArray(profRows) ? profRows[0] : profRows) as Profile | null;

      const role = prof?.role ?? session.user.user_metadata?.role;

      if (role !== "admin" && role !== "admin_ops") { router.replace("/"); return; }

      // ── CRÍTICO: asegurar que la fila profiles exista ─────────────────
      // is_admin() en Supabase consulta profiles. Sin esta fila, todas
      // las queries retornan vacío aunque el usuario sea admin en auth.
      // (Las 4 cuentas admin reales ya tienen fila — esto es solo red de
      // seguridad para el caso raro de un admin creado a mano sin ella.)
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
      } else {
        setMyProfile(prof);
      }

      setAuthorized(true);
      // admin_ops (esta fase) solo ve AdminOpsPanel — nunca las pestañas
      // amplias de abajo, que además usan queries crudas que su RLS no
      // deja pasar.
      if (role === "admin_ops") {
        setTab("ops");
        setLoading(false);
        return;
      }
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

  const loadGroups = useCallback(async () => {
    const { data, error } = await supabase
      .from("groups")
      .select("id, name, city, genre, state, country, is_active, verification_status, rating, total_reviews, created_at, is_verified, is_plus_active, plus_expires_at, plus_subscription_id, admin_highlight")
      .order("created_at", { ascending: false })
      .limit(200);
    if (error) console.error("[Admin groups]", error.message);
    setGroups((data as GroupRow[]) ?? []);
  }, []);

  const loadUsers = useCallback(async () => {
    const { data, error } = await supabase
      .from("profiles")
      .select("id, full_name, email, role, city, created_at")
      .order("created_at", { ascending: false })
      .limit(200);
    if (error) console.error("[Admin users]", error.message);
    setUsers((data as UserRow[]) ?? []);
  }, []);

  const loadReservations = useCallback(async () => {
    const { data, error } = await supabase
      .from("reservations")
      .select("id, event_date, status, payment_status, total_price, created_at, groups(name), profiles(full_name)")
      .order("created_at", { ascending: false })
      .limit(40);
    if (error) console.error("[Admin reservations]", error.message);
    setReservations((data as unknown as ReservationRow[]) ?? []);
  }, []);

  const loadMedia = useCallback(async () => {
    // groups no tiene avatar_url/banner_url — su única imagen real es
    // profile_image (hallazgo real corregido aquí, esta query llevaba
    // tiempo devolviendo error/vacío en silencio).
    const { data, error } = await supabase
      .from("groups")
      .select("id, name, city, profile_image, is_active, verification_status, created_at")
      .not("profile_image", "is", null)
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
    if (tab === "groups")       loadGroups();
    if (tab === "users")        loadUsers();
    if (tab === "reservations") loadReservations();
    if (tab === "media")        loadMedia();
    if (tab === "map")          loadMap();
  }, [tab, authorized, loadGroups, loadUsers, loadReservations, loadMedia, loadMap]);

  // ── Actions ───────────────────────────────────────────────────────────────
  const approveGroup = async (id: string) => {
    await supabase.from("groups").update({ is_active: true, verification_status: "approved", is_verified: true }).eq("id", id);
    loadGroups(); loadOverview();
  };
  const rejectGroup = async (id: string) => {
    await supabase.from("groups").update({ verification_status: "rejected", is_active: false }).eq("id", id);
    loadGroups();
  };

  // Paridad con AdminGroupsScreen (app) — 2026-09-17, petición real: "que
  // tenga la misma función lo que puedo hacer con un grupo como en la
  // app... los dos botones que aparezca igual". Mismas RPC que la app.
  const [manageTarget, setManageTarget] = useState<GroupRow | null>(null);
  const [manageLoading, setManageLoading] = useState(false);

  const grantPlusWeb = async (months: number) => {
    if (!manageTarget) return;
    setManageLoading(true);
    const expiresAt = new Date();
    expiresAt.setMonth(expiresAt.getMonth() + months);
    const { data, error } = await supabase.rpc("admin_grant_plus", {
      p_group_id: manageTarget.id, p_expires_at: expiresAt.toISOString(),
    });
    setManageLoading(false);
    if (error || !data?.ok) { window.alert(error?.message ?? data?.error ?? "No se pudo activar Plus."); return; }
    const updated = { ...manageTarget, is_plus_active: true, plus_expires_at: data.expires_at, plus_subscription_id: data.sub_id, is_verified: true };
    setManageTarget(updated);
    setGroups(prev => prev.map(g => (g.id === updated.id ? updated : g)));
  };
  const revokePlusWeb = async () => {
    if (!manageTarget) return;
    if (!window.confirm(`¿Quitar Plus a ${manageTarget.name}?`)) return;
    setManageLoading(true);
    const { data, error } = await supabase.rpc("admin_revoke_plus", { p_group_id: manageTarget.id });
    setManageLoading(false);
    if (error || !data?.ok) { window.alert(error?.message ?? data?.error ?? "No se pudo quitar Plus."); return; }
    const updated = { ...manageTarget, is_plus_active: false, plus_expires_at: null, plus_subscription_id: null };
    setManageTarget(updated);
    setGroups(prev => prev.map(g => (g.id === updated.id ? updated : g)));
  };
  const toggleHighlightWeb = async () => {
    if (!manageTarget) return;
    const turningOn = !manageTarget.admin_highlight;
    setManageLoading(true);
    const { data, error } = await supabase.rpc("admin_set_group_highlight", { p_group_id: manageTarget.id, p_on: turningOn });
    setManageLoading(false);
    if (error || !data?.ok) { window.alert(error?.message ?? data?.error ?? "No se pudo cambiar el brillo de marco."); return; }
    const updated = { ...manageTarget, admin_highlight: turningOn };
    setManageTarget(updated);
    setGroups(prev => prev.map(g => (g.id === updated.id ? updated : g)));
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

  // admin_ops (Fase 1, sql/660) — solo ve AdminOpsPanel, nada de las
  // pestañas de abajo (Anuncios/Grupos/Usuarios/Reservas/Medios/Mapa usan
  // queries crudas que su RLS no deja pasar, y no es su alcance de todos
  // modos: no-shows, pagos, verificación, eventos, historial, fotos,
  // cotizaciones de conserjería, solicitudes, visa — todo dentro del panel).
  if (myProfile?.role === "admin_ops") {
    return (
      <div className="min-h-screen bg-brand-bg">
        <Navbar />
        <main className="mx-auto max-w-7xl px-4 pb-20 pt-24 sm:px-6 lg:px-8">
          <div className="mb-6">
            <h1 className="text-xl font-extrabold text-white sm:text-2xl">
              Panel — {myProfile.admin_country_scope === "US" ? "Estados Unidos" : myProfile.admin_country_scope === "MX" ? "México" : myProfile.admin_country_scope}
            </h1>
            <p className="text-sm text-brand-muted">
              Solo ves lo que corresponde a tu país
              {myProfile.admin_can_manage_payouts === false ? " · sin acceso a dinero" : ""}
            </p>
          </div>
          <AdminOpsPanel profile={myProfile} />
        </main>
      </div>
    );
  }

  const TABS: { key: Tab; label: string; icon: string; badge?: number }[] = [
    { key: "overview",     label: "Resumen",   icon: "📊" },
    { key: "ops",          label: "Operación", icon: "🛠️" },
    { key: "stats",        label: "Estadísticas", icon: "📈" },
    { key: "ads",          label: "Anuncios",  icon: "📢", badge: stats.pendingAds   },
    { key: "groups",       label: "Proveedores", icon: "🎸", badge: stats.pendingVerif  },
    { key: "users",        label: "Usuarios",  icon: "👥" },
    { key: "reservations", label: "Reservas",  icon: "📅" },
    { key: "media",        label: "Medios",    icon: "🖼️" },
    { key: "map",          label: "Mapa",      icon: "🗺️" },
    { key: "talents",      label: "Talentos",  icon: "💼" },
    { key: "reports",      label: "Reportes",  icon: "📈" },
    { key: "finances",     label: "Finanzas",  icon: "💰" },
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

        {/* ═══ RESUMEN (sql/660 — reporte + acciones rápidas, paridad con
             DashboardScreen.tsx de la app móvil) ══════════════════════ */}
        {tab === "overview" && <AdminHomeReport onNavigateTab={(t) => changeTab(t as Tab)} />}

        {/* ═══ ANUNCIOS ════════════════════════════════════════════════
            2026-09-18 — reemplazado por AdsManager (pestañas por estado,
            editar/pausar/borrar, paridad real con AdApprovalScreen de la
            app). Sin scopeCountry: el admin completo ve/crea de todos
            los países, incluido "Internacional". */}
        {tab === "ads" && <AdsManager />}

        {/* ═══ GRUPOS ══════════════════════════════════════════════════ */}
        {tab === "groups" && (
          <div className="space-y-3">
            {groups.filter(g => g.verification_status === "pending").length > 0 && (
              <div className="mb-4 rounded-2xl border border-orange-400/20 bg-orange-400/5 p-4">
                <p className="mb-3 text-sm font-semibold text-orange-400">Proveedores pendientes de verificación</p>
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

            <div className="flex flex-wrap items-center justify-between gap-3">
              <h3 className="text-sm font-semibold text-brand-muted">
                {groupActiveState || groupActiveCountry
                  ? `Proveedores ${groupActiveState ? `en ${groupActiveState}` : `en ${groupActiveCountry}`} (${groups.filter((g) => groupActiveState ? g.state?.trim().toLowerCase() === groupActiveState.toLowerCase() : groupCountry(g) === groupActiveCountry).length} de ${groups.length})`
                  : `Todos los proveedores (${groups.length})`}
              </h3>
              <input
                type="text"
                value={groupSearch}
                onChange={(e) => setGroupSearch(e.target.value)}
                placeholder="🔍 Buscar por nombre, género o ciudad…"
                className="w-64 rounded-lg border border-brand-border bg-brand-card2 px-3 py-2 text-xs text-white placeholder:text-brand-muted outline-none focus:border-brand-green"
              />
            </div>

            {/* Filtro país → estado — país real de groups.country, nunca adivinado */}
            {groups.length > 0 && (() => {
              const gCountries = Array.from(new Set(groups.map((g) => groupCountry(g)))).sort();
              const gStates = Array.from(new Set(
                groups.filter((g) => !groupActiveCountry || groupCountry(g) === groupActiveCountry)
                  .map((g) => g.state?.trim()).filter((s): s is string => !!s)
              )).sort();
              return (
                <div className="flex flex-wrap gap-1.5">
                  {gCountries.map((c) => (
                    <button key={c} onClick={() => {
                      setGroupActiveCountry(groupActiveCountry === c ? null : c);
                      setGroupActiveState(null);
                    }}
                      className={`rounded-full px-3 py-1.5 text-xs font-medium ${groupActiveCountry === c ? "bg-brand-green text-black" : "border border-brand-green/40 text-brand-green"}`}>
                      {c}
                    </button>
                  ))}
                  {groupActiveCountry && gStates.map((st) => (
                    <button key={st} onClick={() => {
                      setGroupActiveState(groupActiveState === st ? null : st);
                      setShowGroupStats(true);
                    }}
                      className={`rounded-full px-3 py-1.5 text-xs font-medium ${groupActiveState === st ? "bg-brand-green text-black" : "border border-brand-border text-brand-muted"}`}>
                      📍 {st}
                    </button>
                  ))}
                </div>
              );
            })()}

            {/* Desglose por categoría/género — petición real 2026-09-19:
                "cuántos de cada categoría tengo en un estado... para no
                hacerme bolas... y saber qué me hace falta agregar más." */}
            {groups.length > 0 && (
              <div className="rounded-2xl border border-brand-border bg-brand-card">
                <button
                  onClick={() => setShowGroupStats((v) => !v)}
                  className="flex w-full items-center justify-between px-4 py-3 text-left"
                >
                  <span className="text-sm font-semibold text-white">
                    📊 Proveedores por categoría {groupActiveState ? `en ${groupActiveState}` : groupActiveCountry ? `en ${groupActiveCountry} (todos los estados)` : "(todos los países)"}
                  </span>
                  <span className="text-brand-muted">{showGroupStats ? "▲" : "▼"}</span>
                </button>
                {showGroupStats && (() => {
                  const scoped = groups.filter((g) => {
                    if (groupActiveState) return g.state?.trim().toLowerCase() === groupActiveState.toLowerCase();
                    if (groupActiveCountry) return groupCountry(g) === groupActiveCountry;
                    return true;
                  });
                  const stats = CATEGORY_LABELS.map((cat) => {
                    const counts: Record<string, number> = {};
                    cat.genres.forEach((g) => { counts[g] = 0; });
                    let total = 0;
                    scoped.forEach((g) => {
                      const key = CATEGORY_LABELS.find((c) => c.genres.includes(g.genre ?? ""))?.key;
                      if (key === cat.key && g.genre) {
                        total += 1;
                        counts[g.genre] = (counts[g.genre] ?? 0) + 1;
                      }
                    });
                    const present = Object.entries(counts).filter(([, n]) => n > 0)
                      .sort((a, b) => cat.genres.indexOf(a[0]) - cat.genres.indexOf(b[0]));
                    const missing = cat.genres.filter((g) => !counts[g]);
                    return { ...cat, total, present, missing };
                  });
                  return (
                    <div className="max-h-80 space-y-4 overflow-y-auto border-t border-brand-border px-4 py-4">
                      {stats.map((cat) => (
                        <div key={cat.key}>
                          <div className="mb-1.5 flex items-center justify-between">
                            <p className="text-xs font-semibold text-white">{cat.label}</p>
                            <p className="text-xs font-semibold text-brand-green">{cat.total}</p>
                          </div>
                          {cat.present.length > 0 ? (
                            <div className="flex flex-wrap gap-1.5">
                              {cat.present.map(([genre, n]) => (
                                <span key={genre} className="rounded-md border border-brand-border bg-brand-card2 px-2 py-1 text-[11px] text-white">
                                  {genre} <b className="text-brand-green">{n}</b>
                                </span>
                              ))}
                            </div>
                          ) : (
                            <p className="text-[11px] italic text-brand-muted">Sin ninguno registrado todavía</p>
                          )}
                          {cat.missing.length > 0 && (
                            <button
                              onClick={() => setExpandedStatCats((prev) => {
                                const next = new Set(prev);
                                next.has(cat.key) ? next.delete(cat.key) : next.add(cat.key);
                                return next;
                              })}
                              className="mt-1 text-[11px] text-brand-muted hover:text-white"
                            >
                              {expandedStatCats.has(cat.key) ? "▾" : "▸"} Te faltan {cat.missing.length}
                            </button>
                          )}
                          {expandedStatCats.has(cat.key) && cat.missing.length > 0 && (
                            <p className="mt-1 text-[11px] leading-relaxed text-brand-muted">{cat.missing.join(", ")}</p>
                          )}
                        </div>
                      ))}
                    </div>
                  );
                })()}
              </div>
            )}

            {groups.length === 0 && <p className="py-8 text-center text-sm text-brand-muted">Sin proveedores registrados.</p>}
            {Object.entries(
              groups
                .filter((g) => {
                  if (groupActiveState) return g.state?.trim().toLowerCase() === groupActiveState.toLowerCase();
                  if (groupActiveCountry) return groupCountry(g) === groupActiveCountry;
                  return true;
                })
                .filter((g) => {
                  const q = groupSearch.trim().toLowerCase();
                  if (!q) return true;
                  return [g.name, g.genre, g.city].some((v) => v?.toLowerCase().includes(q));
                })
                .reduce<Record<string, GroupRow[]>>((acc, g) => {
                  const cat = categoryForGenre(g.genre);
                  (acc[cat] ??= []).push(g);
                  return acc;
                }, {})
            ).sort(([a], [b]) => a.localeCompare(b)).map(([cat, rows]) => (
              <div key={cat} className="mb-5">
                <h4 className="mb-2 text-xs font-semibold uppercase tracking-wide text-brand-muted">{cat} · {rows.length}</h4>
                <div className="space-y-2">
                  {rows.map(g => (
                    <button
                      key={g.id}
                      onClick={() => setManageTarget(g)}
                      className={`flex w-full items-center gap-3 rounded-xl border bg-brand-card px-4 py-3 text-left transition-colors hover:border-brand-green/40 ${
                        g.admin_highlight ? "border-brand-green/70 shadow-[0_0_10px_rgba(0,230,118,0.35)]" : "border-brand-border"
                      }`}
                    >
                      <div className="min-w-0 flex-1">
                        <div className="flex items-center gap-1.5">
                          <p className="truncate font-semibold text-white">{g.name}</p>
                          {g.is_verified && <span className="shrink-0 text-xs text-brand-green">✓</span>}
                          {g.is_plus_active && <span className="shrink-0 text-xs text-brand-green">✨ Plus</span>}
                        </div>
                        <p className="truncate text-xs text-brand-muted">
                          {g.genre ?? "—"} · {g.city ?? "—"} · ★ {g.rating?.toFixed(1) ?? "—"} ({g.total_reviews ?? 0})
                        </p>
                      </div>
                      <span className={`shrink-0 rounded-full px-2.5 py-1 text-xs font-medium ${STATUS_COLOR[g.verification_status] ?? "text-brand-muted bg-brand-card2"}`}>
                        {g.is_active ? "active" : g.verification_status}
                      </span>
                    </button>
                  ))}
                </div>
              </div>
            ))}

            {/* Modal de manejo — mismos dos botones que AdminGroupsScreen
                en la app (Plus de cortesía + brillo de marco, sql/664/665).
                Petición real: "que tenga la misma función... los dos
                botones que aparezca igual realmente". */}
            <Modal open={!!manageTarget} onClose={() => setManageTarget(null)} title={manageTarget?.name ?? ""}>
              <p className="mb-4 text-xs text-brand-muted">
                {manageTarget?.genre ?? "—"} · {manageTarget?.city ?? "—"}
              </p>

              <div className="mb-4 space-y-2 rounded-xl border border-brand-border bg-brand-bg p-4">
                <p className="text-sm font-semibold text-white">Daricefy Plus</p>
                {manageTarget?.is_plus_active ? (
                  <>
                    <p className="text-xs text-brand-muted">
                      {manageTarget.plus_subscription_id?.startsWith("admin_grant_")
                        ? `✨ Cortesía activa${manageTarget.plus_expires_at ? ` — vence el ${new Date(manageTarget.plus_expires_at).toLocaleDateString("es-MX")}` : ""}.`
                        : "💳 Suscripción Stripe de pago activa."}
                    </p>
                    <ActionBtn label="Quitar Plus" color="red" busy={manageLoading} onClick={revokePlusWeb} />
                  </>
                ) : (
                  <>
                    <p className="text-xs text-brand-muted">Activa Plus gratis (cortesía) — patrocinios, embajadores o alianzas, sin pasar por Stripe.</p>
                    <div className="flex flex-wrap gap-2">
                      <ActionBtn label="1 mes"  color="green" busy={manageLoading} onClick={() => grantPlusWeb(1)} />
                      <ActionBtn label="2 meses" color="green" busy={manageLoading} onClick={() => grantPlusWeb(2)} />
                      <ActionBtn label="1 año"  color="green" busy={manageLoading} onClick={() => grantPlusWeb(12)} />
                    </div>
                  </>
                )}
              </div>

              <div className="space-y-2 rounded-xl border border-brand-border bg-brand-bg p-4">
                <p className="text-sm font-semibold text-white">✨ Brillo de marco</p>
                <p className="text-xs text-brand-muted">
                  {manageTarget?.admin_highlight
                    ? "Activo — su tarjeta brilla en el Explorador (solo el marco). Es visual, no afecta patrocinio ni orden real."
                    : "Resalta el marco de la tarjeta de este proveedor en el Explorador — solo visual, sin tocar patrocinio ni orden real."}
                </p>
                <ActionBtn
                  label={manageTarget?.admin_highlight ? "Quitar brillo de marco" : "Activar brillo de marco"}
                  color={manageTarget?.admin_highlight ? "red" : "green"}
                  busy={manageLoading}
                  onClick={toggleHighlightWeb}
                />
              </div>
            </Modal>
          </div>
        )}

        {/* ═══ USUARIOS ════════════════════════════════════════════════ */}
        {tab === "users" && (
          <div className="space-y-5">
            <div className="flex items-center justify-between gap-3">
              <h3 className="text-sm font-semibold text-brand-muted">Todos los usuarios ({users.length})</h3>
              <input
                type="text"
                value={userSearch}
                onChange={(e) => setUserSearch(e.target.value)}
                placeholder="🔍 Buscar por nombre, correo o ciudad…"
                className="w-64 rounded-lg border border-brand-border bg-brand-card2 px-3 py-2 text-xs text-white placeholder:text-brand-muted outline-none focus:border-brand-green"
              />
            </div>
            {users.length === 0 && <p className="py-8 text-center text-sm text-brand-muted">Sin usuarios registrados.</p>}
            {([
              ["admin", "Admin"], ["admin_ops", "Admin (país)"], ["group", "Grupos"],
              ["talent", "Talentos"], ["client", "Clientes"],
            ] as const).map(([role, label]) => {
              const q = userSearch.trim().toLowerCase();
              const rows = users.filter(u => u.role === role).filter((u) =>
                !q || [u.full_name, u.email, u.city].some((v) => v?.toLowerCase().includes(q))
              );
              if (rows.length === 0) return null;
              return (
                <div key={role}>
                  <h4 className="mb-2 text-xs font-semibold uppercase tracking-wide text-brand-muted">{label} · {rows.length}</h4>
                  <div className="space-y-2">
                    {rows.map(u => (
                      <div key={u.id} className="flex items-center gap-3 rounded-xl border border-brand-border bg-brand-card px-4 py-3">
                        <div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-full bg-brand-card2 text-sm font-bold text-white">
                          {u.full_name?.charAt(0)?.toUpperCase() ?? "?"}
                        </div>
                        <div className="min-w-0 flex-1">
                          <p className="truncate font-semibold text-white">{u.full_name}</p>
                          <p className="truncate text-xs text-brand-muted">{u.email}</p>
                          {u.city && <p className="truncate text-xs text-brand-muted">{u.city}</p>}
                        </div>
                      </div>
                    ))}
                  </div>
                </div>
              );
            })}
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
                    {(r.profiles as any)?.full_name ?? "—"} · {new Date(r.event_date).toLocaleDateString("es-MX")}
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
                    {m.profile_image ? (
                      <div className="relative h-36 w-full bg-brand-card2">
                        <Image src={m.profile_image} alt={m.name} fill className="object-cover" unoptimized />
                      </div>
                    ) : (
                      <div className="flex h-36 items-center justify-center bg-brand-card2">
                        <span className="text-4xl opacity-20">🎸</span>
                      </div>
                    )}
                    <div className="flex items-center gap-3 p-4">
                      <div className="min-w-0 flex-1">
                        <p className="truncate font-semibold text-white">{m.name}</p>
                        <p className="truncate text-xs text-brand-muted">{m.city ?? "Sin ciudad"}</p>
                      </div>
                      <span className={`shrink-0 rounded-full px-2.5 py-1 text-xs font-medium ${STATUS_COLOR[m.verification_status] ?? "text-brand-muted bg-brand-card2"}`}>
                        {m.is_active ? "active" : m.verification_status}
                      </span>
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

        {/* ═══ TALENTOS ════════════════════════════════════════════════ */}
        {tab === "talents" && <TalentsManager />}

        {/* ═══ FINANZAS ════════════════════════════════════════════════ */}
        {tab === "finances" && <FinancesManager />}

        {/* ═══ REPORTES ════════════════════════════════════════════════ */}
        {tab === "reports" && <ReportsManager />}

        {/* ═══ OPERACIÓN (sql/660, Fase 1 del panel de escritorio) ══════ */}
        {tab === "ops" && myProfile && <AdminOpsPanel profile={myProfile} />}

        {/* ═══ ESTADÍSTICAS ═════════════════════════════════════════════ */}
        {tab === "stats" && <AdminStatsPanel />}

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
