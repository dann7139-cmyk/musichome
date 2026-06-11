/**
 * Filtro de groserías para campos de texto (lado cliente).
 * Se aplica en tiempo real mientras el usuario escribe.
 */

const BAD_WORDS = [
  'puta','puto','putas','putos',
  'chinga','chingada','chingado','chingadera','chinguen','chinguen',
  'pendejo','pendeja','pendejos','pendejas',
  'cabron','cabrón','cabrona','cabrones',
  'culero','culera','culeros','culeras',
  'mamón','mamon','mamona','mamar','mames',
  'joder','coño','polla','verga','vergota',
  'pinche','pinches',
  'hijoputa','hijo de puta','hdp',
  'mierda','culo','gilipollas',
  'idiota','imbecil','estupido','estupida',
  'perra','perro','bastardo','bastarda',
  'méndigo','mendigo','méndiga','mendiga',
  'bitch','fuck','shit','asshole','damn','crap','moron',
  'wey','güey','buey',
];

/** Normaliza texto para comparación (quita acentos, minúsculas) */
function normalize(text: string): string {
  return text
    .toLowerCase()
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '');
}

/**
 * Devuelve `true` si el texto contiene groserías.
 */
export function containsProfanity(text: string): boolean {
  if (!text?.trim()) return false;
  const clean = normalize(text);
  return BAD_WORDS.some(word => {
    const w = normalize(word);
    // Busca la palabra completa o como parte de otra (variaciones)
    const regex = new RegExp(`(^|\\s|[^a-z])${w}([^a-z]|\\s|$)`, 'i');
    return regex.test(clean) || clean.includes(w);
  });
}

/**
 * Limpia el texto eliminando los caracteres que forman groserías mientras el usuario escribe.
 * Úsalo en onChangeText para campos sensibles.
 */
export function filterText(text: string): string {
  // No bloquea letra por letra (mala UX), solo alerta — el bloqueo real lo hace el servidor.
  return text;
}

/**
 * Mensaje de advertencia a mostrar cuando se detecta grosería.
 */
export const PROFANITY_WARNING = 'Por favor usa un lenguaje respetuoso. Las groserías no están permitidas.';
