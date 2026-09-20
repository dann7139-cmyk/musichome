import Link from "next/link";
import Navbar from "@/components/Navbar";
import Footer from "@/components/Footer";
import IntroSplash from "@/components/IntroSplash";

// ── Static feature/step data ─────────────────────────────────────────────────

const FEATURES = [
  {
    icon: "🎵",
    title: "Miles de grupos verificados",
    desc:  "Bands, DJs, mariachis, tríos y más. Todos verificados por nuestro equipo.",
  },
  {
    icon: "⚡",
    title: "Reserva en minutos",
    desc:  "Selecciona fecha, paga el anticipo y listo. Sin llamadas ni intermediarios.",
  },
  {
    icon: "🛡️",
    title: "Pago seguro garantizado",
    desc:  "Tu dinero está protegido hasta que el evento concluya satisfactoriamente.",
  },
  {
    icon: "⭐",
    title: "Reseñas reales",
    desc:  "Lee opiniones verificadas de quienes ya contrataron al grupo.",
  },
  {
    icon: "📅",
    title: "Disponibilidad en tiempo real",
    desc:  "Ve al instante si el grupo está libre en tu fecha.",
  },
  {
    icon: "🎯",
    title: "Personaliza tu paquete",
    desc:  "Elige horas, integrantes y extras según tu presupuesto.",
  },
];

const STEPS = [
  {
    num:   "01",
    title: "Busca tu grupo",
    desc:  "Filtra por ciudad, género musical, precio y disponibilidad.",
  },
  {
    num:   "02",
    title: "Elige y reserva",
    desc:  "Selecciona la fecha, el paquete y paga el anticipo en segundos.",
  },
  {
    num:   "03",
    title: "Disfruta el evento",
    desc:  "El grupo llega puntual. El pago restante se libera al terminar.",
  },
];

const CATEGORIES = [
  { emoji: "🎸", label: "Banda" },
  { emoji: "🎹", label: "Trio" },
  { emoji: "🎺", label: "Mariachi" },
  { emoji: "🎧", label: "DJ" },
  { emoji: "🎻", label: "Cuarteto" },
  { emoji: "🎤", label: "Solista" },
  { emoji: "🥁", label: "Percusión" },
  { emoji: "🎷", label: "Jazz" },
];

// ── Page ─────────────────────────────────────────────────────────────────────

