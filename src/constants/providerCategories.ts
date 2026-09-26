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
// "Sierreño" agregado 2026-09-16 — faltaba en la lista real, así que un
// grupo genuinamente sierreño ("Los Mentados") no pudo elegirlo al
// registrarse y quedó guardado como "Ranchero" por default (hallazgo real
// del usuario, corregido también en su fila de producción). Mismo día se
// agregan géneros comunes de Estados Unidos (bluegrass, folk, funk, etc.)
// que tampoco existían — la lista era casi puramente mexicana.
// 2026-09-17 — petición real: "que salgan primero las de méxico". El
// arreglo estaba alfabetizado de corrido, mezclando México/Latinoamérica
// con Estados Unidos (Americana/Appalachian quedaban primero solo por la
// letra A). Ahora son dos bloques ordenados: México/Latinoamérica primero,
// Estados Unidos después.
// "Corridos Tumbados" quitado el mismo día — petición real: "sierreños es
// corridos tumbados, que diga sierreños" (para el usuario son el mismo
// género). Confirmado que ningún grupo real tenía ese género registrado
// (0 filas en producción), así que se puede quitar sin migrar datos —
// queda solo "Sierreño" como opción.
// 2026-09-17 (mismo día) — segunda pasada: "Grupos musicales" (duplicaba
// el nombre de la categoría misma), "Corridos", "Ranchero", "Grupero" y
// "Huapango" quitados — petición real: son demasiado genéricos, "cualquier
// grupo puede tocar corridos/huapango" y "el regional mexicano YA es
// ranchero", no distinguen el acto. Se agregan "Conjunto" y "Norteño-Banda"
// como los estilos reales que sí faltaban (Norteño, Norteño-Banda,
// Sierreño, Banda, Conjunto, Mariachi). Confirmado 0 grupos reales
// registrados con los 5 géneros quitados — se puede quitar sin migrar datos.
// 2026-09-17 (tercera pasada) — petición real: "primero que salgan esos
// porque son los que más buscan... los más que se escucha en GDL" — dentro
// de México, los más buscados van primero (no alfabético).
// 2026-09-19 — petición real: "quiero que aparezca primero los más
// reconocidos: norteño, sierreño, norteño banda, el grupo versátil, y ya
// los demás que casi no se conocen al último" — Norteño-Banda sube del
// bloque alfabético al bloque popular (antes solo estaba en el resto,
// mezclado con Bachata/Tango/etc.). Banda/Mariachi/Rock se quedan justo
// después — siguen siendo géneros muy reconocidos, el usuario no pidió
// bajarlos, solo subir a Norteño-Banda y priorizar Versátil.
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
// Reducido a un solo género "sombrilla" (2026-09-22, petición real: "no
// quiero que salgan las opciones de abajo... el cliente ya elige el
// proveedor que sea") — antes tenía 9 subtipos (Proyectores, Micrófonos,
// etc.) que obligaban a elegir uno para poder ver/pedir Luz y Sonido; ahora
// es UNA sola categoría, igual de simple que Solistas/DJ. Confirmado 0
// grupos reales registrados con cualquiera de esos 9 valores (no hay datos
// que migrar) — mismo criterio ya usado para limpiar géneros musicales sin
// uso real (ver comentario de cabecera de este archivo).
export const LUZ_SONIDO_GENRES = ['Sonido / Iluminación'];
export const RENTA_GENRES = [
  'Escenarios', 'Generadores eléctricos', 'Inflables acuáticos', 'Plantas de luz',
  'Renta de brincolines', 'Renta de mesas', 'Renta de sillas', 'Renta de toldos', 'Tarimas',
];
// Fotógrafos (antes "Multimedia" en el Explorador, renombrado en sql/604):
// el fotógrafo como persona ("Fotografía", categoría separada anidada bajo
// "Servicios de evento") y los 3 hijos reales de "Fotógrafos" en la BD.
export const FOTOGRAFOS_GENRES = ['Fotografía', 'Drones', 'Cabina 360', 'Cabina fotográfica'];
// "Comida" (categoría) renombrada a "Amenidades y Snacks" (petición real
// 2026-09-20) — antes solo tenía UNA opción ("Comida"); ahora son varias,
// así que al tocar la categoría sale el mismo selector de género que ya usan
// grupo/renta/luzSonido (EventCategoryPickerScreen ya soporta esto solo con
// que el arreglo tenga más de 1 elemento, sin tocar esa pantalla).
export const COMIDA_GENRES = ['Comida', 'Barra de mixología', 'Snacks y botanas', 'Café y postres'];
// Terrazas y salones para eventos (2026-09-23, petición real: "que pueda
// subir las terrazas como si fuera grupo igual un video"). Un solo género
// sombrilla, igual que 'Sonido / Iluminación' — el cliente ya elige la
// terraza que quiera, no hace falta partirla en subtipos (salón/jardín/
// terraza los distingue la foto y el video, no un filtro). En la BD es una
// fila de `groups` con genre='Terraza' (sql/681), no una tabla aparte: así
// hereda reservas, wallet, retiros, reseñas, Destacado y video sin duplicar
// nada.
export const TERRAZA_GENRES = ['Terraza'];

