import { ChevronLeft, X } from 'lucide-react-native';
import React, { useEffect, useRef, useState } from 'react';
import { ActivityIndicator, Alert, Animated, Easing, Image, KeyboardAvoidingView, Platform, Pressable, StyleSheet, Text, TextInput, View } from 'react-native';
import Svg, { Circle, Defs, Ellipse, LinearGradient, Path, Rect, Stop } from 'react-native-svg';
import { useTranslation } from 'react-i18next';
import { useStripe } from '@stripe/stripe-react-native';
import { supabase } from '../../config/supabase';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';
import { startGiftConektaCheckout } from '../../utils/conektaCheckout';

// ⚠️ ROLLOUT REGALOS (2026-09-09): Conekta aprobó la cuenta solo para
// Efectivo/SPEI/BBVA — tarjeta queda bloqueada ~90 días. Los regalos son
// SOLO tarjeta (confirmación instantánea para animar el emoji), así que
// mientras tanto se cobran con Stripe (PaymentSheet), igual que ya se
// hace con "pagar a meses". Cuando Conekta habilite tarjeta: poner esto
// en false y todo vuelve a create-gift-order sin más cambios.
const GIFTS_VIA_STRIPE = true;

interface Props {
  visible: boolean;
  onClose: () => void;
  groupId: string;
  groupName: string;
  groupCountry: string | null;
  postId?: string;
  reservationId?: string; // "dar propina" desde calificar post-evento (sql/582)
  onSent?: (info?: { emoji: string }) => void;
}

// ── Catálogo visual "Símbolos" — insignia circular con degradado propio,
// anillo exterior que crece en grosor/opacidad según el nivel (1 = más
// barato, 5 = más caro) y una silueta blanca vectorial (SVG puro, nada
// de emoji del sistema — se ve idéntico en iOS y Android). El emoji en
// BD se sigue usando tal cual en Alerts/notificaciones de texto plano.
// Corazón ($10) se quitó del catálogo (sql/574) — Fuego es ahora el más
// barato, con colores de marca (verde) en vez de naranja.
export const GIFT_VISUALS: Record<string, { level: number; gradient: string[]; ringColor: string; isTrophyTier?: boolean; Icon: () => React.ReactElement }> = {
  'Fuego': {
    level: 1, gradient: ['#FF9E7D', COLORS.red], ringColor: COLORS.red,
    Icon: () => <Path fill="#fff" d="M0,-24 C11,-13 15,-2 8,7 C13,5 18,-1 18,-1 C21,13 10,24 -1,24 C-15,24 -20,10 -12,-2 C-8,-12 -3,-18 0,-24 Z" />,
  },
  'Rayo': {
    level: 2, gradient: ['#60A5FA', '#4338CA'], ringColor: '#4338CA',
    Icon: () => <Path fill="#fff" d="M6,-26 L-14,4 L-2,4 L-8,26 L18,-6 L4,-6 Z" />,
  },
  'Diamante': {
    level: 3, gradient: ['#A5F3FC', '#0E7490'], ringColor: '#0E7490',
    Icon: () => (
      <>
        <Path fill="#fff" d="M-18,-8 L-9,-20 L9,-20 L18,-8 L0,20 Z" />
        <Path stroke="#0E7490" strokeWidth={1} opacity={0.35} fill="none" d="M-9,-20 L0,-8 M9,-20 L0,-8 M-18,-8 L18,-8 M0,-8 L0,20" />
      </>
    ),
  },
  'Corona': {
    level: 4, gradient: ['#FFE066', '#B8860B'], ringColor: '#B8860B',
    Icon: () => (
      <>
        <Path fill="#fff" d="M-20,10 L-16,-10 L-6,0 L0,-16 L6,0 L16,-10 L20,10 Z" />
        <Rect fill="#fff" x={-20} y={10} width={40} height={6} rx={2} />
      </>
    ),
  },
  'Trofeo': {
    level: 5, gradient: ['#FBA5C5', '#A855F7', '#FFD43B'], ringColor: '#A855F7', isTrophyTier: true,
    Icon: () => (
      <>
        <Path fill="#fff" d="M-14,-20 Q-14,0 0,4 Q14,0 14,-20 Z" />
        <Path fill="none" stroke="#fff" strokeWidth={3} d="M-14,-16 C-24,-16 -24,-2 -12,-2" />
        <Path fill="none" stroke="#fff" strokeWidth={3} d="M14,-16 C24,-16 24,-2 12,-2" />
        <Rect fill="#fff" x={-3} y={4} width={6} height={10} />
        <Rect fill="#fff" x={-11} y={14} width={22} height={5} rx={2} />
      </>
    ),
  },
  // "Otro monto" — icono propio (estrella) distinto al Trofeo aunque
  // comparta su mismo nivel/gift_id por debajo; visualmente no debe
  // confundirse con el regalo fijo de $700.
  'Otro monto': {
    level: 5, gradient: [COLORS.green, COLORS.green2], ringColor: COLORS.green2, isTrophyTier: true,
    Icon: () => <Path fill="#fff" d="M0,-24 L7,-8 L24,-8 L10,3 L15,20 L0,10 L-15,20 L-10,3 L-24,-8 L-7,-8 Z" />,
  },
};
// Respaldo por si algún día se agrega un regalo nuevo sin insignia dedicada.
export const DEFAULT_VISUAL = { level: 1, gradient: [COLORS.green, COLORS.green], ringColor: COLORS.green, isTrophyTier: false, Icon: null as null };

