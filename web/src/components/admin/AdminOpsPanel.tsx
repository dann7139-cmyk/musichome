"use client";

/**
 * AdminOpsPanel — Fase 1 del panel de escritorio (ver plan
 * "Panel de escritorio para las 4 cuentas admin"). Traducción a
 * Tailwind/Next.js de AdminOpsHomeScreen.tsx + MediaReviewScreen.tsx +
 * AdminManagedQuotesScreen.tsx + AdminProviderApplicationsScreen.tsx +
 * AdminCrossBorderScreen.tsx de la app móvil — llama exactamente las
 * mismas RPC `admin_*`, nunca queries crudas nuevas, para que la
 * seguridad y las reglas de negocio (candado de dinero
 * admin_can_manage_payouts, aislamiento por país, "en trabajo"
 * admin_claims) vivan en un solo lugar ya probado (sql/602, 44/44 PASS).
 *
 * Fuera de esta fase (backlog explícito, ver plan): pestaña "En vivo"
 * de horas extra, detalle por cliente + PDF de la demanda cruzada.
 * ("Modal de agregar proveedor a mano" y "selector guiado de género por
 * categoría" ya se agregaron el 2026-09-17, petición real del usuario.)
 */

import { useCallback, useEffect, useState } from "react";
import { supabase, type Profile } from "@/lib/supabase";
import { useAdminClaims } from "@/hooks/useAdminClaims";
import { Spinner, EmptyBox, ActionBtn, ClaimBadge, Row, Section, Modal, inputCls, labelCls } from "./ui";
import { CATEGORY_LABELS } from "@/lib/genreCategories";
import AdsManager from "./AdsManager";

// Mismos 3 países que la app (ProviderApplyScreen / AdminProviderApplicationsScreen).
const APPLY_COUNTRIES = ["México", "Estados Unidos", "Canadá"];

// admin_country_scope ('MX'/'US'/'CA') → nombre de país tal cual se guarda
// en target_country de advertisements (mismo mapeo que la app usa para
// provider_applications) — sql/667 fuerza este mismo país del lado del
// servidor, esto solo alinea lo que se ve en pantalla.
const SCOPE_TO_COUNTRY: Record<string, string> = { MX: "México", US: "Estados Unidos", CA: "Canadá" };

type OpsTab =
  | "resumen" | "noshows" | "pagos" | "verificacion" | "eventos" | "historial"
  | "fotos" | "cotizaciones" | "solicitudes" | "visa" | "anuncios";

const money = (n: number | null | undefined, currency = "MXN") =>
  `$${Number(n ?? 0).toLocaleString("es-MX", { minimumFractionDigits: 2 })} ${currency}`;

export default function AdminOpsPanel({ profile }: { profile: Profile }) {
  // El admin completo SIEMPRE puede manejar dinero, sin importar la
  // bandera — sql/660 solo puso admin_can_manage_payouts=true en las
  // cuentas admin_ops, nunca en profiles.role='admin' (se quedó en el
  // default false). Mirar solo la bandera aquí escondía Pagos/Resumen/
  // Verificación/Eventos/Historial incluso al admin completo — mismo bug
  // que ya estaba resuelto correctamente del lado del servidor (las RPC
  // de dinero exentan a role='admin' siempre) pero no aquí en la UI.
  const canManagePayouts = profile.role === "admin" || profile.admin_can_manage_payouts !== false;

  const ALL_TABS: { key: OpsTab; label: string; moneyGated?: boolean }[] = [
    { key: "resumen",      label: "📊 Resumen",      moneyGated: true },
    { key: "noshows",      label: "🚨 No-shows" },
    { key: "pagos",        label: "💵 Pagos",         moneyGated: true },
    { key: "verificacion", label: "🪪 Verificación",  moneyGated: true },
    { key: "eventos",      label: "🔒 Eventos",       moneyGated: true },
    { key: "historial",    label: "🧾 Historial",     moneyGated: true },
    { key: "fotos",        label: "📸 Fotos" },
    { key: "cotizaciones", label: "📞 Cotizaciones" },
    { key: "solicitudes",  label: "📝 Solicitudes" },
    { key: "visa",         label: "✈️ Visa",          moneyGated: true },
    // sql/667 (2026-09-18) — anuncios gratis, acotados al propio país del
    // admin_ops (nunca dinero: los anuncios pagados/Stripe siguen fuera
    // de esta pieza, ver comentario en AdsManager.tsx).
    { key: "anuncios",     label: "📢 Anuncios" },
  ];
  const TABS = ALL_TABS.filter((t) => canManagePayouts || !t.moneyGated);
  const scopeCountry = profile.role === "admin_ops"
    ? SCOPE_TO_COUNTRY[profile.admin_country_scope ?? ""]
    : undefined;
  const [tab, setTab] = useState<OpsTab>(canManagePayouts ? "resumen" : "noshows");

  // Contador de pendientes por pestaña (petición real: "que no se nos pase
  // ningún pendiente") — se recalcula cada vez que cambias de pestaña, así
  // siempre refleja lo que acaba de pasar en la que dejaste.
  const [counts, setCounts] = useState<Partial<Record<OpsTab, number>>>({});
  useEffect(() => {
    let alive = true;
    const load = async () => {
      const [ns, gp, gg, wd, gv, pv, se, ss, media, cq, pa] = await Promise.all([
        supabase.rpc("admin_get_no_shows", { p_limit: 50 }),
        canManagePayouts ? supabase.rpc("admin_get_pending_group_payments", { p_limit: 50 }) : Promise.resolve({ data: null }),
        canManagePayouts ? supabase.rpc("admin_get_pending_gift_payouts") : Promise.resolve({ data: null }),
        canManagePayouts ? supabase.rpc("admin_withdrawals_queue", { p_limit: 60 }) : Promise.resolve({ data: null }),
        canManagePayouts ? supabase.rpc("admin_get_pending_group_verifications", { p_limit: 50 }) : Promise.resolve({ data: null }),
        canManagePayouts ? supabase.rpc("admin_get_pending_profile_verifications", { p_limit: 50 }) : Promise.resolve({ data: null }),
        canManagePayouts ? supabase.rpc("admin_get_stuck_events", { p_limit: 50 }) : Promise.resolve({ data: null }),
        canManagePayouts ? supabase.rpc("admin_get_stuck_service_events", { p_limit: 50 }) : Promise.resolve({ data: null }),
        supabase.rpc("admin_get_pending_media", { p_limit: 50 }),
        supabase.rpc("admin_get_concierge_quotes", { p_limit: 100 }),
        supabase.rpc("admin_get_provider_applications", { p_status: "pending" }),
      ]);
      if (!alive) return;
      const mediaData = (media.data as any) ?? {};
      const mediaCount = (mediaData.groups ?? []).reduce((acc: number, g: any) =>
        acc + (g.photo_status === "pending" ? 1 : 0) + (g.video_status === "pending" ? 1 : 0), 0)
        + (mediaData.event_posts ?? []).length + (mediaData.videos ?? []).length;
      const withdrawalsPending = Array.isArray(wd.data) ? wd.data.filter((w: any) => w.status === "pending" || w.status === "processing").length : 0;

      setCounts({
        noshows: (ns.data as any)?.items?.length ?? 0,
        pagos: ((gp.data as any)?.items?.length ?? 0) + ((gg.data as any)?.items?.length ?? 0) + withdrawalsPending,
        verificacion: ((gv.data as any)?.items?.length ?? 0) + ((pv.data as any)?.items?.length ?? 0),
        eventos: ((se.data as any)?.items?.length ?? 0) + ((ss.data as any)?.items?.length ?? 0),
        fotos: mediaCount,
        cotizaciones: (cq.data as any)?.items?.length ?? 0,
        solicitudes: (pa.data as any)?.items?.length ?? 0,
      });
    };
    load();
    return () => { alive = false; };
  }, [tab, canManagePayouts]);

  return (
    <div className="space-y-5">
      <div className="flex flex-wrap gap-1 rounded-xl border border-brand-border bg-brand-card p-1">
        {TABS.map((t) => {
          const n = counts[t.key] ?? 0;
          return (
            <button
              key={t.key}
              onClick={() => setTab(t.key)}
              className={`flex items-center gap-1.5 rounded-lg px-4 py-2.5 text-sm font-medium transition-all ${
                tab === t.key ? "bg-brand-green text-black" : "text-brand-muted hover:text-white"
              }`}
            >
              {t.label}
              {n > 0 && (
                <span className={`rounded-full px-1.5 py-0.5 text-[10px] font-bold ${
                  tab === t.key ? "bg-black/20 text-black" : "bg-yellow-400/20 text-yellow-400"
                }`}>
                  {n}
                </span>
              )}
            </button>
          );
        })}
      </div>

      {tab === "resumen" && canManagePayouts && <ResumenSection />}
      {tab === "noshows" && <NoShowsSection />}
      {tab === "pagos" && canManagePayouts && <PagosSection />}
      {tab === "verificacion" && canManagePayouts && <VerificacionSection />}
      {tab === "eventos" && canManagePayouts && <EventosSection />}
      {tab === "historial" && canManagePayouts && <HistorialSection />}
      {tab === "fotos" && <FotosSection />}
      {tab === "cotizaciones" && <CotizacionesSection />}
      {tab === "solicitudes" && <SolicitudesSection />}
      {tab === "visa" && canManagePayouts && <VisaSection />}
      {tab === "anuncios" && <AdsManager scopeCountry={scopeCountry} />}
    </div>
  );
}

