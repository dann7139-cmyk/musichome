import { AlertCircle, ArrowLeft, CheckCircle, Clock, XCircle } from 'lucide-react-native';
import React, { useEffect, useState } from 'react';
import {
  Alert,
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
import Badge from '../../components/ui/Badge';
import Particles from '../../components/ui/Particles';

export default function AdminDisputesScreen({ navigation }: any) {
  const [disputes, setDisputes] = useState<any[]>([]);
  const [refreshing, setRefreshing] = useState(false);
  const [selected, setSelected] = useState<any>(null);
  const [resolution, setResolution] = useState('');

  useEffect(() => { fetchDisputes(); }, []);

  const fetchDisputes = async () => {
    const { data } = await supabase
      .from('reservations')
      .select('*, group:groups(name), client:profiles(full_name), package:packages(name)')
      .eq('status', 'cancelled')
      .order('updated_at', { ascending: false })
      .limit(30);
    if (data) setDisputes(data);
  };

  const onRefresh = async () => {
    setRefreshing(true);
    await fetchDisputes();
    setRefreshing(false);
  };

  const handleResolve = async (reservation: any) => {
    Alert.alert('Resolver disputa', '¿Marcar esta reserva como resuelta?', [
      { text: 'Cancelar', style: 'cancel' },
      {
        text: 'Resolver',
        onPress: async () => {
          setSelected(null);
          Alert.alert('Resuelto ✅', 'La disputa fue marcada como resuelta.');
          fetchDisputes();
        },
      },
    ]);
  };

  return (
    <View style={styles.container}>
      <Particles />
      <SafeAreaView style={{ flex: 1 }}>
        <View style={styles.header}>
          <Pressable style={styles.backBtn} onPress={() => navigation.goBack()}>
            <ArrowLeft size={20} color={COLORS.text} />
          </Pressable>
          <Text style={styles.headerTitle}>Disputas</Text>
          <View style={{ width: 40 }} />
        </View>

        {/* SUMMARY */}
        <View style={styles.summaryRow}>
          <View style={styles.summaryCard}>
            <AlertCircle size={20} color={COLORS.red} />
            <Text style={[styles.summaryNum, { color: COLORS.red }]}>{disputes.length}</Text>
            <Text style={styles.summaryLabel}>Canceladas</Text>
          </View>
          <View style={styles.summaryCard}>
            <Clock size={20} color={COLORS.orange} />
            <Text style={[styles.summaryNum, { color: COLORS.orange }]}>
              {disputes.filter(d => !d.resolution_notes).length}
            </Text>
            <Text style={styles.summaryLabel}>Sin resolver</Text>
          </View>
          <View style={styles.summaryCard}>
            <CheckCircle size={20} color={COLORS.green} />
            <Text style={[styles.summaryNum, { color: COLORS.green }]}>
              {disputes.filter(d => d.resolution_notes).length}
            </Text>
            <Text style={styles.summaryLabel}>Resueltas</Text>
          </View>
        </View>

        <ScrollView
          showsVerticalScrollIndicator={false}
          contentContainerStyle={styles.list}
          refreshControl={<RefreshControl refreshing={refreshing} onRefresh={onRefresh} tintColor={COLORS.green} />}
        >
          {disputes.length === 0 ? (
            <View style={styles.empty}>
              <CheckCircle size={48} color={COLORS.muted} />
              <Text style={styles.emptyTitle}>Sin disputas activas</Text>
              <Text style={styles.emptyText}>No hay reservas canceladas en este momento</Text>
            </View>
          ) : (
            disputes.map(d => {
              const isOpen = selected?.id === d.id;
              return (
                <View key={d.id} style={styles.card}>
                  <Pressable style={styles.cardHeader} onPress={() => setSelected(isOpen ? null : d)}>
                    <View style={styles.cardLeft}>
                      <Text style={styles.groupName}>{d.group?.name ?? '—'}</Text>
                      <Text style={styles.clientName}>Cliente: {d.client?.full_name ?? '—'}</Text>
                      <Text style={styles.date}>
                        Evento: {d.event_date} • ${d.total_price?.toLocaleString()}
                      </Text>
                    </View>
                    <Badge label="Cancelada" variant="red" />
                  </Pressable>

                  {isOpen && (
                    <View style={styles.panel}>
                      <Text style={styles.panelLabel}>Resolución / notas</Text>
                      <TextInput
                        style={styles.textArea}
                        placeholder="Describe la resolución..."
                        placeholderTextColor={COLORS.muted}
                        value={resolution}
                        onChangeText={setResolution}
                        multiline
                        numberOfLines={3}
                      />
                      <View style={styles.panelBtns}>
                        <Pressable style={styles.resolveBtn} onPress={() => handleResolve(d)}>
                          <CheckCircle size={16} color={COLORS.black} />
                          <Text style={styles.resolveBtnText}>Marcar resuelta</Text>
                        </Pressable>
                        <Pressable style={styles.closeBtn} onPress={() => setSelected(null)}>
                          <XCircle size={16} color={COLORS.muted2} />
                        </Pressable>
                      </View>
                    </View>
                  )}
                </View>
              );
            })
          )}
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
  summaryRow: { flexDirection: 'row', gap: 10, padding: SPACING.xl },
  summaryCard: {
    flex: 1, alignItems: 'center', paddingVertical: 14,
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border, gap: 4,
  },
  summaryNum: { fontFamily: FONTS.title, fontSize: 22 },
  summaryLabel: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted2 },
  list: { paddingHorizontal: SPACING.xl, paddingBottom: 32, gap: 10 },
  card: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border, overflow: 'hidden',
  },
  cardHeader: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center', padding: SPACING.lg },
  cardLeft: { flex: 1 },
  groupName: { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.text, marginBottom: 3 },
  clientName: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2, marginBottom: 2 },
  date: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted },
  panel: {
    borderTopWidth: 1, borderTopColor: COLORS.border,
    padding: SPACING.lg, gap: 10,
  },
  panelLabel: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted2 },
  textArea: {
    backgroundColor: COLORS.card2, borderRadius: RADIUS.sm,
    borderWidth: 1, borderColor: COLORS.border,
    padding: 12, fontFamily: FONTS.body, fontSize: 14, color: COLORS.text,
    textAlignVertical: 'top',
  },
  panelBtns: { flexDirection: 'row', gap: 10, alignItems: 'center' },
  resolveBtn: {
    flex: 1, flexDirection: 'row', alignItems: 'center', justifyContent: 'center',
    gap: 8, paddingVertical: 12, borderRadius: RADIUS.md, backgroundColor: COLORS.green,
  },
  resolveBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.black },
  closeBtn: {
    width: 44, height: 44, borderRadius: RADIUS.md,
    backgroundColor: COLORS.card2, borderWidth: 1, borderColor: COLORS.border,
    alignItems: 'center', justifyContent: 'center',
  },
  empty: { alignItems: 'center', paddingTop: 60, gap: 12 },
  emptyTitle: { fontFamily: FONTS.title, fontSize: 20, color: COLORS.text },
  emptyText: { fontFamily: FONTS.body, fontSize: 14, color: COLORS.muted2, textAlign: 'center' },
});
