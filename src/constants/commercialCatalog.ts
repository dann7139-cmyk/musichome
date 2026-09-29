/**
 * Catálogo comercial del proveedor — fuente única de verdad de la app.
 *
 * Son los 4 datos estructurados que viven en `groups` (sql/720) y que el
 * proveedor declara al registrarse (`provider_applications`):
 *
 *   min_hours        horas mínimas de contratación
 *   included_hours   cuántas horas incluye el precio base mostrado (price_from)
 *   extra_hour_price precio comercial de una hora adicional elegida ANTES de
 *                    contratar
 *   capacity_max     capacidad máxima del servicio, en la unidad de su categoría
 *
 * NO son un precio final garantizado: sirven para filtrar, ordenar, respetar
 * mínimos y dar una estimación inicial. El precio final siempre es la quote real
 * respondida por Admin/proveedor, con traslado cuando corresponda.
 *
 * `extra_hour_price` de aquí NO es el sistema `extra_hours` (las horas que se
 * piden durante o al final del evento, tabla `extra_hours` + `request_overtime`).
 * Aquel se cobra con su propio precio y no se toca.
 *
 * ── POR QUÉ NO TODAS LAS CATEGORÍAS PIDEN TODO ──────────────────────────────
 * Un formulario que le pregunta "¿cuántas horas mínimas?" a una taquiza, o
 * "¿cuánta gente te cabe?" a un mariachi, es un formulario absurdo. Por eso cada
 * categoría declara abajo qué campos le aplican de verdad:
 *
 *   · Servicios que se venden POR HORAS (música, DJ, solista, comediante, MC,
 *     espectáculo, luz y sonido, fotógrafos, terrazas) → las 3 de horas.
 *   · `comida` se vende por menú/porción, no por hora → solo capacidad
 *     (porciones que puede atender).
 *   · `renta` se cobra por pieza/día → ninguno de los cuatro. Se le deja sin
 *     preguntar nada en vez de inventarle un campo.
 *   · `capacity_max` NO se le pide a `terraza` ni a `luzSonido` porque esos dos
 *     YA tienen su propio campo y duplicarlo crearía dos fuentes de verdad:
 *       - terraza  → `category_details.capacity` (lo pregunta también al cliente)
 *       - luzSonido → `groups.sound_capacity_max` (a cuánta gente le alcanza su
 *                     equipo de sonido, sql/403)
 *     Quien lea capacidad debe usar, mientras eso no se unifique:
 *       capacity_max ?? Number(category_details?.capacity)
 */

export type CatalogFieldKey = 'min_hours' | 'included_hours' | 'extra_hour_price' | 'capacity_max';

export interface CatalogValues {
  min_hours: number | null;
  included_hours: number | null;
  extra_hour_price: number | null;
  capacity_max: number | null;
}

/** Los mismos límites que los CHECK de sql/720. Si cambian allá, cambian aquí. */
export const CATALOG_LIMITS = {
  min_hours:        { min: 0.5, max: 24 },
  included_hours:   { min: 0.5, max: 24 },
  extra_hour_price: { min: 0,   max: 99999999 },
  capacity_max:     { min: 1,   max: 100000 },
} as const;

const HORAS: CatalogFieldKey[] = ['min_hours', 'included_hours', 'extra_hour_price'];

/** Qué campos aplican por categoría (`PROVIDER_CATEGORIES[].key`). */
export const CATALOG_FIELDS_BY_CATEGORY: Record<string, CatalogFieldKey[]> = {
  grupo:       HORAS,
  solista:     HORAS,
  dj:          HORAS,
  comediante:  HORAS,
  mc:          HORAS,
  espectaculo: HORAS,
  luzSonido:   HORAS,           // capacidad = sound_capacity_max, ya existe
  fotografos:  HORAS,
  terraza:     HORAS,           // capacidad = category_details.capacity, ya existe
  comida:      ['capacity_max'],
  renta:       [],
};

/** Formulario vacío — los 4 campos como texto, que es lo que teclea el usuario. */
export const EMPTY_CATALOG_FORM: Record<CatalogFieldKey, string> = {
  min_hours: '', included_hours: '', extra_hour_price: '', capacity_max: '',
};

/**
 * Siembra el formulario con lo que el grupo ya tiene guardado.
 * Se usa para DERIVAR el formulario en render (sin useEffect, que dispararía
 * renders en cascada y es lo que marca react-hooks/set-state-in-effect).
 */
export function catalogFormFrom(g?: Partial<CatalogValues> | null): Record<CatalogFieldKey, string> {
  return {
    min_hours:        g?.min_hours        != null ? String(g.min_hours)        : '',
    included_hours:   g?.included_hours   != null ? String(g.included_hours)   : '',
    extra_hour_price: g?.extra_hour_price != null ? String(g.extra_hour_price) : '',
    capacity_max:     g?.capacity_max     != null ? String(g.capacity_max)     : '',
  };
}

