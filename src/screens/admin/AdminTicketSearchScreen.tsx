import { ArrowLeft, Search } from 'lucide-react-native';
import React, { useEffect, useState } from 'react';
import {
  ActivityIndicator,
  Alert,
  Pressable,
  StyleSheet,
  Text,
  TextInput,
  View,
} from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { supabase } from '../../config/supabase';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';

export default function AdminTicketSearchScreen({ navigation, route }: any) {
  const [folio,    setFolio]    = useState('');
  const [loading,  setLoading]  = useState(false);
  const [result,   setResult]   = useState<any | null>(null);
  const [searched, setSearched] = useState(false);

  // Si llega con reservationId (botón "Ver" de las colas del admin), carga el
  // evento directo por id — sin pedir el folio a mano.
  const reservationId: string | undefined = route?.params?.reservationId;
  useEffect(() => {
    if (!reservationId) return;
    let cancelled = false;
    (async () => {
      setLoading(true);
      setSearched(true);
      const { data, error } = await supabase
        .from('reservations')
        .select('*, group:groups(name, profile_image), quote:quotes!left(event_type, duration_hours), hours_count')
        .eq('id', reservationId)
        .maybeSingle();
      if (cancelled) return;
      setLoading(false);
      if (error) { Alert.alert('Error', error.message); return; }
      setResult(data);
      if (data?.folio) setFolio(String(data.folio));
    })();
    return () => { cancelled = true; };
  }, [reservationId]);

  const search = async () => {
    const q = folio.trim().toUpperCase();
    if (!q) { Alert.alert('Escribe un folio para buscar'); return; }
    setLoading(true);
    setSearched(true);
    setResult(null);
    const { data, error } = await supabase
      .from('reservations')
      .select('*, group:groups(name, profile_image), quote:quotes!left(event_type, duration_hours), hours_count')
      .eq('folio', q)
      .maybeSingle();
    setLoading(false);
    if (error) { Alert.alert('Error', error.message); return; }
    setResult(data);
  };

  return (
    <SafeAreaView style={s.safe} edges={['top']}>
      {/* Header */}
      <View style={s.header}>
        <Pressable onPress={() => navigation.goBack()} style={s.back}>
          <ArrowLeft size={22} color={COLORS.text} />
        </Pressable>
        <Text style={s.headerTitle}>Buscar ticket por folio</Text>
        <View style={{ width: 30 }} />
      </View>

      {/* Search */}
      <View style={s.searchRow}>
        <TextInput
          style={s.input}
          placeholder="DRC-2026-0001"
          placeholderTextColor={COLORS.muted}
          value={folio}
          onChangeText={setFolio}
          autoCapitalize="characters"
          autoCorrect={false}
          returnKeyType="search"
          onSubmitEditing={search}
        />
        <Pressable style={s.searchBtn} onPress={search} disabled={loading}>
          {loading
            ? <ActivityIndicator size="small" color={COLORS.bg} />
            : <Search size={18} color={COLORS.bg} />}
        </Pressable>
      </View>

      {/* No result */}
      {searched && !loading && result === null && (
        <View style={s.empty}>
          <Text style={s.emptyText}>Folio no encontrado</Text>
        </View>
      )}

      {/* Result card */}
      {result && (
        <View style={s.card}>
          <Text style={s.folioValue}>{result.folio}</Text>
          <Text style={s.groupName}>{result.group?.name ?? 'Grupo'}</Text>
          <Text style={s.detail}>{result.event_date ?? '—'} · {result.quote?.event_type ?? 'Evento'}</Text>
          {!!result.address && <Text style={s.detail}>{result.address}</Text>}
          <Text style={[s.detail, { color: COLORS.green, marginTop: 2 }]}>
            ${result.total_price?.toLocaleString()} MXN · {result.status}
          </Text>

          <Pressable
            style={s.ticketBtn}
            onPress={() => navigation.navigate('Ticket', { reservation: result })}
          >
            <Text style={s.ticketBtnText}>🎟 Ver ticket completo</Text>
          </Pressable>
        </View>
      )}
    </SafeAreaView>
  );
}

const s = StyleSheet.create({
  safe:        { flex: 1, backgroundColor: COLORS.bg },
  header:      {
    flexDirection: 'row', alignItems: 'center',
    paddingHorizontal: SPACING.md, paddingVertical: SPACING.sm,
    borderBottomWidth: 1, borderBottomColor: COLORS.border,
  },
  back:        { padding: 4, marginRight: SPACING.sm },
  headerTitle: { flex: 1, fontFamily: FONTS.title, fontSize: 18, color: COLORS.text },

  searchRow: { flexDirection: 'row', gap: 8, padding: SPACING.md },
  input: {
    flex: 1, backgroundColor: COLORS.card, borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: COLORS.border,
    paddingHorizontal: 14, paddingVertical: 12,
    fontFamily: FONTS.bodyMedium, fontSize: 15, color: COLORS.text,
  },
  searchBtn: {
    backgroundColor: COLORS.green, borderRadius: RADIUS.md,
    width: 48, alignItems: 'center', justifyContent: 'center',
  },

  empty:     { flex: 1, alignItems: 'center', justifyContent: 'center' },
  emptyText: { fontFamily: FONTS.bodyMedium, fontSize: 15, color: COLORS.muted },

  card: {
    margin: SPACING.md, backgroundColor: COLORS.card,
    borderRadius: RADIUS.xl, borderWidth: 1, borderColor: COLORS.border,
    padding: SPACING.lg, gap: 6,
  },
  folioValue: { fontFamily: FONTS.title, fontSize: 22, color: COLORS.green, marginBottom: 4 },
  groupName:  { fontFamily: FONTS.bodySemiBold, fontSize: 16, color: COLORS.text },
  detail:     { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2 },

  ticketBtn: {
    marginTop: SPACING.sm, backgroundColor: COLORS.green,
    borderRadius: RADIUS.md, paddingVertical: 12,
    alignItems: 'center',
  },
  ticketBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.bg },
});
