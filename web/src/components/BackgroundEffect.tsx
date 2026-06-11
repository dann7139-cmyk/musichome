"use client";

// Beams: [left%, animDelay, animDuration, opacity, width, color, height%]
const BEAMS: [string, string, string, number, string, string, string][] = [
  ["2%",   "0s",    "3.8s", 0.55, "1px",   "#00E676", "55%"],
  ["6%",   "1.4s",  "5.2s", 0.20, "1px",   "#ffffff", "40%"],
  ["11%",  "0.6s",  "4.4s", 0.45, "2px",   "#00E676", "65%"],
  ["16%",  "2.2s",  "3.6s", 0.25, "1px",   "#00C853", "50%"],
  ["22%",  "0.9s",  "6.0s", 0.15, "1px",   "#ffffff", "35%"],
  ["27%",  "1.8s",  "4.8s", 0.50, "1px",   "#00E676", "70%"],
  ["33%",  "0.3s",  "5.5s", 0.30, "2px",   "#00E676", "45%"],
  ["39%",  "2.6s",  "4.0s", 0.18, "1px",   "#80FFB8", "38%"],
  ["45%",  "1.1s",  "3.2s", 0.60, "3px",   "#00E676", "80%"],
  ["50%",  "0.5s",  "7.0s", 0.12, "1px",   "#ffffff", "30%"],
  ["56%",  "2.0s",  "4.6s", 0.45, "1px",   "#00E676", "60%"],
  ["62%",  "0.8s",  "5.0s", 0.22, "2px",   "#00C853", "42%"],
  ["68%",  "1.6s",  "3.9s", 0.50, "1px",   "#00E676", "68%"],
  ["73%",  "2.8s",  "5.8s", 0.18, "1px",   "#ffffff", "33%"],
  ["79%",  "0.2s",  "4.2s", 0.48, "2px",   "#00E676", "58%"],
  ["84%",  "1.9s",  "6.2s", 0.20, "1px",   "#80FFB8", "44%"],
  ["89%",  "0.7s",  "3.5s", 0.55, "1px",   "#00E676", "62%"],
  ["94%",  "2.4s",  "4.9s", 0.30, "2px",   "#00C853", "50%"],
  ["98%",  "1.0s",  "5.4s", 0.22, "1px",   "#ffffff", "36%"],
];

export default function BackgroundEffect() {
  return (
    <div
      aria-hidden
      className="pointer-events-none fixed inset-0 z-0 overflow-hidden"
      style={{ background: "#040404" }}
    >
      {/* ── Base radial glow from the bottom ─────────────────────────────── */}
      <div
        style={{
          position: "absolute",
          bottom: 0,
          left: "50%",
          transform: "translateX(-50%)",
          width: "100%",
          height: "45%",
          background:
            "radial-gradient(ellipse 80% 100% at 50% 100%, rgba(0,230,118,0.08) 0%, transparent 70%)",
        }}
      />

      {/* ── Top subtle glow ───────────────────────────────────────────────── */}
      <div
        style={{
          position: "absolute",
          top: 0,
          left: "50%",
          transform: "translateX(-50%)",
          width: "70%",
          height: "30%",
          background:
            "radial-gradient(ellipse 100% 100% at 50% 0%, rgba(0,230,118,0.05) 0%, transparent 70%)",
        }}
      />

      {/* ── Rising light beams ────────────────────────────────────────────── */}
      {BEAMS.map(([left, delay, dur, opacity, width, color, height], i) => (
        <div
          key={i}
          style={{
            position:        "absolute",
            left,
            bottom:          0,
            width,
            height,
            background:      `linear-gradient(to top, ${color} 0%, ${color}88 30%, ${color}33 65%, transparent 100%)`,
            opacity,
            animationName:   "beamRise",
            animationDelay:  delay,
            animationDuration: dur,
            animationTimingFunction: "ease-in-out",
            animationIterationCount: "infinite",
            transformOrigin: "bottom center",
            filter:          `blur(${width === "3px" ? "1.5px" : width === "2px" ? "0.8px" : "0.4px"})`,
          }}
        />
      ))}

      {/* ── Horizontal floor glow line ─────────────────────────────────────── */}
      <div
        style={{
          position:  "absolute",
          bottom:    0,
          left:      0,
          right:     0,
          height:    "1px",
          background: "linear-gradient(90deg, transparent 0%, rgba(0,230,118,0.4) 20%, rgba(0,230,118,0.7) 50%, rgba(0,230,118,0.4) 80%, transparent 100%)",
          filter:    "blur(1px)",
        }}
      />

      {/* ── Noise overlay for texture ─────────────────────────────────────── */}
      <div
        style={{
          position: "absolute",
          inset:    0,
          opacity:  0.025,
          backgroundImage:
            "url(\"data:image/svg+xml,%3Csvg viewBox='0 0 256 256' xmlns='http://www.w3.org/2000/svg'%3E%3Cfilter id='noise'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='0.9' numOctaves='4' stitchTiles='stitch'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23noise)'/%3E%3C/svg%3E\")",
          backgroundRepeat: "repeat",
          backgroundSize:   "128px 128px",
        }}
      />
    </div>
  );
}
