"use client";

import { useEffect, useState } from "react";
import { useParams } from "next/navigation";
import Image from "next/image";
import Link from "next/link";
import Navbar from "@/components/Navbar";
import Footer from "@/components/Footer";
import { supabase, Group } from "@/lib/supabase";

interface Review {
  id:         string;
  rating:     number;
  comment:    string | null;
  created_at: string;
  profiles:   { full_name: string } | null;
}

interface Post {
  id:         string;
  caption:    string | null;
  created_at: string;
  photos:     { id: string; url: string; position: number }[];
}

interface VideoItem {
  id:  string;
  url: string;
}

export default function GroupDetailPage() {
  const { id }   = useParams<{ id: string }>();

  const [group,   setGroup]   = useState<Group | null>(null);
  const [reviews, setReviews] = useState<Review[]>([]);
  const [reviewIdx, setReviewIdx] = useState(0);
  const [posts,   setPosts]   = useState<Post[]>([]);
  const [videos,  setVideos]  = useState<VideoItem[]>([]);
  const [openPost, setOpenPost] = useState<Post | null>(null);
  const [loading, setLoading] = useState(true);
  const [showAppModal, setShowAppModal] = useState(false);

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
        // Hallazgo real (2026-09-18): "reviews" tiene DOS foreign keys hacia
        // profiles vía client_id (fk_reviews_client_profile Y
        // reviews_client_id_fkey, mismo campo) — un embed "profiles(...)" sin
        // especificar cuál usar es ambiguo para PostgREST y la consulta
        // fallaba en silencio (nunca llegaban las reseñas, aunque
        // total_reviews sí las contaba bien).
        .select("id, rating, comment, created_at, profiles!reviews_client_id_fkey(full_name)")
        .eq("group_id", id)
        .order("created_at", { ascending: false })
        .limit(10),
      // Publicaciones (fotos de eventos reales) — petición real: "quiero
      // que se vean las publicaciones si es que tiene el grupo". Mismo
      // patrón que FeedScreen de la app: group_event_posts + sus fotos,
      // solo las aprobadas (política pública ya lo permite para anon).
      supabase
        .from("group_event_posts")
        .select("id, caption, created_at, photos:group_event_photos(id, url, position)")
        .eq("group_id", id)
        .eq("status", "approved")
        .order("created_at", { ascending: false })
        .limit(12),
      // Videos del perfil — petición real: "me gustaría que salgan los
      // videos de los grupos en la web". Mismo criterio que GroupDetailScreen
      // de la app: el video legado (groups.promo_video) primero, luego el
      // carrusel (group_videos), solo los aprobados.
      supabase
        .from("group_videos")
        .select("id, url")
        .eq("group_id", id)
        .eq("status", "approved")
        .order("position", { ascending: true }),
    ]).then(([{ data: g }, { data: r }, { data: p }, { data: v }]) => {
      if (g) setGroup(g as Group);
      if (r) setReviews(r as unknown as Review[]);
      if (p) setPosts(
        (p as any[]).map((post) => ({
          ...post,
          photos: (post.photos ?? []).slice().sort((a: any, b: any) => a.position - b.position),
        })) as Post[]
      );
      const legacy: VideoItem[] = (g as any)?.promo_video && (g as any)?.video_status === "approved"
        ? [{ id: "legacy", url: (g as any).promo_video }]
        : [];
      setVideos([...legacy, ...((v as VideoItem[]) ?? [])]);
      setLoading(false);
    });
  }, [id]);

  // Carrusel de reseñas — petición real: "quiero que las reseñas salgan
  // como un carrusel en la web". Una a la vez, rota sola cada 6s, con
  // flechas y puntos para moverse a mano (mismo criterio que el banner de
  // anuncios en /grupos, que ya rota solo con un intervalo + índice).
  useEffect(() => {
    if (reviews.length <= 1) return;
    const t = setInterval(() => setReviewIdx((i) => (i + 1) % reviews.length), 6000);
    return () => clearInterval(t);
  }, [reviews.length]);

  // Cotizar y contratar de verdad (formulario, precio, pago) solo existe en
  // la app móvil por ahora — el botón de aquí nunca debe fingir que "ya
  // contrató" en la web (antes mandaba a /dashboard/cliente?booking=... que
  // no hacía absolutamente nada con ese parámetro).
  const handleContratar = () => setShowAppModal(true);

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
          <p className="text-2xl font-bold text-white">Proveedor no encontrado</p>
          <Link href="/grupos" className="text-brand-green underline">
            Ver todos los proveedores
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
          <Link href="/grupos" className="hover:text-white">Proveedores</Link>
          <span>/</span>
          <span className="text-white">{group.name}</span>
        </nav>

        <div className="grid gap-8 lg:grid-cols-3">
          {/* Left: main content */}
          <div className="lg:col-span-2">
            {/* Cover */}
            <div className="relative mb-6 h-72 w-full overflow-hidden rounded-3xl bg-brand-card sm:h-96">
              {group.profile_image ? (
                <Image src={group.profile_image} alt={group.name} fill className="object-cover" priority />
              ) : (
                <div className="flex h-full w-full items-center justify-center text-7xl opacity-20">🎵</div>
              )}
              <div className="absolute inset-0 bg-gradient-to-t from-black/75 via-black/10 to-transparent" />
              <div className="absolute left-5 top-5 flex gap-2">
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
              {/* Nombre/ciudad sobrepuestos — un solo golpe de vista, sin
                  repetir el título dos veces (antes iba aparte, debajo). */}
              <div className="absolute bottom-0 left-0 right-0 p-6 sm:p-7">
                <h1 className="text-3xl font-extrabold text-white drop-shadow-sm sm:text-4xl">{group.name}</h1>
                <div className="mt-1.5 flex flex-wrap items-center gap-3 text-sm text-white/80">
                  {group.city && <span>📍 {group.city}</span>}
                  {group.genre && <span>🎵 {group.genre}</span>}
                </div>
              </div>
            </div>

            {/* Barra de confianza — calificación, reseñas y trayectoria real
                (total_eventos_completados no se mostraba en ningún lado de
                la web, siendo la mejor prueba de que el grupo sí cumple). */}
            <div className="mb-8 flex flex-wrap gap-3">
              <div className="flex items-center gap-3 rounded-2xl border border-brand-border bg-brand-card px-5 py-3.5">
                <span className="text-2xl font-extrabold text-white">{(group.rating ?? 0).toFixed(1)}</span>
                <div>
                  <div className="flex gap-0.5">
                    {[1, 2, 3, 4, 5].map((s) => (
                      <span key={s} className={s <= Math.round(group.rating ?? 0) ? "text-yellow-400" : "text-brand-border"}>★</span>
                    ))}
                  </div>
                  <p className="text-[11px] text-brand-muted">{group.total_reviews ?? 0} reseñas</p>
                </div>
              </div>
              {!!group.total_eventos_completados && (
                <div className="flex items-center gap-3 rounded-2xl border border-brand-border bg-brand-card px-5 py-3.5">
                  <span className="text-2xl font-extrabold text-white">{group.total_eventos_completados}</span>
                  <p className="text-[11px] leading-tight text-brand-muted">eventos<br />realizados</p>
                </div>
              )}
              {isVerified && (
                <div className="flex items-center gap-2.5 rounded-2xl border border-brand-green/25 bg-brand-green/10 px-5 py-3.5">
                  <span className="text-xl text-brand-green">✓</span>
                  <p className="text-[11px] leading-tight text-brand-green">Perfil<br />verificado</p>
                </div>
              )}
            </div>

            {/* Description */}
            {group.description && (
              <div className="mb-9 border-t border-brand-border pt-8">
                <h2 className="mb-3 text-lg font-bold text-white">Sobre el grupo</h2>
                <p className="leading-relaxed text-brand-muted">{group.description}</p>
              </div>
            )}

            {/* Videos del perfil — petición real: "me gustaría que salgan
                los videos de los grupos en la web". Sin autoplay a
                propósito (controles nativos, el usuario decide reproducir)
                — mismo criterio ya aprendido con los anuncios: forzar
                autoplay+mute trae su propia clase de bugs de códec/audio. */}
            {videos.length > 0 && (
              <div className="mb-9 border-t border-brand-border pt-8">
                <h2 className="mb-4 text-lg font-bold text-white">
                  Videos <span className="font-normal text-brand-muted">({videos.length})</span>
                </h2>
                <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
                  {videos.map((v) => (
                    <video
                      key={v.id}
                      src={v.url}
                      controls
                      playsInline
                      preload="metadata"
                      className="aspect-video w-full rounded-xl bg-black"
                    />
                  ))}
                </div>
              </div>
            )}

            {/* Publicaciones — fotos de eventos reales que el grupo publicó,
                igual que en su perfil dentro de la app. Petición real:
                "quiero que se vean las publicaciones si es que tiene el
                grupo" — si no tiene ninguna aprobada, la sección no aparece
                (no hay nada falso que mostrar). */}
            {posts.length > 0 && (
              <div className="mb-9 border-t border-brand-border pt-8">
                <h2 className="mb-4 text-lg font-bold text-white">
                  Publicaciones <span className="font-normal text-brand-muted">({posts.length})</span>
                </h2>
                <div className="grid grid-cols-3 gap-1.5 sm:gap-2">
                  {posts.flatMap((post) =>
                    post.photos.slice(0, 1).map((photo) => (
                      <button
                        key={photo.id}
                        onClick={() => setOpenPost(post)}
                        className="group relative aspect-square overflow-hidden rounded-lg bg-brand-card2"
                      >
                        <Image src={photo.url} alt={post.caption ?? group.name} fill className="object-cover transition-transform duration-300 group-hover:scale-105" unoptimized />
                        {post.photos.length > 1 && (
                          <span className="absolute right-1.5 top-1.5 rounded-full bg-black/60 px-1.5 py-0.5 text-[10px] font-bold text-white">
                            +{post.photos.length - 1}
                          </span>
                        )}
                      </button>
                    ))
                  )}
                </div>
              </div>
            )}

            {/* Reseñas — carrusel (petición real 2026-09-19: "quiero que
                las reseñas salgan como un carrusel en la web"). Una tarjeta
                grande tipo testimonio a la vez, rota sola cada 6s (efecto
                de arriba), con flechas y puntos para moverse a mano. */}
            <div className="border-t border-brand-border pt-8">
              <div className="mb-6 flex items-center justify-between">
                <h2 className="text-lg font-bold text-white">Reseñas</h2>
                {reviews.length > 1 && (
                  <div className="flex items-center gap-1.5">
                    <button
                      onClick={() => setReviewIdx((i) => (i - 1 + reviews.length) % reviews.length)}
                      className="flex h-8 w-8 items-center justify-center rounded-full border border-brand-border text-brand-muted hover:border-brand-green/40 hover:text-white"
                      aria-label="Reseña anterior"
                    >
                      ‹
                    </button>
                    <button
                      onClick={() => setReviewIdx((i) => (i + 1) % reviews.length)}
                      className="flex h-8 w-8 items-center justify-center rounded-full border border-brand-border text-brand-muted hover:border-brand-green/40 hover:text-white"
                      aria-label="Siguiente reseña"
                    >
                      ›
                    </button>
                  </div>
                )}
              </div>

              {reviews.length === 0 ? (
                <div className="rounded-xl border border-dashed border-brand-border p-6 text-center">
                  <p className="text-sm text-brand-muted">Aún no hay reseñas — sé el primero en contratar y calificar.</p>
                </div>
              ) : (() => {
                const r = reviews[reviewIdx % reviews.length];
                const initials = (r.profiles?.full_name ?? "Cliente")
                  .split(" ").filter(Boolean).slice(0, 2).map((w) => w[0]?.toUpperCase()).join("");
                return (
                  <>
                    <div className="relative overflow-hidden rounded-2xl border border-brand-border bg-brand-card p-8 sm:p-10">
                      <span className="pointer-events-none absolute left-6 top-2 font-serif text-8xl leading-none text-brand-green/10">&ldquo;</span>
                      <div className="relative flex min-h-[168px] flex-col justify-between gap-6">
                        <div>
                          <div className="mb-4 flex gap-0.5 text-yellow-400">
                            {[1, 2, 3, 4, 5].map((s) => (
                              <span key={s} className={s <= r.rating ? "" : "text-brand-border"}>★</span>
                            ))}
                          </div>
                          <p className="text-lg leading-relaxed text-white">
                            {r.comment ?? "Sin comentario escrito."}
                          </p>
                        </div>
                        <div className="flex items-center gap-3">
                          <div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-full bg-brand-green/15 text-xs font-bold text-brand-green">
                            {initials || "C"}
                          </div>
                          <div>
                            <p className="text-sm font-semibold text-white">{r.profiles?.full_name ?? "Cliente"}</p>
                            <p className="text-[11px] text-brand-muted">
                              {new Date(r.created_at).toLocaleDateString("es-MX", { year: "numeric", month: "long", day: "numeric" })}
                            </p>
                          </div>
                        </div>
                      </div>
                    </div>
                    {reviews.length > 1 && (
                      <div className="mt-4 flex justify-center gap-1.5">
                        {reviews.map((_, i) => (
                          <button
                            key={i}
                            onClick={() => setReviewIdx(i)}
                            aria-label={`Ver reseña ${i + 1}`}
                            className={`h-1.5 rounded-full transition-all ${
                              i === reviewIdx % reviews.length ? "w-5 bg-brand-green" : "w-1.5 bg-brand-border"
                            }`}
                          />
                        ))}
                      </div>
                    )}
                  </>
                );
              })()}
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
                {group.price_from ? (
                  <>
                    <p className="text-3xl font-extrabold text-brand-green">
                      ${group.price_from.toLocaleString("es-MX")}
                    </p>
                    <p className="text-xs text-brand-muted">MXN · por evento</p>
                  </>
                ) : (
                  <p className="text-sm font-semibold text-brand-green">Precio a cotizar</p>
                )}
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

      {showAppModal && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/70 p-4" onClick={() => setShowAppModal(false)}>
          <div onClick={(e) => e.stopPropagation()} className="w-full max-w-sm rounded-2xl border border-brand-border bg-brand-card p-6 text-center">
            <p className="mb-2 text-3xl">📱</p>
            <h3 className="mb-2 text-lg font-bold text-white">Contrata desde la app</h3>
            <p className="mb-5 text-sm text-brand-muted">
              Cotizar, negociar y pagar a {group?.name ?? "este grupo"} se hace desde la app de Daricefy —
              ahí está todo el proceso protegido (anticipo, confirmación y soporte).
            </p>
            <button
              onClick={() => setShowAppModal(false)}
              className="w-full rounded-xl bg-brand-green py-3 text-sm font-bold text-black"
            >
              Entendido
            </button>
          </div>
        </div>
      )}

      {/* Lightbox de una publicación — carrusel simple con las fotos + pie de foto */}
      {openPost && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/85 p-4" onClick={() => setOpenPost(null)}>
          <div onClick={(e) => e.stopPropagation()} className="w-full max-w-lg overflow-hidden rounded-2xl border border-brand-border bg-brand-card">
            <div className="grid grid-cols-1 gap-0.5 sm:grid-cols-2">
              {openPost.photos.map((photo) => (
                <div key={photo.id} className="relative aspect-square bg-brand-card2">
                  <Image src={photo.url} alt={openPost.caption ?? group.name} fill className="object-cover" unoptimized />
                </div>
              ))}
            </div>
            <div className="p-4">
              {openPost.caption && <p className="mb-2 text-sm leading-relaxed text-white">{openPost.caption}</p>}
              <p className="text-[10px] text-brand-muted">
                {new Date(openPost.created_at).toLocaleDateString("es-MX", { year: "numeric", month: "long", day: "numeric" })}
              </p>
            </div>
            <button onClick={() => setOpenPost(null)} className="w-full border-t border-brand-border py-3 text-sm font-medium text-brand-muted hover:text-white">
              Cerrar
            </button>
          </div>
        </div>
      )}

      <Footer />
    </div>
  );
}
