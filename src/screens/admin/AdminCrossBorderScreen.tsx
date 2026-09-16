/**
 * AdminCrossBorderScreen — demanda de grupos entre países (sql/657).
 *
 * Cada vez que un cliente pide cotización para un evento en un país
 * DISTINTO al del grupo (comparado contra dónde es el EVENTO, no de dónde
 * es el cliente), queda registrado aquí — con o sin visa activada. Sirve
 * de prueba documentada de demanda real para un trámite de visa de trabajo
 * a futuro.
 *
 * Compartida entre role='admin' (todos los países) y role='admin_ops'
 * (el RPC ya filtra al suyo).
 */
import { ArrowLeft, Plane } from 'lucide-react-native';
import React, { useCallback, useEffect, useState } from 'react';
import {
  ActivityIndicator,
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

const fecha = (d?: string | null) =>
  d ? new Date(d).toLocaleDateString('es-MX', { day: '2-digit', month: 'short', year: '2-digit' }) : '—';

export default function AdminCrossBorderScreen({ navigation }: any) {
  const [items, setItems] = useState<ReportItem[]>([]);
  const [loading, setLoading] = useState(true);
  const [refreshing, setRefreshing] = useState(false);

  const load = useCallback(async () => {
    const { data, error } = await supabase.rpc('admin_get_cross_border_report', { p_limit: 200 });
    if (!error && data?.ok) setItems(data.items ?? []);
    setLoading(false);
    setRefreshing(false);
  }, []);

  useEffect(() => { load(); }, [load]);

  const onRefresh = () => { setRefreshing(true); load(); };

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
              <View key={`${item.group_id}-${item.event_country}`} style={s.card}>
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
                <Text style={s.lastReq}>Última solicitud: {fecha(item.last_request_at)}</Text>
              </View>
            ))}
          </ScrollView>
        )}
      </SafeAreaView>
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
});
