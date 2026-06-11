"use client";

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import Link from "next/link";
import Navbar from "@/components/Navbar";
import { supabase } from "@/lib/supabase";
import { useAuth } from "@/context/AuthContext";

interface GroupStats {
  id:           string;
  name:         string;
  city:         string | null;
  rating:       number | null;
  review_count: number | null;
  base_price:   number | null;
  is_verified:  boolean | null;
  referral_code: string | null;
}

interface Event {
  id:             string;
  event_date:     string;
  event_time:     string | null;
  status:         string;
  payment_status: string;
  total_price:    number;
  profiles:       { name: string } | null;
}

const STATUS_COLOR: Record<string, string> = {
  pending:   "text-yellow-400 bg-yellow-400/10",
  accepted:  "text-blue-400 bg-blue-400/10",
  confirmed: "text-brand-green bg-brand-green/10",
  rejected:  "text-red-400 bg-red-400/10",
  cancelled: "text-red-400 bg-red-400/10",
  completed: "text-brand-green bg-brand-green/10",
};

export default function GroupDashboard() {
  const { profile, loading } = useAuth();
  const router = useRouter();

  const [group,   setGroup]   = useState<GroupStats | null>(null);
  const [events,  setEvents]  = useState<Event[]>([]);
  const [fetching, setFetching] = useState(true);

  useEffect(() => {
    if (loading) return;
    if (!profile) { router.push("/login"); return; }
    if (profile.role !== "group") { router.replace("/dashboard"); return; }

    Promise.all([
      supabase
        .from("groups")
        .select("id, name, city, rating, review_count, base_price, is_verified, referral_code")
        .eq("owner_id", profile.id)
        .single(),
      supabase
        .from("reservations")
        .select(
          "id, event_date, event_time, status, payment_status, total_price, profiles(name)"
        )
        .eq("group_id",
          // We'll get group_id after fetching group, so just fetch all and filter
          // Workaround: use a subquery via RPC is better, but for now fetch by owner_id via group
          "00000000-0000-0000-0000-000000000000" // placeholder, will be replaced below
        ),
    ]).then(([{ data: g }]) => {
      if (!g) { setFetching(false); return; }
      setGroup(g as GroupStats);

      // Now fetch events for this group
      supabase
        .from("reservations")
        .select("id, event_date, event_time, status, payment_status, total_price, profiles(name)")
        .eq("group_id", (g as GroupStats).id)
        .order("event_date", { ascending: false })
        .limit(20)
        .then(({ data: evts }) => {
          setEvents((evts as unknown as Event[]) ?? []);
          setFetching(false);
        });
    });
  }, [profile, loading, router]);

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

  const pending   = events.filter(e => e.status === "pending");
  const upcoming  = events.filter(e => ["accepted","confirmed"].includes(e.status) && new Date(e.event_date) >= new Date());
  const completed = events.filter(e => e.status === "completed");
  const totalEarned = completed.reduce((s, e) => s + (e.total_price ?? 0), 0);

  return (
    <div className="min-h-screen bg-brand-bg">
      <Navbar />
      <main className="mx-auto max-w-5xl px-4 pb-16 pt-24 sm:px-6 lg:px-8">

        {/* Header */}
        <div className="mb-8 flex flex-wrap items-start justify-between gap-4">
          <div>
            <h1 className="text-2xl font-extrabold text-white">
              {group?.name ?? "Mi Grupo"}
            </h1>
            <div className="mt-1 flex flex-wrap items-center gap-3 text-sm text-brand-muted">
              {group?.city && <span>📍 {group.city}</span>}
              {group?.is_verified && (
                <span className="rounded-full bg-brand-green/15 px-2.5 py-0.5 text-xs font-medium text-brand-green">
                  ✓ Verificado
                </span>
              )}
              {group?.rating && (
                <span className="text-yellow-400">★ {group.rating.toFixed(1)} ({group.review_count ?? 0})</span>
              )}
            </div>
          </div>
          <Link
            href={`/grupos/${group?.id}`}
            className="rounded-xl border border-brand-border px-4 py-2 text-sm font-medium text-brand-muted transition-colors hover:border-brand-green hover:text-white"
            target="_blank"
          >
            Ver perfil público →
          </Link>
        </div>

        {/* Stats */}
        <div className="mb-8 grid grid-cols-2 gap-4 sm:grid-cols-4">
          {[
            { val: pending.length,               label: "Solicitudes",  color: "text-yellow-400" },
            { val: upcoming.length,              label: "Próx. eventos", color: "text-blue-400" },
            { val: completed.length,             label: "Completados",  color: "text-brand-green" },
            { val: `$${totalEarned.toLocaleString()}`, label: "Total ganado", color: "text-brand-green" },
          ].map((s) => (
            <div key={s.label} className="rounded-2xl border border-brand-border bg-brand-card p-5 text-center">
              <p className={`text-2xl font-extrabold ${s.color}`}>{s.val}</p>
              <p className="mt-1 text-xs text-brand-muted">{s.label}</p>
            </div>
          ))}
        </div>

        {/* Referral card */}
        {group?.referral_code && (
          <div className="mb-8 rounded-2xl border border-brand-green/20 bg-brand-green/5 p-5">
            <div className="flex flex-wrap items-center justify-between gap-4">
              <div>
                <p className="text-sm font-semibold text-brand-green">🎁 Tu código de referido</p>
                <p className="mt-1 text-xs text-brand-muted">
                  Compártelo y gana $100 por cada cliente que reserve su primer evento
                </p>
              </div>
              <div className="flex items-center gap-2 rounded-xl border border-brand-green/30 bg-brand-bg px-4 py-2">
                <span className="font-mono text-lg font-bold text-brand-green">
                  {group.referral_code}
                </span>
                <button
                  onClick={() => navigator.clipboard.writeText(group.referral_code!)}
                  className="text-brand-muted hover:text-white"
                  title="Copiar"
                >
                  📋
                </button>
              </div>
            </div>
          </div>
        )}

        {/* Pending requests */}
        {pending.length > 0 && (
          <section className="mb-8">
            <h2 className="mb-4 flex items-center gap-2 text-lg font-bold text-white">
              Solicitudes pendientes
              <span className="rounded-full bg-yellow-400/15 px-2.5 py-0.5 text-xs font-bold text-yellow-400">
                {pending.length}
              </span>
            </h2>
            <div className="space-y-3">
              {pending.map((e) => <EventRow key={e.id} event={e} />)}
            </div>
          </section>
        )}

        {/* Upcoming */}
        <section className="mb-8">
          <h2 className="mb-4 text-lg font-bold text-white">Próximos eventos</h2>
          {upcoming.length === 0 ? (
            <div className="rounded-2xl border border-brand-border bg-brand-card p-6 text-center">
              <p className="text-sm text-brand-muted">Sin eventos próximos confirmados.</p>
            </div>
          ) : (
            <div className="space-y-3">
              {upcoming.map((e) => <EventRow key={e.id} event={e} />)}
            </div>
          )}
        </section>

        {/* History */}
        {completed.length > 0 && (
          <section>
            <h2 className="mb-4 text-lg font-bold text-white">Historial de eventos</h2>
            <div className="space-y-3">
              {completed.map((e) => <EventRow key={e.id} event={e} />)}
            </div>
          </section>
        )}
      </main>
    </div>
  );
}

function EventRow({ event: e }: { event: Event }) {
  const color = STATUS_COLOR[e.status] ?? "text-brand-muted bg-brand-card2";
  return (
    <div className="flex flex-wrap items-center gap-4 rounded-2xl border border-brand-border bg-brand-card p-5">
      <div className="flex-1 min-w-0">
        <p className="font-semibold text-white">
          {(e.profiles as { name: string } | null)?.name ?? "Cliente"}
        </p>
        <p className="text-sm text-brand-muted">
          {new Date(e.event_date).toLocaleDateString("es-MX", {
            weekday: "short", year: "numeric", month: "short", day: "numeric",
          })}
          {e.event_time ? ` · ${e.event_time}` : ""}
        </p>
      </div>
      <div className="flex flex-col items-end gap-1">
        <span className={`rounded-full px-2.5 py-0.5 text-xs font-medium ${color}`}>
          {e.status}
        </span>
        <span className="text-sm font-bold text-white">
          ${e.total_price.toLocaleString()} MXN
        </span>
      </div>
    </div>
  );
}
