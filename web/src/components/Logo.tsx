"use client";

import Image from "next/image";
import Link from "next/link";

// Wordmark en blanco sólido (antes tenía un degradado verde/blanco
// partido — petición real: "que sea blanco todo") + el logo real de la
// app (antes eran solo 3 barritas de ecualizador, nunca el logo de
// verdad — assets/images/icon.png de la app móvil).
export default function Logo({ size = "md" }: { size?: "sm" | "md" | "lg" }) {
  const textClass =
    size === "lg" ? "text-4xl sm:text-5xl" : size === "sm" ? "text-base" : "text-xl";
  const iconPx = size === "lg" ? 44 : size === "sm" ? 24 : 32;

  return (
    <Link href="/" className="group inline-flex items-center gap-2.5 select-none">
      <Image src="/logo.png" alt="Daricefy" width={iconPx} height={iconPx} className="shrink-0 rounded-full" priority />
      <span className={`font-extrabold tracking-widest text-white ${textClass}`}>
        DARICEFY
      </span>
    </Link>
  );
}
