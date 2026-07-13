/**
 * AuthContext — Fuente única de verdad para la autenticación.
 *
 * Flujo:
 *  1. onAuthStateChange dispara INITIAL_SESSION al suscribirse
 *  2. Si hay sesión → supabase.auth.getUser() verifica el JWT contra el servidor
 *  3. Se consulta profiles con el user.id (nunca con email)
 *  4. role se extrae de profiles.role → AppNavigator redirige según rol
 *  5. Si el perfil falla → error, NO se cae en "client" silenciosamente
 */

import type { Session, User } from '@supabase/supabase-js';
import * as Location from 'expo-location';
import React, {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useRef,
  useState,
} from 'react';
import { supabase } from '../config/supabase';
import type { Profile, UserRole } from '../types/models';
import { isoToCountryName } from '../utils/locationUtils';

const FALLBACK_CITY = 'Guadalajara';

// ─── Types ────────────────────────────────────────────────────────────────────

export interface AuthState {
  /** Sesión Supabase (contiene access_token, refresh_token, etc.) */
  session: Session | null;
  /** Usuario autenticado validado por el servidor */
  user: User | null;
  /** Fila completa de profiles */
  profile: Profile | null;
  /** Rol extraído de profiles.role */
  role: UserRole | null;
  /** true mientras se valida la sesión y se carga el perfil */
  loading: boolean;
  /** Mensaje de error si el perfil no pudo cargarse */
  error: string | null;
  /**
   * Ciudad detectada por GPS en segundo plano (dato secundario).
   * Solo se llena cuando profile.city es null y el permiso ya fue otorgado.
   */
  detectedCity: string | null;
  /**
   * Estado/región detectado por GPS en segundo plano.
   * Se llena siempre que el GPS funcione.
   */
  detectedState: string | null;
  /**
   * País detectado por GPS (via isoCountryCode → nombre legible).
   * Se llena siempre que el GPS funcione.
   */
  detectedCountry: string | null;
}

export interface AuthContextValue extends AuthState {
  /** Cierra la sesión y limpia todo el estado */
  signOut: () => Promise<void>;
  /** Recarga el perfil desde Supabase (útil tras editar datos) */
  refetchProfile: () => Promise<void>;
  /**
   * Ciudad segura siempre definida:
   *   profile.city  →  detectedCity  →  'Guadalajara'
   * Se mantiene para las pantallas de publicidad (city-based). No usar como
   * filtro principal de grupos — usar safeState.
   */
  safeCity: string;
  /**
   * Estado del usuario.
   *   profile.state  →  detectedState  →  null
   * Null si no se conoce. Es el filtro principal para descubrir grupos.
   */
  safeState: string | null;
  /**
   * País del usuario.
   *   profile.country  →  detectedCountry  →  null
   * Null si no se conoce. Usar para filtro de país como segundo nivel.
   */
  safeCountry: string | null;
}

// ─── Context ──────────────────────────────────────────────────────────────────

const AuthContext = createContext<AuthContextValue | null>(null);

// ─── Provider ─────────────────────────────────────────────────────────────────

