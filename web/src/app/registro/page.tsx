"use client";

import { Suspense, useState } from "react";
import Link from "next/link";
import { useRouter, useSearchParams } from "next/navigation";
import { supabase } from "@/lib/supabase";
import Logo from "@/components/Logo";

type Role = "client" | "group" | "talent";

const ROLE_OPTIONS: { value: Role; label: string; desc: string; icon: string }[] = [
  { value: "client", label: "Cliente", desc: "Quiero contratar grupos para mis eventos.", icon: "🎉" },
  { value: "group",  label: "Grupo",   desc: "Somos un grupo y queremos conseguir eventos.", icon: "🎸" },
  { value: "talent", label: "Talento", desc: "Soy músico o artista y busco oportunidades.", icon: "🎤" },
];

function RegisterForm() {
  const router = useRouter();
  const params = useSearchParams();
  const defaultRole = (params.get("rol") ?? "client") as Role;

  const [role,     setRole]     = useState<Role>(defaultRole);
  const [name,     setName]     = useState("");
  const [email,    setEmail]    = useState("");
  const [password, setPassword] = useState("");
  const [city,     setCity]     = useState("");
  const [referral, setReferral] = useState("");
  const [loading,  setLoading]  = useState(false);
  const [error,    setError]    = useState("");
  const [step,     setStep]     = useState<1 | 2>(1);

  const handleRegister = async (e: React.FormEvent) => {
    e.preventDefault();
    setError("");
    setLoading(true);

    const { data, error: signUpErr } = await supabase.auth.signUp({
      email,
      password,
      options: { data: { name, role, city } },
    });

    if (signUpErr || !data.user) {
      setError(signUpErr?.message ?? "Error al crear la cuenta.");
      setLoading(false);
      return;
    }

    await supabase.from("profiles").upsert({
      id: data.user.id, name, email, role, city: city || null,
    });

    if (role === "client" && referral.trim()) {
      await supabase.rpc("register_referral", {
        p_referral_code: referral.trim().toUpperCase(),
      });
    }

    const roleRoutes: Record<Role, string> = {
      client: "/dashboard/cliente",
      group:  "/dashboard/grupo",
      talent: "/dashboard/talento",
    };
    router.push(roleRoutes[role]);
  };

  // Registro con Google (2026-09-19) — se manda el rol ya elegido en el
  // paso 1 como query param, para que /completar-perfil lo preseleccione.
  const handleGoogle = async () => {
    await supabase.auth.signInWithOAuth({
      provider: "google",
      options: {
        redirectTo: `${window.location.origin}/auth/callback?role=${role}`,
      },
    });
  };

  return (
    <div className="w-full max-w-md">
      <div className="mb-8 flex flex-col items-center text-center">
        <Logo size="lg" />
        <h1 className="mt-6 text-2xl font-bold text-white">Crear cuenta</h1>
        <p className="mt-1 text-sm text-brand-muted">Gratis · Sin tarjeta requerida</p>
      </div>

      <div className="rounded-2xl border border-brand-border bg-brand-card p-8">
        {step === 1 ? (
          <div>
            <p className="mb-5 text-sm font-medium text-brand-muted">
              ¿Cómo quieres usar Daricefy?
            </p>
            <div className="space-y-3">
              {ROLE_OPTIONS.map((opt) => (
                <button
                  key={opt.value}
                  type="button"
                  onClick={() => setRole(opt.value)}
                  className={`flex w-full items-center gap-4 rounded-xl border p-4 text-left transition-all ${
                    role === opt.value
                      ? "border-brand-green bg-brand-green/5"
                      : "border-brand-border hover:border-brand-border/80"
                  }`}
                >
                  <span className="text-2xl">{opt.icon}</span>
                  <div>
                    <p className="font-semibold text-white">{opt.label}</p>
                    <p className="text-xs text-brand-muted">{opt.desc}</p>
                  </div>
                  {role === opt.value && (
                    <span className="ml-auto h-4 w-4 rounded-full bg-brand-green" />
                  )}
                </button>
              ))}
            </div>
            <button
              onClick={() => setStep(2)}
              className="mt-6 w-full rounded-xl bg-brand-green py-3.5 text-sm font-bold text-black transition-colors hover:bg-brand-green2"
            >
              Continuar →
            </button>

            <div className="my-5 flex items-center gap-3">
              <div className="h-px flex-1 bg-brand-border" />
              <span className="text-xs text-brand-muted">o</span>
              <div className="h-px flex-1 bg-brand-border" />
            </div>

            <button
              type="button"
              onClick={handleGoogle}
              className="flex w-full items-center justify-center gap-2.5 rounded-xl border border-brand-border bg-brand-card2 py-3 text-sm font-semibold text-white transition-colors hover:border-brand-muted"
            >
              <span className="flex h-5 w-5 items-center justify-center rounded-full bg-white text-[11px] font-bold text-[#4285F4]">G</span>
              Continuar con Google
            </button>
          </div>
        ) : (
          <form onSubmit={handleRegister} className="space-y-4">
            {error && (
              <div className="rounded-xl border border-red-500/20 bg-red-500/10 p-3 text-sm text-red-400">
                {error}
              </div>
            )}
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
              <label className="mb-1.5 block text-sm font-medium text-brand-muted">Correo</label>
              <input
                type="email" required value={email}
                onChange={(e) => setEmail(e.target.value)}
                placeholder="tu@email.com"
                className="w-full rounded-xl border border-brand-border bg-brand-card2 px-4 py-3 text-sm text-white placeholder-brand-muted outline-none focus:border-brand-green"
              />
            </div>
            <div>
              <label className="mb-1.5 block text-sm font-medium text-brand-muted">Contraseña</label>
              <input
                type="password" required minLength={6} value={password}
                onChange={(e) => setPassword(e.target.value)}
                placeholder="Mínimo 6 caracteres"
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
            {role === "client" && (
              <div>
                <label className="mb-1.5 block text-sm font-medium text-brand-muted">
                  Código de referido <span className="opacity-50">(opcional)</span>
                </label>
                <input
                  type="text" value={referral} maxLength={10}
                  onChange={(e) => setReferral(e.target.value.toUpperCase())}
                  placeholder="XXXXX"
                  className="w-full rounded-xl border border-brand-border bg-brand-card2 px-4 py-3 text-sm text-white placeholder-brand-muted outline-none focus:border-brand-green"
                />
                <p className="mt-1 text-[11px] text-brand-muted">
                  Recibirás un beneficio en tu primera reserva.
                </p>
              </div>
            )}
            <div className="flex gap-3 pt-2">
              <button
                type="button" onClick={() => setStep(1)}
                className="flex-1 rounded-xl border border-brand-border py-3 text-sm font-medium text-brand-muted hover:border-brand-green hover:text-white"
              >
                ← Atrás
              </button>
              <button
                type="submit" disabled={loading}
                className="flex-[2] rounded-xl bg-brand-green py-3 text-sm font-bold text-black shadow-lg shadow-brand-green/20 hover:bg-brand-green2 disabled:opacity-60"
              >
                {loading ? "Creando cuenta…" : "Crear cuenta gratis"}
              </button>
            </div>
          </form>
        )}

        <div className="mt-6 text-center text-sm text-brand-muted">
          ¿Ya tienes cuenta?{" "}
          <Link href="/login" className="font-semibold text-brand-green hover:underline">
            Iniciar sesión
          </Link>
        </div>
      </div>
    </div>
  );
}

export default function RegistroPage() {
  return (
    <div className="flex min-h-screen items-center justify-center px-4 py-12">
      <Suspense fallback={
        <div className="h-10 w-10 animate-spin rounded-full border-2 border-brand-border border-t-brand-green" />
      }>
        <RegisterForm />
      </Suspense>
    </div>
  );
}
