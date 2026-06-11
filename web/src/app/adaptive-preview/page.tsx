'use client';
import { useState } from 'react';

// ── Mock data ──────────────────────────────────────────────────────────────
const GROUPS = [
  {
    id: 1, name: 'Orquesta Sabor', city: 'Pereira', rating: 4.9, verified: true,
    color: '#6366F1', tag: 'Salsa · Cumbia',
    img: 'https://images.unsplash.com/photo-1511192336575-5a79af67a629?w=400&q=80',
  },
  {
    id: 2, name: 'DJ Vibra Pro', city: 'Manizales', rating: 4.8, verified: true,
    color: '#00E676', tag: 'Electrónica · Pop',
    img: 'https://images.unsplash.com/photo-1571266028243-e4733b0f0bb0?w=400&q=80',
  },
  {
    id: 3, name: 'Mariachi El Sol', city: 'Cali', rating: 4.7, verified: false,
    color: '#F59E0B', tag: 'Mariachi · Ranchera',
    img: 'https://images.unsplash.com/photo-1493225457124-a3eb161ffa5f?w=400&q=80',
  },
  {
    id: 4, name: 'Banda Caribe', city: 'Bogotá', rating: 4.9, verified: true,
    color: '#EF4444', tag: 'Vallenato · Tropical',
    img: 'https://images.unsplash.com/photo-1516450360452-9312f5e86fc7?w=400&q=80',
  },
  {
    id: 5, name: 'Jazz Quartet', city: 'Medellín', rating: 4.8, verified: true,
    color: '#3B82F6', tag: 'Jazz · Blues',
    img: 'https://images.unsplash.com/photo-1415201364774-f6f0bb35f28f?w=400&q=80',
  },
  {
    id: 6, name: 'Cumbia Kings', city: 'Cartagena', rating: 4.7, verified: true,
    color: '#EC4899', tag: 'Cumbia · Costeño',
    img: 'https://images.unsplash.com/photo-1464375117522-1311d6a5b81f?w=400&q=80',
  },
  {
    id: 7, name: 'Rock en Vivo', city: 'Bogotá', rating: 4.8, verified: false,
    color: '#8B5CF6', tag: 'Rock · Alternativo',
    img: 'https://images.unsplash.com/photo-1498038432885-c6f3f1b912ee?w=400&q=80',
  },
  {
    id: 8, name: 'Salsa Brava', city: 'Cali', rating: 4.9, verified: true,
    color: '#06B6D4', tag: 'Salsa · Choke',
    img: 'https://images.unsplash.com/photo-1470225620780-dba8ba36b745?w=400&q=80',
  },
];

const NAV_ITEMS = [
  { icon: '🏠', label: 'Explorar',   active: true  },
  { icon: '📋', label: 'Propuestas', active: false },
  { icon: '🗺️', label: 'Mapa',       active: false },
  { icon: '📅', label: 'Reservas',   active: false },
  { icon: '👤', label: 'Perfil',     active: false },
];

// ── Helpers ────────────────────────────────────────────────────────────────
function Logo() {
  return (
    <span className="font-black tracking-tight select-none" style={{ fontSize: 'inherit' }}>
      Darice<span className="text-emerald-400">fy</span>
    </span>
  );
}

function StarRating({ rating }: { rating: number }) {
  return (
    <span className="flex items-center gap-1">
      <svg className="w-3 h-3 fill-amber-400" viewBox="0 0 20 20">
        <path d="M9.049 2.927c.3-.921 1.603-.921 1.902 0l1.07 3.292a1 1 0 00.95.69h3.462c.969 0 1.371 1.24.588 1.81l-2.8 2.034a1 1 0 00-.364 1.118l1.07 3.292c.3.921-.755 1.688-1.54 1.118l-2.8-2.034a1 1 0 00-1.175 0l-2.8 2.034c-.784.57-1.838-.197-1.539-1.118l1.07-3.292a1 1 0 00-.364-1.118L2.98 8.72c-.783-.57-.38-1.81.588-1.81h3.461a1 1 0 00.951-.69l1.07-3.292z" />
      </svg>
      <span className="text-xs font-semibold text-amber-400">{rating.toFixed(1)}</span>
    </span>
  );
}

