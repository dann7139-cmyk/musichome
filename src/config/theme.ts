export const COLORS = {
  // Fondos
  bg: '#040404',
  card: '#0e0e0e',
  card2: '#151515',
  border: '#1a1a1a',

  // Verdes
  green: '#00E676',
  green2: '#00C853',
  greenMuted: 'rgba(0, 230, 118, 0.12)',
  greenGlow: 'rgba(0, 230, 118, 0.25)',

  // Textos
  text: '#efefef',
  muted: '#555555',
  muted2: '#888888',

  // Estados
  gold: '#FFB300',
  blue: '#4285F4',
  red: '#EF5350',
  orange: '#FF9800',
  purple: '#9C27B0',

  // Utilidades
  white: '#FFFFFF',
  black: '#000000',
  overlay: 'rgba(0,0,0,0.75)',

  // Aliases para compatibilidad con código existente
  background: '#040404',
  surface: '#0e0e0e',
  surfaceLight: '#151515',
  primary: '#00E676',
  primaryDark: '#00C853',
  primaryLight: '#69F0AE',
  primaryMuted: 'rgba(0, 230, 118, 0.12)',
  textSecondary: '#888888',
  textMuted: '#555555',
  error: '#EF5350',
  warning: '#FFB300',
  success: '#00E676',
  neon: '#00E676',
};

export const CLIENT_COLORS = {
  bg:     '#F5F6F8',
  card:   '#FFFFFF',
  card2:  '#ECEEF1',
  border: '#E0E2E6',

  green:      '#00955A',
  green2:     '#007A3D',
  greenMuted: 'rgba(0,149,90,0.10)',
  greenGlow:  'rgba(0,149,90,0.18)',

  text:   '#111318',
  muted:  '#9AA0A6',
  muted2: '#5F6368',

  gold:   '#C8900A',
  blue:   '#1A73E8',
  red:    '#D93025',
  orange: '#E8700A',

  white:   '#FFFFFF',
  black:   '#000000',
  overlay: 'rgba(0,0,0,0.45)',

  background:   '#F5F6F8',
  surface:      '#FFFFFF',
  surfaceLight: '#ECEEF1',
  primary:      '#00955A',
  primaryDark:  '#007A3D',
  primaryLight: '#00CC66',
  primaryMuted: 'rgba(0,149,90,0.10)',
  textSecondary:'#5F6368',
  textMuted:    '#9AA0A6',
  error:        '#D93025',
  warning:      '#C8900A',
  success:      '#00955A',
  neon:         '#00955A',
};

export const FONTS = {
  title: 'Syne_800ExtraBold',
  body: 'DMSans_400Regular',
  bodyMedium: 'DMSans_500Medium',
  bodySemiBold: 'DMSans_600SemiBold',
};

// ─── Estándares de header por tipo de pantalla ────────────────────────────────
// LISTA     → FONTS.title 20px centrado          (ReservationsScreen)
// FORMULARIO → FONTS.bodySemiBold 16px izquierda (QuoteFormScreen, QuoteDetailScreen, ProposeRequestScreen, ClientQuoteDetailScreen, EventTimerScreen)
// WIZARD    → FONTS.title 18px centrado          (GuidedRequestScreen, OpenRequestScreen)
// DETALLE   → FONTS.bodySemiBold 16px izquierda  (ClientQuoteDetailScreen)
// ─────────────────────────────────────────────────────────────────────────────

export const RADIUS = {
  sm: 8,
  md: 10,
  lg: 14,
  xl: 18,
  full: 999,
};

export const SPACING = {
  xs: 8,
  sm: 12,
  md: 16,
  lg: 20,
  xl: 24,
  xxl: 32,
};
