import * as Location from 'expo-location';
import * as TaskManager from 'expo-task-manager';
import { supabase } from '../config/supabase';

export const BG_LOCATION_TASK = 'daricefy-bg-location';

// ── Definición del task — DEBE estar en el top level del módulo ───────────────
// Se ejecuta cada vez que el OS entrega una nueva ubicación,
// incluso cuando la app está en segundo plano o cerrada.

TaskManager.defineTask(BG_LOCATION_TASK, async ({ data, error }: any) => {
  if (error) {
    console.error('[BGLocation]', error.message);
    return;
  }

  const locations: Location.LocationObject[] = data?.locations ?? [];
  const loc = locations[0];
  if (!loc) return;

  const { latitude: lat, longitude: lng } = loc.coords;

  // Rechazar coordenadas inválidas antes de persistir en DB
  if (lat == null || lng == null)                       return;
  if (lat === 0 && lng === 0)                           return;
  if (lat < -90 || lat > 90 || lng < -180 || lng > 180) return;
  if (!isFinite(lat) || !isFinite(lng))                 return;

  try {
    // Reversa geocoding para obtener ciudad/estado
    const [geo] = await Location.reverseGeocodeAsync({ latitude: lat, longitude: lng });
    const city  = geo?.city  ?? geo?.subregion ?? null;
    const state = geo?.region ?? null;

    await supabase.rpc('update_my_live_location', {
      p_lat: lat, p_lng: lng,
      p_city: city, p_state: state,
    });
  } catch (e) {
    // Falla silenciosa — no crashea la tarea
    console.warn('[BGLocation] update failed:', e);
  }
});

// ── Pedir permisos y arrancar el tracking ────────────────────────────────────

export async function startBackgroundLocation(): Promise<boolean> {
  try {
    // 1. Permiso foreground (siempre primero)
    let fgStatus: string;
    try {
      const res = await Location.requestForegroundPermissionsAsync();
      fgStatus = res.status;
    } catch {
      // iOS: Info.plist sin las claves NSLocation* — app no fue reconstruida aún
      // Silencioso: la ubicación simplemente no estará disponible en esta sesión
      return false;
    }

    if (fgStatus !== 'granted') return false;

    // 2. Actualización inmediata (funciona con solo foreground)
    await updateLocationOnce();

    // 3. Permiso background ("Siempre" en iOS / "Todo el tiempo" en Android)
    let bgStatus: string;
    try {
      const res = await Location.requestBackgroundPermissionsAsync();
      bgStatus = res.status;
    } catch {
      // Background no disponible (Expo Go, Info.plist sin UIBackgroundModes)
      return false;
    }

    if (bgStatus !== 'granted') return false;

    // 4. Si ya hay una tarea corriendo, no la duplicamos
    const running = await Location.hasStartedLocationUpdatesAsync(BG_LOCATION_TASK).catch(() => false);
    if (running) return true;

    // 5. Arrancar actualizaciones en background
    await Location.startLocationUpdatesAsync(BG_LOCATION_TASK, {
      accuracy: Location.Accuracy.Balanced,
      timeInterval: 5 * 60 * 1000,       // cada 5 minutos
      distanceInterval: 300,              // o cada 300 metros
      deferredUpdatesInterval: 5 * 60 * 1000,
      pausesUpdatesAutomatically: false,
      foregroundService: {                // Android: notificación persistente
        notificationTitle: 'Daricefy activo',
        notificationBody: 'Tu ubicación se está compartiendo.',
        notificationColor: '#00E676',
      },
      showsBackgroundLocationIndicator: true, // iOS: indicador azul en status bar
    });

    return true;
  } catch (e) {
    // Falla silenciosa — la app sigue funcionando sin GPS en background
    return false;
  }
}

// ── Detener el tracking ───────────────────────────────────────────────────────

export async function stopBackgroundLocation(): Promise<void> {
  try {
    const running = await Location.hasStartedLocationUpdatesAsync(BG_LOCATION_TASK).catch(() => false);
    if (running) await Location.stopLocationUpdatesAsync(BG_LOCATION_TASK);
    await supabase.rpc('set_me_offline');
  } catch (e) {
    console.warn('[BGLocation] stopBackgroundLocation error:', e);
  }
}

// ── Una sola lectura cuando no hay permiso background ────────────────────────

export async function updateLocationOnce(): Promise<void> {
  try {
    const { status } = await Location.getForegroundPermissionsAsync();
    if (status !== 'granted') return;
    const loc = await Location.getCurrentPositionAsync({ accuracy: Location.Accuracy.Balanced });
    const { latitude: lat, longitude: lng } = loc.coords;
    if (lat == null || lng == null)                        return;
    if (lat === 0 && lng === 0)                            return;
    if (lat < -90 || lat > 90 || lng < -180 || lng > 180) return;
    if (!isFinite(lat) || !isFinite(lng))                  return;
    const [geo] = await Location.reverseGeocodeAsync(loc.coords);
    await supabase.rpc('update_my_live_location', {
      p_lat: lat,
      p_lng: lng,
      p_city: geo?.city ?? geo?.subregion ?? null,
      p_state: geo?.region ?? null,
    });
  } catch (e) {
    console.warn('[BGLocation] updateLocationOnce error:', e);
  }
}
