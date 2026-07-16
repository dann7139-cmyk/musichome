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
  Keyboard,
  KeyboardAvoidingView,
  Linking,
  Modal,
  Platform,
  Pressable,
  RefreshControl,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  View,
} from 'react-native';
import * as ImagePicker from 'expo-image-picker';
import * as ImageManipulator from 'expo-image-manipulator';
import * as WebBrowser from 'expo-web-browser';
import { SafeAreaView } from 'react-native-safe-area-context';
import { supabase } from '../../config/supabase';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';
import Particles from '../../components/ui/Particles';
import { calcGroupEarnings, calcServiceFee } from '../../utils/calculations';
import { flagFor, placeLine, methodLabel } from '../../utils/countryFormat';

// ─── Types ────────────────────────────────────────────────────────────────────

interface FinancialOverview {
  total_facturado:  number;
  ganancia_bruta:   number;
  stripe_fees:      number;
  fees_no_capturados?: number;
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
  stripe_fee:          number | null;
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
  country_code:       string | null;   // 'MX' | 'US' (sql/470)
  country:            string | null;
  state:              string | null;
  city:               string | null;
  currency:           string | null;   // 'MXN' | 'USD'
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
  // Fila USD de la fuente única (monedas separadas, nunca sumadas)
  const [overviewUsd, setOverviewUsd]   = useState<any | null>(null);
  const [downloadingReport, setDownloadingReport] = useState(false);
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
  const [payoutModal, setPayoutModal]   = useState<any | null>(null);   // retiro a completar
  const [refundRef, setRefundRef]       = useState('');
  const [receiptUri, setReceiptUri]     = useState<string | null>(null);
  const [refundSaving, setRefundSaving] = useState(false);
  // Toolbar de las colas (Reembolsos/Transfers): búsqueda + filtros rápidos.
  // Binacional 🇲🇽/🇺🇸 desde sql/470: el país/moneda vienen del servidor.
  const [qSearch, setQSearch] = useState('');
  const [qFilter, setQFilter] = useState<'pending' | 'done' | 'all'>('pending');
  const [qCountry, setQCountry] = useState<'all' | 'MX' | 'US'>('all');

  const matchesQueue = (statusGroup: 'pending' | 'done', countryCode: string | null | undefined, ...fields: (string | null | undefined)[]) => {
    if (qFilter !== 'all' && statusGroup !== qFilter) return false;
    if (qCountry !== 'all' && (countryCode ?? 'MX') !== qCountry) return false;
    const q = qSearch.trim().toLowerCase();
    if (!q) return true;
    return fields.some(f => (f ?? '').toLowerCase().includes(q));
  };

  // Abrir comprobante (URL firmada — bucket privado)
  const openReceipt = async (path: string) => {
    const { data: signed } = await supabase.storage
      .from('refund-receipts')
      .createSignedUrl(path, 3600);
    if (signed?.signedUrl) await WebBrowser.openBrowserAsync(signed.signedUrl);
    else Alert.alert('Comprobante', 'No se pudo abrir el comprobante.');
  };

