"use client";

/**
 * TalentsManager — gestión de talentos, paridad con AdminTalentsScreen de
 * la app (petición real 2026-09-18: "déjalo listo todo como lo veo en mi
 * app"). Misma fuente de datos (job_board_profiles UNION profiles
 * role='talent'), mismas RPC (admin_get_user_contact,
 * admin_set_profile_verified) — nada nuevo del lado del servidor.
 */

import { useEffect, useMemo, useState } from "react";
import Image from "next/image";
import { supabase } from "@/lib/supabase";
import { Spinner, EmptyBox, Modal, inputCls, labelCls } from "./ui";

interface Talent {
  id: string; user_id: string; full_name: string; avatar_url: string | null;
  instrument_or_role: string; bio: string | null; experience_years: number | null;
  rating: number; total_jobs: number; group_name: string | null;
  phone: string | null; city: string | null; state: string | null;
  verification_status: string; admin_verified: boolean; created_at: string | null;
}

// Mismo criterio simple que stateToCountry() de la app: EE.UU./Canadá se
// reconocen por estado conocido, todo lo demás cae a México (mercado base).
const US_STATES = new Set(["Texas", "California", "Florida", "Arizona", "Nevada", "Illinois", "New York", "Georgia", "North Carolina"]);
const CA_PROVINCES = new Set(["Ontario", "Quebec", "British Columbia", "Alberta"]);
function stateToCountry(state: string | null): string {
  if (!state) return "México";
  if (US_STATES.has(state.trim())) return "Estados Unidos";
  if (CA_PROVINCES.has(state.trim())) return "Canadá";
  return "México";
}

