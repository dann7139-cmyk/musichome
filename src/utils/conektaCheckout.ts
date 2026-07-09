// ============================================================
// src/utils/conektaCheckout.ts
// Hosted Checkout de Conekta (México). Abre la página de pago de Conekta en
// navegador in-app y espera la confirmación del WEBHOOK (fuente de verdad).
//
// REGLA (Decisión 1): NUNCA se da el pago por exitoso solo porque el usuario
// volvió del navegador. Al volver, se consulta la reserva; el webhook es quien
// marca payment_status='paid' y acredita la wallet (misma RPC que Stripe).
//
// No toca wallet, GPS ni anti-fraude — solo dispara el cobro.
// ============================================================
import * as WebBrowser from 'expo-web-browser';
import { supabase } from '../config/supabase';

export type ConektaResult = 'paid' | 'pending' | 'error';

// Método de pago elegido en el checkout Daricefy. El backend lo traduce a los
// allowed_payment_methods de Conekta y aplica el descuento SPEI cuando toca.
export type ConektaMethod = 'card' | 'spei' | 'cash' | 'msi' | 'bnpl';

export async function startConektaCheckout(
  reservationId: string,
  method: ConektaMethod = 'card',
): Promise<ConektaResult> {
  // 1. Crear la orden Hosted
  const { data: sd } = await supabase.auth.getSession();
  const { data, error } = await supabase.functions.invoke('create-conekta-order', {
    body:    { reservation_id: reservationId, method },
    headers: { Authorization: `Bearer ${sd.session?.access_token}` },
  });
  const url = (data as any)?.checkout_url as string | undefined;
  if (error || (data as any)?.error || !url) {
    console.warn('[conekta] create-order falló:', (data as any)?.error ?? error?.message);
    return 'error';
  }

  // 2. Abrir el navegador in-app (el pago ocurre aquí)
  await WebBrowser.openBrowserAsync(url);

  // 3. Al volver: consultar la reserva. El webhook es la fuente de verdad;
  //    reintentar ~20 s por si tarda unos segundos en llegar.
  for (let i = 0; i < 10; i++) {
    const { data: r } = await supabase
      .from('reservations')
      .select('payment_status')
      .eq('id', reservationId)
      .single();
    if (r && ['paid', 'fully_paid'].includes(r.payment_status)) return 'paid';
    await new Promise((res) => setTimeout(res, 2000));
  }
  return 'pending';
}
