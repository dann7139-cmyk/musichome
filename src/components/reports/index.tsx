/**
 * Componentes del módulo Reportes (diseño aprobado 2026-07-18).
 * Reutilizables en AdminReportsScreen, GroupPerformanceScreen y
 * las pantallas de Estadísticas. Agregar una métrica nueva = agregar
 * una tarjeta a una lista — no diseñar una pantalla.
 */

import React from 'react';
import { Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';
import { LinearGradient } from 'expo-linear-gradient';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';
import { STATES_BY_COUNTRY } from '../../utils/locationUtils';

// ─── Formato de dinero (es-MX, sin centavos) ─────────────────────────────────
export function fmtMoney(n: number | null | undefined, currency = ''): string {
  if (n == null || isNaN(Number(n))) return '—';
  const v = `$${Number(n).toLocaleString('es-MX', { maximumFractionDigits: 0 })}`;
  return currency ? `${v} ${currency}` : v;
}

export const COUNTRY_FLAGS: Record<string, string> = {
  'México': '🇲🇽', 'Estados Unidos': '🇺🇸', 'Canadá': '🇨🇦',
};

// ─── KpiCard — tarjeta de métrica ────────────────────────────────────────────
// variant: 'normal' | 'hero' (destacada verde) | 'gold' (ganancia neta)
export function KpiCard({ label, value, detail, detailColor, variant = 'normal', wide }: {
  label: string;
  value: string;
  detail?: string;
  detailColor?: string;
  variant?: 'normal' | 'hero' | 'gold';
  wide?: boolean;
}) {
  const inner = (
    <>
      <Text style={k.label}>{label}</Text>
      <Text style={[k.value, variant === 'hero' && k.valueHero]} numberOfLines={1} adjustsFontSizeToFit>
        {value}
      </Text>
      {!!detail && <Text style={[k.detail, detailColor ? { color: detailColor } : null]}>{detail}</Text>}
    </>
  );
  if (variant === 'hero') {
    return (
      <LinearGradient
        colors={['rgba(0,230,118,0.12)', 'rgba(0,230,118,0.03)', 'transparent']}
        start={{ x: 0, y: 0 }} end={{ x: 1, y: 1 }}
        style={[k.card, k.cardHero, wide && k.wide]}
      >
        {inner}
      </LinearGradient>
    );
  }
  return (
    <View style={[k.card, variant === 'gold' && k.cardGold, wide && k.wide]}>
      {inner}
    </View>
  );
}

const k = StyleSheet.create({
  card: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.xl,
    borderWidth: 1, borderColor: COLORS.border,
    padding: 13, flex: 1, minWidth: '45%',
  },
  cardHero: { borderColor: 'rgba(0,230,118,0.35)' },
  cardGold: {
    borderColor: 'rgba(255,179,0,0.4)',
    backgroundColor: 'rgba(255,179,0,0.05)',
  },
  wide: { minWidth: '100%' },
  label: {
    fontFamily: FONTS.bodySemiBold, fontSize: 10, color: COLORS.muted,
    textTransform: 'uppercase', letterSpacing: 1,
  },
  value: {
    fontFamily: FONTS.title, fontSize: 21, lineHeight: 28, color: COLORS.text,
    marginTop: 3, fontVariant: ['tabular-nums'], includeFontPadding: false,
  },
  valueHero: { fontSize: 26, lineHeight: 33 },
  detail: { fontFamily: FONTS.body, fontSize: 10.5, color: COLORS.muted, marginTop: 2 },
});

// ─── CountryTabs — 🌎 / 🇲🇽 / 🇺🇸 / 🇨🇦 ────────────────────────────────────────
export function CountryTabs({ value, onChange }: {
  value: string | null;                 // null = todos
  onChange: (c: string | null) => void;
}) {
  const opts: { key: string | null; label: string }[] = [
    { key: null,              label: '🌎 Todos' },
    { key: 'México',          label: '🇲🇽 México' },
    { key: 'Estados Unidos',  label: '🇺🇸 EE.UU.' },
    { key: 'Canadá',          label: '🇨🇦 Canadá' },
  ];
  return (
    <View style={c.row}>
      {opts.map(o => (
        <Pressable
          key={o.key ?? 'all'}
          style={[c.chip, value === o.key && c.chipOn]}
          onPress={() => onChange(o.key)}
        >
          <Text style={[c.chipTx, value === o.key && c.chipTxOn]}>{o.label}</Text>
        </Pressable>
      ))}
    </View>
  );
}

const c = StyleSheet.create({
  row: { flexDirection: 'row', gap: 7, flexWrap: 'wrap' },
  chip: {
    borderRadius: RADIUS.full, borderWidth: 1, borderColor: COLORS.border,
    backgroundColor: COLORS.card, paddingHorizontal: 12, paddingVertical: 7,
  },
  chipOn: { borderColor: 'rgba(0,230,118,0.5)', backgroundColor: COLORS.greenMuted },
  chipTx: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.muted2 },
  chipTxOn: { color: COLORS.green, fontFamily: FONTS.bodySemiBold },
});

// ─── TrendBars — tendencia mensual (sin librerías) ───────────────────────────
export function TrendBars({ title, right, data }: {
  title: string;
  right?: string;
  data: { label: string; value: number }[];
}) {
  const max = Math.max(...data.map(d => d.value), 1);
  return (
    <View style={t.card}>
      <View style={t.head}>
        <Text style={t.title}>{title}</Text>
        {!!right && <Text style={t.right}>{right}</Text>}
      </View>
      <View style={t.bars}>
        {data.map((d, i) => {
          const isLast = i === data.length - 1;
          const h = Math.max(6, Math.round((d.value / max) * 64));
          return (
            <View key={`${d.label}-${i}`} style={t.barCol}>
              <View style={[
                t.bar,
                { height: h },
                d.value > 0 && t.barOn,
                isLast && t.barLast,
              ]} />
            </View>
          );
        })}
      </View>
      <View style={t.labels}>
        {data.map((d, i) => <Text key={`l-${i}`} style={t.label}>{d.label}</Text>)}
      </View>
    </View>
  );
}

