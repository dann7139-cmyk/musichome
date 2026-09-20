/**
 * DestacadoScreen — Grupos pagan para aparecer en la sección "Destacados"
 * del Explorador (la primera columna que ve el cliente). Pago vía Stripe
 * PaymentSheet nativo, con renovación automática mensual.
 *
 * Petición real (2026-09-19): "si fuera tu app que le metieras para que
 * generara más dinero" → convertir en autoservicio lo que hoy solo se
 * regala manualmente desde el panel admin (admin_activate_sponsored).
 *
 * A diferencia de Recomendado (RecommendationScreen.tsx), Destacado NO
 * tiene un flujo de pago único/instantáneo propio — el único camino real
 * y ya probado es la SUSCRIPCIÓN mensual sobre `advertisements`
 * (create_advertisement_order + create-promo-subscription, kind='sponsored'),
 * el mismo que ya usan los anuncios de banner/perfil. Por eso aquí solo
 * hay un plan (mensual), no un selector de días.
 *
 * Importante: a diferencia de Recomendado (activación instantánea), el
 * primer pago de Destacado SIEMPRE pasa por revisión de un admin
 * (renew_sponsored_subscription dentro de stripe-webhook deja el anuncio
 * en 'pending_review', no 'active') — mismo criterio que banner/perfil.
 * El copy de esta pantalla debe ser honesto sobre ese paso, nunca prometer
 * activación inmediata.
 *
 * Flujo:
 *  1. Muestra estado actual (activo / en revisión / inactivo)
 *  2. Un solo plan: $1,098 MXN/mes (= calculate_ad_price('sponsored_group',
 *     30, 'city', false) — si cambia la fórmula en la BD, cambia aquí)
 *  3. Al confirmar → create_advertisement_order → create-promo-subscription
 *     (kind='sponsored') → PaymentSheet
 *  4. Webhook confirma el pago → renew_sponsored_subscription → pending_review
 *     → un admin aprueba (approve_ad) → sponsored_groups.is_active = true
 */

import { useStripe } from '@stripe/stripe-react-native';
import { LinearGradient } from 'expo-linear-gradient';
import { ArrowLeft, CheckCircle, Clock, Sparkles, Star } from 'lucide-react-native';
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

const ACCENT = '#C9A84C'; // mismo dorado que la tarjeta "Destacado" en PromocionarseScreen
// $1,098 → $599 (sql/670) → $349/mes (sql/671, 2026-09-19) — decisión
// real del usuario tras ver la vista previa: con solo 12 proveedores
// reales en la plataforma, destacarse vale menos porque casi no hay
// competencia todavía; precio de entrada bajo ahora, se sube cuando sí
// haya demanda real por los 5 lugares. Recomendado queda en $499/mes
// (más caro que Destacado a propósito, RecommendationScreen.tsx).
const MONTHLY_PRICE = 349; // calculate_ad_price('sponsored_group', 30, 'city', false)

interface DestacadoStatus {
  active: boolean;
  endsAt: string | null;
  pendingReview: boolean;
}

function fmtDate(iso: string): string {
  return new Date(iso).toLocaleDateString('es-MX', { day: 'numeric', month: 'long', year: 'numeric' });
}
function daysLeft(endsAt: string): number {
  const diff = new Date(endsAt).getTime() - Date.now();
  return diff > 0 ? Math.ceil(diff / 86_400_000) : 0;
}

