// ============================================================
// utils/clabe.ts — Validación de CLABE interbancaria (estándar Banxico)
// y detección de banco por los primeros 3 dígitos.
//
// La CLABE tiene 18 dígitos: 3 banco + 3 plaza + 11 cuenta + 1 dígito
// de control. El dígito de control se calcula con pesos 3,7,1 cíclicos
// sobre los primeros 17 dígitos, módulo 10.
// ============================================================

// Códigos ABM más comunes en México (los primeros 3 dígitos de la CLABE)
const BANK_CODES: Record<string, string> = {
  '002': 'Citibanamex',
  '012': 'BBVA',
  '014': 'Santander',
  '019': 'Banjercito',
  '021': 'HSBC',
  '030': 'BanBajío',
  '036': 'Inbursa',
  '042': 'Mifel',
  '044': 'Scotiabank',
  '058': 'Banregio',
  '059': 'Invex',
  '060': 'Bansí',
  '062': 'Afirme',
  '072': 'Banorte',
  '106': 'Bank of America México',
  '127': 'Banco Azteca',
  '128': 'Autofin',
  '129': 'Barclays México',
  '130': 'Compartamos',
  '137': 'BanCoppel',
  '140': 'Consubanco',
  '143': 'CIBanco',
  '145': 'BBase',
  '166': 'Banco del Bienestar',
  '168': 'Hipotecaria Federal',
  '638': 'Nu México',
  '646': 'STP',
  '652': 'Caja Popular Mexicana',
  '659': 'Fondo (FIRA)',
  '661': 'Klar (Alternativos)',
  '670': 'Libertad',
  '684': 'Transfer (Operadora de pagos)',
  '685': 'Fondeadora (Cuenca)',
  '686': 'Cuenca',
  '703': 'Tesored',
  '706': 'Arcus',
  '710': 'NVIO (Bitso)',
  '722': 'Mercado Pago',
  '723': 'Cuenca (Cacao)',
  '728': 'Spin by OXXO',
  '846': 'STP (nómina)',
};

/** Solo dígitos, recorta espacios/guiones que la gente pega de su banca. */
export function normalizeClabe(input: string): string {
  return (input ?? '').replace(/\D/g, '');
}

/** Valida longitud (18) y dígito de control (pesos 3,7,1 — Banxico). */
export function validateClabe(input: string): { valid: boolean; error?: string } {
  const clabe = normalizeClabe(input);
  if (clabe.length !== 18) {
    return { valid: false, error: `La CLABE debe tener 18 dígitos (llevas ${clabe.length}).` };
  }
  const weights = [3, 7, 1];
  let sum = 0;
  for (let i = 0; i < 17; i++) {
    sum += (Number(clabe[i]) * weights[i % 3]) % 10;
  }
  const control = (10 - (sum % 10)) % 10;
  if (control !== Number(clabe[17])) {
    return { valid: false, error: 'La CLABE no es válida (dígito de control incorrecto). Revísala en tu banca.' };
  }
  return { valid: true };
}

/** Banco por los primeros 3 dígitos, o null si no está en el catálogo. */
export function bankFromClabe(input: string): string | null {
  const clabe = normalizeClabe(input);
  if (clabe.length < 3) return null;
  return BANK_CODES[clabe.slice(0, 3)] ?? null;
}

/** Últimos 4 dígitos para confirmación visual. */
export function clabeLast4(input: string): string {
  return normalizeClabe(input).slice(-4);
}