export interface ProviderCategory {
  key: string;
  emoji: string;
  labelKey: string;
  genres: string[];
}

// 'comida' apunta a una categoría que TODAVÍA NO EXISTE como fila en
// `categories` (sql/587, no aplicado) — la tarjeta/chip navega y filtra
// igual (es real, no decorativa), pero hoy mostraría 0 resultados hasta
// que esa fila se cree. Reportado explícitamente, no oculto. Mismo caso
// para 'espectaculo' y 'mc' (sql/622, agregadas 2026-09-05 — antes solo
// existían en el registro y no se podían encontrar en Explorador).
// Orden de los chips — petición real 2026-09-22: "después de grupo musical
// al lado esté amenidades y snacks, después shows" — y comediante/maestro de
// ceremonias se dejan junto a Shows (misma familia de "entretenimiento en
// vivo" para el cliente) aunque siguen siendo categorías separadas de
// verdad: si se fusionaran con 'espectaculo' perderían su trato de "solo
// sonido" (SOUND_ONLY_CATEGORIES) y pasarían a pedirles equipo completo
// (tarima/LED) como a un grupo — eso sí sería dañar algo que ya funciona
// bien, así que solo se reordenan, no se fusionan.
export const PROVIDER_CATEGORIES: ProviderCategory[] = [
  { key: 'grupo',      emoji: '🎵', labelKey: 'eventCategoryPicker.grupo',      genres: GRUPO_MUSICAL_GENRES },
  { key: 'comida',     emoji: '🍔', labelKey: 'eventCategoryPicker.comida',     genres: COMIDA_GENRES },
  // 2026-09-05 — "Shows" (antes "Espectáculo") absorbe a Payasos: payaso,
  // mago, personajes y animación son todos tipos de show, no categorías
  // separadas (petición real del usuario). Payasos ya NO es un botón propio.
  { key: 'espectaculo', emoji: '🎪', labelKey: 'eventCategoryPicker.espectaculo', genres: ['Espectáculo', 'Payasos', 'Mago', 'Personajes', 'Animación'] },
  { key: 'comediante', emoji: '🎤', labelKey: 'eventCategoryPicker.comediante', genres: ['Comediante'] },
  { key: 'mc',         emoji: '🎙️', labelKey: 'eventCategoryPicker.mc',        genres: ['Maestro de Ceremonias'] },
  { key: 'solista',    emoji: '🎷', labelKey: 'eventCategoryPicker.solista',    genres: ['Solistas'] },
  { key: 'dj',         emoji: '🎧', labelKey: 'eventCategoryPicker.dj',         genres: ['DJ'] },
  { key: 'luzSonido',  emoji: '🔊', labelKey: 'eventCategoryPicker.luzSonido',  genres: LUZ_SONIDO_GENRES },
  { key: 'renta',      emoji: '🪑', labelKey: 'eventCategoryPicker.renta',      genres: RENTA_GENRES },
  { key: 'fotografos', emoji: '📸', labelKey: 'eventCategoryPicker.fotografos', genres: FOTOGRAFOS_GENRES },
  // Terrazas va al FINAL a propósito: el orden de los chips de arriba es el
  // que pidió el usuario explícitamente ("después de grupo musical al lado
  // esté amenidades y snacks, después shows"), así que la nueva categoría no
  // se mete en medio de ese orden. Moverla es cambiar esta línea de lugar.
  { key: 'terraza',    emoji: '🏡', labelKey: 'eventCategoryPicker.terraza',    genres: TERRAZA_GENRES },
];

