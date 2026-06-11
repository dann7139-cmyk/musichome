"use client";

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import Link from "next/link";
import Navbar from "@/components/Navbar";
import { supabase, Reservation } from "@/lib/supabase";
import { useAuth } from "@/context/AuthContext";

const STATUS_LABEL: Record<string, { label: string; color: string }> = {
  pending:   { label: "Pendiente",   color: "text-yellow-400 bg-yellow-400/10" },
  accepted:  { label: "Aceptado",    color: "text-blue-400 bg-blue-400/10" },
  confirmed: { label: "Confirmado",  color: "text-brand-green bg-brand-green/10" },
  rejected:  { label: "Rechazado",   color: "text-red-400 bg-red-400/10" },
  cancelled: { label: "Cancelado",   color: "text-red-400 bg-red-400/10" },
  completed: { label: "Completado",  color: "text-brand-green bg-brand-green/10" },
};

const PAY_LABEL: Record<string, string> = {
  pending:       "Sin pago",
  deposit_paid:  "Anticipo pagado",
  fully_paid:    "Pagado completo",
};

export default function ClientDashboard() {
  const { profile, loading } = useAuth();
  const router = useRouter();

  const [reservations, setReservations] = useState<Reservation[]>([]);
  const [fetching,     setFetching]     = useState(true);

  useEffect(() => {
    if (loading) return;
    if (!profile) { router.push("/login"); return; }
    if (profile.role !== "client") { router.replace("/dashboard"); return; }

    supabase
      .from("reservations")
      .select(
        "id, group_id, client_id, event_date, event_time, status, payment_status, total_price, deposit_amount, created_at, groups(name, profile_image)"
      )
      .eq("client_id", profile.id)
      .order("event_date", { ascending: false })
      .limit(20)
      .then(({ data }) => {
        setReservations((data as unknown as Reservation[]) ?? []);
        setFetching(false);
      });
  }, [profile, loading, router]);

  const upcoming = reservations.filter(
    (r) =>
      ["pending", "accepted", "confirmed"].includes(r.status) &&
      new Date(r.event_date) >= new Date()
  );
  const past = reservations.filter(
    (r) => r.status === "completed" || new Date(r.event_date) < new Date()
  );

  if (loading || fetching) {
    return (
      <div className="min-h-screen bg-brand-bg">
        <Navbar />
        <div className="flex min-h-[60vh] items-center justify-center">
          <div className="h-10 w-10 animate-spin rounded-full border-2 border-brand-border border-t-brand-green" />
        </div>
      </div>
    );
  }

  return (
    <div className="min-h-screen bg-brand-bg">
      <Navbar />
      <main className="mx-auto max-w-5xl px-4 pb-16 pt-24 sm:px-6 lg:px-8">
        {/* Header */}
        <div className="mb-8 flex flex-wrap items-center justify-between gap-4">
          <div>
            <h1 className="text-2xl font-extrabold text-white">
              Hola, {profile?.name?.split(" ")[0]} 👋
            </h1>
            <p className="text-sm text-brand-muted">Tu panel de reservas</p>
          </div>
          <Link
            href="/grupos"
            className="rounded-xl bg-brand-green px-5 py-2.5 text-sm font-bold text-black transition-colors hover:bg-brand-green2"
          >
            + Contratar grupo
          </Link>
        </div>

        {/* Stats */}
        <div className="mb-8 grid grid-cols-3 gap-4">
          {[
            { val: reservations.length,              label: "Total reservas" },
            { val: upcoming.length,                  label: "Próximos eventos" },
            { val: past.filter(r => r.status === "completed").length, label: "Completados" },
          ].map((s) => (
            <div key={s.label} className="rounded-2xl border border-brand-border bg-brand-card p-5 text-center">
              <p className="text-3xl font-extrabold text-brand-green">{s.val}</p>
              <p className="mt-1 text-xs text-brand-muted">{s.label}</p>
            </div>
          ))}
        </div>

        {/* Upcoming */}
        <section className="mb-8">
          <h2 className="mb-4 text-lg font-bold text-white">Próximos eventos</h2>
          {upcoming.length === 0 ? (
            <div className="rounded-2xl border border-brand-border bg-brand-card p-8 text-center">
              <p className="text-3xl">🎵</p>
              <p className="mt-3 font-semibold text-white">Sin eventos próximos</p>
              <p className="mt-1 text-sm text-brand-muted">
                ¿Tienes un evento? Encuentra tu grupo ideal.
              </p>
              <Link
                href="/grupos"
                className="mt-4 inline-block rounded-xl bg-brand-green px-5 py-2 text-sm font-bold text-black"
              >
                Explorar grupos
              </Link>
            </div>
          ) : (
            <div className="space-y-3">
              {upcoming.map((r) => (
                <ReservationCard key={r.id} reservation={r} />
              ))}
            </div>
          )}
        </section>

        {/* History */}
        {past.length > 0 && (
          <section>
            <h2 className="mb-4 text-lg font-bold text-white">Historial</h2>
            <div className="space-y-3">
              {past.map((r) => (
                <ReservationCard key={r.id} reservation={r} />
              ))}
            </div>
          </section>
        )}
      </main>
    </div>
  );
}

function ReservationCard({ reservation: r }: { reservation: Reservation }) {
  const statusCfg = STATUS_LABEL[r.status] ?? { label: r.status, color: "text-brand-muted bg-brand-card2" };

  return (
    <div className="flex flex-wrap items-center gap-4 rounded-2xl border border-brand-border bg-brand-card p-5">
      <div className="flex h-12 w-12 shrink-0 items-center justify-center rounded-xl bg-brand-card2 text-2xl">
        🎵
      </div>
      <div className="flex-1 min-w-0">
        <p className="font-semibold text-white truncate">
          {(r.groups as { name: string } | null)?.name ?? "Grupo"}
        </p>
        <p className="text-sm text-brand-muted">
          {new Date(r.event_date).toLocaleDateString("es-MX", {
            weekday: "short", year: "numeric", month: "short", day: "numeric",
          })}
          {r.event_time ? ` · ${r.event_time}` : ""}
        </p>
      </div>
      <div className="flex flex-col items-end gap-1.5">
        <span className={`rounded-full px-2.5 py-0.5 text-xs font-medium ${statusCfg.color}`}>
          {statusCfg.label}
        </span>
        <span className="text-xs text-brand-muted">
          {PAY_LABEL[r.payment_status] ?? r.payment_status}
        </span>
        <span className="text-sm font-bold text-white">
          ${r.total_price.toLocaleString()} MXN
        </span>
      </div>
    </div>
  );
}