  // Toolbar de cola: KPI de dinero pendiente + búsqueda + filtros rápidos.
  // Es una función (no componente) para no perder el foco del TextInput.
  const renderQueueToolbar = (opts: { label: string; amount: number; count: number; overdue?: number; usdAmount?: number }) => (
    <>
      <View style={s.kpiPendingCard}>
        <View style={{ flex: 1 }}>
          <Text style={s.kpiPendingLabel}>{opts.label}</Text>
          <Text style={s.kpiPendingAmount}>{fmt(opts.amount)} <Text style={s.currencyTag}>MXN</Text></Text>
          {(opts.usdAmount ?? 0) > 0 && (
            <Text style={[s.kpiPendingAmount, { fontSize: 16, color: COLORS.blue }]}>
              {fmt(opts.usdAmount!)} <Text style={s.currencyTag}>USD 🇺🇸</Text>
            </Text>
          )}
        </View>
        <View style={{ alignItems: 'flex-end', gap: 4 }}>
          <View style={[s.statusPill, { backgroundColor: 'rgba(255,179,0,0.14)', borderColor: COLORS.orange }]}>
            <Text style={[s.statusPillTx, { color: COLORS.orange }]}>{opts.count} pendiente{opts.count === 1 ? '' : 's'}</Text>
          </View>
          {(opts.overdue ?? 0) > 0 && (
            <View style={[s.statusPill, { backgroundColor: 'rgba(239,83,80,0.14)', borderColor: '#EF5350' }]}>
              <Text style={[s.statusPillTx, { color: '#EF5350' }]}>⚠️ {opts.overdue} vencido{opts.overdue === 1 ? '' : 's'}</Text>
            </View>
          )}
        </View>
      </View>
      <View style={s.queueToolbar}>
        <TextInput
          style={s.queueSearch}
          value={qSearch}
          onChangeText={setQSearch}
          placeholder="Buscar por grupo, cliente o folio…"
          placeholderTextColor={COLORS.muted}
        />
        <View style={s.queueChips}>
          {([['pending', 'Pendientes'], ['done', 'Hechos'], ['all', 'Todos']] as const).map(([key, lbl]) => (
            <Pressable
              key={key}
              style={[s.queueChip, qFilter === key && s.queueChipActive]}
              onPress={() => setQFilter(key)}
            >
              <Text style={[s.queueChipTx, qFilter === key && s.queueChipTxActive]}>{lbl}</Text>
            </Pressable>
          ))}
        </View>
        <View style={s.queueChips}>
          {([['all', '🌎 Todos'], ['MX', '🇲🇽 México'], ['US', '🇺🇸 EE.UU.']] as const).map(([key, lbl]) => (
            <Pressable
              key={key}
              style={[s.queueChip, qCountry === key && s.queueChipActive]}
              onPress={() => setQCountry(key)}
            >
              <Text style={[s.queueChipTx, qCountry === key && s.queueChipTxActive]}>{lbl}</Text>
            </Pressable>
          ))}
        </View>
      </View>
    </>
  );

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
    Keyboard.dismiss();
    const res = await ImagePicker.launchImageLibraryAsync({
      mediaTypes: ['images'], quality: 0.8, allowsEditing: false,
    });
    if (res.canceled || !res.assets?.[0]?.uri) return;
    // Comprimir ANTES de subir (una foto de celular pesa 3-8 MB; así queda
    // en ~100-300 KB y el "Marcar como enviado" tarda 1-2 s, no 10+)
    try {
      const small = await ImageManipulator.manipulateAsync(
        res.assets[0].uri,
        [{ resize: { width: 1200 } }],
        { compress: 0.7, format: ImageManipulator.SaveFormat.JPEG },
      );
      setReceiptUri(small.uri);
    } catch {
      setReceiptUri(res.assets[0].uri);   // fallback: subir original
    }
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
    // 📊 FUENTE ÚNICA (sql/490): mismas fórmulas que el Dashboard admin.
    // Monedas separadas — MXN es la vista principal, USD se muestra aparte.
    const days = daysFrom(filter);
    const fromDate = days != null
      ? new Date(Date.now() - days * 86400000).toISOString().substring(0, 10)
      : null;
    const { data: summary, error: sumErr } = await supabase.rpc('admin_finance_summary', {
      p_from: fromDate,
      p_to:   null,
    });
    if ((summary as any)?.ok) {
      const rows: any[] = (summary as any).currencies ?? [];
      const mxn = rows.find(m => m.moneda === 'MXN');
      const usd = rows.find(m => m.moneda === 'USD');
      setOverview({
        total_facturado:    Number(mxn?.total_cobrado ?? 0),
        ganancia_bruta:     Number(mxn?.comision_daricefy ?? 0),
        stripe_fees:        Number(mxn?.fees_reales ?? 0),
        fees_no_capturados: Number(mxn?.fees_no_capturados ?? 0),
        mercadopago_fees:   0,
        ganancia_neta:      Number(mxn?.neto_estimado ?? 0),
        artistas_payout:    Number(mxn?.dinero_grupos ?? 0),
        event_count:        Number(mxn?.eventos_cobrados ?? 0),
      });
      setOverviewUsd(usd ?? null);
      return;
    }
    if (sumErr) console.warn('[FinancialScreen] admin_finance_summary:', sumErr.message);

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
    // 🔒 CERO estimaciones (Fase 0.3): solo se suman fees REALES guardados.
    // Los eventos sin fee capturado se cuentan aparte y se muestran como
    // "No capturado" — jamás se inventa una cifra.
    const totalFeesReales = paid.reduce((s: number, r: any) => s + (r.stripe_fee_amount ?? 0), 0);
    const feesSinCapturar = paid.filter((r: any) => r.stripe_fee_amount == null).length;

