import { useStripe } from '@stripe/stripe-react-native';
import { LinearGradient } from 'expo-linear-gradient';
import { ArrowLeft, Clock, Flame, Tag, TrendingUp, Users, Zap } from 'lucide-react-native';
import React, { useEffect, useMemo, useRef, useState } from 'react';
import {
  ActivityIndicator,
  Alert,
  Animated,
  AppState,
  KeyboardAvoidingView,
  Platform,
  Pressable,
  RefreshControl,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  View,
} from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { supabase } from '../../config/supabase';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';

interface BidPackage {
  id: string;
  name: string;
  duration_days: number;
  min_bid: number;
  description: string;
}

interface ActiveBid {
  bid_amount: number;
  bid_ends_at: string | null;
}

const DISCOUNT_TIERS = [
  { minDays: 15, rate: 0.15, label: '15%' },
  { minDays: 8,  rate: 0.10, label: '10%' },
  { minDays: 4,  rate: 0.05, label: '5%'  },
  { minDays: 1,  rate: 0,    label: null   },
];

function discountRate(days: number): number {
  for (const tier of DISCOUNT_TIERS) {
    if (days >= tier.minDays) return tier.rate;
  }
  return 0;
}

function calcTotal(perDay: number, days: number): number {
  return Math.round(perDay * days * (1 - discountRate(days)));
}

function calcSavings(perDay: number, days: number): number {
  return Math.round(perDay * days * discountRate(days));
}

const EMOJI: Record<string, string> = {
  'Básico': '⚡',
  'Medio':  '🚀',
  'Premium': '👑',
};

function daysLeft(endsAt: string | null): number | null {
  if (!endsAt) return null;
  const diff = new Date(endsAt).getTime() - Date.now();
  return diff > 0 ? Math.ceil(diff / 86_400_000) : 0;
}

function fmtDate(endsAt: string | null): string {
  if (!endsAt) return '';
  return new Date(endsAt).toLocaleDateString('es-MX', {
    day: 'numeric', month: 'long', year: 'numeric',
  });
}

