"use client";

/**
 * FinancesManager — paridad con las piezas de FinancialScreen.tsx de la
 * app que la web AÚN no cubría (petición real 2026-09-18: "déjalo listo
 * todo como lo veo en mi app"). El resto de FinancialScreen (pagos
 * pendientes por reserva, retiros, resumen de ingresos) YA vive en
 * Operación → Pagos y en Resumen — no se duplica aquí, solo lo que
 * faltaba: reembolsos manuales a clientes y el desglose financiero por
 * evento. Mismas RPC exactas que usa la app.
 */

import { useEffect, useState } from "react";
import { supabase } from "@/lib/supabase";
import { Spinner, EmptyBox, Modal, inputCls, labelCls } from "./ui";

interface Refund {
  id: string; reservation_id: string; client_id: string; folio: string | null;
  client_name: string | null; client_phone: string | null; country: string | null;
  state: string | null; city: string | null; currency: string; payment_method: string | null;
  amount: number; clabe: string | null; account_holder: string | null; bank_name: string | null;
  due_date: string | null; status: string; transfer_reference: string | null;
  api_error: string | null; created_at: string;
}

interface EventFin {
  reservation_id: string; event_date: string; group_name: string | null;
  event_total: number; platform_fee: number; stripe_fee: number; mercadopago_fee: number;
  net_platform_profit: number; artists_payout: number; created_at: string;
}

const money = (n: number | null | undefined, currency = "MXN") =>
  `$${Number(n ?? 0).toLocaleString("es-MX", { minimumFractionDigits: 2 })} ${currency}`;