    setOverview({
      total_facturado:  totalRevenue,
      ganancia_bruta:   totalComm,
      stripe_fees:      totalFeesReales,
      fees_no_capturados: feesSinCapturar,
      mercadopago_fees: 0,
      ganancia_neta:    totalComm - totalFeesReales,
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
      // 🔒 CERO estimaciones: fee real o null ("No capturado")
      const stripeFee  = r.stripe_fee_amount ?? null;
      return {
        reservation_id:      r.id,
        event_date:          r.event_date ?? null,
        group_name:          (r.groups as any)?.name ?? null,
        event_total:         total,
        platform_fee:        platFee,
        stripe_fee:          stripeFee,
        mercadopago_fee:     0,
        net_platform_profit: stripeFee != null ? platFee - stripeFee : platFee,
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
    // Fuente única: admin_withdrawals_queue (sql/470) — retiros de `withdrawals`
    // enriquecidos con grupo, país/estado/ciudad, moneda y método esperado.
    // El filtro de fecha del panel se aplica client-side (la cola trae 60 máx).
    const { data, error } = await supabase.rpc('admin_withdrawals_queue');
    if (error) { console.warn('[FinancialScreen] withdrawals queue:', error.message); return; }
    const from = dateFrom(filter);
    const rows = ((data as any) ?? []).filter((x: any) => !from || x.created_at >= from);
    setPayouts(rows);
  };

  // Completar retiro: transferencia hecha → referencia + comprobante → notifica al grupo
  const completePayout = async () => {
    if (!payoutModal) return;
    const reference = refundRef.trim();
    if (!reference) { Alert.alert('Falta la referencia', 'Escribe la clave de rastreo o folio de la transferencia.'); return; }
    setRefundSaving(true);
    try {
      let receiptPath: string | null = null;
      const ownerId = payoutModal.user_id;
      if (receiptUri && ownerId) {
        receiptPath = `${ownerId}/payout_${payoutModal.id}.jpg`;
        const buf = await fetch(receiptUri).then(r => r.arrayBuffer());
        const { error: upErr } = await supabase.storage
          .from('refund-receipts')
          .upload(receiptPath, buf, { contentType: 'image/jpeg', upsert: true });
        if (upErr) throw new Error(`No se pudo subir el comprobante: ${upErr.message}`);
      }
      const { data, error } = await supabase.rpc('admin_complete_payout', {
        p_payout_id: payoutModal.id,
        p_transfer_reference: reference,
        p_receipt_path: receiptPath,
      });
      if (error || (data as any)?.ok === false) {
        throw new Error((data as any)?.error ?? error?.message ?? 'No se pudo completar');
      }
      Alert.alert('✅ Retiro completado', 'El grupo fue notificado con su comprobante.');
      setPayoutModal(null); setRefundRef(''); setReceiptUri(null);
      fetchPayouts();
    } catch (e: any) {
      Alert.alert('Error', e.message ?? 'Intenta de nuevo.');
    } finally {
      setRefundSaving(false);
    }
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
                  {tab === 'transfers' && payouts.filter((x: any) => ['pending','processing'].includes(x.status)).length > 0 && (
                    <View style={s.tabBadge}>
                      <Text style={s.tabBadgeTx}>{payouts.filter((x: any) => ['pending','processing'].includes(x.status)).length}</Text>
                    </View>
                  )}
                </Pressable>
              );})}
            </ScrollView>
          </View>

          {/* ══ TAB: RESUMEN ══ */}
          {activeTab === 'overview' && overview && (
            <>
              {/* 📊 Descargar reporte (Excel) — país + rango; validado en servidor */}
              <Pressable
                style={[s.reportBtn, downloadingReport && { opacity: 0.6 }]}
                disabled={downloadingReport}
                onPress={() => {
                  const download = async (country: string, days: number | null) => {
                    setDownloadingReport(true);
                    try {
                      const from = days != null
                        ? new Date(Date.now() - days * 86400000).toISOString().substring(0, 10)
                        : null;
                      const { data, error } = await supabase.functions.invoke('generate-report', {
                        body: { mode: 'admin', country, from },
                      });
                      if (error || !(data as any)?.ok) {
                        Alert.alert('No se pudo generar', (data as any)?.error ?? error?.message ?? 'Intenta de nuevo.');
                        return;
                      }
                      await Linking.openURL((data as any).url);
                    } catch {
                      Alert.alert('Error', 'No se pudo descargar el reporte.');
                    } finally {
                      setDownloadingReport(false);
                    }
                  };
                  const pickRange = (country: string) => {
                    Alert.alert('📅 Periodo', 'Elige el rango de fechas', [
                      { text: 'Últimos 30 días', onPress: () => download(country, 30) },
                      { text: 'Últimos 90 días', onPress: () => download(country, 90) },
                      { text: 'Este año',        onPress: () => download(country, 365) },
                      { text: 'Todo',            onPress: () => download(country, null) },
                      { text: 'Cancelar', style: 'cancel' },
                    ]);
                  };
                  Alert.alert('📊 Descargar reporte', '¿De qué país?', [
                    { text: '🌎 Todos (reporte global)', onPress: () => pickRange('all') },
                    { text: '🇲🇽 México',                onPress: () => pickRange('MX') },
                    { text: '🇺🇸 Estados Unidos',        onPress: () => pickRange('US') },
                    { text: '🇨🇦 Canadá',                onPress: () => pickRange('CA') },
                    { text: 'Cancelar', style: 'cancel' },
                  ]);
                }}
              >
                <Text style={s.reportBtnTx}>
                  {downloadingReport ? 'Generando reporte…' : '📊 Descargar reporte (Excel)'}
                </Text>
              </Pressable>

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

              {/* Row 3: comisión de procesadores (solo REAL) + neto */}
              <View style={s.kpiRow}>
                <KpiCard
                  icon={<Zap size={16} color={COLORS.orange} />}
                  label="Comisión procesadores"
                  value={fmt(overview.stripe_fees)}
                  sub={(overview.fees_no_capturados ?? 0) > 0
                    ? `⚠️ ${overview.fees_no_capturados} evento(s) sin fee capturado`
                    : 'solo fees reales'}
                  accent={COLORS.orange}
                />
                <KpiCard
                  icon={<Minus size={16} color={COLORS.muted2} />}
                  label="Neto tras procesadores"
                  value={fmt(overview.ganancia_neta)}
                  sub="comisión − fees reales"
                  accent={COLORS.muted2}
                />
              </View>

              {/* 🇺🇸 Fila USD separada (jamás sumada con MXN) */}
              {overviewUsd && Number(overviewUsd.total_cobrado) > 0 && (
                <View style={s.barCard}>
                  <Text style={s.barTitle}>🇺🇸 Operación en USD (separada)</Text>
                  <Text style={{ fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, lineHeight: 18 }}>
                    Cobrado: US${Number(overviewUsd.total_cobrado).toLocaleString('en-US')}  ·  Grupos: US${Number(overviewUsd.dinero_grupos).toLocaleString('en-US')}  ·  Comisión: US${Number(overviewUsd.comision_daricefy).toLocaleString('en-US')}  ·  Neto: US${Number(overviewUsd.neto_estimado).toLocaleString('en-US')}
                  </Text>
                </View>
              )}

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
                    <LegendDot color={COLORS.orange} label={`Procesadores ${fmt(overview.stripe_fees)}`} />
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
                  <Text style={s.eqLabel}>− Comisión procesadores (real)</Text>
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
                  <EventRow
                    label="− Comisión procesador"
                    value={ev.stripe_fee != null ? `−${fmt(ev.stripe_fee)}` : 'No capturado'}
                    color={COLORS.orange}
                  />
                  {ev.mercadopago_fee > 0 && (
                    <EventRow label="− Comisión MercadoPago" value={`−${fmt(ev.mercadopago_fee)}`} color={COLORS.muted2} />
                  )}
                  <EventRow label="Ganancia neta plataforma" value={fmt(ev.net_platform_profit)} color={COLORS.green} bold />
                  <EventRow label="Pagado a artistas" value={fmt(ev.artists_payout)} color={COLORS.gold} />
                </View>
              ))}
            </>
          )}

          {/* ══ TAB: RETIROS DE GRUPOS (cola de trabajo + historial) ══ */}
          {activeTab === 'transfers' && (() => {
            const pendPay = payouts.filter((x: any) => ['pending', 'processing'].includes(x.status));
            const pendMXN = pendPay.filter((x: any) => (x.currency ?? 'MXN') === 'MXN').reduce((sum: number, x: any) => sum + Number(x.amount ?? 0), 0);
            const pendUSD = pendPay.filter((x: any) => x.currency === 'USD').reduce((sum: number, x: any) => sum + Number(x.amount ?? 0), 0);
            const visiblePay = payouts.filter((p: any) => matchesQueue(
              ['pending', 'processing'].includes(p.status) ? 'pending' : 'done',
              p.country_code,
              p.group_name, p.owner_name, p.bank_name, p.bank_clabe, p.state, p.city,
            ));
            return (
            <>
              <Text style={s.sectionTitle}>Pagos a grupos</Text>
              {renderQueueToolbar({
                label: pendUSD > 0 ? 'Por transferir (MXN · USD aparte)' : 'Por transferir a grupos',
                amount: pendMXN,
                count: pendPay.length,
                usdAmount: pendUSD,
              })}
              {visiblePay.length === 0 && (
                <View style={s.emptyCard}>
                  <Text style={s.emptyText}>
                    {qSearch.trim() || qCountry !== 'all' ? 'Sin resultados con estos filtros' : 'Sin retiros pendientes 🎉'}
                  </Text>
                </View>
              )}
              {visiblePay.map((p: any) => {
                const isPendingWork = ['pending', 'processing'].includes(p.status);
                const isUS = p.country_code === 'US';
                const isFail = p.status === 'rejected';
                const stColor = isFail ? '#EF5350' : isPendingWork ? COLORS.orange : COLORS.green;
                const stLabel = isFail ? 'Rechazado' : p.status === 'processing' ? 'Procesando' : isPendingWork ? 'Pendiente' : 'Transferido';
                return (
                  <View key={p.id} style={[s.refundCard, isPendingWork && { borderColor: 'rgba(255,179,0,0.45)' }]}>
                    <View style={s.refundHead}>
                      <View style={{ flex: 1 }}>
                        <Text style={s.payoutName} numberOfLines={1}>
                          {flagFor(p.country_code)} {p.group_name ?? p.owner_name ?? '—'}
                        </Text>
                        <Text style={s.payoutType}>
                          {placeLine(p)} · {methodLabel(p.expected_method)}
                        </Text>
                        <Text style={s.payoutType}>
                          Solicitado el {new Date(p.created_at).toLocaleDateString('es-MX', { day: '2-digit', month: 'short' })}
                          {p.owner_phone ? ` · 📞 ${p.owner_phone}` : ''}
                        </Text>
                      </View>
                      <View style={{ alignItems: 'flex-end', gap: 4 }}>
                        <Text style={[s.payoutAmount, isFail && s.payoutAmountFail]}>
                          {fmt(p.amount)} <Text style={s.currencyTag}>{p.currency ?? 'MXN'}</Text>
                        </Text>
                        <View style={[s.statusPill, { backgroundColor: `${stColor}22`, borderColor: stColor }]}>
                          <Text style={[s.statusPillTx, { color: stColor }]}>{stLabel}</Text>
                        </View>
                      </View>
                    </View>
                    <View style={s.refundBank}>
                      {isUS ? (
                        <Text style={[s.refundBankTx, { color: COLORS.blue }]}>
                          💳 Pago vía Stripe/ACH en USD — Pendiente de integración
                        </Text>
                      ) : p.bank_clabe ? (
                        <>
                          <Text style={s.refundBankTx} selectable>CLABE: {p.bank_clabe}{p.bank_name ? ` · ${p.bank_name}` : ''}</Text>
                          {!!p.account_holder && <Text style={s.refundBankTx}>Titular: {p.account_holder}</Text>}
                        </>
                      ) : (
                        <Text style={[s.refundBankTx, { color: COLORS.orange }]}>⚠️ Sin CLABE registrada</Text>
                      )}
                      {p.status === 'completed' && (
                        <Text style={s.refundBankTx}>Ref: {p.transfer_reference ?? '—'}</Text>
                      )}
                    </View>
                    {p.status === 'completed' && !!p.receipt_path && (
                      <Pressable style={s.receiptBtn} onPress={() => openReceipt(p.receipt_path)}>
                        <Text style={s.receiptBtnTx}>📎 Ver comprobante</Text>
                      </Pressable>
                    )}
                    {isPendingWork && (
                      isUS ? (
                        <View style={[s.refundActions, { opacity: 0.85 }]}>
                          <View style={[s.refundBtnGhost, { borderColor: 'rgba(66,133,244,0.5)' }]}>
                            <Text style={[s.refundBtnGhostTx, { color: COLORS.blue }]}>🇺🇸 Se pagará por Stripe/ACH — Próximamente</Text>
                          </View>
                        </View>
                      ) : (
                        <View style={s.refundActions}>
                          <Pressable
                            style={s.refundBtn}
                            onPress={() => { setPayoutModal(p); setRefundRef(''); setReceiptUri(null); }}
                          >
                            <Text style={s.refundBtnTx}>✓ Ya transferí</Text>
                          </Pressable>
                        </View>
                      )
                    )}
                  </View>
                );
              })}
            </>
            );
          })()}

          {/* ══ TAB: REEMBOLSOS MANUALES (SPEI/efectivo) ══ */}
          {activeTab === 'refunds' && (() => {
            const pend = refunds.filter(x => x.status !== 'sent');
            const overdueN = pend.filter(x => new Date(x.due_date) < new Date()).length;
            const visible = refunds.filter(mr => matchesQueue(
              mr.status === 'sent' ? 'done' : 'pending',
              mr.country_code,
              mr.client_name, mr.folio, mr.payment_method, mr.state, mr.city,
            ));
            return (
            <>
              <Text style={s.sectionTitle}>Reembolsos a clientes</Text>
              {renderQueueToolbar({
                label: 'Por reembolsar (SPEI/efectivo)',
                amount: pend.reduce((sum, x) => sum + Number(x.amount ?? 0), 0),
                count: pend.length,
                overdue: overdueN,
              })}
              {visible.length === 0 && (
                <View style={s.emptyCard}>
                  <Text style={s.emptyText}>
                    {qSearch.trim() ? 'Sin resultados para tu búsqueda' : 'Sin reembolsos manuales pendientes 🎉'}
                  </Text>
                </View>
              )}
              {visible.map(mr => {
                const overdue = mr.status !== 'sent' && new Date(mr.due_date) < new Date();
                const stColor = mr.status === 'sent' ? COLORS.green : mr.status === 'processing' ? COLORS.orange : '#EF5350';
                const stLabel = mr.status === 'sent' ? 'Reembolsado' : mr.status === 'processing' ? 'Procesando' : 'Pendiente';
                return (
                  <View key={mr.id} style={[s.refundCard, overdue && s.refundCardOverdue]}>
                    <View style={s.refundHead}>
                      <View style={{ flex: 1 }}>
                        <Text style={s.payoutName} numberOfLines={1}>{flagFor(mr.country_code)} {mr.client_name ?? '—'}</Text>
                        <Text style={s.payoutType}>
                          {placeLine(mr)}
                        </Text>
                        <Text style={s.payoutType}>
                          Folio {mr.folio ?? 's/f'} · {mr.payment_method === 'cash' ? '🏪 Efectivo' : '🏦 SPEI'}
                          {mr.client_phone ? ` · 📞 ${mr.client_phone}` : ''}
                        </Text>
                      </View>
                      <View style={{ alignItems: 'flex-end', gap: 4 }}>
                        <Text style={s.payoutAmount}>
                          {fmt(mr.amount)} <Text style={s.currencyTag}>{mr.currency ?? 'MXN'}</Text>
                        </Text>
                        <View style={[s.statusPill, { backgroundColor: `${stColor}22`, borderColor: stColor }]}>
                          <Text style={[s.statusPillTx, { color: stColor }]}>{stLabel}</Text>
                        </View>
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
                        <Text style={s.refundBankTx}>Ref: {mr.transfer_reference ?? '—'}</Text>
                      )}
                    </View>
                    {mr.status === 'sent' && !!mr.receipt_path && (
                      <Pressable style={s.receiptBtn} onPress={() => openReceipt(mr.receipt_path!)}>
                        <Text style={s.receiptBtnTx}>📎 Ver comprobante</Text>
                      </Pressable>
                    )}
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
            );
          })()}

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

        {/* ── Modal: completar transferencia (reembolso o retiro) ── */}
        <Modal
          visible={!!refundModal || !!payoutModal}
          transparent animationType="slide"
          onRequestClose={() => { setRefundModal(null); setPayoutModal(null); }}
        >
          <KeyboardAvoidingView
            style={s.refundModalOverlay}
            behavior={Platform.OS === 'ios' ? 'padding' : 'height'}
          >
            <View style={s.refundModalSheet}>
              <View style={s.refundModalHead}>
                <Text style={s.refundModalTitle}>
                  {payoutModal ? 'Confirmar retiro transferido' : 'Confirmar transferencia'}
                </Text>
                <Pressable onPress={() => { setRefundModal(null); setPayoutModal(null); }} hitSlop={8}>
                  <X size={20} color={COLORS.muted2} />
                </Pressable>
              </View>
              <ScrollView keyboardShouldPersistTaps="handled" showsVerticalScrollIndicator={false}>
              {refundModal && (
                <Text style={s.refundIntro}>
                  {refundModal.client_name} · {fmt(refundModal.amount)}
                  {refundModal.clabe ? ` · CLABE ···${String(refundModal.clabe).slice(-4)}` : ''}
                </Text>
              )}
              {payoutModal && (
                <Text style={s.refundIntro}>
                  {flagFor(payoutModal.country_code)} {payoutModal.group_name ?? payoutModal.owner_name ?? 'Grupo'} · {fmt(payoutModal.amount)} {payoutModal.currency ?? 'MXN'}
                  {payoutModal.bank_clabe ? ` · CLABE ···${String(payoutModal.bank_clabe).slice(-4)}` : ''}
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
                onPress={payoutModal ? completePayout : completeRefund}
                disabled={refundSaving}
              >
                {refundSaving
                  ? (
                    <View style={{ flexDirection: 'row', alignItems: 'center', gap: 8 }}>
                      <ActivityIndicator size="small" color="#000" />
                      <Text style={s.refundBtnTx}>{receiptUri ? 'Subiendo comprobante…' : 'Enviando…'}</Text>
                    </View>
                  )
                  : <Text style={s.refundBtnTx}>Marcar como enviado y notificar</Text>}
              </Pressable>
              </ScrollView>
            </View>
          </KeyboardAvoidingView>
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
  reportBtn: {
    paddingVertical: 13, alignItems: 'center',
    backgroundColor: 'rgba(0,230,118,0.08)', borderRadius: RADIUS.full,
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.4)',
  },
  reportBtnTx: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.green },

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

  // ── Colas (Reembolsos/Transfers): KPI + toolbar ──
  kpiPendingCard: {
    flexDirection: 'row', alignItems: 'center', gap: 10,
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: 'rgba(255,179,0,0.35)',
    padding: 14, marginTop: 10, marginBottom: 10,
  },
  kpiPendingLabel:  { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.muted2, marginBottom: 3 },
  kpiPendingAmount: { fontFamily: FONTS.title, fontSize: 22, color: COLORS.text, fontVariant: ['tabular-nums'] },
  queueToolbar: { gap: 8, marginBottom: 12 },
  queueSearch: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: COLORS.border,
    paddingHorizontal: 14, paddingVertical: 10,
    fontFamily: FONTS.body, fontSize: 13.5, color: COLORS.text,
  },
  queueChips: { flexDirection: 'row', gap: 8 },
  queueChip: {
    paddingHorizontal: 14, paddingVertical: 7, borderRadius: RADIUS.full,
    backgroundColor: COLORS.card, borderWidth: 1, borderColor: COLORS.border,
  },
  queueChipActive: { backgroundColor: COLORS.green, borderColor: COLORS.green },
  queueChipTx: { fontFamily: FONTS.bodyMedium, fontSize: 12.5, color: COLORS.muted2 },
  queueChipTxActive: { color: '#000', fontFamily: FONTS.bodySemiBold },
  statusPill: {
    borderRadius: RADIUS.full, borderWidth: 1,
    paddingHorizontal: 8, paddingVertical: 3, alignSelf: 'flex-end',
  },
  statusPillTx: { fontFamily: FONTS.bodySemiBold, fontSize: 10.5 },
  currencyTag:  { fontFamily: FONTS.bodySemiBold, fontSize: 10, color: COLORS.muted2 },
  receiptBtn: {
    marginTop: 10, borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.4)',
    backgroundColor: 'rgba(0,230,118,0.08)',
    paddingVertical: 10, alignItems: 'center',
  },
  receiptBtnTx: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.green },

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
    padding: SPACING.xl, paddingBottom: 36, maxHeight: '85%',
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
