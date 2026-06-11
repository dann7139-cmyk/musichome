/**
 * usePushNotifications
 *
 * Solicita permisos, obtiene el Expo Push Token y lo registra en Supabase
 * (tabla push_tokens via RPC register_push_token).
 *
 * Llamar una sola vez en AppNavigator cuando el usuario tiene sesión activa.
 * Usa try/catch en todo para no romper el flujo si el dispositivo no soporta
 * notificaciones push (simulador iOS, Android emulador, web).
 */

import Constants from 'expo-constants';
import * as Notifications from 'expo-notifications';
import { useEffect, useRef } from 'react';
import { Platform } from 'react-native';
import { registerPushToken } from '../utils/pushNotifications';

// Comportamiento al recibir notificación en primer plano
Notifications.setNotificationHandler({
  handleNotification: async () => ({
    shouldShowAlert:  true,
    shouldPlaySound:  true,
    shouldSetBadge:   true,
    shouldShowBanner: true,
    shouldShowList:   true,
  }),
});

export function usePushNotifications(userId: string | null) {
  const registered = useRef(false);
  const currentToken = useRef<string | null>(null);

  useEffect(() => {
    if (!userId) {
      // Logout: eliminar token del dispositivo actual si lo tenemos
      if (currentToken.current) {
        import('../utils/pushNotifications').then(({ unregisterPushToken }) => {
          unregisterPushToken(currentToken.current!).catch(() => {});
        });
        currentToken.current = null;
        registered.current = false;
      }
      return;
    }
    if (registered.current) return;
    registerToken();
  }, [userId]);

  const registerToken = async () => {
    try {
      // Solicitar permisos (no muestra diálogo si ya fue concedido/rechazado)
      const { status: currentStatus } = await Notifications.getPermissionsAsync();
      let finalStatus = currentStatus;

      if (currentStatus !== 'granted') {
        const { status } = await Notifications.requestPermissionsAsync();
        finalStatus = status;
      }

      if (finalStatus !== 'granted') {
        console.log('[Push] Permiso denegado — no se registra token');
        return;
      }

      const projectId: string | undefined =
        Constants.expoConfig?.extra?.eas?.projectId ??
        Constants.easConfig?.projectId ??
        undefined;

      // En Expo Go sin EAS configurado no hay projectId — skip silencioso.
      // En dev build o producción el projectId viene del eas.json.
      if (!projectId && Constants.appOwnership === 'expo') {
        console.log('[Push] Expo Go sin EAS projectId — push deshabilitado en desarrollo');
        return;
      }

      const tokenData = await Notifications.getExpoPushTokenAsync({ projectId });
      const token = tokenData.data;

      const platform = Platform.OS === 'ios' ? 'ios'
                     : Platform.OS === 'android' ? 'android'
                     : 'web';

      await registerPushToken(token, platform);
      registered.current = true;
      currentToken.current = token;
      console.log('[Push] Token registrado:', token.slice(-8));

      // Canal de notificaciones para Android
      if (Platform.OS === 'android') {
        await Notifications.setNotificationChannelAsync('default', {
          name:       'Daricefy',
          importance: Notifications.AndroidImportance.MAX,
          vibrationPattern: [0, 250, 250, 250],
          lightColor: '#00E676',
        });
      }
    } catch (e) {
      // Silencioso: simulador, entorno web, sin configuración de EAS
      console.warn('[Push] No se pudo registrar token:', e);
    }
  };
}