export default function FinancesManager() {
  const [tab, setTab] = useState<"refunds" | "events">("refunds");
  const [refunds, setRefunds] = useState<Refund[]>([]);
  const [events, setEvents] = useState<EventFin[]>([]);
  const [days, setDays] = useState(30);
  const [loading, setLoading] = useState(true);
  const [busyId, setBusyId] = useState<string | null>(null);
  const [sendModal, setSendModal] = useState<Refund | null>(null);
  const [reference, setReference] = useState("");
  const [receiptFile, setReceiptFile] = useState<File | null>(null);
  const [sending, setSending] = useState(false);

  const loadRefunds = async () => {
    const { data, error } = await supabase.rpc("admin_manual_refund_queue");
    if (error) console.error("[FinancesManager] refunds", error.message);
    setRefunds((data as Refund[]) ?? []);
  };
  const loadEvents = async () => {
    const { data, error } = await supabase.rpc("get_admin_event_financials", { p_days: days, p_limit: 100 });
    if (error) console.error("[FinancesManager] events", error.message);
    setEvents((data as EventFin[]) ?? []);
  };

  useEffect(() => {
    setLoading(true);
    Promise.all([loadRefunds(), loadEvents()]).then(() => setLoading(false));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);
  useEffect(() => { loadEvents(); }, [days]);

  const markProcessing = async (r: Refund) => {
    setBusyId(r.id);
    const { data } = await supabase.rpc("admin_process_manual_refund", { p_refund_id: r.id, p_action: "processing" });
    setBusyId(null);
    if ((data as any)?.ok === false) { window.alert((data as any)?.error ?? "No se pudo procesar."); return; }
    loadRefunds();
  };

  const openSend = (r: Refund) => { setSendModal(r); setReference(""); setReceiptFile(null); };

  const completeRefund = async () => {
    if (!sendModal) return;
    if (!reference.trim()) { window.alert("Escribe la referencia de la transferencia."); return; }
    setSending(true);
    try {
      let receiptPath: string | null = null;
      if (receiptFile) {
        receiptPath = `${sendModal.client_id}/${sendModal.id}.jpg`;
        const { error: upErr } = await supabase.storage.from("refund-receipts").upload(receiptPath, receiptFile, { contentType: receiptFile.type, upsert: true });
        if (upErr) throw new Error("No se pudo subir el comprobante: " + upErr.message);
      }
      const { data, error } = await supabase.rpc("admin_process_manual_refund", {
        p_refund_id: sendModal.id, p_action: "sent", p_transfer_reference: reference.trim(), p_receipt_path: receiptPath,
      });
      if (error || (data as any)?.ok === false) throw new Error((data as any)?.error ?? error?.message ?? "No se pudo completar.");
      window.alert("Reembolso marcado como enviado — el cliente fue notificado.");
      setSendModal(null); loadRefunds();
    } catch (e: any) {
      window.alert(e?.message ?? "No se pudo completar.");
    } finally {
      setSending(false);
    }
  };

  if (loading) return <Spinner />;

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap gap-2">
        <button onClick={() => setTab("refunds")} className={`rounded-full px-3 py-1.5 text-xs font-medium ${tab === "refunds" ? "bg-brand-green text-black" : "border border-brand-border text-brand-muted"}`}>
          💸 Reembolsos a clientes{refunds.filter((r) => r.status === "pending").length > 0 ? ` · ${refunds.filter((r) => r.status === "pending").length}` : ""}
        </button>
        <button onClick={() => setTab("events")} className={`rounded-full px-3 py-1.5 text-xs font-medium ${tab === "events" ? "bg-brand-green text-black" : "border border-brand-border text-brand-muted"}`}>
          📊 Desglose por evento
        </button>
      </div>

      {tab === "refunds" && (
        refunds.length === 0 ? <EmptyBox icon="💸" text="Sin reembolsos pendientes" /> : (
          <div className="grid gap-3 lg:grid-cols-2">
            {refunds.map((r) => (
              <div key={r.id} className="space-y-2 rounded-2xl border border-brand-border bg-brand-card p-4">
                <div className="flex items-center justify-between">
                  <p className="font-semibold text-white">{r.client_name ?? "Cliente"}</p>
                  <span className={`rounded-full px-2.5 py-1 text-xs font-medium ${r.status === "sent" ? "bg-brand-green/15 text-brand-green" : r.status === "processing" ? "bg-blue-400/15 text-blue-400" : "bg-yellow-400/15 text-yellow-400"}`}>
                    {r.status === "sent" ? "Enviado" : r.status === "processing" ? "En proceso" : "Pendiente"}
                  </span>
                </div>
                {r.folio && <p className="text-xs text-brand-muted">Folio {r.folio}</p>}
                <p className="text-lg font-bold text-brand-green">{money(r.amount, r.currency)}</p>
                <p className="text-xs text-brand-muted">📞 {r.client_phone ?? "—"} · {[r.city, r.state, r.country].filter(Boolean).join(", ")}</p>
                {r.clabe && (
                  <div className="rounded-lg bg-brand-bg p-2.5 text-xs">
                    <p className="text-white">{r.account_holder ?? "—"}</p>
                    <p className="text-brand-muted">{r.bank_name ?? "—"} · CLABE {r.clabe}</p>
                  </div>
                )}
                {r.due_date && <p className="text-[11px] text-brand-muted">Vence: {new Date(r.due_date).toLocaleDateString("es-MX")}</p>}
                {r.api_error && <p className="rounded-lg bg-red-500/10 px-2.5 py-1.5 text-xs text-red-400">⚠️ {r.api_error}</p>}
                {r.status !== "sent" && (
                  <div className="flex gap-2 pt-1">
                    {r.status === "pending" && (
                      <button onClick={() => markProcessing(r)} disabled={busyId === r.id} className="rounded-lg border border-blue-400 px-3 py-1.5 text-xs font-medium text-blue-400 disabled:opacity-50">
                        {busyId === r.id ? "…" : "Marcar en proceso"}
                      </button>
                    )}
                    <button onClick={() => openSend(r)} className="rounded-lg bg-brand-green px-3 py-1.5 text-xs font-bold text-black">
                      Marcar como enviado
                    </button>
                  </div>
                )}
              </div>
            ))}
          </div>
        )
      )}

      {tab === "events" && (
        <div className="space-y-3">
          <div className="flex flex-wrap gap-2">
            {[7, 30, 90].map((d) => (
              <button key={d} onClick={() => setDays(d)} className={`rounded-full px-3 py-1.5 text-xs font-medium ${days === d ? "bg-brand-green text-black" : "border border-brand-border text-brand-muted"}`}>
                Últimos {d}d
              </button>
            ))}
          </div>
          {events.length === 0 ? <EmptyBox icon="📊" text="Sin eventos en este rango" /> : (
            <div className="overflow-x-auto rounded-2xl border border-brand-border bg-brand-card">
              <table className="w-full text-sm">
                <thead>
                  <tr className="border-b border-brand-border text-left text-xs uppercase tracking-wide text-brand-muted">
                    <th className="px-4 py-3">Grupo</th>
                    <th className="px-4 py-3">Fecha</th>
                    <th className="px-4 py-3">Total</th>
                    <th className="px-4 py-3">Comisión</th>
                    <th className="px-4 py-3">Fees</th>
                    <th className="px-4 py-3">Ganancia neta</th>
                    <th className="px-4 py-3">Al grupo</th>
                  </tr>
                </thead>
                <tbody>
                  {events.map((e) => (
                    <tr key={e.reservation_id} className="border-b border-brand-border last:border-0">
                      <td className="px-4 py-3 font-medium text-white">{e.group_name ?? "—"}</td>
                      <td className="px-4 py-3 text-brand-muted">{new Date(e.event_date).toLocaleDateString("es-MX")}</td>
                      <td className="px-4 py-3 text-white">{money(e.event_total)}</td>
                      <td className="px-4 py-3 text-brand-green">{money(e.platform_fee)}</td>
                      <td className="px-4 py-3 text-red-400">{money((e.stripe_fee ?? 0) + (e.mercadopago_fee ?? 0))}</td>
                      <td className="px-4 py-3 font-semibold text-brand-green">{money(e.net_platform_profit)}</td>
                      <td className="px-4 py-3 text-brand-muted">{money(e.artists_payout)}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </div>
      )}

      <Modal open={!!sendModal} onClose={() => setSendModal(null)} title="Marcar reembolso como enviado">
        <p className="mb-4 text-xs text-brand-muted">Ya hiciste la transferencia desde tu banco — registra la referencia para avisarle al cliente.</p>
        <label className={labelCls}>Referencia de la transferencia</label>
        <input className={`${inputCls} mb-3`} value={reference} onChange={(e) => setReference(e.target.value)} placeholder="Ej. folio bancario" />
        <label className={labelCls}>Comprobante (opcional)</label>
        <input type="file" accept="image/*" onChange={(e) => setReceiptFile(e.target.files?.[0] ?? null)} className="mb-4 block w-full text-sm text-brand-muted" />
        <div className="flex gap-3">
          <button onClick={() => setSendModal(null)} className="flex-1 rounded-lg border border-brand-border py-2.5 text-sm text-brand-muted">Cancelar</button>
          <button onClick={completeRefund} disabled={sending} className="flex-1 rounded-lg bg-brand-green py-2.5 text-sm font-bold text-black disabled:opacity-50">
            {sending ? "…" : "Confirmar envío"}
          </button>
        </div>
      </Modal>
    </div>
  );
}
