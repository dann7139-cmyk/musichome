"use client";

import {
  createContext,
  useContext,
  useEffect,
  useState,
  ReactNode,
} from "react";
import { Session, User } from "@supabase/supabase-js";
import { supabase, Profile } from "@/lib/supabase";

interface AuthContextValue {
  session:  Session | null;
  user:     User    | null;
  profile:  Profile | null;
  loading:  boolean;
  signOut:  () => Promise<void>;
}

const AuthContext = createContext<AuthContextValue>({
  session: null,
  user:    null,
  profile: null,
  loading: true,
  signOut: async () => {},
});

export function AuthProvider({ children }: { children: ReactNode }) {
  const [session, setSession] = useState<Session | null>(null);
  const [profile, setProfile] = useState<Profile | null>(null);
  const [loading, setLoading] = useState(true);

  async function fetchProfile(user: User) {
    // profiles no tiene columna "name" — es "full_name" (hallazgo real:
    // esta consulta fallaba en silencio para TODOS los roles, y el
    // fallback de abajo asignaba "client" a cualquiera cuyo user_metadata
    // no trajera role, incluyendo cuentas admin reales). Se alias-ea
    // name:full_name para no tener que tocar el resto del código que ya
    // espera profile.name.
    const { data } = await supabase
      .from("profiles")
      .select("id, name:full_name, email, role, city, phone, avatar_url, admin_country_scope, admin_can_manage_payouts")
      .eq("id", user.id)
      .single();

    if (data) {
      setProfile(data as unknown as Profile);
    } else {
      // Fallback: construir perfil desde user_metadata
      // Cubre admins creados directamente en Supabase sin fila en profiles
      setProfile({
        id:         user.id,
        name:       user.user_metadata?.name ?? user.email ?? "Usuario",
        email:      user.email ?? "",
        role:       (user.user_metadata?.role as Profile["role"]) ?? "client",
        city:       user.user_metadata?.city ?? null,
        phone:      null,
        avatar_url: null,
      });
    }
  }

  useEffect(() => {
    supabase.auth.getSession().then(async ({ data: { session } }) => {
      setSession(session);
      if (session?.user) await fetchProfile(session.user);
      setLoading(false);
    });

    const { data: { subscription } } = supabase.auth.onAuthStateChange(
      (_event, session) => {
        setSession(session);
        if (session?.user) {
          fetchProfile(session.user);
        } else {
          setProfile(null);
        }
      }
    );

    return () => subscription.unsubscribe();
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const signOut = async () => {
    await supabase.auth.signOut();
    setProfile(null);
    setSession(null);
  };

  return (
    <AuthContext.Provider
      value={{ session, user: session?.user ?? null, profile, loading, signOut }}
    >
      {children}
    </AuthContext.Provider>
  );
}

export function useAuth() {
  return useContext(AuthContext);
}
