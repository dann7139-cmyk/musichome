/**
 * QuotePaymentScreen — Checkout propio de Daricefy (misma cara para programadas
 * y express). El cliente elige método y el PROVEEDOR se enruta por método,
 * sin que el cliente vea marcas:
 *   · Tarjeta / SPEI / Efectivo → Conekta (Hosted Checkout, México)
 *   · Pagar a meses (MSI)       → Stripe (mensualidades reales, hasta que
 *                                  Conekta habilite MSI)
 *   · BNPL                      → oculto hasta habilitar en Conekta
 *
 * Diseño config-driven (PAYMENT_METHODS): activar/ocultar un método es cambiar
 * `enabled`. Es la base del router por país futuro (MX→Conekta / US→Stripe):
 * la capa de proveedor vive detrás de PAY_MX_WITH_CONEKTA + el switch por método.
 *
 * Modos:
 *   - route.params.quote        → cotización nueva: crea evento + reserva + paga
 *   - route.params.reservation  → reserva existente sin pago: va directo al cobro
 */
import React, { useEffect, useRef, useState } from 'react';
import {
  ActivityIndicator,
  Alert,
  Animated,
  Image,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import {
  ArrowLeft, BadgeCheck, Calendar, CheckCircle, ChevronDown, Copy, Lock,
  MapPin, Music2, RotateCcw, Shield, Wallet,
} from 'lucide-react-native';
import * as Clipboard from 'expo-clipboard';
import { useStripe } from '@stripe/stripe-react-native';
import { useTranslation } from 'react-i18next';
import type { TFunction } from 'i18next';
import { supabase } from '../../config/supabase';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';
import { calculateFinancedPrice, calculateMonthlyPayment, PUBLIC_MSI_FEE_RATES } from '../../utils/publicPricing';
import { startConektaCheckout, fetchConektaReference, ConektaMethod, ConektaReference } from '../../utils/conektaCheckout';
import { getClientActiveEvents, resolveEventContext } from '../../utils/eventBuilder';

const MSI_MIN_AMOUNT = 300; // MXN mínimo para pagar a meses

// Descuento por pagar con SPEI. Sale del MARGEN de la plataforma, NUNCA de
// group_earnings (el grupo cobra completo). Configurable en un solo lugar.
// ⚠️ Debe coincidir con SPEI_DISCOUNT de create-conekta-order (autoritativo).
const SPEI_DISCOUNT = 100; // MXN

// Meses ofrecidos en "Pagar a meses" (tasas reales desde PUBLIC_MSI_FEE_RATES).
const MSI_MONTHS = [3, 6, 9, 12];

// ⚠️ ROLLOUT COBRO MX: true = México cobra con Conekta (Hosted Checkout);
// false = fallback Stripe (intacto, para el router por país / US). Apagable al instante.
const PAY_MX_WITH_CONEKTA = true;

// ── Métodos del checkout Daricefy (config-driven) ──────────────────────────
// `enabled: false` → el método se OCULTA hasta que lo habilitemos en Conekta.
// Activar uno nuevo (BNPL, Apple/Google Pay…) = poner enabled:true aquí; el
// checkout lo muestra automáticamente sin rediseñar nada.
interface PayMethodDef {
  key: ConektaMethod;
  enabled: boolean;
  emoji: string;
  title: string;
  tag?: string;            // etiqueta corta ("Sin tarjeta", "Tarjeta de crédito")
  recommended?: boolean;   // ⭐ Recomendado
  comingSoon?: boolean;    // visible pero deshabilitado con "Próximamente"
  lines: string[];         // bullets descriptivos
  expandsMonths?: boolean; // despliega el selector 3/6/9/12 (solo 'msi')
}

// Textos de los métodos vienen de i18n (t) — la función se llama dentro del
// componente, donde el hook useTranslation ya está disponible.
const getPaymentMethods = (t: TFunction): PayMethodDef[] => [
  {
    key: 'card', enabled: true, emoji: '💳', title: t('quotePaymentScreen.methods.card.title'),
    lines: [
      t('quotePaymentScreen.methods.card.line1'),
      t('quotePaymentScreen.methods.card.line2'),
      t('quotePaymentScreen.methods.card.line3'),
    ],
  },
  {
    key: 'spei', enabled: true, emoji: '🏦', title: t('quotePaymentScreen.methods.spei.title'),
    tag: t('quotePaymentScreen.methods.spei.tag'), recommended: true,
    lines: [
      t('quotePaymentScreen.methods.spei.line1'),
      t('quotePaymentScreen.methods.spei.line2'),
    ],
  },
  {
    key: 'cash', enabled: true, emoji: '🏪', title: t('quotePaymentScreen.methods.cash.title'),
    tag: t('quotePaymentScreen.methods.cash.tag'),
    lines: [
      t('quotePaymentScreen.methods.cash.line1'),
      t('quotePaymentScreen.methods.cash.line2'),
    ],
  },
  {
    key: 'msi', enabled: true, emoji: '📅', title: t('quotePaymentScreen.methods.msi.title'),
    tag: t('quotePaymentScreen.methods.msi.tag'), expandsMonths: true,
    lines: [t('quotePaymentScreen.methods.msi.line1')],
  },
  {
    // BNPL vía Conekta (Aplazo min $20, Creditea min $500, sin máximo).
    // Registro de producción enviado 2026-07-11; la página de Conekta da
    // "error inesperado" hasta que validen la cuenta (~48h) → se muestra
    // como PRÓXIMAMENTE (visible, no seleccionable). Al validar:
    // comingSoon: false y probar con Aplazo +52 9902949001 / OTP 123456.
    key: 'bnpl', enabled: true, comingSoon: true, emoji: '💰', title: t('quotePaymentScreen.methods.bnpl.title'),
    tag: t('quotePaymentScreen.methods.bnpl.tag'),
    lines: [
      t('quotePaymentScreen.methods.bnpl.line1'),
      t('quotePaymentScreen.methods.bnpl.line2'),
    ],
  },
];

export default function QuotePaymentScreen({ route, navigation }: any) {
  const { t } = useTranslation();
  const { quote, reservation: existingRes } = route.params as { quote?: any; reservation?: any };
  const { initPaymentSheet, presentPaymentSheet } = useStripe();
  const PAYMENT_METHODS = getPaymentMethods(t);

  // Derivar datos de display desde cotización o reserva existente
  const baseTotal     = existingRes ? (existingRes.total_price ?? 0) : (quote?.total_amount ?? 0);
  // Solo para ETIQUETA visual — no afecta montos cobrados ni al proveedor.
  const payCurrency   = (existingRes?.currency_code ?? quote?.currency_code ?? 'MXN') === 'USD' ? 'USD' : 'MXN';
  const groupName     = existingRes?.group?.name ?? quote?.group?.name ?? t('quotePaymentScreen.genericGroupName');
  const groupImage    = existingRes?.group?.profile_image ?? quote?.group?.profile_image ?? null;
  const eventDateRaw  = existingRes?.event_date ?? quote?.event_date ?? null;
  const address       = existingRes?.address
    ?? [quote?.event_address, quote?.event_municipio, quote?.event_estado].filter(Boolean).join(', ')
    ?? '';
  const durationHours = existingRes?.hours_count
    ?? existingRes?.quote?.duration_hours
    ?? quote?.duration_hours
    ?? '?';

  const [loading, setLoading]         = useState(false);
  const [busyKey, setBusyKey]         = useState<string | null>(null); // método/mes en proceso (spinner localizado)
  const [mesesOpen, setMesesOpen]     = useState(false);               // despliegue del selector de meses
  const [paid, setPaid]               = useState(false);
  const [paidResId, setPaidResId]     = useState<string | null>(null);
  const [paidAmount, setPaidAmount]   = useState(0);                   // monto realmente cobrado (para pantalla de éxito)
  // sql/585 (Fase 1) — event_id resuelto para esta reserva (nuevo o
  // reutilizado), disponible en la pantalla de éxito para el botón real
  // "agregar otro proveedor". Null si por algún motivo no se pudo determinar.
  const [addonEventCtx, setAddonEventCtx] = useState<{ eventId: string; eventDate: string | null; eventAddress: string | null } | null>(null);
  // Pago pendiente SPEI/efectivo: datos para re-mostrar la CLABE/referencia
  // en la app (la página de Conekta la enseña unos segundos y redirige).
  const [pendingRef, setPendingRef]       = useState<ConektaReference | null>(null);
  const [pendingMethod, setPendingMethod] = useState<'spei' | 'cash' | null>(null);
  const [copied, setCopied]               = useState(false);

  // Animación del checkmark de éxito
  const checkScale = useRef(new Animated.Value(0)).current;
  const checkOp    = useRef(new Animated.Value(0)).current;

  // Pulso del pill "⭐ Recomendado" — guía al cliente al mejor método
  const recPulse = useRef(new Animated.Value(1)).current;
  useEffect(() => {
    const loop = Animated.loop(Animated.sequence([
      Animated.timing(recPulse, { toValue: 1.12, duration: 650, useNativeDriver: true }),
      Animated.timing(recPulse, { toValue: 1,    duration: 650, useNativeDriver: true }),
    ]));
    loop.start();
    return () => loop.stop();
  }, []);
  useEffect(() => {
    if (!paid) return;
    Animated.parallel([
      Animated.spring(checkScale, { toValue: 1, tension: 60, friction: 8, useNativeDriver: true }),
      Animated.timing(checkOp,   { toValue: 1, duration: 300, useNativeDriver: true }),
    ]).start();
  }, [paid]);

  // Monto que cobraría cada método (para display). group_earnings nunca cambia.
  const chargeFor = (method: ConektaMethod, months = 1): number => {
    if (method === 'spei') return Math.max(baseTotal - SPEI_DISCOUNT, 0);
    if (method === 'msi')  return calculateFinancedPrice(baseTotal, months);
    return baseTotal;
  };

  const eventDateStr = eventDateRaw
    ? new Date(eventDateRaw + 'T12:00:00').toLocaleDateString('es-MX', {
        weekday: 'long', year: 'numeric', month: 'long', day: 'numeric',
      })
    : '—';

  // Cobro unificado: el cliente elige un método del checkout Daricefy y se abre
  // el Hosted Checkout de Conekta. Mismo camino para programadas y express.
  const pay = async (method: ConektaMethod, months = 1) => {
    if (loading) return;

    // Monto mínimo solo aplica a "pagar a meses"
    if (method === 'msi' && calculateFinancedPrice(baseTotal, months) < MSI_MIN_AMOUNT) {
      Alert.alert(
        t('quotePaymentScreen.errors.insufficientAmountTitle'),
        t('quotePaymentScreen.errors.insufficientAmountMessage', { minAmount: MSI_MIN_AMOUNT }),
      );
      return;
    }

    setBusyKey(method === 'msi' ? `msi-${months}` : method);
    setLoading(true);
    try {
      const { data: sd } = await supabase.auth.getSession();
      const clientId = sd.session?.user.id;
      if (!clientId) throw new Error(t('quotePaymentScreen.errors.noSession'));

      let reservationId: string;

      if (existingRes) {
        // Modo reserva existente: saltar creación, ir directo al pago
        reservationId = existingRes.id;
        if (existingRes.event_id) {
          setAddonEventCtx({ eventId: existingRes.event_id, eventDate: existingRes.event_date ?? null, eventAddress: existingRes.address ?? null });
        }
      } else {
        // Modo cotización nueva: crear reserva + aceptar cotización.
        //
        // Resolver evento sigue siendo del lado de la app (Alert.alert es
        // UI, no puede vivir en SQL) — solo importa de verdad para
        // cotizaciones viejas sin su propio event_id.
        const activeEvents = quote.event_id ? [] : await getClientActiveEvents();
        const resolvedEventId = await resolveEventContext({
          t,
          presetEventId: quote.event_id ?? null,
          activeEvents,
        });

        // sql/593 (2026-09-01) — UNA sola llamada atómica en vez de
        // insert+update por separado. Hallazgo real del recorrido de los
        // 3 roles: una falla de red justo entre ambos pasos podía dejar
        // la cotización "viva" con una reserva ya creada, y un reintento
        // podía duplicarla (riesgo real de doble cobro). Idempotente:
        // reintentar tras eso regresa la MISMA reserva, no otra.
        const { data: acceptResult, error: acceptErr } = await supabase.rpc('client_accept_quote', {
          p_quote_id:   quote.id,
          p_event_id:   resolvedEventId,
          p_msi_months: months,
        });
        if (acceptErr || !acceptResult?.ok) {
          const code = acceptErr?.message ?? acceptResult?.error ?? '';
          if (code.includes('date_blocked') || code.includes('date_taken')) {
            throw new Error(t('quotePaymentScreen.errors.dateBlocked'));
          }
          if (code.includes('daily_event_limit')) {
            throw new Error(t('quotePaymentScreen.errors.dailyLimit'));
          }
          if (code.includes('time_overlap')) {
            throw new Error(t('quotePaymentScreen.errors.timeOverlap'));
          }
          if (code.includes('event_group_limit_reached')) {
            throw new Error(t('quotePaymentScreen.errors.groupLimitReached'));
          }
          throw new Error(t('quotePaymentScreen.errors.reservationCreateFailed'));
        }

        reservationId = acceptResult.reservation_id;
        const eventId: string = acceptResult.event_id;
        setAddonEventCtx({ eventId, eventDate: quote.event_date ?? null, eventAddress: address || null });

        // Solo en una aceptación nueva de verdad — un reintento
        // idempotente ya notificó la primera vez.
        if (quote.group?.owner_id && !acceptResult.already_accepted) {
          await supabase.from('notifications').insert({
            user_id: quote.group.owner_id,
            type:    'quote_accepted',
            title:   t('quotePaymentScreen.notifications.quoteAcceptedTitle'),
            body:    t('quotePaymentScreen.notifications.quoteAcceptedBody', { amount: baseTotal.toLocaleString(), currency: payCurrency }),
            data:    { quote_id: quote.id, reservation_id: reservationId },
          });
        }
      }

      // ── Router de cobro POR MÉTODO ──────────────────────────────────
      //   SPEI / Efectivo         → Conekta (Hosted Checkout, México).
      //   Tarjeta y Pagar a meses → Stripe. Conekta aprobó la cuenta solo
      //     para Efectivo/SPEI/BBVA (2026-09-09); tarjeta queda bloqueada
      //     ~90 días, así que se cobra con Stripe igual que MSI. El cliente
      //     nunca ve "Stripe".
      //   Cuando Conekta habilite tarjeta y MSI: quitar `&& method !== 'msi'
      //     && method !== 'card'` y listo.
      //   PAY_MX_WITH_CONEKTA=false → todo cae a Stripe (fallback US/rollback).
      if (PAY_MX_WITH_CONEKTA && method !== 'msi' && method !== 'card') {
        const result = await startConektaCheckout(reservationId, method);
        if (result.status === 'paid') {
          setPaidAmount(chargeFor(method, months));
          setPaidResId(reservationId);
          setPaid(true);
        } else if (result.status === 'pending') {
          // SPEI/efectivo: recuperar la CLABE/referencia de la orden y
          // mostrarla EN LA APP (la página de Conekta la enseña unos
          // segundos y redirige — el cliente la necesita para transferir).
          if ((method === 'spei' || method === 'cash') && result.orderId) {
            const ref = await fetchConektaReference(result.orderId);
            if (ref && (ref.clabe || ref.reference)) {
              setPaidResId(reservationId);
              setPendingMethod(method);
              setPendingRef(ref);
              return;
            }
            // Sin cargo generado (cerró el navegador antes de elegir) →
            // puede reintentar desde "Mis Eventos".
            Alert.alert(
              t('quotePaymentScreen.pendingPayment.title'),
              t('quotePaymentScreen.pendingPayment.message'),
              [{ text: t('quotePaymentScreen.pendingPayment.seeReservations'), onPress: () => navigation.navigate('ClientReservations') }],
            );
            return;
          }
          Alert.alert(
            t('quotePaymentScreen.pendingPayment.incompleteTitle'),
            t('quotePaymentScreen.pendingPayment.incompleteMessage'),
            [{ text: t('quotePaymentScreen.pendingPayment.understood'), onPress: () => navigation.navigate('ClientReservations') }],
          );
        } else {
          throw new Error(t('quotePaymentScreen.errors.conektaInitFailed'));
        }
        return;
      }

      // Pago con Stripe: MESES (MSI real, entrega mensualidades) hoy; y todo el
      // cobro cuando PAY_MX_WITH_CONEKTA=false (fallback US/rollback).
      const { data: piData, error: piErr } = await supabase.functions.invoke('create-payment-intent', {
        body: {
          reservation_id: reservationId,
          msi_months:     months > 1 ? months : undefined,
        },
        headers: { Authorization: `Bearer ${sd.session?.access_token}` },
      });

      if (piErr) throw new Error(t('quotePaymentScreen.errors.paymentErrorPrefix', { message: piErr.message }));
      if (!piData) throw new Error(t('quotePaymentScreen.errors.noServerResponse'));
      if (piData.error) {
        // Traducciones de errores Stripe a mensajes amigables
        const stripeMsg: string = piData.error ?? '';
        if (
          months > 1 &&
          (stripeMsg.includes('installment') || stripeMsg.includes('card_not_supported'))
        ) {
          throw new Error(t('quotePaymentScreen.errors.cardInstallmentsNotSupported'));
        }
        throw new Error(stripeMsg || t('quotePaymentScreen.errors.paymentInitFailed'));
      }
      if (!piData.client_secret) throw new Error(t('quotePaymentScreen.errors.noPaymentToken'));

      // Inicializar Payment Sheet
      const { error: initError } = await initPaymentSheet({
        paymentIntentClientSecret: piData.client_secret,
        merchantDisplayName: 'Daricefy',
        style: 'alwaysDark',
      });
      if (initError) throw new Error(initError.message);

      // Presentar Payment Sheet
      const { error: payError } = await presentPaymentSheet();
      if (payError) {
        if (payError.code === 'Canceled') {
          Alert.alert(
            t('quotePaymentScreen.pendingPayment.title'),
            t('quotePaymentScreen.pendingPayment.message'),
            [{ text: t('quotePaymentScreen.pendingPayment.seeReservations'), onPress: () => navigation.navigate('ClientReservations') }],
          );
          return;
        }
        // Errores de MSI desde el PaymentSheet (tarjeta incompatible, etc.)
        const errMsg: string = (payError as any).message ?? '';
        if (
          months > 1 &&
          (errMsg.toLowerCase().includes('installment') ||
           errMsg.toLowerCase().includes('no está disponible') ||
           errMsg.toLowerCase().includes('not available'))
        ) {
          throw new Error(t('quotePaymentScreen.errors.cardInstallmentsNotSupportedRetry'));
        }
        throw new Error(errMsg || t('quotePaymentScreen.errors.paymentProcessingProblem'));
      }

      setPaidAmount(chargeFor(method, months));
      setPaidResId(reservationId);
      setPaid(true);
    } catch (err: any) {
      Alert.alert(t('quotePaymentScreen.errors.paymentErrorTitle'), err.message ?? t('quotePaymentScreen.errors.genericRetry'));
    } finally {
      setLoading(false);
      setBusyKey(null);
    }
  };

  // ── Pantalla de pago pendiente (CLABE SPEI / referencia efectivo) ────────────
  if (pendingRef && pendingMethod) {
    const isSpei  = pendingMethod === 'spei';
    const mainVal = isSpei ? (pendingRef.clabe ?? '') : (pendingRef.reference ?? '');
    const amountStr = (pendingRef.amount ?? chargeFor(pendingMethod, 1)).toLocaleString();
    const copyVal = async () => {
      await Clipboard.setStringAsync(mainVal);
      setCopied(true);
      setTimeout(() => setCopied(false), 2500);
    };
    return (
      <SafeAreaView edges={['top']} style={s.successRoot}>
        <Text style={{ fontSize: 44 }}>{isSpei ? '🏦' : '🏪'}</Text>
        <View style={{ alignItems: 'center', gap: 8 }}>
          <Text style={s.refBigTitle}>{isSpei ? t('quotePaymentScreen.referenceScreen.transferTitle') : t('quotePaymentScreen.referenceScreen.payInStoreTitle')}</Text>
          <Text style={s.successSub}>
            {isSpei
              ? t('quotePaymentScreen.referenceScreen.speiInstructions')
              : t('quotePaymentScreen.referenceScreen.cashInstructions')}
          </Text>
        </View>

        <View style={s.refCard}>
          <Text style={s.refLabel}>{isSpei ? t('quotePaymentScreen.referenceScreen.clabeLabel') : t('quotePaymentScreen.referenceScreen.referenceLabel')}</Text>
          <Text style={s.refValue} selectable>{mainVal}</Text>
          {isSpei && !!pendingRef.bank && (
            <Text style={s.refBank}>{t('quotePaymentScreen.referenceScreen.bankLabel', { bank: pendingRef.bank })}</Text>
          )}
          <Text style={s.refAmount}>{t('quotePaymentScreen.referenceScreen.exactAmount', { amount: amountStr })}</Text>
          <Pressable style={s.refCopyBtn} onPress={copyVal}>
            {copied
              ? <CheckCircle size={16} color="#000" />
              : <Copy size={16} color="#000" />}
            <Text style={s.refCopyText}>{copied ? t('quotePaymentScreen.referenceScreen.copied') : (isSpei ? t('quotePaymentScreen.referenceScreen.copyClabe') : t('quotePaymentScreen.referenceScreen.copyReference'))}</Text>
          </Pressable>
        </View>

        <Text style={s.refNote}>
          {t('quotePaymentScreen.referenceScreen.note')}
        </Text>

        <Pressable
          style={s.whiteBtn}
          onPress={() => navigation.navigate('ClientReservations')}
        >
          <Text style={s.whiteBtnText}>{t('quotePaymentScreen.referenceScreen.seeMyEvents')}</Text>
        </Pressable>
      </SafeAreaView>
    );
  }

  // ── Pantalla de éxito ────────────────────────────────────────────────────────
  if (paid) {
    return (
      <SafeAreaView edges={['top']} style={s.successRoot}>
        <Animated.View style={[s.successIconWrap, { transform: [{ scale: checkScale }], opacity: checkOp }]}>
          <CheckCircle size={72} color={COLORS.green} strokeWidth={1.5} />
        </Animated.View>

        <Animated.View style={{ opacity: checkOp, alignItems: 'center', gap: 8 }}>
          <Text style={s.successTitle}>{t('quotePaymentScreen.success.title')}</Text>
          <Text style={s.successSub}>{t('quotePaymentScreen.success.subtitle')}</Text>
        </Animated.View>

        <Animated.View style={[s.successCard, { opacity: checkOp }]}>
          {groupImage ? (
            <Image source={{ uri: groupImage }} style={s.successAvatar} />
          ) : (
            <View style={s.successAvatarFallback}>
              <Text style={s.successAvatarInitial}>{groupName.charAt(0).toUpperCase()}</Text>
            </View>
          )}
          <View style={{ flex: 1, gap: 4 }}>
            <Text style={s.successGroupName}>{groupName}</Text>
            <Text style={s.successDate}>{eventDateStr}</Text>
          </View>
          <View style={s.successAmtWrap}>
            <Text style={s.successAmt}>${paidAmount.toLocaleString()}</Text>
            <Text style={s.successAmtLabel}>{payCurrency}</Text>
          </View>
        </Animated.View>

        {!!addonEventCtx && (
          <Pressable
            style={s.successBtnSecondary}
            onPress={() => navigation.navigate('EventCategoryPicker', {
              eventId: addonEventCtx.eventId,
              eventDate: addonEventCtx.eventDate,
              eventAddress: addonEventCtx.eventAddress,
            })}
          >
            <Text style={s.successBtnSecondaryText}>{t('quotePaymentScreen.success.addAnotherProvider')}</Text>
          </Pressable>
        )}

        <Pressable
          style={s.successBtn}
          onPress={() => navigation.navigate('ClientReservations', { justPaidReservationId: paidResId })}
        >
          <Text style={s.successBtnText}>{t('quotePaymentScreen.success.seeReservations')}</Text>
        </Pressable>
      </SafeAreaView>
    );
  }

  return (
    <View style={s.root}>
      <SafeAreaView edges={['top']} style={s.header}>
        <Pressable style={s.backBtn} onPress={() => navigation.goBack()}>
          <ArrowLeft size={20} color={COLORS.text} />
        </Pressable>
        <View style={s.headerCenter}>
          {groupImage ? (
            <Image source={{ uri: groupImage }} style={s.groupAvatar} />
          ) : (
            <View style={s.groupAvatarPlaceholder}>
              <Text style={s.groupAvatarInitial}>{groupName.charAt(0).toUpperCase()}</Text>
            </View>
          )}
          <View style={{ flex: 1 }}>
            <Text style={s.headerTitle}>{t('quotePaymentScreen.header.title')}</Text>
            <Text style={s.headerSub}>{groupName}</Text>
          </View>
        </View>
      </SafeAreaView>

      <ScrollView contentContainerStyle={s.scroll} showsVerticalScrollIndicator={false}>

        {/* ── Badges de confianza (sin Stripe) ───────────────────────────────── */}
        <View style={s.badgesRow}>
          <View style={s.badge}>
            <Shield size={12} color={COLORS.green} />
            <Text style={s.badgeText}>{t('quotePaymentScreen.badges.protected')}</Text>
          </View>
          <View style={s.badge}>
            <Lock size={12} color={COLORS.green} />
            <Text style={s.badgeText}>{t('quotePaymentScreen.badges.guarantee')}</Text>
          </View>
        </View>

        {/* ── Detalles del evento ─────────────────────────────────────────────── */}
        <View style={s.section}>
          <View style={s.detailRow}>
            <Calendar size={15} color={COLORS.muted2} />
            <Text style={s.detailText}>{eventDateStr}</Text>
          </View>
          {address ? (
            <View style={s.detailRow}>
              <MapPin size={15} color={COLORS.muted2} />
              <Text style={s.detailText}>{address}</Text>
            </View>
          ) : null}
          <View style={s.detailRow}>
            <Music2 size={15} color={COLORS.muted2} />
            <Text style={s.detailText}>{t('quotePaymentScreen.detail.durationHours', { hours: durationHours })}</Text>
          </View>
          <View style={s.totalRow}>
            <Text style={s.totalLabel}>{t('quotePaymentScreen.detail.totalLabel')}</Text>
            <Text style={s.totalValue}>${baseTotal.toLocaleString()} {payCurrency}</Text>
          </View>
        </View>

        {/* ── Checkout Daricefy: ¿cómo quieres pagar? ─────────────────────────── */}
        <Text style={s.payQuestion}>{t('quotePaymentScreen.payQuestion')}</Text>

        {PAYMENT_METHODS.filter((m) => m.enabled).map((m) => {
          const isMsi = !!m.expandsMonths;
          const busy  = busyKey === m.key;
          const soon  = !!m.comingSoon;
          return (
            <View key={m.key}>
              <Pressable
                style={[
                  s.methodCard,
                  m.recommended && s.methodCardRec,
                  loading && !busy && { opacity: 0.5 },
                  soon && { opacity: 0.55 },
                ]}
                onPress={() => {
                  if (soon) {
                    Alert.alert(t('quotePaymentScreen.comingSoonAlert.title'), t('quotePaymentScreen.comingSoonAlert.message'));
                    return;
                  }
                  isMsi ? setMesesOpen((o) => !o) : pay(m.key);
                }}
                disabled={loading}
              >
                <Text style={s.methodEmoji}>{m.emoji}</Text>

                <View style={{ flex: 1 }}>
                  <View style={s.methodTitleRow}>
                    <Text style={s.methodTitle}>{m.title}</Text>
                    {soon ? (
                      <View style={s.soonPill}>
                        <Text style={s.soonPillText}>{t('quotePaymentScreen.soonPill')}</Text>
                      </View>
                    ) : m.tag ? (
                      <View style={s.methodTag}>
                        <Text style={s.methodTagText}>{m.tag}</Text>
                      </View>
                    ) : null}
                    {m.recommended ? (
                      <Animated.View style={[s.recPill, { transform: [{ scale: recPulse }] }]}>
                        <Text style={s.recPillText}>{t('quotePaymentScreen.recommendedPill')}</Text>
                      </Animated.View>
                    ) : null}
                  </View>

                  {m.lines.map((l, i) => (
                    <Text key={i} style={s.methodLine}>· {l}</Text>
                  ))}

                  {m.key === 'spei' ? (
                    <View style={s.savingsPill}>
                      <Text style={s.savingsText}>{t('quotePaymentScreen.methods.spei.savings', { amount: SPEI_DISCOUNT })}</Text>
                    </View>
                  ) : null}
                </View>

                <View style={s.methodRight}>
                  {busy ? (
                    <ActivityIndicator size="small" color={COLORS.green} />
                  ) : isMsi ? (
                    <ChevronDown
                      size={20}
                      color={COLORS.muted2}
                      style={mesesOpen ? { transform: [{ rotate: '180deg' }] } : undefined}
                    />
                  ) : m.key === 'spei' ? (
                    <>
                      <Text style={s.methodAmtStrike}>${baseTotal.toLocaleString()}</Text>
                      <Text style={s.methodAmt}>${chargeFor('spei').toLocaleString()}</Text>
                    </>
                  ) : (
                    <Text style={s.methodAmt}>${baseTotal.toLocaleString()}</Text>
                  )}
                </View>
              </Pressable>

              {/* Sub-selector de meses (solo 'msi', al desplegar) */}
              {isMsi && mesesOpen ? (
                <View style={s.mesesWrap}>
                  {MSI_MONTHS.map((mo) => {
                    const monthly  = calculateMonthlyPayment(baseTotal, mo);
                    const financed = calculateFinancedPrice(baseTotal, mo);
                    const feePct   = (PUBLIC_MSI_FEE_RATES[mo] ?? 0) * 100;
                    const moBusy   = busyKey === `msi-${mo}`;
                    return (
                      <Pressable
                        key={mo}
                        style={[s.mesRow, loading && !moBusy && { opacity: 0.5 }]}
                        onPress={() => pay('msi', mo)}
                        disabled={loading}
                      >
                        <View style={{ flex: 1 }}>
                          <Text style={s.mesTitle}>{t('quotePaymentScreen.months.label', { count: mo })}</Text>
                          <Text style={s.mesSub}>
                            {t('quotePaymentScreen.months.fee', { feePct: feePct.toFixed(0), amount: financed.toLocaleString(), currency: payCurrency })}
                          </Text>
                        </View>
                        {moBusy ? (
                          <ActivityIndicator size="small" color={COLORS.green} />
                        ) : (
                          <Text style={s.mesAmt}>
                            ${monthly.toLocaleString()}
                            <Text style={s.mesAmtUnit}>{t('quotePaymentScreen.months.perMonth')}</Text>
                          </Text>
                        )}
                      </Pressable>
                    );
                  })}
                </View>
              ) : null}
            </View>
          );
        })}

        {/* ── Beneficios Daricefy ─────────────────────────────────────────────── */}
        <View style={s.benefits}>
          <Text style={s.benefitsTitle}>{t('quotePaymentScreen.benefits.title')}</Text>
          {[
            { Icon: Shield,     text: t('quotePaymentScreen.badges.protected') },
            { Icon: RotateCcw,  text: t('quotePaymentScreen.benefits.refund') },
            { Icon: Wallet,     text: t('quotePaymentScreen.benefits.walletProtected') },
            { Icon: BadgeCheck, text: t('quotePaymentScreen.badges.guarantee') },
          ].map(({ Icon, text }, i) => (
            <View key={i} style={s.benefitRow}>
              <View style={s.benefitIcon}>
                <Icon size={16} color={COLORS.green} />
              </View>
              <Text style={s.benefitText}>{text}</Text>
            </View>
          ))}
        </View>

        <View style={{ height: 40 }} />
      </ScrollView>
    </View>
  );
}

const s = StyleSheet.create({
  root:   { flex: 1, backgroundColor: COLORS.bg },
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
  headerCenter: { flex: 1, flexDirection: 'row', alignItems: 'center', gap: 10 },
  groupAvatar: {
    width: 38, height: 38, borderRadius: 19,
    borderWidth: 1, borderColor: COLORS.border,
  },
  groupAvatarPlaceholder: {
    width: 38, height: 38, borderRadius: 19,
    backgroundColor: COLORS.card2, borderWidth: 1, borderColor: COLORS.border,
    alignItems: 'center', justifyContent: 'center',
  },
  groupAvatarInitial: { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.muted2 },
  headerTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 16, color: COLORS.text },
  headerSub:   { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, marginTop: 1 },
  scroll: { padding: SPACING.xl },

  // Badges
  badgesRow: { flexDirection: 'row', gap: 8, flexWrap: 'wrap', marginBottom: 16 },
  badge: {
    flexDirection: 'row', alignItems: 'center', gap: 5,
    backgroundColor: COLORS.card, borderRadius: RADIUS.full,
    borderWidth: 1, borderColor: COLORS.border,
    paddingHorizontal: 10, paddingVertical: 6,
  },
  badgeText: { fontFamily: FONTS.bodyMedium, fontSize: 11, color: COLORS.muted2 },

  // Detalles
  section: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.xl,
    borderWidth: 1, borderColor: COLORS.border,
    padding: SPACING.lg, marginBottom: 16, gap: 12,
    shadowColor: '#000', shadowOffset: { width: 0, height: 2 }, shadowOpacity: 0.07, shadowRadius: 6, elevation: 2,
  },
  detailRow: { flexDirection: 'row', alignItems: 'flex-start', gap: 10 },
  detailText: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2, flex: 1, lineHeight: 20 },
  totalRow: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between',
    borderTopWidth: 1, borderTopColor: COLORS.border, paddingTop: 12, marginTop: 2,
  },
  totalLabel: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted2 },
  totalValue: { fontFamily: FONTS.bodySemiBold, fontSize: 17, color: COLORS.text },

  // ── Checkout Daricefy: métodos de pago ──────────────────────────────────
  payQuestion: {
    fontFamily: FONTS.bodySemiBold, fontSize: 17, color: COLORS.text, marginBottom: 12,
  },
  // Tarjetas de método: BLANCAS y compactas (petición 2026-07-11), texto
  // oscuro, precios en verde — mismo lenguaje que el botón de pagar.
  methodCard: {
    flexDirection: 'row', alignItems: 'flex-start', gap: 10,
    backgroundColor: '#FFFFFF', borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: 'rgba(0,0,0,0.08)',
    paddingVertical: 11, paddingHorizontal: 13, marginBottom: 8,
    shadowColor: '#000', shadowOffset: { width: 0, height: 2 }, shadowOpacity: 0.06, shadowRadius: 5, elevation: 2,
  },
  methodCardRec: {
    borderWidth: 1.5, borderColor: COLORS.green,
  },
  methodEmoji:    { fontSize: 20, width: 26, textAlign: 'center', marginTop: 1 },
  methodTitleRow: { flexDirection: 'row', alignItems: 'center', gap: 8, flexWrap: 'wrap', marginBottom: 3 },
  methodTitle:    { fontFamily: FONTS.bodySemiBold, fontSize: 13.5, color: '#000' },
  methodTag: {
    backgroundColor: 'rgba(0,0,0,0.05)', borderRadius: RADIUS.full,
    borderWidth: 1, borderColor: 'rgba(0,0,0,0.1)', paddingHorizontal: 7, paddingVertical: 2,
  },
  methodTagText:  { fontFamily: FONTS.bodyMedium, fontSize: 9.5, color: 'rgba(0,0,0,0.55)' },
  recPill:        { backgroundColor: COLORS.green2, borderRadius: RADIUS.full, paddingHorizontal: 8, paddingVertical: 3 },
  recPillText:    { fontFamily: FONTS.bodySemiBold, fontSize: 10, color: '#FFFFFF' },
  soonPill:       { backgroundColor: 'rgba(255,179,0,0.15)', borderRadius: RADIUS.full, borderWidth: 1, borderColor: 'rgba(255,179,0,0.4)', paddingHorizontal: 8, paddingVertical: 3 },
  soonPillText:   { fontFamily: FONTS.bodySemiBold, fontSize: 10, color: '#FFB300' },
  methodLine:     { fontFamily: FONTS.body, fontSize: 11.5, color: 'rgba(0,0,0,0.55)', lineHeight: 16 },
  savingsPill: {
    alignSelf: 'flex-start', backgroundColor: COLORS.green2,
    borderRadius: RADIUS.md, paddingHorizontal: 9, paddingVertical: 4, marginTop: 6,
  },
  savingsText:     { fontFamily: FONTS.bodySemiBold, fontSize: 11, color: '#FFFFFF' },
  methodRight:     { alignItems: 'flex-end', justifyContent: 'center', minWidth: 58, gap: 2, paddingLeft: 6 },
  methodAmt:       { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.green2, fontVariant: ['tabular-nums'] },
  methodAmtStrike: { fontFamily: FONTS.body, fontSize: 10.5, color: 'rgba(0,0,0,0.35)', textDecorationLine: 'line-through' },

  // Sub-selector de meses
  mesesWrap: { marginTop: -2, marginBottom: 10, paddingLeft: 12, gap: 8 },
  mesRow: {
    flexDirection: 'row', alignItems: 'center', gap: 12,
    backgroundColor: COLORS.card2, borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: COLORS.border, padding: 14,
  },
  mesTitle:   { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.text },
  mesSub:     { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted, marginTop: 2 },
  mesAmt:     { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.green },
  mesAmtUnit: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted },

  // Beneficios
  benefits: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.xl,
    borderWidth: 1, borderColor: COLORS.border,
    padding: SPACING.lg, marginTop: 6, gap: 12,
  },
  benefitsTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.text, marginBottom: 2 },
  benefitRow:    { flexDirection: 'row', alignItems: 'center', gap: 10 },
  benefitIcon: {
    width: 28, height: 28, borderRadius: 14,
    backgroundColor: 'rgba(0,230,118,0.1)', alignItems: 'center', justifyContent: 'center',
  },
  benefitText:   { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2, flex: 1 },

  // ── Success ────────────────────────────────────────────────────────────────
  successRoot: {
    flex: 1, backgroundColor: COLORS.bg,
    alignItems: 'center', justifyContent: 'center',
    paddingHorizontal: SPACING.xl, gap: 24,
  },
  successIconWrap: { marginBottom: 8 },
  successTitle: {
    fontFamily: FONTS.title, fontSize: 30, color: COLORS.green, textAlign: 'center',
  },
  successSub: {
    fontFamily: FONTS.body, fontSize: 15, color: COLORS.muted2, textAlign: 'center',
  },
  successCard: {
    width: '100%',
    flexDirection: 'row', alignItems: 'center', gap: 14,
    backgroundColor: COLORS.card, borderRadius: RADIUS.xl,
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.25)',
    padding: 18,
  },
  successAvatar: {
    width: 48, height: 48, borderRadius: 24,
    borderWidth: 1, borderColor: COLORS.border,
  },
  successAvatarFallback: {
    width: 48, height: 48, borderRadius: 24,
    backgroundColor: COLORS.card2, borderWidth: 1, borderColor: COLORS.border,
    alignItems: 'center', justifyContent: 'center',
  },
  successAvatarInitial: { fontFamily: FONTS.bodySemiBold, fontSize: 18, color: COLORS.muted2 },
  successGroupName: { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.text },
  successDate: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2 },
  successAmtWrap: { alignItems: 'flex-end' },
  successAmt: { fontFamily: FONTS.bodySemiBold, fontSize: 18, color: COLORS.green },
  successAmtLabel: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted },
  successBtn: {
    width: '100%',
    backgroundColor: COLORS.green, borderRadius: RADIUS.lg, paddingVertical: 17,
    alignItems: 'center', marginTop: 8,
  },
  successBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 16, color: COLORS.bg },
  successBtnSecondary: {
    width: '100%',
    backgroundColor: 'transparent', borderRadius: RADIUS.lg, borderWidth: 1, borderColor: COLORS.green,
    paddingVertical: 15, alignItems: 'center', marginTop: 10,
  },
  successBtnSecondaryText: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.green },

  // ── Pago pendiente (CLABE SPEI / referencia efectivo) ──
  refCard: {
    width: '100%', alignItems: 'center', gap: 6,
    backgroundColor: COLORS.card, borderRadius: RADIUS.xl,
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.35)',
    paddingVertical: 20, paddingHorizontal: 16,
  },
  refLabel: {
    fontFamily: FONTS.bodySemiBold, fontSize: 11, color: COLORS.muted2,
    letterSpacing: 1.5, textTransform: 'uppercase',
  },
  refValue: {
    fontFamily: FONTS.bodySemiBold, fontSize: 21, color: COLORS.text,
    letterSpacing: 1.2, textAlign: 'center', fontVariant: ['tabular-nums'],
  },
  refBank:   { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2 },
  refAmount: { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.green, marginTop: 2 },
  refCopyBtn: {
    flexDirection: 'row', alignItems: 'center', gap: 8,
    backgroundColor: '#FFFFFF', borderRadius: RADIUS.full,
    paddingHorizontal: 18, paddingVertical: 10, marginTop: 10,
    shadowColor: '#00E676', shadowOpacity: 0.3, shadowRadius: 8, shadowOffset: { width: 0, height: 2 },
    elevation: 4,
  },
  refCopyText: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: '#000' },

  // Título grande y verde de "Transfiere para confirmar"
  refBigTitle: {
    fontFamily: FONTS.title, fontSize: 26, color: COLORS.green,
    textAlign: 'center', lineHeight: 32,
  },
  // Botón blanco (Ver mis eventos en la pantalla de referencia)
  whiteBtn: {
    width: '100%', backgroundColor: '#FFFFFF', borderRadius: RADIUS.full,
    paddingVertical: 16, alignItems: 'center', marginTop: 8,
    shadowColor: '#00E676', shadowOpacity: 0.3, shadowRadius: 10, shadowOffset: { width: 0, height: 3 },
    elevation: 5,
  },
  whiteBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 16, color: '#000' },
  refNote: {
    fontFamily: FONTS.body, fontSize: 12.5, color: COLORS.muted2,
    textAlign: 'center', lineHeight: 18, paddingHorizontal: 10,
  },
});
