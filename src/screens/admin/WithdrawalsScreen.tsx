import { ArrowLeft, CheckCircle, XCircle } from 'lucide-react-native';
import React, { useCallback, useEffect, useState } from 'react';
import {
  ActivityIndicator,
  Alert,
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

function formatCurrency(n: number) {
  return '$' + Number(n ?? 0).toLocaleString('es-MX', { minimumFractionDigits: 0 });
}

const STATUS_STYLE: Record<string, { label: string; color: string }> = {
  pending:    { label: 'Pendiente',   color: COLORS.orange },
  processing: { label: 'Procesando', color: COLORS.blue   },
  completed:  { label: 'Completado', color: COLORS.green  },
  rejected:   { label: 'Rechazado',  color: COLORS.red    },
};

const FILTERS = ['pending', 'processing', 'completed', 'rejected', 'all'] as const;
type Filter = typeof FILTERS[number];

export default function AdminWithdrawalsScreen({ navigation }: any) {
  const [withdrawals, setWithdrawals] = useState<any[]>([]);
  const [loading, setLoading]         = useState(true);
  const [refreshing, setRefreshing]   = useState(false);
  const [filter, setFilter]           = useState<Filter>('pending');

  const load = useCallback(async () => {
    let q = supabase
      .from('withdrawals')
      .select('*, profile:profiles(full_name, role)')
      .order('created_at', { ascending: false })
      .limit(100);

    if (filter !== 'all') q = q.eq('status', filter);

    const { data } = await q;
    setWithdrawals(data ?? []);
    setLoading(false);
    setRefreshing(false);
  }, [filter]);

  useEffect(() => { load(); }, [load]);

  const handleApprove = (wd: any) => {
    Alert.alert(
      'Aprobar retiro',
      `¿Marcar el retiro de ${wd.profile?.full_name} por ${formatCurrency(wd.amount)} como completado?\n\nCLABE: ${wd.bank_clabe}\nBanco: ${wd.bank_name}`,
      [
        { text: 'Cancelar', style: 'cancel' },
        {
          text: 'Completado',
          onPress: async () => {
            await supabase
              .from('withdrawals')
              .update({ status: 'completed', processed_at: new Date().toISOString() })
              .eq('id', wd.id);
            // Notificar al usuario
            await supabase.from('notifications').insert({
              user_id: wd.user_id,
              type: 'payment',
              title: '✅ Retiro completado',
              body: `Tu retiro de ${formatCurrency(wd.amount)} fue procesado exitosamente vía SPEI.`,
              data: { withdrawal_id: wd.id, screen: 'Wallet' },
            });
            load();
          },
        },
      ]
    );
  };

  const handleReject = (wd: any) => {
    Alert.alert(
      'Rechazar retiro',
      `¿Rechazar el retiro de ${formatCurrency(wd.amount)} de ${wd.profile?.full_name}?\nSe devolverá el dinero a su billetera.`,
      [
        { text: 'Cancelar', style: 'cancel' },
        {
          text: 'Rechazar',
          style: 'destructive',
          onPress: async () => {
            const { data, error } = await supabase.rpc('admin_refund_withdrawal', {
              p_withdrawal_id: wd.id,
            });
            if (error || !data?.ok) {
              Alert.alert('Error', data?.error ?? error?.message ?? 'No se pudo rechazar.');
              return;
            }
            load();
          },
        },
      ]
    );
  };

  return (
    <View style={st.container}>
      <Particles />
      <SafeAreaView style={{ flex: 1 }}>
        {/* Header */}
        <View style={st.header}>
          <Pressable style={st.backBtn} onPress={() => navigation.goBack()}>
            <ArrowLeft size={20} color={COLORS.text} />
          </Pressable>
          <Text style={st.headerTitle}>Solicitudes de retiro</Text>
          <View style={{ width: 40 }} />
        </View>

        {/* Filtros */}
        <ScrollView
          horizontal
          showsHorizontalScrollIndicator={false}
          contentContainerStyle={st.filtersRow}
        >
          {FILTERS.map(f => (
            <Pressable
              key={f}
              style={[st.filterChip, filter === f && st.filterChipActive]}
              onPress={() => setFilter(f)}
            >
              <Text style={[st.filterChipText, filter === f && st.filterChipTextActive]}>
                {f === 'all' ? 'Todos' : STATUS_STYLE[f]?.label ?? f}
              </Text>
            </Pressable>
          ))}
        </ScrollView>

        {loading ? (
          <View style={{ flex: 1, alignItems: 'center', justifyContent: 'center' }}>
            <ActivityIndicator color={COLORS.green} />
          </View>
        ) : (
          <ScrollView
            showsVerticalScrollIndicator={false}
            contentContainerStyle={st.scroll}
            refreshControl={<RefreshControl refreshing={refreshing} onRefresh={() => { setRefreshing(true); load(); }} tintColor={COLORS.green} />}
          >
            {withdrawals.length === 0 ? (
              <View style={st.empty}>
                <Text style={st.emptyIcon}>📭</Text>
                <Text style={st.emptyText}>Sin solicitudes</Text>
              </View>
            ) : (
              withdrawals.map(wd => {
                const ss = STATUS_STYLE[wd.status] ?? { label: wd.status, color: COLORS.muted2 };
                const date = new Date(wd.created_at).toLocaleDateString('es-MX', {
                  day: 'numeric', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit',
                });
                return (
                  <View key={wd.id} style={st.card}>
                    {/* Top row */}
                    <View style={st.cardTop}>
                      <View>
                        <Text style={st.cardName}>{wd.profile?.full_name ?? 'Usuario'}</Text>
                        <Text style={st.cardDate}>{date}</Text>
                      </View>
                      <View style={st.cardRight}>
                        <Text style={st.cardAmount}>{formatCurrency(wd.amount)}</Text>
                        <View style={[st.badge, { backgroundColor: ss.color + '22', borderColor: ss.color }]}>
                          <Text style={[st.badgeText, { color: ss.color }]}>{ss.label}</Text>
                        </View>
                      </View>
                    </View>

                    {/* Bank info */}
                    <View style={st.bankRow}>
                      <Text style={st.bankLabel}>CLABE</Text>
                      <Text style={st.bankValue}>{wd.bank_clabe}</Text>
                    </View>
                    <View style={st.bankRow}>
                      <Text style={st.bankLabel}>Banco</Text>
                      <Text style={st.bankValue}>{wd.bank_name ?? '—'}</Text>
                    </View>
                    <View style={st.bankRow}>
                      <Text style={st.bankLabel}>Titular</Text>
                      <Text style={st.bankValue}>{wd.account_holder ?? '—'}</Text>
                    </View>

                    {/* Actions */}
                    {wd.status === 'pending' && (
                      <View style={st.actions}>
                        <Pressable style={st.btnApprove} onPress={() => handleApprove(wd)}>
                          <CheckCircle size={16} color={COLORS.bg} />
                          <Text style={st.btnApproveText}>Completar</Text>
                        </Pressable>
                        <Pressable style={st.btnReject} onPress={() => handleReject(wd)}>
                          <XCircle size={16} color={COLORS.red} />
                          <Text style={st.btnRejectText}>Rechazar</Text>
                        </Pressable>
                      </View>
                    )}
                  </View>
                );
              })
            )}
          </ScrollView>
        )}
      </SafeAreaView>
    </View>
  );
}

const st = StyleSheet.create({
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

  filtersRow: { paddingHorizontal: SPACING.xl, paddingVertical: 12, gap: 8 },
  filterChip: {
    paddingHorizontal: 14, paddingVertical: 7,
    borderRadius: RADIUS.full, borderWidth: 1,
    borderColor: COLORS.border, backgroundColor: COLORS.card,
  },
  filterChipActive:    { borderColor: COLORS.green, backgroundColor: COLORS.greenMuted },
  filterChipText:      { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted2 },
  filterChipTextActive:{ color: COLORS.green },

  scroll: { padding: SPACING.xl, paddingBottom: 40 },
  empty: { alignItems: 'center', paddingTop: 60 },
  emptyIcon: { fontSize: 36, marginBottom: 10 },
  emptyText: { fontFamily: FONTS.bodyMedium, fontSize: 14, color: COLORS.muted2 },

  card: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.xl,
    borderWidth: 1, borderColor: COLORS.border,
    padding: SPACING.lg, marginBottom: 12,
  },
  cardTop:   { flexDirection: 'row', justifyContent: 'space-between', marginBottom: 12 },
  cardName:  { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.text },
  cardDate:  { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted, marginTop: 2 },
  cardRight: { alignItems: 'flex-end', gap: 6 },
  cardAmount:{ fontFamily: FONTS.title, fontSize: 20, color: COLORS.text },

  badge: {
    borderRadius: RADIUS.full, borderWidth: 1,
    paddingHorizontal: 10, paddingVertical: 3,
  },
  badgeText: { fontFamily: FONTS.bodyMedium, fontSize: 11 },

  bankRow: { flexDirection: 'row', justifyContent: 'space-between', marginBottom: 4 },
  bankLabel:{ fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted },
  bankValue:{ fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.text },

  actions: { flexDirection: 'row', gap: 10, marginTop: 14 },
  btnApprove: {
    flex: 1, flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 6,
    backgroundColor: COLORS.green, borderRadius: RADIUS.lg, paddingVertical: 12,
  },
  btnApproveText: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.bg },
  btnReject: {
    flex: 1, flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 6,
    backgroundColor: COLORS.card2, borderRadius: RADIUS.lg, paddingVertical: 12,
    borderWidth: 1, borderColor: COLORS.red + '50',
  },
  btnRejectText: { fontFamily: FONTS.bodyMedium, fontSize: 14, color: COLORS.red },
});
