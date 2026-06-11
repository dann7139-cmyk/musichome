import { ArrowLeft, Calendar, DollarSign, TrendingUp } from 'lucide-react-native';
import React, { useEffect, useState } from 'react';
import {
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
import Particles from '../../components/ui/Particles';

const MONTHS = ['Ene','Feb','Mar','Abr','May','Jun','Jul','Ago','Sep','Oct','Nov','Dic'];

export default function GroupEarningsScreen({ navigation }: any) {
  const [reservations, setReservations] = useState<any[]>([]);
  const [selectedMonth, setSelectedMonth] = useState(new Date().getMonth());
  const [selectedYear] = useState(new Date().getFullYear());
  const [refreshing, setRefreshing] = useState(false);

  useEffect(() => { fetchEarnings(); }, []);

  const onRefresh = async () => { setRefreshing(true); await fetchEarnings(); setRefreshing(false); };

  const fetchEarnings = async () => {
    const { data: sessionData } = await supabase.auth.getSession();
    if (!sessionData.session) return;
    const { data: grp } = await supabase
      .from('groups').select('id').eq('owner_id', sessionData.session.user.id).single();
    if (!grp) return;

    const { data, error } = await supabase
      .from('reservations')
      .select('*, package:packages(name, duration_hours)')
      .eq('group_id', grp.id)
      .eq('status', 'completed')
      .order('event_date', { ascending: false });

    if (error) { console.log('Error fetching earnings:', error.message); return; }

    if (data) {
      const clientIds = [...new Set(data.map((r: any) => r.client_id).filter(Boolean))];
      let clientMap: Record<string, { full_name: string }> = {};
      if (clientIds.length > 0) {
        const { data: clients } = await supabase
          .from('profiles').select('id, full_name').in('id', clientIds);
        if (clients) clients.forEach((c: any) => { clientMap[c.id] = { full_name: c.full_name }; });
      }
      setReservations(data.map((r: any) => ({ ...r, client: clientMap[r.client_id] ?? null })));
    }
  };

  const filtered = reservations.filter(r => {
    if (!r.event_date) return false;
    const d = new Date(r.event_date);
    return d.getMonth() === selectedMonth && d.getFullYear() === selectedYear;
  });

  const monthTotal = filtered.reduce((s, r) => s + (r.group_earnings ?? 0), 0);
  const yearTotal = reservations.reduce((s, r) => s + (r.group_earnings ?? 0), 0);

  return (
    <View style={styles.container}>
      <Particles />
      <SafeAreaView style={{ flex: 1 }}>
        <View style={styles.header}>
          <Pressable style={styles.backBtn} onPress={() => navigation.goBack()}>
            <ArrowLeft size={20} color={COLORS.text} />
          </Pressable>
          <Text style={styles.headerTitle}>Mis Ganancias</Text>
          <View style={{ width: 40 }} />
        </View>

        {/* TOTALES */}
        <View style={styles.totals}>
          <View style={styles.totalCard}>
            <View style={styles.totalIcon}>
              <TrendingUp size={20} color={COLORS.green} />
            </View>
            <Text style={styles.totalLabel}>Este mes</Text>
            <Text style={styles.totalValue}>${monthTotal.toLocaleString()}</Text>
          </View>
          <View style={[styles.totalCard, { borderColor: COLORS.blue }]}>
            <View style={[styles.totalIcon, { backgroundColor: 'rgba(66,133,244,0.1)' }]}>
              <DollarSign size={20} color={COLORS.blue} />
            </View>
            <Text style={styles.totalLabel}>Total {selectedYear}</Text>
            <Text style={[styles.totalValue, { color: COLORS.blue }]}>${yearTotal.toLocaleString()}</Text>
          </View>
        </View>

        {/* FILTRO MESES */}
        <ScrollView
          horizontal showsHorizontalScrollIndicator={false}
          contentContainerStyle={styles.monthList}
        >
          {MONTHS.map((m, i) => (
            <Pressable
              key={i}
              style={[styles.monthChip, selectedMonth === i && styles.monthChipActive]}
              onPress={() => setSelectedMonth(i)}
            >
              <Text style={[styles.monthText, selectedMonth === i && styles.monthTextActive]}>{m}</Text>
            </Pressable>
          ))}
        </ScrollView>

        <ScrollView showsVerticalScrollIndicator={false} contentContainerStyle={styles.list} refreshControl={<RefreshControl refreshing={refreshing} onRefresh={onRefresh} tintColor={COLORS.green} />}>
          {filtered.length === 0 ? (
            <View style={styles.empty}>
              <DollarSign size={40} color={COLORS.muted} />
              <Text style={styles.emptyTitle}>Sin ganancias</Text>
              <Text style={styles.emptyText}>No hay eventos completados en {MONTHS[selectedMonth]}</Text>
            </View>
          ) : (
            filtered.map(r => (
              <View key={r.id} style={styles.row}>
                <View style={styles.rowLeft}>
                  <View style={styles.rowIcon}>
                    <Calendar size={16} color={COLORS.green} />
                  </View>
                  <View style={{ flex: 1 }}>
                    <Text style={styles.rowClient}>{r.client?.full_name ?? 'Cliente'}</Text>
                    <Text style={styles.rowPkg}>{r.package?.name ?? '—'}</Text>
                    <Text style={styles.rowDate}>{r.event_date} {r.event_time ? `· ${r.event_time}` : ''}</Text>
                    {r.address ? <Text style={styles.rowAddr} numberOfLines={1}>{r.address}</Text> : null}
                  </View>
                </View>
                <View style={styles.rowRight}>
                  <Text style={styles.rowEarnings}>${(r.group_earnings ?? 0).toLocaleString()}</Text>
                  <Text style={styles.rowHours}>{r.package?.duration_hours ?? '?'}h</Text>
                </View>
              </View>
            ))
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
  totals: { flexDirection: 'row', gap: 12, padding: SPACING.xl },
  totalCard: {
    flex: 1, backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.green, padding: 14,
  },
  totalIcon: {
    width: 36, height: 36, borderRadius: 10,
    backgroundColor: COLORS.greenMuted,
    alignItems: 'center', justifyContent: 'center', marginBottom: 8,
  },
  totalLabel: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, marginBottom: 2 },
  totalValue: { fontFamily: FONTS.title, fontSize: 22, color: COLORS.green },
  monthList: { paddingHorizontal: SPACING.xl, gap: 8, paddingBottom: 12 },
  monthChip: {
    paddingHorizontal: 14, paddingVertical: 7, borderRadius: RADIUS.full,
    backgroundColor: COLORS.card, borderWidth: 1, borderColor: COLORS.border,
  },
  monthChipActive: { backgroundColor: COLORS.greenMuted, borderColor: COLORS.green },
  monthText: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted2 },
  monthTextActive: { color: COLORS.green },
  list: { padding: SPACING.xl, gap: 10 },
  empty: { alignItems: 'center', paddingTop: 60, gap: 10 },
  emptyTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 18, color: COLORS.muted2 },
  emptyText: { fontFamily: FONTS.body, fontSize: 14, color: COLORS.muted, textAlign: 'center' },
  row: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border,
    padding: 14, flexDirection: 'row', alignItems: 'flex-start',
  },
  rowLeft: { flex: 1, flexDirection: 'row', gap: 12, alignItems: 'flex-start' },
  rowIcon: {
    width: 36, height: 36, borderRadius: 10,
    backgroundColor: COLORS.greenMuted, alignItems: 'center', justifyContent: 'center',
  },
  rowClient: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.text, marginBottom: 2 },
  rowPkg: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.green, marginBottom: 2 },
  rowDate: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, marginBottom: 2 },
  rowAddr: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted },
  rowRight: { alignItems: 'flex-end' },
  rowEarnings: { fontFamily: FONTS.title, fontSize: 20, color: COLORS.green },
  rowHours: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2 },
});
