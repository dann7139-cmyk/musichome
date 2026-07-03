/**
 * QuotePaymentScreen — Pago de cotización vía Stripe.
 * Soporta dos modos:
 *   - route.params.quote        → cotización nueva: crea evento + reserva + paga
 *   - route.params.reservation  → reserva existente sin pago: salta creación y va directo a Stripe
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
  ArrowLeft, Calendar, CheckCircle, CreditCard, Lock, MapPin, Music2, Shield, Zap,
} from 'lucide-react-native';
import { useStripe } from '@stripe/stripe-react-native';
import { supabase } from '../../config/supabase';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';
import { MSI_OPTIONS, MsiOption } from '../../utils/calculations';
import { calculateFinancedPrice, calculateMonthlyPayment, PUBLIC_MSI_FEE_RATES } from '../../utils/publicPricing';

const MSI_MIN_AMOUNT = 300; // MXN mínimo para MSI (recomendación Stripe MX)

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

  // MSI inicial: si la reserva ya tenía un plan, preinicializar con él
  const initialMsi = MSI_OPTIONS.find(o => o.months === (existingRes?.msi_months ?? 1)) ?? MSI_OPTIONS[0];
  const [loading, setLoading]         = useState(false);
  const [selectedMSI, setSelectedMSI] = useState<MsiOption>(initialMsi);
  const [paid, setPaid]               = useState(false);
  const [paidResId, setPaidResId]     = useState<string | null>(null);

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

  const chargeTotal  = calculateFinancedPrice(baseTotal, selectedMSI.months);
  const msiFeeAmount = chargeTotal - baseTotal;
  const monthlyAmt   = calculateMonthlyPayment(baseTotal, selectedMSI.months);

  const eventDateStr = eventDateRaw
    ? new Date(eventDateRaw + 'T12:00:00').toLocaleDateString('es-MX', {
        weekday: 'long', year: 'numeric', month: 'long', day: 'numeric',
      })
    : '—';

  const handlePay = async () => {
    if (loading) return;

    // Validar monto mínimo para MSI
    if (selectedMSI.months > 1 && chargeTotal < MSI_MIN_AMOUNT) {
      Alert.alert(
        'Monto insuficiente',
        `El pago en parcialidades está disponible solo para montos mayores a $${MSI_MIN_AMOUNT} MXN.`,
      );
      return;
    }

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
            ...(selectedMSI.months > 1 ? { msi_months: selectedMSI.months } : {}),
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

      // Crear PaymentIntent
      const { data: piData, error: piErr } = await supabase.functions.invoke('create-payment-intent', {
        body: {
          reservation_id: reservationId,
          msi_months:     selectedMSI.months > 1 ? selectedMSI.months : undefined,
        },
        headers: { Authorization: `Bearer ${sd.session?.access_token}` },
      });

      if (piErr) throw new Error(`Error de pago: ${piErr.message}`);
      if (!piData) throw new Error('Sin respuesta del servidor de pagos.');
      if (piData.error) {
        // Traducciones de errores Stripe a mensajes amigables
        const stripeMsg: string = piData.error ?? '';
        if (
          selectedMSI.months > 1 &&
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
          selectedMSI.months > 1 &&
          (errMsg.toLowerCase().includes('installment') ||
           errMsg.toLowerCase().includes('no está disponible') ||
           errMsg.toLowerCase().includes('not available'))
        ) {
          throw new Error('Esta tarjeta no es compatible con pago en parcialidades. Puedes intentar con otra tarjeta o pagar en 1 solo pago.');
        }
        throw new Error(errMsg || 'Ocurrió un problema al procesar el pago.');
      }

      setPaidResId(reservationId);
      setPaid(true);
    } catch (err: any) {
      Alert.alert('Error al procesar el pago', err.message ?? 'Intenta de nuevo.');
    } finally {
      setLoading(false);
    }
  };

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
            <Text style={s.successAmt}>${chargeTotal.toLocaleString()}</Text>
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

        {/* ── Badges premium ─────────────────────────────────────────────────── */}
        <View style={s.badgesRow}>
          <View style={s.badge}>
            <CreditCard size={12} color={COLORS.blue} />
            <Text style={s.badgeText}>Pago en parcialidades disponible</Text>
          </View>
          <View style={s.badge}>
            <Zap size={12} color={COLORS.green} />
            <Text style={s.badgeText}>Pago seguro · Stripe</Text>
          </View>
          <View style={s.badge}>
            <Lock size={12} color={COLORS.green} />
            <Text style={s.badgeText}>Protección DARICEFY</Text>
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
          <View style={s.detailRow}>
            <Shield size={15} color={COLORS.muted2} />
            <Text style={s.detailText}>Pago protegido — reembolso si el grupo no se presenta</Text>
          </View>
        </View>

        {/* ── Selector MSI ────────────────────────────────────────────────────── */}
        <View style={s.msiCard}>
          <View style={s.msiHeader}>
            <CreditCard size={16} color={COLORS.blue} />
            <Text style={s.msiTitle}>Plan de pago</Text>
          </View>
          <Text style={s.msiSub}>Tarjetas de crédito participantes · Stripe</Text>

          {MSI_OPTIONS.map((opt) => {
            const isActive  = selectedMSI.key === opt.key;
            const monthly   = calculateMonthlyPayment(baseTotal, opt.months);
            const feeRatePct = (PUBLIC_MSI_FEE_RATES[opt.months] ?? 0) * 100;
            return (
              <Pressable
                key={opt.key}
                style={[s.msiOption, isActive && s.msiOptionActive]}
                onPress={() => setSelectedMSI(opt)}
              >
                <View style={s.msiCheck}>
                  {isActive
                    ? <CheckCircle size={16} color={COLORS.green} />
                    : <View style={s.msiCheckEmpty} />}
                </View>
                <View style={{ flex: 1 }}>
                  <Text style={[s.msiOptionLabel, isActive && s.msiOptionLabelActive]}>
                    {opt.label}
                  </Text>
                  <Text style={s.msiOptionSub}>
                    {opt.months > 1
                      ? `${opt.months} mensualidades · cargo +${feeRatePct.toFixed(0)}%`
                      : 'Sin cargo adicional'}
                  </Text>
                </View>
                <Text style={[s.msiOptionAmt, isActive && s.msiOptionAmtActive]}>
                  {opt.months > 1
                    ? `$${monthly.toLocaleString()}/mes`
                    : `$${baseTotal.toLocaleString()}`}
                </Text>
              </Pressable>
            );
          })}

          <Text style={s.msiDisclaimer}>
            Stripe verifica compatibilidad de la tarjeta al confirmar.
          </Text>
        </View>

        {/* ── Breakdown de pago ───────────────────────────────────────────────── */}
        <View style={s.breakdown}>
          <Text style={s.breakdownTitle}>RESUMEN DE PAGO</Text>

          <View style={s.breakdownRow}>
            <View style={s.breakdownLeft}>
              <Text style={s.breakdownLabel}>Cotización del grupo</Text>
            </View>
            <Text style={s.breakdownAmount}>${baseTotal.toLocaleString()} MXN</Text>
          </View>

          {msiFeeAmount > 0 && (
            <View style={s.breakdownRow}>
              <View style={s.breakdownLeft}>
                <Text style={s.breakdownLabel}>Financiamiento ({selectedMSI.months} meses)</Text>
                <Text style={s.breakdownSubLabel}>+{((PUBLIC_MSI_FEE_RATES[selectedMSI.months] ?? 0) * 100).toFixed(0)}% tarifa de financiamiento</Text>
              </View>
              <Text style={[s.breakdownAmount, s.breakdownAmountExtra]}>
                +${msiFeeAmount.toLocaleString()}
              </Text>
            </View>
          )}

          <View style={s.breakdownTotal}>
            <Text style={s.breakdownTotalLabel}>TOTAL A PAGAR</Text>
            <Text style={s.breakdownTotalValue}>
              ${chargeTotal.toLocaleString()} MXN
            </Text>
          </View>

          {selectedMSI.months > 1 && (
            <View style={s.monthlyHero}>
              <View>
                <Text style={s.monthlyHeroLabel}>{selectedMSI.months} pagos de</Text>
                <Text style={s.monthlyHeroAmt}>${monthlyAmt.toLocaleString()} MXN</Text>
              </View>
              <View style={{ alignItems: 'flex-end' }}>
                <Text style={s.monthlyHeroInterest}>Financiamiento incluido ✅</Text>
                <Text style={s.monthlyHeroNote}>El total puede variar.</Text>
              </View>
            </View>
          )}
        </View>

        {/* ── Botón pagar ─────────────────────────────────────────────────────── */}
        <Pressable
          style={[s.payBtn, loading && { opacity: 0.6 }]}
          onPress={handlePay}
          disabled={loading}
        >
          {loading
            ? <ActivityIndicator size="small" color={COLORS.bg} />
            : <CreditCard size={18} color={COLORS.bg} />}
          <Text style={s.payBtnText}>
            {loading
              ? 'Procesando...'
              : selectedMSI.months > 1
                ? `${selectedMSI.months} pagos de $${monthlyAmt.toLocaleString()} MXN`
                : `Pagar $${chargeTotal.toLocaleString()} MXN`}
          </Text>
        </Pressable>

        <Text style={s.payNote}>🔒 Pago seguro · Stripe · Sin compartir datos de tarjeta</Text>
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

  // MSI Card
  msiCard: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.xl,
    borderWidth: 1.5, borderColor: COLORS.blue,
    padding: SPACING.lg, marginBottom: 16,
    shadowColor: COLORS.blue, shadowOffset: { width: 0, height: 2 }, shadowOpacity: 0.08, shadowRadius: 6, elevation: 2,
  },
  msiHeader: { flexDirection: 'row', alignItems: 'center', gap: 10, marginBottom: 4 },
  msiSub:    { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted, marginBottom: 12 },
  msiOption: {
    flexDirection: 'row', alignItems: 'center', gap: 12,
    backgroundColor: COLORS.card2, borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: COLORS.border,
    padding: 14, marginBottom: 8,
  },
  msiOptionActive: { borderColor: COLORS.green, backgroundColor: 'rgba(0,230,118,0.08)' },
  msiCheck:      { width: 20, alignItems: 'center' },
  msiCheckEmpty: {
    width: 16, height: 16, borderRadius: 8,
    borderWidth: 1.5, borderColor: COLORS.border,
  },
  msiTitle:  { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.text },
  msiOptionLabel:       { fontFamily: FONTS.bodyMedium, fontSize: 14, color: COLORS.muted2 },
  msiOptionLabelActive: { color: COLORS.text },
  msiOptionSub:         { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted, marginTop: 2 },
  msiOptionAmt:         { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.muted2 },
  msiOptionAmtActive:   { color: COLORS.green },
  msiDisclaimer: {
    fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted,
    lineHeight: 16, marginTop: 8,
  },

  // Breakdown
  breakdown: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.xl,
    borderWidth: 1, borderColor: COLORS.border,
    padding: SPACING.lg, marginBottom: 16,
    shadowColor: '#000', shadowOffset: { width: 0, height: 2 }, shadowOpacity: 0.07, shadowRadius: 6, elevation: 2,
  },
  breakdownTitle: {
    fontFamily: FONTS.bodySemiBold, fontSize: 11, color: COLORS.muted,
    letterSpacing: 0.8, marginBottom: 14,
  },
  breakdownRow: {
    flexDirection: 'row', alignItems: 'flex-start',
    paddingVertical: 11, borderBottomWidth: 1, borderBottomColor: COLORS.border,
  },
  breakdownLeft:        { flex: 1, paddingRight: 14 },
  breakdownLabel:       { fontFamily: FONTS.body, fontSize: 14, color: COLORS.muted2 },
  breakdownSubLabel:    { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted, marginTop: 3 },
  breakdownAmount:      { fontFamily: FONTS.bodyMedium, fontSize: 14, color: COLORS.text, textAlign: 'right' },
  breakdownAmountExtra: { color: '#F59E0B' },
  breakdownTotal: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between',
    paddingTop: 16, marginTop: 2,
  },
  breakdownTotalLabel: { fontFamily: FONTS.bodySemiBold, fontSize: 11, color: COLORS.muted, letterSpacing: 0.6 },
  breakdownTotalValue: { fontFamily: FONTS.bodySemiBold, fontSize: 20, color: COLORS.green },

  // Monthly hero
  monthlyHero: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between',
    marginTop: 12,
    backgroundColor: COLORS.card2, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.2)', padding: 14,
  },
  monthlyHeroLabel:    { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2 },
  monthlyHeroAmt:      { fontFamily: FONTS.bodySemiBold, fontSize: 18, color: COLORS.green },
  monthlyHeroInterest: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.green, opacity: 0.8 },
  monthlyHeroDivider: { display: 'none' as any },
  monthlyHeroNote: {
    fontFamily: FONTS.body, fontSize: 11,
    color: COLORS.muted, lineHeight: 16,
    textAlign: 'right',
  },

  // Pay button
  payBtn: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 10,
    backgroundColor: COLORS.green, borderRadius: RADIUS.lg, paddingVertical: 17,
    marginBottom: 10,
  },
  payBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.bg },
  payNote:    { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted, textAlign: 'center' },

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
});
