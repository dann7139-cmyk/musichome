import { Calendar as CalendarIcon, Clock, CreditCard, FileText, Share2, Star, Trash2, X } from 'lucide-react-native';
import { Calendar } from 'react-native-calendars';
import React, { useCallback, useEffect, useRef, useState } from 'react';
import { useFocusEffect } from '@react-navigation/native';
import {
  Animated,
  ActivityIndicator,
  Alert,
  Image,
  Modal,
  Pressable,
  RefreshControl,
  ScrollView,
  Share,
  StyleSheet,
  Text,
  TextInput,
  View,
} from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { useTranslation } from 'react-i18next';
import { supabase } from '../../config/supabase';
import { isPaid, parseEventDateMX } from '../../utils/calculations';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';
import Badge from '../../components/ui/Badge';

const STATUS_MAP: Record<string, { label: string; variant: any }> = {
  pending:                    { label: 'Pendiente',        variant: 'orange' },
  pending_payment:            { label: '⚡ Pagar ahora',    variant: 'orange' },
  pending_group_confirmation: { label: 'Por confirmar',    variant: 'orange' },
  accepted:                   { label: '✅ Aceptada',       variant: 'green' },
  confirmed:                  { label: 'Confirmada',       variant: 'green' },
  in_progress:                { label: 'En curso',         variant: 'blue' },
  completed:                  { label: 'Completada',       variant: 'muted' },
  cancelled:                  { label: 'Cancelada',        variant: 'red' },
  rejected:                   { label: 'Rechazada',        variant: 'red' },
};

const QUOTE_STATUS_CFG: Record<string, { label: string; color: string }> = {
  pending:  { label: 'Esperando respuesta', color: COLORS.orange },
  quoted:   { label: 'Cotización recibida', color: COLORS.blue   },
  accepted: { label: 'Aceptada',            color: COLORS.green  },
  rejected: { label: 'Cancelada',           color: COLORS.red    },
  expired:  { label: 'Expirada',            color: COLORS.muted  },
};