export default function BiddingScreen({ navigation, route }: any) {
  const suggestedGap: number | undefined = route?.params?.suggestedGap;
  const { initPaymentSheet, presentPaymentSheet } = useStripe();

  const [packages, setPackages]         = useState<BidPackage[]>([]);
  const [activeBid, setActiveBid]       = useState<ActiveBid | null>(null);
  const [selected, setSelected]         = useState<BidPackage | null>(null);
  const [customMode, setCustomMode]     = useState(false);
  const [perDayInput, setPerDayInput]   = useState('');
  const [customDays, setCustomDays]     = useState('7');
  const [loading, setLoading]           = useState(true);
  const [refreshing, setRefreshing]     = useState(false);
  const [submitting, setSubmitting]     = useState(false);
  const [highlightSuggested, setHighlightSuggested] = useState(false);

  const inputRef = useRef<any>(null);

  // Competition & position
  const [myPosition, setMyPosition]           = useState<number | null>(null);
  const [competitorCount, setCompetitorCount] = useState(0);
  const [activeBidAmounts, setActiveBidAmounts] = useState<number[]>([]);
  const [myGroupId, setMyGroupId]             = useState<string | null>(null);
  const [myCity, setMyCity]                   = useState<string | null>(null);
  const [myState, setMyState]                 = useState<string | null>(null);
  const [cityDemand, setCityDemand]           = useState<any>(null);
  const [liveAlert, setLiveAlert]             = useState(false);
  const [postBidSuccess, setPostBidSuccess]   = useState(false);

  const [retentionAlert, setRetentionAlert]   = useState(false);

  const posAnim              = useRef(new Animated.Value(1)).current;
  const prevPosRef           = useRef<number | null>(null);
  const lastLiveAlertRef     = useRef<number>(0);
  const postBidAnim          = useRef(new Animated.Value(0)).current;
  const paymentAttemptedRef  = useRef(false);
  const preBidAmountRef      = useRef<number>(0);
  const preBidEndsAtRef      = useRef<string | null>(null);
  const preBidOrderAmountRef = useRef<number>(0);  // monto esperado de la orden
  const appStateRef          = useRef(AppState.currentState);
  const retentionShownRef    = useRef(false);

  useEffect(() => { fetchData(); }, []);

  // Auto-fill cuando viene con suggestedGap desde Dashboard
  useEffect(() => {
    if (loading || !suggestedGap) return;
    const amount = (activeBid?.bid_amount ?? 0) + suggestedGap;
    setCustomMode(true);
    setSelected(null);
    setPerDayInput(String(amount));
    setCustomDays('7');
    setHighlightSuggested(true);
    setTimeout(() => {
      inputRef.current?.focus();
      setTimeout(() => setHighlightSuggested(false), 2500);
    }, 350);
  }, [loading]);

  // ── Realtime: actualizar ranking cuando cambian bids en la ciudad ──────────
  useEffect(() => {
    if ((!myCity && !myState) || !myGroupId) return;
    const refreshBids = async () => {
      const now = new Date().toISOString();
      const q = supabase
        .from('groups')
        .select('id, bid_amount, bid_ends_at')
        .gt('bid_amount', 0)
        .gt('bid_ends_at', now)
        .order('bid_amount', { ascending: false });
      if (myState) q.eq('state', myState);          // estado disponible → prioridad
      else if (myCity) q.eq('city', myCity);        // fallback: ciudad
      const { data } = await q;
      const bids = (data ?? []) as { id: string; bid_amount: number; bid_ends_at: string }[];
      const amounts = bids.map(b => b.bid_amount);
      setActiveBidAmounts(amounts);
      setCompetitorCount(bids.length);
      const pos = bids.findIndex(b => b.id === myGroupId);
      const newPos = pos >= 0 ? pos + 1 : null;

      // Detectar cambio de posición y animar
      if (prevPosRef.current !== null && newPos !== null && newPos !== prevPosRef.current) {
        Animated.sequence([
          Animated.timing(posAnim, { toValue: 1.35, duration: 200, useNativeDriver: true }),
          Animated.spring(posAnim,  { toValue: 1,    useNativeDriver: true }),
        ]).start();
      }

      // FOMO en tiempo real — throttle: 1 alerta cada 20–30s, solo si no hay otra activa
      const nowMs = Date.now();
      const throttleMs = 20_000 + Math.random() * 10_000; // 20–30s
      if (!postBidSuccess && nowMs - lastLiveAlertRef.current > throttleMs) {
        lastLiveAlertRef.current = nowMs;
        setLiveAlert(true);
        setTimeout(() => setLiveAlert(false), 2500);
      }
      prevPosRef.current = newPos;
      setMyPosition(newPos);
    };

    // Realtime: escuchar cambios en el estado (o ciudad como fallback)
    const rtFilter = myState ? `state=eq.${myState}` : `city=eq.${myCity}`;
    const rtKey    = myState ? 'state-' + myState : 'city-' + myCity;
    const ch = supabase
      .channel('bidding-live-' + rtKey)
      .on('postgres_changes', {
        event: 'UPDATE', schema: 'public', table: 'groups',
        filter: rtFilter,
      }, refreshBids)
      .subscribe();

    return () => { supabase.removeChannel(ch); };
  }, [myCity, myState, myGroupId]);

  // ── Post-bid: verificar pago al regresar al foreground ──────────────────────
  useEffect(() => {
    const sub = AppState.addEventListener('change', async (nextState) => {
      if (appStateRef.current.match(/inactive|background/) && nextState === 'active') {
        if (paymentAttemptedRef.current) {
          paymentAttemptedRef.current = false;
          // Verificar si el bid cambió respecto al valor pre-pago
          const grpRes = await supabase.rpc('get_my_group');
          const grp = Array.isArray(grpRes.data) ? grpRes.data[0] : grpRes.data;
          const newBidAmount  = (grp as any)?.bid_amount  ?? 0;
          const newBidEndsAt  = (grp as any)?.bid_ends_at ?? null;
          const bidAmountChanged = newBidAmount > preBidAmountRef.current;
          const bidEndsAtChanged = newBidEndsAt !== preBidEndsAtRef.current;
          // Validar que el monto acreditado coincide con el monto de la orden
          if (bidAmountChanged) {
            const credited = newBidAmount - preBidAmountRef.current;
            const expected = preBidOrderAmountRef.current;
            if (expected > 0 && Math.abs(credited - expected) > 1) {
              console.error('[PAYMENT_MISMATCH]', {
                expected,
                credited,
                diff: credited - expected,
                preBid: preBidAmountRef.current,
                newBid: newBidAmount,
              });
            }
          }

          if (bidAmountChanged || bidEndsAtChanged) {
            // Pago exitoso confirmado — mostrar banner
            setPostBidSuccess(true);
            postBidAnim.setValue(0);
            Animated.sequence([
              Animated.timing(postBidAnim, { toValue: 1, duration: 300, useNativeDriver: true }),
              Animated.delay(2200),
              Animated.timing(postBidAnim, { toValue: 0, duration: 350, useNativeDriver: true }),
            ]).start(() => setPostBidSuccess(false));
            const { notificationAsync, NotificationFeedbackType } = await import('expo-haptics');
            notificationAsync(NotificationFeedbackType.Success);
          }
        }
      }
      appStateRef.current = nextState;
    });
    return () => sub.remove();
  }, []);

  // ── Micro-retención: recordatorio único a los 30–60s si hay bid activo ──────
  useEffect(() => {
    if (loading) return;
    if (retentionShownRef.current) return;
    // Solo si tiene bid activo
    if (!activeBid?.bid_amount) return;
    const delay = 30_000 + Math.random() * 30_000;
    const t = setTimeout(() => {
      if (retentionShownRef.current) return;
      if (liveAlert || postBidSuccess) return; // no saturar
      retentionShownRef.current = true;
      setRetentionAlert(true);
      setTimeout(() => setRetentionAlert(false), 3000);
    }, delay);
    return () => clearTimeout(t);
  }, [loading]);

  const onRefresh = async () => { setRefreshing(true); await fetchData(); setRefreshing(false); };

  const fetchData = async () => {
    setLoading(true);
    const [{ data: pkgs }, groupRes] = await Promise.all([
      supabase
        .from('bid_packages')
        .select('*')
        .eq('is_active', true)
        .order('min_bid', { ascending: true }),
      supabase.rpc('get_my_group'),
    ]);

    if (pkgs) setPackages(pkgs as BidPackage[]);

    const grp = Array.isArray(groupRes.data) ? groupRes.data[0] : groupRes.data;
    const gid   = (grp as any)?.id    ?? null;
    const city  = (grp as any)?.city  ?? null;
    const state = (grp as any)?.state ?? null;
    setMyGroupId(gid);
    setMyCity(city);
    setMyState(state);

    if (grp && (grp as any).bid_amount > 0) {
      setActiveBid({
        bid_amount:  (grp as any).bid_amount,
        bid_ends_at: (grp as any).bid_ends_at ?? null,
      });
    }

    // Demanda de la ciudad
    if (city) {
      const { data: demandData } = await supabase.rpc('get_city_demand_score', { p_city: city });
      if ((demandData as any)?.ok) setCityDemand(demandData);
    }

    // Fetch active bids — filtrar por estado si disponible, sino por ciudad
    const now = new Date().toISOString();
    const bidsQuery = supabase
      .from('groups')
      .select('id, bid_amount, bid_ends_at')
      .gt('bid_amount', 0)
      .gt('bid_ends_at', now)
      .order('bid_amount', { ascending: false });
    if (state) bidsQuery.eq('state', state);          // estado disponible → prioridad
    else if (city) bidsQuery.eq('city', city);        // fallback: ciudad
    const { data: bidsData } = await bidsQuery;

    const bids = (bidsData ?? []) as { id: string; bid_amount: number; bid_ends_at: string }[];
    const amounts = bids.map(b => b.bid_amount);
    setActiveBidAmounts(amounts);
    setCompetitorCount(bids.length);

    if (gid) {
      const pos = bids.findIndex(b => b.id === gid);
      setMyPosition(pos >= 0 ? pos + 1 : null);
    }

    setLoading(false);
  };

  const handleSelectPackage = (pkg: BidPackage) => {
    setSelected(pkg);
    setCustomMode(false);
    setPerDayInput(String(pkg.min_bid));
  };

  const handleCustomMode = () => {
    setSelected(null);
    setCustomMode(true);
    setPerDayInput('');
    setCustomDays('7');
  };

  const isActiveBidValid = activeBid
    ? activeBid.bid_ends_at && new Date(activeBid.bid_ends_at) > new Date()
    : false;

  const activeDaysLeft  = activeBid ? daysLeft(activeBid.bid_ends_at) : null;
  const isExpiringSoon  = activeDaysLeft !== null && activeDaysLeft <= 1; // < 24h

  // Pre-llena el formulario con la misma puja activa para renovar rápido
  const handleRenewSamePlan = () => {
    if (!activeBid) return;
    setCustomMode(true);
    setSelected(null);
    setPerDayInput(String(activeBid.bid_amount));
    setCustomDays('7');
  };

  // ── Valores calculados ────────────────────────────────────────────────────

  const perDay = useMemo(() => parseFloat(perDayInput) || 0, [perDayInput]);

  const days = useMemo(() => {
    if (customMode) return parseInt(customDays) || 0;
    return selected?.duration_days || 0;
  }, [customMode, customDays, selected]);

  const discount        = useMemo(() => discountRate(days), [days]);
  const totalPrice      = useMemo(() => calcTotal(perDay, days), [perDay, days]);
  const savings         = useMemo(() => calcSavings(perDay, days), [perDay, days]);
  const discountedPerDay = useMemo(
    () => discount > 0 ? Math.round(perDay * (1 - discount)) : perDay,
    [perDay, discount]
  );

  const hasValidInput = perDay > 0 && days > 0 && totalPrice > 0;

  // ── Datos de competencia ──────────────────────────────────────────────────
  const sortedBids  = useMemo(() => [...activeBidAmounts].sort((a, b) => b - a), [activeBidAmounts]);
  const aboveMe     = myPosition != null ? myPosition - 1 : competitorCount;

  // Cuánto falta para superar al grupo inmediatamente arriba
  const gapToNext   = useMemo(() => {
    if (myPosition == null || myPosition <= 1 || sortedBids.length < myPosition - 1) return null;
    const threshold   = sortedBids[myPosition - 2]; // grupo justo arriba
    const myAmount    = activeBid?.bid_amount ?? 0;
    return threshold > myAmount ? threshold - myAmount + 1 : null;
  }, [myPosition, sortedBids, activeBid]);

  // ── "Para quedar #1": monto para superar al líder con colchón del 15% ──────
  const amountToReachTop1 = useMemo(() => {
    const topBid = sortedBids[0] ?? 0;
    const myBid  = activeBid?.bid_amount ?? 0;
    if (topBid <= myBid) return null;   // ya eres el top o no hay competencia
    const gap = topBid - myBid;
    // +10 mínimo de margen + 15% del gap para evitar empates en tiempo real
    return Math.ceil(gap + 10 + gap * 0.15);
  }, [sortedBids, activeBid]);

  // ── Estimación de posición con el monto actual ────────────────────────────

  const estimatedPosition = useMemo(() => {
    if (!hasValidInput) return null;
    const beat = activeBidAmounts.filter(a => a < totalPrice).length;
    const pos  = activeBidAmounts.length - beat + 1;
    return pos;
  }, [hasValidInput, totalPrice, activeBidAmounts]);

  // ── Sugerencias de monto para distintas posiciones ────────────────────────

  const positionHints = useMemo(() => {
    const targetDays = days || (selected?.duration_days ?? 7);
    const sorted = [...activeBidAmounts].sort((a, b) => b - a);

    if (sorted.length === 0) {
      // Sin competencia — sugerencias por nivel de visibilidad
      return [
        { perDay: 150, label: 'visibilidad básica'   },
        { perDay: 300, label: 'más visibilidad'       },
        { perDay: 600, label: 'máxima exposición'     },
      ];
    }

    return [10, 5, 3]
      .filter(t => t <= sorted.length + 5)
      .map(t => {
        const idx       = Math.min(t - 1, sorted.length - 1);
        const threshold = sorted[idx] ?? 0;
        const pDay      = Math.max(Math.ceil((threshold + 1) / Math.max(targetDays, 1)), 50);
        return { perDay: pDay, label: `Top ${t}` };
      });
  }, [activeBidAmounts, days, selected]);

  // ── Submit ────────────────────────────────────────────────────────────────

  const handleConfirm = async () => {
    if (customMode) {
      if (!perDay || perDay < 50) {
        Alert.alert('Monto inválido', 'El precio mínimo es $50 por día.');
        return;
      }
      if (!days || days < 1 || days > 90) {
        Alert.alert('Duración inválida', 'La duración debe ser entre 1 y 90 días.');
        return;
      }
    } else {
      if (!selected) {
        Alert.alert('Selecciona un paquete', 'Elige un paquete o activa el modo personalizado.');
        return;
      }
      if (perDay < selected.min_bid) {
        Alert.alert('Monto muy bajo', `El mínimo por día para "${selected.name}" es $${selected.min_bid}.`);
        return;
      }
    }

    setSubmitting(true);
    try {
      // Paso 1: Crear orden de pago
      const { data: orderData, error: orderErr } = await supabase.rpc('create_bid_order', {
        p_package_id:    customMode ? null : selected!.id,
        p_custom_amount: totalPrice,
        p_duration_days: days,
      });

      console.log('[BiddingScreen] order creada:', orderData, 'error:', orderErr);

      if (orderErr || !orderData?.ok) {
        const msg = orderData?.error ?? orderErr?.message ?? 'Error desconocido';
        Alert.alert('Error al generar pago', msg === 'bid_too_low'
          ? 'El monto mínimo es $50 por día.'
          : msg === 'bid_below_minimum'
          ? `El monto es menor al mínimo del paquete ($${orderData?.min_bid}).`
          : msg);
        return;
      }

      // Paso 2: Crear PaymentIntent en Stripe
      const { data: { session: paySession } } = await supabase.auth.getSession();
      if (!paySession) throw new Error('Sesión expirada. Vuelve a iniciar sesión.');
      const { data: stripeData, error: stripeErr } = await supabase.functions.invoke('create-bid-payment', {
        body: { order_id: orderData.order_id },
        headers: { Authorization: `Bearer ${paySession.access_token}` },
      });

      console.log('[BiddingScreen] stripeData:', JSON.stringify(stripeData), 'error:', stripeErr);

      if (stripeErr) throw new Error(`Error de función: ${stripeErr.message ?? JSON.stringify(stripeErr)}`);
      if (!stripeData) throw new Error('Sin respuesta del servidor de pagos.');
      if (stripeData.error) throw new Error(stripeData.error);

      const clientSecret: string = stripeData.client_secret;
      if (!clientSecret) throw new Error('No se recibió el token de pago.');

      // Paso 3: Inicializar PaymentSheet
      const { error: initErr } = await initPaymentSheet({
        paymentIntentClientSecret: clientSecret,
        merchantDisplayName:       'Daricefy',
        style:                     'alwaysDark',
      });
      if (initErr) throw new Error(`Error al inicializar pago: ${initErr.message}`);

      // Paso 4: Presentar hoja de pago nativa de Stripe
      const { error: payErr } = await presentPaymentSheet();

      if (payErr) {
        if (payErr.code === 'Canceled') {
          Alert.alert('Pago cancelado', 'Puedes intentarlo de nuevo cuando quieras.');
          return;
        }
        throw new Error(payErr.message);
      }

      // Pago exitoso — el webhook de Stripe confirma en segundo plano
      const { notificationAsync, NotificationFeedbackType } = await import('expo-haptics');
      notificationAsync(NotificationFeedbackType.Success);

      setPostBidSuccess(true);
      postBidAnim.setValue(0);
      Animated.sequence([
        Animated.timing(postBidAnim, { toValue: 1, duration: 300, useNativeDriver: true }),
        Animated.delay(2200),
        Animated.timing(postBidAnim, { toValue: 0, duration: 350, useNativeDriver: true }),
      ]).start(() => {
        setPostBidSuccess(false);
        Alert.alert(
          '🚀 ¡Posicionamiento activado!',
          `Tu grupo aparecerá en los primeros lugares durante ${days} día${days > 1 ? 's' : ''}. Se activa en segundos.`,
          [{ text: 'Perfecto', onPress: () => { fetchData(); navigation.goBack(); } }]
        );
      });
    } catch (e: any) {
      console.error('[BiddingScreen] Error:', e.message);
      Alert.alert('Error al generar pago', e.message ?? 'Intenta de nuevo.');
    } finally {
      setSubmitting(false);
    }
  };

  if (loading) {
    return (
      <View style={s.centered}>
        <ActivityIndicator size="large" color={COLORS.green} />
      </View>
    );
  }

  return (
    <SafeAreaView style={s.safe}>
      <KeyboardAvoidingView
        behavior={Platform.OS === 'ios' ? 'padding' : undefined}
        style={{ flex: 1 }}
      >
        {/* ── Header ─────────────────────────────────────────────────────── */}
        <View style={s.header}>
          <Pressable style={s.backBtn} onPress={() => navigation.goBack()}>
            <ArrowLeft size={20} color={COLORS.text} />
          </Pressable>
          <View style={{ flex: 1 }}>
            <View style={s.headerTitleRow}>
              <Flame size={16} color='#FF6B35' />
              <Text style={s.headerTitle}>Aparece en los primeros lugares</Text>
            </View>
            <Text style={s.headerSub}>
              {myCity ? `Mercado de ${myCity} · Más visibilidad = más eventos` : 'Más visibilidad = más eventos'}
            </Text>
          </View>
        </View>

        <ScrollView
          showsVerticalScrollIndicator={false}
          contentContainerStyle={s.scroll}
          keyboardShouldPersistTaps="handled"
          refreshControl={<RefreshControl refreshing={refreshing} onRefresh={onRefresh} tintColor={COLORS.green} />}
        >

          {/* ── Banner de demanda ─────────────────────────────────────── */}
          {cityDemand?.ok && (cityDemand.demand_level === 'very_high' || cityDemand.demand_level === 'high') && (() => {
            const isVeryHigh = cityDemand.demand_level === 'very_high';
            return (
              <View style={[s.compCard, {
                borderColor: isVeryHigh ? 'rgba(251,146,60,0.5)' : 'rgba(0,230,118,0.35)',
                marginBottom: 12,
              }]}>
                <View style={{ flexDirection: 'row', alignItems: 'center', gap: 8, marginBottom: 4 }}>
                  <Text style={{ fontSize: 15 }}>{isVeryHigh ? '⚡' : '🔥'}</Text>
                  <Text style={[s.compTitle, { color: isVeryHigh ? '#FB923C' : COLORS.green }]}>
                    {isVeryHigh
                      ? `Alta demanda en ${cityDemand.city}`
                      : `Buen momento para anunciarte en ${cityDemand.city}`}
                  </Text>
                </View>
                <Text style={[s.compAlertText, { color: COLORS.muted2 }]}>
                  {isVeryHigh
                    ? `${cityDemand.active_bids} grupos ya posicionados · Pocos espacios disponibles · Aprovecha antes de que se llenen`
                    : `${cityDemand.active_groups} grupos activos · Alta competencia hoy · Posicionarte marca la diferencia`}
                </Text>
              </View>
            );
          })()}

          {/* ── Confirmación post-bid ─────────────────────────────────── */}
          {postBidSuccess && (
            <Animated.View style={[
              s.postBidBanner,
              { opacity: postBidAnim, transform: [{ scale: postBidAnim.interpolate({ inputRange: [0, 1], outputRange: [0.95, 1] }) }] },
            ]}>
              <Text style={s.postBidTitle}>🟢 Estás compitiendo por los primeros lugares</Text>
              <Text style={s.postBidSub}>Tu visibilidad aumentará en los próximos minutos</Text>
            </Animated.View>
          )}

          {/* ── Alerta de competencia en vivo — solo si no hay post-bid ── */}
          {liveAlert && !postBidSuccess && (
            <View style={s.liveAlertBanner}>
              <View style={s.liveAlertDot} />
              <Text style={s.liveAlertText}>⚡ Otro grupo acaba de subir su posición</Text>
            </View>
          )}

          {/* ── Micro-retención — solo si no hay otra alerta ─────────── */}
          {retentionAlert && !liveAlert && !postBidSuccess && (
            <View style={s.retentionBanner}>
              <Text style={s.retentionText}>📊 Revisa tu posición — puede haber cambiado</Text>
            </View>
          )}

          {/* ── Power badge ───────────────────────────────────────────── */}
          {myPosition != null && myPosition <= 3 && (
            <View style={s.powerBadgeRow}>
              <Text style={s.powerBadgeEmoji}>
                {myPosition === 1 ? '🥇' : myPosition === 2 ? '🥈' : '🥉'}
              </Text>
              <Text style={s.powerBadgeText}>
                {myPosition === 1 ? 'Más visible en tu ciudad'
                  : myPosition === 2 ? 'Alta visibilidad'
                  : 'Destacado'}
              </Text>
            </View>
          )}

          {/* ── Posición actual + Competencia ─────────────────────────── */}
          <View style={s.statsRow}>
            <View style={s.statCard}>
              <TrendingUp size={14} color={COLORS.green} />
              <Animated.Text style={[s.statNum, { transform: [{ scale: posAnim }] }]}>
                {myPosition != null ? `#${myPosition}` : '—'}
              </Animated.Text>
              <Text style={s.statLabel}>Tu posición</Text>
            </View>
            <View style={[s.statCard, { borderColor: 'rgba(251,146,60,0.35)' }]}>
              <Users size={14} color='#FB923C' />
              <Text style={[s.statNum, { color: '#FB923C' }]}>{competitorCount}</Text>
              <Text style={s.statLabel}>
                {competitorCount === 1 ? 'grupo compite' : 'grupos compiten'}
              </Text>
            </View>
            {myPosition == null && competitorCount > 0 && (
              <View style={[s.statCard, { borderColor: 'rgba(192,132,252,0.35)' }]}>
                <Zap size={14} color='#c084fc' />
                <Text style={[s.statNum, { color: '#c084fc', fontSize: 11 }]}>Sin puja</Text>
                <Text style={s.statLabel}>no posicionado</Text>
              </View>
            )}
          </View>

          {/* ── Panel de competencia ──────────────────────────────────── */}
          {competitorCount > 0 && (
            <View style={s.compCard}>
              <LinearGradient
                colors={['rgba(251,146,60,0.10)', 'rgba(251,146,60,0.02)']}
                style={StyleSheet.absoluteFillObject}
                start={{ x: 0, y: 0 }} end={{ x: 1, y: 1 }}
              />

              {/* Título */}
              <View style={s.compTitleRow}>
                <Flame size={14} color='#FB923C' />
                <Text style={s.compTitle}>Competencia en tiempo real</Text>
              </View>

              {/* Posición + grupos arriba */}
              <View style={s.compRow}>
                {myPosition != null ? (
                  <>
                    <View style={s.compStat}>
                      <Text style={s.compStatNum}>#{myPosition}</Text>
                      <Text style={s.compStatLabel}>Tu posición actual</Text>
                    </View>
                    <View style={s.compDivider} />
                    <View style={s.compStat}>
                      <Text style={[s.compStatNum, { color: '#FB923C' }]}>{aboveMe}</Text>
                      <Text style={s.compStatLabel}>
                        {aboveMe === 1 ? 'grupo arriba de ti' : 'grupos arriba de ti'}
                      </Text>
                    </View>
                  </>
                ) : (
                  <View style={s.compStat}>
                    <Text style={[s.compStatNum, { color: '#c084fc' }]}>{competitorCount}</Text>
                    <Text style={s.compStatLabel}>grupos ya posicionados</Text>
                  </View>
                )}
                {activeDaysLeft != null && activeDaysLeft > 0 && (
                  <>
                    <View style={s.compDivider} />
                    <View style={s.compStat}>
                      <Text style={[s.compStatNum, { color: COLORS.green }]}>{activeDaysLeft}d</Text>
                      <Text style={s.compStatLabel}>tu posición dura</Text>
                    </View>
                  </>
                )}
              </View>

              {/* Alerta: actividad reciente */}
              {competitorCount > 1 && (
                <View style={s.compAlert}>
                  <View style={s.compAlertDot} />
                  <Text style={s.compAlertText}>Un grupo acaba de subir su posición</Text>
                </View>
              )}

              {/* Presión top 3 */}
              {myPosition != null && myPosition <= 3 && (
                <View style={s.compAlert}>
                  <View style={[s.compAlertDot, { backgroundColor: '#FB923C' }]} />
                  <Text style={[s.compAlertText, { color: '#FB923C' }]}>
                    🔥 Mantén tu posición antes de que alguien te supere
                  </Text>
                </View>
              )}

              {/* Presión por demanda alta */}
              {(cityDemand?.demand_level === 'high' || cityDemand?.demand_level === 'very_high') && (
                <View style={s.compAlert}>
                  <View style={s.compAlertDot} />
                  <Text style={s.compAlertText}>
                    Muchos grupos están compitiendo en este momento
                  </Text>
                </View>
              )}

              {/* Gap para subir + botón exacto */}
              {gapToNext != null && (
                <View style={{ gap: 8 }}>
                  <View style={s.compGap}>
                    <TrendingUp size={12} color={COLORS.green} />
                    <Text style={s.compGapText}>
                      Estás a{' '}
                      <Text style={{ color: COLORS.green, fontFamily: FONTS.bodySemiBold }}>
                        ${gapToNext.toLocaleString()}
                      </Text>
                      {' '}de subir al puesto #{(myPosition ?? 0) - 1}
                    </Text>
                  </View>
                  <Pressable
                    style={s.exactGapBtn}
                    onPress={() => {
                      const newPerDay = (activeBid?.bid_amount ?? 0) + gapToNext;
                      setCustomMode(true);
                      setSelected(null);
                      setPerDayInput(String(newPerDay));
                      setCustomDays('7');
                    }}
                  >
                    <TrendingUp size={13} color={COLORS.bg} />
                    <Text style={s.exactGapBtnText}>
                      ⬆ Subir exactamente +${gapToNext.toLocaleString()} para superar al #{(myPosition ?? 0) - 1}
                    </Text>
                  </Pressable>
                </View>
              )}

              {/* 🥇 Para quedar #1 — muestra solo si no eres el top */}
              {amountToReachTop1 != null && (
                <Pressable
                  style={s.top1Btn}
                  onPress={() => {
                    const newTotal = (activeBid?.bid_amount ?? 0) + amountToReachTop1;
                    setCustomMode(true);
                    setSelected(null);
                    setPerDayInput(String(newTotal));
                    setCustomDays('7');
                  }}
                >
                  <Text style={s.top1BtnEmoji}>🥇</Text>
                  <View style={{ flex: 1 }}>
                    <Text style={s.top1BtnTitle}>Para quedar #1 en {myState ?? myCity ?? 'tu zona'}</Text>
                    <Text style={s.top1BtnSub}>
                      Paga{' '}
                      <Text style={{ color: '#FFD700', fontFamily: FONTS.bodySemiBold }}>
                        +${amountToReachTop1.toLocaleString()} más
                      </Text>
                      {' '}y supera al líder actual
                    </Text>
                  </View>
                </Pressable>
              )}
            </View>
          )}

          {/* ── Active bid status ──────────────────────────────────────── */}
          {isActiveBidValid && activeBid && (
            <View style={[s.activeBidCard, isExpiringSoon && s.activeBidCardUrgent]}>
              <LinearGradient
                colors={isExpiringSoon
                  ? ['rgba(239,68,68,0.18)', 'rgba(239,68,68,0.05)']
                  : ['rgba(192,132,252,0.18)', 'rgba(192,132,252,0.05)']}
                style={StyleSheet.absoluteFillObject}
                start={{ x: 0, y: 0 }} end={{ x: 1, y: 1 }}
              />

              {/* Estado */}
              <View style={s.activeBidRow}>
                <View style={[s.activeBidDot, isExpiringSoon && { backgroundColor: '#ef4444' }]} />
                <Text style={[s.activeBidLabel, isExpiringSoon && { color: '#ef4444' }]}>
                  {isExpiringSoon ? '⚠️ Expira en menos de 24h' : 'Posicionamiento activo'}
                </Text>
              </View>

              <Text style={s.activeBidAmount}>${activeBid.bid_amount.toLocaleString()}</Text>

              <View style={s.activeBidMeta}>
                <Clock size={12} color={isExpiringSoon ? '#ef4444' : COLORS.muted2} />
                <Text style={[s.activeBidEnds, isExpiringSoon && { color: '#ef4444' }]}>
                  Termina el {fmtDate(activeBid.bid_ends_at)}
                  {activeDaysLeft !== null && activeDaysLeft > 0
                    ? ` · ${activeDaysLeft} ${activeDaysLeft === 1 ? 'día' : 'días'} restantes`
                    : ' · Hoy'}
                </Text>
              </View>

              {/* Mensajes de urgencia */}
              {isExpiringSoon ? (
                <>
                  <Text style={s.urgencyMsg}>Si no renuevas, perderás tu posición</Text>
                  <Text style={s.urgencyMsgSub}>Otro grupo puede tomar tu lugar</Text>
                </>
              ) : (
                <Text style={s.activeBidNote}>
                  Activa una nueva puja para extender o mejorar tu posición
                </Text>
              )}

              {/* Botón renovar */}
              <Pressable style={[s.renewBtn, isExpiringSoon && s.renewBtnUrgent]} onPress={handleRenewSamePlan}>
                <Flame size={14} color={isExpiringSoon ? '#fff' : COLORS.green} />
                <Text style={[s.renewBtnText, isExpiringSoon && { color: '#fff' }]}>
                  Renovar mismo plan
                </Text>
              </Pressable>

              {isExpiringSoon && (
                <Text style={s.discountHint}>🎁 Renueva hoy y obtén 10% de descuento por volumen</Text>
              )}

              {/* Subida rápida */}
              <View style={s.upsellRow}>
                <Text style={s.upsellLabel}>Subir rápido:</Text>
                {[50, 100, 200].map(amount => (
                  <Pressable
                    key={amount}
                    style={s.upsellBtn}
                    onPress={() => {
                      const newPerDay = (activeBid?.bid_amount ?? 0) + amount;
                      setCustomMode(true);
                      setSelected(null);
                      setPerDayInput(String(newPerDay));
                      setCustomDays('7');
                    }}
                  >
                    <Text style={s.upsellBtnText}>+${amount}</Text>
                  </Pressable>
                ))}
              </View>
            </View>
          )}

          {/* ── Hero ──────────────────────────────────────────────────── */}
          <View style={s.heroCard}>
            <LinearGradient
              colors={['rgba(0,230,118,0.10)', 'rgba(0,0,0,0)']}
              style={StyleSheet.absoluteFillObject}
              start={{ x: 0, y: 0 }} end={{ x: 1, y: 1 }}
            />
            <TrendingUp size={28} color={COLORS.green} />
            <Text style={s.heroTitle}>¿Cómo funciona?</Text>
            <Text style={s.heroBody}>
              Los grupos con puja activa aparecen{' '}
              <Text style={s.heroHighlight}>primero en los resultados</Text>
              {' '}de los clientes. A mayor puja, más arriba apareces.
            </Text>
            <View style={s.heroBullets}>
              <View style={s.heroBullet}>
                <Zap size={13} color={COLORS.green} />
                <Text style={s.heroBulletText}>Badge "Promocionado" visible para clientes</Text>
              </View>
              <View style={s.heroBullet}>
                <Zap size={13} color={COLORS.green} />
                <Text style={s.heroBulletText}>Posición fija durante toda la duración</Text>
              </View>
              <View style={s.heroBullet}>
                <Tag size={13} color={COLORS.green} />
                <Text style={s.heroBulletText}>Entre más días contrates, menor precio por día</Text>
              </View>
            </View>
          </View>

          {/* ── Volume discount tiers ──────────────────────────────────── */}
          <View style={s.tiersCard}>
            <Text style={s.tiersTitle}>Descuentos por volumen</Text>
            <View style={s.tiersRow}>
              {[
                { label: '1–3 días', sub: 'Precio normal' },
                { label: '4–7 días', sub: '5% dto.' },
                { label: '8–14 días', sub: '10% dto.' },
                { label: '15–30 días', sub: '15% dto.' },
              ].map((tier, i) => {
                const active = i === 0
                  ? days >= 1 && days <= 3
                  : i === 1
                  ? days >= 4 && days <= 7
                  : i === 2
                  ? days >= 8 && days <= 14
                  : days >= 15;
                return (
                  <View key={i} style={[s.tierChip, active && s.tierChipActive]}>
                    <Text style={[s.tierLabel, active && s.tierLabelActive]}>{tier.label}</Text>
                    <Text style={[s.tierSub, active && s.tierSubActive]}>{tier.sub}</Text>
                  </View>
                );
              })}
            </View>
          </View>

          {/* ── Packages ──────────────────────────────────────────────── */}
          <Text style={s.sectionTitle}>Elige tu paquete</Text>

          {packages.map((pkg) => {
            const isSelected = selected?.id === pkg.id;
            const pkgTotal   = calcTotal(pkg.min_bid, pkg.duration_days);
            const pkgDisc    = discountRate(pkg.duration_days);
            return (
              <Pressable
                key={pkg.id}
                style={[s.pkgCard, isSelected && s.pkgCardSelected]}
                onPress={() => handleSelectPackage(pkg)}
              >
                {isSelected && (
                  <LinearGradient
                    colors={['rgba(0,230,118,0.10)', 'rgba(0,0,0,0)']}
                    style={StyleSheet.absoluteFillObject}
                    start={{ x: 0, y: 0 }} end={{ x: 1, y: 1 }}
                  />
                )}
                <View style={s.pkgLeft}>
                  <Text style={s.pkgEmoji}>{EMOJI[pkg.name] ?? '⚡'}</Text>
                  <View style={{ flex: 1 }}>
                    <Text style={[s.pkgName, isSelected && s.pkgNameSelected]}>{pkg.name}</Text>
                    <Text style={s.pkgDesc}>{pkg.description}</Text>
                  </View>
                </View>
                <View style={s.pkgRight}>
                  <Text style={[s.pkgPrice, isSelected && s.pkgPriceSelected]}>
                    ${pkg.min_bid.toLocaleString()}<Text style={s.pkgPerDay}>/día</Text>
                  </Text>
                  <Text style={s.pkgDays}>{pkg.duration_days} días</Text>
                  <Text style={[s.pkgTotal, isSelected && { color: COLORS.green }]}>
                    Total ~${pkgTotal.toLocaleString()}
                  </Text>
                  {pkgDisc > 0 && (
                    <View style={s.pkgDiscBadge}>
                      <Text style={s.pkgDiscBadgeText}>{(pkgDisc * 100).toFixed(0)}% dto.</Text>
                    </View>
                  )}
                </View>
                {isSelected && <View style={s.pkgCheck}><Text style={s.pkgCheckText}>✓</Text></View>}
              </Pressable>
            );
          })}

          {/* ── Monto por día + sugerencias de posición ───────────────── */}
          {selected && !customMode && (
            <View style={s.customAmountBox}>
              <Text style={s.customAmountLabel}>
                Precio por día (mínimo ${selected.min_bid})
              </Text>
              <View style={s.customAmountRow}>
                <Text style={s.customAmountPrefix}>$</Text>
                <TextInput
                  style={s.customAmountInput}
                  keyboardType="numeric"
                  value={perDayInput}
                  onChangeText={setPerDayInput}
                  placeholder={String(selected.min_bid)}
                  placeholderTextColor={COLORS.muted}
                />
                <Text style={s.customAmountSuffix}>/día</Text>
              </View>

              {/* Sugerencias de posición */}
              <Text style={s.hintsLabel}>Sugerencias:</Text>
              <View style={s.hintsRow}>
                {positionHints.map((h, i) => (
                  <Pressable
                    key={i}
                    style={s.hintChip}
                    onPress={() => setPerDayInput(String(h.perDay))}
                  >
                    <Text style={s.hintChipAmount}>Con ${h.perDay.toLocaleString()}</Text>
                    <Text style={s.hintChipLabel}>→ {h.label}</Text>
                  </Pressable>
                ))}
              </View>

              {estimatedPosition != null && (
                <View style={s.estimateRow}>
                  <TrendingUp size={12} color={COLORS.green} />
                  <Text style={s.estimateText}>
                    Con este monto estarías en la posición{' '}
                    <Text style={{ color: COLORS.green }}>#{estimatedPosition}</Text>
                  </Text>
                </View>
              )}

              <Text style={s.customAmountHint}>
                Mayor monto → posición más alta en los resultados
              </Text>
            </View>
          )}

          {/* ── Divider ───────────────────────────────────────────────── */}
          <View style={s.dividerRow}>
            <View style={s.divider} />
            <Text style={s.dividerText}>o personaliza</Text>
            <View style={s.divider} />
          </View>

          {/* ── Free-form bid ─────────────────────────────────────────── */}
          <Pressable
            style={[s.customCard, customMode && s.customCardActive]}
            onPress={handleCustomMode}
          >
            {customMode && (
              <LinearGradient
                colors={['rgba(192,132,252,0.12)', 'rgba(0,0,0,0)']}
                style={StyleSheet.absoluteFillObject}
                start={{ x: 0, y: 0 }} end={{ x: 1, y: 1 }}
              />
            )}
            <Text style={[s.customCardTitle, customMode && s.customCardTitleActive]}>
              🎯 Puja personalizada
            </Text>
            <Text style={s.customCardSub}>
              Elige exactamente cuánto pagar por día y cuántos días
            </Text>
          </Pressable>

          {customMode && (
            <View style={s.customFields}>
              {highlightSuggested && (
                <View style={s.suggestBanner}>
                  <Text style={s.suggestBannerText}>⬆ Monto sugerido para superar al siguiente — confirma o ajusta</Text>
                </View>
              )}
              <View style={s.customFieldRow}>
                <Text style={s.customFieldLabel}>Precio por día (mín. $50)</Text>
                <View style={[s.customFieldInput, highlightSuggested && s.customFieldInputHighlight]}>
                  <Text style={s.customAmountPrefix}>$</Text>
                  <TextInput
                    ref={inputRef}
                    style={s.customAmountInput}
                    keyboardType="numeric"
                    value={perDayInput}
                    onChangeText={(v) => { setPerDayInput(v); setHighlightSuggested(false); }}
                    placeholder="100"
                    placeholderTextColor={COLORS.muted}
                  />
                  <Text style={s.customAmountSuffix}>/día</Text>
                </View>
              </View>
              <View style={[s.customFieldRow, { marginTop: 10 }]}>
                <Text style={s.customFieldLabel}>Duración (días)</Text>
                <View style={s.customFieldInput}>
                  <TextInput
                    style={[s.customAmountInput, { paddingLeft: 14 }]}
                    keyboardType="numeric"
                    value={customDays}
                    onChangeText={setCustomDays}
                    placeholder="7"
                    placeholderTextColor={COLORS.muted}
                  />
                </View>
              </View>

              {/* Sugerencias en modo personalizado */}
              <Text style={[s.hintsLabel, { marginTop: 12 }]}>Sugerencias:</Text>
              <View style={s.hintsRow}>
                {positionHints.map((h, i) => (
                  <Pressable
                    key={i}
                    style={s.hintChip}
                    onPress={() => setPerDayInput(String(h.perDay))}
                  >
                    <Text style={s.hintChipAmount}>Con ${h.perDay.toLocaleString()}</Text>
                    <Text style={s.hintChipLabel}>→ {h.label}</Text>
                  </Pressable>
                ))}
              </View>

              {estimatedPosition != null && (
                <View style={s.estimateRow}>
                  <TrendingUp size={12} color={COLORS.green} />
                  <Text style={s.estimateText}>
                    Posición estimada:{' '}
                    <Text style={{ color: COLORS.green }}>#{estimatedPosition}</Text>
                  </Text>
                </View>
              )}
            </View>
          )}

          {/* ── Summary ───────────────────────────────────────────────── */}
          {hasValidInput && (
            <View style={s.summaryCard}>
              <Text style={s.summaryTitle}>Resumen</Text>

              <View style={s.summaryRow}>
                <Text style={s.summaryKey}>Precio por día</Text>
                <View style={s.summaryValRow}>
                  {discount > 0 && (
                    <Text style={s.summaryValStrike}>${perDay.toLocaleString()}</Text>
                  )}
                  <Text style={s.summaryVal}>${discountedPerDay.toLocaleString()}</Text>
                </View>
              </View>

              <View style={s.summaryRow}>
                <Text style={s.summaryKey}>Duración</Text>
                <Text style={s.summaryVal}>
                  {days} día{days > 1 ? 's' : ''}{' '}
                  <Text style={{ color: COLORS.muted2, fontSize: 12 }}>
                    · Tu posicionamiento dura {days} día{days > 1 ? 's' : ''}
                  </Text>
                </Text>
              </View>

              {discount > 0 && (
                <View style={s.summaryRow}>
                  <Text style={s.summaryKey}>Descuento</Text>
                  <Text style={[s.summaryVal, { color: COLORS.green }]}>
                    {(discount * 100).toFixed(0)}% · Ahorras ${savings.toLocaleString()}
                  </Text>
                </View>
              )}

              <View style={s.summaryDivider} />

              <View style={s.summaryRow}>
                <Text style={s.summaryTotalKey}>Total a pagar</Text>
                <Text style={s.summaryTotalVal}>${totalPrice.toLocaleString()}</Text>
              </View>

              {estimatedPosition != null && (
                <View style={s.summaryRow}>
                  <Text style={s.summaryKey}>Posición estimada</Text>
                  <Text style={[s.summaryVal, { color: COLORS.green }]}>#{estimatedPosition}</Text>
                </View>
              )}

              <View style={s.summaryRow}>
                <Text style={s.summaryKey}>Badge</Text>
                <Text style={[s.summaryVal, { color: COLORS.green }]}>⚡ Promocionado</Text>
              </View>
            </View>
          )}

          <View style={{ height: 20 }} />
        </ScrollView>

        {/* ── CTA ───────────────────────────────────────────────────────── */}
        <View style={s.footer}>
          <Pressable
            style={[s.ctaBtn, (submitting || !hasValidInput) && s.ctaBtnDisabled]}
            onPress={handleConfirm}
            disabled={submitting || !hasValidInput}
          >
            {submitting
              ? <ActivityIndicator size="small" color={COLORS.bg} />
              : <Text style={s.ctaBtnText}>
                  {hasValidInput
                    ? `🚀 Subir de posición · $${totalPrice.toLocaleString()}`
                    : '🚀 Subir de posición'}
                </Text>
            }
          </Pressable>
          {hasValidInput && !submitting && (
            <Text style={s.ctaSubText}>Recomendado para subir de posición</Text>
          )}
        </View>
      </KeyboardAvoidingView>
    </SafeAreaView>
  );
}

