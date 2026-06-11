const MX_STATES = new Set([
  'Aguascalientes', 'Baja California', 'Baja California Sur', 'Campeche',
  'Chiapas', 'Chihuahua', 'Ciudad de México', 'CDMX', 'Coahuila', 'Colima',
  'Durango', 'Guanajuato', 'Guerrero', 'Hidalgo', 'Jalisco',
  'Estado de México', 'México', 'Michoacán', 'Morelos', 'Nayarit',
  'Nuevo León', 'Oaxaca', 'Puebla', 'Querétaro', 'Quintana Roo',
  'San Luis Potosí', 'Sinaloa', 'Sonora', 'Tabasco', 'Tamaulipas',
  'Tlaxcala', 'Veracruz', 'Yucatán', 'Zacatecas',
]);

const US_STATES = new Set([
  'Alabama', 'Alaska', 'Arizona', 'Arkansas', 'California', 'Colorado',
  'Connecticut', 'Delaware', 'Florida', 'Georgia', 'Hawaii', 'Idaho',
  'Illinois', 'Indiana', 'Iowa', 'Kansas', 'Kentucky', 'Louisiana',
  'Maine', 'Maryland', 'Massachusetts', 'Michigan', 'Minnesota', 'Mississippi',
  'Missouri', 'Montana', 'Nebraska', 'Nevada', 'New Hampshire', 'New Jersey',
  'New Mexico', 'New York', 'North Carolina', 'North Dakota', 'Ohio',
  'Oklahoma', 'Oregon', 'Pennsylvania', 'Rhode Island', 'South Carolina',
  'South Dakota', 'Tennessee', 'Texas', 'Utah', 'Vermont', 'Virginia',
  'Washington', 'West Virginia', 'Wisconsin', 'Wyoming', 'District of Columbia',
]);

// Lowercase sets for O(1) case-insensitive lookup
const MX_LOWER = new Set([...MX_STATES].map(s => s.toLowerCase()));
const US_LOWER = new Set([...US_STATES].map(s => s.toLowerCase()));

export function stateToCountry(state: string | null | undefined): string {
  if (!state) return 'México';
  const lower = state.trim().toLowerCase();
  if (MX_LOWER.has(lower)) return 'México';
  if (US_LOWER.has(lower)) return 'Estados Unidos';
  return 'México';
}

// Convierte el código ISO de 2 letras devuelto por expo-location
// (place.isoCountryCode) en un nombre legible para guardar en profiles.country.
export function isoToCountryName(code: string | null | undefined): string {
  if (!code) return 'México';
  const map: Record<string, string> = {
    MX: 'México',           US: 'Estados Unidos',  ES: 'España',
    CO: 'Colombia',         AR: 'Argentina',        CL: 'Chile',
    PE: 'Perú',             VE: 'Venezuela',        EC: 'Ecuador',
    GT: 'Guatemala',        HN: 'Honduras',         SV: 'El Salvador',
    CR: 'Costa Rica',       PA: 'Panamá',           DO: 'República Dominicana',
    CU: 'Cuba',             PR: 'Puerto Rico',      BO: 'Bolivia',
    PY: 'Paraguay',         UY: 'Uruguay',          CA: 'Canadá',
    GB: 'Reino Unido',      DE: 'Alemania',         FR: 'Francia',
    IT: 'Italia',           BR: 'Brasil',           NI: 'Nicaragua',
    JM: 'Jamaica',          TT: 'Trinidad y Tobago',
  };
  return map[code.toUpperCase()] ?? code;
}
