/**
 * ExtraHoursScreen — Grupo propone horas extra al cliente.
 *
 * Flujo:
 * - Grupo ingresa su precio neto (lo que quieren recibir, 100%)
 * - El cliente paga groupNeto × 1.20 (markup 20%, interno — no mostrar)
 * - Si el cliente tiene saldo disponible → descuento automático vía plataforma
 * - Si el saldo está agotado → pago en efectivo directo al grupo (sin markup)
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
import { calcGroupEarnings, formatCurrency } from '../../utils/calculations';
import Particles from '../../components/ui/Particles';

export default function ExtraHoursScreen({ route, navigation }: any) {
  const { reservation, initialHours, maxExtra } = route.params;
  const q = reservation.quote;
  // Tope por logística: con otra tocada después ese día no caben todas
  // (lo calcula EventTimerScreen con maxExtraHoursAfter; sin param = sin tope)
  const extraCap: number = typeof maxExtra === 'number' ? maxExtra : Infinity;

  // Precios pactados en cotización (si los hay), limitados al tope logístico
  const quoteOpts: { hours: number; total: number }[] = ([
    q?.overtime_1h_price != null ? { hours: 1, total: q.overtime_1h_price } : null,
    q?.overtime_2h_price != null ? { hours: 2, total: q.overtime_2h_price } : null,
    q?.overtime_3h_price != null ? { hours: 3, total: q.overtime_3h_price } : null,
  ].filter(Boolean) as { hours: number; total: number }[])
    .filter(o => o.hours <= extraCap);

  const hasQuotePrices = quoteOpts.length > 0;

  const [hoursToAdd, setHoursToAdd]   = useState(initialHours ?? quoteOpts[0]?.hours ?? 1);
  const [pricePerHour, setPricePerHour] = useState(0);
  const [priceLoading, setPriceLoading] = useState(!hasQuotePrices);
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
    // Precio/hora neto derivado de la propia reserva (la tabla packages ya no existe)
    const { data: res } = await supabase
      .from('reservations')
      .select('total_price, group_earnings, hours_count')
      .eq('id', reservation.id)
      .single();
    if (res) {
      const hours = Number(res.hours_count) || 1;
      const net = res.group_earnings ?? calcGroupEarnings(res.total_price ?? 0);
      if (net > 0) setPricePerHour(Math.round(net / hours));
    }
    setPriceLoading(false);
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

  // overtime_X_price en DB ya es precio CLIENTE (markup 20% aplicado en QuoteDetailScreen).
  // Cuando se usa quoteOpt: groupNet = DB_value / 1.20; clientTotal = DB_value.
  // Sin quoteOpts: grupo ingresa precio neto directo.
  const groupNet      = selectedQuoteOpt
    ? calcGroupEarnings(selectedQuoteOpt.total)   // DB tiene precio cliente → derivar neto
    : pricePerHour * hoursToAdd;
  const clientTotal   = selectedQuoteOpt
    ? selectedQuoteOpt.total                      // ya es precio cliente ✓
    : Math.round(groupNet * 1.20);
  const groupEarnings = groupNet;
  const unitPrice     = selectedQuoteOpt
    ? Math.round(selectedQuoteOpt.total / selectedQuoteOpt.hours)
    : pricePerHour;

  const balanceSufficient = clientBalance !== null && clientBalance >= clientTotal;

  // Guard: sin precio por hora resuelto, nunca permitir una extra a $0
  const priceUnavailable = !hasQuotePrices && pricePerHour === 0;

  // ── Proponer hora extra (cliente paga desde saldo) ──────────────────────────
  const handleRequest = async () => {
    if (hoursToAdd > extraCap) {
      Alert.alert('🚐 No hay tiempo', 'Tienes otra tocada después de este evento — el traslado es obligatorio y esas horas extra ya no caben.');
      return;
    }
    setLoading(true);
    const { data, error } = await supabase
      .from('extra_hours')
      .insert([{
        reservation_id:       reservation.id,
        hours_added:          hoursToAdd,
        price_per_hour:       unitPrice,
        total_extra_cost:     clientTotal,           // lo que paga el cliente (groupNeto × 1.20)
        platform_commission:  clientTotal - groupNet, // comisión Daricefy (interna)
        group_extra_earnings: groupEarnings,          // lo que recibe el grupo (= groupNet)
        status:               'pending',
        is_cash_payment:      false,
      }])
      .select('id')
      .single();

    setLoading(false);
    if (error) {
      Alert.alert('Error', error.message);
    } else {
      Alert.alert(
        '⏰ Solicitud enviada',
        `Se notificó al cliente sobre ${hoursToAdd}h extra. Recibirás ${formatCurrency(groupEarnings)} al terminar el evento.`,
        [{ text: 'OK', onPress: () => navigation.goBack() }]
      );
    }
  };

  // ── Registrar pago en efectivo (saldo insuficiente) ─────────────────────────
  const handleCashRequest = async () => {
    if (hoursToAdd > extraCap) {
      Alert.alert('🚐 No hay tiempo', 'Tienes otra tocada después de este evento — el traslado es obligatorio y esas horas extra ya no caben.');
      return;
    }
    Alert.alert(
      '💵 Registrar hora extra en efectivo',
      `¿Confirmas ${hoursToAdd}h extra en efectivo?\n\nEl cliente te pagará directamente: ${formatCurrency(groupNet)}`,
      [
        { text: 'Cancelar', style: 'cancel' },
        {
          text: 'Sí, registrar',
          onPress: async () => {
            setCashLoading(true);
            const { data, error } = await supabase
              .from('extra_hours')
              .insert([{
                reservation_id:       reservation.id,
                hours_added:          hoursToAdd,
                price_per_hour:       unitPrice,
                total_extra_cost:     groupNet,  // efectivo: sin markup, grupo recibe directo
                platform_commission:  0,
                group_extra_earnings: groupNet,
                status:               'pending',
                is_cash_payment:      true,
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

  const hourOptions = (hasQuotePrices ? quoteOpts.map(o => o.hours) : [1, 2])
    .filter(h => h <= extraCap);

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
              Registramos que recibiste ${groupNet.toLocaleString()} en efectivo por {hoursToAdd}h extra.{'\n\n'}
              Este pago no pasa por la plataforma. Tú lo tienes.
            </Text>
            <View style={styles.successSummary}>
              <View style={styles.summaryRow}>
                <Text style={styles.summaryLabel}>Horas extra</Text>
                <Text style={styles.summaryValue}>{hoursToAdd === 1 ? '1 hora' : `${hoursToAdd} horas`}</Text>
              </View>
              <View style={styles.summaryRow}>
                <Text style={styles.summaryLabel}>Recibiste en efectivo</Text>
                <Text style={[styles.summaryValue, { color: COLORS.orange }]}>{formatCurrency(groupNet)}</Text>
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
                  <Text style={[styles.priceValue, { color: COLORS.orange }]}>{formatCurrency(groupNet)}</Text>
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
                label={`✅ Confirmar que recibí ${formatCurrency(groupNet)} en efectivo`}
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
              <PriceRow label={`Precio pactado (${hoursToAdd}h)`} value={formatCurrency(groupNet)} bold />
            ) : (
              <>
                <PriceRow label="Tu precio neto por hora" value={formatCurrency(pricePerHour)} />
                <PriceRow label={`× ${hoursToAdd} hora${hoursToAdd > 1 ? 's' : ''}`} value={formatCurrency(groupNet)} bold />
              </>
            )}
            <View style={styles.divider} />
            <View style={styles.netRow}>
              <Text style={styles.netLabel}>Tu ganancia extra</Text>
              <Text style={styles.netValue}>{formatCurrency(groupEarnings)}</Text>
            </View>
          </View>

          {/* BOTONES */}
          <View style={{ marginTop: 24, marginBottom: 32, gap: 12 }}>
            {priceUnavailable && (
              <Text style={styles.priceUnavailableTx}>
                {priceLoading ? 'Calculando precio…' : 'Precio no disponible para esta reserva'}
              </Text>
            )}
            {balanceSufficient ? (
              // Tiene saldo — descuento automático
              <Button
                label={`Solicitar +${hoursToAdd}h (desde saldo del cliente)`}
                onPress={handleRequest}
                loading={loading || (!hasQuotePrices && loadingBalance)}
                disabled={priceUnavailable}
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
                  disabled={priceUnavailable}
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
    flex: 1, alignItems: 'center', paddingVertical: 12,
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border,
  },
  hoursBtnActive: { borderColor: COLORS.green, backgroundColor: COLORS.greenMuted },
  hoursNum: { fontFamily: FONTS.title, fontSize: 22, color: COLORS.muted2, marginBottom: 2 },
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
  priceUnavailableTx: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, textAlign: 'center' },

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
