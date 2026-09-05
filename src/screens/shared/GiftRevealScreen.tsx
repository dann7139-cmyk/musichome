/**
 * GiftRevealScreen — pantalla de apertura para CUALQUIER regalo o propina
 * (2026-09-05: antes solo aplicaba a "Otro monto"). Primero aparece la
 * insignia (logo para "Otro monto", el ícono propio del regalo para los
 * demás) y después, con un pequeño retraso, se revela el monto — el
 * momento de emoción. Se llega vía notificación (data.screen='GiftReveal',
 * gift_id).
 */
import React, { useEffect, useRef, useState } from 'react';
import { ActivityIndicator, Animated, Easing, Image, Pressable, StyleSheet, Text, View } from 'react-native';
import { SafeAreaView, useSafeAreaInsets } from 'react-native-safe-area-context';
import Svg, { Circle, Defs, Ellipse, LinearGradient, Stop } from 'react-native-svg';
import { X } from 'lucide-react-native';
import { useTranslation } from 'react-i18next';
import { supabase } from '../../config/supabase';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';
import { GIFT_VISUALS, DEFAULT_VISUAL } from '../../components/gifts/GiftPickerModal';

const CONFETTI_COLORS = [COLORS.green, COLORS.gold, COLORS.blue, COLORS.purple, COLORS.red, COLORS.orange];

// 🎉 Mismo patrón de GiftPickerModal.tsx — sin librería externa. El momento
// de abrir el regalo sorpresa merece su propia celebración, igual que la
// que ya ve quien lo envía.
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
    <View style={StyleSheet.absoluteFill} pointerEvents="none">
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
              { translateY: p.anim.interpolate({ inputRange: [0, 1], outputRange: [0, 640] }) },
              { rotate: p.anim.interpolate({ inputRange: [0, 1], outputRange: ['0deg', p.rotateTo] }) },
            ],
          }}
        />
      ))}
    </View>
  );
}

interface GiftRow {
  amount: number;
  currency_code: 'MXN' | 'USD';
  sender_name: string | null;
  giftName: string;
  giftEmoji: string;
  isCustom: boolean;
}

const BADGE_PX = 120;

