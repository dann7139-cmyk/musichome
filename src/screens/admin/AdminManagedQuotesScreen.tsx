/**
 * AdminManagedQuotesScreen — "Cotizaciones que manejo" (modo conserjería).
 *
 * Lista las cotizaciones pendientes de grupos que todavía no manejan su
 * propia cuenta (groups.concierge_mode = true, sql/648). El admin llama
 * al grupo por teléfono, le pregunta su precio, y lo captura aquí —
 * admin_respond_quote (sql/648) hace el resto exactamente como si el
 * grupo mismo hubiera respondido.
 *
 * Compartida entre role='admin' (ve todos los países) y role='admin_ops'
 * (solo su país) — el RPC ya filtra, la pantalla no necesita saberlo.
 */
import { ArrowLeft, Phone, DollarSign, Calendar, MapPin } from 'lucide-react-native';
import React, { useCallback, useEffect, useState } from 'react';
import {
  ActivityIndicator,
  Alert,
  Linking,
  Modal,
  Pressable,
  RefreshControl,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  View,
} from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { supabase } from '../../config/supabase';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';

const call = (phone?: string | null) => { if (phone) Linking.openURL(`tel:${phone}`); };
const fecha = (d?: string | null) =>
  d ? new Date(String(d).substring(0, 10) + 'T12:00:00').toLocaleDateString('es-MX', { day: '2-digit', month: 'short', year: '2-digit' }) : '—';
const hora = (t?: string | null) => {
  if (!t) return null;
  const [h, m] = String(t).split(':').map(Number);
  return `${h % 12 || 12}:${String(m ?? 0).padStart(2, '0')} ${h >= 12 ? 'pm' : 'am'}`;
};

interface QuoteItem {
  quote_id: string;
  group_id: string;
  group_name: string;
  group_phone: string | null;
  group_genre: string | null;
  country: string;
  client_name: string | null;
  client_phone: string | null;
  event_date: string;
  event_time: string | null;
  duration_hours: number | null;
  event_address: string | null;
  event_municipio: string | null;
  event_estado: string | null;
  comments: string | null;
}

