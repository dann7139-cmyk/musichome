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

  // ── Comprar Plus ───────────────────────────────────────────────────────────
  const handleSubscribe = async () => {
    if (!resolvedGroupId) return;

    const priceLabel = selectedPlan === 'annual'
      ? '$1,499 MXN / año  (~$125/mes)'
      : '$199 MXN / mes';

    Alert.alert(
      '🛡 Verificación Plus',
      `Plan: ${selectedPlan === 'annual' ? 'Anual' : 'Mensual'}\nPrecio: ${priceLabel}\n\nSe registra tu tarjeta hoy. No se cobra nada durante 7 días.\nEl cobro inicia al día 8 automáticamente.`,
      [
        { text: 'Cancelar', style: 'cancel' },
        {
          text: 'Comenzar prueba gratis',
          onPress: async () => {
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

              const setupSecret: string = stripeData.setup_intent_client_secret;
              if (!setupSecret) throw new Error('No se recibió el token de configuración');

              // 3. Inicializar PaymentSheet con SetupIntent (captura tarjeta, sin cobro)
              const { error: initErr } = await initPaymentSheet({
                setupIntentClientSecret: setupSecret,
                merchantDisplayName:     'Daricefy',
                style:                   'alwaysDark',
              });
              if (initErr) throw new Error(`Error al inicializar: ${initErr.message}`);

              // 4. Presentar hoja de pago nativa de Stripe
              const { error: payErr } = await presentPaymentSheet();
              if (payErr) {
                if (payErr.code === 'Canceled') return;
                throw new Error(payErr.message);
              }

              // 5. Tarjeta registrada — Plus se activa en segundos vía webhook
              Alert.alert(
                '✅ ¡Plus activado!',
                'Tu badge verde ya está visible. El webhook confirmará en segundos.\n\nTu tarjeta se cobrará en 7 días.',
                [{ text: 'Entendido', onPress: () => loadStatus() }],
              );
            } catch (err: any) {
              Alert.alert('Error', err.message ?? 'No se pudo procesar. Intenta de nuevo.');
            } finally {
              setSubmitting(false);
            }
          },
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
          'Para cancelar o cambiar tu tarjeta, escríbenos a soporte@daricefy.com',
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
                Se renueva el {fmtDate(status?.expires_at ?? null)}
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

          {/* Gestión */}
          <Pressable style={[s.manageBtn, portalLoading && { opacity: 0.6 }]} onPress={handleManage} disabled={portalLoading}>
            {portalLoading
              ? <ActivityIndicator size="small" color={COLORS.text} />
              : <Text style={s.manageBtnText}>Gestionar suscripción</Text>}
          </Pressable>

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
            <Text style={[s.planPrice, selectedPlan === 'annual' && s.planPriceSelected]}>
              $1,499
            </Text>
            <Text style={s.planUnit}>MXN / año  ·  ~$125/mes</Text>
          </Pressable>

          <Pressable
            style={[s.planCard, selectedPlan === 'monthly' && s.planCardSelected]}
            onPress={() => setSelectedPlan('monthly')}
          >
            <Text style={[s.planCardLabel, selectedPlan === 'monthly' && s.planCardLabelSelected]}>
              Mensual
            </Text>
            <Text style={[s.planPrice, selectedPlan === 'monthly' && s.planPriceSelected]}>
              $199
            </Text>
            <Text style={s.planUnit}>MXN / mes</Text>
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
            {submitting ? 'Procesando...' : 'Comenzar prueba gratuita'}
          </Text>
        </Pressable>

        <Text style={s.ctaNote}>
          Sin cargo hoy · Tu tarjeta se cobra al día 8 · Cancela cuando quieras
        </Text>

        <View style={{ height: 40 }} />
      </ScrollView>
    </View>
  );
}

// ─── Beneficios (compartidos entre estados activo e inactivo) ─────────────────

const BENEFITS = [
  'Badge verde 🛡 en tu perfil y búsquedas',
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
    fontSize:   28,
    color:      COLORS.muted2,
  },
  planPriceSelected: {
    color: COLORS.text,
  },
  planUnit: {
    fontFamily: FONTS.body,
    fontSize:   11,
    color:      COLORS.muted,
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