// Grosor/opacidad del anillo exterior — crecen con el nivel, así el ojo
// detecta qué tan "grande" es el regalo sin tener que leer el precio.
const RING_BY_LEVEL: Record<number, { width: number; opacity: number }> = {
  1: { width: 1.5, opacity: 0.35 },
  2: { width: 1.9, opacity: 0.48 },
  3: { width: 2.25, opacity: 0.6 },
  4: { width: 2.6, opacity: 0.73 },
  5: { width: 3.0, opacity: 0.85 },
};

const CONFETTI_COLORS = [COLORS.green, COLORS.gold, COLORS.blue, COLORS.purple, COLORS.red, COLORS.orange];
const BADGE_PX = 64; // tamaño final en pantalla — todo el SVG interno (radio 54, anillo 60...) escala proporcional a esto

// 'Estados Unidos' y 'Canadá' cobran en USD (Canadá no tiene columna de
// saldo en CAD todavía — mientras se hace esa migración completa, se le
// trata como USD en vez de caer por error a pesos mexicanos). El resto,
// MXN. Mismo criterio que el edge function create-gift-order.
function currencyForGroup(country: string | null): 'MXN' | 'USD' {
  return country === 'Estados Unidos' || country === 'Canadá' ? 'USD' : 'MXN';
}

const AnimatedCircle = Animated.createAnimatedComponent(Circle);

