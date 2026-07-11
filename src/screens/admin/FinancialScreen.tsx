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
  Alert,
  Image,
  Modal,
  Pressable,
  RefreshControl,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  View,
} from 'react-native';
import * as ImagePicker from 'expo-image-picker';
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
type TabView    = 'overview' | 'events' | 'transfers' | 'ads' | 'refunds';

// Reembolso manual (SPEI/efectivo) — cola de admin_manual_refund_queue
interface ManualRefund {
  id:                 string;
  reservation_id:     string;
  client_id:          string;
  folio:              string | null;
  client_name:        string | null;
  client_phone:       string | null;
  payment_method:     string;
  amount:             number;
  clabe:              string | null;
  account_holder:     string | null;
  bank_name:          string | null;
  due_date:           string;
  status:             'pending' | 'processing' | 'sent';
  transfer_reference: string | null;
  receipt_path:       string | null;
  api_error:          string | null;
  created_at:         string;
  processed_at:       string | null;
}

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

export default function AdminFinancialScreen({ navigation, route }: any) {
  const [overview, setOverview]         = useState<FinancialOverview | null>(null);
  const [eventFinancials, setEventFins] = useState<EventFinancial[]>([]);
  const [payouts, setPayouts]           = useState<Payout[]>([]);
  const [adIncome, setAdIncome]         = useState<any[]>([]);
  const [filter, setFilter]             = useState<DateFilter>('30d');
  const [activeTab, setActiveTab]       = useState<TabView>(route?.params?.initialTab ?? 'overview');

  // Si la pantalla ya está montada y llega una notificación con initialTab
  useEffect(() => {
    if (route?.params?.initialTab) setActiveTab(route.params.initialTab);
  }, [route?.params?.initialTab]);
  const [loading, setLoading]           = useState(true);
  const [refreshing, setRefreshing]     = useState(false);
  // Cola de reembolsos manuales (SPEI/efectivo)
  const [refunds, setRefunds]           = useState<ManualRefund[]>([]);
  const [refundModal, setRefundModal]   = useState<ManualRefund | null>(null);
  const [refundRef, setRefundRef]       = useState('');
  const [receiptUri, setReceiptUri]     = useState<string | null>(null);
  const [refundSaving, setRefundSaving] = useState(false);

  useEffect(() => { load(); }, [filter]);

  const load = async (isRefresh = false) => {
    if (isRefresh) setRefreshing(true);
    else setLoading(true);
    try {
      await Promise.all([fetchOverview(), fetchEventFinancials(), fetchPayouts(), fetchAdIncome(), fetchRefunds()]);
    } finally {
      setLoading(false);
      setRefreshing(false);
    }
  };

  // ── Cola de reembolsos manuales ───────────────────────────────────────────
  const fetchRefunds = async () => {
    const { data, error } = await supabase.rpc('admin_manual_refund_queue');
    if (error) { console.warn('[FinancialScreen] refund queue:', error.message); return; }
    setRefunds((data ?? []) as ManualRefund[]);
  };

  const markProcessing = async (mr: ManualRefund) => {
    const { data } = await supabase.rpc('admin_process_manual_refund', {
      p_refund_id: mr.id, p_action: 'processing',
    });
    if ((data as any)?.ok === false) { Alert.alert('Error', (data as any)?.error ?? 'Intenta de nuevo'); return; }
    fetchRefunds();
  };

  const pickReceipt = async () => {
    const res = await ImagePicker.launchImageLibraryAsync({
      mediaTypes: ['images'], quality: 0.8, allowsEditing: false,
    });
    if (!res.canceled && res.assets?.[0]?.uri) setReceiptUri(res.assets[0].uri);
  };

  const completeRefund = async () => {
    if (!refundModal) return;
    const reference = refundRef.trim();
    if (!reference) { Alert.alert('Falta la referencia', 'Escribe la clave de rastreo o folio de la transferencia.'); return; }
    setRefundSaving(true);
    try {
      // 1. Subir comprobante (opcional pero recomendado)
      let receiptPath: string | null = null;
      if (receiptUri) {
        receiptPath = `${refundModal.client_id}/${refundModal.id}.jpg`;
        const buf = await fetch(receiptUri).then(r => r.arrayBuffer());
        const { error: upErr } = await supabase.storage
          .from('refund-receipts')
          .upload(receiptPath, buf, { contentType: 'image/jpeg', upsert: true });
        if (upErr) throw new Error(`No se pudo subir el comprobante: ${upErr.message}`);
      }
      // 2. Marcar enviado + notificar al cliente
      const { data, error } = await supabase.rpc('admin_process_manual_refund', {
        p_refund_id: refundModal.id, p_action: 'sent',
        p_transfer_reference: reference, p_receipt_path: receiptPath,
      });
      if (error || (data as any)?.ok === false) {
        throw new Error((data as any)?.error ?? error?.message ?? 'No se pudo completar');
      }
      Alert.alert('✅ Reembolso completado', 'El cliente fue notificado de que su dinero fue enviado.');
      setRefundModal(null); setRefundRef(''); setReceiptUri(null);
      fetchRefunds();
    } catch (e: any) {
      Alert.alert('Error', e.message ?? 'Intenta de nuevo.');
    } finally {
      setRefundSaving(false);
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

          {/* TABS (scrolleables — 5 secciones ya no caben en una fila fija) */}
          <View style={s.tabRow}>
            <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={s.tabRowContent}>
              {(['overview', 'refunds', 'events', 'ads', 'transfers'] as TabView[]).map(tab => {
                const pendingRefunds = refunds.filter(x => x.status !== 'sent').length;
                return (
                <Pressable
                  key={tab}
                  style={[s.tab, activeTab === tab && s.tabActive]}
                  onPress={() => setActiveTab(tab)}
                >
                  <Text style={[s.tabText, activeTab === tab && s.tabTextActive]}>
                    {tab === 'overview' ? 'Resumen'
                      : tab === 'events' ? 'Eventos'
                      : tab === 'ads'    ? '📢 Publicidad'
                      : tab === 'refunds' ? '💸 Reembolsos'
                      : 'Transfers'}
                  </Text>
                  {tab === 'refunds' && pendingRefunds > 0 && (
                    <View style={s.tabBadge}>
                      <Text style={s.tabBadgeTx}>{pendingRefunds}</Text>
                    </View>
                  )}
                </Pressable>
              );})}
            </ScrollView>
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

          {/* ══ TAB: REEMBOLSOS MANUALES (SPEI/efectivo) ══ */}
          {activeTab === 'refunds' && (
            <>
              <Text style={s.sectionTitle}>Reembolsos por transferencia</Text>
              <Text style={s.refundIntro}>
                Pagos SPEI/efectivo cancelados — se devuelven por transferencia manual.
                Promesa al cliente: 5 días hábiles.
              </Text>
              {refunds.length === 0 && (
                <View style={s.emptyCard}>
                  <Text style={s.emptyText}>Sin reembolsos manuales pendientes 🎉</Text>
                </View>
              )}
              {refunds.map(mr => {
                const overdue = mr.status !== 'sent' && new Date(mr.due_date) < new Date();
                const stColor = mr.status === 'sent' ? COLORS.green : mr.status === 'processing' ? COLORS.orange : '#EF5350';
                const stLabel = mr.status === 'sent' ? 'Enviado' : mr.status === 'processing' ? 'Procesando' : 'Pendiente';
                return (
                  <View key={mr.id} style={[s.refundCard, overdue && s.refundCardOverdue]}>
                    <View style={s.refundHead}>
                      <View style={{ flex: 1 }}>
                        <Text style={s.payoutName} numberOfLines={1}>{mr.client_name ?? '—'}</Text>
                        <Text style={s.payoutType}>
                          Folio {mr.folio ?? 's/f'} · {mr.payment_method === 'cash' ? '🏪 Efectivo' : '🏦 SPEI'}
                          {mr.client_phone ? ` · 📞 ${mr.client_phone}` : ''}
                        </Text>
                      </View>
                      <View style={{ alignItems: 'flex-end' }}>
                        <Text style={s.payoutAmount}>{fmt(mr.amount)}</Text>
                        <Text style={[s.refundStatus, { color: stColor }]}>{stLabel}</Text>
                      </View>
                    </View>
                    <View style={s.refundBank}>
                      {mr.clabe ? (
                        <>
                          <Text style={s.refundBankTx} selectable>CLABE: {mr.clabe}</Text>
                          <Text style={s.refundBankTx}>{mr.bank_name ?? 'Banco s/d'} · {mr.account_holder ?? 'Titular s/d'}</Text>
                        </>
                      ) : (
                        <Text style={[s.refundBankTx, { color: COLORS.orange }]}>
                          ⚠️ Sin CLABE — contactar al cliente{mr.client_phone ? ` (${mr.client_phone})` : ''}
                        </Text>
                      )}
                      <Text style={[s.refundDue, overdue && { color: '#EF5350' }]}>
                        Fecha límite: {new Date(mr.due_date + 'T12:00:00').toLocaleDateString('es-MX', { day: '2-digit', month: 'short' })}
                        {overdue ? ' · ⚠️ VENCIDO' : ''}
                      </Text>
                      {!!mr.api_error && (
                        <Text style={s.refundApiErr} numberOfLines={2}>Fallback API: {mr.api_error}</Text>
                      )}
                      {mr.status === 'sent' && (
                        <Text style={s.refundBankTx}>Ref: {mr.transfer_reference ?? '—'} · {mr.receipt_path ? '📎 con comprobante' : 'sin comprobante'}</Text>
                      )}
                    </View>
                    {mr.status !== 'sent' && (
                      <View style={s.refundActions}>
                        {mr.status === 'pending' && (
                          <Pressable style={s.refundBtnGhost} onPress={() => markProcessing(mr)}>
                            <Text style={s.refundBtnGhostTx}>Marcar procesando</Text>
                          </Pressable>
                        )}
                        <Pressable
                          style={s.refundBtn}
                          onPress={() => { setRefundModal(mr); setRefundRef(''); setReceiptUri(null); }}
                        >
                          <Text style={s.refundBtnTx}>✓ Ya transferí</Text>
                        </Pressable>
                      </View>
                    )}
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

        {/* ── Modal: completar reembolso manual ── */}
        <Modal visible={!!refundModal} transparent animationType="slide" onRequestClose={() => setRefundModal(null)}>
          <View style={s.refundModalOverlay}>
            <View style={s.refundModalSheet}>
              <View style={s.refundModalHead}>
                <Text style={s.refundModalTitle}>Confirmar transferencia</Text>
                <Pressable onPress={() => setRefundModal(null)} hitSlop={8}>
                  <X size={20} color={COLORS.muted2} />
                </Pressable>
              </View>
              {refundModal && (
                <Text style={s.refundIntro}>
                  {refundModal.client_name} · {fmt(refundModal.amount)}
                  {refundModal.clabe ? ` · CLABE ···${String(refundModal.clabe).slice(-4)}` : ''}
                </Text>
              )}
              <Text style={s.refundModalLabel}>Referencia / clave de rastreo *</Text>
              <TextInput
                style={s.refundModalInput}
                value={refundRef}
                onChangeText={setRefundRef}
                placeholder="Ej. clave de rastreo SPEI"
                placeholderTextColor={COLORS.muted}
              />
              <Text style={s.refundModalLabel}>Comprobante (foto/captura)</Text>
              <Pressable style={s.refundReceiptPick} onPress={pickReceipt}>
                {receiptUri
                  ? <Image source={{ uri: receiptUri }} style={s.refundReceiptImg} resizeMode="cover" />
                  : <Text style={s.refundReceiptTx}>📎 Subir comprobante</Text>}
              </Pressable>
              <Pressable
                style={[s.refundBtn, { marginTop: 14 }, refundSaving && { opacity: 0.5 }]}
                onPress={completeRefund}
                disabled={refundSaving}
              >
                {refundSaving
                  ? <ActivityIndicator size="small" color="#000" />
                  : <Text style={s.refundBtnTx}>Marcar como enviado y notificar</Text>}
              </Pressable>
            </View>
          </View>
        </Modal>
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
  tabRow:       { backgroundColor: COLORS.card, borderRadius: RADIUS.lg, borderWidth: 1, borderColor: COLORS.border, padding: 4 },
  tabRowContent:{ flexDirection: 'row', gap: 2 },
  tab:          { paddingVertical: 9, paddingHorizontal: 14, alignItems: 'center', borderRadius: RADIUS.md, flexDirection: 'row', gap: 6 },
  tabActive:    { backgroundColor: COLORS.green },
  tabText:      { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted },
  tabTextActive:{ color: COLORS.bg, fontFamily: FONTS.bodySemiBold },
  tabBadge:     { backgroundColor: '#EF5350', borderRadius: RADIUS.full, minWidth: 18, height: 18, alignItems: 'center', justifyContent: 'center', paddingHorizontal: 4 },
  tabBadgeTx:   { fontFamily: FONTS.bodySemiBold, fontSize: 10, color: '#fff' },

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

  // ── Reembolsos manuales ──
  refundIntro: { fontFamily: FONTS.body, fontSize: 12.5, color: COLORS.muted2, marginTop: 4, marginBottom: 12, lineHeight: 17 },
  refundCard: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border,
    padding: 14, marginBottom: 10,
  },
  refundCardOverdue: { borderColor: 'rgba(239,83,80,0.55)' },
  refundHead: { flexDirection: 'row', alignItems: 'flex-start', gap: 10 },
  refundStatus: { fontFamily: FONTS.bodySemiBold, fontSize: 11, marginTop: 2 },
  refundBank: { marginTop: 10, gap: 3 },
  refundBankTx: { fontFamily: FONTS.bodyMedium, fontSize: 12.5, color: COLORS.text },
  refundDue: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2 },
  refundApiErr: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.orange },
  refundActions: { flexDirection: 'row', gap: 8, marginTop: 12 },
  refundBtn: {
    flex: 1, backgroundColor: COLORS.green, borderRadius: RADIUS.md,
    paddingVertical: 11, alignItems: 'center',
  },
  refundBtnTx: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: '#000' },
  refundBtnGhost: {
    flex: 1, backgroundColor: 'transparent', borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: COLORS.border,
    paddingVertical: 11, alignItems: 'center',
  },
  refundBtnGhostTx: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted2 },

  // Modal completar reembolso
  refundModalOverlay: { flex: 1, backgroundColor: 'rgba(0,0,0,0.6)', justifyContent: 'flex-end' },
  refundModalSheet: {
    backgroundColor: COLORS.card, borderTopLeftRadius: 20, borderTopRightRadius: 20,
    padding: SPACING.xl, paddingBottom: 36,
  },
  refundModalHead: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', marginBottom: 8 },
  refundModalTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 17, color: COLORS.text },
  refundModalLabel: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.muted2, marginBottom: 6, marginTop: 6 },
  refundModalInput: {
    backgroundColor: COLORS.card2, borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: COLORS.border,
    paddingHorizontal: 14, paddingVertical: 12, marginBottom: 6,
    fontFamily: FONTS.bodyMedium, fontSize: 14, color: COLORS.text,
  },
  refundReceiptPick: {
    height: 110, borderRadius: RADIUS.md, borderWidth: 1, borderStyle: 'dashed',
    borderColor: COLORS.border, backgroundColor: COLORS.card2,
    alignItems: 'center', justifyContent: 'center', overflow: 'hidden',
  },
  refundReceiptImg: { width: '100%', height: '100%' },
  refundReceiptTx: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted2 },
});

const kpi = StyleSheet.create({
  card:    { flex: 1, backgroundColor: COLORS.card, borderRadius: RADIUS.lg, borderWidth: 1, padding: SPACING.lg, gap: 6 },
  iconWrap:{ width: 32, height: 32, borderRadius: RADIUS.md, alignItems: 'center', justifyContent: 'center' },
  label:   { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted2, textTransform: 'uppercase', letterSpacing: 0.5 },
  value:   { fontFamily: FONTS.title, fontSize: 20 },
  sub:     { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted },
});
