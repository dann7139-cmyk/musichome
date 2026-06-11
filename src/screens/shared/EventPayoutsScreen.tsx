/**
 * EventPayoutsScreen — Detalles de distribución de ganancias de un evento finalizado.
 * Accesible para: dueño del grupo, integrantes/talentos, admin.
 */
import { ChevronLeft } from 'lucide-react-native';
import React, { useEffect, useState } from 'react';
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
import Particles from '../../components/ui/Particles';

const MONTH_SHORT = ['ENE','FEB','MAR','ABR','MAY','JUN','JUL','AGO','SEP','OCT','NOV','DIC'];

const ROLE_LABEL: Record<string, string> = {
  owner:   'Dueño del grupo',
  member:  'Integrante',
  invited: 'Talento invitado',
};
const ROLE_ICON: Record<string, string> = {
  owner:   '👑',
  member:  '🎸',
  invited: '🎤',
};
const ROLE_COLOR: Record<string, string> = {
  owner:   COLORS.green,
  member:  '#42A5F5',
  invited: '#FFB300',
};

export default function EventPayoutsScreen({ navigation, route }: any) {
  const { reservationId, reservation } = route.params ?? {};
  const [payouts,  setPayouts]  = useState<any[]>([]);
  const [loading,   setLoading]   = useState(true);
  const [refreshing, setRefreshing] = useState(false);

  useEffect(() => { fetchPayouts(); }, []);

  const onRefresh = async () => { setRefreshing(true); await fetchPayouts(); setRefreshing(false); };

  const fetchPayouts = async () => {
    const { data } = await supabase
      .from('event_payouts')
      .select('user_id, role, amount, payout_status, profiles:user_id(full_name)')
      .eq('reservation_id', reservationId)
      .order('role')
      .order('amount', { ascending: false });
    setPayouts(data ?? []);
    setLoading(false);
  };

  const totalPrice = Number(reservation?.total_price ?? 0);
  const commission = Math.round(totalPrice * 0.08 * 100) / 100;
  const groupNet   = Math.round((totalPrice - commission) * 100) / 100;

  const parts    = reservation?.event_date?.split('-') ?? [];
  const day      = parts[2] ?? '—';
  const monthIdx = parts[1] ? parseInt(parts[1], 10) - 1 : -1;
  const month    = monthIdx >= 0 ? MONTH_SHORT[monthIdx] : '—';

  return (
    <View style={st.container}>
      <Particles />
      <SafeAreaView style={{ flex: 1 }}>

        {/* ── Header ── */}
        <View style={st.header}>
          <Pressable style={st.backBtn} onPress={() => navigation.goBack()}>
            <ChevronLeft size={20} color={COLORS.text} />
          </Pressable>
          <View style={{ flex: 1 }}>
            <Text style={st.title}>Detalles de ganancias</Text>
            {reservation?.event_date && (
              <Text style={st.subtitle}>
                {day} {month}  ·  {reservation?.client?.full_name ?? 'Cliente'}
              </Text>
            )}
          </View>
        </View>

        <ScrollView contentContainerStyle={st.scroll} showsVerticalScrollIndicator={false} refreshControl={<RefreshControl refreshing={refreshing} onRefresh={onRefresh} tintColor={COLORS.green} />}>

          {/* ── Resumen financiero ── */}
          <View style={st.summaryRow}>
            <View style={st.summaryCard}>
              <Text style={st.summaryLabel}>Total cobrado</Text>
              <Text style={st.summaryValue}>
                ${totalPrice.toLocaleString('es-MX', { minimumFractionDigits: 0 })}
              </Text>
            </View>
            <View style={[st.summaryCard, { borderColor: `${COLORS.orange}50` }]}>
              <Text style={st.summaryLabel}>Comisión 8%</Text>
              <Text style={[st.summaryValue, { color: COLORS.orange }]}>
                -${commission.toLocaleString('es-MX', { minimumFractionDigits: 0 })}
              </Text>
            </View>
            <View style={[st.summaryCard, { borderColor: `${COLORS.green}50` }]}>
              <Text style={st.summaryLabel}>Neto grupo</Text>
              <Text style={[st.summaryValue, { color: COLORS.green }]}>
                ${groupNet.toLocaleString('es-MX', { minimumFractionDigits: 0 })}
              </Text>
            </View>
          </View>

          {/* ── Distribución ── */}
          <Text style={st.sectionTitle}>Distribución de pagos</Text>

          {loading ? (
            <ActivityIndicator color={COLORS.green} style={{ marginTop: 40 }} />
          ) : payouts.length === 0 ? (
            <View style={st.empty}>
              <Text style={st.emptyIcon}>📭</Text>
              <Text style={st.emptyTitle}>Sin datos de distribución</Text>
              <Text style={st.emptyText}>No se encontraron registros de pago para este evento.</Text>
            </View>
          ) : (
            payouts.map((p, i) => {
              const roleColor = ROLE_COLOR[p.role] ?? COLORS.muted2;
              const isPaid    = p.payout_status === 'paid';
              return (
                <View key={i} style={st.payoutRow}>
                  <View style={[st.roleIcon, { backgroundColor: `${roleColor}18`, borderColor: `${roleColor}40` }]}>
                    <Text style={{ fontSize: 18 }}>{ROLE_ICON[p.role] ?? '🎵'}</Text>
                  </View>
                  <View style={st.payoutInfo}>
                    <Text style={st.payoutName} numberOfLines={1}>
                      {p.profiles?.full_name ?? 'Usuario'}
                    </Text>
                    <Text style={[st.payoutRole, { color: roleColor }]}>
                      {ROLE_LABEL[p.role] ?? p.role}
                    </Text>
                  </View>
                  <View style={{ alignItems: 'flex-end', gap: 4 }}>
                    <Text style={st.payoutAmount}>
                      ${Number(p.amount).toLocaleString('es-MX', { minimumFractionDigits: 0 })} MXN
                    </Text>
                    <View style={[st.statusPill, {
                      backgroundColor: isPaid ? `${COLORS.green}15` : `${COLORS.orange}15`,
                      borderColor:     isPaid ? `${COLORS.green}40` : `${COLORS.orange}40`,
                    }]}>
                      <Text style={[st.statusText, { color: isPaid ? COLORS.green : COLORS.orange }]}>
                        {isPaid ? '✓ Pagado' : '⏳ Pendiente'}
                      </Text>
                    </View>
                  </View>
                </View>
              );
            })
          )}

          {/* ── Nota plataforma ── */}
          {!loading && payouts.length > 0 && (
            <View style={st.note}>
              <Text style={st.noteText}>
                💡 La comisión del 8% es retenida por la plataforma. El resto se distribuye entre los participantes del evento.
              </Text>
            </View>
          )}

        </ScrollView>
      </SafeAreaView>
    </View>
  );
}

