import {
  AlertCircle,
  BarChart2,
  Bell,
  Briefcase,
  DollarSign,
  Map,
  Megaphone,
  Phone,
  Plane,
  RefreshCw,
  Shield,
  TrendingUp,
  UserPlus,
  Users,
  Wallet,
  Zap,
} from 'lucide-react-native';
import React, { useEffect, useState } from 'react';
import {
  Alert,
  Dimensions,
  Linking,
  Pressable,
  RefreshControl,
  ScrollView,
  Share,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import { LinearGradient } from 'expo-linear-gradient';
import { SafeAreaView } from 'react-native-safe-area-context';
import { useTranslation } from 'react-i18next';
import type { TFunction } from 'i18next';
import { supabase } from '../../config/supabase';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';
import Badge from '../../components/ui/Badge';
import Particles from '../../components/ui/Particles';
import { flagFor, placeLine } from '../../utils/countryFormat';

const { width: SW } = Dimensions.get('window');

const MONTH_SHORT = ['ENE','FEB','MAR','ABR','MAY','JUN','JUL','AGO','SEP','OCT','NOV','DIC'];

// Textos de los chips de estado vienen de i18n (t) — la función se llama
// dentro del componente, donde el hook useTranslation ya está disponible.
const getStatusChips = (t: TFunction) => ([
  { key: 'pending',     label: t('adminDashboardScreen.statusChips.pending'),     color: '#FF9800', bg: 'rgba(255,152,0,0.15)'     },
  { key: 'confirmed',   label: t('adminDashboardScreen.statusChips.confirmed'),   color: '#00E676', bg: 'rgba(0,230,118,0.12)'     },
  { key: 'in_progress', label: t('adminDashboardScreen.statusChips.inProgress'),  color: '#40C4FF', bg: 'rgba(64,196,255,0.12)'    },
  { key: 'completed',   label: t('adminDashboardScreen.statusChips.completed'),   color: '#B0BEC5', bg: 'rgba(176,190,197,0.12)'   },
  { key: 'cancelled',   label: t('adminDashboardScreen.statusChips.cancelled'),   color: '#FF5252', bg: 'rgba(255,82,82,0.12)'     },
] as const);

// Textos de las acciones rápidas vienen de i18n (t) — la función se llama
// dentro del componente, donde el hook useTranslation ya está disponible.
const getQuickActions = (t: TFunction) => ([
  { icon: Shield,    label: t('adminDashboardScreen.quickActions.verifications'), colors: ['#0d2a5e','#061530'], ic: '#40C4FF',  screen: 'AdminVerifications' },
  { icon: AlertCircle, label: t('adminDashboardScreen.quickActions.disputes'),    colors: ['#3d0d0d','#200606'], ic: COLORS.red, screen: 'AdminDisputes' },
  { icon: Users,     label: t('adminDashboardScreen.quickActions.groups'),        colors: ['#3d2a00','#1a1200'], ic: COLORS.gold,   screen: 'AdminGroups' },
  { icon: Briefcase, label: t('adminDashboardScreen.quickActions.talents'),       colors: ['#1a0d3d','#0d0617'], ic: '#CE93D8',     screen: 'Talentos'    },
  { icon: BarChart2, label: t('adminDashboardScreen.quickActions.stats'),         colors: ['#1a0d2e','#0d0617'], ic: '#CE93D8',  screen: 'AdminStats' },
  { icon: DollarSign, label: t('adminDashboardScreen.quickActions.finances'),     colors: ['#002213','#000f09'], ic: COLORS.green, screen: 'AdminFinancial' },
  { icon: BarChart2, label: t('adminDashboardScreen.quickActions.reports'),       colors: ['#002213','#000f09'], ic: COLORS.green, screen: 'AdminReports' },
  { icon: Map,       label: t('adminDashboardScreen.quickActions.liveMap'),       colors: ['#001a2e','#000d17'], ic: '#40C4FF',  screen: 'AdminMap' },
  { icon: Wallet,    label: t('adminDashboardScreen.quickActions.withdrawals'),   colors: ['#002213','#000f09'], ic: COLORS.green, screen: 'AdminFinancial' },
  { icon: Megaphone, label: t('adminDashboardScreen.quickActions.ads'),           colors: ['#001a1a','#000d0d'], ic: '#00C4B4',    screen: 'AdApproval' },
  { icon: Phone,     label: t('adminDashboardScreen.quickActions.concierge'),     colors: ['#002213','#000f09'], ic: COLORS.green, screen: 'AdminManagedQuotes' },
  { icon: UserPlus,  label: t('adminDashboardScreen.quickActions.providerApplications'), colors: ['#1a0d3d','#0d0617'], ic: '#CE93D8', screen: 'AdminProviderApplications' },
]);

export default function AdminDashboardScreen({ navigation }: any) {
  const { t } = useTranslation();
  const [refreshing,    setRefreshing]    = useState(false);
  const [unreadNotif,   setUnreadNotif]   = useState(0);

  // Wallet
  const [walletBalance, setWalletBalance] = useState(0);
  const [walletTotal,   setWalletTotal]   = useState(0);

  // KPIs
  const [statusCounts,  setStatusCounts]  = useState({ pending: 0, confirmed: 0, in_progress: 0, completed: 0, cancelled: 0 });
  const [revenueTotal,  setRevenueTotal]  = useState(0);
  const [commTotal,     setCommTotal]     = useState(0);
  const [totalGroups,   setTotalGroups]   = useState(0);
  const [totalClients,  setTotalClients]  = useState(0);
  const [openRequests,  setOpenRequests]  = useState(0);

  // Chart
  const [monthlyBars, setMonthlyBars] = useState<{ label: string; count: number }[]>([]);

  // Lists
  const [topGroups,    setTopGroups]    = useState<{ name: string; count: number; revenue: number }[]>([]);
  const [liveEvents,   setLiveEvents]   = useState<any[]>([]);
  const [todayEvents,  setTodayEvents]  = useState<any[]>([]);
  const [pendingVerif, setPendingVerif] = useState<any[]>([]);
  const [openDisputes,  setOpenDisputes]  = useState<any[]>([]);
  const [pendingMedia,  setPendingMedia]  = useState(0);
  const [pendingAds,    setPendingAds]    = useState(0);
  // Modo conserjería + solicitudes de proveedores (sql/648+649, 2026-09-13) —
  // mismo patrón que pendingMedia/pendingAds, visibles aquí y no solo en la
  // campana de notificaciones.
  const [pendingConciergeQuotes, setPendingConciergeQuotes] = useState(0);
  const [pendingProviderApps,    setPendingProviderApps]    = useState(0);
  const [noShows,       setNoShows]       = useState<any[]>([]);
  const [noShowsHistory,setNoShowsHistory]= useState<any[]>([]);
  const [noShowsTab,    setNoShowsTab]    = useState<'pending' | 'history'>('pending');
  const [stuckEvents,   setStuckEvents]   = useState<any[]>([]);
  // 🔒 sql/641 (2026-09-11) — el otro tipo de "atorado": SÍ iniciaron pero
  // nunca cerraron (p.ej. Comida/renta de mesas y el cliente nunca dio el
  // código de "servicio terminado", sql/639).
  const [stuckServiceEvents, setStuckServiceEvents] = useState<any[]>([]);
  const [unverifiedPayouts, setUnverifiedPayouts] = useState<any[]>([]);
  const [resolvingId,   setResolvingId]   = useState<string | null>(null);

  useEffect(() => { fetchAll(); }, []);
  useEffect(() => {
    const unsub = navigation.addListener('focus', fetchUnread);
    return unsub;
  }, [navigation]);

  const fetchUnread = async () => {
    const { data: sd } = await supabase.auth.getSession();
    if (!sd.session) return;
    const { count } = await supabase
      .from('notifications').select('*', { count: 'exact', head: true })
      .eq('user_id', sd.session.user.id).eq('is_read', false);
    setUnreadNotif(count ?? 0);
  };

  const fetchAll = async () => {
    fetchUnread();

    // Wallet del admin
    const { data: { user } } = await supabase.auth.getUser();
    if (user) {
      const { data: wData } = await supabase
        .from('wallets').select('available_balance, total_earned')
        .eq('user_id', user.id).maybeSingle();
      setWalletBalance(wData?.available_balance ?? 0);
      setWalletTotal(wData?.total_earned ?? 0);
    }

    const todayStr = new Date().toISOString().split('T')[0];

    // Get last 6 months range
    const sixMonthsAgo = new Date();
    sixMonthsAgo.setMonth(sixMonthsAgo.getMonth() - 5);
    sixMonthsAgo.setDate(1);
    const fromDate = sixMonthsAgo.toISOString().split('T')[0];

    const mediaData = await supabase
      .from('groups')
      .select('id', { count: 'exact', head: true })
      .or('photo_status.eq.pending,video_status.eq.pending');
    const eventPostsData = await supabase
      .from('group_event_posts')
      .select('id', { count: 'exact', head: true })
      .eq('status', 'pending');
    const carouselVideosData = await supabase
      .from('group_videos')
      .select('id', { count: 'exact', head: true })
      .eq('status', 'pending');
    setPendingMedia((mediaData.count ?? 0) + (eventPostsData.count ?? 0) + (carouselVideosData.count ?? 0));

    const adsData = await supabase
      .from('advertisements')
      .select('id', { count: 'exact', head: true })
      .eq('status', 'pending_review');
    setPendingAds(adsData.count ?? 0);

    const conciergeData = await supabase.rpc('admin_get_concierge_quotes', { p_limit: 500 });
    setPendingConciergeQuotes(conciergeData.data?.items?.length ?? 0);

    const providerAppsData = await supabase.rpc('admin_get_provider_applications', { p_status: 'pending' });
    setPendingProviderApps(providerAppsData.data?.items?.length ?? 0);

    const [resAll, verData, todayData, disputeData, liveData, groupsData, clientsData, reqData] = await Promise.all([
      supabase.from('reservations').select('status, total_price, created_at, group_id, group:groups(name)'),
      supabase.from('verification_requests').select('id, group:groups(name)').eq('status', 'pending').limit(5),
      supabase.from('reservations').select('id, event_time, group:groups(name), client:profiles(full_name), status').eq('event_date', todayStr).in('status', ['confirmed', 'in_progress']).order('event_time'),
      supabase.from('disputes').select('id, group:groups(name)').eq('status', 'open').limit(5),
      supabase.from('reservations').select('id, group:groups(name), client:profiles(full_name), address').eq('status', 'in_progress').order('event_started_at', { ascending: false }),
      supabase.from('groups').select('id', { count: 'exact', head: true }).eq('is_active', true),
      supabase.from('profiles').select('id', { count: 'exact', head: true }).eq('role', 'client'),
      supabase.from('event_requests').select('id', { count: 'exact', head: true }).eq('status', 'open'),
    ]);

    // 📊 Números de DINERO desde la FUENTE ÚNICA (sql/490) — mismas cifras
    // que la pantalla de Finanzas, mismas fórmulas, cero divergencias.
    // (Antes: SUM(platform_commission) por status — daba números distintos.)
    supabase.rpc('admin_finance_summary', { p_from: null, p_to: null })
      .then(({ data: fin }) => {
        const mxn = ((fin as any)?.currencies ?? []).find((m: any) => m.moneda === 'MXN');
        if (mxn) {
          setRevenueTotal(Number(mxn.total_cobrado ?? 0));
          setCommTotal(Number(mxn.comision_daricefy ?? 0));
        }
      });

    // Process reservations (conteos de estados y gráficas — sin dinero)
    const allRes = resAll.data ?? [];
    const counts = { pending: 0, confirmed: 0, in_progress: 0, completed: 0, cancelled: 0 } as any;
    const groupMap: Record<string, { name: string; count: number; revenue: number }> = {};
    const monthly: Record<string, number> = {};

    allRes.forEach((r: any) => {
      if (counts[r.status] !== undefined) counts[r.status]++;
      if (r.group_id) {
        if (!groupMap[r.group_id]) groupMap[r.group_id] = { name: r.group?.name ?? '—', count: 0, revenue: 0 };
        groupMap[r.group_id].count++;
        if (r.status === 'completed') groupMap[r.group_id].revenue += r.total_price ?? 0;
      }
      const mo = r.created_at?.substring(0, 7);
      if (mo && mo >= fromDate.substring(0, 7)) monthly[mo] = (monthly[mo] ?? 0) + 1;
    });

    // Build monthly chart (last 6 months)
    const bars = Array.from({ length: 6 }, (_, i) => {
      const d = new Date(); d.setMonth(d.getMonth() - (5 - i));
      const key = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}`;
      return { label: MONTH_SHORT[d.getMonth()], count: monthly[key] ?? 0 };
    });

    const top = Object.values(groupMap).sort((a, b) => b.count - a.count).slice(0, 5);

    setStatusCounts(counts);
    setTotalGroups(groupsData.count ?? 0);
    setTotalClients(clientsData.count ?? 0);
    setOpenRequests(reqData.count ?? 0);
    setMonthlyBars(bars);
    setTopGroups(top);
    setLiveEvents(liveData.data ?? []);
    setTodayEvents(todayData.data ?? []);
    setPendingVerif(verData.data ?? []);
    setOpenDisputes(disputeData.data ?? []);

    const { data: nsData }     = await supabase.rpc('admin_get_no_shows',         { p_limit: 50 });
    const { data: nsHistData } = await supabase.rpc('admin_get_no_shows_history', { p_limit: 50 });
    const { data: stuckData }  = await supabase.rpc('admin_get_stuck_events',     { p_limit: 50 });
    const { data: stuckSvcData } = await supabase.rpc('admin_get_stuck_service_events', { p_limit: 50 });
    const { data: unverData }  = await supabase.rpc('admin_get_unverified_payouts',{ p_limit: 50 });
    setNoShows(nsData?.items ?? []);
    setNoShowsHistory(nsHistData?.items ?? []);
    setStuckEvents(stuckData?.items ?? []);
    setStuckServiceEvents(stuckSvcData?.items ?? []);
    setUnverifiedPayouts(unverData?.items ?? []);
  };

  const onRefresh = async () => { setRefreshing(true); await fetchAll(); setRefreshing(false); };

  const resolveNoShow = async (
    reservationId: string,
    groupId: string,
    resolution: 'refunded_100' | 'no_refund' | 'reviewed',
    applyStrike: boolean,
  ) => {
    setResolvingId(reservationId);
    try {
      if (resolution === 'refunded_100') {
        const { data: refundData, error: refundErr } = await supabase.functions.invoke('process-refund', {
          // Idempotency-Key estable: reintentar NUNCA duplica el reembolso
          body: { reservation_id: reservationId, idempotency_key: `noshow-${reservationId}` },
        });
        const refundFailed = refundErr || (refundData as any)?.error;
        if (refundFailed) {
          const detail = (refundData as any)?.error ?? refundErr?.message ?? t('adminDashboardScreen.noShowResolve.refundErrorDefault');
          Alert.alert(
            t('adminDashboardScreen.noShowResolve.refundErrorTitle'),
            t('adminDashboardScreen.noShowResolve.refundErrorMessage', { detail }),
            [
              { text: t('adminDashboardScreen.common.close'), style: 'cancel' },
              { text: t('adminDashboardScreen.common.retry'), onPress: () => resolveNoShow(reservationId, groupId, resolution, applyStrike) },
            ],
          );
          return;
        }
      }
      if (applyStrike) {
        await supabase.rpc('admin_apply_strike', {
          p_group_id:       groupId,
          p_strike_type:    'no_show',
          p_reservation_id: reservationId,
          p_note:           resolution === 'no_refund'
            ? t('adminDashboardScreen.noShowResolve.strikeNoteNoRefund')
            : t('adminDashboardScreen.noShowResolve.strikeNoteNoShow'),
        });
      }
      await supabase.rpc('admin_resolve_no_show', {
        p_reservation_id: reservationId,
        p_resolution:     resolution,
      });
      Alert.alert(
        t('adminDashboardScreen.noShowResolve.resolvedTitle'),
        resolution === 'refunded_100' ? t('adminDashboardScreen.noShowResolve.resolvedRefunded') :
        resolution === 'no_refund'    ? t('adminDashboardScreen.noShowResolve.resolvedNoRefund') :
                                        t('adminDashboardScreen.noShowResolve.resolvedReviewed'),
      );
      await fetchAll();
    } finally {
      setResolvingId(null);
    }
  };

  // Opción B: forzar inicio de un evento atorado (GPS roto, etc.). Auditado
  // en la RPC; la llegada GPS sigue siendo obligatoria (no se salta el anti-fraude).
  const forceStartEvent = async (reservationId: string) => {
    setResolvingId(reservationId);
    try {
      const { data, error } = await supabase.rpc('admin_force_start_event', {
        p_reservation_id: reservationId,
      });
      if (error || (data as any)?.ok === false) {
        Alert.alert(t('adminDashboardScreen.forceStart.errorTitle'), (data as any)?.error ?? error?.message ?? t('adminDashboardScreen.common.tryAgain'));
        return;
      }
      Alert.alert(t('adminDashboardScreen.forceStart.successTitle'), t('adminDashboardScreen.forceStart.successMessage'));
      await fetchAll();
    } finally {
      setResolvingId(null);
    }
  };

  // 🔒 sql/640 — evento que SÍ inició pero nunca cerró (el cliente nunca
  // dio el código de "servicio terminado"). Cierra y libera el pago.
  const forceCompleteEvent = (ev: any) => {
    Alert.alert(
      'Forzar cierre del evento',
      `Esto marca el evento de ${ev.group_name ?? 'este grupo'} como terminado AHORA MISMO y libera el pago pendiente. Confírmalo primero con ambos por teléfono.`,
      [
        { text: 'Cancelar', style: 'cancel' },
        {
          text: 'Sí, forzar cierre', style: 'destructive',
          onPress: async () => {
            setResolvingId(ev.id);
            try {
              const { data, error } = await supabase.rpc('admin_force_complete_event', {
                p_reservation_id: ev.id,
                p_reason: 'Confirmado por soporte vía DashboardScreen',
              });
              if (error || (data as any)?.ok === false) {
                Alert.alert('Error', (data as any)?.error ?? error?.message ?? t('adminDashboardScreen.common.tryAgain'));
                return;
              }
              Alert.alert('Listo', 'El evento quedó cerrado y el pago se liberó.');
              await fetchAll();
            } finally {
              setResolvingId(null);
            }
          },
        },
      ],
    );
  };

  // Marcar/copiar teléfono — SOLO admin (los teléfonos no salen a otros usuarios).
  const handlePhone = (who: string, phone?: string | null) => {
    if (!phone) return;
    Alert.alert(who, phone, [
      { text: t('adminDashboardScreen.phone.call'), onPress: () => Linking.openURL(`tel:${phone}`) },
      { text: t('adminDashboardScreen.phone.copyShare'), onPress: () => Share.share({ message: phone }) },
      { text: t('adminDashboardScreen.common.close'), style: 'cancel' },
    ]);
  };

  // Chips de contacto (grupo/cliente) para las colas del admin. Se renderiza
  // solo si el RPC trae teléfonos (degrada a nada si aún no los trae).
  const renderPhones = (row: any) => {
    if (!row.group_phone && !row.client_phone) return null;
    return (
      <View style={s.phoneRow}>
        {row.group_phone && (
          <Pressable style={s.phoneChip} onPress={() => handlePhone(t('adminDashboardScreen.phone.groupWho', { name: row.group_name ?? '' }), row.group_phone)}>
            <Phone size={12} color={COLORS.green} />
            <Text style={s.phoneChipText}>{t('adminDashboardScreen.phone.callGroup')}</Text>
          </Pressable>
        )}
        {row.client_phone && (
          <Pressable style={s.phoneChip} onPress={() => handlePhone(t('adminDashboardScreen.phone.clientWho', { name: row.client_name ?? '' }), row.client_phone)}>
            <Phone size={12} color={COLORS.green} />
            <Text style={s.phoneChipText}>{t('adminDashboardScreen.phone.callClient')}</Text>
          </Pressable>
        )}
      </View>
    );
  };

  // Evento atorado (confirmed) donde el grupo confirmó que NO irá: primero lo
  // lleva al estado no-show canónico (admin_mark_no_show), luego reusa el flujo
  // EXISTENTE de resolución (reembolso Stripe vía process-refund + strike).
  const markStuckNoShow = async (ev: any, resolution: 'refunded_100' | 'no_refund') => {
    setResolvingId(ev.id);
    try {
      const { data, error } = await supabase.rpc('admin_mark_no_show', { p_reservation_id: ev.id });
      if (error || (data as any)?.ok === false) {
        Alert.alert(t('adminDashboardScreen.stuckMenu.markNoShowErrorTitle'), (data as any)?.error ?? error?.message ?? t('adminDashboardScreen.common.tryAgain'));
        return;
      }
      // resolveNoShow maneja su propio estado/errores (reembolso idempotente + strike + notif)
      await resolveNoShow(ev.id, ev.group_id, resolution, true);
    } finally {
      setResolvingId(null);
    }
  };

  const handleStuckMenu = (ev: any) => {
    const precio = `$${(ev.total_price ?? 0).toLocaleString('es-MX', { maximumFractionDigits: 0 })}`;
    const late   = ev.minutes_late != null ? t('adminDashboardScreen.stuckMenu.lateSuffix', { minutes: ev.minutes_late }) : '';
    Alert.alert(
      t('adminDashboardScreen.stuckMenu.title'),
      t('adminDashboardScreen.stuckMenu.message', {
        group: ev.group_name ?? t('adminDashboardScreen.stuckMenu.groupFallback'),
        folio: ev.folio ?? ev.id.substring(0, 8),
        client: ev.client_name ?? '—',
        price: precio,
        late,
      }),
      [
        {
          text: t('adminDashboardScreen.stuckMenu.forceStartOption'),
          onPress: () => Alert.alert(
            t('adminDashboardScreen.stuckMenu.forceStartTitle'),
            t('adminDashboardScreen.stuckMenu.forceStartMessage'),
            [
              { text: t('adminDashboardScreen.common.cancel'), style: 'cancel' },
              { text: t('adminDashboardScreen.stuckMenu.forceStartButton'), onPress: () => forceStartEvent(ev.id) },
            ]
          ),
        },
        {
          text: t('adminDashboardScreen.stuckMenu.refundOption'),
          onPress: () => Alert.alert(
            t('adminDashboardScreen.stuckMenu.refundConfirmTitle'),
            t('adminDashboardScreen.stuckMenu.refundConfirmMessage', { price: precio }),
            [
              { text: t('adminDashboardScreen.common.cancel'), style: 'cancel' },
              { text: t('adminDashboardScreen.common.confirm'), onPress: () => markStuckNoShow(ev, 'refunded_100') },
            ]
          ),
        },
        {
          text: t('adminDashboardScreen.stuckMenu.noRefundOption'),
          style: 'destructive',
          onPress: () => Alert.alert(
            t('adminDashboardScreen.stuckMenu.noRefundConfirmTitle'),
            t('adminDashboardScreen.stuckMenu.noRefundConfirmMessage'),
            [
              { text: t('adminDashboardScreen.common.cancel'), style: 'cancel' },
              { text: t('adminDashboardScreen.common.apply'), style: 'destructive', onPress: () => markStuckNoShow(ev, 'no_refund') },
            ]
          ),
        },
        { text: t('adminDashboardScreen.common.close'), style: 'cancel' },
      ]
    );
  };

  const verifyAndReleasePayout = async (ev: any) => {
    setResolvingId(ev.id);
    try {
      const { data, error } = await supabase.rpc('admin_verify_arrival_and_release', { p_reservation_id: ev.id });
      const rel = (data as any)?.release;
      if (error || (data as any)?.ok === false) {
        Alert.alert(t('adminDashboardScreen.unverifiedPayouts.releaseErrorTitle'), (data as any)?.error ?? error?.message ?? t('adminDashboardScreen.common.tryAgain'));
        return;
      }
      if (rel && rel.ok && rel.skipped) {
        Alert.alert(t('adminDashboardScreen.unverifiedPayouts.notReleasedTitle'), t('adminDashboardScreen.unverifiedPayouts.notReleasedMessage', { reason: rel.reason ?? t('adminDashboardScreen.unverifiedPayouts.unknownReason') }));
      } else {
        Alert.alert(t('adminDashboardScreen.unverifiedPayouts.releasedTitle'), t('adminDashboardScreen.unverifiedPayouts.releasedMessage'));
      }
      await fetchAll();
    } finally {
      setResolvingId(null);
    }
  };

  const blockUnverifiedPayout = async (ev: any) => {
    setResolvingId(ev.id);
    try {
      const { data, error } = await supabase.rpc('admin_block_unverified_payout', { p_reservation_id: ev.id });
      if (error || (data as any)?.ok === false) {
        Alert.alert(t('adminDashboardScreen.unverifiedPayouts.blockErrorTitle'), (data as any)?.error ?? error?.message ?? t('adminDashboardScreen.common.tryAgain'));
        return;
      }
      Alert.alert(t('adminDashboardScreen.unverifiedPayouts.blockedTitle'), t('adminDashboardScreen.unverifiedPayouts.blockedMessage'));
      await fetchAll();
    } finally {
      setResolvingId(null);
    }
  };

  const handleUnverifiedMenu = (ev: any) => {
    const precio = `$${(ev.total_price ?? 0).toLocaleString('es-MX', { maximumFractionDigits: 0 })}`;
    Alert.alert(
      t('adminDashboardScreen.unverifiedPayouts.menuTitle'),
      t('adminDashboardScreen.unverifiedPayouts.menuMessage', {
        group: ev.group_name ?? t('adminDashboardScreen.stuckMenu.groupFallback'),
        folio: ev.folio ?? ev.id.substring(0, 8),
        client: ev.client_name ?? '—',
        price: precio,
      }),
      [
        {
          text: t('adminDashboardScreen.unverifiedPayouts.arrivedOption'),
          onPress: () => Alert.alert(t('adminDashboardScreen.unverifiedPayouts.releaseConfirmTitle'),
            t('adminDashboardScreen.unverifiedPayouts.releaseConfirmMessage'),
            [
              { text: t('adminDashboardScreen.common.cancel'), style: 'cancel' },
              { text: t('adminDashboardScreen.unverifiedPayouts.releaseButton'), onPress: () => verifyAndReleasePayout(ev) },
            ]),
        },
        {
          text: t('adminDashboardScreen.unverifiedPayouts.notArrivedOption'),
          style: 'destructive',
          onPress: () => Alert.alert(t('adminDashboardScreen.unverifiedPayouts.blockConfirmTitle'),
            t('adminDashboardScreen.unverifiedPayouts.blockConfirmMessage'),
            [
              { text: t('adminDashboardScreen.common.cancel'), style: 'cancel' },
              { text: t('adminDashboardScreen.unverifiedPayouts.blockButton'), style: 'destructive', onPress: () => blockUnverifiedPayout(ev) },
            ]),
        },
        { text: t('adminDashboardScreen.common.close'), style: 'cancel' },
      ]
    );
  };

  const handleNoShowMenu = (ns: any) => {
    const precio = `$${(ns.total_price ?? 0).toLocaleString('es-MX', { maximumFractionDigits: 0 })}`;
    Alert.alert(
      t('adminDashboardScreen.noShowMenu.title'),
      t('adminDashboardScreen.noShowMenu.message', {
        group: ns.group_name ?? t('adminDashboardScreen.stuckMenu.groupFallback'),
        folio: ns.folio ?? ns.id.substring(0, 8),
        client: ns.client_name ?? '—',
        price: precio,
      }),
      [
        {
          text: t('adminDashboardScreen.noShowMenu.refundOption'),
          onPress: () => Alert.alert(
            t('adminDashboardScreen.stuckMenu.refundConfirmTitle'),
            t('adminDashboardScreen.noShowMenu.refundConfirmMessage', { price: precio }),
            [
              { text: t('adminDashboardScreen.common.cancel'), style: 'cancel' },
              { text: t('adminDashboardScreen.common.confirm'), onPress: () => resolveNoShow(ns.id, ns.group_id, 'refunded_100', true) },
            ]
          ),
        },
        {
          text: t('adminDashboardScreen.noShowMenu.noRefundOption'),
          style: 'destructive',
          onPress: () => Alert.alert(
            t('adminDashboardScreen.stuckMenu.noRefundConfirmTitle'),
            t('adminDashboardScreen.noShowMenu.noRefundConfirmMessage'),
            [
              { text: t('adminDashboardScreen.common.cancel'), style: 'cancel' },
              { text: t('adminDashboardScreen.common.apply'), style: 'destructive', onPress: () => resolveNoShow(ns.id, ns.group_id, 'no_refund', true) },
            ]
          ),
        },
        {
          // Archivar SÍ resuelve (lo saca de la cola al historial) — con
          // confirmación, porque antes "Cerrar sin acción" archivaba en
          // silencio y parecía que solo cerraba la ventana.
          text: t('adminDashboardScreen.noShowMenu.archiveOption'),
          onPress: () => Alert.alert(
            t('adminDashboardScreen.noShowMenu.archiveConfirmTitle'),
            t('adminDashboardScreen.noShowMenu.archiveConfirmMessage'),
            [
              { text: t('adminDashboardScreen.common.cancel'), style: 'cancel' },
              { text: t('adminDashboardScreen.noShowMenu.archiveButton'), onPress: () => resolveNoShow(ns.id, ns.group_id, 'reviewed', false) },
            ]
          ),
        },
        { text: t('adminDashboardScreen.common.close'), style: 'cancel' },
      ]
    );
  };

  const maxBar = Math.max(...monthlyBars.map(b => b.count), 1);
  const maxTopCount = Math.max(...topGroups.map(g => g.count), 1);
  const totalRes = Object.values(statusCounts).reduce((a, b) => a + b, 0);
  const hasAlerts = pendingVerif.length > 0 || openDisputes.length > 0 || statusCounts.pending > 0 || pendingMedia > 0 || pendingAds > 0 || noShows.length > 0 || stuckEvents.length > 0 || stuckServiceEvents.length > 0 || unverifiedPayouts.length > 0 || pendingConciergeQuotes > 0 || pendingProviderApps > 0;

  const today = new Date();
  const dateStr = today.toLocaleDateString('es-MX', { weekday: 'long', day: 'numeric', month: 'long' });

  const STATUS_CHIPS = getStatusChips(t);
  const QUICK_ACTIONS = getQuickActions(t);

  return (
    <View style={s.root}>
      <Particles />
      <SafeAreaView edges={['top']} style={{ flex: 1 }}>
        <ScrollView
          showsVerticalScrollIndicator={false}
          refreshControl={<RefreshControl refreshing={refreshing} onRefresh={onRefresh} tintColor={COLORS.green} />}
        >
          {/* ── HEADER ─────────────────────────────────────────────────────── */}
          <View style={s.header}>
            <View>
              <Text style={s.logo}>Darice<Text style={{ color: COLORS.green }}>fy</Text></Text>
              <Text style={s.dateTag}>{dateStr}</Text>
            </View>
            <View style={s.headerRight}>
              {/* 📂 Expediente: buscar por folio, nombre o teléfono */}
              <Pressable style={s.iconBtn} onPress={() => navigation.navigate('AdminTicketSearch')}>
                <Text style={{ fontSize: 15 }}>📂</Text>
              </Pressable>
              <Pressable style={s.iconBtn} onPress={onRefresh}>
                <RefreshCw size={16} color={COLORS.muted2} />
              </Pressable>
              <Pressable style={s.iconBtn} onPress={() => navigation.navigate('Notifications')}>
                <Bell size={16} color={COLORS.muted2} />
                {unreadNotif > 0 && (
                  <View style={s.notifDot}><Text style={s.notifDotText}>{unreadNotif > 99 ? '99+' : unreadNotif}</Text></View>
                )}
              </Pressable>
            </View>
          </View>

          {/* ── WALLET ADMIN ─────────────────────────────────────────────── */}
          <Pressable style={s.walletWidget} onPress={() => navigation.navigate('Wallet')}>
            <LinearGradient
              colors={['rgba(0,230,118,0.10)', 'rgba(0,200,83,0.04)']}
              style={StyleSheet.absoluteFill}
              start={{ x: 0, y: 0 }} end={{ x: 1, y: 1 }}
            />
            <View style={s.walletLeft}>
              <Wallet size={20} color={COLORS.green} />
              <View>
                <Text style={s.walletLabel}>Mi billetera</Text>
                <Text style={s.walletAmount} numberOfLines={1} adjustsFontSizeToFit>
                  ${walletBalance.toLocaleString('es-MX', { minimumFractionDigits: 0 })}
                  <Text style={s.walletAmountSub}> disponible</Text>
                </Text>
                <Text style={s.walletTotal}>
                  Total acumulado: ${walletTotal.toLocaleString('es-MX', { minimumFractionDigits: 0 })}
                </Text>
              </View>
            </View>
            <View style={s.walletRight}>
              <Pressable style={s.walletWithdrawBtn} onPress={() => navigation.navigate('Withdraw', { available: walletBalance })}>
                <Text style={s.walletWithdrawText}>Retirar →</Text>
              </Pressable>
            </View>
          </Pressable>

          {/* ── STATUS KPI CHIPS ───────────────────────────────────────────── */}
          <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={s.statusRow} style={{ marginBottom: 20 }}>
            {([
              { key: 'pending',     label: 'Pendientes',  color: '#FF9800', bg: 'rgba(255,152,0,0.15)'     },
              { key: 'confirmed',   label: 'Confirmadas', color: '#00E676', bg: 'rgba(0,230,118,0.12)'     },
              { key: 'in_progress', label: 'En curso',    color: '#40C4FF', bg: 'rgba(64,196,255,0.12)'    },
              { key: 'completed',   label: 'Completadas', color: '#B0BEC5', bg: 'rgba(176,190,197,0.12)'   },
              { key: 'cancelled',   label: 'Canceladas',  color: '#FF5252', bg: 'rgba(255,82,82,0.12)'     },
            ] as const).map(st => (
              <View key={st.key} style={[s.statusChip, { backgroundColor: st.bg, borderColor: st.color + '60' }]}>
                <Text style={[s.statusNum, { color: st.color }]}>{(statusCounts as any)[st.key]}</Text>
                <Text style={s.statusLbl}>{st.label}</Text>
              </View>
            ))}
          </ScrollView>

          {/* ── KPI CARDS ─────────────────────────────────────────────────── */}
          <View style={s.kpiRow}>
            <LinearGradient colors={['#002213','#000d09']} style={s.kpiCard} start={{ x: 0, y: 0 }} end={{ x: 1, y: 1 }}>
              <View style={s.kpiIconWrap}>
                <DollarSign size={18} color={COLORS.green} />
              </View>
              <Text style={s.kpiLabel}>Ingresos plataforma</Text>
              <Text style={s.kpiValue} numberOfLines={1} adjustsFontSizeToFit>
                ${commTotal.toLocaleString('es-MX', { maximumFractionDigits: 0 })}
              </Text>
              <Text style={s.kpiSub}>de ${revenueTotal.toLocaleString('es-MX', { maximumFractionDigits: 0 })} facturados</Text>
            </LinearGradient>
            <LinearGradient colors={['#001a2e','#000d17']} style={s.kpiCard} start={{ x: 0, y: 0 }} end={{ x: 1, y: 1 }}>
              <View style={[s.kpiIconWrap, { backgroundColor: 'rgba(64,196,255,0.15)' }]}>
                <TrendingUp size={18} color='#40C4FF' />
              </View>
              <Text style={s.kpiLabel}>Total reservas</Text>
              <Text style={[s.kpiValue, { color: '#40C4FF' }]}>{totalRes}</Text>
              <Text style={s.kpiSub}>{openRequests} solicitudes ⚡ abiertas</Text>
            </LinearGradient>
          </View>

          <View style={s.kpiRow}>
            <LinearGradient colors={['#1a0d00','#0d0600']} style={s.kpiCard} start={{ x: 0, y: 0 }} end={{ x: 1, y: 1 }}>
              <View style={[s.kpiIconWrap, { backgroundColor: 'rgba(255,152,0,0.15)' }]}>
                <Users size={18} color={COLORS.gold} />
              </View>
              <Text style={s.kpiLabel}>Grupos activos</Text>
              <Text style={[s.kpiValue, { color: COLORS.gold }]}>{totalGroups}</Text>
              <Text style={s.kpiSub}>{totalClients} clientes registrados</Text>
            </LinearGradient>
            <LinearGradient colors={['#1a0d2e','#0d0617']} style={s.kpiCard} start={{ x: 0, y: 0 }} end={{ x: 1, y: 1 }}>
              <View style={[s.kpiIconWrap, { backgroundColor: 'rgba(156,39,176,0.15)' }]}>
                <Zap size={18} color='#CE93D8' />
              </View>
              <Text style={s.kpiLabel}>Eventos hoy</Text>
              <Text style={[s.kpiValue, { color: '#CE93D8' }]}>{todayEvents.length}</Text>
              <Text style={s.kpiSub}>{liveEvents.length} en curso ahora</Text>
            </LinearGradient>
          </View>

          {/* ── 📊 PANEL EJECUTIVO ─────────────────────────────────────────── */}
          <Pressable style={s.reportsBand} onPress={() => navigation.navigate('AdminReports')}>
            <Text style={s.reportsBandTx}>📊 Reportes — panel ejecutivo</Text>
            <Text style={s.reportsBandSub}>
              Dinero, eventos y comunidad por país · filtros y exportar Excel/PDF →
            </Text>
          </Pressable>

          {/* ── ALERTAS ───────────────────────────────────────────────────── */}
          {hasAlerts && (
            <View style={s.alertStrip}>
              <Text style={s.alertTitle}>⚠️ Requieren atención</Text>
              <View style={s.alertChips}>
                {statusCounts.pending > 0 && (
                  <View style={[s.alertChip, { borderColor: 'rgba(255,152,0,0.5)' }]}>
                    <Text style={[s.alertChipNum, { color: COLORS.orange }]}>{statusCounts.pending}</Text>
                    <Text style={s.alertChipLbl}>Reservas</Text>
                  </View>
                )}
                {pendingVerif.length > 0 && (
                  <Pressable style={[s.alertChip, { borderColor: 'rgba(64,196,255,0.5)' }]} onPress={() => navigation.navigate('AdminVerifications')}>
                    <Text style={[s.alertChipNum, { color: '#40C4FF' }]}>{pendingVerif.length}</Text>
                    <Text style={s.alertChipLbl}>Verif.</Text>
                  </Pressable>
                )}
                {openDisputes.length > 0 && (
                  <Pressable style={[s.alertChip, { borderColor: 'rgba(255,82,82,0.5)' }]} onPress={() => navigation.navigate('AdminDisputes')}>
                    <Text style={[s.alertChipNum, { color: COLORS.red }]}>{openDisputes.length}</Text>
                    <Text style={s.alertChipLbl}>Disputas</Text>
                  </Pressable>
                )}
                {pendingMedia > 0 && (
                  <Pressable style={[s.alertChip, { borderColor: 'rgba(156,39,176,0.5)' }]} onPress={() => navigation.navigate('AdminMediaReview')}>
                    <Text style={[s.alertChipNum, { color: '#CE93D8' }]}>{pendingMedia}</Text>
                    <Text style={s.alertChipLbl}>Medios</Text>
                  </Pressable>
                )}
                {pendingAds > 0 && (
                  <Pressable style={[s.alertChip, { borderColor: 'rgba(0,196,180,0.5)' }]} onPress={() => navigation.navigate('AdApproval')}>
                    <Text style={[s.alertChipNum, { color: '#00C4B4' }]}>{pendingAds}</Text>
                    <Text style={s.alertChipLbl}>Anuncios</Text>
                  </Pressable>
                )}
                {noShows.length > 0 && (
                  <View style={[s.alertChip, { borderColor: 'rgba(255,82,82,0.5)' }]}>
                    <Text style={[s.alertChipNum, { color: COLORS.red }]}>{noShows.length}</Text>
                    <Text style={s.alertChipLbl}>No-Shows</Text>
                  </View>
                )}
                {stuckEvents.length > 0 && (
                  <View style={[s.alertChip, { borderColor: 'rgba(255,152,0,0.5)' }]}>
                    <Text style={[s.alertChipNum, { color: COLORS.orange }]}>{stuckEvents.length}</Text>
                    <Text style={s.alertChipLbl}>Atorados</Text>
                  </View>
                )}
                {stuckServiceEvents.length > 0 && (
                  <View style={[s.alertChip, { borderColor: 'rgba(255,152,0,0.5)' }]}>
                    <Text style={[s.alertChipNum, { color: COLORS.orange }]}>{stuckServiceEvents.length}</Text>
                    <Text style={s.alertChipLbl}>Sin cerrar</Text>
                  </View>
                )}
                {unverifiedPayouts.length > 0 && (
                  <View style={[s.alertChip, { borderColor: 'rgba(64,196,255,0.5)' }]}>
                    <Text style={[s.alertChipNum, { color: '#40C4FF' }]}>{unverifiedPayouts.length}</Text>
                    <Text style={s.alertChipLbl}>Verificar</Text>
                  </View>
                )}
                {pendingConciergeQuotes > 0 && (
                  <Pressable style={[s.alertChip, { borderColor: 'rgba(0,230,118,0.5)' }]} onPress={() => navigation.navigate('AdminManagedQuotes')}>
                    <Text style={[s.alertChipNum, { color: COLORS.green }]}>{pendingConciergeQuotes}</Text>
                    <Text style={s.alertChipLbl}>Por llamar</Text>
                  </Pressable>
                )}
                {pendingProviderApps > 0 && (
                  <Pressable style={[s.alertChip, { borderColor: 'rgba(206,147,216,0.5)' }]} onPress={() => navigation.navigate('AdminProviderApplications')}>
                    <Text style={[s.alertChipNum, { color: '#CE93D8' }]}>{pendingProviderApps}</Text>
                    <Text style={s.alertChipLbl}>Solicitudes</Text>
                  </Pressable>
                )}
              </View>
            </View>
          )}

          {/* ── EVENTOS EN VIVO ───────────────────────────────────────────── */}
          {liveEvents.length > 0 && (
            <View style={s.section}>
              <View style={s.sectionHeader}>
                <View style={s.liveIndicator} />
                <Text style={s.sectionTitle}>En curso ({liveEvents.length})</Text>
              </View>
              {liveEvents.map(r => (
                <View key={r.id} style={[s.eventRow, { borderLeftColor: COLORS.green }]}>
                  <View style={{ flex: 1 }}>
                    <Text style={s.eventGroup}>{r.group?.name ?? '—'}</Text>
                    <Text style={s.eventSub}>{r.client?.full_name ?? '—'}</Text>
                  </View>
                  <Badge label="En vivo" variant="green" dot />
                </View>
              ))}
            </View>
          )}

          {/* ── EVENTOS HOY ───────────────────────────────────────────────── */}
          {todayEvents.length > 0 && (
            <View style={s.section}>
              <View style={s.sectionHeader}>
                <Text style={s.sectionTitle}>Eventos hoy</Text>
              </View>
              {todayEvents.map(r => (
                <View key={r.id} style={[s.eventRow, { borderLeftColor: r.status === 'in_progress' ? COLORS.blue : COLORS.green }]}>
                  <View style={{ flex: 1 }}>
                    <Text style={s.eventGroup}>{r.group?.name ?? '—'}</Text>
                    <Text style={s.eventSub}>{r.client?.full_name ?? '—'}{r.event_time ? ` · ${r.event_time}` : ''}</Text>
                  </View>
                  <Badge label={r.status === 'in_progress' ? 'En curso' : 'Confirmada'} variant={r.status === 'in_progress' ? 'blue' : 'green'} dot />
                </View>
              ))}
            </View>
          )}

          {/* ── GRÁFICA MENSUAL ──────────────────────────────────────────── */}
          <View style={s.section}>
            <View style={s.sectionHeader}>
              <BarChart2 size={14} color={COLORS.green} />
              <Text style={s.sectionTitle}>Reservas mensuales</Text>
            </View>
            <View style={s.chartWrap}>
              <View style={s.chart}>
                {monthlyBars.map((bar, i) => {
                  const pct = bar.count / maxBar;
                  return (
                    <View key={i} style={s.barCol}>
                      {bar.count > 0 && (
                        <Text style={s.barNum}>{bar.count}</Text>
                      )}
                      <View style={s.barBg}>
                        <LinearGradient
                          colors={[COLORS.green, '#00C853']}
                          style={[s.barFill, { height: `${Math.max(pct * 100, 4)}%` }]}
                          start={{ x: 0, y: 0 }} end={{ x: 0, y: 1 }}
                        />
                      </View>
                      <Text style={s.barLabel}>{bar.label}</Text>
                    </View>
                  );
                })}
              </View>
            </View>
          </View>

          {/* ── TOP GRUPOS ────────────────────────────────────────────────── */}
          {topGroups.length > 0 && (
            <View style={s.section}>
              <View style={s.sectionHeader}>
                <Text style={s.sectionTitle}>Top grupos por reservas</Text>
              </View>
              {topGroups.map((g, i) => {
                const pct = g.count / maxTopCount;
                const ACCENT = ['#00E676','#40C4FF','#FFB300','#CE93D8','#FF7043'][i] ?? COLORS.green;
                return (
                  <View key={i} style={s.topGroupRow}>
                    <View style={[s.topGroupRank, { backgroundColor: ACCENT + '22' }]}>
                      <Text style={[s.topGroupRankNum, { color: ACCENT }]}>{i + 1}</Text>
                    </View>
                    <View style={{ flex: 1 }}>
                      <View style={s.topGroupNameRow}>
                        <Text style={s.topGroupName} numberOfLines={1}>{g.name}</Text>
                        <Text style={[s.topGroupCount, { color: ACCENT }]}>{g.count} res.</Text>
                      </View>
                      <View style={s.topGroupBarBg}>
                        <View style={[s.topGroupBarFill, { width: `${pct * 100}%`, backgroundColor: ACCENT }]} />
                      </View>
                    </View>
                  </View>
                );
              })}
            </View>
          )}

          {/* ── DISPUTAS / VERIFICACIONES ─────────────────────────────────── */}
          {openDisputes.length > 0 && (
            <View style={s.section}>
              <View style={s.sectionHeader}>
                <Text style={s.sectionTitle}>Disputas abiertas</Text>
                <Pressable onPress={() => navigation.navigate('AdminDisputes')}>
                  <Text style={s.seeAll}>Ver todas →</Text>
                </Pressable>
              </View>
              {openDisputes.map(d => (
                <Pressable key={d.id} style={[s.eventRow, { borderLeftColor: COLORS.red }]} onPress={() => navigation.navigate('AdminDisputes', { disputeId: d.id })}>
                  <AlertCircle size={13} color={COLORS.red} />
                  <Text style={[s.eventGroup, { flex: 1, marginLeft: 8 }]}>{d.group?.name ?? 'Grupo'}</Text>
                  <Badge label="Abierta" variant="red" />
                </Pressable>
              ))}
            </View>
          )}
          {pendingVerif.length > 0 && (
            <View style={s.section}>
              <View style={s.sectionHeader}>
                <Text style={s.sectionTitle}>Verificaciones pendientes</Text>
                <Pressable onPress={() => navigation.navigate('AdminVerifications')}>
                  <Text style={s.seeAll}>Ver todas →</Text>
                </Pressable>
              </View>
              {pendingVerif.map(v => (
                <Pressable key={v.id} style={[s.eventRow, { borderLeftColor: '#40C4FF' }]} onPress={() => navigation.navigate('AdminVerifications', { requestId: v.id })}>
                  <Shield size={13} color='#40C4FF' />
                  <Text style={[s.eventGroup, { flex: 1, marginLeft: 8 }]}>{v.group?.name ?? 'Grupo'}</Text>
                  <Badge label="Pendiente" variant="orange" />
                </Pressable>
              ))}
            </View>
          )}

          {/* ── VERIFICAR LLEGADA (pagos retenidos) ───────────────────────── */}
          {unverifiedPayouts.length > 0 && (
            <View style={[s.section, s.unverifiedSection]}>
              <View style={s.sectionHeader}>
                <AlertCircle size={14} color="#40C4FF" />
                <Text style={[s.sectionTitle, { color: '#40C4FF' }]}>
                  Verificar llegada ({unverifiedPayouts.length})
                </Text>
              </View>
              <Text style={s.stuckHint}>
                Eventos pagados cuyo grupo nunca marcó llegada GPS → el pago quedó retenido. Llama para confirmar si tocó, y libera o bloquea.
              </Text>
              {unverifiedPayouts.map((ev: any) => (
                <View key={ev.id} style={s.noShowRow}>
                  <View style={{ flex: 1 }}>
                    <Text style={s.noShowFolio}>{ev.folio ?? ev.id.substring(0, 8)}</Text>
                    <Text style={s.noShowGroup}>{ev.group_name ?? '—'}</Text>
                    <Text style={s.noShowMeta}>
                      {ev.client_name ?? '—'}  ·  {ev.event_date}{ev.event_time ? `  ${ev.event_time}` : ''}
                    </Text>
                    <Text style={s.noShowMeta}>
                      ${(ev.total_price ?? 0).toLocaleString('es-MX', { maximumFractionDigits: 0 })}  ·  {ev.status}
                    </Text>
                    {renderPhones(ev)}
                  </View>
                  <View style={s.noShowActions}>
                    <Pressable
                      style={[s.resolveBtn, resolvingId === ev.id && { opacity: 0.45 }]}
                      onPress={() => handleUnverifiedMenu(ev)}
                      disabled={resolvingId === ev.id}
                    >
                      <Text style={s.resolveBtnText}>
                        {resolvingId === ev.id ? '…' : 'Resolver →'}
                      </Text>
                    </Pressable>
                  </View>
                </View>
              ))}
            </View>
          )}

          {/* ── EVENTOS ATORADOS ──────────────────────────────────────────── */}
          {stuckEvents.length > 0 && (
            <View style={[s.section, s.stuckSection]}>
              <View style={s.sectionHeader}>
                <AlertCircle size={14} color={COLORS.orange} />
                <Text style={[s.sectionTitle, { color: COLORS.orange }]}>
                  Eventos atorados ({stuckEvents.length})
                </Text>
              </View>
              <Text style={s.stuckHint}>
                Confirmados y pagados, con la hora ya pasada y sin llegada GPS. Fuerza el inicio si el grupo sí está tocando. La llegada real sigue siendo obligatoria; el pago se libera al finalizar.
              </Text>
              {stuckEvents.map((ev: any) => (
                <View key={ev.id} style={s.noShowRow}>
                  <View style={{ flex: 1 }}>
                    <Text style={s.noShowFolio}>{ev.folio ?? ev.id.substring(0, 8)}</Text>
                    <Text style={s.noShowGroup}>{ev.group_name ?? '—'}</Text>
                    <Text style={s.noShowMeta}>
                      {ev.client_name ?? '—'}  ·  {ev.event_date}{ev.event_time ? `  ${ev.event_time}` : ''}
                    </Text>
                    <Text style={s.noShowMeta}>
                      ${(ev.total_price ?? 0).toLocaleString('es-MX', { maximumFractionDigits: 0 })}{ev.minutes_late != null ? `  ·  ⏱ ${ev.minutes_late} min tarde` : ''}
                    </Text>
                    {renderPhones(ev)}
                  </View>
                  <View style={s.noShowActions}>
                    <Pressable
                      style={[s.resolveBtn, resolvingId === ev.id && { opacity: 0.45 }]}
                      onPress={() => handleStuckMenu(ev)}
                      disabled={resolvingId === ev.id}
                    >
                      <Text style={s.resolveBtnText}>
                        {resolvingId === ev.id ? '…' : 'Resolver →'}
                      </Text>
                    </Pressable>
                    <Pressable
                      style={s.detailBtn}
                      onPress={() => navigation.navigate('AdminTicketSearch', { reservationId: ev.id })}
                    >
                      <Text style={s.detailBtnText}>Ver</Text>
                    </Pressable>
                  </View>
                </View>
              ))}
            </View>
          )}

          {/* ── EVENTOS ATORADOS SIN CERRAR (sql/639+640+641, 2026-09-11) ──
              El otro tipo de atorado: SÍ iniciaron pero nunca cerraron —
              típico de Comida/renta de mesas/etc. cuando el cliente nunca
              le dio al proveedor el código de "servicio terminado". */}
          {stuckServiceEvents.length > 0 && (
            <View style={[s.section, s.stuckSection]}>
              <View style={s.sectionHeader}>
                <AlertCircle size={14} color={COLORS.orange} />
                <Text style={[s.sectionTitle, { color: COLORS.orange }]}>
                  Eventos sin cerrar ({stuckServiceEvents.length})
                </Text>
              </View>
              <Text style={s.stuckHint}>
                Iniciaron pero nunca se cerraron — normalmente porque el cliente nunca le dio al proveedor el código de "servicio terminado". Confirma con ambos por teléfono antes de forzar el cierre; libera el pago pendiente del grupo.
              </Text>
              {stuckServiceEvents.map((ev: any) => (
                <View key={ev.id} style={s.noShowRow}>
                  <View style={{ flex: 1 }}>
                    <Text style={s.noShowFolio}>{ev.folio ?? ev.id.substring(0, 8)}</Text>
                    <Text style={s.noShowGroup}>{ev.group_name ?? '—'}{ev.group_genre ? ` · ${ev.group_genre}` : ''}</Text>
                    <Text style={s.noShowMeta}>
                      {ev.client_name ?? '—'}  ·  {ev.event_date}{ev.event_time ? `  ${ev.event_time}` : ''}
                    </Text>
                    <Text style={s.noShowMeta}>
                      ${(ev.total_price ?? 0).toLocaleString('es-MX', { maximumFractionDigits: 0 })} {ev.currency}{'  ·  '}⏱ lleva {ev.hours_stuck}h sin cerrarse
                    </Text>
                    {renderPhones(ev)}
                  </View>
                  <View style={s.noShowActions}>
                    <Pressable
                      style={[s.resolveBtn, resolvingId === ev.id && { opacity: 0.45 }]}
                      onPress={() => forceCompleteEvent(ev)}
                      disabled={resolvingId === ev.id}
                    >
                      <Text style={s.resolveBtnText}>
                        {resolvingId === ev.id ? '…' : 'Forzar cierre →'}
                      </Text>
                    </Pressable>
                    <Pressable
                      style={s.detailBtn}
                      onPress={() => navigation.navigate('AdminTicketSearch', { reservationId: ev.id })}
                    >
                      <Text style={s.detailBtnText}>Ver</Text>
                    </Pressable>
                  </View>
                </View>
              ))}
            </View>
          )}

          {/* ── NO-SHOWS ──────────────────────────────────────────────────── */}
          {(noShows.length > 0 || noShowsHistory.length > 0) && (
            <View style={[s.section, noShows.length > 0 && s.noShowSection]}>
              <View style={s.sectionHeader}>
                <AlertCircle size={14} color={noShows.length > 0 ? COLORS.red : COLORS.muted2} />
                <Text style={[s.sectionTitle, noShows.length > 0 && { color: COLORS.red }]}>
                  No-Shows
                </Text>
                {noShows.length > 0 && (
                  <Text style={s.nsMoneyAtStake}>
                    ${noShows.reduce((sum: number, n: any) => sum + (n.total_price ?? 0), 0).toLocaleString('es-MX', { maximumFractionDigits: 0 })} en juego
                  </Text>
                )}
              </View>

              {/* Toggle pendientes / historial */}
              <View style={s.nsTabRow}>
                <Pressable
                  style={[s.nsTab, noShowsTab === 'pending' && s.nsTabActive]}
                  onPress={() => setNoShowsTab('pending')}
                >
                  <Text style={[s.nsTabText, noShowsTab === 'pending' && s.nsTabTextActive]}>
                    ⚠️ Pendientes ({noShows.length})
                  </Text>
                </Pressable>
                <Pressable
                  style={[s.nsTab, noShowsTab === 'history' && s.nsTabActive]}
                  onPress={() => setNoShowsTab('history')}
                >
                  <Text style={[s.nsTabText, noShowsTab === 'history' && s.nsTabTextActive]}>
                    📋 Historial ({noShowsHistory.length})
                  </Text>
                </Pressable>
              </View>

              {/* ── Pendientes ── */}
              {noShowsTab === 'pending' && (
                noShows.length === 0
                  ? <Text style={s.nsEmpty}>Sin no-shows pendientes.</Text>
                  : noShows.map((ns: any) => (
                      <View key={ns.id} style={s.noShowRow}>
                        <View style={{ flex: 1 }}>
                          <Text style={s.noShowFolio}>{ns.folio ?? ns.id.substring(0, 8)}</Text>
                          <Text style={s.noShowGroup}>{flagFor(ns.country_code)} {ns.group_name ?? '—'}</Text>
                          <Text style={s.noShowMeta}>
                            {placeLine(ns)}
                          </Text>
                          <Text style={s.noShowMeta}>
                            {ns.client_name ?? '—'}  ·  {ns.event_date}{ns.event_time ? `  ${ns.event_time}` : ''}
                          </Text>
                          <Text style={s.noShowMeta}>
                            ${(ns.total_price ?? 0).toLocaleString('es-MX', { maximumFractionDigits: 0 })} {ns.currency ?? 'MXN'}  ·  payout: {ns.payout_status}{ns.has_strike ? '  · ⚡ Strike previo' : ''}
                          </Text>
                          {/* 🗺️ Evidencia GPS (sql/487): rastro, PIN y llegada */}
                          <Text style={s.noShowMeta}>
                            🚐 En camino: {ns.group_en_route_at ? '✅ sí' : '✖️ no'}
                            {'  ·  '}🔢 Inició con PIN: {ns.event_started_at ? '✅ sí' : '✖️ no'}
                            {'  ·  '}📍 Llegada: {ns.group_arrived_at ? (ns.arrival_gps_verified ? '✅ GPS' : '⚠️ sin GPS') : '✖️ no'}
                          </Text>
                          {(ns.transit_lat != null || ns.event_lat != null) && (
                            <Pressable
                              hitSlop={6}
                              onPress={() => {
                                const pts: string[] = [];
                                if (ns.event_lat != null)   pts.push(`Evento: https://www.google.com/maps/search/?api=1&query=${ns.event_lat},${ns.event_lng}`);
                                if (ns.transit_lat != null) pts.push(`Último punto del grupo${ns.transit_updated_at ? ` (${new Date(ns.transit_updated_at).toLocaleTimeString('es-MX', { hour: '2-digit', minute: '2-digit' })})` : ''}: https://www.google.com/maps/search/?api=1&query=${ns.transit_lat},${ns.transit_lng}`);
                                Alert.alert('🗺️ Evidencia GPS', '¿Qué quieres ver en el mapa?', [
                                  // La prueba clave: distancia entre el último punto del grupo y el evento
                                  ...(ns.event_lat != null && ns.transit_lat != null ? [{
                                    text: '⚖️ Comparar: rastro del grupo → evento',
                                    onPress: () => Linking.openURL(
                                      `https://www.google.com/maps/dir/?api=1&origin=${ns.transit_lat},${ns.transit_lng}&destination=${ns.event_lat},${ns.event_lng}`
                                    ),
                                  }] : []),
                                  ...(ns.event_lat != null ? [{ text: '📍 Lugar del evento', onPress: () => Linking.openURL(`https://www.google.com/maps/search/?api=1&query=${ns.event_lat},${ns.event_lng}`) }] : []),
                                  ...(ns.transit_lat != null ? [{ text: '🚐 Último punto del grupo', onPress: () => Linking.openURL(`https://www.google.com/maps/search/?api=1&query=${ns.transit_lat},${ns.transit_lng}`) }] : []),
                                  { text: 'Cerrar', style: 'cancel' },
                                ]);
                              }}
                            >
                              <Text style={s.gpsEvidenceLink}>🗺️ Ver evidencia GPS en el mapa</Text>
                            </Pressable>
                          )}
                          {renderPhones(ns)}
                        </View>
                        <View style={s.noShowActions}>
                          <Pressable
                            style={[s.resolveBtn, resolvingId === ns.id && { opacity: 0.45 }]}
                            onPress={() => handleNoShowMenu(ns)}
                            disabled={resolvingId === ns.id}
                          >
                            <Text style={s.resolveBtnText}>
                              {resolvingId === ns.id ? '…' : 'Resolver →'}
                            </Text>
                          </Pressable>
                          <Pressable
                            style={s.detailBtn}
                            onPress={() => navigation.navigate('AdminTicketSearch', { reservationId: ns.id })}
                          >
                            <Text style={s.detailBtnText}>Ver</Text>
                          </Pressable>
                        </View>
                      </View>
                    ))
              )}

              {/* ── Historial ── */}
              {noShowsTab === 'history' && (
                noShowsHistory.length === 0
                  ? <Text style={s.nsEmpty}>Sin no-shows resueltos aún.</Text>
                  : noShowsHistory.map((ns: any) => {
                      const res      = ns.admin_no_show_resolution as string;
                      const resIcon  = res === 'refunded_100' ? '💚' : res === 'no_refund' ? '⛔' : '❌';
                      const resLabel = res === 'refunded_100' ? 'Reembolsado' : res === 'no_refund' ? 'Sin reembolso' : 'Cerrado';
                      const resolvedDate = ns.admin_no_show_resolved_at
                        ? new Date(ns.admin_no_show_resolved_at).toLocaleDateString('es-MX', {
                            day: '2-digit', month: '2-digit', year: '2-digit',
                          })
                        : '—';
                      return (
                        <View key={ns.id} style={[s.noShowRow, s.nsHistoryRow]}>
                          <View style={{ flex: 1 }}>
                            <View style={s.nsHistHeader}>
                              <Text style={s.noShowFolio}>{ns.folio ?? ns.id.substring(0, 8)}</Text>
                              <View style={s.nsResolutionBadge}>
                                <Text style={s.nsResolutionText}>{resIcon} {resLabel}</Text>
                              </View>
                            </View>
                            <Text style={s.noShowGroup}>{flagFor(ns.country_code)} {ns.group_name ?? '—'}</Text>
                            <Text style={s.noShowMeta}>
                              {placeLine(ns)}  ·  {ns.client_name ?? '—'}  ·  {ns.event_date}
                              {ns.has_strike ? '  · ⚡ Strike' : ''}
                            </Text>
                            <Text style={s.noShowMeta}>
                              ${(ns.total_price ?? 0).toLocaleString('es-MX', { maximumFractionDigits: 0 })} {ns.currency ?? 'MXN'}
                            </Text>
                            <Text style={s.nsResolvedBy}>
                              Resolvió: {ns.resolver_name ?? 'Admin'}  ·  {resolvedDate}
                            </Text>
                          </View>
                        </View>
                      );
                    })
              )}
            </View>
          )}

          {/* ── ACCIONES RÁPIDAS ──────────────────────────────────────────── */}
          <View style={s.section}>
            <View style={s.sectionHeader}>
              <Text style={s.sectionTitle}>Acciones rápidas</Text>
            </View>
            <View style={s.actionGrid}>
              {([
                { icon: Shield,    label: 'Verificaciones', colors: ['#0d2a5e','#061530'], ic: '#40C4FF',  screen: 'AdminVerifications' },
                { icon: AlertCircle, label: 'Disputas',     colors: ['#3d0d0d','#200606'], ic: COLORS.red, screen: 'AdminDisputes' },
                { icon: Users,     label: 'Proveedores',    colors: ['#3d2a00','#1a1200'], ic: COLORS.gold,   screen: 'AdminGroups' },
                { icon: Briefcase, label: 'Talentos',       colors: ['#1a0d3d','#0d0617'], ic: '#CE93D8',     screen: 'Talentos'    },
                { icon: BarChart2, label: 'Estadísticas',   colors: ['#1a0d2e','#0d0617'], ic: '#CE93D8',  screen: 'AdminStats' },
                { icon: DollarSign, label: 'Finanzas',      colors: ['#002213','#000f09'], ic: COLORS.green, screen: 'AdminFinancial' },
                { icon: BarChart2, label: 'Reportes',       colors: ['#002213','#000f09'], ic: COLORS.green, screen: 'AdminReports' },
                { icon: Map,       label: 'Mapa en vivo',   colors: ['#001a2e','#000d17'], ic: '#40C4FF',  screen: 'AdminMap' },
                { icon: Wallet,    label: 'Retiros',        colors: ['#002213','#000f09'], ic: COLORS.green, screen: 'AdminFinancial' },
                { icon: Megaphone, label: 'Anuncios',       colors: ['#001a1a','#000d0d'], ic: '#00C4B4',    screen: 'AdApproval' },
                { icon: Phone,     label: 'Interés sin proveedor', colors: ['#3d2200','#1a0f00'], ic: '#FFB300', screen: 'AdminCategoryInterest' },
                { icon: Plane,     label: 'Demanda entre países', colors: ['#001a2e','#000d17'], ic: '#40C4FF', screen: 'AdminCrossBorder' },
              ]).map(({ icon: Icon, label, colors, ic, screen }) => (
                <Pressable key={label} style={s.actionBtnWrap} onPress={() => navigation.navigate(screen)}>
                  <LinearGradient colors={colors as any} style={s.actionBtn} start={{ x: 0, y: 0 }} end={{ x: 1, y: 1 }}>
                    <View style={[s.actionIconWrap, { backgroundColor: ic + '22' }]}>
                      <Icon size={15} color={ic} />
                    </View>
                    <Text style={s.actionLabel}>{label}</Text>
                  </LinearGradient>
                </Pressable>
              ))}
            </View>
          </View>

          <View style={{ height: 40 }} />
        </ScrollView>
      </SafeAreaView>
    </View>
  );
}

