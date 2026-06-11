'use client';
import { useState } from 'react';

const EVENTS = [
  {
    id: 1,
    name: 'Lala',
    date: 'Sáb 19 Abr · 21:00',
    location: 'Monterrey, NL',
    status: 'completed' as const,
    express: true,
    duration: '3h',
    earnings: 4830,
    type: 'Corporativo',
    image: null,
  },
];

const STATUS_MAP = {
  completed: { label: 'Completada', dot: '#00E676', bg: 'rgba(0,230,118,0.08)', text: '#00E676' },
  pending:   { label: 'Pendiente',  dot: '#FFC107', bg: 'rgba(255,193,7,0.08)',  text: '#FFC107' },
  upcoming:  { label: 'Próximo',    dot: '#90CAF9', bg: 'rgba(144,202,249,0.08)', text: '#90CAF9' },
};

export default function EventsPreview() {
  const [tab, setTab] = useState<'upcoming' | 'pending'>('upcoming');

  return (
    <div
      style={{ fontFamily: "'Inter', 'SF Pro Display', system-ui, sans-serif" }}
      className="min-h-screen bg-[#040404] text-white flex flex-col items-center py-10 px-4"
    >
      {/* ── Header / Wallet ─────────────────────────────── */}
      <div className="w-full max-w-sm">

        {/* Avatar + greeting */}
        <div className="flex items-center gap-3 mb-8">
          <div className="w-10 h-10 rounded-full bg-gradient-to-br from-[#00E676] to-[#00897B] flex items-center justify-center text-[#040404] font-bold text-sm select-none">
            DR
          </div>
          <div>
            <p className="text-[11px] text-[#555] uppercase tracking-widest font-medium">Bienvenido</p>
            <p className="text-[15px] font-semibold text-white leading-tight">Daniel Rivera</p>
          </div>
          <div className="ml-auto">
            <div className="w-8 h-8 rounded-full bg-[#111] flex items-center justify-center">
              <svg width="16" height="16" fill="none" viewBox="0 0 24 24">
                <path d="M18 8A6 6 0 0 0 6 8c0 7-3 9-3 9h18s-3-2-3-9" stroke="#888" strokeWidth="1.8" strokeLinecap="round"/>
                <path d="M13.73 21a2 2 0 0 1-3.46 0" stroke="#888" strokeWidth="1.8" strokeLinecap="round"/>
              </svg>
            </div>
          </div>
        </div>

        {/* Balance card */}
        <div
          className="relative rounded-3xl p-6 mb-8 overflow-hidden"
          style={{
            background: 'linear-gradient(135deg, #0e1f14 0%, #0a1a0f 50%, #061008 100%)',
            boxShadow: '0 0 0 1px rgba(0,230,118,0.12), 0 20px 60px rgba(0,0,0,0.6)',
          }}
        >
          {/* glow */}
          <div
            className="absolute -top-10 -right-10 w-44 h-44 rounded-full opacity-20 pointer-events-none"
            style={{ background: 'radial-gradient(circle, #00E676, transparent 70%)' }}
          />

          <p className="text-[11px] text-[#4CAF50] uppercase tracking-widest font-medium mb-1">Saldo disponible</p>
          <p className="text-[38px] font-black text-white leading-none tracking-tight">
            $4,830
            <span className="text-[18px] font-medium text-[#4CAF50] ml-1">MXN</span>
          </p>
          <p className="text-[12px] text-[#3a3a3a] mt-1">Actualizado hoy · 19 Abr 2026</p>

          <div className="mt-5 flex gap-3">
            <button
              className="flex-1 py-2.5 rounded-xl text-[13px] font-semibold text-[#040404]"
              style={{ background: 'linear-gradient(135deg, #00E676, #00C853)' }}
            >
              Retirar
            </button>
            <button
              className="flex-1 py-2.5 rounded-xl text-[13px] font-semibold text-[#00E676]"
              style={{ background: 'rgba(0,230,118,0.08)', border: '1px solid rgba(0,230,118,0.2)' }}
            >
              Historial
            </button>
          </div>
        </div>

        {/* ── Section title ───────────────────────────────── */}
        <div className="flex items-center justify-between mb-4">
          <p className="text-[17px] font-bold tracking-tight">Eventos</p>
          <p className="text-[12px] text-[#444] font-medium">1 evento</p>
        </div>

        {/* ── Tabs ────────────────────────────────────────── */}
        <div
          className="flex p-1 rounded-2xl mb-6"
          style={{ background: '#0e0e0e', border: '1px solid #1a1a1a' }}
        >
          {(['upcoming', 'pending'] as const).map((t) => (
            <button
              key={t}
              onClick={() => setTab(t)}
              className="flex-1 py-2 rounded-xl text-[13px] font-semibold transition-all duration-300"
              style={
                tab === t
                  ? {
                      background: 'linear-gradient(135deg, #00E676 0%, #00C853 100%)',
                      color: '#040404',
                      boxShadow: '0 4px 16px rgba(0,230,118,0.3)',
                    }
                  : { color: '#444' }
              }
            >
              {t === 'upcoming' ? 'Próximos' : 'Pendientes'}
            </button>
          ))}
        </div>

        {/* ── Event Card ──────────────────────────────────── */}
        {EVENTS.map((ev) => {
          const st = STATUS_MAP[ev.status];
          return (
            <div
              key={ev.id}
              className="rounded-3xl p-5 mb-4"
              style={{
                background: '#0e0e0e',
                border: '1px solid #1c1c1c',
                boxShadow: '0 8px 32px rgba(0,0,0,0.5)',
              }}
            >
              {/* Top row: name + badges */}
              <div className="flex items-start justify-between mb-4">
                <div>
                  <p className="text-[22px] font-black tracking-tight leading-none">{ev.name}</p>
                  <p className="text-[12px] text-[#444] mt-1 font-medium">{ev.type}</p>
                </div>
                <div className="flex flex-col items-end gap-1.5">
                  {/* Status badge */}
                  <span
                    className="flex items-center gap-1.5 px-3 py-1 rounded-full text-[11px] font-semibold"
                    style={{ background: st.bg, color: st.text }}
                  >
                    <span
                      className="w-1.5 h-1.5 rounded-full"
                      style={{ background: st.dot }}
                    />
                    {st.label}
                  </span>
                  {/* Express badge */}
                  {ev.express && (
                    <span
                      className="px-2.5 py-0.5 rounded-full text-[10px] font-bold tracking-wide"
                      style={{
                        background: 'rgba(255,193,7,0.1)',
                        color: '#FFC107',
                        border: '1px solid rgba(255,193,7,0.2)',
                      }}
                    >
                      ⚡ EXPRESS
                    </span>
                  )}
                </div>
              </div>

              {/* Divider */}
              <div className="h-px mb-4" style={{ background: '#181818' }} />

              {/* Meta row */}
              <div className="flex gap-5 mb-5">
                <div className="flex items-center gap-2">
                  <div
                    className="w-7 h-7 rounded-xl flex items-center justify-center"
                    style={{ background: '#151515' }}
                  >
                    <svg width="13" height="13" fill="none" viewBox="0 0 24 24">
                      <rect x="3" y="4" width="18" height="18" rx="3" stroke="#00E676" strokeWidth="1.8"/>
                      <path d="M3 9h18M8 2v4M16 2v4" stroke="#00E676" strokeWidth="1.8" strokeLinecap="round"/>
                    </svg>
                  </div>
                  <div>
                    <p className="text-[10px] text-[#3a3a3a] uppercase tracking-wider">Fecha</p>
                    <p className="text-[12px] font-semibold text-[#ccc]">{ev.date}</p>
                  </div>
                </div>

                <div className="flex items-center gap-2">
                  <div
                    className="w-7 h-7 rounded-xl flex items-center justify-center"
                    style={{ background: '#151515' }}
                  >
                    <svg width="13" height="13" fill="none" viewBox="0 0 24 24">
                      <path d="M12 2C8.13 2 5 5.13 5 9c0 5.25 7 13 7 13s7-7.75 7-13c0-3.87-3.13-7-7-7z" stroke="#00E676" strokeWidth="1.8"/>
                      <circle cx="12" cy="9" r="2.5" stroke="#00E676" strokeWidth="1.8"/>
                    </svg>
                  </div>
                  <div>
                    <p className="text-[10px] text-[#3a3a3a] uppercase tracking-wider">Lugar</p>
                    <p className="text-[12px] font-semibold text-[#ccc]">{ev.location}</p>
                  </div>
                </div>

                <div className="flex items-center gap-2">
                  <div
                    className="w-7 h-7 rounded-xl flex items-center justify-center"
                    style={{ background: '#151515' }}
                  >
                    <svg width="13" height="13" fill="none" viewBox="0 0 24 24">
                      <circle cx="12" cy="12" r="9" stroke="#00E676" strokeWidth="1.8"/>
                      <path d="M12 7v5l3 3" stroke="#00E676" strokeWidth="1.8" strokeLinecap="round"/>
                    </svg>
                  </div>
                  <div>
                    <p className="text-[10px] text-[#3a3a3a] uppercase tracking-wider">Duración</p>
                    <p className="text-[12px] font-semibold text-[#ccc]">{ev.duration}</p>
                  </div>
                </div>
              </div>

              {/* Earnings row */}
              <div
                className="rounded-2xl px-4 py-3 flex items-center justify-between mb-4"
                style={{ background: 'rgba(0,230,118,0.04)', border: '1px solid rgba(0,230,118,0.1)' }}
              >
                <div>
                  <p className="text-[10px] text-[#00C853] uppercase tracking-widest font-medium">Ganancia</p>
                  <p className="text-[20px] font-black text-[#00E676] leading-tight">
                    ${ev.earnings.toLocaleString()}
                    <span className="text-[12px] font-medium text-[#00C853] ml-1">MXN</span>
                  </p>
                </div>
                <div
                  className="w-10 h-10 rounded-2xl flex items-center justify-center"
                  style={{ background: 'rgba(0,230,118,0.12)' }}
                >
                  <svg width="18" height="18" fill="none" viewBox="0 0 24 24">
                    <path d="M12 2v20M17 5H9.5a3.5 3.5 0 0 0 0 7h5a3.5 3.5 0 0 1 0 7H6" stroke="#00E676" strokeWidth="2" strokeLinecap="round"/>
                  </svg>
                </div>
              </div>

              {/* CTA button */}
              <button
                className="w-full py-3.5 rounded-2xl text-[14px] font-bold tracking-wide flex items-center justify-center gap-2 transition-all duration-200 active:scale-[0.98]"
                style={{
                  background: '#111',
                  border: '1px solid #222',
                  color: '#fff',
                }}
              >
                Ver detalles de ganancias
                <svg width="14" height="14" fill="none" viewBox="0 0 24 24">
                  <path d="M5 12h14M13 6l6 6-6 6" stroke="#00E676" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"/>
                </svg>
              </button>
            </div>
          );
        })}

        {/* Empty state for Pendientes */}
        {tab === 'pending' && (
          <div
            className="rounded-3xl p-8 text-center"
            style={{ background: '#0e0e0e', border: '1px solid #1a1a1a' }}
          >
            <div
              className="w-12 h-12 rounded-2xl flex items-center justify-center mx-auto mb-3"
              style={{ background: '#151515' }}
            >
              <svg width="22" height="22" fill="none" viewBox="0 0 24 24">
                <circle cx="12" cy="12" r="9" stroke="#333" strokeWidth="1.8"/>
                <path d="M12 8v4l2 2" stroke="#333" strokeWidth="1.8" strokeLinecap="round"/>
              </svg>
            </div>
            <p className="text-[14px] font-semibold text-[#333]">Sin eventos pendientes</p>
            <p className="text-[12px] text-[#2a2a2a] mt-1">Todo al día ✓</p>
          </div>
        )}

        <p className="text-center text-[10px] text-[#222] mt-8 tracking-widest uppercase">
          MusicHome · Preview
        </p>
      </div>
    </div>
  );
}
