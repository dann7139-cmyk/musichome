/**
 * AdminTicketSearchScreen — 📂 EXPEDIENTE del admin.
 *
 * UNA caja de búsqueda: folio parcial ("0001"), nombre de cliente, nombre
 * de grupo o teléfono → filas compactas → tap abre el expediente completo:
 * teléfonos (tap = llamar), mini-perfiles con historial, dirección + mapa,
 * evidencia GPS, pago, y los últimos eventos de ese cliente/grupo para
 * saltar entre expedientes.
 *
 * Sigue aceptando route.params.reservationId (botón "Ver" de las colas)
 * para abrir el expediente directo. RPCs: sql/488.
 */
import { ArrowLeft, Search } from 'lucide-react-native';
import React, { useEffect, useState } from 'react';
import {
  ActivityIndicator,
  Alert,
  Image,
  Linking,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  View,
} from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { supabase } from '../../config/supabase';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';

const STATUS_ES: Record<string, string> = {
  completed: '🏁 Completado', in_progress: '🔴 En curso', accepted: '✅ Pagado',
  confirmed: '✅ Confirmado', cancelled: '❌ Cancelado', rejected: '🚫 Rechazado',
  pending: '⏳ Pendiente', pending_payment: '⏳ Por pagar', expired: '⌛ Expirado',
};
const stLabel = (s?: string | null) => STATUS_ES[s ?? ''] ?? (s ?? '—');
const money = (n: any, cur = 'MXN') =>
  `$${Number(n ?? 0).toLocaleString('es-MX', { maximumFractionDigits: 0 })} ${cur}`;
const fecha = (d?: string | null) =>
  d ? new Date(String(d).substring(0, 10) + 'T12:00:00').toLocaleDateString('es-MX', { day: '2-digit', month: 'short', year: '2-digit' }) : '—';
const hora = (t?: string | null) => {
  if (!t) return null;
  const [h, m] = String(t).split(':').map(Number);
  return `${h % 12 || 12}:${String(m ?? 0).padStart(2, '0')} ${h >= 12 ? 'pm' : 'am'}`;
};
const call = (phone?: string | null) => { if (phone) Linking.openURL(`tel:${phone}`); };

