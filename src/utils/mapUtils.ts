// Geographic utilities shared between ExpressCard and ProposalCard.
// ExpressCard keeps its own internal copy; this file is used by ProposalCard.

export const CITY_COORDS: Record<string, { lat: number; lng: number }> = {
  // CDMX
  'ciudad de mexico': { lat: 19.4326, lng: -99.1332 },
  'cdmx':            { lat: 19.4326, lng: -99.1332 },
  'iztapalapa':      { lat: 19.3579, lng: -99.0591 },
  'ecatepec':        { lat: 19.6012, lng: -99.0329 },
  'naucalpan':       { lat: 19.4794, lng: -99.2389 },
  'tlalnepantla':    { lat: 19.5432, lng: -99.1965 },
  'nezahualcoyotl':  { lat: 19.4022, lng: -99.0153 },
  'coyoacan':        { lat: 19.3467, lng: -99.1619 },
  // GDL metro
  'guadalajara':     { lat: 20.6597, lng: -103.3496 },
  'zapopan':         { lat: 20.7214, lng: -103.3865 },
  'tlaquepaque':     { lat: 20.6305, lng: -103.2971 },
  'san pedro tlaquepaque': { lat: 20.6305, lng: -103.2971 },
  'tonala':          { lat: 20.6228, lng: -103.2292 },
  'tlajomulco':      { lat: 20.4890, lng: -103.4321 },
  'tlajomulco de zuniga': { lat: 20.4890, lng: -103.4321 },
  'el salto':        { lat: 20.5356, lng: -103.2096 },
  'puerto vallarta': { lat: 20.6534, lng: -105.2253 },
  // Norte
  'monterrey':       { lat: 25.6866, lng: -100.3161 },
  'saltillo':        { lat: 25.4232, lng: -100.9963 },
  'torreon':         { lat: 25.5428, lng: -103.4068 },
  'chihuahua':       { lat: 28.6330, lng: -106.0691 },
  'ciudad juarez':   { lat: 31.6904, lng: -106.4245 },
  'tijuana':         { lat: 32.5149, lng: -117.0382 },
  'mexicali':        { lat: 32.6245, lng: -115.4523 },
  'hermosillo':      { lat: 29.0729, lng: -110.9559 },
  'culiacan':        { lat: 24.8090, lng: -107.3940 },
  'mazatlan':        { lat: 23.2494, lng: -106.4111 },
  'los mochis':      { lat: 25.7903, lng: -108.9865 },
  'reynosa':         { lat: 26.0924, lng: -98.2777 },
  'matamoros':       { lat: 25.8694, lng: -97.5025 },
  'victoria':        { lat: 23.7369, lng: -99.1411 },
  'durango':         { lat: 24.0277, lng: -104.6532 },
  'la paz':          { lat: 24.1426, lng: -110.3128 },
  // Centro
  'puebla':          { lat: 19.0414, lng: -98.2063 },
  'toluca':          { lat: 19.2826, lng: -99.6557 },
  'queretaro':       { lat: 20.5888, lng: -100.3899 },
  'san luis potosi': { lat: 22.1565, lng: -100.9855 },
  'aguascalientes':  { lat: 21.8818, lng: -102.2916 },
  'leon':            { lat: 21.1236, lng: -101.6858 },
  'celaya':          { lat: 20.5234, lng: -100.8155 },
  'irapuato':        { lat: 20.6766, lng: -101.3552 },
  'morelia':         { lat: 19.7060, lng: -101.1950 },
  'colima':          { lat: 19.2452, lng: -103.7241 },
  'tepic':           { lat: 21.5040, lng: -104.8955 },
  'zacatecas':       { lat: 22.7709, lng: -102.5832 },
  'pachuca':         { lat: 20.1011, lng: -98.7591 },
  'cuernavaca':      { lat: 18.9261, lng: -99.2306 },
  // Sur / Sureste
  'acapulco':        { lat: 16.8531, lng: -99.8237 },
  'veracruz':        { lat: 19.1739, lng: -96.1342 },
  'xalapa':          { lat: 19.5438, lng: -96.9102 },
  'merida':          { lat: 20.9674, lng: -89.5926 },
  'cancun':          { lat: 21.1619, lng: -86.8515 },
  'playa del carmen': { lat: 20.6296, lng: -87.0739 },
  'villahermosa':    { lat: 17.9892, lng: -92.9473 },
  'tuxtla gutierrez': { lat: 16.7521, lng: -93.1153 },
  'oaxaca':          { lat: 17.0732, lng: -96.7266 },
  'chetumal':        { lat: 18.5001, lng: -88.2963 },
  'tapachula':       { lat: 14.9060, lng: -92.2634 },
  'campeche':        { lat: 19.8301, lng: -90.5349 },
  // Fallbacks por estado
  'jalisco':         { lat: 20.6597, lng: -103.3496 },
  'nuevo leon':      { lat: 25.6866, lng: -100.3161 },
  'estado de mexico': { lat: 19.2826, lng: -99.6557 },
  'baja california': { lat: 32.5149, lng: -117.0382 },
  'sonora':          { lat: 29.0729, lng: -110.9559 },
  'sinaloa':         { lat: 24.8090, lng: -107.3940 },
  'tamaulipas':      { lat: 25.8694, lng: -97.5025 },
  'guerrero':        { lat: 16.8531, lng: -99.8237 },
  'chiapas':         { lat: 16.7521, lng: -93.1153 },
  'yucatan':         { lat: 20.9674, lng: -89.5926 },
  'quintana roo':    { lat: 21.1619, lng: -86.8515 },
  'tabasco':         { lat: 17.9892, lng: -92.9473 },
  'default':         { lat: 19.4326, lng: -99.1332 },
};