// ── Group card with real photo + hover glow ────────────────────────────────
function GroupCard({ group, desktop, compact = false }: { group: typeof GROUPS[0]; desktop: boolean; compact?: boolean }) {
  const [hovered, setHovered] = useState(false);
  const [imgError, setImgError] = useState(false);

  return (
    <div
      onMouseEnter={() => setHovered(true)}
      onMouseLeave={() => setHovered(false)}
      className="rounded-2xl overflow-hidden cursor-pointer"
      style={{
        backgroundColor: '#0e0e0e',
        border: `1px solid ${hovered && desktop ? group.color + '55' : '#1c1c1c'}`,
        transform: hovered && desktop ? 'translateY(-5px) scale(1.015)' : 'none',
        boxShadow: hovered && desktop
          ? `0 12px 32px ${group.color}30, 0 0 0 1px ${group.color}22`
          : '0 2px 8px rgba(0,0,0,0.4)',
        transition: 'all 0.22s cubic-bezier(0.34, 1.56, 0.64, 1)',
      }}
    >
      {/* Photo */}
      <div
        className="w-full relative overflow-hidden"
        style={{ height: compact ? 72 : desktop ? 130 : 95 }}
      >
        {!imgError ? (
          // eslint-disable-next-line @next/next/no-img-element
          <img
            src={group.img}
            alt={group.name}
            className="w-full h-full object-cover"
            onError={() => setImgError(true)}
            style={{
              filter: hovered && desktop ? 'brightness(1.1)' : 'brightness(0.85)',
              transition: 'filter 0.2s',
            }}
          />
        ) : (
          <div
            className="w-full h-full flex items-center justify-center"
            style={{ background: `linear-gradient(135deg, ${group.color}22, ${group.color}08)` }}
          >
            <span className="font-black text-4xl" style={{ color: group.color, opacity: 0.5 }}>
              {group.name.charAt(0)}
            </span>
          </div>
        )}
        {/* Dark gradient overlay */}
        <div
          className="absolute inset-0"
          style={{ background: 'linear-gradient(to top, rgba(14,14,14,0.85) 0%, transparent 55%)' }}
        />
        {/* Verified badge */}
        {group.verified && (
          <div
            className="absolute top-2 right-2 text-[10px] font-bold px-1.5 py-0.5 rounded-full"
            style={{ backgroundColor: 'rgba(59,130,246,0.85)', color: '#fff', backdropFilter: 'blur(4px)' }}
          >
            ✓
          </div>
        )}
      </div>

      {/* Info */}
      {!compact && (
        <div className="p-3 flex flex-col gap-1">
          <span className="font-semibold text-white text-sm leading-tight">{group.name}</span>
          <StarRating rating={group.rating} />
          <div className="flex items-center gap-1 mt-0.5">
            <span className="text-[10px] text-gray-500">📍 {group.city}</span>
          </div>
          <span
            className="text-[10px] mt-1 px-2 py-0.5 rounded-full self-start font-medium"
            style={{ backgroundColor: `${group.color}18`, color: group.color }}
          >
            {group.tag}
          </span>
        </div>
      )}
      {compact && (
        <div className="px-2 pb-2">
          <div className="text-white text-[11px] font-semibold truncate">{group.name}</div>
          <div className="text-gray-500 text-[10px]">{group.city}</div>
        </div>
      )}
    </div>
  );
}

// ── Search bar ─────────────────────────────────────────────────────────────
function SearchBar({ placeholder = 'Buscar grupos, géneros...' }: { placeholder?: string }) {
  const [focused, setFocused] = useState(false);
  return (
    <div
      className="flex items-center gap-2 px-3 py-2.5 rounded-xl transition-all duration-150"
      style={{
        backgroundColor: '#0e0e0e',
        border: `1px solid ${focused ? 'rgba(0,230,118,0.35)' : '#1c1c1c'}`,
        boxShadow: focused ? '0 0 0 3px rgba(0,230,118,0.07)' : 'none',
      }}
    >
      <svg className="w-4 h-4 text-gray-500 shrink-0" fill="none" stroke="currentColor" viewBox="0 0 24 24">
        <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M21 21l-6-6m2-5a7 7 0 11-14 0 7 7 0 0114 0z" />
      </svg>
      <input
        type="text"
        placeholder={placeholder}
        onFocus={() => setFocused(true)}
        onBlur={() => setFocused(false)}
        className="bg-transparent text-sm text-white placeholder-gray-600 outline-none w-full"
      />
      {focused && (
        <span
          className="text-[10px] px-1.5 py-0.5 rounded font-medium shrink-0"
          style={{ backgroundColor: '#1c1c1c', color: '#555' }}
        >
          ⌘K
        </span>
      )}
    </div>
  );
}

