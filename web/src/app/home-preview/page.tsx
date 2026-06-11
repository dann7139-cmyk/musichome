'use client';
import { useState } from 'react';

// ── Fake data ──────────────────────────────────────────────────────────────────
const RECOMMENDED = [
  { id: 1, name: 'Los Compadres', genre: 'Norteño', city: 'Pereira', rating: 4.9, reviews: 48, price: 8500, verified: true, img: null, tag: 'Top 1' },
  { id: 2, name: 'Banda Élite',   genre: 'Banda',   city: 'Manizales', rating: 4.8, reviews: 31, price: 12000, verified: true, img: null, tag: null },
];
const FEATURED = [
  { id: 3, name: 'Mariachi Real',  genre: 'Mariachi', city: 'Pereira',    rating: 4.7, reviews: 22, price: 6500, verified: true,  img: null },
  { id: 4, name: 'Tropical Crew',  genre: 'Tropical', city: 'Manizales',  rating: 4.6, reviews: 17, price: 7200, verified: false, img: null },
  { id: 5, name: 'Jazz Quarter',   genre: 'Jazz',      city: 'Pereira',    rating: 4.5, reviews: 9,  price: 9800, verified: true,  img: null },
  { id: 6, name: 'Cumbia Kings',   genre: 'Cumbia',    city: 'Manizales',  rating: 4.4, reviews: 14, price: 5500, verified: false, img: null },
];
const NAV_ITEMS = [
  { icon: '🏠', label: 'Inicio', active: true  },
  { icon: '🎵', label: 'Eventos', active: false },
  { icon: '🗺️', label: 'Mapa',   active: false },
  { icon: '👤', label: 'Perfil',  active: false },
];

// ── Stars ──────────────────────────────────────────────────────────────────────
function Stars({ rating }: { rating: number }) {
  return (
    <span className="flex items-center gap-0.5">
      {[1,2,3,4,5].map(i => (
        <svg key={i} width="10" height="10" viewBox="0 0 24 24" fill={i <= Math.round(rating) ? '#FFB300' : 'none'}
          stroke={i <= Math.round(rating) ? '#FFB300' : '#444'} strokeWidth="2">
          <polygon points="12 2 15.09 8.26 22 9.27 17 14.14 18.18 21.02 12 17.77 5.82 21.02 7 14.14 2 9.27 8.91 8.26 12 2"/>
        </svg>
      ))}
    </span>
  );
}

// ── Verified badge ─────────────────────────────────────────────────────────────
function Verified() {
  return (
    <svg width="14" height="14" viewBox="0 0 24 24" fill="#1D9BF0">
      <path d="M9 12l2 2 4-4M7.835 4.697a3.42 3.42 0 001.946-.806 3.42 3.42 0 014.438 0 3.42 3.42 0 001.946.806 3.42 3.42 0 013.138 3.138 3.42 3.42 0 00.806 1.946 3.42 3.42 0 010 4.438 3.42 3.42 0 00-.806 1.946 3.42 3.42 0 01-3.138 3.138 3.42 3.42 0 00-1.946.806 3.42 3.42 0 01-4.438 0 3.42 3.42 0 00-1.946-.806 3.42 3.42 0 01-3.138-3.138 3.42 3.42 0 00-.806-1.946 3.42 3.42 0 010-4.438 3.42 3.42 0 00.806-1.946 3.42 3.42 0 013.138-3.138z"
        stroke="none"/>
      <path d="M9 12l2 2 4-4" stroke="white" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round" fill="none"/>
    </svg>
  );
}

// ── Group card (vertical) ──────────────────────────────────────────────────────
function GroupCard({ g, large = false }: { g: any; large?: boolean }) {
  const initials = g.name.split(' ').map((w: string) => w[0]).join('').slice(0,2).toUpperCase();
  const hue = (g.id * 53) % 360;
  return (
    <div
      className={`flex-shrink-0 rounded-2xl overflow-hidden border border-[#1c1c1c] ${large ? 'w-52' : 'w-44'}`}
      style={{ background: '#0e0e0e' }}
    >
      {/* Image / placeholder */}
      <div
        className={`w-full flex items-center justify-center relative ${large ? 'h-36' : 'h-28'}`}
        style={{ background: `hsl(${hue},30%,10%)` }}
      >
        <span className="text-3xl font-black" style={{ color: `hsl(${hue},60%,60%)`, fontFamily: 'system-ui' }}>
          {initials}
        </span>
        {/* tag badge */}
        {g.tag && (
          <span className="absolute top-2 left-2 text-[10px] font-bold px-2 py-0.5 rounded-full"
            style={{ background: 'linear-gradient(135deg,#00E676,#00C853)', color: '#000' }}>
            {g.tag}
          </span>
        )}
        {/* price badge */}
        <span className="absolute bottom-2 right-2 text-[11px] font-semibold px-2 py-0.5 rounded-full"
          style={{ background: 'rgba(0,0,0,0.7)', color: '#00E676', backdropFilter: 'blur(4px)', border: '1px solid rgba(0,230,118,0.3)' }}>
          ${g.price.toLocaleString()}
        </span>
      </div>
      {/* Info */}
      <div className="p-3">
        <div className="flex items-center gap-1 mb-0.5">
          <p className="text-[13px] font-bold text-white leading-tight truncate flex-1">{g.name}</p>
          {g.verified && <Verified />}
        </div>
        <p className="text-[11px] text-[#555] mb-1.5">{g.genre} · {g.city}</p>
        <div className="flex items-center gap-1.5">
          <Stars rating={g.rating} />
          <span className="text-[10px] font-semibold text-[#FFB300]">{g.rating}</span>
          <span className="text-[10px] text-[#444]">({g.reviews})</span>
        </div>
      </div>
    </div>
  );
}

