/**
 * GroupPerformanceScreen — 📈 Mi desempeño (panel del grupo).
 * Diseño aprobado 2026-07-18. El grupo ve SOLO lo suyo con las
 * palabras de siempre ("Tu ganancia") — Daricefy y sus comisiones
 * no existen en esta pantalla. Mismos números que su Wallet.
 *
 * Datos: group_performance_dashboard (sql/504) — group_id derivado
 * del token, jamás del cliente.
 */

import { ArrowLeft, Download, Star } from 'lucide-react-native';
import React, { useCallback, useEffect, useState } from 'react';
import {
  ActivityIndicator,
  Alert,
  Linking,
  Pressable,
  RefreshControl,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { useTranslation } from 'react-i18next';
import type { TFunction } from 'i18next';
import { supabase } from '../../config/supabase';
import { exportDaricefyReportPdf } from '../../utils/exportDaricefyReportPdf';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';
import {
  fmtMoney, KpiCard, MetricRow, SectionHeader, TrendBars,
} from '../../components/reports';

const getRanges = (t: TFunction) => [
  { key: '90d',  label: t('groupPerformanceScreen.ranges.d90'),  days: 90 },
  { key: 'year', label: t('groupPerformanceScreen.ranges.year'), days: 365 },
  { key: 'all',  label: t('groupPerformanceScreen.ranges.all'),  days: 0 },
];

const MONTH_LABELS = ['ene', 'feb', 'mar', 'abr', 'may', 'jun', 'jul', 'ago', 'sep', 'oct', 'nov', 'dic'];
const monthLabel = (yyyymm: string) =>
  MONTH_LABELS[(parseInt(yyyymm?.split('-')[1] ?? '1', 10) - 1) % 12] ?? yyyymm;

function fmtDate(iso: string | null): string {
  if (!iso) return '—';
  return new Date(iso).toLocaleDateString('es-MX', { day: 'numeric', month: 'short', year: 'numeric' });
}

export default function GroupPerformanceScreen({ navigation }: any) {
  const { t } = useTranslation();
  const RANGES = getRanges(t);
  const [range,      setRange]      = useState('all');
  const [data,       setData]       = useState<any | null>(null);
  const [loading,    setLoading]    = useState(true);
  const [refreshing, setRefreshing] = useState(false);
  const [exporting,  setExporting]  = useState(false);

  const load = useCallback(async () => {
    try {
      const r = RANGES.find(x => x.key === range) ?? RANGES[2];
      const from = r.days > 0
        ? new Date(Date.now() - r.days * 86_400_000).toISOString().slice(0, 10)
        : null;
      const { data: d, error } = await supabase.rpc('group_performance_dashboard', {
        p_from: from, p_to: null,
      });
      if (error) throw error;
      if (d?.ok) setData(d);
    } catch (e: any) {
      console.error('[GroupPerformance]', e?.message);
    } finally {
      setLoading(false);
    }
  }, [range]);

  useEffect(() => { load(); }, [load]);
  const onRefresh = async () => { setRefreshing(true); await load(); setRefreshing(false); };

  // ── Exportar mi reporte (Excel o PDF — solo SUS datos) ──────────────────────
  const handleExport = () => {
    Alert.alert(t('groupPerformanceScreen.export.sheetTitle'), t('groupPerformanceScreen.export.sheetMessage'), [
      { text: t('groupPerformanceScreen.export.cancel'), style: 'cancel' },
      { text: t('groupPerformanceScreen.export.excel'), onPress: () => runExport('xlsx') },
      { text: t('groupPerformanceScreen.export.pdf'), onPress: () => runExport('pdf') },
    ]);
  };

  const runExport = async (format: 'xlsx' | 'pdf') => {
    if (exporting) return;
    setExporting(true);
    try {
      const r = RANGES.find(x => x.key === range) ?? RANGES[2];
      const from = r.days > 0
        ? new Date(Date.now() - r.days * 86_400_000).toISOString().slice(0, 10)
        : '2000-01-01';
      const { data: { session } } = await supabase.auth.getSession();
      if (!session) throw new Error(t('groupPerformanceScreen.export.sessionExpired'));
      const { data: res, error } = await supabase.functions.invoke('generate-report', {
        body: { mode: 'group', format, from, to: new Date().toISOString().slice(0, 10) },
        headers: { Authorization: `Bearer ${session.access_token}` },
      });
      if (error) throw new Error(error.message ?? t('groupPerformanceScreen.export.networkError'));
      if ((res as any)?.error) throw new Error((res as any).error);
      if (format === 'pdf') {
        const report = (res as any)?.report;
        if (!report) throw new Error(t('groupPerformanceScreen.export.noFile'));
        await exportDaricefyReportPdf(report);
      } else {
        const url = (res as any)?.url as string | undefined;
        if (!url) throw new Error(t('groupPerformanceScreen.export.noFile'));
        await Linking.openURL(url);
      }
    } catch (e: any) {
      Alert.alert(t('groupPerformanceScreen.export.errorTitle'), e.message ?? t('groupPerformanceScreen.export.errorDefault'));
    } finally {
      setExporting(false);
    }
  };

  const rt = data?.rating ?? {};
  const ev = data?.events ?? {};
  const money: any[] = data?.money ?? [];
  const trendData = (data?.trend ?? []).map((t: any) => ({
    label: monthLabel(t.mes), value: Number(t.total),
  }));

  return (
    <View style={s.root}>
      <SafeAreaView edges={['top']} style={s.header}>
        <Pressable style={s.backBtn} onPress={() => navigation.goBack()}>
          <ArrowLeft size={20} color={COLORS.text} />
        </Pressable>
        <View style={{ flex: 1 }}>
          <Text style={s.headerTitle}>{t('groupPerformanceScreen.header.title')}</Text>
          <Text style={s.headerSub}>{data ? `${data.from} — ${data.to}` : ' '}</Text>
        </View>
        <Pressable style={[s.exportBtn, exporting && { opacity: 0.6 }]} onPress={handleExport} disabled={exporting}>
          {exporting
            ? <ActivityIndicator size="small" color="#000" />
            : <Download size={14} color="#000" strokeWidth={2.5} />}
          <Text style={s.exportTx}>{t('groupPerformanceScreen.export.button')}</Text>
        </Pressable>
      </SafeAreaView>

      {loading ? (
        <View style={s.center}><ActivityIndicator size="large" color={COLORS.green} /></View>
      ) : (
        <ScrollView
          contentContainerStyle={s.scroll}
          showsVerticalScrollIndicator={false}
          refreshControl={<RefreshControl refreshing={refreshing} onRefresh={onRefresh} tintColor={COLORS.green} />}
        >
          {/* Rango */}
          <View style={s.rangeRow}>
            {RANGES.map(r => (
              <Pressable
                key={r.key}
                style={[s.rangeChip, range === r.key && s.rangeChipOn]}
                onPress={() => setRange(r.key)}
              >
                <Text style={[s.rangeTx, range === r.key && s.rangeTxOn]}>{r.label}</Text>
              </Pressable>
            ))}
          </View>

          {/* ── ⭐ Desempeño ── */}
          <View style={s.grid}>
            <KpiCard
              variant="hero" wide
              label={t('groupPerformanceScreen.kpi.avgRating')}
              value={`${Number(rt.promedio ?? 0).toFixed(1)} ★`}
              detail={t('groupPerformanceScreen.kpi.reviewsCount', { count: rt.resenas ?? 0 })}
            />
            <KpiCard label={t('groupPerformanceScreen.kpi.eventsRealized')} value={String(ev.realizados ?? 0)} />
            <KpiCard label={t('groupPerformanceScreen.kpi.upcoming')} value={String(ev.proximos ?? 0)} />
            <KpiCard
              label={t('groupPerformanceScreen.kpi.cancelled')}
              value={String(ev.cancelados ?? 0)}
              detail={t('groupPerformanceScreen.kpi.cancelledDetail', { yours: ev.cancel_tuyos ?? 0, client: ev.cancel_cliente ?? 0 })}
              detailColor={(ev.cancel_tuyos ?? 0) > 0 ? COLORS.orange : undefined}
            />
            <KpiCard
              label={t('groupPerformanceScreen.kpi.noShows')}
              value={String(ev.no_shows ?? 0)}
              detail={(ev.no_shows ?? 0) === 0 ? t('groupPerformanceScreen.kpi.noShowsClean') : t('groupPerformanceScreen.kpi.noShowsAffects')}
              detailColor={(ev.no_shows ?? 0) === 0 ? COLORS.green : COLORS.red}
            />
          </View>

          {/* ── 💵 Tus ganancias ── */}
          {money.map((m: any) => (
            <View key={m.moneda}>
              <SectionHeader title={t('groupPerformanceScreen.earnings.sectionTitle')} note={m.moneda} />
              <View style={s.grid}>
                <KpiCard variant="hero" wide label={t('groupPerformanceScreen.earnings.totalLabel', { currency: m.moneda })} value={fmtMoney(m.total)} />
                <KpiCard label={t('groupPerformanceScreen.earnings.pending')} value={fmtMoney(m.pendiente)} detail={t('groupPerformanceScreen.earnings.pendingDetail')} />
                <KpiCard label={t('groupPerformanceScreen.earnings.paid')} value={fmtMoney(m.pagado)} />
              </View>
            </View>
          ))}

          {/* ── 📈 Tendencia ── */}
          {trendData.length > 1 && (
            <>
              <SectionHeader title={t('groupPerformanceScreen.trend.sectionTitle')} note={t('groupPerformanceScreen.trend.note')} />
              <TrendBars title={t('groupPerformanceScreen.trend.last6Months')} data={trendData} />
            </>
          )}

          {/* ── 📍 Ciudades ── */}
          {(data?.cities ?? []).length > 0 && (
            <>
              <SectionHeader title={t('groupPerformanceScreen.cities.sectionTitle')} />
              <View style={s.cityWrap}>
                {(data.cities as any[]).map((c: any) => (
                  <View key={c.ciudad} style={s.cityChip}>
                    <Text style={s.cityTx}>{c.ciudad} · {c.eventos}</Text>
                  </View>
                ))}
              </View>
            </>
          )}

          {/* ── 🧾 Historial de pagos ── */}
          {(data?.payments ?? []).length > 0 && (
            <>
              <SectionHeader title={t('groupPerformanceScreen.payments.sectionTitle')} note={t('groupPerformanceScreen.payments.note')} />
              {(data.payments as any[]).map((p: any, i: number) => (
                <MetricRow
                  key={i}
                  icon={p.tipo === 'retiro' ? '💸' : '🎉'}
                  label={p.label}
                  sub={fmtDate(p.fecha)}
                  value={fmtMoney(p.amount)}
                  pill={
                    p.estado === 'released' || p.estado === 'paid' || p.estado === 'completed'
                      ? { kind: 'ok', label: p.tipo === 'retiro' ? t('groupPerformanceScreen.payments.paidStatus') : t('groupPerformanceScreen.payments.releasedStatus') }
                      : p.estado === 'held' || p.estado === 'pending'
                        ? { kind: 'warn', label: t('groupPerformanceScreen.payments.pendingStatus') }
                        : { kind: 'warn', label: p.estado }
                  }
                />
              ))}
            </>
          )}

          {/* ── 💬 Comentarios recientes ── */}
          {(data?.reviews ?? []).length > 0 && (
            <>
              <SectionHeader title={t('groupPerformanceScreen.reviews.sectionTitle')} />
              {(data.reviews as any[]).map((rv: any, i: number) => (
                <View key={i} style={s.revCard}>
                  <View style={s.revHead}>
                    <Text style={s.revName}>{rv.cliente}</Text>
                    <View style={{ flexDirection: 'row', gap: 1 }}>
                      {Array.from({ length: 5 }, (_, j) => (
                        <Star
                          key={j} size={11}
                          color={COLORS.gold}
                          fill={j < (rv.rating ?? 0) ? COLORS.gold : 'transparent'}
                        />
                      ))}
                    </View>
                    <Text style={s.revDate}>{fmtDate(rv.fecha)}</Text>
                  </View>
                  <Text style={s.revTx}>"{rv.comment}"</Text>
                </View>
              ))}
            </>
          )}

          <View style={{ height: 40 }} />
        </ScrollView>
      )}
    </View>
  );
}

// ─── Estilos ──────────────────────────────────────────────────────────────────
const s = StyleSheet.create({
  root: { flex: 1, backgroundColor: COLORS.bg },
  header: {
    flexDirection: 'row', alignItems: 'center', gap: 10,
    paddingHorizontal: SPACING.md, paddingBottom: SPACING.sm,
    borderBottomWidth: 1, borderBottomColor: COLORS.border,
  },
  backBtn: { width: 40, height: 40, alignItems: 'center', justifyContent: 'center' },
  headerTitle: { fontFamily: FONTS.title, fontSize: 17, color: COLORS.text },
  headerSub: { fontFamily: FONTS.body, fontSize: 10.5, color: COLORS.muted },
  exportBtn: {
    flexDirection: 'row', alignItems: 'center', gap: 6,
    backgroundColor: COLORS.green, borderRadius: RADIUS.lg,
    paddingHorizontal: 13, paddingVertical: 9,
  },
  exportTx: { fontFamily: FONTS.bodySemiBold, fontSize: 12.5, color: '#000' },
  center: { flex: 1, alignItems: 'center', justifyContent: 'center' },
  scroll: { paddingHorizontal: SPACING.md, paddingTop: SPACING.md },

  rangeRow: { flexDirection: 'row', gap: 7, marginBottom: 10 },
  rangeChip: {
    borderRadius: RADIUS.full, borderWidth: 1, borderColor: COLORS.border,
    backgroundColor: COLORS.card, paddingHorizontal: 11, paddingVertical: 6,
  },
  rangeChipOn: { borderColor: 'rgba(0,230,118,0.5)', backgroundColor: COLORS.greenMuted },
  rangeTx: { fontFamily: FONTS.bodyMedium, fontSize: 11, color: COLORS.muted2 },
  rangeTxOn: { color: COLORS.green },

  grid: { flexDirection: 'row', flexWrap: 'wrap', gap: 9 },

  cityWrap: { flexDirection: 'row', flexWrap: 'wrap', gap: 7 },
  cityChip: {
    borderRadius: RADIUS.full, borderWidth: 1, borderColor: COLORS.border,
    backgroundColor: COLORS.card, paddingHorizontal: 11, paddingVertical: 6,
  },
  cityTx: { fontFamily: FONTS.bodyMedium, fontSize: 11.5, color: COLORS.muted2 },

  revCard: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border,
    padding: 12, marginBottom: 8,
  },
  revHead: { flexDirection: 'row', alignItems: 'center', gap: 8 },
  revName: { fontFamily: FONTS.bodySemiBold, fontSize: 12.5, color: COLORS.text },
  revDate: { marginLeft: 'auto', fontFamily: FONTS.body, fontSize: 10, color: COLORS.muted },
  revTx: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, lineHeight: 17, marginTop: 6 },
});
