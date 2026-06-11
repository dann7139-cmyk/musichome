import type { Metadata } from "next";
import "./globals.css";
import { AuthProvider } from "@/context/AuthContext";
import BackgroundEffect from "@/components/BackgroundEffect";

export const metadata: Metadata = {
  title:       "DARICEFY — Contrata grupos en minutos",
  description: "Encuentra el mejor grupo para tu evento con DARICEFY. Música en vivo, bandas, DJs y más en toda México.",
  keywords:    "grupos musicales, música en vivo, contratar grupo, eventos, DARICEFY",
  openGraph: {
    title:       "DARICEFY — Contrata grupos en minutos",
    description: "Encuentra el mejor grupo para tu evento.",
    type:        "website",
    locale:      "es_MX",
    siteName:    "DARICEFY",
  },
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="es">
      <body style={{ background: "#040404" }}>
        {/* Global rising-lights background — visible in ALL pages */}
        <BackgroundEffect />

        {/* Page content sits on top of background (z-10+) */}
        <div style={{ position: "relative", zIndex: 1 }}>
          <AuthProvider>{children}</AuthProvider>
        </div>
      </body>
    </html>
  );
}