// Mismo criterio ya usado en HomeScreen para "músicos primero" / deck de
// Destacados en "Todos" — categorías SIN temporizador de tandas (sql/603+604).
// 'Maestro de Ceremonias' agregado 2026-09-05 (sql/622) — trabaja corrido
// todo el evento, igual que Comediante, no por tandas con descanso.
// 'Espectáculo'/'Payasos' NO se agregan — ahora son la misma categoría
// "Shows" (2026-09-05, sql/625) y eligen tipo de descanso libremente,
// igual que un solista (antes Payasos sí estaba forzado a sin-descansos).
export const NON_MUSICIAN_GENRES = new Set<string>([
  'Comediante', 'Maestro de Ceremonias',
  ...COMIDA_GENRES,
  'Renta de brincolines', 'Inflables acuáticos', 'Renta de mesas', 'Renta de sillas',
  'Fotografía', 'Drones', 'Cabina 360', 'Cabina fotográfica',
  ...TERRAZA_GENRES,
]);

// Un grupo puede tocar más de un estilo a la vez (petición real 2026-09-20:
// "un grupo puede poner dos generos, por decir norteño/sierreño") — se
// guarda en `groups.genre` como texto separado por "/" (ej. "Norteño/
// Sierreño"). splitGenres() lo separa; genreMatches() dice si CUALQUIERA de
// esos estilos es el que se busca. Un grupo de un solo género sigue
// funcionando igual (splitGenres devuelve un arreglo de 1).
export function splitGenres(genre: string | null | undefined): string[] {
  if (!genre) return [];
  return genre.split('/').map(g => g.trim()).filter(Boolean);
}

export function genreMatches(groupGenre: string | null | undefined, target: string | null | undefined): boolean {
  if (!groupGenre || !target) return false;
  const t = target.trim().toLowerCase();
  return splitGenres(groupGenre).some(g => g.toLowerCase() === t);
}

// true si ALGUNO de los estilos separados es de músico (deck "solo músicos"
// en "Todos") — combinar un género musical con uno de servicio ("Comida")
// no es un caso real hoy, pero si pasara, cuenta como músico igual.
export function isMusicianGenre(genre: string | null | undefined): boolean {
  return splitGenres(genre).some(g => !NON_MUSICIAN_GENRES.has(g));
}

// Espejo en JS de group_category_key() (sql/610) — misma tabla de géneros,
// para que el admin pueda filtrar por categoría al regalar Destacado/
// Recomendado (esas plazas ya son 5 por categoría por estado en la BD,
// este filtro solo ayuda a ELEGIR el grupo correcto, la BD decide el cupo).
export function categoryKeyForGenre(genre: string | null | undefined): string | null {
  if (!genre) return null;
  for (const part of splitGenres(genre)) {
    const found = PROVIDER_CATEGORIES.find(cat => cat.genres.includes(part));
    if (found) return found.key;
  }
  return null;
}

// ─────────────────────────────────────────────────────────────────────────
// Campos por categoría — cotización (QuoteFormScreen) y perfil del
// proveedor (DashboardScreen "Mi Equipo" / "Mi [Categoría]") — 2026-09-05.
//
// Hallazgo real: todo el ciclo de cotización (lo que pregunta el cliente,
// lo que ve el proveedor, lo que el proveedor configura en su perfil)
// estaba armado únicamente para música (sonido/iluminación/tarima/LED) —
// un cliente pidiéndole cotización a Comida o Renta de mesas veía esas
// mismas preguntas, que no sirven de nada. Esta es la ÚNICA fuente de
// verdad para los campos nuevos — QuoteFormScreen, DashboardScreen y
// QuoteDetailScreen leen de aquí, nunca se vuelve a duplicar por separado
// (mismo bug que ya se corrigió hoy para las categorías de registro).
//
// Categorías que SÍ usan la sección de equipo musical ya existente
// (has_sound/has_lighting/has_stage/has_led_screen en `groups`, sin
// cambios) — 'luzSonido' incluida porque ESE es literalmente su producto.
export const EQUIPMENT_CATEGORIES = new Set<string>(['grupo', 'solista', 'dj', 'espectaculo', 'luzSonido']);

