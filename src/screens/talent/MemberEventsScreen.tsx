import { BarChart2, Bell, ChevronRight, Clock, ExternalLink, MapPin, Navigation, PlayCircle } from 'lucide-react-native';
import React, { useEffect, useMemo, useState } from 'react';
import {
  ActivityIndicator,
  Linking,
  Pressable,
  RefreshControl,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from 'react-native';

const CAL_DAY_NAMES = ['Dom', 'Lun', 'Mar', 'Mié', 'Jue', 'Vie', 'Sáb'];

function CalendarStrip({ events }: { events: any[] }) {
  const today = new Date();
  const todayStr = today.toISOString().split('T')[0];
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
        const dateStr = d.toISOString().split('T')[0];
        const hasEvent = eventDays.has(dateStr);
        const isToday  = dateStr === todayStr;
        return (
          <View key={dateStr} style={[
            styles.calDay,
            isToday  && styles.calDayToday,
            hasEvent && styles.calDayEvent,
          ]}>
            <Text style={[styles.calDayName, (isToday || hasEvent) && { color: COLORS.green }]}>
              {CAL_DAY_NAMES[d.getDay()]}
            </Text>
            <Text style={[styles.calDayNum, hasEvent && { color: COLORS.text, fontFamily: FONTS.bodySemiBold }]}>
              {d.getDate()}
            </Text>
            {hasEvent && <View style={styles.calDot} />}
          </View>
        );
      })}
    </ScrollView>
  );
}
import { SafeAreaView } from 'react-native-safe-area-context';
import { isUpcoming, snapshotNow } from '../../utils/eventFilter';
import { supabase } from '../../config/supabase';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';
import Badge from '../../components/ui/Badge';
import Particles from '../../components/ui/Particles';

const STATUS_MAP: Record<string, { label: string; variant: any; color: string }> = {
  pending:                    { label: 'Pendiente',      variant: 'orange', color: COLORS.orange },
  pending_group_confirmation: { label: 'Por confirmar',  variant: 'orange', color: COLORS.orange },
  accepted:                   { label: 'Aceptada',       variant: 'blue',   color: COLORS.blue   },
  confirmed:                  { label: 'Confirmada',     variant: 'green',  color: COLORS.green  },
  in_progress:                { label: 'En curso',       variant: 'blue',   color: COLORS.blue   },
  completed:                  { label: 'Completada',     variant: 'muted',  color: COLORS.muted  },
  cancelled:                  { label: 'Cancelada',      variant: 'red',    color: COLORS.red    },
  rejected:                   { label: 'Rechazada',      variant: 'red',    color: COLORS.red    },
};

const MONTH_SHORT = ['ENE','FEB','MAR','ABR','MAY','JUN','JUL','AGO','SEP','OCT','NOV','DIC'];

