/**
 * ExtraHoursScreen — Grupo propone horas extra al cliente.
 *
 * Flujo actualizado:
 * - Grupo selecciona cuántas horas extra ofrecer
 * - Se muestra el desglose con "Tarifa de servicio" (10%)
 * - Si el cliente tiene saldo disponible → se descuenta automáticamente
 * - Si el saldo está agotado → el grupo puede registrar pago en efectivo
 */
import { ArrowLeft, Clock, DollarSign, Banknote, CheckCircle } from 'lucide-react-native';
import React, { useEffect, useState } from 'react';
import {
  Alert,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { supabase } from '../../config/supabase';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';
import Button from '../../components/ui/Button';
import { calcServiceFee, calcGroupEarnings, formatCurrency, SERVICE_FEE_RATE } from '../../utils/calculations';
import Particles from '../../components/ui/Particles';

export default function ExtraHoursScreen({ route, navigation }: any) {
  const { reservation } = route.params;
  const q = reservation.quote;

  // Precios pactados en cotización (si los hay)
  const quoteOpts: { hours: number; total: number }[] = [
    q?.overtime_1h_price != null ? { hours: 1, total: q.overtime_1h_price } : null,
    q?.overtime_2h_price != null ? { hours: 2, total: q.overtime_2h_price } : null,
    q?.overtime_3h_price != null ? { hours: 3, total: q.overtime_3h_price } : null,
  ].filter(Boolean) as { hours: number; total: number }[];

  const hasQuotePrices = quoteOpts.length > 0;

  const [hoursToAdd, setHoursToAdd]   = useState(quoteOpts[0]?.hours ?? 1);
  const [pricePerHour, setPricePerHour] = useState(0);
  const [loading, setLoading]         = useState(false);
  const [cashLoading, setCashLoading] = useState(false);

  // Saldo disponible del cliente para esta reserva
  const [clientBalance, setClientBalance] = useState<number | null>(null);
  const [loadingBalance, setLoadingBalance] = useState(true);

  // ID de la hora extra recién insertada (para confirmar efectivo)
  const [pendingExtraId, setPendingExtraId] = useState<string | null>(null);
  const [cashConfirmed, setCashConfirmed] = useState(false);

  useEffect(() => {
    if (!hasQuotePrices) fetchPriceInfo();
    fetchClientBalance();
  }, []);

  const fetchPriceInfo = async () => {
    const { data: pkg } = await supabase
      .from('packages')
      .select('price, duration_hours')
      .eq('id', reservation.package_id)
      .single();
    if (pkg) setPricePerHour(Math.round(pkg.price / pkg.duration_hours));
  };

  const fetchClientBalance = async () => {
    setLoadingBalance(true);
    const { data } = await supabase.rpc('get_client_available_balance', {
      p_reservation_id: reservation.id,
    });
    setClientBalance(typeof data === 'number' ? data : null);
    setLoadingBalance(false);
  };

  // ── Cálculo de precios ──────────────────────────────────────────────────────
  const selectedQuoteOpt = hasQuotePrices
    ? (quoteOpts.find(o => o.hours === hoursToAdd) ?? quoteOpts[0])
    : null;

  const totalExtra    = selectedQuoteOpt ? selectedQuoteOpt.total : pricePerHour * hoursToAdd;
  const serviceFee    = calcServiceFee(totalExtra);   // 10% de la hora extra
  const groupEarnings = calcGroupEarnings(totalExtra); // 90% — lo que recibe el grupo
  const unitPrice     = selectedQuoteOpt
    ? Math.round(selectedQuoteOpt.total / selectedQuoteOpt.hours)
    : pricePerHour;

  const balanceSufficient = clientBalance !== null && clientBalance >= totalExtra;

  // ── Proponer hora extra (cliente paga desde saldo) ──────────────────────────
  const handleRequest = async () => {
    setLoading(true);
    const { data, error } = await supabase
      .from('extra_hours')
      .insert([{
        reservation_id:    reservation.id,
        hours_added:       hoursToAdd,
        price_per_hour:    unitPrice,
        total_extra_cost:  totalExtra,
        platform_commission: serviceFee,
        group_extra_earnings: groupEarnings,
        status:            'pending',
        is_cash_payment:   false,
      }])
      .select('id')
      .single();

    setLoading(false);
    if (error) {
      Alert.alert('Error', error.message);
    } else {
      Alert.alert(
        '⏰ Solicitud enviada',
        `Se notificó al cliente que puede agregar ${hoursToAdd}h extra por ${formatCurrency(totalExtra)}.`,
        [{ text: 'OK', onPress: () => navigation.goBack() }]
      );
    }
  };

  // ── Registrar pago en efectivo (saldo insuficiente) ─────────────────────────
  const handleCashRequest = async () => {
    Alert.alert(
      '💵 Registrar hora extra en efectivo',
      `¿Confirmas que vas a solicitar ${hoursToAdd}h extra por ${formatCurrency(totalExtra)} en efectivo?\n\nEsto es porque el saldo del cliente ya no es suficiente.`,
      [
        { text: 'Cancelar', style: 'cancel' },
        {
          text: 'Sí, registrar',
          onPress: async () => {
            setCashLoading(true);
            const { data, error } = await supabase
              .from('extra_hours')
              .insert([{
                reservation_id:      reservation.id,
                hours_added:         hoursToAdd,
                price_per_hour:      unitPrice,
                total_extra_cost:    totalExtra,
                platform_commission: 0,      // efectivo no pasa por la plataforma
                group_extra_earnings: totalExtra,
                status:              'pending',
                is_cash_payment:     true,
              }])
              .select('id')
              .single();

            setCashLoading(false);
            if (error) {
              Alert.alert('Error', error.message);
            } else {
              setPendingExtraId(data.id);
            }
          },
        },
      ]
    );
  };

  // ── Confirmar que el grupo recibió el efectivo ──────────────────────────────
  const handleConfirmCashReceived = async () => {
    if (!pendingExtraId) return;
    setCashLoading(true);
    const { error } = await supabase.rpc('confirm_cash_extra_payment', {
      p_extra_hour_id:  pendingExtraId,
      p_reservation_id: reservation.id,
    });
    setCashLoading(false);
    if (error) {
      Alert.alert('Error', error.message);
    } else {
      setCashConfirmed(true);
    }
  };

  const hourOptions = hasQuotePrices ? quoteOpts.map(o => o.hours) : [1, 2];

  // ── RENDER: Confirmación de efectivo recibido ───────────────────────────────
  if (cashConfirmed) {
    return (
      <View style={styles.container}>
        <Particles />
        <SafeAreaView style={{ flex: 1, alignItems: 'center', justifyContent: 'center', padding: SPACING.xl }}>
          <View style={styles.successCard}>
            <CheckCircle size={56} color={COLORS.green} />
            <Text style={styles.successTitle}>¡Efectivo confirmado!</Text>
            <Text style={styles.successDesc}>
              Registramos que recibiste ${totalExtra.toLocaleString()} en efectivo por {hoursToAdd}h extra.{'\n\n'}
              Este pago no pasa por la plataforma. Tú lo tienes.
            </Text>
            <View style={styles.successSummary}>
              <View style={styles.summaryRow}>
                <Text style={styles.summaryLabel}>Pago por plataforma</Text>
                <Text style={styles.summaryValue}>{formatCurrency(groupEarnings)}</Text>
              </View>
              <View style={styles.summaryRow}>
                <Text style={styles.summaryLabel}>Efectivo (tú lo tienes)</Text>
                <Text style={[styles.summaryValue, { color: COLORS.orange }]}>{formatCurrency(totalExtra)}</Text>
              </View>
            </View>
            <Button label="Listo" onPress={() => navigation.goBack()} size="lg" />
          </View>
        </SafeAreaView>
      </View>
    );
  }

  // ── RENDER: Confirmar recepción de efectivo ─────────────────────────────────
  if (pendingExtraId) {
    return (
      <View style={styles.container}>
        <Particles />
        <SafeAreaView style={{ flex: 1 }}>
          <View style={styles.header}>
            <Pressable style={styles.backBtn} onPress={() => navigation.goBack()}>
              <ArrowLeft size={20} color={COLORS.text} />
            </Pressable>
            <Text style={styles.headerTitle}>Confirmar Efectivo</Text>
            <View style={{ width: 40 }} />
          </View>
          <ScrollView contentContainerStyle={styles.scroll}>
            <View style={styles.cashConfirmCard}>
              <Banknote size={36} color={COLORS.orange} />
              <Text style={styles.cashConfirmTitle}>Confirmar Pago en Efectivo</Text>

              <View style={styles.cashConfirmDetails}>
                <View style={styles.priceRow}>
                  <Text style={styles.priceLabel}>Concepto</Text>
                  <Text style={styles.priceValue}>{hoursToAdd} hora{hoursToAdd > 1 ? 's' : ''} extra</Text>
                </View>
                <View style={styles.priceRow}>
                  <Text style={styles.priceLabel}>Monto recibido</Text>
                  <Text style={[styles.priceValue, { color: COLORS.orange }]}>{formatCurrency(totalExtra)}</Text>
                </View>
              </View>

              <View style={styles.cashWarning}>
                <Text style={styles.cashWarningText}>
                  ⚠️ Solo confirma si realmente recibiste el dinero. Al confirmar, el cliente verá que quedó saldado.{'\n\n'}
                  Este pago NO pasa por la plataforma.
                </Text>
              </View>
            </View>

            <View style={{ marginTop: 16, marginBottom: 32, gap: 12 }}>
              <Button
                label={`✅ Confirmar que recibí ${formatCurrency(totalExtra)} en efectivo`}
                onPress={handleConfirmCashReceived}
                loading={cashLoading}
                size="lg"
              />
              <Button
                label="Aún no lo recibo"
                onPress={() => navigation.goBack()}
                variant="ghost"
                size="lg"
              />
            </View>
          </ScrollView>
        </SafeAreaView>
      </View>
    );
  }

  // ── RENDER PRINCIPAL ────────────────────────────────────────────────────────
  return (
    <View style={styles.container}>
      <Particles />
      <SafeAreaView style={{ flex: 1 }}>
        <View style={styles.header}>
          <Pressable style={styles.backBtn} onPress={() => navigation.goBack()}>
            <ArrowLeft size={20} color={COLORS.text} />
          </Pressable>
          <Text style={styles.headerTitle}>Horas Extra</Text>
          <View style={{ width: 40 }} />
        </View>

        <ScrollView showsVerticalScrollIndicator={false} contentContainerStyle={styles.scroll}>

          {/* INFO */}
          <View style={styles.infoCard}>
            <Clock size={20} color={COLORS.orange} />
            <Text style={styles.infoText}>
              {hasQuotePrices
                ? 'Estos precios fueron pactados en la cotización. Selecciona las horas que quieres ofrecer.'
                : 'Puedes solicitar hasta 2 horas extra. El cliente recibirá la notificación para aprobar.'}
            </Text>
          </View>

          {/* SALDO DEL CLIENTE */}
          {!loadingBalance && (
            <View style={[styles.balanceCard, balanceSufficient ? styles.balanceOk : styles.balanceLow]}>
              <DollarSign size={18} color={balanceSufficient ? COLORS.green : COLORS.orange} />
              <View style={{ flex: 1 }}>
                <Text style={styles.balanceLabel}>Saldo disponible del cliente</Text>
                <Text style={[styles.balanceValue, { color: balanceSufficient ? COLORS.green : COLORS.orange }]}>
                  {clientBalance !== null ? formatCurrency(clientBalance) : 'No disponible'}
                </Text>
              </View>
              {!balanceSufficient && clientBalance !== null && (
                <View style={styles.balanceLowBadge}>
                  <Text style={styles.balanceLowBadgeText}>Insuficiente</Text>
                </View>
              )}
            </View>
          )}

          {/* SELECTOR DE HORAS */}
          <Text style={styles.sectionTitle}>¿Cuántas horas extra?</Text>
          <View style={styles.selectorRow}>
            {hourOptions.map(h => {
              const opt    = hasQuotePrices ? quoteOpts.find(o => o.hours === h) : null;
              const isActive = hoursToAdd === h;
              return (
                <Pressable
                  key={h}
                  style={[styles.hoursBtn, isActive && styles.hoursBtnActive]}
                  onPress={() => setHoursToAdd(h)}
                >
                  <Text style={[styles.hoursNum, isActive && styles.hoursNumActive]}>+{h}h</Text>
                  {opt ? (
                    <Text style={[styles.hoursSub, isActive && { color: COLORS.green }]}>
                      {formatCurrency(opt.total)}
                    </Text>
                  ) : (
                    <Text style={[styles.hoursSub, isActive && { color: COLORS.green }]}>
                      {h === 1 ? 'Una hora' : 'Dos horas'}
                    </Text>
                  )}
                </Pressable>
              );
            })}
          </View>

          {/* DESGLOSE */}
          <Text style={styles.sectionTitle}>Desglose</Text>
          <View style={styles.breakdownCard}>
            {hasQuotePrices ? (
              <PriceRow label={`Precio pactado (${hoursToAdd}h)`} value={formatCurrency(totalExtra)} bold />
            ) : (
              <>
                <PriceRow label="Precio por hora" value={formatCurrency(pricePerHour)} />
                <PriceRow label={`× ${hoursToAdd} hora${hoursToAdd > 1 ? 's' : ''}`} value={formatCurrency(totalExtra)} bold />
              </>
            )}
            <View style={styles.divider} />

            {balanceSufficient ? (
              // Pago desde saldo: el cliente paga, la plataforma toma 10%
              <>
                <PriceRow
                  label={`Tarifa de servicio (${Math.round(SERVICE_FEE_RATE * 100)}%)`}
                  value={`-${formatCurrency(serviceFee)}`}
                  color={COLORS.muted2}
                />
                <View style={styles.divider} />
                <View style={styles.netRow}>
                  <Text style={styles.netLabel}>Tu ganancia extra</Text>
                  <Text style={styles.netValue}>{formatCurrency(groupEarnings)}</Text>
                </View>
              </>
            ) : (
              // Pago en efectivo: el grupo se queda todo
              <>
                <PriceRow label="Tarifa de servicio" value="$0 (efectivo)" color={COLORS.muted2} />
                <View style={styles.divider} />
                <View style={styles.netRow}>
                  <Text style={styles.netLabel}>Tu ganancia extra (efectivo)</Text>
                  <Text style={styles.netValue}>{formatCurrency(totalExtra)}</Text>
                </View>
              </>
            )}
          </View>

          {/* TOTAL QUE PAGA EL CLIENTE */}
          <View style={styles.clientPays}>
            <DollarSign size={18} color={COLORS.green} />
            <Text style={styles.clientPaysText}>
              El cliente paga: <Text style={styles.clientPaysAmount}>{formatCurrency(totalExtra)}</Text>
            </Text>
          </View>

          {/* BOTONES */}
          <View style={{ marginTop: 24, marginBottom: 32, gap: 12 }}>
            {balanceSufficient ? (
              // Tiene saldo — descuento automático
              <Button
                label={`Solicitar +${hoursToAdd}h (desde saldo del cliente)`}
                onPress={handleRequest}
                loading={loading}
                size="lg"
              />
            ) : (
              // Sin saldo — opciones: efectivo o cancelar
              <>
                <View style={styles.noBalanceBanner}>
                  <Text style={styles.noBalanceTitle}>⚠️ Saldo del cliente insuficiente</Text>
                  <Text style={styles.noBalanceDesc}>
                    El cliente agotó su saldo disponible. Puede pagar en efectivo directamente a ti.
                  </Text>
                </View>
                <Button
                  label={`💵 Registrar ${hoursToAdd}h en efectivo`}
                  onPress={handleCashRequest}
                  loading={cashLoading}
                  size="lg"
                />
              </>
            )}
            <Button
              label="Cancelar"
              onPress={() => navigation.goBack()}
              variant="ghost"
              size="lg"
            />
          </View>
        </ScrollView>
      </SafeAreaView>
    </View>
  );
}

function PriceRow({ label, value, bold, color }: {
  label: string; value: string; bold?: boolean; color?: string;
}) {
  return (
    <View style={styles.priceRow}>
      <Text style={[styles.priceLabel, bold && styles.bold]}>{label}</Text>
      <Text style={[styles.priceValue, bold && styles.bold, color ? { color } : undefined]}>{value}</Text>
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: COLORS.bg },
  header: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between',
    paddingHorizontal: SPACING.xl, paddingVertical: 14,
    borderBottomWidth: 1, borderBottomColor: COLORS.border,
  },
  backBtn: {
    width: 40, height: 40, borderRadius: 12,
    backgroundColor: COLORS.card, borderWidth: 1, borderColor: COLORS.border,
    alignItems: 'center', justifyContent: 'center',
  },
  headerTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 16, color: COLORS.text },
  scroll: { padding: SPACING.xl },

  infoCard: {
    flexDirection: 'row', alignItems: 'flex-start', gap: 12,
    backgroundColor: 'rgba(255,152,0,0.1)', borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.orange, padding: SPACING.lg, marginBottom: 20,
  },
  infoText: { fontFamily: FONTS.body, fontSize: 14, color: COLORS.orange, flex: 1, lineHeight: 20 },

  // Client balance
  balanceCard: {
    flexDirection: 'row', alignItems: 'center', gap: 12,
    borderRadius: RADIUS.lg, borderWidth: 1, padding: SPACING.lg, marginBottom: 24,
  },
  balanceOk:  { backgroundColor: 'rgba(0,230,118,0.06)', borderColor: 'rgba(0,230,118,0.3)' },
  balanceLow: { backgroundColor: 'rgba(245,158,11,0.06)', borderColor: 'rgba(245,158,11,0.3)' },
  balanceLabel: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2, marginBottom: 3 },
  balanceValue: { fontFamily: FONTS.title, fontSize: 20 },
  balanceLowBadge: {
    paddingHorizontal: 10, paddingVertical: 4, borderRadius: RADIUS.full,
    backgroundColor: 'rgba(245,158,11,0.15)', borderWidth: 1, borderColor: 'rgba(245,158,11,0.4)',
  },
  balanceLowBadgeText: { fontFamily: FONTS.bodySemiBold, fontSize: 11, color: COLORS.orange },

  sectionTitle: { fontFamily: FONTS.title, fontSize: 18, color: COLORS.text, marginBottom: 14 },
  selectorRow:  { flexDirection: 'row', gap: 14, marginBottom: 28 },
  hoursBtn: {
    flex: 1, alignItems: 'center', paddingVertical: 20,
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border,
  },
  hoursBtnActive: { borderColor: COLORS.green, backgroundColor: COLORS.greenMuted },
  hoursNum: { fontFamily: FONTS.title, fontSize: 32, color: COLORS.muted2, marginBottom: 4 },
  hoursNumActive: { color: COLORS.green },
  hoursSub: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted },

  breakdownCard: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border, padding: SPACING.lg, marginBottom: 16,
  },
  priceRow:  { flexDirection: 'row', justifyContent: 'space-between', marginBottom: 10 },
  priceLabel: { fontFamily: FONTS.body, fontSize: 14, color: COLORS.muted2 },
  priceValue: { fontFamily: FONTS.bodyMedium, fontSize: 14, color: COLORS.text },
  bold: { fontFamily: FONTS.bodySemiBold, color: COLORS.text },
  divider: { height: 1, backgroundColor: COLORS.border, marginVertical: 8 },
  netRow:   { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center' },
  netLabel: { fontFamily: FONTS.bodyMedium, fontSize: 14, color: COLORS.muted2 },
  netValue: { fontFamily: FONTS.title, fontSize: 24, color: COLORS.green },

  clientPays: {
    flexDirection: 'row', alignItems: 'center', gap: 8,
    backgroundColor: COLORS.greenMuted, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.green, padding: SPACING.lg,
  },
  clientPaysText:   { fontFamily: FONTS.bodyMedium, fontSize: 14, color: COLORS.text },
  clientPaysAmount: { fontFamily: FONTS.title, fontSize: 18, color: COLORS.green },

  noBalanceBanner: {
    backgroundColor: 'rgba(245,158,11,0.08)', borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: 'rgba(245,158,11,0.35)', padding: SPACING.lg,
  },
  noBalanceTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.orange, marginBottom: 6 },
  noBalanceDesc:  { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2, lineHeight: 20 },

  // Cash confirmation
  cashConfirmCard: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.xl,
    borderWidth: 1, borderColor: COLORS.border, padding: SPACING.xl, alignItems: 'center', gap: 16,
  },
  cashConfirmTitle: { fontFamily: FONTS.title, fontSize: 20, color: COLORS.text, textAlign: 'center' },
  cashConfirmDetails: {
    width: '100%', backgroundColor: COLORS.card2, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border, padding: SPACING.lg, gap: 10,
  },
  cashWarning: {
    backgroundColor: 'rgba(245,158,11,0.08)', borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: 'rgba(245,158,11,0.35)', padding: SPACING.lg, width: '100%',
  },
  cashWarningText: {
    fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2, lineHeight: 20, textAlign: 'center',
  },

  // Success
  successCard: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.xl,
    borderWidth: 1, borderColor: COLORS.border, padding: SPACING.xl, alignItems: 'center', gap: 16,
    width: '100%',
  },
  successTitle: { fontFamily: FONTS.title, fontSize: 22, color: COLORS.text },
  successDesc: {
    fontFamily: FONTS.body, fontSize: 14, color: COLORS.muted2,
    textAlign: 'center', lineHeight: 22,
  },
  successSummary: {
    width: '100%', backgroundColor: COLORS.card2, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border, padding: SPACING.lg, gap: 10,
  },
  summaryRow: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center' },
  summaryLabel: { fontFamily: FONTS.body, fontSize: 14, color: COLORS.muted2 },
  summaryValue: { fontFamily: FONTS.bodyMedium, fontSize: 14, color: COLORS.text },
});
