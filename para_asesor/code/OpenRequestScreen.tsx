/**
 * OpenRequestScreen — Solicitud Inmediata (tipo Uber)
 *
 * El cliente elige un género musical y llena los detalles del evento.
 * La solicitud llega a TODOS los grupos de ese género.
 * El primer grupo que acepte se queda con el evento.
 */
import * as Location from 'expo-location';
import { ArrowLeft, CheckCircle, Clock, Navigation, Send, Trash2, Zap } from 'lucide-react-native';
import React, { useCallback, useEffect, useState } from 'react';
import { useStripe } from '@stripe/stripe-react-native';
import {
  ActivityIndicator,
  Alert,
  Image,
  Linking,
  Pressable,
  RefreshControl,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  View,
} from 'react-native';
import { useFocusEffect } from '@react-navigation/native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { supabase } from '../../config/supabase';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';
import { analyzeMessage, PHONE_WARNING } from '../../utils/phoneFilter';
import TimePickerModal from '../../components/ui/TimePickerModal';

// ─── Datos ────────────────────────────────────────────────────────────────────

const MUSIC_GENRES = [
  { key: 'Norteño',           label: '🪗 Norteño' },
  { key: 'Banda',             label: '🎺 Banda' },
  { key: 'Mariachi',          label: '🎻 Mariachi' },
  { key: 'Grupero',           label: '🎸 Grupero' },
  { key: 'Cumbia',            label: '🥁 Cumbia' },
  { key: 'Salsa',             label: '💃 Salsa' },
  { key: 'Jazz',              label: '🎷 Jazz' },
  { key: 'Rock',              label: '🤘 Rock' },
  { key: 'Pop',               label: '🎤 Pop' },
  { key: 'Regional Mexicano', label: '🇲🇽 Regional Mexicano' },
  { key: 'Tropical',          label: '🌴 Tropical' },
  { key: 'Ranchero',          label: '🤠 Ranchero' },
  { key: 'Electrónica',       label: '🎧 Electrónica' },
  { key: 'Otro',              label: '🎵 Otro' },
];

const EVENT_TYPES = [
  { key: 'fiesta_privada', label: '🎉 Fiesta privada' },
  { key: 'boda',           label: '💍 Boda' },
  { key: 'cumpleanos',     label: '🎂 Cumpleaños' },
  { key: 'graduacion',     label: '🎓 Graduación' },
  { key: 'empresarial',    label: '🏢 Empresarial' },
  { key: 'otro',           label: '🎵 Otro' },
];

const DURATION_OPTIONS = [
  { value: 3, label: '3h' }, { value: 4, label: '4h' },
  { value: 5, label: '5h' }, { value: 6, label: '6h' },
  { value: 7, label: '7h' }, { value: 8, label: '8h+' },
];

const COVERED_OPTIONS = [
  { key: 'si',    label: 'Sí' },
  { key: 'no',    label: 'No' },
  { key: 'no_se', label: 'No sé' },
];

const VENUE_SIZES = [
  { key: 'patio_pequeno',         label: '🏡 Patio pequeño' },
  { key: 'salon_mediano',         label: '🏛️ Salón mediano' },
  { key: 'jardin_grande',         label: '🌳 Jardín grande' },
  { key: 'escenario_profesional', label: '🎤 Escenario profesional' },
];

const SOUND_OPTIONS = [
  { key: 'si',       label: 'Necesito sonido' },
  { key: 'no',       label: 'No necesito' },
  { key: 'ya_tengo', label: 'Ya cuento con sonido' },
];

// ─── Helpers ─────────────────────────────────────────────────────────────────

function SectionTitle({ children }: { children: React.ReactNode }) {
  return <Text style={s.sectionTitle}>{children}</Text>;
}

function ChipGrid<T extends string | number>({
  options, selected, onSelect,
}: {
  options: { key: T; label: string }[];
  selected: T | null;
  onSelect: (v: T) => void;
}) {
  return (
    <View style={s.chipGrid}>
      {options.map(o => (
        <Pressable
          key={String(o.key)}
          style={[s.chip, selected === o.key && s.chipActive]}
          onPress={() => onSelect(o.key)}
        >
          <Text style={[s.chipText, selected === o.key && s.chipTextActive]}>
            {o.label}
          </Text>
        </Pressable>
      ))}
    </View>
  );
}

// ─── Screen ──────────────────────────────────────────────────────────────────

const STATUS_LABELS: Record<string, { label: string; color: string }> = {
  open:           { label: '⏳ Esperando grupo',    color: '#00E676' },
  en_negociacion: { label: '🤝 Grupo interesado',   color: '#FFB300' },
  accepted:       { label: '✅ Confirmada',          color: '#40C4FF' },
  cancelled:      { label: '❌ Cancelada',           color: '#666' },
  expired:        { label: '⌛ Expirada',            color: '#FF6400' },
};

const GENRE_EMOJIS: Record<string, string> = {
  'Norteño': '🪗', 'Banda': '🎺', 'Mariachi': '🎻', 'Grupero': '🎸',
  'Cumbia': '🥁', 'Salsa': '💃', 'Jazz': '🎷', 'Rock': '🤘', 'Pop': '🎤',
  'Regional Mexicano': '🇲🇽', 'Tropical': '🌴', 'Ranchero': '🤠',
  'Electrónica': '🎧', 'Otro': '🎵',
};

function fmtDate(d: string) {
  return new Date(d + 'T12:00:00').toLocaleDateString('es-MX', {
    weekday: 'short', day: 'numeric', month: 'short',
  });
}