export default function MemberEventsScreen({ navigation }: any) {
  const [reservations,    setReservations]    = useState<any[]>([]);
  const [pendingQuotesList, setPendingQuotesList] = useState<any[]>([]);
  const [groupName,       setGroupName]       = useState<string | null>(null);
  const [loading,         setLoading]         = useState(true);
  const [refreshing,      setRefreshing]      = useState(false);
  const [noGroup,         setNoGroup]         = useState(false);
  const [unreadCount,     setUnreadCount]     = useState(0);
  const [activeTab,       setActiveTab]       = useState<'proximos' | 'pendientes'>('proximos');

  useEffect(() => { fetchEvents(); }, []);

  useEffect(() => {
    const unsub = navigation.addListener('focus', () => {
      fetchEvents();
      fetchUnread();
    });
    return unsub;
  }, [navigation]);

  // Realtime: actualizar estado de reserva en la lista sin recargar manualmente
  useEffect(() => {
    const sub = supabase
      .channel('member-events-status')
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

  const fetchEvents = async () => {
    try {
      // Obtener el grupo al que pertenece el integrante
      const { data: grpRaw, error: grpErr } = await supabase
        .rpc('get_my_group')
        .maybeSingle();

      if (grpErr || !grpRaw) {
        setNoGroup(true);
        setLoading(false);
        setRefreshing(false);
        return;
      }

      const grp = grpRaw as { id: string; name: string };
      setGroupName(grp.name);
      setNoGroup(false);

      // ── Reservas del grupo (join directo a profiles para evitar bloqueos RLS) ──
      const { data: resData, error: resErr } = await supabase
        .from('reservations')
        .select('id,client_id,group_id,event_date,event_time,address,status,payment_status,total_price,quote_id,event_started_at,break_type,group_arrived_at,notes,created_at,event_request_id,hours_count,client:profiles!client_id(full_name)')
        .eq('group_id', grp.id)
        .order('event_date', { ascending: true });

      // ── Cotizaciones aceptadas (eventos sin reserva creada aún) ─
      const { data: quoteData } = await supabase
        .from('quotes')
        .select('*, client:profiles!client_id(full_name)')
        .eq('group_id', grp.id)
        .in('status', ['accepted', 'in_progress', 'completed'])
        .order('event_date', { ascending: true });

      // ── Cotizaciones pendientes (tab Pendientes) ────────────────
      const { data: pendingData } = await supabase
        .from('quotes')
        .select('*, client:profiles!client_id(full_name)')
        .eq('group_id', grp.id)
        .in('status', ['pending', 'quoted'])
        .order('created_at', { ascending: false });
      setPendingQuotesList(pendingData ?? []);

      // Si resErr (ej. RLS), continuar con array vacío para mostrar cotizaciones
      const resRows = resErr ? [] : (resData ?? []);

      const merged = resRows.map((r: any) => ({ ...r }));

      // ── Convertir cotizaciones aceptadas a formato unificado ───
      // Solo mostramos las que aún NO tienen una reserva asociada (quote_id match)
      const reservationQuoteIds = new Set(
        merged.map((r: any) => r.quote_id).filter(Boolean)
      );

      const quoteEvents = (quoteData ?? [])
        .filter((q: any) => !reservationQuoteIds.has(q.id))
        .map((q: any) => ({
          id:         `quote-${q.id}`,
          event_date: q.event_date,
          event_time: q.event_time ?? null,
          status:     q.status ?? 'accepted',
          address:    [q.event_municipio, q.event_estado].filter(Boolean).join(', ') || null,
          client:     q.client ?? null,
          package:    { name: `Cotización · ${q.duration_hours}h`, duration_hours: q.duration_hours },
          _isQuote:   true,
          _quoteData: q,
        }));

      // Ordenar todo por event_date
      const all = [...merged, ...quoteEvents].sort((a: any, b: any) => {
        if (!a.event_date) return 1;
        if (!b.event_date) return -1;
        return a.event_date.localeCompare(b.event_date);
      });

      setReservations(all);
    } catch (e: any) {
      console.log('[MemberEvents] Error:', e.message);
    } finally {
      setLoading(false);
      setRefreshing(false);
    }
  };

  const onRefresh = () => {
    setRefreshing(true);
    fetchEvents();
  };

  // Derived arrays — before early returns (Rules of Hooks), memoized so
  // filters run once per reservations change. nowMs computed once per pass.
  const { liveEvents, completedEvts, upcoming, historyEvts } = useMemo(() => {
    const nowMs     = snapshotNow();
    const activeSet = new Set(['accepted', 'confirmed', 'pending', 'pending_group_confirmation']);
    return {
      liveEvents:    reservations.filter(r => r.status === 'in_progress'),
      completedEvts: reservations.filter(r => r.status === 'completed'),
      upcoming:      reservations.filter(r => activeSet.has(r.status) && isUpcoming(r.event_date, r.event_time, nowMs)),
      historyEvts:   reservations.filter(r => activeSet.has(r.status) && !isUpcoming(r.event_date, r.event_time, nowMs)),
    };
  }, [reservations]);

  if (loading) {
    return (
      <View style={styles.container}>
        <Particles />
        <View style={styles.center}>
          <ActivityIndicator size="large" color={COLORS.green} />
        </View>
      </View>
    );
  }

  if (noGroup) {
    return (
      <View style={styles.container}>
        <Particles />
        <SafeAreaView style={{ flex: 1 }}>
          <View style={styles.header}>
            <Text style={styles.title}>Eventos del grupo</Text>
          </View>
          <View style={styles.center}>
            <Text style={styles.emptyIcon}>🎸</Text>
            <Text style={styles.emptyTitle}>Sin grupo asignado</Text>
            <Text style={styles.emptyText}>
              Cuando un grupo te invite y aceptes, verás sus eventos aquí.
            </Text>
          </View>
        </SafeAreaView>
      </View>
    );
  }

  return (
    <View style={styles.container}>
      <Particles />
      <SafeAreaView style={{ flex: 1 }}>
        <View style={styles.header}>
          <View style={{ flex: 1 }}>
            <Text style={styles.title}>Eventos</Text>
            {groupName && <Text style={styles.subtitle}>{groupName}</Text>}
          </View>
          <Pressable style={styles.statsBtn} onPress={() => navigation.navigate('TalentStats')}>
            <BarChart2 size={18} color={COLORS.green} />
          </Pressable>
          <Pressable style={styles.statsBtn} onPress={() => navigation.navigate('Notifications')}>
            <Bell size={18} color={COLORS.muted2} />
            {unreadCount > 0 && (
              <View style={styles.badgeDot}>
                <Text style={styles.badgeDotText}>{unreadCount > 9 ? '9+' : unreadCount}</Text>
              </View>
            )}
          </Pressable>
        </View>

        {/* ── Tabs ── */}
        <View style={styles.tabs}>
          <Pressable
            style={[styles.tab, activeTab === 'proximos' && styles.tabActive]}
            onPress={() => setActiveTab('proximos')}
          >
            <Text style={[styles.tabText, activeTab === 'proximos' && styles.tabTextActive]}>
              Próximos eventos
            </Text>
          </Pressable>
          <Pressable
            style={[styles.tab, activeTab === 'pendientes' && styles.tabActive]}
            onPress={() => setActiveTab('pendientes')}
          >
            <Text style={[styles.tabText, activeTab === 'pendientes' && styles.tabTextActive]}>
              Pendientes{pendingQuotesList.length > 0 ? ` ${pendingQuotesList.length}` : ''}
            </Text>
          </Pressable>
        </View>

        <ScrollView
          showsVerticalScrollIndicator={false}
          contentContainerStyle={styles.list}
          refreshControl={<RefreshControl refreshing={refreshing} onRefresh={onRefresh} tintColor={COLORS.green} />}
        >
          {/* ── Nota de pagos externos ── */}
          <View style={styles.paymentNote}>
            <Text style={styles.paymentNoteText}>
              💡 Los pagos de cada evento los acuerdas y recibes directamente con el dueño del grupo, fuera de la plataforma.
            </Text>
          </View>

          {/* ── Tab: Próximos eventos ── */}
          {activeTab === 'proximos' && (
            reservations.length === 0 ? (
              <View style={styles.emptyState}>
                <Text style={styles.emptyIcon}>📅</Text>
                <Text style={styles.emptyTitle}>Sin eventos todavía</Text>
                <Text style={styles.emptyText}>Los eventos confirmados de tu grupo aparecerán aquí</Text>
              </View>
            ) : (
              <>
                {/* En curso */}
                {liveEvents.length > 0 && (
                  <>
                    <Text style={[styles.sectionTitle, { color: '#EF5350' }]}>🔴 En curso · {liveEvents.length}</Text>
                    {liveEvents.map(r => (
                      <EventCard key={r.id} reservation={r} navigation={navigation} />
                    ))}
                  </>
                )}
                {/* Próximos */}
                {upcoming.length > 0 && (
                  <>
                    <Text style={[styles.sectionTitle, { marginTop: liveEvents.length > 0 ? 20 : 0 }]}>
                      Próximos · {upcoming.length}
                    </Text>
                    <CalendarStrip events={upcoming} />
                    {upcoming.map(r => (
                      <EventCard key={r.id} reservation={r} navigation={navigation} />
                    ))}
                  </>
                )}
                {/* Historial */}
                {historyEvts.length > 0 && (
                  <>
                    <Text style={[styles.sectionTitle, { marginTop: 20 }]}>Historial · {historyEvts.length}</Text>
                    {historyEvts.map(r => (
                      <EventCard key={r.id} reservation={r} navigation={navigation} isPast />
                    ))}
                  </>
                )}
                {/* Finalizados */}
                {completedEvts.length > 0 && (
                  <>
                    <Text style={[styles.sectionTitle, { marginTop: 20, color: COLORS.green }]}>
                      ✅ Finalizados · {completedEvts.length}
                    </Text>
                    {completedEvts.map(r => (
                      <EventCard key={r.id} reservation={r} navigation={navigation} />
                    ))}
                  </>
                )}
              </>
            )
          )}

          {/* ── Tab: Pendientes ── */}
          {activeTab === 'pendientes' && (
            pendingQuotesList.length === 0 ? (
              <View style={styles.emptyState}>
                <Text style={styles.emptyIcon}>📋</Text>
                <Text style={styles.emptyTitle}>Sin solicitudes pendientes</Text>
                <Text style={styles.emptyText}>Las cotizaciones nuevas de clientes aparecerán aquí</Text>
              </View>
            ) : (
              <>
                <Text style={styles.sectionTitle}>Solicitudes · {pendingQuotesList.length}</Text>
                {pendingQuotesList.map((q: any) => (
                  <PendingQuoteCard key={q.id} quote={q} navigation={navigation} />
                ))}
              </>
            )
          )}
        </ScrollView>
      </SafeAreaView>
    </View>
  );
}

function fmtTime(t: string | null | undefined): string {
  if (!t) return '';
  const [hStr, mStr] = t.substring(0, 5).split(':');
  const h = parseInt(hStr, 10);
  const h12 = h % 12 || 12;
  return `${h12}:${mStr} ${h >= 12 ? 'PM' : 'AM'}`;
}

function useCountdown(eventDate: string | null, eventTime: string | null) {
  const [countdown, setCountdown] = useState('');
  useEffect(() => {
    if (!eventDate) return;
    const tick = () => {
      const timeStr = (eventTime ?? '00:00').substring(0, 5);
      const target = new Date(`${eventDate}T${timeStr}:00`);
      const diff = target.getTime() - Date.now();
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

function EventCard({ reservation: r, navigation, isPast }: any) {
  const s       = STATUS_MAP[r.status] ?? STATUS_MAP.pending;
  const parts   = r.event_date?.split('-') ?? [];
  const day     = parts[2] ?? '—';
  const monthIdx = parts[1] ? parseInt(parts[1], 10) - 1 : -1;
  const month   = monthIdx >= 0 ? MONTH_SHORT[monthIdx] : '—';

  const isPaid = r.payment_status === 'paid' || r.payment_status === 'deposit_paid' || r.payment_status === 'fully_paid';
  const isLive = r.status === 'in_progress';
  const isAccepted = r.status === 'accepted' || r.status === 'in_progress' || r.status === 'confirmed' || r.status === 'completed';
  const showCountdown = isPaid && !isLive;
  const countdown = useCountdown(showCountdown ? r.event_date : null, r.event_time);
  const isExpress = !!r.event_request_id;

  const handlePress = async () => {
    if (r._isQuote) {
      if (isAccepted) {
        // Buscar la reserva real por quote_id para navegar al temporizador
        const { data: res } = await supabase
          .from('reservations')
          .select('id,client_id,group_id,event_date,event_time,address,status,payment_status,total_price,quote_id,event_started_at,break_type,group_arrived_at,notes,hours_count,event_request_id')
          .eq('quote_id', r._quoteData.id)
          .maybeSingle();
        if (res) {
          navigation.navigate('EventTimer', { reservation: { ...res, quote: r._quoteData }, readOnly: true, userRole: 'talent' });
        } else {
          // Fallback con datos de la cotización
          navigation.navigate('EventTimer', {
            reservation: {
              id: r._quoteData.id,
              event_date: r.event_date,
              event_time: r.event_time,
              address: r.address,
              status: r.status,
              total_price: r._quoteData.total_amount,
              quote_id: r._quoteData.id,
              event_started_at: null,
              break_type: null,
              group_arrived_at: null,
              quote: r._quoteData,
              payment_status: 'paid',
            },
            readOnly: true,
            userRole: 'talent',
          });
        }
      } else {
        navigation.navigate('GroupQuoteDetail', { quote: r._quoteData });
      }
    } else if (isPaid || isLive || r.status === 'completed') {
      navigation.navigate('EventTimer', { reservation: r, readOnly: true, userRole: 'talent' });
    } else {
      navigation.navigate('GroupReservationDetail', { reservation: r });
    }
  };

  return (
    <Pressable
      style={[styles.card, r._isQuote && styles.cardQuote, isLive && styles.cardLive, isPast && { opacity: 0.5 }]}
      onPress={handlePress}
    >
      {/* Fecha */}
      <View style={[styles.dateBubble, { backgroundColor: `${s.color}18`, borderColor: `${s.color}40` }]}>
        <Text style={[styles.dateDay, { color: s.color }]}>{day}</Text>
        <Text style={[styles.dateMon, { color: s.color }]}>{month}</Text>
      </View>

      {/* Contenido */}
      <View style={styles.cardBody}>
        <View style={styles.cardTop}>
          <Text style={styles.clientName} numberOfLines={1}>
            {r.client?.full_name ?? 'Cliente'}
          </Text>
          <View style={{ alignItems: 'flex-end', gap: 4 }}>
            <Badge label={s.label} variant={s.variant} dot />
            {isExpress && (
              <View style={styles.expressBadge}>
                <Text style={styles.expressBadgeText}>⚡ Express</Text>
              </View>
            )}
          </View>
        </View>
        <Text style={styles.pkgName} numberOfLines={1}>
          {isExpress ? 'Solicitud express' : '—'}
          {r.hours_count ? ` · ${r.hours_count}h` : ''}
        </Text>
        <View style={styles.metaRow}>
          {r.event_time && (
            <View style={styles.metaItem}>
              <Clock size={11} color={COLORS.muted} />
              <Text style={styles.metaText}>{fmtTime(r.event_time)}</Text>
            </View>
          )}
          {r.address && (
            <View style={styles.metaItem}>
              <MapPin size={11} color={COLORS.muted} />
              <Text style={styles.metaText} numberOfLines={1}>{r.address}</Text>
            </View>
          )}
        </View>
        {isLive && (
          <View style={styles.liveBtn}>
            <PlayCircle size={14} color={COLORS.green} />
            <Text style={styles.liveBtnText}>🔴 Evento en curso — Ver en vivo</Text>
          </View>
        )}
        {showCountdown && countdown ? (
          <View style={styles.countdownRow}>
            <Clock size={11} color={COLORS.green} />
            <Text style={styles.countdownText}>Inicia en: {countdown}</Text>
          </View>
        ) : null}
        {isPaid && r.address ? (
          <Pressable
            style={styles.navBtn}
            onPress={() => Linking.openURL(
              `https://www.google.com/maps/dir/?api=1&destination=${encodeURIComponent(r.address)}`
            )}
          >
            <Navigation size={11} color={COLORS.green} />
            <Text style={styles.navBtnText} numberOfLines={1}>{r.address}</Text>
            <ExternalLink size={10} color={COLORS.green} />
          </Pressable>
        ) : null}
      </View>

      <ChevronRight size={16} color={COLORS.muted} />
    </Pressable>
  );
}

function PendingQuoteCard({ quote: q, navigation }: any) {
  const isQuoted = q.status === 'quoted';
  const color    = isQuoted ? COLORS.blue : COLORS.orange;
  const label    = isQuoted ? 'Cotización enviada' : 'Esperando respuesta';
  const parts    = q.event_date?.split('-') ?? [];
  const day      = parts[2] ?? '—';
  const monthIdx = parts[1] ? parseInt(parts[1], 10) - 1 : -1;
  const month    = monthIdx >= 0 ? MONTH_SHORT[monthIdx] : '—';

  return (
    <Pressable
      style={[styles.card, styles.cardQuote]}
      onPress={() => navigation.navigate('GroupQuoteDetail', { quote: q })}
    >
      <View style={[styles.dateBubble, { backgroundColor: `${color}18`, borderColor: `${color}40` }]}>
        <Text style={[styles.dateDay, { color }]}>{day}</Text>
        <Text style={[styles.dateMon, { color }]}>{month}</Text>
      </View>
      <View style={styles.cardBody}>
        <View style={styles.cardTop}>
          <Text style={styles.clientName} numberOfLines={1}>
            {q.client?.full_name ?? 'Cliente'}
          </Text>
          <View style={{ paddingHorizontal: 8, paddingVertical: 3, borderRadius: 20, borderWidth: 1, backgroundColor: `${color}18`, borderColor: `${color}40` }}>
            <Text style={{ fontFamily: FONTS.bodyMedium, fontSize: 11, color }}>{label}</Text>
          </View>
        </View>
        <Text style={styles.pkgName}>{q.event_type ?? 'Evento'} · {q.duration_hours}h</Text>
        <View style={styles.metaRow}>
          {q.event_time && (
            <View style={styles.metaItem}>
              <Clock size={11} color={COLORS.muted} />
              <Text style={styles.metaText}>{fmtTime(q.event_time)}</Text>
            </View>
          )}
          {q.event_municipio && (
            <View style={styles.metaItem}>
              <MapPin size={11} color={COLORS.muted} />
              <Text style={styles.metaText} numberOfLines={1}>{q.event_municipio}, {q.event_estado}</Text>
            </View>
          )}
        </View>
        {isQuoted && q.total_amount && (
          <Text style={{ fontFamily: FONTS.bodySemiBold, fontSize: 12, color: COLORS.green, marginTop: 2 }}>
            ${q.total_amount?.toLocaleString()} MXN cotizados
          </Text>
        )}
      </View>
      <ChevronRight size={16} color={COLORS.muted} />
    </Pressable>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: COLORS.bg },
  center:    { flex: 1, alignItems: 'center', justifyContent: 'center', gap: 12, padding: 40 },

  header: {
    flexDirection: 'row',
    alignItems: 'center',
    paddingHorizontal: SPACING.xl,
    paddingTop: 16,
    paddingBottom: 14,
  },
  statsBtn: {
    width: 38, height: 38, borderRadius: 19,
    backgroundColor: 'rgba(0,230,118,0.1)',
    alignItems: 'center', justifyContent: 'center',
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.2)',
  },
  badgeDot: {
    position: 'absolute', top: -2, right: -2,
    minWidth: 16, height: 16, borderRadius: 8,
    backgroundColor: COLORS.green,
    alignItems: 'center', justifyContent: 'center',
    paddingHorizontal: 3,
  },
  badgeDotText: { fontFamily: FONTS.bodySemiBold, fontSize: 9, color: COLORS.bg },
  title:    { fontFamily: FONTS.title, fontSize: 24, color: COLORS.text },
  subtitle: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.green, marginTop: 2 },

  list: { padding: SPACING.xl, gap: 10, paddingBottom: 40 },

  sectionTitle: {
    fontFamily: FONTS.bodySemiBold,
    fontSize: 13,
    color: COLORS.muted2,
    marginBottom: 8,
    letterSpacing: 0.5,
    textTransform: 'uppercase',
  },

  card: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 14,
    backgroundColor: COLORS.card,
    borderRadius: 20,
    borderWidth: 1,
    borderColor: '#1c1c1c',
    padding: 14,
  },
  cardQuote: {
    borderColor: `${COLORS.green}30`,
    backgroundColor: 'rgba(0,230,118,0.03)',
  },
  dateBubble: {
    width: 52, height: 60,
    borderRadius: 14,
    borderWidth: 1,
    alignItems: 'center', justifyContent: 'center',
    flexShrink: 0,
  },
  dateDay: { fontFamily: FONTS.title, fontSize: 20, lineHeight: 24 },
  dateMon: { fontFamily: FONTS.bodyMedium, fontSize: 10, letterSpacing: 1 },

  cardBody: { flex: 1, gap: 5 },
  cardTop: {
    flexDirection: 'row', alignItems: 'flex-start',
    justifyContent: 'space-between', gap: 8,
  },
  clientName: { fontFamily: FONTS.title, fontSize: 16, color: COLORS.text, flex: 1 },
  pkgName:    { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted },
  metaRow:    { flexDirection: 'row', gap: 6, flexWrap: 'wrap', marginTop: 2 },
  metaItem:   {
    flexDirection: 'row', alignItems: 'center', gap: 4,
    backgroundColor: '#151515', borderRadius: 8,
    paddingHorizontal: 7, paddingVertical: 4,
  },
  metaText:   { fontFamily: FONTS.bodyMedium, fontSize: 11, color: COLORS.muted2 },

  emptyState: { alignItems: 'center', paddingTop: 80, gap: 8 },
  emptyIcon:  { fontSize: 48 },
  emptyTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 18, color: COLORS.text },
  emptyText:  { fontFamily: FONTS.body, fontSize: 14, color: COLORS.muted2, textAlign: 'center', lineHeight: 20 },

  cardLive: {
    borderColor: `${COLORS.green}60`,
    backgroundColor: 'rgba(0,230,118,0.05)',
  },
  liveBtn: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 6,
    marginTop: 10, backgroundColor: 'rgba(0,230,118,0.10)',
    borderTopWidth: 1, borderTopColor: 'rgba(0,230,118,0.25)',
    paddingVertical: 10, paddingHorizontal: 14,
    marginHorizontal: -14, marginBottom: -14,
    borderBottomLeftRadius: RADIUS.lg, borderBottomRightRadius: RADIUS.lg,
  },
  liveBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.green },
  countdownRow: { flexDirection: 'row', alignItems: 'center', gap: 4, marginTop: 4 },
  countdownText: { fontFamily: FONTS.bodyMedium, fontSize: 11, color: COLORS.green },

  expressBadge: {
    backgroundColor: 'rgba(255,179,0,0.15)', borderRadius: 20,
    paddingHorizontal: 7, paddingVertical: 3,
    borderWidth: 1, borderColor: 'rgba(255,179,0,0.40)',
  },
  expressBadgeText: { fontFamily: FONTS.bodyMedium, fontSize: 10, color: '#FFB300' },
  navBtn: {
    flexDirection: 'row' as const, alignItems: 'center' as const, gap: 5,
    backgroundColor: 'rgba(0,230,118,0.08)', borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.3)',
    paddingHorizontal: 8, paddingVertical: 5, marginTop: 4,
  },
  navBtnText: { fontFamily: FONTS.bodyMedium, fontSize: 11, color: COLORS.green, flex: 1 },
  // ── Tabs ──────────────────────────────────────────────────
  tabs: {
    flexDirection: 'row',
    marginHorizontal: SPACING.xl, marginBottom: 12,
    backgroundColor: COLORS.card,
    borderRadius: RADIUS.lg, borderWidth: 1, borderColor: COLORS.border,
    padding: 4,
  },
  tab:           { flex: 1, paddingVertical: 9, alignItems: 'center', borderRadius: RADIUS.md },
  tabActive:     { backgroundColor: COLORS.green },
  tabText:       { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted2 },
  tabTextActive: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.bg },

  // ── Calendar strip ────────────────────────────────────────
  calDay: {
    width: 44, alignItems: 'center' as const, paddingVertical: 8, borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: 'transparent',
  },
  calDayToday: {
    borderColor: `${COLORS.green}50`,
    backgroundColor: `${COLORS.green}0A`,
  },
  calDayEvent: {
    borderColor: COLORS.green,
    backgroundColor: `${COLORS.green}15`,
  },
  calDayName: { fontFamily: FONTS.body, fontSize: 10, color: COLORS.muted, marginBottom: 4 },
  calDayNum:  { fontFamily: FONTS.bodyMedium, fontSize: 16, color: COLORS.muted2 },
  calDot: {
    width: 5, height: 5, borderRadius: 3,
    backgroundColor: COLORS.green, marginTop: 4,
  },

  // Nota de pagos externos
  paymentNote: {
    marginHorizontal: 0, marginBottom: 14,
    backgroundColor: 'rgba(0,230,118,0.06)', borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.2)',
    paddingHorizontal: SPACING.lg, paddingVertical: 10,
  },
  paymentNoteText: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, lineHeight: 17 },
});
