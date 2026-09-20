"use client";

import { useState } from "react";
import { useRouter, usePathname } from "next/navigation";
import { useAuth } from "@/context/AuthContext";
import Logo from "@/components/Logo";
import Link from "next/link";
import AccountSwitcher from "@/components/AccountSwitcher";

const DASHBOARD_ROUTE: Record<string, string> = {
  client:  "/dashboard/cliente",
  group:   "/dashboard/grupo",
  talent:  "/dashboard/talento",
  admin:   "/dashboard/admin",
};

export default function Navbar() {
  const { profile, loading, signOut } = useAuth();
  const router   = useRouter();
  const pathname = usePathname();
  const [open, setOpen] = useState(false);

  const handleSignOut = async () => {
    await signOut();
    router.push("/");
  };

  const dashboardHref = profile ? (DASHBOARD_ROUTE[profile.role] ?? "/dashboard/cliente") : "/login";

  const navLinks = [
    { label: "Explorar", href: "/grupos" },
    { label: "Cómo funciona", href: "/#como-funciona" },
    { label: "Para grupos", href: "/#para-grupos" },
  ];

  return (
    <header className="fixed top-0 left-0 right-0 z-50 border-b border-brand-border bg-brand-bg/80 backdrop-blur-xl">
      <nav className="mx-auto flex h-16 max-w-7xl items-center justify-between px-4 sm:px-6 lg:px-8">
        {/* Logo */}
        <Logo size="md" />

        {/* Desktop nav */}
        <div className="hidden items-center gap-8 md:flex">
          {navLinks.map((l) => (
            <Link
              key={l.href}
              href={l.href}
              className={`text-sm font-medium transition-colors hover:text-brand-green ${
                pathname === l.href ? "text-brand-green" : "text-brand-muted"
              }`}
            >
              {l.label}
            </Link>
          ))}
        </div>

        {/* Desktop auth */}
        <div className="hidden items-center gap-3 md:flex">
          {loading ? null : profile ? (
            <>
              <AccountSwitcher />
              <Link
                href={dashboardHref}
                className="rounded-lg bg-brand-card2 px-4 py-2 text-sm font-medium text-white transition-colors hover:bg-white/10"
              >
                Mi panel
              </Link>
              <button
                onClick={handleSignOut}
                className="rounded-lg border border-brand-border px-4 py-2 text-sm font-medium text-brand-muted transition-colors hover:border-brand-green hover:text-white"
              >
                Salir
              </button>
            </>
          ) : (
            <>
              <Link
                href="/login"
                className="rounded-lg px-4 py-2 text-sm font-medium text-brand-muted transition-colors hover:text-white"
              >
                Iniciar sesión
              </Link>
              <Link
                href="/registro"
                className="rounded-lg bg-brand-green px-4 py-2 text-sm font-bold text-black transition-colors hover:bg-brand-green2"
              >
                Regístrate gratis
              </Link>
            </>
          )}
        </div>

        {/* Mobile hamburger */}
        <button
          className="flex h-11 w-11 flex-col items-center justify-center gap-1.5 rounded-lg md:hidden"
          onClick={() => setOpen(!open)}
          aria-label="Menú"
        >
          <span className={`block h-0.5 w-5 bg-white transition-all ${open ? "translate-y-2 rotate-45" : ""}`} />
          <span className={`block h-0.5 w-5 bg-white transition-all ${open ? "opacity-0" : ""}`} />
          <span className={`block h-0.5 w-5 bg-white transition-all ${open ? "-translate-y-2 -rotate-45" : ""}`} />
        </button>
      </nav>

      {/* Mobile menu */}
      {open && (
        <div className="border-t border-brand-border bg-brand-card px-4 pb-6 pt-4 md:hidden">
          <div className="flex flex-col gap-4">
            {navLinks.map((l) => (
              <Link
                key={l.href}
                href={l.href}
                onClick={() => setOpen(false)}
                className="text-sm font-medium text-brand-muted hover:text-white"
              >
                {l.label}
              </Link>
            ))}
            <div className="mt-2 flex flex-col gap-3 border-t border-brand-border pt-4">
              {profile ? (
                <>
                  <div className="flex justify-center">
                    <AccountSwitcher />
                  </div>
                  <Link
                    href={dashboardHref}
                    onClick={() => setOpen(false)}
                    className="rounded-lg bg-brand-card2 px-4 py-2.5 text-center text-sm font-medium text-white"
                  >
                    Mi panel
                  </Link>
                  <button
                    onClick={handleSignOut}
                    className="rounded-lg border border-brand-border px-4 py-2.5 text-sm font-medium text-brand-muted"
                  >
                    Cerrar sesión
                  </button>
                </>
              ) : (
                <>
                  <Link
                    href="/login"
                    onClick={() => setOpen(false)}
                    className="rounded-lg border border-brand-border px-4 py-2.5 text-center text-sm font-medium text-white"
                  >
                    Iniciar sesión
                  </Link>
                  <Link
                    href="/registro"
                    onClick={() => setOpen(false)}
                    className="rounded-lg bg-brand-green px-4 py-2.5 text-center text-sm font-bold text-black"
                  >
                    Regístrate gratis
                  </Link>
                </>
              )}
            </div>
          </div>
        </div>
      )}
    </header>
  );
}
