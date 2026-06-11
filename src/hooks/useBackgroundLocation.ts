import { useEffect, useRef, useState } from 'react';
import { AppState, AppStateStatus } from 'react-native';
import {
  startBackgroundLocation,
  stopBackgroundLocation,
  updateLocationOnce,
} from '../utils/backgroundLocation';

/**
 * Activa GPS en background mientras el componente esté montado.
 * Al desmontarse (logout/cierre) marca offline.
 *
 * Uso: llama este hook en el Dashboard de grupo, talento o cliente.
 *   const { gpsActive } = useBackgroundLocation();
 */
export function useBackgroundLocation() {
  const [gpsActive, setGpsActive]   = useState(false);
  const [requested, setRequested]   = useState(false);
  const appStateRef = useRef<AppStateStatus>(AppState.currentState);

  useEffect(() => {
    let mounted = true;

    const init = async () => {
      const ok = await startBackgroundLocation();
      if (mounted) {
        setGpsActive(ok);
        setRequested(true);
      }
    };

    init();

    // Cuando la app vuelve al foreground: refrescar ubicación
    const sub = AppState.addEventListener('change', async (next) => {
      if (appStateRef.current.match(/inactive|background/) && next === 'active') {
        await updateLocationOnce();
      }
      appStateRef.current = next;
    });

    return () => {
      mounted = false;
      sub.remove();
      stopBackgroundLocation();
    };
  }, []);

  return { gpsActive, requested };
}
