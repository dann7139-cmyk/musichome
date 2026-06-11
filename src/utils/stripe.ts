import { supabase } from '../config/supabase';

export interface MPPreferenceResult {
  initPoint: string;        // URL de pago (producción o sandbox)
  preferenceId: string;
  deposit: number;          // monto del anticipo en pesos
  fullPrice: number;        // precio total del paquete en pesos
}

/**
 * Llama a la Edge Function para crear una preferencia de Mercado Pago.
 * El backend lee la reserva, calcula el 50% y crea la preferencia.
 * @param reservationId - ID de la reserva en Supabase
 * @returns URL de checkout + info del monto
 */
export async function createMPPreference(
  reservationId: string,
): Promise<MPPreferenceResult> {
  const { data: sd } = await supabase.auth.getSession();
  const { data, error } = await supabase.functions.invoke('create-mp-preference', {
    body: { reservation_id: reservationId },
    headers: sd.session ? { Authorization: `Bearer ${sd.session.access_token}` } : {},
  });

  if (error || !data) {
    // Intentar extraer el mensaje real del body de la Edge Function
    let message = 'Error creando preferencia de Mercado Pago';
    try {
      const errBody = await (error as any)?.context?.json?.();
      if (errBody?.error) message = errBody.error;
    } catch { /* usa mensaje genérico */ }
    throw new Error(message);
  }

  const url: string = data.sandbox_init_point ?? data.init_point;
  if (!url) throw new Error('No se recibió el enlace de pago de Mercado Pago');

  return {
    initPoint: url,
    preferenceId: data.preference_id,
    deposit: data.deposit,
    fullPrice: data.full_price,
  };
}
