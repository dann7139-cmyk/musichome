// ── Tarifa de servicio (comisión plataforma) ──────────────────────────────────
//
// Modelo markup 20%: cliente paga grupoNeto × 1.20; grupo recibe 100% de su precio neto.
// La comisión es interna — nunca mostrar montos ni porcentajes en UI cliente/grupo.

/** Markup de plataforma: 20% sobre precio neto del grupo. */
export const SERVICE_FEE_RATE = 0.20;

// ── MSI (Meses Sin Intereses) ─────────────────────────────────────────────────
//
// Fee adicional que paga el cliente para financiar el costo de MSI a DARICEFY.
// El grupo siempre recibe su ganancia calculada sobre total_price (sin MSI fee).
// Tasas deben coincidir exactamente con PUBLIC_MSI_FEE_RATES en publicPricing.ts
//   3 MSI → +5%  |  6 MSI → +8%  |  9 MSI → +11%  |  12 MSI → +14%

/** @deprecated — usar publicPricing.ts PUBLIC_MSI_FEE_RATES para cálculos nuevos. */
export const MSI_FEE_RATE_PER_MONTH = 0.01;

export interface MsiOption {
  months: number;
  label: string;
  key: string;
  feeRate: number;
}

export const MSI_OPTIONS: MsiOption[] = [
  { months: 1,  label: '1 pago',  key: '1_pago',  feeRate: 0    },
  { months: 3,  label: '3 MSI',   key: '3_msi',   feeRate: 0.05 },
  { months: 6,  label: '6 MSI',   key: '6_msi',   feeRate: 0.06 },
  { months: 9,  label: '9 MSI',   key: '9_msi',   feeRate: 0.09 },
  { months: 12, label: '12 MSI',  key: '12_msi',  feeRate: 0.12 },
];

// Tasas MSI — espejo de PUBLIC_MSI_FEE_RATES (publicPricing.ts) para uso interno.
const _MSI_RATES: Record<number, number> = { 1: 0, 3: 0.05, 6: 0.06, 9: 0.09, 12: 0.12 };

/**
 * Calcula el cargo MSI adicional que paga el cliente.
 * @param baseAmount  total_price de la reserva (sin MSI fee)
 * @param months      número de meses (1 = sin MSI, sin cargo)
 */
export function calcMsiFee(baseAmount: number, months: number): number {
  if (months <= 1) return 0;
  return Math.round(baseAmount * (_MSI_RATES[months] ?? 0));
}

/** Monto mensual aproximado que paga el cliente con MSI. */
export function calcMonthlyMsi(baseAmount: number, months: number): number {
  if (months <= 1) return baseAmount;
  return Math.ceil((baseAmount + calcMsiFee(baseAmount, months)) / months);
}

/** Comisión de plataforma dado el precio total que paga el cliente.
 *  Modelo markup 20%: plataforma = clienteTotal − grupoNeto = clienteTotal − clienteTotal/1.20. */
export function calcServiceFee(clientTotal: number): number {
  return clientTotal - calcGroupEarnings(clientTotal);
}

/** Precio neto del grupo dado el precio total del cliente (grupo recibe 100% de su precio neto). */
export function calcGroupEarnings(clientTotal: number): number {
  return Math.round(clientTotal / 1.20);
}

/** Etiqueta UI que siempre se debe mostrar en lugar de "comisión". */
export const LABEL_SERVICE_FEE = 'Tarifa de servicio';
export const LABEL_EVENT_BASE  = 'Subtotal evento';

// ── Express y ajustes por anticipación ────────────────────────────────────────

/**
 * @deprecated Express ahora tiene la misma tarifa que reservas programadas (10%).
 * El modo Express solo garantiza respuesta prioritaria, sin costo adicional.
 * Se mantiene en 0 para compatibilidad con código existente que lo referencia.
 */
export const EXPRESS_FEE_RATE = 0;

/**
 * Devuelve el número de días naturales entre hoy y la fecha del evento.
 * 0 = mismo día, 1 = mañana, etc.
 */
export function calcDaysUntilEvent(dateStr: string): number {
  const today = new Date();
  today.setHours(0, 0, 0, 0);
  const event = new Date(dateStr + 'T00:00:00');
  return Math.max(0, Math.floor((event.getTime() - today.getTime()) / 86_400_000));
}

export type AnticipationAdj = {
  multiplier: number;                         // fracción del precio base (+0.10, -0.05, etc.)
  amount: number;                             // en $ (calculado externamente)
  label: string;                              // texto para mostrar en UI
  reason: string;                             // explicación del porqué
  type: 'discount' | 'surcharge' | 'none';
};

