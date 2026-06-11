/**
 * cityUtils — helpers de ciudad compartidos en toda la app.
 *
 * normalizeCity : elimina acentos, pone en minúsculas y elimina espacios
 *                 para comparaciones seguras en RPC / filtros de Supabase.
 * getSafeCity   : combina profile.city, detectedCity y fallback en un valor
 *                 siempre definido y normalizado.
 */

export function normalizeCity(city: string | null | undefined): string {
  if (!city) return 'guadalajara';
  return city
    .toLowerCase()
    .trim()
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '');
}

export function getSafeCity(
  profileCity: string | null | undefined,
  detectedCity: string | null | undefined,
): string | null {
  const city = profileCity ?? detectedCity ?? null;
  if (!city) return null;
  return normalizeCity(city);
}
