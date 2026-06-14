/**
 * ClientExtraHoursScreen — Vista del cliente para aprobar/rechazar horas extra.
 *
 * Muestra:
 * - Saldo disponible (lo que el cliente ya pagó, disponible para extras)
 * - Barra de progreso del saldo (verde → rojo conforme se consume)
 * - Desglose de la hora extra solicitada por el grupo
 * - Botón para aprobar (descuenta del saldo) o rechazar
 * - Si el saldo es insuficiente → opción de pago adicional o efectivo
 */
import { ArrowLeft, Banknote, CheckCircle, DollarSign, XCircle } from 'lucide-react-native';
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
import Particles from '../../components/ui/Particles';
import { formatCurrency, SERVICE_FEE_RATE } from '../../utils/calculations';
import { formatExtraHourRange, formatProposedAt } from '../../utils/extraHoursFormatter';

// ─── Barra de progreso de saldo ───────────────────────────────────────────────

function BalanceBar({ used, total }: { used: number; total: number }) {
  const ratio       = total > 0 ? Math.min(1, used / total) : 0;
  const remaining   = total - used;
  const pct         = Math.round(ratio * 100);
  const barColor    = ratio > 0.8 ? COLORS.red : ratio > 0.5 ? COLORS.orange : COLORS.green;

  return (
    <View style={bar.wrap}>
      <View style={bar.row}>
        <Text style={bar.label}>Saldo usado</Text>
        <Text style={bar.label}>Disponible</Text>
      </View>
      <View style={bar.track}>
        <View style={[bar.fill, { width: `${pct}%` as any, backgroundColor: barColor }]} />
      </View>
      <View style={bar.row}>
        <Text style={[bar.amount, { color: barColor }]}>{formatCurrency(used)}</Text>
        <Text style={[bar.amount, { color: COLORS.green }]}>{formatCurrency(remaining)}</Text>
      </View>
    </View>
  );
}

const bar = StyleSheet.create({
  wrap:   { marginBottom: 16 },
  row:    { flexDirection: 'row', justifyContent: 'space-between', marginBottom: 6 },
  label:  { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted },
  track:  { height: 8, backgroundColor: COLORS.card2, borderRadius: 4, overflow: 'hidden' },
  fill:   { height: '100%', borderRadius: 4 },
  amount: { fontFamily: FONTS.bodySemiBold, fontSize: 14 },
});

// ─── Pantalla principal ────────────────────────────────────────────────────────

