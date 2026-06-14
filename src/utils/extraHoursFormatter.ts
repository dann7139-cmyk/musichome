/**
 * Utilidades para mostrar contexto temporal de horas extra al cliente.
 * Calcula rangos "de HH:MM a HH:MM" y timestamps relativos.
 */

/** Suma `hoursToAdd` horas a "HH:MM" y devuelve "HH:MM" (wraps en 24h). */
function addHoursToTime(baseTime: string, hoursToAdd: number): string {
  const [h, m] = baseTime.split(':').map(Number);
  const totalMin = h * 60 + m + Math.round(hoursToAdd * 60);
  const newH = Math.floor(totalMin / 60) % 24;
  const newM = totalMin % 60;
  return `${String(newH).padStart(2, '0')}:${String(newM).padStart(2, '0')}`;
}

/**
 * Calcula el rango horario de una hora extra específica.
 *
 * @param eventTime     Hora de inicio del evento "HH:MM"
 * @param originalHours Horas contratadas originalmente
 * @param prevExtra     Horas extra ya aprobadas ANTES de esta solicitud
 *                      (usar reservation.extra_hours_added ?? 0)
 * @param thisHours     Horas que añade esta solicitud
 */
export function formatExtraHourRange(
  eventTime: string,
  originalHours: number,
  prevExtra: number,
  thisHours: number,
): { from: string; to: string } | null {
  if (!eventTime || !originalHours) return null;
  const from = addHoursToTime(eventTime, originalHours + prevExtra);
  const to   = addHoursToTime(eventTime, originalHours + prevExtra + thisHours);
  return { from, to };
}

/**
 * Devuelve una etiqueta de tiempo relativa/absoluta para "cuándo fue propuesta".
 * - < 1 min   → "Ahora mismo"
 * - < 60 min  → "Hace X min"
 * - >= 60 min → "A las HH:MM"
 */
export function formatProposedAt(createdAt: string | undefined): string | null {
  if (!createdAt) return null;
  const created = new Date(createdAt);
  if (isNaN(created.getTime())) return null;

  const diffMin = Math.floor((Date.now() - created.getTime()) / 60_000);

  if (diffMin < 1)  return 'Ahora mismo';
  if (diffMin < 60) return `Hace ${diffMin} min`;

  return `A las ${created.toLocaleTimeString('es-MX', {
    hour:   '2-digit',
    minute: '2-digit',
    hour12: false,
  })}`;
}
