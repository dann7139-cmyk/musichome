import React from 'react';
import { StyleSheet, Text, View } from 'react-native';
import { COLORS, FONTS, RADIUS } from '../../config/theme';
import { formatCurrency } from '../../utils/calculations';

interface Props {
  totalPrice: number;
  groupEarnings: number;
  memberCount?: number;
  currencySymbol?: string;
  commissionAmount?: number;
  durationHours?: number;
  // legacy – ignored
  commission?: number;
  extraHours?: number;
  commissionRate?: number;
}

export default function FinancialBreakdown({
  totalPrice,
  groupEarnings,
  memberCount,
  currencySymbol = '$',
  commissionAmount,
  durationHours,
}: Props) {
  const perMember = memberCount && memberCount > 0
    ? groupEarnings / memberCount
    : null;

  return (
    <View style={styles.container}>
      <Text style={styles.title}>Desglose Financiero</Text>

      <View style={styles.divider} />

      <Row label="Total del evento" value={formatCurrency(totalPrice, currencySymbol)} />

      {commissionAmount != null && durationHours != null && (
        <Row
          label={`Comisión de gestión ($200 × ${durationHours}h)`}
          value={`−${formatCurrency(commissionAmount, currencySymbol)}`}
          valueColor={COLORS.muted2}
        />
      )}

      <View style={styles.divider} />

      <View style={styles.netRow}>
        <Text style={styles.netLabel}>GANANCIA NETA</Text>
        <Text style={styles.netValue}>{formatCurrency(groupEarnings, currencySymbol)}</Text>
      </View>

      {perMember !== null && (
        <View style={styles.perMemberRow}>
          <Text style={styles.perMemberLabel}>Por integrante</Text>
          <Text style={styles.perMemberValue}>{formatCurrency(perMember, currencySymbol)}</Text>
        </View>
      )}
    </View>
  );
}

function Row({ label, value, valueColor }: { label: string; value: string; valueColor?: string }) {
  return (
    <View style={styles.row}>
      <Text style={styles.rowLabel}>{label}</Text>
      <Text style={[styles.rowValue, valueColor ? { color: valueColor } : undefined]}>{value}</Text>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    backgroundColor: COLORS.card,
    borderRadius: RADIUS.lg,
    borderWidth: 1,
    borderColor: COLORS.border,
    padding: 20,
  },
  title: {
    fontFamily: FONTS.bodySemiBold,
    fontSize: 14,
    color: COLORS.muted2,
    marginBottom: 14,
    textTransform: 'uppercase',
    letterSpacing: 1,
  },
  divider: {
    height: 1,
    backgroundColor: COLORS.border,
    marginVertical: 12,
  },
  row: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    marginBottom: 4,
  },
  rowLabel: {
    fontFamily: FONTS.body,
    fontSize: 14,
    color: COLORS.muted2,
  },
  rowValue: {
    fontFamily: FONTS.bodyMedium,
    fontSize: 14,
    color: COLORS.text,
  },
  netRow: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
    backgroundColor: 'rgba(0,230,118,0.07)',
    borderRadius: RADIUS.md,
    borderWidth: 1,
    borderColor: 'rgba(0,230,118,0.22)',
    paddingHorizontal: 12,
    paddingVertical: 10,
  },
  netLabel: {
    fontFamily: FONTS.bodyMedium,
    fontSize: 13,
    color: COLORS.green,
  },
  netValue: {
    fontFamily: FONTS.bodySemiBold,
    fontSize: 17,
    color: COLORS.green,
  },
  perMemberRow: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
    marginTop: 8,
    paddingTop: 8,
    borderTopWidth: 1,
    borderTopColor: COLORS.border,
  },
  perMemberLabel: {
    fontFamily: FONTS.body,
    fontSize: 12,
    color: COLORS.muted,
  },
  perMemberValue: {
    fontFamily: FONTS.bodySemiBold,
    fontSize: 13,
    color: COLORS.green,
  },
});