export function AuthProvider({ children }: { children: React.ReactNode }) {
  const [state, setState] = useState<AuthState>({
    session: null,
    user: null,
    profile: null,
    role: null,
    loading: true,   // Arranca en true — la app espera antes de mostrar cualquier pantalla
    error: null,
    detectedCity: null,
    detectedState: null,
    detectedCountry: null,
  });

  // Evitar setState después de unmount
  const mountedRef = useRef(true);
  useEffect(() => {
    mountedRef.current = true;
    return () => { mountedRef.current = false; };
  }, []);

  const patch = useCallback((update: Partial<AuthState>) => {
    if (mountedRef.current) {
      setState(prev => ({ ...prev, ...update }));
    }
  }, []);

  // ── Carga el perfil desde la tabla profiles usando el user.id ──────────────
  const fetchProfile = useCallback(async (userId: string): Promise<void> => {
    console.log('[AuthContext] fetchProfile → userId:', userId);

    // Timeout de 12 s para evitar que la app quede bloqueada si Supabase no responde
    const timeout = new Promise<{ data: null; error: { message: string; code: string; details: null; hint: null } }>(
      resolve => setTimeout(() => resolve({ data: null, error: { message: 'Tiempo de espera agotado. Verifica tu conexión.', code: 'timeout', details: null, hint: null } }), 12_000)
    );

    const { data, error } = await Promise.race([
      supabase.rpc('get_my_profile').maybeSingle(),
      timeout,
    ]);

    // Log del resultado crudo para depuración
    console.log('[AuthContext] profiles query result →', { data, error });

    if (error) {
      // Error real: red caída, RLS bloqueó, timeout, etc.
      console.error('[AuthContext] Error al consultar profiles:', {
        message: error.message,
        code:    error.code,
        details: error.details,
        hint:    error.hint,
      });
      patch({
        profile: null,
        role: null,
        loading: false,
        error: `Error al cargar perfil: ${error.message}`,
      });
      return;
    }

    if (!data) {
      // .maybeSingle() devolvió null → no existe fila en profiles para este user.id
      console.error('[AuthContext] No se encontró perfil para userId:', userId,
        '— ¿Se creó la fila en profiles al registrarse?');
      patch({
        profile: null,
        role: null,
        loading: false,
        error: 'No se encontró perfil de usuario. Contacta soporte.',
      });
      return;
    }

    const profile = data as Profile;

    // Validar que el rol sea uno de los valores esperados
    const validRoles: UserRole[] = ['admin', 'group', 'client', 'talent'];
    if (!validRoles.includes(profile.role)) {
      console.error('[AuthContext] Rol inválido en profiles:', profile.role,
        '— Valores aceptados: admin | group | client');
      patch({
        profile: null,
        role: null,
        loading: false,
        error: `Rol inválido: "${profile.role}". Contacta soporte.`,
      });
      return;
    }

    console.log('[AuthContext] Perfil cargado →', { id: profile.id, role: profile.role });
    patch({
      profile,
      role: profile.role,
      loading: false,
      error: null,
    });
  }, [patch]);

  // ── Maneja cualquier cambio de sesión (login, logout, refresh token) ────────
  const handleSession = useCallback(async (session: Session | null, event?: string) => {
    console.log('[AuthContext] handleSession → session:', session ? 'presente' : 'null', '| event:', event);

    if (!session) {
      // Signed out — limpia todo
      console.log('[AuthContext] Sin sesión → limpiando estado');
      patch({
        session: null,
        user: null,
        profile: null,
        role: null,
        loading: false,
        error: null,
      });
      return;
    }

    // TOKEN_REFRESHED / USER_UPDATED ocurren en segundo plano — solo actualizar la sesión silenciosamente.
    if (event === 'TOKEN_REFRESHED' || event === 'USER_UPDATED') {
      patch({ session, user: session.user });
      return;
    }

    // Para INITIAL_SESSION y SIGNED_IN: mostrar SplashLoader mientras validamos
    patch({ loading: true, error: null });

    // Paso 1: confirmar que la sesión es válida en el servidor (no solo caché local)
    // Timeout de 10 s — si getUser() cuelga, confiamos en la sesión local
    console.log('[AuthContext] Validando JWT con getUser()...');
    const getUserTimeout = new Promise<{ data: { user: null }; error: { message: string; status: number } }>(
      resolve => setTimeout(() => resolve({ data: { user: null }, error: { message: 'timeout', status: 0 } }), 10_000)
    );
    const { data: { user }, error: userError } = await Promise.race([
      supabase.auth.getUser(),
      getUserTimeout,
    ]);

    if (userError) {
      if ((userError as any).status === 0) {
        // Timeout — confiamos en la sesión local y continuamos
        console.warn('[AuthContext] getUser() timeout — usando sesión local');
        patch({ session, user: session.user });
        await fetchProfile(session.user.id);
        return;
      }
      console.error('[AuthContext] getUser() falló:', {
        message: userError.message,
        status:  (userError as any).status,
      });
      // Token inválido o expirado — forzar sign out
      await supabase.auth.signOut();
      patch({
        session: null,
        user: null,
        profile: null,
        role: null,
        loading: false,
        error: null,
      });
      return;
    }

    if (!user) {
      console.error('[AuthContext] getUser() devolvió null sin error — sesión inconsistente');
      await supabase.auth.signOut();
      patch({
        session: null,
        user: null,
        profile: null,
        role: null,
        loading: false,
        error: null,
      });
      return;
    }

    // Paso 2: sesión confirmada → ahora sí buscar el perfil
    console.log('[AuthContext] JWT válido → user.id:', user.id, '| email:', user.email);
    patch({ session, user });

    await fetchProfile(user.id);
  }, [patch, fetchProfile]);

  // ── Suscripción única a cambios de auth ────────────────────────────────────
  useEffect(() => {
    const { data: { subscription } } = supabase.auth.onAuthStateChange(
      async (event, session) => {
        console.log('[AuthContext] onAuthStateChange →', event,
          '| session:', session ? session.user?.id : 'null');
        if (!mountedRef.current) return;
        await handleSession(session, event);
      }
    );

    return () => subscription.unsubscribe();
  }, [handleSession]);

  // ── GPS — detección silenciosa de estado y país (solo lectura) ─────────────
  // Detecta la ubicación del dispositivo y la guarda SOLO EN MEMORIA como
  // detectedState/detectedCountry. NUNCA escribe a la DB automáticamente.
  // La escritura la confirma el usuario vía LocationRequestScreen.
  // Se activa cuando falta state o country en el perfil (cualquier rol excepto admin).
  useEffect(() => {
    const { profile, role } = state;
    if (!profile || role === 'admin') return;
    // Salir si ya tenemos estado Y país persistidos en el perfil
    if (profile.state && profile.country) return;
    // O si ya los detectamos en esta sesión
    if (state.detectedState && state.detectedCountry) return;

    let cancelled = false;

    (async () => {
      try {
        // Solo detectar si el permiso YA fue otorgado — el prompt del sistema
        // lo dispara LocationRequestScreen cuando el usuario toca "Activar"
        // (mejor práctica de tiendas: pedir permiso en contexto, no al abrir).
        const { status } = await Location.getForegroundPermissionsAsync();
        if (status !== 'granted') return;

        const loc = await Promise.race([
          Location.getCurrentPositionAsync({ accuracy: Location.Accuracy.Balanced }),
          new Promise<never>((_, reject) =>
            setTimeout(() => reject(new Error('gps timeout')), 6000)
          ),
        ]);

        const geocodeResult = await Promise.race([
          Location.reverseGeocodeAsync({
            latitude:  loc.coords.latitude,
            longitude: loc.coords.longitude,
          }),
          new Promise<never>((_, reject) =>
            setTimeout(() => reject(new Error('geocode timeout')), 3000)
          ),
        ]);

        const place       = (geocodeResult as Location.LocationGeocodedAddress[])[0];
        const stateName   = place?.region ?? null;                      // "Jalisco"
        const countryIso  = place?.isoCountryCode ?? null;              // "MX"
        const countryName = countryIso ? isoToCountryName(countryIso) : null; // "México"
        if ((!stateName && !countryName) || cancelled) return;

        console.log('[AuthContext] GPS detectó — estado:', stateName, '| país:', countryName);

        // Solo persiste en memoria. La escritura a DB la confirma el usuario vía LocationRequestScreen.
        if (mountedRef.current) {
          patch({ detectedState: stateName, detectedCountry: countryName });
        }
      } catch (err) {
        console.log('[AuthContext] GPS silencioso falló (normal):', err);
      }
    })();

    return () => { cancelled = true; };
  }, [state.profile?.id, state.role]);

  // ── API pública del contexto ───────────────────────────────────────────────

  const signOut = useCallback(async () => {
    // Limpiar estado inmediatamente sin esperar onAuthStateChange
    patch({
      session: null,
      user: null,
      profile: null,
      role: null,
      loading: false,
      error: null,
    });
    await supabase.auth.signOut();
  }, [patch]);

  const refetchProfile = useCallback(async () => {
    if (state.user?.id) {
      // No ponemos loading:true para evitar flash del SplashLoader.
      // El perfil se actualiza silenciosamente y AppNavigator re-renderiza
      // cuando cambian los datos (ej: profile.city recién asignada).
      patch({ error: null });
      await fetchProfile(state.user.id);
    }
  }, [state.user?.id, fetchProfile, patch]);

  const safeCity    = state.profile?.city    ?? state.detectedCity    ?? FALLBACK_CITY;
  const safeState   = state.profile?.state   ?? state.detectedState   ?? null;
  const safeCountry = state.profile?.country ?? state.detectedCountry ?? null;

  return (
    <AuthContext.Provider value={{ ...state, signOut, refetchProfile, safeCity, safeState, safeCountry }}>
      {children}
    </AuthContext.Provider>
  );
}

// ─── Hook ─────────────────────────────────────────────────────────────────────

/**
 * Retorna el contexto de autenticación.
 * Lanza error si se usa fuera de <AuthProvider>.
 */
export function useAuth(): AuthContextValue {
  const ctx = useContext(AuthContext);
  if (!ctx) {
    throw new Error('useAuth debe usarse dentro de <AuthProvider>');
  }
  return ctx;
}
