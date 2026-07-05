/**
 * ScheduledQuotesCarousel — TODO lo programado entrante del grupo
 * (cotizaciones directas Y solicitudes abiertas con fecha futura), como
 * sheet deslizante ENCIMA del dashboard, idéntico al carrusel exprés:
 * tarjeta oscura con mapa (chip 📅 PROGRAMADA) + ruta con instrumentos,
 * foto del cliente + "Ver perfil ›", stats y Detalles / Cotizar.
 *
 * Montado globalmente junto a ExpressCarousel (GroupRoot). Se abre:
 *  - solo, cuando llega algo nuevo (realtime INSERT en quotes/event_requests)
 *  - imperativamente con openScheduledQuotes() desde el banner 📅 del
 *    dashboard y las notificaciones "📋 Nueva solicitud de cotización" /
 *    "📅 Nueva solicitud programada disponible"
 */
import React, { useCallback, useEffect, useRef, useState } from 'react';
import {
  Animated,
  Dimensions,
  Easing,
  FlatList,
  Image,
  Pressable,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import * as Location from 'expo-location';
import { Clock, MapPin, Users, X, Zap } from 'lucide-react-native';
import { useNavigation } from '@react-navigation/native';
import { supabase } from '../../config/supabase';
import { COLORS, FONTS, RADIUS } from '../../config/theme';
import RequestZoneMap, { EVENT_LABELS, fmtDate } from './RequestZoneMap';
import ClientProfileModal from './ClientProfileModal';
import RequestDetailsModal from './RequestDetailsModal';
import { setExpressCarouselCollapsed } from '../express/ExpressCarousel';
import { estimateEtaMin, eventCardCenter, formatDist, formatEta, haversineKm } from '../../utils/mapUtils';

const { width: W, height: H } = Dimensions.get('window');
const CARD_WIDTH    = Math.round(W * 0.86);
const LIST_PADDING  = Math.round((W - CARD_WIDTH) / 2);
const CARD_GAP      = 12;
const SNAP_INTERVAL = CARD_WIDTH + CARD_GAP;
const SHEET_HEIGHT  = Math.round(H * 0.72);
const ABOVE_HEIGHT  = H - SHEET_HEIGHT;

// ── Imperativo: dashboard/notificaciones pueden abrir el carrusel ─────────────
// Con cola: si se llama antes de que el carrusel monte o de que groupId
// cargue (tap de notificación en arranque en frío), se guarda y se ejecuta
// en cuanto esté listo.
let _openScheduled: ((quoteId?: string) => void) | null = null;
let _queuedOpen: { id?: string } | null = null;
export function openScheduledQuotes(quoteId?: string) {
  // Idempotente por estado (show() no reinicia si ya está visible) — sin
  // debounce por tiempo: una segunda apertura legítima siempre funciona
  if (_openScheduled) {
    _openScheduled(quoteId);
  } else {
    _queuedOpen = { id: quoteId };
  }
}

function fmtTime12h(t?: string | null): string | null {
  if (!t) return null;
  const [hStr, mStr] = t.substring(0, 5).split(':');
  const h = parseInt(hStr, 10);
  return `${h % 12 || 12}:${mStr} ${h >= 12 ? 'PM' : 'AM'}`;
}

// ── Forma común de tarjeta para ambos orígenes ────────────────────────────────
// kind 'quote'   = cotización directa (tabla quotes)   → Cotizar: GroupQuoteDetail
// kind 'request' = solicitud abierta (event_requests)  → Cotizar: ProposeRequest
function normalizeQuote(q: any) {
  return {
    kind: 'quote' as const,
    id: q.id,
    client_id: q.client_id,
    clientName: q.client?.full_name ?? 'Cliente',
    clientAvatar: q.client?.avatar_url ?? null,
    subtitle: 'Cotización programada',
    event_type: q.event_type,
    event_date: q.event_date,
    event_time: q.event_time,
    hours: q.duration_hours,
    personas: q.num_personas,
    zona: [q.event_municipio, q.event_estado].filter(Boolean).join(', '),
    details: {
      event_type: q.event_type, event_date: q.event_date, event_time: q.event_time,
      hours: q.duration_hours, guest_count: q.num_personas,
      location_city: q.event_municipio, location_estado: q.event_estado,
      venue_covered: q.venue_covered, venue_size: q.venue_size,
      needs_sound: q.needs_sound, comments: q.comments,
    },
    raw: q,
  };
}

function normalizeRequest(r: any) {
  return {
    kind: 'request' as const,
    id: r.id,
    client_id: r.client_id,
    clientName: r.requester?.full_name ?? 'Cliente',
    clientAvatar: r.requester?.avatar_url ?? null,
    subtitle: 'Solicitud programada',
    event_type: r.event_type,
    event_date: r.event_date,
    event_time: r.event_time,
    hours: r.hours,
    personas: r.guest_count,
    zona: [r.location_municipio ?? r.location_city, r.location_estado].filter(Boolean).join(', '),
    details: {
      event_type: r.event_type, genre: r.genre, event_date: r.event_date, event_time: r.event_time,
      hours: r.hours, guest_count: r.guest_count,
      location_city: r.location_city, location_estado: r.location_estado,
      venue_covered: r.venue_covered, venue_size: r.venue_size,
      needs_sound: r.needs_sound, comments: r.comments,
    },
    raw: r,
  };
}

// ── Tarjeta — mismo lenguaje visual que ExpressCard ──────────────────────────
function ScheduledQuoteCard({
  item, userLocation, groupPhotoUrl, onCotizar, onViewProfile,
}: any) {
  const [detailsOpen, setDetailsOpen] = useState(false);
  const center = eventCardCenter(item.raw);
  const distKm = userLocation && center
    ? haversineKm(userLocation.latitude, userLocation.longitude, center.latitude, center.longitude)
    : null;
  const time12 = fmtTime12h(item.event_time);

  return (
    <View style={s.card}>
      {center && (
        <RequestZoneMap
          mapId={String(item.id)} center={center} typeLabel="📅 Programada"
          userLocation={userLocation} groupPhotoUrl={groupPhotoUrl}
        />
      )}

      <View style={s.body}>
        {/* Cliente — foto + Ver perfil, como ExpressCard */}
        <View style={s.clientRow}>
          {item.clientAvatar
            ? <Image source={{ uri: item.clientAvatar }} style={s.clientAvatar} />
            : (
              <View style={s.clientAvatarPh}>
                <Text style={s.clientAvatarInitial}>
                  {(item.clientName ?? '?').charAt(0).toUpperCase()}
                </Text>
              </View>
            )
          }
          <View style={{ flex: 1 }}>
            <Text style={s.clientName} numberOfLines={1}>{item.clientName}</Text>
            <Text style={s.clientCity} numberOfLines={1}>{item.subtitle}</Text>
          </View>
          <Pressable
            onPress={onViewProfile}
            hitSlop={8}
            style={({ pressed }) => [s.viewProfileBtn, pressed && { opacity: 0.6 }]}
          >
            <Text style={s.viewProfileTx}>Ver perfil ›</Text>
          </Pressable>
        </View>

        <Text style={s.eventType} numberOfLines={1}>
          {EVENT_LABELS[item.event_type ?? ''] ?? 'Evento'}
        </Text>
        <Text style={s.cityTx} numberOfLines={1}>
          {item.zona || 'Zona por confirmar'}
        </Text>

        {/* Stats — misma fila que ExpressCard */}
        <View style={s.statsRow}>
          <View style={s.stat}>
            <Text style={s.statVal}>{item.hours ?? '—'}</Text>
            <Text style={s.statLbl}>hrs</Text>
          </View>
          <View style={s.statDiv} />
          <View style={s.stat}>
            <Text style={s.statVal} numberOfLines={1}>{item.event_date ? fmtDate(item.event_date) : '—'}</Text>
            <Text style={s.statLbl}>fecha</Text>
          </View>
          {time12 ? (
            <>
              <View style={s.statDiv} />
              <View style={s.stat}>
                <Text style={s.statVal}>{time12}</Text>
                <Text style={s.statLbl}>hora</Text>
              </View>
            </>
          ) : null}
          {item.personas ? (
            <>
              <View style={s.statDiv} />
              <View style={s.stat}>
                <View style={{ flexDirection: 'row', alignItems: 'center', gap: 3 }}>
                  <Users size={10} color={COLORS.muted2} />
                  <Text style={s.statVal}>{item.personas}</Text>
                </View>
                <Text style={s.statLbl}>personas</Text>
              </View>
            </>
          ) : null}
          {distKm != null && (
            <>
              <View style={s.statDiv} />
              <View style={s.stat}>
                <View style={{ flexDirection: 'row', alignItems: 'center', gap: 3 }}>
                  <MapPin size={10} color={COLORS.muted2} />
                  <Text style={s.statVal}>{formatDist(distKm)}</Text>
                </View>
                <Text style={s.statLbl}>de ti</Text>
              </View>
              <View style={s.statDiv} />
              <View style={s.stat}>
                <View style={{ flexDirection: 'row', alignItems: 'center', gap: 3 }}>
                  <Clock size={10} color={COLORS.muted2} />
                  <Text style={s.statVal}>{formatEta(estimateEtaMin(distKm))}</Text>
                </View>
                <Text style={s.statLbl}>llegada</Text>
              </View>
            </>
          )}
        </View>

        <View style={s.actions}>
          <Pressable onPress={() => setDetailsOpen(true)} hitSlop={8}
            style={({ pressed }) => [s.btnOutline, pressed && { opacity: 0.6 }]}>
            <Text style={s.btnOutlineTx}>Detalles</Text>
          </Pressable>
          <Pressable onPress={onCotizar}
            style={({ pressed }) => [s.btnPrimary, pressed && { opacity: 0.82 }]}>
            <Zap size={12} color={COLORS.bg} />
            <Text style={s.btnPrimaryTx}>Cotizar</Text>
          </Pressable>
        </View>
      </View>

      <RequestDetailsModal
        request={detailsOpen ? item.details : null}
        onClose={() => setDetailsOpen(false)}
        onCotizar={() => { setDetailsOpen(false); onCotizar(); }}
      />
    </View>
  );
}

// ── Carrusel overlay ──────────────────────────────────────────────────────────
export default function ScheduledQuotesCarousel({ groupId }: { groupId: string | null }) {
  const navigation = useNavigation<any>();

  const [visible,     setVisible]     = useState(false);
  const [quotes,      setQuotes]      = useState<any[]>([]);
  const [highlightId, setHighlightId] = useState<string | null>(null);
  const [userLocation,    setUserLocation]    = useState<{ latitude: number; longitude: number } | null>(null);
  const [groupPhotoUrl,   setGroupPhotoUrl]   = useState<string | null>(null);
  const [groupGenre,      setGroupGenre]      = useState<string | null>(null);
  const [profileClientId, setProfileClientId] = useState<string | null>(null);

  const dismissedRef = useRef<Set<string>>(new Set());
  const visibleRef   = useRef(false);
  const slideAnim    = useRef(new Animated.Value(SHEET_HEIGHT)).current;
  const dimAnim      = useRef(new Animated.Value(0)).current;

  // Autocuración: el ref sigue SIEMPRE al estado real — si una animación se
  // interrumpe y visible queda en false, el ref se libera y el siguiente
  // open vuelve a funcionar (nada se queda trabado)
  useEffect(() => { visibleRef.current = visible; }, [visible]);

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
  }, []);

  // Foto + género del grupo, UNA vez por sesión (el género filtra el realtime
  // y las solicitudes abiertas; antes se consultaba en cada fetch)
  useEffect(() => {
    if (!groupId) return;
    supabase.from('groups').select('genre, profile_image').eq('id', groupId).single()
      .then(({ data: g }) => {
        if (g?.profile_image) setGroupPhotoUrl(g.profile_image);
        setGroupGenre(g?.genre ?? null);
      });
  }, [groupId]);

  const fetchPending = useCallback(async (): Promise<any[]> => {
    if (!groupId) return [];

    const [{ data: qs }, { data: reqs }, { data: myProps }] = await Promise.all([
      // Cotizaciones directas pendientes de responder
      supabase
        .from('quotes')
        .select('*, client:profiles!client_id(full_name, avatar_url)')
        .eq('group_id', groupId)
        .eq('status', 'pending')
        .order('created_at', { ascending: false }),
      // Solicitudes abiertas programadas del género del grupo, vigentes
      groupGenre
        ? supabase
            .from('event_requests')
            .select('*, requester:profiles!client_id(full_name, avatar_url)')
            .in('status', ['open', 'en_negociacion'])
            .eq('genre', groupGenre)
            .gt('expires_at', new Date().toISOString())
            .order('created_at', { ascending: false })
        : Promise.resolve({ data: [] as any[] } as any),
      // Solicitudes donde ya envié propuesta (no volver a mostrar)
      supabase
        .from('event_request_proposals')
        .select('request_id')
        .eq('group_id', groupId),
    ]);

    const proposed = new Set((myProps ?? []).map((p: any) => p.request_id));
    const openReqs = (reqs ?? []).filter((r: any) => {
      const isExpress = r.is_express === true || r.is_express === 'true';
      return !isExpress && !proposed.has(r.id);
    });

    return [
      ...(qs ?? []).map(normalizeQuote),
      ...openReqs.map(normalizeRequest),
    ];
  }, [groupId, groupGenre]);

  const show = useCallback(() => {
    // Ya visible → no reiniciar la animación (evita el parpadeo/cierre visual)
    if (visibleRef.current) return;
    visibleRef.current = true;
    setVisible(true);
    slideAnim.setValue(SHEET_HEIGHT);
    Animated.parallel([
      Animated.spring(slideAnim, { toValue: 0, tension: 65, friction: 11, useNativeDriver: true }),
      Animated.timing(dimAnim,   { toValue: 1, duration: 300, useNativeDriver: true }),
    ]).start();
  }, [slideAnim, dimAnim]);

  const hide = useCallback(() => {
    Animated.parallel([
      Animated.timing(slideAnim, { toValue: SHEET_HEIGHT, duration: 340, easing: Easing.in(Easing.cubic), useNativeDriver: true }),
      Animated.timing(dimAnim,   { toValue: 0, duration: 280, useNativeDriver: true }),
    ]).start(() => {
      visibleRef.current = false;
      setVisible(false);
    });
  }, [slideAnim, dimAnim]);

  // Repliegue del carrusel exprés AUTOCURADO: sigue al estado real de este
  // sheet (visible Y con tarjetas). Si la lista se vacía por un refresh, el
  // sheet se cierra de verdad y el exprés regresa solo — nada puede quedarse
  // replegado por una animación interrumpida. También libera al desmontar.
  useEffect(() => {
    const count = quotes.filter(q => !dismissedRef.current.has(q.id)).length;
    const active = visible && count > 0;
    setExpressCarouselCollapsed(active);
    if (visible && count === 0) {
      visibleRef.current = false;
      setVisible(false);
    }
  }, [visible, quotes]);

  useEffect(() => () => setExpressCarouselCollapsed(false), []);

  // Apertura imperativa (banner del dashboard / notificación).
  // Si groupId aún no carga, se encola y se reintenta cuando esté listo.
  const pendingOpenRef = useRef<{ id?: string } | null>(null);

  useEffect(() => {
    _openScheduled = async (quoteId?: string) => {
      if (!groupId) {
        pendingOpenRef.current = { id: quoteId };
        console.log('[Programadas] open encolado — groupId aún no carga');
        return;
      }
      dismissedRef.current = new Set();   // reabrir muestra todas
      const rows = await fetchPending();
      console.log('[Programadas] open — items:', rows.length, 'highlight:', quoteId ?? '—');
      setQuotes(rows);
      setHighlightId(quoteId ?? null);
      if (rows.length > 0) show();
    };
    // Consumir aperturas encoladas (tap antes del mount o antes de groupId)
    const queued = _queuedOpen ?? pendingOpenRef.current;
    if (queued && groupId) {
      _queuedOpen = null;
      pendingOpenRef.current = null;
      void _openScheduled(queued.id);
    }
    return () => { _openScheduled = null; };
  }, [groupId, fetchPending, show]);

  // Realtime: cotización directa o solicitud abierta nueva → aparece sola
  // encima del dashboard. El canal de event_requests se filtra POR GÉNERO en
  // el servidor (sin eso, cada solicitud del país refetcheaba en cada
  // dispositivo) + guard de is_express en el payload. Solo un INSERT nuevo
  // reabre el sheet — cerrar con X es persistente ante items viejos.
  useEffect(() => {
    if (!groupId) return;
    const refresh = async () => {
      const rows = await fetchPending();
      setQuotes(rows);
      if (rows.filter(q => !dismissedRef.current.has(q.id)).length > 0) show();
    };
    const channel = supabase.channel(`scheduled-incoming-${groupId}`);
    channel.on(
      'postgres_changes',
      { event: 'INSERT', schema: 'public', table: 'quotes', filter: `group_id=eq.${groupId}` },
      refresh
    );
    if (groupGenre) {
      channel.on(
        'postgres_changes',
        { event: 'INSERT', schema: 'public', table: 'event_requests', filter: `genre=eq.${groupGenre}` },
        (payload: any) => {
          const r = payload?.new;
          const isExpress = r?.is_express === true || r?.is_express === 'true';
          if (!isExpress) void refresh();
        }
      );
    }
    channel.subscribe();
    return () => { supabase.removeChannel(channel); };
  }, [groupId, groupGenre, fetchPending, show]);

  const visibleQuotes = quotes
    .filter(q => !dismissedRef.current.has(q.id))
    .sort((a, b) => (a.id === highlightId ? -1 : b.id === highlightId ? 1 : 0));

  const handleCotizar = useCallback((item: any) => {
    hide();
    if (item.kind === 'quote') {
      navigation.navigate('GroupQuoteDetail', { quote: item.raw });
    } else {
      navigation.navigate('ProposeRequest', { request: item.raw });
    }
  }, [navigation, hide]);

  if (!visible || visibleQuotes.length === 0) return null;

  const count = visibleQuotes.length;

  return (
    <>
      <Animated.View
        pointerEvents="none"
        style={[st.backdrop, { opacity: dimAnim.interpolate({ inputRange: [0, 1], outputRange: [0, 0.4] }) }]}
      />
      <Animated.View style={[st.sheet, { transform: [{ translateY: slideAnim }] }]} pointerEvents="box-none">
        <View style={st.header}>
          <View style={st.headerLeft}>
            <View style={st.dot} />
            <Text style={st.headerTx}>
              {count === 1 ? '1 solicitud programada' : `${count} solicitudes programadas`}
            </Text>
          </View>
          <Pressable onPress={hide} hitSlop={10}
            style={({ pressed }) => [st.headerX, pressed && { opacity: 0.6 }]}>
            <X size={16} color={COLORS.text} />
          </Pressable>
        </View>

        <FlatList
          data={visibleQuotes}
          keyExtractor={(q: any) => q.id}
          horizontal
          showsHorizontalScrollIndicator={false}
          // flex-start: sin esto el item se estira a la altura del sheet y el
          // marco de la tarjeta se va hasta abajo de la pantalla
          contentContainerStyle={{ paddingHorizontal: LIST_PADDING, alignItems: 'flex-start' }}
          ItemSeparatorComponent={() => <View style={{ width: CARD_GAP }} />}
          snapToInterval={SNAP_INTERVAL}
          snapToAlignment="start"
          decelerationRate="fast"
          renderItem={({ item }) => (
            <ScheduledQuoteCard
              item={item}
              userLocation={userLocation}
              groupPhotoUrl={groupPhotoUrl}
              onCotizar={() => handleCotizar(item)}
              onViewProfile={() => setProfileClientId(item.client_id)}
            />
          )}
        />

        {count > 1 && (
          <View style={st.swipeHint} pointerEvents="none">
            <Text style={st.swipeHintTx}>‹  desliza para ver las {count} solicitudes  ›</Text>
          </View>
        )}
      </Animated.View>

      <ClientProfileModal clientId={profileClientId} onClose={() => setProfileClientId(null)} />
    </>
  );
}

