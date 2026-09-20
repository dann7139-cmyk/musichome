"use client";

/**
 * AdsManager — lista completa de anuncios con pestañas por estado, tal
 * cual AdApprovalScreen de la app (petición real 2026-09-18: "que jale
 * bien en la web en los dos tal cual como pongo anuncios gratis y cuáles
 * hay, tal como lo veo en la app"). Compartido entre:
 *   - dashboard/admin (role='admin', sin `scopeCountry` — ve y crea de
 *     cualquier país, incluido "Internacional").
 *   - AdminOpsPanel (role='admin_ops', con `scopeCountry` — solo ve/edita
 *     los de SU país + los internacionales de solo lectura; nunca puede
 *     crear "Internacional" ni tocar los de otro país — sql/667).
 *
 * 2026-09-18 — se agrega "Promoción de grupo" (Destacado/Recomendado/
 * Puja: bid_orders, recommendation_orders, sponsored_groups), mezclado en
 * la misma lista con badge de tipo — petición real: "faltó poner lo de
 * destacados... creo que en la app tengo más cosas cuando me meto a
 * anuncios". Activar/desactivar SOLO para admin completo (las RPC
 * admin_activate_* exigen role='admin' del lado del servidor) — admin_ops
 * no ve el botón "+ Destacar grupo", aunque sí ve estas filas en su lista
 * si caen en su país (misma regla de sql/667 para is_free=false igual).
 *
 * No incluye (backlog, fuera de esta pieza): anuncios pagados con Stripe
 * (Payment Intent real desde la web).
 */

import { useCallback, useEffect, useMemo, useState } from "react";
import Image from "next/image";
import { supabase } from "@/lib/supabase";
import CreateFreeAdModal from "./CreateFreeAdModal";
import { Spinner, EmptyBox } from "./ui";

interface Ad {
  id: string; type: string; title: string; subtitle: string | null;
  status: string; is_free: boolean; total_price: number | null;
  target_country: string | null; target_state: string | null;
  starts_at: string | null; ends_at: string | null; created_at: string;
  media_url: string | null; media_type: string | null;
  button_text: string | null; link_url: string | null; tag: string | null;
  rejection_reason: string | null; impressions: number; clicks: number;
  // Filas normalizadas de bid_orders/recommendation_orders/sponsored_groups
  // (mismo patrón que AdApprovalScreen.fetchAds de la app) — _source marca
  // que NO son una fila real de `advertisements`.
  _source?: "bid" | "rec" | "sponsored";
  _groupId?: string;
  budget?: number | null;
}

const isExpiredDate = (iso: string | null) => !!iso && new Date(iso).getTime() < Date.now();

const STATUS_TABS: { key: string; label: string; color: string }[] = [
  { key: "all",            label: "Todos",      color: "#94A3B8" },
  { key: "active",         label: "Activos",    color: "#00E676" },
  { key: "pending_review", label: "Pendientes", color: "#F59E0B" },
  { key: "paused",         label: "Pausados",   color: "#94A3B8" },
  { key: "rejected",       label: "Rechazados", color: "#EF4444" },
  { key: "expired",        label: "Vencidos",   color: "#6B7280" },
];

const TYPE_LABEL: Record<string, string> = {
  banner_home:       "Banner de inicio",
  profile_ad:        "Anuncio de perfil",
  sponsored_group:   "Grupo destacado",
  bid_order:         "Puja de posicionamiento",
  recommendation_ad: "Recomendado",
};

function isExpired(ad: Ad) {
  return !!ad.ends_at && new Date(ad.ends_at).getTime() < Date.now();
}

function AdThumb({ ad }: { ad: Ad }) {
  if (!ad.media_url) {
    return <div className="flex h-14 w-14 shrink-0 items-center justify-center rounded-lg bg-brand-card2 text-lg">📢</div>;
  }
  return (
    <div className="relative h-14 w-14 shrink-0 overflow-hidden rounded-lg bg-brand-card2">
      {ad.media_type === "video" ? (
        <video src={ad.media_url} muted loop autoPlay playsInline className="h-full w-full object-cover" />
      ) : (
        <Image src={ad.media_url} alt="" fill className="object-cover" unoptimized />
      )}
    </div>
  );
}

