/**
 * Construye el `markedDates` de react-native-calendars a partir de los días
 * ocupados de un grupo (RPC get_group_busy_days) y sus bloqueos manuales
 * (group_unavailability).
 *
 * Regla de negocio (Fase A — máximo 2 eventos/día): un día con reserva
 * existente NO se deshabilita — el grupo puede tener hasta 2 eventos el
 * mismo día sin traslape real. Solo los bloqueos manuales deshabilitan el
 * día. La disponibilidad real (límite diario, traslape) la decide el
 * backend al confirmar (create_booking_with_event / client_accept_proposal).
 */

export interface GroupBusyDay {
  event_date: string | null;
  event_time?: string | null;
  hours_count?: number | null;
}

export interface GroupBlockedDay {
  date: string | null;
}

export interface CalendarDayStyle {
  backgroundColor: string;
  textColor: string;
}

export interface CalendarMark {
  disabled?: boolean;
  disableTouchEvent?: boolean;
  customStyles?: {
    container?: Record<string, unknown>;
    text?: Record<string, unknown>;
  };
}

export function buildGroupCalendarMarks(
  busyDays: GroupBusyDay[] | null | undefined,
  blockedDays: GroupBlockedDay[] | null | undefined,
  busyStyle: CalendarDayStyle,
  blockedStyle: CalendarDayStyle,
): Record<string, CalendarMark> {
  const marked: Record<string, CalendarMark> = {};

  (busyDays ?? []).forEach((day) => {
    if (!day.event_date) return;
    marked[day.event_date] = {
      customStyles: {
        container: { backgroundColor: busyStyle.backgroundColor },
        text: { color: busyStyle.textColor, fontWeight: '700' },
      },
    };
  });

  (blockedDays ?? []).forEach((day) => {
    if (!day.date) return;
    marked[day.date] = {
      disabled: true,
      disableTouchEvent: true,
      customStyles: {
        container: { backgroundColor: blockedStyle.backgroundColor },
        text: { color: blockedStyle.textColor },
      },
    };
  });

  return marked;
}
