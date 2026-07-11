// ============================================================
// utils/countryFormat.ts — Helpers binacionales 🇲🇽/🇺🇸 del panel admin.
// El país/moneda vienen calculados del servidor (country_code_of, sql/470);
// aquí solo se FORMATEA. Agregar un país nuevo = agregar su bandera aquí.
// ============================================================

export function flagFor(code?: string | null): string {
  switch ((code ?? 'MX').toUpperCase()) {
    case 'US': return '🇺🇸';
    case 'MX': return '🇲🇽';
    default:   return '🌎';
  }
}

/** "Zapopan, Jalisco" · "Austin, Texas" · fallback al país */
export function placeLine(x: { city?: string | null; state?: string | null; country?: string | null }): string {
  const parts = [x.city, x.state].filter(Boolean);
  return parts.length > 0 ? parts.join(', ') : (x.country ?? 'México');
}

/** Etiqueta del método de pago esperado para el admin */
export function methodLabel(expected?: string | null): string {
  return expected === 'stripe_ach' ? 'Stripe/ACH' : 'SPEI (CLABE)';
}
