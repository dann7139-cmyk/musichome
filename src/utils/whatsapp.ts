/**
 * WhatsApp para el panel de conserjería (Admin).
 *
 * Etapa 1 de "Arma mi fiesta": el admin ya recibe la solicitud de cotización de
 * los proveedores en `concierge_mode` y hoy tiene que copiar los datos a mano
 * para pedirles su precio. Esto arma el mensaje y abre WhatsApp.
 *
 * REGLA DE PRIVACIDAD (decisión de producto, auditoría 2026-09-28): al proveedor
 * se le manda SOLO lo necesario para cotizar — servicio, fecha, hora, duración,
 * municipio/estado, invitados y requerimientos. **NUNCA** la dirección exacta,
 * ni el nombre, ni el teléfono del cliente. Es coherente con la política que ya
 * aplica el carril exprés (el pin del destino se desplaza y la dirección no se
 * muestra antes del pago).
 *
 * No hay fuente de datos nueva: todo sale de lo que `admin_get_concierge_quotes`
 * ya devuelve a la pantalla.
 */

/** Lada internacional por país. Solo los países que existen en `countries`. */
const LADAS: Record<string, string> = {
  MX: '52',
  MEXICO: '52',
  MÉXICO: '52',
  US: '1',
  USA: '1',
  'ESTADOS UNIDOS': '1',
  'UNITED STATES': '1',
  CA: '1',
  CANADA: '1',
  CANADÁ: '1',
};

/**
 * Deja el teléfono como lo pide wa.me: solo dígitos, con lada y sin `+`.
 * Devuelve null cuando no hay forma de construir un número usable — en ese caso
 * el botón se deshabilita en vez de abrir WhatsApp con un número roto.
 */
export function normalizeWhatsAppPhone(
  phone?: string | null,
  country?: string | null,
): string | null {
  if (!phone) return null;

  const traiaMas = phone.trim().startsWith('+');
  const digitos = phone.replace(/\D/g, '');
  if (digitos.length < 8) return null;

  // Ya venía en formato internacional: se respeta tal cual.
  if (traiaMas) return digitos;

  // Número local de 10 dígitos → se le pone la lada del país del proveedor.
  const lada = LADAS[(country ?? '').trim().toUpperCase()];
  if (digitos.length === 10 && lada) return lada + digitos;

  // Ya trae lada aunque no tuviera '+' (ej. 5216181234567).
  if (digitos.length > 10) return digitos;

  // 10 dígitos sin país conocido: no se adivina la lada.
  return lada ? lada + digitos : null;
}

/** Un renglón del mensaje. Los vacíos se omiten. */
export interface QuoteWhatsAppData {
  groupName?: string | null;
  servicio?: string | null;
  eventType?: string | null;
  fecha?: string | null;
  hora?: string | null;
  duracionHoras?: number | null;
  /** Municipio y estado. NUNCA la dirección exacta. */
  zona?: string | null;
  invitados?: number | null;
  /** Tamaño del lugar / si es techado, ya traducido por la pantalla. */
  lugar?: string | null;
  /** Sonido, iluminación, tarima, LED… ya traducidos por la pantalla. */
  requerimientos?: string[];
  /** `category_details` ya formateado por la pantalla. */
  detalles?: string | null;
  comentarios?: string | null;
}

/**
 * Arma el mensaje. La pantalla pasa los textos ya traducidos (ella tiene los
 * mapas de etiquetas), así que aquí no se duplica ninguna tabla de labels.
 */
export function buildQuoteWhatsAppMessage(d: QuoteWhatsAppData): string {
  const l: string[] = [];

  l.push(`Hola${d.groupName ? ` ${d.groupName}` : ''}, tengo una solicitud de cotización para ti:`);
  l.push('');

  if (d.servicio)  l.push(`Servicio: ${d.servicio}`);
  if (d.eventType) l.push(`Evento: ${d.eventType}`);

  const cuando = [d.fecha, d.hora].filter(Boolean).join(' · ');
  if (cuando) l.push(`Fecha: ${cuando}`);

  if (d.duracionHoras) l.push(`Duración: ${d.duracionHoras} h`);
  if (d.zona)          l.push(`Zona: ${d.zona}`);
  if (d.invitados)     l.push(`Invitados: ${d.invitados}`);
  if (d.lugar)         l.push(`Lugar: ${d.lugar}`);

  if (d.requerimientos && d.requerimientos.length > 0) {
    l.push(`Requiere: ${d.requerimientos.join(' · ')}`);
  }
  if (d.detalles)    l.push(`Detalles: ${d.detalles}`);
  if (d.comentarios) l.push(`Notas del cliente: ${d.comentarios}`);

  l.push('');
  l.push('¿Cuánto cobrarías, incluyendo traslado a esa zona?');

  return l.join('\n');
}

/** URL de wa.me lista para `Linking.openURL`. */
export function buildWhatsAppUrl(phoneNormalizado: string, mensaje: string): string {
  return `https://wa.me/${phoneNormalizado}?text=${encodeURIComponent(mensaje)}`;
}
