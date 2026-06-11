"use client";

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import Navbar from "@/components/Navbar";
import { supabase } from "@/lib/supabase";
import { useAuth } from "@/context/AuthContext";

interface TalentJob {
  id:          string;
  event_date:  string;
  event_time:  string | null;
  status:      string;
  total_price: number;
  groups:      { name: string; city: string | null } | null;
}

export default function TalentDashboard() {
  const { profile, loading } = useAuth();
  const router = useRouter();
  const [jobs,     setJobs]     = useState<TalentJob[]>([]);
  const [fetching, setFetching] = useState(true);

  useEffect(() => {
    if (loading) return;
    if (!profile) { router.push("/login"); return; }
    if (profile.role !== "talent") { router.replace("/dashboard"); return; }

    supabase
      .from("job_assignments")
      .select("id, event_date, event_time, status, total_price, groups(name, city)")
      .eq("talent_id", profile.id)
      .order("event_date", { ascending: false })
      .limit(20)
      .then(({ data }) => {
        setJobs((data as unknown as TalentJob[]) ?? []);
        setFetching(false);
      });
  }, [profile, loading, router]);

  const upcoming  = jobs.filter(j => ["accepted","confirmed"].includes(j.status) && new Date(j.event_date) >= new Date());
  const past      = jobs.filter(j => j.status === "completed");

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
      <main className="mx-auto max-w-4xl px-4 pb-16 pt-24 sm:px-6 lg:px-8">
        <div className="mb-8">
          <h1 className="text-2xl font-extrabold text-white">
            Panel de talento
          </h1>
          <p className="text-sm text-brand-muted">
            Hola, {profile?.name?.split(" ")[0]}
          </p>
        </div>

        {/* Stats */}
        <div className="mb-8 grid grid-cols-3 gap-4">
          {[
            { val: upcoming.length, label: "Próximos" },
            { val: past.length,     label: "Completados" },
            { val: jobs.length,     label: "Total" },
          ].map((s) => (
            <div key={s.label} className="rounded-2xl border border-brand-border bg-brand-card p-5 text-center">
              <p className="text-3xl font-extrabold text-brand-green">{s.val}</p>
              <p className="mt-1 text-xs text-brand-muted">{s.label}</p>
            </div>
          ))}
        </div>

        {/* Upcoming */}
        <section className="mb-8">
          <h2 className="mb-4 text-lg font-bold text-white">Eventos asignados</h2>
          {upcoming.length === 0 ? (
            <div className="rounded-2xl border border-brand-border bg-brand-card p-8 text-center">
              <p className="text-3xl">🎤</p>
              <p className="mt-3 font-semibold text-white">Sin eventos próximos</p>
              <p className="mt-1 text-sm text-brand-muted">
                Tu grupo te asignará eventos aquí.
              </p>
            </div>
          ) : (
            <div className="space-y-3">
              {upcoming.map((j) => (
                <div key={j.id} className="flex flex-wrap items-center gap-4 rounded-2xl border border-brand-border bg-brand-card p-5">
                  <div className="flex-1">
                    <p className="font-semibold text-white">
                      {(j.groups as { name: string } | null)?.name ?? "Grupo"}
                    </p>
                    <p className="text-sm text-brand-muted">
                      {new Date(j.event_date).toLocaleDateString("es-MX", {
                        weekday: "short", month: "short", day: "numeric",
                      })}
                      {j.event_time ? ` · ${j.event_time}` : ""}
                      {(j.groups as { city: string | null } | null)?.city
                        ? ` · ${(j.groups as { city: string | null }).city}`
                        : ""}
                    </p>
                  </div>
                  <span className="rounded-full bg-brand-green/10 px-2.5 py-0.5 text-xs font-medium text-brand-green">
                    {j.status}
                  </span>
                </div>
              ))}
            </div>
          )}
        </section>

        {/* History */}
        {past.length > 0 && (
          <section>
            <h2 className="mb-4 text-lg font-bold text-white">Historial</h2>
            <div className="space-y-3">
              {past.map((j) => (
                <div key={j.id} className="flex flex-wrap items-center gap-4 rounded-2xl border border-brand-border bg-brand-card p-4 opacity-75">
                  <div className="flex-1">
                    <p className="text-sm font-semibold text-white">
                      {(j.groups as { name: string } | null)?.name ?? "Grupo"}
                    </p>
                    <p className="text-xs text-brand-muted">
                      {new Date(j.event_date).toLocaleDateString("es-MX", {
                        month: "short", day: "numeric", year: "numeric",
                      })}
                    </p>
                  </div>
                  <span className="rounded-full bg-brand-green/10 px-2.5 py-0.5 text-xs text-brand-green">
                    ✓ Completado
                  </span>
                </div>
              ))}
            </div>
          </section>
        )}
      </main>
    </div>
  );
}