export default function TalentsManager() {
  const [talents, setTalents]   = useState<Talent[]>([]);
  const [loading, setLoading]   = useState(true);
  const [search, setSearch]     = useState("");
  const [activeCountry, setActiveCountry] = useState<string | null>(null);
  const [activeState, setActiveState]     = useState<string | null>(null);
  const [selected, setSelected] = useState<Talent | null>(null);
  const [ownerEmail, setOwnerEmail] = useState<string | null>(null);
  const [contactLoading, setContactLoading] = useState(false);
  const [note, setNote] = useState("");
  const [actionLoading, setActionLoading] = useState(false);

  const load = async () => {
    setLoading(true);
    const [jbpRes, talentRes] = await Promise.all([
      supabase.from("job_board_profiles").select(`
        id, user_id, instrument_or_role, bio, experience_years, rating, total_jobs, is_visible,
        profile:profiles!job_board_profiles_user_id_fkey(full_name, avatar_url, phone, city, state, role, verification_status, admin_verified, created_at)
      `).order("rating", { ascending: false }),
      supabase.from("profiles").select("id, full_name, avatar_url, phone, city, state, verification_status, admin_verified, created_at").eq("role", "talent").order("full_name"),
    ]);
    const jbps = (jbpRes.data as any[]) ?? [];
    const tProfs = (talentRes.data as any[]) ?? [];
    const allIds = Array.from(new Set([...jbps.map((j) => j.user_id), ...tProfs.map((p) => p.id)]));

    const { data: memberships } = allIds.length > 0
      ? await supabase.from("job_invitations").select("invited_user_id, group:groups(name)").in("invited_user_id", allIds).eq("status", "accepted").is("event_id", null)
      : { data: [] as any[] };
    const memberMap: Record<string, string> = {};
    (memberships ?? []).forEach((m: any) => { memberMap[m.invited_user_id] = m.group?.name ?? "—"; });

    const map = new Map<string, Talent>();
    tProfs.forEach((p) => {
      map.set(p.id, {
        id: p.id, user_id: p.id, full_name: p.full_name ?? "Sin nombre", avatar_url: p.avatar_url ?? null,
        instrument_or_role: "—", bio: null, experience_years: null, rating: 0, total_jobs: 0,
        group_name: memberMap[p.id] ?? null, phone: p.phone ?? null, city: p.city ?? null, state: p.state ?? null,
        verification_status: p.verification_status ?? "none", admin_verified: p.admin_verified ?? false, created_at: p.created_at ?? null,
      });
    });
    // Dueños de grupo (sql/21) reciben un job_board_profile automático y
    // OCULTO (is_visible=false) al registrarse — es una opción para
    // anunciarse también como talento individual, no algo activo por
    // default. Bug real reportado 2026-09-19: "cuando registro un grupo,
    // aparece en talentos" — pasaba porque este filtro no distinguía esa
    // fila automática/oculta de una que el dueño sí activó a propósito.
    jbps.filter((j) => j.profile?.role !== "client" && (j.profile?.role !== "group" || j.is_visible === true)).forEach((j) => {
      map.set(j.user_id, {
        id: j.id, user_id: j.user_id, full_name: j.profile?.full_name ?? "Sin nombre", avatar_url: j.profile?.avatar_url ?? null,
        instrument_or_role: j.instrument_or_role ?? "—", bio: j.bio ?? null, experience_years: j.experience_years ?? null,
        rating: j.rating ?? 0, total_jobs: j.total_jobs ?? 0, group_name: memberMap[j.user_id] ?? null,
        phone: j.profile?.phone ?? null, city: j.profile?.city ?? null, state: j.profile?.state ?? null,
        verification_status: j.profile?.verification_status ?? "none", admin_verified: j.profile?.admin_verified ?? false, created_at: j.profile?.created_at ?? null,
      });
    });
    setTalents(Array.from(map.values()));
    setLoading(false);
  };
  useEffect(() => { load(); }, []);

  const countries = useMemo(() => {
    const c = new Set<string>();
    talents.forEach((t) => c.add(stateToCountry(t.state)));
    return Array.from(c).sort();
  }, [talents]);

  const states = useMemo(() => {
    const base = activeCountry ? talents.filter((t) => stateToCountry(t.state) === activeCountry) : talents;
    const s = new Set<string>();
    base.forEach((t) => { if (t.state?.trim()) s.add(t.state.trim()); });
    return Array.from(s).sort();
  }, [talents, activeCountry]);

  const filtered = useMemo(() => {
    let list = talents;
    if (search.trim()) {
      const q = search.toLowerCase();
      list = list.filter((t) => t.full_name?.toLowerCase().includes(q) || t.instrument_or_role?.toLowerCase().includes(q) || t.state?.toLowerCase().includes(q));
    }
    if (activeCountry) list = list.filter((t) => stateToCountry(t.state) === activeCountry);
    if (activeState) list = list.filter((t) => t.state?.trim().toLowerCase() === activeState.toLowerCase());
    return list;
  }, [talents, search, activeCountry, activeState]);

  const openProfile = async (t: Talent) => {
    setSelected(t); setOwnerEmail(null); setNote(""); setContactLoading(true);
    const { data } = await supabase.rpc("admin_get_user_contact", { p_user_id: t.user_id });
    if ((data as any)?.ok) setOwnerEmail((data as any).email ?? null);
    setContactLoading(false);
  };

  const handleVerify = async (verify: boolean) => {
    if (!selected) return;
    if (!verify && !note.trim()) { window.alert("Escribe una nota — es obligatoria para quitar la verificación."); return; }
    setActionLoading(true);
    const { data, error } = await supabase.rpc("admin_set_profile_verified", { p_user_id: selected.user_id, p_verified: verify, p_note: note.trim() || null });
    setActionLoading(false);
    if (error || !(data as any)?.ok) { window.alert((data as any)?.error ?? error?.message ?? "No se pudo actualizar."); return; }
    const updated = { ...selected, admin_verified: verify, verification_status: verify ? "approved" : "none" };
    setSelected(updated);
    setTalents((prev) => prev.map((t) => (t.user_id === selected.user_id ? { ...t, admin_verified: verify, verification_status: verify ? "approved" : "none" } : t)));
    setNote("");
    window.alert(verify ? `${selected.full_name} verificado.` : "Verificación retirada.");
  };

  if (loading) return <Spinner />;

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <h3 className="text-base font-semibold text-white">Talentos ({talents.length})</h3>
        <input
          type="text" value={search} onChange={(e) => setSearch(e.target.value)}
          placeholder="🔍 Buscar por nombre, instrumento o estado…"
          className="w-full max-w-sm rounded-lg border border-brand-border bg-brand-bg px-3 py-2 text-sm text-white placeholder:text-brand-muted outline-none focus:border-brand-green"
        />
      </div>

      {countries.length > 0 && (
        <div className="flex flex-wrap gap-2">
          {countries.map((c) => (
            <button key={c} onClick={() => { setActiveCountry(activeCountry === c ? null : c); setActiveState(null); }}
              className={`rounded-full px-3 py-1.5 text-xs font-medium ${activeCountry === c ? "bg-brand-green text-black" : "border border-brand-green/40 text-brand-green"}`}>
              {c}
            </button>
          ))}
          {activeCountry && states.map((st) => (
            <button key={st} onClick={() => setActiveState(activeState === st ? null : st)}
              className={`rounded-full px-3 py-1.5 text-xs font-medium ${activeState === st ? "bg-brand-green text-black" : "border border-brand-border text-brand-muted"}`}>
              📍 {st}
            </button>
          ))}
        </div>
      )}

      {filtered.length === 0 ? (
        <EmptyBox icon="🎤" text="Sin talentos que coincidan" />
      ) : (
        <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4">
          {filtered.map((t) => (
            <button key={t.user_id} onClick={() => openProfile(t)} className="flex flex-col items-center gap-1.5 rounded-2xl border border-brand-border bg-brand-card p-4 text-center hover:border-brand-green/40">
              <div className="relative h-14 w-14 overflow-hidden rounded-full bg-brand-card2">
                {t.avatar_url ? <Image src={t.avatar_url} alt={t.full_name} fill className="object-cover" unoptimized />
                  : <div className="flex h-full w-full items-center justify-center text-lg font-bold text-brand-green">{t.full_name.charAt(0).toUpperCase()}</div>}
                {t.admin_verified && <span className="absolute -bottom-0.5 -right-0.5 flex h-4 w-4 items-center justify-center rounded-full bg-blue-500 text-[9px] text-white">✓</span>}
              </div>
              <p className="w-full truncate text-sm font-semibold text-white">{t.full_name}</p>
              <p className="w-full truncate text-xs text-brand-muted">{t.instrument_or_role}</p>
              <div className="flex items-center gap-2 text-[11px] text-brand-muted">
                {t.city && <span>📍 {t.city}</span>}
                {t.rating > 0 && <span className="text-yellow-400">★ {t.rating.toFixed(1)}</span>}
              </div>
            </button>
          ))}
        </div>
      )}

      <Modal open={!!selected} onClose={() => setSelected(null)} title={selected?.full_name ?? ""}>
        {selected && (
          <div className="space-y-4">
            <div className="flex justify-center">
              <div className="relative h-20 w-20 overflow-hidden rounded-full bg-brand-card2">
                {selected.avatar_url ? <Image src={selected.avatar_url} alt="" fill className="object-cover" unoptimized />
                  : <div className="flex h-full w-full items-center justify-center text-2xl font-bold text-brand-green">{selected.full_name.charAt(0).toUpperCase()}</div>}
              </div>
            </div>
            <div className="flex flex-wrap justify-center gap-2">
              <span className={`rounded-full border px-2.5 py-1 text-xs font-medium ${selected.admin_verified ? "border-blue-400/40 bg-blue-400/10 text-blue-400" : "border-brand-border text-brand-muted"}`}>
                {selected.admin_verified ? "✓ Verificado" : "Sin verificar"}
              </span>
              {selected.group_name && <span className="rounded-full border border-brand-green/40 bg-brand-green/10 px-2.5 py-1 text-xs font-medium text-brand-green">En {selected.group_name}</span>}
            </div>

            <div className="space-y-1.5 rounded-xl border border-brand-border bg-brand-bg p-3 text-sm">
              <div className="flex justify-between"><span className="text-brand-muted">Instrumento</span><span className="text-white">{selected.instrument_or_role}</span></div>
              <div className="flex justify-between"><span className="text-brand-muted">Ciudad</span><span className="text-white">{[selected.city, selected.state].filter(Boolean).join(", ") || "—"}</span></div>
              <div className="flex justify-between"><span className="text-brand-muted">Rating</span><span className="text-white">{selected.rating > 0 ? `★ ${selected.rating.toFixed(1)} (${selected.total_jobs} trabajos)` : "Sin trabajos aún"}</span></div>
              {selected.experience_years != null && <div className="flex justify-between"><span className="text-brand-muted">Experiencia</span><span className="text-white">{selected.experience_years} años</span></div>}
              <div className="flex justify-between"><span className="text-brand-muted">Teléfono</span><span className="text-white">{selected.phone ?? "—"}</span></div>
              <div className="flex justify-between"><span className="text-brand-muted">Correo</span><span className="text-white">{contactLoading ? "…" : ownerEmail ?? "—"}</span></div>
              {selected.bio && <p className="pt-1 text-brand-muted">{selected.bio}</p>}
            </div>

            <label className={labelCls}>Nota interna (obligatoria para quitar verificación)</label>
            <textarea className={`${inputCls} mb-1`} rows={2} value={note} onChange={(e) => setNote(e.target.value)} />

            {selected.admin_verified ? (
              <button onClick={() => handleVerify(false)} disabled={actionLoading} className="w-full rounded-lg bg-red-500 py-2.5 text-sm font-bold text-white disabled:opacity-50">
                {actionLoading ? "…" : "Quitar verificación"}
              </button>
            ) : (
              <button onClick={() => handleVerify(true)} disabled={actionLoading} className="w-full rounded-lg bg-brand-green py-2.5 text-sm font-bold text-black disabled:opacity-50">
                {actionLoading ? "…" : "Verificar talento gratis"}
              </button>
            )}
          </div>
        )}
      </Modal>
    </div>
  );
}
