/**
 * PlusScreen — Verificación Plus para grupos.
 *
 * Flujo:
 *  1. Carga el estado actual de Plus vía get_my_plus_status
 *  2. Si inactivo: muestra selector mensual/anual + CTA trial 7 días
 *  3. Al confirmar → create-plus-subscription → SetupIntent → PaymentSheet
 *  4. El webhook activa Plus en el fondo (subscription.created → activate_plus)
 *  5. Si activo: muestra estado + botón a Stripe Customer Portal
 */

import { useStripe } from '@stripe/stripe-react-native';
import * as WebBrowser from 'expo-web-browser';
import { LinearGradient } from 'expo-linear-gradient';
import { ArrowLeft, CheckCircle, ShieldCheck, TrendingUp, Zap, Star, AlertCircle } from 'lucide-react-native';
import React, { useCallback, useEffect, useState } from 'react';
import {
  ActivityIndicator,
  Alert,
  Linking,
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
import { SUPPORT_EMAIL } from '../../utils/support';

// ─── Tipos ────────────────────────────────────────────────────────────────────

type PlusPlan = 'monthly' | 'annual';

interface PlusStatus {
  is_active:     boolean;
  status:        string;  // trialing | active | past_due | cancelled | inactive
  trial_ends_at: string | null;
  expires_at:    string | null;
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

function fmtDate(iso: string | null): string {
  if (!iso) return '—';
  return new Date(iso).toLocaleDateString('es-MX', {
    day: 'numeric', month: 'long', year: 'numeric',
  });
}

function daysLeft(iso: string | null): number {
  if (!iso) return 0;
  const diff = new Date(iso).getTime() - Date.now();
  return diff > 0 ? Math.ceil(diff / 86_400_000) : 0;
}

// ─── Screen ───────────────────────────────────────────────────────────────────

export default function PlusScreen({ navigation, route }: any) {
  const groupId: string | undefined = route?.params?.groupId;

  const { initPaymentSheet, presentPaymentSheet } = useStripe();

  const [resolvedGroupId, setResolvedGroupId] = useState<string | undefined>(groupId);
  const [status,          setStatus]          = useState<PlusStatus | null>(null);
  const [selectedPlan,    setSelectedPlan]    = useState<PlusPlan>('annual');
  const [loading,         setLoading]         = useState(true);
  const [submitting,      setSubmitting]      = useState(false);
  const [refreshing,      setRefreshing]      = useState(false);

  // ── Resolver groupId si no viene en params ─────────────────────────────────
  useEffect(() => {
    if (resolvedGroupId) return;
    supabase.rpc('get_my_group').then(({ data }) => {
      const grp = Array.isArray(data) ? data[0] : data;
      if (grp?.id) setResolvedGroupId(grp.id);
    });
  }, []);

  // ── Cargar estado Plus ─────────────────────────────────────────────────────
  const loadStatus = useCallback(async () => {
    if (!resolvedGroupId) return;
    try {
      const { data, error } = await supabase.rpc('get_my_plus_status', {
        p_group_id: resolvedGroupId,
      });
      if (error) throw error;
      const row = Array.isArray(data) ? data[0] : data;
      setStatus(row ?? { is_active: false, status: 'inactive', trial_ends_at: null, expires_at: null });
    } catch (e: any) {
      console.error('[PlusScreen] loadStatus:', e?.message);
    } finally {
      setLoading(false);
    }
  }, [resolvedGroupId]);

  useEffect(() => { loadStatus(); }, [loadStatus]);

  const onRefresh = async () => {
    setRefreshing(true);
    await loadStatus();
    setRefreshing(false);
  };

  // ── Suscripción Stripe (mensual o anual) — SetupIntent + trial 7 días ───────
  const startStripeSubscription = async () => {
    setSubmitting(true);
    try {
      // 1. Obtener sesión
      const { data: { session } } = await supabase.auth.getSession();
      if (!session) throw new Error('Sesión expirada. Vuelve a iniciar sesión.');

      // 2. Crear Stripe Subscription (SetupIntent, sin cobro inmediato)
      const { data: stripeData, error: stripeErr } = await supabase.functions.invoke(
        'create-plus-subscription',
        {
          body: { group_id: resolvedGroupId, plan: selectedPlan },
          headers: { Authorization: `Bearer ${session.access_token}` },
        },
      );

      if (stripeErr) throw new Error(stripeErr.message ?? 'Error de función');
      if (!stripeData) throw new Error('Sin respuesta del servidor de pagos');
      if (stripeData.error) throw new Error(stripeData.error);

      // 🎁 El trial de 7 días es UNA sola vez (lo decide el servidor):
      //   · trial=true  → SetupIntent (captura tarjeta, cobra al día 8)
      //   · trial=false → PaymentIntent (ya usó su prueba: cobra HOY)
      const setupSecret: string | null = stripeData.setup_intent_client_secret ?? null;
      const paySecret: string | null   = stripeData.payment_intent_client_secret ?? null;
      const hasTrial: boolean          = stripeData.trial !== false;
      if (!setupSecret && !paySecret) throw new Error('No se recibió el token de configuración');

      // 3. Inicializar PaymentSheet (Setup con trial / Payment sin trial)
      const { error: initErr } = await initPaymentSheet({
        ...(setupSecret
          ? { setupIntentClientSecret: setupSecret }
          : { paymentIntentClientSecret: paySecret! }),
        merchantDisplayName: 'Daricefy',
        style:               'alwaysDark',
      });
      if (initErr) throw new Error(`Error al inicializar: ${initErr.message}`);

      // 4. Presentar hoja de pago nativa de Stripe
      const { error: payErr } = await presentPaymentSheet();
      if (payErr) {
        if (payErr.code === 'Canceled') return;
        throw new Error(payErr.message);
      }

      // 5. Listo — Plus se activa en segundos vía webhook
      Alert.alert(
        '✅ ¡Plus activado!',
        hasTrial
          ? 'Tu badge verde ya está visible. El webhook confirmará en segundos.\n\nTu tarjeta se cobrará en 7 días.'
          : 'Tu pago se procesó y tu badge verde se activa en segundos.\n\n(La prueba gratis solo aplica la primera vez.)',
        [{ text: 'Entendido', onPress: () => loadStatus() }],
      );
    } catch (err: any) {
      Alert.alert('Error', err.message ?? 'No se pudo procesar. Intenta de nuevo.');
    } finally {
      setSubmitting(false);
    }
  };

  // ── 🏆 Pago ÚNICO anual con Conekta (tarjeta, OXXO o SPEI) ──────────────────
  // Sin renovación automática: el webhook activa 1 año con activate_plus.
  // Si paga antes de vencer, el año se SUMA al vencimiento actual.
  const handlePayAnnualConekta = async () => {
    if (!resolvedGroupId || submitting) return;
    setSubmitting(true);
    try {
      const { data: { session } } = await supabase.auth.getSession();
      if (!session) throw new Error('Sesión expirada. Vuelve a iniciar sesión.');

      const { data, error } = await supabase.functions.invoke('create-plus-conekta-order', {
        body:    { group_id: resolvedGroupId },
        headers: { Authorization: `Bearer ${session.access_token}` },
      });
      if (error) throw new Error(error.message ?? 'Error de red');
      if ((data as any)?.error) throw new Error((data as any).error);
      const url = (data as any)?.checkout_url as string | undefined;
      if (!url) throw new Error('No se recibió la página de pago');

      // El pago ocurre en el navegador; el WEBHOOK es la fuente de verdad.
      await WebBrowser.openBrowserAsync(url);

      // Al volver: refrescar estado. Tarjeta confirma en segundos;
      // OXXO/SPEI se activa solo cuando el cliente deposita.
      await loadStatus();
      Alert.alert(
        '⏳ Esperando confirmación',
        'Si pagaste con tarjeta, tu Plus se activa en unos segundos (desliza hacia abajo para actualizar).\n\nSi elegiste OXXO o SPEI, se activa automáticamente cuando se acredite tu depósito y te llegará una notificación.',
      );
    } catch (err: any) {
      Alert.alert('Error', err.message ?? 'No se pudo iniciar el pago. Intenta de nuevo.');
    } finally {
      setSubmitting(false);
    }
  };

  // ── Comprar Plus ───────────────────────────────────────────────────────────
  const handleSubscribe = async () => {
    if (!resolvedGroupId) return;

    // Anual: elegir entre suscripción (Stripe, renueva sola) o pago único
    // (Conekta: tarjeta, OXXO o SPEI — para quien no quiere cargos recurrentes)
    if (selectedPlan === 'annual') {
      Alert.alert(
        '🛡 Plus Anual — $1,499 MXN',
        '¿Cómo quieres pagar tu año?\n\n🔁 Con renovación: tu tarjeta se cobra sola cada año hasta que canceles.\n💵 Pago único: pagas una vez y tu Plus dura 1 año — NADIE te vuelve a cobrar; al vencer decides si renuevas.',
        [
          { text: 'Cancelar', style: 'cancel' },
          {
            text: '🔁 Tarjeta — se renueva sola cada año',
            onPress: () => startStripeSubscription(),
          },
          {
            text: '💵 Pago único · tarjeta, OXXO o SPEI',
            onPress: () => handlePayAnnualConekta(),
          },
        ],
      );
      return;
    }

    // Aquí solo llega el plan mensual (el anual salió arriba con su selector)
    Alert.alert(
      '🛡 Verificación Plus',
      'Plan: Mensual — $199 MXN / mes\n\n🔁 COBRO AUTOMÁTICO: tu tarjeta se cobra sola cada mes hasta que canceles (puedes cancelar cuando quieras desde "Gestionar suscripción").\n\nPrimera vez: 7 días gratis y el cobro inicia al día 8. Si ya usaste tu prueba gratis, el primer cobro es hoy.',
      [
        { text: 'Cancelar', style: 'cancel' },
        {
          text: 'Comenzar prueba gratis',
          onPress: () => startStripeSubscription(),
        },
      ],
    );
  };

  // ── Gestionar suscripción (Stripe Customer Portal) ─────────────────────────
  const [portalLoading, setPortalLoading] = useState(false);

  const handleManage = async () => {
    if (!resolvedGroupId || portalLoading) return;
    setPortalLoading(true);
    try {
      const { data: { session } } = await supabase.auth.getSession();
      if (!session) throw new Error('Sesión expirada. Vuelve a iniciar sesión.');

      const { data, error } = await supabase.functions.invoke('create-portal-session', {
        body:    { group_id: resolvedGroupId },
        headers: { Authorization: `Bearer ${session.access_token}` },
      });

      if (error) throw new Error(error.message ?? 'Error de red');
      if (data?.error === 'portal_not_configured') {
        Alert.alert(
          'Portal no disponible',
          `Para cancelar o cambiar tu tarjeta, escríbenos a ${SUPPORT_EMAIL}`,
        );
        return;
      }
      if (data?.error) throw new Error(data.error);

      const portalUrl: string = data?.url;
      if (!portalUrl) throw new Error('No se recibió URL del portal');

      await Linking.openURL(portalUrl);
    } catch (err: any) {
      Alert.alert('Error', err.message ?? 'No se pudo abrir el portal. Intenta de nuevo.');
    } finally {
      setPortalLoading(false);
    }
  };

  // ── Precios según plan ─────────────────────────────────────────────────────
  const PRICES = {
    monthly: { mxn: '$199', label: 'mes', perMonth: '$199/mes' },
    annual:  { mxn: '$1,499', label: 'año', perMonth: '~$125/mes', savings: 'Ahorras $889' },
  };

  // ── Loading ────────────────────────────────────────────────────────────────
  if (loading) {
    return (
      <View style={s.root}>
        <SafeAreaView edges={['top']} style={s.header}>
          <Pressable style={s.backBtn} onPress={() => navigation.goBack()}>
            <ArrowLeft size={20} color={COLORS.text} />
          </Pressable>
          <Text style={s.headerTitle}>Verificación Plus</Text>
          <View style={{ width: 40 }} />
        </SafeAreaView>
        <View style={s.loadingCenter}>
          <ActivityIndicator size="large" color={COLORS.green} />
        </View>
      </View>
    );
  }

  const isActive  = status?.is_active ?? false;
  const isTrial   = status?.status === 'trialing';
  const isPastDue = status?.status === 'past_due';
  // Activo pero SIN suscripción Stripe = pago único anual (Conekta):
  // no se renueva solo → "Vence el..." y botón de renovar (no portal Stripe)
  const isOneTime = isActive && status?.status === 'inactive';

  // ── Render: Plus activo ────────────────────────────────────────────────────
  if (isActive || isTrial) {
    return (
      <View style={s.root}>
        <SafeAreaView edges={['top']} style={s.header}>
          <Pressable style={s.backBtn} onPress={() => navigation.goBack()}>
            <ArrowLeft size={20} color={COLORS.text} />
          </Pressable>
          <Text style={s.headerTitle}>Verificación Plus</Text>
          <View style={{ width: 40 }} />
        </SafeAreaView>

        <ScrollView
          contentContainerStyle={s.scroll}
          showsVerticalScrollIndicator={false}
          refreshControl={<RefreshControl refreshing={refreshing} onRefresh={onRefresh} tintColor={COLORS.green} />}
        >
          {/* Hero activo */}
          <LinearGradient
            colors={['rgba(0,230,118,0.14)', 'rgba(0,230,118,0.04)', 'transparent']}
            style={s.hero}
          >
            <ShieldCheck size={52} color={COLORS.green} strokeWidth={1.8} />
            <Text style={s.heroTitle}>Plus Activo</Text>
            {isTrial ? (
              <View style={s.trialBanner}>
                <Text style={s.trialBannerText}>
                  🎁 Prueba gratuita · {daysLeft(status?.trial_ends_at ?? null)} días restantes
                </Text>
                <Text style={s.trialBannerSub}>
                  Tu tarjeta se cobra el {fmtDate(status?.trial_ends_at ?? null)}
                </Text>
              </View>
            ) : (
              <Text style={s.heroSub}>
                {isOneTime ? 'Vence el' : 'Se renueva el'} {fmtDate(status?.expires_at ?? null)}
              </Text>
            )}
          </LinearGradient>

          {/* Beneficios activos */}
          <View style={s.benefitsCard}>
            <Text style={s.benefitsTitle}>Tu Plus incluye</Text>
            {BENEFITS.map((b, i) => (
              <View key={i} style={s.benefitRow}>
                <CheckCircle size={16} color={COLORS.green} />
                <Text style={s.benefitText}>{b}</Text>
              </View>
            ))}
          </View>

          {/* Gestión — suscripción Stripe: portal · pago único: renovar otro año */}
          {isOneTime ? (
            <Pressable style={[s.manageBtn, submitting && { opacity: 0.6 }]} onPress={handlePayAnnualConekta} disabled={submitting}>
              {submitting
                ? <ActivityIndicator size="small" color={COLORS.text} />
                : <Text style={s.manageBtnText}>Renovar 1 año más · $1,499</Text>}
            </Pressable>
          ) : (
            <Pressable style={[s.manageBtn, portalLoading && { opacity: 0.6 }]} onPress={handleManage} disabled={portalLoading}>
              {portalLoading
                ? <ActivityIndicator size="small" color={COLORS.text} />
                : <Text style={s.manageBtnText}>Gestionar suscripción</Text>}
            </Pressable>
          )}

          <View style={{ height: 40 }} />
        </ScrollView>
      </View>
    );
  }

  // ── Render: Pago fallido ───────────────────────────────────────────────────
  if (isPastDue) {
    return (
      <View style={s.root}>
        <SafeAreaView edges={['top']} style={s.header}>
          <Pressable style={s.backBtn} onPress={() => navigation.goBack()}>
            <ArrowLeft size={20} color={COLORS.text} />
          </Pressable>
          <Text style={s.headerTitle}>Verificación Plus</Text>
          <View style={{ width: 40 }} />
        </SafeAreaView>
        <View style={s.pastDueCenter}>
          <AlertCircle size={48} color={COLORS.red} />
          <Text style={s.pastDueTitle}>Pago fallido</Text>
          <Text style={s.pastDueSub}>
            No pudimos cobrar tu tarjeta. Tu badge Plus está desactivado.
          </Text>
          <Pressable style={[s.manageBtn, portalLoading && { opacity: 0.6 }]} onPress={handleManage} disabled={portalLoading}>
            {portalLoading
              ? <ActivityIndicator size="small" color={COLORS.text} />
              : <Text style={s.manageBtnText}>Actualizar tarjeta</Text>}
          </Pressable>
        </View>
      </View>
    );
  }

  // ── Render: Inactivo — pantalla de compra ──────────────────────────────────
  return (
    <View style={s.root}>
      <SafeAreaView edges={['top']} style={s.header}>
        <Pressable style={s.backBtn} onPress={() => navigation.goBack()}>
          <ArrowLeft size={20} color={COLORS.text} />
        </Pressable>
        <Text style={s.headerTitle}>Verificación Plus</Text>
        <View style={{ width: 40 }} />
      </SafeAreaView>

      <ScrollView
        contentContainerStyle={s.scroll}
        showsVerticalScrollIndicator={false}
        refreshControl={<RefreshControl refreshing={refreshing} onRefresh={onRefresh} tintColor={COLORS.green} />}
      >
        {/* Hero */}
        <LinearGradient
          colors={['rgba(0,230,118,0.10)', 'rgba(0,230,118,0.02)', 'transparent']}
          style={s.hero}
        >
          <ShieldCheck size={52} color={COLORS.green} strokeWidth={1.8} />
          <Text style={s.heroTitle}>Verificación Plus</Text>
          <Text style={s.heroSub}>
            Muestra compromiso real.{'\n'}Aparece antes que grupos sin Plus.
          </Text>
        </LinearGradient>

        {/* Selector de plan — anual primero (ancla de precio) */}
        <View style={s.planRow}>
          <Pressable
            style={[s.planCard, selectedPlan === 'annual' && s.planCardSelected]}
            onPress={() => setSelectedPlan('annual')}
          >
            <View style={s.planCardTop}>
              <Text style={[s.planCardLabel, selectedPlan === 'annual' && s.planCardLabelSelected]}>
                Anual
              </Text>
              <View style={s.savingsBadge}>
                <Text style={s.savingsText}>AHORRA 33%</Text>
              </View>
            </View>
            <Text
              style={[s.planPrice, selectedPlan === 'annual' && s.planPriceSelected]}
              numberOfLines={1} adjustsFontSizeToFit
            >
              $1,499
            </Text>
            <Text style={s.planUnit}>MXN / año  ·  ~$125/mes</Text>
            <Text style={s.planPayNote}>💵 Tarjeta, OXXO o SPEI</Text>
          </Pressable>

          <Pressable
            style={[s.planCard, selectedPlan === 'monthly' && s.planCardSelected]}
            onPress={() => setSelectedPlan('monthly')}
          >
            {/* Misma estructura que la anual para que los precios queden alineados */}
            <View style={s.planCardTop}>
              <Text style={[s.planCardLabel, selectedPlan === 'monthly' && s.planCardLabelSelected]}>
                Mensual
              </Text>
            </View>
            <Text style={[s.planPrice, selectedPlan === 'monthly' && s.planPriceSelected]}>
              $199
            </Text>
            <Text style={s.planUnit}>MXN / mes</Text>
            <Text style={s.planPayNote}>💳 Se renueva sola</Text>
          </Pressable>
        </View>

        {/* Beneficios */}
        <View style={s.benefitsCard}>
          <Text style={s.benefitsTitle}>Qué incluye</Text>
          {BENEFITS.map((b, i) => (
            <View key={i} style={s.benefitRow}>
              <CheckCircle size={16} color={COLORS.green} />
              <Text style={s.benefitText}>{b}</Text>
            </View>
          ))}
        </View>

        {/* CTA */}
        <Pressable
          style={[s.ctaBtn, submitting && { opacity: 0.6 }]}
          onPress={handleSubscribe}
          disabled={submitting}
        >
          {submitting
            ? <ActivityIndicator size="small" color="#000" />
            : <ShieldCheck size={18} color="#000" strokeWidth={2.5} />
          }
          <Text style={s.ctaBtnText}>
            {submitting ? 'Procesando...' : selectedPlan === 'annual' ? 'Obtener Plus Anual' : 'Comenzar prueba gratuita'}
          </Text>
        </Pressable>

        <Text style={s.ctaNote}>
          {selectedPlan === 'annual'
            ? 'Suscripción con 7 días gratis, o pago único sin renovación (OXXO/SPEI)'
            : 'Sin cargo hoy · Tu tarjeta se cobra al día 8 · Cancela cuando quieras'}
        </Text>

        <View style={{ height: 40 }} />
      </ScrollView>
    </View>
  );
}

// ─── Beneficios (compartidos entre estados activo e inactivo) ─────────────────

const BENEFITS = [
  'Badge verde 🛡 en tu perfil y búsquedas',
  '🎬 2 videos MÁS en tu perfil (3 en total, en vez de 1)',
  '📸 Sube fotos de tus eventos a tu perfil',
  '💰 Gana dinero extra: tus fans te mandan regalos con dinero real',
  'Apareces antes que grupos sin Plus en tu zona',
  'Sello de confianza en cotizaciones express',
  'Con Bidding, llegas al top cuando quieras',
];

// ─── Estilos ──────────────────────────────────────────────────────────────────

const s = StyleSheet.create({
  root: {
    flex: 1,
    backgroundColor: COLORS.bg,
  },
  header: {
    flexDirection:   'row',
    alignItems:      'center',
    justifyContent:  'space-between',
    paddingHorizontal: SPACING.md,
    paddingBottom:   SPACING.sm,
    borderBottomWidth: 1,
    borderBottomColor: COLORS.border,
  },
  headerTitle: {
    fontFamily: FONTS.bodySemiBold,
    fontSize:   16,
    color:      COLORS.text,
  },
  backBtn: {
    width:           40,
    height:          40,
    alignItems:      'center',
    justifyContent:  'center',
  },
  scroll: {
    paddingHorizontal: SPACING.md,
    paddingTop:        SPACING.lg,
  },
  loadingCenter: {
    flex:            1,
    alignItems:      'center',
    justifyContent:  'center',
  },

  // Hero
  hero: {
    alignItems:    'center',
    borderRadius:  RADIUS.xl,
    padding:       SPACING.xxl,
    marginBottom:  SPACING.lg,
    gap:           SPACING.sm,
  },
  heroTitle: {
    fontFamily: FONTS.title,
    fontSize:   26,
    color:      COLORS.text,
    textAlign:  'center',
  },
  heroSub: {
    fontFamily: FONTS.body,
    fontSize:   14,
    color:      COLORS.muted2,
    textAlign:  'center',
    lineHeight: 20,
  },

  // Trial banner (estado activo en trial)
  trialBanner: {
    backgroundColor: 'rgba(0,230,118,0.10)',
    borderRadius:    RADIUS.md,
    padding:         SPACING.sm,
    alignItems:      'center',
    marginTop:       4,
  },
  trialBannerText: {
    fontFamily: FONTS.bodySemiBold,
    fontSize:   14,
    color:      COLORS.green,
  },
  trialBannerSub: {
    fontFamily: FONTS.body,
    fontSize:   12,
    color:      COLORS.muted2,
    marginTop:  2,
  },

  // Selector de plan
  planRow: {
    flexDirection:  'row',
    gap:            SPACING.sm,
    marginBottom:   SPACING.lg,
  },
  planCard: {
    flex:            1,
    backgroundColor: COLORS.card,
    borderRadius:    RADIUS.lg,
    borderWidth:     1.5,
    borderColor:     COLORS.border,
    padding:         SPACING.md,
    gap:             2,
  },
  planCardSelected: {
    borderColor:     COLORS.green,
    backgroundColor: 'rgba(0,230,118,0.06)',
  },
  planCardTop: {
    flexDirection:  'row',
    alignItems:     'center',
    gap:            6,
    marginBottom:   2,
    minHeight:      17,   // misma altura con o sin badge → precios alineados
  },
  planCardLabel: {
    fontFamily: FONTS.bodySemiBold,
    fontSize:   13,
    color:      COLORS.muted2,
  },
  planCardLabelSelected: {
    color: COLORS.green,
  },
  savingsBadge: {
    backgroundColor: COLORS.green,
    borderRadius:    4,
    paddingHorizontal: 5,
    paddingVertical:   1,
  },
  savingsText: {
    fontFamily: FONTS.bodySemiBold,
    fontSize:   9,
    color:      '#000',
  },
  planPrice: {
    fontFamily: FONTS.title,
    fontSize:   26,
    lineHeight: 34,              // Syne se recorta sin lineHeight explícito
    color:      COLORS.muted2,
    fontVariant: ['tabular-nums'],
    includeFontPadding: false,
  },
  planPriceSelected: {
    color: COLORS.text,
  },
  planUnit: {
    fontFamily: FONTS.body,
    fontSize:   11,
    color:      COLORS.muted,
  },
  planPayNote: {
    fontFamily: FONTS.bodyMedium,
    fontSize:   10,
    color:      COLORS.green,
    marginTop:  4,
  },

  // Beneficios
  benefitsCard: {
    backgroundColor: COLORS.card,
    borderRadius:    RADIUS.lg,
    padding:         SPACING.md,
    marginBottom:    SPACING.lg,
    gap:             SPACING.xs,
  },
  benefitsTitle: {
    fontFamily: FONTS.bodySemiBold,
    fontSize:   13,
    color:      COLORS.muted2,
    marginBottom: 4,
    textTransform: 'uppercase',
    letterSpacing: 0.5,
  },
  benefitRow: {
    flexDirection: 'row',
    alignItems:    'center',
    gap:           10,
  },
  benefitText: {
    fontFamily: FONTS.body,
    fontSize:   14,
    color:      COLORS.text,
    flex:       1,
  },

  // CTA
  ctaBtn: {
    backgroundColor: COLORS.green,
    borderRadius:    RADIUS.lg,
    paddingVertical: 16,
    flexDirection:   'row',
    alignItems:      'center',
    justifyContent:  'center',
    gap:             8,
    marginBottom:    SPACING.sm,
  },
  ctaBtnText: {
    fontFamily: FONTS.bodySemiBold,
    fontSize:   16,
    color:      '#000',
  },
  ctaNote: {
    fontFamily: FONTS.body,
    fontSize:   12,
    color:      COLORS.muted,
    textAlign:  'center',
  },

  // Gestión
  manageBtn: {
    borderWidth:     1,
    borderColor:     COLORS.border,
    borderRadius:    RADIUS.lg,
    paddingVertical: 14,
    alignItems:      'center',
    marginTop:       SPACING.md,
  },
  manageBtnText: {
    fontFamily: FONTS.bodySemiBold,
    fontSize:   14,
    color:      COLORS.muted2,
  },

  // Past due
  pastDueCenter: {
    flex:           1,
    alignItems:     'center',
    justifyContent: 'center',
    padding:        SPACING.xxl,
    gap:            SPACING.md,
  },
  pastDueTitle: {
    fontFamily: FONTS.title,
    fontSize:   22,
    color:      COLORS.red,
  },
  pastDueSub: {
    fontFamily: FONTS.body,
    fontSize:   14,
    color:      COLORS.muted2,
    textAlign:  'center',
    lineHeight: 22,
  },
});
