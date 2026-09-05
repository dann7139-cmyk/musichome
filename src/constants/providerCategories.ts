// Categorías reales de proveedor — fuente única de verdad.
//
// Petición real (2026-09-03): "quiero que las categorías sean las mismas
// en Explorador como aparecen cuando el cliente le pone en agregar otro
// proveedor... en el Explorador no dicen diferentes." Antes el Explorador
// (HomeScreen) sacaba sus chips de la tabla `categories` en vivo (raíces
// desordenadas/duplicadas: "Música en vivo", "Sonido / Iluminación" +
// "Iluminación y Audio" como dos raíces distintas para lo mismo, "Comida"
// que ni existe como fila) — mientras que "Agregar otro proveedor"
// (EventCategoryPickerScreen) ya usaba esta lista curada y consistente.
// Ahora AMBAS pantallas importan de aquí — una sola fuente, imposible que
// se desincronicen otra vez.
//
// Los `genres` de cada categoría son los valores EXACTOS de `groups.genre`
// sembrados en producción (confirmados por consulta directa) — deben
// coincidir literalmente, si cambian aquí hay que revisar group_default_
// break_type() en la BD (sql/603/604) también.
export const GRUPO_MUSICAL_GENRES = [
  'Bachata', 'Balada', 'Banda', 'Blues', 'Bolero', 'Corridos', 'Corridos Tumbados',
  'Country', 'Cuartetos', 'Cumbia', 'Danzón', 'Electrónica', 'Folklore', 'Gospel',
  'Grupero', 'Grupos musicales', 'Hip Hop', 'Huapango', 'Jazz', 'Mariachi', 'Marimba',
  'Merengue', 'Norteño', 'Pop', 'R&B', 'Ranchero', 'Reggaeton', 'Rock', 'Salsa',
  'Sextetos', 'Son Jarocho', 'Tango', 'Tríos', 'Tropical', 'Trova', 'Vallenato', 'Versátil',
];
export const LUZ_SONIDO_GENRES = [
  'Sonido / Iluminación', 'Sonido', 'Iluminación',
  'Cabinas DJ', 'Iluminación profesional', 'Micrófonos', 'Pantallas LED', 'Proyectores', 'Sonido profesional',
];
export const RENTA_GENRES = [
  'Escenarios', 'Generadores eléctricos', 'Inflables acuáticos', 'Plantas de luz',
  'Renta de brincolines', 'Renta de mesas', 'Renta de sillas', 'Renta de toldos', 'Tarimas',
];
// Fotógrafos (antes "Multimedia" en el Explorador, renombrado en sql/604):
// el fotógrafo como persona ("Fotografía", categoría separada anidada bajo
// "Servicios de evento") y los 3 hijos reales de "Fotógrafos" en la BD.
export const FOTOGRAFOS_GENRES = ['Fotografía', 'Drones', 'Cabina 360', 'Cabina fotográfica'];

export interface ProviderCategory {
  key: string;
  emoji: string;
  labelKey: string;
  genres: string[];
}

// 'comida' apunta a una categoría que TODAVÍA NO EXISTE como fila en
// `categories` (sql/587, no aplicado) — la tarjeta/chip navega y filtra
// igual (es real, no decorativa), pero hoy mostraría 0 resultados hasta
// que esa fila se cree. Reportado explícitamente, no oculto.
export const PROVIDER_CATEGORIES: ProviderCategory[] = [
  { key: 'grupo',      emoji: '🎵', labelKey: 'eventCategoryPicker.grupo',      genres: GRUPO_MUSICAL_GENRES },
  { key: 'solista',    emoji: '🎷', labelKey: 'eventCategoryPicker.solista',    genres: ['Solistas'] },
  { key: 'dj',         emoji: '🎧', labelKey: 'eventCategoryPicker.dj',         genres: ['DJ'] },
  { key: 'comediante', emoji: '🎤', labelKey: 'eventCategoryPicker.comediante', genres: ['Comediante'] },
  { key: 'payasos',    emoji: '🤡', labelKey: 'eventCategoryPicker.payasos',    genres: ['Payasos'] },
  { key: 'luzSonido',  emoji: '🔊', labelKey: 'eventCategoryPicker.luzSonido',  genres: LUZ_SONIDO_GENRES },
  { key: 'comida',     emoji: '🍔', labelKey: 'eventCategoryPicker.comida',     genres: ['Comida'] },
  { key: 'renta',      emoji: '🪑', labelKey: 'eventCategoryPicker.renta',      genres: RENTA_GENRES },
  { key: 'fotografos', emoji: '📸', labelKey: 'eventCategoryPicker.fotografos', genres: FOTOGRAFOS_GENRES },
];

// Mismo criterio ya usado en HomeScreen para "músicos primero" / deck de
// Destacados en "Todos" — categorías SIN temporizador de tandas (sql/603+604).
export const NON_MUSICIAN_GENRES = new Set<string>([
  'Comediante', 'Payasos', 'Comida',
  'Renta de brincolines', 'Inflables acuáticos', 'Renta de mesas', 'Renta de sillas',
  'Fotografía', 'Drones', 'Cabina 360', 'Cabina fotográfica',
]);

// Espejo en JS de group_category_key() (sql/610) — misma tabla de géneros,
// para que el admin pueda filtrar por categoría al regalar Destacado/
// Recomendado (esas plazas ya son 5 por categoría por estado en la BD,
// este filtro solo ayuda a ELEGIR el grupo correcto, la BD decide el cupo).
export function categoryKeyForGenre(genre: string | null | undefined): string | null {
  if (!genre) return null;
  const found = PROVIDER_CATEGORIES.find(cat => cat.genres.includes(genre));
  return found ? found.key : null;
}
