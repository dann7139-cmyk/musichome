import React, { useCallback, useEffect, useRef, useState } from 'react';
import {
  ActivityIndicator,
  Alert,
  Animated,
  Dimensions,
  Easing,
  FlatList,
  NativeScrollEvent,
  NativeSyntheticEvent,
  Platform,
  Pressable,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import { X } from 'lucide-react-native';
import { useNavigation } from '@react-navigation/native';
import { supabase } from '../../config/supabase';
import { useAuth } from '../../context/AuthContext';
import { COLORS, FONTS, RADIUS } from '../../config/theme';
import { useClientProposals, ClientProposal } from '../../context/ClientProposalContext';
import ProposalCard, {
  PROPOSAL_CARD_WIDTH,
  PROPOSAL_CARD_GAP,
  PROPOSAL_LIST_PADDING,
} from './ProposalCard';

const { height: H } = Dimensions.get('window');

const SHEET_HEIGHT  = Math.round(H * 0.72);
const SNAP_INTERVAL = PROPOSAL_CARD_WIDTH + PROPOSAL_CARD_GAP;
const ABOVE_HEIGHT  = H - SHEET_HEIGHT;

// ── Punto verde pulsante ──────────────────────────────────────────────────────
const LiveDot = React.memo(function LiveDot() {
  const scale = useRef(new Animated.Value(1)).current;
  useEffect(() => {
    const anim = Animated.loop(
      Animated.sequence([
        Animated.timing(scale, { toValue: 1.5, duration: 700, useNativeDriver: true }),
        Animated.timing(scale, { toValue: 1.0, duration: 700, useNativeDriver: true }),
      ])
    );
    anim.start();
    return () => anim.stop();
  }, []);
  return <Animated.View style={[st.dot, { transform: [{ scale }] }]} />;
});

// ── Wrapper animado por scroll ────────────────────────────────────────────────
const AnimatedCard = React.memo(function AnimatedCard({
  item, index, scrollX, hiringId, focusedIndex,
  onHire, onDismiss, onViewProfile, clientPhotoUrl,
}: {
  item:           ClientProposal;
  index:          number;
  scrollX:        Animated.Value;
  hiringId:       string | null;
  focusedIndex:   number;
  onHire:         (proposal: ClientProposal) => void;
  onDismiss:      (id: string) => void;
  onViewProfile:  (proposal: ClientProposal) => void;
  clientPhotoUrl: string | null;
}) {
  const iRange = [
    (index - 1) * SNAP_INTERVAL,
    index       * SNAP_INTERVAL,
    (index + 1) * SNAP_INTERVAL,
  ];
  const scale   = scrollX.interpolate({ inputRange: iRange, outputRange: [0.93, 1.0, 0.93], extrapolate: 'clamp' });
  const opacity = scrollX.interpolate({ inputRange: iRange, outputRange: [0.60, 1.0, 0.60], extrapolate: 'clamp' });

  return (
    <Animated.View style={{ transform: [{ scale }], opacity }}>
      <ProposalCard
        proposal={item}
        clientPhotoUrl={clientPhotoUrl}
        onHire={onHire}
        onDismiss={onDismiss}
        onViewProfile={() => onViewProfile(item)}
        isHiring={hiringId === item.id}
        isBlocked={hiringId !== null && hiringId !== item.id}
      />
    </Animated.View>
  );
});

// ── ProposalCarousel ──────────────────────────────────────────────────────────
export default function ProposalCarousel() {
  const { proposals, dismiss, dismissAll, reviveAll } = useClientProposals();
  const { profile } = useAuth();
  const navigation  = useNavigation<any>();

  const clientPhotoUrl = profile?.avatar_url ?? null;

  const [visible,      setVisible]      = useState(false);
  const [hiringId,     setHiringId]     = useState<string | null>(null);
  const [focusedIndex, setFocusedIndex] = useState(0);

  const scrollX         = useRef(new Animated.Value(0)).current;
  const slideAnim       = useRef(new Animated.Value(SHEET_HEIGHT)).current;
  const dimAnim         = useRef(new Animated.Value(0)).current;
  const prevCount       = useRef(0);
  const flatListRef     = useRef<FlatList<ClientProposal>>(null);
  const scrollOffsetRef = useRef(0);

  // Rastrear offset del scroll en el hilo JS
  useEffect(() => {
    const id = scrollX.addListener(({ value }) => { scrollOffsetRef.current = value; });
    return () => scrollX.removeListener(id);
  }, [scrollX]);

  // Ajustar focusedIndex cuando se eliminan tarjetas
  useEffect(() => {
    if (proposals.length === 0) return;
    setFocusedIndex(prev => Math.min(prev, proposals.length - 1));
  }, [proposals.length]);

  // Limpiar hiringId si esa propuesta ya no existe
  useEffect(() => {
    if (hiringId && !proposals.find(p => p.id === hiringId)) {
      setHiringId(null);
    }
  }, [proposals, hiringId]);

  // ── Animación del sheet ───────────────────────────────────────────────────
  useEffect(() => {
    const was = prevCount.current;
    const now = proposals.length;

    if (was === 0 && now > 0) {
      setVisible(true);
      setFocusedIndex(0);
      slideAnim.setValue(SHEET_HEIGHT);
      Animated.parallel([
        Animated.spring(slideAnim, { toValue: 0, tension: 65, friction: 11, useNativeDriver: true }),
        Animated.timing(dimAnim,   { toValue: 1, duration: 300, useNativeDriver: true }),
      ]).start();
    } else if (was > 0 && now === 0) {
      setHiringId(null);
      Animated.parallel([
        Animated.timing(slideAnim, { toValue: SHEET_HEIGHT, duration: 340, easing: Easing.in(Easing.cubic), useNativeDriver: true }),
        Animated.timing(dimAnim,   { toValue: 0, duration: 280, useNativeDriver: true }),
      ]).start(() => setVisible(false));
    } else if (now > was && was > 0) {
      // Nueva cotización — scroll parcial Uber-style
      const newIdx  = now - 1;
      const target  = newIdx * SNAP_INTERVAL;
      const current = scrollOffsetRef.current;
      const partial = Math.round(current + (target - current) * 0.65);
      setTimeout(() => {
        flatListRef.current?.scrollToOffset({ offset: partial, animated: true });
      }, 180);
    }

    prevCount.current = now;
  }, [proposals.length]);

  // ── Handler: ver perfil del grupo ────────────────────────────────────────
  const handleViewProfile = useCallback((proposal: ClientProposal) => {
    if (proposal.group) {
      navigation.navigate('GroupDetail', { group: proposal.group });
    }
  }, [navigation]);

  // ── Handler: contratar y pagar ────────────────────────────────────────────
  const handleHire = useCallback(async (proposal: ClientProposal) => {
    if (hiringId) return;

    // Cotización PROGRAMADA: directo al checkout con la cotización (el
    // checkout crea evento + reserva y la marca aceptada al pagar — mismo
    // flujo que aceptar desde el detalle). Sin RPC express.
    if (proposal.kind === 'scheduled' && proposal.raw) {
      dismiss(proposal.id);   // cierra la tarjeta (y el sheet si era la única)
      navigation.navigate('QuotePayment', { quote: proposal.raw });
      return;
    }

    setHiringId(proposal.id);
    console.log('[⚡ TAP] Contratar y pagar', { proposalId: proposal.id, requestId: proposal.request_id, groupOwnerId: proposal.group_owner_id });

    try {
      // 1. Fijar el grupo elegido en la solicitud (sin cambiar status para que el RPC funcione)
      if (proposal.group_owner_id) {
        const { error: updateErr } = await supabase
          .from('event_requests')
          .update({
            negotiating_group_id: proposal.group_owner_id,
            proposal_data:        proposal.proposal_data,
          })
          .eq('id', proposal.request_id);
        console.log('[⚡ UPDATE] negotiating_group_id', updateErr ? `ERROR: ${updateErr.message}` : 'OK');
      }

      // 2. Crear la reserva vía RPC (espera status 'en_negociacion')
      const { data, error } = await supabase.rpc('client_accept_proposal', {
        p_request_id: proposal.request_id,
      });
      console.log('[⚡ RPC] client_accept_proposal', JSON.stringify(data), error ? `ERROR: ${error.message}` : null);

      if (error || !data?.ok) {
        const code = data?.error ?? error?.message ?? '';
        if (code === 'not_in_negotiation') {
          Alert.alert(
            'Ya contratado',
            'Este evento ya fue confirmado. Puedes continuar desde "Mis Eventos".',
            [{ text: 'Ver mis eventos', onPress: () => navigation.navigate('ClientReservations') }],
          );
          void reviveAll();
          return;
        }
        if (code === 'group_unavailable' || code.includes('date_blocked') || code.includes('date_taken')) {
          Alert.alert(
            'Fecha no disponible',
            'El grupo ya tiene otro evento o bloqueó esa fecha. Esta propuesta fue descartada.',
            [{ text: 'Entendido', onPress: () => dismiss(proposal.id) }],
          );
          return;
        }
        if (code.includes('daily_event_limit')) {
          Alert.alert(
            'Fecha no disponible',
            'Este grupo ya tiene 2 eventos agendados ese día. Esta propuesta fue descartada.',
            [{ text: 'Entendido', onPress: () => dismiss(proposal.id) }],
          );
          return;
        }
        if (code.includes('time_overlap')) {
          Alert.alert(
            'Horario no disponible',
            'El horario de esta propuesta choca con otro evento del grupo ese día. Esta propuesta fue descartada.',
            [{ text: 'Entendido', onPress: () => dismiss(proposal.id) }],
          );
          return;
        }
        Alert.alert('Error', `No se pudo confirmar. ${code || 'Inténtalo de nuevo.'}`);
        return;
      }

      const reservationId: string = data.reservation_id;
      console.log('[⚡ NAV] Navegando a QuotePayment con reservationId:', reservationId);

      if (!reservationId) {
        navigation.navigate('ClientReservations');
        return;
      }

      // 3. Navegar a pago — construimos la reserva con los datos del proposal
      //    para no depender de un fetch extra (evita RLS timing issues).
      //    QuotePaymentScreen solo necesita id + total_price + display fields.
      const reservationForPayment = {
        id:          reservationId,
        total_price: Number(proposal.proposal_data.total_amount ?? 0),
        event_date:  proposal.request?.event_date ?? null,
        address:     proposal.request?.location_city ?? '',
        hours_count: proposal.request?.hours ?? 1,
        group: {
          id:            proposal.group?.id ?? '',
          name:          proposal.group?.name ?? 'Grupo',
          profile_image: proposal.group?.profile_image ?? null,
        },
        package: null,
      };

      void reviveAll();
      navigation.navigate('QuotePayment', { reservation: reservationForPayment });
    } catch (e: any) {
      console.log('[⚡ CATCH] Error inesperado:', e.message);
      Alert.alert('Error', e.message ?? 'Inténtalo de nuevo.');
    } finally {
      setHiringId(null);
    }
  }, [hiringId, navigation, reviveAll, dismiss]);

  // ── Callbacks de lista ────────────────────────────────────────────────────
  const handleMomentumScrollEnd = useCallback((e: NativeSyntheticEvent<NativeScrollEvent>) => {
    const x   = e.nativeEvent.contentOffset.x;
    const idx = Math.round(x / SNAP_INTERVAL);
    setFocusedIndex(Math.max(0, Math.min(idx, proposals.length - 1)));
  }, [proposals.length]);

  const renderItem = useCallback(({ item, index }: { item: ClientProposal; index: number }) => (
    <AnimatedCard
      item={item}
      index={index}
      scrollX={scrollX}
      hiringId={hiringId}
      focusedIndex={focusedIndex}
      onHire={handleHire}
      onDismiss={dismiss}
      onViewProfile={handleViewProfile}
      clientPhotoUrl={clientPhotoUrl}
    />
  ), [scrollX, hiringId, focusedIndex, handleHire, dismiss, handleViewProfile, clientPhotoUrl]);

  const keyExtractor  = useCallback((item: ClientProposal) => item.id, []);
  const getItemLayout = useCallback((_: any, index: number) => ({
    length: PROPOSAL_CARD_WIDTH,
    offset: index * SNAP_INTERVAL,
    index,
  }), []);

  if (!visible && proposals.length === 0) return null;

  const count = proposals.length;

  return (
    <>
      {/* Backdrop oscurecido */}
      <Animated.View
        pointerEvents="none"
        style={[
          st.backdrop,
          { opacity: dimAnim.interpolate({ inputRange: [0, 1], outputRange: [0, 0.4] }) },
        ]}
      />

      {/* Sheet */}
      <Animated.View
        style={[st.sheet, { transform: [{ translateY: slideAnim }] }]}
        pointerEvents="box-none"
      >
        {/* Header */}
        <View style={st.header}>
          <View style={st.headerLeft}>
            <LiveDot />
            <Text style={st.headerTx}>
              {count === 1 ? '1 grupo te cotizó' : `${count} grupos te cotizaron`}
            </Text>
          </View>
          {/* X: cierra el carrusel (equivale a "Ignorar todas por ahora") */}
          <Pressable
            onPress={dismissAll}
            hitSlop={10}
            disabled={hiringId !== null}
            style={({ pressed }) => [st.headerX, pressed && { opacity: 0.6 }]}
          >
            <X size={16} color={COLORS.text} />
          </Pressable>
        </View>

        {/* Tarjetas */}
        <Animated.FlatList
          ref={flatListRef as any}
          data={proposals}
          keyExtractor={keyExtractor}
          renderItem={renderItem}
          getItemLayout={getItemLayout}
          horizontal
          showsHorizontalScrollIndicator={false}
          contentContainerStyle={{ paddingHorizontal: PROPOSAL_LIST_PADDING }}
          ItemSeparatorComponent={() => <View style={{ width: PROPOSAL_CARD_GAP }} />}
          snapToInterval={SNAP_INTERVAL}
          snapToAlignment="start"
          decelerationRate="fast"
          windowSize={3}
          removeClippedSubviews={Platform.OS === 'android'}
          onScroll={Animated.event(
            [{ nativeEvent: { contentOffset: { x: scrollX } } }],
            { useNativeDriver: true }
          )}
          onMomentumScrollEnd={handleMomentumScrollEnd}
          scrollEventThrottle={16}
        />

        {/* Indicador de deslizar — fuera de la tarjeta, solo si hay más de una */}
        {count > 1 && (
          <View style={st.swipeHint} pointerEvents="none">
            <Text style={st.swipeHintTx}>‹  desliza para ver las {count} cotizaciones  ›</Text>
          </View>
        )}

        {/* Botón ignorar todas */}
        <Pressable
          style={({ pressed }) => [st.dismissAllBtn, pressed && { opacity: 0.6 }]}
          onPress={dismissAll}
          disabled={hiringId !== null}
        >
          {hiringId !== null
            ? <ActivityIndicator size="small" color={COLORS.muted} />
            : <Text style={st.dismissAllTx}>Ignorar todas por ahora</Text>
          }
        </Pressable>
      </Animated.View>
    </>
  );
}

// ── Styles ────────────────────────────────────────────────────────────────────
const st = StyleSheet.create({
  backdrop: {
    position:        'absolute',
    top:             0, left: 0, right: 0,
    height:          ABOVE_HEIGHT,
    backgroundColor: '#000',
    zIndex:          9998,
  },
  sheet: {
    position:  'absolute',
    bottom:    0, left: 0, right: 0,
    height:    SHEET_HEIGHT,
    zIndex:    9999,
    shadowColor:   '#000',
    shadowOffset:  { width: 0, height: -6 },
    shadowOpacity: 0.55,
    shadowRadius:  18,
    elevation:     14,
  },
  header: {
    flexDirection:     'row',
    alignItems:        'center',
    justifyContent:    'space-between',
    paddingHorizontal: 20,
    paddingVertical:   12,
    backgroundColor:   'rgba(6,12,6,0.97)',
    borderTopLeftRadius:  22,
    borderTopRightRadius: 22,
    borderBottomWidth:    1,
    borderBottomColor:    'rgba(0,230,118,0.1)',
  },
  headerLeft: { flexDirection: 'row', alignItems: 'center', gap: 8 },
  dot: {
    width: 7, height: 7, borderRadius: 3.5,
    backgroundColor: COLORS.green,
    shadowColor:     COLORS.green,
    shadowOffset:    { width: 0, height: 0 },
    shadowOpacity:   1, shadowRadius: 4, elevation: 4,
  },
  headerTx: {
    fontFamily: FONTS.bodySemiBold, fontSize: 13,
    color: COLORS.text, letterSpacing: 0.2,
  },
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

  dismissAllBtn: {
    alignItems: 'center',
    paddingVertical: 13,
    backgroundColor: 'rgba(6,12,6,0.97)',
    borderTopWidth: 1,
    borderTopColor: 'rgba(255,255,255,0.05)',
  },
  dismissAllTx: {
    fontFamily: FONTS.bodyMedium, fontSize: 13,
    color: COLORS.muted, letterSpacing: 0.1,
  },
});