const t = StyleSheet.create({
  card: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.xl,
    borderWidth: 1, borderColor: COLORS.border, padding: 13,
  },
  head: { flexDirection: 'row', alignItems: 'center', marginBottom: 10 },
  title: { fontFamily: FONTS.bodySemiBold, fontSize: 12.5, color: COLORS.text },
  right: { marginLeft: 'auto', fontFamily: FONTS.body, fontSize: 10.5, color: COLORS.muted },
  bars: { flexDirection: 'row', alignItems: 'flex-end', gap: 6, height: 64 },
  barCol: { flex: 1, alignItems: 'stretch', justifyContent: 'flex-end' },
  bar: { backgroundColor: COLORS.card2, borderRadius: 5 },
  barOn: { backgroundColor: COLORS.green2 },
  barLast: { backgroundColor: COLORS.green },
  labels: { flexDirection: 'row', gap: 6, marginTop: 6 },
  label: { flex: 1, textAlign: 'center', fontFamily: FONTS.body, fontSize: 9, color: COLORS.muted },
});

// ─── StatePicker — estados del país elegido, sin escribir ────────────────────
// Aparece solo cuando hay un país seleccionado. "Todos los estados" = null.
export function StatePicker({ country, value, onChange }: {
  country: string | null;
  value: string | null;
  onChange: (s: string | null) => void;
}) {
  if (!country) return null;
  const states = STATES_BY_COUNTRY[country] ?? [];
  if (states.length === 0) return null;
  return (
    <ScrollView
      horizontal
      showsHorizontalScrollIndicator={false}
      style={{ flexGrow: 0, marginTop: 8 }}
      contentContainerStyle={{ gap: 7, paddingRight: 8, alignItems: 'center' }}
    >
      <Pressable
        style={[c.chip, value === null && c.chipOn]}
        onPress={() => onChange(null)}
      >
        <Text style={[c.chipTx, value === null && c.chipTxOn]}>Todos los estados</Text>
      </Pressable>
      {states.map(st => (
        <Pressable
          key={st}
          style={[c.chip, value === st && c.chipOn]}
          onPress={() => onChange(st)}
        >
          <Text style={[c.chipTx, value === st && c.chipTxOn]}>{st}</Text>
        </Pressable>
      ))}
    </ScrollView>
  );
}

// ─── StatusPill — ok / vigilar / riesgo ──────────────────────────────────────
export function StatusPill({ kind, label }: { kind: 'ok' | 'warn' | 'bad'; label: string }) {
  const cfg = {
    ok:   { bg: COLORS.greenMuted,           color: COLORS.green },
    warn: { bg: 'rgba(255,193,7,0.12)',      color: '#FFC107' },
    bad:  { bg: 'rgba(239,83,80,0.12)',      color: COLORS.red },
  }[kind];
  return (
    <View style={[p.pill, { backgroundColor: cfg.bg }]}>
      <Text style={[p.tx, { color: cfg.color }]}>{label}</Text>
    </View>
  );
}

const p = StyleSheet.create({
  pill: { borderRadius: RADIUS.full, paddingHorizontal: 8, paddingVertical: 3 },
  tx: { fontFamily: FONTS.bodySemiBold, fontSize: 9.5, letterSpacing: 0.4 },
});

// ─── MetricRow — icono + nombre + valor + chip ───────────────────────────────
export function MetricRow({ icon, label, sub, value, pill }: {
  icon: string;
  label: string;
  sub?: string;
  value: string;
  pill?: { kind: 'ok' | 'warn' | 'bad'; label: string };
}) {
  return (
    <View style={m.row}>
      <View style={m.ic}><Text style={{ fontSize: 14 }}>{icon}</Text></View>
      <View style={{ flex: 1, minWidth: 0 }}>
        <Text style={m.label} numberOfLines={1}>{label}</Text>
        {!!sub && <Text style={m.sub} numberOfLines={1}>{sub}</Text>}
      </View>
      <Text style={m.value}>{value}</Text>
      {pill && <StatusPill kind={pill.kind} label={pill.label} />}
    </View>
  );
}

const m = StyleSheet.create({
  row: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border,
    padding: 12, flexDirection: 'row', alignItems: 'center', gap: 10,
    marginBottom: 8,
  },
  ic: {
    width: 30, height: 30, borderRadius: 10, backgroundColor: COLORS.card2,
    alignItems: 'center', justifyContent: 'center',
  },
  label: { fontFamily: FONTS.bodyMedium, fontSize: 12.5, color: COLORS.text },
  sub: { fontFamily: FONTS.body, fontSize: 10.5, color: COLORS.muted },
  value: {
    fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.text,
    fontVariant: ['tabular-nums'],
  },
});

// ─── SectionHeader ───────────────────────────────────────────────────────────
export function SectionHeader({ title, note }: { title: string; note?: string }) {
  return (
    <View style={s.row}>
      <Text style={s.title}>{title}</Text>
      {!!note && <Text style={s.note}>{note}</Text>}
    </View>
  );
}

const s = StyleSheet.create({
  row: { flexDirection: 'row', alignItems: 'baseline', gap: 8, marginTop: SPACING.lg, marginBottom: 9 },
  title: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.text },
  note: { fontFamily: FONTS.body, fontSize: 10.5, color: COLORS.muted },
});
