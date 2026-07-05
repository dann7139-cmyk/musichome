import { ArrowLeft, ChevronRight, Clock, MapPin } from 'lucide-react-native';
import React, { useEffect, useState } from 'react';
import {
  Image,
  Pressable,
  RefreshControl,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import * as Location from 'expo-location';
import { supabase } from '../../config/supabase';
import { isPaid } from '../../utils/calculations';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';
import Particles from '../../components/ui/Particles';
import RequestZoneMap from '../../components/requests/RequestZoneMap';
import ClientProfileModal from '../../components/requests/ClientProfileModal';
import { eventCardCenter } from '../../utils/mapUtils';

// ─── Constants ────────────────────────────────────────────────────────────────

const MONTH_SHORT = ['ene','feb','mar','abr','may','jun','jul','ago','sep','oct','nov','dic'];
const DAY_SHORT   = ['Dom','Lun','Mar','Mié','Jue','Vie','Sáb'];

const TODAY = new Date().toISOString().split('T')[0];

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

// ─── Payment chip ─────────────────────────────────────────────────────────────

type ChipData = { label: string; color: string; bgColor: string; borderColor: string };

function mkChip(label: string, color: string, bgColor: string, borderColor: string): ChipData {
  return { label, color, bgColor, borderColor };
}

function getPaymentChip(r: any, isHistory: boolean): ChipData {
  // Disputa — prioridad máxima
  if (r.payout_status === 'blocked') {
    return mkChip('⚠  En disputa · pago retenido', COLORS.red, 'rgba(239,83,80,0.10)', 'rgba(239,83,80,0.35)');
  }

  const paid = isPaid(r.payment_status);

  if (paid) {
    const payout = r.payout_status as string | undefined;

    if (payout === 'released' || payout === 'refunded') {
      if (isHistory) {
        return mkChip('✓  Cobrado', COLORS.green2, 'rgba(0,200,83,0.07)', 'rgba(0,200,83,0.25)');
      }
      return mkChip('✓  Disponible para retiro', COLORS.green, COLORS.greenMuted, 'rgba(0,230,118,0.35)');
    }

    if (payout === 'half_released') {
      return mkChip('✓  50% disponible · resto pendiente', COLORS.green2, 'rgba(0,200,83,0.07)', 'rgba(0,200,83,0.25)');
    }

    if (payout === 'held') {
      const eventPassed = r.event_date && r.event_date < TODAY;
      const fadedOrange = 'rgba(255,152,0,0.60)';
      const orangeColor = isHistory ? fadedOrange : COLORS.orange;

      if (!eventPassed) {
        const label = isHistory ? '⏱  Liberación pendiente' : '⏱  Retenido hasta el evento';
        return mkChip(label, orangeColor, 'rgba(255,152,0,0.10)', 'rgba(255,152,0,0.30)');
      }

      // Post-evento: calcular tiempo restante hasta liberación (12h)
      const heldAt = r.held_at ? new Date(r.held_at as string) : null;
      if (heldAt) {
        const releaseAt = new Date(heldAt.getTime() + 12 * 60 * 60 * 1000);
        const msLeft    = releaseAt.getTime() - Date.now();

        if (msLeft > 60_000) {
          const hoursLeft = msLeft / 3_600_000;
          const label = hoursLeft >= 1
            ? `⏱  Libera en ${Math.round(hoursLeft)}h`
            : `⏱  Libera en ${Math.round(msLeft / 60_000)} min`;
          return mkChip(label, orangeColor, 'rgba(255,152,0,0.10)', 'rgba(255,152,0,0.30)');
        }

        // 12h ya pasaron pero el cron aún no corrió (ventana ~15 min)
        return mkChip('Liberando pronto...', COLORS.muted2, COLORS.card2, COLORS.border);
      }

      // held sin held_at — fallback
      const label = isHistory ? '⏱  Liberación pendiente' : '⏱  Retenido';
      return mkChip(label, orangeColor, 'rgba(255,152,0,0.10)', 'rgba(255,152,0,0.30)');
    }
  }

  // Sin pago — mostrar estado de reserva relevante
  if (r.status === 'pending_group_confirmation') {
    return mkChip('● Por confirmar', COLORS.orange, 'rgba(255,152,0,0.08)', 'rgba(255,152,0,0.30)');
  }
  if (r.status === 'in_progress') {
    return mkChip('▶  En curso', COLORS.blue, 'rgba(66,133,244,0.08)', 'rgba(66,133,244,0.30)');
  }
  if (r.status === 'cancelled' || r.status === 'rejected' || r.status === 'expired') {
    return mkChip('✕  ' + (r.status === 'cancelled' ? 'Cancelada' : r.status === 'rejected' ? 'Rechazada' : 'Expirada'),
      COLORS.muted2, COLORS.card2, COLORS.border);
  }

  return mkChip('○  Pendiente de pago', COLORS.muted2, COLORS.card2, COLORS.border);
}

// ─── Screen ───────────────────────────────────────────────────────────────────

export default function GroupReservationsScreen({ route, navigation }: any) {
  const initialFilter: string | null = route?.params?.initialFilter ?? null;
  const initTab: MainTab = initialFilter === 'history' ? 'historial' : initialFilter ? 'status' : 'activas';
  const initStatus: string | null = initialFilter && initialFilter !== 'history' ? initialFilter : null;

  const [reservations, setReservations] = useState<any[]>([]);
  const [mainTab,      setMainTab]      = useState<MainTab>(initTab);
  const [statusFilter, setStatusFilter] = useState<string | null>(initStatus);
  const [refreshing,   setRefreshing]   = useState(false);
  const [page,         setPage]         = useState(0);
  const [hasMore,      setHasMore]      = useState(true);
  const PAGE_SIZE = 50;
  // GPS + foto del grupo → ruta con instrumentos en las tarjetas (como ExpressCard)
  const [userLocation,  setUserLocation]  = useState<{ latitude: number; longitude: number } | null>(null);
  const [groupPhotoUrl, setGroupPhotoUrl] = useState<string | null>(null);
  const [profileClientId, setProfileClientId] = useState<string | null>(null);

  useEffect(() => { fetchReservations(0); }, []);

  useEffect(() => {
    (async () => {
      try {
        const last = await Location.getLastKnownPositionAsync({});
        if (last) {
          setUserLocation({ latitude: last.coords.latitude, longitude: last.coords.longitude });
        } else {
          const { granted } = await Location.getForegroundPermissionsAsync();
          if (granted) {
            const pos = await Location.getCurrentPositionAsync({ accuracy: Location.Accuracy.Balanced });
            setUserLocation({ latitude: pos.coords.latitude, longitude: pos.coords.longitude });
          }
        }
      } catch {}
    })();
    supabase.auth.getUser().then(({ data }) => {
      if (!data.user) return;
      supabase.from('groups').select('profile_image').eq('owner_id', data.user.id).single()
        .then(({ data: g }) => { if (g?.profile_image) setGroupPhotoUrl(g.profile_image); });
    });
  }, []);

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
        .select('*,quote:quotes!quote_id(duration_hours,overtime_1h_price,overtime_2h_price,overtime_3h_price,event_type,notes,latitude,longitude),event_request:event_requests!event_request_id(latitude,longitude,event_lat,event_lng),client:profiles!client_id(full_name)')
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

      const clientIds = [...new Set(data.map((r: any) => r.client_id).filter(Boolean))];
      let clientMap: Record<string, { full_name: string; avatar_url: string | null }> = {};

      if (clientIds.length > 0) {
        const { data: clients } = await supabase
          .from('profiles')
          .select('id, full_name, avatar_url')
          .in('id', clientIds);
        if (clients) {
          clients.forEach((c: any) => { clientMap[c.id] = { full_name: c.full_name, avatar_url: c.avatar_url ?? null }; });
        }
      }

      const merged = data.map((r: any) => ({
        ...r,
        client:  clientMap[r.client_id]  ?? null,
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

  const loadMore = () => { if (hasMore) fetchReservations(page + 1); };

  const onRefresh = async () => {
    setRefreshing(true);
    await fetchReservations(0);
    setRefreshing(false);
  };

  const activeReservations  = reservations.filter(r => !r.event_date || r.event_date >= TODAY);
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
            {mainTab === 'activas' && (
              <Text style={styles.headerSub}>{activeReservations.length} activas</Text>
            )}
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
              const count  = f.key === 'pagadas' ? paidCount : (countByStatus[f.key] ?? 0);
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
              {filtered.map((r, idx) => {
                const hist = mainTab === 'historial' || (r.event_date && r.event_date < TODAY);
                return (
                  <ReservationCard
                    key={r.id}
                    reservation={r}
                    navigation={navigation}
                    isHistory={hist}
                    showMap={!hist && idx < 6}
                    userLocation={userLocation}
                    groupPhotoUrl={groupPhotoUrl}
                    onViewProfile={r.client_id ? () => setProfileClientId(r.client_id) : null}
                  />
                );
              })}
              {hasMore && (
                <Pressable style={styles.loadMoreBtn} onPress={loadMore}>
                  <Text style={styles.loadMoreText}>Cargar más</Text>
                </Pressable>
              )}
            </>
          )}
        </ScrollView>
      </SafeAreaView>

      {/* Perfil público del cliente (RPC 435 — sin teléfono/email) */}
      <ClientProfileModal clientId={profileClientId} onClose={() => setProfileClientId(null)} />
    </View>
  );
}

// ─── ReservationCard ──────────────────────────────────────────────────────────

function ReservationCard({ reservation: r, navigation, isHistory, showMap = false, userLocation = null, groupPhotoUrl = null, onViewProfile = null }: any) {
  const chip = getPaymentChip(r, isHistory);

  const d = r.event_date ? new Date(r.event_date + 'T12:00:00') : null;
  const dateShort = d
    ? `${DAY_SHORT[d.getDay()]} ${d.getDate()} ${MONTH_SHORT[d.getMonth()]}`
    : '—';

  const isExpress = !!r.event_request_id;
  const typeLabel = isExpress ? '⚡ Express' : '📅 Programada';
  const mapCenter = showMap ? eventCardCenter(r) : null;

  return (
    <Pressable
      style={({ pressed }) => [
        styles.card,
        isHistory && styles.cardHistory,
        pressed  && styles.cardPressed,
      ]}
      onPress={() => {
        if (isPaid(r.payment_status) || r.status === 'in_progress' || r.status === 'accepted' || r.status === 'completed') {
          navigation.navigate('EventTimer', { reservation: r });
        } else {
          navigation.navigate('GroupConfirmBooking', { reservation: r });
        }
      }}
    >
      {mapCenter && (
        <RequestZoneMap
          mapId={String(r.id)} center={mapCenter} typeLabel={typeLabel}
          userLocation={userLocation} groupPhotoUrl={groupPhotoUrl}
        />
      )}
      <View style={styles.cardInner}>
      {/* Fila 1: foto + nombre del cliente + precio + chevron */}
      <View style={styles.cardTopRow}>
        {r.client?.avatar_url ? (
          <Image source={{ uri: r.client.avatar_url }} style={styles.clientAvatar} />
        ) : (
          <View style={styles.clientAvatarPh}>
            <Text style={styles.clientAvatarInitial}>
              {(r.client?.full_name ?? '?').charAt(0).toUpperCase()}
            </Text>
          </View>
        )}
        <Text style={styles.clientName} numberOfLines={1}>
          {r.client?.full_name ?? 'Cliente'}
        </Text>
        <View style={styles.cardRightCol}>
          <Text style={[styles.price, { color: chip.color }]}>
            ${r.group_earnings?.toLocaleString() ?? '—'}
          </Text>
          <ChevronRight size={16} color={COLORS.muted} />
        </View>
      </View>

      {/* Fila 2: chip de pago — protagonista + origen */}
      <View style={{ flexDirection: 'row', alignItems: 'center', gap: 6, flexWrap: 'wrap' }}>
        <View style={[styles.payChip, { backgroundColor: chip.bgColor, borderColor: chip.borderColor }]}>
          <Text style={[styles.payChipText, { color: chip.color }]}>{chip.label}</Text>
        </View>
        {!mapCenter && (
          <View style={styles.originChip}>
            <Text style={styles.originChipText}>{typeLabel}</Text>
          </View>
        )}
        {onViewProfile && (
          <Pressable
            onPress={(e: any) => { e.stopPropagation?.(); onViewProfile(); }}
            hitSlop={8}
            style={({ pressed }: any) => [styles.originChip, pressed && { opacity: 0.6 }]}
          >
            <Text style={styles.originChipText}>Ver perfil ›</Text>
          </Pressable>
        )}
      </View>

      {/* Fila 3: fecha + hora */}
      <View style={styles.metaRow}>
        <Text style={[styles.dateText, isHistory && styles.dateTextHistory]}>{dateShort}</Text>
        {r.event_time && (
          <>
            <Text style={styles.metaDot}>·</Text>
            <Clock size={11} color={COLORS.muted} />
            <Text style={styles.metaText}>{r.event_time}</Text>
          </>
        )}
      </View>

      {/* Fila 4: dirección */}
      {r.address ? (
        <View style={styles.metaRow}>
          <MapPin size={11} color={COLORS.muted} />
          <Text style={[styles.metaText, { flex: 1 }]} numberOfLines={1}>{r.address}</Text>
        </View>
      ) : null}

      {/* Fila 5: tipo de evento */}
      {(r.quote?.event_type || r.quote?.duration_hours) ? (
        <Text style={styles.pkgName} numberOfLines={1}>
          {r.quote.event_type ?? 'Cotización'}{r.quote.duration_hours ? ` · ${r.quote.duration_hours}h` : ''}
        </Text>
      ) : null}
      </View>
    </Pressable>
  );
}

// ─── Styles ───────────────────────────────────────────────────────────────────

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
  headerSub:   { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted, textAlign: 'center', marginTop: 1 },

  tabBar: {
    flexDirection: 'row', borderBottomWidth: 1, borderBottomColor: COLORS.border,
    marginBottom: 2,
  },
  tabBtn: {
    flex: 1, flexDirection: 'row', alignItems: 'center', justifyContent: 'center',
    gap: 6, paddingVertical: 12, borderBottomWidth: 2, borderBottomColor: 'transparent',
  },
  tabBtnActive:     { borderBottomColor: COLORS.green },
  tabBtnText:       { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted2 },
  tabBtnTextActive: { color: COLORS.green },

  filters:       { paddingHorizontal: SPACING.xl, paddingVertical: 10, gap: 8 },
  chip: {
    flexDirection: 'row', alignItems: 'center', gap: 6,
    paddingHorizontal: 12, paddingVertical: 6,
    borderRadius: RADIUS.full, borderWidth: 1, borderColor: COLORS.border,
    backgroundColor: COLORS.card,
  },
  chipActive:           { borderColor: COLORS.green, backgroundColor: COLORS.greenMuted },
  chipText:             { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted2 },
  chipTextActive:       { color: COLORS.green },
  chipCount: {
    minWidth: 18, height: 18, borderRadius: 9,
    backgroundColor: COLORS.border, alignItems: 'center', justifyContent: 'center',
    paddingHorizontal: 4,
  },
  chipCountActive:      { backgroundColor: `${COLORS.green}30` },
  chipCountText:        { fontFamily: FONTS.bodyMedium, fontSize: 10, color: COLORS.muted },
  chipCountTextActive:  { color: COLORS.green },

  list: { padding: SPACING.xl, gap: 10, paddingBottom: 40 },

  // ── Card ────────────────────────────────────────────────────────────────────
  // Cascarón estilo ExpressCard: mapa arriba (opcional) + contenido con padding interno
  card: {
    backgroundColor: '#060c06', borderRadius: 20, overflow: 'hidden',
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.35)',
  },
  cardInner: { padding: 14, gap: 8 },
  originChip: {
    backgroundColor: 'rgba(0,230,118,0.10)', borderRadius: 20,
    paddingHorizontal: 8, paddingVertical: 3,
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.30)',
  },
  originChipText: { fontFamily: FONTS.bodyMedium, fontSize: 10, color: COLORS.green },
  clientAvatar:   { width: 28, height: 28, borderRadius: 14, marginRight: 8 },
  clientAvatarPh: {
    width: 28, height: 28, borderRadius: 14, marginRight: 8,
    backgroundColor: 'rgba(0,230,118,0.12)', alignItems: 'center', justifyContent: 'center',
  },
  clientAvatarInitial: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.green },
  cardHistory: {
    backgroundColor: COLORS.bg,
    borderColor: 'rgba(26,26,26,0.55)',
  },
  cardPressed: { backgroundColor: COLORS.card2 },

  cardTopRow: {
    flexDirection: 'row', alignItems: 'center',
    justifyContent: 'space-between', gap: 8,
  },
  clientName: { fontFamily: FONTS.title, fontSize: 17, color: COLORS.text, flex: 1 },
  cardRightCol: {
    flexDirection: 'row', alignItems: 'center', gap: 6, flexShrink: 0,
  },
  price: { fontFamily: FONTS.bodySemiBold, fontSize: 15 },

  // Chip de estado de pago — protagonista
  payChip: {
    alignSelf: 'flex-start' as const,
    borderRadius: RADIUS.full, borderWidth: 1,
    paddingHorizontal: 12, paddingVertical: 7,
  },
  payChipText: { fontFamily: FONTS.bodySemiBold, fontSize: 13 },

  // Meta rows
  metaRow:         { flexDirection: 'row', alignItems: 'center', gap: 5 },
  dateText:        { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted2 },
  dateTextHistory: { color: COLORS.muted },
  metaDot:         { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted },
  metaText:        { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.muted },
  pkgName:         { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted },

  // Empty state
  empty:      { alignItems: 'center', paddingTop: 80, gap: 8 },
  emptyIcon:  { fontSize: 48 },
  emptyTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 16, color: COLORS.text },
  emptyText:  { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted },

  loadMoreBtn: {
    marginHorizontal: SPACING.xl, marginVertical: 12, paddingVertical: 14,
    borderRadius: RADIUS.lg, borderWidth: 1, borderColor: COLORS.border,
    alignItems: 'center' as const,
  },
  loadMoreText: { fontFamily: FONTS.bodyMedium, fontSize: 14, color: COLORS.muted2 },
});