export default function AdsManager({ scopeCountry }: { scopeCountry?: string }) {
  const [ads, setAds]         = useState<Ad[]>([]);
  const [loading, setLoading] = useState(true);
  const [tab, setTab]         = useState("all");
  const [busyId, setBusyId]   = useState<string | null>(null);
  const [editingAd, setEditingAd] = useState<Ad | null>(null);
  // 2026-09-18 — petición real: "quiero poder seleccionar varios para
  // borrarlos por si tengo muchos". Borra uno por uno con delete_ad (ya
  // trae su propio guard de país para admin_ops) — sin RPC nueva.
  const [selectMode, setSelectMode] = useState(false);
  const [selectedIds, setSelectedIds] = useState<Set<string>>(new Set());
  const [bulkDeleting, setBulkDeleting] = useState(false);
  // "⭐ Destacar grupo" — Destacado/Recomendado/Puja (admin_activate_*),
  // solo para admin completo (las RPC exigen role='admin' del servidor).
  const [promoModal, setPromoModal] = useState(false);

  const load = useCallback(async () => {
    const [adsRes, bidsRes, recRes, sponRes] = await Promise.all([
      supabase.from("advertisements").select("id, type, title, subtitle, status, is_free, total_price, target_country, target_state, starts_at, ends_at, created_at, media_url, media_type, button_text, link_url, tag, rejection_reason, impressions, clicks").order("created_at", { ascending: false }).limit(200),
      supabase.from("bid_orders").select("id, group_id, amount, duration_days, status, starts_at, ends_at, created_at, group:groups(name)").order("created_at", { ascending: false }).limit(100),
      supabase.from("recommendation_orders").select("id, group_id, amount, duration_days, status, starts_at, ends_at, created_at, group:groups(name)").order("created_at", { ascending: false }).limit(100),
      supabase.from("sponsored_groups").select("id, group_id, starts_at, ends_at, is_active, created_at, group:groups(name)").order("created_at", { ascending: false }).limit(100),
    ]);
    if (adsRes.error) console.error("[AdsManager] ads", adsRes.error.message);

    const now = Date.now();
    const bids: Ad[] = ((bidsRes.data as any[]) ?? []).map((b) => {
      const expired = b.ends_at && new Date(b.ends_at).getTime() <= now;
      const status = b.status === "paid" && !expired ? "active" : b.status === "paid" && expired ? "expired" : b.status === "expired" ? "expired" : "pending_review";
      return { id: b.id, type: "bid_order", title: b.group?.name ?? "Grupo", subtitle: `Posicionamiento · ${b.duration_days ?? 1}d`, status, is_free: false, budget: b.amount, total_price: null, target_country: null, target_state: null, starts_at: b.starts_at, ends_at: b.ends_at, created_at: b.created_at, media_url: null, media_type: null, button_text: null, link_url: null, tag: null, rejection_reason: null, impressions: 0, clicks: 0, _source: "bid", _groupId: b.group_id };
    });
    const recs: Ad[] = ((recRes.data as any[]) ?? []).map((r) => {
      const expired = r.ends_at && new Date(r.ends_at).getTime() <= now;
      const status = r.status === "paid" && !expired ? "active" : r.status === "paid" && expired ? "expired" : r.status === "expired" ? "expired" : r.status === "cancelled" ? "rejected" : "pending_review";
      return { id: r.id, type: "recommendation_ad", title: r.group?.name ?? "Grupo", subtitle: `Recomendado · ${r.duration_days ?? 1}d`, status, is_free: false, budget: r.amount, total_price: null, target_country: null, target_state: null, starts_at: r.starts_at, ends_at: r.ends_at, created_at: r.created_at, media_url: null, media_type: null, button_text: null, link_url: null, tag: null, rejection_reason: null, impressions: 0, clicks: 0, _source: "rec", _groupId: r.group_id };
    });
    // Un sponsored_group ya cubierto por una fila real de advertisements
    // (type='sponsored_group' con link_id) no se duplica — mismo criterio
    // que la app.
    const coveredByAd = new Set(((adsRes.data as any[]) ?? []).filter((a) => a.type === "sponsored_group" && (a as any).link_id).map((a) => (a as any).link_id as string));
    const spons: Ad[] = ((sponRes.data as any[]) ?? []).filter((s) => !coveredByAd.has(s.group_id)).map((s) => {
      const expired = s.ends_at && new Date(s.ends_at).getTime() <= now;
      const status = s.is_active && !expired ? "active" : "expired";
      return { id: s.id, type: "sponsored_group", title: s.group?.name ?? "Grupo", subtitle: "Grupo destacado (directo)", status, is_free: false, budget: null, total_price: null, target_country: null, target_state: null, starts_at: s.starts_at, ends_at: s.ends_at, created_at: s.created_at, media_url: null, media_type: null, button_text: null, link_url: null, tag: null, rejection_reason: null, impressions: 0, clicks: 0, _source: "sponsored", _groupId: s.group_id };
    });

    const all = [...((adsRes.data as Ad[]) ?? []), ...bids, ...recs, ...spons]
      .sort((a, b) => new Date(b.created_at).getTime() - new Date(a.created_at).getTime());
    setAds(all);
    setLoading(false);
  }, []);
  useEffect(() => { load(); }, [load]);

  // Con scopeCountry (admin_ops): la política RLS ya solo trae los de su
  // país + internacionales — aquí nomás se distingue visualmente cuáles
  // son "de otro" (internacionales, sql/667) para que sepa que no los
  // puede editar/borrar, evitando el "choque" entre admins.
  const isMine = useCallback((ad: Ad) => {
    if (!scopeCountry) return true;
    return !!ad.target_country && ad.target_country.toLowerCase() === scopeCountry.toLowerCase();
  }, [scopeCountry]);

  const filtered = useMemo(() => {
    let list = tab === "all" ? ads
      : tab === "expired" ? ads.filter((a) => isExpired(a) && a.status !== "rejected")
      : ads.filter((a) => a.status === tab && !isExpired(a));
    return list;
  }, [ads, tab]);

  const countFor = (key: string) =>
    key === "all" ? ads.length
    : key === "expired" ? ads.filter((a) => isExpired(a) && a.status !== "rejected").length
    : ads.filter((a) => a.status === key && !isExpired(a)).length;

  const approve = async (id: string) => {
    setBusyId(id);
    const { data, error } = await supabase.rpc("approve_ad", { p_id: id });
    setBusyId(null);
    if (error || (data as any)?.ok === false) { window.alert((data as any)?.error ?? error?.message ?? "No se pudo aprobar."); return; }
    load();
  };
  const reject = async (id: string) => {
    const reason = window.prompt("Motivo de rechazo (opcional)");
    if (reason === null) return; // canceló el prompt
    setBusyId(id);
    const { error } = await supabase.rpc("reject_ad", { p_id: id, p_reason: reason.trim() || null });
    setBusyId(null);
    if (error) { window.alert(error.message); return; }
    load();
  };
  const toggle = async (id: string) => {
    setBusyId(id);
    const { data, error } = await supabase.rpc("toggle_ad", { p_id: id });
    setBusyId(null);
    if (error || (data as any)?.ok === false) { window.alert((data as any)?.error ?? error?.message ?? "No se pudo cambiar."); return; }
    load();
  };
  const remove = async (id: string, title: string) => {
    if (!window.confirm(`¿Borrar "${title}"? No se puede deshacer.`)) return;
    setBusyId(id);
    const { data, error } = await supabase.rpc("delete_ad", { p_id: id });
    setBusyId(null);
    if (error || (data as any)?.ok === false) { window.alert((data as any)?.error ?? error?.message ?? "No se pudo borrar."); return; }
    load();
  };

  const deactivatePromo = async (ad: Ad) => {
    if (!ad._source || !ad._groupId) return;
    if (!window.confirm(`¿Desactivar "${TYPE_LABEL[ad.type]}" para ${ad.title}?`)) return;
    setBusyId(ad.id);
    const p_type = ad._source === "sponsored" ? "sponsored" : ad._source === "rec" ? "recommendation" : "bidding";
    const { data, error } = await supabase.rpc("admin_deactivate_group", { p_group_id: ad._groupId, p_type });
    setBusyId(null);
    if (error || (data as any)?.ok === false) { window.alert((data as any)?.error ?? error?.message ?? "No se pudo desactivar."); return; }
    load();
  };

  const toggleSelected = (id: string) => {
    setSelectedIds((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id); else next.add(id);
      return next;
    });
  };
  const cancelSelectMode = () => { setSelectMode(false); setSelectedIds(new Set()); };
  const bulkDelete = async () => {
    if (selectedIds.size === 0) return;
    if (!window.confirm(`¿Borrar ${selectedIds.size} anuncio${selectedIds.size !== 1 ? "s" : ""}? No se puede deshacer.`)) return;
    setBulkDeleting(true);
    const ids = Array.from(selectedIds);
    const results = await Promise.all(ids.map((id) => supabase.rpc("delete_ad", { p_id: id })));
    setBulkDeleting(false);
    const failed = results.filter((r) => r.error || (r.data as any)?.ok === false).length;
    if (failed > 0) window.alert(`${ids.length - failed} de ${ids.length} borrados — ${failed} no se pudieron borrar.`);
    cancelSelectMode();
    load();
  };

  if (loading) return <Spinner />;

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div className="flex flex-wrap gap-2">
          {STATUS_TABS.map((t) => {
            const c = countFor(t.key);
            return (
              <button
                key={t.key}
                onClick={() => setTab(t.key)}
                className="flex items-center gap-1.5 rounded-full border px-3 py-1.5 text-xs font-medium"
                style={tab === t.key ? { borderColor: t.color, backgroundColor: `${t.color}22`, color: t.color } : { borderColor: "var(--brand-border, #262626)" }}
              >
                {t.label}
                {c > 0 && <span className="rounded-full px-1.5 text-[10px] font-bold" style={{ backgroundColor: t.color, color: "#000" }}>{c}</span>}
              </button>
            );
          })}
        </div>
        <div className="flex gap-2">
          {selectMode ? (
            <>
              <span className="flex items-center rounded-lg border border-brand-border px-3 py-1.5 text-xs text-brand-muted">
                {selectedIds.size} seleccionado{selectedIds.size !== 1 ? "s" : ""}
              </span>
              <button onClick={bulkDelete} disabled={selectedIds.size === 0 || bulkDeleting} className="rounded-lg border border-red-400 px-3 py-1.5 text-xs font-bold text-red-400 disabled:opacity-40">
                {bulkDeleting ? "…" : "🗑️ Borrar seleccionados"}
              </button>
              <button onClick={cancelSelectMode} className="rounded-lg border border-brand-border px-3 py-1.5 text-xs font-medium text-brand-muted hover:text-white">Cancelar</button>
            </>
          ) : (
            <button onClick={() => setSelectMode(true)} className="rounded-lg border border-brand-border px-3 py-1.5 text-xs font-medium text-brand-muted hover:text-white">☑️ Seleccionar</button>
          )}
          <CreateFreeAdModal onCreated={load} lockedCountry={scopeCountry} />
          {!scopeCountry && (
            <button onClick={() => setPromoModal(true)} className="rounded-xl border border-yellow-400/50 bg-yellow-400/10 px-4 py-2.5 text-sm font-bold text-yellow-400 hover:bg-yellow-400/20">
              ⭐ Destacar grupo
            </button>
          )}
        </div>
      </div>

      {scopeCountry && (
        <p className="text-xs text-brand-muted">
          📍 Mostrando anuncios de <strong className="text-white">{scopeCountry}</strong> + los internacionales (de solo lectura — esos solo los administra Daniel).
        </p>
      )}

      {filtered.length === 0 ? (
        <EmptyBox icon="📢" text="Sin anuncios en esta categoría" />
      ) : (
        <div className="grid gap-3 lg:grid-cols-2">
          {filtered.map((ad) => {
            const mine = isMine(ad);
            const busy = busyId === ad.id;
            return (
              <div key={ad.id} className={`space-y-2 rounded-2xl border p-4 ${selectMode && selectedIds.has(ad.id) ? "border-brand-green bg-brand-green/5" : "border-brand-border bg-brand-card"}`}>
                <div className="flex items-start gap-3">
                  {selectMode && mine && (
                    <input
                      type="checkbox"
                      checked={selectedIds.has(ad.id)}
                      onChange={() => toggleSelected(ad.id)}
                      className="mt-1 h-4 w-4 shrink-0 accent-brand-green"
                    />
                  )}
                  <AdThumb ad={ad} />
                  <div className="min-w-0 flex-1">
                    <div className="mb-1 flex flex-wrap items-center gap-1.5">
                      <span className="rounded-full border border-brand-border px-2 py-0.5 text-[10px] font-medium text-brand-muted">
                        {TYPE_LABEL[ad.type] ?? ad.type}
                      </span>
                      {ad.is_free && <span className="rounded-full bg-blue-400/15 px-2 py-0.5 text-[10px] font-bold text-blue-400">GRATIS</span>}
                      {!mine && !ad._source && <span className="rounded-full bg-purple-400/15 px-2 py-0.5 text-[10px] font-bold text-purple-300">🌐 Internacional</span>}
                      {ad._source && <span className="rounded-full bg-yellow-400/15 px-2 py-0.5 text-[10px] font-bold text-yellow-400">💰 Pagado</span>}
                    </div>
                    <p className="truncate font-semibold text-white">{ad.title}</p>
                    {ad.subtitle && <p className="truncate text-xs text-brand-muted">{ad.subtitle}</p>}
                    {!ad._source && (
                      <p className="mt-0.5 text-[11px] text-brand-muted">
                        📍 {ad.target_country ?? "Internacional"}{ad.target_state ? ` · ${ad.target_state}` : ""}
                      </p>
                    )}
                    {ad.budget != null && (
                      <p className="mt-0.5 text-[11px] text-brand-green">💲 {ad.budget.toLocaleString("es-MX")} MXN</p>
                    )}
                  </div>
                </div>

                {(ad.starts_at || ad.ends_at) && (
                  <p className="text-[11px] text-brand-muted">
                    📅 {ad.starts_at ? new Date(ad.starts_at).toLocaleDateString("es-MX", { day: "2-digit", month: "short" }) : "—"}
                    {" → "}
                    {ad.ends_at ? new Date(ad.ends_at).toLocaleDateString("es-MX", { day: "2-digit", month: "short", year: "2-digit" }) : "∞"}
                  </p>
                )}

                {ad.rejection_reason && (
                  <p className="rounded-lg bg-red-500/10 px-2.5 py-1.5 text-xs text-red-400">❌ {ad.rejection_reason}</p>
                )}

                {(ad.impressions > 0 || ad.clicks > 0) && (
                  <p className="text-[11px] text-brand-muted">👁 {ad.impressions.toLocaleString()} · 🖱 {ad.clicks.toLocaleString()}</p>
                )}

                {ad._source && ad.status === "pending_review" && (
                  <p className="text-[11px] italic text-brand-muted">⚡ Se activa automáticamente al confirmar el pago</p>
                )}

                {ad._source ? (
                  !scopeCountry && ad.status === "active" && (
                    <button onClick={() => deactivatePromo(ad)} disabled={busy} className="rounded-lg border border-red-400 px-3 py-1.5 text-xs font-medium text-red-400 disabled:opacity-50">
                      {busy ? "…" : "Desactivar"}
                    </button>
                  )
                ) : mine ? (
                  <div className="flex flex-wrap gap-2 pt-1">
                    {ad.status === "pending_review" && (
                      <>
                        <button onClick={() => approve(ad.id)} disabled={busy} className="rounded-lg bg-brand-green px-3 py-1.5 text-xs font-bold text-black disabled:opacity-50">
                          {busy ? "…" : "✓ Aprobar"}
                        </button>
                        <button onClick={() => reject(ad.id)} disabled={busy} className="rounded-lg border border-red-400 px-3 py-1.5 text-xs font-medium text-red-400 disabled:opacity-50">
                          ✕ Rechazar
                        </button>
                      </>
                    )}
                    {(ad.status === "active" || ad.status === "paused") && (
                      <button onClick={() => toggle(ad.id)} disabled={busy} className="rounded-lg border border-brand-border px-3 py-1.5 text-xs font-medium text-brand-muted hover:text-white disabled:opacity-50">
                        {busy ? "…" : ad.status === "active" ? "⏸ Pausar" : "▶ Reactivar"}
                      </button>
                    )}
                    {ad.is_free && (
                      <button onClick={() => setEditingAd(ad)} className="rounded-lg border border-brand-border px-3 py-1.5 text-xs font-medium text-brand-muted hover:text-white">
                        ✏️ Editar
                      </button>
                    )}
                    <button onClick={() => remove(ad.id, ad.title)} disabled={busy} className="rounded-lg border border-red-400/40 px-3 py-1.5 text-xs font-medium text-red-400 disabled:opacity-50">
                      🗑️ Borrar
                    </button>
                  </div>
                ) : (
                  <p className="pt-1 text-[11px] italic text-brand-muted">Solo lectura — este anuncio internacional lo administra Daniel.</p>
                )}
              </div>
            );
          })}
        </div>
      )}

      {editingAd && (
        <CreateFreeAdModal
          editingAd={editingAd}
          onClose={() => setEditingAd(null)}
          onCreated={load}
          lockedCountry={scopeCountry}
          hideTrigger
        />
      )}

      {promoModal && (
        <PromoteGroupModal onClose={() => setPromoModal(false)} onDone={load} />
      )}
    </div>
  );
}

