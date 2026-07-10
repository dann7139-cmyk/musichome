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
import { supabase } from '../../config/supabase';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';
import { calculateFinancedPrice, calculateMonthlyPayment, PUBLIC_MSI_FEE_RATES } from '../../utils/publicPricing';
import { startConektaCheckout, fetchConektaReference, ConektaMethod, ConektaReference } from '../../utils/conektaCheckout';

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
  lines: string[];         // bullets descriptivos
  expandsMonths?: boolean; // despliega el selector 3/6/9/12 (solo 'msi')
}

const PAYMENT_METHODS: PayMethodDef[] = [
  {
    key: 'card', enabled: true, emoji: '💳', title: 'Tarjeta',
    lines: ['Pago inmediato', 'Débito o crédito', 'Pago protegido por Daricefy'],
  },
  {
    key: 'spei', enabled: true, emoji: '🏦', title: 'Transferencia SPEI',
    tag: 'Sin tarjeta', recommended: true,
    lines: ['No necesitas tarjeta', 'Pago desde tu banca'],
  },
  {
    key: 'cash', enabled: true, emoji: '🏪', title: 'Pago en efectivo',
    tag: 'Sin tarjeta',
    lines: ['OXXO, 7-Eleven, farmacias y más', 'Ideal si no tienes tarjeta'],
  },
  {
    key: 'msi', enabled: true, emoji: '📅', title: 'Pagar a meses',
    tag: 'Tarjeta de crédito', expandsMonths: true,
    lines: ['3, 6, 9 y 12 meses'],
  },
  {
    // Compra ahora, paga después (BNPL / Kueski). Oculto hasta habilitar en Conekta.
    key: 'bnpl', enabled: false, emoji: '🛍️', title: 'Compra ahora, paga después',
    tag: 'Sin tarjeta',
    lines: ['Difiere tu pago sin tarjeta de crédito'],
  },
];

