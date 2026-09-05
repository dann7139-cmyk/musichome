import { AlertCircle, ArrowLeft, CheckCircle, Clock, Scale, XCircle } from 'lucide-react-native';
import type { TFunction } from 'i18next';
import React, { useEffect, useState } from 'react';
import { useTranslation } from 'react-i18next';
import {
  ActivityIndicator,
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
import DisputeEvidenceMap from '../../components/admin/DisputeEvidenceMap';

// Fila que devuelve admin_dispute_overview (sql/186)
interface DisputeRow {
  dispute_id: string;
  reservation_id: string;
  event_date: string | null;
  total_price: number | null;
  status: 'open' | 'under_review' | 'resolved_client' | 'resolved_group';
  reason: string | null;
  opened_by: string;
  opener_email: string | null;
  group_name: string | null;
  created_at: string;
  updated_at: string;
}

type StatusChip = 'open' | 'under_review' | 'resolved' | 'all';

const getStatusBadge = (
  t: TFunction,
): Record<DisputeRow['status'], { label: string; variant: 'red' | 'orange' | 'green' }> => ({
  open:            { label: t('adminDisputesScreen.status.open'),           variant: 'red' },
  under_review:    { label: t('adminDisputesScreen.status.underReview'),    variant: 'orange' },
  resolved_client: { label: t('adminDisputesScreen.status.resolvedClient'), variant: 'green' },
  resolved_group:  { label: t('adminDisputesScreen.status.resolvedGroup'),  variant: 'green' },
});

export default function AdminDisputesScreen({ navigation }: any) {
  const { t } = useTranslation();
  const [disputes, setDisputes] = useState<DisputeRow[]>([]);
  const [refreshing, setRefreshing] = useState(false);
  const [chip, setChip] = useState<StatusChip>('open');
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [note, setNote] = useState('');
  const [resolving, setResolving] = useState(false);

  useEffect(() => { fetchDisputes(); }, []);

  const fetchDisputes = async () => {
    // Trae TODAS y filtra por chip en cliente (contadores completos gratis)
    const { data, error } = await supabase.rpc('admin_dispute_overview', {
      p_status: 'all', p_limit: 100, p_offset: 0,
    });
    if (error) {
      Alert.alert(t('adminDisputesScreen.errors.loadTitle'), error.message);
      return;
    }
    setDisputes((data ?? []) as DisputeRow[]);
  };

  const onRefresh = async () => {
    setRefreshing(true);
    await fetchDisputes();
    setRefreshing(false);
  };

  const openCount     = disputes.filter(d => d.status === 'open').length;
  const reviewCount   = disputes.filter(d => d.status === 'under_review').length;
  const resolvedCount = disputes.filter(d => d.status.startsWith('resolved')).length;

  const visible = disputes.filter(d =>
    chip === 'all' ? true :
    chip === 'resolved' ? d.status.startsWith('resolved') :
    d.status === chip
  );

  const doResolve = async (dispute: DisputeRow, resolution: 'resolved_client' | 'resolved_group') => {
    setResolving(true);
    const { data, error } = await supabase.rpc('resolve_dispute', {
      p_dispute_id: dispute.dispute_id,
      p_resolution: resolution,
      p_resolution_note: note.trim() || null,
    });
    setResolving(false);
    if (error || !data?.ok) {
      Alert.alert(
        t('adminDisputesScreen.errors.resolveTitle'),
        error?.message ?? t('adminDisputesScreen.errors.resolveDefault'),
      );
      return;
    }
    setSelectedId(null);
    setNote('');
    Alert.alert(
      t('adminDisputesScreen.resolveSuccess.title'),
      t('adminDisputesScreen.resolveSuccess.message'),
    );
    fetchDisputes();
  };

  const confirmResolve = (dispute: DisputeRow, resolution: 'resolved_client' | 'resolved_group') => {
    if (resolution === 'resolved_group') {
      Alert.alert(
        t('adminDisputesScreen.confirmGroup.title'),
        t('adminDisputesScreen.confirmGroup.message'),
        [
          { text: t('adminDisputesScreen.actions.cancel'), style: 'cancel' },
          { text: t('adminDisputesScreen.actions.confirm'), onPress: () => doResolve(dispute, resolution) },
        ],
      );
    } else {
      Alert.alert(
        t('adminDisputesScreen.confirmClient.title'),
        t('adminDisputesScreen.confirmClient.message'),
        [
          { text: t('adminDisputesScreen.actions.cancel'), style: 'cancel' },
          { text: t('adminDisputesScreen.actions.confirm'), style: 'destructive', onPress: () => doResolve(dispute, resolution) },
        ],
      );
    }
  };

  const chips: { key: StatusChip; label: string }[] = [
    { key: 'open',         label: t('adminDisputesScreen.chips.open', { count: openCount }) },
    { key: 'under_review', label: t('adminDisputesScreen.chips.underReview', { count: reviewCount }) },
    { key: 'resolved',     label: t('adminDisputesScreen.chips.resolved', { count: resolvedCount }) },
    { key: 'all',          label: t('adminDisputesScreen.chips.all') },
  ];

  const statusBadge = getStatusBadge(t);

  return (
    <View style={styles.container}>
      <Particles />
      <SafeAreaView style={{ flex: 1 }}>
        <View style={styles.header}>
          <Pressable style={styles.backBtn} onPress={() => navigation.goBack()}>
            <ArrowLeft size={20} color={COLORS.text} />
          </Pressable>
          <Text style={styles.headerTitle}>{t('adminDisputesScreen.title')}</Text>
          <View style={{ width: 40 }} />
        </View>

        {/* SUMMARY */}
        <View style={styles.summaryRow}>
          <View style={styles.summaryCard}>
            <AlertCircle size={20} color={COLORS.red} />
            <Text style={[styles.summaryNum, { color: COLORS.red }]}>{openCount}</Text>
            <Text style={styles.summaryLabel}>{t('adminDisputesScreen.summary.open')}</Text>
          </View>
          <View style={styles.summaryCard}>
            <Clock size={20} color={COLORS.orange} />
            <Text style={[styles.summaryNum, { color: COLORS.orange }]}>{reviewCount}</Text>
            <Text style={styles.summaryLabel}>{t('adminDisputesScreen.summary.underReview')}</Text>
          </View>
          <View style={styles.summaryCard}>
            <CheckCircle size={20} color={COLORS.green} />
            <Text style={[styles.summaryNum, { color: COLORS.green }]}>{resolvedCount}</Text>
            <Text style={styles.summaryLabel}>{t('adminDisputesScreen.summary.resolved')}</Text>
          </View>
        </View>

        {/* CHIPS DE FILTRO */}
        <View style={styles.chipsRow}>
          {chips.map(c => (
            <Pressable
              key={c.key}
              style={[styles.chip, chip === c.key && styles.chipActive]}
              onPress={() => setChip(c.key)}
            >
              <Text style={[styles.chipTx, chip === c.key && styles.chipTxActive]}>{c.label}</Text>
            </Pressable>
          ))}
        </View>

        <ScrollView
          showsVerticalScrollIndicator={false}
          contentContainerStyle={styles.list}
          refreshControl={<RefreshControl refreshing={refreshing} onRefresh={onRefresh} tintColor={COLORS.green} />}
        >
          {visible.length === 0 ? (
            <View style={styles.empty}>
              <Scale size={48} color={COLORS.muted} />
              <Text style={styles.emptyTitle}>{t('adminDisputesScreen.empty.title')}</Text>
              <Text style={styles.emptyText}>
                {chip === 'open' ? t('adminDisputesScreen.empty.open') : t('adminDisputesScreen.empty.other')}
              </Text>
            </View>
          ) : (
            visible.map(d => {
              const isOpen = selectedId === d.dispute_id;
              const canResolve = d.status === 'open' || d.status === 'under_review';
              const badge = statusBadge[d.status] ?? { label: d.status, variant: 'red' as const };
              return (
                <View key={d.dispute_id} style={styles.card}>
                  <Pressable
                    style={styles.cardHeader}
                    onPress={() => { setSelectedId(isOpen ? null : d.dispute_id); setNote(''); }}
                  >
                    <View style={styles.cardLeft}>
                      <Text style={styles.groupName}>{d.group_name ?? '—'}</Text>
                      <Text style={styles.clientName}>
                        {t('adminDisputesScreen.card.openedBy', { email: d.opener_email ?? '—' })}
                      </Text>
                      {!!d.reason && (
                        <Text style={styles.reason} numberOfLines={isOpen ? undefined : 2}>
                          “{d.reason}”
                        </Text>
                      )}
                      <Text style={styles.date}>
                        {t('adminDisputesScreen.card.event', {
                          date: d.event_date ?? '—',
                          price: d.total_price?.toLocaleString() ?? '—',
                        })}
                      </Text>
                    </View>
                    <Badge label={badge.label} variant={badge.variant} />
                  </Pressable>

                  {isOpen && (
                    <View style={styles.panel}>
                      {/* Evidencia GPS — se monta solo al expandir (sql/426) */}
                      <DisputeEvidenceMap reservationId={d.reservation_id} />

                      {canResolve && (
                        <>
                          <Text style={styles.panelLabel}>{t('adminDisputesScreen.panel.label')}</Text>
                          <TextInput
                            style={styles.textArea}
                            placeholder={t('adminDisputesScreen.panel.placeholder')}
                            placeholderTextColor={COLORS.muted}
                            value={note}
                            onChangeText={setNote}
                            multiline
                            numberOfLines={3}
                          />
                          <View style={styles.panelBtns}>
                            <Pressable
                              style={[styles.resolveBtn, styles.btnClient, resolving && { opacity: 0.5 }]}
                              disabled={resolving}
                              onPress={() => confirmResolve(d, 'resolved_client')}
                            >
                              {resolving
                                ? <ActivityIndicator size="small" color={COLORS.text} />
                                : <Text style={styles.btnClientText}>{t('adminDisputesScreen.panel.favorClient')}</Text>}
                            </Pressable>
                            <Pressable
                              style={[styles.resolveBtn, styles.btnGroup, resolving && { opacity: 0.5 }]}
                              disabled={resolving}
                              onPress={() => confirmResolve(d, 'resolved_group')}
                            >
                              {resolving
                                ? <ActivityIndicator size="small" color={COLORS.black} />
                                : <Text style={styles.btnGroupText}>{t('adminDisputesScreen.panel.favorGroup')}</Text>}
                            </Pressable>
                            <Pressable style={styles.closeBtn} onPress={() => setSelectedId(null)}>
                              <XCircle size={16} color={COLORS.muted2} />
                            </Pressable>
                          </View>
                        </>
                      )}
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
  summaryRow: { flexDirection: 'row', gap: 10, paddingHorizontal: SPACING.xl, paddingTop: SPACING.xl },
  summaryCard: {
    flex: 1, alignItems: 'center', paddingVertical: 14,
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border, gap: 4,
  },
  summaryNum: { fontFamily: FONTS.title, fontSize: 22 },
  summaryLabel: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted2 },
  chipsRow: { flexDirection: 'row', gap: 8, paddingHorizontal: SPACING.xl, paddingVertical: 12, flexWrap: 'wrap' },
  chip: {
    paddingHorizontal: 12, paddingVertical: 7, borderRadius: 20,
    backgroundColor: COLORS.card, borderWidth: 1, borderColor: COLORS.border,
  },
  chipActive: { backgroundColor: 'rgba(0,230,118,0.12)', borderColor: 'rgba(0,230,118,0.45)' },
  chipTx: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.muted2 },
  chipTxActive: { color: COLORS.green },
  list: { paddingHorizontal: SPACING.xl, paddingBottom: 32, gap: 10 },
  card: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border, overflow: 'hidden',
  },
  cardHeader: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'flex-start', padding: SPACING.lg, gap: 10 },
  cardLeft: { flex: 1 },
  groupName: { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.text, marginBottom: 3 },
  clientName: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2, marginBottom: 2 },
  reason: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.text, marginBottom: 4, fontStyle: 'italic' },
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
    gap: 8, paddingVertical: 12, borderRadius: RADIUS.md,
  },
  btnClient: {
    backgroundColor: 'rgba(239,83,80,0.12)',
    borderWidth: 1, borderColor: 'rgba(239,83,80,0.45)',
  },
  btnClientText: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.red },
  btnGroup: { backgroundColor: COLORS.green },
  btnGroupText: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.black },
  closeBtn: {
    width: 44, height: 44, borderRadius: RADIUS.md,
    backgroundColor: COLORS.card2, borderWidth: 1, borderColor: COLORS.border,
    alignItems: 'center', justifyContent: 'center',
  },
  empty: { alignItems: 'center', paddingTop: 60, gap: 12 },
  emptyTitle: { fontFamily: FONTS.title, fontSize: 20, color: COLORS.text },
  emptyText: { fontFamily: FONTS.body, fontSize: 14, color: COLORS.muted2, textAlign: 'center' },
});