// Comediante/MC: trabajan con micrófono pero no cargan tarima/pantallas —
// solo se les pregunta/declara sonido, no el resto del equipo.
export const SOUND_ONLY_CATEGORIES = new Set<string>(['comediante', 'mc']);

// Comida/Renta cobran por CONTRATO, no por hora (petición real 2026-09-05:
// "el proveedor de comida va por el contrato, ya sabe que se tardará mucho
// o poco, ahí no es horas"). Al cliente no se le pregunta duración — se
// manda un valor fijo (3h) solo para no romper el candado de duración
// mínima de complete_event, que ya usa ese mismo 3 como su propio default
// cuando duration_hours viene NULL. El proveedor pone un precio TOTAL, no
// por hora — sin horas extra (no tiene sentido para un servicio de contrato).
// 'terraza' entra aquí por la misma razón (2026-09-23): un salón se renta por
// evento ("la tarde", "el día"), no por hora, y no tiene horas extra por
// tanda como un grupo.
export const FLAT_RATE_CATEGORIES = new Set<string>(['comida', 'renta', 'terraza']);
export const FLAT_RATE_DEFAULT_HOURS = 3;

// Categorías que NO se trasladan: el cliente va a ELLAS, no ellas al cliente.
// Por eso al cotizar no se les pide "costo de traslado" (para un salón no
// existe) ni se les calcula distancia desde la dirección del evento.
// Hoy solo terrazas; se deja como conjunto porque es el patrón del archivo y
// porque cualquier sede futura (rancho, hacienda, quinta) cae igual aquí.
export const NO_TRAVEL_CATEGORIES = new Set<string>(['terraza']);

// true si esta categoría es una SEDE (el evento pasa ahí). Útil para textos:
// a una terraza no se le dice "¿a qué hora llegas?" sino "¿a qué hora empieza
// tu evento?".
export function isVenueCategory(categoryKey: string | null | undefined): boolean {
  return !!categoryKey && NO_TRAVEL_CATEGORIES.has(categoryKey);
}

export type CategoryDetailFieldType = 'chips' | 'multiChips' | 'text' | 'number';

export interface CategoryDetailOption {
  key: string;
  labelKey: string;
}

export interface CategoryDetailField {
  key: string;
  type: CategoryDetailFieldType;
  labelKey: string;
  placeholderKey?: string; // solo 'text' | 'number'
  options?: CategoryDetailOption[]; // solo 'chips' | 'multiChips'
  // false = el proveedor lo configura en su perfil ("Mi Comida"/"Mi Renta")
  // pero al cliente NO se le pregunta al cotizar — ya se ve en las fotos/
  // video del proveedor (petición real 2026-09-05: "cada proveedor en su
  // perfil o videos aparece que ven... el cliente ya sabe o que ve").
  // Default true (se pregunta a ambos) si se omite.
  askClient?: boolean;
}

