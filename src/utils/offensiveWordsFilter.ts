// src/utils/offensiveWordsFilter.ts
//
// Filtro básico de palabras ofensivas para comentarios públicos (fotos
// de eventos, sql/559). Mismo criterio que validatePublicText.ts: se
// revisa del lado del cliente antes de enviar — es una lista de
// palabras, no moderación por IA, bloquea las peores pero no es
// perfecto al 100%.

import { validatePublicText } from './textValidation';

const OFFENSIVE_WORDS = [
  'pendejo', 'pendeja', 'pendejada',
  'puto', 'puta', 'putos', 'putas',
  'mierda', 'chingada', 'chingadas', 'chingado', 'chingar',
  'verga', 'vergas',
  'cabron', 'cabrón', 'cabrona',
  'idiota', 'imbecil', 'imbécil', 'estupido', 'estúpido', 'estupida', 'estúpida',
  'maldito', 'maldita',
  'culero', 'culera',
  'joto', 'jota',
  'perra', 'perro asqueroso',
  'fuck', 'shit', 'bitch', 'asshole',
];

export function containsOffensiveWords(text: string): boolean {
  if (!text) return false;
  const normalized = text
    .toLowerCase()
    .normalize('NFD')
    .replace(/[̀-ͯ]/g, ''); // quita acentos para comparar parejo

  return OFFENSIVE_WORDS.some(word => {
    const w = word.normalize('NFD').replace(/[̀-ͯ]/g, '');
    return normalized.includes(w);
  });
}

export function validateComment(text: string): { valid: boolean; error?: string } {
  if (!text || !text.trim()) {
    return { valid: false, error: 'Escribe un comentario.' };
  }
  if (containsOffensiveWords(text)) {
    return { valid: false, error: 'Tu comentario incluye lenguaje ofensivo. Cámbialo antes de publicar.' };
  }
  // Sin teléfonos, correos, links ni redes sociales — mismo filtro que
  // ya usa el resto de la app (textValidation.ts).
  const contact = validatePublicText(text);
  if (!contact.valid) return contact;
  return { valid: true };
}
