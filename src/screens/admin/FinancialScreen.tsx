import {
  ArrowLeft,
  AlertCircle,
  CheckCircle,
  Clock,
  DollarSign,
  Minus,
  TrendingUp,
  X,
  Zap,
} from 'lucide-react-native';
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
import { supabase } from '../../config/supabase';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';
import Particles from '../../components/ui/Particles';
import { calcGroupEarnings, calcServiceFee } from '../../utils/calculations';

// ─── Types ────────────────────────────────────────────────────────────────────

interface FinancialOverview {
  total_facturado:  number;
  ganancia_bruta:   number;
  stripe_fees:      number;
  mercadopago_fees: number;
  ganancia_neta:    number;
  artistas_payout:  number;
  event_count:      number;
}

interface EventFinancial {
  reservation_id:      string;
  event_date:          string | null;
  group_name:          string | null;
  event_total:         number;
  platform_fee:        number;
  stripe_fee:          number;
  mercadopago_fee:     number;
  net_platform_profit: number;
  artists_payout:      number;
  created_at:          string;
}

interface Payout {
  id:                 string;
  user_id:            string | null;
  reservation_id:     string | null;
  stripe_transfer_id: string | null;
  amount:             number;
  payout_type:        string | null;
  status:             string;
  created_at:         string;
  profile?:           { full_name: string | null };
}

type DateFilter = '7d' | '30d' | '90d' | 'all';
type TabView    = 'overview' | 'events' | 'transfers' | 'ads';

const DATE_OPTIONS: { label: string; value: DateFilter }[] = [
  { label: '7 días',  value: '7d' },
  { label: '30 días', value: '30d' },
  { label: '90 días', value: '90d' },
  { label: 'Todo',    value: 'all' },
];

function dateFrom(filter: DateFilter): string | null {
  if (filter === 'all') return null;
  const days = filter === '7d' ? 7 : filter === '30d' ? 30 : 90;
  const d = new Date();
  d.setDate(d.getDate() - days);
  return d.toISOString();
}

function daysFrom(filter: DateFilter): number | null {
  if (filter === 'all') return null;
  return filter === '7d' ? 7 : filter === '30d' ? 30 : 90;
}

// ─── Component ────────────────────────────────────────────────────────────────