export default function QuotePaymentScreen({ route, navigation }: any) {
  const { quote, reservation: existingRes } = route.params as { quote?: any; reservation?: any };
  const { initPaymentSheet, presentPaymentSheet } = useStripe();

  // Derivar datos de display desde cotización o reserva existente
  const baseTotal     = existingRes ? (existingRes.total_price ?? 0) : (quote?.total_amount ?? 0);
  const groupName     = existingRes?.group?.name ?? quote?.group?.name ?? 'Grupo';
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
  // Pago pendiente SPEI/efectivo: datos para re-mostrar la CLABE/referencia
  // en la app (la página de Conekta la enseña unos segundos y redirige).
  const [pendingRef, setPendingRef]       = useState<ConektaReference | null>(null);
  const [pendingMethod, setPendingMethod] = useState<'spei' | 'cash' | null>(null);
  const [copied, setCopied]               = useState(false);

  // Animación del checkmark de éxito
  const checkScale = useRef(new Animated.Value(0)).current;
  const checkOp    = useRef(new Animated.Value(0)).current;
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
        'Monto insuficiente',
        `Pagar a meses está disponible solo para montos mayores a $${MSI_MIN_AMOUNT} MXN.`,
      );
      return;
    }

    setBusyKey(method === 'msi' ? `msi-${months}` : method);
    setLoading(true);
    try {
      const { data: sd } = await supabase.auth.getSession();
      const clientId = sd.session?.user.id;
      if (!clientId) throw new Error('No hay sesión activa.');

      let reservationId: string;

      if (existingRes) {
        // Modo reserva existente: saltar creación, ir directo al pago
        reservationId = existingRes.id;
      } else {
        // Modo cotización nueva: crear evento + reserva + aceptar cotización
        const { data: eventData, error: eventErr } = await supabase
          .from('events')
          .insert({
            client_id:  clientId,
            event_date: quote.event_date,
            event_time: quote.event_time ?? null,
            address:    address || null,
            status:     'active',
          })
          .select('id')
          .single();
        if (eventErr || !eventData?.id) throw new Error('No se pudo crear el evento.');

        const { data: resData, error: resErr } = await supabase
          .from('reservations')
          .insert({
            event_id:    eventData.id,
            client_id:   clientId,
            group_id:    quote.group_id,
            event_date:  quote.event_date,
            event_time:  quote.event_time  ?? null,
            address:     address || null,
            total_price: baseTotal,
            status:      'accepted',
            quote_id:    quote.id,
            notes:       quote.comments   ?? null,
            ...(months > 1 ? { msi_months: months } : {}),
            // 🎁 Regalo: copiar del quote a la reserva
            ...(quote.is_gift ? {
              is_gift:                true,
              gift_recipient_name:    quote.gift_recipient_name ?? null,
              gift_recipient_contact: quote.gift_recipient_contact ?? null,
              gift_message:           quote.gift_message ?? null,
            } : {}),
          })
          .select('id')
          .single();
        if (resErr || !resData?.id) throw new Error('No se pudo crear la reserva.');

        reservationId = resData.id;

        await supabase.from('quotes').update({ status: 'accepted' }).eq('id', quote.id);

        if (quote.group?.owner_id) {
          await supabase.from('notifications').insert({
            user_id: quote.group.owner_id,
            type:    'quote_accepted',
            title:   '✅ Cotización aceptada',
            body:    `Un cliente aceptó tu cotización de $${baseTotal.toLocaleString()} MXN.`,
            data:    { quote_id: quote.id, reservation_id: reservationId },
          });
        }
      }

      // ── Router de cobro POR MÉTODO ──────────────────────────────────
      //   Tarjeta / SPEI / Efectivo → Conekta (Hosted Checkout, México).
      //   Pagar a meses (MSI)        → Stripe, que SÍ entrega mensualidades
      //     reales mientras Conekta no tenga MSI habilitado. El cliente nunca
      //     ve "Stripe" (la UI dice "meses con tarjeta de crédito").
      //   Al habilitar MSI en Conekta: quitar `&& method !== 'msi'` y listo.
      //   PAY_MX_WITH_CONEKTA=false → todo cae a Stripe (fallback US/rollback).
      if (PAY_MX_WITH_CONEKTA && method !== 'msi') {
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
              'Pago pendiente',
              'Puedes completar el pago desde "Mis Eventos" cuando quieras.',
              [{ text: 'Ver mis eventos', onPress: () => navigation.navigate('ClientReservations') }],
            );
            return;
          }
          Alert.alert(
            'Estamos confirmando tu pago…',
            'Tu pago se está procesando. En un momento verás tu evento confirmado en "Mis Eventos".',
            [{ text: 'Ver mis eventos', onPress: () => navigation.navigate('ClientReservations') }],
          );
        } else {
          throw new Error('No se pudo iniciar el pago con Conekta. Intenta de nuevo.');
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

      if (piErr) throw new Error(`Error de pago: ${piErr.message}`);
      if (!piData) throw new Error('Sin respuesta del servidor de pagos.');
      if (piData.error) {
        // Traducciones de errores Stripe a mensajes amigables
        const stripeMsg: string = piData.error ?? '';
        if (
          months > 1 &&
          (stripeMsg.includes('installment') || stripeMsg.includes('card_not_supported'))
        ) {
          throw new Error('Esta tarjeta no es compatible con pago en parcialidades. Selecciona "1 pago" o intenta con otra tarjeta.');
        }
        throw new Error(stripeMsg || 'No se pudo inicializar el pago.');
      }
      if (!piData.client_secret) throw new Error('No se recibió el token de pago.');

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
            'Pago pendiente',
            'Puedes completar el pago desde "Mis Eventos" cuando quieras.',
            [{ text: 'Ver mis eventos', onPress: () => navigation.navigate('ClientReservations') }],
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
          throw new Error('Esta tarjeta no es compatible con pago en parcialidades. Puedes intentar con otra tarjeta o pagar en 1 solo pago.');
        }
        throw new Error(errMsg || 'Ocurrió un problema al procesar el pago.');
      }

      setPaidAmount(chargeFor(method, months));
      setPaidResId(reservationId);
      setPaid(true);
    } catch (err: any) {
      Alert.alert('Error al procesar el pago', err.message ?? 'Intenta de nuevo.');
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
      <SafeAreaView style={s.successRoot}>
        <Text style={{ fontSize: 44 }}>{isSpei ? '🏦' : '🏪'}</Text>
        <View style={{ alignItems: 'center', gap: 8 }}>
          <Text style={s.successTitle}>{isSpei ? 'Transfiere para confirmar' : 'Paga en tienda para confirmar'}</Text>
          <Text style={s.successSub}>
            {isSpei
              ? 'Haz una transferencia SPEI desde tu banca con estos datos:'
              : 'Da esta referencia en OXXO, 7-Eleven, farmacias y más:'}
          </Text>
        </View>

        <View style={s.refCard}>
          <Text style={s.refLabel}>{isSpei ? 'CLABE' : 'Referencia'}</Text>
          <Text style={s.refValue} selectable>{mainVal}</Text>
          {isSpei && !!pendingRef.bank && (
            <Text style={s.refBank}>Banco destino: {pendingRef.bank}</Text>
          )}
          <Text style={s.refAmount}>Monto exacto: ${amountStr} MXN</Text>
          <Pressable style={s.refCopyBtn} onPress={copyVal}>
            {copied
              ? <CheckCircle size={16} color="#000" />
              : <Copy size={16} color="#000" />}
            <Text style={s.refCopyText}>{copied ? '¡Copiado!' : (isSpei ? 'Copiar CLABE' : 'Copiar referencia')}</Text>
          </Pressable>
        </View>

        <Text style={s.refNote}>
          Tu evento se confirmará automáticamente en cuanto recibamos tu pago.
          Copia estos datos antes de salir — si los pierdes, puedes generar
          unos nuevos desde "Pago pendiente" en tu inicio.
        </Text>

        <Pressable
          style={s.successBtn}
          onPress={() => navigation.navigate('ClientReservations')}
        >
          <Text style={s.successBtnText}>Ver mis eventos</Text>
        </Pressable>
      </SafeAreaView>
    );
  }

  // ── Pantalla de éxito ────────────────────────────────────────────────────────
  if (paid) {
    return (
      <SafeAreaView style={s.successRoot}>
        <Animated.View style={[s.successIconWrap, { transform: [{ scale: checkScale }], opacity: checkOp }]}>
          <CheckCircle size={72} color={COLORS.green} strokeWidth={1.5} />
        </Animated.View>

        <Animated.View style={{ opacity: checkOp, alignItems: 'center', gap: 8 }}>
          <Text style={s.successTitle}>¡Pago exitoso!</Text>
          <Text style={s.successSub}>Tu reserva está confirmada</Text>
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
            <Text style={s.successAmtLabel}>MXN</Text>
          </View>
        </Animated.View>

        <Pressable
          style={s.successBtn}
          onPress={() => navigation.navigate('ClientReservations', { justPaidReservationId: paidResId })}
        >
          <Text style={s.successBtnText}>Ver mis reservas</Text>
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
            <Text style={s.headerTitle}>Confirmar pago</Text>
            <Text style={s.headerSub}>{groupName}</Text>
          </View>
        </View>
      </SafeAreaView>

      <ScrollView contentContainerStyle={s.scroll} showsVerticalScrollIndicator={false}>

        {/* ── Badges de confianza (sin Stripe) ───────────────────────────────── */}
        <View style={s.badgesRow}>
          <View style={s.badge}>
            <Shield size={12} color={COLORS.green} />
            <Text style={s.badgeText}>Pago protegido</Text>
          </View>
          <View style={s.badge}>
            <Lock size={12} color={COLORS.green} />
            <Text style={s.badgeText}>Garantía Daricefy</Text>
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
            <Text style={s.detailText}>{durationHours}h de servicio</Text>
          </View>
          <View style={s.totalRow}>
            <Text style={s.totalLabel}>Total del evento</Text>
            <Text style={s.totalValue}>${baseTotal.toLocaleString()} MXN</Text>
          </View>
        </View>

        {/* ── Checkout Daricefy: ¿cómo quieres pagar? ─────────────────────────── */}
        <Text style={s.payQuestion}>¿Cómo quieres pagar?</Text>

        {PAYMENT_METHODS.filter((m) => m.enabled).map((m) => {
          const isMsi = !!m.expandsMonths;
          const busy  = busyKey === m.key;
          return (
            <View key={m.key}>
              <Pressable
                style={[
                  s.methodCard,
                  m.recommended && s.methodCardRec,
                  loading && !busy && { opacity: 0.5 },
                ]}
                onPress={() => (isMsi ? setMesesOpen((o) => !o) : pay(m.key))}
                disabled={loading}
              >
                <Text style={s.methodEmoji}>{m.emoji}</Text>

                <View style={{ flex: 1 }}>
                  <View style={s.methodTitleRow}>
                    <Text style={s.methodTitle}>{m.title}</Text>
                    {m.tag ? (
                      <View style={s.methodTag}>
                        <Text style={s.methodTagText}>{m.tag}</Text>
                      </View>
                    ) : null}
                    {m.recommended ? (
                      <View style={s.recPill}>
                        <Text style={s.recPillText}>⭐ Recomendado</Text>
                      </View>
                    ) : null}
                  </View>

                  {m.lines.map((l, i) => (
                    <Text key={i} style={s.methodLine}>· {l}</Text>
                  ))}

                  {m.key === 'spei' ? (
                    <View style={s.savingsPill}>
                      <Text style={s.savingsText}>Ahorra ${SPEI_DISCOUNT} MXN pagando por transferencia</Text>
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
                          <Text style={s.mesTitle}>{mo} meses</Text>
                          <Text style={s.mesSub}>
                            Comisión +{feePct.toFixed(0)}% · total ${financed.toLocaleString()} MXN
                          </Text>
                        </View>
                        {moBusy ? (
                          <ActivityIndicator size="small" color={COLORS.green} />
                        ) : (
                          <Text style={s.mesAmt}>
                            ${monthly.toLocaleString()}
                            <Text style={s.mesAmtUnit}>/mes</Text>
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
          <Text style={s.benefitsTitle}>Tu pago está protegido</Text>
          {[
            { Icon: Shield,     text: 'Pago protegido' },
            { Icon: RotateCcw,  text: 'Reembolso si el grupo no se presenta' },
            { Icon: Wallet,     text: 'Wallet protegida' },
            { Icon: BadgeCheck, text: 'Garantía Daricefy' },
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
  methodCard: {
    flexDirection: 'row', alignItems: 'flex-start', gap: 12,
    backgroundColor: COLORS.card, borderRadius: RADIUS.xl,
    borderWidth: 1, borderColor: COLORS.border,
    padding: SPACING.lg, marginBottom: 10,
    shadowColor: '#000', shadowOffset: { width: 0, height: 2 }, shadowOpacity: 0.06, shadowRadius: 5, elevation: 2,
  },
  methodCardRec: {
    borderWidth: 1.5, borderColor: COLORS.green,
    backgroundColor: 'rgba(0,230,118,0.06)',
  },
  methodEmoji:    { fontSize: 24, width: 32, textAlign: 'center', marginTop: 1 },
  methodTitleRow: { flexDirection: 'row', alignItems: 'center', gap: 8, flexWrap: 'wrap', marginBottom: 5 },
  methodTitle:    { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.text },
  methodTag: {
    backgroundColor: COLORS.card2, borderRadius: RADIUS.full,
    borderWidth: 1, borderColor: COLORS.border, paddingHorizontal: 8, paddingVertical: 3,
  },
  methodTagText:  { fontFamily: FONTS.bodyMedium, fontSize: 10, color: COLORS.muted2 },
  recPill:        { backgroundColor: 'rgba(0,230,118,0.15)', borderRadius: RADIUS.full, paddingHorizontal: 8, paddingVertical: 3 },
  recPillText:    { fontFamily: FONTS.bodyMedium, fontSize: 10, color: COLORS.green },
  methodLine:     { fontFamily: FONTS.body, fontSize: 12.5, color: COLORS.muted2, lineHeight: 18 },
  savingsPill: {
    alignSelf: 'flex-start', backgroundColor: 'rgba(0,230,118,0.12)',
    borderRadius: RADIUS.md, paddingHorizontal: 10, paddingVertical: 5, marginTop: 7,
  },
  savingsText:     { fontFamily: FONTS.bodySemiBold, fontSize: 12, color: COLORS.green },
  methodRight:     { alignItems: 'flex-end', justifyContent: 'center', minWidth: 58, gap: 2, paddingLeft: 6 },
  methodAmt:       { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.text },
  methodAmtStrike: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted, textDecorationLine: 'line-through' },

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
    backgroundColor: COLORS.green, borderRadius: RADIUS.full,
    paddingHorizontal: 18, paddingVertical: 10, marginTop: 10,
  },
  refCopyText: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: '#000' },
  refNote: {
    fontFamily: FONTS.body, fontSize: 12.5, color: COLORS.muted2,
    textAlign: 'center', lineHeight: 18, paddingHorizontal: 10,
  },
});