export default function ClientReservationsScreen({ navigation, route }: any) {
  const { t } = useTranslation();
  const [reservations,     setReservations]     = useState<any[]>([]);
  const [quotes,           setQuotes]           = useState<any[]>([]);
  const [expressRequests,  setExpressRequests]  = useState<any[]>([]);
  const initialTab = route?.params?.initialTab === 'pendientes' ? 'pendientes' : 'eventos';
  const [activeTab,        setActiveTab]        = useState<'eventos' | 'pendientes'>(initialTab);
  // ID de reserva recién pagada — mientras el webhook confirma, mostramos "Verificando..."
  const justPaidId = route?.params?.justPaidReservationId ?? null;
  const [refreshing,       setRefreshing]       = useState(false);
  const [resPage,          setResPage]          = useState(0);
  const [resHasMore,       setResHasMore]       = useState(true);
  const RES_PAGE_SIZE = 50;
  const [reviewedIds,      setReviewedIds]      = useState<Set<string>>(new Set());

  // useFocusEffect ya dispara en el mount inicial — no necesitamos useEffect separado
  useFocusEffect(useCallback(() => { fetchAll(0); }, []));

  // Realtime: actualizar estado de reserva sin necesidad de salir/entrar
  useEffect(() => {
    let cancelled = false;
    let sub: ReturnType<typeof supabase.channel> | null = null;
    supabase.auth.getSession().then(({ data }) => {
      if (cancelled) return;
      const uid = data.session?.user.id;
      if (!uid) return;
      sub = supabase
        .channel(`client-reservations-status-${uid}`)
        .on('postgres_changes', {
          event: 'UPDATE',
          schema: 'public',
          table: 'reservations',
          filter: `client_id=eq.${uid}`,
        }, (payload: any) => {
          const upd = payload.new;
          setReservations(prev =>
            prev.map(r => r.id === upd.id ? { ...r, ...upd } : r)
          );
        })
        .subscribe();
    });
    return () => { cancelled = true; if (sub) supabase.removeChannel(sub); };
  }, []);

  const fetchAll = async (pageNum: number = 0) => {
    const { data: sessionData } = await supabase.auth.getSession();
    if (!sessionData.session) return;
    const uid = sessionData.session.user.id;
    const from = pageNum * RES_PAGE_SIZE;
    const to   = from + RES_PAGE_SIZE - 1;

    const [resData, quoteData, exprData] = await Promise.all([
      supabase
        .from('reservations')
        .select('*, group:groups(id, name, genre, city, profile_image, owner_id), quote:quotes(duration_hours, overtime_1h_price, overtime_2h_price, overtime_3h_price, event_type), event_request_id, hours_count')
        .eq('client_id', uid)
        .order('created_at', { ascending: false })
        .range(from, to),
      supabase
        .from('quotes')
        .select('*, group:groups(id, name)')
        .eq('client_id', uid)
        .order('created_at', { ascending: false }),
      supabase
        .from('event_requests')
        .select('*')
        .eq('client_id', uid)
        .in('status', ['open', 'en_negociacion'])
        .order('created_at', { ascending: false }),
    ]);

    if (resData.data) {
      setResHasMore(resData.data.length === RES_PAGE_SIZE);
      if (pageNum === 0) {
        setReservations(resData.data);
      } else {
        setReservations(prev => [...prev, ...resData.data!]);
      }
      setResPage(pageNum);
      // IDs de reservas completadas que ya tienen reseña
      const completedIds = resData.data
        .filter((r: any) => r.status === 'completed')
        .map((r: any) => r.id);
      if (completedIds.length > 0) {
        const { data: revData } = await supabase
          .from('reviews')
          .select('reservation_id')
          .in('reservation_id', completedIds);
        setReviewedIds(new Set((revData ?? []).map((rv: any) => rv.reservation_id)));
      }
    }

    if (quoteData.data) {
      const acceptedIds = quoteData.data
        .filter(q => q.status === 'accepted')
        .map(q => q.id);

      let reservationByQuote: Record<string, any> = {};
      if (acceptedIds.length > 0) {
        const { data: linkedRes } = await supabase
          .from('reservations')
          .select('id,quote_id,folio,event_date,event_time,address,status,payment_status,total_price,event_started_at,break_type,group_id,client_id,notes,platform_commission,group_earnings')
          .in('quote_id', acceptedIds);
        linkedRes?.forEach(r => {
          if (r.quote_id) reservationByQuote[r.quote_id] = r;
        });
      }

      setQuotes(quoteData.data.map(q => ({
        ...q,
        _reservation: reservationByQuote[q.id] ?? null,
      })));
    }

    // Cargar info del grupo que propuso (para solicitudes en negociación)
    const exprReqs = exprData.data ?? [];
    const negOwnerIds = exprReqs
      .filter((r: any) => r.status === 'en_negociacion' && r.negotiating_group_id)
      .map((r: any) => r.negotiating_group_id);

    let exprGroupMap: Record<string, any> = {};
    if (negOwnerIds.length > 0) {
      const { data: exprGroups } = await supabase
        .from('groups')
        .select('id, owner_id, name, profile_image')
        .in('owner_id', negOwnerIds);
      exprGroupMap = Object.fromEntries(
        (exprGroups ?? []).map((g: any) => [g.owner_id, g])
      );
    }

    setExpressRequests(exprReqs.map((r: any) => ({
      ...r,
      _group: r.negotiating_group_id ? (exprGroupMap[r.negotiating_group_id] ?? null) : null,
    })));
  };

  const loadMoreReservations = () => {
    if (resHasMore) fetchAll(resPage + 1);
  };

  const onRefresh = async () => {
    setRefreshing(true);
    await fetchAll(0);
    setRefreshing(false);
  };

  const handleDeleteQuote = (q: any) => {
    Alert.alert(
      'Eliminar solicitud',
      '¿Quieres eliminar esta solicitud? El grupo ya no la verá.',
      [
        { text: 'No', style: 'cancel' },
        {
          text: 'Sí, eliminar',
          style: 'destructive',
          onPress: async () => {
            // 1. Notificar al grupo
            if (q.group?.id) {
              const { data: grpData } = await supabase
                .from('groups')
                .select('owner_id')
                .eq('id', q.group.id)
                .single();

              if (grpData?.owner_id) {
                const notifs: any[] = [{
                  user_id: grpData.owner_id,
                  type: 'quote_cancelled',
                  title: 'Solicitud eliminada',
                  body: 'Un cliente eliminó su solicitud de cotización.',
                  data: { group_id: q.group.id },
                }];

                const [{ data: members }, { data: jobs }] = await Promise.all([
                  supabase.from('job_invitations').select('invited_user_id')
                    .eq('group_id', q.group.id).eq('invitation_type', 'membership').eq('status', 'accepted'),
                  supabase.from('job_invitations').select('invited_user_id')
                    .eq('group_id', q.group.id).eq('invitation_type', 'job').eq('status', 'accepted'),
                ]);

                [...(members ?? []), ...(jobs ?? [])].forEach((m: any) =>
                  notifs.push({
                    user_id: m.invited_user_id,
                    type: 'quote_cancelled',
                    title: 'Solicitud eliminada',
                    body: 'Un cliente eliminó su solicitud de cotización.',
                    data: { group_id: q.group.id },
                  })
                );

                await supabase.from('notifications').insert(notifs);
              }
            }

            // 2. Eliminar cotización
            await supabase.from('quotes').delete().eq('id', q.id);

            // 3. Refrescar
            await fetchAll(0);

            // 4. Ofrecer volver a cotizar
            Alert.alert(
              'Solicitud eliminada',
              '¿Quieres volver a cotizar con este grupo?',
              [
                { text: 'No, gracias', style: 'cancel' },
                {
                  text: 'Volver a cotizar',
                  onPress: () => navigation.navigate('QuoteForm', { group: q.group }),
                },
              ]
            );
          },
        },
      ]
    );
  };

  const today         = new Date().toISOString().slice(0, 10); // 'YYYY-MM-DD'
  const pendingQuotes  = quotes.filter(q =>
    (q.status === 'pending' || q.status === 'quoted') && q.event_date >= today
  );
  const pendingCount   = pendingQuotes.length + expressRequests.length;

  // Badge en el ícono del menú inferior
  useEffect(() => {
    navigation.setOptions({
      tabBarBadge: pendingCount > 0 ? pendingCount : undefined,
    });
  }, [pendingCount]);

  // "Eventos" tab: reservas reales + cotizaciones aceptadas (con o sin reserva vinculada)
  const reservationIds = new Set(reservations.map(r => r.id));
  const acceptedQuoteItems = quotes
    .filter(q => q.status === 'accepted')
    .map(q => {
      // Si ya tiene reserva vinculada, usarla; si no, construir desde cotización
      if (q._reservation && reservationIds.has(q._reservation.id)) return null;
      if (q._reservation) return q._reservation;
      // Sin reserva: representar la cotización como evento
      return {
        id:             `quote-${q.id}`,
        _isQuote:       true,
        _quoteData:     q,
        event_date:     q.event_date,
        event_time:     q.event_time ?? null,
        status:         'accepted',
        payment_status: null,
        total_price:    q.total_amount,
        group:          q.group,
        address:        [q.event_address, q.event_municipio, q.event_estado].filter(Boolean).join(', ') || '',
        created_at:     q.created_at,
      };
    })
    .filter(Boolean);

  const eventItems = [...reservations, ...acceptedQuoteItems]
    .filter(r => r && !['cancelled', 'rejected', 'expired'].includes(r.status ?? ''))
    .filter((r, i, arr) => r && arr.findIndex(x => x?.id === r.id) === i)
    .sort((a, b) => (b.created_at ?? '').localeCompare(a.created_at ?? ''));

  return (
    <View style={styles.container}>
      <SafeAreaView style={{ flex: 1 }}>
        <View style={styles.header}>
          <Text style={styles.title}>{t('reservations.title')}</Text>
        </View>

        {/* ── Tabs ──────────────────────────────────────────────── */}
        <View style={styles.tabs}>
          <Pressable
            style={[styles.tab, activeTab === 'eventos' && styles.tabActive]}
            onPress={() => setActiveTab('eventos')}
          >
            <Text style={[styles.tabText, activeTab === 'eventos' && styles.tabTextActive]}>
              {t('reservations.tab_events')}
            </Text>
          </Pressable>
          <Pressable
            style={[styles.tab, activeTab === 'pendientes' && styles.tabActive]}
            onPress={() => setActiveTab('pendientes')}
          >
            <View style={{ flexDirection: 'row', alignItems: 'center', gap: 6 }}>
              <Text style={[styles.tabText, activeTab === 'pendientes' && styles.tabTextActive]}>
                {t('reservations.tab_pending')}
              </Text>
              {pendingCount > 0 && (
                <View style={[styles.tabBadgePill, activeTab === 'pendientes' && styles.tabBadgePillActive]}>
                  <Text style={[styles.tabBadgePillText, activeTab === 'pendientes' && styles.tabBadgePillTextActive]}>{pendingCount}</Text>
                </View>
              )}
            </View>
          </Pressable>
        </View>

        <ScrollView
          showsVerticalScrollIndicator={false}
          contentContainerStyle={styles.list}
          refreshControl={<RefreshControl refreshing={refreshing} onRefresh={onRefresh} tintColor={COLORS.green} />}
        >
          {/* ── Tab: Eventos ────────────────────────────────────── */}
          {activeTab === 'eventos' && (
            eventItems.length === 0 ? (
              <View style={styles.empty}>
                <Text style={styles.emptyIcon}>🎵</Text>
                <Text style={styles.emptyTitle}>{t('reservations.tab_events')}</Text>
                <Text style={styles.emptyText}>{t('reservations.empty_events')}</Text>
              </View>
            ) : (
              <>
                {eventItems.map((r) => (
                  <ReservationCard
                    key={r.id}
                    reservation={r}
                    navigation={navigation}
                    onUpdate={() => fetchAll(0)}
                    isReviewed={reviewedIds.has(r.id)}
                    isJustPaid={justPaidId === r.id}
                    onRate={(reservationId: string) => {
                      const res = reservations.find(r => r.id === reservationId);
                      if (res) {
                        navigation.navigate('EventTimer' as any, { reservation: res, readOnly: true, userRole: 'client' });
                      }
                    }}
                  />
                ))}
                {resHasMore && (
                  <Pressable style={styles.loadMoreBtn} onPress={loadMoreReservations}>
                    <Text style={styles.loadMoreText}>{t('reservations.load_more')}</Text>
                  </Pressable>
                )}
              </>
            )
          )}

          {/* ── Tab: Pendientes ────────────────────────────────── */}
          {activeTab === 'pendientes' && (() => {
            const visibleQuotes = quotes.filter(q => q.status === 'pending' || q.status === 'quoted');
            const hasAny = visibleQuotes.length > 0 || expressRequests.length > 0;
            return !hasAny ? (
              <View style={styles.empty}>
                <Text style={styles.emptyIcon}>📋</Text>
                <Text style={styles.emptyTitle}>{t('reservations.empty_pending')}</Text>
                <Text style={styles.emptyText}>{t('reservations.empty_pending_sub')}</Text>
              </View>
            ) : (
              <>
                {/* ── Solicitudes express ── */}
                {expressRequests.map((req: any) => {
                  const hasProposal = req.status === 'en_negociacion';
                  const proposal    = req.proposal_data ?? {};
                  const expiresAt   = req.expires_at ? new Date(req.expires_at) : null;
                  const isExpired   = expiresAt ? expiresAt.getTime() < Date.now() : false;
                  const timeLeft    = expiresAt && !isExpired
                    ? (() => {
                        const diff = expiresAt.getTime() - Date.now();
                        const m = Math.floor(diff / 60_000);
                        const s = Math.floor((diff % 60_000) / 1_000);
                        return m > 0 ? `${m}m ${s}s` : `${s}s`;
                      })()
                    : null;
                  return (
                    <Pressable
                      key={req.id}
                      style={[styles.quoteCard, hasProposal && { borderColor: COLORS.green + '50' }]}
                      onPress={() => navigation.navigate('OpenRequest', { tab: 'mine' })}
                    >
                      <View style={styles.quoteTop}>
                        <View style={[styles.quotePill, hasProposal
                          ? { borderColor: COLORS.green + '60', backgroundColor: COLORS.green + '18' }
                          : { borderColor: COLORS.orange + '60', backgroundColor: COLORS.orange + '18' }
                        ]}>
                          <Text style={{ fontSize: 11 }}>⚡</Text>
                          <Text style={[styles.quotePillText, { color: hasProposal ? COLORS.green : COLORS.orange }]}>
                            {hasProposal ? t('reservations.proposal_received') : t('reservations.searching_group')}
                          </Text>
                        </View>
                        {timeLeft && (
                          <Text style={[styles.quoteDate, { color: COLORS.orange }]}>⏱ {timeLeft}</Text>
                        )}
                      </View>
                      <Text style={styles.quoteGroup}>
                        {hasProposal && req._group ? req._group.name : `${req.genre} · ${req.hours}h`}
                      </Text>
                      <View style={styles.quoteInfo}>
                        {req.event_date && (
                          <Text style={styles.quoteInfoText}>
                            📅 {new Date(req.event_date + 'T12:00:00').toLocaleDateString('es-MX', { day: 'numeric', month: 'short' })}
                          </Text>
                        )}
                        <Text style={styles.quoteInfoText}>⏱ {req.hours}h</Text>
                      </View>
                      {hasProposal && proposal.total_amount != null && (
                        <View style={styles.quotePriceRow}>
                          <Text style={styles.quotePriceLabel}>{t('reservations.proposed_total')}</Text>
                          <Text style={[styles.quotePriceVal, { color: COLORS.green }]}>
                            ${Number(proposal.total_amount).toLocaleString()} MXN
                          </Text>
                        </View>
                      )}
                      {hasProposal && proposal.arrival_time && (
                        <Text style={[styles.quoteInfoText, { marginBottom: 6, color: '#FFD54F' }]}>
                          {t('reservations.arrives_at', { time: proposal.arrival_time })}
                        </Text>
                      )}
                      <Text style={styles.quoteCta}>
                        {hasProposal ? 'Ver y responder →' : 'Ver solicitud →'}
                      </Text>
                    </Pressable>
                  );
                })}

                {/* ── Cotizaciones pendientes ── */}
                {visibleQuotes.map((q) => {
                  const cfg = QUOTE_STATUS_CFG[q.status] ?? QUOTE_STATUS_CFG.pending;
                  const eventDate = q.event_date
                    ? new Date(q.event_date + 'T12:00:00').toLocaleDateString('es-MX', { day: 'numeric', month: 'short', year: 'numeric' })
                    : '—';
                  const linkedRes = q._reservation;
                  const isPaidRes = linkedRes && isPaid(linkedRes.payment_status);
                  const isLiveRes = linkedRes?.status === 'in_progress';

                  const handleQuotePress = () => {
                    if (isPaidRes || isLiveRes || linkedRes?.status === 'completed') {
                      navigation.navigate('EventTimer', { reservation: { ...linkedRes, quote: q }, readOnly: true, userRole: 'client' });
                    } else {
                      navigation.navigate('ClientQuoteDetail', { quoteId: q.id });
                    }
                  };

                  return (
                    <Pressable
                      key={q.id}
                      style={styles.quoteCard}
                      onPress={handleQuotePress}
                    >
                      <View style={styles.quoteTop}>
                        <View style={[styles.quotePill, { borderColor: cfg.color + '50', backgroundColor: cfg.color + '18' }]}>
                          <FileText size={11} color={cfg.color} />
                          <Text style={[styles.quotePillText, { color: cfg.color }]}>{cfg.label}</Text>
                        </View>
                        <View style={{ flexDirection: 'row', alignItems: 'center', gap: 12 }}>
                          {q.status === 'pending' && (
                            <Pressable onPress={() => handleDeleteQuote(q)} hitSlop={8}>
                              <Trash2 size={16} color={COLORS.red} />
                            </Pressable>
                          )}
                          <Text style={styles.quoteDate}>
                            {new Date(q.created_at).toLocaleDateString('es-MX', { day: '2-digit', month: 'short' })}
                          </Text>
                        </View>
                      </View>
                      <Text style={styles.quoteGroup}>{q.group?.name ?? 'Grupo'}</Text>
                      <View style={styles.quoteInfo}>
                        <Text style={styles.quoteInfoText}>📅 {eventDate}</Text>
                        <Text style={styles.quoteInfoText}>⏱ {q.duration_hours}h</Text>
                      </View>
                      {q.status === 'quoted' && q.total_amount && (
                        <View style={styles.quotePriceRow}>
                          <Text style={styles.quotePriceLabel}>Total cotizado:</Text>
                          <Text style={styles.quotePriceVal}>${q.total_amount?.toLocaleString()} MXN</Text>
                        </View>
                      )}
                      <Text style={styles.quoteCta}>
                        {isLiveRes ? '🔴 Ver evento en vivo →' : isPaidRes ? '🕐 Ver temporizador →' : q.status === 'quoted' ? 'Ver y responder →' : 'Ver detalle →'}
                      </Text>
                    </Pressable>
                  );
                })}
              </>
            );
          })()}
        </ScrollView>
      </SafeAreaView>

    </View>
  );
}