const st = StyleSheet.create({
  container: { flex: 1, backgroundColor: COLORS.bg },

  header: {
    flexDirection: 'row', alignItems: 'center', gap: 10,
    paddingHorizontal: SPACING.xl, paddingTop: 16, paddingBottom: 14,
  },
  backBtn: {
    width: 36, height: 36, borderRadius: 18,
    backgroundColor: 'rgba(255,255,255,0.06)',
    alignItems: 'center', justifyContent: 'center',
    borderWidth: 1, borderColor: COLORS.border,
  },
  title:    { fontFamily: FONTS.title, fontSize: 22, color: COLORS.text },
  subtitle: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.muted2, marginTop: 1 },

  scroll: { paddingHorizontal: SPACING.xl, paddingBottom: 40, gap: 12 },

  summaryRow: { flexDirection: 'row', gap: 8, marginBottom: 4 },
  summaryCard: {
    flex: 1, backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border,
    paddingVertical: 12, paddingHorizontal: 10, alignItems: 'center',
  },
  summaryLabel: { fontFamily: FONTS.body, fontSize: 10, color: COLORS.muted, textAlign: 'center', marginBottom: 4 },
  summaryValue: { fontFamily: FONTS.title, fontSize: 16, color: COLORS.text, textAlign: 'center' },

  sectionTitle: {
    fontFamily: FONTS.bodySemiBold, fontSize: 12, color: COLORS.muted2,
    textTransform: 'uppercase', letterSpacing: 0.6, marginTop: 4, marginBottom: 2,
  },

  payoutRow: {
    flexDirection: 'row', alignItems: 'center', gap: 12,
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border, padding: 14,
  },
  roleIcon: {
    width: 44, height: 44, borderRadius: 22, borderWidth: 1,
    alignItems: 'center', justifyContent: 'center', flexShrink: 0,
  },
  payoutInfo:   { flex: 1 },
  payoutName:   { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.text },
  payoutRole:   { fontFamily: FONTS.bodyMedium, fontSize: 11, marginTop: 2 },
  payoutAmount: { fontFamily: FONTS.title, fontSize: 15, color: COLORS.text },
  statusPill: {
    paddingHorizontal: 8, paddingVertical: 3,
    borderRadius: 20, borderWidth: 1,
  },
  statusText: { fontFamily: FONTS.bodyMedium, fontSize: 10 },

  empty: { alignItems: 'center', paddingTop: 60, gap: 8 },
  emptyIcon:  { fontSize: 40 },
  emptyTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 16, color: COLORS.text },
  emptyText:  { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2, textAlign: 'center' },

  note: {
    backgroundColor: 'rgba(0,230,118,0.06)', borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.2)',
    padding: 14, marginTop: 8,
  },
  noteText: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, lineHeight: 18 },
});
