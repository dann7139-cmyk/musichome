/**
 * RecommendationScreen — Grupos pagan para aparecer en "Recomendado para ti"
 * de la HomeScreen del cliente. Pago vía Stripe PaymentSheet nativo.
 *
 * Flujo:
 *  1. Muestra estado actual (activo/inactivo) y cuándo expira
 *  2. Muestra 3 paquetes de duración con precio
 *  3. Al confirmar → place_recommendation_order → create-recommendation-payment → PaymentSheet
 *  4. Webhook stripe-webhook confirma el pago → confirm_recommendation_payment → wallet
 */

import { useStripe } from '@stripe/stripe-react-native';
import { LinearGradient } from 'expo-linear-gradient';
import { ArrowLeft, CheckCircle, Clock, Star, TrendingUp, Zap } from 'lucide-react-native';
import React, { useCallback, useEffect, useState } from 'react';
import {
  ActivityIndicator,
  Alert,
  Pressable,
  RefreshControl,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { supabase } from '../../config/supabase';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';

// ─── Tipos ────────────────────────────────────────────────────────────────────

interface RecPackage {
  days: number;
  label: string;
  price: number;
  perDay: number;
  savings: number;
  emoji: string;
  highlight?: boolean;
}

interface RecStatus {
  active: boolean;
  order_id?: string;
  amount?: number;
  duration_days?: number;
  ends_at?: string;
  starts_at?: string;
  last_order?: {
    order_id: string;
    status: string;
    amount: number;
    ends_at: string;
  } | null;
}

// ─── Paquetes de duración ────────────────────────────────────────────────────

const PACKAGES: RecPackage[] = [
  {
    days: 1, label: '1 día', price: 79, perDay: 79, savings: 0,
    emoji: '⚡',
  },
  {
    days: 3, label: '3 días', price: 199, perDay: 66, savings: 38,
    emoji: '🚀',
    highlight: true,
  },
  {
    days: 7, label: '7 días', price: 399, perDay: 57, savings: 154,
    emoji: '👑',
  },
];

// ─── Helpers ─────────────────────────────────────────────────────────────────

function fmtDate(iso: string): string {
  return new Date(iso).toLocaleDateString('es-MX', {
    day: 'numeric', month: 'long', year: 'numeric',
  });
}

function daysLeft(endsAt: string): number {
  const diff = new Date(endsAt).getTime() - Date.now();
  return diff > 0 ? Math.ceil(diff / 86_400_000) : 0;
}

// ─── Screen ───────────────────────────────────────────────────────────────────

export default function RecommendationScreen({ navigation, route }: any) {
  const [groupId, setGroupId] = useState<string | undefined>(route?.params?.groupId);

  const { initPaymentSheet, presentPaymentSheet } = useStripe();

  const [loadingStatus, setLoadingStatus] = useState(true); // eslint-disable-line
  const [submitting, setSubmitting] = useState(false);
  const [refreshing, setRefreshing] = useState(false);
  const [status,     setStatus]     = useState<RecStatus | null>(null);
  const [selected,   setSelected]   = useState<RecPackage>(PACKAGES[1]);

  // ── Cargar groupId si no viene en params ───────────────────────────────────
  useEffect(() => {
    if (groupId) return;
    supabase.rpc('get_my_group').then(({ data }) => {
      const grp = Array.isArray(data) ? data[0] : data;
      if (grp?.id) setGroupId(grp.id);
    });
  }, []);

  // ── Cargar estado actual ────────────────────────────────────────────────────
  const loadStatus = useCallback(async () => {
    if (!groupId) return;
    try {
      const { data, error } = await supabase.rpc('get_my_recommendation_status', {
        p_group_id: groupId,
      });
      if (error) throw error;
      setStatus(data as RecStatus);
    } catch (e: any) {
      console.error('[REC] loadStatus error', e?.message);
    } finally {
      setLoadingStatus(false);
    }
  }, [groupId]);

  useEffect(() => { loadStatus(); }, [loadStatus]);

  const onRefresh = async () => {
    setRefreshing(true);
    await loadStatus();
    setRefreshing(false);
  };

  // ── Pagar con Stripe ────────────────────────────────────────────────────────
  const handlePurchase = async () => {
    if (!groupId) return;

    Alert.alert(
      '⭐ Confirmar recomendación',
      `Aparecer en "Recomendado para ti" durante ${selected.label}\n\nPrecio: $${selected.price} MXN`,
      [
        { text: 'Cancelar', style: 'cancel' },
        {
          text: `Pagar $${selected.price}`,
          onPress: async () => {
            setSubmitting(true);
            try {
              // 1. Crear orden en la BD
              const { data: orderData, error: orderErr } = await supabase.rpc(
                'place_recommendation_order',
                { p_group_id: groupId, p_duration: selected.days },
              );
              if (orderErr || !orderData?.ok) {
                throw new Error(orderData?.error ?? orderErr?.message ?? 'Error al crear orden');
              }
              const orderId: string = orderData.order_id;

              // 2. Crear PaymentIntent en Stripe (Edge Function)
              const { data: { session: paySession } } = await supabase.auth.getSession();
              if (!paySession) throw new Error('Sesión expirada. Vuelve a iniciar sesión.');
              const { data: stripeData, error: stripeErr } = await supabase.functions.invoke(
                'create-recommendation-payment',
                {
                  body: { order_id: orderId },
                  headers: { Authorization: `Bearer ${paySession.access_token}` },
                },
              );

              if (stripeErr) throw new Error(stripeErr.message ?? 'Error de función');
              if (!stripeData) throw new Error('Sin respuesta del servidor de pagos');
              if (stripeData.error) throw new Error(stripeData.error);

              const clientSecret: string = stripeData.client_secret;
              if (!clientSecret) throw new Error('No se recibió el token de pago');

              // 3. Inicializar PaymentSheet
              const { error: initErr } = await initPaymentSheet({
                paymentIntentClientSecret: clientSecret,
                merchantDisplayName:       'Daricefy',
                style:                     'alwaysDark',
              });
              if (initErr) throw new Error(`Error al inicializar pago: ${initErr.message}`);

              // 4. Presentar hoja de pago nativa de Stripe
              const { error: payErr } = await presentPaymentSheet();

              if (payErr) {
                if (payErr.code === 'Canceled') {
                  Alert.alert('Pago cancelado', 'Puedes intentarlo de nuevo cuando quieras.');
                  return;
                }
                throw new Error(payErr.message);
              }

              // 5. Pago exitoso — el webhook confirma en segundo plano
              console.log('[RECOMMENDATION_PAYMENT]', {
                order_id:     orderId,
                amount:       selected.price,
                group_id:     groupId,
                duration_days: selected.days,
                reference_id: `rec_${orderId}`,
              });

              Alert.alert(
                '✅ ¡Recomendación activada!',
                `Tu grupo aparecerá en "Recomendado para ti" durante ${selected.label}. Se activa en segundos.`,
                [{ text: 'Perfecto', onPress: () => loadStatus() }],
              );
            } catch (err: any) {
              Alert.alert('Error', err.message ?? 'No se pudo procesar el pago. Intenta de nuevo.');
            } finally {
              setSubmitting(false);
            }
          },
        },
      ],
    );
  };

  // ── Render ──────────────────────────────────────────────────────────────────
  return (
    <View style={s.root}>
      <SafeAreaView edges={['top']} style={s.header}>
        <Pressable style={s.backBtn} onPress={() => navigation.goBack()}>
          <ArrowLeft size={20} color={COLORS.text} />
        </Pressable>
        <Text style={s.headerTitle}>⭐ Ser recomendado</Text>
        <View style={{ width: 40 }} />
      </SafeAreaView>

      <ScrollView
          contentContainerStyle={s.scroll}
          showsVerticalScrollIndicator={false}
          refreshControl={
            <RefreshControl refreshing={refreshing} onRefresh={onRefresh} tintColor={COLORS.gold} />
          }
        >
          {/* ── Hero ── */}
          <LinearGradient
            colors={['rgba(255,193,7,0.12)', 'rgba(255,193,7,0.03)', 'transparent']}
            style={s.hero}
          >
            <Star size={40} color={COLORS.gold} />
            <Text style={s.heroTitle}>Aparecer como{'\n'}Recomendado</Text>
            <Text style={s.heroSub}>
              Tu grupo aparece primero en "Recomendado para ti"{'\n'}
              para clientes en tu ciudad. Más visibilidad = más reservas.
            </Text>
          </LinearGradient>

          {/* ── Estado actual ── */}
          {loadingStatus && (
            <ActivityIndicator size="small" color={COLORS.gold} style={{ marginBottom: 12 }} />
          )}
          {!loadingStatus && (status?.active ? (
            <View style={s.activeCard}>
              <View style={s.activeHeader}>
                <CheckCircle size={18} color={COLORS.gold} />
                <Text style={s.activeTitle}>¡Recomendación activa!</Text>
              </View>
              <View style={s.activeRow}>
                <Clock size={13} color={COLORS.muted2} />
                <Text style={s.activeMeta}>
                  Expira en {daysLeft(status.ends_at!)} días · {fmtDate(status.ends_at!)}
                </Text>
              </View>
              <View style={s.activeRow}>
                <TrendingUp size={13} color={COLORS.gold} />
                <Text style={s.activeMeta}>
                  {status.duration_days} días · ${status.amount} pagados
                </Text>
              </View>
              <Text style={s.activeRenew}>
                Puedes comprar un nuevo paquete para extender tu visibilidad.
              </Text>
            </View>
          ) : (
            <View style={s.inactiveCard}>
              <Zap size={16} color={COLORS.muted2} />
              <Text style={s.inactiveTxt}>
                {status?.last_order
                  ? 'Tu última recomendación expiró. ¡Actívala de nuevo!'
                  : 'Aún no tienes ninguna recomendación activa.'}
              </Text>
            </View>
          ))}

          {/* ── Beneficios ── */}
          <View style={s.card}>
            <Text style={s.cardTitle}>¿Por qué ser recomendado?</Text>
            {[
              '⭐  Apareces PRIMERO en "Recomendado para ti" en tu ciudad',
              '📈  Mayor visibilidad = más solicitudes de reserva',
              '🎯  Clientes ya filtrados por tu ciudad y género',
              '⚡  Activación inmediata al confirmar el pago',
            ].map((b, i) => (
              <Text key={i} style={s.benefit}>{b}</Text>
            ))}
          </View>

          {/* ── Selector de duración ── */}
          <Text style={s.sectionLabel}>Elige tu paquete</Text>

          {PACKAGES.map((pkg) => {
            const isSelected = selected.days === pkg.days;
            return (
              <Pressable
                key={pkg.days}
                style={[
                  s.pkgCard,
                  isSelected && s.pkgCardSelected,
                  pkg.highlight && s.pkgHighlight,
                ]}
                onPress={() => setSelected(pkg)}
              >
                {pkg.highlight && (
                  <View style={s.popularBadge}>
                    <Text style={s.popularBadgeText}>MÁS POPULAR</Text>
                  </View>
                )}
                <View style={s.pkgRow}>
                  <Text style={s.pkgEmoji}>{pkg.emoji}</Text>
                  <View style={{ flex: 1 }}>
                    <Text style={[s.pkgLabel, isSelected && { color: COLORS.gold }]}>
                      {pkg.label}
                    </Text>
                    <Text style={s.pkgPerDay}>${pkg.perDay}/día</Text>
                  </View>
                  <View style={s.pkgRight}>
                    <Text style={[s.pkgPrice, isSelected && { color: COLORS.gold }]}>
                      ${pkg.price}
                    </Text>
                    {pkg.savings > 0 && (
                      <Text style={s.pkgSavings}>ahorras ${pkg.savings}</Text>
                    )}
                  </View>
                  <View style={[s.radio, isSelected && s.radioSelected]}>
                    {isSelected && <View style={s.radioDot} />}
                  </View>
                </View>
              </Pressable>
            );
          })}

          {/* ── Botón de pago ── */}
          <Pressable
            style={[s.payBtn, submitting && { opacity: 0.7 }]}
            onPress={handlePurchase}
            disabled={submitting}
          >
            <LinearGradient
              colors={[COLORS.gold, '#F59E0B']}
              start={{ x: 0, y: 0 }}
              end={{ x: 1, y: 0 }}
              style={s.payGradient}
            >
              {submitting ? (
                <ActivityIndicator size="small" color={COLORS.bg} />
              ) : (
                <>
                  <Star size={17} color={COLORS.bg} />
                  <Text style={s.payText}>
                    Activar recomendación · ${selected.price}
                  </Text>
                </>
              )}
            </LinearGradient>
          </Pressable>

          <Text style={s.disclaimer}>
            Pago seguro con tarjeta vía Stripe. La recomendación se activa automáticamente
            al confirmar. Sin renovación automática.
          </Text>

          <View style={{ height: 40 }} />
        </ScrollView>
    </View>
  );
}

// ─── Styles ───────────────────────────────────────────────────────────────────

const s = StyleSheet.create({
  root:   { flex: 1, backgroundColor: COLORS.bg },
  header: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between',
    paddingHorizontal: SPACING.xl, paddingVertical: 12,
    borderBottomWidth: 1, borderBottomColor: COLORS.border,
  },
  backBtn: {
    width: 40, height: 40, borderRadius: 12,
    backgroundColor: COLORS.card, borderWidth: 1, borderColor: COLORS.border,
    alignItems: 'center', justifyContent: 'center',
  },
  headerTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 17, color: COLORS.text },
  center: { flex: 1, alignItems: 'center', justifyContent: 'center' },
  scroll: { padding: SPACING.xl, gap: 14 },

  hero: {
    alignItems: 'center', paddingVertical: 28, paddingHorizontal: 20,
    borderRadius: RADIUS.xl, gap: 10,
    borderWidth: 1, borderColor: 'rgba(255,193,7,0.2)',
  },
  heroTitle: {
    fontFamily: FONTS.title, fontSize: 26, color: COLORS.text,
    textAlign: 'center', lineHeight: 32,
  },
  heroSub: {
    fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2,
    textAlign: 'center', lineHeight: 20,
  },

  activeCard: {
    backgroundColor: 'rgba(255,193,7,0.08)', borderRadius: RADIUS.xl,
    borderWidth: 1, borderColor: 'rgba(255,193,7,0.3)', padding: SPACING.lg, gap: 8,
  },
  activeHeader: { flexDirection: 'row', alignItems: 'center', gap: 8 },
  activeTitle:  { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.gold },
  activeRow:    { flexDirection: 'row', alignItems: 'center', gap: 6 },
  activeMeta:   { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2 },
  activeRenew:  { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted, marginTop: 4 },

  inactiveCard: {
    flexDirection: 'row', alignItems: 'center', gap: 10,
    backgroundColor: COLORS.card, borderRadius: RADIUS.xl,
    borderWidth: 1, borderColor: COLORS.border, padding: SPACING.lg,
  },
  inactiveTxt: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2, flex: 1 },

  card: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.xl,
    borderWidth: 1, borderColor: COLORS.border, padding: SPACING.lg, gap: 8,
  },
  cardTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.text, marginBottom: 4 },
  benefit:   { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2, lineHeight: 20 },

  sectionLabel: {
    fontFamily: FONTS.bodySemiBold, fontSize: 11, color: COLORS.muted2,
    textTransform: 'uppercase', letterSpacing: 1,
  },
  pkgCard: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.xl,
    borderWidth: 1, borderColor: COLORS.border, padding: SPACING.lg,
    position: 'relative', overflow: 'hidden',
  },
  pkgCardSelected: { borderColor: COLORS.gold, backgroundColor: 'rgba(255,193,7,0.06)' },
  pkgHighlight:    { borderColor: 'rgba(255,193,7,0.35)' },
  popularBadge: {
    position: 'absolute', top: 10, right: 10,
    backgroundColor: COLORS.gold, borderRadius: 6,
    paddingHorizontal: 8, paddingVertical: 2,
  },
  popularBadgeText: { fontFamily: FONTS.bodySemiBold, fontSize: 9, color: COLORS.bg, letterSpacing: 0.6 },
  pkgRow:    { flexDirection: 'row', alignItems: 'center', gap: 12 },
  pkgEmoji:  { fontSize: 22, width: 32, textAlign: 'center' },
  pkgLabel:  { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.text },
  pkgPerDay: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, marginTop: 2 },
  pkgRight:  { alignItems: 'flex-end', marginRight: 12 },
  pkgPrice:  { fontFamily: FONTS.title, fontSize: 20, color: COLORS.text },
  pkgSavings:{ fontFamily: FONTS.body, fontSize: 11, color: COLORS.green, marginTop: 1 },

  radio:         { width: 20, height: 20, borderRadius: 10, borderWidth: 2, borderColor: COLORS.border, alignItems: 'center', justifyContent: 'center' },
  radioSelected: { borderColor: COLORS.gold },
  radioDot:      { width: 10, height: 10, borderRadius: 5, backgroundColor: COLORS.gold },

  payBtn:      { borderRadius: RADIUS.xl, overflow: 'hidden', marginTop: 4 },
  payGradient: { flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 9, paddingVertical: 16 },
  payText:     { fontFamily: FONTS.bodySemiBold, fontSize: 16, color: COLORS.bg },

  disclaimer: {
    fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted,
    textAlign: 'center', lineHeight: 17,
  },
});
