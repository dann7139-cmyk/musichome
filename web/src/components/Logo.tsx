"use client";

import Link from "next/link";

/**
 * DARICEFY logo with musical soul:
 *   D-A-R-I  →  Do-Re-Mi = the first three solfège notes
 *   C-E-F-Y  →  Create Every Frequency for You
 *
 * Visual: animated chromatic gradient text + live equalizer bars
 */
export default function Logo({ size = "md" }: { size?: "sm" | "md" | "lg" }) {
  const textClass =
    size === "lg"
      ? "text-4xl sm:text-5xl"
      : size === "sm"
      ? "text-base"
      : "text-xl";

  return (
    <Link href="/" className="group inline-flex items-center gap-2 select-none">
      {/* ── Animated equalizer (3 bars) ───────────────────────────────── */}
      <span className="flex items-end gap-[3px]" aria-hidden>
        {[
          { h: "14px", animation: "eqBar1 1.1s ease-in-out infinite" },
          { h: "20px", animation: "eqBar2 0.9s ease-in-out infinite 0.15s" },
          { h: "11px", animation: "eqBar3 1.3s ease-in-out infinite 0.3s" },
        ].map((bar, i) => (
          <span
            key={i}
            style={{
              display:         "block",
              width:           size === "sm" ? "2px" : "3px",
              height:          bar.h,
              borderRadius:    "2px",
              background:      "linear-gradient(to top, #00E676, #00C853)",
              animation:       bar.animation,
              transformOrigin: "bottom center",
              boxShadow:       "0 0 6px rgba(0,230,118,0.7)",
            }}
          />
        ))}
      </span>

      {/* ── DARI — solfège root ──────────────────────────────────────── */}
      <span
        className={`font-extrabold tracking-widest ${textClass}`}
        style={{
          background: "linear-gradient(270deg, #00E676, #80FFB8, #00C853, #ffffff, #00E676)",
          backgroundSize: "300% 300%",
          WebkitBackgroundClip: "text",
          WebkitTextFillColor: "transparent",
          backgroundClip: "text",
          animation: "logoShimmer 4s ease infinite, logoPulse 3s ease-in-out infinite",
        }}
      >
        DARI
      </span>

      {/* ── CEFY — frequency signature ──────────────────────────────── */}
      <span
        className={`font-extrabold tracking-widest ${textClass}`}
        style={{
          background: "linear-gradient(270deg, #ffffff, #00E676, #80FFB8, #00E676)",
          backgroundSize: "300% 300%",
          WebkitBackgroundClip: "text",
          WebkitTextFillColor: "transparent",
          backgroundClip: "text",
          animation: "logoShimmer 4s ease infinite 0.5s, logoPulse 3s ease-in-out infinite 1.5s",
        }}
      >
        CEFY
      </span>
    </Link>
  );
}