// ── Main ───────────────────────────────────────────────────────────────────────
export default function HomePreview() {
  const [search, setSearch] = useState('');

  return (
    <div
      className="min-h-screen flex justify-center bg-[#040404] py-8 px-4"
      style={{ fontFamily: "'Inter', 'SF Pro Display', -apple-system, sans-serif" }}
    >
      {/* Phone shell */}
      <div className="w-full max-w-sm flex flex-col" style={{ minHeight: '100vh' }}>

        {/* ── STATUS BAR ── */}
        <div className="flex justify-between items-center px-6 pt-3 pb-1">
          <span className="text-[11px] font-semibold text-white">9:41</span>
          <div className="flex items-center gap-1">
            <svg width="16" height="11" viewBox="0 0 16 11" fill="white"><rect x="0" y="4" width="3" height="7" rx="1"/><rect x="4.5" y="2.5" width="3" height="8.5" rx="1"/><rect x="9" y="0.5" width="3" height="10.5" rx="1"/><rect x="13.5" y="0" width="2" height="11" rx="1" opacity="0.3"/></svg>
            <svg width="16" height="12" viewBox="0 0 16 12" fill="white"><path d="M8 2.4C10.4 2.4 12.5 3.4 14 5L15.5 3.4C13.6 1.3 11 0 8 0C5 0 2.4 1.3 0.5 3.4L2 5C3.5 3.4 5.6 2.4 8 2.4Z" opacity="0.3"/><path d="M8 5.6C9.7 5.6 11.2 6.3 12.3 7.5L13.8 5.9C12.3 4.3 10.3 3.3 8 3.3C5.7 3.3 3.7 4.3 2.2 5.9L3.7 7.5C4.8 6.3 6.3 5.6 8 5.6Z" opacity="0.6"/><path d="M8 8.8C9 8.8 9.9 9.2 10.6 9.9L8 12.4L5.4 9.9C6.1 9.2 7 8.8 8 8.8Z"/></svg>
            <div className="flex items-center gap-0.5">
              <div className="w-5 h-2.5 rounded-[3px] border border-white/40 flex items-center px-0.5">
                <div className="h-1.5 rounded-[2px] flex-1" style={{ background: 'white' }}/>
              </div>
            </div>
          </div>
        </div>

        {/* ── HEADER ──────────────────────────────────────────────────────── */}
        <div className="flex items-center justify-between px-5 pt-2 pb-4">
          {/* DARICEFY logo */}
          <div>
            <h1 className="text-[26px] font-black tracking-[-1px] leading-none"
              style={{
                background: 'linear-gradient(135deg, #ffffff 30%, #00E676 100%)',
                WebkitBackgroundClip: 'text',
                WebkitTextFillColor: 'transparent',
                letterSpacing: '-1.5px',
              }}>
              DARICEFY
            </h1>
            <p className="text-[11px] text-[#444] font-medium tracking-wider mt-0.5">
              Música en vivo para tu evento
            </p>
          </div>

          {/* Right icons */}
          <div className="flex items-center gap-2">
            {/* Notifications */}
            <button className="w-9 h-9 rounded-full flex items-center justify-center relative"
              style={{ background: '#111', border: '1px solid #1c1c1c' }}>
              <svg width="17" height="17" fill="none" viewBox="0 0 24 24">
                <path d="M18 8A6 6 0 0 0 6 8c0 7-3 9-3 9h18s-3-2-3-9" stroke="#888" strokeWidth="1.8" strokeLinecap="round"/>
                <path d="M13.73 21a2 2 0 0 1-3.46 0" stroke="#888" strokeWidth="1.8" strokeLinecap="round"/>
              </svg>
              <span className="absolute -top-0.5 -right-0.5 w-2.5 h-2.5 rounded-full bg-[#00E676]"/>
            </button>

            {/* Avatar */}
            <div className="w-9 h-9 rounded-full flex items-center justify-center text-[13px] font-bold text-[#000]"
              style={{ background: 'linear-gradient(135deg,#00E676,#00C853)' }}>
              C
            </div>
          </div>
        </div>

        {/* ── BANNER: PROPUESTAS (hero CTA) ──────────────────────────────── */}
        <div className="px-5 mb-3">
          <button
            className="w-full rounded-3xl p-4 text-left relative overflow-hidden transition-all active:scale-[0.98]"
            style={{
              background: 'linear-gradient(135deg, #0a1f10 0%, #071510 100%)',
              border: '1px solid rgba(0,230,118,0.25)',
              boxShadow: '0 0 30px rgba(0,230,118,0.12), 0 0 60px rgba(0,230,118,0.06), inset 0 1px 0 rgba(0,230,118,0.15)',
            }}
          >
            {/* Glow radial */}
            <div className="absolute -top-8 -left-8 w-36 h-36 rounded-full pointer-events-none"
              style={{ background: 'radial-gradient(circle, rgba(0,230,118,0.15) 0%, transparent 70%)' }}/>
            <div className="absolute top-3 right-4 pointer-events-none">
              {/* Lightning icon premium */}
              <div className="w-11 h-11 rounded-2xl flex items-center justify-center"
                style={{ background: 'rgba(0,230,118,0.15)', border: '1px solid rgba(0,230,118,0.3)' }}>
                <svg width="20" height="20" viewBox="0 0 24 24" fill="#00E676">
                  <path d="M13 2L4.09 12.56A1 1 0 005 14h6l-1 8 8.91-10.56A1 1 0 0019 10h-6l1-8z"/>
                </svg>
              </div>
            </div>

            <div className="pr-14">
              {/* Eyebrow */}
              <div className="flex items-center gap-1.5 mb-1">
                <span className="w-1.5 h-1.5 rounded-full bg-[#00E676] animate-pulse"/>
                <span className="text-[10px] font-semibold text-[#00E676] uppercase tracking-widest">Express · En minutos</span>
              </div>
              {/* Headline */}
              <p className="text-[18px] font-black text-white leading-tight mb-1"
                style={{ letterSpacing: '-0.5px' }}>
                Recibe propuestas<br/>en minutos
              </p>
              {/* Subtitle */}
              <p className="text-[12px] text-[#4a7a5a] font-medium mb-3">
                Contrata música para tu evento
              </p>
              {/* CTA row */}
              <div className="flex items-center gap-2">
                <span className="text-[13px] font-bold px-4 py-2 rounded-xl"
                  style={{ background: 'linear-gradient(135deg,#00E676,#00C853)', color: '#000' }}>
                  Solicitar ahora
                </span>
                <span className="text-[11px] text-[#3a6b4a]">Sin compromiso</span>
              </div>
            </div>
          </button>
        </div>

        {/* ── BANNER: MAPA ────────────────────────────────────────────────── */}
        <div className="px-5 mb-5">
          <button
            className="w-full rounded-2xl p-3.5 flex items-center gap-3 text-left transition-all active:scale-[0.98]"
            style={{
              background: '#0e0e0e',
              border: '1px solid #1c1c1c',
              boxShadow: '0 4px 20px rgba(0,0,0,0.4)',
            }}
          >
            <div className="w-10 h-10 rounded-xl flex items-center justify-center flex-shrink-0"
              style={{ background: 'rgba(66,133,244,0.12)', border: '1px solid rgba(66,133,244,0.25)' }}>
              <svg width="18" height="18" viewBox="0 0 24 24" fill="none">
                <path d="M12 2C8.13 2 5 5.13 5 9c0 5.25 7 13 7 13s7-7.75 7-13c0-3.87-3.13-7-7-7z"
                  fill="rgba(66,133,244,0.3)" stroke="#4285F4" strokeWidth="1.5"/>
                <circle cx="12" cy="9" r="2.5" fill="#4285F4"/>
              </svg>
            </div>
            <div className="flex-1">
              <p className="text-[14px] font-semibold text-white leading-tight">Ver grupos en el mapa</p>
              <p className="text-[11px] text-[#444] font-medium">Descubre qué hay cerca de ti</p>
            </div>
            <svg width="16" height="16" fill="none" viewBox="0 0 24 24">
              <path d="M9 18l6-6-6-6" stroke="#333" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"/>
            </svg>
          </button>
        </div>

        {/* ── SEARCH BAR ──────────────────────────────────────────────────── */}
        <div className="px-5 mb-5">
          <div className="flex items-center gap-2 px-4 py-3 rounded-2xl"
            style={{ background: '#0e0e0e', border: '1px solid #1c1c1c' }}>
            <svg width="16" height="16" fill="none" viewBox="0 0 24 24">
              <circle cx="11" cy="11" r="8" stroke="#444" strokeWidth="2"/>
              <path d="M21 21l-4.35-4.35" stroke="#444" strokeWidth="2" strokeLinecap="round"/>
            </svg>
            <input
              className="flex-1 bg-transparent text-[14px] text-white outline-none placeholder:text-[#333]"
              placeholder="Buscar grupo, género o ciudad..."
              value={search}
              onChange={e => setSearch(e.target.value)}
            />
            {/* Location btn */}
            <button className="w-7 h-7 rounded-xl flex items-center justify-center"
              style={{ background: '#151515' }}>
              <svg width="13" height="13" fill="none" viewBox="0 0 24 24">
                <path d="M12 2C8.13 2 5 5.13 5 9c0 5.25 7 13 7 13s7-7.75 7-13c0-3.87-3.13-7-7-7z"
                  stroke="#555" strokeWidth="1.8"/>
                <circle cx="12" cy="9" r="2.5" stroke="#555" strokeWidth="1.8"/>
              </svg>
            </button>
          </div>
        </div>

        {/* ── RECOMENDADOS ─────────────────────────────────────────────────── */}
        <div className="mb-5">
          <div className="flex items-center justify-between px-5 mb-3">
            <p className="text-[15px] font-bold text-white">Recomendados</p>
            <button className="text-[12px] font-semibold" style={{ color: '#00E676' }}>Ver todos</button>
          </div>
          <div className="flex gap-3 overflow-x-auto px-5 pb-2" style={{ scrollbarWidth: 'none' }}>
            {RECOMMENDED.map(g => <GroupCard key={g.id} g={g} large />)}
          </div>
        </div>

        {/* ── DESTACADOS ───────────────────────────────────────────────────── */}
        <div className="mb-6 flex-1">
          <div className="flex items-center justify-between px-5 mb-3">
            <p className="text-[15px] font-bold text-white">Destacados</p>
            <span className="text-[11px] text-[#444] font-medium">{FEATURED.length} grupos</span>
          </div>
          <div className="flex gap-3 overflow-x-auto px-5 pb-2" style={{ scrollbarWidth: 'none' }}>
            {FEATURED.map(g => <GroupCard key={g.id} g={g} />)}
          </div>

          {/* Grid 2-col below */}
          <div className="grid grid-cols-2 gap-3 px-5 mt-3">
            {FEATURED.slice(0, 4).map(g => {
              const initials = g.name.split(' ').map((w: string) => w[0]).join('').slice(0,2).toUpperCase();
              const hue = (g.id * 53) % 360;
              return (
                <div key={`grid-${g.id}`} className="rounded-2xl p-3 border border-[#1c1c1c]"
                  style={{ background: '#0e0e0e' }}>
                  <div className="flex items-center gap-2 mb-2">
                    <div className="w-9 h-9 rounded-xl flex items-center justify-center text-[12px] font-black flex-shrink-0"
                      style={{ background: `hsl(${hue},30%,12%)`, color: `hsl(${hue},60%,60%)` }}>
                      {initials}
                    </div>
                    <div className="flex-1 min-w-0">
                      <div className="flex items-center gap-1">
                        <p className="text-[12px] font-bold text-white truncate">{g.name}</p>
                        {g.verified && <Verified />}
                      </div>
                      <p className="text-[10px] text-[#444]">{g.city}</p>
                    </div>
                  </div>
                  <div className="flex items-center justify-between">
                    <Stars rating={g.rating} />
                    <span className="text-[11px] font-bold" style={{ color: '#00E676' }}>
                      ${(g.price/1000).toFixed(1)}k
                    </span>
                  </div>
                </div>
              );
            })}
          </div>
        </div>

        {/* ── BOTTOM NAV ───────────────────────────────────────────────────── */}
        <div className="sticky bottom-0 pt-2 pb-6"
          style={{
            background: 'linear-gradient(to top, #000000 70%, transparent)',
          }}>
          <div className="flex items-center justify-around mx-5 py-3 px-2 rounded-2xl"
            style={{
              background: 'rgba(14,14,14,0.95)',
              border: '1px solid #1c1c1c',
              backdropFilter: 'blur(20px)',
              boxShadow: '0 -4px 30px rgba(0,0,0,0.5)',
            }}>
            {NAV_ITEMS.map(item => (
              <button key={item.label} className="flex flex-col items-center gap-1 px-3 py-1">
                <span className={`text-[22px] ${!item.active && 'opacity-40'}`}>{item.icon}</span>
                <span className={`text-[10px] font-semibold ${item.active ? 'text-[#00E676]' : 'text-[#444]'}`}>
                  {item.label}
                </span>
                {item.active && (
                  <span className="w-1 h-1 rounded-full bg-[#00E676] -mt-0.5"/>
                )}
              </button>
            ))}
          </div>
        </div>

      </div>
    </div>
  );
}