// ── "⭐ Destacar grupo" — Destacado/Recomendado/Puja ──────────────────────
// Duraciones preestablecidas — petición real: "no sale si 1 mes o 2 o 3 o
// todo el año si quiero regalarles". 0 = sin límite (equivalente a "todo
// el año" real: admin_activate_sponsored trata p_days<=0 como +100 años;
// admin_activate_recommendation lo trata como ends_at NULL = sin vencer).
const GIFT_DURATIONS = [
  { label: "1 mes", days: 30 },
  { label: "2 meses", days: 60 },
  { label: "3 meses", days: 90 },
  { label: "Todo el año", days: 365 },
];

function PromoteGroupModal({ onClose, onDone }: { onClose: () => void; onDone: () => void }) {
  const [search, setSearch] = useState("");
  const [results, setResults] = useState<{ id: string; name: string; city: string | null }[]>([]);
  const [searching, setSearching] = useState(false);
  const [group, setGroup] = useState<{ id: string; name: string } | null>(null);
  const [type, setType] = useState<"sponsored" | "recommendation" | "bidding">("sponsored");
  const [days, setDays] = useState(30);
  const [bidAmount, setBidAmount] = useState("100");
  const [saving, setSaving] = useState(false);
  // Marca qué tipos ya activaste para ESTE grupo en esta sesión del modal
  // — petición real: "nada más sale el destacado, no sale el recomendado
  // también, para regalar más". Antes el modal se cerraba solo tras
  // activar uno, así que dar Destacado + Recomendado al mismo grupo
  // significaba volver a buscarlo desde cero. Ahora se queda abierto.
  const [activatedTypes, setActivatedTypes] = useState<Set<string>>(new Set());

  useEffect(() => {
    if (!search.trim() || group) { setResults([]); return; }
    setSearching(true);
    const t = setTimeout(async () => {
      const { data } = await supabase.from("groups").select("id, name, city").ilike("name", `%${search.trim()}%`).eq("is_active", true).limit(8);
      setResults((data as any[]) ?? []);
      setSearching(false);
    }, 300);
    return () => clearTimeout(t);
  }, [search, group]);

  const activate = async () => {
    if (!group) return;
    setSaving(true);
    const rpc = type === "sponsored" ? "admin_activate_sponsored" : type === "recommendation" ? "admin_activate_recommendation" : "admin_activate_bidding";
    const params: Record<string, unknown> = { p_group_id: group.id, p_days: days };
    if (type === "bidding") params.p_bid_amount = Number(bidAmount) || 100;
    const { data, error } = await supabase.rpc(rpc, params);
    setSaving(false);
    if (error || (data as any)?.ok === false) { window.alert((data as any)?.error ?? error?.message ?? "No se pudo activar."); return; }
    setActivatedTypes((prev) => new Set(prev).add(type));
    onDone(); // refresca la lista de atrás, pero el modal se queda abierto
  };

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4" onClick={onClose}>
      <div onClick={(e) => e.stopPropagation()} className="max-h-[85vh] w-full max-w-md overflow-y-auto rounded-2xl border border-brand-border bg-brand-card p-6">
        <h3 className="mb-1 text-lg font-bold text-white">⭐ Destacar grupo</h3>
        <p className="mb-4 text-xs text-brand-muted">Cortesía o alianza — sin pasar por Stripe. Ya hablaste con el grupo por teléfono.</p>

        {!group ? (
          <>
            <input
              autoFocus type="text" value={search} onChange={(e) => setSearch(e.target.value)}
              placeholder="Buscar grupo por nombre…"
              className="mb-3 w-full rounded-lg border border-brand-border bg-brand-bg px-3 py-2 text-sm text-white placeholder:text-brand-muted outline-none focus:border-brand-green"
            />
            {searching && <p className="text-xs text-brand-muted">Buscando…</p>}
            <div className="space-y-1.5">
              {results.map((g) => (
                <button key={g.id} onClick={() => setGroup(g)} className="block w-full rounded-lg border border-brand-border px-3 py-2 text-left text-sm text-white hover:border-brand-green">
                  {g.name} {g.city && <span className="text-xs text-brand-muted">· {g.city}</span>}
                </button>
              ))}
            </div>
          </>
        ) : (
          <>
            <div className="mb-4 flex items-center justify-between rounded-lg bg-brand-bg px-3 py-2">
              <p className="text-sm font-semibold text-white">{group.name}</p>
              <button onClick={() => { setGroup(null); setActivatedTypes(new Set()); }} className="text-xs text-brand-muted hover:text-white">Cambiar</button>
            </div>

            {activatedTypes.size > 0 && (
              <p className="mb-3 rounded-lg border border-brand-green/30 bg-brand-green/5 px-3 py-2 text-xs text-brand-green">
                ✓ Ya activaste: {Array.from(activatedTypes).map((t) => t === "sponsored" ? "Destacado" : t === "recommendation" ? "Recomendado" : "Puja").join(", ")} — puedes darle otra promoción más a este mismo grupo.
              </p>
            )}

            <label className="mb-1 block text-xs font-medium text-brand-muted">Tipo de promoción</label>
            <div className="mb-3 flex gap-2">
              {([["sponsored", "⭐ Destacado"], ["recommendation", "🔥 Recomendado"], ["bidding", "⬆️ Puja"]] as const).map(([k, l]) => (
                <button key={k} onClick={() => setType(k)} className={`relative flex-1 rounded-lg border px-2 py-2 text-xs font-medium ${type === k ? "border-brand-green bg-brand-green/10 text-brand-green" : "border-brand-border text-brand-muted"}`}>
                  {l}
                  {activatedTypes.has(k) && <span className="absolute -right-1 -top-1 flex h-4 w-4 items-center justify-center rounded-full bg-brand-green text-[9px] text-black">✓</span>}
                </button>
              ))}
            </div>

            <label className="mb-1 block text-xs font-medium text-brand-muted">Duración — para regalar 1, 2, 3 meses o todo el año</label>
            <div className="mb-3 flex flex-wrap gap-2">
              {GIFT_DURATIONS.map((d) => (
                <button key={d.days} onClick={() => setDays(d.days)} className={`rounded-full border px-3 py-1.5 text-xs font-medium ${days === d.days ? "bg-brand-green text-black border-brand-green" : "border-brand-border text-brand-muted"}`}>
                  {d.label}
                </button>
              ))}
            </div>
            <input type="number" min={1} value={days} onChange={(e) => setDays(Number(e.target.value) || 1)} placeholder="O escribe otro número de días" className="mb-3 w-full rounded-lg border border-brand-border bg-brand-bg px-3 py-2 text-sm text-white placeholder:text-brand-muted" />

            {type === "bidding" && (
              <>
                <label className="mb-1 block text-xs font-medium text-brand-muted">Monto de la puja (MXN)</label>
                <input type="number" min={1} value={bidAmount} onChange={(e) => setBidAmount(e.target.value)} className="mb-3 w-full rounded-lg border border-brand-border bg-brand-bg px-3 py-2 text-sm text-white" />
              </>
            )}

            <div className="flex gap-3">
              <button onClick={onClose} className="flex-1 rounded-lg border border-brand-border py-2.5 text-sm text-brand-muted">
                {activatedTypes.size > 0 ? "Listo, cerrar" : "Cancelar"}
              </button>
              <button onClick={activate} disabled={saving || activatedTypes.has(type)} className="flex-1 rounded-lg bg-brand-green py-2.5 text-sm font-bold text-black disabled:opacity-50">
                {saving ? "…" : activatedTypes.has(type) ? "Ya activo" : "Activar"}
              </button>
            </div>
          </>
        )}
      </div>
    </div>
  );
}
