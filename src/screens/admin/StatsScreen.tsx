/**
 * AdminStatsScreen — Estadísticas avanzadas de la plataforma.
 * 6 tabs: Plataforma · Usuarios · Comercial · Finanzas · Riesgo · Inteligencia
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
  AlertTriangle, ArrowLeft, DollarSign, Globe, TrendingUp, Users, Zap,
} from 'lucide-react-native';
import { supabase } from '../../config/supabase';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';

// ─── Helpers ─────────────────────────────────────────────────────────────────

function fmt(n: number) {
  return n.toLocaleString('es-MX', { minimumFractionDigits: 0, maximumFractionDigits: 0 });
}
function fmtM(n: number) { return `$${fmt(n)}`; }
function pct(n: number)  { return `${Math.round(n)}%`; }

// ─── Sub-components ───────────────────────────────────────────────────────────

function StatCard({ label, value, sub, color = COLORS.green, wide = false }: any) {
  return (
    <View style={[c.statCard, wide && { flex: undefined, width: '100%' }]}>
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
  const p = max > 0 ? Math.min(100, (value / max) * 100) : 0;
  return (
    <View style={c.progressBg}>
      <View style={[c.progressFill, { width: `${p}%` as any, backgroundColor: color }]} />
    </View>
  );
}

function BarChartV({ data, color = COLORS.green }: { data: { label: string; value: number }[]; color?: string }) {
  const max = Math.max(...data.map(d => d.value), 1);
  return (
    <View style={c.chartRow}>
      {data.map((d, i) => (
        <View key={i} style={c.chartBar}>
          <Text style={c.chartVal}>{d.value > 0 ? (d.value >= 1000 ? `${(d.value / 1000).toFixed(0)}k` : String(d.value)) : ''}</Text>
          <View style={[c.chartFill, { height: Math.max(4, (d.value / max) * 60), backgroundColor: color }]} />
          <Text style={c.chartLabel}>{d.label}</Text>
        </View>
      ))}
    </View>
  );
}

function RankRow({ rank, label, value, sub }: any) {
  const medals = ['🥇', '🥈', '🥉'];
  return (
    <View style={c.rankRow}>
      <Text style={c.rankMedal}>{medals[rank - 1] ?? `#${rank}`}</Text>
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
  { label: 'Plataforma',   icon: Globe },
  { label: 'Usuarios',     icon: Users },
  { label: 'Comercial',    icon: TrendingUp },
  { label: 'Finanzas',     icon: DollarSign },
  { label: 'Riesgo',       icon: AlertTriangle },
  { label: 'Inteligencia', icon: Zap },
];

// ─── Screen ───────────────────────────────────────────────────────────────────

export default function AdminStatsScreen({ navigation }: any) {
  const [activeTab, setActiveTab] = useState(0);
  const [loading,   setLoading]   = useState(true);
  const [refreshing, setRefreshing] = useState(false);

  // ── Data ─────────────────────────────────────────────────────────────────
  const [reservations, setReservations] = useState<any[]>([]);
  const [profiles,     setProfiles]     = useState<any[]>([]);
  const [groups,       setGroups]       = useState<any[]>([]);
  const [quotes,       setQuotes]       = useState<any[]>([]);
  const [topGroups,    setTopGroups]    = useState<any[]>([]);
  const [riskGroups,   setRiskGroups]   = useState<any[]>([]);
  const [topCities,    setTopCities]    = useState<any[]>([]);
  const [monthly,      setMonthly]      = useState<any[]>([]);
  const [platformStats, setPlatformStats] = useState<any>(null);
  const [marketGaps,    setMarketGaps]    = useState<any[]>([]);
  const [loyaltyMetrics, setLoyaltyMetrics] = useState<any>(null);
  // Wallet transactions del admin (fuente única de verdad financiera)
  const [walletTx,       setWalletTx]       = useState<any[]>([]);
  // Bid orders pagados
  const [bidOrders,      setBidOrders]      = useState<any[]>([]);
  // Wallet balance real del admin
  const [adminWallet,    setAdminWallet]    = useState<any>(null);
  // Top grupos que generan ingresos (ads + bidding + recomendaciones)
  const [topPayingGroups, setTopPayingGroups] = useState<any[]>([]);
  // Recommendation orders pagadas (para cityRanking)
  const [recOrders,      setRecOrders]      = useState<any[]>([]);

  useEffect(() => { loadAll(); }, []);

  const onRefresh = async () => { setRefreshing(true); await loadAll(); setRefreshing(false); };

  const loadAll = async () => {
    setLoading(true);
    const [resRes, profRes, grpRes, quotesRes, topGrpRes, riskRes, citiesRes, monthRes, statsRes, gapsRes, loyRes, wtRes, bidRes, walletRes, adsGroupRes, recOrdRes] = await Promise.all([
      supabase.from('reservations')
        .select('status, total_price, commission_amount, group_earnings, event_date, created_at, group_id'),
      supabase.from('profiles')
        .select('role, created_at, id'),
      supabase.from('groups')
        .select('id, name, rating, is_active, city, created_at'),
      supabase.from('quotes')
        .select('status, created_at'),
      supabase.rpc('get_top_groups_earnings', { p_limit: 5 }),
      supabase.rpc('get_risk_groups', { p_limit: 5 }),
      supabase.rpc('get_events_by_city', { p_limit: 5 }),
      supabase.rpc('get_platform_monthly_stats', { p_months: 6 }),
      supabase.rpc('get_admin_platform_stats', { p_days_back: 30 }),
      supabase.rpc('get_platform_gaps', { p_days_back: 30, p_limit: 8 }),
      supabase.rpc('get_loyalty_metrics', { p_days_back: 30 }),
      // Fuente única de verdad: wallet_transactions del admin (plataforma)
      supabase.from('wallet_transactions')
        .select('type, amount, created_at, reference_id, description')
        .in('type', ['platform_income', 'ad_income', 'bid_income', 'recommendation_income'])
        .eq('status', 'completed'),
      // Bids pagados con ciudad (para ingresos por ciudad)
      supabase.from('bid_orders')
        .select('amount, created_at, group_id, groups(city, name)')
        .eq('status', 'paid'),
      // Wallet balance del admin actual
      supabase.from('wallets')
        .select('available_balance, total_earned')
        .limit(1)
        .maybeSingle(),
      // Ads pagados por grupo (solo link_id + precio — sin join FK incierto)
      supabase.from('advertisements')
        .select('link_id, type, ad_packages(price)')
        .in('status', ['active', 'approved', 'expired', 'pending_review'])
        .not('link_id', 'is', null),
      // Recommendation orders pagadas (para cityRanking + topPayingGroups)
      supabase.from('recommendation_orders')
        .select('amount, group_id, city, groups(name)')
        .eq('status', 'paid'),
    ]);

    setReservations(resRes.data ?? []);
    setProfiles(profRes.data ?? []);
    setGroups(grpRes.data ?? []);
    setQuotes(quotesRes.data ?? []);
    setTopGroups(topGrpRes.data ?? []);
    setRiskGroups(riskRes.data ?? []);
    setTopCities(citiesRes.data ?? []);
    setMonthly(monthRes.data ?? []);
    setPlatformStats(statsRes.data ?? null);
    setMarketGaps(gapsRes.data ?? []);
    setLoyaltyMetrics((loyRes.data as any)?.[0] ?? null);
    setWalletTx(wtRes.data ?? []);
    setBidOrders(bidRes.data ?? []);
    setAdminWallet(walletRes.data ?? null);
    setRecOrders(recOrdRes.data ?? []);

    // Construir top grupos que pagan: combinar ads + bids + recomendaciones por group_id
    const grpMap: Record<string, string> = {};
    (grpRes.data ?? []).forEach((g: any) => { grpMap[g.id] = g.name; });

    const groupPay: Record<string, { name: string; ads: number; bids: number; recs: number }> = {};
    (adsGroupRes.data ?? []).forEach((a: any) => {
      if (!a.link_id) return;
      const gid   = a.link_id;
      const name  = grpMap[gid] ?? gid;
      const price = Number((a.ad_packages as any)?.price ?? 0);
      if (!groupPay[gid]) groupPay[gid] = { name, ads: 0, bids: 0, recs: 0 };
      groupPay[gid].ads += price;
    });
    (bidRes.data ?? []).forEach((b: any) => {
      const gid  = b.group_id;
      const name = grpMap[gid] ?? (b.groups as any)?.name ?? gid;
      if (!groupPay[gid]) groupPay[gid] = { name, ads: 0, bids: 0, recs: 0 };
      groupPay[gid].bids += Number(b.amount ?? 0);
    });
    (recOrdRes.data ?? []).forEach((r: any) => {
      const gid  = r.group_id;
      const name = grpMap[gid] ?? (r.groups as any)?.name ?? gid;
      if (!groupPay[gid]) groupPay[gid] = { name, ads: 0, bids: 0, recs: 0 };
      groupPay[gid].recs += Number(r.amount ?? 0);
    });
    const ranked = Object.entries(groupPay)
      .map(([id, v]) => ({
        id,
        name:  v.name,
        city:  (grpRes.data ?? []).find((g: any) => g.id === id)?.city ?? 'Sin ciudad',
        ads:   v.ads,
        bids:  v.bids,
        recs:  v.recs,
        total: v.ads + v.bids + v.recs,
      }))
      .sort((a, b) => b.total - a.total)
      .slice(0, 5);
    setTopPayingGroups(ranked);
    console.log('[WALLET] resumen', {
      txCount:    wtRes.data?.length ?? 0,
      topGrupos:  ranked.length,
      walletDB:   walletRes.data?.available_balance ?? 'n/a',
    });
    setLoading(false);
  };

  // ── Calculations ─────────────────────────────────────────────────────────
  const now        = new Date();
  const monthStart = new Date(now.getFullYear(), now.getMonth(), 1).toISOString();

  const todayStart = new Date(now.getFullYear(), now.getMonth(), now.getDate()).toISOString();

  const completed  = reservations.filter(r => r.status === 'completed');
  const pending    = reservations.filter(r => ['pending','pending_payment','pending_group_confirmation','accepted'].includes(r.status));
  const cancelled  = reservations.filter(r => ['cancelled','rejected'].includes(r.status));

  const completedThisMonth = completed.filter(r => r.event_date >= monthStart.split('T')[0]);
  const totalRevenue       = completed.reduce((s, r) => s + (r.total_price ?? 0), 0);
  const totalCommission    = completed.reduce((s, r) => s + (r.commission_amount ?? 0), 0);
  const revenueThisMonth   = completedThisMonth.reduce((s, r) => s + (r.total_price ?? 0), 0);

  // Commission projection kept for legacy tabs
  const daysElapsed = now.getDate();

  // Growth (compare this month vs last month events)
  const lastMonthStart = new Date(now.getFullYear(), now.getMonth() - 1, 1).toISOString().split('T')[0];
  const lastMonthEnd   = new Date(now.getFullYear(), now.getMonth(), 0).toISOString().split('T')[0];
  const lastMonthCount = completed.filter(r => r.event_date >= lastMonthStart && r.event_date <= lastMonthEnd).length;
  const thisMonthCount = completedThisMonth.length;
  const growth = lastMonthCount > 0 ? ((thisMonthCount - lastMonthCount) / lastMonthCount) * 100 : 0;

  // Users
  const totalClients = profiles.filter(p => p.role === 'client').length;
  const totalTalents = profiles.filter(p => p.role === 'talent').length;
  const totalGroupP  = profiles.filter(p => p.role === 'group').length;
  const totalGroups  = groups.length;
  const activeGroups = groups.filter(g => g.is_active).length;

  const newProfilesThisMonth = profiles.filter(p => p.created_at >= monthStart).length;
  const newGroupsThisMonth   = groups.filter(g => g.created_at >= monthStart).length;

  // Quotes
  const quotesRespondedTotal  = quotes.filter(q => q.status !== 'pending');
  const quotesAcceptedTotal   = quotes.filter(q => q.status === 'accepted');
  const globalConvRate        = quotesRespondedTotal.length > 0
    ? (quotesAcceptedTotal.length / quotesRespondedTotal.length) * 100 : 0;

  // ── Wallet (fuente única) ─────────────────────────────────────────────────
  const wtEvents  = walletTx.filter(t => t.type === 'platform_income');
  const wtAds     = walletTx.filter(t => t.type === 'ad_income');
  const wtBids    = walletTx.filter(t => t.type === 'bid_income');
  const wtRec     = walletTx.filter(t => t.type === 'recommendation_income');

  const sumWt = (list: any[]) => list.reduce((s, t) => s + Number(t.amount ?? 0), 0);

  // Totales históricos
  const walletEvents  = sumWt(wtEvents);
  const walletAds     = sumWt(wtAds);
  const walletBids    = sumWt(wtBids);
  const walletRec     = sumWt(wtRec);
  const walletTotal   = walletEvents + walletAds + walletBids + walletRec;

  // Este mes
  const walletEventsMonth = sumWt(wtEvents.filter(t => t.created_at >= monthStart));
  const walletAdsMonth    = sumWt(wtAds.filter(t => t.created_at >= monthStart));
  const walletBidsMonth   = sumWt(wtBids.filter(t => t.created_at >= monthStart));
  const walletRecMonth    = sumWt(wtRec.filter(t => t.created_at >= monthStart));
  const walletTotalMonth  = walletEventsMonth + walletAdsMonth + walletBidsMonth + walletRecMonth;

  // Hoy / semana
  const walletToday  = sumWt(walletTx.filter(t => t.created_at >= todayStart));

  // Proyección mensual (usa daysElapsed ya declarado arriba)
  const walletProjection = daysElapsed > 0 ? Math.round((walletTotalMonth / daysElapsed) * 30) : 0;

  // Publicidad desglosada por tipo
  const adsByType: Record<string, number> = {};
  wtAds.forEach(t => {
    const key = t.description?.includes('banner_home')     ? 'banner_home'
              : t.description?.includes('sponsored_group') ? 'sponsored_group'
              : t.description?.includes('profile_ad')      ? 'profile_ad'
              : 'otros';
    adsByType[key] = (adsByType[key] ?? 0) + Number(t.amount ?? 0);
  });

  // Mapa rápido id→grupo para lookups sin iteración
  const groupMap = new Map(groups.map(g => [g.id, g]));

  // Ingresos por ciudad — FUENTE ÚNICA: wallet_transactions + bids + recs (tienen ciudad)
  const cityData: Record<string, { events: number; commission: number; ads: number; bids: number; recs: number }> = {};
  const ensureCity = (c: string) => {
    if (!cityData[c]) cityData[c] = { events: 0, commission: 0, ads: 0, bids: 0, recs: 0 };
  };

  // Eventos → comisión desde reservations (bruto real)
  completed.forEach(r => {
    const city = groupMap.get(r.group_id)?.city ?? 'Sin ciudad';
    ensureCity(city);
    cityData[city].events     += 1;
    cityData[city].commission += Number(r.commission_amount ?? 0);
  });

  // Bids → ciudad del grupo
  bidOrders.forEach(b => {
    const city = (b.groups as any)?.city ?? groupMap.get(b.group_id)?.city ?? 'Sin ciudad';
    ensureCity(city);
    cityData[city].bids += Number(b.amount ?? 0);
  });

  // Publicidad → ciudad del grupo (desde topPayingGroups que ya tiene city)
  topPayingGroups.forEach(g => {
    if (g.ads > 0) {
      ensureCity(g.city);
      cityData[g.city].ads += g.ads;
    }
  });

  // Recomendaciones → ciudad del recommendation_order
  recOrders.forEach((r: any) => {
    const city = r.city ?? groupMap.get(r.group_id)?.city ?? 'Sin ciudad';
    ensureCity(city);
    cityData[city].recs += Number(r.amount ?? 0);
  });

  const cityRanking = Object.entries(cityData).map(([city, d]) => ({
    city,
    events:     d.events,
    commission: d.commission,
    ads:        d.ads,
    bids:       d.bids,
    recs:       d.recs,
    total:      d.commission + d.ads + d.bids + d.recs,
  })).sort((a, b) => b.total - a.total).slice(0, 8);

  const maxCityIncome = cityRanking[0]?.total ?? 1;

  // ── Alertas inteligentes (últimos 7 días vs 7 días anteriores) ────────────
  const week1Start = new Date(now.getTime() - 7  * 86400000).toISOString(); // hace 7 días
  const week2Start = new Date(now.getTime() - 14 * 86400000).toISOString(); // hace 14 días

  const wtThisWeek = walletTx.filter(t => t.created_at >= week1Start);
  const wtLastWeek = walletTx.filter(t => t.created_at >= week2Start && t.created_at < week1Start);

  const thisWeekTotal = sumWt(wtThisWeek);
  const lastWeekTotal = sumWt(wtLastWeek);
  const thisWeekAds   = sumWt(wtThisWeek.filter(t => t.type === 'ad_income'));
  const lastWeekAds   = sumWt(wtLastWeek.filter(t => t.type === 'ad_income'));
  const thisWeekBids  = sumWt(wtThisWeek.filter(t => t.type === 'bid_income'));
  const lastWeekBids  = sumWt(wtLastWeek.filter(t => t.type === 'bid_income'));

  const weekDrop     = lastWeekTotal > 0 && thisWeekTotal < lastWeekTotal * 0.85;
  const adsBoom      = lastWeekAds   > 0 ? thisWeekAds  > lastWeekAds  * 1.2 : thisWeekAds > 0;
  const biddingBoom  = lastWeekBids  > 0 ? thisWeekBids > lastWeekBids * 1.2 : thisWeekBids > 0;
  const weekChangePct = lastWeekTotal > 0
    ? Math.round(((thisWeekTotal - lastWeekTotal) / lastWeekTotal) * 100) : 0;

  const alerts: { icon: string; text: string; color: string }[] = [];
  if (weekDrop)    alerts.push({ icon: '⚠️', text: `Ingresos bajaron ${Math.abs(weekChangePct)}% esta semana`, color: COLORS.red });
  if (adsBoom)     alerts.push({ icon: '🔥', text: 'Publicidad creciendo esta semana', color: COLORS.gold });
  if (biddingBoom) alerts.push({ icon: '⚡', text: 'Bidding subiendo esta semana', color: '#A78BFA' });
  if (!weekDrop && !adsBoom && !biddingBoom && lastWeekTotal > 0)
    alerts.push({ icon: '✅', text: `Ingresos estables esta semana (${weekChangePct >= 0 ? '+' : ''}${weekChangePct}%)`, color: COLORS.green });

  console.log('[WALLET]', { total: walletTotal, eventos: walletEvents, publicidad: walletAds, bidding: walletBids, recomendaciones: walletRec });

  // Chart data
  const revenueChart   = monthly.map(m => ({ label: m.period, value: Number(m.revenue) }));
  const commChart      = monthly.map(m => ({ label: m.period, value: Number(m.commission) }));

  // Fill missing months
  const fillChartData = (data: any[]) => {
    if (data.length === 0) {
      const filled: any[] = [];
      for (let i = 5; i >= 0; i--) {
        const d = new Date(now.getFullYear(), now.getMonth() - i, 1);
        filled.push({ label: d.toLocaleDateString('es-MX', { month: 'short' }), value: 0 });
      }
      return filled;
    }
    return data;
  };

  const maxCityCount = topCities[0]?.event_count ?? 1;

  // ── Render ───────────────────────────────────────────────────────────────
  return (
    <View style={c.root}>
      <SafeAreaView edges={['top']} style={c.header}>
        <Pressable style={c.backBtn} onPress={() => navigation.goBack()}>
          <ArrowLeft size={20} color={COLORS.text} />
        </Pressable>
        <Text style={c.headerTitle}>Estadísticas Admin</Text>
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

          {/* ══ TAB 0: PLATAFORMA ══ */}
          {activeTab === 0 && (
            <View>
              <View style={c.statsGrid}>
                <StatCard label="Eventos totales"   value={completed.length}          sub="Completados" />
                <StatCard label="Este mes"           value={completedThisMonth.length} sub="Completados" color={COLORS.blue} />
                <StatCard label="Ingresos brutos"    value={fmtM(totalRevenue)}        sub="Pagado por clientes" />
                <StatCard label="Ganancia plataforma" value={fmtM(walletTotal)}        sub="Wallet real" color={COLORS.orange} />
              </View>

              <View style={c.card}>
                <SectionTitle title="Crecimiento y rendimiento" />
                <Row2 label="Crecimiento mensual"    value={`${growth >= 0 ? '+' : ''}${pct(growth)}`}
                  color={growth >= 0 ? COLORS.green : COLORS.red} />
                <Row2 label="Comisión este mes"        value={fmtM(walletEventsMonth)} color={COLORS.green} />
                <Row2 label="Publicidad este mes"    value={fmtM(walletAdsMonth)} color={COLORS.gold} />
                <Row2 label="Bidding este mes"       value={fmtM(walletBidsMonth)} color="#A78BFA" />
                <Row2 label="⭐ Recom. este mes"     value={fmtM(walletRecMonth)} color="#FCD34D" />
                <Row2 label="Ingreso total (mes)"    value={fmtM(walletTotalMonth)} color={COLORS.green} />
                <Row2 label="Reservas pendientes"    value={String(pending.length)} color={COLORS.orange} />
                <Row2 label="Reservas canceladas"    value={String(cancelled.length)} color={COLORS.red} />
                <Row2 label="Total reservas"         value={String(reservations.length)} />
                {platformStats && <>
                  <Row2 label="Solicitudes express (30d)"  value={String(platformStats.express_requests ?? 0)} color={COLORS.blue} />
                  <Row2 label="Conversión express"         value={pct(platformStats.express_conversion ?? 0)}  color={COLORS.gold} />
                  <Row2 label="Nuevos clientes (30d)"      value={String(platformStats.new_clients ?? 0)}      color={COLORS.green} />
                  <Row2 label="Nuevos grupos (30d)"        value={String(platformStats.new_groups ?? 0)}       color={COLORS.blue} />
                </>}
              </View>

              <View style={c.card}>
                <SectionTitle title="Últimos 6 meses" />
                <View style={{ flexDirection: 'row', gap: 16, marginBottom: 8 }}>
                  <View style={{ flexDirection: 'row', alignItems: 'center', gap: 5 }}>
                    <View style={{ width: 10, height: 10, borderRadius: 2, backgroundColor: COLORS.green }} />
                    <Text style={c.chartLegend}>Ingresos</Text>
                  </View>
                  <View style={{ flexDirection: 'row', alignItems: 'center', gap: 5 }}>
                    <View style={{ width: 10, height: 10, borderRadius: 2, backgroundColor: COLORS.orange }} />
                    <Text style={c.chartLegend}>Comisiones</Text>
                  </View>
                </View>
                <BarChartV data={fillChartData(revenueChart)} />
                <BarChartV data={fillChartData(commChart)} color={COLORS.orange} />
              </View>
            </View>
          )}

          {/* ══ TAB 1: USUARIOS ══ */}
          {activeTab === 1 && (
            <View>
              <View style={c.statsGrid}>
                <StatCard label="Grupos"    value={totalGroups}  color={COLORS.green} />
                <StatCard label="Talentos"  value={totalTalents} color={COLORS.blue} />
                <StatCard label="Clientes"  value={totalClients} color={COLORS.orange} />
                <StatCard label="Activos"   value={activeGroups} sub="Grupos" color={COLORS.green} />
              </View>

              <View style={c.card}>
                <SectionTitle title="Nuevos registros este mes" />
                <Row2 label="Usuarios nuevos (todos los roles)" value={String(newProfilesThisMonth)} color={COLORS.green} />
                <Row2 label="Grupos nuevos"                     value={String(newGroupsThisMonth)} color={COLORS.blue} />
              </View>

              <View style={c.card}>
                <SectionTitle title="Distribución de usuarios" />
                <View style={{ marginBottom: 10 }}>
                  <View style={c.row2}><Text style={c.row2Label}>Clientes</Text><Text style={[c.row2Val, { color: COLORS.orange }]}>{totalClients}</Text></View>
                  <ProgressBar value={totalClients} max={profiles.length || 1} color={COLORS.orange} />
                </View>
                <View style={{ marginBottom: 10 }}>
                  <View style={c.row2}><Text style={c.row2Label}>Talentos</Text><Text style={[c.row2Val, { color: COLORS.blue }]}>{totalTalents}</Text></View>
                  <ProgressBar value={totalTalents} max={profiles.length || 1} color={COLORS.blue} />
                </View>
                <View style={{ marginBottom: 10 }}>
                  <View style={c.row2}><Text style={c.row2Label}>Grupos (dueños)</Text><Text style={[c.row2Val, { color: COLORS.green }]}>{totalGroupP}</Text></View>
                  <ProgressBar value={totalGroupP} max={profiles.length || 1} color={COLORS.green} />
                </View>
              </View>

              {loyaltyMetrics && (
                <View style={c.card}>
                  <SectionTitle title="Fidelización de clientes" />
                  <Row2 label="Clientes con puntos"    value={String(loyaltyMetrics.total_loyalty_clients ?? 0)} color={COLORS.green} />
                  <Row2 label="🥈 Plata"               value={String(loyaltyMetrics.silver_clients ?? 0)} />
                  <Row2 label="🥇 Oro"                 value={String(loyaltyMetrics.gold_clients ?? 0)} color={COLORS.gold} />
                  <Row2 label="💎 VIP"                 value={String(loyaltyMetrics.vip_clients ?? 0)} color="#A78BFA" />
                  <Row2 label="Promedio eventos/cliente" value={Number(loyaltyMetrics.avg_events_per_client ?? 0).toFixed(1)} />
                  <Row2 label="% Clientes recurrentes"  value={pct(Number(loyaltyMetrics.repeat_rate_pct ?? 0))} color={COLORS.blue} />
                  <Row2 label="Puntos otorgados (30d)"  value={String(loyaltyMetrics.points_awarded_period ?? 0)} />
                  <Row2 label="Ingresos gold+VIP"       value={pct(Number(loyaltyMetrics.top_tier_revenue_pct ?? 0))} color={COLORS.gold} />
                </View>
              )}
            </View>
          )}

          {/* ══ TAB 2: COMERCIAL ══ */}
          {activeTab === 2 && (
            <View>
              <View style={c.card}>
                <SectionTitle title="Cotizaciones globales" />
                <Row2 label="Total enviadas"     value={String(quotes.length)} />
                <Row2 label="Respondidas"        value={String(quotesRespondedTotal.length)} />
                <Row2 label="Aceptadas"          value={String(quotesAcceptedTotal.length)} color={COLORS.green} />
                <Row2 label="% Conversión global" value={pct(globalConvRate)} color={globalConvRate >= 50 ? COLORS.green : COLORS.orange} />
              </View>

              <View style={c.card}>
                <SectionTitle title="Promedio por evento" />
                <Row2 label="Ingreso promedio por evento" value={fmtM(completed.length > 0 ? Math.round(totalRevenue / completed.length) : 0)} />
                <Row2 label="Comisión promedio" value={fmtM(completed.length > 0 ? Math.round(totalCommission / completed.length) : 0)} color={COLORS.orange} />
                <Row2 label="Total eventos completados" value={String(completed.length)} />
              </View>

              {topCities.length > 0 && (
                <View style={c.card}>
                  <SectionTitle title="Ciudades con más eventos" />
                  {topCities.map((item: any, i: number) => (
                    <View key={i} style={{ marginBottom: 10 }}>
                      <View style={c.row2}>
                        <Text style={c.row2Label}>📍 {item.city}</Text>
                        <Text style={c.row2Val}>{item.event_count} eventos</Text>
                      </View>
                      <ProgressBar value={Number(item.event_count)} max={Number(maxCityCount)} />
                    </View>
                  ))}
                </View>
              )}
            </View>
          )}

          {/* ══ TAB 3: FINANZAS ══ */}
          {activeTab === 3 && (
            <View>

              {/* ── 0. Alertas inteligentes ── */}
              {alerts.length > 0 && (
                <View style={c.alertsCard}>
                  {alerts.map((a, i) => (
                    <View key={i} style={[c.alertRow, { borderLeftColor: a.color }]}>
                      <Text style={c.alertIcon}>{a.icon}</Text>
                      <Text style={[c.alertText, { color: a.color }]}>{a.text}</Text>
                    </View>
                  ))}
                </View>
              )}

              {/* ── 1. KPIs principales ── */}
              <View style={c.statsGrid}>
                <StatCard label="💰 Ingresos hoy"      value={fmtM(walletToday)}      color={COLORS.green} />
                <StatCard label="📈 Ingresos mes"       value={fmtM(walletTotalMonth)} color={COLORS.blue} />
                <StatCard label="💵 Ganancia neta total" value={fmtM(walletTotal)}      color={COLORS.green} sub="Eventos+Ads+Bids" wide />
                <StatCard label="🚀 Proyección mes"     value={fmtM(walletProjection)} color={COLORS.gold} wide />
              </View>

              {/* ── 1b. Ganancia neta — solo desglose, sin repetir el total ── */}
              <View style={c.card}>
                <SectionTitle title="💵 Desglose ganancia neta" />
                <Row2 label="Eventos (comisión 8%)"  value={fmtM(walletEvents)}      color={COLORS.green} />
                <Row2 label="Publicidad"              value={fmtM(walletAds)}         color={COLORS.gold} />
                <Row2 label="Bidding"                 value={fmtM(walletBids)}        color="#A78BFA" />
                <Row2 label="⭐ Recomendaciones"      value={fmtM(walletRec)}         color="#FCD34D" />
                <View style={{ borderTopWidth: 1, borderTopColor: COLORS.border, marginTop: 8, paddingTop: 8 }}>
                  <Row2 label="Este mes (total)"      value={fmtM(walletTotalMonth)}  color={COLORS.green} />
                </View>
              </View>

              {/* ── 1c. Billetera plataforma — calculada desde wallet_transactions ── */}
              <View style={c.card}>
                <SectionTitle title="🏦 Billetera plataforma" />
                {/* Balance = SUM(wallet_transactions) — fuente de verdad, nunca $0 */}
                <Row2 label="Balance disponible"   value={fmtM(walletTotal)}  color={COLORS.green} />
                <Row2 label="Ingresos hoy"         value={fmtM(walletToday)}  color={COLORS.green} />
                <Row2 label="Ingresos esta semana" value={fmtM(thisWeekTotal)} />
                <Row2 label="Total transacciones"  value={String(walletTx.length)} />
                {adminWallet && (
                  <Row2 label="DB balance (tabla wallets)"
                    value={fmtM(Number(adminWallet.available_balance ?? 0))}
                    color={Math.abs(Number(adminWallet.available_balance ?? 0) - walletTotal) < 1
                      ? COLORS.green : COLORS.orange}
                  />
                )}
              </View>

              {/* ── 2. Ingresos por fuente ── */}
              <View style={c.card}>
                <SectionTitle title="Ingresos por fuente" />

                <Text style={c.sourceHeader}>📅 EVENTOS</Text>
                <Row2 label="Comisiones totales"    value={fmtM(walletEvents)}      color={COLORS.green} />
                <Row2 label="Comisiones este mes"   value={fmtM(walletEventsMonth)} color={COLORS.green} />
                <Row2 label="Ingresos brutos"       value={fmtM(totalRevenue)} />
                <Row2 label="Ticket promedio"
                  value={completed.length > 0 ? fmtM(Math.round(totalRevenue / completed.length)) : '—'} />

                <Text style={[c.sourceHeader, { marginTop: 14 }]}>📢 PUBLICIDAD</Text>
                <Row2 label="Total publicidad"      value={fmtM(walletAds)}      color={COLORS.gold} />
                <Row2 label="Publicidad este mes"   value={fmtM(walletAdsMonth)} color={COLORS.gold} />
                {Object.entries(adsByType).map(([type, amt]) => (
                  <Row2
                    key={type}
                    label={`  · ${type === 'banner_home' ? 'Banners home' : type === 'sponsored_group' ? 'Grupos destacados' : type === 'profile_ad' ? 'Anuncios perfil' : 'Otros'}`}
                    value={fmtM(amt)}
                    color={COLORS.muted2}
                  />
                ))}
                {walletAds === 0 && <Row2 label="  · Aún sin pagos confirmados de publicidad" value="$0" color={COLORS.muted} />}

                <Text style={[c.sourceHeader, { marginTop: 14 }]}>🔥 BIDDING</Text>
                <Row2 label="Total posicionamiento"  value={fmtM(walletBids)}      color="#A78BFA" />
                <Row2 label="Bidding este mes"        value={fmtM(walletBidsMonth)} color="#A78BFA" />
                {walletBids === 0 && <Row2 label="  · Aún sin pagos de bidding" value="$0" color={COLORS.muted} />}

                <Text style={[c.sourceHeader, { marginTop: 14 }]}>⭐ RECOMENDACIONES</Text>
                <Row2 label="Total recomendaciones"   value={fmtM(walletRec)}      color="#FCD34D" />
                <Row2 label="Recomendaciones este mes" value={fmtM(walletRecMonth)} color="#FCD34D" />
                <Row2 label="  · Transacciones"       value={String(wtRec.length)} color={COLORS.muted2} />
                {walletRec === 0 && <Row2 label="  · Aún sin recomendaciones pagadas" value="$0" color={COLORS.muted} />}
              </View>

              {/* ── 2b. Top grupos por ingresos ── */}
              <View style={c.card}>
                <SectionTitle title="🏆 Top grupos que más pagan" />
                {topPayingGroups.length === 0 ? (
                  <Text style={c.emptyTxt}>Sin datos aún</Text>
                ) : topPayingGroups.map((g, i) => {
                  const medals = ['🥇', '🥈', '🥉', '#4', '#5'];
                  return (
                    <View key={g.id} style={c.rankRow}>
                      <Text style={c.rankMedal}>{medals[i]}</Text>
                      <View style={{ flex: 1 }}>
                        <Text style={c.rankLabel} numberOfLines={1}>{g.name}</Text>
                        <View style={{ flexDirection: 'row', gap: 8, marginTop: 2 }}>
                          {g.ads  > 0 && <Text style={[c.cityMeta, { color: COLORS.gold }]}>Ads {fmtM(g.ads)}</Text>}
                          {g.bids > 0 && <Text style={[c.cityMeta, { color: '#A78BFA' }]}>Bid {fmtM(g.bids)}</Text>}
                          {(g as any).recs > 0 && <Text style={[c.cityMeta, { color: '#FCD34D' }]}>Reco. {fmtM((g as any).recs)}</Text>}
                        </View>
                      </View>
                      <Text style={c.rankVal}>{fmtM(g.total)}</Text>
                    </View>
                  );
                })}
              </View>

              {/* ── 3. Ingresos por ciudad ── */}
              <View style={c.card}>
                <SectionTitle title="Ingresos por ciudad" />
                {cityRanking.length === 0 ? (
                  <Text style={c.emptyTxt}>Sin datos de ciudad disponibles</Text>
                ) : cityRanking.map((item, i) => (
                  <View key={i} style={{ marginBottom: 12 }}>
                    <View style={c.row2}>
                      <Text style={c.row2Label}>📍 {item.city}</Text>
                      <Text style={[c.row2Val, { color: COLORS.green }]}>{fmtM(item.total)}</Text>
                    </View>
                    <View style={{ flexDirection: 'row', gap: 8, marginTop: 3, flexWrap: 'wrap' }}>
                      <Text style={c.cityMeta}>{item.events} eventos · {fmtM(item.commission)}</Text>
                      {item.ads  > 0 && <Text style={[c.cityMeta, { color: COLORS.gold }]}>· Ads {fmtM(item.ads)}</Text>}
                      {item.bids > 0 && <Text style={[c.cityMeta, { color: '#A78BFA' }]}>· Bid {fmtM(item.bids)}</Text>}
                      {(item as any).recs > 0 && <Text style={[c.cityMeta, { color: '#FCD34D' }]}>· Reco. {fmtM((item as any).recs)}</Text>}
                    </View>
                    <ProgressBar value={item.total} max={maxCityIncome} />
                  </View>
                ))}
              </View>

              {/* ── 4. Eventos (negocio) ── */}
              <View style={c.card}>
                <SectionTitle title="Eventos" />
                <Row2 label="Completados"          value={String(completed.length)} color={COLORS.green} />
                <Row2 label="Activos ahora"        value={String(reservations.filter(r => r.status === 'in_progress').length)} color={COLORS.blue} />
                <Row2 label="Cancelados / rechazados" value={String(cancelled.length)} color={COLORS.red} />
                <Row2 label="Pendientes de pago"   value={String(pending.length)} color={COLORS.orange} />
                <Row2 label="Ingresos brutos este mes" value={fmtM(revenueThisMonth)} />
              </View>

              {/* ── 5. Conversión ── */}
              <View style={c.card}>
                <SectionTitle title="Conversión" />
                <Row2 label="% Cotizaciones → eventos" value={pct(globalConvRate)} color={globalConvRate >= 50 ? COLORS.green : COLORS.orange} />
                {platformStats && <>
                  <Row2 label="Conversión express"     value={pct(platformStats.express_conversion ?? 0)} color={COLORS.gold} />
                  <Row2 label="Nuevos clientes (30d)"  value={String(platformStats.new_clients ?? 0)} color={COLORS.green} />
                  <Row2 label="Nuevos grupos (30d)"    value={String(platformStats.new_groups ?? 0)} color={COLORS.blue} />
                </>}
              </View>

              {/* ── 6. Gráficas ── */}
              <View style={c.card}>
                <SectionTitle title="Tendencia últimos 6 meses" />
                <View style={{ flexDirection: 'row', gap: 16, marginBottom: 8 }}>
                  <View style={{ flexDirection: 'row', alignItems: 'center', gap: 5 }}>
                    <View style={{ width: 10, height: 10, borderRadius: 2, backgroundColor: COLORS.green }} />
                    <Text style={c.chartLegend}>Ingresos totales</Text>
                  </View>
                  <View style={{ flexDirection: 'row', alignItems: 'center', gap: 5 }}>
                    <View style={{ width: 10, height: 10, borderRadius: 2, backgroundColor: COLORS.orange }} />
                    <Text style={c.chartLegend}>Comisiones</Text>
                  </View>
                </View>
                <BarChartV data={fillChartData(revenueChart)} />
                <BarChartV data={fillChartData(commChart)} color={COLORS.orange} />
              </View>

            </View>
          )}

          {/* ══ TAB 4: RIESGO ══ */}
          {activeTab === 4 && (
            <View>
              {riskGroups.length > 0 ? (
                <View style={c.card}>
                  <SectionTitle title="Grupos con más cancelaciones" />
                  {riskGroups.map((g: any, i: number) => (
                    <View key={i} style={c.rankRow}>
                      <View style={[c.riskBadge, { backgroundColor: i === 0 ? 'rgba(239,83,80,0.15)' : 'rgba(255,152,0,0.1)' }]}>
                        <AlertTriangle size={12} color={i === 0 ? COLORS.red : COLORS.orange} />
                      </View>
                      <View style={{ flex: 1 }}>
                        <Text style={c.rankLabel}>{g.group_name}</Text>
                      </View>
                      <Text style={[c.rankVal, { color: COLORS.red }]}>{g.cancellation_count} cancel.</Text>
                    </View>
                  ))}
                </View>
              ) : (
                <View style={c.card}>
                  <Text style={c.emptyTxt}>Sin grupos con cancelaciones registradas 🎉</Text>
                </View>
              )}

              <View style={c.card}>
                <SectionTitle title="Resumen de riesgo" />
                <Row2 label="Total cancelaciones / rechazos" value={String(cancelled.length)} color={COLORS.red} />
                <Row2 label="% Tasa cancelación global"
                  value={pct(reservations.length > 0 ? (cancelled.length / reservations.length) * 100 : 0)}
                  color={COLORS.orange}
                />
                <Row2 label="Eventos actualmente activos"    value={String(reservations.filter(r => r.status === 'in_progress').length)} color={COLORS.green} />
                <Row2 label="Reservas totales"               value={String(reservations.length)} />
              </View>
            </View>
          )}

          {/* ══ TAB 5: INTELIGENCIA ══ */}
          {activeTab === 5 && (
            <View>
              {topGroups.length > 0 && (
                <View style={c.card}>
                  <SectionTitle title="Top grupos por ingresos" />
                  {topGroups.map((g: any, i: number) => (
                    <RankRow
                      key={i}
                      rank={i + 1}
                      label={g.group_name}
                      sub={`${g.event_count} eventos`}
                      value={fmtM(Number(g.total_earnings))}
                    />
                  ))}
                </View>
              )}

              <View style={c.card}>
                <SectionTitle title="Top grupos por rating" />
                {groups
                  .filter(g => g.rating != null)
                  .sort((a, b) => b.rating - a.rating)
                  .slice(0, 5)
                  .map((g, i) => (
                    <RankRow
                      key={i}
                      rank={i + 1}
                      label={g.name}
                      sub={g.city ?? ''}
                      value={`★ ${Number(g.rating).toFixed(1)}`}
                    />
                  ))
                }
                {groups.filter(g => g.rating != null).length === 0 && (
                  <Text style={c.emptyTxt}>Sin ratings registrados aún</Text>
                )}
              </View>

              {topCities.length > 0 && (
                <View style={c.card}>
                  <SectionTitle title="Eventos por ciudad" />
                  {topCities.map((item: any, i: number) => (
                    <RankRow
                      key={i}
                      rank={i + 1}
                      label={item.city}
                      value={`${item.event_count} eventos`}
                    />
                  ))}
                </View>
              )}

              {marketGaps.length > 0 && (
                <View style={c.card}>
                  <SectionTitle title="Oportunidades de mercado" />
                  {marketGaps.map((gap: any, i: number) => {
                    const levelColor: Record<string, string> = {
                      sin_grupos: COLORS.red,
                      critica:    COLORS.red,
                      alta:       COLORS.orange,
                      moderada:   COLORS.gold,
                    };
                    const col = levelColor[gap.gap_level] ?? COLORS.muted2;
                    return (
                      <View key={i} style={c.rankRow}>
                        <View style={{ flex: 1 }}>
                          <Text style={c.rankLabel}>{gap.city} · {gap.genre}</Text>
                          <Text style={c.rankSub}>{gap.demand_count} solicitudes · {gap.supply_count} grupos</Text>
                        </View>
                        <Text style={[c.rankVal, { color: col, fontSize: 11 }]}>{gap.gap_level.replace('_', ' ')}</Text>
                      </View>
                    );
                  })}
                </View>
              )}

              <View style={c.card}>
                <SectionTitle title="KPIs estratégicos" />
                <Row2 label="Promedio eventos / grupo activo"
                  value={activeGroups > 0 ? String(Math.round(completed.length / activeGroups)) : '—'}
                />
                <Row2 label="% Grupos activos"
                  value={pct(totalGroups > 0 ? (activeGroups / totalGroups) * 100 : 0)}
                  color={COLORS.green}
                />
                <Row2 label="Ingreso promedio por evento" value={fmtM(completed.length > 0 ? Math.round(totalRevenue / completed.length) : 0)} />
                <Row2 label="Comisión promedio"           value={fmtM(completed.length > 0 ? Math.round(totalCommission / completed.length) : 0)} />
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
  center:      { flex: 1, alignItems: 'center', justifyContent: 'center' },
  scroll:      { padding: SPACING.xl, gap: 16 },

  tabBar:        { borderBottomWidth: 1, borderBottomColor: COLORS.border },
  tabBarContent: { paddingHorizontal: SPACING.xl, gap: 2, alignItems: 'center' },
  tab:           { flexDirection: 'row', alignItems: 'center', gap: 5, paddingHorizontal: 14, paddingVertical: 14 },
  tabActive:     { borderBottomWidth: 2, borderBottomColor: COLORS.green },
  tabText:       { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.muted2 },
  tabTextActive: { color: COLORS.green },

  card: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.xl,
    borderWidth: 1, borderColor: COLORS.border, padding: SPACING.lg,
  },
  statsGrid: { flexDirection: 'row', gap: 12, flexWrap: 'wrap' },
  statCard: {
    flex: 1, minWidth: '45%', backgroundColor: COLORS.card, borderRadius: RADIUS.xl,
    borderWidth: 1, borderColor: COLORS.border, padding: SPACING.lg,
    alignItems: 'center',
  },
  statVal:   { fontFamily: FONTS.title, fontSize: 20, color: COLORS.green, marginBottom: 4, textAlign: 'center' },
  statLabel: { fontFamily: FONTS.bodyMedium, fontSize: 11, color: COLORS.muted2, textAlign: 'center' },
  statSub:   { fontFamily: FONTS.body, fontSize: 10, color: COLORS.muted, marginTop: 2 },

  sectionTitle: {
    fontFamily: FONTS.bodySemiBold, fontSize: 11, color: COLORS.muted2,
    textTransform: 'uppercase', letterSpacing: 1, marginBottom: 14,
  },
  row2:      { flexDirection: 'row', justifyContent: 'space-between', paddingVertical: 7, borderBottomWidth: 1, borderBottomColor: COLORS.border },
  row2Label: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2 },
  row2Val:   { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.text },

  progressBg:   { height: 6, backgroundColor: COLORS.border, borderRadius: 3, overflow: 'hidden', marginTop: 4 },
  progressFill: { height: '100%', borderRadius: 3 },

  chartRow:  { flexDirection: 'row', alignItems: 'flex-end', height: 90, gap: 4, paddingTop: 10 },
  chartBar:  { flex: 1, alignItems: 'center', justifyContent: 'flex-end', gap: 4 },
  chartFill: { width: '80%', borderRadius: 3 },
  chartVal:  { fontFamily: FONTS.body, fontSize: 8, color: COLORS.muted, textAlign: 'center' },
  chartLabel:  { fontFamily: FONTS.body, fontSize: 9, color: COLORS.muted2 },
  chartLegend: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted2 },

  rankRow:   { flexDirection: 'row', alignItems: 'center', gap: 12, paddingVertical: 8, borderBottomWidth: 1, borderBottomColor: COLORS.border },
  rankMedal: { fontSize: 18, width: 28, textAlign: 'center' },
  rankLabel: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.text },
  rankSub:   { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted2 },
  rankVal:   { fontFamily: FONTS.title, fontSize: 14, color: COLORS.green },

  riskBadge: { width: 28, height: 28, borderRadius: 8, alignItems: 'center', justifyContent: 'center' },
  emptyTxt:  { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted, textAlign: 'center', paddingVertical: 20 },
  sourceHeader: { fontFamily: FONTS.bodySemiBold, fontSize: 11, color: COLORS.muted2, textTransform: 'uppercase' as const, letterSpacing: 0.8, marginTop: 4, marginBottom: 6 },
  cityMeta: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted2 },
  alertsCard: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.xl,
    borderWidth: 1, borderColor: COLORS.border,
    padding: SPACING.lg, gap: 8,
  },
  alertRow: {
    flexDirection: 'row', alignItems: 'center', gap: 8,
    borderLeftWidth: 3, paddingLeft: 10, paddingVertical: 4,
  },
  alertIcon: { fontSize: 16 },
  alertText: { fontFamily: FONTS.bodyMedium, fontSize: 13, flex: 1 },
});