const s = StyleSheet.create({
  safe:     { flex: 1, backgroundColor: COLORS.bg },
  centered: { flex: 1, backgroundColor: COLORS.bg, alignItems: 'center', justifyContent: 'center' },

  // Header
  header: {
    flexDirection: 'row', alignItems: 'center', gap: 12,
    paddingHorizontal: SPACING.xl, paddingTop: 4, paddingBottom: 14,
    borderBottomWidth: 1, borderBottomColor: COLORS.border,
  },
  backBtn: {
    width: 38, height: 38, borderRadius: 10,
    backgroundColor: COLORS.card, borderWidth: 1, borderColor: COLORS.border,
    alignItems: 'center', justifyContent: 'center',
  },
  headerTitleRow: { flexDirection: 'row', alignItems: 'center', gap: 6, marginBottom: 2 },
  headerTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.text },
  headerSub:   { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, marginTop: 1 },

  scroll: { paddingHorizontal: SPACING.xl, paddingTop: 16, paddingBottom: 24 },

  // Position + competition stats
  statsRow: {
    flexDirection: 'row', gap: 10, marginBottom: 16,
  },
  statCard: {
    flex: 1, alignItems: 'center', gap: 4,
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.25)',
    paddingVertical: 12,
  },
  statNum:   { fontFamily: FONTS.title, fontSize: 20, color: COLORS.green, lineHeight: 24 },
  statLabel: { fontFamily: FONTS.body, fontSize: 10, color: COLORS.muted2, textAlign: 'center' },

  // Active bid
  activeBidCard: {
    borderRadius: RADIUS.xl, borderWidth: 1.5, borderColor: 'rgba(192,132,252,0.4)',
    backgroundColor: COLORS.card, padding: 16, marginBottom: 16, overflow: 'hidden',
  },
  activeBidRow:    { flexDirection: 'row', alignItems: 'center', gap: 7, marginBottom: 6 },
  activeBidDot:    { width: 8, height: 8, borderRadius: 4, backgroundColor: '#c084fc' },
  activeBidLabel:  { fontFamily: FONTS.bodySemiBold, fontSize: 12, color: '#c084fc', textTransform: 'uppercase', letterSpacing: 0.6 },
  activeBidAmount: { fontFamily: FONTS.title, fontSize: 28, color: COLORS.text, marginBottom: 6 },
  activeBidMeta:   { flexDirection: 'row', alignItems: 'center', gap: 5, marginBottom: 8 },
  activeBidEnds:   { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, flex: 1 },
  activeBidNote:   { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted, fontStyle: 'italic' },

  // Hero
  heroCard: {
    borderRadius: RADIUS.xl, borderWidth: 1, borderColor: COLORS.greenGlow,
    backgroundColor: COLORS.card, padding: 20, marginBottom: 16, overflow: 'hidden', gap: 8,
  },
  heroTitle:      { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.text },
  heroBody:       { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2, lineHeight: 20 },
  heroHighlight:  { color: COLORS.green, fontFamily: FONTS.bodySemiBold },
  heroBullets:    { gap: 6, marginTop: 4 },
  heroBullet:     { flexDirection: 'row', alignItems: 'center', gap: 8 },
  heroBulletText: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2 },

  // Volume tiers
  tiersCard: {
    borderRadius: RADIUS.xl, borderWidth: 1, borderColor: COLORS.border,
    backgroundColor: COLORS.card2, padding: 14, marginBottom: 20,
  },
  tiersTitle: {
    fontFamily: FONTS.bodySemiBold, fontSize: 11, color: COLORS.muted2,
    textTransform: 'uppercase', letterSpacing: 0.8, marginBottom: 10,
  },
  tiersRow:       { flexDirection: 'row', gap: 6 },
  tierChip: {
    flex: 1, borderRadius: RADIUS.md, borderWidth: 1, borderColor: COLORS.border,
    backgroundColor: COLORS.card, padding: 8, alignItems: 'center',
  },
  tierChipActive:  { borderColor: COLORS.green, backgroundColor: COLORS.greenMuted },
  tierLabel:       { fontFamily: FONTS.bodySemiBold, fontSize: 10, color: COLORS.muted2, textAlign: 'center', marginBottom: 2 },
  tierLabelActive: { color: COLORS.green },
  tierSub:         { fontFamily: FONTS.body, fontSize: 9, color: COLORS.muted, textAlign: 'center' },
  tierSubActive:   { color: COLORS.green },

  sectionTitle: {
    fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.muted2,
    textTransform: 'uppercase', letterSpacing: 0.8, marginBottom: 12,
  },

  // Packages
  pkgCard: {
    flexDirection: 'row', alignItems: 'center',
    borderRadius: RADIUS.xl, borderWidth: 1, borderColor: COLORS.border,
    backgroundColor: COLORS.card, padding: 16, marginBottom: 10,
    overflow: 'hidden', position: 'relative',
  },
  pkgCardSelected: { borderColor: COLORS.green },
  pkgLeft:  { flexDirection: 'row', alignItems: 'center', gap: 12, flex: 1 },
  pkgEmoji: { fontSize: 26 },
  pkgName:  { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.text, marginBottom: 2 },
  pkgNameSelected: { color: COLORS.green },
  pkgDesc:  { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2 },
  pkgRight: { alignItems: 'flex-end', gap: 2 },
  pkgPrice: { fontFamily: FONTS.title, fontSize: 18, color: COLORS.text },
  pkgPriceSelected: { color: COLORS.green },
  pkgPerDay: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2 },
  pkgDays:   { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted2 },
  pkgTotal:  { fontFamily: FONTS.bodySemiBold, fontSize: 12, color: COLORS.muted2 },
  pkgDiscBadge: {
    backgroundColor: COLORS.greenMuted, borderRadius: RADIUS.full,
    borderWidth: 1, borderColor: COLORS.green,
    paddingHorizontal: 7, paddingVertical: 2,
  },
  pkgDiscBadgeText: { fontFamily: FONTS.bodySemiBold, fontSize: 9, color: COLORS.green },
  pkgCheck: {
    position: 'absolute', top: 10, right: 10,
    width: 20, height: 20, borderRadius: 10,
    backgroundColor: COLORS.green, alignItems: 'center', justifyContent: 'center',
  },
  pkgCheckText: { fontFamily: FONTS.bodySemiBold, fontSize: 11, color: COLORS.bg },

  // Custom amount input
  customAmountBox: {
    borderRadius: RADIUS.xl, borderWidth: 1, borderColor: COLORS.border,
    backgroundColor: COLORS.card2, padding: 14, marginBottom: 12,
  },
  customAmountLabel:  { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted2, marginBottom: 8 },
  customAmountRow: {
    flexDirection: 'row', alignItems: 'center',
    borderWidth: 1, borderColor: COLORS.border,
    borderRadius: RADIUS.md, backgroundColor: COLORS.card,
    paddingHorizontal: 14, height: 48,
  },
  customAmountPrefix: { fontFamily: FONTS.bodySemiBold, fontSize: 16, color: COLORS.muted2, marginRight: 4 },
  customAmountInput:  { flex: 1, fontFamily: FONTS.bodySemiBold, fontSize: 16, color: COLORS.text },
  customAmountSuffix: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted, marginLeft: 4 },
  customAmountHint:   { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted, marginTop: 6, fontStyle: 'italic' },

  // Position hints
  hintsLabel: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted2, marginTop: 10, marginBottom: 6 },
  hintsRow:   { flexDirection: 'row', gap: 8, flexWrap: 'wrap' },
  hintChip: {
    flexDirection: 'row', alignItems: 'center', gap: 4,
    backgroundColor: 'rgba(0,230,118,0.08)', borderRadius: RADIUS.full,
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.25)',
    paddingHorizontal: 10, paddingVertical: 5,
  },
  hintChipAmount: { fontFamily: FONTS.bodySemiBold, fontSize: 11, color: COLORS.green },
  hintChipLabel:  { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted2 },

  // Estimate row
  estimateRow: {
    flexDirection: 'row', alignItems: 'center', gap: 6,
    marginTop: 8, backgroundColor: 'rgba(0,230,118,0.06)',
    borderRadius: RADIUS.md, paddingHorizontal: 10, paddingVertical: 6,
  },
  estimateText: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.muted2 },

  // Divider
  dividerRow:  { flexDirection: 'row', alignItems: 'center', gap: 10, marginVertical: 16 },
  divider:     { flex: 1, height: 1, backgroundColor: COLORS.border },
  dividerText: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted },

  // Custom bid card
  customCard: {
    borderRadius: RADIUS.xl, borderWidth: 1, borderColor: COLORS.border,
    backgroundColor: COLORS.card, padding: 16, marginBottom: 10, overflow: 'hidden',
  },
  customCardActive:      { borderColor: '#c084fc' },
  customCardTitle:       { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.text, marginBottom: 4 },
  customCardTitleActive: { color: '#c084fc' },
  customCardSub:         { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2 },

  // Custom fields
  customFields: {
    borderRadius: RADIUS.xl, borderWidth: 1, borderColor: '#c084fc33',
    backgroundColor: COLORS.card2, padding: 14, marginBottom: 12,
  },
  customFieldRow:   { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', gap: 12 },
  customFieldLabel: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted2, flex: 1 },
  customFieldInput: {
    flexDirection: 'row', alignItems: 'center',
    borderWidth: 1, borderColor: COLORS.border,
    borderRadius: RADIUS.md, backgroundColor: COLORS.card,
    paddingHorizontal: 10, height: 44, minWidth: 130,
  },
  customFieldInputHighlight: {
    borderColor: COLORS.green,
    backgroundColor: 'rgba(0,230,118,0.07)',
  },
  suggestBanner: {
    backgroundColor: 'rgba(0,230,118,0.12)',
    borderRadius: RADIUS.sm,
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.4)',
    paddingHorizontal: 12, paddingVertical: 8, marginBottom: 10,
  },
  suggestBannerText: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.green },

  // Summary
  summaryCard: {
    borderRadius: RADIUS.xl, borderWidth: 1, borderColor: COLORS.border,
    backgroundColor: COLORS.card2, padding: 16, marginBottom: 12, gap: 10,
  },
  summaryTitle:     { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.muted2, marginBottom: 4 },
  summaryRow:       { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center' },
  summaryValRow:    { flexDirection: 'row', alignItems: 'center', gap: 6 },
  summaryKey:       { fontFamily: FONTS.body, fontSize: 14, color: COLORS.muted2 },
  summaryVal:       { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.text },
  summaryValStrike: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted, textDecorationLine: 'line-through' },
  summaryDivider:   { height: 1, backgroundColor: COLORS.border },
  summaryTotalKey:  { fontFamily: FONTS.bodySemiBold, fontSize: 16, color: COLORS.text },
  summaryTotalVal:  { fontFamily: FONTS.title, fontSize: 24, color: COLORS.green },

  // Footer CTA
  footer: {
    paddingHorizontal: SPACING.xl, paddingTop: 12, paddingBottom: 24,
    borderTopWidth: 1, borderTopColor: COLORS.border,
    backgroundColor: COLORS.bg,
  },
  ctaBtn:         { backgroundColor: COLORS.green, borderRadius: RADIUS.xl, height: 52, alignItems: 'center', justifyContent: 'center' },
  ctaBtnDisabled: { opacity: 0.4 },
  ctaBtnText:     { fontFamily: FONTS.bodySemiBold, fontSize: 16, color: COLORS.bg },
  ctaSubText:     { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted, textAlign: 'center', marginTop: 6 },
  postBidBanner: {
    backgroundColor: 'rgba(0,230,118,0.12)', borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.4)',
    paddingHorizontal: 16, paddingVertical: 12, marginBottom: 10, gap: 4,
  },
  postBidTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.green },
  postBidSub:   { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2 },
  retentionBanner: {
    flexDirection: 'row', alignItems: 'center', gap: 8,
    backgroundColor: 'rgba(99,102,241,0.10)', borderRadius: RADIUS.sm,
    borderWidth: 1, borderColor: 'rgba(99,102,241,0.25)',
    paddingHorizontal: 12, paddingVertical: 8, marginBottom: 10,
  },
  retentionText: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: '#818CF8', flex: 1 },

  // ── Panel de competencia ──────────────────────────────────────────────
  compCard: {
    borderRadius: RADIUS.xl, borderWidth: 1, borderColor: 'rgba(251,146,60,0.30)',
    backgroundColor: COLORS.card, marginBottom: 12, padding: 14, overflow: 'hidden',
  },
  compTitleRow: { flexDirection: 'row', alignItems: 'center', gap: 6, marginBottom: 12 },
  compTitle:    { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: '#FB923C' },
  compRow:      { flexDirection: 'row', alignItems: 'center', gap: 8, marginBottom: 10 },
  compStat:     { flex: 1, alignItems: 'center', gap: 2 },
  compStatNum:  { fontFamily: FONTS.title, fontSize: 20, color: COLORS.text },
  compStatLabel:{ fontFamily: FONTS.body, fontSize: 10, color: COLORS.muted2, textAlign: 'center' as const },
  compDivider:  { width: 1, height: 32, backgroundColor: COLORS.border },
  compAlert: {
    flexDirection: 'row', alignItems: 'center', gap: 6,
    backgroundColor: 'rgba(251,146,60,0.10)', borderRadius: RADIUS.md,
    paddingHorizontal: 10, paddingVertical: 6, marginBottom: 8,
  },
  compAlertDot: { width: 6, height: 6, borderRadius: 3, backgroundColor: '#FB923C' },
  compAlertText:{ fontFamily: FONTS.bodyMedium, fontSize: 11, color: '#FB923C' },
  compGap: {
    flexDirection: 'row', alignItems: 'center', gap: 6,
    backgroundColor: 'rgba(0,230,118,0.08)', borderRadius: RADIUS.md,
    paddingHorizontal: 10, paddingVertical: 6,
  },
  compGapText:  { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, flex: 1 },

  // ── Renovación / urgencia ──────────────────────────────────────────────
  activeBidCardUrgent: { borderColor: 'rgba(239,68,68,0.45)' },
  urgencyMsg:    { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: '#ef4444', marginTop: 4 },
  urgencyMsgSub: { fontFamily: FONTS.body,         fontSize: 11, color: '#f87171', marginTop: 2 },
  renewBtn: {
    flexDirection: 'row', alignItems: 'center', gap: 6,
    alignSelf: 'flex-start', marginTop: 12,
    borderRadius: RADIUS.md, borderWidth: 1.5, borderColor: COLORS.green,
    paddingHorizontal: 14, paddingVertical: 8,
  },
  renewBtnUrgent: { backgroundColor: '#ef4444', borderColor: '#ef4444' },
  renewBtnText:   { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.green },
  discountHint:   { fontFamily: FONTS.body, fontSize: 11, color: '#f59e0b', marginTop: 8 },
  // Power badge
  powerBadgeRow: {
    flexDirection: 'row', alignItems: 'center', gap: 6,
    marginHorizontal: SPACING.lg, marginBottom: 10,
    backgroundColor: 'rgba(251,146,60,0.10)',
    borderRadius: RADIUS.md, borderWidth: 1, borderColor: 'rgba(251,146,60,0.30)',
    paddingHorizontal: 12, paddingVertical: 8,
  },
  powerBadgeEmoji: { fontSize: 20 },
  powerBadgeText:  { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: '#FB923C', flex: 1 },
  // Quick upsell
  upsellRow: { flexDirection: 'row', alignItems: 'center', gap: 6, marginTop: 8, flexWrap: 'wrap' },
  upsellLabel: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted2 },
  upsellBtn: {
    backgroundColor: 'rgba(0,230,118,0.10)',
    borderRadius: RADIUS.sm, borderWidth: 1, borderColor: 'rgba(0,230,118,0.30)',
    paddingHorizontal: 10, paddingVertical: 5,
  },
  upsellBtnText: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.green },
  // Live alert banner
  liveAlertBanner: {
    flexDirection: 'row', alignItems: 'center', gap: 8,
    marginHorizontal: SPACING.lg, marginBottom: 8,
    backgroundColor: 'rgba(251,146,60,0.10)',
    borderRadius: RADIUS.md, borderWidth: 1, borderColor: 'rgba(251,146,60,0.30)',
    paddingHorizontal: 12, paddingVertical: 8,
  },
  liveAlertDot: {
    width: 7, height: 7, borderRadius: 4,
    backgroundColor: '#FB923C',
  },
  liveAlertText: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: '#FB923C', flex: 1 },
  // Exact gap button
  exactGapBtn: {
    flexDirection: 'row', alignItems: 'center', gap: 6,
    backgroundColor: COLORS.green, borderRadius: RADIUS.md,
    paddingHorizontal: 12, paddingVertical: 9,
  },
  exactGapBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 12, color: COLORS.bg, flex: 1 },

  // 🥇 Para quedar #1
  top1Btn: {
    flexDirection: 'row', alignItems: 'center', gap: 10,
    marginTop: 8,
    backgroundColor: 'rgba(255,215,0,0.10)',
    borderWidth: 1, borderColor: 'rgba(255,215,0,0.45)',
    borderRadius: RADIUS.md, paddingHorizontal: 12, paddingVertical: 10,
  },
  top1BtnEmoji: { fontSize: 22 },
  top1BtnTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: '#FFD700', marginBottom: 2 },
  top1BtnSub:   { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2 },
});
