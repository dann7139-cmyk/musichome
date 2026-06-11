import { nowMexicoCity, parseEventDateMX } from './calculations';

/**
 * Returns true when the event's full timestamp (date + time) is strictly
 * in the future, using Mexico City local time.
 *
 * • Uses parseEventDateMX / nowMexicoCity — same semantics as EventTimerScreen.
 * • null/undefined/malformed inputs → returns false (safe, no crash, no Invalid Date).
 * • null eventTime → treated as 23:59 so a same-day event without time stays
 *   "upcoming" until end of that day.
 *
 * @param eventDate  'YYYY-MM-DD' from the DB
 * @param eventTime  'HH:MM' or 'HH:MM:SS' from the DB, or null
 * @param nowMs      optional precomputed nowMexicoCity().getTime() — pass when
 *                   calling inside a filter loop to avoid N toLocaleString() calls
 */
export function isUpcoming(
  eventDate: string | null | undefined,
  eventTime: string | null | undefined,
  nowMs?: number,
): boolean {
  if (!eventDate) return false;
  const time = eventTime ? eventTime.substring(0, 5) : '23:59';
  const ts = parseEventDateMX(eventDate, time);
  if (ts === null) return false;
  const now = nowMs ?? nowMexicoCity().getTime();
  return ts.getTime() > now;
}

/**
 * Precomputes nowMexicoCity().getTime() once and returns a bound filter function.
 * Use inside a useMemo / effect when filtering many reservations in one pass
 * to avoid calling toLocaleString() once per item.
 *
 * Usage:
 *   const nowMs = snapshotNow();
 *   const upcoming = list.filter(r => isUpcoming(r.event_date, r.event_time, nowMs));
 */
export function snapshotNow(): number {
  return nowMexicoCity().getTime();
}
