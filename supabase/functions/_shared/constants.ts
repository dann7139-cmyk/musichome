/** Markup de plataforma: 20% sobre precio neto del grupo. */
export const COMMISSION_RATE = 0.20;

/** Multiplicador precio neto → precio cliente. clienteTotal = grupoNeto × COMMISSION_DIVISOR */
export const COMMISSION_DIVISOR = 1.20;

/** Descuento fijo en MXN para pagos SPEI (absorbido por Daricefy). */
export const SPEI_DISCOUNT_MXN = 100;

/**
 * Tasas de cargo financiero MSI por número de meses (sobre el precio contado).
 * Igualadas a la comisión REAL que Stripe cobra por meses sin intereses en
 * México (docs.stripe.com/payments/mx-installments) — antes 6/9/12 meses
 * cobraban menos de lo que Stripe le cobra a Daricefy por esos plazos
 * (6%/9%/12% en vez de 7.5%/10%/12.5%), perdiendo la diferencia en cada
 * pago a meses de 6, 9 o 12 (corregido 2026-09-11).
 */
export const MSI_FEE_RATES: Record<number, number> = {
  1:  0,
  3:  0.05,
  6:  0.075,
  9:  0.10,
  12: 0.125,
};
