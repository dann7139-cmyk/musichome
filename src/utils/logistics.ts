import { supabase } from '../config/supabase';

export interface LogisticsConflict {
  conflict: boolean;
  reason?: 'overlap' | 'time_buffer' | 'travel_time';
  /** Mensaje para el cliente (genérico) */
  messageClient?: string;
  /** Mensaje para el grupo (con detalle de traslado) */
  messageGroup?: string;
  gapMinutes?: number;
  travelMinutes?: number;
}

/**
 * Llama a la Edge Function `check-travel-conflict` para validar si un grupo
 * puede aceptar un nuevo evento (nueva reserva, reprogramación) sin conflicto
 * logístico con sus eventos existentes.
 *
 * Falla abierto (conflict: false) si el servidor no responde — no bloquear
 * operaciones por errores de red.
 */
export async function checkGroupLogistics(params: {
  groupId:       string;
  eventDate:     string;    // 'YYYY-MM-DD'
  eventTime?:    string;    // 'HH:MM' o 'HH:MM:SS'
  durationHours?: number;   // default 3
  lat?:          number;
  lng?:          number;
  skipId?:       string;    // UUID de reserva a ignorar (para reschedule)
}): Promise<LogisticsConflict> {
  try {
    const { data: session } = await supabase.auth.getSession();
    const token = session.session?.access_token;
    if (!token) return { conflict: false };

    const { data, error } = await supabase.functions.invoke('check-travel-conflict', {
      body: {
        group_id:       params.groupId,
        event_date:     params.eventDate,
        event_time:     params.eventTime,
        duration_hours: params.durationHours ?? 3,
        lat:            params.lat,
        lng:            params.lng,
        skip_id:        params.skipId ?? '',
      },
      headers: { Authorization: `Bearer ${token}` },
    });

    if (error || !data) return { conflict: false };

    return {
      conflict:       data.conflict ?? false,
      reason:         data.reason,
      messageClient:  data.message_client,
      messageGroup:   data.message_group,
      gapMinutes:     data.gap_minutes,
      travelMinutes:  data.travel_minutes,
    };
  } catch {
    return { conflict: false };
  }
}

/**
 * ¿Cuántas horas extra caben después de un evento sin invadir las 2h de
 * traslado hacia la siguiente tocada del grupo ese mismo día?
 *
 * - Devuelve Infinity si el grupo NO tiene otra tocada después ese día
 *   (horas extra sin restricción).
 * - Devuelve 0 si el evento queda "encajonado" (no cabe ni una hora extra).
 * - Falla abierto (Infinity) si no se puede consultar — no bloquear por red.
 */
export async function maxExtraHoursAfter(params: {
  groupId:        string;
  eventDate:      string;          // 'YYYY-MM-DD'
  eventTime?:     string | null;   // 'HH:MM' o 'HH:MM:SS'
  durationHours?: number | null;   // horas contratadas (default 3)
}): Promise<number> {
  try {
    if (!params.groupId || !params.eventDate || !params.eventTime) return Infinity;
    const [h, m] = String(params.eventTime).split(':').map(Number);
    if (!Number.isFinite(h)) return Infinity;
    const start = h + (m || 0) / 60;
    const end   = start + (Number(params.durationHours) || 3);

    const { data, error } = await supabase.rpc('get_group_busy_days', {
      p_group_id: params.groupId,
      p_from:     params.eventDate,
      p_to:       params.eventDate,
    });
    if (error || !Array.isArray(data)) return Infinity;

    let cap = Infinity;
    for (const row of data as any[]) {
      if (!row?.event_time) continue;
      const [bh, bm] = String(row.event_time).split(':').map(Number);
      const bs = bh + (bm || 0) / 60;
      if (bs <= start + 0.01) continue;          // el propio evento o uno anterior
      cap = Math.min(cap, bs - 2 - end);         // 2h de traslado obligatorias
    }
    return cap === Infinity ? Infinity : Math.max(0, Math.floor(cap + 1e-9));
  } catch {
    return Infinity;
  }
}

/** Detecta currency_code basado en el país del evento. */
export function currencyForCountry(country: 'MX' | 'US' | string): 'MXN' | 'USD' {
  return country === 'US' ? 'USD' : 'MXN';
}

/** Formatea un monto con el símbolo correcto según moneda. */
export function formatMoney(amount: number, currency: 'MXN' | 'USD' | string): string {
  if (currency === 'USD') {
    return `US$${amount.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
  }
  return `$${amount.toLocaleString('es-MX', { minimumFractionDigits: 0, maximumFractionDigits: 2 })}`;
}
