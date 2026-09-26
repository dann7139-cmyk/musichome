import { Alert } from 'react-native';
import type { TFunction } from 'i18next';
import i18n from '../i18n';
import { supabase } from '../config/supabase';

// sql/585 (ya aplicado a producción) — "carrito"/constructor de evento. Si
// client_get_my_events() no existiera o fallara, esta función devuelve [] de
// forma segura (fallback = cada reserva crea su propio evento nuevo, el
// comportamiento anterior).

export interface ActiveEventOption {
  event_id: string;
  event_date: string;
  address: string;
  providerCount: number;
  providerLimit: number;
}

const ACTIVE_RES_STATUSES = ['pending', 'pending_payment', 'pending_group_confirmation', 'accepted', 'confirmed', 'in_progress'];

// sql/686 — el límite de proveedores por evento vive en la BASE
// (max_providers_per_event(), una sola fuente de verdad que leen también los 2
// triggers, resolve_shared_event_id() y create_booking_with_event()).
// client_get_my_events() lo manda por evento en `provider_limit`, así que aquí
// NO se hardcodea: esta constante es solo el respaldo para cuando la app corre
// contra una base donde sql/686 todavía no se aplicó (la RPC vieja no manda el
// campo). Antes de sql/686 el valor era 3.
const PROVIDER_LIMIT_FALLBACK = 20;

const dateLocale = () => (i18n.language?.startsWith('en') ? 'en-US' : 'es-MX');

export async function getClientActiveEvents(): Promise<ActiveEventOption[]> {
  const { data, error } = await supabase.rpc('client_get_my_events');
  if (error || !data?.ok) return [];
  const today = new Date().toISOString().slice(0, 10);
  return (data.items ?? [])
    .filter((ev: any) => ev.event_date >= today)
    .map((ev: any): ActiveEventOption => ({
      event_id: ev.event_id,
      event_date: ev.event_date,
      address: ev.address,
      providerCount: (ev.providers ?? []).filter((p: any) => ACTIVE_RES_STATUSES.includes(p.status)).length,
      providerLimit: Number(ev.provider_limit) > 0 ? Number(ev.provider_limit) : PROVIDER_LIMIT_FALLBACK,
    }))
    .filter((ev: ActiveEventOption) => ev.providerCount < ev.providerLimit);
}

/**
 * Decisión SIEMPRE explícita, nunca inferida por texto de dirección.
 * - Si `presetEventId` ya viene decidido (el cliente llegó aquí desde
 *   "Agregar otro proveedor a mi evento"), se usa directo, sin preguntar.
 * - Si no hay eventos activos con cupo, resuelve null (crea uno nuevo —
 *   comportamiento idéntico al actual).
 * - Si hay exactamente 1, pregunta explícito sí/no.
 * - Si hay 2+ (raro — dos fiestas distintas a la vez), deja elegir cuál.
 *
 * `t` es obligatorio — mismo patrón getXxx(t)/factory ya usado en el resto
 * del proyecto para utilidades fuera de un componente (no pueden llamar al
 * hook useTranslation directo).
 */
export function resolveEventContext(params: {
  t: TFunction;
  presetEventId?: string | null;
  activeEvents: ActiveEventOption[];
}): Promise<string | null> {
  const { t } = params;
  return new Promise((resolve) => {
    if (params.presetEventId) {
      resolve(params.presetEventId);
      return;
    }
    if (params.activeEvents.length === 0) {
      resolve(null);
      return;
    }
    if (params.activeEvents.length === 1) {
      const ev = params.activeEvents[0];
      const fecha = new Date(ev.event_date + 'T12:00:00').toLocaleDateString(dateLocale(), { day: 'numeric', month: 'long' });
      Alert.alert(
        t('eventBuilder.confirmTitle'),
        t('eventBuilder.confirmMessage', { date: fecha, address: ev.address }),
        [
          { text: t('eventBuilder.newEvent'), style: 'cancel', onPress: () => resolve(null) },
          { text: t('eventBuilder.addToExisting'), onPress: () => resolve(ev.event_id) },
        ],
        // Hallazgo de auditoría (2026-09-04): en Android, Alert.alert es
        // descartable con el botón "atrás" por default — sin onDismiss, esa
        // acción no llama a NINGÚN botón y la Promise se queda esperando
        // para siempre, dejando loading=true fijo en la pantalla que llamó
        // esto (flujo roto real, no solo teórico). resolve() es idempotente
        // — si el usuario sí tocó un botón, esto no hace nada de más.
        { cancelable: true, onDismiss: () => resolve(null) },
      );
      return;
    }
    const buttons = params.activeEvents.map(ev => ({
      text: new Date(ev.event_date + 'T12:00:00').toLocaleDateString(dateLocale(), { day: 'numeric', month: 'short' }) + ` — ${ev.address}`,
      onPress: () => resolve(ev.event_id),
    }));
    buttons.push({ text: t('eventBuilder.newEvent'), style: 'cancel', onPress: () => resolve(null) } as any);
    Alert.alert(
      t('eventBuilder.multiTitle'), t('eventBuilder.multiMessage'), buttons as any,
      { cancelable: true, onDismiss: () => resolve(null) },
    );
  });
}