export default function GiftRevealScreen({ route, navigation }: any) {
  const { t } = useTranslation();
  const insets = useSafeAreaInsets();
  const giftId: string | undefined = route?.params?.gift_id;
  const [gift, setGift] = useState<GiftRow | null>(null);
  const [loading, setLoading] = useState(true);
  const [celebrating, setCelebrating] = useState(false);

  const badgeScale = useRef(new Animated.Value(0)).current;
  const amountOpacity = useRef(new Animated.Value(0)).current;
  const amountScale = useRef(new Animated.Value(0.7)).current;
  const ripple = useRef(new Animated.Value(0)).current;

  useEffect(() => {
    if (!giftId) { setLoading(false); return; }
    (async () => {
      // group_amount (no "amount") es lo único que se MUESTRA — el
      // grupo/talento nunca debe ver el total que pagó el cliente ni la
      // comisión de Daricefy (2026-09-05, hallazgo real en pruebas). "amount"
      // sí se lee, pero solo para detectar "Otro monto" internamente, nunca
      // se pinta en pantalla — mismo criterio que WalletScreen.tsx.
      const { data } = await supabase
        .from('group_gifts')
        .select('amount, group_amount, currency_code, sender:profiles!sender_id(full_name), gift:gift_catalog(name, emoji, prices:gift_catalog_prices(currency_code, amount))')
        .eq('id', giftId)
        .single();
      if (data) {
        const row = data as any;
        const basePrice = row.gift?.prices?.find((p: any) => p.currency_code === row.currency_code)?.amount;
        setGift({
          amount: Number(row.group_amount),
          currency_code: row.currency_code,
          sender_name: row.sender?.full_name ?? null,
          giftName: row.gift?.name ?? '',
          giftEmoji: row.gift?.emoji ?? '🎁',
          isCustom: basePrice == null || Number(row.amount) !== Number(basePrice),
        });
      }
      setLoading(false);
    })();
  }, [giftId]);

  // La insignia con el logo aparece de inmediato, sin esperar la consulta a
  // BD — antes se quedaba detrás de un spinner de pantalla completa hasta
  // que llegaba el monto, y se sentía lento (2026-09-05). Solo el monto (la
  // parte sorpresa) espera a los datos reales.
  useEffect(() => {
    Animated.timing(badgeScale, { toValue: 1, duration: 420, easing: Easing.out(Easing.back(1.5)), useNativeDriver: true }).start();
    Animated.timing(ripple, { toValue: 1, duration: 1100, easing: Easing.out(Easing.quad), useNativeDriver: true }).start();
  }, []);

  useEffect(() => {
    if (loading || !gift) return;
    // El ícono se queda solo un instante corto antes de revelar el monto
    // (2026-09-05) — sin esta pausa, si la consulta ya venía cargada, el
    // monto salía casi junto con el ícono y se perdía el efecto sorpresa.
    Animated.sequence([
      Animated.delay(450),
      Animated.parallel([
        Animated.timing(amountOpacity, { toValue: 1, duration: 380, useNativeDriver: true }),
        Animated.timing(amountScale, { toValue: 1, duration: 380, easing: Easing.out(Easing.back(1.4)), useNativeDriver: true }),
      ]),
    ]).start(() => setCelebrating(true));
  }, [loading, gift]);

  const currencySymbol = gift?.currency_code === 'USD' ? 'US$' : '$';

  return (
    <SafeAreaView style={s.safe}>
      <Pressable
        hitSlop={12}
        onPress={() => navigation.goBack()}
        style={[s.closeBtn, { top: insets.top + 10 }]}
      >
        <X size={22} color="#fff" />
      </Pressable>

      <View style={s.center}>
        <Animated.View style={{ width: BADGE_PX, height: BADGE_PX, alignItems: 'center', justifyContent: 'center', transform: [{ scale: badgeScale }] }}>
          {[0, 1, 2].map(i => (
            <Animated.View
              key={i}
              pointerEvents="none"
              style={{
                position: 'absolute', width: BADGE_PX, height: BADGE_PX, borderRadius: BADGE_PX / 2,
                borderWidth: 3, borderColor: COLORS.green2,
                opacity: ripple.interpolate({ inputRange: [0, i * 0.18, i * 0.18 + 0.01, 1], outputRange: [0, 0, 0.7, 0] }),
                transform: [{ scale: ripple.interpolate({ inputRange: [0, 1], outputRange: [1, 1.9 + i * 0.35] }) }],
              }}
            />
          ))}
          <Svg width={BADGE_PX} height={BADGE_PX} viewBox="-66 -66 132 132">
            <Defs>
              <LinearGradient id="revealGrad" x1="0" y1="0" x2="1" y2="1">
                {(gift ? (GIFT_VISUALS[gift.giftName] ?? DEFAULT_VISUAL) : DEFAULT_VISUAL).gradient.map((c, i, arr) => (
                  <Stop key={i} offset={i / Math.max(1, arr.length - 1)} stopColor={c} />
                ))}
              </LinearGradient>
            </Defs>
            <Circle cx={0} cy={0} r={60} fill="none" stroke={COLORS.green2} strokeWidth={3} opacity={0.85} />
            {/* El ícono real solo se sabe hasta que llega el dato — el anillo
                de arriba ya apareció de inmediato, esto se resuelve casi
                al instante detrás (2026-09-05). */}
            {!!gift && !gift.isCustom && (
              <>
                <Circle cx={0} cy={0} r={54} fill="url(#revealGrad)" />
                <Ellipse cx={-16} cy={-20} rx={10} ry={5.5} fill="#fff" opacity={0.2} transform="rotate(-20 -16 -20)" />
                {(() => {
                  const Icon = (GIFT_VISUALS[gift.giftName] ?? DEFAULT_VISUAL).Icon;
                  return Icon ? <Icon /> : null;
                })()}
              </>
            )}
          </Svg>
          {/* Logo real (2026-09-05) — mismo tratamiento que "Otro monto" en
              GiftPickerModal.tsx, en vez de la estrella dibujada. */}
          {!!gift && gift.isCustom && (
            <Image
              source={require('../../../assets/images/icon.png')}
              style={{ position: 'absolute', width: 96, height: 96, borderRadius: 48 }}
              resizeMode="cover"
            />
          )}
        </Animated.View>

        {loading ? (
          <ActivityIndicator color={COLORS.green} style={{ marginTop: 22 }} />
        ) : !gift ? (
          <Text style={[s.errorTx, { marginTop: 22 }]}>{t('gifts.revealError')}</Text>
        ) : (
          <>
            <Text style={s.label}>
              {t('gifts.revealFrom', { name: gift.sender_name ?? t('common.someone') })}
            </Text>

            <Animated.Text
              style={[s.amount, { opacity: amountOpacity, transform: [{ scale: amountScale }] }]}
              numberOfLines={1}
              adjustsFontSizeToFit
            >
              {currencySymbol}{gift.amount} {gift.currency_code}
            </Animated.Text>

            <Text style={s.sub}>{t('gifts.revealThanks')}</Text>

            {celebrating && <ConfettiBurst />}
          </>
        )}
      </View>
    </SafeAreaView>
  );
}

const s = StyleSheet.create({
  safe: { flex: 1, backgroundColor: COLORS.bg },
  closeBtn: {
    position: 'absolute', right: SPACING.xl, zIndex: 10,
    width: 40, height: 40, borderRadius: 20,
    backgroundColor: 'rgba(255,255,255,0.08)', alignItems: 'center', justifyContent: 'center',
  },
  center: { flex: 1, alignItems: 'center', justifyContent: 'center', paddingHorizontal: SPACING.xl, gap: 14 },
  errorTx: { fontFamily: FONTS.body, fontSize: 14, color: COLORS.muted },
  label: { fontFamily: FONTS.bodySemiBold, fontSize: 16, color: '#fff', textAlign: 'center', marginTop: 22 },
  amount: { fontFamily: FONTS.title, fontSize: 40, color: COLORS.green, marginTop: 6 },
  sub: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted, marginTop: 4 },
});
