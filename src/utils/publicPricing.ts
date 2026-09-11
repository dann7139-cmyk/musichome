// ── Precios públicos para cotizaciones ────────────────────────────────────────
//
// El grupo escribe el monto NETO que quiere recibir.
// La plataforma carga el 20% encima → contado = precioGrupo × 1.20.
// Los planes MSI aplican un multiplicador sobre el contado.
//
// Fórmulas oficiales (igualadas a la comisión REAL de Stripe MSI México,
// docs.stripe.com/payments/mx-installments — corregido 2026-09-11, antes
// 6/9/12 meses cobraban menos de lo que Stripe le cobra a Daricefy):
//   contado  = groupPrice × 1.20
//   3 meses  = contado × 1.05
//   6 meses  = contado × 1.075
//   9 meses  = contado × 1.10
//   12 meses = contado × 1.125

/** Tasas de financiamiento MSI por número de meses (sobre el contado). Debe
 *  coincidir EXACTO con MSI_FEE_RATES de supabase/functions/_shared/constants.ts */
export const PUBLIC_MSI_FEE_RATES: Record<number, number> = {
  1:  0,
  3:  0.05,
  6:  0.075,
  9:  0.10,
  12: 0.125,
};

export interface PublicPrices {
  contado: number;
  meses3:  number;
  meses6:  number;
  meses9:  number;
  meses12: number;
}

/**
 * Dado el precio neto del grupo (lo que recibirán), retorna los precios
 * públicos en todas las modalidades de pago.
 */
export function calculatePublicPrices(groupPrice: number): PublicPrices {
  const contado = calculateContadoPrice(groupPrice);
  return {
    contado,
    meses3:  calculateFinancedPrice(contado, 3),
    meses6:  calculateFinancedPrice(contado, 6),
    meses9:  calculateFinancedPrice(contado, 9),
    meses12: calculateFinancedPrice(contado, 12),
  };
}

/**
 * Precio de contado (pago único) dado el precio neto del grupo.
 * El grupo siempre recibe exactamente `groupPrice`.
 */
export function calculateContadoPrice(groupPrice: number): number {
  if (groupPrice <= 0) return 0;
  return Math.round(groupPrice * 1.20);
}

/**
 * Precio total que paga el cliente en un plan de financiamiento.
 * @param contado  Precio de contado (1 pago)
 * @param months   Número de meses (1, 3, 6, 9, 12)
 */
export function calculateFinancedPrice(contado: number, months: number): number {
  const multiplier = 1 + (PUBLIC_MSI_FEE_RATES[months] ?? 0);
  return Math.round(contado * multiplier);
}

/** Monto por mensualidad dado el precio de contado y el número de meses. */
export function calculateMonthlyPayment(contado: number, months: number): number {
  if (months <= 1) return contado;
  return Math.ceil(calculateFinancedPrice(contado, months) / months);
}
