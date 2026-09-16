/**
 * AdminCrossBorderScreen — demanda de grupos entre países (sql/657/658).
 *
 * Cada vez que un cliente pide cotización para un evento en un país
 * DISTINTO al del grupo (comparado contra dónde es el EVENTO, no de dónde
 * es el cliente), queda registrado aquí — con o sin visa activada. Sirve
 * de prueba documentada de demanda real para un trámite de visa de trabajo
 * a futuro: cada tarjeta se puede abrir para ver QUIÉN pidió cada evento
 * (nombre/teléfono/fecha/dirección), y copiarlo como texto para un trámite.
 *
 * Compartida entre role='admin' (todos los países) y role='admin_ops'
 * (el RPC ya filtra al suyo).
 */
import { ArrowLeft, Plane, Phone, Copy, Check, X } from 'lucide-react-native';
import * as Clipboard from 'expo-clipboard';
import React, { useCallback, useEffect, useState } from 'react';
import {
  ActivityIndicator,
  Linking,
  Modal,
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

interface ReportItem {
  group_id: string;
  group_name: string;
  group_country: string;
  has_work_visa: boolean;
  event_country: string;
  total_requests: number;
  blocked_requests: number;
  fulfilled_requests: number;
  last_request_at: string;
}

interface DetailItem {
  quote_id: string;
  was_blocked: boolean;
  client_name: string | null;
  client_phone: string | null;
  event_date: string;
  event_time: string | null;
  event_address: string | null;
  event_municipio: string | null;
  event_estado: string | null;
  created_at: string;
}

const fecha = (d?: string | null) =>
  d ? new Date(d).toLocaleDateString('es-MX', { day: '2-digit', month: 'short', year: '2-digit' }) : '—';
const call = (phone?: string | null) => { if (phone) Linking.openURL(`tel:${phone}`); };

export default function AdminCrossBorderScreen({ navigation }: any) {
  const [items, setItems] = useState<ReportItem[]>([]);
  const [loading, setLoading] = useState(true);
  const [refreshing, setRefreshing] = useState(false);

  const [detailTarget, setDetailTarget] = useState<ReportItem | null>(null);
  const [detailItems, setDetailItems] = useState<DetailItem[]>([]);
  const [detailLoading, setDetailLoading] = useState(false);
  const [copied, setCopied] = useState(false);

  const load = useCallback(async () => {
    const { data, error } = await supabase.rpc('admin_get_cross_border_report', { p_limit: 200 });
    if (!error && data?.ok) setItems(data.items ?? []);
    setLoading(false);
    setRefreshing(false);
  }, []);

  useEffect(() => { load(); }, [load]);

  const onRefresh = () => { setRefreshing(true); load(); };

  const openDetail = async (item: ReportItem) => {
    setDetailTarget(item);
    setDetailItems([]);
    setDetailLoading(true);
    setCopied(false);
    const { data, error } = await supabase.rpc('admin_get_cross_border_detail', {
      p_group_id: item.group_id,
      p_event_country: item.event_country,
      p_limit: 100,
    });
    if (!error && data?.ok) setDetailItems(data.items ?? []);
    setDetailLoading(false);
  };

  const copyDetailAsText = async () => {
    if (!detailTarget) return;
    const lines = [
      `${detailTarget.group_name} — solicitudes de ${detailTarget.group_country} a ${detailTarget.event_country}`,
      '',
      ...detailItems.map((d, i) =>
        `${i + 1}. ${d.client_name ?? 'Cliente sin nombre'} · ${d.client_phone ?? 'sin teléfono'} · ${fecha(d.event_date)} · ${[d.event_address, d.event_municipio, d.event_estado].filter(Boolean).join(', ')} · ${d.was_blocked ? 'BLOQUEADA (sin visa)' : 'cumplida'}`
      ),
    ];
    await Clipboard.setStringAsync(lines.join('\n'));
    setCopied(true);
    setTimeout(() => setCopied(false), 2500);
  };

  const totalBlocked = items.reduce((s, i) => s + i.blocked_requests, 0);

  return (
    <View style={s.container}>
      <SafeAreaView style={{ flex: 1 }}>
        <View style={s.header}>
          <Pressable style={s.backBtn} onPress={() => navigation.goBack()}>
            <ArrowLeft size={20} color={COLORS.text} />
          </Pressable>
          <Text style={s.headerTitle}>✈️ Demanda entre países</Text>
          <View style={{ width: 40 }} />
        </View>

        {loading ? (
          <View style={s.center}><ActivityIndicator size="large" color={COLORS.green} /></View>
        ) : items.length === 0 ? (
          <View style={s.center}>
            <Plane size={40} color={COLORS.muted} />
            <Text style={s.emptyTitle}>Nada todavía</Text>
            <Text style={s.emptyText}>Aquí aparece cada vez que un cliente pida un grupo para un evento en otro país.</Text>
          </View>
        ) : (
          <ScrollView
            contentContainerStyle={{ padding: SPACING.xl, gap: 12 }}
            refreshControl={<RefreshControl refreshing={refreshing} onRefresh={onRefresh} tintColor={COLORS.green} />}
          >
            {totalBlocked > 0 && (
              <View style={s.summaryCard}>
                <Text style={s.summaryText}>
                  📋 {totalBlocked} solicitud{totalBlocked !== 1 ? 'es' : ''} de fuera de su país no se pudo{totalBlocked !== 1 ? 'ieron' : ''} cumplir por falta de visa — evidencia real de demanda para un futuro trámite.
                </Text>
              </View>
            )}
            {items.map(item => (
              <Pressable key={`${item.group_id}-${item.event_country}`} style={s.card} onPress={() => openDetail(item)}>
                <View style={s.cardHeader}>
                  <Text style={s.groupName} numberOfLines={1}>{item.group_name}</Text>
                  <View style={[s.visaPill, item.has_work_visa ? s.visaPillOn : s.visaPillOff]}>
                    <Text style={s.visaPillText}>{item.has_work_visa ? '🛂 Con visa' : '🚫 Sin visa'}</Text>
                  </View>
                </View>
                <Text style={s.route}>{item.group_country} → {item.event_country}</Text>

                <View style={s.statsRow}>
                  <View style={s.stat}>
                    <Text style={s.statNum}>{item.total_requests}</Text>
                    <Text style={s.statLabel}>Total</Text>
                  </View>
                  <View style={s.stat}>
                    <Text style={[s.statNum, { color: item.blocked_requests > 0 ? '#EF5350' : COLORS.text }]}>{item.blocked_requests}</Text>
                    <Text style={s.statLabel}>Bloqueadas</Text>
                  </View>
                  <View style={s.stat}>
                    <Text style={[s.statNum, { color: COLORS.green }]}>{item.fulfilled_requests}</Text>
                    <Text style={s.statLabel}>Cumplidas</Text>
                  </View>
                </View>
                <Text style={s.lastReq}>Última solicitud: {fecha(item.last_request_at)} · toca para ver quién las pidió</Text>
              </Pressable>
            ))}
          </ScrollView>
        )}
      </SafeAreaView>

      {/* Detalle: quién pidió cada evento — la prueba documentada real */}
      <Modal visible={!!detailTarget} transparent animationType="slide" onRequestClose={() => setDetailTarget(null)}>
        <View style={s.overlay}>
          <View style={s.sheet}>
            <View style={s.sheetHeader}>
              <Text style={s.sheetTitle} numberOfLines={2}>{detailTarget?.group_name}</Text>
              <Pressable onPress={() => setDetailTarget(null)}>
                <X size={20} color={COLORS.muted2} />
              </Pressable>
            </View>
            <Text style={s.sheetSub}>{detailTarget?.group_country} → {detailTarget?.event_country}</Text>

            <Pressable style={s.copyAllBtn} onPress={copyDetailAsText} disabled={detailLoading || detailItems.length === 0}>
              {copied
                ? <><Check size={14} color={COLORS.green} /><Text style={s.copyAllBtnText}>Copiado</Text></>
                : <><Copy size={14} color={COLORS.text} /><Text style={s.copyAllBtnText}>Copiar todo como texto</Text></>}
            </Pressable>

            {detailLoading ? (
              <ActivityIndicator color={COLORS.green} style={{ marginVertical: 20 }} />
            ) : (
              <ScrollView style={{ maxHeight: 420 }} contentContainerStyle={{ gap: 10, paddingVertical: 8 }}>
                {detailItems.map((d, i) => (
                  <View key={d.quote_id} style={s.detailCard}>
                    <View style={s.detailCardHeader}>
                      <Text style={s.detailClientName} numberOfLines={1}>{i + 1}. {d.client_name ?? 'Cliente sin nombre'}</Text>
                      <View style={[s.visaPill, d.was_blocked ? s.visaPillOff : s.visaPillOn]}>
                        <Text style={s.visaPillText}>{d.was_blocked ? 'Bloqueada' : 'Cumplida'}</Text>
                      </View>
                    </View>
                    <Pressable style={s.detailPhoneRow} onPress={() => call(d.client_phone)} disabled={!d.client_phone}>
                      <Phone size={12} color={COLORS.green} />
                      <Text style={s.detailPhoneText}>{d.client_phone ?? 'sin teléfono'}</Text>
                    </Pressable>
                    <Text style={s.detailLine}>{fecha(d.event_date)}{d.event_time ? ` · ${d.event_time}` : ''}</Text>
                    <Text style={s.detailLine} numberOfLines={2}>
                      {[d.event_address, d.event_municipio, d.event_estado].filter(Boolean).join(', ')}
                    </Text>
                  </View>
                ))}
              </ScrollView>
            )}
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
  headerTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.text },

  emptyTitle: { fontFamily: FONTS.title, fontSize: 18, color: COLORS.text, marginTop: 4 },
  emptyText: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2, textAlign: 'center' },

  summaryCard: {
    backgroundColor: 'rgba(239,83,80,0.10)', borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: 'rgba(239,83,80,0.3)', padding: 14,
  },
  summaryText: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.text, lineHeight: 17 },

  card: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border, padding: 14, gap: 6,
  },
  cardHeader: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' },
  groupName: { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.text, flex: 1, marginRight: 8 },
  visaPill: { paddingHorizontal: 10, paddingVertical: 4, borderRadius: RADIUS.full },
  visaPillOn: { backgroundColor: COLORS.greenMuted },
  visaPillOff: { backgroundColor: 'rgba(239,83,80,0.15)' },
  visaPillText: { fontFamily: FONTS.bodyMedium, fontSize: 10, color: COLORS.text },
  route: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2 },

  statsRow: { flexDirection: 'row', gap: 20, marginTop: 6 },
  stat: { alignItems: 'center' },
  statNum: { fontFamily: FONTS.title, fontSize: 20, color: COLORS.text },
  statLabel: { fontFamily: FONTS.body, fontSize: 10, color: COLORS.muted2, marginTop: 2 },

  lastReq: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted, marginTop: 4 },

  overlay: { flex: 1, backgroundColor: 'rgba(0,0,0,0.5)', justifyContent: 'flex-end' },
  sheet: {
    backgroundColor: COLORS.card, borderTopLeftRadius: 24, borderTopRightRadius: 24,
    padding: SPACING.xl, paddingBottom: 40, maxHeight: '85%',
  },
  sheetHeader: { flexDirection: 'row', alignItems: 'flex-start', justifyContent: 'space-between', gap: 10 },
  sheetTitle: { fontFamily: FONTS.title, fontSize: 18, color: COLORS.text, flex: 1 },
  sheetSub: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, marginTop: 2, marginBottom: 12 },

  copyAllBtn: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 8,
    backgroundColor: COLORS.card2, borderWidth: 1, borderColor: COLORS.border,
    borderRadius: RADIUS.md, paddingVertical: 11, marginBottom: 8,
  },
  copyAllBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.text },

  detailCard: {
    backgroundColor: COLORS.card2, borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: COLORS.border, padding: 12, gap: 4,
  },
  detailCardHeader: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', gap: 8 },
  detailClientName: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.text, flex: 1 },
  detailPhoneRow: { flexDirection: 'row', alignItems: 'center', gap: 6 },
  detailPhoneText: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.text },
  detailLine: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2 },
});
