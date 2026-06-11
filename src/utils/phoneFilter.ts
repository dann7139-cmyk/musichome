/**
 * phoneFilter.ts
 * Blindaje multicapa para el chat: detecta teléfonos, emails y keywords
 * que puedan usarse para intercambiar datos de contacto fuera de la plataforma.
 */

export type ViolationType = 'phone' | 'email' | 'keyword';

export interface FilterResult {
  blocked: boolean;
  type?: ViolationType;
  pattern?: string;
}

// ── Teléfonos ─────────────────────────────────────────────────────────────────
// Eliminar separadores comunes antes de buscar dígitos consecutivos
const STRIP_SEPARATORS = /[\s\-\(\)\+\.]/g;

// 7+ dígitos seguidos (cubre números locales mexicanos y similares)
const DIGITS_REGEX = /\d{7,}/;

// ── Emails ───────────────────────────────────────────────────────────────────
const EMAIL_PATTERNS: Array<{ re: RegExp; label: string }> = [
  { re: /@[a-z0-9]/i,                               label: 'email @' },
  { re: /\.(com|net|org|mx|io|app|co|me)\b/i,       label: 'dominio web' },
];

// ── Keywords de redes sociales / contacto ────────────────────────────────────
const BLOCKED_KEYWORDS: Array<{ re: RegExp; label: string }> = [
  { re: /ll[aá]mam[ei]/i,                label: 'llámame' },
  { re: /wh?[a4]ts[a4]pp?/i,             label: 'WhatsApp' },
  { re: /wa\.me/i,                        label: 'wa.me' },
  { re: /telegr[a4]m/i,                  label: 'Telegram' },
  { re: /t\.me\//i,                       label: 't.me' },
  { re: /m[a4]nd[a4]\s*m[e3]ns[a4]je/i, label: 'mándame mensaje' },
  { re: /cont[a4]ct[a4]me/i,             label: 'contáctame' },
  { re: /s[i1]gu[e3]me\s+en/i,          label: 'sígueme en' },
  { re: /busca[nm]e\s+en/i,             label: 'búscame en' },
  { re: /inst[a4]gr[a4]m/i,             label: 'Instagram' },
  { re: /f[a4]c[e3]b[o0][o0]k/i,        label: 'Facebook' },
  { re: /tiktok/i,                        label: 'TikTok' },
  { re: /sn[a4]pch[a4]t/i,              label: 'Snapchat' },
  { re: /twitter|x\.com/i,               label: 'Twitter/X' },
  { re: /youtube\.com/i,                 label: 'YouTube' },
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
  // 1. Keywords (sobre texto original, sin strip)
  for (const kw of BLOCKED_KEYWORDS) {
    if (kw.re.test(text)) {
      return { blocked: true, type: 'keyword', pattern: kw.label };
    }
  }
  // 2. Patrones de email (sobre texto original)
  for (const ep of EMAIL_PATTERNS) {
    if (ep.re.test(text)) {
      return { blocked: true, type: 'email', pattern: ep.label };
    }
  }
  // 3. Dígitos consecutivos (tras quitar separadores)
  const stripped = text.replace(STRIP_SEPARATORS, '');
  if (DIGITS_REGEX.test(stripped)) {
    return { blocked: true, type: 'phone', pattern: '7+ dígitos' };
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
 * Mensaje de advertencia al usuario.
 */
export const PHONE_WARNING =
  'Por seguridad, no puedes compartir datos de contacto en el chat. '
  + 'Usa la app para coordinar los detalles del evento.';