export default function AdminManagedQuotesScreen({ navigation }: any) {
  const [items, setItems] = useState<QuoteItem[]>([]);
  const [loading, setLoading] = useState(true);
  const [refreshing, setRefreshing] = useState(false);
  const [priceModal, setPriceModal] = useState<QuoteItem | null>(null);
  const [basePrice, setBasePrice] = useState('');
  const [travelCost, setTravelCost] = useState('');
  const [overtimeHourPrice, setOvertimeHourPrice] = useState('');
  const [notes, setNotes] = useState('');
  const [sending, setSending] = useState(false);

  const load = useCallback(async () => {
    const { data, error } = await supabase.rpc('admin_get_concierge_quotes', { p_limit: 100 });
    if (!error && data?.ok) setItems(data.items ?? []);
    setLoading(false);
    setRefreshing(false);
  }, []);

  useEffect(() => { load(); }, [load]);

  const onRefresh = () => { setRefreshing(true); load(); };

  const openPriceModal = (item: QuoteItem) => {
    setPriceModal(item);
    setBasePrice('');
    setTravelCost('');
    setOvertimeHourPrice('');
    setNotes('');
  };

  const sendPrice = async () => {
    if (!priceModal) return;
    const price = Number(basePrice.replace(',', '.'));
    if (!Number.isFinite(price) || price <= 0) {
      Alert.alert('Precio inválido', 'Escribe el precio neto que pidió el grupo por teléfono.');
      return;
    }
    setSending(true);
    const { data, error } = await supabase.rpc('admin_respond_quote', {
      p_quote_id: priceModal.quote_id,
      p_base_price: price,
      p_travel_cost: travelCost ? Number(travelCost.replace(',', '.')) : 0,
      p_overtime_hour_price: overtimeHourPrice ? Number(overtimeHourPrice.replace(',', '.')) : null,
      p_notes: notes.trim() || null,
    });
    setSending(false);
    if (error || !data?.ok) {
      Alert.alert('Error', error?.message ?? data?.error ?? 'No se pudo enviar la cotización.');
      return;
    }
    setPriceModal(null);
    setItems(prev => prev.filter(i => i.quote_id !== priceModal.quote_id));
    Alert.alert('✅ Enviada', `Se le mandó la cotización al cliente. Total con tu comisión: $${Number(data.total_amount).toLocaleString('es-MX')}.`);
  };

  return (
    <View style={s.container}>
      <SafeAreaView style={{ flex: 1 }}>
        <View style={s.header}>
          <Pressable style={s.backBtn} onPress={() => navigation.goBack()}>
            <ArrowLeft size={20} color={COLORS.text} />
          </Pressable>
          <Text style={s.headerTitle}>📞 Cotizaciones que manejo</Text>
          <View style={{ width: 40 }} />
        </View>

        {loading ? (
          <View style={s.center}><ActivityIndicator size="large" color={COLORS.green} /></View>
        ) : items.length === 0 ? (
          <View style={s.center}>
            <Text style={{ fontSize: 40 }}>📞</Text>
            <Text style={s.emptyTitle}>Nada pendiente</Text>
            <Text style={s.emptyText}>Aquí aparecen las cotizaciones de grupos en modo conserjería.</Text>
          </View>
        ) : (
          <ScrollView
            contentContainerStyle={{ padding: SPACING.xl, gap: 12 }}
            refreshControl={<RefreshControl refreshing={refreshing} onRefresh={onRefresh} tintColor={COLORS.green} />}
          >
            {items.map(item => (
              <View key={item.quote_id} style={s.card}>
                <View style={s.cardHeader}>
                  <Text style={s.groupName} numberOfLines={1}>{item.group_name}</Text>
                  <Text style={s.genre}>{item.group_genre ?? ''} · {item.country}</Text>
                </View>

                <Pressable style={s.callRow} onPress={() => call(item.group_phone)} disabled={!item.group_phone}>
                  <Phone size={13} color={COLORS.green} />
                  <Text style={s.callText}>Grupo: {item.group_phone ?? 'sin teléfono'}</Text>
                </Pressable>
                <Pressable style={s.callRow} onPress={() => call(item.client_phone)} disabled={!item.client_phone}>
                  <Phone size={13} color={COLORS.gold} />
                  <Text style={s.callText}>{item.client_name ?? 'Cliente'}: {item.client_phone ?? 'sin teléfono'}</Text>
                </Pressable>

                <View style={s.infoRow}>
                  <Calendar size={13} color={COLORS.muted2} />
                  <Text style={s.infoText}>
                    {fecha(item.event_date)}{item.event_time ? ` · ${hora(item.event_time)}` : ''}
                    {item.duration_hours ? ` · ${item.duration_hours}h` : ''}
                  </Text>
                </View>
                {(item.event_address || item.event_municipio) && (
                  <View style={s.infoRow}>
                    <MapPin size={13} color={COLORS.muted2} />
                    <Text style={s.infoText} numberOfLines={2}>
                      {[item.event_address, item.event_municipio, item.event_estado].filter(Boolean).join(', ')}
                    </Text>
                  </View>
                )}
                {item.comments ? <Text style={s.comments} numberOfLines={3}>"{item.comments}"</Text> : null}

                <Pressable style={s.priceBtn} onPress={() => openPriceModal(item)}>
                  <DollarSign size={16} color={COLORS.bg} />
                  <Text style={s.priceBtnText}>Poner precio</Text>
                </Pressable>
              </View>
            ))}
          </ScrollView>
        )}
      </SafeAreaView>

      <Modal visible={!!priceModal} transparent animationType="slide" onRequestClose={() => setPriceModal(null)}>
        <View style={s.overlay}>
          <View style={s.sheet}>
            <Text style={s.sheetTitle}>{priceModal?.group_name}</Text>
            <Text style={s.sheetHint}>Escribe lo que el grupo pidió por teléfono — el sistema le agrega la comisión de Daricefy automáticamente, igual que si el grupo lo hubiera puesto él mismo.</Text>

            <Text style={s.label}>Precio del grupo (neto)</Text>
            <TextInput
              style={s.input}
              value={basePrice}
              onChangeText={setBasePrice}
              placeholder="Ej. 9000"
              placeholderTextColor={COLORS.muted}
              keyboardType="numeric"
            />

            <Text style={s.label}>Costo de traslado (opcional)</Text>
            <TextInput
              style={s.input}
              value={travelCost}
              onChangeText={setTravelCost}
              placeholder="0"
              placeholderTextColor={COLORS.muted}
              keyboardType="numeric"
            />

            <Text style={s.label}>Precio por hora extra (neto, opcional)</Text>
            <TextInput
              style={s.input}
              value={overtimeHourPrice}
              onChangeText={setOvertimeHourPrice}
              placeholder="Ej. 500 — pregúntale al grupo cuánto cobra la hora extra"
              placeholderTextColor={COLORS.muted}
              keyboardType="numeric"
            />

            <Text style={s.label}>Nota interna (opcional)</Text>
            <TextInput
              style={[s.input, { height: 70, textAlignVertical: 'top' }]}
              value={notes}
              onChangeText={setNotes}
              placeholder="Ej. confirmó disponibilidad, pide anticipo..."
              placeholderTextColor={COLORS.muted}
              multiline
            />

            <View style={{ flexDirection: 'row', gap: 10, marginTop: 16 }}>
              <Pressable style={[s.modalBtn, s.modalBtnCancel]} onPress={() => setPriceModal(null)}>
                <Text style={s.modalBtnCancelText}>Cancelar</Text>
              </Pressable>
              <Pressable style={[s.modalBtn, s.modalBtnSend, sending && { opacity: 0.6 }]} onPress={sendPrice} disabled={sending}>
                {sending ? <ActivityIndicator size="small" color={COLORS.bg} /> : <Text style={s.modalBtnSendText}>Enviar al cliente</Text>}
              </Pressable>
            </View>
          </View>
        </View>
      </Modal>
    </View>
  );
}