// ── Styles del sheet (espejo de ExpressCarousel) ──────────────────────────────
const st = StyleSheet.create({
  // zIndex POR ENCIMA del carrusel exprés (9998/9999): si el grupo abre las
  // programadas desde la notificación/banner, deben verse aunque haya
  // exprés activas debajo (la X las revela)
  backdrop: {
    position: 'absolute', top: 0, left: 0, right: 0,
    height: ABOVE_HEIGHT, backgroundColor: '#000', zIndex: 10000,
  },
  sheet: {
    position: 'absolute', bottom: 0, left: 0, right: 0,
    height: SHEET_HEIGHT, zIndex: 10001,
    shadowColor: '#000', shadowOffset: { width: 0, height: -6 },
    shadowOpacity: 0.55, shadowRadius: 18, elevation: 14,
  },
  header: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between',
    paddingHorizontal: 20, paddingVertical: 12,
    backgroundColor: 'rgba(6,12,6,0.97)',
    borderTopLeftRadius: 22, borderTopRightRadius: 22,
    borderBottomWidth: 1, borderBottomColor: 'rgba(0,230,118,0.1)',
  },
  headerLeft: { flexDirection: 'row', alignItems: 'center', gap: 8 },
  dot: {
    width: 7, height: 7, borderRadius: 3.5, backgroundColor: COLORS.green,
    shadowColor: COLORS.green, shadowOffset: { width: 0, height: 0 },
    shadowOpacity: 1, shadowRadius: 4, elevation: 4,
  },
  headerTx: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.text, letterSpacing: 0.2 },
  headerX: {
    width: 30, height: 30, borderRadius: 15,
    backgroundColor: 'rgba(255,255,255,0.06)',
    borderWidth: 1, borderColor: 'rgba(255,255,255,0.14)',
    alignItems: 'center', justifyContent: 'center',
  },
  swipeHint: { alignItems: 'center', paddingTop: 10 },
  swipeHintTx: {
    fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.green,
    letterSpacing: 0.4,
    backgroundColor: 'rgba(0,230,118,0.08)',
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.25)',
    borderRadius: 20, paddingHorizontal: 14, paddingVertical: 6,
    overflow: 'hidden',
  },
});

