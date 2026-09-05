import { ArrowLeft, Phone, Volume2 } from 'lucide-react-native';
import React, { useCallback, useEffect, useState } from 'react';
import {
  ActivityIndicator,
  FlatList,
  Linking,
  Pressable,
  RefreshControl,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { useTranslation } from 'react-i18next';
import { supabase } from '../../config/supabase';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';

// sql/589 + sql/590 (2026-09-01) — cola de "eventos que necesitan que TÚ
// coordines" en vez de dejar que cada grupo cotice por su cuenta: 2+
// proveedores en el mismo evento Y alguien declaró el nivel GRANDE de
// sonido/luz/escenario/led. Antes de esta pantalla, admin_get_event_detail
// (sql/585) ya calculaba esta señal pero no había forma de DESCUBRIR estos
// eventos sin ya saber qué folio buscar — este es el punto de entrada.
//
// Un evento con 2+ proveedores y sonido/luz normal NUNCA aparece aquí —
// esos se dejan que los grupos coticen solos, tal como se pidió.

interface ReviewItem {
  event_id: string;
  event_date: string;
  address: string | null;
  client_name: string | null;
  provider_count: number;
  max_needs_sound: string | null;
  requested_by: string[];
  // sql/594 — teléfono de CADA proveedor del evento (no solo quien
  // declaró equipo grande), para que el admin pueda llamar a cualquiera
  // si algo sale mal, aunque se espera que los grupos se coordinen solos.
  providers: { group_name: string; phone: string | null }[];
}

export default function AdminEventsReviewScreen({ navigation }: any) {
  const { t, i18n } = useTranslation();
  const [loading, setLoading]     = useState(true);
  const [refreshing, setRefreshing] = useState(false);
  const [items, setItems]         = useState<ReviewItem[]>([]);

  const dateLocale = i18n.language?.startsWith('en') ? 'en-US' : 'es-MX';

  const SOUND_LABEL: Record<string, string> = {
    si_50:  t('adminEventDetailScreen.needsSound.si_50'),
    si_100: t('adminEventDetailScreen.needsSound.si_100'),
    si_200: t('adminEventDetailScreen.needsSound.si_200'),
    si:     t('adminEventDetailScreen.needsSound.si'),
  };

  const load = useCallback(async () => {
    const { data, error } = await supabase.rpc('admin_get_events_needing_review');
    if (!error && data?.ok) setItems(data.items ?? []);
    setLoading(false);
    setRefreshing(false);
  }, []);

  useEffect(() => { load(); }, [load]);

  const onRefresh = () => { setRefreshing(true); load(); };

  if (loading) {
    return (
      <View style={{ flex: 1, backgroundColor: COLORS.bg, alignItems: 'center', justifyContent: 'center' }}>
        <ActivityIndicator color={COLORS.green} />
      </View>
    );
  }

  return (
    <View style={{ flex: 1, backgroundColor: COLORS.bg }}>
      <SafeAreaView edges={['top']} style={s.header}>
        <Pressable onPress={() => navigation.goBack()} hitSlop={8}>
          <ArrowLeft size={20} color={COLORS.text} />
        </Pressable>
        <Text style={s.headerTitle}>{t('adminEventsReviewScreen.headerTitle')}</Text>
        <View style={{ width: 20 }} />
      </SafeAreaView>

      <Text style={s.headerHint}>{t('adminEventsReviewScreen.headerHint')}</Text>

      <FlatList
        data={items}
        keyExtractor={(it) => it.event_id}
        contentContainerStyle={s.list}
        refreshControl={<RefreshControl refreshing={refreshing} onRefresh={onRefresh} tintColor={COLORS.green} />}
        ListEmptyComponent={
          <View style={s.emptyBox}>
            <Text style={s.emptyIcon}>✅</Text>
            <Text style={s.emptyTx}>{t('adminEventsReviewScreen.empty')}</Text>
            <Text style={s.emptyHint}>{t('adminEventsReviewScreen.emptyHint')}</Text>
          </View>
        }
        renderItem={({ item }) => (
          <Pressable
            style={s.card}
            onPress={() => navigation.navigate('AdminEventDetail', { eventId: item.event_id })}
          >
            <View style={s.cardRow}>
              <Volume2 size={16} color={COLORS.orange} />
              <Text style={s.cardDate}>
                {new Date(item.event_date + 'T12:00:00').toLocaleDateString(dateLocale, { weekday: 'short', day: 'numeric', month: 'short' })}
              </Text>
              <View style={s.providersPill}>
                <Text style={s.providersPillText}>{t('adminEventsReviewScreen.providersCount', { count: item.provider_count })}</Text>
              </View>
            </View>
            {!!item.address && <Text style={s.cardAddress} numberOfLines={1}>📍 {item.address}</Text>}
            {!!item.client_name && <Text style={s.cardClient} numberOfLines={1}>👤 {item.client_name}</Text>}
            <Text style={s.cardSound}>
              {item.max_needs_sound && SOUND_LABEL[item.max_needs_sound]
                ? SOUND_LABEL[item.max_needs_sound]
                : t('adminEventsReviewScreen.bigSetup')}
              {!!item.requested_by?.length && ` · ${t('adminEventsReviewScreen.requestedBy', { names: item.requested_by.join(', ') })}`}
            </Text>

            {/* sql/594 — teléfono de cada proveedor, por si el admin
                necesita intervenir aunque se espera que se coordinen solos. */}
            {!!item.providers?.length && (
              <View style={s.providersList}>
                {item.providers.map(p => (
                  <View key={p.group_name} style={s.providerRow}>
                    <Text style={s.providerRowName} numberOfLines={1}>{p.group_name}</Text>
                    {p.phone ? (
                      <Pressable
                        style={s.providerCallBtn}
                        onPress={() => Linking.openURL(`tel:${p.phone}`)}
                      >
                        <Phone size={12} color={COLORS.green} />
                        <Text style={s.providerCallBtnText}>{p.phone}</Text>
                      </Pressable>
                    ) : (
                      <Text style={s.providerNoPhone}>{t('adminEventsReviewScreen.noPhone')}</Text>
                    )}
                  </View>
                ))}
              </View>
            )}
          </Pressable>
        )}
      />
    </View>
  );
}

const s = StyleSheet.create({
  header: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between',
    paddingHorizontal: SPACING.xl, paddingBottom: 8,
  },
  headerTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 16, color: COLORS.text },
  headerHint: {
    fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2,
    paddingHorizontal: SPACING.xl, paddingBottom: 12,
  },
  list: { padding: SPACING.xl, paddingTop: 4, gap: 12 },
  card: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg, borderWidth: 1,
    borderColor: COLORS.orange + '40', padding: 14, gap: 6,
  },
  cardRow: { flexDirection: 'row', alignItems: 'center', gap: 8 },
  cardDate: { flex: 1, fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.text },
  providersPill: {
    backgroundColor: 'rgba(255,152,0,0.15)', borderRadius: RADIUS.full,
    paddingHorizontal: 10, paddingVertical: 3,
  },
  providersPillText: { fontFamily: FONTS.bodyMedium, fontSize: 11, color: COLORS.orange },
  cardAddress: { fontFamily: FONTS.body, fontSize: 12.5, color: COLORS.muted2 },
  cardClient: { fontFamily: FONTS.body, fontSize: 12.5, color: COLORS.muted2 },
  cardSound: { fontFamily: FONTS.bodyMedium, fontSize: 12.5, color: COLORS.orange, marginTop: 2 },
  providersList: {
    marginTop: 8, paddingTop: 8, borderTopWidth: 1, borderTopColor: COLORS.border, gap: 6,
  },
  providerRow: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', gap: 8 },
  providerRowName: { flex: 1, fontFamily: FONTS.body, fontSize: 12.5, color: COLORS.muted2 },
  providerCallBtn: {
    flexDirection: 'row', alignItems: 'center', gap: 4,
    paddingHorizontal: 8, paddingVertical: 4, borderRadius: RADIUS.md,
    backgroundColor: COLORS.greenMuted, borderWidth: 1, borderColor: COLORS.green,
  },
  providerCallBtnText: { fontFamily: FONTS.bodyMedium, fontSize: 11.5, color: COLORS.green },
  providerNoPhone: { fontFamily: FONTS.body, fontSize: 11.5, color: COLORS.muted },
  emptyBox: { alignItems: 'center', paddingTop: 80, gap: 6, paddingHorizontal: SPACING.xl },
  emptyIcon: { fontSize: 40 },
  emptyTx: { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.text },
  emptyHint: { fontFamily: FONTS.body, fontSize: 12.5, color: COLORS.muted2, textAlign: 'center' },
});