export default function ClientExtraHoursScreen({ route, navigation }: any) {
  const { reservation, extraHour } = route.params;

  const [loading, setLoading]           = useState(false);
  const [rejectLoading, setRejectLoading] = useState(false);
  const [approved, setApproved]         = useState(false);
  const [rejected, setRejected]         = useState(false);

  // Saldo del cliente
  const [totalPaid, setTotalPaid]           = useState<number>(reservation.total_price ?? 0);
  const [serviceFee, setServiceFee]         = useState<number>(reservation.service_fee_amount ?? 0);
  const [clientBalance, setClientBalance]   = useState<number | null>(null);
  const [loadingBalance, setLoadingBalance] = useState(true);

  useEffect(() => { fetchBalance(); }, []);

  const fetchBalance = async () => {
    setLoadingBalance(true);
    // Calcular saldo: total_paid - service_fee (valor inicial)
    const fee     = reservation.service_fee_amount ?? Math.round((reservation.total_price ?? 0) * 0.10);
    const initial = (reservation.total_price ?? 0) - fee;
    setServiceFee(fee);

    // Saldo actual (descontando extras ya aprobadas)
    const { data } = await supabase.rpc('get_client_available_balance', {
      p_reservation_id: reservation.id,
    });
    setClientBalance(typeof data === 'number' ? data : initial);
    setLoadingBalance(false);
  };

  const extraTotal   = extraHour.total_extra_cost ?? 0;
  const isCash       = extraHour.is_cash_payment ?? false;
  const hoursAdded   = extraHour.hours_added ?? 1;
  const balanceSuff  = clientBalance !== null && clientBalance >= extraTotal;
  const usedBalance  = totalPaid - serviceFee - (clientBalance ?? 0);

  // Contexto temporal
  const timeRange  = formatExtraHourRange(
    reservation.event_time,
    reservation.hours ?? reservation.duration ?? 0,
    reservation.extra_hours_added ?? 0,
    hoursAdded,
  );
  const proposedAt = formatProposedAt(extraHour.created_at);

  // ── Aprobar hora extra ────────────────────────────────────────────────────

  const handleApprove = async () => {
    if (isCash) {
      Alert.alert(
        '💵 Pago en efectivo',
        `El grupo recibirá ${formatCurrency(extraTotal)} directamente de ti. ¿Confirmas?`,
        [
          { text: 'Cancelar', style: 'cancel' },
          {
            text: 'Confirmar',
            onPress: async () => {
              setLoading(true);
              // RPC atómica: marca paid en una sola transacción
              const { error } = await supabase.rpc('approve_extra_hour_payment_atomic', {
                p_extra_hour_id: extraHour.id,
              });
              setLoading(false);
              if (error) Alert.alert('Error', error.message);
              else setApproved(true);
            },
          },
        ]
      );
      return;
    }

    if (!balanceSuff) {
      Alert.alert(
        'Saldo insuficiente',
        `Tu saldo disponible es ${formatCurrency(clientBalance ?? 0)} y la hora extra cuesta ${formatCurrency(extraTotal)}.\n\nContacta al grupo para acordar el pago.`
      );
      return;
    }

    setLoading(true);
    // RPC atómica: marca paid Y descuenta saldo en una sola transacción
    // Previene race conditions y garantiza consistencia financiera.
    const { error } = await supabase.rpc('approve_extra_hour_payment_atomic', {
      p_extra_hour_id: extraHour.id,
    });
    setLoading(false);

    if (error) Alert.alert('Error', error.message);
    else setApproved(true);
  };

  // ── Rechazar hora extra ──────────────────────────────────────────────────

  const handleReject = () => {
    Alert.alert(
      'Rechazar hora extra',
      '¿Estás seguro de que no quieres agregar esta hora extra?\n\nEl grupo continuará hasta cumplir el tiempo contratado.',
      [
        { text: 'Cancelar', style: 'cancel' },
        {
          text: 'Rechazar',
          style: 'destructive',
          onPress: async () => {
            setRejectLoading(true);
            await supabase
              .from('extra_hours')
              .update({ status: 'rejected' })
              .eq('id', extraHour.id);
            setRejectLoading(false);
            setRejected(true);
          },
        },
      ]
    );
  };

  // ── RENDER: Aprobada ──────────────────────────────────────────────────────
  if (approved) {
    return (
      <View style={styles.container}>
        <Particles />
        <SafeAreaView style={{ flex: 1, alignItems: 'center', justifyContent: 'center', padding: SPACING.xl }}>
          <View style={styles.resultCard}>
            <CheckCircle size={60} color={COLORS.green} />
            <Text style={styles.resultTitle}>¡Hora extra aprobada!</Text>
            <Text style={styles.resultDesc}>
              {isCash
                ? `Paga ${formatCurrency(extraTotal)} directamente al grupo en efectivo.`
                : `Se descontaron ${formatCurrency(extraTotal)} de tu saldo disponible.\n\nSaldo restante: ${formatCurrency((clientBalance ?? 0) - extraTotal)}`}
            </Text>
            <Button label="Entendido" onPress={() => navigation.goBack()} size="lg" />
          </View>
        </SafeAreaView>
      </View>
    );
  }

  // ── RENDER: Rechazada ─────────────────────────────────────────────────────
  if (rejected) {
    return (
      <View style={styles.container}>
        <Particles />
        <SafeAreaView style={{ flex: 1, alignItems: 'center', justifyContent: 'center', padding: SPACING.xl }}>
          <View style={styles.resultCard}>
            <XCircle size={60} color={COLORS.red} />
            <Text style={styles.resultTitle}>Hora extra rechazada</Text>
            <Text style={styles.resultDesc}>
              El evento continuará hasta cumplir el tiempo contratado originalmente.
            </Text>
            <Button label="Volver" onPress={() => navigation.goBack()} size="lg" />
          </View>
        </SafeAreaView>
      </View>
    );
  }

  // ── RENDER PRINCIPAL ──────────────────────────────────────────────────────
  return (
    <View style={styles.container}>
      <Particles />
      <SafeAreaView style={{ flex: 1 }}>
        <View style={styles.header}>
          <Pressable style={styles.backBtn} onPress={() => navigation.goBack()}>
            <ArrowLeft size={20} color={COLORS.text} />
          </Pressable>
          <Text style={styles.headerTitle}>
            {isCash ? 'Pago en Efectivo' : 'Agregar Horas Extra'}
          </Text>
          <View style={{ width: 40 }} />
        </View>

        <ScrollView showsVerticalScrollIndicator={false} contentContainerStyle={styles.scroll}>

          {/* TU SALDO DISPONIBLE */}
          {!loadingBalance && !isCash && (
            <View style={styles.balanceCard}>
              <View style={styles.balanceHeader}>
                <DollarSign size={18} color={COLORS.green} />
                <Text style={styles.balanceTitle}>Tu Saldo Disponible</Text>
              </View>

              <View style={styles.balanceRows}>
                <View style={styles.balanceRow}>
                  <Text style={styles.balanceRowLabel}>Pagaste inicialmente</Text>
                  <Text style={styles.balanceRowValue}>{formatCurrency(totalPaid)}</Text>
                </View>
                <View style={styles.balanceRow}>
                  <Text style={styles.balanceRowLabel}>Tarifa de servicio</Text>
                  <Text style={[styles.balanceRowValue, { color: COLORS.muted }]}>-{formatCurrency(serviceFee)}</Text>
                </View>
                <View style={styles.balanceDivider} />
                <View style={styles.balanceRow}>
                  <Text style={[styles.balanceRowLabel, { fontFamily: FONTS.bodySemiBold }]}>
                    Saldo para horas extra
                  </Text>
                  <Text style={[styles.balanceRowValue, { color: COLORS.green, fontFamily: FONTS.title, fontSize: 20 }]}>
                    {formatCurrency(totalPaid - serviceFee)}
                  </Text>
                </View>
              </View>

              {/* Barra de progreso de saldo */}
              <BalanceBar
                used={usedBalance > 0 ? usedBalance : 0}
                total={totalPaid - serviceFee}
              />

              <Text style={styles.balanceNote}>
                ℹ️ No se hará ningún cargo adicional a tu tarjeta. Todo se descuenta del pago inicial.
              </Text>
            </View>
          )}

          {/* SOLICITUD DEL GRUPO */}
          <View style={styles.requestCard}>
            <Text style={styles.requestTitle}>
              {isCash ? '💵 El grupo solicita pago en efectivo' : `➕ +${hoursAdded} hora${hoursAdded > 1 ? 's' : ''} adicional${hoursAdded > 1 ? 'es' : ''}`}
            </Text>

            <View style={styles.requestDetails}>
              <View style={styles.requestRow}>
                <Text style={styles.requestLabel}>
                  {isCash ? 'Monto solicitado' : `+${hoursAdded} hora${hoursAdded > 1 ? 's' : ''} adicional${hoursAdded > 1 ? 'es' : ''}`}
                </Text>
                <Text style={styles.requestAmount}>{formatCurrency(extraTotal)}</Text>
              </View>

              {timeRange && (
                <View style={styles.requestRow}>
                  <Text style={styles.requestLabel}>Horario</Text>
                  <Text style={[styles.requestLabel, { color: COLORS.text }]}>
                    {timeRange.from} → {timeRange.to}
                  </Text>
                </View>
              )}

              {proposedAt && (
                <View style={styles.requestRow}>
                  <Text style={styles.requestLabel}>Propuesta</Text>
                  <Text style={[styles.requestLabel, { color: COLORS.muted }]}>{proposedAt}</Text>
                </View>
              )}

              {!isCash && (
                <View style={styles.requestRow}>
                  <Text style={styles.requestLabel}>Después de esta hora extra</Text>
                  <Text style={[styles.requestLabel, { color: COLORS.muted }]}>
                    Saldo restante: {formatCurrency((clientBalance ?? 0) - extraTotal)}
                  </Text>
                </View>
              )}
            </View>

            {isCash ? (
              <View style={styles.cashInfo}>
                <Banknote size={18} color={COLORS.orange} />
                <Text style={styles.cashInfoText}>
                  Paga directamente al grupo en efectivo. La app solo registra la transacción.
                </Text>
              </View>
            ) : !balanceSuff ? (
              <View style={styles.insufficientWarn}>
                <Text style={styles.insufficientTitle}>⚠️ Saldo Insuficiente</Text>
                <Text style={styles.insufficientDesc}>
                  Tu saldo disponible ({formatCurrency(clientBalance ?? 0)}) no cubre esta hora extra ({formatCurrency(extraTotal)}).{'\n\n'}
                  Habla con el grupo para acordar el pago en efectivo.
                </Text>
              </View>
            ) : (
              <View style={styles.balanceOkBanner}>
                <CheckCircle size={16} color={COLORS.green} />
                <Text style={styles.balanceOkText}>
                  Tienes saldo suficiente. El descuento es automático, sin cargo a tu tarjeta.
                </Text>
              </View>
            )}
          </View>

          {/* AVISO BASE */}
          <View style={styles.baseNotice}>
            <Text style={styles.baseNoticeText}>
              ⚠️ El evento base ya está incluido. Las horas extra son adicionales al contrato original.
            </Text>
          </View>

          {/* BOTONES */}
          <View style={{ marginTop: 8, marginBottom: 32, gap: 12 }}>
            {isCash ? (
              <Button
                label={`💵 Confirmar pago de ${formatCurrency(extraTotal)} en efectivo`}
                onPress={handleApprove}
                loading={loading}
                size="lg"
              />
            ) : balanceSuff ? (
              <Button
                label={`✅ Confirmar y descontar de mi saldo`}
                onPress={handleApprove}
                loading={loading}
                size="lg"
              />
            ) : (
              <Button
                label="Hablar con el grupo"
                onPress={() => navigation.goBack()}
                size="lg"
              />
            )}
            <Button
              label="Rechazar hora extra"
              onPress={handleReject}
              loading={rejectLoading}
              variant="ghost"
              size="lg"
            />
          </View>
        </ScrollView>
      </SafeAreaView>
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

  // Balance card
  balanceCard: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.xl,
    borderWidth: 1, borderColor: COLORS.border, padding: SPACING.xl, marginBottom: 20,
  },
  balanceHeader: { flexDirection: 'row', alignItems: 'center', gap: 10, marginBottom: 16 },
  balanceTitle:  { fontFamily: FONTS.title, fontSize: 17, color: COLORS.text },
  balanceRows:   { gap: 8, marginBottom: 16 },
  balanceRow:    { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center', paddingVertical: 6 },
  balanceRowLabel: { fontFamily: FONTS.body, fontSize: 14, color: COLORS.muted2 },
  balanceRowValue: { fontFamily: FONTS.bodyMedium, fontSize: 14, color: COLORS.text },
  balanceDivider: { height: 1, backgroundColor: COLORS.border, marginVertical: 4 },
  balanceNote: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted, marginTop: 4 },

  // Request card
  requestCard: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.xl,
    borderWidth: 1, borderColor: COLORS.border, padding: SPACING.xl, marginBottom: 16, gap: 16,
  },
  requestTitle:  { fontFamily: FONTS.title, fontSize: 18, color: COLORS.text },
  requestDetails: {
    backgroundColor: COLORS.card2, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border, padding: SPACING.lg, gap: 8,
  },
  requestRow:    { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center' },
  requestLabel:  { fontFamily: FONTS.body, fontSize: 14, color: COLORS.muted2 },
  requestAmount: { fontFamily: FONTS.title, fontSize: 24, color: COLORS.green },

  cashInfo: {
    flexDirection: 'row', alignItems: 'flex-start', gap: 12,
    backgroundColor: 'rgba(245,158,11,0.08)', borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: 'rgba(245,158,11,0.35)', padding: SPACING.lg,
  },
  cashInfoText: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2, flex: 1, lineHeight: 20 },

  insufficientWarn: {
    backgroundColor: 'rgba(239,68,68,0.06)', borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: 'rgba(239,68,68,0.3)', padding: SPACING.lg,
  },
  insufficientTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.red, marginBottom: 8 },
  insufficientDesc:  { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2, lineHeight: 20 },

  balanceOkBanner: {
    flexDirection: 'row', alignItems: 'center', gap: 10,
    backgroundColor: 'rgba(0,230,118,0.08)', borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.3)', padding: SPACING.lg,
  },
  balanceOkText: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.green, flex: 1 },

  baseNotice: {
    backgroundColor: 'rgba(245,158,11,0.06)', borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: 'rgba(245,158,11,0.25)', padding: 12, marginBottom: 8,
  },
  baseNoticeText: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2 },

  // Result screens
  resultCard: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.xl,
    borderWidth: 1, borderColor: COLORS.border, padding: SPACING.xl,
    alignItems: 'center', gap: 16, width: '100%',
  },
  resultTitle: { fontFamily: FONTS.title, fontSize: 22, color: COLORS.text, textAlign: 'center' },
  resultDesc:  { fontFamily: FONTS.body, fontSize: 14, color: COLORS.muted2, textAlign: 'center', lineHeight: 22 },
});
