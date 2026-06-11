import Link from "next/link";
import Logo from "@/components/Logo";

export default function Footer() {
  return (
    <footer className="border-t border-brand-border bg-brand-card">
      <div className="mx-auto max-w-7xl px-4 py-12 sm:px-6 lg:px-8">
        <div className="grid grid-cols-2 gap-8 md:grid-cols-4">
          {/* Brand */}
          <div className="col-span-2 md:col-span-1">
            <Logo size="md" />
            <p className="mt-3 max-w-xs text-sm text-brand-muted">
              La plataforma líder para contratar grupos musicales en México.
            </p>
          </div>

          {/* Plataforma */}
          <div>
            <h3 className="mb-4 text-xs font-semibold uppercase tracking-wider text-brand-muted">
              Plataforma
            </h3>
            <ul className="space-y-2">
              {[
                { label: "Explorar grupos", href: "/grupos" },
                { label: "Cómo funciona", href: "/#como-funciona" },
                { label: "Para grupos", href: "/#para-grupos" },
                { label: "Precios",   href: "/#precios" },
              ].map((l) => (
                <li key={l.href}>
                  <Link
                    href={l.href}
                    className="text-sm text-brand-muted transition-colors hover:text-white"
                  >
                    {l.label}
                  </Link>
                </li>
              ))}
            </ul>
          </div>

          {/* Cuenta */}
          <div>
            <h3 className="mb-4 text-xs font-semibold uppercase tracking-wider text-brand-muted">
              Cuenta
            </h3>
            <ul className="space-y-2">
              {[
                { label: "Iniciar sesión", href: "/login" },
                { label: "Registrarse",   href: "/registro" },
                { label: "Mi panel",      href: "/dashboard/cliente" },
              ].map((l) => (
                <li key={l.href}>
                  <Link
                    href={l.href}
                    className="text-sm text-brand-muted transition-colors hover:text-white"
                  >
                    {l.label}
                  </Link>
                </li>
              ))}
            </ul>
          </div>

          {/* Descarga */}
          <div>
            <h3 className="mb-4 text-xs font-semibold uppercase tracking-wider text-brand-muted">
              App móvil
            </h3>
            <p className="mb-4 text-sm text-brand-muted">
              Descarga la app y gestiona tus eventos desde tu celular.
            </p>
            <div className="flex flex-col gap-2">
              <a
                href="#"
                className="flex items-center gap-2 rounded-lg border border-brand-border px-3 py-2 text-xs font-medium text-white transition-colors hover:border-brand-green"
              >
                <svg viewBox="0 0 24 24" className="h-4 w-4 fill-white">
                  <path d="M18.71 19.5c-.83 1.24-1.71 2.45-3.05 2.47-1.34.03-1.77-.79-3.29-.79-1.53 0-2 .77-3.27.82-1.31.05-2.3-1.32-3.14-2.53C4.25 17 2.94 12.45 4.7 9.39c.87-1.52 2.43-2.48 4.12-2.51 1.28-.02 2.5.87 3.29.87.78 0 2.26-1.07 3.8-.91.65.03 2.47.26 3.64 1.98-.09.06-2.17 1.28-2.15 3.81.03 3.02 2.65 4.03 2.68 4.04-.03.07-.42 1.44-1.38 2.83M13 3.5c.73-.83 1.94-1.46 2.94-1.5.13 1.17-.34 2.35-1.04 3.19-.69.85-1.83 1.51-2.95 1.42-.15-1.15.41-2.35 1.05-3.11z" />
                </svg>
                App Store
              </a>
              <a
                href="#"
                className="flex items-center gap-2 rounded-lg border border-brand-border px-3 py-2 text-xs font-medium text-white transition-colors hover:border-brand-green"
              >
                <svg viewBox="0 0 24 24" className="h-4 w-4 fill-white">
                  <path d="M3 20.5v-17c0-.83.94-1.3 1.6-.8l14 8.5c.6.36.6 1.24 0 1.6l-14 8.5c-.66.5-1.6.03-1.6-.8z" />
                </svg>
                Google Play
              </a>
            </div>
          </div>
        </div>

        <div className="mt-10 flex flex-col items-center justify-between gap-4 border-t border-brand-border pt-8 sm:flex-row">
          <p className="text-sm text-brand-muted">
            © {new Date().getFullYear()} DARICEFY. Todos los derechos reservados.
          </p>
          <div className="flex gap-6">
            <Link href="/privacidad" className="text-xs text-brand-muted hover:text-white">
              Privacidad
            </Link>
            <Link href="/terminos" className="text-xs text-brand-muted hover:text-white">
              Términos
            </Link>
          </div>
        </div>
      </div>
    </footer>
  );
}
