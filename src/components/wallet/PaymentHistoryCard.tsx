import React, { useCallback, useEffect, useState } from 'react';
import { ActivityIndicator, Alert, Pressable, StyleSheet, Text, View } from 'react-native';
import * as WebBrowser from 'expo-web-browser';
import { supabase } from '../../config/supabase';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';

// sql/635 (2026-09-09) — antes de esto, la ÚNICA forma de ver el
// comprobante de un pago era tocando la notificación push en el momento
// en que llegaba (NotificationsScreen.tsx) — si el grupo la borraba o
// pasaba el tiempo, no había ningún lugar en la app para volver a verlo.
// Esta tarjeta lee group_get_payment_history() (acotada al propio grupo
// del lado del servidor) y deja reabrir cualquier comprobante viejo.
const KIND_LABEL: Record<string, { icon: string; label: string }> = {
  evento:  { icon: '🎤', label: 'Pago de evento' },
  propina: { icon: '🎁', label: 'Propinas' },
  retiro:  { icon: '🏦', label: 'Retiro' },
};

const money = (n: number | null | undefined) =>
  `$${Number(n ?? 0).toLocaleString('es-MX', { minimumFractionDigits: 2 })}`;

export default function PaymentHistoryCard() {
  const [loading, setLoading] = useState(true);
  const [items, setItems] = useState<any[]>([]);
  const [opening, setOpening] = useState<string | null>(null);

  const load = useCallback(async () => {
    const { data, error } = await supabase.rpc('group_get_payment_history', { p_limit: 30 });
    if (!error && (data as any)?.ok) setItems((data as any).items ?? []);
    setLoading(false);
  }, []);

  useEffect(() => { load(); }, [load]);

  const openReceipt = async (id: string, receiptPath: string | null | undefined) => {
    if (!receiptPath) { Alert.alert('Sin comprobante', 'Este movimiento no tiene un comprobante guardado.'); return; }
    setOpening(id);
    const { data, error } = await supabase.storage.from('refund-receipts').createSignedUrl(receiptPath, 3600);
    setOpening(null);
    if (error || !data?.signedUrl) { Alert.alert('Error', 'No se pudo abrir el comprobante.'); return; }
    await WebBrowser.openBrowserAsync(data.signedUrl);
  };

  if (loading) {
    return (
      <View style={s.card}>
        <ActivityIndicator color={COLORS.green} />
      </View>
    );
  }

  if (items.length === 0) return null; // sin historial todavía — no ocupar espacio en pantalla

  return (
    <View style={s.card}>
      <Text style={s.title}>🧾 Historial de pagos</Text>
      {items.map((it) => {
        const meta = KIND_LABEL[it.kind] ?? { icon: '💳', label: it.kind };
        return (
          <View key={it.id} style={s.row}>
            <View style={{ flex: 1 }}>
              <Text style={s.rowLabel} numberOfLines={1}>
                {meta.icon} {meta.label}{it.folio ? ` · ${it.folio}` : ''}
              </Text>
              <Text style={s.rowDate}>
                {new Date(it.created_at).toLocaleDateString('es-MX', { day: 'numeric', month: 'short', year: 'numeric' })}
              </Text>
            </View>
            <Text style={s.rowAmount}>{money(it.amount)}</Text>
            <Pressable style={s.receiptBtn} onPress={() => openReceipt(it.id, it.receipt_path)} disabled={opening === it.id}>
              {opening === it.id
                ? <ActivityIndicator size="small" color={COLORS.green} />
                : <Text style={s.receiptBtnText}>Ver</Text>}
            </Pressable>
          </View>
        );
      })}
    </View>
  );
}

const s = StyleSheet.create({
  card: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.xl,
    borderWidth: 1, borderColor: COLORS.border,
    padding: SPACING.lg, marginTop: 12, gap: 4,
  },
  title: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.text, marginBottom: 4 },
  row: {
    flexDirection: 'row', alignItems: 'center', gap: 8,
    paddingVertical: 8, borderTopWidth: 1, borderTopColor: COLORS.border,
  },
  rowLabel: { fontFamily: FONTS.bodyMedium, fontSize: 12.5, color: COLORS.text },
  rowDate: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted2, marginTop: 1 },
  rowAmount: { fontFamily: FONTS.bodySemiBold, fontSize: 12.5, color: COLORS.green },
  receiptBtn: {
    paddingHorizontal: 10, paddingVertical: 5, borderRadius: RADIUS.md,
    backgroundColor: COLORS.greenMuted, borderWidth: 1, borderColor: COLORS.green,
  },
  receiptBtnText: { fontFamily: FONTS.bodyMedium, fontSize: 11.5, color: COLORS.green },
});