/**
 * Calcula el ajuste por anticipación.
 * días = 0       → mismo día      → +20% recargo
 * días 1-2       → última hora    → +10% recargo
 * días 3-7       → normal         → sin ajuste
 * días 8-14      → con tiempo     → -3% descuento
 * días ≥ 15      → anticipado     → -5% descuento
 */
export function getAnticipationAdj(days: number, basePrice: number): AnticipationAdj {
  if (days === 0) return {
    multiplier: 0.20, amount: Math.round(basePrice * 0.20),
    label: 'Recargo mismo día (+20%)',
    reason: 'Reservar el mismo día requiere atención prioritaria del equipo.',
    type: 'surcharge',
  };
  if (days <= 2) return {
    multiplier: 0.10, amount: Math.round(basePrice * 0.10),
    label: 'Recargo última hora (+10%)',
    reason: 'Reservas en menos de 72h tienen disponibilidad limitada.',
    type: 'surcharge',
  };
  if (days >= 15) return {
    multiplier: -0.05, amount: Math.round(basePrice * 0.05),
    label: 'Descuento anticipación (-5%)',
    reason: 'Gracias por reservar con más de 2 semanas de antelación.',
    type: 'discount',
  };
  if (days >= 8) return {
    multiplier: -0.03, amount: Math.round(basePrice * 0.03),
    label: 'Descuento anticipación (-3%)',
    reason: 'Reservar con más de una semana de antelación.',
    type: 'discount',
  };
  return {
    multiplier: 0, amount: 0, label: '', reason: '', type: 'none',
  };
}

/** @deprecated Usar SERVICE_FEE_RATE (0.20). */
export const PLATFORM_FEE_RATE = 0.07;

/** @deprecated Comisión ahora es fija al 20% markup. */
export const COMMISSION_TIERS: Array<{ maxPrice: number; rate: number }> = [
  { maxPrice: Infinity, rate: SERVICE_FEE_RATE },
];

/** @deprecated Usar SERVICE_FEE_RATE (0.20) directamente. */
export function getCommissionRate(_basePrice: number): number {
  return SERVICE_FEE_RATE;
}

/** Precio al cliente dado el precio neto del grupo (markup 20%). */
export function calcClientPrice(groupNet: number): number {
  return Math.round(groupNet * 1.20);
}

/** Comisión de plataforma dado el precio neto del grupo (20% del neto). */
export function calcPlatformFee(groupNet: number): number {
  return Math.round(groupNet * SERVICE_FEE_RATE);
}

/** Costo, comisión y ganancia de horas extra (modelo markup 20%).
 *  pricePerHour = precio neto del grupo por hora. */
export function calcExtraHour(pricePerHour: number, hours: number, _legacyRate?: number) {
  const groupNet      = pricePerHour * hours;
  const clientTotal   = Math.round(groupNet * 1.20);
  const commission    = clientTotal - groupNet;
  const groupEarnings = groupNet;
  return { totalExtra: groupNet, commission, groupEarnings, clientTotal };
}

/** @deprecated */
export const COMMISSION_PER_HOUR = 200;
/** @deprecated */
export function calcCommissionByHours(totalPrice: number, _durationHours: number) {
  const commission = Math.round(totalPrice * PLATFORM_FEE_RATE);
  const earnings   = totalPrice - commission;
  return { commission, earnings };
}
/** @deprecated */
export function calcCommission(totalPrice: number, commissionRate: number) {
  const commission = (totalPrice * commissionRate) / 100;
  const earnings = totalPrice - commission;
  return { commission, earnings };
}

export function isPaid(status: string | null | undefined): boolean {
  return status === 'paid' || status === 'deposit_paid' || status === 'fully_paid';
}

/**
 * Devuelve la hora actual en zona horaria America/Mexico_City.
 * Usar en lugar de `new Date()` para comparar con horarios de eventos.
 *
 * IMPORTANTE: el Date resultante tiene .getTime() ajustado para que la
 * aritmética de diferencias (diffMs) sea correcta contra eventDateTime
 * construido desde strings locales sin timezone explícita.
 */
export function nowMexicoCity(): Date {
  return new Date(new Date().toLocaleString('en-US', { timeZone: 'America/Mexico_City' }));
}

/**
 * Parsea una fecha+hora de evento (event_date + event_time de la DB) como
 * si estuviera en America/Mexico_City, retorna un Date comparable con nowMexicoCity().
 *
 * Retorna null ante cualquier input inválido — nunca lanza ni devuelve Invalid Date.
 *
 * @param eventDate  'YYYY-MM-DD'
 * @param eventTime  'HH:MM' o 'HH:MM:SS'
 */
