/**
 * GroupStatsScreen — Estadísticas avanzadas del grupo.
 * 5 tabs: Resumen · Finanzas · Comercial · Reputación · Zona
 */
import React, { useEffect, useState } from 'react';
import {
  ActivityIndicator,
  Pressable,
  RefreshControl,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import {
  ArrowLeft, BarChart2, DollarSign, MapPin, Star, TrendingUp,
} from 'lucide-react-native';
import { supabase } from '../../config/supabase';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';

// ─── Helpers ─────────────────────────────────────────────────────────────────

function fmt(n: number) {
  return n.toLocaleString('es-MX', { minimumFractionDigits: 0, maximumFractionDigits: 0 });
}
function fmtM(n: number) {
  return `$${fmt(n)}`;
}
function pct(n: number) {
  return `${Math.round(n)}%`;
}

// ─── Sub-components ───────────────────────────────────────────────────────────

function StatCard({ label, value, sub, color = COLORS.green }: any) {
  return (
    <View style={c.statCard}>
      <Text style={[c.statVal, { color }]}>{value}</Text>
      <Text style={c.statLabel}>{label}</Text>
      {sub ? <Text style={c.statSub}>{sub}</Text> : null}
    </View>
  );
}

function Row2({ label, value, color }: { label: string; value: string; color?: string }) {
  return (
    <View style={c.row2}>
      <Text style={c.row2Label}>{label}</Text>
      <Text style={[c.row2Val, color ? { color } : null]}>{value}</Text>
    </View>
  );
}

function SectionTitle({ title }: { title: string }) {
  return <Text style={c.sectionTitle}>{title}</Text>;
}

function ProgressBar({ value, max, color = COLORS.green }: { value: number; max: number; color?: string }) {
  const pct = max > 0 ? Math.min(100, (value / max) * 100) : 0;
  return (
    <View style={c.progressBg}>
      <View style={[c.progressFill, { width: `${pct}%` as any, backgroundColor: color }]} />
    </View>
  );
}

function BarChartV({ data }: { data: { label: string; value: number }[] }) {
  const max     = Math.max(...data.map(d => d.value), 1);
  const lastIdx = data.length - 1;
  return (
    <View style={c.chartRow}>
      {data.map((d, i) => {
        const isCurrent = i === lastIdx;
        const barColor  = isCurrent ? COLORS.green : '#2e2e2e';
        const valColor  = isCurrent ? COLORS.green : COLORS.muted;
        const lblColor  = isCurrent ? COLORS.green : COLORS.muted2;
        return (
          <View key={i} style={c.chartBar}>
            <Text style={[c.chartVal, { color: valColor }]}>
              {d.value > 0 ? `$${d.value >= 1000 ? `${(d.value / 1000).toFixed(0)}k` : d.value}` : ''}
            </Text>
            <View style={[c.chartFill, { height: Math.max(4, (d.value / max) * 60), backgroundColor: barColor }]} />
            <Text style={[c.chartLabel, { color: lblColor }]}>{d.label}</Text>
          </View>
        );
      })}
    </View>
  );
}

function RankRow({ rank, label, value, sub }: any) {
  return (
    <View style={c.rankRow}>
      <Text style={c.rankNum}>{rank}</Text>
      <View style={{ flex: 1 }}>
        <Text style={c.rankLabel}>{label}</Text>
        {sub ? <Text style={c.rankSub}>{sub}</Text> : null}
      </View>
      <Text style={c.rankVal}>{value}</Text>
    </View>
  );
}

// ─── TABS ─────────────────────────────────────────────────────────────────────

const TABS = [
  { label: 'Resumen',    icon: BarChart2 },
  { label: 'Finanzas',   icon: DollarSign },
  { label: 'Comercial',  icon: TrendingUp },
  { label: 'Reputación', icon: Star },
  { label: 'Zona',       icon: MapPin },
];

// ─── Screen ───────────────────────────────────────────────────────────────────

export default function GroupStatsScreen({ navigation }: any) {
  const [activeTab, setActiveTab] = useState(0);
  const [loading,   setLoading]   = useState(true);
  const [refreshing, setRefreshing] = useState(false);

  // ── Data states ──────────────────────────────────────────────────────────
  const [reservations, setReservations] = useState<any[]>([]);
  const [quotes,       setQuotes]       = useState<any[]>([]);
  const [group,        setGroup]        = useState<any>(null);
  const [monthlyData,  setMonthlyData]  = useState<any[]>([]);

  useEffect(() => { loadAll(); }, []);

  const onRefresh = async () => { setRefreshing(true); await loadAll(); setRefreshing(false); };

  const loadAll = async () => {
    setLoading(true);
    const { data: grpRaw } = await supabase.rpc('get_my_group').maybeSingle();
    if (!grpRaw) { setLoading(false); return; }
    const grp = grpRaw as any;

    const [resRes, quotesRes, grpRes, monthRes] = await Promise.all([
      supabase.from('reservations')
        .select('status, payment_status, payout_status, group_earnings, commission_amount, service_fee_amount, msi_fee_amount, total_price, event_date, event_time, package_id, created_at')
        .eq('group_id', grp.id),
      supabase.from('quotes')
        .select('status, created_at')
        .eq('group_id', grp.id),
      supabase.from('groups')
        .select('name, rating, nivel, reputation_points, city, country')
        .eq('id', grp.id)
        .single(),
      supabase.rpc('get_group_monthly_earnings', { p_group_id: grp.id, p_months: 6 }),
    ]);

    setReservations(resRes.data ?? []);
    setQuotes(quotesRes.data ?? []);
    setGroup(grpRes.data);
    setMonthlyData(monthRes.data ?? []);
    setLoading(false);
  };

  // ── Calculations ─────────────────────────────────────────────────────────
  const completed   = reservations.filter(r => r.status === 'completed');
  // For financial calculations: all reservations where money was collected
  const paid = reservations.filter(r =>
    r.payment_status === 'paid' || r.payment_status === 'fully_paid' || r.payment_status === 'deposit_paid'
  );
  const now         = new Date();
  const monthStart  = new Date(now.getFullYear(), now.getMonth(), 1);

  const completedThisMonth   = completed.filter(r => new Date(r.event_date) >= monthStart);
  const paidThisMonth        = paid.filter(r => new Date(r.created_at) >= monthStart);
  const totalEarnings        = paid.reduce((s, r) => s + (r.group_earnings ?? 0), 0);
  const earningsThisMonth    = paidThisMonth.reduce((s, r) => s + (r.group_earnings ?? 0), 0);
  // service_fee_amount is set by trigger; commission_amount is legacy fallback
  const totalCommission      = paid.reduce((s, r) => s + (r.service_fee_amount ?? r.commission_amount ?? 0), 0);
  const grossIncome          = paid.reduce((s, r) => s + (r.total_price ?? 0) + (r.msi_fee_amount ?? 0), 0);
  const avgPerEvent          = paid.length > 0 ? totalEarnings / paid.length : 0;

  const totalRes         = reservations.length;
  const acceptedCount    = reservations.filter(r => ['accepted','confirmed','in_progress','completed'].includes(r.status)).length;
  const cancelledCount   = reservations.filter(r => ['cancelled','rejected'].includes(r.status)).length;
  const acceptanceRate   = totalRes > 0 ? (acceptedCount / totalRes) * 100 : 0;
  const cancellationRate = totalRes > 0 ? (cancelledCount / totalRes) * 100 : 0;

  // Avg per hour (assume 3h per event as default)
  const totalHours = paid.length * 3;
  const avgPerHour = totalHours > 0 ? totalEarnings / totalHours : 0;

  // Best month from monthly data
  const bestMonth = monthlyData.length > 0
    ? monthlyData.reduce((best, m) => Number(m.earnings) > Number(best.earnings) ? m : best, monthlyData[0])
    : null;

  // Quotes stats
  const quotesResponded  = quotes.filter(q => q.status !== 'pending');
  const quotesAccepted   = quotes.filter(q => q.status === 'accepted');
  const convRate         = quotesResponded.length > 0 ? (quotesAccepted.length / quotesResponded.length) * 100 : 0;


  // Most popular hour
  const hourCounts: Record<string, number> = {};
  completed.forEach(r => {
    if (r.event_time) {
      const h = r.event_time.split(':')[0];
      hourCounts[h] = (hourCounts[h] ?? 0) + 1;
    }
  });
  const topHour = Object.entries(hourCounts).sort((a, b) => b[1] - a[1])[0];
  const topHourLabel = topHour ? `${topHour[0]}:00 hrs` : 'Sin datos';

  // Most popular day
  const dayNames = ['Dom', 'Lun', 'Mar', 'Mié', 'Jue', 'Vie', 'Sáb'];
  const dayCounts: Record<string, number> = {};
  completed.forEach(r => {
    if (r.event_date) {
      const d = dayNames[new Date(r.event_date + 'T12:00:00').getDay()];
      dayCounts[d] = (dayCounts[d] ?? 0) + 1;
    }
  });
  const topDay = Object.entries(dayCounts).sort((a, b) => b[1] - a[1])[0]?.[0] ?? 'Sin datos';

  // Zone: top locations
  const cityCounts: Record<string, number> = {};
  reservations.filter(r => r.status === 'completed').forEach(r => {
    if (r.address) {
      // Take the last part of the address as approximate city
      const parts = r.address.split(',');
      const city = parts[parts.length - 1]?.trim() ?? 'Desconocido';
      cityCounts[city] = (cityCounts[city] ?? 0) + 1;
    }
  });
  const topCities = Object.entries(cityCounts)
    .sort((a, b) => b[1] - a[1])
    .slice(0, 5)
    .map(([city, count]) => ({ city, count }));

  const maxCityCount = topCities[0]?.count ?? 1;

  // Chart data
  const chartData = monthlyData.map(m => ({ label: m.period, value: Number(m.earnings) }));
  // Fill missing months with 0 if less than 6 months
  if (chartData.length === 0) {
    for (let i = 5; i >= 0; i--) {
      const d = new Date(now.getFullYear(), now.getMonth() - i, 1);
      chartData.push({ label: d.toLocaleDateString('es-MX', { month: 'short' }), value: 0 });
    }
  }

  // ── Render ───────────────────────────────────────────────────────────────
  return (
    <View style={c.root}>
      <SafeAreaView edges={['top']} style={c.header}>
        <Pressable style={c.backBtn} onPress={() => navigation.goBack()}>
          <ArrowLeft size={20} color={COLORS.text} />
        </Pressable>
        <Text style={c.headerTitle}>Estadísticas</Text>
        <View style={{ width: 40 }} />
      </SafeAreaView>

      {/* Tab bar */}
      <ScrollView
        horizontal
        showsHorizontalScrollIndicator={false}
        style={c.tabBar}
        contentContainerStyle={c.tabBarContent}
      >
        {TABS.map((tab, i) => {
          const Icon = tab.icon;
          const active = activeTab === i;
          return (
            <Pressable key={i} style={[c.tab, active && c.tabActive]} onPress={() => setActiveTab(i)}>
              <Icon size={13} color={active ? COLORS.green : COLORS.muted2} />
              <Text style={[c.tabText, active && c.tabTextActive]}>{tab.label}</Text>
            </Pressable>
          );
        })}
      </ScrollView>

      {loading ? (
        <View style={c.center}>
          <ActivityIndicator size="large" color={COLORS.green} />
        </View>
      ) : (
        <ScrollView contentContainerStyle={c.scroll} showsVerticalScrollIndicator={false} refreshControl={<RefreshControl refreshing={refreshing} onRefresh={onRefresh} tintColor={COLORS.green} />}>

          {/* ══ TAB 0: RESUMEN ══ */}
          {activeTab === 0 && (
            <View>
              <View style={c.statsGrid}>
                <StatCard label="Eventos totales"   value={completed.length}           sub="Completados" />
                <StatCard label="Este mes"           value={completedThisMonth.length}  sub="Completados" color={COLORS.blue} />
                <StatCard label="Ingresos totales"   value={fmtM(totalEarnings)}        sub="Retenido + liberado" />
                <StatCard label="Este mes"           value={fmtM(earningsThisMonth)}    sub="Retenido + liberado" color={COLORS.blue} />
              </View>

              <View style={c.card}>
                <SectionTitle title="Rendimiento general" />
                <Row2 label="Nivel actual" value={group?.nivel ?? 'Bronce'} color={COLORS.gold} />
                <Row2 label="Rating promedio" value={group?.rating != null ? `★ ${Number(group.rating).toFixed(1)}` : 'Sin reseñas'} color={COLORS.gold} />
                <Row2 label="Puntos de reputación" value={fmt(group?.reputation_points ?? 0)} color={COLORS.green} />
                <Row2 label="Tasa de aceptación" value={pct(acceptanceRate)} color={acceptanceRate >= 70 ? COLORS.green : COLORS.orange} />
                <Row2 label="Tasa de cancelación" value={pct(cancellationRate)} color={cancellationRate > 20 ? COLORS.red : COLORS.muted2} />
                <Row2 label="Reservas totales" value={String(totalRes)} />
                <Row2 label="Cotizaciones enviadas" value={String(quotes.length)} />
              </View>
            </View>
          )}

          {/* ══ TAB 1: FINANZAS ══ */}
          {activeTab === 1 && (
            <View>
              <View style={c.card}>
                <SectionTitle title="Resumen financiero" />
                <Row2 label="Total bruto generado"    value={fmtM(grossIncome)} />
                <Row2 label="Comisiones pagadas"       value={fmtM(totalCommission)} color={COLORS.red} />
                <Row2 label="Total neto ganado"        value={fmtM(totalEarnings)} color={COLORS.green} />
                <Row2 label="Promedio por evento"      value={fmtM(Math.round(avgPerEvent))} color={COLORS.green} />
                <Row2 label="Promedio por hora"        value={fmtM(Math.round(avgPerHour))} />
                {bestMonth && (
                  <Row2 label="Mes más fuerte"
                    value={`${bestMonth.period} — ${fmtM(Number(bestMonth.earnings))}`}
                    color={COLORS.gold}
                  />
                )}
              </View>

              <View style={c.card}>
                <SectionTitle title="Ingresos mensuales (últimos 6 meses)" />
                {chartData.every(d => d.value === 0) ? (
                  <Text style={c.emptyTxt}>Sin reservas pagadas aún</Text>
                ) : (
                  <BarChartV data={chartData} />
                )}
              </View>

              <View style={c.statsGrid}>
                <StatCard label="Reservas pagadas" value={paid.length} />
                <StatCard label="Ganancia total"   value={fmtM(totalEarnings)} sub="neta" />
              </View>
            </View>
          )}

          {/* ══ TAB 2: COMERCIAL ══ */}
          {activeTab === 2 && (
            <View>
              <View style={c.card}>
                <SectionTitle title="Cotizaciones" />
                <Row2 label="Solicitudes recibidas"   value={String(quotes.length)} />
                <Row2 label="Respondidas"              value={String(quotesResponded.length)} />
                <Row2 label="Aceptadas por cliente"    value={String(quotesAccepted.length)} color={COLORS.green} />
                <Row2 label="% Conversión"             value={pct(convRate)} color={convRate >= 50 ? COLORS.green : COLORS.orange} />
              </View>

              <View style={c.card}>
                <SectionTitle title="Rendimiento comercial" />
                <Row2 label="Hora más solicitada"   value={topHourLabel} />
                <Row2 label="Día más solicitado"    value={topDay} color={COLORS.green} />
              </View>
            </View>
          )}

          {/* ══ TAB 3: REPUTACIÓN ══ */}
          {activeTab === 3 && (
            <View>
              <View style={[c.card, c.ratingHero]}>
                <Text style={c.ratingBig}>
                  {group?.rating != null ? Number(group.rating).toFixed(1) : '—'}
                </Text>
                <Text style={c.ratingStars}>
                  {group?.rating != null
                    ? '★'.repeat(Math.round(group.rating)) + '☆'.repeat(5 - Math.round(group.rating))
                    : '☆☆☆☆☆'}
                </Text>
                <Text style={c.ratingLabel}>Calificación promedio</Text>
              </View>

              <View style={c.card}>
                <SectionTitle title="Nivel y reputación" />
                <Row2 label="Nivel actual"           value={group?.nivel ?? 'Bronce'} color={COLORS.gold} />
                <Row2 label="Puntos acumulados"      value={fmt(group?.reputation_points ?? 0)} color={COLORS.green} />
                <Row2 label="Eventos completados"    value={String(completed.length)} color={COLORS.green} />
                <Row2 label="Eventos cancelados"     value={String(cancelledCount)} color={cancelledCount > 0 ? COLORS.red : COLORS.muted2} />
                <Row2 label="Ciudad base"            value={group?.city ?? 'No registrada'} />
              </View>

              <View style={c.card}>
                <SectionTitle title="Tasas de rendimiento" />
                <Text style={c.progressLabel}>Tasa de aceptación</Text>
                <ProgressBar value={acceptanceRate} max={100} color={acceptanceRate >= 70 ? COLORS.green : COLORS.orange} />
                <View style={c.row2}><Text style={c.row2Label} /><Text style={[c.row2Val, { color: COLORS.green }]}>{pct(acceptanceRate)}</Text></View>

                <Text style={[c.progressLabel, { marginTop: 12 }]}>Tasa de cancelación</Text>
                <ProgressBar value={cancellationRate} max={100} color={cancellationRate > 20 ? COLORS.red : COLORS.green} />
                <View style={c.row2}><Text style={c.row2Label} /><Text style={[c.row2Val, { color: cancellationRate > 20 ? COLORS.red : COLORS.muted2 }]}>{pct(cancellationRate)}</Text></View>
              </View>
            </View>
          )}

          {/* ══ TAB 4: ZONA ══ */}
          {activeTab === 4 && (
            <View>
              <View style={c.card}>
                <SectionTitle title="Zona base del grupo" />
                <Row2 label="Ciudad" value={group?.city ?? 'No registrada'} color={COLORS.green} />
                <Row2 label="País"   value={group?.country ?? 'México'} />
              </View>

              <View style={c.card}>
                <SectionTitle title="Ubicaciones frecuentes" />
                {topCities.length === 0 ? (
                  <Text style={c.emptyTxt}>Sin eventos registrados aún</Text>
                ) : (
                  topCities.map((item, i) => (
                    <View key={i} style={{ marginBottom: 12 }}>
                      <View style={c.row2}>
                        <Text style={c.row2Label}>📍 {item.city}</Text>
                        <Text style={c.row2Val}>{item.count} eventos</Text>
                      </View>
                      <ProgressBar value={item.count} max={maxCityCount} />
                    </View>
                  ))
                )}
              </View>

              <View style={c.statsGrid}>
                <StatCard label="Total eventos"   value={completed.length}     sub="Completados" />
                <StatCard label="Ciudades"         value={topCities.length}     sub="Distintas" color={COLORS.blue} />
              </View>
            </View>
          )}

          <View style={{ height: 40 }} />
        </ScrollView>
      )}
    </View>
  );
}

// ─── Styles ───────────────────────────────────────────────────────────────────

const c = StyleSheet.create({
  root:   { flex: 1, backgroundColor: COLORS.bg },
  header: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between',
    paddingHorizontal: SPACING.xl, paddingVertical: 12,
    borderBottomWidth: 1, borderBottomColor: COLORS.border,
  },
  backBtn: {
    width: 40, height: 40, borderRadius: 12,
    backgroundColor: COLORS.card, borderWidth: 1, borderColor: COLORS.border,
    alignItems: 'center', justifyContent: 'center',
  },
  headerTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 17, color: COLORS.text },
  center: { flex: 1, alignItems: 'center', justifyContent: 'center' },
  scroll: { padding: SPACING.xl, gap: 16 },

  // Tab bar
  tabBar:        { borderBottomWidth: 1, borderBottomColor: COLORS.border, maxHeight: 48 },
  tabBarContent: { paddingHorizontal: SPACING.xl, gap: 4, alignItems: 'center' },
  tab: {
    flexDirection: 'row', alignItems: 'center', gap: 5,
    paddingHorizontal: 14, paddingVertical: 12,
  },
  tabActive:     { borderBottomWidth: 2, borderBottomColor: COLORS.green },
  tabText:       { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.muted2 },
  tabTextActive: { color: COLORS.green },

  // Cards
  card: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.xl,
    borderWidth: 1, borderColor: COLORS.border, padding: SPACING.lg,
  },
  statsGrid: { flexDirection: 'row', flexWrap: 'wrap', gap: 10 },
  statCard: {
    flexBasis: '48%', flexGrow: 1,
    backgroundColor: COLORS.card, borderRadius: RADIUS.xl,
    borderWidth: 1, borderColor: COLORS.border, padding: 14,
    alignItems: 'center',
  },
  statVal:   { fontFamily: FONTS.title, fontSize: 20, color: COLORS.green, marginBottom: 3 },
  statLabel: { fontFamily: FONTS.bodyMedium, fontSize: 11, color: COLORS.muted2, textAlign: 'center' },
  statSub:   { fontFamily: FONTS.body, fontSize: 10, color: COLORS.muted, marginTop: 2 },

  sectionTitle: {
    fontFamily: FONTS.bodySemiBold, fontSize: 11, color: COLORS.muted2,
    textTransform: 'uppercase', letterSpacing: 1, marginBottom: 14,
  },
  row2: { flexDirection: 'row', justifyContent: 'space-between', paddingVertical: 7, borderBottomWidth: 1, borderBottomColor: COLORS.border },
  row2Label: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2 },
  row2Val:   { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.text },

  progressBg:   { height: 6, backgroundColor: COLORS.border, borderRadius: 3, overflow: 'hidden', marginTop: 4 },
  progressFill: { height: '100%', borderRadius: 3 },
  progressLabel: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, marginTop: 4 },

  // Chart
  chartRow: { flexDirection: 'row', alignItems: 'flex-end', height: 90, gap: 4, paddingTop: 10 },
  chartBar:  { flex: 1, alignItems: 'center', justifyContent: 'flex-end', gap: 4 },
  chartFill: { width: '80%', borderRadius: 3 },
  chartVal:  { fontFamily: FONTS.body, fontSize: 8, color: COLORS.muted, textAlign: 'center' },
  chartLabel: { fontFamily: FONTS.body, fontSize: 9, color: COLORS.muted2 },

  // Rank
  rankRow: { flexDirection: 'row', alignItems: 'center', gap: 12, paddingVertical: 8, borderBottomWidth: 1, borderBottomColor: COLORS.border },
  rankNum:   { fontFamily: FONTS.title, fontSize: 18, color: COLORS.muted, width: 24, textAlign: 'center' },
  rankLabel: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.text },
  rankSub:   { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted2 },
  rankVal:   { fontFamily: FONTS.title, fontSize: 15, color: COLORS.green },

  // Rating hero
  ratingHero:  { alignItems: 'center', paddingVertical: 24 },
  ratingBig:   { fontFamily: FONTS.title, fontSize: 72, color: COLORS.gold },
  ratingStars: { fontSize: 24, color: COLORS.gold, marginBottom: 8 },
  ratingLabel: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2 },

  emptyTxt: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted, textAlign: 'center', paddingVertical: 20 },
});
