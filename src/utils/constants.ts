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

/**
 * Radio (m) para verificar llegada del grupo por GPS en el cliente.
 * El servidor valida a 250 m (release_half_on_arrival, sql/424) — el
 * margen de 50 m evita rechazos por deriva GPS urbana.
 */
export const ARRIVAL_RADIUS_M = 200;