// ─────────────────────────────────────────────────────────────────────────
// RESUMEN
// ─────────────────────────────────────────────────────────────────────────
function ResumenSection() {
  const [data, setData] = useState<any>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    supabase.rpc("admin_ops_country_summary").then(({ data: res }) => {
      if ((res as any)?.ok) setData(res);
      setLoading(false);
    });
  }, []);

  if (loading) return <Spinner />;
  const currency = data?.country === "US" ? "USD" : "MXN";

  return (
    <div className="max-w-md rounded-2xl border border-brand-border bg-brand-card p-5">
      <h3 className="mb-3 text-sm font-semibold text-brand-muted">
        Ingresos de {data?.country === "US" ? "Estados Unidos" : data?.country ?? "—"} (histórico)
      </h3>
      <div className="space-y-1">
        <Row label="Total cobrado a clientes" value={money(data?.total_cobrado, currency)} />
        <Row label="Pagado/por pagar a proveedores" value={money(data?.dinero_grupos, currency)} />
        <Row label="Comisión de Daricefy" value={money(data?.comision_daricefy, currency)} highlight />
      </div>
      <p className="mt-3 text-xs text-brand-muted">{data?.eventos_cobrados ?? 0} eventos cobrados en total</p>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────────────────
// NO-SHOWS
// ─────────────────────────────────────────────────────────────────────────
function NoShowsSection() {
  const [items, setItems] = useState<any[]>([]);
  const [loading, setLoading] = useState(true);
  const [busyId, setBusyId] = useState<string | null>(null);
  const { claims, claim, release, busyId: claimBusyId } = useAdminClaims("no_show", items.map((i) => i.id));

  const load = useCallback(async () => {
    const { data } = await supabase.rpc("admin_get_no_shows", { p_limit: 50 });
    if ((data as any)?.ok) setItems((data as any).items ?? []);
    setLoading(false);
  }, []);
  useEffect(() => { load(); }, [load]);

  const resolve = async (id: string, resolution: string) => {
    setBusyId(id);
    const { data, error } = await supabase.rpc("admin_resolve_no_show", { p_reservation_id: id, p_resolution: resolution });
    setBusyId(null);
    if (error || (data as any)?.ok === false) { window.alert((data as any)?.error ?? error?.message ?? "No se pudo resolver"); return; }
    await release(id);
    load();
  };

  if (loading) return <Spinner />;
  if (items.length === 0) return <EmptyBox icon="✅" text="Sin no-shows pendientes" />;

  return (
    <div className="grid gap-3 lg:grid-cols-2">
      {items.map((it) => {
        const c = claims[it.id];
        const locked = !!c && !c.is_mine;
        return (
          <div key={it.id} className="space-y-2 rounded-2xl border border-brand-border bg-brand-card p-4">
            <div className="flex items-center justify-between">
              <p className="font-semibold text-white">{it.group_name ?? "Grupo"}</p>
              <p className="font-bold text-brand-green">{money(it.total_price, it.currency)}</p>
            </div>
            <p className="text-xs text-brand-muted">{it.event_date} {it.event_time ?? ""} · {it.city ?? it.state ?? it.country}</p>
            {it.client_name && <p className="text-xs text-brand-muted">Cliente: {it.client_name}</p>}
            {it.has_strike && <p className="text-xs text-orange-400">⚠️ Ya tiene strike por no-show</p>}
            <div className="flex flex-wrap gap-2">
              {it.group_phone && <a href={`tel:${it.group_phone}`} className="rounded-lg border border-brand-green bg-brand-green/10 px-2.5 py-1 text-xs text-brand-green">📞 Grupo: {it.group_phone}</a>}
              {it.client_phone && <a href={`tel:${it.client_phone}`} className="rounded-lg border border-brand-border bg-brand-card2 px-2.5 py-1 text-xs text-brand-muted">📞 Cliente: {it.client_phone}</a>}
            </div>
            <ClaimBadge claim={c} busy={claimBusyId === it.id} onClaim={() => claim(it.id)} onRelease={() => release(it.id)} />
            <div className="flex flex-wrap gap-2 pt-1">
              <ActionBtn label="Reembolsar 100%" color="green" disabled={locked} busy={busyId === it.id} onClick={() => resolve(it.id, "refunded_100")} />
              <ActionBtn label="Sin reembolso" color="orange" disabled={locked} busy={busyId === it.id} onClick={() => resolve(it.id, "no_refund")} />
              <ActionBtn label="Solo revisar" color="muted" disabled={locked} busy={busyId === it.id} onClick={() => resolve(it.id, "reviewed")} />
            </div>
          </div>
        );
      })}
    </div>
  );
}

// ─────────────────────────────────────────────────────────────────────────
// PAGOS
// ─────────────────────────────────────────────────────────────────────────
type PayKind = "advance" | "final_settlement" | "gift" | "withdrawal";
interface PayModal { kind: PayKind; id: string; groupId?: string; title: string; amount: number; currency: string; maxAmount?: number }

function PagosSection() {
  const [groupPayments, setGroupPayments] = useState<any[]>([]);
  const [upcomingPayments, setUpcomingPayments] = useState<any[]>([]);
  const [giftPayouts, setGiftPayouts] = useState<any[]>([]);
  const [withdrawals, setWithdrawals] = useState<any[]>([]);
  const [loading, setLoading] = useState(true);
  const [modal, setModal] = useState<PayModal | null>(null);
  const [advanceAmount, setAdvanceAmount] = useState("");
  const [reference, setReference] = useState("");
  const [file, setFile] = useState<File | null>(null);
  const [saving, setSaving] = useState(false);

  const load = useCallback(async () => {
    const [gp, up, gg, wd] = await Promise.all([
      supabase.rpc("admin_get_pending_group_payments", { p_limit: 50 }),
      supabase.rpc("admin_get_upcoming_group_payments", { p_limit: 50 }),
      supabase.rpc("admin_get_pending_gift_payouts"),
      supabase.rpc("admin_withdrawals_queue", { p_limit: 60 }),
    ]);
    if ((gp.data as any)?.ok) setGroupPayments((gp.data as any).items ?? []);
    if ((up.data as any)?.ok) setUpcomingPayments((up.data as any).items ?? []);
    if ((gg.data as any)?.ok) setGiftPayouts((gg.data as any).items ?? []);
    if (!wd.error && Array.isArray(wd.data)) {
      setWithdrawals((wd.data as any[]).filter((w) => w.status === "pending" || w.status === "processing"));
    }
    setLoading(false);
  }, []);
  useEffect(() => { load(); }, [load]);

  const closeModal = () => { setModal(null); setReference(""); setFile(null); setAdvanceAmount(""); };

  const confirm = async () => {
    if (!modal) return;
    const amount = modal.kind === "advance" ? parseFloat(advanceAmount) : modal.amount;
    if (modal.kind === "advance" && (!advanceAmount || isNaN(amount) || amount <= 0)) {
      window.alert("Escribe un monto de anticipo válido."); return;
    }
    if (!file) { window.alert("Sube el comprobante de la transferencia."); return; }
    if (!reference.trim()) { window.alert("Escribe la referencia de la transferencia."); return; }
    setSaving(true);
    try {
      const folder = modal.groupId ?? modal.id;
      const ext = file.name.split(".").pop() || "jpg";
      const receiptPath = `${folder}/${modal.kind}_${modal.id}_${Date.now()}.${ext}`;
      const { error: upErr } = await supabase.storage
        .from("refund-receipts")
        .upload(receiptPath, file, { contentType: file.type || "image/jpeg", upsert: true });
      if (upErr) throw new Error("No se pudo subir el comprobante: " + upErr.message);

      const nowIso = new Date().toISOString();
      let res: any;
      if (modal.kind === "advance") {
        res = await supabase.rpc("admin_register_group_payment", {
          p_reservation_id: modal.id, p_amount: amount, p_kind: "advance",
          p_receipt_path: receiptPath, p_note: null, p_transfer_reference: reference.trim(), p_transferred_at: nowIso,
        });
      } else if (modal.kind === "final_settlement") {
        res = await supabase.rpc("admin_register_group_payment", {
          p_reservation_id: modal.id, p_amount: modal.amount, p_kind: "final_settlement",
          p_receipt_path: receiptPath, p_note: null, p_transfer_reference: reference.trim(), p_transferred_at: nowIso,
        });
      } else if (modal.kind === "gift") {
        res = await supabase.rpc("admin_register_gift_payout", {
          p_group_id: modal.id, p_amount: modal.amount, p_currency_code: modal.currency,
          p_receipt_path: receiptPath, p_transfer_reference: reference.trim(), p_transferred_at: nowIso,
        });
      } else {
        res = await supabase.rpc("admin_complete_payout", {
          p_payout_id: modal.id, p_transfer_reference: reference.trim(), p_receipt_path: receiptPath,
        });
      }
      if (res.error || res.data?.ok === false) throw new Error(res.data?.error ?? res.error?.message ?? "No se pudo registrar el pago");
      window.alert("Pago registrado y notificado al grupo.");
      closeModal();
      load();
    } catch (e: any) {
      window.alert(e?.message ?? "No se pudo registrar el pago");
    } finally {
      setSaving(false);
    }
  };

  if (loading) return <Spinner />;

  return (
    <div className="space-y-6">
      <Section title="Próximos eventos pagados (dar anticipo)" count={upcomingPayments.length}>
        <p className="mb-3 text-xs text-brand-muted">
          Ya cobraste el evento pero todavía no sucede. Da un anticipo al proveedor
          (grupo o cualquier otra categoría) si quieres asegurar que sí va a presentarse.
        </p>
        {upcomingPayments.length === 0 && <EmptyBox icon="💵" text="Sin eventos pagados pendientes por venir" />}
        <div className="grid gap-3 lg:grid-cols-2">
          {upcomingPayments.map((it) => (
            <div key={it.reservation_id} className="space-y-2 rounded-2xl border border-brand-border bg-brand-card p-4">
              <div className="flex items-center justify-between">
                <p className="font-semibold text-white">{it.group_name}{it.group_genre ? ` · ${it.group_genre}` : ""}</p>
                <p className="font-bold text-brand-green">{money(it.saldo_pendiente, it.currency_code)}</p>
              </div>
              <p className="text-xs text-brand-muted">{it.event_date} · {it.client_name ?? "—"}</p>
              <p className="text-xs text-brand-muted">Ganancia del proveedor: {money(it.group_earnings, it.currency_code)} · Ya anticipado: {money(it.total_anticipado, it.currency_code)}</p>
              <ActionBtn label="💵 Registrar anticipo" color="green" onClick={() => setModal({
                kind: "advance", id: it.reservation_id, groupId: it.group_id,
                title: `Anticipo a ${it.group_name}`, amount: 0, currency: it.currency_code, maxAmount: it.saldo_pendiente,
              })} />
            </div>
          ))}
        </div>
      </Section>

      <Section title="Pagos de eventos" count={groupPayments.length}>
        {groupPayments.length === 0 && <EmptyBox icon="💵" text="Sin pagos pendientes" />}
        <div className="grid gap-3 lg:grid-cols-2">
          {groupPayments.map((it) => (
            <div key={it.reservation_id} className="space-y-2 rounded-2xl border border-brand-border bg-brand-card p-4">
              <div className="flex items-center justify-between">
                <p className="font-semibold text-white">{it.group_name}</p>
                <p className="font-bold text-brand-green">{money(it.saldo_pendiente, it.currency_code)}</p>
              </div>
              <p className="text-xs text-brand-muted">{it.event_date} · {it.client_name ?? "—"}</p>
              {!it.bank_clabe && <p className="text-xs text-orange-400">⚠️ Sin datos bancarios registrados</p>}
              <ActionBtn label="Registrar pago" color="green" disabled={!it.bank_clabe} onClick={() => setModal({
                kind: "final_settlement", id: it.reservation_id, groupId: it.group_id,
                title: `Pago a ${it.group_name}`, amount: it.saldo_pendiente, currency: it.currency_code,
              })} />
            </div>
          ))}
        </div>
      </Section>

      <Section title="Propinas/regalos acumulados" count={giftPayouts.length}>
        {giftPayouts.length === 0 && <EmptyBox icon="🎁" text="Sin solicitudes pendientes" />}
        <div className="grid gap-3 lg:grid-cols-2">
          {giftPayouts.map((it) => (
            <div key={it.request_id} className="space-y-2 rounded-2xl border border-brand-border bg-brand-card p-4">
              <div className="flex items-center justify-between">
                <p className="font-semibold text-white">{it.group_name}</p>
                <p className="font-bold text-brand-green">{money(it.amount, it.currency)}</p>
              </div>
              {!it.bank_clabe && <p className="text-xs text-orange-400">⚠️ Sin datos bancarios registrados</p>}
              <ActionBtn label="Registrar pago" color="green" disabled={!it.bank_clabe} onClick={() => setModal({
                kind: "gift", id: it.group_id, title: `Propinas a ${it.group_name}`, amount: it.amount, currency: it.currency,
              })} />
            </div>
          ))}
        </div>
      </Section>

      <Section title="Retiros" count={withdrawals.length}>
        {withdrawals.length === 0 && <EmptyBox icon="🏦" text="Sin retiros pendientes" />}
        <div className="grid gap-3 lg:grid-cols-2">
          {withdrawals.map((it) => (
            <div key={it.id} className="space-y-2 rounded-2xl border border-brand-border bg-brand-card p-4">
              <div className="flex items-center justify-between">
                <p className="font-semibold text-white">{it.owner_name ?? it.group_name ?? "Usuario"}</p>
                <p className="font-bold text-brand-green">{money(it.amount, it.currency)}</p>
              </div>
              <p className="text-xs text-brand-muted">{it.expected_method === "stripe_ach" ? "ACH (Stripe)" : "SPEI"} · {it.status}</p>
              {it.owner_phone && <a href={`tel:${it.owner_phone}`} className="block text-xs text-brand-green">📞 {it.owner_phone}</a>}
              {it.bank_clabe ? (
                <div className="rounded-lg bg-brand-bg p-3 text-xs">
                  <p className="text-brand-muted">Banco: <span className="font-medium text-white">{it.bank_name ?? "—"}</span></p>
                  <p className="text-brand-muted">Titular: <span className="font-medium text-white">{it.account_holder ?? "—"}</span></p>
                  <p className="text-brand-muted">CLABE: <span className="font-mono font-medium text-white">{it.bank_clabe}</span></p>
                </div>
              ) : (
                <p className="text-xs text-orange-400">⚠️ Sin datos bancarios registrados</p>
              )}
              <ActionBtn label="Marcar transferido" color="green" disabled={!it.bank_clabe} onClick={() => setModal({
                kind: "withdrawal", id: it.id, title: `Retiro de ${it.owner_name ?? ""}`, amount: it.amount, currency: it.currency,
              })} />
            </div>
          ))}
        </div>
      </Section>

      <Modal open={!!modal} onClose={closeModal} title={modal?.title ?? ""}>
        {modal?.kind === "advance" ? (
          <>
            <label className={labelCls}>Monto del anticipo (máx. {money(modal.maxAmount, modal.currency)})</label>
            <input
              type="number" className={`${inputCls} mb-4`} value={advanceAmount}
              onChange={(e) => setAdvanceAmount(e.target.value)}
              placeholder="Ej. 2000" min={0} max={modal.maxAmount}
            />
          </>
        ) : (
          <p className="mb-4 text-2xl font-extrabold text-brand-green">{money(modal?.amount, modal?.currency)}</p>
        )}
        <label className={labelCls}>Comprobante de transferencia</label>
        <input type="file" accept="image/*,.pdf" onChange={(e) => setFile(e.target.files?.[0] ?? null)} className="mb-4 block w-full text-sm text-brand-muted" />
        <label className={labelCls}>Referencia de la transferencia</label>
        <input className={`${inputCls} mb-4`} value={reference} onChange={(e) => setReference(e.target.value)} placeholder="Ej. SPEI123456" />
        <div className="flex gap-3">
          <button onClick={closeModal} className="flex-1 rounded-lg border border-brand-border py-2.5 text-sm text-brand-muted">Cancelar</button>
          <button onClick={confirm} disabled={saving} className="flex-1 rounded-lg bg-brand-green py-2.5 text-sm font-bold text-black disabled:opacity-50">
            {saving ? "…" : "Confirmar pago"}
          </button>
        </div>
      </Modal>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────────────────
// VERIFICACIÓN
// ─────────────────────────────────────────────────────────────────────────
function VerificacionSection() {
  const [groups, setGroups] = useState<any[]>([]);
  const [profiles, setProfiles] = useState<any[]>([]);
  const [loading, setLoading] = useState(true);
  const [busyId, setBusyId] = useState<string | null>(null);

  const load = useCallback(async () => {
    const [g, p] = await Promise.all([
      supabase.rpc("admin_get_pending_group_verifications", { p_limit: 50 }),
      supabase.rpc("admin_get_pending_profile_verifications", { p_limit: 50 }),
    ]);
    if ((g.data as any)?.ok) setGroups((g.data as any).items ?? []);
    if ((p.data as any)?.ok) setProfiles((p.data as any).items ?? []);
    setLoading(false);
  }, []);
  useEffect(() => { load(); }, [load]);

  const reviewGroup = async (id: string, approved: boolean) => {
    setBusyId(id);
    await supabase.rpc("admin_review_group_verification", { p_attempt_id: id, p_approved: approved });
    setBusyId(null);
    load();
  };
  const reviewProfile = async (id: string, approved: boolean) => {
    setBusyId(id);
    await supabase.rpc("admin_set_profile_verified", { p_user_id: id, p_verified: approved });
    setBusyId(null);
    load();
  };

  if (loading) return <Spinner />;

  return (
    <div className="space-y-6">
      <Section title="Grupos/proveedores" count={groups.length}>
        {groups.length === 0 && <EmptyBox icon="🪪" text="Sin solicitudes pendientes" />}
        <div className="grid gap-3 lg:grid-cols-2">
          {groups.map((it) => (
            <div key={it.id} className="space-y-2 rounded-2xl border border-brand-border bg-brand-card p-4">
              <p className="font-semibold text-white">{it.group_name}</p>
              <p className="text-xs text-brand-muted">{it.city ?? it.state ?? it.country}</p>
              <div className="flex gap-3">
                {it.document_url && <img src={it.document_url} alt="doc" className="h-20 w-20 rounded-lg object-cover" />}
                {it.selfie_url && <img src={it.selfie_url} alt="selfie" className="h-20 w-20 rounded-lg object-cover" />}
              </div>
              <div className="flex gap-2">
                <ActionBtn label="Aprobar" color="green" busy={busyId === it.id} onClick={() => reviewGroup(it.id, true)} />
                <ActionBtn label="Rechazar" color="red" busy={busyId === it.id} onClick={() => reviewGroup(it.id, false)} />
              </div>
            </div>
          ))}
        </div>
      </Section>

      <Section title="Clientes y talentos" count={profiles.length}>
        {profiles.length === 0 && <EmptyBox icon="👤" text="Sin solicitudes pendientes" />}
        <div className="grid gap-3 lg:grid-cols-2">
          {profiles.map((it) => (
            <div key={it.id} className="space-y-2 rounded-2xl border border-brand-border bg-brand-card p-4">
              <p className="font-semibold text-white">{it.full_name}</p>
              <p className="text-xs text-brand-muted">{it.role === "talent" ? "Talento" : "Cliente"} · {it.city ?? it.state ?? it.country}</p>
              <div className="flex gap-2">
                <ActionBtn label="Aprobar" color="green" busy={busyId === it.id} onClick={() => reviewProfile(it.id, true)} />
                <ActionBtn label="Rechazar" color="red" busy={busyId === it.id} onClick={() => reviewProfile(it.id, false)} />
              </div>
            </div>
          ))}
        </div>
      </Section>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────────────────
// EVENTOS
// ─────────────────────────────────────────────────────────────────────────
function EventosSection() {
  const [notStarted, setNotStarted] = useState<any[]>([]);
  const [notEnded, setNotEnded] = useState<any[]>([]);
  const [loading, setLoading] = useState(true);
  const [busyId, setBusyId] = useState<string | null>(null);

  const load = useCallback(async () => {
    const [a, b] = await Promise.all([
      supabase.rpc("admin_get_stuck_events", { p_limit: 50 }),
      supabase.rpc("admin_get_stuck_service_events", { p_limit: 50 }),
    ]);
    if ((a.data as any)?.ok) setNotStarted((a.data as any).items ?? []);
    if ((b.data as any)?.ok) setNotEnded((b.data as any).items ?? []);
    setLoading(false);
  }, []);
  useEffect(() => { load(); }, [load]);

  const forceStart = async (id: string) => {
    setBusyId(id);
    const { data, error } = await supabase.rpc("admin_force_start_event", { p_reservation_id: id });
    setBusyId(null);
    if (error || (data as any)?.ok === false) { window.alert((data as any)?.error ?? error?.message ?? "No se pudo forzar el inicio."); return; }
    load();
  };
  const forceComplete = async (id: string) => {
    if (!window.confirm("Esto marca el evento como terminado AHORA MISMO y libera el pago pendiente del grupo. Confírmalo primero con ambos por teléfono.")) return;
    setBusyId(id);
    const { data, error } = await supabase.rpc("admin_force_complete_event", {
      p_reservation_id: id, p_reason: "Confirmado por soporte vía panel web",
    });
    setBusyId(null);
    if (error || (data as any)?.ok === false) { window.alert((data as any)?.error ?? error?.message ?? "No se pudo forzar el cierre."); return; }
    load();
  };

  if (loading) return <Spinner />;

  return (
    <div className="space-y-6">
      <Section title="Nunca iniciaron (ya pasó su hora)" count={notStarted.length}>
        {notStarted.length === 0 && <EmptyBox icon="✅" text="Nada atorado sin iniciar" />}
        <div className="grid gap-3 lg:grid-cols-2">
          {notStarted.map((it) => (
            <div key={it.id} className="space-y-2 rounded-2xl border border-brand-border bg-brand-card p-4">
              <div className="flex items-center justify-between">
                <p className="font-semibold text-white">{it.group_name ?? "Grupo"}</p>
                <p className="font-bold text-brand-green">{money(it.total_price, it.currency)}</p>
              </div>
              <p className="text-xs text-brand-muted">{it.event_date} {it.event_time ?? ""} · lleva {Math.round((it.minutes_late ?? 0) / 60)}h de retraso</p>
              <ActionBtn label="Forzar inicio" color="green" busy={busyId === it.id} onClick={() => forceStart(it.id)} />
            </div>
          ))}
        </div>
      </Section>

      <Section title="Iniciaron pero nunca cerraron" count={notEnded.length}>
        {notEnded.length === 0 && <EmptyBox icon="✅" text="Nada atorado sin cerrar" />}
        <div className="grid gap-3 lg:grid-cols-2">
          {notEnded.map((it) => (
            <div key={it.id} className="space-y-2 rounded-2xl border border-brand-border bg-brand-card p-4">
              <div className="flex items-center justify-between">
                <p className="font-semibold text-white">{it.group_name ?? "Grupo"}</p>
                <p className="font-bold text-brand-green">{money(it.total_price, it.currency)}</p>
              </div>
              <p className="text-xs text-brand-muted">{it.event_date} {it.event_time ?? ""} · lleva {it.hours_stuck}h sin cerrarse</p>
              <ActionBtn label="Forzar cierre" color="red" busy={busyId === it.id} onClick={() => forceComplete(it.id)} />
            </div>
          ))}
        </div>
      </Section>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────────────────
// HISTORIAL
// ─────────────────────────────────────────────────────────────────────────
const HISTORIAL_LABELS: Record<string, string> = {
  evento: "🎤 Pago de evento", propina: "🎁 Propinas pagadas", retiro: "🏦 Retiro", reembolso: "↩️ Reembolso",
};

function HistorialSection() {
  const [items, setItems] = useState<any[]>([]);
  const [loading, setLoading] = useState(true);
  const [filter, setFilter] = useState<string>("todos");

  useEffect(() => {
    supabase.rpc("admin_get_payment_history", { p_limit: 100 }).then(({ data }) => {
      if ((data as any)?.ok) setItems((data as any).items ?? []);
      setLoading(false);
    });
  }, []);

  const openReceipt = async (path: string | null) => {
    if (!path) { window.alert("Este movimiento no tiene comprobante guardado."); return; }
    const { data, error } = await supabase.storage.from("refund-receipts").createSignedUrl(path, 3600);
    if (error || !data?.signedUrl) { window.alert("No se pudo abrir el comprobante."); return; }
    window.open(data.signedUrl, "_blank");
  };

  if (loading) return <Spinner />;
  const filtered = filter === "todos" ? items : items.filter((i) => i.kind === filter);

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap gap-2">
        {["todos", "evento", "propina", "retiro", "reembolso"].map((k) => (
          <button key={k} onClick={() => setFilter(k)}
            className={`rounded-full px-3 py-1.5 text-xs font-medium ${filter === k ? "bg-brand-green text-black" : "border border-brand-border text-brand-muted"}`}>
            {k === "todos" ? "Todos" : HISTORIAL_LABELS[k]}
          </button>
        ))}
      </div>
      {filtered.length === 0 && <EmptyBox icon="🧾" text="Sin movimientos todavía" />}
      <div className="space-y-2">
        {filtered.map((it) => (
          <div key={it.id} className="flex items-center justify-between rounded-xl border border-brand-border bg-brand-card px-4 py-3">
            <div>
              <p className="font-semibold text-white">{it.group_name ?? "—"}</p>
              <p className="text-xs text-brand-muted">
                {HISTORIAL_LABELS[it.kind] ?? it.kind} · {new Date(it.created_at).toLocaleDateString("es-MX")}
                {it.transfer_ref ? ` · ref ${it.transfer_ref}` : ""}
              </p>
            </div>
            <div className="flex items-center gap-3">
              <span className="font-bold text-brand-green">{money(it.amount)}</span>
              <button onClick={() => openReceipt(it.receipt_path)} className="rounded-lg border border-brand-border px-2.5 py-1 text-xs text-brand-muted hover:text-white">Ver comprobante</button>
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────────────────
// FOTOS (media)
// ─────────────────────────────────────────────────────────────────────────
function FotosSection() {
  const [groups, setGroups] = useState<any[]>([]);
  const [posts, setPosts] = useState<any[]>([]);
  const [videos, setVideos] = useState<any[]>([]);
  const [loading, setLoading] = useState(true);
  const [busyId, setBusyId] = useState<string | null>(null);

  const claimIds = [
    ...groups.flatMap((g) => [g.photo_status === "pending" ? g.id + "_photo" : null, g.video_status === "pending" ? g.id + "_video" : null]),
    ...posts.map((p) => p.id + "_eventpost"),
    ...videos.map((v) => v.id + "_carouselvideo"),
  ].filter((x): x is string => !!x);
  const { claims, claim, release, busyId: claimBusyId } = useAdminClaims("media", claimIds);
  const locked = (id: string) => { const c = claims[id]; return !!c && !c.is_mine; };

  const load = useCallback(async () => {
    const { data } = await supabase.rpc("admin_get_pending_media", { p_limit: 50 });
    if ((data as any)?.ok) {
      setGroups((data as any).groups ?? []);
      setPosts((data as any).event_posts ?? []);
      setVideos((data as any).videos ?? []);
    }
    setLoading(false);
  }, []);
  useEffect(() => { load(); }, [load]);

  const reject = (label: string) => window.prompt(`Motivo de rechazo (${label})`);

  const approvePhoto = async (g: any) => {
    setBusyId(g.id + "p");
    await supabase.rpc("approve_group_photo", { p_group_id: g.id });
    setBusyId(null);
    await release(g.id + "_photo");
    load();
  };
  const rejectPhoto = async (g: any) => {
    const reason = reject("foto"); if (!reason) return;
    setBusyId(g.id + "p");
    await supabase.rpc("reject_group_photo", { p_group_id: g.id, p_reason: reason });
    setBusyId(null);
    await release(g.id + "_photo");
    load();
  };
  const approveVideo = async (g: any) => {
    setBusyId(g.id + "v");
    await supabase.rpc("approve_group_video", { p_group_id: g.id });
    setBusyId(null);
    await release(g.id + "_video");
    load();
  };
  const rejectVideo = async (g: any) => {
    const reason = reject("video"); if (!reason) return;
    setBusyId(g.id + "v");
    await supabase.rpc("reject_group_video", { p_group_id: g.id, p_reason: reason });
    setBusyId(null);
    await release(g.id + "_video");
    load();
  };
  const approvePost = async (p: any) => {
    setBusyId(p.id);
    await supabase.from("group_event_posts").update({ status: "approved" }).eq("id", p.id);
    setBusyId(null);
    await release(p.id + "_eventpost");
    load();
  };
  const rejectPost = async (p: any) => {
    const reason = reject("publicación"); if (!reason) return;
    setBusyId(p.id);
    await supabase.from("group_event_posts").update({ status: "rejected", review_note: reason }).eq("id", p.id);
    setBusyId(null);
    await release(p.id + "_eventpost");
    load();
  };
  const approveCarousel = async (v: any) => {
    setBusyId(v.id);
    await supabase.from("group_videos").update({ status: "approved" }).eq("id", v.id);
    setBusyId(null);
    await release(v.id + "_carouselvideo");
    load();
  };
  const rejectCarousel = async (v: any) => {
    const reason = reject("video del carrusel"); if (!reason) return;
    setBusyId(v.id);
    await supabase.from("group_videos").update({ status: "rejected", review_note: reason }).eq("id", v.id);
    setBusyId(null);
    await release(v.id + "_carouselvideo");
    load();
  };

  if (loading) return <Spinner />;
  if (groups.length === 0 && posts.length === 0 && videos.length === 0) return <EmptyBox icon="✅" text="Sin medios pendientes" />;

  return (
    <div className="grid gap-4 lg:grid-cols-2">
      {groups.map((g) => (
        <div key={g.id} className="space-y-4 rounded-2xl border border-brand-border bg-brand-card p-4">
          <p className="font-semibold text-white">{g.name}</p>
          {g.photo_status === "pending" && (
            <div className="space-y-2">
              <p className="text-xs uppercase tracking-wide text-brand-muted">Foto de perfil</p>
              {g.profile_image
                ? <img src={g.profile_image} alt="" className="h-40 w-full rounded-lg object-cover" />
                : <div className="flex h-40 items-center justify-center rounded-lg bg-brand-card2 text-xs text-brand-muted">Sin imagen</div>}
              <ClaimBadge claim={claims[g.id + "_photo"]} busy={claimBusyId === g.id + "_photo"} onClaim={() => claim(g.id + "_photo")} onRelease={() => release(g.id + "_photo")} />
              <div className="flex gap-2">
                <ActionBtn label="✓ Aprobar" color="green" disabled={locked(g.id + "_photo")} busy={busyId === g.id + "p"} onClick={() => approvePhoto(g)} />
                <ActionBtn label="✕ Rechazar" color="red" disabled={locked(g.id + "_photo")} busy={busyId === g.id + "p"} onClick={() => rejectPhoto(g)} />
              </div>
            </div>
          )}
          {g.video_status === "pending" && (
            <div className="space-y-2">
              <p className="text-xs uppercase tracking-wide text-brand-muted">Video promocional</p>
              {g.promo_video
                ? <video src={g.promo_video} controls muted className="h-44 w-full rounded-lg bg-brand-card2 object-cover" />
                : <div className="flex h-40 items-center justify-center rounded-lg bg-brand-card2 text-xs text-brand-muted">Sin video</div>}
              <ClaimBadge claim={claims[g.id + "_video"]} busy={claimBusyId === g.id + "_video"} onClaim={() => claim(g.id + "_video")} onRelease={() => release(g.id + "_video")} />
              <div className="flex gap-2">
                <ActionBtn label="✓ Aprobar" color="green" disabled={locked(g.id + "_video")} busy={busyId === g.id + "v"} onClick={() => approveVideo(g)} />
                <ActionBtn label="✕ Rechazar" color="red" disabled={locked(g.id + "_video")} busy={busyId === g.id + "v"} onClick={() => rejectVideo(g)} />
              </div>
            </div>
          )}
        </div>
      ))}

      {posts.map((p) => (
        <div key={p.id} className="space-y-2 rounded-2xl border border-brand-border bg-brand-card p-4">
          <p className="font-semibold text-white">{p.groups?.name ?? "Grupo"}</p>
          <p className="text-xs uppercase tracking-wide text-brand-muted">Publicación {p.photos?.length > 1 ? `· ${p.photos.length} fotos` : ""}</p>
          {p.caption && <p className="text-xs text-brand-muted">{p.caption}</p>}
          <div className="flex gap-2 overflow-x-auto">
            {(p.photos ?? []).map((ph: any) => <img key={ph.id} src={ph.url} alt="" className="h-32 w-40 shrink-0 rounded-lg object-cover" />)}
          </div>
          <ClaimBadge claim={claims[p.id + "_eventpost"]} busy={claimBusyId === p.id + "_eventpost"} onClaim={() => claim(p.id + "_eventpost")} onRelease={() => release(p.id + "_eventpost")} />
          <div className="flex gap-2">
            <ActionBtn label="✓ Aprobar" color="green" disabled={locked(p.id + "_eventpost")} busy={busyId === p.id} onClick={() => approvePost(p)} />
            <ActionBtn label="✕ Rechazar" color="red" disabled={locked(p.id + "_eventpost")} busy={busyId === p.id} onClick={() => rejectPost(p)} />
          </div>
        </div>
      ))}

      {videos.map((v) => (
        <div key={v.id} className="space-y-2 rounded-2xl border border-brand-border bg-brand-card p-4">
          <p className="font-semibold text-white">{v.groups?.name ?? "Grupo"}</p>
          <p className="text-xs uppercase tracking-wide text-brand-muted">Video del carrusel</p>
          <video src={v.url} controls muted className="h-44 w-full rounded-lg bg-brand-card2 object-cover" />
          <ClaimBadge claim={claims[v.id + "_carouselvideo"]} busy={claimBusyId === v.id + "_carouselvideo"} onClaim={() => claim(v.id + "_carouselvideo")} onRelease={() => release(v.id + "_carouselvideo")} />
          <div className="flex gap-2">
            <ActionBtn label="✓ Aprobar" color="green" disabled={locked(v.id + "_carouselvideo")} busy={busyId === v.id} onClick={() => approveCarousel(v)} />
            <ActionBtn label="✕ Rechazar" color="red" disabled={locked(v.id + "_carouselvideo")} busy={busyId === v.id} onClick={() => rejectCarousel(v)} />
          </div>
        </div>
      ))}
    </div>
  );
}

// ─────────────────────────────────────────────────────────────────────────
// COTIZACIONES (conserjería)
// ─────────────────────────────────────────────────────────────────────────
function CotizacionesSection() {
  const [items, setItems] = useState<any[]>([]);
  const [loading, setLoading] = useState(true);
  const [search, setSearch] = useState("");
  const [modal, setModal] = useState<any | null>(null);
  const [basePrice, setBasePrice] = useState("");
  const [travelCost, setTravelCost] = useState("");
  const [ot1, setOt1] = useState(""); const [ot2, setOt2] = useState(""); const [ot3, setOt3] = useState("");
  const [notes, setNotes] = useState("");
  const [sending, setSending] = useState(false);
  const { claims, claim, release, busyId: claimBusyId } = useAdminClaims("concierge_quote", items.map((i) => i.quote_id));

  const load = useCallback(async () => {
    const { data } = await supabase.rpc("admin_get_concierge_quotes", { p_limit: 100 });
    if ((data as any)?.ok) setItems((data as any).items ?? []);
    setLoading(false);
  }, []);
  useEffect(() => { load(); }, [load]);

  const openModal = (item: any) => {
    setModal(item); setBasePrice(""); setTravelCost(""); setOt1(""); setOt2(""); setOt3(""); setNotes("");
  };

  const send = async () => {
    if (!modal) return;
    const price = Number(basePrice.replace(",", "."));
    if (!Number.isFinite(price) || price <= 0) { window.alert("Escribe el precio neto que pidió el grupo."); return; }
    setSending(true);
    const { data, error } = await supabase.rpc("admin_respond_quote", {
      p_quote_id: modal.quote_id, p_base_price: price,
      p_travel_cost: travelCost ? Number(travelCost.replace(",", ".")) : 0,
      p_overtime_1h_price: ot1 ? Number(ot1.replace(",", ".")) : null,
      p_overtime_2h_price: ot2 ? Number(ot2.replace(",", ".")) : null,
      p_overtime_3h_price: ot3 ? Number(ot3.replace(",", ".")) : null,
      p_notes: notes.trim() || null,
    });
    setSending(false);
    if (error || !data?.ok) { window.alert(error?.message ?? data?.error ?? "No se pudo enviar la cotización."); return; }
    await release(modal.quote_id);
    setModal(null);
    window.alert(`Enviada. Total con comisión: $${Number(data.total_amount).toLocaleString("es-MX")}.`);
    load();
  };

  if (loading) return <Spinner />;
  if (items.length === 0) return <EmptyBox icon="📞" text="Nada pendiente — aquí aparecen las cotizaciones de grupos en modo conserjería." />;

  const q = search.trim().toLowerCase();
  const filtered = !q ? items : items.filter((it) =>
    [it.group_name, it.client_name, it.group_genre, it.country].some((v) => v?.toLowerCase().includes(q))
  );

  return (
    <div className="space-y-3">
      <input
        type="text"
        value={search}
        onChange={(e) => setSearch(e.target.value)}
        placeholder="🔍 Buscar por grupo, cliente o país…"
        className="w-full max-w-sm rounded-lg border border-brand-border bg-brand-bg px-3 py-2 text-sm text-white placeholder:text-brand-muted outline-none focus:border-brand-green"
      />
      {filtered.length === 0 ? <EmptyBox icon="🔍" text="Sin resultados para esa búsqueda" /> : (
      <div className="grid gap-4 lg:grid-cols-2">
      {filtered.map((item) => {
        const c = claims[item.quote_id];
        const lockedByOther = !!c && !c.is_mine;
        return (
          <div key={item.quote_id} className="space-y-2 rounded-2xl border border-brand-border bg-brand-card p-4">
            <div className="flex items-center justify-between">
              <p className="font-semibold text-white">{item.group_name}</p>
              <p className="text-xs text-brand-muted">{item.group_genre} · {item.country}</p>
            </div>
            <div className="flex flex-wrap gap-2 text-xs">
              {item.group_phone && <a href={`tel:${item.group_phone}`} className="rounded-lg border border-brand-green bg-brand-green/10 px-2.5 py-1 text-brand-green">📞 Grupo: {item.group_phone}</a>}
              {item.client_phone && <a href={`tel:${item.client_phone}`} className="rounded-lg border border-brand-border bg-brand-card2 px-2.5 py-1 text-brand-muted">📞 {item.client_name ?? "Cliente"}: {item.client_phone}</a>}
            </div>
            <p className="text-xs text-brand-muted">{item.event_date} {item.event_time ?? ""}{item.duration_hours ? ` · ${item.duration_hours}h` : ""}</p>
            {(item.event_address || item.event_municipio) && (
              <p className="text-xs text-brand-muted">📍 {[item.event_address, item.event_municipio, item.event_estado].filter(Boolean).join(", ")}</p>
            )}
            {item.comments && <p className="text-xs italic text-brand-muted">&ldquo;{item.comments}&rdquo;</p>}
            <ClaimBadge claim={c} busy={claimBusyId === item.quote_id} onClaim={() => claim(item.quote_id)} onRelease={() => release(item.quote_id)} />
            <ActionBtn label="💲 Poner precio" color="green" disabled={lockedByOther} onClick={() => openModal(item)} />
          </div>
        );
      })}
      </div>
      )}

      <Modal open={!!modal} onClose={() => setModal(null)} title={modal?.group_name ?? ""}>
        <p className="mb-4 text-xs text-brand-muted">Escribe lo que el grupo pidió por teléfono — el sistema agrega la comisión automáticamente.</p>
        <label className={labelCls}>Precio del grupo (neto)</label>
        <input className={`${inputCls} mb-3`} value={basePrice} onChange={(e) => setBasePrice(e.target.value)} placeholder="Ej. 9000" />
        <label className={labelCls}>Costo de traslado (opcional)</label>
        <input className={`${inputCls} mb-3`} value={travelCost} onChange={(e) => setTravelCost(e.target.value)} placeholder="0" />
        <label className={labelCls}>Horas extra (opcional) — total por 1h/2h/3h extra</label>
        <div className="mb-3 grid grid-cols-3 gap-2">
          <input className={inputCls} value={ot1} onChange={(e) => setOt1(e.target.value)} placeholder="1h" />
          <input className={inputCls} value={ot2} onChange={(e) => setOt2(e.target.value)} placeholder="2h" />
          <input className={inputCls} value={ot3} onChange={(e) => setOt3(e.target.value)} placeholder="3h" />
        </div>
        <label className={labelCls}>Nota interna (opcional)</label>
        <textarea className={`${inputCls} mb-4`} rows={2} value={notes} onChange={(e) => setNotes(e.target.value)} />
        <div className="flex gap-3">
          <button onClick={() => setModal(null)} className="flex-1 rounded-lg border border-brand-border py-2.5 text-sm text-brand-muted">Cancelar</button>
          <button onClick={send} disabled={sending} className="flex-1 rounded-lg bg-brand-green py-2.5 text-sm font-bold text-black disabled:opacity-50">
            {sending ? "…" : "Enviar al cliente"}
          </button>
        </div>
      </Modal>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────────────────
// SOLICITUDES DE PROVEEDORES
// ─────────────────────────────────────────────────────────────────────────
function SolicitudesSection() {
  const [tab, setTab] = useState<"pending" | "approved" | "rejected" | "all">("pending");
  const [items, setItems] = useState<any[]>([]);
  const [loading, setLoading] = useState(true);
  const [search, setSearch] = useState("");
  const [approveTarget, setApproveTarget] = useState<any | null>(null);
  const [email, setEmail] = useState(""); const [genre, setGenre] = useState(""); const [tempPass, setTempPass] = useState("");
  const [approving, setApproving] = useState(false);
  const pendingIds = items.filter((i) => i.status === "pending").map((i) => i.id);
  const { claims, claim, release, busyId: claimBusyId } = useAdminClaims("provider_application", pendingIds);

  // 2026-09-17 — petición real: "quiero que pueda agregar proveedores en
  // la computadora, todos los admin que puedan hacer eso". Antes esto era
  // backlog explícito de la Fase 1 (ver comentario al inicio del archivo).
  // Mismo flujo que AdminProviderApplicationsScreen de la app: manda la
  // MISMA solicitud pública (submit_provider_application) y encadena
  // directo al modal de aprobar de aquí abajo — un solo flujo, cuenta lista.
  const [addModal, setAddModal] = useState(false);
  const [addName, setAddName] = useState(""); const [addPhone, setAddPhone] = useState("");
  const [addCategory, setAddCategory] = useState<string | null>(null);
  const [addYears, setAddYears] = useState(""); const [addMinHours, setAddMinHours] = useState("");
  const [addCountry, setAddCountry] = useState("México");
  const [addState, setAddState] = useState(""); const [addCity, setAddCity] = useState("");
  const [addNotes, setAddNotes] = useState("");
  const [adding, setAdding] = useState(false);

  const openAdd = () => {
    setAddModal(true);
    setAddName(""); setAddPhone(""); setAddCategory(null);
    setAddYears(""); setAddMinHours("");
    setAddCountry("México"); setAddState(""); setAddCity(""); setAddNotes("");
  };

  const openApprove = (item: any) => {
    setApproveTarget(item);
    setEmail("");
    // Si la categoría solo tiene un género posible (DJ, Comida, MC...) se
    // preselecciona; si tiene varios, el admin elige de la lista real de
    // abajo (chips) — nunca a mano, evita el typo que ya causó un bug real
    // (un grupo genuinamente Sierreño quedó guardado como "Ranchero").
    const opts = CATEGORY_LABELS.find((c) => c.key === item.category)?.genres ?? [];
    setGenre(opts.length === 1 ? opts[0] : "");
    setTempPass("");
  };

  const sendAdd = async () => {
    if (!addName.trim() || addPhone.trim().length < 7 || !addCategory) {
      window.alert("Escribe el nombre, teléfono y elige la categoría.");
      return;
    }
    setAdding(true);
    const { data, error } = await supabase.rpc("submit_provider_application", {
      p_full_name: addName.trim(),
      p_phone: addPhone.trim(),
      p_category: addCategory,
      p_years_experience: addYears ? parseInt(addYears, 10) : null,
      p_min_hours: addMinHours ? parseFloat(addMinHours) : null,
      p_country: addCountry,
      p_state: addState.trim() || null,
      p_city: addCity.trim() || null,
      p_notes: addNotes.trim() || null,
    });
    setAdding(false);
    if (error || !data?.ok) { window.alert(error?.message ?? data?.error ?? "No se pudo crear la solicitud."); return; }
    setAddModal(false);
    openApprove({
      id: data.application_id,
      full_name: addName.trim(), phone: addPhone.trim(), category: addCategory,
      years_experience: addYears ? parseInt(addYears, 10) : null,
      min_hours: addMinHours ? parseFloat(addMinHours) : null,
      country: addCountry, state: addState.trim() || null, city: addCity.trim() || null,
      notes: addNotes.trim() || null, status: "pending", admin_notes: null, created_at: new Date().toISOString(),
    });
  };

  const load = useCallback(async (t: typeof tab) => {
    const { data } = await supabase.rpc("admin_get_provider_applications", { p_status: t === "all" ? null : t });
    if ((data as any)?.ok) setItems((data as any).items ?? []);
    setLoading(false);
  }, []);
  useEffect(() => { setLoading(true); load(tab); }, [tab, load]);

  const doApprove = async () => {
    if (!approveTarget) return;
    if (!email.trim() || !genre.trim()) { window.alert("Escribe el correo y el género exacto del grupo."); return; }
    setApproving(true);
    const { data, error } = await supabase.rpc("admin_approve_provider_application", {
      p_application_id: approveTarget.id, p_email: email.trim(), p_genre: genre.trim(), p_temp_password: tempPass.trim() || null,
    });
    setApproving(false);
    if (error || !data?.ok) { window.alert(error?.message ?? data?.error ?? "No se pudo aprobar."); return; }
    await release(approveTarget.id);
    setApproveTarget(null);
    window.alert(`Cuenta creada.\nCorreo: ${data.email}\nContraseña: ${data.temp_password}\n\nPásaselos al proveedor por WhatsApp.`);
    load(tab);
  };

  const doReject = async (item: any) => {
    const reason = window.prompt("Motivo de rechazo (opcional)");
    await supabase.rpc("admin_reject_provider_application", { p_application_id: item.id, p_reason: reason || null });
    await release(item.id);
    load(tab);
  };

  const q = search.trim().toLowerCase();
  const filtered = !q ? items : items.filter((it) =>
    [it.full_name, it.category, it.city, it.state, it.country, it.phone].some((v) => v?.toLowerCase?.().includes(q))
  );

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div className="flex flex-wrap gap-2">
          {([["pending", "Pendientes"], ["approved", "Aprobadas"], ["rejected", "Rechazadas"], ["all", "Todas"]] as const).map(([k, l]) => (
            <button key={k} onClick={() => setTab(k)} className={`rounded-full px-3 py-1.5 text-xs font-medium ${tab === k ? "bg-brand-green text-black" : "border border-brand-border text-brand-muted"}`}>{l}</button>
          ))}
        </div>
        <button onClick={openAdd} className="rounded-lg bg-brand-green px-3 py-1.5 text-xs font-bold text-black hover:bg-brand-green2">
          + Agregar proveedor
        </button>
      </div>

      <input
        type="text"
        value={search}
        onChange={(e) => setSearch(e.target.value)}
        placeholder="🔍 Buscar por nombre, categoría o ciudad…"
        className="w-full max-w-sm rounded-lg border border-brand-border bg-brand-bg px-3 py-2 text-sm text-white placeholder:text-brand-muted outline-none focus:border-brand-green"
      />

      {loading ? <Spinner /> : filtered.length === 0 ? <EmptyBox icon="📝" text={q ? "Sin resultados para esa búsqueda" : "Nada aquí"} /> : (
        <div className="grid gap-3 lg:grid-cols-2">
          {filtered.map((item) => {
            const c = claims[item.id];
            const lockedByOther = !!c && !c.is_mine;
            return (
              <div key={item.id} className="space-y-2 rounded-2xl border border-brand-border bg-brand-card p-4">
                <div className="flex items-center justify-between">
                  <p className="font-semibold text-white">{item.full_name}</p>
                  <span className="rounded-full bg-brand-card2 px-2.5 py-1 text-xs text-brand-muted">{item.status}</span>
                </div>
                <p className="text-xs text-brand-muted">{CATEGORY_LABELS.find((c) => c.key === item.category)?.label ?? item.category}</p>
                <a href={`tel:${item.phone}`} className="text-xs text-brand-green">📞 {item.phone}</a>
                {item.years_experience != null && <p className="text-xs text-brand-muted">{item.years_experience} años de trayectoria</p>}
                {item.min_hours != null && <p className="text-xs text-brand-muted">Mínimo {item.min_hours}h de contratación</p>}
                <p className="text-xs text-brand-muted">{[item.city, item.state, item.country].filter(Boolean).join(", ")}</p>
                {item.notes && <p className="text-xs italic text-brand-muted">&ldquo;{item.notes}&rdquo;</p>}
                {item.status === "rejected" && item.admin_notes && <p className="text-xs text-red-400">Motivo: {item.admin_notes}</p>}
                {item.status === "pending" && (
                  <>
                    <ClaimBadge claim={c} busy={claimBusyId === item.id} onClaim={() => claim(item.id)} onRelease={() => release(item.id)} />
                    <div className="flex gap-2">
                      <ActionBtn label="Rechazar" color="muted" disabled={lockedByOther} onClick={() => doReject(item)} />
                      <ActionBtn label="Aprobar y crear cuenta" color="green" disabled={lockedByOther} onClick={() => openApprove(item)} />
                    </div>
                  </>
                )}
              </div>
            );
          })}
        </div>
      )}

      <Modal open={!!approveTarget} onClose={() => setApproveTarget(null)} title={approveTarget?.full_name ?? ""}>
        <p className="mb-4 text-xs text-brand-muted">Ya lo contactaste y viste sus fotos/videos por WhatsApp. Crea su cuenta real.</p>
        <label className={labelCls}>Correo del proveedor</label>
        <input className={`${inputCls} mb-3`} value={email} onChange={(e) => setEmail(e.target.value)} placeholder="correo@ejemplo.com" />
        <label className={labelCls}>Género exacto — de esto depende que aparezca en su categoría del Explorador</label>
        <div className="mb-4 flex flex-wrap gap-2">
          {(CATEGORY_LABELS.find((c) => c.key === approveTarget?.category)?.genres ?? []).map((g) => (
            <button
              key={g}
              onClick={() => setGenre(g)}
              className={`rounded-full px-2.5 py-1 text-xs font-medium ${genre === g ? "bg-brand-green text-black" : "border border-brand-border text-brand-muted"}`}
            >
              {g}
            </button>
          ))}
        </div>
        <label className={labelCls}>Contraseña temporal (opcional — se genera si la dejas vacía)</label>
        <input className={`${inputCls} mb-4`} value={tempPass} onChange={(e) => setTempPass(e.target.value)} />
        <div className="flex gap-3">
          <button onClick={() => setApproveTarget(null)} className="flex-1 rounded-lg border border-brand-border py-2.5 text-sm text-brand-muted">Cancelar</button>
          <button onClick={doApprove} disabled={approving} className="flex-1 rounded-lg bg-brand-green py-2.5 text-sm font-bold text-black disabled:opacity-50">
            {approving ? "…" : "Crear cuenta"}
          </button>
        </div>
      </Modal>

      {/* Alta directa — ya hablaste con el proveedor por teléfono. Manda la
          MISMA solicitud pública que llenaría él, y encadena directo al
          modal de aprobar de arriba — un solo flujo, cuenta lista. */}
      <Modal open={addModal} onClose={() => setAddModal(false)} title="Agregar proveedor">
        <label className={labelCls}>Nombre o nombre del grupo</label>
        <input className={`${inputCls} mb-3`} value={addName} onChange={(e) => setAddName(e.target.value)} placeholder="Ej. Banda Los Ejemplares" />
        <label className={labelCls}>Teléfono (WhatsApp)</label>
        <input className={`${inputCls} mb-3`} value={addPhone} onChange={(e) => setAddPhone(e.target.value)} placeholder="Ej. 33 1234 5678" />

        <label className={labelCls}>Categoría</label>
        <div className="mb-3 flex flex-wrap gap-2">
          {CATEGORY_LABELS.map((cat) => (
            <button
              key={cat.key}
              onClick={() => setAddCategory(cat.key)}
              className={`rounded-full px-2.5 py-1 text-xs font-medium ${addCategory === cat.key ? "bg-brand-green text-black" : "border border-brand-border text-brand-muted"}`}
            >
              {cat.label}
            </button>
          ))}
        </div>

        <div className="mb-3 grid grid-cols-2 gap-2">
          <div>
            <label className={labelCls}>Años de trayectoria</label>
            <input className={inputCls} value={addYears} onChange={(e) => setAddYears(e.target.value.replace(/[^0-9]/g, ""))} placeholder="Ej. 5" />
          </div>
          <div>
            <label className={labelCls}>Horas mínimas de contratación</label>
            <input className={inputCls} value={addMinHours} onChange={(e) => setAddMinHours(e.target.value.replace(/[^0-9.]/g, ""))} placeholder="Ej. 3" />
          </div>
        </div>

        <label className={labelCls}>País</label>
        <div className="mb-3 flex flex-wrap gap-2">
          {APPLY_COUNTRIES.map((c) => (
            <button
              key={c}
              onClick={() => setAddCountry(c)}
              className={`rounded-full px-2.5 py-1 text-xs font-medium ${addCountry === c ? "bg-brand-green text-black" : "border border-brand-border text-brand-muted"}`}
            >
              {c}
            </button>
          ))}
        </div>

        <div className="mb-3 grid grid-cols-2 gap-2">
          <div>
            <label className={labelCls}>Estado</label>
            <input className={inputCls} value={addState} onChange={(e) => setAddState(e.target.value)} placeholder="Ej. Jalisco" />
          </div>
          <div>
            <label className={labelCls}>Ciudad</label>
            <input className={inputCls} value={addCity} onChange={(e) => setAddCity(e.target.value)} placeholder="Ej. Zapopan" />
          </div>
        </div>

        <label className={labelCls}>Notas (opcional)</label>
        <textarea className={`${inputCls} mb-4`} rows={2} value={addNotes} onChange={(e) => setAddNotes(e.target.value)} placeholder="Ej. tocamos en bodas y XV años, tenemos equipo propio..." />

        <div className="flex gap-3">
          <button onClick={() => setAddModal(false)} className="flex-1 rounded-lg border border-brand-border py-2.5 text-sm text-brand-muted">Cancelar</button>
          <button onClick={sendAdd} disabled={adding} className="flex-1 rounded-lg bg-brand-green py-2.5 text-sm font-bold text-black disabled:opacity-50">
            {adding ? "…" : "Siguiente"}
          </button>
        </div>
      </Modal>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────────────────
// VISA / DEMANDA ENTRE PAÍSES (solo lectura en esta fase)
// ─────────────────────────────────────────────────────────────────────────
// Descarga (imprime) un PDF con logo del detalle de un grupo+ruta — para
// cuando un grupo pide el papel para su trámite de visa. Sin librería de
// PDF: abre una pestaña con HTML imprimible y usa el diálogo nativo del
// navegador ("Guardar como PDF"), igual de válido para el consulado.
async function downloadCrossBorderPdf(groupId: string, groupName: string, groupCountry: string, eventCountry: string) {
  const { data } = await supabase.rpc("admin_get_cross_border_detail", {
    p_group_id: groupId, p_event_country: eventCountry, p_limit: 200,
  });
  const rows: any[] = (data as any)?.items ?? [];
  const win = window.open("", "_blank");
  if (!win) { window.alert("Tu navegador bloqueó la ventana — permite pop-ups para descargar el PDF."); return; }

  const esc = (v: unknown) => String(v ?? "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  const fecha = (d?: string | null) => d ? new Date(d).toLocaleDateString("es-MX", { day: "2-digit", month: "long", year: "numeric" }) : "—";
  const rowsHtml = rows.map((r, i) => `
    <tr>
      <td>${i + 1}</td>
      <td>${esc(r.client_name ?? "Sin nombre registrado")}</td>
      <td>${esc(r.client_phone ?? "—")}</td>
      <td>${esc(fecha(r.event_date))}${r.event_time ? " " + esc(r.event_time) : ""}</td>
      <td>${esc([r.event_address, r.event_municipio, r.event_estado].filter(Boolean).join(", "))}</td>
      <td>${r.was_blocked ? "Bloqueada - sin visa" : "Cumplida"}</td>
    </tr>`).join("");

  win.document.write(`<!doctype html><html><head><meta charset="utf-8"><title>${esc(groupName)} - Demanda entre países</title>
    <style>
      @page { margin: 36px 40px; }
      body { font-family: -apple-system, Roboto, Arial, sans-serif; color: #1a1a1a; margin: 0; font-size: 12px; }
      .header { display: flex; align-items: center; gap: 10px; margin-bottom: 16px; }
      .header img { width: 32px; height: 32px; border-radius: 50%; }
      .header b { font-size: 15px; }
      h1 { font-size: 17px; margin: 12px 0 2px; }
      .sub { font-size: 12px; color: #555; margin-bottom: 16px; }
      table { width: 100%; border-collapse: collapse; }
      th { text-align: left; font-size: 10px; text-transform: uppercase; color: #666; border-bottom: 2px solid #e0e0e0; padding: 6px; }
      td { padding: 8px 6px; border-bottom: 1px solid #eee; font-size: 11px; }
      tr { page-break-inside: avoid; }
      .foot { margin-top: 24px; font-size: 9.5px; color: #666; }
    </style></head><body>
    <div class="header"><img src="${window.location.origin}/logo.png" /><b>DARICEFY</b></div>
    <h1>${esc(groupName)}</h1>
    <p class="sub">Ruta: ${esc(groupCountry)} -&gt; ${esc(eventCountry)} | Generado el ${fecha(new Date().toISOString())}</p>
    <table><thead><tr><th></th><th>Cliente</th><th>Teléfono</th><th>Fecha del evento</th><th>Dirección</th><th>Estado</th></tr></thead>
    <tbody>${rowsHtml}</tbody></table>
    <p class="foot">Documento generado automáticamente por Daricefy a partir de las solicitudes reales recibidas en la plataforma.</p>
    <script>window.onload = () => window.print();</script>
    </body></html>`);
  win.document.close();
}

function VisaSection() {
  const [items, setItems] = useState<any[]>([]);
  const [loading, setLoading] = useState(true);
  const [search, setSearch] = useState("");

  useEffect(() => {
    supabase.rpc("admin_get_cross_border_report", { p_limit: 200 }).then(({ data }) => {
      if ((data as any)?.ok) setItems((data as any).items ?? []);
      setLoading(false);
    });
  }, []);

  if (loading) return <Spinner />;
  if (items.length === 0) return <EmptyBox icon="✈️" text="Sin demanda entre países registrada todavía" />;

  const q = search.trim().toLowerCase();
  const filtered = !q ? items : items.filter((it) =>
    [it.group_name, it.group_country, it.event_country].some((v) => v?.toLowerCase().includes(q))
  );

  return (
    <div className="space-y-3">
      <input
        type="text"
        value={search}
        onChange={(e) => setSearch(e.target.value)}
        placeholder="🔍 Buscar por grupo o país…"
        className="w-full max-w-sm rounded-lg border border-brand-border bg-brand-bg px-3 py-2 text-sm text-white placeholder:text-brand-muted outline-none focus:border-brand-green"
      />
      <div className="overflow-x-auto rounded-2xl border border-brand-border bg-brand-card">
      <table className="w-full text-sm">
        <thead>
          <tr className="border-b border-brand-border text-left text-xs uppercase tracking-wide text-brand-muted">
            <th className="px-4 py-3">Grupo</th>
            <th className="px-4 py-3">Ruta</th>
            <th className="px-4 py-3">Bloqueadas</th>
            <th className="px-4 py-3">Cumplidas</th>
            <th className="px-4 py-3"></th>
          </tr>
        </thead>
        <tbody>
          {filtered.map((it, i) => (
            <tr key={i} className="border-b border-brand-border last:border-0">
              <td className="px-4 py-3 font-medium text-white">{it.group_name}</td>
              <td className="px-4 py-3 text-brand-muted">{it.group_country} → {it.event_country}</td>
              <td className="px-4 py-3 text-red-400">{it.blocked_requests ?? 0}</td>
              <td className="px-4 py-3 text-brand-green">{it.fulfilled_requests ?? 0}</td>
              <td className="px-4 py-3">
                <button
                  onClick={() => downloadCrossBorderPdf(it.group_id, it.group_name, it.group_country, it.event_country)}
                  className="rounded-lg border border-brand-green px-2.5 py-1 text-xs font-medium text-brand-green hover:bg-brand-green/10"
                >
                  📥 PDF
                </button>
              </td>
            </tr>
          ))}
        </tbody>
      </table>
      </div>
    </div>
  );
}
