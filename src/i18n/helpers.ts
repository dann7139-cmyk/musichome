import i18n from './index';

type NotifKey =
  | 'payment_received'
  | 'earnings_released'
  | 'half_released'
  | 'extra_hours';

interface NotifOptions {
  amount?: string | number;
  currency?: string;
  date?: string;
}

export function getNotifTitle(key: NotifKey): string {
  return i18n.t(`notifications.${key}_title`);
}

export function getNotifBody(key: NotifKey, opts: NotifOptions = {}): string {
  return i18n.t(`notifications.${key}_body`, opts as Record<string, unknown>);
}
