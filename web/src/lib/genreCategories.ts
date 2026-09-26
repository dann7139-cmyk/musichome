// Mismas categorías/listas que src/constants/providerCategories.ts de la
// app móvil (fuente real) — duplicado aquí porque son 2 proyectos
// separados (Next.js / Expo) sin import compartido. Si se agrega un
// género nuevo allá, hay que copiarlo aquí también.

// 2026-09-17 — México/Latinoamérica primero, Estados Unidos después
// (mismo orden que src/constants/providerCategories.ts de la app).
// "Corridos Tumbados" quitado (mismo día) — para el usuario es el mismo
// género que Sierreño; 0 grupos reales lo tenían registrado.
// 2026-09-17 (segunda pasada) — "Grupos musicales" (duplicaba el nombre
// de la categoría), "Corridos", "Ranchero", "Grupero" y "Huapango"
// quitados por genéricos (petición real: "cualquier grupo puede tocar
// corridos/huapango", "el regional mexicano ya es ranchero"). Se agregan
// "Conjunto" y "Norteño-Banda". 0 grupos reales con los 5 géneros
// quitados — confirmado en producción antes de quitarlos.
// 2026-09-19 — petición real: "quiero que aparezca primero los más
// reconocidos: norteño, sierreño, norteño banda, el grupo versátil, y ya
// los demás que casi no se conocen al último" — Norteño-Banda sube del
// bloque alfabético al popular. Banda/Mariachi/Rock se quedan justo
// después (siguen siendo muy reconocidos, no se pidió bajarlos).
const GRUPO_MUSICAL_GENRES_MX_POPULAR = ['Norteño', 'Sierreño', 'Norteño-Banda', 'Versátil', 'Banda', 'Mariachi', 'Rock'];
const GRUPO_MUSICAL_GENRES_MX_REST = [
  'Bachata', 'Balada', 'Blues', 'Bolero', 'Conjunto', 'Country',
  'Cuartetos', 'Cumbia', 'Danzón', 'Electrónica', 'Folklore', 'Gospel',
  'Hip Hop', 'Jazz', 'Marimba', 'Merengue',
  'Pop', 'R&B', 'Reggaeton', 'Salsa', 'Sextetos', 'Son Jarocho',
  'Tango', 'Tríos', 'Tropical', 'Trova', 'Vallenato',
];
const GRUPO_MUSICAL_GENRES_MX = [...GRUPO_MUSICAL_GENRES_MX_POPULAR, ...GRUPO_MUSICAL_GENRES_MX_REST];
const GRUPO_MUSICAL_GENRES_US = [
  'Americana', 'Appalachian', 'Bluegrass', 'Cajun', 'Classical', 'Dance', 'Disco', 'Folk',
  'Funk', 'Indie', 'Klezmer', 'Metal', 'Motown', 'Punk', 'Soul', 'Southern Rock', 'Swing', 'Zydeco',
];
export const GRUPO_MUSICAL_GENRES = [...GRUPO_MUSICAL_GENRES_MX, ...GRUPO_MUSICAL_GENRES_US];
// Reducido a un solo género "sombrilla" (2026-09-22) — mismo cambio que en
// la app móvil (src/constants/providerCategories.ts), 0 grupos reales con
// los 9 valores anteriores.
export const LUZ_SONIDO_GENRES = ['Sonido / Iluminación'];
export const RENTA_GENRES = [
  'Escenarios', 'Generadores eléctricos', 'Inflables acuáticos', 'Plantas de luz',
  'Renta de brincolines', 'Renta de mesas', 'Renta de sillas', 'Renta de toldos', 'Tarimas',
];
export const FOTOGRAFOS_GENRES = ['Fotografía', 'Drones', 'Cabina 360', 'Cabina fotográfica'];
// "Comida" (categoría) renombrada a "Amenidades y Snacks" (petición real
// 2026-09-20) — mismo arreglo que src/constants/providerCategories.ts (app).
export const COMIDA_GENRES = ['Comida', 'Barra de mixología', 'Snacks y botanas', 'Café y postres'];
// Terrazas y salones (2026-09-23) — espejo de TERRAZA_GENRES en la app.
// Un solo género sombrilla; en la BD es una fila de `groups` con
// genre='Terraza' (sql/681), no una tabla aparte.
export const TERRAZA_GENRES = ['Terraza'];