// ── MOBILE ────────────────────────────────────────────────────────────────
function MobileView() {
  return (
    <div
      className="relative rounded-[2.5rem] overflow-hidden flex flex-col"
      style={{
        width: 375, height: 812,
        backgroundColor: '#040404',
        border: '8px solid #1a1a1a',
        boxShadow: '0 40px 80px rgba(0,0,0,0.8), inset 0 0 0 1px rgba(255,255,255,0.04)',
        flexShrink: 0,
      }}
    >
      {/* Status bar */}
      <div className="flex justify-between items-center px-6 pt-3 pb-1">
        <span className="text-white text-xs font-semibold">9:41</span>
        <div
          className="absolute top-3 left-1/2 -translate-x-1/2 w-24 h-5 rounded-full"
          style={{ backgroundColor: '#1a1a1a' }}
        />
        <div className="flex gap-1 items-center">
          <div className="w-4 h-2.5 rounded-sm border border-gray-500 relative">
            <div className="absolute inset-0.5 right-1.5 bg-white rounded-sm" />
          </div>
        </div>
      </div>

      {/* Header */}
      <div className="flex items-center justify-between px-5 py-2">
        <div>
          <div className="text-white font-black" style={{ fontSize: 22, letterSpacing: -0.5 }}><Logo /></div>
          <div className="text-gray-500 text-xs mt-0.5">Hola, Daniel 👋</div>
        </div>
        <div className="flex gap-2">
          <div className="w-9 h-9 rounded-xl flex items-center justify-center" style={{ backgroundColor: '#0e0e0e', border: '1px solid #1c1c1c' }}>
            <span className="text-sm">🔔</span>
          </div>
        </div>
      </div>

      {/* Propuestas hero */}
      <div className="px-5 mb-2">
        <div
          className="rounded-[18px] p-3 flex items-center gap-3 relative overflow-hidden"
          style={{ border: '1px solid rgba(0,230,118,0.22)', backgroundColor: '#061008', boxShadow: '0 0 20px rgba(0,230,118,0.10)' }}
        >
          <div className="absolute -top-5 -left-5 w-20 h-20 rounded-full" style={{ backgroundColor: 'rgba(0,230,118,0.06)' }} />
          <div className="w-9 h-9 rounded-[11px] flex items-center justify-center shrink-0" style={{ backgroundColor: 'rgba(0,230,118,0.15)', border: '1px solid rgba(0,230,118,0.3)' }}>
            <span className="text-base">⚡</span>
          </div>
          <div className="flex-1 min-w-0">
            <div className="flex items-center gap-1.5 mb-0.5">
              <div className="w-[5px] h-[5px] rounded-full animate-pulse" style={{ backgroundColor: '#00E676' }} />
              <span className="text-[9px] font-semibold uppercase tracking-wider" style={{ color: '#00E676' }}>Express · En minutos</span>
            </div>
            <div className="text-white font-black text-[13px] leading-tight mb-1">Recibe propuestas en minutos</div>
            <div className="text-[11px] mb-2" style={{ color: '#4a7a5a' }}>Contrata música para tu evento</div>
            <div className="inline-flex px-3 py-1 rounded-2xl text-[11px] font-bold text-black" style={{ backgroundColor: '#00E676' }}>
              Solicitar ahora →
            </div>
          </div>
        </div>
      </div>

      {/* Mapa glass */}
      <div className="px-5 mb-3">
        <div className="rounded-[18px] p-3 flex items-center gap-3" style={{ backgroundColor: 'rgba(255,255,255,0.03)', border: '1px solid rgba(255,255,255,0.07)' }}>
          <div className="w-10 h-10 rounded-xl flex items-center justify-center" style={{ backgroundColor: 'rgba(66,133,244,0.12)', border: '1px solid rgba(66,133,244,0.25)' }}>
            <span className="text-lg">🗺️</span>
          </div>
          <div className="flex-1">
            <div className="text-white text-sm font-semibold">Ver grupos en el mapa</div>
            <div className="text-gray-500 text-xs mt-0.5">Descubre qué hay cerca de ti</div>
          </div>
          <span className="text-gray-500 text-xl font-light">›</span>
        </div>
      </div>

      {/* Search */}
      <div className="px-5 mb-3">
        <SearchBar placeholder="Buscar grupos..." />
      </div>

      {/* Groups 2-col */}
      <div className="px-5 flex-1 overflow-hidden">
        <div className="flex items-center justify-between mb-2">
          <span className="text-white font-bold text-sm">Destacados</span>
          <span className="text-emerald-400 text-xs">Ver todos →</span>
        </div>
        <div className="grid grid-cols-2 gap-2">
          {GROUPS.slice(0, 4).map(g => <GroupCard key={g.id} group={g} desktop={false} />)}
        </div>
      </div>

      {/* Bottom nav */}
      <div
        className="flex items-center justify-around px-2 py-2 mt-1"
        style={{ backgroundColor: 'rgba(6,6,6,0.97)', backdropFilter: 'blur(20px)', borderTop: '1px solid #111' }}
      >
        {NAV_ITEMS.map(item => (
          <div key={item.label} className="flex flex-col items-center gap-0.5 px-2">
            <span className={`text-[18px] ${item.active ? '' : 'opacity-25'}`}>{item.icon}</span>
            <span className={`text-[9px] font-medium ${item.active ? 'text-emerald-400' : 'text-gray-600'}`}>{item.label}</span>
            {item.active && <div className="w-1 h-1 rounded-full bg-emerald-400 mt-0.5" />}
          </div>
        ))}
      </div>
    </div>
  );
}