// 🎐 Insignia del regalo — respiración sutil del anillo en reposo (más
// rápida entre más caro el regalo) y, al enviarse con éxito, un rebote
// de escala + 2-3 ondas de impacto expandiéndose desde el centro. El
// Trofeo/Otro monto (isTrophyTier) reciben más duración — es el "screenshot moment".
function GiftBadge({ name, index, celebrate }: { name: string; index: number; celebrate: boolean }) {
  const visual = GIFT_VISUALS[name] ?? DEFAULT_VISUAL;
  const ring = RING_BY_LEVEL[visual.level] ?? RING_BY_LEVEL[1];
  const isTrophy = !!visual.isTrophyTier;
  // "Otro monto" (2026-09-05) — usa el logo real de Daricefy en vez del
  // ícono SVG (estrella), para que se vea que ese nivel vale más. El
  // anillo animado se conserva igual, solo se reemplaza el relleno.
  const isLogoVisual = name === 'Otro monto';
  const gradId = `giftGrad-${name}`;

  const breathe      = useRef(new Animated.Value(0)).current; // JS-driven: alimenta props de SVG (opacidad/grosor del anillo)
  const breatheScale = useRef(new Animated.Value(1)).current; // nativo: alimenta el transform de escala — no pueden ser el mismo valor (drivers distintos)
  const scale        = useRef(new Animated.Value(1)).current;
  const ripple        = useRef(new Animated.Value(0)).current;
  const flash         = useRef(new Animated.Value(0)).current;

  useEffect(() => {
    const half = 900 - visual.level * 80; // más caro = respira más rápido
    const loopJS = Animated.loop(
      Animated.sequence([
        Animated.delay(index * 140),
        Animated.timing(breathe, { toValue: 1, duration: half, easing: Easing.inOut(Easing.sin), useNativeDriver: false }),
        Animated.timing(breathe, { toValue: 0, duration: half, easing: Easing.inOut(Easing.sin), useNativeDriver: false }),
      ]),
    );
    const loopNative = Animated.loop(
      Animated.sequence([
        Animated.delay(index * 140),
        Animated.timing(breatheScale, { toValue: 1.1, duration: half, easing: Easing.inOut(Easing.sin), useNativeDriver: true }),
        Animated.timing(breatheScale, { toValue: 1, duration: half, easing: Easing.inOut(Easing.sin), useNativeDriver: true }),
      ]),
    );
    loopJS.start();
    loopNative.start();
    return () => { loopJS.stop(); loopNative.stop(); };
  }, []);

  useEffect(() => {
    if (!celebrate) return;
    const bump = isTrophy ? 300 : 220;
    scale.setValue(1);
    ripple.setValue(0);
    flash.setValue(0);
    Animated.sequence([
      Animated.timing(scale, { toValue: 1.32, duration: bump, easing: Easing.out(Easing.back(2)), useNativeDriver: true }),
      Animated.timing(scale, { toValue: 1, duration: bump, easing: Easing.inOut(Easing.quad), useNativeDriver: true }),
    ]).start();
    Animated.sequence([
      Animated.timing(flash, { toValue: 1, duration: 90, useNativeDriver: true }),
      Animated.timing(flash, { toValue: 0, duration: 260, useNativeDriver: true }),
    ]).start();
    Animated.timing(ripple, { toValue: 1, duration: isTrophy ? 1200 : 900, easing: Easing.out(Easing.quad), useNativeDriver: true }).start();
  }, [celebrate]);

  // Respiración más notoria: el anillo crece de grosor Y de opacidad (no
  // solo opacidad), y toda la insignia se agranda un poco de paso — antes
  // el cambio era casi imperceptible.
  const ringOpacity  = breathe.interpolate({ inputRange: [0, 1], outputRange: [ring.opacity * 0.3, Math.min(1, ring.opacity * 1.35)] });
  const ringStroke   = breathe.interpolate({ inputRange: [0, 1], outputRange: [ring.width * 0.7, ring.width * 1.7] });
  const rippleCount  = isTrophy ? 4 : 3;

  return (
    <Animated.View style={{ width: BADGE_PX, height: BADGE_PX, alignItems: 'center', justifyContent: 'center', transform: [{ scale: Animated.multiply(breatheScale, scale) }] }}>
      {celebrate && (
        <Animated.View
          pointerEvents="none"
          style={{
            position: 'absolute', width: BADGE_PX, height: BADGE_PX, borderRadius: BADGE_PX / 2,
            backgroundColor: '#fff', opacity: flash.interpolate({ inputRange: [0, 1], outputRange: [0, 0.65] }),
          }}
        />
      )}
      {celebrate && Array.from({ length: rippleCount }).map((_, i) => (
        <Animated.View
          key={i}
          pointerEvents="none"
          style={{
            position: 'absolute', width: BADGE_PX, height: BADGE_PX, borderRadius: BADGE_PX / 2,
            borderWidth: 3, borderColor: visual.ringColor,
            opacity: ripple.interpolate({
              inputRange: [0, i * 0.15, i * 0.15 + 0.01, 1],
              outputRange: [0, 0, 0.8, 0],
            }),
            transform: [{ scale: ripple.interpolate({ inputRange: [0, 1], outputRange: [1, 2.1 + i * 0.4] }) }],
          }}
        />
      ))}
      <Svg width={BADGE_PX} height={BADGE_PX} viewBox="-66 -66 132 132">
        <Defs>
          <LinearGradient id={gradId} x1="0" y1="0" x2="1" y2="1">
            {visual.gradient.map((c, i) => (
              <Stop key={i} offset={i / (visual.gradient.length - 1)} stopColor={c} />
            ))}
          </LinearGradient>
        </Defs>
        <AnimatedCircle cx={0} cy={0} r={60} fill="none" stroke={visual.ringColor} strokeWidth={ringStroke as any} opacity={ringOpacity as any} />
        {!isLogoVisual && (
          <>
            <Circle cx={0} cy={0} r={54} fill={`url(#${gradId})`} />
            <Ellipse cx={-16} cy={-20} rx={10} ry={5.5} fill="#fff" opacity={0.2} transform="rotate(-20 -16 -20)" />
            {visual.Icon ? <visual.Icon /> : <GiftIconFallback />}
          </>
        )}
      </Svg>
      {isLogoVisual && (
        <Image
          source={require('../../../assets/images/icon.png')}
          style={{ position: 'absolute', width: 52, height: 52, borderRadius: 26 }}
          resizeMode="cover"
        />
      )}
    </Animated.View>
  );
}

