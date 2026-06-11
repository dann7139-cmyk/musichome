"use client";

import { useState, useEffect, useCallback } from "react";
import Link from "next/link";
import Image from "next/image";
import Navbar from "@/components/Navbar";
import Footer from "@/components/Footer";
import { supabase, Group } from "@/lib/supabase";

const CITIES = [
  "Guadalajara", "Ciudad de México", "Monterrey", "Puebla",
  "Tijuana", "León", "Querétaro", "San Luis Potosí",
];

const CATEGORIES = [
  "Banda", "Trio", "Mariachi", "DJ", "Cuarteto", "Solista", "Percusión", "Jazz",
];

interface BannerAd {
  id: string;
  title: string;
  subtitle: string | null;
  tag: string | null;
  media_url: string | null;
  media_type: string | null;
  button_text: string | null;
  cta_url: string | null;
}

// ── Banner Ad Component ──────────────────────────────────────────────────────
function BannerAdCard({ ad }: { ad: BannerAd }) {
  return (
    <div className="relative mb-6 overflow-hidden rounded-2xl border border-brand-green/20 bg-gradient-to-r from-brand-green/8 to-blue-500/5">
      {ad.media_url && ad.media_type === "image" && (
        <div className="absolute inset-0 opacity-15">
          <Image src={ad.media_url} alt={ad.title} fill className="object-cover" unoptimized />
        </div>
      )}
      <div className="relative flex items-center gap-4 px-5 py-4">
        <div className="flex-1 min-w-0">
          <span className="mb-1 inline-block rounded-full border border-brand-green/40 bg-brand-green/10 px-2 py-0.5 text-[10px] font-bold uppercase tracking-wider text-brand-green">
            {ad.tag ?? "Publicidad"}
          </span>
          <p className="truncate font-bold text-white">{ad.title}</p>
          {ad.subtitle && (
            <p className="truncate text-sm text-brand-muted">{ad.subtitle}</p>
          )}
        </div>
        {ad.cta_url && (
          <a
            href={ad.cta_url}
            target="_blank"
            rel="noopener noreferrer"
            className="shrink-0 rounded-xl bg-brand-green px-4 py-2.5 text-sm font-bold text-black hover:bg-brand-green2"
          >
            {ad.button_text ?? "Ver más"} →
          </a>
        )}
      </div>
    </div>
  );
}

// ── Promo Slot (sin anuncios activos) ────────────────────────────────────────
function PromoSlot() {
  return (
    <Link
      href="/registro?rol=group"
      className="mb-6 flex items-center gap-4 rounded-2xl border border-brand-green/20 bg-brand-green/5 px-5 py-3.5 transition-colors hover:border-brand-green/40"
    >
      <div className="flex-1 min-w-0">
        <span className="text-[10px] font-bold uppercase tracking-wider text-brand-green opacity-70">
          Espacio publicitario
        </span>
        <p className="truncate text-sm font-semibold text-white">
          Promociona tu grupo 🚀
        </p>
        <p className="truncate text-xs text-brand-muted">
          Consigue más eventos · Toca para anunciarte
        </p>
      </div>
      <span className="shrink-0 rounded-xl bg-brand-green/15 px-3 py-2 text-xs font-bold text-brand-green hover:bg-brand-green hover:text-black">
        Anunciarme →
      </span>
    </Link>
  );
}