export default function AdminTicketSearchScreen({ navigation, route }: any) {
  const [query,    setQuery]    = useState('');
  const [loading,  setLoading]  = useState(false);
  const [results,  setResults]  = useState<any[] | null>(null);
  const [detail,   setDetail]   = useState<any | null>(null);

  const openDetail = async (reservationId: string) => {
    setLoading(true);
    const { data, error } = await supabase.rpc('admin_expediente_detail', {
      p_reservation_id: reservationId,
    });
    setLoading(false);
    if (error || (data as any)?.ok === false) {
      Alert.alert('Error', (data as any)?.error ?? error?.message ?? 'No se pudo cargar el expediente.');
      return;
    }
    setDetail(data);
  };

  // Botón "Ver" de las colas del admin → expediente directo
  const reservationId: string | undefined = route?.params?.reservationId;
  useEffect(() => {
    if (reservationId) void openDetail(reservationId);
  }, [reservationId]);

  const search = async () => {
    const q = query.trim();
    if (q.length < 3) { Alert.alert('Escribe al menos 3 letras o números'); return; }
    setLoading(true);
    setDetail(null);
    const { data, error } = await supabase.rpc('admin_search_expediente', { p_query: q });
    setLoading(false);
    if (error || (data as any)?.ok === false) {
      Alert.alert('Error', (data as any)?.error ?? error?.message ?? 'No se pudo buscar.');
      return;
    }
    setResults((data as any)?.items ?? []);
  };

  const r  = detail?.reservation;
  const cl = detail?.client;
  const gr = detail?.group;

  return (
    <SafeAreaView style={s.safe} edges={['top']}>
      {/* Header */}
      <View style={s.header}>
        <Pressable
          onPress={() => { if (detail && results) setDetail(null); else navigation.goBack(); }}
          style={s.back}
        >
          <ArrowLeft size={22} color={COLORS.text} />
        </Pressable>
        <Text style={s.headerTitle}>{detail ? `📂 ${r?.folio ?? 'Expediente'}` : '📂 Expediente'}</Text>
        <View style={{ width: 30 }} />
      </View>

      {/* Search (oculta cuando hay expediente abierto) */}
      {!detail && (
        <View style={s.searchRow}>
          <TextInput
            style={s.input}
            placeholder="Folio, cliente, grupo o teléfono"
            placeholderTextColor={COLORS.muted}
            value={query}
            onChangeText={setQuery}
            autoCorrect={false}
            returnKeyType="search"
            onSubmitEditing={search}
          />
          <Pressable style={s.searchBtn} onPress={search} disabled={loading}>
            {loading && !detail
              ? <ActivityIndicator size="small" color={COLORS.bg} />
              : <Search size={18} color={COLORS.bg} />}
          </Pressable>
        </View>
      )}

      <ScrollView contentContainerStyle={s.scroll} showsVerticalScrollIndicator={false}>

        {/* ── Resultados compactos ── */}
        {!detail && results !== null && (
          results.length === 0
            ? <Text style={s.emptyText}>Sin resultados — prueba con otra parte del folio, nombre o teléfono.</Text>
            : results.map((it: any) => (
                <Pressable key={it.id} style={s.rowCard} onPress={() => openDetail(it.id)}>
                  <View style={{ flex: 1 }}>
                    <Text style={s.rowFolio}>{it.folio ?? it.id.substring(0, 8)}</Text>
                    <Text style={s.rowLine} numberOfLines={1}>
                      {it.group_name ?? '—'} → {it.client_name ?? '—'}
                    </Text>
                    <Text style={s.rowMeta}>
                      {fecha(it.event_date)}{hora(it.event_time) ? ` · ${hora(it.event_time)}` : ''} · {money(it.total_price, it.currency)}
                    </Text>
                  </View>
                  <Text style={s.rowStatus}>{stLabel(it.status)}</Text>
                </Pressable>
              ))
        )}

        {loading && detail === null && results === null && (
          <ActivityIndicator style={{ marginTop: 40 }} color={COLORS.green} />
        )}

        {/* ── 📂 Expediente completo ── */}
        {detail && r && (
          <>
            {/* Evento */}
            <View style={s.card}>
              <View style={s.cardHeadRow}>
                <Text style={s.folioBig}>{r.folio ?? '—'}</Text>
                <Text style={s.statusPill}>{stLabel(r.status)}</Text>
              </View>
              <Text style={s.detailLine}>
                📅 {fecha(r.event_date)}{hora(r.event_time) ? ` · ${hora(r.event_time)}` : ''}
                {r.hours_count ? ` · ${r.hours_count}h` : ''}{r.event_type ? ` · ${r.event_type}` : ''}
              </Text>
              {!!r.address && <Text style={s.detailLine}>📍 {r.address}</Text>}
              {r.event_lat != null && (
                <Pressable hitSlop={6} onPress={() => Linking.openURL(`https://www.google.com/maps/search/?api=1&query=${r.event_lat},${r.event_lng}`)}>
                  <Text style={s.mapLink}>🗺️ Ver dirección en el mapa</Text>
                </Pressable>
              )}
              <Text style={s.detailLine}>
                💰 {money(r.total_price, r.currency)} · {r.payment_method_type ? `${r.payment_method_type} · ` : ''}pago: {r.payment_status ?? '—'} · payout: {r.payout_status ?? '—'}
              </Text>
              {r.status === 'cancelled' && (
                <Text style={[s.detailLine, { color: '#EF5350' }]}>
                  ❌ Cancelado por: {r.cancelled_by ?? '—'}{r.cancel_reason ? ` · ${r.cancel_reason}` : ''}
                </Text>
              )}
              {/* Evidencia GPS */}
              <Text style={s.evidence}>
                🚐 En camino: {r.group_en_route_at ? '✅' : '✖️'}
                {'  ·  '}🔢 PIN: {r.event_started_at ? '✅' : '✖️'}
                {'  ·  '}📍 Llegada: {r.group_arrived_at ? (r.arrival_gps_verified ? '✅ GPS' : '⚠️ sin GPS') : '✖️'}
                {'  ·  '}🏁 Fin: {r.event_ended_at ? '✅' : '✖️'}
              </Text>
              {r.transit_lat != null && r.event_lat != null && (
                <Pressable hitSlop={6} onPress={() => Linking.openURL(`https://www.google.com/maps/dir/?api=1&origin=${r.transit_lat},${r.transit_lng}&destination=${r.event_lat},${r.event_lng}`)}>
                  <Text style={s.mapLink}>⚖️ Comparar rastro del grupo → evento</Text>
                </Pressable>
              )}
              <Pressable
                style={s.ticketBtn}
                onPress={async () => {
                  const { data } = await supabase
                    .from('reservations')
                    .select('*, group:groups(name, profile_image), quote:quotes!left(event_type, duration_hours), hours_count')
                    .eq('id', r.id).maybeSingle();
                  if (data) navigation.navigate('Ticket', { reservation: data });
                }}
              >
                <Text style={s.ticketBtnText}>🎟 Ver ticket completo</Text>
              </Pressable>
            </View>

            {/* Cliente */}
            <View style={s.card}>
              <Text style={s.sectionTitle}>👤 Cliente</Text>
              <View style={s.personRow}>
                {cl?.avatar
                  ? <Image source={{ uri: cl.avatar }} style={s.avatar} />
                  : <View style={[s.avatar, s.avatarEmpty]}><Text style={s.avatarTx}>{(cl?.name ?? '?').charAt(0)}</Text></View>}
                <View style={{ flex: 1 }}>
                  <Text style={s.personName}>{cl?.name ?? '—'} {cl?.verified ? '✓' : ''}</Text>
                  <Text style={s.personMeta}>
                    {cl?.events_total ?? 0} eventos · {cl?.events_completed ?? 0} completados · {cl?.events_cancelled ?? 0} cancelados
                    {(cl?.open_disputes ?? 0) > 0 ? ` · ⚠️ ${cl.open_disputes} disputa(s) abierta(s)` : ''}
                  </Text>
                </View>
              </View>
              {!!cl?.phone && (
                <Pressable style={s.phoneBtn} onPress={() => call(cl.phone)}>
                  <Text style={s.phoneBtnTx}>📞 {cl.phone} — llamar</Text>
                </Pressable>
              )}
            </View>

            {/* Grupo */}
            <View style={s.card}>
              <Text style={s.sectionTitle}>🎸 Grupo</Text>
              <View style={s.personRow}>
                {gr?.image
                  ? <Image source={{ uri: gr.image }} style={s.avatar} />
                  : <View style={[s.avatar, s.avatarEmpty]}><Text style={s.avatarTx}>{(gr?.name ?? '?').charAt(0)}</Text></View>}
                <View style={{ flex: 1 }}>
                  <Text style={s.personName}>{gr?.name ?? '—'} {gr?.verified ? '✓' : ''}</Text>
                  <Text style={s.personMeta}>
                    {gr?.events_total ?? 0} eventos · {gr?.events_completed ?? 0} completados · {gr?.events_cancelled ?? 0} cancelados
                    {(gr?.strikes ?? 0) > 0 ? ` · ⚡ ${gr.strikes} strike(s)` : ''}
                  </Text>
                  {!!gr?.owner_name && <Text style={s.personMeta}>Dueño: {gr.owner_name}</Text>}
                </View>
              </View>
              {!!gr?.phone && (
                <Pressable style={s.phoneBtn} onPress={() => call(gr.phone)}>
                  <Text style={s.phoneBtnTx}>📞 {gr.phone} — llamar</Text>
                </Pressable>
              )}
            </View>

            {/* Historial del cliente */}
            {(detail.client_history ?? []).length > 0 && (
              <View style={s.card}>
                <Text style={s.sectionTitle}>📋 Otros eventos de este cliente</Text>
                {detail.client_history.map((h: any) => (
                  <Pressable key={h.id} style={s.histRow} onPress={() => openDetail(h.id)}>
                    <Text style={s.histTx} numberOfLines={1}>
                      {h.folio ?? h.id.substring(0, 8)} · {fecha(h.event_date)} · {h.counterpart ?? '—'} · {money(h.total_price)}
                    </Text>
                    <Text style={s.histStatus}>{stLabel(h.status)}</Text>
                  </Pressable>
                ))}
              </View>
            )}

            {/* Historial del grupo */}
            {(detail.group_history ?? []).length > 0 && (
              <View style={s.card}>
                <Text style={s.sectionTitle}>📋 Otros eventos de este grupo</Text>
                {detail.group_history.map((h: any) => (
                  <Pressable key={h.id} style={s.histRow} onPress={() => openDetail(h.id)}>
                    <Text style={s.histTx} numberOfLines={1}>
                      {h.folio ?? h.id.substring(0, 8)} · {fecha(h.event_date)} · {h.counterpart ?? '—'} · {money(h.total_price)}
                    </Text>
                    <Text style={s.histStatus}>{stLabel(h.status)}</Text>
                  </Pressable>
                ))}
              </View>
            )}

            {loading && <ActivityIndicator style={{ marginVertical: 12 }} color={COLORS.green} />}
          </>
        )}
      </ScrollView>
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

  scroll: { padding: SPACING.md, paddingBottom: 40, gap: 10 },
  emptyText: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2, textAlign: 'center', marginTop: 30, lineHeight: 19 },

  // Fila compacta de resultados
  rowCard: {
    flexDirection: 'row', alignItems: 'center', gap: 8,
    backgroundColor: COLORS.card, borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: COLORS.border,
    paddingHorizontal: 12, paddingVertical: 10,
  },
  rowFolio:  { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.green },
  rowLine:   { fontFamily: FONTS.bodyMedium, fontSize: 12.5, color: COLORS.text, marginTop: 1 },
  rowMeta:   { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted2, marginTop: 1 },
  rowStatus: { fontFamily: FONTS.bodyMedium, fontSize: 11, color: COLORS.muted2 },

  // Expediente
  card: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border, padding: 14, gap: 5,
  },
  cardHeadRow: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' },
  folioBig:    { fontFamily: FONTS.title, fontSize: 20, color: COLORS.green, letterSpacing: 1 },
  statusPill:  { fontFamily: FONTS.bodySemiBold, fontSize: 12, color: COLORS.text },
  detailLine:  { fontFamily: FONTS.body, fontSize: 12.5, color: COLORS.text, lineHeight: 18 },
  evidence:    { fontFamily: FONTS.bodyMedium, fontSize: 11.5, color: COLORS.muted2, marginTop: 4 },
  mapLink:     { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.green, textDecorationLine: 'underline', marginTop: 2 },

  sectionTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 13.5, color: COLORS.text, marginBottom: 4 },
  personRow: { flexDirection: 'row', alignItems: 'center', gap: 10 },
  avatar:      { width: 44, height: 44, borderRadius: 22 },
  avatarEmpty: { backgroundColor: COLORS.card2, alignItems: 'center', justifyContent: 'center', borderWidth: 1, borderColor: COLORS.border },
  avatarTx:    { fontFamily: FONTS.bodySemiBold, fontSize: 17, color: COLORS.green },
  personName:  { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.text },
  personMeta:  { fontFamily: FONTS.body, fontSize: 11.5, color: COLORS.muted2, marginTop: 1 },
  phoneBtn: {
    marginTop: 8, backgroundColor: 'rgba(0,230,118,0.08)',
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.35)',
    borderRadius: RADIUS.md, paddingVertical: 9, alignItems: 'center',
  },
  phoneBtnTx: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.green },

  histRow: {
    flexDirection: 'row', alignItems: 'center', gap: 8,
    paddingVertical: 7, borderTopWidth: 1, borderTopColor: COLORS.border,
  },
  histTx:     { flex: 1, fontFamily: FONTS.body, fontSize: 11.5, color: COLORS.text },
  histStatus: { fontFamily: FONTS.bodyMedium, fontSize: 10.5, color: COLORS.muted2 },

  ticketBtn: {
    marginTop: 8, backgroundColor: COLORS.green,
    borderRadius: RADIUS.md, paddingVertical: 11, alignItems: 'center',
  },
  ticketBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 13.5, color: COLORS.bg },
});