export default function AdminFinancialScreen({ navigation }: any) {
  const [overview, setOverview]         = useState<FinancialOverview | null>(null);
  const [eventFinancials, setEventFins] = useState<EventFinancial[]>([]);
  const [payouts, setPayouts]           = useState<Payout[]>([]);
  const [adIncome, setAdIncome]         = useState<any[]>([]);
  const [filter, setFilter]             = useState<DateFilter>('30d');
  const [activeTab, setActiveTab]       = useState<TabView>('overview');
  const [loading, setLoading]           = useState(true);
  const [refreshing, setRefreshing]     = useState(false);

  useEffect(() => { load(); }, [filter]);

  const load = async (isRefresh = false) => {
    if (isRefresh) setRefreshing(true);
    else setLoading(true);
    try {
      await Promise.all([fetchOverview(), fetchEventFinancials(), fetchPayouts(), fetchAdIncome()]);
    } finally {
      setLoading(false);
      setRefreshing(false);
    }
  };

  // ── Resumen financiero (RPC con fallback directo) ────────────────────────
  const fetchOverview = async () => {
    const days = daysFrom(filter);
    const { data, error: rpcErr } = await supabase.rpc('get_admin_financial_overview', {
      p_days: days,
    });
    if (data) {
      setOverview(data as FinancialOverview);
      return;
    }
    if (rpcErr) console.warn('[FinancialScreen] RPC error:', rpcErr.message);

    // Fallback directo desde reservations (incluye stripe_fee_amount real)
    const from = dateFrom(filter);
    let q = supabase
      .from('reservations')
      .select('total_price, group_earnings, service_fee_amount, commission_amount, msi_fee_amount, base_price, stripe_fee_amount, payment_status')
      .in('payment_status', ['paid', 'fully_paid', 'deposit_paid']);
    if (from) q = q.gte('created_at', from);
    const { data: rows } = await q;
    const paid = rows ?? [];

    const totalRevenue  = paid.reduce((s: number, r: any) => s + (r.total_price ?? 0) + (r.msi_fee_amount ?? 0), 0);
    const totalComm     = paid.reduce((s: number, r: any) =>
      s + (r.service_fee_amount ?? r.commission_amount ?? calcServiceFee(r.total_price ?? 0)) + (r.msi_fee_amount ?? 0), 0);
    const totalArtists  = paid.reduce((s: number, r: any) =>
      s + (r.group_earnings ?? r.base_price ?? calcGroupEarnings(r.total_price ?? 0)), 0);
    const totalStripe   = paid.reduce((s: number, r: any) => {
      const total = (r.total_price ?? 0) + (r.msi_fee_amount ?? 0);
      return s + (r.stripe_fee_amount ?? Math.round(total * 0.036 + 3));
    }, 0);

    setOverview({
      total_facturado:  totalRevenue,
      ganancia_bruta:   totalComm,
      stripe_fees:      totalStripe,
      mercadopago_fees: 0,
      ganancia_neta:    totalComm - totalStripe,
      artistas_payout:  totalArtists,
      event_count:      paid.length,
    });
  };

  // ── Desglose por evento ───────────────────────────────────────────────────
  const fetchEventFinancials = async () => {
    const days = daysFrom(filter);
    const { data } = await supabase.rpc('get_admin_event_financials', {
      p_days:  days ?? 3650,
      p_limit: 50,
    });

    if (data && (data as any[]).length > 0) {
      setEventFins(data as EventFinancial[]);
      return;
    }

    // Fallback: construir desde reservations directamente
    const from = dateFrom(filter);
    let q = supabase
      .from('reservations')
      .select(`
        id, event_date, created_at, total_price, group_earnings,
        service_fee_amount, commission_amount, msi_fee_amount, base_price,
        stripe_fee_amount, payment_status,
        groups ( name )
      `)
      .in('payment_status', ['paid', 'fully_paid', 'deposit_paid'])
      .order('created_at', { ascending: false })
      .limit(50);
    if (from) q = q.gte('created_at', from);
    const { data: rows } = await q;

    const mapped: EventFinancial[] = (rows ?? []).map((r: any) => {
      const total      = (r.total_price ?? 0) + (r.msi_fee_amount ?? 0);
      const platFee    = (r.service_fee_amount ?? r.commission_amount ?? calcServiceFee(r.total_price ?? 0))
                         + (r.msi_fee_amount ?? 0);
      const stripeFee  = r.stripe_fee_amount ?? Math.round(total * 0.036 + 3);
      return {
        reservation_id:      r.id,
        event_date:          r.event_date ?? null,
        group_name:          (r.groups as any)?.name ?? null,
        event_total:         total,
        platform_fee:        platFee,
        stripe_fee:          stripeFee,
        mercadopago_fee:     0,
        net_platform_profit: platFee - stripeFee,
        artists_payout:      r.group_earnings ?? r.base_price ?? calcGroupEarnings(r.total_price ?? 0),
        created_at:          r.created_at,
      };
    });
    setEventFins(mapped);
  };

  // ── Ingresos publicitarios (wallet_transactions) ──────────────────────────
  const fetchAdIncome = async () => {
    const from = dateFrom(filter);
    let q = supabase
      .from('wallet_transactions')
      .select('type, amount, description, created_at')
      .in('type', ['ad_income', 'bid_income', 'recommendation_income'])
      .order('created_at', { ascending: false })
      .limit(100);
    if (from) q = q.gte('created_at', from);
    const { data } = await q;
    setAdIncome(data ?? []);
  };

  // ── Historial de retiros (payout_requests) ───────────────────────────────
  const fetchPayouts = async () => {
    const from = dateFrom(filter);
    let q = supabase
      .from('payout_requests')
      .select(`
        id, group_id, status, amount, clabe, notes, created_at, reviewed_at,
        group:groups(name)
      `)
      .order('created_at', { ascending: false })
      .limit(60);
    if (from) q = q.gte('created_at', from);
    const { data } = await q;
    setPayouts((data as any) ?? []);
  };

  const fmt = (n: number) =>
    `$${n.toLocaleString('es-MX', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;

  const payoutTypeLabel = (t: string | null) => {
    switch (t) {
      case 'deposit_group':   return 'Anticipo (grupo)';
      case 'final_group':     return 'Pago final (grupo)';
      case 'member':          return 'Integrante';
      case 'talent_invited':  return 'Talento invitado';
      case 'final_referral':  return 'Referido';
      default:                return t ?? '—';
    }
  };

  if (loading) {
    return (
      <View style={s.loadingCtr}>
        <ActivityIndicator size="large" color={COLORS.green} />
      </View>
    );
  }

  return (
    <View style={s.container}>
      <Particles />
      <SafeAreaView style={{ flex: 1 }}>

        {/* HEADER */}
        <View style={s.header}>
          <Pressable style={s.backBtn} onPress={() => navigation.goBack()}>
            <ArrowLeft size={20} color={COLORS.text} />
          </Pressable>
          <Text style={s.headerTitle}>Panel Financiero</Text>
          <View style={{ width: 40 }} />
        </View>

        <ScrollView
          showsVerticalScrollIndicator={false}
          contentContainerStyle={s.scroll}
          refreshControl={
            <RefreshControl refreshing={refreshing} onRefresh={() => load(true)} tintColor={COLORS.green} />
          }
        >
          {/* FILTRO DE FECHAS */}
          <View style={s.filterRow}>
            {DATE_OPTIONS.map(opt => (
              <Pressable
                key={opt.value}
                style={[s.filterChip, filter === opt.value && s.filterChipActive]}
                onPress={() => setFilter(opt.value)}
              >
                <Text style={[s.filterChipText, filter === opt.value && s.filterChipTextActive]}>
                  {opt.label}
                </Text>
              </Pressable>
            ))}
          </View>

          {/* TABS */}
          <View style={s.tabRow}>
            {(['overview', 'events', 'ads', 'transfers'] as TabView[]).map(tab => (
              <Pressable
                key={tab}
                style={[s.tab, activeTab === tab && s.tabActive]}
                onPress={() => setActiveTab(tab)}
              >
                <Text style={[s.tabText, activeTab === tab && s.tabTextActive]}>
                  {tab === 'overview' ? 'Resumen'
                    : tab === 'events' ? 'Eventos'
                    : tab === 'ads'    ? '📢 Publicidad'
                    : 'Transfers'}
                </Text>
              </Pressable>
            ))}
          </View>

          {/* ══ TAB: RESUMEN ══ */}
          {activeTab === 'overview' && overview && (
            <>
              {/* Row 1: Total facturado + Ganancia bruta */}
              <View style={s.kpiRow}>
                <KpiCard
                  icon={<DollarSign size={16} color={COLORS.green} />}
                  label="Total Facturado"
                  value={fmt(overview.total_facturado)}
                  sub={`${overview.event_count} eventos`}
                  accent={COLORS.green}
                />
                <KpiCard
                  icon={<TrendingUp size={16} color={COLORS.blue} />}
                  label="Ganancia Bruta"
                  value={fmt(overview.ganancia_bruta)}
                  sub={overview.total_facturado > 0
                    ? `${((overview.ganancia_bruta / overview.total_facturado) * 100).toFixed(1)}% · fee + MSI`
                    : '—'}
                  accent={COLORS.blue}
                />
              </View>

              {/* Row 2: Comisión plataforma + Pagado artistas */}
              <View style={s.kpiRow}>
                <KpiCard
                  icon={<CheckCircle size={16} color={COLORS.green} />}
                  label="Tu Comisión"
                  value={fmt(overview.ganancia_bruta)}
                  sub="20% markup · ganancia plataforma"
                  accent={COLORS.green}
                />
                <KpiCard
                  icon={<AlertCircle size={16} color={COLORS.gold} />}
                  label="Pagado Artistas"
                  value={fmt(overview.artistas_payout)}
                  sub="al grupo + integrantes"
                  accent={COLORS.gold}
                />
              </View>

              {/* Row 3: Stripe fees + Ganancia neta tras costos */}
              <View style={s.kpiRow}>
                <KpiCard
                  icon={<Zap size={16} color={COLORS.orange} />}
                  label="Costo Stripe"
                  value={fmt(overview.stripe_fees)}
                  sub={overview.stripe_fees > 0 ? '− comisión procesamiento' : 'sin datos'}
                  accent={COLORS.orange}
                />
                <KpiCard
                  icon={<Minus size={16} color={COLORS.muted2} />}
                  label="Neto tras Stripe"
                  value={fmt(overview.ganancia_neta)}
                  sub="comisión − costo Stripe"
                  accent={COLORS.muted2}
                />
              </View>

              {/* Barra de distribución */}
              {overview.total_facturado > 0 && (
                <View style={s.barCard}>
                  <Text style={s.barTitle}>Distribución del dinero</Text>
                  <View style={s.barTrack}>
                    <View style={[s.barFill, { flex: overview.ganancia_bruta / overview.total_facturado, backgroundColor: COLORS.green }]} />
                    <View style={[s.barFill, { flex: overview.stripe_fees / overview.total_facturado, backgroundColor: COLORS.orange }]} />
                    <View style={[s.barFill, { flex: overview.mercadopago_fees / overview.total_facturado, backgroundColor: COLORS.muted }]} />
                    <View style={[s.barFill, { flex: overview.artistas_payout / overview.total_facturado, backgroundColor: COLORS.blue }]} />
                  </View>
                  <View style={s.barLegend}>
                    <LegendDot color={COLORS.green}  label={`Tu comisión ${fmt(overview.ganancia_bruta)}`} />
                    <LegendDot color={COLORS.orange} label={`Stripe ${fmt(overview.stripe_fees)}`} />
                    <LegendDot color={COLORS.blue}   label={`Artistas ${fmt(overview.artistas_payout)}`} />
                  </View>
                </View>
              )}

              {/* Ecuación resumen */}
              <View style={s.equationCard}>
                <Text style={s.equationTitle}>Cómo se calcula tu ganancia</Text>
                <View style={s.equationRow}>
                  <Text style={s.eqLabel}>Tu comisión cobrada (20% markup)</Text>
                  <Text style={[s.eqValue, { color: COLORS.green }]}>{fmt(overview.ganancia_bruta)}</Text>
                </View>
                <View style={s.equationRow}>
                  <Text style={s.eqLabel}>− Costo Stripe</Text>
                  <Text style={[s.eqValue, { color: COLORS.orange }]}>−{fmt(overview.stripe_fees)}</Text>
                </View>
                <View style={[s.equationRow, s.equationTotal]}>
                  <Text style={s.eqTotalLabel}>= Neto real tras costos</Text>
                  <Text style={s.eqTotalValue}>{fmt(overview.ganancia_neta)}</Text>
                </View>
              </View>
            </>
          )}

          {/* ══ TAB: DESGLOSE POR EVENTO ══ */}
          {activeTab === 'events' && (
            <>
              <Text style={s.sectionTitle}>Desglose por evento</Text>
              {eventFinancials.length === 0 && (
                <View style={s.emptyCard}>
                  <Text style={s.emptyText}>Sin datos en este período</Text>
                  <Text style={s.emptySubText}>Sin reservas pagadas en este período</Text>
                </View>
              )}
              {eventFinancials.map(ev => (
                <View key={ev.reservation_id} style={s.eventCard}>
                  <View style={s.eventCardHeader}>
                    <View style={{ flex: 1 }}>
                      <Text style={s.eventGroup} numberOfLines={1}>
                        {ev.group_name ?? 'Grupo'}
                      </Text>
                      <Text style={s.eventDate}>
                        {ev.event_date
                          ? new Date(ev.event_date).toLocaleDateString('es-MX', { day: '2-digit', month: 'short', year: 'numeric' })
                          : '—'}
                        {' · '}
                        #{ev.reservation_id.slice(0, 8)}
                      </Text>
                    </View>
                    <Text style={s.eventTotal}>{fmt(ev.event_total)}</Text>
                  </View>

                  <View style={s.eventDivider} />

                  <EventRow label="Comisión plataforma" value={fmt(ev.platform_fee)} color={COLORS.blue} />
                  <EventRow label="− Comisión Stripe (est.)" value={`−${fmt(ev.stripe_fee)}`} color={COLORS.orange} />
                  {ev.mercadopago_fee > 0 && (
                    <EventRow label="− Comisión MercadoPago" value={`−${fmt(ev.mercadopago_fee)}`} color={COLORS.muted2} />
                  )}
                  <EventRow label="Ganancia neta plataforma" value={fmt(ev.net_platform_profit)} color={COLORS.green} bold />
                  <EventRow label="Pagado a artistas" value={fmt(ev.artists_payout)} color={COLORS.gold} />
                </View>
              ))}
            </>
          )}

          {/* ══ TAB: HISTORIAL TRANSFERS ══ */}
          {activeTab === 'transfers' && (
            <>
              <Text style={s.sectionTitle}>Historial de Transfers</Text>
              {payouts.length === 0 && (
                <View style={s.emptyCard}>
                  <Text style={s.emptyText}>Sin transfers en este período</Text>
                </View>
              )}
              {payouts.map(p => {
                const isOk   = p.status === 'processed' || p.status === 'approved';
                const isFail = p.status === 'rejected';
                const clabeMasked = p.clabe
                  ? `CLABE ···${String(p.clabe).slice(-4)}`
                  : (p.notes?.slice(0, 24) ?? 'Retiro');
                return (
                  <View key={p.id} style={s.payoutRow}>
                    <View style={[s.payoutIconWrap, isOk ? s.payoutIconOk : isFail ? s.payoutIconFail : s.payoutIconPending]}>
                      {isOk   ? <CheckCircle size={14} color={COLORS.green} /> :
                       isFail ? <X           size={14} color="#EF5350" /> :
                                <Clock       size={14} color={COLORS.orange} />}
                    </View>
                    <View style={{ flex: 1 }}>
                      <Text style={s.payoutName} numberOfLines={1}>
                        {(p.group as any)?.name ?? p.group_id?.slice(0, 8) ?? '—'}
                      </Text>
                      <Text style={s.payoutType}>{clabeMasked}</Text>
                    </View>
                    <View style={{ alignItems: 'flex-end' }}>
                      <Text style={[s.payoutAmount, isFail && s.payoutAmountFail]}>
                        {fmt(p.amount)}
                      </Text>
                      <Text style={s.payoutDate}>
                        {new Date(p.created_at).toLocaleDateString('es-MX', { day: '2-digit', month: 'short' })}
                      </Text>
                    </View>
                  </View>
                );
              })}
            </>
          )}

          {/* ══ TAB: PUBLICIDAD ══ */}
          {activeTab === 'ads' && (() => {
            const adRows    = adIncome.filter(t => t.type === 'ad_income');
            const bidRows   = adIncome.filter(t => t.type === 'bid_income');
            const recRows   = adIncome.filter(t => t.type === 'recommendation_income');
            const sumAds    = adRows.reduce((s, t) => s + Number(t.amount ?? 0), 0);
            const sumBids   = bidRows.reduce((s, t) => s + Number(t.amount ?? 0), 0);
            const sumRecs   = recRows.reduce((s, t) => s + Number(t.amount ?? 0), 0);
            const sumTotal  = sumAds + sumBids + sumRecs;
            const periodDays   = daysFrom(filter) ?? 90;
            const dailyAvg     = periodDays > 0 ? sumTotal / periodDays : 0;
            const activeAdCount = new Set(adIncome.map(t => t.reference_id).filter(Boolean)).size;
            const perAd        = activeAdCount > 0 ? sumTotal / activeAdCount : 0;

            const typeLabel = (type: string) =>
              type === 'ad_income'             ? '📢 Publicidad'
              : type === 'bid_income'          ? '🔥 Bidding'
              : type === 'recommendation_income' ? '⭐ Recomendado'
              : type;

            const typeColor = (type: string) =>
              type === 'ad_income'             ? COLORS.gold
              : type === 'bid_income'          ? '#A78BFA'
              : type === 'recommendation_income' ? '#FCD34D'
              : COLORS.muted2;

            return (
              <>
                {/* Resumen por tipo */}
                <View style={s.eventCard}>
                  <Text style={[s.sectionTitle, { marginBottom: 12 }]}>Resumen del período</Text>
                  <EventRow label="📢 Publicidad (banner, dest., perfil)" value={fmt(sumAds)}  color={COLORS.gold} />
                  <EventRow label="🔥 Bidding (posicionamiento)"           value={fmt(sumBids)} color="#A78BFA" />
                  <EventRow label="⭐ Recomendaciones"                     value={fmt(sumRecs)} color="#FCD34D" />
                  <View style={{ borderTopWidth: 1, borderTopColor: COLORS.border, marginTop: 8, paddingTop: 8 }}>
                    <EventRow label="Total ingresos publicitarios" value={fmt(sumTotal)} color={COLORS.green} bold />
                  </View>
                </View>

                {/* Métricas de ritmo */}
                {sumTotal > 0 && (
                  <View style={[s.eventCard, { flexDirection: 'row', gap: 10 }]}>
                    <View style={{ flex: 1, alignItems: 'center' }}>
                      <Text style={[s.overviewVal, { color: COLORS.green }]}>{fmt(dailyAvg)}</Text>
                      <Text style={s.overviewLabel}>Ingreso / día</Text>
                    </View>
                    <View style={{ width: 1, backgroundColor: COLORS.border }} />
                    <View style={{ flex: 1, alignItems: 'center' }}>
                      <Text style={[s.overviewVal, { color: '#FCD34D' }]}>
                        {activeAdCount > 0 ? fmt(perAd) : '—'}
                      </Text>
                      <Text style={s.overviewLabel}>Por anuncio</Text>
                    </View>
                    <View style={{ width: 1, backgroundColor: COLORS.border }} />
                    <View style={{ flex: 1, alignItems: 'center' }}>
                      <Text style={[s.overviewVal, { color: '#A78BFA' }]}>{activeAdCount}</Text>
                      <Text style={s.overviewLabel}>Anuncios únicos</Text>
                    </View>
                  </View>
                )}

                {/* Historial de transacciones */}
                <Text style={[s.sectionTitle, { marginTop: 4 }]}>Transacciones ({adIncome.length})</Text>
                {adIncome.length === 0 && (
                  <View style={s.emptyCard}>
                    <Text style={s.emptyText}>Sin ingresos publicitarios en este período</Text>
                  </View>
                )}
                {adIncome.map((t, i) => (
                  <View key={t.reference_id ?? i} style={s.payoutRow}>
                    <View style={[s.payoutIconWrap, { backgroundColor: typeColor(t.type) + '20' }]}>
                      <Text style={{ fontSize: 14 }}>
                        {t.type === 'ad_income' ? '📢' : t.type === 'bid_income' ? '🔥' : '⭐'}
                      </Text>
                    </View>
                    <View style={{ flex: 1 }}>
                      <Text style={s.payoutName} numberOfLines={1}>
                        {t.description ?? typeLabel(t.type)}
                      </Text>
                      <Text style={s.payoutType}>{typeLabel(t.type)}</Text>
                    </View>
                    <View style={{ alignItems: 'flex-end' }}>
                      <Text style={[s.payoutAmount, { color: typeColor(t.type) }]}>
                        {fmt(Number(t.amount ?? 0))}
                      </Text>
                      <Text style={s.payoutDate}>
                        {new Date(t.created_at).toLocaleDateString('es-MX', { day: '2-digit', month: 'short' })}
                      </Text>
                    </View>
                  </View>
                ))}
              </>
            );
          })()}

          <View style={{ height: 40 }} />
        </ScrollView>
      </SafeAreaView>
    </View>
  );
}

// ─── Sub-components ───────────────────────────────────────────────────────────

function KpiCard({
  icon, label, value, sub, accent,
}: {
  icon: React.ReactNode; label: string; value: string; sub: string; accent: string;
}) {
  return (
    <View style={[kpi.card, { borderColor: accent + '30' }]}>
      <View style={[kpi.iconWrap, { backgroundColor: accent + '15' }]}>{icon}</View>
      <Text style={kpi.label}>{label}</Text>
      <Text style={[kpi.value, { color: accent }]}>{value}</Text>
      <Text style={kpi.sub}>{sub}</Text>
    </View>
  );
}

function LegendDot({ color, label }: { color: string; label: string }) {
  return (
    <View style={s.legendItem}>
      <View style={[s.legendDot, { backgroundColor: color }]} />
      <Text style={s.legendText}>{label}</Text>
    </View>
  );
}

function EventRow({
  label, value, color, bold,
}: {
  label: string; value: string; color: string; bold?: boolean;
}) {
  return (
    <View style={s.eventRow}>
      <Text style={[s.eventRowLabel, bold && { color: COLORS.text, fontFamily: FONTS.bodySemiBold }]}>
        {label}
      </Text>
      <Text style={[s.eventRowValue, { color }, bold && { fontFamily: FONTS.bodySemiBold }]}>
        {value}
      </Text>
    </View>
  );
}

// ─── Styles ───────────────────────────────────────────────────────────────────

const s = StyleSheet.create({
  container:  { flex: 1, backgroundColor: COLORS.bg },
  loadingCtr: { flex: 1, backgroundColor: COLORS.bg, alignItems: 'center', justifyContent: 'center' },
  header: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between',
    paddingHorizontal: SPACING.xl, paddingVertical: 14,
    borderBottomWidth: 1, borderBottomColor: COLORS.border,
  },
  backBtn: {
    width: 40, height: 40, borderRadius: 12,
    backgroundColor: COLORS.card, borderWidth: 1, borderColor: COLORS.border,
    alignItems: 'center', justifyContent: 'center',
  },
  headerTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 16, color: COLORS.text },
  scroll:      { padding: SPACING.xl, gap: 14 },

  // Filter chips
  filterRow:            { flexDirection: 'row', gap: 8, flexWrap: 'wrap' },
  filterChip:           { paddingHorizontal: 14, paddingVertical: 7, borderRadius: RADIUS.full, backgroundColor: COLORS.card, borderWidth: 1, borderColor: COLORS.border },
  filterChipActive:     { backgroundColor: COLORS.green, borderColor: COLORS.green },
  filterChipText:       { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted },
  filterChipTextActive: { color: COLORS.bg },

  // Tabs
  tabRow:       { flexDirection: 'row', backgroundColor: COLORS.card, borderRadius: RADIUS.lg, borderWidth: 1, borderColor: COLORS.border, padding: 4 },
  tab:          { flex: 1, paddingVertical: 9, alignItems: 'center', borderRadius: RADIUS.md },
  tabActive:    { backgroundColor: COLORS.green },
  tabText:      { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted },
  tabTextActive:{ color: COLORS.bg, fontFamily: FONTS.bodySemiBold },

  // KPI grid
  kpiRow: { flexDirection: 'row', gap: 12 },

  // Distribution bar
  barCard:  { backgroundColor: COLORS.card, borderRadius: RADIUS.lg, borderWidth: 1, borderColor: COLORS.border, padding: SPACING.lg },
  barTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.muted2, marginBottom: 12, textTransform: 'uppercase', letterSpacing: 0.6 },
  barTrack: { flexDirection: 'row', height: 10, borderRadius: 5, overflow: 'hidden', marginBottom: 10 },
  barFill:  { height: '100%' },
  barLegend: { flexDirection: 'row', flexWrap: 'wrap', gap: 10 },
  legendItem: { flexDirection: 'row', alignItems: 'center', gap: 6 },
  legendDot:  { width: 8, height: 8, borderRadius: 4 },
  legendText: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2 },

  // Equation card
  equationCard: { backgroundColor: COLORS.card, borderRadius: RADIUS.lg, borderWidth: 1, borderColor: COLORS.border, padding: SPACING.lg },
  equationTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.muted2, textTransform: 'uppercase', letterSpacing: 0.6, marginBottom: 12 },
  equationRow: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center', paddingVertical: 7, borderBottomWidth: 1, borderBottomColor: COLORS.border },
  equationTotal: { borderBottomWidth: 0, paddingTop: 12, marginTop: 4 },
  eqLabel: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2 },
  eqValue: { fontFamily: FONTS.bodyMedium, fontSize: 14 },
  eqTotalLabel: { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.text },
  eqTotalValue: { fontFamily: FONTS.title, fontSize: 20, color: COLORS.green },

  // Section
  sectionTitle: { fontFamily: FONTS.title, fontSize: 16, color: COLORS.text },
  overviewVal:   { fontFamily: FONTS.title, fontSize: 15, color: COLORS.text, textAlign: 'center' },
  overviewLabel: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted, textAlign: 'center', marginTop: 2 },

  // Empty
  emptyCard:    { backgroundColor: COLORS.card, borderRadius: RADIUS.lg, borderWidth: 1, borderColor: COLORS.border, padding: SPACING.xl, alignItems: 'center', gap: 8 },
  emptyText:    { fontFamily: FONTS.bodyMedium, fontSize: 14, color: COLORS.muted },
  emptySubText: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted, textAlign: 'center', lineHeight: 18 },

  // Event card
  eventCard: { backgroundColor: COLORS.card, borderRadius: RADIUS.lg, borderWidth: 1, borderColor: COLORS.border, padding: SPACING.lg },
  eventCardHeader: { flexDirection: 'row', alignItems: 'flex-start', justifyContent: 'space-between', marginBottom: 12 },
  eventGroup: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.text },
  eventDate:  { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted, marginTop: 2 },
  eventTotal: { fontFamily: FONTS.title, fontSize: 18, color: COLORS.green },
  eventDivider: { height: 1, backgroundColor: COLORS.border, marginBottom: 10 },
  eventRow: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center', paddingVertical: 5 },
  eventRowLabel: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2 },
  eventRowValue: { fontFamily: FONTS.bodyMedium, fontSize: 13 },

  // Payout row
  payoutRow: { flexDirection: 'row', alignItems: 'center', gap: 12, backgroundColor: COLORS.card, borderRadius: RADIUS.lg, borderWidth: 1, borderColor: COLORS.border, padding: SPACING.md },
  payoutIconWrap: { width: 34, height: 34, borderRadius: RADIUS.md, alignItems: 'center', justifyContent: 'center' },
  payoutIconOk:      { backgroundColor: COLORS.greenMuted },
  payoutIconFail:    { backgroundColor: 'rgba(239,83,80,0.1)' },
  payoutIconPending: { backgroundColor: 'rgba(255,152,0,0.1)' },
  payoutName:   { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.text },
  payoutType:   { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted, marginTop: 2 },
  payoutAmount: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.green },
  payoutAmountFail: { color: '#EF5350' },
  payoutDate:   { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted, marginTop: 2 },
});

const kpi = StyleSheet.create({
  card:    { flex: 1, backgroundColor: COLORS.card, borderRadius: RADIUS.lg, borderWidth: 1, padding: SPACING.lg, gap: 6 },
  iconWrap:{ width: 32, height: 32, borderRadius: RADIUS.md, alignItems: 'center', justifyContent: 'center' },
  label:   { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted2, textTransform: 'uppercase', letterSpacing: 0.5 },
  value:   { fontFamily: FONTS.title, fontSize: 20 },
  sub:     { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted },
});
