"use client";

import { Suspense, useState } from "react";
import Link from "next/link";
import { useRouter, useSearchParams } from "next/navigation";
import { supabase } from "@/lib/supabase";
import Logo from "@/components/Logo";

function LoginForm() {
  const router     = useRouter();
  const params     = useSearchParams();
  const redirectTo = params.get("redirect") ?? null;

  const [email,    setEmail]    = useState("");
  const [password, setPassword] = useState("");
  const [loading,  setLoading]  = useState(false);
  const [error,    setError]    = useState("");

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setError("");
    setLoading(true);

    const { data, error: err } = await supabase.auth.signInWithPassword({
      email,
      password,
    });

    if (err || !data.session) {
      setError(
        err?.message?.includes("Invalid login")
          ? "Correo o contraseña incorrectos."
          : err?.message ?? "Error al iniciar sesión."
      );
      setLoading(false);
      return;
    }

    if (redirectTo) {
      router.push(redirectTo);
      return;
    }

    // /dashboard detects role and redirects correctly (avoids RLS race)
    router.push("/dashboard");
  };

  return (
    <div className="relative w-full max-w-md">
      <div className="mb-8 flex flex-col items-center text-center">
        <Logo size="lg" />
        <h1 className="mt-6 text-2xl font-bold text-white">Iniciar sesión</h1>
        <p className="mt-1 text-sm text-brand-muted">Bienvenido de vuelta</p>
      </div>

      <div className="rounded-2xl border border-brand-border bg-brand-card p-8">
        <form onSubmit={handleSubmit} className="space-y-5">
          {error && (
            <div className="rounded-xl border border-red-500/20 bg-red-500/10 p-3 text-sm text-red-400">
              {error}
            </div>
          )}

          <div>
            <label className="mb-1.5 block text-sm font-medium text-brand-muted">
              Correo electrónico
            </label>
            <input
              type="email"
              required
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              placeholder="tu@email.com"
              className="w-full rounded-xl border border-brand-border bg-brand-card2 px-4 py-3 text-sm text-white placeholder-brand-muted outline-none transition-colors focus:border-brand-green"
            />
          </div>

          <div>
            <div className="mb-1.5 flex items-center justify-between">
              <label className="text-sm font-medium text-brand-muted">Contraseña</label>
              <Link href="/recuperar" className="text-xs text-brand-green hover:underline">
                ¿Olvidaste tu contraseña?
              </Link>
            </div>
            <input
              type="password"
              required
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              placeholder="••••••••"
              className="w-full rounded-xl border border-brand-border bg-brand-card2 px-4 py-3 text-sm text-white placeholder-brand-muted outline-none transition-colors focus:border-brand-green"
            />
          </div>

          <button
            type="submit"
            disabled={loading}
            className="w-full rounded-xl bg-brand-green py-3.5 text-sm font-bold text-black shadow-lg shadow-brand-green/20 transition-all hover:bg-brand-green2 disabled:opacity-60 active:scale-[0.98]"
          >
            {loading ? "Ingresando…" : "Iniciar sesión"}
          </button>
        </form>

        <div className="mt-6 text-center text-sm text-brand-muted">
          ¿No tienes cuenta?{" "}
          <Link href="/registro" className="font-semibold text-brand-green hover:underline">
            Regístrate gratis
          </Link>
        </div>
      </div>

      <p className="mt-6 text-center text-xs text-brand-muted">
        Al continuar aceptas nuestros{" "}
        <Link href="/terminos" className="underline hover:text-white">Términos</Link>
        {" "}y{" "}
        <Link href="/privacidad" className="underline hover:text-white">Privacidad</Link>.
      </p>
    </div>
  );
}

export default function LoginPage() {
  return (
    <div className="flex min-h-screen items-center justify-center px-4">
      <Suspense fallback={
        <div className="h-10 w-10 animate-spin rounded-full border-2 border-brand-border border-t-brand-green" />
      }>
        <LoginForm />
      </Suspense>
    </div>
  );
}