function ReservationCard({ reservation: r, navigation, onUpdate, isReviewed, isJustPaid, onRate }: any) {
  const now = new Date();
  const todayLocal = `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}-${String(now.getDate()).padStart(2, '0')}`;
  // Solo mostrar faded si el evento está completado/cancelado Y la fecha ya pasó
  const isFinished = r.status === 'completed' || r.status === 'cancelled' || r.status === 'rejected';
  const isPast = isFinished && r.event_date && r.event_date < todayLocal;

  // Pulso del punto EN VIVO
  const pulseAnim = useRef(new Animated.Value(1)).current;
  useEffect(() => {
    if (r.status !== 'in_progress') return;
    const anim = Animated.loop(
      Animated.sequence([
        Animated.timing(pulseAnim, { toValue: 0.3, duration: 600, useNativeDriver: true }),
        Animated.timing(pulseAnim, { toValue: 1.0, duration: 600, useNativeDriver: true }),
      ])
    );
    anim.start();
    return () => anim.stop();
  }, [r.status]);

  // Cuando el grupo acepta pero el cliente aún no pagó → badge naranja con CTA
  const isPaidStatus = isPaid(r.payment_status);
  const s = (() => {
    if (r.status === 'pending' || r.status === 'pending_payment' || r.status === 'accepted' || r.status === 'confirmed') {
      if (isPaidStatus) return STATUS_MAP[r.status] ?? STATUS_MAP.pending;
      // Pago recién enviado — esperando que el webhook confirme
      if (isJustPaid) return { label: '⏳ Verificando pago...', variant: 'orange' as any };
      if (r.payment_status === 'deposit_pending') return { label: '↩ Reintentar pago', variant: 'orange' as any };
      return { label: '⚡ Pagar ahora', variant: 'orange' as any };
    }
    return STATUS_MAP[r.status] ?? STATUS_MAP.pending;
  })();
  const [cancelling,          setCancelling]          = useState(false);
  const [countdown,           setCountdown]           = useState('');
  const [rescheduleVisible,   setRescheduleVisible]   = useState(false);
  const [rescheduleDate,      setRescheduleDate]      = useState('');
  const [rescheduleSaving,    setRescheduleSaving]    = useState(false);
  const [hasBeenRescheduled,  setHasBeenRescheduled]  = useState(false);

  // Reprogramar: solo si confirmada/aceptada, ya pagó, queda más de 24h, y no se ha reprogramado ya
  const hoursUntilEvent = r.event_date
    ? (new Date(r.event_date + 'T00:00:00').getTime() - Date.now()) / 3_600_000
    : 0;
  const canReschedule =
    !r._isQuote &&
    !hasBeenRescheduled &&
    (r.status === 'confirmed' || r.status === 'accepted') &&
    isPaid(r.payment_status) &&
    hoursUntilEvent > 24;

  const handleReschedule = async () => {
    if (!rescheduleDate) {
      Alert.alert('Selecciona una fecha', 'Elige la nueva fecha del evento.');
      return;
    }

    // Validar disponibilidad: el grupo no debe tener otra reserva ese día
    const groupId = (r.group as any)?.id;
    if (groupId) {
      const { data: conflict } = await supabase
        .from('reservations')
        .select('id, event_time')
        .eq('group_id', groupId)
        .eq('event_date', rescheduleDate)
        .neq('id', r.id)
        .in('status', ['confirmed', 'accepted', 'pending'])
        .limit(1)
        .maybeSingle();

      if (conflict) {
        // Verificar buffer de 2h entre eventos
        const newEventTime = r.event_time ?? '20:00:00';
        const conflictTime = (conflict as any).event_time ?? '20:00:00';
        const newHour    = parseInt(newEventTime.split(':')[0], 10);
        const conflictHour = parseInt(conflictTime.split(':')[0], 10);
        if (Math.abs(newHour - conflictHour) < 2) {
          Alert.alert(
            'Fecha no disponible',
            'El grupo ya tiene un evento cerca de ese horario. Elige otra fecha.',
          );
          return;
        }
      }
    }

    setRescheduleSaving(true);
    const { error } = await supabase
      .from('reservations')
      .update({ event_date: rescheduleDate })
      .eq('id', r.id);
    setRescheduleSaving(false);

    if (error) {
      Alert.alert('Error', error.message ?? 'No se pudo reprogramar. Intenta de nuevo.');
      return;
    }

    // Notificar al dueño del grupo (fire-and-forget)
    const ownerId = (r.group as any)?.owner_id;
    if (ownerId) {
      supabase.from('notifications').insert({
        user_id: ownerId,
        type: 'reservation',
        title: 'Evento reprogramado',
        body: `El cliente reprogramó el evento al ${rescheduleDate}. Revisa tu agenda.`,
        data: { reservation_id: r.id, screen: 'GroupReservations' },
      });
    }

    setHasBeenRescheduled(true);
    setRescheduleVisible(false);
    onUpdate();
    Alert.alert('Reprogramado', `Evento movido al ${rescheduleDate}. Se notificó al grupo.`);
  };

  const canCancel = ['pending', 'pending_payment', 'pending_group_confirmation', 'accepted', 'confirmed'].includes(r.status);

  // Monto a pagar: total completo (pago único con opción MSI para programadas y express)
  const payAmount = r.total_price != null ? r.total_price : null;

  // Mostrar botón de pago si: pendiente/aceptada/confirmada + no pagado todavía.
  // Funciona para reservas programadas Y solicitudes express (ambas tienen total_price).
  const canPay =
    !isJustPaid &&
    (r.status === 'pending' || r.status === 'pending_payment' || r.status === 'accepted' || r.status === 'confirmed') &&
    payAmount != null &&
    !isPaid(r.payment_status);

  const isPaidReservation = isPaid(r.payment_status);
  const isLive = r.status === 'in_progress';

  // Contador regresivo de 24 h para pagar
  useEffect(() => {
    if (!canPay || !r.booking_expiration_at) return;
    const tick = () => {
      const diff = new Date(r.booking_expiration_at).getTime() - Date.now();
      if (diff <= 0) { setCountdown('Tiempo expirado'); return; }
      const h = Math.floor(diff / 3_600_000);
      const m = Math.floor((diff % 3_600_000) / 60_000);
      const s = Math.floor((diff % 60_000) / 1_000);
      setCountdown(`${h}h ${m.toString().padStart(2, '0')}m ${s.toString().padStart(2, '0')}s`);
    };
    tick();
    const id = setInterval(tick, 1_000);
    return () => clearInterval(id);
  }, [canPay, r.booking_expiration_at]);

  // Contador regresivo hasta el inicio del evento (cuando ya está pagado)
  const [eventCountdown, setEventCountdown] = useState('');
  useEffect(() => {
    if (!isPaidReservation || isLive || !r.event_date) return;
    const tick = () => {
      const target = parseEventDateMX(r.event_date, r.event_time ?? '00:00');
      if (!target) { setEventCountdown(''); return; }
      const diff = target.getTime() - Date.now();
      if (diff <= 0) { setEventCountdown(''); return; }
      const d = Math.floor(diff / 86_400_000);
      const h = Math.floor((diff % 86_400_000) / 3_600_000);
      const m = Math.floor((diff % 3_600_000) / 60_000);
      const s = Math.floor((diff % 60_000) / 1_000);
      if (d > 0) setEventCountdown(`${d}d ${h}h ${String(m).padStart(2,'0')}m`);
      else setEventCountdown(`${h}h ${String(m).padStart(2,'0')}m ${String(s).padStart(2,'0')}s`);
    };
    tick();
    const id = setInterval(tick, 1_000);
    return () => clearInterval(id);
  }, [isPaidReservation, isLive, r.event_date, r.event_time]);

  const payCurrency = (r.currency_code ?? 'MXN') === 'USD' ? 'USD' : 'MXN';
  const { t } = useTranslation();
  const payLabel = r.payment_status === 'deposit_pending'
    ? t('reservations.btn_retry', { amount: payAmount?.toLocaleString() })
    : t('reservations.btn_pay', { amount: payAmount?.toLocaleString(), currency: payCurrency });


  const handleCancel = async () => {
    // Para cotizaciones sin reserva real, no hay política de reembolso
    if (r._isQuote) {
      Alert.alert(
        'Cancelar cotización',
        '¿Confirmas cancelar esta cotización? No hay pago registrado.',
        [
          { text: 'No', style: 'cancel' },
          {
            text: 'Sí, cancelar', style: 'destructive',
            onPress: async () => {
              setCancelling(true);
              const quoteId = r._quoteData?.id;
              const { error } = await supabase
                .from('quotes').update({ status: 'rejected' }).eq('id', quoteId);
              setCancelling(false);
              if (error) { Alert.alert('Error', error.message ?? 'Intenta de nuevo.'); return; }
              if (r._quoteData?.group?.id) {
                const { data: grpData } = await supabase
                  .from('groups').select('owner_id').eq('id', r._quoteData.group.id).single();
                if (grpData?.owner_id) {
                  const notifs: any[] = [{
                    user_id: grpData.owner_id, type: 'quote_cancelled',
                    title: 'Evento cancelado', body: 'El cliente canceló el evento aceptado.',
                    data: { group_id: r._quoteData.group.id },
                  }];
                  const [{ data: members }, { data: jobs }] = await Promise.all([
                    supabase.from('job_invitations').select('invited_user_id')
                      .eq('group_id', r._quoteData.group.id).eq('invitation_type', 'membership').eq('status', 'accepted'),
                    supabase.from('job_invitations').select('invited_user_id')
                      .eq('group_id', r._quoteData.group.id).eq('invitation_type', 'job').eq('status', 'accepted'),
                  ]);
                  [...(members ?? []), ...(jobs ?? [])].forEach((m: any) =>
                    notifs.push({ user_id: m.invited_user_id, type: 'quote_cancelled',
                      title: 'Evento cancelado', body: 'El cliente canceló el evento aceptado.',
                      data: { group_id: r._quoteData.group.id } })
                  );
                  await supabase.from('notifications').insert(notifs);
                }
              }
              onUpdate();
            },
          },
        ]
      );
      return;
    }

    // Reserva real: consultar política de reembolso primero
    setCancelling(true);
    const { data: policy } = await supabase.rpc('get_cancellation_policy', {
      p_reservation_id: r.id,
    });
    setCancelling(false);

    const policyMsg = (() => {
      if (!policy || !policy.ok) return '¿Estás seguro de cancelar?';
      const h = policy.hours_until;
      if (policy.refund_policy === 'not_paid') {
        return 'No tienes pago registrado. Se cancelará sin cargo.';
      }
      if (policy.refund_policy === 'full') {
        return `Cancelas con más de 48h de anticipación.\n\n✅ Reembolso completo: $${policy.refund_amount.toLocaleString()} MXN`;
      }
      if (policy.refund_policy === 'partial') {
        return `Cancelas entre 24h y 48h antes del evento.\n\n⚠️ Reembolso parcial: $${policy.refund_amount.toLocaleString()} MXN`;
      }
      return `Cancelas con menos de 24h de anticipación (${h}h).\n\n❌ Sin reembolso. El pago no será devuelto.`;
    })();

    Alert.alert(
      'Política de cancelación',
      policyMsg + '\n\n¿Confirmas la cancelación?',
      [
        { text: 'No', style: 'cancel' },
        {
          text: 'Sí, cancelar', style: 'destructive',
          onPress: async () => {
            setCancelling(true);
            const { data, error } = await supabase
              .rpc('client_cancel_reservation', { p_reservation_id: r.id });
            setCancelling(false);
            if (error || data?.ok === false) {
              Alert.alert('No se pudo cancelar', data?.error ?? error?.message ?? 'Intenta de nuevo.');
              return;
            }
            onUpdate();
          },
        },
      ]
    );
  };

  const isExpress = !!r.event_request_id;

  return (
    <View style={[styles.card, isPast && { opacity: 0.5 }, isExpress && styles.cardExpress, isLive && styles.cardLive]}>
      {/* ── Banner EN VIVO ── */}
      {isLive && (
        <View style={styles.liveBanner}>
          <Animated.View style={[styles.liveDot, { opacity: pulseAnim }]} />
          <Text style={styles.liveBannerText}>EN VIVO AHORA</Text>
        </View>
      )}

      {/* ── Info card ── */}
      <Pressable
        style={styles.cardPressable}
        onPress={() => {
          if (isPaidReservation || isLive || r.status === 'accepted' || r.status === 'confirmed' || r.status === 'completed') {
            navigation.navigate('EventTimer', { reservation: r, readOnly: true, userRole: 'client' });
          }
        }}
      >
        <View style={styles.cardTop}>
          {/* Avatar del grupo */}
          {r.group?.profile_image ? (
            <Image source={{ uri: r.group.profile_image }} style={styles.groupAvatar} />
          ) : (
            <View style={styles.groupAvatarPlaceholder}>
              <Text style={styles.groupAvatarInitial}>
                {(r.group?.name ?? 'G').charAt(0).toUpperCase()}
              </Text>
            </View>
          )}
          <View style={styles.cardLeft}>
            <Text style={styles.groupName}>{r.group?.name ?? 'Grupo'}</Text>
            <Text style={[styles.packageName, isExpress && { marginTop: 2 }]}>
              {isExpress ? `Solicitud express · ${r.hours_count ?? '?'}h` : (r.quote?.event_type ?? 'Cotización')}
            </Text>
          </View>
          <View style={{ alignItems: 'flex-end', gap: 6 }}>
            <Badge label={s.label} variant={s.variant} dot />
            {isExpress && (
              <View style={styles.expressBadge}>
                <Text style={styles.expressBadgeText}>⚡ Express</Text>
              </View>
            )}
          </View>
        </View>

        <View style={styles.cardDivider} />

        <View style={styles.cardBottom}>
          <View style={styles.infoChip}>
            <CalendarIcon size={12} color={COLORS.green} />
            <Text style={styles.infoText}>{r.event_date ?? '—'}</Text>
          </View>
          {r.event_time && (
            <View style={styles.infoChip}>
              <Clock size={12} color={COLORS.green} />
              <Text style={styles.infoText}>{(() => {
                const [hStr, mStr] = (r.event_time ?? '').substring(0, 5).split(':');
                const h = parseInt(hStr, 10);
                return `${h % 12 || 12}:${mStr} ${h >= 12 ? 'PM' : 'AM'}`;
              })()}</Text>
            </View>
          )}
          <View style={styles.priceRow}>
            <Text style={styles.price}>${r.total_price?.toLocaleString()}</Text>
          </View>
        </View>

        {/* Folio */}
        {r.folio && (
          <Text style={styles.folioText}>{r.folio}</Text>
        )}

        {/* Payment status badge */}
        {isPaidReservation && (
          <View style={[styles.paidBadge, { backgroundColor: 'rgba(0,230,118,0.12)', borderColor: COLORS.green }]}>
            <Text style={[styles.paidBadgeText, { color: COLORS.green }]}>✅ Pagado</Text>
          </View>
        )}

        {/* Countdown to event start — solo si hay hora definida */}
        {isPaidReservation && !isLive && r.event_time && eventCountdown ? (
          <View style={styles.eventCountdownBox}>
            <Clock size={13} color={COLORS.green} />
            <View style={{ flex: 1 }}>
              <Text style={[styles.eventCountdownText, { color: COLORS.muted2, fontSize: 11, marginBottom: 1 }]}>
                {new Date(r.event_date + 'T12:00:00').toLocaleDateString('es-MX', { weekday: 'short', day: 'numeric', month: 'short' })}
                {' · '}
                {(() => {
                  const [h, m] = (r.event_time ?? '').substring(0, 5).split(':').map(Number);
                  const ampm = h >= 12 ? 'PM' : 'AM';
                  const h12 = h % 12 || 12;
                  return `${h12}:${String(m).padStart(2, '0')} ${ampm}`;
                })()}
              </Text>
              <Text style={styles.eventCountdownText}>⏰ Inicia en {eventCountdown}</Text>
            </View>
          </View>
        ) : null}
      </Pressable>

      {/* Ver evento / EN VIVO */}
      {(isPaidReservation || isLive || r.status === 'accepted' || r.status === 'confirmed' || r.status === 'completed') && (
        <Pressable
          style={[styles.timerBtn, isLive && styles.timerBtnLive]}
          onPress={() => navigation.navigate('EventTimer', { reservation: r, readOnly: true, userRole: 'client' })}
        >
          <Text style={[styles.timerBtnText, isLive && styles.timerBtnTextLive]}>
            {isLive
              ? '🔴 Ver evento en vivo'
              : r.status === 'completed'
                ? '✅ Ver resumen del evento'
                : isPaidReservation
                  ? '🕐 Ver temporizador del evento'
                  : '📅 Ver detalles del evento'}
          </Text>
        </Pressable>
      )}

      {/* Ver ticket */}
      {isPaidReservation && r.folio && (
        <Pressable
          style={styles.ticketBtn}
          onPress={() => navigation.navigate('Ticket', { reservation: r })}
        >
          <Text style={styles.ticketBtnText}>🎟 Ver ticket</Text>
        </Pressable>
      )}

      {/* ── Contador regresivo para pagar ── */}
      {canPay && countdown ? (
        <View style={styles.countdownRow}>
          <Clock size={13} color={COLORS.muted2} />
          <Text style={styles.countdownText}>Tiempo para pagar: {countdown}</Text>
        </View>
      ) : null}

      {/* ── Banner MSI ── */}
      {canPay && (
        <View style={styles.msiBanner}>
          <View style={styles.msiBannerRow}>
            <Text style={styles.msiEmoji}>💳</Text>
            <Text style={styles.msiTitle}>Hasta 12 cuotas mensuales</Text>
            <View style={styles.msiPills}>
              {['3x', '6x', '12x'].map(m => (
                <View key={m} style={styles.msiPill}>
                  <Text style={styles.msiPillText}>{m}</Text>
                </View>
              ))}
            </View>
          </View>
          <Text style={styles.msiSub}>Con tarjetas mexicanas participantes · Stripe</Text>
        </View>
      )}

      {/* ── Botón Pagar ── */}
      {canPay && (
        <Pressable
          style={styles.payBtn}
          onPress={() => {
            if (r._isQuote && r._quoteData) {
              // Cotización aceptada sin reserva creada → flujo nuevo
              navigation.navigate('QuotePayment', { quote: r._quoteData });
            } else {
              // Reserva existente (programada, express o desde cotización)
              navigation.navigate('QuotePayment', { reservation: r });
            }
          }}
        >
          <View style={styles.payBtnInner}>
            <CreditCard size={16} color={COLORS.bg} />
            <View>
              <Text style={styles.payBtnText}>{payLabel}</Text>
              <Text style={styles.payBtnSub}>Elige tu plan de pago al confirmar</Text>
            </View>
          </View>
        </Pressable>
      )}

      {/* ── Botón Reprogramar ── */}
      {canReschedule && (
        <Pressable
          style={styles.rescheduleBtn}
          onPress={() => { setRescheduleDate(''); setRescheduleVisible(true); }}
        >
          <CalendarIcon size={14} color={COLORS.green} />
          <Text style={styles.rescheduleBtnText}>{t('reservations.btn_reschedule')}</Text>
        </Pressable>
      )}

      {/* ── Modal Reprogramar ── */}
      <Modal visible={rescheduleVisible} transparent animationType="slide">
        <View style={styles.rescheduleOverlay}>
          <View style={styles.rescheduleSheet}>
            <View style={styles.rescheduleHeader}>
              <Text style={styles.rescheduleTitle}>Reprogramar evento</Text>
              <Pressable onPress={() => setRescheduleVisible(false)} hitSlop={8}>
                <X size={20} color={COLORS.muted2} />
              </Pressable>
            </View>
            <Text style={styles.rescheduleHint}>
              Elige la nueva fecha para el evento. El grupo recibirá una notificación. Solo se permite una reprogramación por reserva.
            </Text>
            <Calendar
              onDayPress={(day: any) => setRescheduleDate(day.dateString)}
              markedDates={rescheduleDate ? { [rescheduleDate]: { selected: true, selectedColor: COLORS.green, selectedTextColor: '#fff' } } : {}}
              minDate={(() => { const d = new Date(); d.setDate(d.getDate() + 1); return `${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,'0')}-${String(d.getDate()).padStart(2,'0')}`; })()}
              theme={{
                calendarBackground: COLORS.card2,
                textSectionTitleColor: COLORS.muted,
                selectedDayBackgroundColor: COLORS.green,
                selectedDayTextColor: '#fff',
                todayTextColor: COLORS.green,
                dayTextColor: COLORS.text,
                textDisabledColor: COLORS.muted,
                monthTextColor: COLORS.text,
                textMonthFontFamily: FONTS.bodySemiBold,
                textDayFontFamily: FONTS.body,
                textDayHeaderFontFamily: FONTS.bodyMedium,
              }}
            />
            {rescheduleDate ? (
              <Text style={styles.rescheduleSelected}>Nueva fecha: {rescheduleDate}</Text>
            ) : null}
            <Pressable
              style={[styles.rescheduleConfirmBtn, (!rescheduleDate || rescheduleSaving) && { opacity: 0.5 }]}
              onPress={handleReschedule}
              disabled={!rescheduleDate || rescheduleSaving}
            >
              {rescheduleSaving
                ? <ActivityIndicator size="small" color={COLORS.bg} />
                : <Text style={styles.rescheduleConfirmText}>Confirmar nueva fecha</Text>
              }
            </Pressable>
          </View>
        </View>
      </Modal>

      {/* ── Botón Cancelar ── */}
      {canCancel && (
        <View style={[styles.cancelBtnWrapper, canPay && { borderTopWidth: 0 }]}>
          <Pressable
            style={[styles.cancelBtn, cancelling && { opacity: 0.5 }]}
            onPress={handleCancel}
            disabled={cancelling}
          >
            {cancelling ? (
              <ActivityIndicator size="small" color={COLORS.red} />
            ) : (
              <>
                <X size={14} color={COLORS.red} />
                <Text style={styles.cancelBtnText}>{t('reservations.btn_cancel')}</Text>
              </>
            )}
          </Pressable>
        </View>
      )}

      {/* ── Botón Calificar + Compartir ── */}
      {r.status === 'completed' && !r._isQuote && (
        <View style={styles.completedActions}>
          {isReviewed ? (
            <Text style={styles.ratedText}>⭐ Ya calificaste este evento</Text>
          ) : (
            <Pressable
              style={styles.rateBtn}
              onPress={() => onRate?.(r.id, r.group?.name ?? 'el grupo')}
            >
              <Star size={15} color={COLORS.gold} fill={COLORS.gold} />
              <Text style={styles.rateBtnText}>{t('reservations.rate_title')}</Text>
            </Pressable>
          )}
          <Pressable
            style={styles.shareBtn}
            onPress={() => {
              const groupName = r.group?.name ?? 'el grupo';
              Share.share({
                message:
                  `🎵 ${groupName} tocó en mi evento y fue increíble.\n` +
                  `Música en vivo para cualquier ocasión. ` +
                  `¡Búscalos en DARICEFY y reserva tu grupo! 🎶`,
              });
            }}
          >
            <Share2 size={15} color={COLORS.muted2} />
            <Text style={styles.shareBtnText}>Compartir</Text>
          </Pressable>
        </View>
      )}
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: COLORS.bg },
  header: { paddingHorizontal: SPACING.xl, paddingVertical: 16 },
  title: { fontFamily: FONTS.title, fontSize: 24, color: COLORS.text },
  list: { padding: SPACING.xl, gap: 12 },

  // ── Card ──
  card: {
    backgroundColor: COLORS.card,
    borderRadius: 20,
    borderWidth: 1,
    borderColor: COLORS.border,
    overflow: 'hidden',
  },
  cardPressable: { padding: 16 },
  cardTop: { flexDirection: 'row', alignItems: 'center', gap: 10, marginBottom: 12 },
  groupAvatar: {
    width: 44, height: 44, borderRadius: 22,
    borderWidth: 1, borderColor: COLORS.border,
  },
  groupAvatarPlaceholder: {
    width: 44, height: 44, borderRadius: 22,
    backgroundColor: COLORS.card2,
    borderWidth: 1, borderColor: COLORS.border,
    alignItems: 'center', justifyContent: 'center',
  },
  groupAvatarInitial: { fontFamily: FONTS.bodySemiBold, fontSize: 18, color: COLORS.green },
  cardLeft: { flex: 1 },
  groupName:   { fontFamily: FONTS.bodySemiBold, fontSize: 16, color: COLORS.text, marginBottom: 2 },
  packageName: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted },
  cardDivider: { height: 1, backgroundColor: COLORS.border, marginBottom: 12 },
  cardBottom:  { flexDirection: 'row', alignItems: 'center', gap: 8, flexWrap: 'wrap' },
  infoChip:    {
    flexDirection: 'row', alignItems: 'center', gap: 5,
    backgroundColor: COLORS.card2, borderRadius: 10,
    paddingHorizontal: 9, paddingVertical: 5,
  },
  infoRow:     { flexDirection: 'row', alignItems: 'center', gap: 4 },
  infoText:    { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.muted2 },
  priceRow:    { flexDirection: 'row', alignItems: 'center', gap: 4, marginLeft: 'auto' as any },
  price:       { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.green },

  // Paid badge (inline in card)
  paidBadge: {
    marginTop: 10,
    alignSelf: 'flex-start',
    paddingHorizontal: 10, paddingVertical: 4,
    borderRadius: RADIUS.full, borderWidth: 1,
    backgroundColor: 'rgba(0,230,118,0.08)', borderColor: 'rgba(0,230,118,0.3)',
  },
  paidBadgeText: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.green },

  // ── Countdown ──
  countdownRow: {
    flexDirection: 'row', alignItems: 'center', gap: 6,
    paddingHorizontal: 14, paddingVertical: 7,
    borderTopWidth: 1, borderTopColor: COLORS.border,
  },
  countdownText: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2 },

  // ── MSI banner ──
  msiBanner: {
    paddingHorizontal: 14, paddingVertical: 10,
    borderTopWidth: 1, borderTopColor: COLORS.border,
    backgroundColor: 'rgba(0,230,118,0.05)',
  },
  msiBannerRow: { flexDirection: 'row', alignItems: 'center', gap: 8, marginBottom: 3 },
  msiEmoji: { fontSize: 17 },
  msiTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.green, flex: 1 },
  msiSub:   { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted2, paddingLeft: 25 },
  msiPills: { flexDirection: 'row', gap: 4 },
  msiPill:  {
    backgroundColor: 'rgba(0,230,118,0.15)',
    borderRadius: 6, paddingHorizontal: 6, paddingVertical: 3,
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.3)',
  },
  msiPillText: { fontFamily: FONTS.bodySemiBold, fontSize: 11, color: COLORS.green },

  // ── Pay button ──
  payBtn: {
    backgroundColor: COLORS.green,
    paddingVertical: 10, paddingHorizontal: SPACING.md,
    alignItems: 'center',
  },
  payBtnInner: { flexDirection: 'row', alignItems: 'center', gap: 10 },
  payBtnText:  { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.bg },
  payBtnSub:   { fontFamily: FONTS.body, fontSize: 10, color: 'rgba(0,0,0,0.5)', marginTop: 1 },

  // ── Cancel button ──
  cancelBtnWrapper: {
    borderTopWidth: 1, borderTopColor: COLORS.border,
    paddingHorizontal: SPACING.lg, paddingVertical: 12,
  },
  cancelBtn: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'center',
    gap: 8, paddingVertical: 10, borderRadius: RADIUS.md,
    backgroundColor: 'rgba(239,83,80,0.08)',
    borderWidth: 1, borderColor: 'rgba(239,83,80,0.2)',
  },
  cancelBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.red },

  // ── Empty state ──
  empty:      { alignItems: 'center', paddingTop: 80 },
  emptyIcon:  { fontSize: 48, marginBottom: 16 },
  emptyTitle: { fontFamily: FONTS.title, fontSize: 20, color: COLORS.text, marginBottom: 8 },
  emptyText:  { fontFamily: FONTS.body, fontSize: 14, color: COLORS.muted2, textAlign: 'center' },

  // ── Tabs ──
  tabs: {
    flexDirection: 'row',
    marginHorizontal: SPACING.xl,
    marginBottom: 16,
    padding: 4,
    backgroundColor: COLORS.card,
    borderRadius: 100,
    borderWidth: 1,
    borderColor: COLORS.border,
  },
  tab:          { flex: 1, paddingVertical: 11, alignItems: 'center', borderRadius: 100 },
  tabActive:    {
    backgroundColor: COLORS.green,
    shadowColor: COLORS.green,
    shadowOffset: { width: 0, height: 4 },
    shadowOpacity: 0.35,
    shadowRadius: 8,
    elevation: 4,
  },
  tabText:      { fontFamily: FONTS.bodyMedium, fontSize: 14, color: COLORS.muted2 },
  tabTextActive:{ color: COLORS.bg, fontFamily: FONTS.bodySemiBold },
  tabBadge:     { color: COLORS.green, fontFamily: FONTS.bodySemiBold },
  tabBadgePill: {
    minWidth: 18, height: 18, borderRadius: 9,
    backgroundColor: `${COLORS.green}22`,
    alignItems: 'center', justifyContent: 'center',
    paddingHorizontal: 5,
  },
  tabBadgePillActive: { backgroundColor: 'rgba(0,0,0,0.2)' },
  tabBadgePillText:   { fontFamily: FONTS.bodyMedium, fontSize: 10, color: COLORS.green },
  tabBadgePillTextActive: { color: COLORS.bg },

  // ── Event countdown ──
  eventCountdownBox: {
    flexDirection: 'row', alignItems: 'center', gap: 6,
    marginTop: 10, paddingHorizontal: 12, paddingVertical: 8,
    borderRadius: RADIUS.md, borderWidth: 1,
    backgroundColor: 'rgba(0,230,118,0.07)', borderColor: 'rgba(0,230,118,0.3)',
  },
  eventCountdownText: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.green },

  // ── Timer button ──
  // ── Folio ──
  folioText: {
    fontFamily: FONTS.bodyMedium, fontSize: 11, color: COLORS.muted,
    letterSpacing: 0.5, paddingHorizontal: SPACING.lg, paddingTop: 4, paddingBottom: 2,
  },

  // ── Ticket button ──
  ticketBtn: {
    borderTopWidth: 1, borderTopColor: COLORS.border,
    paddingVertical: 12, paddingHorizontal: SPACING.lg,
    alignItems: 'center',
  },
  ticketBtnText: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted2 },

  timerBtn: {
    borderTopWidth: 1, borderTopColor: COLORS.border,
    paddingVertical: 14, paddingHorizontal: SPACING.lg,
    alignItems: 'center', flexDirection: 'row', justifyContent: 'center', gap: 8,
  },
  timerBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.green },
  timerBtnLive: {
    backgroundColor: '#10b981',
    borderTopWidth: 0,
    borderWidth: 0,
  },
  timerBtnTextLive: { color: '#fff', fontFamily: FONTS.bodySemiBold, fontSize: 14 },

  // ── Live card ──
  cardLive: {
    borderWidth: 2,
    borderColor: '#10b981',
  },
  liveBanner: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 8,
    backgroundColor: '#dcfce7',
    paddingVertical: 6,
    paddingHorizontal: 12,
    borderTopLeftRadius: 12,
    borderTopRightRadius: 12,
    borderBottomWidth: 1,
    borderBottomColor: '#86efac',
  },
  liveDot: {
    width: 8,
    height: 8,
    borderRadius: 4,
    backgroundColor: '#dc2626',
  },
  liveBannerText: {
    fontFamily: FONTS.bodySemiBold,
    color: '#15803d',
    fontSize: 12,
    letterSpacing: 0.5,
  },

  // ── Quote card ──
  quoteCard: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border,
    padding: SPACING.lg,
  },
  quoteTop: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center', marginBottom: 8 },
  quotePill: {
    flexDirection: 'row', alignItems: 'center', gap: 5,
    paddingHorizontal: 9, paddingVertical: 4,
    borderRadius: RADIUS.full, borderWidth: 1,
  },
  quotePillText:  { fontFamily: FONTS.bodyMedium, fontSize: 11 },
  quoteDate:      { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted },
  quoteGroup:     { fontFamily: FONTS.bodySemiBold, fontSize: 17, color: COLORS.text, marginBottom: 6 },
  quoteInfo:      { flexDirection: 'row', gap: 14, marginBottom: 8 },
  quoteInfoText:  { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2 },
  quotePriceRow:  { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center', backgroundColor: 'rgba(66,133,244,0.1)', borderRadius: RADIUS.md, padding: 10, marginBottom: 8 },
  quotePriceLabel:{ fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.blue },
  quotePriceVal:  { fontFamily: FONTS.title, fontSize: 18, color: COLORS.blue },
  quoteCta:       { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.green, textAlign: 'right' },

  cardExpress: {
    borderColor: `${COLORS.green}40`,
  },
  expressBadge: {
    backgroundColor: 'rgba(0,230,118,0.12)', borderRadius: 20,
    paddingHorizontal: 7, paddingVertical: 3,
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.35)',
  },
  expressBadgeText: { fontFamily: FONTS.bodyMedium, fontSize: 10, color: COLORS.green },

  // ── Rate button ──
  rateBtn: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 7,
    backgroundColor: 'rgba(255,179,0,0.12)',
    borderRadius: RADIUS.lg, paddingVertical: 10, paddingHorizontal: 14,
    borderWidth: 1, borderColor: 'rgba(255,179,0,0.25)',
    flex: 1,
  },
  rateBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.gold },
  ratedText: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted2, textAlign: 'center', paddingVertical: 10 },

  // ── Rating modal ──
  modalOverlay: {
    flex: 1, backgroundColor: 'rgba(0,0,0,0.75)',
    justifyContent: 'center', alignItems: 'center', padding: SPACING.xl,
  },
  modalCard: {
    width: '100%', backgroundColor: COLORS.card,
    borderRadius: RADIUS.xl, borderWidth: 1, borderColor: COLORS.border,
    padding: SPACING.xl,
  },
  modalTitle: { fontFamily: FONTS.title, fontSize: 22, color: COLORS.text, marginBottom: 4 },
  modalSubtitle: { fontFamily: FONTS.body, fontSize: 14, color: COLORS.muted2, marginBottom: 20 },
  starsRow: { flexDirection: 'row', justifyContent: 'center', gap: 12, marginBottom: 10 },
  ratingLabel: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.gold, textAlign: 'center', marginBottom: 16 },
  commentInput: {
    backgroundColor: COLORS.card2, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border,
    color: COLORS.text, fontFamily: FONTS.body, fontSize: 14,
    padding: SPACING.md, minHeight: 80, textAlignVertical: 'top',
    marginBottom: 20,
  },
  modalActions: { flexDirection: 'row', gap: 12 },
  modalCancelBtn: {
    flex: 1, borderRadius: RADIUS.lg, borderWidth: 1, borderColor: COLORS.border,
    paddingVertical: 13, alignItems: 'center',
  },
  modalCancelText: { fontFamily: FONTS.bodyMedium, fontSize: 14, color: COLORS.muted2 },
  modalSubmitBtn: {
    flex: 2, backgroundColor: COLORS.gold, borderRadius: RADIUS.lg,
    paddingVertical: 13, alignItems: 'center',
  },
  modalSubmitText: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.bg },
  reviewWarningText: {
    fontFamily: FONTS.body, fontSize: 12, color: COLORS.orange,
    marginTop: 6, lineHeight: 17,
  },
  completedActions: {
    flexDirection: 'row', gap: 10, alignItems: 'center',
    marginTop: 4,
  },
  shareBtn: {
    flexDirection: 'row', alignItems: 'center', gap: 6,
    backgroundColor: COLORS.card2,
    borderRadius: RADIUS.lg, paddingVertical: 10, paddingHorizontal: 14,
    borderWidth: 1, borderColor: COLORS.border,
    flex: 1, justifyContent: 'center',
  },
  shareBtnText: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted2 },

  // Reprogramar
  rescheduleBtn: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 8,
    paddingVertical: 12, borderTopWidth: 1, borderTopColor: COLORS.border,
  },
  rescheduleBtnText: { fontFamily: FONTS.bodyMedium, fontSize: 14, color: COLORS.green },
  rescheduleOverlay: {
    flex: 1, backgroundColor: 'rgba(0,0,0,0.7)', justifyContent: 'flex-end',
  },
  rescheduleSheet: {
    backgroundColor: COLORS.card, borderTopLeftRadius: 20, borderTopRightRadius: 20,
    padding: SPACING.xl, paddingBottom: 36,
  },
  rescheduleHeader: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', marginBottom: 8,
  },
  rescheduleTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 17, color: COLORS.text },
  rescheduleHint: {
    fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2, marginBottom: 16, lineHeight: 18,
  },
  rescheduleSelected: {
    fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.green,
    textAlign: 'center', marginVertical: 12,
  },
  rescheduleConfirmBtn: {
    backgroundColor: COLORS.green, borderRadius: RADIUS.lg,
    paddingVertical: 14, alignItems: 'center', marginTop: 8,
  },
  rescheduleConfirmText: { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.bg },
  loadMoreBtn: {
    marginHorizontal: SPACING.xl, marginVertical: 12, paddingVertical: 14,
    borderRadius: RADIUS.lg, borderWidth: 1, borderColor: COLORS.border,
    alignItems: 'center' as const,
  },
  loadMoreText: { fontFamily: FONTS.bodyMedium, fontSize: 14, color: COLORS.muted2 },
});