// ── Group Card ───────────────────────────────────────────────────────────────
function GroupCard({
  group,
  isSponsored,
}: {
  group: Group;
  isSponsored: boolean;
}) {
  const isBidActive =
    (group.bid_amount ?? 0) > 0 &&
    group.bid_ends_at &&
    new Date(group.bid_ends_at).getTime() > Date.now();

  return (
    <Link
      href={`/grupos/${group.id}`}
      className={`group flex flex-col overflow-hidden rounded-2xl border bg-brand-card transition-all hover:-translate-y-0.5 ${
        isSponsored
          ? "border-brand-green/40 shadow-sm shadow-brand-green/10"
          : "border-brand-border hover:border-brand-green/30"
      }`}
    >
      {/* Cover image */}
      <div className="relative h-48 w-full overflow-hidden bg-brand-card2">
        {group.cover_image || group.profile_image ? (
          <Image
            src={group.cover_image ?? group.profile_image!}
            alt={group.name}
            fill
            className="object-cover transition-transform duration-300 group-hover:scale-105"
            unoptimized
          />
        ) : (
          <div className="flex h-full w-full items-center justify-center text-5xl opacity-20">
            🎵
          </div>
        )}
        {/* Badges */}
        <div className="absolute left-3 top-3 flex gap-1.5">
          {group.is_verified && (
            <span className="rounded-full bg-brand-green/90 px-2.5 py-0.5 text-[10px] font-bold text-black">
              ✓ Verificado
            </span>
          )}
          {isSponsored && (
            <span className="rounded-full bg-yellow-400/90 px-2.5 py-0.5 text-[10px] font-bold text-black">
              ⭐ Destacado
            </span>
          )}
          {!isSponsored && isBidActive && (
            <span className="rounded-full bg-orange-500/90 px-2.5 py-0.5 text-[10px] font-bold text-white">
              🔥 Destacado
            </span>
          )}
        </div>
      </div>

      {/* Info */}
      <div className="flex flex-1 flex-col p-4">
        <div className="mb-1 flex items-start justify-between gap-2">
          <h3 className="font-bold text-white line-clamp-1 transition-colors group-hover:text-brand-green">
            {group.name}
          </h3>
          <div className="flex shrink-0 items-center gap-1">
            <span className="text-yellow-400">★</span>
            <span className="text-sm font-medium text-white">
              {(group.rating ?? 0).toFixed(1)}
            </span>
          </div>
        </div>

        <div className="mb-3 flex flex-wrap items-center gap-2">
          {group.city && (
            <span className="text-xs text-brand-muted">📍 {group.city}</span>
          )}
          {group.category && (
            <span className="rounded-full border border-brand-border px-2 py-0.5 text-[10px] text-brand-muted">
              {group.category}
            </span>
          )}
        </div>

        {group.description && (
          <p className="mb-4 text-xs leading-relaxed text-brand-muted line-clamp-2">
            {group.description}
          </p>
        )}

        <div className="mt-auto flex items-center justify-between border-t border-brand-border pt-3">
          <div>
            <p className="text-[10px] text-brand-muted">Desde</p>
            <p className="text-sm font-bold text-brand-green">
              ${(group.base_price ?? 0).toLocaleString("es-MX")} MXN
            </p>
          </div>
          <span className="rounded-lg bg-brand-green/10 px-3 py-1.5 text-xs font-semibold text-brand-green transition-colors group-hover:bg-brand-green group-hover:text-black">
            Ver perfil →
          </span>
        </div>
      </div>
    </Link>
  );
}

// ── Inline ad slot (entre grupos) ────────────────────────────────────────────
function InlineAdCard({ ad }: { ad: BannerAd }) {
  return (
    <div className="col-span-full overflow-hidden rounded-2xl border border-brand-green/15 bg-brand-card">
      <div className="flex items-center gap-4 px-5 py-4">
        {ad.media_url && ad.media_type === "image" && (
          <div className="relative h-14 w-14 shrink-0 overflow-hidden rounded-xl bg-brand-card2">
            <Image src={ad.media_url} alt={ad.title} fill className="object-cover" unoptimized />
          </div>
        )}
        <div className="flex-1 min-w-0">
          <span className="text-[10px] font-bold uppercase tracking-wider text-brand-green opacity-70">
            {ad.tag ?? "Publicidad"}
          </span>
          <p className="truncate text-sm font-semibold text-white">{ad.title}</p>
          {ad.subtitle && (
            <p className="truncate text-xs text-brand-muted">{ad.subtitle}</p>
          )}
        </div>
        {ad.cta_url && (
          <a
            href={ad.cta_url}
            target="_blank"
            rel="noopener noreferrer"
            className="shrink-0 rounded-xl bg-brand-green/15 px-3 py-2 text-xs font-bold text-brand-green hover:bg-brand-green hover:text-black"
          >
            {ad.button_text ?? "Ver más"} →
          </a>
        )}
      </div>
    </div>
  );
}

