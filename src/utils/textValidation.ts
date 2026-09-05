// src/utils/textValidation.ts

/**
 * Validación de texto público para prevenir bypass de plataforma.
 * Bloquea teléfonos, emails, URLs, redes sociales y palabras de contacto.
 */

export const PHONE_REGEX = /(\+?\d{1,3}[\s-]?)?\(?\d{3}\)?[\s-]?\d{3}[\s-]?\d{4}|\d{7,}/;
export const EMAIL_REGEX = /[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}/;
export const URL_REGEX = /(https?:\/\/|www\.)[^\s]+|[a-zA-Z0-9-]+\.(com|mx|net|org|io|co|app|tv|biz)/i;
// Incluye variantes/abreviaciones cortas ("insta", "face") y erratas
// comunes ("isntagram", "instagran", "facebok") — con \b para que "face"
// no dispare dentro de palabras normales como "factura" o "faceta".
export const SOCIAL_REGEX = /@[a-zA-Z0-9_]+|(?:whatsapp|instagram|isntagram|instagran|facebook|facebok|\bface\b|\binsta\b|twitter|tiktok|youtube|snapchat|telegram|discord|messenger|wa\.me|fb\.com|ig\.com|tw\.com)/i;
export const CONTACT_KEYWORDS_REGEX = /(?:mi (?:tel[ée]fono|n[úu]mero|cel|celular|whats|wa))|(?:ll[áa]mame|escr[íi]beme|cont[áa]ctame)\s+(?:al|a)/i;

export interface ValidationResult {
  valid: boolean;
  error?: string;
}

export function validatePublicText(text: string | null | undefined): ValidationResult {
  if (!text || !text.trim()) return { valid: true };

  if (PHONE_REGEX.test(text)) {
    return {
      valid: false,
      error: 'No incluyas números telefónicos. Daricefy maneja toda la comunicación.',
    };
  }

  if (EMAIL_REGEX.test(text)) {
    return {
      valid: false,
      error: 'No incluyas correos electrónicos. Daricefy maneja toda la comunicación.',
    };
  }

  if (URL_REGEX.test(text)) {
    return {
      valid: false,
      error: 'No incluyas sitios web ni enlaces externos.',
    };
  }

  if (SOCIAL_REGEX.test(text)) {
    return {
      valid: false,
      error: 'No incluyas redes sociales. Daricefy maneja la comunicación.',
    };
  }

  if (CONTACT_KEYWORDS_REGEX.test(text)) {
    return {
      valid: false,
      error: 'No incluyas información de contacto directo.',
    };
  }

  return { valid: true };
}
