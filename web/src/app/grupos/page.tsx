"use client";

import { useState, useEffect, useCallback, useRef } from "react";
import Link from "next/link";
import Image from "next/image";
import Navbar from "@/components/Navbar";
import Footer from "@/components/Footer";
import { supabase, Group } from "@/lib/supabase";
import { CATEGORY_LABELS, NON_MUSICIAN_GENRES } from "@/lib/genreCategories";

// Los 3 países donde opera Daricefy (mismos valores que guarda groups.country
// en la app móvil). El estado ya NO es una lista fija de ciudades — se llena
// solo con los estados que de verdad tienen grupos activos en ese país.
const COUNTRIES = ["México", "Estados Unidos", "Canadá"];

// get_active_banner_ads() nunca devuelve "cta_url" — ese campo no existe
// (hallazgo real: el botón "Ver más" nunca aparecía). El link real vive en
// link_url o youtube_url, según link_type.
interface BannerAd {
  id: string;
  title: string;
  subtitle: string | null;
  tag: string | null;
  media_url: string | null;
  media_type: string | null;
  button_text: string | null;
  link_type: string | null;
  link_url: string | null;
  youtube_url: string | null;
}

// ── Video de anuncio, con botón para quitarle el silencio ────────────────────
// React a veces NO respeta el atributo JSX "muted" a tiempo para que el
// navegador autorice el autoplay (lo trata como defaultMuted) — se fuerza
// por ref para que el autoplay funcione de verdad en cualquier navegador.
//
// Detección real de falla visual: algunos .mov de iPhone traen audio PCM
// sin comprimir — el navegador SÍ decodifica el audio (se escucha) pero
// nunca pinta un solo cuadro de video (videoWidth se queda en 0 para
// siempre). Antes eso se veía como un hueco negro roto; ahora, si a los
// 2.5s no hay ancho real de video, se cae a una tarjeta limpia en vez de
// dejar algo que se vea fallado. No hay forma de arreglar el archivo ya
// subido desde el código — hay que resubirlo (ver comentario en el botón).
function AdVideo({ src, className, fallbackIcon = "🎬" }: { src: string; className: string; fallbackIcon?: string }) {
  const ref = useRef<HTMLVideoElement | null>(null);
  const [muted, setMuted] = useState(true);
  const [visualFailed, setVisualFailed] = useState(false);

  useEffect(() => {
    setVisualFailed(false);
    const check = setTimeout(() => {
      const v = ref.current;
      if (v && v.videoWidth === 0) setVisualFailed(true);
    }, 2500);
    return () => clearTimeout(check);
  }, [src]);

  if (visualFailed) {
    return (
      <div className="absolute inset-0 flex h-full w-full flex-col items-center justify-center gap-1 bg-brand-card2 text-brand-muted">
        <span className="text-3xl opacity-40">{fallbackIcon}</span>
        <span className="text-[10px]">Vista previa no disponible</span>
      </div>
    );
  }

  return (
    <div className="group/video relative h-full w-full">
      <video
        ref={(el) => {
          ref.current = el;
          if (el) { el.muted = muted; el.play().catch(() => {}); }
        }}
        src={src}
        autoPlay
        loop
        playsInline
        muted={muted}
        onError={() => setVisualFailed(true)}
        className={className}
      />
      <button
        onClick={(e) => {
          e.preventDefault();
          e.stopPropagation();
          const next = !muted;
          setMuted(next);
          if (ref.current) { ref.current.muted = next; ref.current.play().catch(() => {}); }
        }}
        className="absolute bottom-2 right-2 z-10 flex h-7 w-7 items-center justify-center rounded-full bg-black/60 text-xs text-white opacity-0 transition-opacity group-hover/video:opacity-100"
        aria-label={muted ? "Activar sonido" : "Silenciar"}
      >
        {muted ? "🔇" : "🔊"}
      </button>
    </div>
  );
}