// ── Styles de la tarjeta (paleta ExpressCard) ─────────────────────────────────
const s = StyleSheet.create({
  card: { width: CARD_WIDTH, backgroundColor: '#060c06', borderRadius: RADIUS.xl, overflow: 'hidden', borderWidth: 1, borderColor: 'rgba(0,230,118,0.55)' },
  body: { paddingHorizontal: 16, paddingTop: 13, paddingBottom: 15, gap: 9 },

  clientRow:           { flexDirection: 'row', alignItems: 'center', gap: 10 },
  clientAvatar:        { width: 40, height: 40, borderRadius: 20 },
  clientAvatarPh:      { width: 40, height: 40, borderRadius: 20, backgroundColor: 'rgba(0,230,118,0.12)', alignItems: 'center', justifyContent: 'center' },
  clientAvatarInitial: { fontFamily: FONTS.bodySemiBold, fontSize: 17, color: COLORS.green },
  clientName:          { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.text },
  clientCity:          { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted2, marginTop: 1 },
  viewProfileBtn: {
    backgroundColor: 'rgba(0,230,118,0.10)', borderRadius: 20,
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.35)',
    paddingHorizontal: 10, paddingVertical: 5,
  },
  viewProfileTx: { fontFamily: FONTS.bodySemiBold, fontSize: 11, color: COLORS.green },

  eventType: { fontFamily: FONTS.bodySemiBold, fontSize: 16, color: COLORS.text, letterSpacing: 0.1 },
  cityTx:    { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2, marginTop: -5 },

  statsRow: { flexDirection: 'row', flexWrap: 'wrap', alignItems: 'center', gap: 12, rowGap: 8 },
  stat:     { alignItems: 'flex-start', gap: 2 },
  statVal:  { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.text },
  statLbl:  { fontFamily: FONTS.body, fontSize: 10, color: COLORS.muted },
  statDiv:  { width: 1, height: 26, backgroundColor: 'rgba(255,255,255,0.07)' },

  actions:      { flexDirection: 'row', gap: 8, marginTop: 2 },
  btnOutline:   { paddingHorizontal: 14, paddingVertical: 10, borderRadius: RADIUS.lg, alignItems: 'center', justifyContent: 'center', borderWidth: 1, borderColor: 'rgba(0,230,118,0.35)', backgroundColor: 'rgba(0,230,118,0.08)' },
  btnOutlineTx: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.green },
  btnPrimary:   { flex: 1, flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 5, paddingVertical: 10, borderRadius: RADIUS.lg, backgroundColor: COLORS.green },
  btnPrimaryTx: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.bg },
});