export default function LandingPage() {
  return (
    <div className="min-h-screen bg-brand-bg text-brand-text">
      <IntroSplash />
      <Navbar />

      {/* ── HERO ─────────────────────────────────────────────────────────── */}
      <section className="relative flex min-h-screen flex-col items-center justify-center overflow-hidden px-4 pt-16 text-center">
        {/* Radial glow */}
        <div
          aria-hidden
          className="pointer-events-none absolute inset-0"
          style={{
            background:
              "radial-gradient(ellipse 70% 40% at 50% 0%, rgba(0,230,118,0.12), transparent 70%)",
          }}
        />
        {/* Grid pattern */}
        <div
          aria-hidden
          className="pointer-events-none absolute inset-0 opacity-[0.03]"
          style={{
            backgroundImage:
              "linear-gradient(#fff 1px, transparent 1px), linear-gradient(90deg, #fff 1px, transparent 1px)",
            backgroundSize: "60px 60px",
          }}
        />

        <div className="relative z-10 mx-auto max-w-4xl">
          {/* Badge */}
          <div className="mb-6 inline-flex items-center gap-2 rounded-full border border-brand-green/30 bg-brand-green/5 px-4 py-1.5">
            <span className="h-2 w-2 rounded-full bg-brand-green animate-pulse" />
            <span className="text-sm font-medium text-brand-green">
              +1,200 grupos disponibles en México
            </span>
          </div>

          <h1 className="mb-6 text-5xl font-extrabold leading-tight tracking-tight text-white sm:text-6xl lg:text-7xl">
            Contrata grupos
            <br />
            <span className="text-brand-green">en minutos</span>
          </h1>

          <p className="mb-10 mx-auto max-w-2xl text-lg text-brand-muted sm:text-xl">
            Encuentra el mejor grupo para tu evento con{" "}
            <strong className="text-white">DARICEFY</strong>. Bodas,
            quinceañeras, empresariales y más. Pago seguro, disponibilidad
            real.
          </p>

          <div className="flex flex-col items-center gap-4 sm:flex-row sm:justify-center">
            <Link
              href="/grupos"
              className="rounded-xl bg-brand-green px-8 py-4 text-base font-bold text-black shadow-lg shadow-brand-green/20 transition-all hover:bg-brand-green2 hover:shadow-brand-green/40 active:scale-95"
            >
              Buscar proveedores
            </Link>
            <Link
              href="/registro"
              className="rounded-xl border border-brand-border px-8 py-4 text-base font-medium text-white transition-colors hover:border-brand-green hover:text-brand-green"
            >
              Quiero ser proveedor →
            </Link>
          </div>

          {/* Petición real: "quiero que el cliente sepa que se tiene que
              registrar con esa misma cuenta [con la que] ingresa en la
              app" — la cuenta es una sola, compartida entre web y app. */}
          <p className="mt-5 text-xs text-brand-muted">
            Tu cuenta es una sola: regístrate aquí o en la app, y usa el mismo correo y contraseña en ambos.
          </p>

          {/* Stats */}
          <div className="mt-16 grid grid-cols-3 gap-6 border-t border-brand-border pt-10">
            {[
              { val: "1,200+", label: "Grupos activos" },
              { val: "8,500+", label: "Eventos realizados" },
              { val: "4.9★",   label: "Calificación promedio" },
            ].map((s) => (
              <div key={s.label} className="text-center">
                <p className="text-2xl font-extrabold text-white sm:text-3xl">{s.val}</p>
                <p className="mt-1 text-sm text-brand-muted">{s.label}</p>
              </div>
            ))}
          </div>
        </div>

        {/* Scroll hint */}
        <div className="absolute bottom-8 left-1/2 -translate-x-1/2 animate-bounce">
          <svg viewBox="0 0 24 24" className="h-6 w-6 fill-brand-muted">
            <path d="M7.41 8.59L12 13.17l4.59-4.58L18 10l-6 6-6-6 1.41-1.41z" />
          </svg>
        </div>
      </section>

      {/* ── CATEGORÍAS ───────────────────────────────────────────────────── */}
      <section className="border-y border-brand-border bg-brand-card py-12">
        <div className="mx-auto max-w-7xl px-4 sm:px-6 lg:px-8">
          <div className="flex flex-wrap items-center justify-center gap-3">
            {CATEGORIES.map((c) => (
              <Link
                key={c.label}
                href={`/grupos?categoria=${c.label.toLowerCase()}`}
                className="flex items-center gap-2 rounded-full border border-brand-border bg-brand-card2 px-5 py-2.5 text-sm font-medium text-brand-text transition-all hover:border-brand-green hover:text-brand-green"
              >
                <span>{c.emoji}</span>
                {c.label}
              </Link>
            ))}
          </div>
        </div>
      </section>

      {/* ── CÓMO FUNCIONA ─────────────────────────────────────────────────── */}
      <section id="como-funciona" className="py-24 px-4">
        <div className="mx-auto max-w-7xl sm:px-6 lg:px-8">
          <div className="mb-16 text-center">
            <p className="mb-2 text-sm font-semibold uppercase tracking-widest text-brand-green">
              Proceso simple
            </p>
            <h2 className="text-3xl font-extrabold text-white sm:text-4xl">
              ¿Cómo funciona?
            </h2>
          </div>

          <div className="grid gap-8 md:grid-cols-3">
            {STEPS.map((step, i) => (
              <div key={step.num} className="relative flex flex-col items-center text-center">
                {/* Connector line */}
                {i < STEPS.length - 1 && (
                  <div className="absolute left-1/2 top-10 hidden h-0.5 w-full translate-x-1/2 bg-gradient-to-r from-brand-green/40 to-transparent md:block" />
                )}
                <div className="relative mb-6 flex h-20 w-20 items-center justify-center rounded-2xl border border-brand-green/30 bg-brand-card">
                  <span className="text-3xl font-extrabold text-brand-green opacity-40">
                    {step.num}
                  </span>
                </div>
                <h3 className="mb-2 text-lg font-bold text-white">{step.title}</h3>
                <p className="text-sm leading-relaxed text-brand-muted">{step.desc}</p>
              </div>
            ))}
          </div>
        </div>
      </section>

      {/* ── FEATURES ─────────────────────────────────────────────────────── */}
      <section className="bg-brand-card py-24 px-4">
        <div className="mx-auto max-w-7xl sm:px-6 lg:px-8">
          <div className="mb-16 text-center">
            <p className="mb-2 text-sm font-semibold uppercase tracking-widest text-brand-green">
              Por qué elegirnos
            </p>
            <h2 className="text-3xl font-extrabold text-white sm:text-4xl">
              Todo lo que necesitas
            </h2>
          </div>

          <div className="grid gap-6 sm:grid-cols-2 lg:grid-cols-3">
            {FEATURES.map((f) => (
              <div
                key={f.title}
                className="group rounded-2xl border border-brand-border bg-brand-card2 p-6 transition-all hover:border-brand-green/40"
              >
                <span className="mb-4 block text-3xl">{f.icon}</span>
                <h3 className="mb-2 text-base font-bold text-white">{f.title}</h3>
                <p className="text-sm leading-relaxed text-brand-muted">{f.desc}</p>
              </div>
            ))}
          </div>
        </div>
      </section>

      {/* ── PARA GRUPOS ───────────────────────────────────────────────────── */}
      <section id="para-grupos" className="py-24 px-4">
        <div className="mx-auto max-w-7xl sm:px-6 lg:px-8">
          <div className="overflow-hidden rounded-3xl border border-brand-green/20 bg-brand-card">
            <div className="grid md:grid-cols-2">
              {/* Text */}
              <div className="flex flex-col justify-center p-10 lg:p-16">
                <p className="mb-3 text-sm font-semibold uppercase tracking-widest text-brand-green">
                  Para grupos musicales
                </p>
                <h2 className="mb-4 text-3xl font-extrabold text-white sm:text-4xl">
                  Haz crecer tu agenda de eventos
                </h2>
                <p className="mb-8 text-brand-muted">
                  Regístrate gratis, publica tu perfil y empieza a recibir
                  solicitudes de clientes en tu ciudad. Gestiona todo desde la
                  app o la web.
                </p>
                <ul className="mb-8 space-y-3">
                  {[
                    "Perfil profesional con fotos y videos",
                    "Pagos protegidos con anticipo garantizado",
                    "Panel de eventos y agenda integrada",
                    "Métricas de rendimiento y reputación",
                  ].map((item) => (
                    <li key={item} className="flex items-center gap-3 text-sm text-brand-text">
                      <span className="flex h-5 w-5 shrink-0 items-center justify-center rounded-full bg-brand-green/15 text-brand-green">
                        ✓
                      </span>
                      {item}
                    </li>
                  ))}
                </ul>
                <Link
                  href="/registro?rol=grupo"
                  className="inline-flex w-fit rounded-xl bg-brand-green px-6 py-3 text-sm font-bold text-black transition-colors hover:bg-brand-green2"
                >
                  Unirme como grupo →
                </Link>
              </div>

              {/* Visual panel */}
              <div className="flex items-center justify-center bg-brand-card2 p-10">
                <div className="w-full max-w-sm rounded-2xl border border-brand-border bg-brand-bg p-6">
                  <div className="mb-4 flex items-center gap-3">
                    <div className="h-12 w-12 rounded-xl bg-brand-green/20 flex items-center justify-center text-2xl">
                      🎸
                    </div>
                    <div>
                      <p className="font-bold text-white">Tu Grupo</p>
                      <p className="text-xs text-brand-muted">Guadalajara · Rock</p>
                    </div>
                  </div>
                  <div className="grid grid-cols-3 gap-3 mb-4">
                    {[
                      { val: "48", label: "Eventos" },
                      { val: "4.9", label: "Rating" },
                      { val: "$12k", label: "Ganado" },
                    ].map((s) => (
                      <div key={s.label} className="rounded-xl bg-brand-card p-3 text-center">
                        <p className="text-lg font-bold text-brand-green">{s.val}</p>
                        <p className="text-[10px] text-brand-muted">{s.label}</p>
                      </div>
                    ))}
                  </div>
                  <div className="rounded-xl bg-brand-green/10 border border-brand-green/20 p-3 text-center">
                    <p className="text-xs font-medium text-brand-green">
                      ✓ Verificado · Top en tu ciudad
                    </p>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>
      </section>

      {/* ── CTA FINAL ─────────────────────────────────────────────────────── */}
      <section className="bg-brand-card py-24 px-4 text-center">
        <div className="mx-auto max-w-2xl">
          <h2 className="mb-4 text-3xl font-extrabold text-white sm:text-4xl">
            ¿Listo para tu próximo evento?
          </h2>
          <p className="mb-8 text-brand-muted">
            Únete a miles de clientes que ya contrataron con DARICEFY.
          </p>
          <div className="flex flex-col items-center gap-4 sm:flex-row sm:justify-center">
            <Link
              href="/grupos"
              className="rounded-xl bg-brand-green px-8 py-4 text-base font-bold text-black shadow-lg shadow-brand-green/20 transition-all hover:bg-brand-green2 active:scale-95"
            >
              Buscar grupos ahora
            </Link>
            <Link
              href="/registro"
              className="rounded-xl border border-brand-border px-8 py-4 text-base font-medium text-white transition-colors hover:border-brand-green"
            >
              Crear cuenta gratis
            </Link>
          </div>
        </div>
      </section>

      <Footer />
    </div>
  );
}
