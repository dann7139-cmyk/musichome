"use client";

/**
 * /auth/callback — recibe el regreso de Google (2026-09-19).
 *
 * El cliente de supabase-js en el navegador ya trae detectSessionInUrl:true
 * por default (web/src/lib/supabase.ts no lo desactiva) — cuando esta
 * página carga con "?code=..." en la URL, el propio cliente intercambia el
 * código por una sesión solo, sin que aquí se tenga que llamar
 * exchangeCodeForSession a mano (llamarlo también sería redundante y podría
 * chocar con ese intercambio automático). Aquí solo se espera a que la
 * sesión aparezca vía onAuthStateChange y se decide a dónde mandar:
 *   - Alta nueva sin fila en profiles todavía → /completar-perfil
 *     (si no, /dashboard la crearía sola como "client" sin preguntar rol).
 *   - Ya tiene perfil → /dashboard (ya sabe detectar el rol y redirigir).
 */

import { Suspense, useEffect } from "react";
import { useRouter, useSearchParams } from "next/navigation";
import { supabase } from "@/lib/supabase";

function CallbackInner() {
  const router = useRouter();
  const params = useSearchParams();
  const redirectTo = params.get("redirect");
  const preselectedRole = params.get("role");

  useEffect(() => {
    let handled = false;

    const finish = async () => {
      if (handled) return;
      handled = true;

      const { data: profile } = await supabase
        .from("profiles")
        .select("id")
        .eq("id", (await supabase.auth.getUser()).data.user?.id ?? "")
        .maybeSingle();

      if (!profile) {
        router.replace(`/completar-perfil${preselectedRole ? `?role=${preselectedRole}` : ""}`);
        return;
      }
      router.replace(redirectTo || "/dashboard");
    };

    const { data: { subscription } } = supabase.auth.onAuthStateChange((_event, session) => {
      if (session) finish();
    });

    // Respaldo: si la sesión ya estaba lista antes de suscribirse arriba.
    supabase.auth.getSession().then(({ data }) => {
      if (data.session) finish();
    });

    const timeout = setTimeout(() => {
      if (!handled) router.replace("/login?error=oauth");
    }, 8000);

    return () => {
      subscription.unsubscribe();
      clearTimeout(timeout);
    };
  }, [router, redirectTo, preselectedRole]);

  return (
    <div className="flex min-h-screen flex-col items-center justify-center gap-4 bg-brand-bg">
      <div className="h-10 w-10 animate-spin rounded-full border-2 border-brand-border border-t-brand-green" />
      <p className="text-sm text-brand-muted">Iniciando sesión…</p>
    </div>
  );
}

export default function AuthCallbackPage() {
  return (
    <Suspense fallback={
      <div className="flex min-h-screen items-center justify-center bg-brand-bg">
        <div className="h-10 w-10 animate-spin rounded-full border-2 border-brand-border border-t-brand-green" />
      </div>
    }>
      <CallbackInner />
    </Suspense>
  );
}