// ── DESKTOP / WINDOWS ─────────────────────────────────────────────────────
function SidebarItem({ item }: { item: typeof NAV_ITEMS[0] }) {
  const [hovered, setHovered] = useState(false);
  return (
    <div
      onMouseEnter={() => setHovered(true)}
      onMouseLeave={() => setHovered(false)}
      className="flex items-center gap-3 px-3 py-2 rounded-xl cursor-pointer transition-all duration-150"
      style={{
        backgroundColor: item.active ? 'rgba(0,230,118,0.08)' : hovered ? 'rgba(255,255,255,0.04)' : 'transparent',
        borderLeft: `2px solid ${item.active ? '#00E676' : 'transparent'}`,
      }}
    >
      <span className={`text-lg ${!item.active && !hovered ? 'opacity-30' : ''}`}>{item.icon}</span>
      <span className="text-sm font-medium" style={{ color: item.active ? '#00E676' : hovered ? '#fff' : '#444' }}>
        {item.label}
      </span>
      {item.active && <div className="ml-auto w-1.5 h-1.5 rounded-full bg-emerald-400" />}
    </div>
  );
}

function DesktopView() {
  return (
    <div
      className="rounded-2xl overflow-hidden flex"
      style={{
        width: 960, height: 660,
        backgroundColor: '#040404',
        border: '1px solid #1c1c1c',
        boxShadow: '0 40px 80px rgba(0,0,0,0.7)',
        flexShrink: 0,
      }}
    >
      {/* Sidebar */}
      <div className="flex flex-col py-6 px-3 gap-1" style={{ width: 210, backgroundColor: '#060606', borderRight: '1px solid #111' }}>
        <div className="px-3 mb-5">
          <div className="text-white font-black text-xl" style={{ letterSpacing: -0.5 }}><Logo /></div>
          <div className="text-gray-600 text-xs mt-0.5">Panel de exploración</div>
        </div>
        {NAV_ITEMS.map(item => <SidebarItem key={item.label} item={item} />)}

        {/* Bottom profile */}
        <div className="mt-auto px-1">
          <div className="flex items-center gap-2.5 p-2.5 rounded-xl cursor-pointer" style={{ backgroundColor: '#0a0a0a', border: '1px solid #1a1a1a' }}>
            <div className="w-8 h-8 rounded-full flex items-center justify-center font-bold text-sm shrink-0" style={{ backgroundColor: 'rgba(0,230,118,0.15)', color: '#00E676' }}>D</div>
            <div className="flex-1 min-w-0">
              <div className="text-white text-xs font-semibold">Daniel R.</div>
              <div className="text-gray-600 text-[10px]">Cliente · Pereira</div>
            </div>
            <span className="text-gray-600 text-xs">⋯</span>
          </div>
        </div>
      </div>

      {/* Main */}
      <div className="flex-1 overflow-y-auto flex flex-col">
        {/* Topbar */}
        <div className="flex items-center gap-3 px-6 py-4" style={{ borderBottom: '1px solid #0e0e0e' }}>
          <div className="flex-1">
            <div className="text-white font-bold text-base">Explorar grupos</div>
            <div className="text-gray-500 text-xs">📍 Pereira, Colombia</div>
          </div>
          <div className="w-64"><SearchBar /></div>
          <div className="w-9 h-9 rounded-xl flex items-center justify-center relative" style={{ backgroundColor: '#0e0e0e', border: '1px solid #1a1a1a' }}>
            <span className="text-base">🔔</span>
            <div className="absolute top-1.5 right-1.5 w-2 h-2 rounded-full bg-emerald-400 border border-black" />
          </div>
        </div>

        <div className="p-5 flex flex-col gap-5 flex-1">
          {/* CTA row */}
          <div className="grid grid-cols-2 gap-3">
            {/* Propuestas */}
            <div
              className="rounded-2xl p-4 flex items-center gap-4 relative overflow-hidden cursor-pointer group"
              style={{ border: '1px solid rgba(0,230,118,0.20)', backgroundColor: '#061008', boxShadow: '0 0 24px rgba(0,230,118,0.08)' }}
            >
              <div className="absolute -top-10 -left-10 w-32 h-32 rounded-full transition-all duration-500 group-hover:scale-150 group-hover:opacity-100 opacity-60" style={{ backgroundColor: 'rgba(0,230,118,0.06)' }} />
              <div className="w-11 h-11 rounded-[13px] flex items-center justify-center text-xl shrink-0" style={{ backgroundColor: 'rgba(0,230,118,0.15)', border: '1px solid rgba(0,230,118,0.3)' }}>⚡</div>
              <div className="flex-1 z-10">
                <div className="flex items-center gap-2 mb-1">
                  <div className="w-1.5 h-1.5 rounded-full animate-pulse bg-emerald-400" />
                  <span className="text-[10px] font-semibold uppercase tracking-wider text-emerald-400">Express · En minutos</span>
                </div>
                <div className="text-white font-black text-sm leading-tight mb-1">Recibe propuestas en minutos</div>
                <div className="text-xs mb-2.5" style={{ color: '#4a7a5a' }}>Contrata música para tu evento</div>
                <div className="inline-flex px-3 py-1.5 rounded-full text-xs font-bold text-black" style={{ backgroundColor: '#00E676' }}>
                  Solicitar ahora →
                </div>
              </div>
            </div>

            {/* Mapa glass */}
            <div
              className="rounded-2xl p-4 flex items-center gap-4 cursor-pointer group transition-all duration-200"
              style={{ backgroundColor: 'rgba(255,255,255,0.025)', border: '1px solid rgba(255,255,255,0.06)' }}
            >
              <div className="w-14 h-14 rounded-2xl flex items-center justify-center text-3xl" style={{ backgroundColor: 'rgba(66,133,244,0.10)', border: '1px solid rgba(66,133,244,0.20)' }}>🗺️</div>
              <div>
                <div className="text-white font-semibold text-sm mb-1">Ver grupos en el mapa</div>
                <div className="text-gray-500 text-xs mb-2">Descubre músicos cerca de ti</div>
                <div className="inline-flex items-center gap-1 text-blue-400 text-xs font-medium">
                  Abrir mapa interactivo
                  <span>→</span>
                </div>
              </div>
            </div>
          </div>

          {/* Buscador sobre grupos */}
          <div>
            <div className="flex items-center justify-between mb-3">
              <div>
                <span className="text-white font-bold text-sm">Grupos destacados</span>
                <span className="text-gray-600 text-xs ml-2">· 8 disponibles hoy</span>
              </div>
              <div className="flex items-center gap-2">
                {['Todos', 'Salsa', 'Pop', 'Jazz', 'Rock'].map((f, i) => (
                  <span
                    key={f}
                    className="text-xs px-2.5 py-1 rounded-full cursor-pointer transition-all"
                    style={{
                      backgroundColor: i === 0 ? 'rgba(0,230,118,0.12)' : '#0e0e0e',
                      color: i === 0 ? '#00E676' : '#555',
                      border: `1px solid ${i === 0 ? 'rgba(0,230,118,0.25)' : '#1c1c1c'}`,
                    }}
                  >{f}</span>
                ))}
                <span className="text-emerald-400 text-xs cursor-pointer hover:underline">Ver todos →</span>
              </div>
            </div>

            {/* 4-col grid */}
            <div className="grid grid-cols-4 gap-3">
              {GROUPS.map(g => <GroupCard key={g.id} group={g} desktop={true} />)}
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}

// ── PAGE ──────────────────────────────────────────────────────────────────
export default function AdaptivePreviewPage() {
  return (
    <div
      className="min-h-screen flex flex-col items-center justify-start py-16 px-8 gap-24"
      style={{ backgroundColor: '#000', fontFamily: 'Inter, system-ui, sans-serif' }}
    >
      {/* Header */}
      <div className="text-center">
        <div className="font-black text-3xl mb-2 text-white" style={{ letterSpacing: -1 }}>
          Darice<span className="text-emerald-400">fy</span>
          <span className="font-light text-gray-600 text-lg ml-3">· Adaptive UI Preview</span>
        </div>
        <p className="text-gray-500 text-sm">React Native · Windows Store & Mobile · Diseño adaptativo</p>
      </div>

      {/* MOBILE */}
      <section className="flex flex-col items-center gap-5">
        <div className="flex items-center gap-4">
          <div className="h-px w-16" style={{ background: 'linear-gradient(to right, transparent, #222)' }} />
          <span className="text-gray-500 text-[11px] font-semibold uppercase tracking-widest">📱 Móvil · 375px</span>
          <div className="h-px w-16" style={{ background: 'linear-gradient(to left, transparent, #222)' }} />
        </div>
        <MobileView />
        <p className="text-gray-600 text-xs text-center">
          Nav inferior · Grid 2 col · Fotos reales · Glow verde · Glassmorphism
        </p>
      </section>

      {/* Breakpoint divider */}
      <div className="flex items-center gap-6 w-full max-w-5xl">
        <div className="flex-1 h-px" style={{ background: 'linear-gradient(to right, transparent, #1c1c1c)' }} />
        <div className="px-4 py-1.5 rounded-full text-xs font-semibold text-emerald-400" style={{ border: '1px solid rgba(0,230,118,0.2)', backgroundColor: 'rgba(0,230,118,0.05)' }}>
          ↔ Responsive breakpoint
        </div>
        <div className="flex-1 h-px" style={{ background: 'linear-gradient(to left, transparent, #1c1c1c)' }} />
      </div>

      {/* DESKTOP */}
      <section className="flex flex-col items-center gap-5">
        <div className="flex items-center gap-4">
          <div className="h-px w-16" style={{ background: 'linear-gradient(to right, transparent, #222)' }} />
          <span className="text-gray-500 text-[11px] font-semibold uppercase tracking-widest">🖥️ Windows · 960px+</span>
          <div className="h-px w-16" style={{ background: 'linear-gradient(to left, transparent, #222)' }} />
        </div>
        <DesktopView />
        <p className="text-gray-600 text-xs text-center">
          Sidebar + Grid 4 col + Hover lift & glow + Filtros de género + Búsqueda
        </p>
      </section>

      {/* Feature legend */}
      <div className="grid grid-cols-4 gap-6 max-w-3xl w-full text-center" style={{ borderTop: '1px solid #0e0e0e', paddingTop: 48 }}>
        {[
          { icon: '📸', title: 'Fotos reales',        desc: 'Imágenes de músicos reales con overlay degradado' },
          { icon: '🌟', title: 'Hover Premium',        desc: 'Lift + border glow del color del grupo' },
          { icon: '🔍', title: 'Buscador inteligente', desc: 'Focus ring verde, shortcut ⌘K en desktop' },
          { icon: '🎛️', title: 'Filtros de género',    desc: 'Salsa, Pop, Jazz, Rock — chips activos en verde' },
        ].map(f => (
          <div key={f.title} className="flex flex-col items-center gap-2">
            <span className="text-2xl">{f.icon}</span>
            <span className="text-white text-xs font-semibold">{f.title}</span>
            <span className="text-gray-600 text-[11px] leading-relaxed">{f.desc}</span>
          </div>
        ))}
      </div>
    </div>
  );
}