export function normalizeCity(s: string): string {
  return s.toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '');
}

export function resolveCoords(city: string, estado?: string | null): { lat: number; lng: number } {
  const c = normalizeCity(city);
  if (CITY_COORDS[c]) return CITY_COORDS[c];
  if (estado) {
    const e = normalizeCity(estado);
    if (CITY_COORDS[e]) return CITY_COORDS[e];
  }
  return CITY_COORDS['default'];
}

export function idHash(id: string): number {
  let h = 0;
  for (let i = 0; i < id.length; i++) h = (h * 31 + id.charCodeAt(i)) & 0x7fffffff;
  return h;
}

export function privacyOffset(
  id: string,
  city: string,
  estado?: string | null,
  lat?: number | null,
  lng?: number | null,
): { latitude: number; longitude: number } {
  const h    = idHash(id);
  const dlat = ((h % 800) - 400) / 50_000;
  const dlng = (((h * 31) % 800) - 400) / 50_000;
  if (lat != null && lng != null) return { latitude: lat + dlat, longitude: lng + dlng };
  const base = resolveCoords(city, estado);
  return { latitude: base.lat + dlat, longitude: base.lng + dlng };
}

export function haversineKm(lat1: number, lon1: number, lat2: number, lon2: number): number {
  const R = 6371;
  const dLat = (lat2 - lat1) * Math.PI / 180;
  const dLon = (lon2 - lon1) * Math.PI / 180;
  const a =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(lat1 * Math.PI / 180) * Math.cos(lat2 * Math.PI / 180) *
    Math.sin(dLon / 2) ** 2;
  return R * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

export function formatDist(km: number): string {
  if (km < 1) return `${Math.round(km * 1000)} m`;
  if (km < 10) return `${km.toFixed(1)} km`;
  return `${Math.round(km)} km`;
}

export function mapRegionForPoints(
  p1: { latitude: number; longitude: number },
  p2: { latitude: number; longitude: number },
) {
  const spanLat = Math.abs(p1.latitude  - p2.latitude);
  const spanLng = Math.abs(p1.longitude - p2.longitude);
  const span    = Math.max(spanLat, spanLng);
  const pad     = Math.max(span * 0.35, 0.04);
  const minLat  = Math.min(p1.latitude,  p2.latitude)  - pad;
  const maxLat  = Math.max(p1.latitude,  p2.latitude)  + pad;
  const minLng  = Math.min(p1.longitude, p2.longitude) - pad;
  const maxLng  = Math.max(p1.longitude, p2.longitude) + pad;
  return {
    latitude:       (minLat + maxLat) / 2,
    longitude:      (minLng + maxLng) / 2,
    latitudeDelta:  maxLat - minLat,
    longitudeDelta: maxLng - minLng,
  };
}

export function cameraForPoints(
  p1: { latitude: number; longitude: number },
  p2: { latitude: number; longitude: number },
) {
  const region   = mapRegionForPoints(p1, p2);
  const altitude = Math.max((region.latitudeDelta / 0.072) * 6500 * 1.8, 5000);
  return {
    center:   { latitude: region.latitude, longitude: region.longitude },
    pitch:    0,
    heading:  0,
    altitude,
  };
}
