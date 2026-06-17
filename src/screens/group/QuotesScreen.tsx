/**
 * GroupQuotesScreen — El grupo ve todas las solicitudes de cotización recibidas.
 */
import React, { useCallback, useEffect, useState } from 'react';
import {
  ActivityIndicator,
  FlatList,
  Pressable,
  RefreshControl,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { ArrowLeft, FileText, Clock, CheckCircle, XCircle, AlertCircle } from 'lucide-react-native';
import { supabase } from '../../config/supabase';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';

// ─── Tipos ───────────────────────────────────────────────────────────────────

const EVENT_TYPE_LABELS: Record<string, string> = {
  fiesta_privada: '🎉 Fiesta privada',
  boda:           '💍 Boda',
  cumpleanos:     '🎂 Cumpleaños',
  graduacion:     '🎓 Graduación',
  empresarial:    '🏢 Empresarial',
  otro:           '🎵 Otro',
};

const STATUS_CONFIG: Record<string, { label: string; color: string; icon: any }> = {
  pending:  { label: 'Pendiente',     color: COLORS.orange,  icon: Clock },
  quoted:   { label: 'Cotizado',      color: COLORS.blue,    icon: FileText },
  accepted: { label: 'Aceptado',      color: COLORS.green,   icon: CheckCircle },
  rejected: { label: 'Rechazado',     color: COLORS.red,     icon: XCircle },
  expired:  { label: 'Expirado',      color: COLORS.muted,   icon: AlertCircle },
};

// ─── Screen ──────────────────────────────────────────────────────────────────

export default function GroupQuotesScreen({ navigation }: any) {
  const [quotes,      setQuotes]      = useState<any[]>([]);
  const [loading,     setLoading]     = useState(true);
  const [refreshing,  setRefreshing]  = useState(false);
  const [activeTab,   setActiveTab]   = useState<'pending' | 'all'>('pending');

  const loadQuotes = useCallback(async () => {
    const { data: { user } } = await supabase.auth.getUser();
    if (!user) return;

    // Obtener el grupo del usuario
    const { data: grp } = await supabase
      .rpc('get_my_group')
      .maybeSingle() as { data: any };
    if (!grp) return;

    let query = supabase
      .from('quotes')
      .select(`
        *,
        client:profiles!client_id(full_name, avatar_url)
      `)
      .eq('group_id', grp.id)
      .order('created_at', { ascending: false });

    if (activeTab === 'pending') {
      const today = new Date().toISOString().slice(0, 10);
      query = query.in('status', ['pending', 'quoted']).gte('event_date', today);
    }

    const { data } = await query;
    setQuotes(data ?? []);
  }, [activeTab]);

  useEffect(() => {
    setLoading(true);
    loadQuotes().finally(() => setLoading(false));
  }, [loadQuotes]);

  const onRefresh = async () => {
    setRefreshing(true);
    await loadQuotes();
    setRefreshing(false);
  };

  const filteredQuotes = quotes;

  // ── Render item ────────────────────────────────────────────────────────
  const renderItem = ({ item }: { item: any }) => {
    const cfg  = STATUS_CONFIG[item.status] ?? STATUS_CONFIG.pending;
    const Icon = cfg.icon;
    const eventDate = new Date(item.event_date + 'T12:00:00').toLocaleDateString('es-MX', {
      weekday: 'short', day: 'numeric', month: 'short', year: 'numeric',
    });

    return (
      <Pressable
        style={s.card}
        onPress={() => navigation.navigate('GroupQuoteDetail', { quote: item })}
      >
        {/* Status row */}
        <View style={s.cardTop}>
          <View style={[s.statusPill, { borderColor: cfg.color + '50', backgroundColor: cfg.color + '15' }]}>
            <Icon size={11} color={cfg.color} />
            <Text style={[s.statusText, { color: cfg.color }]}>{cfg.label}</Text>
          </View>
          <Text style={s.cardDate}>
            {new Date(item.created_at).toLocaleDateString('es-MX', { day: '2-digit', month: 'short' })}
          </Text>
        </View>

        {/* Client */}
        <Text style={s.clientName}>{item.client?.full_name ?? 'Cliente'}</Text>
        <Text style={s.eventTypeText}>{EVENT_TYPE_LABELS[item.event_type] ?? item.event_type}</Text>

        {/* Event info */}
        <View style={s.infoRow}>
          <Text style={s.infoText}>📅 {eventDate}</Text>
          <Text style={s.infoText}>⏰ {item.event_time}</Text>
          <Text style={s.infoText}>⏱ {item.duration_hours === 5 ? '+4h' : `${item.duration_hours}h`}</Text>
        </View>
        <Text style={s.locationText}>
          📍 {item.event_municipio}, {item.event_estado}
        </Text>

        {/* Price if quoted */}
        {item.status === 'quoted' && item.total_amount && (
          <View style={s.priceRow}>
            <Text style={s.priceLabelTxt}>Cotización enviada:</Text>
            <Text style={s.priceValueTxt}>${item.total_amount.toLocaleString()}</Text>
          </View>
        )}

        <View style={s.cardFooter}>
          <Text style={s.cardCta}>
            {item.status === 'pending' ? 'Responder →' : 'Ver detalle →'}
          </Text>
        </View>
      </Pressable>
    );
  };

  return (
    <View style={s.root}>
      <SafeAreaView edges={['top']} style={s.header}>
        <Pressable style={s.backBtn} onPress={() => navigation.goBack()}>
          <ArrowLeft size={20} color={COLORS.text} />
        </Pressable>
        <Text style={s.headerTitle}>Cotizaciones</Text>
        <View style={{ width: 40 }} />
      </SafeAreaView>

      {/* Tabs */}
      <View style={s.tabs}>
        {(['pending', 'all'] as const).map(tab => (
          <Pressable
            key={tab}
            style={[s.tab, activeTab === tab && s.tabActive]}
            onPress={() => setActiveTab(tab)}
          >
            <Text style={[s.tabText, activeTab === tab && s.tabTextActive]}>
              {tab === 'pending' ? 'Pendientes' : 'Todas'}
            </Text>
          </Pressable>
        ))}
      </View>

      {loading ? (
        <View style={s.center}>
          <ActivityIndicator size="large" color={COLORS.green} />
        </View>
      ) : (
        <FlatList
          data={filteredQuotes}
          keyExtractor={item => item.id}
          renderItem={renderItem}
          contentContainerStyle={s.list}
          refreshControl={<RefreshControl refreshing={refreshing} onRefresh={onRefresh} tintColor={COLORS.green} />}
          ListEmptyComponent={
            <View style={s.empty}>
              <Text style={s.emptyEmoji}>📋</Text>
              <Text style={s.emptyTitle}>
                {activeTab === 'pending' ? 'Sin solicitudes pendientes' : 'Sin cotizaciones aún'}
              </Text>
              <Text style={s.emptySub}>
                Las solicitudes de cotización de clientes aparecerán aquí.
              </Text>
            </View>
          }
        />
      )}
    </View>
  );
}

// ─── Styles ──────────────────────────────────────────────────────────────────

const s = StyleSheet.create({
  root: { flex: 1, backgroundColor: COLORS.bg },

  header: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between',
    paddingHorizontal: SPACING.xl, paddingVertical: 12,
    borderBottomWidth: 1, borderBottomColor: COLORS.border,
  },
  backBtn: {
    width: 40, height: 40, borderRadius: 12,
    backgroundColor: COLORS.card, borderWidth: 1, borderColor: COLORS.border,
    alignItems: 'center', justifyContent: 'center',
  },
  headerTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 17, color: COLORS.text },

  tabs: {
    flexDirection: 'row',
    borderBottomWidth: 1, borderBottomColor: COLORS.border,
  },
  tab: { flex: 1, paddingVertical: 14, alignItems: 'center' },
  tabActive: { borderBottomWidth: 2, borderBottomColor: COLORS.green },
  tabText:       { fontFamily: FONTS.bodyMedium, fontSize: 14, color: COLORS.muted2 },
  tabTextActive: { color: COLORS.green },

  list: { padding: SPACING.xl, gap: 12 },
  center: { flex: 1, alignItems: 'center', justifyContent: 'center' },

  card: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.xl,
    borderWidth: 1, borderColor: COLORS.border, padding: SPACING.lg,
  },
  cardTop: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center', marginBottom: 10 },
  statusPill: {
    flexDirection: 'row', alignItems: 'center', gap: 5,
    paddingHorizontal: 10, paddingVertical: 4,
    borderRadius: RADIUS.full, borderWidth: 1,
  },
  statusText:  { fontFamily: FONTS.bodyMedium, fontSize: 11 },
  cardDate:    { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted },
  clientName:  { fontFamily: FONTS.title, fontSize: 18, color: COLORS.text, marginBottom: 2 },
  eventTypeText: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted2, marginBottom: 10 },
  infoRow:     { flexDirection: 'row', gap: 14, marginBottom: 4 },
  infoText:    { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2 },
  locationText: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, marginBottom: 10 },
  priceRow:    { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', marginBottom: 10, backgroundColor: COLORS.greenMuted, padding: 10, borderRadius: RADIUS.md },
  priceLabelTxt: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.green },
  priceValueTxt: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.green },
  cardFooter:  { borderTopWidth: 1, borderTopColor: COLORS.border, paddingTop: 10, alignItems: 'flex-end' },
  cardCta:     { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.green },

  empty:      { flex: 1, alignItems: 'center', justifyContent: 'center', paddingTop: 80 },
  emptyEmoji: { fontSize: 48, marginBottom: 16 },
  emptyTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 18, color: COLORS.text, marginBottom: 8 },
  emptySub:   { fontFamily: FONTS.body, fontSize: 14, color: COLORS.muted2, textAlign: 'center', lineHeight: 22, paddingHorizontal: 40 },
});
