import React, { useCallback, useEffect, useRef, useState } from 'react';
import {
  Animated,
  Dimensions,
  Easing,
  FlatList,
  NativeSyntheticEvent,
  NativeScrollEvent,
  Platform,
  Pressable,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import { X } from 'lucide-react-native';
import { useNavigation, useNavigationState } from '@react-navigation/native';
import * as Location from 'expo-location';
import { useExpress, ExpressDispatch } from '../../context/ExpressContext';
import { supabase } from '../../config/supabase';
import { COLORS, FONTS } from '../../config/theme';
import ExpressCard, { CARD_WIDTH, CARD_GAP, LIST_PADDING } from './ExpressCard';

const { height: H } = Dimensions.get('window');

// Misma altura que ProposalCarousel (cliente) — la tarjeta creció con la fila
// de cliente + Detalles y con 0.48 los botones quedaban cortados abajo.
const SHEET_HEIGHT  = Math.round(H * 0.72);
const SNAP_INTERVAL = CARD_WIDTH + CARD_GAP;
const ABOVE_HEIGHT  = H - SHEET_HEIGHT;

// ── Live dot ──────────────────────────────────────────────────────────────────
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

// ── Per-card Animated wrapper ─────────────────────────────────────────────────
type UserLoc = { latitude: number; longitude: number } | null;

const AnimatedCard = React.memo(function AnimatedCard({
  item, index, scrollX, isBlocked, isFocused, onCotizar, onDismiss, userLocation, groupPhotoUrl,
}: {
  item:           ExpressDispatch;
  index:          number;
  scrollX:        Animated.Value;
  isBlocked:      boolean;
  isFocused:      boolean;
  onCotizar:      (id: string) => void;
  onDismiss:      (id: string) => void;
  userLocation:   UserLoc;
  groupPhotoUrl:  string | null;
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
      <ExpressCard
        dispatch={item}
        isBlocked={isBlocked}
        isFocused={isFocused}
        onCotizar={onCotizar}
        onDismiss={onDismiss}
        userLocation={userLocation}
        groupPhotoUrl={groupPhotoUrl}
      />
    </Animated.View>
  );
});

// ── Imperativo: el carrusel de PROGRAMADAS se muestra encima — mientras esté
// abierto, este carrusel se repliega y regresa intacto al cerrarse aquél ──────
let _setCollapsed: ((c: boolean) => void) | null = null;
export function setExpressCarouselCollapsed(collapsed: boolean) {
  _setCollapsed?.(collapsed);
}

// ── Main carousel ─────────────────────────────────────────────────────────────
export default function ExpressCarousel() {
  const { dispatches, dismiss } = useExpress();
  const navigation = useNavigation<any>();

  // Hide the carousel entirely while IncomingExpress is covering the screen.
  // useNavigationState reads the parent (root) stack, which includes IncomingExpress.
  const isExpressScreenOpen = useNavigationState(
    state => state?.routes?.some(r => r.name === 'IncomingExpress') ?? false
  );

  // After closing IncomingExpress, wait 5 s before re-showing the carousel.
  const prevExpressOpenRef  = useRef(false);
  const [reshowBlocked, setReshowBlocked] = useState(false);
  useEffect(() => {
    const wasOpen = prevExpressOpenRef.current;
    prevExpressOpenRef.current = isExpressScreenOpen;
    if (wasOpen && !isExpressScreenOpen) {
      setReshowBlocked(true);
      const t = setTimeout(() => setReshowBlocked(false), 5_000);
      return () => clearTimeout(t);
    }
  }, [isExpressScreenOpen]);

  const [userLocation, setUserLocation]   = useState<UserLoc>(null);
  const [groupPhotoUrl, setGroupPhotoUrl] = useState<string | null>(null);

  useEffect(() => {
    // La ruta animada de la tarjeta depende de esto: getLastKnownPositionAsync
    // devuelve null sin fix cacheado (reinicio/arranque frío) → fallback a un
    // fix fresco SOLO si el permiso ya está concedido (no dispara prompt).
    (async () => {
      try {
        const last = await Location.getLastKnownPositionAsync({});
        if (last) {
          setUserLocation({ latitude: last.coords.latitude, longitude: last.coords.longitude });
          return;
        }
        const { granted } = await Location.getForegroundPermissionsAsync();
        if (!granted) return;
        const pos = await Location.getCurrentPositionAsync({ accuracy: Location.Accuracy.Balanced });
        setUserLocation({ latitude: pos.coords.latitude, longitude: pos.coords.longitude });
      } catch {}
    })();

    supabase.auth.getUser().then(({ data }) => {
      if (!data.user) return;
      supabase
        .from('groups')
        .select('profile_image')
        .eq('owner_id', data.user.id)
        .single()
        .then(({ data: g }) => { if (g?.profile_image) setGroupPhotoUrl(g.profile_image); });
    });
  }, []);

  const [visible, setVisible]       = useState(false);
  const [quotingId, setQuotingId]   = useState<string | null>(null);
  const [focusedIndex, setFocusedIndex] = useState(0);
  const [collapsed, setCollapsed]   = useState(false);

  useEffect(() => {
    _setCollapsed = setCollapsed;
    return () => { _setCollapsed = null; };
  }, []);

  const scrollX         = useRef(new Animated.Value(0)).current;
  const slideAnim       = useRef(new Animated.Value(SHEET_HEIGHT)).current;
  const dimAnim         = useRef(new Animated.Value(0)).current;
  const prevCount       = useRef(0);
  const flatListRef     = useRef<FlatList<ExpressDispatch>>(null);
  const scrollOffsetRef = useRef(0);

  // Track JS-thread scroll offset for partial auto-scroll calculations
  useEffect(() => {
    const id = scrollX.addListener(({ value }) => { scrollOffsetRef.current = value; });
    return () => scrollX.removeListener(id);
  }, [scrollX]);

  // Clamp focusedIndex when cards are removed
  useEffect(() => {
    if (dispatches.length === 0) return;
    setFocusedIndex(prev => Math.min(prev, dispatches.length - 1));
  }, [dispatches.length]);

  // ── Sheet + backdrop visibility ─────────────────────────────────────────
  useEffect(() => {
    const was = prevCount.current;
    const now = dispatches.length;

    if (was === 0 && now > 0) {
      setVisible(true);
      setFocusedIndex(0);
      slideAnim.setValue(SHEET_HEIGHT);
      Animated.parallel([
        Animated.spring(slideAnim, { toValue: 0, tension: 65, friction: 11, useNativeDriver: true }),
        Animated.timing(dimAnim,   { toValue: 1, duration: 300, useNativeDriver: true }),
      ]).start();
    } else if (was > 0 && now === 0) {
      setQuotingId(null);
      Animated.parallel([
        Animated.timing(slideAnim, { toValue: SHEET_HEIGHT, duration: 340, easing: Easing.in(Easing.cubic), useNativeDriver: true }),
        Animated.timing(dimAnim,   { toValue: 0, duration: 280, useNativeDriver: true }),
      ]).start(() => setVisible(false));
    } else if (now > was && was > 0) {
      // New card arrived — scroll 65% toward it (Uber-style, non-aggressive)
      const newIdx  = now - 1;
      const target  = newIdx * SNAP_INTERVAL;
      const current = scrollOffsetRef.current;
      const partial = Math.round(current + (target - current) * 0.65);
      setTimeout(() => {
        flatListRef.current?.scrollToOffset({ offset: partial, animated: true });
      }, 180);
    }

    prevCount.current = now;
  }, [dispatches.length]);

  // Clear quotingId if that dispatch was removed
  useEffect(() => {
    if (quotingId && !dispatches.find(d => d.id === quotingId)) {
      setQuotingId(null);
    }
  }, [dispatches, quotingId]);

  // ── Callbacks ───────────────────────────────────────────────────────────
  const handleCotizar = useCallback((id: string) => {
    setQuotingId(id);
    const d = dispatches.find(x => x.id === id);
    navigation.navigate('ProposeRequest', { dispatchId: id, request: d?.request });
  }, [navigation, dispatches]);

  // X de la tarjeta: cierra el carrusel completo (mismo mecanismo que Ignorar
  // por tarjeta — recuperable desde el banner ⚡ del dashboard)
  const handleCloseAll = useCallback(() => {
    dispatches.forEach(d => dismiss(d.id));
  }, [dispatches, dismiss]);


  // Update focused card when scroll settles on a snap point
  const handleMomentumScrollEnd = useCallback((e: NativeSyntheticEvent<NativeScrollEvent>) => {
    const x   = e.nativeEvent.contentOffset.x;
    const idx = Math.round(x / SNAP_INTERVAL);
    setFocusedIndex(Math.max(0, Math.min(idx, dispatches.length - 1)));
  }, [dispatches.length]);

  // ── Render item ─────────────────────────────────────────────────────────
  const renderItem = useCallback(({ item, index }: { item: ExpressDispatch; index: number }) => (
    <AnimatedCard
      item={item}
      index={index}
      scrollX={scrollX}
      isBlocked={quotingId !== null && quotingId !== item.id}
      isFocused={focusedIndex === index}
      onCotizar={handleCotizar}
      onDismiss={dismiss}
      userLocation={userLocation}
      groupPhotoUrl={groupPhotoUrl}
    />
  ), [scrollX, quotingId, focusedIndex, handleCotizar, dismiss, userLocation, groupPhotoUrl]);

  const keyExtractor  = useCallback((item: ExpressDispatch) => item.id, []);
  const getItemLayout = useCallback((_: any, index: number) => ({
    length: CARD_WIDTH,
    offset: index * SNAP_INTERVAL,
    index,
  }), []);

  if (isExpressScreenOpen || reshowBlocked || collapsed) return null;
  if (!visible && dispatches.length === 0) return null;

  const count = dispatches.length;

  return (
    <>
      {/* Dim backdrop above the sheet */}
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
        <View style={st.header}>
          <View style={st.headerLeft}>
            <LiveDot />
            <Text style={st.headerTx}>
              {count === 1 ? '1 solicitud express' : `${count} solicitudes express`}
            </Text>
          </View>
          {/* X: cierra el carrusel (recuperable desde el banner ⚡ del dashboard) */}
          <Pressable
            onPress={handleCloseAll}
            hitSlop={10}
            style={({ pressed }) => [st.headerX, pressed && { opacity: 0.6 }]}
          >
            <X size={16} color={COLORS.text} />
          </Pressable>
        </View>

        <Animated.FlatList
          ref={flatListRef as any}
          data={dispatches}
          keyExtractor={keyExtractor}
          renderItem={renderItem}
          getItemLayout={getItemLayout}
          horizontal
          showsHorizontalScrollIndicator={false}
          contentContainerStyle={{ paddingHorizontal: LIST_PADDING }}
          ItemSeparatorComponent={() => <View style={{ width: CARD_GAP }} />}
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
            <Text style={st.swipeHintTx}>‹  desliza para ver las {count} solicitudes  ›</Text>
          </View>
        )}
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
});
