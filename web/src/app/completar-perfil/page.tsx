"use client";

/**
 * /completar-perfil — último paso para cuentas nuevas dadas de alta con
 * Google (2026-09-19). Supabase ya creó el usuario en auth.users al volver
 * de /auth/callback, pero no existe fila en profiles todavía (nadie eligió
 * rol ni llenó el resto, como sí pasa en /registro). Mismos 3 roles que
 * /registro — nunca pide correo ni contraseña, ya vienen de la sesión.
 */

import { Suspense, useEffect, useState } from "react";
import { useRouter, useSearchParams } from "next/navigation";
import { supabase } from "@/lib/supabase";
import Logo from "@/components/Logo";

type Role = "client" | "group" | "talent";

const ROLE_OPTIONS: { value: Role; label: string; desc: string; icon: string }[] = [
  { value: "client", label: "Cliente", desc: "Quiero contratar grupos para mis eventos.", icon: "🎉" },
  { value: "group",  label: "Grupo",   desc: "Somos un grupo y queremos conseguir eventos.", icon: "🎸" },
  { value: "talent", label: "Talento", desc: "Soy músico o artista y busco oportunidades.", icon: "🎤" },
];

const ROLE_ROUTES: Record<Role, string> = {
  client: "/dashboard/cliente",
  group:  "/dashboard/grupo",
  talent: "/dashboard/talento",
};

function CompleteProfileForm() {
  const router = useRouter();
  const params = useSearchParams();
  const defaultRole = (params.get("role") as Role | null) ?? "client";

  const [role, setRole] = useState<Role>(defaultRole);
  const [name, setName] = useState("");
  const [city, setCity] = useState("");
  const [loading, setLoading] = useState(false);
  const [checking, setChecking] = useState(true);
  const [error, setError] = useState("");

  // Si no hay sesión (alguien llega a esta URL directo) mandar a login;
  // si ya tiene perfil (entró por aquí dos veces) mandar a su dashboard.
  useEffect(() => {
    (async () => {
      const { data: { user } } = await supabase.auth.getUser();
      if (!user) { router.replace("/login"); return; }

      setName((user.user_metadata?.full_name as string) ?? (user.user_metadata?.name as string) ?? "");

      const { data: profile } = await supabase.from("profiles").select("role").eq("id", user.id).maybeSingle();
      if (profile?.role) { router.replace(ROLE_ROUTES[profile.role as Role] ?? "/dashboard"); return; }
      setChecking(false);
    })();
  }, [router]);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setError("");
    if (!name.trim()) { setError("Escribe tu nombre."); return; }
    setLoading(true);

    const { data: { user } } = await supabase.auth.getUser();
    if (!user) { setError("Tu sesión expiró, entra de nuevo."); setLoading(false); return; }

    const { error: upErr } = await supabase.from("profiles").upsert({
      id: user.id,
      name: name.trim(),
      email: user.email,
      role,
      city: city.trim() || null,
    });

    if (upErr) {
      setError(upErr.message);
      setLoading(false);
      return;
    }

    router.push(ROLE_ROUTES[role]);
  };

  if (checking) {
    return <div className="h-10 w-10 animate-spin rounded-full border-2 border-brand-border border-t-brand-green" />;
  }

  return (
    <div className="w-full max-w-md">
      <div className="mb-8 flex flex-col items-center text-center">
        <Logo size="lg" />
        <h1 className="mt-6 text-2xl font-bold text-white">¡Ya casi!</h1>
        <p className="mt-1 text-sm text-brand-muted">Solo falta esto para terminar</p>
      </div>

      <div className="rounded-2xl border border-brand-border bg-brand-card p-8">
        <form onSubmit={handleSubmit} className="space-y-4">
          {error && (
            <div className="rounded-xl border border-red-500/20 bg-red-500/10 p-3 text-sm text-red-400">
              {error}
            </div>
          )}

          <div>
            <p className="mb-3 text-sm font-medium text-brand-muted">¿Cómo quieres usar Daricefy?</p>
            <div className="space-y-2.5">
              {ROLE_OPTIONS.map((opt) => (
                <button
                  key={opt.value}
                  type="button"
                  onClick={() => setRole(opt.value)}
                  className={`flex w-full items-center gap-3 rounded-xl border p-3.5 text-left transition-all ${
                    role === opt.value ? "border-brand-green bg-brand-green/5" : "border-brand-border hover:border-brand-border/80"
                  }`}
                >
                  <span className="text-xl">{opt.icon}</span>
                  <div>
                    <p className="text-sm font-semibold text-white">{opt.label}</p>
                    <p className="text-xs text-brand-muted">{opt.desc}</p>
                  </div>
                  {role === opt.value && <span className="ml-auto h-4 w-4 shrink-0 rounded-full bg-brand-green" />}
                </button>
              ))}
            </div>
          </div>

          <div>
            <label className="mb-1.5 block text-sm font-medium text-brand-muted">
              {role === "group" ? "Nombre del grupo" : "Tu nombre"}
            </label>
            <input
              type="text" required value={name}
              onChange={(e) => setName(e.target.value)}
              placeholder={role === "group" ? "Los Increíbles" : "Ana García"}
              className="w-full rounded-xl border border-brand-border bg-brand-card2 px-4 py-3 text-sm text-white placeholder-brand-muted outline-none focus:border-brand-green"
            />
          </div>

          <div>
            <label className="mb-1.5 block text-sm font-medium text-brand-muted">
              Ciudad <span className="opacity-50">(opcional)</span>
            </label>
            <input
              type="text" value={city}
              onChange={(e) => setCity(e.target.value)}
              placeholder="Guadalajara"
              className="w-full rounded-xl border border-brand-border bg-brand-card2 px-4 py-3 text-sm text-white placeholder-brand-muted outline-none focus:border-brand-green"
            />
          </div>

          <button
            type="submit" disabled={loading}
            className="w-full rounded-xl bg-brand-green py-3.5 text-sm font-bold text-black shadow-lg shadow-brand-green/20 transition-all hover:bg-brand-green2 disabled:opacity-60"
          >
            {loading ? "Guardando…" : "Terminar"}
          </button>
        </form>
      </div>
    </div>
  );
}

export default function CompleteProfilePage() {
  return (
    <div className="flex min-h-screen items-center justify-center px-4 py-12">
      <Suspense fallback={
        <div className="h-10 w-10 animate-spin rounded-full border-2 border-brand-border border-t-brand-green" />
      }>
        <CompleteProfileForm />
      </Suspense>
    </div>
  );
}
