/** Markup de plataforma: 20% sobre precio neto del grupo. */
export const COMMISSION_RATE = 0.20;

/** Multiplicador precio neto → precio cliente. clienteTotal = grupoNeto × COMMISSION_DIVISOR */
export const COMMISSION_DIVISOR = 1.20;

/** Descuento fijo en MXN para pagos SPEI (absorbido por Daricefy). */
export const SPEI_DISCOUNT_MXN = 100;

/** Tasas de cargo financiero MSI por número de meses (sobre el precio contado). */
export const MSI_FEE_RATES: Record<number, number> = {
  1:  0,
  3:  0.05,
  6:  0.06,
  9:  0.09,
  12: 0.12,
};
