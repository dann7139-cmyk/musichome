"use client";

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { supabase } from "@/lib/supabase";

const ROUTE: Record<string, string> = {
  client: "/dashboard/cliente",
  group:  "/dashboard/grupo",
  talent: "/dashboard/talento",
  admin:  "/dashboard/admin",
};

export default function DashboardPage() {
  const router = useRouter();
  const [msg, setMsg] = useState("Cargando…");

  useEffect(() => {
    async function redirect() {
      // 1. Verificar sesión activa
      const { data: { session } } = await supabase.auth.getSession();

      if (!session) {
        router.replace("/login");
        return;
      }

      // 2. Buscar perfil en la base de datos
      const { data: profile } = await supabase
        .from("profiles")
        .select("role")
        .eq("id", session.user.id)
        .single();

      const role = (profile as { role: string } | null)?.role
        // 3. Fallback: role en user_metadata (si se guardó al registrar)
        ?? (session.user.user_metadata?.role as string | undefined)
        // 4. Fallback final: intentar detectar por email
        ?? null;

      if (!role) {
        // Perfil no encontrado — crearlo como cliente y redirigir
        setMsg("Configurando tu cuenta…");
        await supabase.from("profiles").upsert({
          id:    session.user.id,
          email: session.user.email ?? "",
          name:  session.user.user_metadata?.name ?? session.user.email ?? "Usuario",
          role:  "client",
        });
        router.replace("/dashboard/cliente");
        return;
      }

      router.replace(ROUTE[role] ?? "/dashboard/cliente");
    }

    redirect();
  }, [router]);

  return (
    <div className="flex min-h-screen flex-col items-center justify-center gap-4 bg-brand-bg">
      <div className="h-10 w-10 animate-spin rounded-full border-2 border-brand-border border-t-brand-green" />
      <p className="text-sm text-brand-muted">{msg}</p>
    </div>
  );
}
