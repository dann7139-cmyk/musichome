/**
 * phoneFilter.ts
 * Blindaje multicapa para el chat: detecta teléfonos, emails y keywords
 * que puedan usarse para intercambiar datos de contacto fuera de la plataforma.
 *
 * Capas de detección:
 *   1. Keywords de redes/contacto
 *   2. Emails
 *   3. Dígitos consecutivos (quita separadores: espacios, guiones, paréntesis)
 *   4. Números escritos con palabras en español ("nueve uno dos tres...")
 *   5. Dígitos dispersos en ventana de 30 caracteres (bypass con espacios)
 */

export type ViolationType = 'phone' | 'email' | 'keyword';

export interface FilterResult {
  blocked: boolean;
  type?: ViolationType;
  pattern?: string;
}

// ── Capa 3: Separadores y dígitos consecutivos ────────────────────────────────
const STRIP_SEPARATORS = /[\s\-\(\)\+\.\,]/g;
const DIGITS_REGEX      = /\d{7,}/;

// ── Capa 5: Ventana de 30 chars — cuenta dígitos totales (bypass con espacios) ─
// "55 5123 4567" tiene 10 dígitos en 12 chars → bloqueado
const WINDOW_SIZE    = 30;
const WINDOW_MIN_DIGITS = 7;

function countDigitsInWindow(text: string): boolean {
  for (let i = 0; i <= text.length - WINDOW_SIZE; i++) {
    const window = text.slice(i, i + WINDOW_SIZE);
    const digits = (window.match(/\d/g) ?? []).length;
    if (digits >= WINDOW_MIN_DIGITS) return true;
  }
  // También revisar textos más cortos que la ventana
  if (text.length < WINDOW_SIZE) {
    const digits = (text.match(/\d/g) ?? []).length;
    if (digits >= WINDOW_MIN_DIGITS) return true;
  }
  return false;
}

// ── Capa 4: Números escritos en palabras (español) ────────────────────────────
// Si aparecen 7+ palabras numéricas seguidas (o separadas por espacios/y/coma)
// se interpreta como número de teléfono dictado: "nueve uno dos tres cuatro..."
const WORD_TOKEN_RE = /\b(cero|uno|una|dos|tres|cuatro|cinco|seis|siete|ocho|nueve|diez|once|doce|trece|catorce|quince|veinte|treinta|cuarenta|cincuenta|sesenta|setenta|ochenta|noventa)\b/gi;

function countWordDigits(text: string): number {
  const matches = text.match(WORD_TOKEN_RE);
  return matches ? matches.length : 0;
}

// ── Capa 1: Emails ────────────────────────────────────────────────────────────
const EMAIL_PATTERNS: Array<{ re: RegExp; label: string }> = [
  { re: /@[a-z0-9]/i,                               label: 'email @' },
  { re: /\.(com|net|org|mx|io|app|co|me)\b/i,       label: 'dominio web' },
];

// ── Capa 2: Keywords de redes sociales / contacto ─────────────────────────────
const BLOCKED_KEYWORDS: Array<{ re: RegExp; label: string }> = [
  { re: /ll[aá]mam[ei]/i,                label: 'llámame' },
  { re: /wh?[a4]ts[a4]pp?/i,             label: 'WhatsApp' },
  { re: /wa\.me/i,                        label: 'wa.me' },
  { re: /telegr[a4]m/i,                  label: 'Telegram' },
  { re: /t\.me\//i,                       label: 't.me' },
  { re: /m[a4]nd[a4]\s*m[e3]ns[a4]je/i, label: 'mándame mensaje' },
  { re: /cont[a4]ct[a4]me/i,             label: 'contáctame' },
  { re: /s[i1]gu[e3]me\s+en/i,           label: 'sígueme en' },
  { re: /busca[nm]e\s+en/i,              label: 'búscame en' },
  { re: /inst[a4]gr[a4]m/i,              label: 'Instagram' },
  { re: /f[a4]c[e3]b[o0][o0]k/i,        label: 'Facebook' },
  { re: /tiktok/i,                        label: 'TikTok' },
  { re: /sn[a4]pch[a4]t/i,              label: 'Snapchat' },
  { re: /twitter|x\.com/i,               label: 'Twitter/X' },
  { re: /youtube\.com/i,                  label: 'YouTube' },
  { re: /m[i1]s\s+r[e3]d[e3]s/i,        label: 'mis redes' },
  { re: /ig\s*[:=@]/i,                   label: 'ig:' },
  { re: /fb\s*[:=@]/i,                   label: 'fb:' },
  { re: /\btt\s*[:=@]/i,                 label: 'tt:' },
  { re: /\bsnap\s*[:=@]/i,              label: 'snap:' },
];

/**
 * Analiza un mensaje y devuelve si debe bloquearse, el tipo de violación
 * y el patrón detectado.
 */
export function analyzeMessage(text: string): FilterResult {
  if (!text) return { blocked: false };

  // Capa 1 — Keywords de contacto/redes
  for (const kw of BLOCKED_KEYWORDS) {
    if (kw.re.test(text)) {
      return { blocked: true, type: 'keyword', pattern: kw.label };
    }
  }

  // Capa 2 — Emails
  for (const ep of EMAIL_PATTERNS) {
    if (ep.re.test(text)) {
      return { blocked: true, type: 'email', pattern: ep.label };
    }
  }

  // Capa 3 — Dígitos consecutivos (quita separadores)
  const stripped = text.replace(STRIP_SEPARATORS, '');
  if (DIGITS_REGEX.test(stripped)) {
    return { blocked: true, type: 'phone', pattern: '7+ dígitos consecutivos' };
  }

  // Capa 4 — Números en palabras ("nueve uno dos tres cuatro cinco cinco")
  // 7+ palabras numéricas en el mensaje → número de teléfono escrito
  if (countWordDigits(text) >= 7) {
    return { blocked: true, type: 'phone', pattern: 'número escrito en palabras' };
  }

  // Capa 5 — Dígitos dispersos en ventana de 30 caracteres
  // Captura bypasses como "55 5123 4567" o "5 5 5 1 2 3 4"
  if (countDigitsInWindow(text)) {
    return { blocked: true, type: 'phone', pattern: '7+ dígitos en ventana de 30 chars' };
  }

  return { blocked: false };
}

/**
 * Compatibilidad hacia atrás con llamadas existentes.
 */
export function containsPhoneNumber(text: string): boolean {
  return analyzeMessage(text).blocked;
}

/**
 * Alias usado en algunas pantallas.
 */
export function containsBlockedContact(text: string): boolean {
  return analyzeMessage(text).blocked;
}

/**
 * Mensaje de advertencia al usuario.
 */
export const PHONE_WARNING =
  'Por seguridad, no puedes compartir datos de contacto en el chat. '
  + 'Usa la app para coordinar los detalles del evento.';
