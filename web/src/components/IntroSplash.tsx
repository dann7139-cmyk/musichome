"use client";

/**
 * Pantalla de bienvenida al entrar a la web — petición real: "quiero que
 * cuando me meto a la página salga el logo y el botón de ingresar, haz un
 * mensaje de presentación profesional". La primera versión era una
 * animación de 1.75s que se autodesvanecía — el usuario reportó que "no
 * jaló bien" (demasiado rápida para verse, sin ningún botón real). Ahora
 * es una pantalla de bienvenida de verdad: se queda hasta que el usuario
 * decide qué hacer (Ingresar, o seguir explorando sin cuenta).
 *
 * Solo se muestra UNA vez por sesión de navegador (sessionStorage) —
 * navegar dentro del sitio no la repite, solo una visita nueva.
 */

import { useEffect, useState } from "react";
import Image from "next/image";
import { useRouter } from "next/navigation";

const SEEN_KEY = "daricefy_intro_seen";

export default function IntroSplash() {
  const router = useRouter();
  const [visible, setVisible] = useState(false);
  const [leaving, setLeaving] = useState(false);

  useEffect(() => {
    let alreadySeen = true;
    try { alreadySeen = sessionStorage.getItem(SEEN_KEY) === "1"; } catch {}
    if (alreadySeen) return;

    setVisible(true);
    try { sessionStorage.setItem(SEEN_KEY, "1"); } catch {}
  }, []);

  const dismiss = (after?: () => void) => {
    setLeaving(true);
    setTimeout(() => { setVisible(false); after?.(); }, 350);
  };

  if (!visible) return null;

  return (
    <div
      className={`fixed inset-0 z-[200] flex flex-col items-center justify-center gap-8 bg-brand-bg px-6 text-center transition-opacity duration-300 ${leaving ? "pointer-events-none opacity-0" : "opacity-100"}`}
    >
      <div aria-hidden className="pointer-events-none absolute inset-0" style={{ background: "radial-gradient(ellipse 60% 45% at 50% 30%, rgba(0,230,118,0.10), transparent 70%)" }} />

      <div className={`relative flex flex-col items-center gap-5 transition-all duration-500 ${leaving ? "scale-95 opacity-0" : "scale-100 opacity-100"}`}>
        <div className="relative flex h-20 w-20 items-center justify-center">
          <span className="absolute inset-0 animate-[introPulse_2.2s_ease-out_infinite] rounded-full bg-brand-green/25 blur-xl" />
          <span className="absolute inset-0 rounded-full border border-brand-green/30" />
          <Image src="/logo.png" alt="Daricefy" width={60} height={60} priority className="relative rounded-full" />
        </div>

        <span className="text-2xl font-extrabold tracking-[0.25em] text-white">DARICEFY</span>

        <p className="max-w-sm text-sm leading-relaxed text-brand-muted">
          La plataforma para encontrar y contratar grupos musicales y talento en vivo para tu evento —
          con pago seguro y disponibilidad real.
        </p>

        <div className="mt-2 flex w-full max-w-xs flex-col items-center gap-3">
          <button
            onClick={() => dismiss(() => router.push("/login"))}
            className="w-full rounded-xl bg-brand-green py-3.5 text-sm font-bold text-black shadow-lg shadow-brand-green/20 transition-all hover:bg-brand-green2 active:scale-95"
          >
            Ingresar
          </button>
          <button
            onClick={() => dismiss()}
            className="text-xs font-medium text-brand-muted transition-colors hover:text-white"
          >
            Continuar explorando sin cuenta →
          </button>
        </div>
      </div>

      <style>{`
        @keyframes introPulse {
          0%   { transform: scale(0.85); opacity: 0.9; }
          70%  { transform: scale(1.6);  opacity: 0; }
          100% { transform: scale(1.6);  opacity: 0; }
        }
      `}</style>
    </div>
  );
}