export default function OpenRequestScreen({ navigation, route }: any) {
  const { initPaymentSheet, presentPaymentSheet } = useStripe();

  // ── Tabs ──────────────────────────────────────────────────────────────────
  const initialTab = route?.params?.tab === 'mine' ? 'mine' : 'new';
  const [activeTab, setActiveTab] = useState<'new' | 'mine'>(initialTab);

  // ── Mis solicitudes ───────────────────────────────────────────────────────
  const [myRequests,  setMyRequests]  = useState<any[]>([]);
  const [loadingMine, setLoadingMine] = useState(false);
  const [refreshMine, setRefreshMine] = useState(false);
  const [cancelingId, setCancelingId] = useState<string | null>(null);

  const fetchMyRequests = async () => {
    const { data: { user } } = await supabase.auth.getUser();
    if (!user) return;
    const { data: reqs } = await supabase
      .from('event_requests')
      .select('*')
      .eq('client_id', user.id)
      .order('created_at', { ascending: false });

    const requests = reqs ?? [];

    // Para solicitudes en negociación, traer info del grupo que propuso
    const negIds = requests
      .filter((r: any) => r.status === 'en_negociacion' && r.negotiating_group_id)
      .map((r: any) => r.negotiating_group_id);

    let groupLookup: Record<string, any> = {};
    if (negIds.length > 0) {
      const { data: groups } = await supabase
        .from('groups')
        .select('id, owner_id, name, genre, profile_image, city')
        .in('owner_id', negIds);
      groupLookup = Object.fromEntries((groups ?? []).map((g: any) => [g.owner_id, g]));
    }

    setMyRequests(requests.map((r: any) => ({
      ...r,
      negotiating_group: r.negotiating_group_id ? (groupLookup[r.negotiating_group_id] ?? null) : null,
    })));
  };

  useEffect(() => {
    if (activeTab === 'mine') {
      setLoadingMine(true);
      fetchMyRequests().finally(() => setLoadingMine(false));
    }
  }, [activeTab]);

  useFocusEffect(useCallback(() => {
    if (activeTab === 'mine') fetchMyRequests();
  }, [activeTab]));

  const [respondingId, setRespondingId] = useState<string | null>(null);

  const handleCancel = (reqId: string, eventType: string) => {
    Alert.alert(
      'Cancelar solicitud',
      `¿Seguro que quieres cancelar la solicitud de "${eventType}"? Los grupos dejarán de verla.`,
      [
        { text: 'No', style: 'cancel' },
        {
          text: 'Sí, cancelar',
          style: 'destructive',
          onPress: async () => {
            setCancelingId(reqId);
            const { data: { user } } = await supabase.auth.getUser();
            const { error } = await supabase
              .from('event_requests')
              .update({ status: 'cancelled' })
              .eq('id', reqId)
              .eq('client_id', user!.id)
              .eq('status', 'open');
            setCancelingId(null);
            if (error) {
              Alert.alert('Error', 'No se pudo cancelar. Inténtalo de nuevo.');
            } else {
              fetchMyRequests();
            }
          },
        },
      ],
    );
  };

  const handleAcceptProposal = async (req: any) => {
    const reqId     = req.id;
    const groupName = req.negotiating_group?.name ?? 'el grupo';
    const total     = req.proposal_data?.total_amount != null
      ? Number(req.proposal_data.total_amount) : null;
    const deposit   = total != null ? Math.round((total * 50) / 100) : null;

    setRespondingId(reqId);
    try {
      // 1. Crear reserva vía RPC
      const { data, error } = await supabase.rpc('client_accept_proposal', { p_request_id: reqId });

      if (error || !data?.ok) {
        const code = data?.error ?? error?.message ?? '';
        if (code === 'not_in_negotiation') {
          Alert.alert(
            'Ya contratado',
            'Este evento ya fue confirmado. Puedes pagar el anticipo desde "Mis Eventos".',
            [{ text: 'Ver mis eventos', onPress: () => navigation.navigate('ClientReservations') }],
          );
          return;
        }
        Alert.alert('Error', `No se pudo confirmar. ${code || 'Inténtalo de nuevo.'}`);
        return;
      }

      const reservationId: string = data.reservation_id;

      // 2. Abrir Stripe Payment Sheet si hay monto
      if (deposit != null && reservationId) {
        const { data: { session } } = await supabase.auth.getSession();
        const { data: piData, error: piErr } = await supabase.functions.invoke('create-payment-intent', {
          body: { reservation_id: reservationId },
          headers: { Authorization: `Bearer ${session?.access_token}` },
        });

        if (piErr || piData?.error || !piData?.client_secret) {
          Alert.alert(
            'Reserva creada',
            `Tu evento con ${groupName} está agendado. Paga el anticipo de $${deposit.toLocaleString()} MXN desde "Mis Eventos".`,
            [{ text: 'Ver mis eventos', onPress: () => navigation.navigate('ClientReservations') }],
          );
          return;
        }

        const { error: initError } = await initPaymentSheet({
          paymentIntentClientSecret: piData.client_secret,
          merchantDisplayName: 'Daricefy',
          style: 'alwaysDark',
        });
        if (initError) {
          Alert.alert('Error', initError.message);
          navigation.navigate('ClientReservations');
          return;
        }

        const { error: payError } = await presentPaymentSheet();
        if (payError) {
          if (payError.code !== 'Canceled') {
            Alert.alert('Error de pago', payError.message);
          }
        } else {
          // Actualizar reserva directamente (el webhook también lo hará cuando esté configurado)
          await supabase
            .from('reservations')
            .update({ status: 'confirmed', payment_status: 'deposit_paid' })
            .eq('id', reservationId);

          // Notificar al grupo (owner + miembros)
          const { data: resInfo } = await supabase
            .from('reservations')
            .select('group_id, total_price, group:groups(owner_id)')
            .eq('id', reservationId)
            .single();
          const grpId   = resInfo?.group_id;
          const ownerId = (resInfo?.group as any)?.owner_id;
          const amount  = resInfo?.total_price
            ? Math.round((resInfo.total_price * 50) / 100)
            : total != null ? Math.round((total * 50) / 100) : 0;
          if (grpId && ownerId) {
            const notifBody = `El cliente pagó el anticipo de $${amount.toLocaleString('es-MX')} MXN. El evento está confirmado.`;
            const notifData = { reservation_id: reservationId, screen: 'GroupReservations' };
            const notifs: any[] = [
              { user_id: ownerId, type: 'deposit_paid', title: '💰 Anticipo recibido', body: notifBody, data: notifData },
            ];
            const { data: members } = await supabase
              .from('job_invitations')
              .select('invited_user_id')
              .eq('group_id', grpId)
              .in('invitation_type', ['membership', 'job'])
              .eq('status', 'accepted');
            (members ?? []).forEach((m: any) => {
              notifs.push({ user_id: m.invited_user_id, type: 'deposit_paid', title: '💰 Anticipo recibido', body: notifBody, data: notifData });
            });
            await supabase.from('notifications').insert(notifs);
          }

          Alert.alert('¡Pago exitoso!', `Tu evento con ${groupName} está confirmado. ¡Nos vemos pronto! 🎉`);
        }
        navigation.navigate('ClientReservations');
      } else {
        navigation.navigate('ClientReservations');
      }
    } catch (e: any) {
      Alert.alert('Error', e.message ?? 'Inténtalo de nuevo.');
    } finally {
      setRespondingId(null);
    }
  };

  const handleRejectProposal = (reqId: string, groupName: string) => {
    Alert.alert(
      '¿Rechazar esta propuesta?',
      `La solicitud volverá a estar disponible para que otros grupos de ${groupName.split(' ')[0]} puedan proponerse.`,
      [
        { text: 'Cancelar', style: 'cancel' },
        {
          text: '❌ Sí, buscar otro',
          style: 'destructive',
          onPress: async () => {
            setRespondingId(reqId);
            const { data, error } = await supabase.rpc('client_reject_proposal', { p_request_id: reqId });
            setRespondingId(null);
            if (error || !data?.ok) {
              Alert.alert('Error', 'No se pudo rechazar. Inténtalo de nuevo.');
            } else {
              fetchMyRequests();
            }
          },
        },
      ],
    );
  };

  // Paso 1: Género
  const [genre, setGenre] = useState<string | null>(null);

  // Paso 2: Evento
  const [eventType,    setEventType]    = useState<string | null>(null);
  const eventDate = (() => {
    const n = new Date();
    return `${n.getFullYear()}-${String(n.getMonth()+1).padStart(2,'0')}-${String(n.getDate()).padStart(2,'0')}`;
  })();
  const [eventTime,    setEventTime]    = useState('');
  const [showTimePicker, setShowTimePicker] = useState(false);
  const [hours,        setHours]        = useState<number>(3);
  const [guestCount,   setGuestCount]   = useState('');

  // GPS auto-location
  const [locationLoading,    setLocationLoading]    = useState(false);
  const [locationDetected,   setLocationDetected]   = useState(false);
  const [showLocationInputs, setShowLocationInputs] = useState(false);

  // Paso 3: Ubicación
  const [city,            setCity]            = useState('');
  const [municipio,       setMunicipio]       = useState('');
  const [estado,          setEstado]          = useState('');
  const [address,         setAddress]         = useState('');
  const [addressConfirmed, setAddressConfirmed] = useState(false);

  // Paso 4: Detalles del lugar
  const [venueCovered, setVenueCovered] = useState<string | null>(null);
  const [venueSize,    setVenueSize]    = useState<string | null>(null);
  const [needsSound,   setNeedsSound]   = useState<string | null>(null);
  const [comments,     setComments]     = useState('');

  // UI
  const [loading, setLoading] = useState(false);
  const [commentsWarn, setCommentsWarn] = useState(false);

  // Surge pricing
  const [surgeInfo, setSurgeInfo] = useState<{ surge_factor: number; client_message: string } | null>(null);

  useEffect(() => {
    (async () => {
      setLocationLoading(true);
      try {
        const { status } = await Location.requestForegroundPermissionsAsync();
        if (status === 'granted') {
          const pos = await Location.getCurrentPositionAsync({ accuracy: Location.Accuracy.Balanced });
          const [geo] = await Location.reverseGeocodeAsync(pos.coords);
          if (geo) {
            setCity(geo.city ?? geo.subregion ?? '');
            setEstado(geo.region ?? '');
            setMunicipio(geo.subregion ?? geo.district ?? '');
            setLocationDetected(true);
          }
        }
      } catch (_) {}
      setLocationLoading(false);
    })();
  }, []);

  useEffect(() => {
    if (!genre) { setSurgeInfo(null); return; }
    supabase
      .rpc('get_surge_factor', { p_genre: genre, p_city: city.trim() || null })
      .then(({ data }) => { if (data) setSurgeInfo(data as any); });
  }, [genre, city]);

  const confirmAddress = () => {
    const full = [address.trim(), municipio.trim(), estado.trim()].filter(Boolean).join(', ');
    if (!address.trim()) { Alert.alert('Error', 'Escribe la dirección del evento.'); return; }
    Alert.alert(
      'Confirmar dirección',
      `¿La dirección es correcta?\n\n"${full}"`,
      [
        { text: 'Corregir', style: 'cancel' },
        { text: 'Sí, es correcta', onPress: () => setAddressConfirmed(true) },
      ]
    );
  };

  const openInMaps = () => {
    const full = [address.trim(), municipio.trim(), estado.trim()].filter(Boolean).join(', ');
    if (!full) return;
    Linking.openURL(`https://www.google.com/maps/search/?api=1&query=${encodeURIComponent(full)}`);
  };

  const canSubmit =
    !!genre && !!eventType && !!eventTime && !!hours &&
    !!guestCount && parseInt(guestCount) > 0 &&
    !!city.trim() && !!estado.trim() &&
    !!address.trim() &&
    !!venueCovered && !!venueSize && !!needsSound &&
    !commentsWarn;

  const handleSubmit = async () => {
    if (!canSubmit) {
      Alert.alert('Campos incompletos', 'Por favor completa todos los campos requeridos.');
      return;
    }

    const { data: { user } } = await supabase.auth.getUser();
    if (!user) { Alert.alert('Error', 'Sesión no encontrada.'); return; }

    setLoading(true);

    const { data: inserted, error } = await supabase
      .from('event_requests')
      .insert({
        client_id:        user.id,
        genre,
        event_type:       eventType,
        event_date:       eventDate,
        event_time:       eventTime,
        hours,
        guest_count:      parseInt(guestCount),
        location_city:    city.trim(),
        location_municipio: municipio.trim() || null,
        location_estado:  estado.trim(),
        location_address: address.trim(),
        venue_covered:    venueCovered,
        venue_size:       venueSize,
        needs_sound:      needsSound,
        comments:         comments.trim() || null,
      })
      .select()
      .single();

    setLoading(false);

    if (error) {
      Alert.alert('Error', error.message ?? 'No se pudo enviar tu solicitud.');
      return;
    }

    // Obtener GPS del cliente para ordenar grupos por proximidad
    let eventLat: number | null = null;
    let eventLng: number | null = null;
    try {
      const { status } = await Location.requestForegroundPermissionsAsync();
      if (status === 'granted') {
        const pos = await Location.getCurrentPositionAsync({ accuracy: Location.Accuracy.Balanced });
        eventLat = pos.coords.latitude;
        eventLng = pos.coords.longitude;
      }
    } catch (_) { /* sin GPS → ordena sin distancia */ }

    // Ola 1: notifica los top-5 grupos por ranking + proximidad
    const { data: rpcResult } = await supabase.rpc('notify_wave_1', {
      p_request_id: inserted.id,
      p_event_lat:  eventLat,
      p_event_lng:  eventLng,
      p_radius_km:  50,
    });

    const notified: number = rpcResult?.notified ?? 0;
    const isUrgent: boolean = rpcResult?.urgent ?? false;

    Alert.alert(
      isUrgent ? '🔥 Solicitud urgente enviada' : '✅ Solicitud enviada',
      `Tu solicitud llegó a ${notified} grupo${notified !== 1 ? 's' : ''} de ${genre}. Si no hay respuesta en 2 minutos se notifican más grupos automáticamente.`,
      [{ text: 'Perfecto', onPress: () => navigation.goBack() }],
    );
  };

  return (
    <View style={s.root}>
      <SafeAreaView edges={['top']} style={s.header}>
        <Pressable style={s.backBtn} onPress={() => navigation.goBack()}>
          <ArrowLeft size={20} color={COLORS.text} />
        </Pressable>
        <View style={{ flex: 1 }}>
          <Text style={s.headerTitle}>Solicitar grupo ahora</Text>
          <Text style={s.headerSub}>El primer grupo disponible te contactará</Text>
        </View>
        <Zap size={22} color={COLORS.green} />
      </SafeAreaView>

      {/* ── Tabs ─────────────────────────────────────────────────────────────── */}
      <View style={s.tabBar}>
        <Pressable
          style={[s.tabBtn, activeTab === 'new' && s.tabBtnActive]}
          onPress={() => setActiveTab('new')}
        >
          <Text style={[s.tabBtnText, activeTab === 'new' && s.tabBtnTextActive]}>
            ⚡ Nueva solicitud
          </Text>
        </Pressable>
        <Pressable
          style={[s.tabBtn, activeTab === 'mine' && s.tabBtnActive]}
          onPress={() => setActiveTab('mine')}
        >
          <Text style={[s.tabBtnText, activeTab === 'mine' && s.tabBtnTextActive]}>
            📋 Mis solicitudes
            {myRequests.filter(r => r.status === 'open').length > 0 && (
              <Text style={s.tabBadge}> {myRequests.filter(r => r.status === 'open').length}</Text>
            )}
          </Text>
        </Pressable>
      </View>

      {/* ── Vista: Mis solicitudes ────────────────────────────────────────────── */}
      {activeTab === 'mine' && (
        <ScrollView
          contentContainerStyle={s.scroll}
          showsVerticalScrollIndicator={false}
          refreshControl={
            <RefreshControl
              refreshing={refreshMine}
              onRefresh={async () => { setRefreshMine(true); await fetchMyRequests(); setRefreshMine(false); }}
              tintColor={COLORS.green}
            />
          }
        >
          {loadingMine && <ActivityIndicator color={COLORS.green} style={{ marginTop: 40 }} />}

          {!loadingMine && myRequests.length === 0 && (
            <View style={s.emptyMine}>
              <Text style={s.emptyMineEmoji}>📭</Text>
              <Text style={s.emptyMineTitle}>Sin solicitudes</Text>
              <Text style={s.emptyMineSub}>Aún no has enviado ninguna solicitud inmediata.</Text>
            </View>
          )}

          {myRequests.map(req => {
            const st           = STATUS_LABELS[req.status] ?? { label: req.status, color: COLORS.muted2 };
            const isOpen       = req.status === 'open';
            const isNeg        = req.status === 'en_negociacion';
            const isCanceling  = cancelingId === req.id;
            const isResponding = respondingId === req.id;
            const grp          = req.negotiating_group;

            return (
              <View key={req.id} style={[s.mineCard, isNeg && s.mineCardNeg]}>
                {/* Cabecera siempre visible */}
                <View style={s.mineCardTop}>
                  <View style={{ flex: 1 }}>
                    <Text style={s.mineCardType}>
                      {req.event_type?.replace('_', ' ')}
                      {'  '}
                      <Text style={s.mineCardGenre}>{req.genre}</Text>
                    </Text>
                    <Text style={s.mineCardDate}>
                      {fmtDate(req.event_date)} · {req.hours}h · {req.location_city}
                    </Text>
                  </View>
                  <View style={[s.statusBadge, { borderColor: st.color + '60', backgroundColor: st.color + '18' }]}>
                    <Text style={[s.statusBadgeText, { color: st.color }]}>{st.label}</Text>
                  </View>
                </View>

                {/* ── Propuesta de un grupo (en_negociacion) ── */}
                {isNeg && grp && (
                  <View style={s.proposalBox}>
                    {/* Info del grupo */}
                    <View style={s.proposalGroupRow}>
                      {grp.profile_image ? (
                        <Image source={{ uri: grp.profile_image }} style={s.proposalAvatar} />
                      ) : (
                        <View style={s.proposalAvatarPlaceholder}>
                          <Text style={{ fontSize: 22 }}>{GENRE_EMOJIS[grp.genre] ?? '🎵'}</Text>
                        </View>
                      )}
                      <View style={{ flex: 1 }}>
                        <Text style={s.proposalGroupName}>{grp.name}</Text>
                        <Text style={s.proposalGroupSub}>{grp.genre} · {grp.city}</Text>
                      </View>
                      <Pressable
                        style={s.viewProfileBtn}
                        onPress={() => navigation.navigate('GroupDetail', { group: grp })}
                      >
                        <Text style={s.viewProfileBtnText}>Ver perfil →</Text>
                      </Pressable>
                    </View>

                    {/* Banner valor / protección */}
                    {Number(req.demand_multiplier ?? 1) > 1 && (
                      <View style={s.demandBanner}>
                        <Text style={s.demandBannerText}>
                          ✨ Reserva protegida por la app · Pago seguro y garantía de servicio
                        </Text>
                      </View>
                    )}

                    {/* Resumen de la cotización */}
                    {req.proposal_data && (
                      <View style={s.proposalPriceBox}>
                        {/* Desglose: precio/h × horas = subtotal */}
                        {req.proposal_data.price_per_hour != null && (
                          <>
                            <View style={s.proposalPriceRow}>
                              <Text style={s.proposalPriceLabel}>Precio por hora</Text>
                              <Text style={s.proposalPriceValSub}>${Number(req.proposal_data.price_per_hour).toLocaleString()}/h</Text>
                            </View>
                            <View style={s.proposalPriceRow}>
                              <Text style={s.proposalPriceLabel}>Duración</Text>
                              <Text style={s.proposalPriceValSub}>{req.hours ?? 3} horas</Text>
                            </View>
                            <View style={s.proposalPriceRow}>
                              <Text style={s.proposalPriceLabel}>Subtotal</Text>
                              <Text style={s.proposalPriceValSub}>
                                ${(Number(req.proposal_data.price_per_hour) * (req.hours ?? 3)).toLocaleString()} MXN
                              </Text>
                            </View>
                          </>
                        )}
                        {req.proposal_data.travel_cost > 0 && (
                          <View style={s.proposalPriceRow}>
                            <Text style={s.proposalPriceLabel}>Traslado</Text>
                            <Text style={s.proposalPriceValSub}>+${Number(req.proposal_data.travel_cost).toLocaleString()}</Text>
                          </View>
                        )}
                        {/* Total en negrita */}
                        {req.proposal_data.total_amount != null && (
                          <View style={[s.proposalPriceRow, s.totalRow]}>
                            <Text style={s.totalLabel}>Total</Text>
                            <Text style={s.totalVal}>${Number(req.proposal_data.total_amount).toLocaleString()} MXN</Text>
                          </View>
                        )}
                        {req.proposal_data.arrival_time ? (
                          <View style={[s.proposalPriceRow, s.arrivalRow]}>
                            <Text style={s.arrivalLabel}>🕐 Llegada del grupo</Text>
                            <Text style={s.arrivalVal}>{req.proposal_data.arrival_time}</Text>
                          </View>
                        ) : null}
                        {req.proposal_data.start_time ? (
                          <View style={[s.proposalPriceRow, s.arrivalRow]}>
                            <Text style={s.arrivalLabel}>🎵 Inicio de tocada</Text>
                            <Text style={s.arrivalVal}>{req.proposal_data.start_time}</Text>
                          </View>
                        ) : null}
                        {req.proposal_data.start_time && req.proposal_data.arrival_time ? (
                          <View style={s.startTimeNote}>
                            <Text style={s.startTimeNoteText}>
                              ℹ️ El grupo llega antes para instalar el sonido. La música inicia a las {req.proposal_data.start_time}.
                            </Text>
                          </View>
                        ) : null}
                        {req.proposal_data.notes ? (
                          <View style={s.proposalNotesBox}>
                            <Text style={s.proposalNotesText}>💬 {req.proposal_data.notes}</Text>
                          </View>
                        ) : null}
                      </View>
                    )}

                    <Text style={s.proposalMsg}>
                      ¿Contratas a este grupo para tu evento?
                    </Text>

                    <View style={s.proposalBtnRow}>
                      <Pressable
                        style={[s.rejectProposalBtn, isResponding && { opacity: 0.5 }]}
                        onPress={() => !isResponding && handleRejectProposal(req.id, grp.name)}
                        disabled={isResponding}
                      >
                        {isResponding
                          ? <ActivityIndicator size="small" color="#FF5252" />
                          : <Text style={s.rejectProposalBtnText}>❌ Buscar otro</Text>
                        }
                      </Pressable>
                      <Pressable
                        style={[s.acceptProposalBtn, isResponding && { opacity: 0.5 }]}
                        onPress={() => !isResponding && handleAcceptProposal(req)}
                        disabled={isResponding}
                      >
                        {isResponding
                          ? <ActivityIndicator size="small" color={COLORS.bg} />
                          : <Text style={s.acceptProposalBtnText}>✅ Contratar</Text>
                        }
                      </Pressable>
                    </View>
                  </View>
                )}

                {/* Cancelar (solo si está open) */}
                {isOpen && (
                  <Pressable
                    style={[s.cancelBtn, isCanceling && s.cancelBtnDisabled]}
                    onPress={() => !isCanceling && handleCancel(req.id, req.event_type)}
                    disabled={isCanceling}
                  >
                    {isCanceling
                      ? <ActivityIndicator size="small" color="#FF5252" />
                      : <>
                          <Trash2 size={14} color="#FF5252" />
                          <Text style={s.cancelBtnText}>Cancelar solicitud</Text>
                        </>
                    }
                  </Pressable>
                )}
              </View>
            );
          })}

          <View style={{ height: 40 }} />
        </ScrollView>
      )}

      {/* ── Vista: Nueva solicitud (formulario) ───────────────────────────────── */}
      {activeTab === 'new' && (
      <View style={{ flex: 1 }}>
        <ScrollView
          contentContainerStyle={s.scroll}
          showsVerticalScrollIndicator={false}
          keyboardShouldPersistTaps="handled"
        >

          {/* ── BANNER INFORMATIVO ─────────────────────────────────────────── */}
          <View style={s.infoBanner}>
            <Text style={s.infoBannerText}>
              ⚡ Tu solicitud llegará a <Text style={{ fontFamily: FONTS.bodySemiBold }}>TODOS</Text> los grupos del género que selecciones.
              El primero en aceptar confirma el evento.
              {'\n'}🔒 Tu dirección exacta se muestra al grupo solo después de confirmar y pagar.
            </Text>
          </View>

          {/* ── 1. GÉNERO MUSICAL ─────────────────────────────────────────── */}
          <SectionTitle>1. ¿Qué tipo de música quieres? *</SectionTitle>
          <ChipGrid
            options={MUSIC_GENRES as any}
            selected={genre}
            onSelect={setGenre}
          />
          {genre && (
            <View style={s.genreSelected}>
              <Text style={s.genreSelectedText}>
                Seleccionaste: <Text style={{ color: COLORS.green }}>{genre}</Text>
              </Text>
            </View>
          )}

          {/* ── 2. TIPO DE EVENTO ─────────────────────────────────────────── */}
          <SectionTitle>2. Tipo de evento *</SectionTitle>
          <ChipGrid
            options={EVENT_TYPES as any}
            selected={eventType}
            onSelect={setEventType}
          />

          {/* ── 3. HORA DE INICIO ─────────────────────────────────────────── */}
          <SectionTitle>3. Hora de inicio *</SectionTitle>
          <Pressable
            style={[s.timeChip, eventTime ? s.timeChipActive : null]}
            onPress={() => setShowTimePicker(true)}
          >
            <Clock size={16} color={eventTime ? COLORS.green : COLORS.muted2} />
            <Text style={[s.timeChipText, eventTime ? s.timeChipTextActive : null]}>
              {eventTime
                ? (() => {
                    const [hStr, mStr] = eventTime.split(':');
                    const h = parseInt(hStr, 10);
                    return `${h % 12 || 12}:${mStr} ${h >= 12 ? 'PM' : 'AM'}`;
                  })()
                : 'Toca para elegir la hora'}
            </Text>
          </Pressable>

          {/* ── 4. DURACIÓN ───────────────────────────────────────────────── */}
          <SectionTitle>4. Duración * <Text style={s.minNote}>(mín. 3h)</Text></SectionTitle>
          <View style={s.durationRow}>
            {DURATION_OPTIONS.map(d => (
              <Pressable
                key={d.value}
                style={[s.durationBtn, hours === d.value && s.durationBtnActive]}
                onPress={() => setHours(d.value)}
              >
                <Text style={[s.durationBtnText, hours === d.value && s.durationBtnTextActive]}>
                  {d.label}
                </Text>
              </Pressable>
            ))}
          </View>

          {/* ── 5. PERSONAS ───────────────────────────────────────────────── */}
          <SectionTitle>5. Número aproximado de personas *</SectionTitle>
          <TextInput
            style={s.input}
            placeholder="Ej: 80"
            placeholderTextColor={COLORS.muted}
            value={guestCount}
            onChangeText={t => setGuestCount(t.replace(/[^0-9]/g, ''))}
            keyboardType="numeric"
            maxLength={4}
          />

          {/* ── 6. UBICACIÓN DEL EVENTO ───────────────────────────────────── */}
          <SectionTitle>6. Ubicación del evento *</SectionTitle>
          <Text style={s.hintText}>📍 Los grupos verán la ciudad. La dirección exacta se muestra solo después del pago.</Text>

          {locationLoading ? (
            <View style={s.locationLoadingRow}>
              <ActivityIndicator size="small" color={COLORS.green} />
              <Text style={s.locationLoadingText}>Detectando tu ubicación...</Text>
            </View>
          ) : locationDetected && !showLocationInputs ? (
            <View style={s.locationCard}>
              <Navigation size={16} color={COLORS.green} />
              <View style={{ flex: 1 }}>
                <Text style={s.locationCardCity}>
                  {city}{estado ? `, ${estado}` : ''}
                </Text>
                {!!municipio && (
                  <Text style={s.locationCardMunicipio}>{municipio}</Text>
                )}
              </View>
              <Pressable
                style={s.locationEditBtn}
                onPress={() => setShowLocationInputs(true)}
              >
                <Text style={s.locationEditBtnText}>Editar</Text>
              </Pressable>
            </View>
          ) : (
            <>
              <TextInput
                style={s.input}
                placeholder="Ciudad"
                placeholderTextColor={COLORS.muted}
                value={city}
                onChangeText={setCity}
              />
              <View style={s.row2}>
                <TextInput
                  style={[s.input, { flex: 1 }]}
                  placeholder="Municipio"
                  placeholderTextColor={COLORS.muted}
                  value={municipio}
                  onChangeText={setMunicipio}
                />
                <TextInput
                  style={[s.input, { flex: 1 }]}
                  placeholder="Estado *"
                  placeholderTextColor={COLORS.muted}
                  value={estado}
                  onChangeText={setEstado}
                />
              </View>
            </>
          )}

          {/* ── 7. DIRECCIÓN EXACTA (oculta) ─────────────────────────────── */}
          <SectionTitle>7. Dirección exacta del evento *</SectionTitle>
          <Text style={s.hintText}>🔒 Solo se revela al grupo después de que pagues el anticipo.</Text>
          <TextInput
            style={s.input}
            placeholder="Calle, número, colonia..."
            placeholderTextColor={COLORS.muted}
            value={address}
            onChangeText={t => { setAddress(t); setAddressConfirmed(false); }}
          />

          {address.trim().length > 0 && (
            <View style={s.mapSection}>
              {addressConfirmed ? (
                <View style={s.mapConfirmed}>
                  <CheckCircle size={16} color={COLORS.green} />
                  <View style={{ flex: 1 }}>
                    <Text style={s.mapConfirmedText}>Dirección confirmada</Text>
                    <Pressable onPress={openInMaps}>
                      <Text style={s.mapLink}>Ver en Google Maps →</Text>
                    </Pressable>
                  </View>
                </View>
              ) : (
                <Pressable style={s.mapConfirmBtn} onPress={confirmAddress}>
                  <Navigation size={15} color={COLORS.green} />
                  <Text style={s.mapConfirmBtnText}>Confirmar dirección</Text>
                </Pressable>
              )}
            </View>
          )}

          {/* ── 8. DETALLES DEL LUGAR ─────────────────────────────────────── */}
          <SectionTitle>8. ¿El lugar está techado? *</SectionTitle>
          <ChipGrid
            options={COVERED_OPTIONS as any}
            selected={venueCovered}
            onSelect={setVenueCovered}
          />

          <SectionTitle>9. Tamaño del espacio *</SectionTitle>
          <ChipGrid
            options={VENUE_SIZES as any}
            selected={venueSize}
            onSelect={setVenueSize}
          />

          <SectionTitle>10. ¿Necesitas sonido incluido? *</SectionTitle>
          <ChipGrid
            options={SOUND_OPTIONS as any}
            selected={needsSound}
            onSelect={setNeedsSound}
          />

          {/* ── 11. COMENTARIOS ───────────────────────────────────────────── */}
          <SectionTitle>11. Comentarios adicionales</SectionTitle>
          <TextInput
            style={[s.input, s.inputMulti]}
            placeholder={'Ej: "Es en rancho a 30 min de la ciudad"\n"Queremos música variada"'}
            placeholderTextColor={COLORS.muted}
            value={comments}
            onChangeText={v => {
              let c = v.replace(/[0-9]/g, '');
              const NUM_WORDS = /\b(cero|uno|dos|tres|cuatro|cinco|seis|siete|ocho|nueve)([\s\-./]+(cero|uno|dos|tres|cuatro|cinco|seis|siete|ocho|nueve)){2,}/gi;
              c = c.replace(NUM_WORDS, '');
              const result = analyzeMessage(c);
              if (result.blocked) {
                setCommentsWarn(true);
                supabase.auth.getUser().then(({ data: { user } }) => {
                  if (user) supabase.from('contact_violation_logs').insert({
                    user_id: user.id, sender_role: 'client',
                    attempted_message: c.slice(0, 200),
                    violation_type: result.type!, detected_pattern: result.pattern ?? null,
                  });
                });
              } else {
                setCommentsWarn(false);
              }
              setComments(c);
            }}
            multiline
            maxLength={500}
            textAlignVertical="top"
          />
          <Text style={s.charCount}>{comments.length}/500</Text>
          {commentsWarn && (
            <View style={s.contactWarnBox}>
              <Text style={s.contactWarnText}>⚠️ {PHONE_WARNING}</Text>
            </View>
          )}

          {/* ── BANNER SURGE ──────────────────────────────────────────────── */}
          {surgeInfo && surgeInfo.surge_factor >= 1.03 && (
            <View style={s.surgeBanner}>
              <Text style={s.surgeBannerText}>
                ✨ Reserva protegida por la app · Pago seguro y garantía de servicio
              </Text>
            </View>
          )}

          {/* ── BOTÓN ENVIAR ──────────────────────────────────────────────── */}
          <Pressable
            style={[s.submitBtn, (!canSubmit || loading) && s.submitBtnDisabled]}
            onPress={handleSubmit}
            disabled={!canSubmit || loading}
          >
            <Send size={18} color={canSubmit ? COLORS.bg : COLORS.muted} />
            <Text style={[s.submitBtnText, !canSubmit && { color: COLORS.muted }]}>
              {loading ? 'Enviando solicitud...' : '⚡ Enviar solicitud a grupos disponibles'}
            </Text>
          </Pressable>

          <View style={{ height: 40 }} />
        </ScrollView>

      </View>
      )}
      <TimePickerModal
        visible={showTimePicker}
        value={eventTime}
        title="Hora de inicio"
        onConfirm={(t) => { setEventTime(t); setShowTimePicker(false); }}
        onClose={() => setShowTimePicker(false)}
      />
    </View>
  );
}