function GiftIconFallback() {
  return <Path fill="#fff" d="M-16,-4 L16,-4 L16,20 L-16,20 Z M-20,-10 L20,-10 L20,-4 L-20,-4 Z M0,-10 L0,20 M-6,-10 C-14,-10 -14,-20 -6,-20 C0,-20 0,-10 0,-10 Z M6,-10 C14,-10 14,-20 6,-20 C0,-20 0,-10 0,-10 Z" />;
}

// 🎉 Ráfaga de confeti al confirmarse el pago — partículas cayendo con
// rotación y desvanecido, colores de la paleta de la app. Sin librería
// externa (solo Animated), para no meter una dependencia nueva.
function ConfettiBurst() {
  const particles = useRef(
    Array.from({ length: 26 }, () => ({
      left: Math.random() * 100,
      color: CONFETTI_COLORS[Math.floor(Math.random() * CONFETTI_COLORS.length)],
      size: 6 + Math.random() * 6,
      delay: Math.random() * 250,
      duration: 1000 + Math.random() * 700,
      rotateTo: `${Math.round(360 + Math.random() * 360)}deg`,
      anim: new Animated.Value(0),
    })),
  ).current;

  useEffect(() => {
    const anims = particles.map(p =>
      Animated.timing(p.anim, {
        toValue: 1, duration: p.duration, delay: p.delay,
        easing: Easing.out(Easing.quad), useNativeDriver: true,
      }),
    );
    Animated.parallel(anims).start();
  }, []);

  return (
    <View style={s.confettiLayer} pointerEvents="none">
      {particles.map((p, i) => (
        <Animated.View
          key={i}
          style={{
            position: 'absolute',
            left: `${p.left}%`,
            top: 0,
            width: p.size, height: p.size * 1.6,
            borderRadius: 2,
            backgroundColor: p.color,
            opacity: p.anim.interpolate({ inputRange: [0, 0.1, 0.85, 1], outputRange: [0, 1, 1, 0] }),
            transform: [
              { translateY: p.anim.interpolate({ inputRange: [0, 1], outputRange: [0, 260] }) },
              { rotate: p.anim.interpolate({ inputRange: [0, 1], outputRange: ['0deg', p.rotateTo] }) },
            ],
          }}
        />
      ))}
    </View>
  );
}

