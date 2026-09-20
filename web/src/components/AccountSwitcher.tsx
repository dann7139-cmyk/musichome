"use client";

/**
 * AccountSwitcher — cambiar rápido entre varias cuentas ya conocidas (ej.
 * tu admin + la cuenta de un cliente que manejas por él) sin cerrar
 * sesión y volver a escribir contraseña cada vez. Petición real
 * (2026-09-18): "quiero un botón para irme rápido a la cuenta del
 * cliente de Lala... hago el evento, cotizo desde mi admin, me vuelvo a
 * meter a la de Lala para el pago, y regresar a mi cuenta de admin".
 *
 * Cómo funciona: guarda el access_token/refresh_token de cada sesión ya
 * iniciada (en este navegador, con localStorage) bajo un nombre que tú
 * eliges — cambiar de cuenta es instantáneo (supabase.auth.setSession),
 * nunca vuelve a pedir contraseña. Para agregar una cuenta nueva, inicia
 * sesión normal en ella una vez y usa "+ Guardar esta cuenta" aquí mismo.
 *
 * ⚠️ Los tokens quedan guardados en este navegador — solo úsalo en un
 * equipo de confianza (el tuyo), igual que guardar contraseñas.
 */

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { supabase } from "@/lib/supabase";
import { useAuth } from "@/context/AuthContext";

const STORAGE_KEY = "daricefy_account_switcher";

interface SavedAccount {
  label: string;
  email: string;
  access_token: string;
  refresh_token: string;
}

function loadAccounts(): SavedAccount[] {
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    return raw ? JSON.parse(raw) : [];
  } catch {
    return [];
  }
}
function saveAccounts(list: SavedAccount[]) {
  try { localStorage.setItem(STORAGE_KEY, JSON.stringify(list)); } catch {}
}

export default function AccountSwitcher() {
  const { session, profile } = useAuth();
  const router = useRouter();
  const [accounts, setAccounts] = useState<SavedAccount[]>([]);
  const [open, setOpen] = useState(false);
  const [switching, setSwitching] = useState<string | null>(null);

  useEffect(() => { setAccounts(loadAccounts()); }, []);

  if (!session) return null;

  const currentEmail = session.user.email ?? "";
  const others = accounts.filter((a) => a.email.toLowerCase() !== currentEmail.toLowerCase());

  const addCurrent = () => {
    const label = window.prompt("¿Cómo le quieres llamar a esta cuenta? (ej. \"Lala\", \"Mi admin\")", profile?.name || currentEmail);
    if (!label) return;
    const next = [
      ...accounts.filter((a) => a.email.toLowerCase() !== currentEmail.toLowerCase()),
      { label, email: currentEmail, access_token: session.access_token, refresh_token: session.refresh_token },
    ];
    setAccounts(next);
    saveAccounts(next);
    setOpen(false);
  };

  const switchTo = async (acc: SavedAccount) => {
    setSwitching(acc.email);
    const { error } = await supabase.auth.setSession({
      access_token: acc.access_token,
      refresh_token: acc.refresh_token,
    });
    setSwitching(null);
    if (error) {
      window.alert(`No se pudo cambiar a "${acc.label}" — es probable que esa sesión ya haya expirado. Inicia sesión ahí de nuevo una vez y vuelve a guardarla.`);
      return;
    }
    setOpen(false);
    router.push("/dashboard");
    router.refresh();
  };

  const forget = (email: string) => {
    const next = accounts.filter((a) => a.email.toLowerCase() !== email.toLowerCase());
    setAccounts(next);
    saveAccounts(next);
  };

  // 2026-09-18 — petición real: "no me deja agregar la otra cuenta, que
  // me mande donde inicio sesión si quiero agregar otra cuenta, ahí
  // tengo la cuenta guardada y que se guarde después". Antes solo se
  // podía guardar la cuenta YA activa — para una cuenta nueva (que nunca
  // has usado en este navegador) hace falta cerrar sesión, iniciar sesión
  // ahí, y guardarla. Este botón hace el primer paso completo: si la
  // cuenta actual todavía no está guardada, la guarda ANTES de salir
  // (para no perderla), y manda directo al login.
  const isCurrentSaved = accounts.some((a) => a.email.toLowerCase() === currentEmail.toLowerCase());
  const addAnother = async () => {
    if (!isCurrentSaved) {
      const label = window.prompt(
        "Antes de salir, guardemos esta cuenta para no perderla — ¿cómo le llamamos?",
        profile?.name || currentEmail
      );
      if (label === null) return; // canceló — no seguimos sin guardar
      if (label.trim()) {
        const next = [...accounts, { label: label.trim(), email: currentEmail, access_token: session!.access_token, refresh_token: session!.refresh_token }];
        saveAccounts(next);
      }
    }
    await supabase.auth.signOut();
    setOpen(false);
    router.push("/login");
  };

  return (
    <div className="relative">
      <button
        onClick={() => setOpen((v) => !v)}
        className="flex items-center gap-1.5 rounded-lg border border-brand-border bg-brand-card2 px-3 py-2 text-xs font-medium text-white hover:border-brand-green/40"
      >
        🔀 Cuentas{others.length > 0 ? ` (${others.length})` : ""}
      </button>

      {open && (
        <>
          <div className="fixed inset-0 z-40" onClick={() => setOpen(false)} />
          <div className="absolute right-0 z-50 mt-2 w-64 rounded-xl border border-brand-border bg-brand-card p-2 shadow-xl">
            <p className="px-2 py-1.5 text-[10px] uppercase tracking-wide text-brand-muted">Ahora eres</p>
            <p className="mb-2 truncate px-2 text-sm font-semibold text-white">{profile?.name || currentEmail}</p>

            {others.length > 0 && (
              <>
                <div className="my-1 border-t border-brand-border" />
                <p className="px-2 py-1.5 text-[10px] uppercase tracking-wide text-brand-muted">Cambiar a</p>
                {others.map((a) => (
                  <div key={a.email} className="flex items-center gap-1">
                    <button
                      onClick={() => switchTo(a)}
                      disabled={switching === a.email}
                      className="flex-1 truncate rounded-lg px-2 py-2 text-left text-sm text-white hover:bg-brand-card2 disabled:opacity-50"
                    >
                      {switching === a.email ? "Cambiando…" : a.label}
                    </button>
                    <button
                      onClick={() => forget(a.email)}
                      title="Olvidar esta cuenta"
                      className="rounded-lg px-2 py-2 text-xs text-brand-muted hover:text-red-400"
                    >
                      ✕
                    </button>
                  </div>
                ))}
              </>
            )}

            <div className="my-1 border-t border-brand-border" />
            <button onClick={addCurrent} className="w-full rounded-lg px-2 py-2 text-left text-sm text-brand-green hover:bg-brand-green/10">
              + Guardar esta cuenta
            </button>
            <button onClick={addAnother} className="w-full rounded-lg px-2 py-2 text-left text-sm text-brand-muted hover:bg-brand-card2 hover:text-white">
              + Agregar otra cuenta (ir a iniciar sesión)
            </button>
          </div>
        </>
      )}
    </div>
  );
}