// Categorías con preguntas propias (ni equipo musical ni "sonido solo").
// El key de cada campo/opción es lo que se guarda tal cual dentro del
// jsonb `category_details` (sql/623) — en groups (lo que el proveedor
// ofrece) y en quotes (lo que el cliente pidió).
export const CATEGORY_DETAIL_FIELDS: Record<string, CategoryDetailField[]> = {
  comida: [
    {
      key: 'service_type', type: 'chips', askClient: false,
      labelKey: 'categoryDetails.comida.serviceType.label',
      options: [
        { key: 'buffet',     labelKey: 'categoryDetails.comida.serviceType.options.buffet' },
        { key: 'banquete',   labelKey: 'categoryDetails.comida.serviceType.options.banquete' },
        { key: 'food_truck', labelKey: 'categoryDetails.comida.serviceType.options.foodTruck' },
        { key: 'estaciones', labelKey: 'categoryDetails.comida.serviceType.options.estaciones' },
      ],
    },
    {
      key: 'dietary_notes', type: 'text',
      labelKey: 'categoryDetails.comida.dietaryNotes.label',
      placeholderKey: 'categoryDetails.comida.dietaryNotes.placeholder',
    },
  ],
  renta: [
    {
      key: 'items_needed', type: 'multiChips', askClient: false,
      labelKey: 'categoryDetails.renta.itemsNeeded.label',
      options: [
        { key: 'mesas',              labelKey: 'categoryDetails.renta.itemsNeeded.options.mesas' },
        { key: 'sillas',             labelKey: 'categoryDetails.renta.itemsNeeded.options.sillas' },
        { key: 'carpas',             labelKey: 'categoryDetails.renta.itemsNeeded.options.carpas' },
        { key: 'tarimas',            labelKey: 'categoryDetails.renta.itemsNeeded.options.tarimas' },
        { key: 'escenarios',         labelKey: 'categoryDetails.renta.itemsNeeded.options.escenarios' },
        { key: 'plantas_luz',        labelKey: 'categoryDetails.renta.itemsNeeded.options.plantasLuz' },
        { key: 'generadores',        labelKey: 'categoryDetails.renta.itemsNeeded.options.generadores' },
        { key: 'brincolines',        labelKey: 'categoryDetails.renta.itemsNeeded.options.brincolines' },
        { key: 'inflables_acuaticos', labelKey: 'categoryDetails.renta.itemsNeeded.options.inflablesAcuaticos' },
        { key: 'toro_mecanico',      labelKey: 'categoryDetails.renta.itemsNeeded.options.toroMecanico' },
      ],
    },
    {
      key: 'logistics_notes', type: 'text',
      labelKey: 'categoryDetails.renta.logisticsNotes.label',
      placeholderKey: 'categoryDetails.renta.logisticsNotes.placeholder',
    },
  ],
  // "Shows" (antes "Espectáculo") — 2026-09-05, sql/625. Absorbe a Payasos:
  // payaso/mago/personajes/animación son tipos de show, no categorías
  // separadas. "Edad de los niños" (rango específico) se reemplaza por
  // "audience" (niños/adultos/todas las edades) — más simple, y el cliente
  // lo decide al cotizar según lo que necesita para SU evento.
  espectaculo: [
    {
      key: 'show_type', type: 'chips',
      labelKey: 'categoryDetails.espectaculo.showType.label',
      options: [
        { key: 'payaso',      labelKey: 'categoryDetails.espectaculo.showType.options.payaso' },
        { key: 'mago',        labelKey: 'categoryDetails.espectaculo.showType.options.mago' },
        { key: 'personajes',  labelKey: 'categoryDetails.espectaculo.showType.options.personajes' },
        { key: 'animacion',   labelKey: 'categoryDetails.espectaculo.showType.options.animacion' },
      ],
    },
    {
      key: 'audience', type: 'chips',
      labelKey: 'categoryDetails.espectaculo.audience.label',
      options: [
        { key: 'ninos',    labelKey: 'categoryDetails.espectaculo.audience.options.ninos' },
        { key: 'adultos',  labelKey: 'categoryDetails.espectaculo.audience.options.adultos' },
        { key: 'todas',    labelKey: 'categoryDetails.espectaculo.audience.options.todas' },
      ],
    },
    {
      key: 'wants_games_package', type: 'chips',
      labelKey: 'categoryDetails.espectaculo.gamesPackage.label',
      options: [
        { key: 'si', labelKey: 'categoryDetails.espectaculo.gamesPackage.options.si' },
        { key: 'no', labelKey: 'categoryDetails.espectaculo.gamesPackage.options.no' },
      ],
    },
  ],
  // Terrazas y salones (2026-09-23). Los campos son los que de verdad
  // deciden una renta de sede y que hoy se preguntan por WhatsApp: cuánta
  // gente cabe, si está techado, qué viene incluido, hasta qué hora se puede
  // poner música y si dejan meter comida/bebida de fuera.
  // 'capacity' y 'space_type' SÍ se le preguntan al cliente (son el filtro
  // real: "somos 200 y queremos techado"). 'included' y 'noise_curfew' los
  // declara la terraza en su perfil — al cliente no se le pregunta porque no
  // los elige, los consulta.
  terraza: [
    {
      key: 'capacity', type: 'number',
      labelKey: 'categoryDetails.terraza.capacity.label',
      placeholderKey: 'categoryDetails.terraza.capacity.placeholder',
    },
    {
      key: 'space_type', type: 'chips',
      labelKey: 'categoryDetails.terraza.spaceType.label',
      options: [
        { key: 'techado',    labelKey: 'categoryDetails.terraza.spaceType.options.techado' },
        { key: 'aire_libre', labelKey: 'categoryDetails.terraza.spaceType.options.aireLibre' },
        { key: 'mixto',      labelKey: 'categoryDetails.terraza.spaceType.options.mixto' },
      ],
    },
    {
      key: 'included', type: 'multiChips', askClient: false,
      labelKey: 'categoryDetails.terraza.included.label',
      options: [
        { key: 'mesas',            labelKey: 'categoryDetails.terraza.included.options.mesas' },
        { key: 'sillas',           labelKey: 'categoryDetails.terraza.included.options.sillas' },
        { key: 'manteleria',       labelKey: 'categoryDetails.terraza.included.options.manteleria' },
        { key: 'cocina',           labelKey: 'categoryDetails.terraza.included.options.cocina' },
        { key: 'estacionamiento',  labelKey: 'categoryDetails.terraza.included.options.estacionamiento' },
        { key: 'alberca',          labelKey: 'categoryDetails.terraza.included.options.alberca' },
        { key: 'asadores',         labelKey: 'categoryDetails.terraza.included.options.asadores' },
        { key: 'aire_acondicionado', labelKey: 'categoryDetails.terraza.included.options.aireAcondicionado' },
        { key: 'pista_baile',      labelKey: 'categoryDetails.terraza.included.options.pistaBaile' },
        { key: 'seguridad',        labelKey: 'categoryDetails.terraza.included.options.seguridad' },
      ],
    },
    {
      key: 'noise_curfew', type: 'text', askClient: false,
      labelKey: 'categoryDetails.terraza.noiseCurfew.label',
      placeholderKey: 'categoryDetails.terraza.noiseCurfew.placeholder',
    },
    {
      key: 'outside_food', type: 'chips',
      labelKey: 'categoryDetails.terraza.outsideFood.label',
      options: [
        { key: 'si',       labelKey: 'categoryDetails.terraza.outsideFood.options.si' },
        { key: 'no',       labelKey: 'categoryDetails.terraza.outsideFood.options.no' },
        { key: 'con_cuota', labelKey: 'categoryDetails.terraza.outsideFood.options.conCuota' },
      ],
    },
  ],
  fotografos: [
    {
      key: 'coverage_type', type: 'multiChips',
      labelKey: 'categoryDetails.fotografos.coverageType.label',
      options: [
        { key: 'fotos',  labelKey: 'categoryDetails.fotografos.coverageType.options.fotos' },
        { key: 'video',  labelKey: 'categoryDetails.fotografos.coverageType.options.video' },
        { key: 'drone',  labelKey: 'categoryDetails.fotografos.coverageType.options.drone' },
        { key: 'cabina', labelKey: 'categoryDetails.fotografos.coverageType.options.cabina' },
      ],
    },
    {
      key: 'delivery_format', type: 'chips',
      labelKey: 'categoryDetails.fotografos.deliveryFormat.label',
      options: [
        { key: 'digital', labelKey: 'categoryDetails.fotografos.deliveryFormat.options.digital' },
        { key: 'fisico',  labelKey: 'categoryDetails.fotografos.deliveryFormat.options.fisico' },
        { key: 'ambos',   labelKey: 'categoryDetails.fotografos.deliveryFormat.options.ambos' },
      ],
    },
  ],
};
