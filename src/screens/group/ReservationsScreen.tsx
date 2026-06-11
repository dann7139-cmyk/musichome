import { ArrowLeft, ChevronRight, Clock, MapPin } from 'lucide-react-native';
import React, { useEffect, useState } from 'react';
import {
  Pressable,
  RefreshControl,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { supabase } from '../../config/supabase';
import { isPaid } from '../../utils/calculations';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';
import Badge from '../../components/ui/Badge';
import Particles from '../../components/ui/Particles';

const STATUS_MAP: Record<string, { label: string; variant: any; color: string }> = {
  pending:                    { label: 'Pendiente',      variant: 'orange', color: COLORS.orange },
  pending_payment:            { label: 'Pago pendiente', variant: 'orange', color: COLORS.orange },
  pending_group_confirmation: { label: 'Por confirmar',  variant: 'orange', color: COLORS.orange },
  accepted:                   { label: 'Aceptada',       variant: 'blue',   color: COLORS.blue   },
  confirmed:                  { label: 'Confirmada',     variant: 'green',  color: COLORS.green  },
  in_progress:                { label: 'En curso',       variant: 'blue',   color: COLORS.blue   },
  completed:                  { label: 'Completada',     variant: 'muted',  color: COLORS.muted  },
  cancelled:                  { label: 'Cancelada',      variant: 'red',    color: COLORS.red    },
  rejected:                   { label: 'Rechazada',      variant: 'red',    color: COLORS.red    },
  expired:                    { label: 'Expirada',       variant: 'red',    color: COLORS.red    },
};

const MONTH_SHORT = ['ENE','FEB','MAR','ABR','MAY','JUN','JUL','AGO','SEP','OCT','NOV','DIC'];

const TODAY = new Date().toISOString().split('T')[0]; // 'YYYY-MM-DD'


const MAIN_TABS = [
  { label: 'Activas',    key: 'activas'   },
  { label: 'Historial',  key: 'historial' },
  { label: 'Por status', key: 'status'    },
] as const;

type MainTab = 'activas' | 'historial' | 'status';

const STATUS_FILTERS = [
  { label: 'Pagadas',       key: 'pagadas' },
  { label: 'Por confirmar', key: 'pending_group_confirmation' },
  { label: 'Pago pend.',    key: 'pending_payment' },
  { label: 'Aceptada',      key: 'accepted' },
  { label: 'Confirmada',    key: 'confirmed' },
  { label: 'Pendiente',     key: 'pending' },
  { label: 'En curso',      key: 'in_progress' },
];

export default function GroupReservationsScreen({ route, navigation }: any) {
  const initialFilter: string | null = route?.params?.initialFilter ?? null;
  const initTab: MainTab = initialFilter === 'history' ? 'historial' : initialFilter ? 'status' : 'activas';
  const initStatus: string | null = initialFilter && initialFilter !== 'history' ? initialFilter : null;

  const [reservations, setReservations] = useState<any[]>([]);
  const [mainTab, setMainTab] = useState<MainTab>(initTab);
  const [statusFilter, setStatusFilter] = useState<string | null>(initStatus);
  const [refreshing, setRefreshing] = useState(false);
  const [page, setPage] = useState(0);
  const [hasMore, setHasMore] = useState(true);
  const PAGE_SIZE = 50;

  useEffect(() => { fetchReservations(0); }, []);

  useEffect(() => {
    const unsubscribe = navigation.addListener('focus', () => {
      fetchReservations(0);
    });
    return unsubscribe;
  }, [navigation]);

  const fetchReservations = async (pageNum: number) => {
    try {
      const { data: grpRaw, error: grpErr } = await supabase
        .rpc('get_my_group')
        .maybeSingle();

      if (grpErr) { console.log('[RES] Group error:', grpErr.message); return; }
      if (!grpRaw) { console.log('[RES] No group found'); return; }
      const grp = grpRaw as { id: string };

      const from = pageNum * PAGE_SIZE;
      const to   = from + PAGE_SIZE - 1;

      const { data, error } = await supabase
        .from('reservations')
        .select('*,quote:quotes!quote_id(duration_hours,overtime_1h_price,overtime_2h_price,overtime_3h_price,event_type,guests_count,notes),package:packages!package_id(duration_hours,extra_hour_price),client:profiles!client_id(full_name)')
        .eq('group_id', grp.id)
        .order('event_date', { ascending: false })
        .range(from, to);

      console.log('[RES] Query result - count:', data?.length ?? 0, 'error:', error?.message ?? 'none');

      if (error) return;

      setHasMore((data?.length ?? 0) === PAGE_SIZE);

      if (!data || data.length === 0) {
        if (pageNum === 0) setReservations([]);
        return;
      }

      const packageIds = [...new Set(data.map((r: any) => r.package_id).filter(Boolean))];
      let packageMap: Record<string, { name: string; duration_hours: number | null }> = {};

      if (packageIds.length > 0) {
        const { data: pkgs } = await supabase
          .from('packages')
          .select('id, name, duration_hours')
          .in('id', packageIds);
        if (pkgs) {
          pkgs.forEach((p: any) => { packageMap[p.id] = { name: p.name, duration_hours: p.duration_hours }; });
        }
      }

      const clientIds = [...new Set(data.map((r: any) => r.client_id).filter(Boolean))];
      let clientMap: Record<string, { full_name: string }> = {};

      if (clientIds.length > 0) {
        const { data: clients } = await supabase
          .from('profiles')
          .select('id, full_name')
          .in('id', clientIds);
        if (clients) {
          clients.forEach((c: any) => { clientMap[c.id] = { full_name: c.full_name }; });
        }
      }

      const merged = data.map((r: any) => ({
        ...r,
        client: clientMap[r.client_id] ?? null,
        package: packageMap[r.package_id] ?? null,
      }));

      if (pageNum === 0) {
        setReservations(merged);
      } else {
        setReservations(prev => [...prev, ...merged]);
      }
      setPage(pageNum);
    } catch (e: any) {
      console.log('[RES] Exception:', e.message);
    }
  };

  const loadMore = () => {
    if (hasMore) fetchReservations(page + 1);
  };

  const onRefresh = async () => {
    setRefreshing(true);
    await fetchReservations(0);
    setRefreshing(false);
  };

  // Reservas activas: solo las que aún no han pasado de fecha
  const activeReservations = reservations.filter(r => !r.event_date || r.event_date >= TODAY);

  // Historial: todas las que ya pasaron de fecha (sin importar el estado)
  const historyReservations = reservations.filter(r => r.event_date && r.event_date < TODAY);


  const filtered =
    mainTab === 'historial' ? historyReservations :
    mainTab === 'status'
      ? statusFilter === 'pagadas'
        ? reservations.filter(r => isPaid(r.payment_status))
        : statusFilter
          ? reservations.filter(r => r.status === statusFilter)
          : reservations
      : activeReservations;

  const countByStatus = reservations.reduce<Record<string, number>>((acc, r) => {
    acc[r.status] = (acc[r.status] ?? 0) + 1;
    return acc;
  }, {});
  const paidCount = reservations.filter(r => isPaid(r.payment_status)).length;

  return (
    <View style={styles.container}>
      <Particles />
      <SafeAreaView style={{ flex: 1 }}>
        {/* HEADER */}
        <View style={styles.header}>
          <Pressable style={styles.backBtn} onPress={() => navigation.goBack()}>
            <ArrowLeft size={20} color={COLORS.text} />
          </Pressable>
          <View>
            <Text style={styles.headerTitle}>Reservas</Text>
            <Text style={styles.headerSub}>{activeReservations.length} activas</Text>
          </View>
          <View style={{ width: 40 }} />
        </View>

        {/* MAIN TABS */}
        <View style={styles.tabBar}>
          {MAIN_TABS.map(t => {
            const count =
              t.key === 'activas'   ? activeReservations.length :
              t.key === 'historial' ? historyReservations.length :
              reservations.length;
            const active = mainTab === t.key;
            return (
              <Pressable
                key={t.key}
                style={[styles.tabBtn, active && styles.tabBtnActive]}
                onPress={() => setMainTab(t.key)}
              >
                <Text style={[styles.tabBtnText, active && styles.tabBtnTextActive]}>{t.label}</Text>
                {count > 0 && (
                  <View style={[styles.chipCount, active && styles.chipCountActive]}>
                    <Text style={[styles.chipCountText, active && styles.chipCountTextActive]}>{count}</Text>
                  </View>
                )}
              </Pressable>
            );
          })}
        </View>

        {/* SUB-FILTER — solo visible en tab "Por status" */}
        {mainTab === 'status' && (
          <ScrollView
            horizontal showsHorizontalScrollIndicator={false}
            contentContainerStyle={styles.filters}
          >
            {STATUS_FILTERS.map(f => {
              const count = f.key === 'pagadas' ? paidCount : (countByStatus[f.key] ?? 0);
              const active = statusFilter === f.key;
              return (
                <Pressable
                  key={f.key}
                  style={[styles.chip, active && styles.chipActive]}
                  onPress={() => setStatusFilter(active ? null : f.key)}
                >
                  <Text style={[styles.chipText, active && styles.chipTextActive]}>{f.label}</Text>
                  {count > 0 && (
                    <View style={[styles.chipCount, active && styles.chipCountActive]}>
                      <Text style={[styles.chipCountText, active && styles.chipCountTextActive]}>{count}</Text>
                    </View>
                  )}
                </Pressable>
              );
            })}
          </ScrollView>
        )}

        {/* LIST */}
        <ScrollView
          showsVerticalScrollIndicator={false}
          contentContainerStyle={styles.list}
          refreshControl={<RefreshControl refreshing={refreshing} onRefresh={onRefresh} tintColor={COLORS.green} />}
        >
          {filtered.length === 0 ? (
            <View style={styles.empty}>
              <Text style={styles.emptyIcon}>📋</Text>
              <Text style={styles.emptyTitle}>Sin reservas</Text>
              <Text style={styles.emptyText}>No hay reservas en este estado</Text>
            </View>
          ) : (
            <>
              {filtered.map(r => (
                <ReservationCard key={r.id} reservation={r} navigation={navigation} isHistory={mainTab === 'historial'} />
              ))}
              {hasMore && (
                <Pressable style={styles.loadMoreBtn} onPress={loadMore}>
                  <Text style={styles.loadMoreText}>Cargar más</Text>
                </Pressable>
              )}
            </>
          )}
        </ScrollView>
      </SafeAreaView>
    </View>
  );
}

const PAYOUT_BADGE: Record<string, { label: string; color: string }> = {
  held:     { label: '⏳ Retenido',        color: COLORS.orange },
  released: { label: '✅ Disponible',      color: COLORS.green  },
  blocked:  { label: '🔒 Bloqueado',       color: COLORS.red    },
  refunded: { label: '↩ Reembolsado',      color: COLORS.muted  },
};

function ReservationCard({ reservation: r, navigation, isHistory }: any) {
  const s = STATUS_MAP[r.status] ?? STATUS_MAP.pending;
  const parts = r.event_date?.split('-') ?? [];
  const day = parts[2] ?? '—';
  const monthIdx = parts[1] ? parseInt(parts[1], 10) - 1 : -1;
  const month = monthIdx >= 0 ? MONTH_SHORT[monthIdx] : '—';
  const accentColor = isHistory ? COLORS.muted : s.color;
  const payoutBadge = isPaid(r.payment_status) ? (PAYOUT_BADGE[r.payout_status] ?? null) : null;

  return (
    <Pressable
      style={[styles.card, isHistory && styles.cardPast]}
      onPress={() => {
        if (isPaid(r.payment_status) || r.status === 'in_progress' || r.status === 'accepted' || r.status === 'completed') {
          navigation.navigate('EventTimer', { reservation: r });
        } else {
          navigation.navigate('GroupConfirmBooking', { reservation: r });
        }
      }}
    >
      {/* Date bubble */}
      <View style={[styles.dateBubble, { backgroundColor: `${accentColor}18`, borderColor: `${accentColor}40` }]}>
        <Text style={[styles.dateDay, { color: accentColor }]}>{day}</Text>
        <Text style={[styles.dateMon, { color: accentColor }]}>{month}</Text>
      </View>

      {/* Content */}
      <View style={styles.cardBody}>
        <View style={styles.cardTopRow}>
          <Text style={[styles.clientName, isHistory && { color: COLORS.muted }]} numberOfLines={1}>{r.client?.full_name ?? 'Cliente'}</Text>
          <Badge label={s.label} variant={isHistory ? 'muted' : s.variant} dot />
        </View>

        <Text style={styles.pkgName} numberOfLines={1}>
          {r.package?.name ?? '—'}
          {r.package?.duration_hours ? ` · ${r.package.duration_hours}h` : ''}
        </Text>

        {/* Payout status — visible cuando ya fue pagado */}
        {payoutBadge && (
          <View style={[styles.payoutChip, { borderColor: payoutBadge.color + '40', backgroundColor: payoutBadge.color + '12' }]}>
            <Text style={[styles.payoutChipText, { color: payoutBadge.color }]}>{payoutBadge.label}</Text>
          </View>
        )}

        <View style={styles.metaRow}>
          {r.event_time && (
            <View style={styles.metaItem}>
              <Clock size={11} color={COLORS.muted} />
              <Text style={styles.metaText}>{r.event_time}</Text>
            </View>
          )}
          {r.address && (
            <View style={styles.metaItem}>
              <MapPin size={11} color={COLORS.muted} />
              <Text style={styles.metaText} numberOfLines={1}>{r.address}</Text>
            </View>
          )}
        </View>
      </View>

      {/* Right: price + arrow */}
      <View style={styles.cardRight}>
        <Text style={[styles.price, { color: accentColor }]}>
          ${r.group_earnings?.toLocaleString() ?? '—'}
        </Text>
        <ChevronRight size={14} color={COLORS.muted} />
      </View>
    </Pressable>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: COLORS.bg },

  header: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between',
    paddingHorizontal: SPACING.xl, paddingTop: 12, paddingBottom: 14,
  },
  backBtn: {
    width: 40, height: 40, borderRadius: 12,
    backgroundColor: COLORS.card, borderWidth: 1, borderColor: COLORS.border,
    alignItems: 'center', justifyContent: 'center',
  },
  headerTitle: { fontFamily: FONTS.title, fontSize: 20, color: COLORS.text, textAlign: 'center' },
  headerSub: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted, textAlign: 'center', marginTop: 1 },

  tabBar: {
    flexDirection: 'row', borderBottomWidth: 1, borderBottomColor: COLORS.border,
    marginBottom: 2,
  },
  tabBtn: {
    flex: 1, flexDirection: 'row', alignItems: 'center', justifyContent: 'center',
    gap: 6, paddingVertical: 12, borderBottomWidth: 2, borderBottomColor: 'transparent',
  },
  tabBtnActive: { borderBottomColor: COLORS.green },
  tabBtnText: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted2 },
  tabBtnTextActive: { color: COLORS.green },

  filters: { paddingHorizontal: SPACING.xl, paddingVertical: 10, gap: 8 },
  chip: {
    flexDirection: 'row', alignItems: 'center', gap: 6,
    paddingHorizontal: 12, paddingVertical: 6,
    borderRadius: RADIUS.full, borderWidth: 1, borderColor: COLORS.border,
    backgroundColor: COLORS.card,
  },
  chipActive: { borderColor: COLORS.green, backgroundColor: COLORS.greenMuted },
  chipText: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted2 },
  chipTextActive: { color: COLORS.green },
  chipCount: {
    minWidth: 18, height: 18, borderRadius: 9,
    backgroundColor: COLORS.border, alignItems: 'center', justifyContent: 'center',
    paddingHorizontal: 4,
  },
  chipCountActive: { backgroundColor: `${COLORS.green}30` },
  chipCountText: { fontFamily: FONTS.bodyMedium, fontSize: 10, color: COLORS.muted },
  chipCountTextActive: { color: COLORS.green },

  list: { padding: SPACING.xl, gap: 10, paddingBottom: 40 },

  card: {
    flexDirection: 'row', alignItems: 'center', gap: 14,
    backgroundColor: COLORS.card, borderRadius: 20,
    borderWidth: 1, borderColor: '#1c1c1c',
    padding: 14,
  },
  cardPast: { opacity: 0.5 },
  dateBubble: {
    width: 50, height: 58, borderRadius: 14,
    borderWidth: 1, alignItems: 'center', justifyContent: 'center',
    flexShrink: 0,
  },
  dateDay: { fontFamily: FONTS.title, fontSize: 20, lineHeight: 24 },
  dateMon: { fontFamily: FONTS.bodyMedium, fontSize: 10, letterSpacing: 1 },

  cardBody: { flex: 1, gap: 5 },
  cardTopRow: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', gap: 8 },
  clientName: { fontFamily: FONTS.title, fontSize: 16, color: COLORS.text, flex: 1 },
  pkgName: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted },
  metaRow: { flexDirection: 'row', gap: 6, flexWrap: 'wrap', marginTop: 2 },
  metaItem: {
    flexDirection: 'row', alignItems: 'center', gap: 4,
    backgroundColor: '#151515', borderRadius: 8,
    paddingHorizontal: 7, paddingVertical: 4,
  },
  metaText: { fontFamily: FONTS.bodyMedium, fontSize: 11, color: COLORS.muted2 },

  cardRight: { alignItems: 'flex-end', gap: 6, flexShrink: 0 },
  price: { fontFamily: FONTS.title, fontSize: 17 },

  empty: { alignItems: 'center', paddingTop: 80, gap: 8 },
  emptyIcon: { fontSize: 36 },
  emptyTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 16, color: COLORS.text },
  emptyText: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted },
  loadMoreBtn: {
    marginHorizontal: SPACING.xl, marginVertical: 12, paddingVertical: 14,
    borderRadius: RADIUS.lg, borderWidth: 1, borderColor: COLORS.border,
    alignItems: 'center' as const,
  },
  loadMoreText: { fontFamily: FONTS.bodyMedium, fontSize: 14, color: COLORS.muted2 },

  payoutChip: {
    alignSelf: 'flex-start' as const,
    borderRadius: RADIUS.full, borderWidth: 1,
    paddingHorizontal: 8, paddingVertical: 3,
    marginTop: 4,
  },
  payoutChipText: { fontFamily: FONTS.bodyMedium, fontSize: 10 },
});