export default function GiftPickerModal({ visible, onClose, groupId, groupName, groupCountry, postId, reservationId, onSent }: Props) {
  const { t } = useTranslation();
  const { initPaymentSheet, presentPaymentSheet } = useStripe();
  // Nombre del regalo en el idioma del teléfono (mismo criterio que el
  // resto de la app, src/i18n) — el nombre en español sigue siendo el
  // valor real en BD/keys internas, esto solo cambia lo que se muestra.
  const giftLabel = (name: string) => t(`gifts.names.${name}`, name);
  const [gifts,     setGifts]     = useState<any[]>([]);
  const [loading,   setLoading]   = useState(true);
  const [sendingId, setSendingId] = useState<string | null>(null);
  const [celebrating, setCelebrating] = useState(false);
  const [celebratingGiftId, setCelebratingGiftId] = useState<string | null>(null);
  const [customMode, setCustomMode] = useState(false);
  const [customAmountText, setCustomAmountText] = useState('');
  const [customSending, setCustomSending] = useState(false);
  const [customCelebrating, setCustomCelebrating] = useState(false);
  const currency = currencyForGroup(groupCountry);
  const trofeo = gifts.find(g => g.name === 'Trofeo');

  useEffect(() => {
    if (!visible) return;
    setLoading(true);
    supabase
      .from('gift_catalog')
      .select('id, emoji, name, sort_order, prices:gift_catalog_prices(currency_code, amount)')
      .eq('active', true)
      .order('sort_order', { ascending: true })
      .then(({ data }) => {
        const rows = ((data as any[]) ?? [])
          .map(g => ({
            ...g,
            price: (g.prices ?? []).find((p: any) => p.currency_code === currency)?.amount ?? null,
          }))
          .filter(g => g.price != null);
        setGifts(rows);
        setLoading(false);
      });
  }, [visible, currency]);

  // Cobro del regalo — enruta al procesador vigente (Stripe mientras
  // Conekta no tenga tarjeta; ver GIFTS_VIA_STRIPE arriba). Devuelve el
  // MISMO shape que startGiftConektaCheckout para no tocar la UX de
  // celebración/pendiente/error de abajo. El webhook sigue siendo la
  // fuente de verdad: sólo se celebra al ver group_gifts.status = 'paid'.
  const runGiftCheckout = async (
    giftId: string,
    customAmount?: number,
  ): Promise<{ ok: boolean; status: 'paid' | 'pending' | 'error'; error?: string }> => {
    if (!GIFTS_VIA_STRIPE) {
      return startGiftConektaCheckout(groupId, giftId, postId, customAmount, reservationId);
    }

    const { data: sd } = await supabase.auth.getSession();
    const { data, error } = await supabase.functions.invoke('create-gift-payment-intent', {
      body: {
        group_id: groupId, gift_id: giftId, post_id: postId ?? null,
        custom_amount: customAmount ?? null, reservation_id: reservationId ?? null,
      },
      headers: { Authorization: `Bearer ${sd.session?.access_token}` },
    });
    const clientSecret = (data as any)?.client_secret as string | undefined;
    const giftOrderId  = (data as any)?.gift_order_id as string | undefined;
    if (error || (data as any)?.error || !clientSecret || !giftOrderId) {
      const msg = (data as any)?.error ?? error?.message ?? t('gifts.tryAgain');
      console.warn('[gift-stripe] create-payment-intent falló:', msg);
      return { ok: false, status: 'error', error: msg };
    }

    const { error: initErr } = await initPaymentSheet({
      paymentIntentClientSecret: clientSecret,
      merchantDisplayName: 'Daricefy',
      style: 'alwaysDark',
    });
    if (initErr) return { ok: false, status: 'error', error: initErr.message };

    const { error: payErr } = await presentPaymentSheet();
    if (payErr) {
      // El usuario cerró la hoja sin pagar → "pendiente" sin celebrar
      // (mismo trato que cerrar el navegador de Conekta sin pagar).
      if (payErr.code === 'Canceled') return { ok: true, status: 'pending' };
      return { ok: false, status: 'error', error: payErr.message };
    }

    // Stripe aceptó el pago — el webhook acredita la wallet y marca 'paid'.
    // Se consulta group_gifts.status unas veces antes de celebrar (idéntico
    // al polling que hace startGiftConektaCheckout con reservas).
    for (let i = 0; i < 4; i++) {
      const { data: g } = await supabase
        .from('group_gifts').select('status').eq('id', giftOrderId).single();
      if (g?.status === 'paid') return { ok: true, status: 'paid' };
      if (i < 3) await new Promise((r) => setTimeout(r, 1500));
    }
    return { ok: true, status: 'pending' };
  };

  const handleSend = async (gift: any, customAmount?: number) => {
    if (sendingId) return;
    setSendingId(gift.id);
    const isTrophy = !!(GIFT_VISUALS[gift.name] ?? DEFAULT_VISUAL).isTrophyTier;
    const amountTxt = customAmount != null ? ` (${currency === 'USD' ? 'US$' : '$'}${customAmount})` : '';
    // El spinner de la tarjeta se queda activo hasta tener el resultado REAL
    // (incluye el tiempo que el usuario pasa en la hoja de pago + el polling
    // de confirmación) — celebrar antes de eso es lo que causaba el bug real
    // reportado: cerrar sin pagar igual mostraba "regalo enviado".
    const res = await runGiftCheckout(gift.id, customAmount);
    setSendingId(null);
    if (!res.ok) {
      Alert.alert(t('gifts.couldNotSend'), res.error ?? t('gifts.tryAgain'));
      return;
    }
    if (res.status !== 'paid') {
      Alert.alert(t('gifts.pendingTitle'), t('gifts.pendingBody'));
      onClose();
      return;
    }
    setCelebratingGiftId(gift.id);
    setCelebrating(true);
    onSent?.({ emoji: gift.emoji });
    setTimeout(() => {
      setCelebrating(false);
      setCelebratingGiftId(null);
      Alert.alert(
        t('gifts.thanksTitle'),
        t('gifts.sentGift', { emoji: gift.emoji, giftName: giftLabel(gift.name), amount: amountTxt, group: groupName }),
      );
      onClose();
    }, isTrophy ? 1700 : 1300);
  };

  // "Otro monto" (2026-08-26) — hereda el gift_id del Trofeo por debajo
  // (mismo candado de precio mínimo/comisión), pero se queda en SU PROPIA
  // tarjeta/insignia mientras carga y celebra — antes usaba handleSend()
  // compartido con la cuadrícula y al volver a la grilla la tarjeta de
  // $700 (Trofeo) se quedaba "cargando" en vez de la de "Otro monto",
  // muy confuso porque el cliente nunca tocó esa tarjeta.
  const submitCustom = async () => {
    if (!trofeo || customSending) return;
    const val = Number(customAmountText.replace(',', '.'));
    const minVal = Number(trofeo.price);
    if (!Number.isFinite(val) || val < minVal) {
      Alert.alert(t('gifts.invalidAmount'), t('gifts.minimumIs', { amount: `${currency === 'USD' ? 'US$' : '$'}${minVal}` }));
      return;
    }
    setCustomSending(true);
    const amountTxt = `${currency === 'USD' ? 'US$' : '$'}${val}`;
    // Igual que handleSend — celebra solo si el resultado REAL es 'paid',
    // nunca solo porque el usuario cerró la hoja de pago.
    const res = await runGiftCheckout(trofeo.id, val);
    setCustomSending(false);
    if (!res.ok) {
      Alert.alert(t('gifts.couldNotSend'), res.error ?? t('gifts.tryAgain'));
      return;
    }
    if (res.status !== 'paid') {
      Alert.alert(t('gifts.pendingTitle'), t('gifts.pendingBody'));
      onClose();
      return;
    }
    setCustomCelebrating(true);
    setCelebrating(true); // confeti general, igual que los demás regalos
    onSent?.({ emoji: '🌟' });
    setTimeout(() => {
      setCustomCelebrating(false);
      setCelebrating(false);
      setCustomMode(false);
      setCustomAmountText('');
      Alert.alert(
        t('gifts.thanksTitle'),
        t('gifts.sentCustom', { amount: amountTxt, group: groupName }),
      );
      onClose();
    }, 1700);
  };

  // Sin <Modal> nativo a propósito: cuando se abre DESDE DENTRO de otro
  // <Modal> (el detalle de una publicación), apilar dos Modal nativos se
  // rompe en Android (el segundo no queda arriba/interactivo). Al ser una
  // capa absoluta normal, siempre se monta dentro del mismo árbol nativo
  // que la esté llamando — funciona igual desde el perfil, el feed o
  // desde dentro del detalle de una publicación.
  if (!visible) return null;

  return (
    <KeyboardAvoidingView style={s.backdrop} behavior={Platform.OS === 'ios' ? 'padding' : 'height'}>
      <Pressable style={StyleSheet.absoluteFill} onPress={celebrating ? undefined : onClose} />
      <View style={s.sheet}>
        {celebrating && <ConfettiBurst />}
        <View style={s.header}>
          <Text style={s.title}>
            {t(reservationId ? 'gifts.tipTitle' : 'gifts.supportTitle', { name: groupName })}
          </Text>
          <Pressable hitSlop={10} onPress={onClose}>
            <X size={22} color={COLORS.text} />
          </Pressable>
        </View>
        <Text style={s.subtitle}>
          {t(reservationId ? 'gifts.tipSubtitle' : 'gifts.supportSubtitle', {
            currency: t(currency === 'USD' ? 'gifts.currencyDollars' : 'gifts.currencyPesos'),
          })}
        </Text>

        {loading ? (
          <ActivityIndicator color={COLORS.green} style={{ marginVertical: 30 }} />
        ) : customMode ? (
          <View>
            <Pressable style={s.backLink} onPress={() => setCustomMode(false)} hitSlop={10} disabled={customSending}>
              <ChevronLeft size={16} color={COLORS.muted} />
              <Text style={s.backLinkTx}>{t('gifts.back')}</Text>
            </Pressable>
            <View style={s.customBox}>
              <GiftBadge name="Otro monto" index={0} celebrate={customCelebrating} />
              <Text style={s.customLabel}>{t('gifts.howMuch', { name: groupName })}</Text>
              {!!trofeo && (
                <Text style={s.customHint}>
                  {t('gifts.minimum', { amount: `${currency === 'USD' ? 'US$' : '$'}${trofeo.price}` })}
                </Text>
              )}
              <View style={s.customInputRow}>
                <Text style={s.customCurrency}>{currency === 'USD' ? 'US$' : '$'}</Text>
                <TextInput
                  style={s.customInput}
                  keyboardType="decimal-pad"
                  placeholder={trofeo ? String(trofeo.price) : '0'}
                  placeholderTextColor={COLORS.muted2}
                  value={customAmountText}
                  onChangeText={setCustomAmountText}
                  editable={!customSending}
                  autoFocus
                />
              </View>
              <Pressable style={[s.customSendBtn, customSending && { opacity: 0.6 }]} onPress={submitCustom} disabled={customSending}>
                {customSending
                  ? <ActivityIndicator color="#04140a" />
                  : <Text style={s.customSendBtnTx}>{t('gifts.sendGift')}</Text>}
              </Pressable>
            </View>
          </View>
        ) : (
          <View style={s.grid}>
            {gifts.map((g, i) => (
              <Pressable
                key={g.id}
                style={[s.card, sendingId === g.id && { opacity: 0.6 }]}
                onPress={() => handleSend(g)}
                disabled={!!sendingId}
              >
                {sendingId === g.id ? (
                  <ActivityIndicator color={COLORS.green} />
                ) : (
                  <>
                    <GiftBadge name={g.name} index={i} celebrate={celebratingGiftId === g.id} />
                    <Text style={s.name} numberOfLines={1}>{giftLabel(g.name)}</Text>
                    <Text style={s.price}>{currency === 'USD' ? 'US$' : '$'}{g.price}</Text>
                  </>
                )}
              </Pressable>
            ))}
            {/* 🏆➕ "Otro monto" — hereda la insignia del Trofeo (nivel más
                alto) para el cliente que quiere dar más que el máximo fijo. */}
            {!!trofeo && (
              <Pressable
                style={s.card}
                onPress={() => setCustomMode(true)}
                disabled={!!sendingId}
              >
                <GiftBadge name="Otro monto" index={gifts.length} celebrate={false} />
                <Text style={s.name} numberOfLines={1}>{t('gifts.otherAmount')}</Text>
                <Text style={s.price}>{t('gifts.youChoose')}</Text>
              </Pressable>
            )}
          </View>
        )}
      </View>
    </KeyboardAvoidingView>
  );
}

