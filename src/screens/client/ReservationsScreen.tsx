import { Calendar as CalendarIcon, ChevronRight, Clock, CreditCard, FileText, Pencil, PartyPopper, Plus, Share2, Star, Trash2, X } from 'lucide-react-native';
import { Calendar } from 'react-native-calendars';
import React, { useCallback, useEffect, useRef, useState } from 'react';
import { useFocusEffect } from '@react-navigation/native';
import {
  Animated,
  ActivityIndicator,
  Alert,
  Image,
  KeyboardAvoidingView,
  Modal,
  Platform,
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
import RequestZoneMap from '../../components/requests/RequestZoneMap';
import { eventCardCenter, approxGroupLocation } from '../../utils/mapUtils';
import { openSupport } from '../../utils/support';
import { validateClabe, bankFromClabe, normalizeClabe, clabeLast4 } from '../../utils/clabe';
import * as WebBrowser from 'expo-web-browser';

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

/**
 * Encabezado "Mi evento" — sql/685 (Fase 1 de "Mi Evento").
 *
 * Este bloque ya vivía DUPLICADO letra por letra en las pestañas "Eventos" y
 * "Pendientes". Al agregarle el botón de editar habría quedado duplicado en dos
 * lugares más, así que se extrajo aquí: mismo markup y mismos estilos que
 * antes, un solo lugar donde cambiarlo. No se movió a otro archivo ni se
 * generalizó — sigue siendo de esta pantalla.
 *
 * `meta` es la fila de public.events (nombre/tipo/invitados...). Puede venir
 * undefined: eventos anteriores a Fase 1, o una base donde sql/685 todavía no
 * se aplicó. En ese caso el encabezado se ve exactamente como antes.
 */
function EventGroupHeader({ group, meta, t, dateLocale, navigation }: any) {
  const prettyDate = group.eventDate
    ? new Date(group.eventDate + 'T12:00:00').toLocaleDateString(dateLocale, { day: 'numeric', month: 'long' })
    : '—';
  return (
    <View style={styles.eventGroupHeader}>
      {/* Dos renglones y no uno. Antes de Fase 1 el título compartía renglón
          con "Agregar otro proveedor" y le quedaban ~92dp en un teléfono de
          360dp; al sumar el lápiz bajaba a ~50dp, y en uno de 320dp el título
          desaparecía. Con el nombre del evento (hasta 80 caracteres) eso era
          inservible. El botón conserva EXACTAMENTE el mismo estilo de antes,
          solo baja de renglón. */}
      <View style={styles.eventGroupHeaderTop}>
        {/* Fase 2 — tocar el título abre el dashboard del evento (MyEventScreen).
            El lápiz sigue yendo a editar los datos y el pill verde al hub de
            servicios: tres destinos distintos, sin quitar nada de Fase 1. */}
        <Pressable
          style={{ flex: 1 }}
          onPress={() => navigation.navigate('MyEvent', { eventId: group.eventId })}
        >
          <View style={styles.eventGroupHeaderTitleRow}>
            <Text style={styles.eventGroupHeaderTitle} numberOfLines={2}>
              {meta?.name ? meta.name : t('reservations.myEventTitle', { date: prettyDate })}
            </Text>
            <ChevronRight size={15} color={COLORS.muted2} />
          </View>
          {!!meta?.name && <Text style={styles.eventGroupHeaderAddress}>{prettyDate}</Text>}
          {!!group.address && <Text style={styles.eventGroupHeaderAddress} numberOfLines={1}>📍 {group.address}</Text>}
        </Pressable>
        <Pressable
          style={styles.eventGroupHeaderEditBtn}
          onPress={() => navigation.navigate('EventInfo', { eventId: group.eventId })}
          hitSlop={6}
        >
          <Pencil size={14} color={COLORS.muted2} />
        </Pressable>
      </View>
      <Pressable
        style={styles.eventGroupHeaderAddBtn}
        onPress={() => navigation.navigate('EventCategoryPicker', {
          eventId: group.eventId, eventDate: group.eventDate, eventAddress: group.address,
        })}
      >
        <Plus size={14} color={COLORS.green} />
        <Text style={styles.eventGroupHeaderAddBtnText}>{t('reservations.addAnotherProvider')}</Text>
      </Pressable>
    </View>
  );
}

/**
 * CTA de "Arma tu fiesta" — Fase 2. Punto de entrada principal, dentro de la
 * pestaña donde ya viven los eventos, sin reorganizar la navegación. Aparece en
 * los dos casos que pidió el usuario: con eventos ya creados (arriba de la
 * lista) y en el estado vacío.
 */
function BuildPartyCta({ t, navigation, variant }: any) {
  const grande = variant === 'empty';
  return (
    <Pressable
      style={[styles.ctaCard, grande && styles.ctaCardBig]}
      onPress={() => navigation.navigate('PartyBuilder')}
    >
      <View style={styles.ctaIcon}>
        <PartyPopper size={grande ? 22 : 18} color={COLORS.green} />
      </View>
      <View style={{ flex: 1 }}>
        <Text style={styles.ctaTitle}>{t('reservations.buildPartyTitle')}</Text>
        <Text style={styles.ctaText}>
          {grande ? t('reservations.buildPartyTextEmpty') : t('reservations.buildPartyText')}
        </Text>
      </View>
      <ChevronRight size={18} color={COLORS.green} />
    </Pressable>
  );
}

export default function ClientReservationsScreen({ navigation, route }: any) {
  const { t, i18n } = useTranslation();
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
  // sql/685 — filas de public.events del cliente, indexadas por id, para poder
  // mostrar el nombre que le puso a su evento en el encabezado "Mi evento".
  const [eventMeta,        setEventMeta]        = useState<Record<string, any>>({});

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

    const [resData, quoteData, exprData, eventData] = await Promise.all([
      supabase
        .from('reservations')
        .select('*, group:groups(id, name, genre, city, state, profile_image, owner_id), quote:quotes(duration_hours, overtime_1h_price, overtime_2h_price, overtime_3h_price, event_type, latitude, longitude), event_request:event_requests!event_request_id(latitude, longitude, event_lat, event_lng), event_request_id, hours_count')
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
      // sql/685 — datos básicos del evento. select('*') a propósito: si esa
      // migración todavía no está aplicada, nombrar las columnas nuevas daría
      // 42703 y rompería el fetch completo de la pantalla. Así, en el peor
      // caso, el encabezado simplemente no muestra nombre.
      supabase
        .from('events')
        .select('*')
        .eq('client_id', uid),
    ]);

    if (eventData.data) {
      const byId: Record<string, any> = {};
      eventData.data.forEach((ev: any) => { byId[ev.id] = ev; });
      setEventMeta(byId);
    }

    if (resData.data) {
      setResHasMore(resData.data.length === RES_PAGE_SIZE);

      // Canceladas con reembolso — ciclo de vida visible:
      //   · en proceso  → visible ("Reembolso en camino") hasta que se envíe
      //   · enviado     → visible 7 días más ("✅ Reembolso enviado" + comprobante)
      //   · automático  → visible 7 días desde la cancelación
      //   después de eso, el evento se oculta solo.
      const GRACE_MS = 7 * 24 * 60 * 60 * 1000;
      const cancelledIds = resData.data
        .filter((r: any) => r.status === 'cancelled' && r.payout_status === 'refunded')
        .map((r: any) => r.id);
      const mrByRes: Record<string, any> = {};
      if (cancelledIds.length > 0) {
        const { data: mrData } = await supabase
          .from('manual_refunds')
          .select('reservation_id, status, processed_at')
          .in('reservation_id', cancelledIds);
        (mrData ?? []).forEach((m: any) => { mrByRes[m.reservation_id] = m; });
      }
      const visibleRes = resData.data.filter((r: any) => {
        if (!(r.status === 'cancelled' && r.payout_status === 'refunded')) return true;
        const mr = mrByRes[r.id];
        if (mr && mr.status !== 'sent') return true;   // reembolso manual en camino
        const doneAt = mr?.processed_at ?? r.cancelled_at;
        if (!doneAt) return false;
        return (Date.now() - new Date(doneAt).getTime()) < GRACE_MS;
      });

      if (pageNum === 0) {
        setReservations(visibleRes);
      } else {
        setReservations(prev => [...prev, ...visibleRes]);
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
          .select('id,quote_id,folio,event_date,event_time,address,status,payment_status,total_price,event_started_at,event_ended_at,break_type,group_id,client_id,notes,platform_commission,group_earnings')
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
                    .eq('group_id', q.group.id).eq('invitation_type', 'event').eq('status', 'accepted'),
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
    // Canceladas ocultas, EXCEPTO las que tienen reembolso en proceso:
    // esas se muestran como "Cancelada · reembolso en camino" hasta que el
    // admin lo marque enviado (fetchAll ya filtró las reembolsadas).
    .filter(r => r && (
      !['cancelled', 'rejected', 'expired'].includes(r.status ?? '') ||
      (r.status === 'cancelled' && r.payout_status === 'refunded' && !!r.mp_payment_id)
    ))
    .filter((r, i, arr) => r && arr.findIndex(x => x?.id === r.id) === i)
    .sort((a, b) => (b.created_at ?? '').localeCompare(a.created_at ?? ''));

  // sql/585 (Fase 1C, ampliado 2026-09-01) — agrupación "Mi evento":
  // puramente aditivo, no toca el render de eventItems de abajo en
  // absoluto, no muta reservas ni pagos. Antes solo aparecía con 2+
  // proveedores; ahora aparece desde 1 solo, para que "Agregar otro
  // proveedor" tenga un punto de entrada persistente en Mis Reservas y no
  // dependa de que el cliente toque el botón en el aviso de éxito antes de
  // cerrarlo. create_booking_with_event() YA crea un event_id real para
  // cada reserva nueva hoy (confirmado en producción) — con este cambio,
  // toda reserva con event_id (nueva o vieja) obtiene su tarjeta "Mi
  // evento" además de su tarjeta normal de abajo (redundancia visual
  // menor, aceptada a cambio de tener un punto de entrada persistente).
  // 2026-09-06 — "Mi evento" ahora también agrupa cotizaciones TODAVÍA SIN
  // responder (pending/quoted), no solo reservas/cotizaciones aceptadas.
  // Hallazgo real del cliente probando: pedir la 1ª cotización a un grupo
  // no dejaba ningún lugar para "agregar otro proveedor" hasta que ALGUIEN
  // ya hubiera confirmado — obligaba a repetir todo el formulario para el
  // 2º grupo. QuoteFormScreen ya liga cada cotización nueva a un event_id
  // real (columna nueva de quotes, sql/585) — aquí solo se refleja eso.
  // Solo fechas de hoy en adelante — mismo criterio que pendingQuotes: una
  // cotización pendiente de un evento que ya pasó no debe resucitar su
  // tarjeta "Mi evento".
  const pendingEventQuotes = quotes.filter(q =>
    q?.event_id && ['pending', 'quoted'].includes(q.status) && (q.event_date ?? '') >= today
  );

  const groupedEvents = (() => {
    const byEvent: Record<string, any[]> = {};
    for (const r of eventItems) {
      if (!r?.event_id || r._isQuote) continue;
      (byEvent[r.event_id] ??= []).push(r);
    }
    for (const q of pendingEventQuotes) {
      (byEvent[q.event_id] ??= []).push(q);
    }
    return Object.entries(byEvent)
      .filter(([, items]) => items.length >= 1)
      .map(([eventId, items]) => ({
        eventId,
        eventDate: items[0].event_date,
        // Una reserva trae `address`; una cotización trae `event_address`
        // (nombres reales de cada tabla) — el evento puede tener solo
        // cotizaciones pendientes, así que se aceptan ambos.
        address:   items[0].address ?? items[0].event_address ?? null,
        providers: items,
      }))
      .sort((a, b) => (b.eventDate ?? '').localeCompare(a.eventDate ?? ''));
  })();

  // Eventos que existen SOLO por una cotización pendiente — todavía no
  // tienen ninguna tarjeta en eventItems para anclar el encabezado antes de
  // ella, así que se muestran aparte, arriba de la lista normal.
  const eventItemEventIds = new Set(eventItems.map(r => r?.event_id).filter(Boolean));
  const pendingOnlyGroupedEvents = groupedEvents.filter(g => !eventItemEventIds.has(g.eventId));

  return (
    <View style={styles.container}>
      <SafeAreaView edges={['top']} style={{ flex: 1 }}>
        {/* Petición real (2026-09-03): quitado el título repetido — el tab
            de abajo ya dice "Reservas"/"Mis Eventos". */}
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
              <View>
                <BuildPartyCta t={t} navigation={navigation} variant="empty" />
                <View style={styles.empty}>
                  <Text style={styles.emptyIcon}>🎵</Text>
                  <Text style={styles.emptyTitle}>{t('reservations.tab_events')}</Text>
                  <Text style={styles.emptyText}>{t('reservations.empty_events')}</Text>
                </View>
              </View>
            ) : (
              <>
                <BuildPartyCta t={t} navigation={navigation} variant="inline" />
                {/* sql/585 (Fase 1C, rediseñado 2026-09-02) — "Mi evento" ya
                    NO duplica la tarjeta de la reserva: se inserta como un
                    encabezado ligero justo antes de la PRIMERA reserva de
                    cada event_id (una sola vez por evento, sin importar
                    cuántos proveedores tenga — sql/686 subió el máximo de 3
                    a 20), y cada reserva sigue
                    renderizando su ReservationCard normal, completo, una
                    sola vez — con chat/cancelar/calificar/GPS intactos. El
                    botón "Agregar otro proveedor" vive en ese encabezado,
                    así que es un punto de entrada persistente incluso con
                    1 solo proveedor, sin repetir precio/estado que ya
                    muestra la tarjeta de abajo. */}
                {(() => {
                  const shownEventHeaders = new Set<string>();
                  return eventItems.map((r, idx) => {
                    const showHeader = !!r?.event_id && !r._isQuote && !shownEventHeaders.has(r.event_id);
                    if (showHeader) shownEventHeaders.add(r.event_id);
                    const group = showHeader ? groupedEvents.find(g => g.eventId === r.event_id) : null;
                    return (
                      <React.Fragment key={r.id}>
                        {showHeader && group && (
                          <EventGroupHeader
                            group={group}
                            meta={eventMeta[group.eventId]}
                            t={t}
                            dateLocale={i18n.language?.startsWith('en') ? 'en-US' : 'es-MX'}
                            navigation={navigation}
                          />
                        )}
                        <ReservationCard
                          reservation={r}
                          navigation={navigation}
                          onUpdate={() => fetchAll(0)}
                          isReviewed={reviewedIds.has(r.id)}
                          isJustPaid={justPaidId === r.id}
                          showMap={idx < 6}
                          onRate={(reservationId: string) => {
                            const res = reservations.find(r => r.id === reservationId);
                            if (res) {
                              navigation.navigate('EventTimer' as any, { reservation: res, readOnly: true, userRole: 'client' });
                            }
                          }}
                        />
                      </React.Fragment>
                    );
                  });
                })()}
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
            const hasAny = visibleQuotes.length > 0 || expressRequests.length > 0 || pendingOnlyGroupedEvents.length > 0;
            return !hasAny ? (
              <View style={styles.empty}>
                <Text style={styles.emptyIcon}>📋</Text>
                <Text style={styles.emptyTitle}>{t('reservations.empty_pending')}</Text>
                <Text style={styles.emptyText}>{t('reservations.empty_pending_sub')}</Text>
              </View>
            ) : (
              <>
                {/* 2026-09-02 (pedido real) — movido de la pestaña "Eventos":
                    un evento que todavía NO tiene ninguna reserva confirmada
                    (solo cotizaciones pendientes) pertenece conceptualmente
                    a "Pendientes", no a "Eventos" — ahí solo debían aparecer
                    eventos ya confirmados. En cuanto la primera cotización
                    se acepte, este evento pasa al mecanismo normal de la
                    pestaña Eventos (inline, antes de su tarjeta) y
                    desaparece de aquí. */}
                {pendingOnlyGroupedEvents.map(group => (
                  <EventGroupHeader
                    key={group.eventId}
                    group={group}
                    meta={eventMeta[group.eventId]}
                    t={t}
                    dateLocale={i18n.language?.startsWith('en') ? 'en-US' : 'es-MX'}
                    navigation={navigation}
                  />
                ))}

                {/* ── Solicitudes express ── */}
                {expressRequests.length > 0 && (
                  <Text style={styles.pendSectionTitle}>⚡ Solicitudes exprés · {expressRequests.length}</Text>
                )}
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
                {visibleQuotes.length > 0 && (
                  <Text style={[styles.pendSectionTitle, expressRequests.length > 0 && { marginTop: 10 }]}>
                    📅 Cotizaciones programadas · {visibleQuotes.length}
                  </Text>
                )}
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
                        <View style={{ flexDirection: 'row', alignItems: 'center', gap: 6, flexWrap: 'wrap', flex: 1 }}>
                          <View style={[styles.quotePill, { borderColor: cfg.color + '50', backgroundColor: cfg.color + '18' }]}>
                            <FileText size={11} color={cfg.color} />
                            <Text style={[styles.quotePillText, { color: cfg.color }]}>{cfg.label}</Text>
                          </View>
                          <View style={[styles.quotePill, { borderColor: COLORS.green + '50', backgroundColor: COLORS.green + '12' }]}>
                            <Text style={[styles.quotePillText, { color: COLORS.green }]}>📅 Programada</Text>
                          </View>
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

          {/* Pie: guía arriba, políticas en medio, soporte hasta abajo */}
          <Pressable
            style={[styles.policyFooter, { marginTop: 24 }]}
            hitSlop={8}
            onPress={() => navigation.navigate('EventGuide', { role: 'client' })}
          >
            <Text style={styles.guideFooterText}>❓ ¿Cómo funciona el evento?</Text>
          </Pressable>
          <Pressable
            style={styles.policyFooter}
            hitSlop={8}
            onPress={() => navigation.navigate('CancellationPolicy', { role: 'client' })}
          >
            <Text style={styles.policyFooterText}>📋 Políticas de cancelación</Text>
          </Pressable>
          <Pressable style={[styles.supportFooter, { marginTop: 4 }]} hitSlop={8} onPress={() => openSupport()}>
            <Text style={styles.supportFooterText}>💬 ¿Necesitas ayuda? Contacta a soporte</Text>
          </Pressable>
        </ScrollView>
      </SafeAreaView>

    </View>
  );
}

function ReservationCard({ reservation: r, navigation, onUpdate, isReviewed, isJustPaid, onRate, showMap = false }: any) {
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
  // Reembolso manual (SPEI/efectivo): datos bancarios del cliente
  const [clabeOpen,           setClabeOpen]           = useState(false);
  const [clabeInput,          setClabeInput]          = useState('');
  const [holderInput,         setHolderInput]         = useState('');
  const [bankInput,           setBankInput]           = useState('');
  // Pulso de la tarjetita del botón de pagar (llama la atención al CTA)
  const payPulse = useRef(new Animated.Value(1)).current;
  useEffect(() => {
    const loop = Animated.loop(Animated.sequence([
      Animated.timing(payPulse, { toValue: 1.22, duration: 650, useNativeDriver: true }),
      Animated.timing(payPulse, { toValue: 1,    duration: 650, useNativeDriver: true }),
    ]));
    loop.start();
    return () => loop.stop();
  }, []);

  // Estado visible del reembolso en canceladas (manual_refunds propio, RLS)
  const [refundInfo,          setRefundInfo]          = useState<any>(null);
  useEffect(() => {
    if (r.status === 'cancelled' && !r._isQuote && r.mp_payment_id) {
      supabase.from('manual_refunds')
        .select('status, due_date, amount, receipt_path')
        .eq('reservation_id', r.id)
        .maybeSingle()
        .then(({ data }) => setRefundInfo(data));
    }
  }, [r.status, r.id]);
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
                      .eq('group_id', r._quoteData.group.id).eq('invitation_type', 'event').eq('status', 'accepted'),
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

    // Reserva real: desglose de cargo por proximidad calculado en el servidor
    setCancelling(true);
    const { data: charge } = await supabase.rpc('compute_cancellation_charge', {
      p_reservation_id: r.id,
    });
    setCancelling(false);

    const fmt = (n: number) => `$${Number(n).toLocaleString('es-MX')} ${payCurrency}`;
    const tier    = charge?.tier as string | undefined;
    const refund  = Number(charge?.refund_amount ?? 0);
    const retain  = Number(charge?.retain_amount ?? 0);

    // Copy del PORQUÉ (filosofía de producto: el grupo apartó la fecha)
    const whyCopy = charge?.is_express
      ? '\n\n💡 Esta fue una solicitud exprés (para hoy). El grupo se movilizó de inmediato dejando otras oportunidades — el cargo lo compensa por eso.'
      : '\n\n💡 ¿Por qué hay un cargo? Cuando el grupo aceptó tu evento, apartó esa fecha y dejó pasar otras oportunidades de tocar. Cancelarla le afecta — este cargo lo compensa por la fecha que reservó para ti.';

    const breakdownMsg = (() => {
      if (!charge?.ok) return '¿Estás seguro de cancelar esta reserva?';
      if (tier === 'not_paid') return 'No hay pago registrado. Se cancelará sin cargo.';
      if (tier === 'free') {
        return `Cancelas con más de 15 días de anticipación.\n\n✅ Reembolso completo: ${fmt(refund)}\nSin cargo.`;
      }
      const pct = (tier === 'partial_10') ? '10%' : '25%';
      const anticip = charge?.is_express
        ? 'Solicitud exprés'
        : (tier === 'partial_10') ? 'Cancelas entre 7 y 15 días antes'
        : 'Cancelas con menos de 7 días de anticipación';
      return `${anticip}.\n\n💰 Recuperas: ${fmt(refund)}\n📌 Se retiene ${pct} (${fmt(retain)}) como compensación al grupo y tarifa.` + whyCopy;
    })();

    // SPEI/efectivo con reembolso a recibir → pedimos CLABE para la
    // transferencia manual (Conekta solo reembolsa tarjeta por API)
    const needsBankData =
      r.payment_provider === 'conekta' &&
      ['spei', 'cash'].includes(String(r.payment_method_type ?? '')) &&
      !!charge?.ok && refund > 0;

    Alert.alert(
      'Cancelar reserva',
      breakdownMsg + '\n\n¿Confirmas la cancelación?',
      [
        { text: 'No', style: 'cancel' },
        {
          text: 'Sí, cancelar', style: 'destructive',
          onPress: () => {
            if (needsBankData) { setClabeOpen(true); return; }
            executeCancellation();
          },
        },
      ]
    );
  };

  // Ejecuta la cancelación (con datos bancarios si es reembolso manual).
  // El servidor recalcula el monto (tiers); el cliente no lo decide.
  // Idempotente por cancel-{id}: reintentar no duplica reembolso.
  const executeCancellation = async (bank?: { clabe: string; account_holder: string; bank_name: string }) => {
    const fmt = (n: number) => `$${Number(n).toLocaleString('es-MX')} ${payCurrency}`;
    setCancelling(true);
    const { data, error } = await supabase.functions.invoke('process-refund', {
      body: {
        reservation_id: r.id,
        mode: 'cancellation',
        ...(bank ? { clabe: bank.clabe, account_holder: bank.account_holder, bank_name: bank.bank_name } : {}),
      },
    });
    setCancelling(false);
    const failed = error || (data as any)?.error || (data as any)?.ok === false;
    if (failed) {
      const detail = (data as any)?.error ?? error?.message ?? 'Intenta de nuevo.';
      Alert.alert(
        'No se pudo cancelar',
        `${detail}\n\nSi ya se emitió el reembolso, reintentar no genera doble cargo.`,
        [
          { text: 'Cerrar', style: 'cancel' },
          { text: 'Reintentar', onPress: () => (bank ? executeCancellation(bank) : handleCancel()) },
        ],
      );
      return;
    }
    const b = (data as any)?.breakdown;
    const refundAmt = Number(b?.refund_amount ?? (data as any)?.amount ?? 0);
    if ((data as any)?.refund_mode === 'manual_pending') {
      Alert.alert(
        'Reserva cancelada',
        `Tu reembolso de ${fmt(refundAmt)} se enviará por transferencia bancaria${bank ? ` a tu cuenta terminación ${clabeLast4(bank.clabe)}` : ''} en un máximo de 5 días hábiles. Te avisaremos cuando esté enviado.`,
      );
    } else {
      Alert.alert(
        'Reserva cancelada',
        refundAmt > 0
          ? `Se emitió tu reembolso de ${fmt(refundAmt)}. Aparecerá en tu cuenta en 3-10 días hábiles.`
          : 'Tu reserva fue cancelada.',
      );
    }
    onUpdate();
  };

  // Estado del reembolso de una reserva cancelada (automático o manual)
  const viewRefundStatus = async () => {
    const fmt = (n: number) => `$${Number(n).toLocaleString('es-MX')} ${payCurrency}`;
    const { data: mr } = await supabase
      .from('manual_refunds')
      .select('amount, status, due_date, transfer_reference, receipt_path, clabe')
      .eq('reservation_id', r.id)
      .maybeSingle();

    if (!mr) {
      Alert.alert(
        'Reembolso',
        'Tu reembolso se emitió automáticamente a tu método de pago original. Aparece en tu cuenta en 3-10 días hábiles.',
      );
      return;
    }
    const dueTxt = new Date(mr.due_date + 'T12:00:00').toLocaleDateString('es-MX', { day: '2-digit', month: 'long' });
    if (mr.status === 'sent') {
      const openReceipt = async () => {
        if (!mr.receipt_path) return;
        const { data: signed } = await supabase.storage
          .from('refund-receipts')
          .createSignedUrl(mr.receipt_path, 3600);
        if (signed?.signedUrl) await WebBrowser.openBrowserAsync(signed.signedUrl);
        else Alert.alert('Comprobante', 'No se pudo abrir el comprobante. Intenta más tarde.');
      };
      Alert.alert(
        '✅ Reembolso enviado',
        `Enviamos ${fmt(Number(mr.amount))} por transferencia${mr.clabe ? ` a tu cuenta terminación ${String(mr.clabe).slice(-4)}` : ''}.` +
        (mr.transfer_reference ? `\n\nReferencia: ${mr.transfer_reference}` : ''),
        mr.receipt_path
          ? [{ text: 'Cerrar', style: 'cancel' }, { text: '📎 Ver comprobante', onPress: openReceipt }]
          : [{ text: 'Cerrar' }],
      );
    } else {
      Alert.alert(
        '💸 Reembolso en proceso',
        `Tu reembolso de ${fmt(Number(mr.amount))} se enviará por transferencia bancaria a más tardar el ${dueTxt}. Te avisaremos cuando esté enviado.`,
      );
    }
  };

  // Confirmación de datos bancarios del modal CLABE
  const submitClabe = () => {
    const clabe = normalizeClabe(clabeInput);
    const check = validateClabe(clabe);
    if (!check.valid) { Alert.alert('CLABE inválida', check.error); return; }
    const holder = holderInput.trim();
    if (holder.length < 5) { Alert.alert('Falta el titular', 'Escribe el nombre completo del titular de la cuenta.'); return; }
    const bank = (bankFromClabe(clabe) ?? bankInput.trim());
    if (!bank) { Alert.alert('Falta el banco', 'No reconocimos el banco de tu CLABE — escríbelo.'); return; }
    Alert.alert(
      'Confirma tu cuenta',
      `Tu reembolso se enviará a:\n\n${bank} · cuenta terminación ${clabeLast4(clabe)}\nTitular: ${holder}\n\n¿Es correcta?`,
      [
        { text: 'Revisar', style: 'cancel' },
        {
          text: 'Sí, cancelar reserva', style: 'destructive',
          onPress: () => {
            setClabeOpen(false);
            executeCancellation({ clabe, account_holder: holder, bank_name: bank });
          },
        },
      ],
    );
  };

  const isExpress = !!r.event_request_id;
  const typeLabel = isExpress ? '⚡ Express' : '📅 Programada';
  // Finalizados/cancelados: tarjeta COMPACTA — sin mapa, sin badge de pago,
  // sin botones grandes; solo resumen + acciones chicas (calificar/ticket/compartir)
  const mapCenter = showMap && !isFinished ? eventCardCenter(r) : null;
  // 🚐 Posición EN VIVO del grupo (mientras va en camino — group_update_transit
  // + realtime). Sin trayecto activo: su zona APROXIMADA (su ciudad), misma
  // semántica que el carrusel de cotizaciones. Verde = evento, foto = grupo.
  const transitPos = (!isFinished && r.group_en_route_at && !r.group_arrived_at
    && r.transit_lat != null && r.transit_lng != null)
    ? { latitude: r.transit_lat, longitude: r.transit_lng }
    : null;
  const groupApprox = transitPos
    ?? (mapCenter
      ? approxGroupLocation(r.group?.id ?? String(r.id), r.group?.city, r.group?.state, mapCenter)
      : null);

  return (
    <View style={[styles.card, isPast && { opacity: 0.5 }, isExpress && styles.cardExpress, isLive && styles.cardLive, isFinished && styles.cardFinished]}>
      {/* ── Banner EN VIVO ── */}
      {isLive && (
        <View style={styles.liveBanner}>
          <Animated.View style={[styles.liveDot, { opacity: pulseAnim }]} />
          <Text style={styles.liveBannerText}>EN VIVO AHORA</Text>
        </View>
      )}

      {/* ── 🚐 El grupo va en camino (tracking en vivo) ── */}
      {!isLive && transitPos && (
        <View style={styles.enRouteBanner}>
          <Animated.Text style={{ opacity: pulseAnim, fontSize: 14 }}>🚐</Animated.Text>
          <Text style={styles.enRouteBannerText}>
            ¡{r.group?.name ?? 'Tu grupo'} va en camino! Míralo acercarse en el mapa
          </Text>
        </View>
      )}

      {/* ── Mapa de zona (estilo ExpressCard) — folio discreto encima ── */}
      {mapCenter && (
        <View style={{ position: 'relative' }}>
          <RequestZoneMap
            mapId={String(r.id)} center={mapCenter} typeLabel={typeLabel}
            userLocation={groupApprox} groupPhotoUrl={r.group?.profile_image ?? null}
          />
          {r.folio && (
            <View style={styles.folioOnMap}>
              <Text style={styles.folioOnMapText}>{r.folio}</Text>
            </View>
          )}
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
          {/* Avatar del grupo + Ver perfil debajo */}
          <View style={styles.avatarCol}>
            {r.group?.profile_image ? (
              <Image source={{ uri: r.group.profile_image }} style={styles.groupAvatar} />
            ) : (
              <View style={styles.groupAvatarPlaceholder}>
                <Text style={styles.groupAvatarInitial}>
                  {(r.group?.name ?? 'G').charAt(0).toUpperCase()}
                </Text>
              </View>
            )}
            {r.group?.id && (
              <Pressable
                onPress={(e: any) => { e.stopPropagation?.(); navigation.navigate('GroupDetail', { group: r.group }); }}
                hitSlop={8}
                style={({ pressed }: any) => pressed && { opacity: 0.6 }}
              >
                <Text style={styles.profileLinkText}>Ver perfil ›</Text>
              </Pressable>
            )}
          </View>
          <View style={styles.cardLeft}>
            <Text style={styles.groupName}>{r.group?.name ?? 'Grupo'}</Text>
            {/* Tipo de evento solo en programadas (en express el mapa ya lo dice) */}
            {!isExpress && (
              <Text style={styles.packageName}>{r.quote?.event_type ?? 'Cotización'}</Text>
            )}
          </View>
          <View style={{ alignItems: 'flex-end', gap: 6 }}>
            <Badge label={s.label} variant={s.variant} dot />
            {!mapCenter && (
              <View style={[styles.expressBadge, !isExpress && { borderColor: 'rgba(0,230,118,0.30)' }]}>
                <Text style={styles.expressBadgeText}>{typeLabel}</Text>
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
            <Text style={styles.price}>${r.total_price?.toLocaleString()} {payCurrency}</Text>
          </View>
        </View>

        {/* Folio — vive dentro del mapa; aquí solo cuando NO hay mapa (centrado) */}
        {r.folio && !mapCenter && (
          <Text style={[styles.folioText, { textAlign: 'center' }]}>{r.folio}</Text>
        )}

        {/* Payment status badge — con el MÉTODO de pago (Tarjeta/SPEI/Efectivo/Meses) */}
        {isPaidReservation && r.status !== 'completed' && (
          <View style={[styles.paidBadge, { backgroundColor: 'rgba(0,230,118,0.12)', borderColor: COLORS.green }]}>
            <Text style={[styles.paidBadgeText, { color: COLORS.green }]}>
              ✅ Pagado{(() => {
                if ((r.msi_months ?? 0) > 1) return ` · 📅 ${r.msi_months} meses`;
                switch (r.payment_method_type) {
                  case 'card': return ' · 💳 Tarjeta';
                  case 'spei': return ' · 🏦 SPEI';
                  case 'cash': return ' · 🏪 Efectivo';
                }
                if (r.payment_provider === 'stripe') return ' · 💳 Tarjeta';
                return '';
              })()}
            </Text>
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

      {/* Ver evento / EN VIVO — los finalizados abren el resumen tocando la tarjeta */}
      {(isPaidReservation || isLive || r.status === 'accepted' || r.status === 'confirmed') && !isFinished && (
        <Pressable
          style={[styles.timerBtn, isLive && styles.timerBtnLive]}
          onPress={() => navigation.navigate('EventTimer', { reservation: r, readOnly: true, userRole: 'client' })}
        >
          <Text style={[styles.timerBtnText, isLive && styles.timerBtnTextLive]}>
            {isLive
              ? '🔴 Ver evento en vivo'
              : isPaidReservation
                ? '🕐 Ver temporizador del evento'
                : '📅 Ver detalles del evento'}
          </Text>
        </Pressable>
      )}

      {/* Ver ticket — visible siempre que hubo pago, salvo en completadas
          (ahí vive como chip compacto); una cancelada-pagada lo necesita
          como comprobante durante el reembolso/disputa */}
      {isPaidReservation && r.folio && r.status !== 'completed' && (
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

      {/* ── Botón Pagar — blanco, letras negras, precio verde ── */}
      {canPay && (
        <Pressable
          style={({ pressed }) => [styles.payBtn, pressed && styles.payBtnPressed]}
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
            <Animated.View style={[styles.payBtnIconCircle, { transform: [{ scale: payPulse }] }]}>
              <CreditCard size={15} color="#4285F4" />
            </Animated.View>
            <View style={{ flex: 1 }}>
              <Text style={styles.payBtnText}>{payLabel}</Text>
              <Text style={styles.payBtnSub}>Elige tu forma de pago al confirmar</Text>
            </View>
            <Text style={styles.payBtnPrice}>${r.total_price?.toLocaleString()} {payCurrency}</Text>
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
      {/* ── Modal CLABE — reembolso manual SPEI/efectivo ── */}
      <Modal visible={clabeOpen} transparent animationType="slide" onRequestClose={() => setClabeOpen(false)}>
        <KeyboardAvoidingView
          style={styles.rescheduleOverlay}
          behavior={Platform.OS === 'ios' ? 'padding' : 'height'}
        >
          <View style={styles.rescheduleSheet}>
            <View style={styles.rescheduleHeader}>
              <Text style={styles.rescheduleTitle}>¿A qué cuenta te reembolsamos?</Text>
              <Pressable onPress={() => setClabeOpen(false)} hitSlop={8}>
                <X size={20} color={COLORS.muted2} />
              </Pressable>
            </View>
            <Text style={styles.clabeHint}>
              Pagaste por {r.payment_method_type === 'cash' ? 'efectivo' : 'transferencia'}, así que tu
              reembolso se envía por transferencia bancaria en un máximo de 5 días hábiles.
            </Text>
            <Text style={styles.clabeLabel}>CLABE (18 dígitos)</Text>
            <TextInput
              style={styles.clabeInput}
              value={clabeInput}
              onChangeText={(t) => { setClabeInput(normalizeClabe(t).slice(0, 18)); }}
              keyboardType="number-pad"
              maxLength={18}
              placeholder="000000000000000000"
              placeholderTextColor={COLORS.muted}
            />
            {normalizeClabe(clabeInput).length >= 3 && (
              <Text style={styles.clabeBankDetected}>
                {bankFromClabe(clabeInput)
                  ? `🏦 ${bankFromClabe(clabeInput)}`
                  : 'Banco no reconocido — escríbelo abajo'}
              </Text>
            )}
            {!bankFromClabe(clabeInput) && normalizeClabe(clabeInput).length >= 3 && (
              <>
                <Text style={styles.clabeLabel}>Banco</Text>
                <TextInput
                  style={styles.clabeInput}
                  value={bankInput}
                  onChangeText={setBankInput}
                  placeholder="Nombre de tu banco"
                  placeholderTextColor={COLORS.muted}
                />
              </>
            )}
            <Text style={styles.clabeLabel}>Nombre completo del titular</Text>
            <TextInput
              style={styles.clabeInput}
              value={holderInput}
              onChangeText={setHolderInput}
              placeholder="Como aparece en tu cuenta"
              placeholderTextColor={COLORS.muted}
              autoCapitalize="words"
            />
            <Pressable
              style={[styles.clabeSubmitBtn, cancelling && { opacity: 0.5 }]}
              onPress={submitClabe}
              disabled={cancelling}
            >
              {cancelling
                ? <ActivityIndicator size="small" color="#000" />
                : <Text style={styles.clabeSubmitTx}>Confirmar y cancelar reserva</Text>}
            </Pressable>
          </View>
        </KeyboardAvoidingView>
      </Modal>

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

      {/* ── Reserva cancelada con pago: estado del reembolso VISIBLE ── */}
      {r.status === 'cancelled' && !r._isQuote && !!r.mp_payment_id && (
        <Pressable style={styles.refundStrip} onPress={viewRefundStatus}>
          {refundInfo?.status === 'sent' ? (
            <>
              <Text style={styles.refundStripEmoji}>✅</Text>
              <Text style={[styles.refundStripText, { color: COLORS.green }]}>
                {refundInfo.receipt_path
                  ? 'Reembolso enviado — toca para ver el comprobante'
                  : 'Reembolso enviado — toca para ver el detalle'}
              </Text>
            </>
          ) : refundInfo ? (
            <>
              <Text style={styles.refundStripEmoji}>💸</Text>
              <Text style={[styles.refundStripText, { color: COLORS.orange }]}>
                Reembolso en camino — a más tardar el {new Date(refundInfo.due_date + 'T12:00:00').toLocaleDateString('es-MX', { day: '2-digit', month: 'short' })}
              </Text>
            </>
          ) : (
            <>
              <Text style={styles.refundStripEmoji}>💸</Text>
              <Text style={[styles.refundStripText, { color: COLORS.muted2 }]}>
                Reembolso emitido a tu método de pago (3-10 días hábiles)
              </Text>
            </>
          )}
        </Pressable>
      )}

      {/* 🕐 Registro de horarios (petición del usuario 2026-09-10) — cuándo
          inició y terminó, para cualquier categoría (temporizador o código). */}
      {r.status === 'completed' && r.event_started_at && r.event_ended_at && (
        <Text style={styles.scheduleRecordText}>
          🕐 Inició: {new Date(r.event_started_at).toLocaleTimeString('es-MX', { hour: 'numeric', minute: '2-digit' })}
          {' · '}
          Terminó: {new Date(r.event_ended_at).toLocaleTimeString('es-MX', { hour: 'numeric', minute: '2-digit' })}
        </Text>
      )}

      {/* ── Acciones compactas del evento finalizado ── */}
      {r.status === 'completed' && !r._isQuote && (
        <View style={styles.completedActions}>
          {isReviewed ? (
            <Text style={styles.ratedText}>⭐ Calificado</Text>
          ) : (
            <Pressable
              style={styles.rateBtn}
              onPress={() => onRate?.(r.id, r.group?.name ?? 'el grupo')}
            >
              <Star size={13} color={COLORS.gold} fill={COLORS.gold} />
              <Text style={styles.rateBtnText}>{t('reservations.rate_title')}</Text>
            </Pressable>
          )}
          {isPaidReservation && r.folio && (
            <Pressable
              style={styles.shareBtn}
              onPress={() => navigation.navigate('Ticket', { reservation: r })}
            >
              <Text style={styles.shareBtnText}>🎟 Ticket</Text>
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
            <Share2 size={13} color={COLORS.muted2} />
            <Text style={styles.shareBtnText}>Compartir</Text>
          </Pressable>
          {/* ⚠️ Reportar un problema → abre disputa (open_dispute, sql/483):
              bloquea la liberación del pago y notifica a grupo + admin */}
          {isPaidReservation && ['in_progress', 'completed'].includes(r.status) && (
            <Pressable
              style={styles.shareBtn}
              onPress={() => {
                const send = (reason: string) => {
                  Alert.alert(
                    '⚠️ Abrir un reporte',
                    `Motivo: ${reason}\n\nEl pago del evento queda en pausa mientras Daricefy revisa el caso con la evidencia del temporizador (llegada GPS, inicio con tu PIN, descansos y duración). ¿Confirmas?`,
                    [
                      { text: 'Cancelar', style: 'cancel' },
                      {
                        text: 'Sí, reportar', style: 'destructive',
                        onPress: async () => {
                          const { data, error } = await supabase.rpc('open_dispute', {
                            p_reservation_id: r.id,
                            p_reason: reason,
                          });
                          if (error || (data as any)?.ok === false) {
                            Alert.alert('No se pudo reportar', error?.message ?? 'Intenta de nuevo.');
                            return;
                          }
                          Alert.alert(
                            'Reporte enviado',
                            'El grupo y el equipo de Daricefy fueron notificados. Te contactaremos con la resolución.',
                          );
                        },
                      },
                    ],
                  );
                };
                Alert.alert('⚠️ Reportar un problema', '¿Qué pasó con tu evento?', [
                  { text: 'El grupo no cumplió lo acordado', onPress: () => send('El grupo no cumplió lo acordado') },
                  { text: 'Problema con el tiempo tocado',   onPress: () => send('Problema con el tiempo/duración tocada') },
                  { text: 'Otro problema',                   onPress: () => send('Otro problema — contactar al cliente') },
                  { text: 'Cancelar', style: 'cancel' },
                ]);
              }}
            >
              <Text style={styles.reportBtnText}>⚠️ Reportar</Text>
            </Pressable>
          )}
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

  // ── "Mi evento" (sql/585, Fase 1C, rediseñado 2026-09-02) — encabezado
  // ligero antes de la primera reserva de cada event_id, SIN duplicar
  // precio/estado (eso ya lo muestra la ReservationCard de abajo).
  eventGroupHeader: {
    gap: 12,
    backgroundColor: COLORS.card2,
    borderRadius: RADIUS.lg,
    borderWidth: 1,
    borderColor: 'rgba(0,230,118,0.25)',
    padding: 14,
  },
  // Renglón 1: título/fecha/dirección + lápiz. El lápiz se queda arriba a la
  // derecha (fácil de encontrar) sin robarle ancho al botón de abajo.
  eventGroupHeaderTop: {
    flexDirection: 'row', alignItems: 'flex-start', gap: 10,
  },
  // ── CTA "Arma tu fiesta" (Fase 2) ─────────────────────────────────────────
  ctaCard: {
    flexDirection: 'row', alignItems: 'center', gap: 12,
    backgroundColor: COLORS.card2, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.35)',
    padding: 14,
  },
  ctaCardBig: { padding: 18, marginBottom: 8 },
  ctaIcon: {
    width: 40, height: 40, borderRadius: RADIUS.full,
    backgroundColor: 'rgba(0,230,118,0.12)',
    alignItems: 'center', justifyContent: 'center',
  },
  ctaTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 14.5, color: COLORS.text },
  ctaText:  { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, marginTop: 2, lineHeight: 17 },

  eventGroupHeaderTitleRow: { flexDirection: 'row', alignItems: 'center', gap: 6 },
  eventGroupHeaderTitle: { flex: 1, fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.text },
  eventGroupHeaderAddress: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, marginTop: 2 },
  eventGroupHeaderAddBtn: {
    flexDirection: 'row', alignItems: 'center', gap: 5,
    backgroundColor: 'rgba(0,230,118,0.12)', borderRadius: RADIUS.full,
    paddingHorizontal: 12, paddingVertical: 8,
    // Mismo pill de siempre; solo se ancla a la izquierda en su propio renglón
    // en vez de estirarse a todo el ancho.
    alignSelf: 'flex-start',
  },
  eventGroupHeaderAddBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 12, color: COLORS.green },
  // sql/685 — lápiz para capturar/editar los datos básicos del evento. Gris a
  // propósito: la acción principal del encabezado sigue siendo "Agregar otro
  // proveedor" (verde), esta es secundaria.
  eventGroupHeaderEditBtn: {
    width: 32, height: 32, borderRadius: RADIUS.full,
    alignItems: 'center', justifyContent: 'center',
    backgroundColor: COLORS.card, borderWidth: 1, borderColor: COLORS.border,
  },

  // ── Card ──
  // Cascarón estilo ExpressCard: fondo oscuro + borde verde fino; el mapa
  // de zona (RequestZoneMap) entra arriba gracias al overflow hidden
  card: {
    backgroundColor: '#060c06',
    borderRadius: 20,
    borderWidth: 1,
    borderColor: 'rgba(0,230,118,0.35)',
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
    backgroundColor: '#FFFFFF',
    paddingVertical: 11, paddingHorizontal: SPACING.md,
    marginHorizontal: 12, marginBottom: 12, borderRadius: RADIUS.full,
    shadowColor: '#00E676', shadowOpacity: 0.35, shadowRadius: 10, shadowOffset: { width: 0, height: 3 },
    elevation: 5,
  },
  payBtnPressed: { transform: [{ scale: 0.97 }], opacity: 0.9 },
  payBtnInner: { flexDirection: 'row', alignItems: 'center', gap: 10 },
  payBtnIconCircle: {
    width: 32, height: 32, borderRadius: 16,
    backgroundColor: 'rgba(66,133,244,0.14)',
    alignItems: 'center', justifyContent: 'center',
  },
  payBtnText:  { fontFamily: FONTS.bodySemiBold, fontSize: 13.5, color: '#000' },
  payBtnSub:   { fontFamily: FONTS.body, fontSize: 10, color: 'rgba(0,0,0,0.55)', marginTop: 1 },
  payBtnPrice: { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.green2, fontVariant: ['tabular-nums'] },

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
    marginTop: 16,
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
  supportFooter:     { alignSelf: 'center', marginTop: 24, marginBottom: 8, paddingVertical: 8, paddingHorizontal: 14 },
  supportFooterText: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted2, textDecorationLine: 'underline' },
  policyFooter:      { alignSelf: 'center', marginBottom: 12, paddingVertical: 4, paddingHorizontal: 14 },
  policyFooterText:  { fontFamily: FONTS.body, fontSize: 11.5, color: COLORS.muted, textDecorationLine: 'underline' },
  guideFooterText:   { fontFamily: FONTS.bodySemiBold, fontSize: 12.5, color: COLORS.green, textDecorationLine: 'underline' },

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
  // 🚐 En camino
  enRouteBanner: {
    flexDirection: 'row', alignItems: 'center', gap: 8,
    backgroundColor: 'rgba(0,230,118,0.12)',
    paddingVertical: 7, paddingHorizontal: 12,
    borderBottomWidth: 1, borderBottomColor: 'rgba(0,230,118,0.35)',
  },
  enRouteBannerText: { fontFamily: FONTS.bodySemiBold, fontSize: 12, color: COLORS.green, flex: 1 },
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
  quoteDate:      { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted },
  quoteGroup:     { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.text, marginBottom: 6 },
  quoteInfo:      { flexDirection: 'row', gap: 14, marginBottom: 8 },
  quoteInfoText:  { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2 },
  quotePriceRow:  { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center', backgroundColor: 'rgba(66,133,244,0.1)', borderRadius: RADIUS.md, paddingHorizontal: 10, paddingVertical: 8, marginBottom: 8 },
  quotePriceLabel:{ fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.blue },
  quotePriceVal:  { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.blue },
  quoteCta:       { fontFamily: FONTS.bodySemiBold, fontSize: 12, color: COLORS.green, textAlign: 'right' },
  pendSectionTitle: {
    fontFamily: FONTS.bodySemiBold, fontSize: 12, color: COLORS.muted2,
    textTransform: 'uppercase', letterSpacing: 0.6, marginBottom: 2,
  },

  cardExpress: {
    borderColor: `${COLORS.green}40`,
  },
  cardFinished: {
    borderColor: 'rgba(255,255,255,0.10)',   // finalizados sobrios, sin borde verde
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
  scheduleRecordText: { fontFamily: FONTS.body, fontSize: 11.5, color: COLORS.muted2, marginBottom: 6 },

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
  reportBtnText: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: '#EF5350' },

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

  // ── Modal CLABE (reembolso manual) ──
  clabeHint: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2, marginBottom: 14, lineHeight: 18 },
  clabeLabel: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.muted2, marginBottom: 6, marginTop: 4 },
  clabeInput: {
    backgroundColor: COLORS.card2, borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: COLORS.border,
    paddingHorizontal: 14, paddingVertical: 12, marginBottom: 10,
    fontFamily: FONTS.bodyMedium, fontSize: 15, color: COLORS.text, letterSpacing: 1,
  },
  clabeBankDetected: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.green, marginBottom: 8 },
  clabeSubmitBtn: {
    backgroundColor: COLORS.green, borderRadius: RADIUS.lg,
    paddingVertical: 15, alignItems: 'center', marginTop: 8,
  },
  clabeSubmitTx: { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: '#000' },

  // Franja de estado del reembolso (reservas canceladas)
  refundStrip: {
    flexDirection: 'row', alignItems: 'center', gap: 8,
    marginHorizontal: 14, marginBottom: 12, marginTop: 2,
    backgroundColor: 'rgba(255,255,255,0.04)', borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: 'rgba(255,255,255,0.08)',
    paddingHorizontal: 12, paddingVertical: 10,
  },
  refundStripEmoji: { fontSize: 14 },
  refundStripText:  { fontFamily: FONTS.bodyMedium, fontSize: 12, flex: 1, lineHeight: 16 },

  // Avatar + "Ver perfil" debajo
  avatarCol:       { alignItems: 'center', gap: 4 },
  profileLinkText: { fontFamily: FONTS.bodySemiBold, fontSize: 10.5, color: COLORS.green },

  // Folio discreto dentro del mapa (abajo a la izquierda)
  folioOnMap: {
    position: 'absolute', bottom: 8, left: 8,
    backgroundColor: 'rgba(0,0,0,0.55)', borderRadius: RADIUS.full,
    paddingHorizontal: 8, paddingVertical: 3,
    borderWidth: 1, borderColor: 'rgba(255,255,255,0.12)',
  },
  folioOnMapText: { fontFamily: FONTS.bodyMedium, fontSize: 9.5, color: 'rgba(255,255,255,0.8)', letterSpacing: 0.5 },
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
