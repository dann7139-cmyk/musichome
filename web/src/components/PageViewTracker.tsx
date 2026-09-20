"use client";

/**
 * Cuenta visitas reales a la web (sql/663) — sin cookies de terceros, sin
 * IP, sin nada personal: solo la ruta visitada + un id aleatorio que vive
 * en localStorage del propio navegador (para poder distinguir "sesiones
 * únicas" de "vistas totales" sin identificar a nadie).
 */

import { useEffect } from "react";
import { usePathname } from "next/navigation";
import { supabase } from "@/lib/supabase";

function getSessionId(): string {
  try {
    const key = "daricefy_session_id";
    let id = localStorage.getItem(key);
    if (!id) {
      id = crypto.randomUUID();
      localStorage.setItem(key, id);
    }
    return id;
  } catch {
    return "no-storage";
  }
}

export default function PageViewTracker() {
  const pathname = usePathname();

  useEffect(() => {
    supabase.from("page_views").insert({
      path: pathname,
      session_id: getSessionId(),
      referrer: typeof document !== "undefined" ? document.referrer || null : null,
    });
  }, [pathname]);

  return null;
}