const s = StyleSheet.create({
  backdrop: {
    ...StyleSheet.absoluteFill, zIndex: 999, elevation: 999,
    backgroundColor: 'rgba(0,0,0,0.6)', justifyContent: 'flex-end',
  },
  sheet: {
    backgroundColor: COLORS.card, borderTopLeftRadius: 24, borderTopRightRadius: 24,
    padding: SPACING.xl, paddingBottom: 34, overflow: 'hidden',
  },
  confettiLayer: { ...StyleSheet.absoluteFill, zIndex: 10 },
  header: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' },
  title: { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: '#fff', flexShrink: 1, marginRight: 10 },
  subtitle: { fontFamily: FONTS.body, fontSize: 12.5, color: COLORS.muted, marginTop: 4, marginBottom: 16 },
  grid: { flexDirection: 'row', flexWrap: 'wrap', gap: 10 },
  card: {
    width: '30%', borderRadius: RADIUS.lg, paddingVertical: 14,
    backgroundColor: COLORS.card2, borderWidth: 1, borderColor: COLORS.border,
    alignItems: 'center', justifyContent: 'center', gap: 6,
  },
  name: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.text, textAlign: 'center', paddingHorizontal: 4 },
  price: { fontFamily: FONTS.bodySemiBold, fontSize: 12.5, color: COLORS.green },

  backLink: { flexDirection: 'row', alignItems: 'center', gap: 2, marginBottom: 6, alignSelf: 'flex-start' },
  backLinkTx: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted },
  customBox: { alignItems: 'center', paddingVertical: 10, gap: 8 },
  customLabel: { fontFamily: FONTS.bodySemiBold, fontSize: 14.5, color: COLORS.text, textAlign: 'center', marginTop: 4 },
  customHint: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted },
  customInputRow: {
    flexDirection: 'row', alignItems: 'center', gap: 6, marginTop: 6,
    backgroundColor: COLORS.card2, borderWidth: 1, borderColor: COLORS.border,
    borderRadius: RADIUS.lg, paddingHorizontal: 16, paddingVertical: 10, minWidth: 160,
  },
  customCurrency: { fontFamily: FONTS.bodySemiBold, fontSize: 18, color: COLORS.green },
  customInput: { fontFamily: FONTS.bodySemiBold, fontSize: 18, color: '#fff', flex: 1, padding: 0 },
  customSendBtn: {
    backgroundColor: COLORS.green, borderRadius: RADIUS.lg,
    paddingVertical: 13, paddingHorizontal: 28, marginTop: 10,
  },
  customSendBtnTx: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: '#04140a' },
});
