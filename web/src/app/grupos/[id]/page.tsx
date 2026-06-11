"use client";

import { useEffect, useState } from "react";
import { useParams, useRouter } from "next/navigation";
import Image from "next/image";
import Link from "next/link";
import Navbar from "@/components/Navbar";
import Footer from "@/components/Footer";
import { supabase, Group } from "@/lib/supabase";
import { useAuth } from "@/context/AuthContext";

interface Review {
  id:         string;
  rating:     number;
  comment:    string | null;
  created_at: string;
  profiles:   { name: string } | null;
}

export default function GroupDetailPage() {
  const { id }   = useParams<{ id: string }>();
  const router   = useRouter();
  const { profile } = useAuth();

  const [group,   setGroup]   = useState<Group | null>(null);
  const [reviews, setReviews] = useState<Review[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    if (!id) return;

    Promise.all([
      supabase
        .from("groups")
        .select("*")
        .eq("id", id)
        .single(),
      supabase
        .from("reviews")
        .select("id, rating, comment, created_at, profiles(name)")
        .eq("group_id", id)
        .order("created_at", { ascending: false })
        .limit(10),
    ]).then(([{ data: g }, { data: r }]) => {
      if (g) setGroup(g as Group);
      if (r) setReviews(r as unknown as Review[]);
      setLoading(false);
    });
  }, [id]);

  const handleContratar = () => {
    if (!profile) {
      router.push(`/login?redirect=/grupos/${id}`);
      return;
    }
    router.push(`/dashboard/cliente?booking=${id}`);
  };

  if (loading) {
    return (
      <div className="min-h-screen bg-brand-bg">
        <Navbar />
        <div className="flex min-h-[60vh] items-center justify-center">
          <div className="h-10 w-10 animate-spin rounded-full border-2 border-brand-border border-t-brand-green" />
        </div>
      </div>
    );
  }

  if (!group) {
    return (
      <div className="min-h-screen bg-brand-bg">
        <Navbar />
        <div className="flex min-h-[60vh] flex-col items-center justify-center gap-4 text-center">
          <p className="text-2xl font-bold text-white">Grupo no encontrado</p>
          <Link href="/grupos" className="text-brand-green underline">
            Ver todos los grupos
          </Link>
        </div>
      </div>
    );
  }

  const isVerified = group.is_verified;
  const isBidActive =
    (group.bid_amount ?? 0) > 0 &&
    group.bid_ends_at &&
    new Date(group.bid_ends_at).getTime() > Date.now();

  return (
    <div className="min-h-screen bg-brand-bg">
      <Navbar />

      <main className="mx-auto max-w-5xl px-4 pb-20 pt-24 sm:px-6 lg:px-8">
        {/* Breadcrumb */}
        <nav className="mb-6 flex items-center gap-2 text-sm text-brand-muted">
          <Link href="/grupos" className="hover:text-white">Grupos</Link>
          <span>/</span>
          <span className="text-white">{group.name}</span>
        </nav>

        <div className="grid gap-8 lg:grid-cols-3">
          {/* Left: main content */}
          <div className="lg:col-span-2">
            {/* Cover */}
            <div className="relative mb-6 h-64 w-full overflow-hidden rounded-2xl bg-brand-card sm:h-80">
              {group.cover_image ? (
                <Image src={group.cover_image} alt={group.name} fill className="object-cover" />
              ) : (
                <div className="flex h-full w-full items-center justify-center text-7xl opacity-20">🎵</div>
              )}
              <div className="absolute inset-0 bg-gradient-to-t from-black/60 to-transparent" />
              <div className="absolute bottom-4 left-4 flex gap-2">
                {isVerified && (
                  <span className="rounded-full bg-brand-green/90 px-3 py-1 text-xs font-bold text-black">
                    ✓ Verificado
                  </span>
                )}
                {isBidActive && (
                  <span className="rounded-full bg-orange-500/90 px-3 py-1 text-xs font-bold text-white">
                    🔥 Destacado
                  </span>
                )}
              </div>
            </div>

            {/* Name + rating */}
            <div className="mb-4 flex flex-wrap items-start justify-between gap-4">
              <div>
                <h1 className="text-3xl font-extrabold text-white">{group.name}</h1>
                <div className="mt-1 flex flex-wrap items-center gap-3 text-sm text-brand-muted">
                  {group.city && <span>📍 {group.city}</span>}
                  {group.category && <span>🎵 {group.category}</span>}
                  {group.genre && <span>· {group.genre}</span>}
                </div>
              </div>
              <div className="flex items-center gap-1.5 rounded-xl bg-brand-card px-4 py-2">
                <span className="text-2xl font-extrabold text-white">
                  {(group.rating ?? 0).toFixed(1)}
                </span>
                <div>
                  <div className="flex gap-0.5">
                    {[1, 2, 3, 4, 5].map((s) => (
                      <span
                        key={s}
                        className={s <= Math.round(group.rating ?? 0) ? "text-yellow-400" : "text-brand-border"}
                      >
                        ★
                      </span>
                    ))}
                  </div>
                  <p className="text-[10px] text-brand-muted">
                    {group.review_count ?? 0} reseñas
                  </p>
                </div>
              </div>
            </div>

            {/* Description */}
            {group.description && (
              <div className="mb-8">
                <h2 className="mb-3 text-lg font-bold text-white">Sobre el grupo</h2>
                <p className="leading-relaxed text-brand-muted">{group.description}</p>
              </div>
            )}

            {/* Reviews */}
            <div>
              <h2 className="mb-4 text-lg font-bold text-white">
                Reseñas {reviews.length > 0 && `(${reviews.length})`}
              </h2>
              {reviews.length === 0 ? (
                <p className="text-sm text-brand-muted">Aún no hay reseñas.</p>
              ) : (
                <div className="space-y-4">
                  {reviews.map((r) => (
                    <div
                      key={r.id}
                      className="rounded-xl border border-brand-border bg-brand-card p-4"
                    >
                      <div className="mb-2 flex items-center justify-between">
                        <p className="text-sm font-semibold text-white">
                          {r.profiles?.name ?? "Cliente"}
                        </p>
                        <div className="flex gap-0.5 text-yellow-400">
                          {[1, 2, 3, 4, 5].map((s) => (
                            <span key={s} className={s <= r.rating ? "" : "opacity-20"}>★</span>
                          ))}
                        </div>
                      </div>
                      {r.comment && (
                        <p className="text-sm leading-relaxed text-brand-muted">{r.comment}</p>
                      )}
                      <p className="mt-2 text-[10px] text-brand-muted">
                        {new Date(r.created_at).toLocaleDateString("es-MX", {
                          year: "numeric", month: "long", day: "numeric",
                        })}
                      </p>
                    </div>
                  ))}
                </div>
              )}
            </div>
          </div>

          {/* Right: booking card (sticky) */}
          <div className="lg:col-span-1">
            <div className="sticky top-24 rounded-2xl border border-brand-border bg-brand-card p-6">
              {/* Profile pic */}
              {group.profile_image && (
                <div className="mb-4 flex justify-center">
                  <div className="relative h-20 w-20 overflow-hidden rounded-full border-2 border-brand-green">
                    <Image src={group.profile_image} alt={group.name} fill className="object-cover" />
                  </div>
                </div>
              )}

              <h3 className="mb-1 text-center text-lg font-bold text-white">{group.name}</h3>
              {group.city && (
                <p className="mb-4 text-center text-sm text-brand-muted">📍 {group.city}</p>
              )}

              <div className="mb-4 rounded-xl bg-brand-card2 p-4 text-center">
                <p className="text-xs text-brand-muted">Precio base</p>
                <p className="text-3xl font-extrabold text-brand-green">
                  ${(group.base_price ?? 0).toLocaleString()}
                </p>
                <p className="text-xs text-brand-muted">MXN · por evento</p>
              </div>

              <button
                onClick={handleContratar}
                className="mb-3 w-full rounded-xl bg-brand-green py-3.5 text-sm font-bold text-black shadow-lg shadow-brand-green/20 transition-all hover:bg-brand-green2 active:scale-95"
              >
                Contratar ahora
              </button>

              <p className="text-center text-xs text-brand-muted">
                Sin compromisos · Pago seguro · Anticipo protegido
              </p>

              <div className="mt-6 space-y-2">
                {[
                  "✓ Disponibilidad en tiempo real",
                  "✓ Confirmación inmediata",
                  "✓ Soporte 24/7",
                ].map((item) => (
                  <p key={item} className="text-xs text-brand-muted">{item}</p>
                ))}
              </div>
            </div>
          </div>
        </div>
      </main>

      <Footer />
    </div>
  );
}