const s = StyleSheet.create({
  container: { flex: 1, backgroundColor: COLORS.bg },
  center: { flex: 1, alignItems: 'center', justifyContent: 'center', gap: 8, padding: SPACING.xl },
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
  emptyTitle: { fontFamily: FONTS.title, fontSize: 18, color: COLORS.text, marginTop: 4 },
  emptyText: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2, textAlign: 'center' },

  card: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border, padding: 14, gap: 6,
  },
  cardHeader: { marginBottom: 4 },
  groupName: { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.text },
  genre: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2 },

  callRow: { flexDirection: 'row', alignItems: 'center', gap: 6 },
  callText: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.text },

  infoRow: { flexDirection: 'row', alignItems: 'flex-start', gap: 6, marginTop: 2 },
  infoText: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, flex: 1 },
  comments: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted, fontStyle: 'italic', marginTop: 2 },

  priceBtn: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 6,
    backgroundColor: COLORS.green, borderRadius: RADIUS.md, paddingVertical: 11, marginTop: 8,
  },
  priceBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.bg },

  overlay: { flex: 1, backgroundColor: 'rgba(0,0,0,0.5)', justifyContent: 'flex-end' },
  sheet: {
    backgroundColor: COLORS.card, borderTopLeftRadius: 24, borderTopRightRadius: 24,
    padding: SPACING.xl, paddingBottom: 40,
  },
  sheetTitle: { fontFamily: FONTS.title, fontSize: 18, color: COLORS.text, marginBottom: 6 },
  sheetHint: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, marginBottom: 16, lineHeight: 17 },
  label: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted2, marginBottom: 6 },
  input: {
    backgroundColor: COLORS.bg, borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: COLORS.border,
    paddingHorizontal: 14, paddingVertical: 12,
    fontFamily: FONTS.body, fontSize: 15, color: COLORS.text, marginBottom: 14,
  },
  modalBtn: { flex: 1, alignItems: 'center', justifyContent: 'center', paddingVertical: 13, borderRadius: RADIUS.md },
  modalBtnCancel: { backgroundColor: COLORS.card2, borderWidth: 1, borderColor: COLORS.border },
  modalBtnCancelText: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.muted2 },
  modalBtnSend: { backgroundColor: COLORS.green },
  modalBtnSendText: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.bg },
});