// ── Banner Ad Component ──────────────────────────────────────────────────────
// Rediseñado como banner grande de verdad (antes era una fila angosta con
// una miniatura de 64px — petición real: "se ve chico"). El media llena
// todo el fondo del banner, con degradado para que el texto se lea encima.
// 2026-09-19 — petición real: "quiero que aparezcan dos en esa fila... para
// que se vea completo la imagen" — se usa aspect-video (16:9), la MISMA
// proporción que ya fuerza el recorte al subir la imagen (ver pickMedia en
// CreateAdvertisementScreen.tsx), así el recuadro nunca recorta lo que el
// anunciante ya vio y aprobó al subir su foto. Antes tenía una altura fija
// muy corta (h-36/h-48) para todo el ancho, una proporción mucho más ancha
// que 16:9 que sí recortaba arriba/abajo.
function BannerAdCard({ ad }: { ad: BannerAd }) {
  const ctaUrl = ad.link_url ?? ad.youtube_url ?? null;
  return (
    <div className="relative aspect-[21/9] w-full overflow-hidden rounded-2xl border border-brand-green/20 bg-brand-card">
      {ad.media_url && (
        ad.media_type === "video" ? (
          <AdVideo src={ad.media_url} className="absolute inset-0 h-full w-full object-cover" />
        ) : (
          <Image src={ad.media_url} alt={ad.title} fill className="object-cover" unoptimized />
        )
      )}
      <div className="pointer-events-none absolute inset-0 bg-gradient-to-t from-black/85 via-black/20 to-black/10" />
      <div className="pointer-events-none absolute inset-x-0 bottom-0 flex flex-wrap items-end justify-between gap-2 p-3 sm:p-4">
        <div className="min-w-0">
          <span className="mb-1 inline-block rounded-full border border-brand-green/50 bg-brand-green/15 px-2 py-0.5 text-[9px] font-bold uppercase tracking-wider text-brand-green">
            {ad.tag ?? "Publicidad"}
          </span>
          <p className="text-sm font-extrabold text-white sm:text-base">{ad.title}</p>
          {ad.subtitle && (
            <p className="mt-0.5 max-w-md text-xs text-white/80">{ad.subtitle}</p>
          )}
        </div>
        {ctaUrl && (
          <a
            href={ctaUrl}
            target="_blank"
            rel="noopener noreferrer"
            className="pointer-events-auto shrink-0 rounded-lg bg-brand-green px-3 py-1.5 text-xs font-bold text-black hover:bg-brand-green2"
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
      <div className="relative h-28 w-full overflow-hidden bg-brand-card2">
        {group.profile_image ? (
          <Image
            src={group.profile_image}
            alt={group.name}
            fill
            className="object-cover transition-transform duration-300 group-hover:scale-105"
            unoptimized
          />
        ) : (
          <div className="flex h-full w-full items-center justify-center text-3xl opacity-20">
            🎵
          </div>
        )}
        {/* Badges */}
        <div className="absolute left-2 top-2 flex gap-1">
          {group.is_verified && (
            <span className="rounded-full bg-brand-green/90 px-1.5 py-0.5 text-[8px] font-bold text-black">
              ✓
            </span>
          )}
          {isSponsored && (
            <span className="rounded-full bg-yellow-400/90 px-1.5 py-0.5 text-[8px] font-bold text-black">
              ⭐
            </span>
          )}
          {!isSponsored && isBidActive && (
            <span className="rounded-full bg-orange-500/90 px-1.5 py-0.5 text-[8px] font-bold text-white">
              🔥
            </span>
          )}
        </div>
      </div>

      {/* Info */}
      <div className="flex flex-1 flex-col p-2.5">
        <div className="mb-0.5 flex items-start justify-between gap-1">
          <h3 className="truncate text-xs font-bold text-white transition-colors group-hover:text-brand-green">
            {group.name}
          </h3>
          <div className="flex shrink-0 items-center gap-0.5">
            <span className="text-[10px] text-yellow-400">★</span>
            <span className="text-[10px] font-medium text-white">
              {(group.rating ?? 0).toFixed(1)}
            </span>
          </div>
        </div>

        <div className="mb-1.5 flex flex-wrap items-center gap-1">
          {group.city && (
            <span className="truncate text-[10px] text-brand-muted">📍 {group.city}</span>
          )}
          {group.genre && (
            <span className="truncate rounded-full border border-brand-border px-1.5 py-0.5 text-[9px] text-brand-muted">
              {group.genre}
            </span>
          )}
        </div>

        <div className="mt-auto flex items-center justify-between border-t border-brand-border pt-1.5">
          <p className="text-xs font-bold text-brand-green">
            {group.price_from ? `$${group.price_from.toLocaleString("es-MX")}` : "A cotizar"}
          </p>
          <span className="rounded-md bg-brand-green/10 px-2 py-1 text-[10px] font-semibold text-brand-green transition-colors group-hover:bg-brand-green group-hover:text-black">
            Ver →
          </span>
        </div>
      </div>
    </Link>
  );
}

// ── Deck de Recomendados / Destacados / Populares ────────────────────────────
// Mismo diseño real que el Explorador de la app (HomeScreen.tsx: MiniDeck/
// DeckCard) — un solo renglón de 3 columnas, cada una con UNA tarjeta que va
// rotando sola entre sus grupos (nunca varias apiladas). Antes la web no
// tenía esto — el "destacado" solo era una estrellita dentro de la
// cuadrícula normal (hallazgo real 2026-09-19: "el diseño del explorador en
// la web ya está mal", comparado con la app).
interface DeckSection {
  key: "reco" | "dest" | "pop";
  label: string;
  items: Group[];
}

function DeckCard({ group, variant }: { group: Group; variant: DeckSection["key"] }) {
  return (
    <Link
      href={`/grupos/${group.id}`}
      className={`relative block aspect-[1/1.32] w-full overflow-hidden rounded-xl bg-brand-card2 ${
        variant === "dest" ? "ring-2 ring-[#C9A84C]/70 shadow-[0_0_14px_rgba(201,168,76,0.35)]" : ""
      }`}
    >
      {group.profile_image ? (
        <Image src={group.profile_image} alt={group.name} fill className="object-cover" unoptimized />
      ) : (
        <div className="flex h-full w-full items-center justify-center text-3xl opacity-20">🎵</div>
      )}
      <div className="pointer-events-none absolute inset-x-0 bottom-0 h-3/5 bg-gradient-to-t from-black/90 to-transparent" />
      <div className="absolute bottom-1.5 left-2 right-2">
        <p className="flex items-center gap-1 text-[10px] font-semibold text-yellow-400">
          ★ {(group.rating ?? 0).toFixed(1)}
        </p>
        <p className="truncate text-xs font-bold text-white">{group.name}</p>
      </div>
    </Link>
  );
}

function DeckColumn({ section }: { section: DeckSection }) {
  const [idx, setIdx] = useState(0);
  const n = section.items.length;

  useEffect(() => {
    if (n <= 1) return;
    const id = setInterval(() => setIdx((i) => (i + 1) % n), 2600);
    return () => clearInterval(id);
  }, [n]);

  const labelCls =
    section.key === "reco"
      ? "border-brand-green/50 bg-brand-green/10 text-brand-green"
      : section.key === "dest"
      ? "border-[#C9A84C]/55 bg-[#C9A84C]/15 text-[#E6C25A]"
      : "border-white/25 bg-white/[0.06] text-white";

  return (
    <div className="flex flex-col items-center gap-2">
      <span className={`w-full rounded-lg border px-2 py-1 text-center text-[11px] font-bold ${labelCls}`}>
        {section.label}
      </span>
      <DeckCard group={section.items[idx % n]} variant={section.key} />
    </div>
  );
}

function ExplorerDeck({ sponsored, recommended, byRating }: { sponsored: Group[]; recommended: Group[]; byRating: Group[] }) {
  const destacados = sponsored.slice(0, 20);
  const destIds = new Set(destacados.map((g) => g.id));
  const recomendados = recommended.filter((r) => !destIds.has(r.id)).slice(0, 20);
  const recIds = new Set(recomendados.map((g) => g.id));
  const populares = byRating.filter((g) => !destIds.has(g.id) && !recIds.has(g.id)).slice(0, 20);

  // 💎 El Destacado (más caro) va AL CENTRO — el lugar de honor, igual que en la app.
  const sections: DeckSection[] = [
    { key: "reco" as const, label: "Recomendados", items: recomendados },
    { key: "dest" as const, label: "Destacados",   items: destacados },
    { key: "pop"  as const, label: "Populares",    items: populares },
  ].filter((s) => s.items.length > 0);

  if (sections.length === 0) return null;

  return (
    // Bug real reportado 2026-09-19: "se ve muy grande" — en la app cada
    // tarjeta ocupa ~80% de su columna dentro de un celular angosto; en un
    // monitor ancho, estirar esas mismas 3 columnas a todo el ancho del
    // contenido (1280px) hacía tarjetas gigantes. Se acota el deck a un
    // ancho fijo chico (parecido a las tarjetas de la cuadrícula de abajo),
    // nunca a todo el ancho de la página.
    <div className="mb-6 grid max-w-xs grid-cols-3 gap-2.5 sm:max-w-sm">
      {sections.map((s) => (
        <DeckColumn key={s.key} section={s} />
      ))}
    </div>
  );
}

// ── Main page ────────────────────────────────────────────────────────────────
export default function GruposPage() {
  const [groups,           setGroups]           = useState<Group[]>([]);
  const [bannerAds,        setBannerAds]        = useState<BannerAd[]>([]);
  const [sponsoredIds,     setSponsoredIds]     = useState<Set<string>>(new Set());
  const [sponsoredGroups,  setSponsoredGroups]  = useState<Group[]>([]);
  const [recommendedGroups, setRecommendedGroups] = useState<Group[]>([]);
  const [loading,          setLoading]          = useState(true);
  const [country,          setCountry]          = useState("");
  const [state,            setState]            = useState("");
  const [availableStates,  setAvailableStates]  = useState<string[]>([]);
  // 2026-09-17 — petición real: "que salgan las categorías" al entrar,
  // como en la app, en vez de un <select> escondido. selectedCatKey guarda
  // la categoría (key de CATEGORY_LABELS); selectedGenre, el género exacto
  // dentro de ella (Norteño, Sierreño...) — null = todos los de la categoría.
  const [selectedCatKey,   setSelectedCatKey]   = useState("");
  const [selectedGenre,    setSelectedGenre]    = useState<string | null>(null);
  const [search,           setSearch]           = useState("");
  const [sort,             setSort]             = useState<"rating" | "price_asc" | "price_desc">("rating");
  const [currentAdIndex,   setCurrentAdIndex]   = useState(0);

  // ── Estados disponibles para el país elegido — se calculan de los grupos
  // reales, nunca una lista fija (antes tenía 8 ciudades de México a mano,
  // que ni filtraban por el campo correcto ni servían para EE.UU./Canadá).
  useEffect(() => {
    setState("");
    if (!country) { setAvailableStates([]); return; }
    supabase
      .from("groups")
      .select("state")
      .eq("is_active", true)
      .eq("country", country)
      .not("state", "is", null)
      .then(({ data }) => {
        const unique = Array.from(new Set((data ?? []).map((g: any) => g.state as string))).sort();
        setAvailableStates(unique);
      });
  }, [country]);

  // ── Fetch ads + sponsored/recomendados (deck real del Explorador) ─────────
  const fetchAds = useCallback(async (targetState: string, targetCountry: string) => {
    const [{ data: banners }, { data: sponsored }, { data: recommended }] = await Promise.all([
      supabase.rpc("get_active_banner_ads", { p_state: targetState || null, p_country: targetCountry || null }),
      supabase.rpc("get_sponsored_group_ids", { p_state: targetState || null, p_country: targetCountry || null }),
      supabase.rpc("get_active_recommendations", { p_state: targetState || null, p_country: targetCountry || null, p_limit: 20 }),
    ]);
    setBannerAds((banners as BannerAd[]) ?? []);
    const sponsoredList = (sponsored as { group_id: string }[] ?? []);
    setSponsoredIds(new Set(sponsoredList.map(s => s.group_id)));
    setRecommendedGroups((recommended as Group[]) ?? []);

    const sponsoredGroupIds = sponsoredList.map(s => s.group_id);
    if (sponsoredGroupIds.length === 0) { setSponsoredGroups([]); return; }
    const { data: sponsoredFull } = await supabase
      .from("groups")
      .select("id, name, description, city, state, genre, price_from, rating, total_reviews, profile_image, badges, bid_amount, bid_ends_at, boost_score, is_verified, owner_id")
      .in("id", sponsoredGroupIds);
    setSponsoredGroups((sponsoredFull as Group[]) ?? []);
  }, []);

  // ── Fetch groups ──────────────────────────────────────────────────────────
  // groups no tiene "status"/"category"/"base_price" — son is_active/genre/
  // price_from (hallazgo real: esta consulta fallaba en silencio y siempre
  // mostraba "0 grupos encontrados", sin importar los filtros). El filtro
  // geográfico ahora es país → estado (como el resto de la app), no ciudad.
  const fetchGroups = useCallback(async () => {
    setLoading(true);

    let q = supabase
      .from("groups")
      .select(
        "id, name, description, city, state, genre, price_from, rating, total_reviews, profile_image, badges, bid_amount, bid_ends_at, boost_score, is_verified, owner_id"
      )
      .eq("is_active", true);

    if (country)  q = q.eq("country", country);
    if (state)    q = q.eq("state", state);
    if (selectedCatKey) {
      const cat = CATEGORY_LABELS.find((c) => c.key === selectedCatKey);
      if (cat) {
        // Género exacto elegido (Norteño, Sierreño...) filtra preciso;
        // sin elegir uno, se comporta como siempre (toda la categoría).
        if (selectedGenre) q = q.eq("genre", selectedGenre);
        else q = q.in("genre", cat.genres);
      }
    }
    if (search)   q = q.ilike("name", `%${search}%`);

    if (sort === "rating")     q = q.order("rating",     { ascending: false, nullsFirst: false });
    if (sort === "price_asc")  q = q.order("price_from", { ascending: true,  nullsFirst: false });
    if (sort === "price_desc") q = q.order("price_from", { ascending: false, nullsFirst: false });

    const { data } = await q.limit(48);
    setGroups((data as Group[]) ?? []);
    setLoading(false);
  }, [country, state, selectedCatKey, selectedGenre, search, sort]);

  useEffect(() => { fetchGroups(); fetchAds(state, country); }, [fetchGroups, fetchAds, state, country]);

  useEffect(() => { setSelectedGenre(null); }, [selectedCatKey]);

  // ── Auto-rotate banner ads ────────────────────────────────────────────────
  useEffect(() => {
    if (bannerAds.length <= 1) return;
    const id = setInterval(() => {
      setCurrentAdIndex(i => (i + 1) % bannerAds.length);
    }, 5000);
    return () => clearInterval(id);
  }, [bannerAds.length]);

  // Bug real reportado 2026-09-19: "salen grupos y otra vez el anuncio debajo
  // del grupo, quiero que estén en el mismo lugar, como en la app y se
  // cambien solo" — antes el mismo anuncio aparecía DOS veces (el banner de
  // arriba, y otra vez insertado a mano dentro de la cuadrícula tras el 3er/
  // 6to grupo). La app solo tiene UN lugar para el anuncio, que rota solo
  // entre todos — se quita la inserción duplicada, el banner de arriba ya
  // rota solo con `currentAdIndex` (ver efecto de arriba).
  const activeBanner = bannerAds.length > 0 ? bannerAds[currentAdIndex % bannerAds.length] : null;

  // ── Deck de Recomendados/Destacados/Populares, acotado a la categoría/
  // género elegidos — mismo criterio que HomeScreen.tsx de la app: sin
  // categoría elegida ("Todos"), esta fila muestra SOLO músicos; con una
  // categoría, solo grupos de esa categoría (o del género exacto si se
  // eligió uno). Bug real reportado: "si el cliente se mete a comida pues
  // que le aparezcan los destacados o recomendado y populares de esa
  // categoría" — antes el deck no filtraba por categoría en absoluto.
  const activeCat = CATEGORY_LABELS.find((c) => c.key === selectedCatKey);
  const activeGenres = selectedCatKey
    ? (selectedGenre ? [selectedGenre] : activeCat?.genres ?? null)
    : null;
  const deckGenreFilter = (g: Group) =>
    activeGenres ? activeGenres.includes(g.genre ?? "") : !NON_MUSICIAN_GENRES.has(g.genre ?? "");

  const deckSponsored   = sponsoredGroups.filter(deckGenreFilter);
  const deckRecommended = recommendedGroups.filter(deckGenreFilter);
  const deckByRating     = [...groups]
    .filter(deckGenreFilter)
    .sort((a, b) => (b.rating ?? 0) - (a.rating ?? 0));

  return (
    <div className="min-h-screen bg-brand-bg">
      <Navbar />

      <main className="mx-auto max-w-7xl px-4 pb-16 pt-24 sm:px-6 lg:px-8">

        {/* Header */}
        <div className="mb-8">
          <h1 className="text-3xl font-extrabold text-white sm:text-4xl">
            Explorar proveedores
          </h1>
          <p className="mt-2 text-brand-muted">
            Encuentra el proveedor perfecto para tu evento.
          </p>
        </div>

        {/* Categorías — visibles al entrar, igual que en la app (antes
            escondidas dentro de un <select>). 2026-09-17, petición real:
            "que si me meto pues salgan las categorías". */}
        <div className="mb-3 flex flex-wrap gap-2">
          <button
            onClick={() => setSelectedCatKey("")}
            className={`rounded-full px-4 py-2 text-sm font-medium transition-colors ${
              selectedCatKey === ""
                ? "bg-brand-green text-black"
                : "border border-brand-border bg-brand-card text-brand-muted hover:border-brand-green/50 hover:text-white"
            }`}
          >
            Todos
          </button>
          {CATEGORY_LABELS.map((cat) => (
            <button
              key={cat.key}
              onClick={() => setSelectedCatKey(cat.key)}
              className={`rounded-full px-4 py-2 text-sm font-medium transition-colors ${
                selectedCatKey === cat.key
                  ? "bg-brand-green text-black"
                  : "border border-brand-border bg-brand-card text-brand-muted hover:border-brand-green/50 hover:text-white"
              }`}
            >
              {cat.label}
            </button>
          ))}
        </div>

        {/* Géneros de la categoría activa — Norteño, Sierreño, Banda...
            México/Latinoamérica primero, Estados Unidos después (mismo
            orden que la app). Solo aparece si la categoría tiene más de
            un género (Grupo musical, Luz y sonido, Shows, Renta). */}
        {(() => {
          const cat = CATEGORY_LABELS.find((c) => c.key === selectedCatKey);
          if (!cat || cat.genres.length <= 1) return null;
          return (
            <div className="mb-6 flex flex-wrap gap-2 border-l-2 border-brand-green/30 pl-3">
              <button
                onClick={() => setSelectedGenre(null)}
                className={`rounded-full px-3 py-1.5 text-xs font-medium transition-colors ${
                  selectedGenre === null
                    ? "bg-brand-green/20 text-brand-green"
                    : "border border-brand-border text-brand-muted hover:text-white"
                }`}
              >
                Todos los géneros
              </button>
              {cat.genres.map((g) => (
                <button
                  key={g}
                  onClick={() => setSelectedGenre(g)}
                  className={`rounded-full px-3 py-1.5 text-xs font-medium transition-colors ${
                    selectedGenre === g
                      ? "bg-brand-green/20 text-brand-green"
                      : "border border-brand-border text-brand-muted hover:text-white"
                  }`}
                >
                  {g}
                </button>
              ))}
            </div>
          );
        })()}

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

          {/* País */}
          <select
            value={country}
            onChange={(e) => setCountry(e.target.value)}
            className="rounded-xl border border-brand-border bg-brand-card px-4 py-2.5 text-sm text-white outline-none focus:border-brand-green"
          >
            <option value="">Todos los países</option>
            {COUNTRIES.map((c) => (
              <option key={c} value={c}>{c}</option>
            ))}
          </select>

          {/* Estado — depende del país elegido; solo se muestran los que
              de verdad tienen grupos activos ahí (nada de ciudades a mano). */}
          <select
            value={state}
            onChange={(e) => setState(e.target.value)}
            disabled={!country}
            className="rounded-xl border border-brand-border bg-brand-card px-4 py-2.5 text-sm text-white outline-none focus:border-brand-green disabled:opacity-50"
          >
            <option value="">{country ? "Todos los estados" : "Elige un país primero"}</option>
            {availableStates.map((s) => (
              <option key={s} value={s}>{s}</option>
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

        {/* ── DECK: Recomendados · Destacados · Populares ─────────────────── */}
        <ExplorerDeck sponsored={deckSponsored} recommended={deckRecommended} byRating={deckByRating} />

        {/* ── BANNER ADS — dos cuadros lado a lado ─────────────────────────
            Petición real (2026-09-19): "quiero que aparezcan dos en esa
            fila, anuncio - anuncio". Los dos rotan juntos: el segundo
            cuadro siempre muestra el SIGUIENTE anuncio al del primero, así
            con el mismo temporizador de antes (currentAdIndex) los dos se
            actualizan solos sin lógica nueva de tiempo. */}
        {activeBanner ? (
          <div className="mb-6">
            <div className="grid gap-4 sm:grid-cols-2">
              <BannerAdCard ad={activeBanner} />
              {bannerAds.length > 1 ? (
                <BannerAdCard ad={bannerAds[(currentAdIndex + 1) % bannerAds.length]} />
              ) : (
                <PromoSlot />
              )}
            </div>
            {/* Dots si hay más de 2 */}
            {bannerAds.length > 2 && (
              <div className="mt-3 flex justify-center gap-1.5">
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
            : `${groups.length} proveedor${groups.length !== 1 ? "es" : ""} encontrado${groups.length !== 1 ? "s" : ""}`}
        </p>

        {/* ── GRID DE GRUPOS ──────────────────────────────────────────── */}
        {loading ? (
          <div className="grid gap-3 grid-cols-2 sm:grid-cols-3 lg:grid-cols-5 xl:grid-cols-6">
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
              No encontramos proveedores con esos filtros
            </p>
            <p className="mt-2 text-sm text-brand-muted">
              Intenta con otra ciudad o categoría.
            </p>
            <button
              onClick={() => { setCountry(""); setSelectedCatKey(""); setSearch(""); }}
              className="mt-6 rounded-xl bg-brand-green px-6 py-2.5 text-sm font-bold text-black"
            >
              Limpiar filtros
            </button>
          </div>
        ) : (
          <div className="grid gap-3 grid-cols-2 sm:grid-cols-3 lg:grid-cols-5 xl:grid-cols-6">
            {groups.map((g) => (
              <GroupCard key={g.id} group={g} isSponsored={sponsoredIds.has(g.id)} />
            ))}
          </div>
        )}
      </main>

      <Footer />
    </div>
  );
}