// `key` agregado 2026-09-17 — mismas keys que PROVIDER_CATEGORIES de la
// app (src/constants/providerCategories.ts), para poder manejar la
// categoría elegida como estado (antes solo existía `label`, con emoji,
// incómodo de usar como valor de filtro/estado).
export const CATEGORY_LABELS: { key: string; label: string; genres: string[] }[] = [
  { key: 'grupo',       label: '🎵 Grupo musical', genres: GRUPO_MUSICAL_GENRES },
  { key: 'solista',     label: '🎷 Solista', genres: ['Solistas'] },
  { key: 'dj',          label: '🎧 DJ', genres: ['DJ'] },
  { key: 'comediante',  label: '🎤 Comediante', genres: ['Comediante'] },
  { key: 'espectaculo', label: '🎪 Shows', genres: ['Espectáculo', 'Payasos', 'Mago', 'Personajes', 'Animación'] },
  { key: 'mc',          label: '🎙️ Maestro de Ceremonias', genres: ['Maestro de Ceremonias'] },
  { key: 'luzSonido',   label: '🔊 Luz y sonido', genres: LUZ_SONIDO_GENRES },
  { key: 'comida',      label: '🍔 Amenidades y Snacks', genres: COMIDA_GENRES },
  { key: 'renta',       label: '🪑 Renta', genres: RENTA_GENRES },
  { key: 'fotografos',  label: '📸 Fotografía', genres: FOTOGRAFOS_GENRES },
  // Al final igual que en la app — el orden de arriba lo pidió el usuario
  // explícitamente y la categoría nueva no se mete en medio.
  { key: 'terraza',     label: '🏡 Terrazas y Salones', genres: TERRAZA_GENRES },
];

// Un grupo puede tocar más de un estilo a la vez (petición real 2026-09-20:
// "un grupo puede poner dos generos, por decir norteño/sierreño") — se
// guarda en `groups.genre` separado por "/" (ej. "Norteño/Sierreño").
// Espejo exacto de splitGenres()/genreMatches() en
// src/constants/providerCategories.ts de la app.
export function splitGenres(genre: string | null | undefined): string[] {
  if (!genre) return [];
  return genre.split("/").map((g) => g.trim()).filter(Boolean);
}

export function genreMatches(groupGenre: string | null | undefined, target: string | null | undefined): boolean {
  if (!groupGenre || !target) return false;
  const t = target.trim().toLowerCase();
  return splitGenres(groupGenre).some((g) => g.toLowerCase() === t);
}

// true si ALGUNO de los estilos separados es de músico (deck "solo músicos"
// en "Todos"), espejo de isMusicianGenre() en providerCategories.ts (app).
export function isMusicianGenre(genre: string | null | undefined): boolean {
  return splitGenres(genre).some((g) => !NON_MUSICIAN_GENRES.has(g));
}

/** Categoría real a la que pertenece un género — "Otro" si no coincide con ninguna lista. */
export function categoryForGenre(genre: string | null | undefined): string {
  if (!genre) return "Sin género";
  for (const part of splitGenres(genre)) {
    const found = CATEGORY_LABELS.find((c) => c.genres.includes(part));
    if (found) return found.label;
  }
  return "Otro";
}

// Espejo de NON_MUSICIAN_GENRES en src/constants/providerCategories.ts (app) —
// mismo criterio para el deck de Recomendados/Destacados/Populares: en "Todos"
// (sin categoría elegida) esa fila muestra SOLO músicos, igual que la app.
export const NON_MUSICIAN_GENRES = new Set<string>([
  'Comediante', 'Maestro de Ceremonias',
  ...COMIDA_GENRES,
  'Renta de brincolines', 'Inflables acuáticos', 'Renta de mesas', 'Renta de sillas',
  'Fotografía', 'Drones', 'Cabina 360', 'Cabina fotográfica',
  ...TERRAZA_GENRES,
]);