export function parseEventDateMX(
  eventDate: string | null | undefined,
  eventTime: string | null | undefined,
): Date | null {
  if (!eventDate || !eventTime) return null;
  const hhmm = eventTime.substring(0, 5);
  if (!/^\d{4}-\d{2}-\d{2}$/.test(eventDate) || !/^\d{2}:\d{2}$/.test(hhmm)) return null;
  // Creamos el Date como si el dispositivo estuviera en Mexico City,
  // igual que nowMexicoCity() — la diferencia entre ambos es correcta.
  const mxNow = new Date().toLocaleString('en-US', { timeZone: 'America/Mexico_City' });
  const offsetMs = new Date().getTime() - new Date(mxNow).getTime();
  const result = new Date(new Date(`${eventDate}T${hhmm}:00`).getTime() + offsetMs);
  return isNaN(result.getTime()) ? null : result;
}

export function formatCurrency(amount: number, symbol = '$') {
  return `${symbol}${amount.toLocaleString('es-MX', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
}

export function breakTypeLabel(type: string): string {
  const map: Record<string, string> = {
    A: '15 min cada hora',
    B: '15 min único (a la mitad)',
    D: 'Sin descanso (3h exactas)',
  };
  return map[type] ?? type;
}

/** Recargo fijo en $ según tipo de descanso */
export const BREAK_SURCHARGE_FIXED: Record<string, number> = {
  A: 0,
  B: 0,
  D: 0,
};

/** Precio ajustado sumando el recargo fijo */
export function calcBreakAdjustedPrice(basePrice: number, breakType: string): number {
  const extra = BREAK_SURCHARGE_FIXED[breakType] ?? 0;
  return basePrice + extra;
}

export function totalEventSeconds(durationHours: number, _breakType: string): number {
  const baseSeconds = durationHours * 3600;
  // Los descansos no cuentan como tiempo de música, no se agregan
  return baseSeconds;
}

// ── Horario de descansos ────────────────────────────────────────────────

export type ScheduleSegment = {
  type: 'music' | 'break';
  fromMin: number;   // minutos desde el inicio
  toMin: number;
  fromTime: string;  // "8:00 PM"
  toTime: string;
  isExtra?: boolean;
};

function formatClock(date: Date): string {
  let h = date.getHours();
  const m = date.getMinutes();
  const ampm = h >= 12 ? 'PM' : 'AM';
  if (h === 0) h = 12;
  else if (h > 12) h -= 12;
  return `${h}:${String(m).padStart(2, '0')} ${ampm}`;
}

/**
 * Genera el horario de segmentos (música / descanso) para el evento.
 * @param startTime - Hora de inicio real del evento
 * @param contractHours - Horas contratadas (ej: 3)
 * @param breakType - Tipo de descanso: A, B, D
 */
export function generateBreakSchedule(
  startTime: Date,
  contractHours: number,
  breakType: string,
  extraHours: number = 0,
): ScheduleSegment[] {
  const segments: ScheduleSegment[] = [];
  let cursor = 0; // minutos desde inicio

  const addSeg = (type: 'music' | 'break', durationMin: number, isExtra = false) => {
    const from = new Date(startTime.getTime() + cursor * 60000);
    const to = new Date(startTime.getTime() + (cursor + durationMin) * 60000);
    segments.push({
      type,
      fromMin: cursor,
      toMin: cursor + durationMin,
      fromTime: formatClock(from),
      toTime: formatClock(to),
      ...(isExtra ? { isExtra: true } : {}),
    });
    cursor += durationMin;
  };

  switch (breakType) {
    case 'A':
      // 15 min descanso por hora, pero la última hora NO lleva descanso (el evento termina)
      for (let i = 0; i < contractHours; i++) {
        addSeg('music', 45);
        if (i < contractHours - 1) {
          addSeg('break', 15);
        }
      }
      break;

    case 'B':
      // Un descanso de 15 min a la mitad
      {
        const halfMusic = (contractHours * 60 - 15) / 2;
        addSeg('music', halfMusic);
        addSeg('break', 15);
        addSeg('music', halfMusic);
      }
      break;

    case 'D':
    default:
      // Sin descanso
      addSeg('music', contractHours * 60);
      break;
  }

  // Horas extra: siempre 15 min descanso + 60 min música por cada hora extra
  for (let i = 0; i < extraHours; i++) {
    addSeg('break', 15, true);  // descanso antes de hora extra
    addSeg('music', 60, true);  // la hora extra
  }

  return segments;
}