// ─── Styles ──────────────────────────────────────────────────────────────────
const CARD_W = Math.floor((SW - SPACING.xl * 2 - 8 * 2) / 3);

const s = StyleSheet.create({
  root: { flex: 1, backgroundColor: COLORS.bg },

  header: {
    flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center',
    paddingHorizontal: SPACING.xl, paddingTop: 14, paddingBottom: 18,
  },
  logo: { fontFamily: FONTS.title, fontSize: 22, color: COLORS.text },
  dateTag: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted2, marginTop: 2, textTransform: 'capitalize' },
  headerRight: { flexDirection: 'row', gap: 8 },
  iconBtn: {
    width: 38, height: 38, borderRadius: 10,
    backgroundColor: COLORS.card, borderWidth: 1, borderColor: COLORS.border,
    alignItems: 'center', justifyContent: 'center',
  },
  notifDot: {
    position: 'absolute', top: 5, right: 5, minWidth: 16, height: 16, borderRadius: 8,
    backgroundColor: COLORS.green, borderWidth: 1.5, borderColor: COLORS.bg,
    alignItems: 'center', justifyContent: 'center', paddingHorizontal: 3,
  },
  notifDotText: { fontFamily: FONTS.bodySemiBold, fontSize: 9, color: COLORS.bg },

  // Status chips
  statusRow: { paddingHorizontal: SPACING.xl, gap: 8 },
  statusChip: {
    alignItems: 'center', paddingHorizontal: 16, paddingVertical: 12,
    borderRadius: RADIUS.lg, borderWidth: 1, minWidth: 90,
  },
  statusNum: { fontFamily: FONTS.title, fontSize: 28, lineHeight: 32 },
  statusLbl: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted2, marginTop: 2 },

  // KPI cards
  kpiRow: { flexDirection: 'row', gap: 12, marginHorizontal: SPACING.xl, marginBottom: 12 },
  kpiCard: {
    flex: 1, borderRadius: RADIUS.xl, padding: 16,
    borderWidth: 1, borderColor: COLORS.border,
  },
  kpiIconWrap: {
    width: 36, height: 36, borderRadius: 10,
    backgroundColor: 'rgba(0,230,118,0.15)',
    alignItems: 'center', justifyContent: 'center', marginBottom: 10,
  },
  kpiLabel: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted2, marginBottom: 4 },
  kpiValue: {
    fontFamily: FONTS.title, fontSize: 26, color: COLORS.green, lineHeight: 32,
    fontVariant: ['tabular-nums'], includeFontPadding: false,
  },

  // 📊 Banda de acceso al panel ejecutivo
  reportsBand: {
    marginBottom: 14, padding: 14, borderRadius: RADIUS.xl,
    borderWidth: 1.5, borderColor: 'rgba(0,230,118,0.45)',
    backgroundColor: COLORS.card, gap: 3,
  },
  reportsBandTx:  { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.green },
  reportsBandSub: { fontFamily: FONTS.body, fontSize: 11.5, color: COLORS.muted2 },
  kpiSub:   { fontFamily: FONTS.body, fontSize: 10, color: COLORS.muted, marginTop: 4 },

  // Alert strip
  alertStrip: {
    marginHorizontal: SPACING.xl, marginBottom: 20,
    backgroundColor: 'rgba(255,152,0,0.06)', borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: 'rgba(255,152,0,0.22)', padding: 14,
  },
  alertTitle: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.orange, marginBottom: 10 },
  alertChips: { flexDirection: 'row', gap: 8 },
  alertChip: {
    alignItems: 'center', paddingHorizontal: 16, paddingVertical: 8,
    borderRadius: RADIUS.md, borderWidth: 1, backgroundColor: 'rgba(0,0,0,0.3)',
  },
  alertChipNum: { fontFamily: FONTS.title, fontSize: 20, lineHeight: 24 },
  alertChipLbl: { fontFamily: FONTS.body, fontSize: 10, color: COLORS.muted2, marginTop: 2 },

  // Section
  section: {
    marginHorizontal: SPACING.xl, marginBottom: 20,
    backgroundColor: COLORS.card, borderRadius: RADIUS.xl,
    borderWidth: 1, borderColor: COLORS.border, padding: 16,
  },
  sectionHeader: { flexDirection: 'row', alignItems: 'center', gap: 8, marginBottom: 14 },
  nsMoneyAtStake: { fontFamily: FONTS.bodySemiBold, fontSize: 12, color: COLORS.red, marginLeft: 'auto' },
  sectionTitle:  { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.text, flex: 1 },
  seeAll:        { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.green },
  liveIndicator: { width: 8, height: 8, borderRadius: 4, backgroundColor: COLORS.red },

  eventRow: {
    flexDirection: 'row', alignItems: 'center', gap: 10,
    paddingVertical: 10, borderLeftWidth: 3, paddingLeft: 10,
    borderBottomWidth: 1, borderBottomColor: COLORS.border,
    marginBottom: 2,
  },
  eventGroup: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.text },
  eventSub:   { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted2, marginTop: 2 },

  // Chart
  chartWrap: { height: 140 },
  chart: { flex: 1, flexDirection: 'row', alignItems: 'flex-end', gap: 6 },
  barCol: { flex: 1, alignItems: 'center', height: '100%', justifyContent: 'flex-end' },
  barNum: { fontFamily: FONTS.body, fontSize: 10, color: COLORS.muted2, marginBottom: 3 },
  barBg:  { width: '100%', flex: 1, backgroundColor: COLORS.card2, borderRadius: 4, overflow: 'hidden', justifyContent: 'flex-end' },
  barFill: { width: '100%', borderRadius: 4 },
  barLabel: { fontFamily: FONTS.body, fontSize: 10, color: COLORS.muted2, marginTop: 6 },

  // Top groups
  topGroupRow: { flexDirection: 'row', alignItems: 'center', gap: 12, marginBottom: 12 },
  topGroupRank: { width: 30, height: 30, borderRadius: 8, alignItems: 'center', justifyContent: 'center' },
  topGroupRankNum: { fontFamily: FONTS.bodySemiBold, fontSize: 14 },
  topGroupNameRow: { flexDirection: 'row', justifyContent: 'space-between', marginBottom: 5 },
  topGroupName: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.text, flex: 1 },
  topGroupCount: { fontFamily: FONTS.bodySemiBold, fontSize: 13, marginLeft: 8 },
  topGroupBarBg: { height: 5, backgroundColor: COLORS.card2, borderRadius: 3, overflow: 'hidden' },
  topGroupBarFill: { height: '100%', borderRadius: 3 },

  // Wallet widget
  walletWidget: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between',
    marginHorizontal: SPACING.xl, marginBottom: 20,
    backgroundColor: COLORS.card, borderRadius: RADIUS.xl,
    borderWidth: 1, borderColor: `${COLORS.green}50`,
    paddingHorizontal: SPACING.lg, paddingVertical: 16,
    overflow: 'hidden', position: 'relative',
  },
  walletLeft:       { flexDirection: 'row', alignItems: 'center', gap: 14, flex: 1 },
  walletLabel:      { fontFamily: FONTS.bodyMedium, fontSize: 11, color: COLORS.muted2, marginBottom: 2, textTransform: 'uppercase' as const, letterSpacing: 0.5 },
  walletAmount:     {
    fontFamily: FONTS.title, fontSize: 26, lineHeight: 32, color: COLORS.green,
    fontVariant: ['tabular-nums'], includeFontPadding: false,
  },
  walletAmountSub:  { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2 },
  walletTotal:      { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted, marginTop: 2 },
  walletRight:      { alignItems: 'flex-end', gap: 8 },
  walletWithdrawBtn: {
    backgroundColor: COLORS.green, borderRadius: RADIUS.md,
    paddingHorizontal: 16, paddingVertical: 9,
  },
  walletWithdrawText: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.bg },

  // No-shows
  noShowSection: { borderColor: 'rgba(255,82,82,0.35)' },
  stuckSection:  { borderColor: 'rgba(255,152,0,0.35)' },
  unverifiedSection: { borderColor: 'rgba(64,196,255,0.35)' },
  stuckHint:     { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, marginBottom: 10, lineHeight: 17 },
  phoneRow:      { flexDirection: 'row', flexWrap: 'wrap', gap: 8, marginTop: 8 },
  phoneChip: {
    flexDirection: 'row', alignItems: 'center', gap: 5,
    paddingVertical: 6, paddingHorizontal: 10, borderRadius: 8,
    backgroundColor: 'rgba(0,230,118,0.10)', borderWidth: 1, borderColor: 'rgba(0,230,118,0.35)',
  },
  phoneChipText: { fontFamily: FONTS.bodySemiBold, fontSize: 12, color: COLORS.green },
  noShowRow: {
    flexDirection: 'row', alignItems: 'center',
    paddingVertical: 10, borderBottomWidth: 1, borderBottomColor: COLORS.border, gap: 10,
  },
  noShowFolio:   { fontFamily: FONTS.bodySemiBold, fontSize: 12, color: COLORS.text },
  noShowGroup:   { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.text, marginTop: 2 },
  noShowMeta:    { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted2, marginTop: 1 },
  gpsEvidenceLink: { fontFamily: FONTS.bodyMedium, fontSize: 11, color: COLORS.green, textDecorationLine: 'underline', marginTop: 3 },
  noShowActions: { flexDirection: 'row', gap: 6 },
  resolveBtn: {
    backgroundColor: 'rgba(0,230,118,0.10)', borderRadius: RADIUS.md,
    paddingHorizontal: 10, paddingVertical: 7,
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.35)',
  },
  resolveBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 11, color: COLORS.green },
  detailBtn: {
    backgroundColor: COLORS.card2, borderRadius: RADIUS.md,
    paddingHorizontal: 10, paddingVertical: 7,
    borderWidth: 1, borderColor: COLORS.border,
  },
  detailBtnText: { fontFamily: FONTS.bodyMedium, fontSize: 11, color: COLORS.muted2 },

  // No-show tabs & history
  nsTabRow: { flexDirection: 'row', gap: 8, marginBottom: 14 },
  nsTab: {
    flex: 1, paddingVertical: 8, borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: COLORS.border, alignItems: 'center',
  },
  nsTabActive:     { borderColor: COLORS.green, backgroundColor: 'rgba(0,230,118,0.08)' },
  nsTabText:       { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.muted2 },
  nsTabTextActive: { color: COLORS.green },
  nsEmpty:         { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, textAlign: 'center', paddingVertical: 12 },
  nsHistoryRow:    { opacity: 0.85 },
  nsHistHeader:    { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center', marginBottom: 2 },
  nsResolutionBadge: {
    backgroundColor: 'rgba(176,190,197,0.08)', borderRadius: RADIUS.sm,
    paddingHorizontal: 8, paddingVertical: 3, borderWidth: 1, borderColor: COLORS.border,
  },
  nsResolutionText: { fontFamily: FONTS.bodyMedium, fontSize: 11, color: COLORS.muted2 },
  nsResolvedBy:     { fontFamily: FONTS.body, fontSize: 10, color: COLORS.muted, marginTop: 3 },

  // Actions
  actionGrid: { flexDirection: 'row', flexWrap: 'wrap', gap: 8 },
  actionBtnWrap: { width: CARD_W },
  actionBtn: {
    borderRadius: RADIUS.lg, padding: 10, alignItems: 'center', gap: 7,
    borderWidth: 1, borderColor: COLORS.border,
  },
  actionIconWrap: { width: 32, height: 32, borderRadius: 9, alignItems: 'center', justifyContent: 'center' },
  actionLabel: { fontFamily: FONTS.bodyMedium, fontSize: 10, color: COLORS.muted2, textAlign: 'center' },
});
