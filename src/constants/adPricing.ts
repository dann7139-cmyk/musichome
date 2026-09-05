// Precios de publicidad — fuente única de verdad en el frontend, espejo
// exacto de calculate_ad_price() en la BD (sql/612). Antes de sql/612
// el mismo precio vivía duplicado a mano en 4 lugares del frontend
// (BANNER_HOME_PRICES en AdvertisingPackagesScreen.tsx, BANNER_TIER_PRICES
// y BASE_PER_DAY en CreateAdvertisementScreen.tsx) — ahora solo este
// archivo. Si cambias un número aquí, cámbialo también en
// calculate_ad_price() en la BD (sql/NNN nuevo), o el precio que se
// muestra dejará de coincidir con el que de verdad se cobra.
//
// Petición real del usuario (2026-09-05): precios más bajos (apenas
// empieza), Recomendado más caro que Destacado a propósito, video +35%
// solo en Banner Home y Anuncio de Perfil, misma escala de duración
// (3/7/15 días) en los 4 tipos para que se vea parecido entre pantallas.
//
// El multiplicador de demanda/ciudad que existía antes (podía llegar a
// ×2 el precio) se QUITÓ por decisión explícita del usuario — precio
// fijo y predecible siempre, sin sorpresas.

export type AdType = 'banner_home' | 'sponsored_group' | 'profile_ad';
export type LocationType = 'city' | 'multi_city' | 'national' | 'international';

// Precio base (imagen, alcance "mi ciudad") en los 3 puntos de referencia.
export const AD_BASE_PRICES: Record<AdType, { d3: number; d7: number; d15: number }> = {
  profile_ad:      { d3: 129, d7: 249, d15: 449 },
  sponsored_group: { d3: 169, d7: 299, d15: 549 },
  banner_home:     { d3: 229, d7: 399, d15: 749 },
};

export const VIDEO_MULTIPLIER = 1.35; // solo banner_home y profile_ad
export const VIDEO_AD_TYPES: AdType[] = ['banner_home', 'profile_ad'];

export const LOCATION_MULT: Record<LocationType, number> = {
  city:          1.0,
  multi_city:    1.5,
  national:      2.0,
  international: 3.5,
};

// Precio de Recomendado — vive aparte (no es un AdType/ad_packages, es su
// propia tabla recommendation_orders), mismo criterio de 3/7/15 días.
export const RECOMENDADO_PRICES = { d3: 199, d7: 349, d15: 649 };

/** Precio base (imagen, sin alcance) para `days` — espejo de la parte de
 * calculate_ad_price() antes de aplicar el multiplicador de alcance. */
export function calcAdBaseImagePrice(type: AdType, days: number): number {
  const p = AD_BASE_PRICES[type];
  const d = Math.max(1, days || 7);
  if (d <= 3)  return d * (p.d3 / 3);
  if (d <= 7)  return d * (p.d7 / 7);
  return d * (p.d15 / 15);
}

/** Precio final (imagen o video + alcance) para `days` — mismo cálculo
 * que calculate_ad_price() en la BD, sin el multiplicador de demanda
 * (ya no existe). */
export function calcAdPrice(type: AdType, days: number, locationType: LocationType, isVideo = false): number {
  const base = calcAdBaseImagePrice(type, days);
  const videoMult = isVideo && VIDEO_AD_TYPES.includes(type) ? VIDEO_MULTIPLIER : 1.0;
  return Math.round(base * LOCATION_MULT[locationType] * videoMult * 100) / 100;
}

/** Precio de Recomendado (no lleva alcance ni video). */
export function calcRecomendadoPrice(days: number): number {
  const d = Math.max(1, days || 7);
  if (d <= 3) return d * (RECOMENDADO_PRICES.d3 / 3);
  if (d <= 7) return d * (RECOMENDADO_PRICES.d7 / 7);
  return d * (RECOMENDADO_PRICES.d15 / 15);
}
