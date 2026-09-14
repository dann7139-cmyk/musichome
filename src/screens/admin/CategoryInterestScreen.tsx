import { ArrowLeft, MapPin, Phone } from 'lucide-react-native';
import React, { useEffect, useState } from 'react';
import { useTranslation } from 'react-i18next';
import {
  ActivityIndicator,
  Alert,
  Linking,
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

// sql/605 — petición real (2026-09-03): "que le aparezca al admin el
// número de cliente, así yo consigo uno de lo que está buscando... mientras
// por si no hay [proveedores]". Lista manual de leads — NO hay matching
// automático, el admin la usa para reclutar/contactar por su cuenta.
interface InterestRow {
  id: string;
  category_label: string;
  genres: string[];
  city: string | null;
  state: string | null;
  created_at: string;
  contacted_at: string | null;
  client: { full_name: string | null; phone: string | null } | null;
}

type Tab = 'pending' | 'contacted';

const call = (phone?: string | null) => { if (phone) Linking.openURL(`tel:${phone}`); };

export default function CategoryInterestScreen({ navigation }: any) {
  const { t } = useTranslation();
  const [rows, setRows] = useState<InterestRow[]>([]);
  const [tab, setTab] = useState<Tab>('pending');
  const [loading, setLoading] = useState(true);
  const [refreshing, setRefreshing] = useState(false);
  const [markingId, setMarkingId] = useState<string | null>(null);

  useEffect(() => { fetchRows(); }, []);

  const fetchRows = async () => {
    const { data, error } = await supabase
      .from('category_interest_requests')
      .select('id, category_label, genres, city, state, created_at, contacted_at, client:profiles!category_interest_requests_client_id_fkey(full_name, phone)')
      .order('created_at', { ascending: false })
      .limit(200);
    if (error) {
      Alert.alert(t('common.error'), error.message);
    } else {
      setRows(((data ?? []) as any[]).map(r => ({ ...r, client: Array.isArray(r.client) ? r.client[0] ?? null : r.client })));
    }
    setLoading(false);
  };

  const onRefresh = async () => {
    setRefreshing(true);
    await fetchRows();
    setRefreshing(false);
  };

  const markContacted = async (id: string) => {
    setMarkingId(id);
    const { data, error } = await supabase.rpc('mark_category_interest_contacted', { p_id: id });
    setMarkingId(null);
    if (error || !(data as any)?.ok) {
      Alert.alert(t('common.error'), t('adminCategoryInterestScreen.markError'));
      return;
    }
    setRows(prev => prev.map(r => r.id === id ? { ...r, contacted_at: new Date().toISOString() } : r));
  };

  const pending   = rows.filter(r => !r.contacted_at);
  const contacted = rows.filter(r => !!r.contacted_at);
  const visible   = tab === 'pending' ? pending : contacted;

  return (
    <View style={s.root}>
      <SafeAreaView edges={['top']} style={{ flex: 1 }}>
        <View style={s.header}>
          <Pressable onPress={() => navigation.goBack()} hitSlop={10}>
            <ArrowLeft size={20} color={COLORS.text} />
          </Pressable>
          <Text style={s.headerTitle}>{t('adminCategoryInterestScreen.title')}</Text>
          <View style={{ width: 20 }} />
        </View>

        <View style={s.tabs}>
          <Pressable style={[s.tab, tab === 'pending' && s.tabActive]} onPress={() => setTab('pending')}>
            <Text style={[s.tabText, tab === 'pending' && s.tabTextActive]}>
              {t('adminCategoryInterestScreen.tabPending')} · {pending.length}
            </Text>
          </Pressable>
          <Pressable style={[s.tab, tab === 'contacted' && s.tabActive]} onPress={() => setTab('contacted')}>
            <Text style={[s.tabText, tab === 'contacted' && s.tabTextActive]}>
              {t('adminCategoryInterestScreen.tabContacted')} · {contacted.length}
            </Text>
          </Pressable>
        </View>

        {loading ? (
          <ActivityIndicator style={{ marginTop: 40 }} color={COLORS.green} />
        ) : (
          <ScrollView
            contentContainerStyle={s.list}
            refreshControl={<RefreshControl refreshing={refreshing} onRefresh={onRefresh} tintColor={COLORS.green} />}
          >
            {visible.length === 0 ? (
              <View style={s.empty}>
                <Text style={s.emptyEmoji}>📭</Text>
                <Text style={s.emptyText}>
                  {tab === 'pending' ? t('adminCategoryInterestScreen.emptyPending') : t('adminCategoryInterestScreen.emptyContacted')}
                </Text>
              </View>
            ) : visible.map(r => (
              <View key={r.id} style={s.card}>
                <View style={s.cardTop}>
                  <Text style={s.category}>{r.category_label}</Text>
                  <Text style={s.date}>{new Date(r.created_at).toLocaleDateString('es-MX', { day: 'numeric', month: 'short' })}</Text>
                </View>
                <Text style={s.clientName}>{r.client?.full_name ?? '—'}</Text>
                {(r.city || r.state) && (
                  <View style={s.metaRow}>
                    <MapPin size={12} color={COLORS.muted} />
                    <Text style={s.metaText}>{[r.city, r.state].filter(Boolean).join(', ')}</Text>
                  </View>
                )}
                <View style={s.cardBottom}>
                  <Pressable style={s.phoneBtn} onPress={() => call(r.client?.phone)} disabled={!r.client?.phone}>
                    <Phone size={14} color={COLORS.green} />
                    <Text style={s.phoneText}>{r.client?.phone ?? t('adminCategoryInterestScreen.noPhone')}</Text>
                  </Pressable>
                  {tab === 'pending' && (
                    <Pressable
                      style={[s.contactBtn, markingId === r.id && { opacity: 0.6 }]}
                      onPress={() => markContacted(r.id)}
                      disabled={markingId === r.id}
                    >
                      {markingId === r.id
                        ? <ActivityIndicator size="small" color={COLORS.bg} />
                        : <Text style={s.contactBtnText}>{t('adminCategoryInterestScreen.markContacted')}</Text>}
                    </Pressable>
                  )}
                </View>
              </View>
            ))}
          </ScrollView>
        )}
      </SafeAreaView>
    </View>
  );
}

const s = StyleSheet.create({
  root: { flex: 1, backgroundColor: COLORS.bg },
  header: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between',
    paddingHorizontal: SPACING.xl, paddingBottom: 12,
  },
  headerTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 16, color: COLORS.text },
  tabs: { flexDirection: 'row', gap: 8, paddingHorizontal: SPACING.xl, marginBottom: 12 },
  tab: {
    paddingVertical: 8, paddingHorizontal: 14, borderRadius: RADIUS.full,
    borderWidth: 1, borderColor: COLORS.border, backgroundColor: COLORS.card2,
  },
  tabActive: { borderColor: COLORS.green, backgroundColor: COLORS.greenMuted },
  tabText: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.muted2 },
  tabTextActive: { color: COLORS.green },
  list: { padding: SPACING.xl, paddingTop: 0, gap: 10, paddingBottom: 40 },
  empty: { alignItems: 'center', paddingTop: 60 },
  emptyEmoji: { fontSize: 36, marginBottom: 10 },
  emptyText: { fontFamily: FONTS.body, color: COLORS.muted, fontSize: 13 },
  card: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg, borderWidth: 1, borderColor: COLORS.border,
    padding: 14, gap: 6,
  },
  cardTop: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center' },
  category: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.text },
  date: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted },
  clientName: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted2 },
  metaRow: { flexDirection: 'row', alignItems: 'center', gap: 4 },
  metaText: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted },
  cardBottom: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center', marginTop: 4 },
  phoneBtn: { flexDirection: 'row', alignItems: 'center', gap: 6 },
  phoneText: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.green },
  contactBtn: { backgroundColor: COLORS.green, borderRadius: RADIUS.full, paddingVertical: 7, paddingHorizontal: 14 },
  contactBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 12, color: COLORS.bg },
});