// ── Main page ────────────────────────────────────────────────────────────────
export default function GruposPage() {
  const [groups,           setGroups]           = useState<Group[]>([]);
  const [bannerAds,        setBannerAds]        = useState<BannerAd[]>([]);
  const [sponsoredIds,     setSponsoredIds]     = useState<Set<string>>(new Set());
  const [loading,          setLoading]          = useState(true);
  const [city,             setCity]             = useState("");
  const [category,         setCategory]         = useState("");
  const [search,           setSearch]           = useState("");
  const [sort,             setSort]             = useState<"rating" | "price_asc" | "price_desc">("rating");
  const [currentAdIndex,   setCurrentAdIndex]   = useState(0);

  // ── Fetch ads + sponsored groups ──────────────────────────────────────────
  const fetchAds = useCallback(async (targetCity: string) => {
    const [{ data: banners }, { data: sponsored }] = await Promise.all([
      supabase.rpc("get_active_banner_ads", { p_city: targetCity || null }),
      supabase.rpc("get_sponsored_group_ids", { p_city: targetCity || null }),
    ]);
    setBannerAds((banners as BannerAd[]) ?? []);
    setSponsoredIds(new Set((sponsored as { group_id: string }[] ?? []).map(s => s.group_id)));
  }, []);

  // ── Fetch groups ──────────────────────────────────────────────────────────
  const fetchGroups = useCallback(async () => {
    setLoading(true);

    let q = supabase
      .from("groups")
      .select(
        "id, name, description, city, genre, category, base_price, rating, review_count, profile_image, cover_image, badges, bid_amount, bid_ends_at, boost_score, is_verified, owner_id"
      )
      .eq("status", "active");

    if (city)     q = q.ilike("city", `%${city}%`);
    if (category) q = q.ilike("category", `%${category}%`);
    if (search)   q = q.ilike("name", `%${search}%`);

    if (sort === "rating")     q = q.order("rating",     { ascending: false, nullsFirst: false });
    if (sort === "price_asc")  q = q.order("base_price", { ascending: true,  nullsFirst: false });
    if (sort === "price_desc") q = q.order("base_price", { ascending: false, nullsFirst: false });

    const { data } = await q.limit(48);
    setGroups((data as Group[]) ?? []);
    setLoading(false);
  }, [city, category, search, sort]);

  useEffect(() => { fetchGroups(); fetchAds(city); }, [fetchGroups, fetchAds, city]);

  // ── Auto-rotate banner ads ────────────────────────────────────────────────
  useEffect(() => {
    if (bannerAds.length <= 1) return;
    const id = setInterval(() => {
      setCurrentAdIndex(i => (i + 1) % bannerAds.length);
    }, 5000);
    return () => clearInterval(id);
  }, [bannerAds.length]);

  // ── Build group list with inline ads every 3 groups ──────────────────────
  const profileAdsToInsert = bannerAds.filter(a => a.media_type !== "video").slice(0, 2);

  function buildGroupRows() {
    const items: { type: "group"; data: Group } | { type: "ad"; data: BannerAd } extends infer T ? T[] : never = [];
    groups.forEach((g, i) => {
      items.push({ type: "group", data: g });
      // Insert inline ad after 3rd and 6th group
      if ((i === 2 || i === 5) && profileAdsToInsert[i === 2 ? 0 : 1]) {
        items.push({ type: "ad", data: profileAdsToInsert[i === 2 ? 0 : 1] });
      }
    });
    return items;
  }

  const rows = buildGroupRows();
  const activeBanner = bannerAds.length > 0 ? bannerAds[currentAdIndex % bannerAds.length] : null;

  return (
    <div className="min-h-screen bg-brand-bg">
      <Navbar />

      <main className="mx-auto max-w-7xl px-4 pb-16 pt-24 sm:px-6 lg:px-8">

        {/* Header */}
        <div className="mb-8">
          <h1 className="text-3xl font-extrabold text-white sm:text-4xl">
            Explorar grupos
          </h1>
          <p className="mt-2 text-brand-muted">
            Encuentra el grupo perfecto para tu evento.
          </p>
        </div>

        {/* Filtros */}
        <div className="mb-6 grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
          {/* Search */}
          <div className="relative lg:col-span-1">
            <svg
              viewBox="0 0 24 24"
              className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 fill-brand-muted"
            >
              <path d="M15.5 14h-.79l-.28-.27A6.471 6.471 0 0 0 16 9.5 6.5 6.5 0 1 0 9.5 16c1.61 0 3.09-.59 4.23-1.57l.27.28v.79l5 4.99L20.49 19l-4.99-5zm-6 0C7.01 14 5 11.99 5 9.5S7.01 5 9.5 5 14 7.01 14 9.5 11.99 14 9.5 14z" />
            </svg>
            <input
              type="text"
              placeholder="Buscar por nombre…"
              value={search}
              onChange={(e) => setSearch(e.target.value)}
              className="w-full rounded-xl border border-brand-border bg-brand-card py-2.5 pl-9 pr-4 text-sm text-white placeholder-brand-muted outline-none focus:border-brand-green"
            />
          </div>

          {/* City */}
          <select
            value={city}
            onChange={(e) => setCity(e.target.value)}
            className="rounded-xl border border-brand-border bg-brand-card px-4 py-2.5 text-sm text-white outline-none focus:border-brand-green"
          >
            <option value="">Todas las ciudades</option>
            {CITIES.map((c) => (
              <option key={c} value={c}>{c}</option>
            ))}
          </select>

          {/* Category */}
          <select
            value={category}
            onChange={(e) => setCategory(e.target.value)}
            className="rounded-xl border border-brand-border bg-brand-card px-4 py-2.5 text-sm text-white outline-none focus:border-brand-green"
          >
            <option value="">Todas las categorías</option>
            {CATEGORIES.map((c) => (
              <option key={c} value={c}>{c}</option>
            ))}
          </select>

          {/* Sort */}
          <select
            value={sort}
            onChange={(e) => setSort(e.target.value as typeof sort)}
            className="rounded-xl border border-brand-border bg-brand-card px-4 py-2.5 text-sm text-white outline-none focus:border-brand-green"
          >
            <option value="rating">Mejor calificados</option>
            <option value="price_asc">Precio: menor a mayor</option>
            <option value="price_desc">Precio: mayor a menor</option>
          </select>
        </div>

        {/* ── BANNER AD o Promo Slot ─────────────────────────────────────── */}
        {activeBanner ? (
          <div>
            <BannerAdCard ad={activeBanner} />
            {/* Dots si hay más de 1 */}
            {bannerAds.length > 1 && (
              <div className="mb-6 -mt-4 flex justify-center gap-1.5">
                {bannerAds.map((_, i) => (
                  <button
                    key={i}
                    onClick={() => setCurrentAdIndex(i)}
                    className={`h-1.5 rounded-full transition-all ${
                      i === currentAdIndex % bannerAds.length
                        ? "w-4 bg-brand-green"
                        : "w-1.5 bg-brand-border"
                    }`}
                  />
                ))}
              </div>
            )}
          </div>
        ) : (
          <PromoSlot />
        )}

        {/* Results count */}
        <p className="mb-6 text-sm text-brand-muted">
          {loading
            ? "Buscando…"
            : `${groups.length} grupo${groups.length !== 1 ? "s" : ""} encontrado${groups.length !== 1 ? "s" : ""}`}
        </p>

        {/* ── GRID DE GRUPOS ──────────────────────────────────────────── */}
        {loading ? (
          <div className="grid gap-6 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4">
            {Array.from({ length: 8 }).map((_, i) => (
              <div
                key={i}
                className="h-72 animate-pulse rounded-2xl border border-brand-border bg-brand-card"
              />
            ))}
          </div>
        ) : groups.length === 0 ? (
          <div className="flex flex-col items-center justify-center py-24 text-center">
            <span className="mb-4 text-6xl">🎵</span>
            <p className="text-lg font-semibold text-white">
              No encontramos grupos con esos filtros
            </p>
            <p className="mt-2 text-sm text-brand-muted">
              Intenta con otra ciudad o categoría.
            </p>
            <button
              onClick={() => { setCity(""); setCategory(""); setSearch(""); }}
              className="mt-6 rounded-xl bg-brand-green px-6 py-2.5 text-sm font-bold text-black"
            >
              Limpiar filtros
            </button>
          </div>
        ) : (
          <div className="grid gap-6 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4">
            {rows.map((item, idx) =>
              item.type === "ad" ? (
                <InlineAdCard key={`ad-${item.data.id}-${idx}`} ad={item.data} />
              ) : (
                <GroupCard
                  key={item.data.id}
                  group={item.data}
                  isSponsored={sponsoredIds.has(item.data.id)}
                />
              )
            )}
          </div>
        )}
      </main>

      <Footer />
    </div>
  );
}
