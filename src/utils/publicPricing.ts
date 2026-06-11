// ── Precios públicos para cotizaciones ────────────────────────────────────────
//
// El grupo escribe el monto NETO que quiere recibir.
// La plataforma carga el 10% encima → contado = precioGrupo / 0.90.
// Los planes MSI aplican un multiplicador sobre el contado.
//
// Fórmulas oficiales:
//   contado  = groupPrice / 0.90
//   3 meses  = contado × 1.05
//   6 meses  = contado × 1.08
//   9 meses  = contado × 1.11
//   12 meses = contado × 1.14

/** Tasas de financiamiento MSI por número de meses (sobre el contado). */
export const PUBLIC_MSI_FEE_RATES: Record<number, number> = {
  1:  0,
  3:  0.05,
  6:  0.08,
  9:  0.11,
  12: 0.14,
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
  return Math.round(groupPrice / 0.90);
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