// ─── Styles ──────────────────────────────────────────────────────────────────

const s = StyleSheet.create({
  root: { flex: 1, backgroundColor: COLORS.bg },

  // ── Tabs ──────────────────────────────────────────────────────────────────
  tabBar: {
    flexDirection: 'row',
    borderBottomWidth: 1, borderBottomColor: COLORS.border,
    backgroundColor: COLORS.bg,
  },
  tabBtn: {
    flex: 1, paddingVertical: 13, alignItems: 'center',
    borderBottomWidth: 2, borderBottomColor: 'transparent',
  },
  tabBtnActive: { borderBottomColor: COLORS.green },
  tabBtnText:   { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted2 },
  tabBtnTextActive: { color: COLORS.green, fontFamily: FONTS.bodySemiBold },
  tabBadge:     { color: '#FF5252', fontFamily: FONTS.bodySemiBold },

  // ── Mis solicitudes ───────────────────────────────────────────────────────
  emptyMine: { alignItems: 'center', paddingVertical: 60, paddingHorizontal: 20 },
  emptyMineEmoji: { fontSize: 48, marginBottom: 14 },
  emptyMineTitle: { fontFamily: FONTS.title, fontSize: 20, color: COLORS.text, marginBottom: 8 },
  emptyMineSub:   { fontFamily: FONTS.body, fontSize: 14, color: COLORS.muted2, textAlign: 'center' },

  mineCard: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border,
    padding: SPACING.lg, marginBottom: 12,
  },
  mineCardTop:  { flexDirection: 'row', alignItems: 'flex-start', gap: 10, marginBottom: 8 },
  mineCardType: { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.text, textTransform: 'capitalize' },
  mineCardGenre: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2 },
  mineCardDate:  { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2, marginTop: 3 },

  statusBadge: {
    borderRadius: RADIUS.full, borderWidth: 1,
    paddingHorizontal: 10, paddingVertical: 5, alignSelf: 'flex-start',
  },
  statusBadgeText: { fontFamily: FONTS.bodyMedium, fontSize: 11 },

  cancelBtn: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 8,
    borderRadius: RADIUS.md, paddingVertical: 10,
    borderWidth: 1, borderColor: 'rgba(255,82,82,0.4)',
    backgroundColor: 'rgba(255,82,82,0.08)',
  },
  cancelBtnDisabled: { opacity: 0.5 },
  cancelBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: '#FF5252' },

  // ── Propuesta de grupo (en_negociacion) ──────────────────────────────────
  mineCardNeg: {
    borderColor: 'rgba(255,179,0,0.40)',
    backgroundColor: 'rgba(255,179,0,0.04)',
  },
  proposalBox: {
    backgroundColor: 'rgba(255,179,0,0.06)',
    borderRadius: RADIUS.md, borderWidth: 1, borderColor: 'rgba(255,179,0,0.25)',
    padding: 12, marginBottom: 10,
  },
  proposalGroupRow: { flexDirection: 'row', alignItems: 'center', gap: 12, marginBottom: 10 },
  proposalAvatar: { width: 48, height: 48, borderRadius: 24, borderWidth: 2, borderColor: 'rgba(255,179,0,0.4)' },
  proposalAvatarPlaceholder: {
    width: 48, height: 48, borderRadius: 24,
    backgroundColor: 'rgba(255,179,0,0.12)', alignItems: 'center', justifyContent: 'center',
    borderWidth: 1, borderColor: 'rgba(255,179,0,0.30)',
  },
  proposalGroupName: { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.text },
  proposalGroupSub: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, marginTop: 2 },
  viewProfileBtn: {
    backgroundColor: 'rgba(0,230,118,0.10)',
    borderRadius: RADIUS.md, paddingHorizontal: 10, paddingVertical: 7,
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.30)',
  },
  viewProfileBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 12, color: COLORS.green },
  proposalMsg: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2, lineHeight: 19, marginBottom: 12 },
  proposalBtnRow: { flexDirection: 'row', gap: 10 },
  rejectProposalBtn: {
    flex: 1, alignItems: 'center', justifyContent: 'center', paddingVertical: 11,
    borderRadius: RADIUS.md, borderWidth: 1, borderColor: 'rgba(255,82,82,0.40)',
    backgroundColor: 'rgba(255,82,82,0.08)',
  },
  rejectProposalBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: '#FF5252' },
  acceptProposalBtn: {
    flex: 1, alignItems: 'center', justifyContent: 'center', paddingVertical: 11,
    borderRadius: RADIUS.md, backgroundColor: COLORS.green,
  },
  acceptProposalBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.bg },

  // ── Desglose de precio en propuesta ──────────────────────────────────────
  proposalPriceBox: {
    backgroundColor: 'rgba(0,0,0,0.25)',
    borderRadius: RADIUS.md, borderWidth: 1, borderColor: 'rgba(255,179,0,0.15)',
    padding: 10, marginBottom: 10, gap: 6,
  },
  proposalPriceRow:   { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center' },
  proposalPriceLabel: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2 },
  proposalPriceVal:   { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: '#FFB300' },
  proposalPriceValSub:{ fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.text },
  totalRow: {
    marginTop: 6, paddingTop: 8,
    borderTopWidth: 1, borderTopColor: 'rgba(255,179,0,0.25)',
  },
  totalLabel: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.text },
  totalVal:   { fontFamily: FONTS.title, fontSize: 16, color: '#FFB300' },

  arrivalRow: {
    marginTop: 6, paddingTop: 8,
    borderTopWidth: 1, borderTopColor: 'rgba(255,179,0,0.15)',
  },
  arrivalLabel: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.text },
  arrivalVal:   { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: '#FFB300' },

  startTimeNote: {
    backgroundColor: 'rgba(0,230,118,0.06)', borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.2)',
    paddingHorizontal: 10, paddingVertical: 7, marginTop: 4,
  },
  startTimeNoteText: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, lineHeight: 17 },

  demandBanner: {
    backgroundColor: 'rgba(0,230,118,0.07)',
    borderRadius: RADIUS.md, borderWidth: 1, borderColor: 'rgba(0,230,118,0.22)',
    paddingHorizontal: 12, paddingVertical: 9, marginBottom: 10,
  },
  demandBannerText: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.green, lineHeight: 17 },

  surgeBanner: {
    backgroundColor: 'rgba(0,230,118,0.07)',
    borderRadius: RADIUS.md, borderWidth: 1, borderColor: 'rgba(0,230,118,0.22)',
    paddingHorizontal: 14, paddingVertical: 10, marginBottom: 14,
  },
  surgeBannerText: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.green, lineHeight: 19 },

  proposalNotesBox: {
    marginTop: 4, paddingTop: 8,
    borderTopWidth: 1, borderTopColor: 'rgba(255,179,0,0.15)',
  },
  proposalNotesText: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, lineHeight: 18 },

  header: {
    flexDirection: 'row', alignItems: 'center', gap: 14,
    paddingHorizontal: SPACING.xl, paddingVertical: 12,
    borderBottomWidth: 1, borderBottomColor: COLORS.border,
  },
  backBtn: {
    width: 40, height: 40, borderRadius: 12,
    backgroundColor: COLORS.card, borderWidth: 1, borderColor: COLORS.border,
    alignItems: 'center', justifyContent: 'center',
  },
  headerTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 16, color: COLORS.text },
  headerSub:   { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, marginTop: 1 },

  scroll: { padding: SPACING.xl },

  infoBanner: {
    backgroundColor: 'rgba(0,230,118,0.08)',
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.25)',
    borderRadius: RADIUS.lg, padding: 14, marginBottom: 24,
  },
  infoBannerText: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.green, lineHeight: 20 },

  sectionTitle: {
    fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.text,
    marginTop: 24, marginBottom: 12,
  },
  minNote: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, fontWeight: 'normal' },
  hintText: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted, marginBottom: 10, lineHeight: 18 },

  genreSelected: {
    backgroundColor: 'rgba(0,230,118,0.06)', borderRadius: RADIUS.md,
    padding: 10, marginTop: 4,
  },
  genreSelectedText: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2 },

  input: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: COLORS.border,
    paddingHorizontal: 14, paddingVertical: 13,
    fontFamily: FONTS.body, fontSize: 14, color: COLORS.text,
    marginBottom: 10,
  },
  inputMulti: { minHeight: 90, paddingTop: 13 },
  charCount:  { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted, textAlign: 'right', marginTop: -6, marginBottom: 10 },
  row2:       { flexDirection: 'row', gap: 10 },

  chipGrid: { flexDirection: 'row', gap: 8, flexWrap: 'wrap', marginBottom: 4 },
  chip: {
    paddingHorizontal: 13, paddingVertical: 10,
    borderRadius: RADIUS.full,
    backgroundColor: COLORS.card, borderWidth: 1, borderColor: COLORS.border,
  },
  chipActive:     { backgroundColor: 'rgba(0,230,118,0.12)', borderColor: COLORS.green },
  chipText:       { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted2 },
  chipTextActive: { color: COLORS.green },

  calendarWrapper: {
    borderRadius: RADIUS.lg,
    overflow: 'hidden',
    borderWidth: 1,
    borderColor: COLORS.border,
    marginBottom: 4,
  },
  calendar: { borderRadius: RADIUS.lg },
  durationRow: { flexDirection: 'row', gap: 8, marginBottom: 4 },
  durationBtn: {
    flex: 1, alignItems: 'center', paddingVertical: 12,
    backgroundColor: COLORS.card, borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: COLORS.border,
  },
  durationBtnActive:     { borderColor: COLORS.green, backgroundColor: 'rgba(0,230,118,0.12)' },
  durationBtnText:       { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted2 },
  durationBtnTextActive: { color: COLORS.green },

  dateBtn: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: COLORS.border,
    paddingHorizontal: 14, paddingVertical: 14, marginBottom: 10,
  },
  dateBtnText: { fontFamily: FONTS.bodyMedium, fontSize: 14, color: COLORS.text },

  timeChip: {
    flexDirection: 'row', alignItems: 'center', gap: 10,
    backgroundColor: COLORS.card, borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: COLORS.border,
    paddingHorizontal: 14, paddingVertical: 15, marginBottom: 10,
  },
  timeChipActive:     { borderColor: COLORS.green, backgroundColor: 'rgba(0,230,118,0.08)' },
  timeChipText:       { fontFamily: FONTS.body, fontSize: 15, color: COLORS.muted2, flex: 1 },
  timeChipTextActive: { fontFamily: FONTS.bodySemiBold, color: COLORS.green },

  mapSection:    { marginBottom: 10, marginTop: -4 },
  mapConfirmBtn: {
    flexDirection: 'row', alignItems: 'center', gap: 8,
    backgroundColor: 'rgba(0,230,118,0.08)', borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: COLORS.green,
    paddingVertical: 11, paddingHorizontal: 14,
  },
  mapConfirmBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.green, flex: 1 },
  mapConfirmed: {
    flexDirection: 'row', alignItems: 'center', gap: 8,
    backgroundColor: 'rgba(0,230,118,0.08)', borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: COLORS.green,
    paddingVertical: 11, paddingHorizontal: 14,
  },
  mapConfirmedText: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.green },
  mapLink:          { fontFamily: FONTS.body, fontSize: 11, color: COLORS.green, opacity: 0.7, marginTop: 2 },

  submitBtn: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 10,
    backgroundColor: COLORS.green, borderRadius: RADIUS.lg,
    paddingVertical: 16, marginTop: 28,
  },
  submitBtnDisabled: { backgroundColor: COLORS.card, borderWidth: 1, borderColor: COLORS.border },
  submitBtnText:     { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.bg },

  calOverlay: { flex: 1, backgroundColor: 'rgba(0,0,0,0.7)', justifyContent: 'flex-end' },
  calSheet: {
    backgroundColor: COLORS.card, borderTopLeftRadius: 24, borderTopRightRadius: 24,
    paddingTop: 20, paddingBottom: 32,
    borderTopWidth: 1, borderTopColor: COLORS.border,
  },
  calTitle:     { fontFamily: FONTS.title, fontSize: 20, color: COLORS.text, textAlign: 'center', marginBottom: 12 },
  calClose:     { marginTop: 16, alignItems: 'center' },
  calCloseText: { fontFamily: FONTS.bodyMedium, fontSize: 14, color: COLORS.muted2 },

  contactWarnBox: {
    backgroundColor: 'rgba(255,179,0,0.10)',
    borderRadius: RADIUS.md, borderWidth: 1, borderColor: 'rgba(255,179,0,0.35)',
    paddingHorizontal: 12, paddingVertical: 9, marginTop: 6, marginBottom: 6,
  },
  contactWarnText: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: '#FFB300', lineHeight: 17 },

  // ── GPS Location ──────────────────────────────────────────────────────────
  locationLoadingRow: {
    flexDirection: 'row', alignItems: 'center', gap: 10,
    paddingVertical: 14, paddingHorizontal: 4, marginBottom: 10,
  },
  locationLoadingText: { fontFamily: FONTS.body, fontSize: 14, color: COLORS.muted2 },
  locationCard: {
    flexDirection: 'row', alignItems: 'center', gap: 12,
    backgroundColor: 'rgba(0,230,118,0.07)',
    borderRadius: RADIUS.md, borderWidth: 1, borderColor: 'rgba(0,230,118,0.30)',
    paddingHorizontal: 14, paddingVertical: 13, marginBottom: 10,
  },
  locationCardCity: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.text },
  locationCardMunicipio: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, marginTop: 2 },
  locationEditBtn: {
    backgroundColor: 'rgba(0,230,118,0.12)', borderRadius: RADIUS.md,
    paddingHorizontal: 12, paddingVertical: 7,
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.35)',
  },
  locationEditBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 12, color: COLORS.green },
});