export default function DestacadoScreen({ navigation, route }: any) {
  const [groupId, setGroupId] = useState<string | undefined>(route?.params?.groupId);
  const [groupName, setGroupName] = useState<string | undefined>();

  const { initPaymentSheet, presentPaymentSheet } = useStripe();

  const [loadingStatus, setLoadingStatus] = useState(true);
  const [submitting, setSubmitting] = useState(false);
  const [refreshing, setRefreshing] = useState(false);
  const [status, setStatus] = useState<DestacadoStatus | null>(null);

  useEffect(() => {
    if (groupId) return;
    supabase.rpc('get_my_group').then(({ data }) => {
      const grp = Array.isArray(data) ? data[0] : data;
      if (grp?.id) { setGroupId(grp.id); setGroupName(grp.name); }
    });
  }, []);

  const loadStatus = useCallback(async () => {
    if (!groupId) return;
    try {
      const { data: { user } } = await supabase.auth.getUser();
      const [{ data: sg }, adRes] = await Promise.all([
        supabase.from('sponsored_groups')
          .select('is_active, ends_at')
          .eq('group_id', groupId)
          .order('created_at', { ascending: false })
          .limit(1).maybeSingle(),
        user
          ? supabase.from('advertisements')
              .select('status')
              .eq('type', 'sponsored_group')
              .eq('advertiser_id', user.id)
              .order('created_at', { ascending: false })
              .limit(1).maybeSingle()
          : Promise.resolve({ data: null }),
      ]);
      const active = !!sg?.is_active && !!sg.ends_at && new Date(sg.ends_at).getTime() > Date.now();
      setStatus({
        active,
        endsAt: sg?.ends_at ?? null,
        pendingReview: (adRes as any)?.data?.status === 'pending_review',
      });
    } catch (e: any) {
      console.error('[DESTACADO] loadStatus error', e?.message);
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

  const handleSubscribe = () => {
    if (!groupId || submitting) return;
    Alert.alert(
      '🌟 Destacar mi grupo',
      `Tu grupo aparece en la sección "Destacados" del Explorador — lo primero que ve el cliente.\n\nSe cobra $${MONTHLY_PRICE} MXN al mes con tarjeta y se renueva sola hasta que canceles. Después del primer pago tu Destacado entra a revisión y se activa en cuanto se aprueba (normalmente rápido) — no es instantáneo.`,
      [
        { text: 'Ahora no', style: 'cancel' },
        { text: `Destacarme · $${MONTHLY_PRICE}`, onPress: startSubscription },
      ],
    );
  };

  const startSubscription = () => {
    void (async () => {
      if (!groupId) return;
      setSubmitting(true);
      try {
        const { data: orderData, error: orderErr } = await supabase.rpc('create_advertisement_order', {
          p_type: 'sponsored_group',
          p_title: groupName ? `${groupName} — Destacado` : 'Destacado',
          p_location_type: 'city',
          p_custom_days: 30,
        });
        if (orderErr || !orderData?.ok) {
          if (orderData?.error === 'no_capacity') {
            throw new Error('Por ahora no hay lugares de Destacado en tu categoría y estado (máx. 5 grupos a la vez). Se liberan cuando vencen las campañas activas — intenta más tarde.');
          }
          throw new Error(orderData?.error ?? orderErr?.message ?? 'Error al crear la orden');
        }
        const adId: string = orderData.ad_id;

        const { data: { session } } = await supabase.auth.getSession();
        if (!session) throw new Error('Sesión expirada. Vuelve a iniciar sesión.');
        const { data, error } = await supabase.functions.invoke('create-promo-subscription', {
          body: { kind: 'sponsored', ad_id: adId },
          headers: { Authorization: `Bearer ${session.access_token}` },
        });
        if (error) throw new Error(error.message ?? 'Error de red');
        if ((data as any)?.error) throw new Error((data as any).error);
        const secret = (data as any)?.payment_intent_client_secret as string | undefined;
        if (!secret) throw new Error('No se recibió el token de pago');

        const { error: initErr } = await initPaymentSheet({
          paymentIntentClientSecret: secret,
          merchantDisplayName: 'Daricefy',
          style: 'alwaysDark',
        });
        if (initErr) throw new Error(initErr.message);
        const { error: payErr } = await presentPaymentSheet();
        if (payErr) {
          if (payErr.code === 'Canceled') return;
          throw new Error(payErr.message);
        }
        Alert.alert(
          '✅ Pago recibido',
          'Tu Destacado entra a revisión y se activa en cuanto se apruebe — normalmente rápido. Se renueva solo cada mes hasta que canceles.',
          [{ text: 'Perfecto', onPress: () => loadStatus() }],
        );
      } catch (err: any) {
        Alert.alert('Error', err.message ?? 'No se pudo procesar el pago. Intenta de nuevo.');
      } finally {
        setSubmitting(false);
      }
    })();
  };

  return (
    <View style={s.root}>
      <SafeAreaView edges={['top']} style={s.header}>
        <Pressable style={s.backBtn} onPress={() => navigation.goBack()}>
          <ArrowLeft size={20} color={COLORS.text} />
        </Pressable>
        <Text style={s.headerTitle}>🌟 Destacar mi grupo</Text>
        <View style={{ width: 40 }} />
      </SafeAreaView>

      <ScrollView
        contentContainerStyle={s.scroll}
        showsVerticalScrollIndicator={false}
        refreshControl={<RefreshControl refreshing={refreshing} onRefresh={onRefresh} tintColor={ACCENT} />}
      >
        <LinearGradient colors={['rgba(201,168,76,0.14)', 'rgba(201,168,76,0.03)', 'transparent']} style={s.hero}>
          <Star size={40} color={ACCENT} />
          <Text style={s.heroTitle}>Aparecer como{'\n'}Destacado</Text>
          <Text style={s.heroSub}>
            Tu grupo entra a la sección "Destacados" — la columna dorada,{'\n'}
            la primera que ve el cliente al abrir el Explorador.
          </Text>
        </LinearGradient>

        {loadingStatus && <ActivityIndicator size="small" color={ACCENT} style={{ marginBottom: 12 }} />}
        {!loadingStatus && (
          status?.active ? (
            <View style={s.activeCard}>
              <View style={s.activeHeader}>
                <CheckCircle size={18} color={ACCENT} />
                <Text style={s.activeTitle}>¡Destacado activo!</Text>
              </View>
              {status.endsAt && (
                <View style={s.activeRow}>
                  <Clock size={13} color={COLORS.muted2} />
                  <Text style={s.activeMeta}>
                    Se renueva en {daysLeft(status.endsAt)} días · {fmtDate(status.endsAt)}
                  </Text>
                </View>
              )}
              <Text style={s.activeRenew}>
                Tu suscripción se renueva sola cada mes. Para cancelarla escríbenos a soporte.
              </Text>
            </View>
          ) : status?.pendingReview ? (
            <View style={s.pendingCard}>
              <Clock size={16} color={ACCENT} />
              <Text style={s.pendingTxt}>
                Tu pago se recibió — tu Destacado está en revisión y se activa en cuanto se apruebe.
              </Text>
            </View>
          ) : (
            <View style={s.inactiveCard}>
              <Sparkles size={16} color={COLORS.muted2} />
              <Text style={s.inactiveTxt}>Aún no tienes Destacado activo.</Text>
            </View>
          )
        )}

        <View style={s.card}>
          <Text style={s.cardTitle}>¿Por qué destacarme?</Text>
          {[
            '🌟  Apareces en la sección PRINCIPAL del Explorador',
            '📈  Es la primera columna que ve el cliente, antes que nada',
            '🎯  Visibilidad en tu propia ciudad y categoría',
            '🔁  Se renueva solo cada mes, cancela cuando quieras',
          ].map((b, i) => (
            <Text key={i} style={s.benefit}>{b}</Text>
          ))}
        </View>

        <View style={s.planCard}>
          <Text style={s.planLabel}>Plan mensual</Text>
          <Text style={s.planPrice}>${MONTHLY_PRICE} <Text style={s.planPriceUnit}>MXN/mes</Text></Text>
          <Text style={s.planNote}>Precio local a tu estado y categoría · cobro recurrente con tarjeta</Text>
        </View>

        <Pressable style={[s.payBtn, submitting && { opacity: 0.7 }]} onPress={handleSubscribe} disabled={submitting}>
          <LinearGradient colors={[ACCENT, '#8C7233']} start={{ x: 0, y: 0 }} end={{ x: 1, y: 0 }} style={s.payGradient}>
            {submitting ? (
              <ActivityIndicator size="small" color={COLORS.bg} />
            ) : (
              <>
                <Star size={17} color={COLORS.bg} />
                <Text style={s.payText}>Destacarme · ${MONTHLY_PRICE}/mes</Text>
              </>
            )}
          </LinearGradient>
        </Pressable>

        <Text style={s.disclaimer}>
          Pago seguro con tarjeta. Tras el primer pago, tu Destacado pasa a revisión
          y se activa al aprobarse — no es instantáneo. Las renovaciones sí son
          automáticas, sin pasos extra.
        </Text>

        <View style={{ height: 40 }} />
      </ScrollView>
    </View>
  );
}

const s = StyleSheet.create({
  root: { flex: 1, backgroundColor: COLORS.bg },
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
  scroll: { padding: SPACING.xl, gap: 14 },

  hero: {
    alignItems: 'center', paddingVertical: 28, paddingHorizontal: 20,
    borderRadius: RADIUS.xl, gap: 10,
    borderWidth: 1, borderColor: 'rgba(201,168,76,0.25)',
  },
  heroTitle: { fontFamily: FONTS.title, fontSize: 26, color: COLORS.text, textAlign: 'center', lineHeight: 32 },
  heroSub: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2, textAlign: 'center', lineHeight: 20 },

  activeCard: {
    backgroundColor: 'rgba(201,168,76,0.08)', borderRadius: RADIUS.xl,
    borderWidth: 1, borderColor: 'rgba(201,168,76,0.3)', padding: SPACING.lg, gap: 8,
  },
  activeHeader: { flexDirection: 'row', alignItems: 'center', gap: 8 },
  activeTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: ACCENT },
  activeRow: { flexDirection: 'row', alignItems: 'center', gap: 6 },
  activeMeta: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2 },
  activeRenew: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted, marginTop: 4 },

  pendingCard: {
    flexDirection: 'row', alignItems: 'center', gap: 10,
    backgroundColor: 'rgba(201,168,76,0.08)', borderRadius: RADIUS.xl,
    borderWidth: 1, borderColor: 'rgba(201,168,76,0.3)', padding: SPACING.lg,
  },
  pendingTxt: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.text, flex: 1 },

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
  benefit: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2, lineHeight: 20 },

  planCard: {
    backgroundColor: 'rgba(201,168,76,0.06)', borderRadius: RADIUS.xl,
    borderWidth: 1.5, borderColor: 'rgba(201,168,76,0.4)', padding: SPACING.lg, gap: 4,
    alignItems: 'center',
  },
  planLabel: {
    fontFamily: FONTS.bodySemiBold, fontSize: 11, color: COLORS.muted2,
    textTransform: 'uppercase', letterSpacing: 1,
  },
  planPrice: { fontFamily: FONTS.title, fontSize: 30, color: COLORS.text, marginTop: 2 },
  planPriceUnit: { fontFamily: FONTS.body, fontSize: 14, color: COLORS.muted2 },
  planNote: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted, textAlign: 'center', marginTop: 4 },

  payBtn: { borderRadius: RADIUS.xl, overflow: 'hidden', marginTop: 4 },
  payGradient: { flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 9, paddingVertical: 16 },
  payText: { fontFamily: FONTS.bodySemiBold, fontSize: 16, color: COLORS.bg },

  disclaimer: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted, textAlign: 'center', lineHeight: 17 },
});
