/**
 * GroupEventsScreen — Pestaña "Eventos" del grupo.
 * Próximos eventos: reservas pagadas/en curso → EventTimer
 * Pendientes: cotizaciones sin responder o por aceptar → GroupQuoteDetail
 */
import { BarChart2, Bell, ChevronRight, Clock, MapPin, PlayCircle, TrendingUp } from 'lucide-react-native';
import React, { useCallback, useEffect, useMemo, useState } from 'react';
import { isUpcoming, snapshotNow } from '../../utils/eventFilter';
import { parseEventDateMX } from '../../utils/calculations';
import {
  ActivityIndicator,
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
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';
import Badge from '../../components/ui/Badge';
import Particles from '../../components/ui/Particles';
import RequestZoneMap from '../../components/requests/RequestZoneMap';
import ClientProfileModal from '../../components/requests/ClientProfileModal';
import { eventCardCenter } from '../../utils/mapUtils';
import { openSupport } from '../../utils/support';

const TIER_CFG: Record<string, { emoji: string; label: string; color: string }> = {
  bronze: { emoji: '🥉', label: 'Bronce', color: '#CD7F32' },
  silver: { emoji: '🥈', label: 'Plata',  color: '#B0BEC5' },
  gold:   { emoji: '🥇', label: 'Oro',    color: '#FFD700' },
  vip:    { emoji: '💎', label: 'VIP',    color: '#00E5FF' },
};

function ClientAvatar({ client }: { client: any }) {
  const initial   = client?.full_name?.charAt(0)?.toUpperCase() ?? '?';
  const avatarUrl = client?.avatar_url ?? null;
  const tier      = client?.loyalty_tier ? TIER_CFG[client.loyalty_tier] : null;

  return (
    <View style={{ alignItems: 'center', gap: 4 }}>
      <View style={st.clientAvatar}>
        {avatarUrl ? (
          <Image source={{ uri: avatarUrl }} style={st.clientAvatarImg} />
        ) : (
          <Text style={st.clientAvatarInitial}>{initial}</Text>
        )}
      </View>
      {tier && (
        <View style={[st.tierBadge, { borderColor: tier.color + '70', backgroundColor: tier.color + '18' }]}>
          <Text style={[st.tierText, { color: tier.color }]}>{tier.emoji} {tier.label}</Text>
        </View>
      )}
    </View>
  );
}

const STATUS_MAP: Record<string, { label: string; variant: any; color: string }> = {
  pending:     { label: 'Pendiente',       variant: 'orange', color: COLORS.orange },
  accepted:    { label: 'Aceptada',        variant: 'blue',   color: COLORS.blue   },
  confirmed:   { label: 'Confirmada',      variant: 'green',  color: COLORS.green  },
  in_progress: { label: 'En curso',        variant: 'blue',   color: COLORS.blue   },
  completed:   { label: 'Completada',      variant: 'muted',  color: COLORS.muted  },
  cancelled:   { label: 'Cancelada',       variant: 'red',    color: COLORS.red    },
  no_show:     { label: 'No se presentó',  variant: 'red',    color: COLORS.red    },
};

const QUOTE_STATUS_CFG: Record<string, { label: string; color: string }> = {
  pending: { label: 'Esperando respuesta', color: COLORS.orange },
  quoted:  { label: 'Cotización enviada',  color: COLORS.blue   },
};

const MONTH_SHORT = ['ENE','FEB','MAR','ABR','MAY','JUN','JUL','AGO','SEP','OCT','NOV','DIC'];
const CAL_DAY_NAMES = ['Dom', 'Lun', 'Mar', 'Mié', 'Jue', 'Vie', 'Sáb'];

// ─── CalendarStrip ────────────────────────────────────────────────────────────

function localDate(d: Date): string {
  return `${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,'0')}-${String(d.getDate()).padStart(2,'0')}`;
}

function CalendarStrip({ events }: { events: any[] }) {
  const today    = new Date();
  const todayStr = localDate(today);
  const eventDays = new Set(events.map((e: any) => e.event_date).filter(Boolean));
  const days = Array.from({ length: 30 }, (_, i) => {
    const d = new Date(today);
    d.setDate(today.getDate() + i);
    return d;
  });

  return (
    <ScrollView
      horizontal
      showsHorizontalScrollIndicator={false}
      contentContainerStyle={{ paddingHorizontal: SPACING.xl, paddingVertical: 6, gap: 8 }}
      style={{ marginBottom: 10 }}
    >
      {days.map((d) => {
        const dateStr  = localDate(d);
        const hasEvent = eventDays.has(dateStr);
        const isToday  = dateStr === todayStr;
        return (
          <View key={dateStr} style={[
            st.calDay,
            isToday  && st.calDayToday,
            hasEvent && st.calDayEvent,
          ]}>
            <Text style={[st.calDayName, (isToday || hasEvent) && { color: COLORS.green }]}>
              {CAL_DAY_NAMES[d.getDay()]}
            </Text>
            <Text style={[st.calDayNum, hasEvent && { color: COLORS.text, fontFamily: FONTS.bodySemiBold }]}>
              {d.getDate()}
            </Text>
            {hasEvent && <View style={st.calDot} />}
          </View>
        );
      })}
    </ScrollView>
  );
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

function fmtTime(t: string | null | undefined): string {
  if (!t) return '';
  const [hStr, mStr] = t.substring(0, 5).split(':');
  const h = parseInt(hStr, 10);
  const h12 = h % 12 || 12;
  return `${h12}:${mStr} ${h >= 12 ? 'PM' : 'AM'}`;
}

// ─── Countdown hook ───────────────────────────────────────────────────────────

function useCountdown(eventDate: string | null, eventTime: string | null) {
  const [countdown, setCountdown] = useState('');
  useEffect(() => {
    if (!eventDate) return;
    const tick = () => {
      const timeStr = (eventTime ?? '00:00').substring(0, 5);
      const target = new Date(`${eventDate}T${timeStr}:00`);
      const diff   = target.getTime() - Date.now();
      if (diff <= 0) { setCountdown(''); return; }
      const d = Math.floor(diff / 86_400_000);
      const h = Math.floor((diff % 86_400_000) / 3_600_000);
      const m = Math.floor((diff % 3_600_000) / 60_000);
      const s = Math.floor((diff % 60_000) / 1_000);
      if (d > 0) setCountdown(`${d}d ${h}h ${String(m).padStart(2,'0')}m`);
      else setCountdown(`${h}h ${String(m).padStart(2,'0')}m ${String(s).padStart(2,'0')}s`);
    };
    tick();
    const id = setInterval(tick, 1_000);
    return () => clearInterval(id);
  }, [eventDate, eventTime]);
  return countdown;
}

// ─── EventCard ────────────────────────────────────────────────────────────────

function EventCard({ reservation: r, navigation, showMap = false, userLocation = null, groupPhotoUrl = null, onViewProfile = null }: any) {
  const isNoShow    = r.status === 'cancelled' && r.cancellation_type === 'system_auto' && r.cancel_reason === 'no_show_grupo';
  const displayKey  = isNoShow ? 'no_show' : r.status;
  const s           = STATUS_MAP[displayKey] ?? STATUS_MAP.accepted;
  const parts       = r.event_date?.split('-') ?? [];
  const day         = parts[2] ?? '—';
  const monthIdx    = parts[1] ? parseInt(parts[1], 10) - 1 : -1;
  const month       = monthIdx >= 0 ? MONTH_SHORT[monthIdx] : '—';

  const isPaid        = r.payment_status === 'paid' || r.payment_status === 'deposit_paid' || r.payment_status === 'fully_paid';
  const isLive        = r.status === 'in_progress';
  const isCompleted   = r.status === 'completed';
  const isExpress     = !!r.event_request_id;
  const showCountdown = (isPaid || r.status === 'accepted') && !isLive && !isNoShow;
  const countdown     = useCountdown(showCountdown ? r.event_date : null, r.event_time);

  const typeLabel = isExpress ? '⚡ Express' : '📅 Programada';
  const mapCenter = showMap && !isNoShow ? eventCardCenter(r) : null;

  return (
    <Pressable
      style={[
        st.card,
        isLive      && st.cardLive,
        isExpress   && !isNoShow && st.cardExpress,
        isCompleted && st.cardCompleted,
        isNoShow    && st.cardNoShow,
      ]}
      onPress={() => navigation.navigate('EventTimer', { reservation: r })}
    >
      {mapCenter && (
        <RequestZoneMap
          mapId={String(r.id)} center={mapCenter} typeLabel={typeLabel}
          userLocation={userLocation} groupPhotoUrl={groupPhotoUrl}
        />
      )}
      <View style={st.cardRow}>
      <View style={{ alignItems: 'center', gap: 6 }}>
        <View style={[st.dateBubble, { backgroundColor: `${s.color}18`, borderColor: `${s.color}40` }]}>
          <Text style={[st.dateDay, { color: s.color }]}>{day}</Text>
          <Text style={[st.dateMon, { color: s.color }]}>{month}</Text>
        </View>
        <ClientAvatar client={r.client} />
      </View>

      <View style={st.cardBody}>
        <View style={st.cardTop}>
          <Text style={st.clientName} numberOfLines={1}>
            {r.client?.full_name ?? 'Cliente'}
          </Text>
          <View style={{ alignItems: 'flex-end', gap: 4 }}>
            <Badge label={s.label} variant={s.variant} dot />
            {!mapCenter && !isNoShow && (
              <View style={[st.originBadge, isExpress && st.originBadgeExpress]}>
                <Text style={[st.originBadgeText, isExpress && { color: '#FFB300' }]}>{typeLabel}</Text>
              </View>
            )}
            {onViewProfile && (
              <Pressable
                onPress={(e: any) => { e.stopPropagation?.(); onViewProfile(); }}
                hitSlop={8}
                style={({ pressed }: any) => [st.viewProfileBtn, pressed && { opacity: 0.6 }]}
              >
                <Text style={st.viewProfileTx}>Ver perfil ›</Text>
              </Pressable>
            )}
          </View>
        </View>
        <Text style={st.pkgName} numberOfLines={1}>
          {isExpress
            ? `Evento Express · ${r.hours_count ?? '?'}h`
            : (r.quote_id || r._isQuote ? 'Cotización' : '—') +
              (r.quote?.duration_hours ? ` · ${r.quote.duration_hours}h` : '')
          }
        </Text>
        <View style={st.metaRow}>
          {r.event_time && (
            <View style={st.metaItem}>
              <Clock size={11} color={COLORS.muted} />
              <Text style={st.metaText}>{fmtTime(r.event_time)}</Text>
            </View>
          )}
          {r.address ? (
            <View style={st.metaItem}>
              <MapPin size={11} color={COLORS.muted} />
              <Text style={st.metaText} numberOfLines={1}>{r.address}</Text>
            </View>
          ) : null}
        </View>
        {isLive && (
          <View style={st.liveBtn}>
            <PlayCircle size={14} color={COLORS.green} />
            <Text style={st.liveBtnText}>🔴 Evento en curso — Ver en vivo</Text>
          </View>
        )}
        {showCountdown && countdown ? (
          <View style={st.countdownRow}>
            <Clock size={11} color={COLORS.green} />
            <Text style={st.countdownText}>Inicia en: {countdown}</Text>
          </View>
        ) : null}
        {isNoShow && (
          <View style={st.noShowRow}>
            <Text style={st.noShowText}>El grupo no se presentó — Admin revisará el pago</Text>
          </View>
        )}
        {isCompleted && (
          <Pressable
            style={st.earningsBtn}
            onPress={(e) => {
              e.stopPropagation?.();
              navigation.navigate('EventPayouts', { reservationId: r.id, reservation: r });
            }}
          >
            <TrendingUp size={13} color={COLORS.green} />
            <Text style={st.earningsBtnText}>Ver detalles de ganancias</Text>
          </Pressable>
        )}
      </View>

      <ChevronRight size={16} color={COLORS.muted} />
      </View>
    </Pressable>
  );
}

// ─── QuoteCard ────────────────────────────────────────────────────────────────

function QuoteCard({ quote: q, navigation, showMap = false, userLocation = null, groupPhotoUrl = null, onViewProfile = null }: any) {
  const cfg  = QUOTE_STATUS_CFG[q.status] ?? QUOTE_STATUS_CFG.pending;
  const parts = q.event_date?.split('-') ?? [];
  const day   = parts[2] ?? '—';
  const monthIdx = parts[1] ? parseInt(parts[1], 10) - 1 : -1;
  const month = monthIdx >= 0 ? MONTH_SHORT[monthIdx] : '—';

  const mapCenter = showMap ? eventCardCenter(q) : null;

  return (
    <Pressable
      style={[st.card, st.cardQuote]}
      onPress={() => navigation.navigate('GroupQuoteDetail', { quote: q })}
    >
      {mapCenter && (
        <RequestZoneMap
          mapId={`q-${q.id}`} center={mapCenter} typeLabel="📅 Programada"
          userLocation={userLocation} groupPhotoUrl={groupPhotoUrl}
        />
      )}
      <View style={st.cardRow}>
      <View style={{ alignItems: 'center', gap: 6 }}>
        <View style={[st.dateBubble, { backgroundColor: `${cfg.color}18`, borderColor: `${cfg.color}40` }]}>
          <Text style={[st.dateDay, { color: cfg.color }]}>{day}</Text>
          <Text style={[st.dateMon, { color: cfg.color }]}>{month}</Text>
        </View>
        <ClientAvatar client={q.client} />
      </View>

      <View style={st.cardBody}>
        <View style={st.cardTop}>
          <Text style={st.clientName} numberOfLines={1}>
            {q.client?.full_name ?? 'Cliente'}
          </Text>
          <View style={{ alignItems: 'flex-end', gap: 4 }}>
            <View style={[st.quotePill, { backgroundColor: `${cfg.color}18`, borderColor: `${cfg.color}40` }]}>
              <Text style={[st.quotePillText, { color: cfg.color }]}>{cfg.label}</Text>
            </View>
            {!mapCenter && (
              <View style={st.originBadge}>
                <Text style={st.originBadgeText}>📅 Programada</Text>
              </View>
            )}
            {onViewProfile && (
              <Pressable
                onPress={(e: any) => { e.stopPropagation?.(); onViewProfile(); }}
                hitSlop={8}
                style={({ pressed }: any) => [st.viewProfileBtn, pressed && { opacity: 0.6 }]}
              >
                <Text style={st.viewProfileTx}>Ver perfil ›</Text>
              </Pressable>
            )}
          </View>
        </View>
        <Text style={st.pkgName} numberOfLines={1}>
          {q.event_type ?? 'Evento'} · {q.duration_hours}h
        </Text>
        <View style={st.metaRow}>
          {q.event_time && (
            <View style={st.metaItem}>
              <Clock size={11} color={COLORS.muted} />
              <Text style={st.metaText}>{fmtTime(q.event_time)}</Text>
            </View>
          )}
          {q.event_municipio && (
            <View style={st.metaItem}>
              <MapPin size={11} color={COLORS.muted} />
              <Text style={st.metaText} numberOfLines={1}>{q.event_municipio}, {q.event_estado}</Text>
            </View>
          )}
        </View>
        {q.status === 'quoted' && q.total_amount && (
          <Text style={st.quotePrice}>${q.total_amount?.toLocaleString()} MXN cotizados</Text>
        )}
      </View>

      <ChevronRight size={16} color={COLORS.muted} />
      </View>
    </Pressable>
  );
}

// ─── ProposalCard — Express proposal awaiting client response ────────────────

function ProposalCard({ proposal: p, showMap = false, userLocation = null, groupPhotoUrl = null, onViewProfile = null }: any) {
  const req    = p.request ?? {};
  const data   = p.proposal_data ?? {};
  const parts  = req.event_date?.split('-') ?? [];
  const day    = parts[2] ?? '—';
  const monthIdx = parts[1] ? parseInt(parts[1], 10) - 1 : -1;
  const month  = monthIdx >= 0 ? MONTH_SHORT[monthIdx] : '—';
  const amt    = data.total_amount;

  const mapCenter = showMap && req.id ? eventCardCenter({ id: req.id, ...req }) : null;

  return (
    <View style={[st.card, st.cardQuote]}>
      {mapCenter && (
        <RequestZoneMap
          mapId={`p-${req.id}`} center={mapCenter} typeLabel="📩 Propuesta enviada"
          userLocation={userLocation} groupPhotoUrl={groupPhotoUrl}
        />
      )}
      <View style={st.cardRow}>
      <View style={{ alignItems: 'center', gap: 6 }}>
        <View style={[st.dateBubble, { backgroundColor: 'rgba(255,152,0,0.1)', borderColor: 'rgba(255,152,0,0.3)' }]}>
          <Text style={[st.dateDay,  { color: COLORS.orange }]}>{day}</Text>
          <Text style={[st.dateMon, { color: COLORS.orange }]}>{month}</Text>
        </View>
      </View>
      <View style={st.cardBody}>
        <View style={st.cardTop}>
          <Text style={st.clientName} numberOfLines={1}>📩 Propuesta enviada</Text>
          <View style={{ alignItems: 'flex-end', gap: 4 }}>
            <View style={[st.quotePill, { backgroundColor: 'rgba(255,152,0,0.1)', borderColor: 'rgba(255,152,0,0.3)' }]}>
              <Text style={[st.quotePillText, { color: COLORS.orange }]}>Esperando</Text>
            </View>
            {onViewProfile && (
              <Pressable
                onPress={onViewProfile}
                hitSlop={8}
                style={({ pressed }: any) => [st.viewProfileBtn, pressed && { opacity: 0.6 }]}
              >
                <Text style={st.viewProfileTx}>Ver perfil ›</Text>
              </Pressable>
            )}
          </View>
        </View>
        <Text style={st.pkgName} numberOfLines={1}>
          {req.event_type ?? 'Evento'} · {req.hours ?? '?'}h{req.genre ? ` · ${req.genre}` : ''}
        </Text>
        <View style={st.metaRow}>
          {req.event_time && (
            <View style={st.metaItem}>
              <Clock size={11} color={COLORS.muted} />
              <Text style={st.metaText}>{fmtTime(req.event_time)}</Text>
            </View>
          )}
          {(req.location_municipio || req.location_city) && (
            <View style={st.metaItem}>
              <MapPin size={11} color={COLORS.muted} />
              <Text style={st.metaText} numberOfLines={1}>
                {req.location_municipio ?? req.location_city}, {req.location_estado}
              </Text>
            </View>
          )}
        </View>
        {amt != null && (
          <Text style={st.quotePrice}>${Number(amt).toLocaleString()} MXN cotizados</Text>
        )}
        <Text style={[st.metaText, { marginTop: 4, color: COLORS.muted }]}>
          El cliente está revisando tu propuesta
        </Text>
      </View>
      </View>
    </View>
  );
}

// ─── Main Screen ──────────────────────────────────────────────────────────────

export default function GroupEventsScreen({ navigation }: any) {
  const [activeTab,    setActiveTab]    = useState<'proximos' | 'pendientes' | 'historial'>('proximos');
  const [reservations, setReservations] = useState<any[]>([]);
  const [quotes,       setQuotes]       = useState<any[]>([]);
  const [proposals,    setProposals]    = useState<any[]>([]); // Express proposals sent by this group
  // GPS + foto del grupo → ruta con instrumentos en las tarjetas (como ExpressCard)
  const [userLocation,  setUserLocation]  = useState<{ latitude: number; longitude: number } | null>(null);
  const [groupPhotoUrl, setGroupPhotoUrl] = useState<string | null>(null);
  const [profileClientId, setProfileClientId] = useState<string | null>(null);

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
  const [groupName,    setGroupName]    = useState<string | null>(null);
  const [loading,      setLoading]      = useState(true);
  const [refreshing,   setRefreshing]   = useState(false);
  const [unreadCount,  setUnreadCount]  = useState(0);
  const [walletBalance, setWalletBalance] = useState(0);

  const fetchWallet = useCallback(async () => {
    const { data } = await supabase.rpc('get_my_wallet');
    if (data?.ok) {
      setWalletBalance(data.wallet?.available_balance ?? 0);
    }
  }, []);

  useEffect(() => { fetchAll(); fetchWallet(); }, []);

  useEffect(() => {
    const unsub = navigation.addListener('focus', () => { fetchAll(); fetchUnread(); fetchWallet(); });
    return unsub;
  }, [navigation]);

  // Realtime: actualizar saldo de billetera cuando llega un pago
  useEffect(() => {
    const sub = supabase
      .channel('group-events-wallet-realtime')
      .on('postgres_changes',
        { event: 'UPDATE', schema: 'public', table: 'group_wallets' },
        () => fetchWallet())
      .on('postgres_changes',
        { event: 'INSERT', schema: 'public', table: 'wallet_transactions' },
        () => fetchWallet())
      .subscribe();
    return () => { supabase.removeChannel(sub); };
  }, [fetchWallet]);

  // Realtime: actualizar estado de reserva en la lista sin salir de la pantalla
  useEffect(() => {
    const sub = supabase
      .channel('group-events-status')
      .on('postgres_changes', {
        event: 'UPDATE',
        schema: 'public',
        table: 'reservations',
      }, (payload: any) => {
        const upd = payload.new;
        setReservations(prev =>
          prev.map(r => r.id === upd.id ? { ...r, ...upd } : r)
        );
      })
      .subscribe();
    return () => { supabase.removeChannel(sub); };
  }, []);

  const fetchUnread = async () => {
    const { data: sd } = await supabase.auth.getSession();
    if (!sd.session) return;
    const { count } = await supabase
      .from('notifications')
      .select('*', { count: 'exact', head: true })
      .eq('user_id', sd.session.user.id)
      .eq('is_read', false);
    setUnreadCount(count ?? 0);
  };

  const fetchAll = async () => {
    try {
      const { data: grpRaw } = await supabase.rpc('get_my_group').maybeSingle();
      if (!grpRaw) { setLoading(false); setRefreshing(false); return; }

      const grp = grpRaw as { id: string; name: string };
      setGroupName(grp.name);

      // Backend floor: no cargar eventos de hace más de 1 año
      const oneYearAgo = new Date();
      oneYearAgo.setFullYear(oneYearAgo.getFullYear() - 1);
      const floorDate = oneYearAgo.toISOString().split('T')[0];

      // Marcar abandonados ANTES de cargar (no-show del grupo, SECURITY DEFINER)
      await supabase.rpc('mark_abandoned_reservations');

      // ── Reservas del grupo ─────────────────────────────────────────────────────
      // Nota: profiles se hidrata por separado (query propia) porque PostgREST
      // falla con "more than one relationship" cuando hay múltiples FKs entre
      // reservations y profiles. quotes usa !left para manejar filas con
      // quote_id nulo sin excluirlas. packages fue eliminada de la DB.
      const { data: resData, error: resError } = await supabase
        .from('reservations')
        .select('id,client_id,group_id,event_date,event_time,address,status,payment_status,total_price,quote_id,event_started_at,group_arrived_at,break_type,notes,folio,created_at,hours_count,event_request_id,cancellation_type,cancel_reason,cancelled_at,quote:quotes!left(duration_hours,overtime_1h_price,overtime_2h_price,overtime_3h_price,event_type,latitude,longitude),event_request:event_requests!event_request_id(latitude,longitude,event_lat,event_lng)')
        .eq('group_id', grp.id)
        .or('payment_status.eq.paid,payment_status.eq.deposit_paid,payment_status.eq.fully_paid,status.eq.in_progress,status.eq.accepted,status.eq.confirmed,status.eq.completed')
        .gte('event_date', floorDate)
        .order('event_date', { ascending: true });

      console.log('[GroupEvents] fetch: rows=', resData?.length ?? 'null', 'err=', resError?.message ?? 'none');

      // Hidratar perfiles de clientes en query separada (evita ambigüedad PostgREST)
      let clientMap: Record<string, any> = {};
      if (resData && resData.length > 0) {
        const clientIds = [...new Set((resData as any[]).map((r: any) => r.client_id).filter(Boolean))];
        if (clientIds.length > 0) {
          const { data: profilesData } = await supabase
            .from('profiles')
            .select('id,full_name,avatar_url,loyalty_tier')
            .in('id', clientIds);
          clientMap = Object.fromEntries((profilesData ?? []).map((p: any) => [p.id, p]));
        }
      }

      // ── Cotizaciones aceptadas sin reserva vinculada ────────
      const { data: acceptedQuotes } = await supabase
        .from('quotes')
        .select('*, client:profiles!client_id(full_name,avatar_url,loyalty_tier)')
        .eq('group_id', grp.id)
        .in('status', ['accepted', 'in_progress', 'completed'])
        .gte('event_date', floorDate)
        .order('event_date', { ascending: true });

      const mergedRes = (resData ?? []).map((r: any) => ({
        ...r,
        client: clientMap[r.client_id] ?? null,
      }));

      // Cotizaciones aceptadas que NO tienen reserva vinculada
      const reservationQuoteIds = new Set(mergedRes.map((r: any) => r.quote_id).filter(Boolean));
      const quoteEvents = (acceptedQuotes ?? [])
        .filter((q: any) => !reservationQuoteIds.has(q.id))
        .map((q: any) => ({
          id:             `quote-${q.id}`,
          event_date:     q.event_date,
          event_time:     q.event_time ?? null,
          status:         'accepted',
          payment_status: 'paid',
          address:        [q.event_municipio, q.event_estado].filter(Boolean).join(', ') || null,
          latitude:       q.latitude ?? null,
          longitude:      q.longitude ?? null,
          client_id:      q.client_id ?? null,
          client:         q.client ?? null,
          quote:          { duration_hours: q.duration_hours, event_type: q.event_type ?? null },
          _isQuote:       true,
          _quoteData:     q,
        }));

      setReservations([...mergedRes, ...quoteEvents].sort((a: any, b: any) =>
        (a.event_date ?? '').localeCompare(b.event_date ?? '')
      ));

      // ── Cotizaciones pendientes ─────────────────────────────
      const { data: quoteData } = await supabase
        .from('quotes')
        .select('*, client:profiles!client_id(full_name,avatar_url,loyalty_tier)')
        .eq('group_id', grp.id)
        .in('status', ['pending', 'quoted'])
        .order('created_at', { ascending: false });

      setQuotes(quoteData ?? []);

      // ── Propuestas Express enviadas — esperando respuesta del cliente ──
      const { data: proposalData } = await supabase
        .from('event_request_proposals')
        .select(`
          request_id,
          proposal_data,
          request:event_requests!request_id(
            id, client_id, event_type, event_date, event_time, hours, guest_count,
            location_city, location_municipio, location_estado, genre, status,
            latitude, longitude, event_lat, event_lng
          )
        `)
        .eq('group_id', grp.id);

      // Only show proposals where the request is still open/negotiating (not yet accepted/reserved)
      const activePropIds = new Set([...(quoteData ?? []).map((q: any) => q.event_request_id).filter(Boolean)]);
      const activeProposals = (proposalData ?? []).filter((p: any) => {
        const s = p.request?.status;
        return s === 'open' || s === 'en_negociacion' || s === 'negotiating';
      }).filter((p: any) => !activePropIds.has(p.request_id));
      setProposals(activeProposals);
    } catch (e: any) {
      console.log('[GroupEvents] Error:', e.message);
    } finally {
      setLoading(false);
      setRefreshing(false);
    }
  };

  const onRefresh = () => { setRefreshing(true); fetchAll(); };

  // Derived arrays — memoized so filters run once per reservations change,
  // not on every render. nowMs is computed once per memo pass (not N times).
  const { liveEvents, completedEvts, upcoming, historyEvts, noShowEvts } = useMemo(() => {
    const nowMs     = snapshotNow();
    const activeSet = new Set(['accepted', 'confirmed', 'pending', 'pending_payment']);
    const getDurationMs = (r: any): number => {
      const h = r.hours_count ?? r.quote?.duration_hours ?? 4;
      return h * 3600 * 1000;
    };
    // Usa timestamps directos en lugar de string comparison para evitar problemas
    // con formato/timezone. Evento con hora nula se trata como 23:59 del día
    // para que se quede en Próximos todo el día.
    const isProximo = (r: any) => {
      if (!r.event_date) return false;
      const time = r.event_time ? r.event_time.substring(0, 5) : '23:59';
      const startTs = parseEventDateMX(r.event_date, time);
      if (!startTs) return true;
      return nowMs < startTs.getTime() + getDurationMs(r);
    };
    return {
      liveEvents:    reservations.filter(r => r.status === 'in_progress'),
      completedEvts: reservations.filter(r => r.status === 'completed'),
      upcoming:      reservations.filter(r => activeSet.has(r.status) && isProximo(r)),
      historyEvts:   reservations.filter(r => activeSet.has(r.status) && !isProximo(r)),
      noShowEvts:    reservations.filter(r =>
        r.status === 'cancelled' &&
        r.cancellation_type === 'system_auto' &&
        r.cancel_reason === 'no_show_grupo'
      ),
    };
  }, [reservations]);

  if (loading) {
    return (
      <View style={st.container}>
        <Particles />
        <View style={st.center}>
          <ActivityIndicator size="large" color={COLORS.green} />
        </View>
      </View>
    );
  }

  return (
    <View style={st.container}>
      <Particles />
      <SafeAreaView style={{ flex: 1 }}>

        {/* Header */}
        <View style={st.header}>
          <View style={{ flex: 1 }}>
            <Text style={st.title}>Eventos</Text>
            {groupName && <Text style={st.subtitle}>{groupName}</Text>}
          </View>
          <Pressable style={st.iconBtn} onPress={() => navigation.navigate('GroupStats')}>
            <BarChart2 size={18} color={COLORS.green} />
          </Pressable>
          <Pressable style={st.iconBtn} onPress={() => navigation.navigate('Notifications')}>
            <Bell size={18} color={COLORS.muted2} />
            {unreadCount > 0 && (
              <View style={st.badgeDot}>
                <Text style={st.badgeDotText}>{unreadCount > 9 ? '9+' : unreadCount}</Text>
              </View>
            )}
          </Pressable>
        </View>

        {/* Wallet widget */}
        <Pressable style={st.walletWidget} onPress={() => navigation.navigate('Wallet')}>
          <Text style={st.walletEmoji}>💰</Text>
          <View style={{ flex: 1 }}>
            <Text style={st.walletLabel}>Mi billetera</Text>
            <Text style={st.walletAmount}>
              ${walletBalance.toLocaleString('es-MX', { minimumFractionDigits: 0 })} MXN
            </Text>
          </View>
          <Text style={st.walletAction}>Ver →</Text>
        </Pressable>

        {/* Tabs */}
        <View style={st.tabs}>
          <Pressable
            style={[st.tab, activeTab === 'proximos' && st.tabActive]}
            onPress={() => setActiveTab('proximos')}
          >
            <Text style={[st.tabText, activeTab === 'proximos' && st.tabTextActive]}>
              Próximos
            </Text>
          </Pressable>
          <Pressable
            style={[st.tab, activeTab === 'pendientes' && st.tabActive]}
            onPress={() => setActiveTab('pendientes')}
          >
            <Text style={[st.tabText, activeTab === 'pendientes' && st.tabTextActive]}>
              Pendientes
              {(quotes.length + proposals.length) > 0 && (
                <Text style={st.tabBadge}> {quotes.length + proposals.length}</Text>
              )}
            </Text>
          </Pressable>
          <Pressable
            style={[st.tab, activeTab === 'historial' && st.tabActive]}
            onPress={() => setActiveTab('historial')}
          >
            <Text style={[st.tabText, activeTab === 'historial' && st.tabTextActive]}>
              Historial
              {(completedEvts.length + historyEvts.length + noShowEvts.length) > 0 && (
                <Text style={st.tabBadge}> {completedEvts.length + historyEvts.length + noShowEvts.length}</Text>
              )}
            </Text>
          </Pressable>
        </View>

        <ScrollView
          showsVerticalScrollIndicator={false}
          contentContainerStyle={st.list}
          refreshControl={<RefreshControl refreshing={refreshing} onRefresh={onRefresh} tintColor={COLORS.green} />}
        >

          {/* ── Tab: Próximos eventos ── */}
          {activeTab === 'proximos' && (
            liveEvents.length === 0 && upcoming.length === 0 ? (
              <View style={st.emptyState}>
                <Text style={st.emptyIcon}>📅</Text>
                <Text style={st.emptyTitle}>Sin eventos próximos</Text>
                <Text style={st.emptyText}>Los eventos pagados y confirmados aparecerán aquí</Text>
              </View>
            ) : (
              <>
                {/* En curso */}
                {liveEvents.length > 0 && (
                  <>
                    <Text style={[st.sectionTitle, { color: '#EF5350' }]}>🔴 En curso · {liveEvents.length}</Text>
                    {liveEvents.map(r => (
                      <EventCard key={r.id} reservation={r} navigation={navigation} showMap userLocation={userLocation} groupPhotoUrl={groupPhotoUrl}
                        onViewProfile={r.client_id ? () => setProfileClientId(r.client_id) : null} />
                    ))}
                  </>
                )}
                {/* Próximos */}
                {upcoming.length > 0 && (
                  <>
                    <Text style={[st.sectionTitle, { marginTop: liveEvents.length > 0 ? 20 : 0 }]}>
                      Próximos · {upcoming.length}
                    </Text>
                    <CalendarStrip events={upcoming} />
                    {/* Mapa solo en las primeras tarjetas — listas largas con N mapas causan jank */}
                    {upcoming.map((r, idx) => (
                      <EventCard key={r.id} reservation={r} navigation={navigation} showMap={idx < 6} userLocation={userLocation} groupPhotoUrl={groupPhotoUrl}
                        onViewProfile={r.client_id ? () => setProfileClientId(r.client_id) : null} />
                    ))}
                  </>
                )}
              </>
            )
          )}

          {/* ── Tab: Pendientes ── */}
          {activeTab === 'pendientes' && (
            quotes.length === 0 && proposals.length === 0 ? (
              <View style={st.emptyState}>
                <Text style={st.emptyIcon}>📋</Text>
                <Text style={st.emptyTitle}>Sin solicitudes pendientes</Text>
                <Text style={st.emptyText}>Las cotizaciones nuevas de clientes aparecerán aquí</Text>
              </View>
            ) : (
              <>
                {proposals.length > 0 && (
                  <>
                    <Text style={st.sectionTitle}>Propuestas enviadas · {proposals.length}</Text>
                    {proposals.map((p: any, idx: number) => (
                      <ProposalCard key={p.request_id} proposal={p} showMap={idx < 4} userLocation={userLocation} groupPhotoUrl={groupPhotoUrl}
                        onViewProfile={p.request?.client_id ? () => setProfileClientId(p.request.client_id) : null} />
                    ))}
                  </>
                )}
                {quotes.length > 0 && (
                  <>
                    <Text style={[st.sectionTitle, { marginTop: proposals.length > 0 ? 20 : 0 }]}>
                      Solicitudes · {quotes.length}
                    </Text>
                    {quotes.map((q, idx) => (
                      <QuoteCard key={q.id} quote={q} navigation={navigation} showMap={idx < 6} userLocation={userLocation} groupPhotoUrl={groupPhotoUrl}
                        onViewProfile={q.client_id ? () => setProfileClientId(q.client_id) : null} />
                    ))}
                  </>
                )}
              </>
            )
          )}

          {/* ── Tab: Historial ── */}
          {activeTab === 'historial' && (
            completedEvts.length === 0 && historyEvts.length === 0 && noShowEvts.length === 0 ? (
              <View style={st.emptyState}>
                <Text style={st.emptyIcon}>📆</Text>
                <Text style={st.emptyTitle}>Sin eventos pasados</Text>
                <Text style={st.emptyText}>Los eventos realizados aparecerán aquí</Text>
              </View>
            ) : (
              <>
                {completedEvts.length > 0 && (
                  <>
                    <Text style={[st.sectionTitle, { color: COLORS.green }]}>
                      ✅ Finalizados · {completedEvts.length}
                    </Text>
                    {completedEvts.map(r => (
                      <EventCard key={r.id} reservation={r} navigation={navigation} />
                    ))}
                  </>
                )}
                {historyEvts.length > 0 && (
                  <>
                    <Text style={[st.sectionTitle, { marginTop: completedEvts.length > 0 ? 20 : 0 }]}>
                      Sin cerrar · {historyEvts.length}
                    </Text>
                    {historyEvts.map(r => (
                      <EventCard key={r.id} reservation={r} navigation={navigation} />
                    ))}
                  </>
                )}
                {noShowEvts.length > 0 && (
                  <>
                    <Text style={[st.sectionTitle, {
                      color: COLORS.red,
                      marginTop: (completedEvts.length > 0 || historyEvts.length > 0) ? 20 : 0,
                    }]}>
                      ⚠️ No se presentaron · {noShowEvts.length}
                    </Text>
                    {noShowEvts.map(r => (
                      <EventCard key={r.id} reservation={r} navigation={navigation} />
                    ))}
                  </>
                )}
              </>
            )
          )}

          {/* Soporte discreto al pie de la lista de eventos */}
          <Pressable style={st.supportFooter} hitSlop={8} onPress={() => openSupport()}>
            <Text style={st.supportFooterText}>💬 ¿Necesitas ayuda? Contacta a soporte</Text>
          </Pressable>

        </ScrollView>
      </SafeAreaView>

      {/* Perfil público del cliente (RPC 435 — sin teléfono/email) */}
      <ClientProfileModal clientId={profileClientId} onClose={() => setProfileClientId(null)} />
    </View>
  );
}

// ─── Styles ───────────────────────────────────────────────────────────────────

const st = StyleSheet.create({
  container: { flex: 1, backgroundColor: COLORS.bg },
  center:    { flex: 1, alignItems: 'center', justifyContent: 'center' },

  header: {
    flexDirection: 'row', alignItems: 'center', gap: 8,
    paddingHorizontal: SPACING.xl, paddingTop: 16, paddingBottom: 12,
  },
  title:    { fontFamily: FONTS.title, fontSize: 26, color: COLORS.text },
  subtitle: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.green, marginTop: 1 },

  iconBtn: {
    width: 38, height: 38, borderRadius: 19,
    backgroundColor: 'rgba(0,230,118,0.08)',
    alignItems: 'center', justifyContent: 'center',
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.18)',
  },
  badgeDot: {
    position: 'absolute', top: -2, right: -2,
    minWidth: 16, height: 16, borderRadius: 8,
    backgroundColor: COLORS.green,
    alignItems: 'center', justifyContent: 'center', paddingHorizontal: 3,
  },
  badgeDotText: { fontFamily: FONTS.bodySemiBold, fontSize: 9, color: COLORS.bg },

  tabs: {
    flexDirection: 'row',
    marginHorizontal: SPACING.xl, marginBottom: 12,
    backgroundColor: COLORS.card,
    borderRadius: RADIUS.lg, borderWidth: 1, borderColor: COLORS.border,
    padding: 4,
  },
  tab: {
    flex: 1, paddingVertical: 9, alignItems: 'center', borderRadius: RADIUS.md,
  },
  tabActive: { backgroundColor: COLORS.green },
  tabText:      { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted2 },
  tabTextActive: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.bg },
  tabBadge: { fontFamily: FONTS.bodySemiBold, fontSize: 11, color: 'inherit' },

  list: { paddingHorizontal: SPACING.xl, paddingBottom: 40, gap: 10 },

  sectionTitle: {
    fontFamily: FONTS.bodySemiBold, fontSize: 12, color: COLORS.muted2,
    textTransform: 'uppercase', letterSpacing: 0.6, marginBottom: 4,
  },
  supportFooter:     { alignSelf: 'center', marginTop: 24, marginBottom: 8, paddingVertical: 8, paddingHorizontal: 14 },
  supportFooterText: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted2, textDecorationLine: 'underline' },

  // Contenedor vertical estilo ExpressCard: mapa arriba (opcional) + fila de contenido
  card: {
    backgroundColor: '#060c06', borderRadius: 20, overflow: 'hidden',
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.35)',
  },
  cardRow: {
    flexDirection: 'row', alignItems: 'center', gap: 14, padding: 14,
  },
  originBadge: {
    backgroundColor: 'rgba(0,230,118,0.10)', borderRadius: 20,
    paddingHorizontal: 7, paddingVertical: 3,
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.30)',
  },
  originBadgeExpress: {
    backgroundColor: 'rgba(255,179,0,0.1)', borderColor: 'rgba(255,179,0,0.3)',
  },
  originBadgeText: { fontFamily: FONTS.bodyMedium, fontSize: 10, color: COLORS.green },
  viewProfileBtn: {
    backgroundColor: 'rgba(0,230,118,0.10)', borderRadius: 20,
    paddingHorizontal: 8, paddingVertical: 3,
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.35)',
  },
  viewProfileTx: { fontFamily: FONTS.bodySemiBold, fontSize: 10, color: COLORS.green },
  cardQuote: {
    borderColor: `${COLORS.green}30`,
    backgroundColor: 'rgba(0,230,118,0.03)',
  },
  cardLive: {
    borderColor: `${COLORS.green}60`,
    backgroundColor: 'rgba(0,230,118,0.06)',
  },

  dateBubble: {
    width: 46, height: 54, borderRadius: 14, borderWidth: 1,
    alignItems: 'center', justifyContent: 'center', flexShrink: 0,
  },
  dateDay: { fontFamily: FONTS.title, fontSize: 17, lineHeight: 21 },
  dateMon: { fontFamily: FONTS.bodyMedium, fontSize: 9, letterSpacing: 1 },

  cardBody: { flex: 1, gap: 5 },
  cardTop:  { flexDirection: 'row', alignItems: 'flex-start', justifyContent: 'space-between', gap: 8 },
  clientName: { fontFamily: FONTS.title, fontSize: 16, color: COLORS.text, flex: 1 },
  pkgName:    { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted },
  metaRow:    { flexDirection: 'row', gap: 6, flexWrap: 'wrap', marginTop: 2 },
  metaItem:   {
    flexDirection: 'row', alignItems: 'center', gap: 4,
    backgroundColor: '#151515', borderRadius: 8,
    paddingHorizontal: 7, paddingVertical: 4,
  },
  metaText:   { fontFamily: FONTS.bodyMedium, fontSize: 11, color: COLORS.muted2 },

  liveBtn: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 6,
    marginTop: 10, backgroundColor: 'rgba(0,230,118,0.10)',
    borderTopWidth: 1, borderTopColor: 'rgba(0,230,118,0.25)',
    paddingVertical: 10, paddingHorizontal: 14, borderRadius: 0,
    marginHorizontal: -14, marginBottom: -14,
    borderBottomLeftRadius: RADIUS.lg, borderBottomRightRadius: RADIUS.lg,
  },
  liveBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.green },
  countdownRow: { flexDirection: 'row', alignItems: 'center', gap: 4, marginTop: 3 },
  countdownText: { fontFamily: FONTS.bodyMedium, fontSize: 11, color: COLORS.green },

  quotePill: {
    paddingHorizontal: 8, paddingVertical: 3, borderRadius: 20, borderWidth: 1,
  },
  quotePillText: { fontFamily: FONTS.bodyMedium, fontSize: 11 },
  quotePrice:    { fontFamily: FONTS.bodySemiBold, fontSize: 12, color: COLORS.green, marginTop: 2 },

  emptyState: { alignItems: 'center', paddingTop: 80, gap: 8 },
  emptyIcon:  { fontSize: 44 },
  emptyTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 17, color: COLORS.text },
  emptyText:  { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2, textAlign: 'center', lineHeight: 20 },

  // CalendarStrip
  calDay: {
    width: 42, paddingVertical: 8, borderRadius: RADIUS.md,
    alignItems: 'center', gap: 3,
    backgroundColor: COLORS.card, borderWidth: 1, borderColor: COLORS.border,
  },
  calDayToday: { borderColor: COLORS.green },
  calDayEvent: { borderColor: COLORS.green, backgroundColor: 'rgba(0,230,118,0.08)' },
  calDayName:  { fontFamily: FONTS.bodyMedium, fontSize: 9, color: COLORS.muted, textTransform: 'uppercase' },
  calDayNum:   { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.muted2 },
  calDot:      { width: 5, height: 5, borderRadius: 3, backgroundColor: COLORS.green },

  walletWidget: {
    flexDirection: 'row', alignItems: 'center', gap: 12,
    marginHorizontal: SPACING.xl, marginBottom: 14,
    backgroundColor: COLORS.greenMuted, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: `${COLORS.green}40`,
    paddingHorizontal: SPACING.lg, paddingVertical: 12,
  },
  walletEmoji:  { fontSize: 16 },
  walletLabel:  { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted2, marginBottom: 1 },
  walletAmount: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.green },
  walletAction: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.green },

  cardExpress: {
    borderColor: `${COLORS.green}40`,
  },
  cardCompleted: {
    opacity: 0.85,
    borderColor: 'rgba(255,255,255,0.10)',   // historial sobrio, sin borde verde
  },
  cardNoShow: {
    opacity: 0.6,
    borderColor: '#4B5563',
  },
  noShowRow: {
    marginTop: 4,
  },
  noShowText: {
    fontFamily: FONTS.body, fontSize: 11, color: COLORS.red,
  },
  earningsBtn: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 6,
    marginTop: 10, backgroundColor: 'rgba(0,230,118,0.06)',
    borderTopWidth: 1, borderTopColor: '#1c1c1c',
    paddingVertical: 11, paddingHorizontal: 14,
    marginHorizontal: -14, marginBottom: -14,
    borderBottomLeftRadius: 20, borderBottomRightRadius: 20,
  },
  earningsBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.green },

  clientAvatar: {
    width: 40, height: 40, borderRadius: 20,
    backgroundColor: '#1a1a1a', borderWidth: 1, borderColor: '#2a2a2a',
    alignItems: 'center', justifyContent: 'center', overflow: 'hidden',
  },
  clientAvatarImg:     { width: 40, height: 40, borderRadius: 20 },
  clientAvatarInitial: { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.muted2 },
  tierBadge: {
    paddingHorizontal: 6, paddingVertical: 2, borderRadius: 20,
    borderWidth: 1, alignItems: 'center',
  },
  tierText: { fontFamily: FONTS.bodyMedium, fontSize: 9 },
});