/** Categoría desconocida → no se inventan campos. */
export function catalogFieldsFor(categoryKey?: string | null): CatalogFieldKey[] {
  if (!categoryKey) return [];
  return CATALOG_FIELDS_BY_CATEGORY[categoryKey] ?? [];
}

export function categoryUsesCatalog(categoryKey?: string | null): boolean {
  return catalogFieldsFor(categoryKey).length > 0;
}

/** Etiqueta y ayuda de cada campo, dependiendo de la categoría. */
export function catalogFieldLabel(field: CatalogFieldKey, categoryKey?: string | null): string {
  switch (field) {
    case 'min_hours':        return 'Horas mínimas de contratación';
    case 'included_hours':   return 'Horas que incluye tu precio base';
    case 'extra_hour_price': return 'Precio de una hora adicional';
    case 'capacity_max':
      return categoryKey === 'comida' ? 'Personas que puedes atender' : 'Capacidad máxima';
  }
}

export function catalogFieldPlaceholder(field: CatalogFieldKey, categoryKey?: string | null): string {
  switch (field) {
    case 'min_hours':        return 'Ej. 3';
    case 'included_hours':   return 'Ej. 4';
    case 'extra_hour_price': return 'Ej. 1500';
    case 'capacity_max':     return categoryKey === 'comida' ? 'Ej. 150' : 'Ej. 200';
  }
}

/** Solo dígitos y un punto para horas/precio; solo dígitos para capacidad. */
export function sanitizeCatalogInput(field: CatalogFieldKey, raw: string): string {
  if (field === 'capacity_max') return raw.replace(/[^0-9]/g, '');
  return raw.replace(/[^0-9.]/g, '').replace(/(\..*)\./g, '$1');
}

/** '' → null. Lo que no sea número tampoco se manda. */
export function parseCatalogInput(field: CatalogFieldKey, raw: string): number | null {
  const t = raw.trim();
  if (t === '') return null;
  const n = field === 'capacity_max' ? parseInt(t, 10) : parseFloat(t);
  return Number.isFinite(n) ? n : null;
}

/**
 * Espejo de las validaciones del servidor, para avisar antes de mandar. El
 * servidor sigue siendo la autoridad (RPC + CHECK de sql/720).
 * Devuelve el mensaje del primer problema, o null si todo bien.
 */
export function validateCatalog(v: Partial<CatalogValues>): string | null {
  const { min_hours: mh, included_hours: ih, extra_hour_price: ep, capacity_max: cm } = v;

  if (mh != null && (mh <= 0 || mh > CATALOG_LIMITS.min_hours.max)) {
    return `Las horas mínimas deben estar entre ${CATALOG_LIMITS.min_hours.min} y ${CATALOG_LIMITS.min_hours.max}.`;
  }
  if (ih != null && (ih <= 0 || ih > CATALOG_LIMITS.included_hours.max)) {
    return `Las horas incluidas deben estar entre ${CATALOG_LIMITS.included_hours.min} y ${CATALOG_LIMITS.included_hours.max}.`;
  }
  if (ep != null && ep < 0) {
    return 'El precio de la hora adicional no puede ser negativo.';
  }
  if (cm != null && (cm <= 0 || cm > CATALOG_LIMITS.capacity_max.max)) {
    return `La capacidad debe estar entre ${CATALOG_LIMITS.capacity_max.min} y ${CATALOG_LIMITS.capacity_max.max}.`;
  }
  return null;
}

/**
 * Aviso NO bloqueante — el mismo que devuelve la RPC en `avisos`.
 * A propósito no es un error: no está comprobado que ningún tipo de servicio
 * necesite legítimamente incluir menos horas que su mínimo, así que se avisa y
 * se guarda igual (ver el encabezado de sql/720).
 */
export function catalogWarning(v: Partial<CatalogValues>): string | null {
  const { min_hours: mh, included_hours: ih } = v;
  if (mh != null && ih != null && ih < mh) {
    return `Tu precio base incluye ${ih} h pero el mínimo de contratación es ${mh} h: al cliente le aparecería una estimación más baja de lo que puede contratar.`;
  }
  return null;
}

/** Traduce el `error` de la RPC a algo que el usuario entienda. */
export function catalogErrorMessage(error?: string | null): string {
  switch (error) {
    case 'not_allowed':              return 'No tienes permiso para editar el catálogo de este proveedor.';
    case 'group_not_found':          return 'No se encontró el proveedor.';
    case 'not_authenticated':        return 'Vuelve a iniciar sesión e intenta de nuevo.';
    case 'invalid_min_hours':        return 'Las horas mínimas no son válidas.';
    case 'invalid_included_hours':   return 'Las horas incluidas no son válidas.';
    case 'invalid_extra_hour_price': return 'El precio de la hora adicional no es válido.';
    case 'invalid_capacity_max':     return 'La capacidad no es válida.';
    default:                         return 'No se pudo guardar el catálogo comercial.';
  }
}
