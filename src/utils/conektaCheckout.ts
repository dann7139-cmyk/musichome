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

export type ConektaStatus = 'paid' | 'pending' | 'error';
export interface ConektaResult {
  status:  ConektaStatus;
  orderId: string | null;   // para recuperar la referencia SPEI/efectivo
}

// Método de pago elegido en el checkout Daricefy. El backend lo traduce a los
// allowed_payment_methods de Conekta y aplica el descuento SPEI cuando toca.
export type ConektaMethod = 'card' | 'spei' | 'cash' | 'msi' | 'bnpl';

// Datos de pago pendiente (CLABE SPEI o referencia de efectivo) de una orden.
export interface ConektaReference {
  method_type: string | null;
  clabe:       string | null;
  bank:        string | null;
  reference:   string | null;
  barcode_url: string | null;
  amount:      number | null;   // MXN
  expires_at:  number | null;   // unix seconds
}

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
  const url     = (data as any)?.checkout_url as string | undefined;
  const orderId = ((data as any)?.order_id as string | undefined) ?? null;
  if (error || (data as any)?.error || !url) {
    console.warn('[conekta] create-order falló:', (data as any)?.error ?? error?.message);
    return { status: 'error', orderId: null };
  }

  // 2. Abrir el navegador in-app (el pago ocurre aquí)
  await WebBrowser.openBrowserAsync(url);

  // 3. Al volver: consultar la reserva. El webhook es la fuente de verdad.
  //    Tarjeta/BNPL: ~6 s de espera máx — si el usuario CERRÓ sin pagar, la
  //    UI se libera rápido para elegir otro método (antes eran 20 s con todo
  //    bloqueado). Si sí pagó y el webhook tarda más, igual confirma solo y
  //    la reserva aparece pagada al refrescar.
  //    SPEI/efectivo: el pago NO ocurre ahora (el cliente transfiere después),
  //    así que 1 sola consulta y regresamos 'pending' de inmediato.
  const attempts = (method === 'spei' || method === 'cash') ? 1 : 4;
  for (let i = 0; i < attempts; i++) {
    const { data: r } = await supabase
      .from('reservations')
      .select('payment_status')
      .eq('id', reservationId)
      .single();
    if (r && ['paid', 'fully_paid'].includes(r.payment_status)) {
      return { status: 'paid', orderId };
    }
    if (i < attempts - 1) await new Promise((res) => setTimeout(res, 1500));
  }
  return { status: 'pending', orderId };
}

// ── 📣 Publicidad con Conekta (banner/destacado/perfil · bid · recomendado) ──
// Crea la orden hosted por el MONTO de la orden en BD (server-side) y abre el
// checkout. La activación la hace conekta-webhook — al volver del navegador
// NO se asume pagado (OXXO/SPEI se acreditan después).
export async function startPromoConektaCheckout(
  kind: 'ad' | 'bid' | 'rec',
  id: string,
): Promise<{ ok: boolean; error?: string }> {
  const { data: sd } = await supabase.auth.getSession();
  const { data, error } = await supabase.functions.invoke('create-promo-conekta-order', {
    body:    { kind, id },
    headers: { Authorization: `Bearer ${sd.session?.access_token}` },
  });
  const url = (data as any)?.checkout_url as string | undefined;
  if (error || (data as any)?.error || !url) {
    const msg = (data as any)?.error ?? error?.message ?? 'No se pudo iniciar el pago';
    console.warn('[conekta] promo create-order falló:', msg);
    return { ok: false, error: msg };
  }
  await WebBrowser.openBrowserAsync(url);
  return { ok: true };
}

// Recupera la CLABE (SPEI) o referencia (efectivo) de una orden pendiente,
// para re-mostrarla en la app (la página de Conekta la enseña solo unos
// segundos antes de redirigir).
export async function fetchConektaReference(orderId: string): Promise<ConektaReference | null> {
  try {
    const { data: sd } = await supabase.auth.getSession();
    const { data, error } = await supabase.functions.invoke('get-conekta-reference', {
      body:    { order_id: orderId },
      headers: { Authorization: `Bearer ${sd.session?.access_token}` },
    });
    if (error || (data as any)?.error) {
      console.warn('[conekta] get-reference falló:', (data as any)?.error ?? error?.message);
      return null;
    }
    return data as ConektaReference;
  } catch {
    return null;
  }
}
