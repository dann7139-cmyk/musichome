/**
 * AdminManagedQuotesScreen — "Cotizaciones que manejo" (modo conserjería).
 *
 * Dos pestañas:
 * - Cotizaciones: solicitudes pendientes de grupos que todavía no manejan
 *   su propia cuenta (groups.concierge_mode = true, sql/648). El admin
 *   llama al grupo por teléfono, le pregunta su precio, y lo captura
 *   aquí — admin_respond_quote hace el resto exactamente como si el
 *   grupo mismo hubiera respondido.
 * - En vivo: eventos de esos mismos grupos que ya están en curso — el
 *   admin puede proponerle horas extra al cliente en nombre del grupo
 *   (admin_propose_extra_hours, sql/651), ya que el grupo normalmente no
 *   entra a la app a hacerlo él mismo desde EventTimerScreen.
 *
 * Compartida entre role='admin' (ve todos los países) y role='admin_ops'
 * (solo su país) — los RPCs ya filtran, la pantalla no necesita saberlo.
 */
import { ArrowLeft, Phone, DollarSign, Calendar, MapPin, Clock, Copy, Check } from 'lucide-react-native';
import * as Clipboard from 'expo-clipboard';
import React, { useCallback, useEffect, useState } from 'react';
import {
  ActivityIndicator,
  Alert,
  Linking,
  Modal,
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
import {
  EVENT_TYPE_LABELS, COVERED_LABELS, VENUE_LABELS, SOUND_LABELS,
  LIGHTING_LABELS, STAGE_LABELS, LED_LABELS,
} from '../../components/quote/QuoteFormShared';

const call = (phone?: string | null) => { if (phone) Linking.openURL(`tel:${phone}`); };
const openInMaps = (addr: string) => Linking.openURL(`https://maps.google.com/maps?q=${encodeURIComponent(addr)}`);
const fecha = (d?: string | null) =>
  d ? new Date(String(d).substring(0, 10) + 'T12:00:00').toLocaleDateString('es-MX', { day: '2-digit', month: 'short', year: '2-digit' }) : '—';
const hora = (t?: string | null) => {
  if (!t) return null;
  const [h, m] = String(t).split(':').map(Number);
  return `${h % 12 || 12}:${String(m ?? 0).padStart(2, '0')} ${h >= 12 ? 'pm' : 'am'}`;
};

interface QuoteItem {
  quote_id: string;
  group_id: string;
  group_name: string;
  group_phone: string | null;
  group_genre: string | null;
  country: string;
  client_name: string | null;
  client_phone: string | null;
  event_type: string | null;
  event_date: string;
  event_time: string | null;
  duration_hours: number | null;
  num_personas: number | null;
  event_address: string | null;
  event_municipio: string | null;
  event_estado: string | null;
  venue_covered: string | null;
  venue_size: string | null;
  needs_sound: string | null;
  needs_lighting: string | null;
  needs_stage: string | null;
  needs_led: string | null;
  category_details: Record<string, any> | null;
  is_gift: boolean | null;
  gift_recipient_name: string | null;
  comments: string | null;
}

interface LiveItem {
  reservation_id: string;
  group_id: string;
  group_name: string;
  group_phone: string | null;
  client_name: string | null;
  client_phone: string | null;
  event_date: string;
  hours_count: number | null;
  event_started_at: string | null;
  address: string | null;
  country: string;
  negotiated_1h: number | null;
  negotiated_2h: number | null;
  negotiated_3h: number | null;
}

type TabKey = 'quotes' | 'live';

export default function AdminManagedQuotesScreen({ navigation }: any) {
  const [tab, setTab] = useState<TabKey>('quotes');

  const [items, setItems] = useState<QuoteItem[]>([]);
  const [loading, setLoading] = useState(true);
  const [refreshing, setRefreshing] = useState(false);
  const [priceModal, setPriceModal] = useState<QuoteItem | null>(null);
  const [basePrice, setBasePrice] = useState('');
  const [travelCost, setTravelCost] = useState('');
  const [overtime1h, setOvertime1h] = useState('');
  const [overtime2h, setOvertime2h] = useState('');
  const [overtime3h, setOvertime3h] = useState('');
  const [notes, setNotes] = useState('');
  const [sending, setSending] = useState(false);

  const [liveItems, setLiveItems] = useState<LiveItem[]>([]);
  const [liveLoading, setLiveLoading] = useState(true);
  const [liveRefreshing, setLiveRefreshing] = useState(false);
  const [extraModal, setExtraModal] = useState<LiveItem | null>(null);
  const [extraHours, setExtraHours] = useState(1);
  const [extraPrice, setExtraPrice] = useState('');
  const [extraNotes, setExtraNotes] = useState('');
  const [sendingExtra, setSendingExtra] = useState(false);

  const [copiedKey, setCopiedKey] = useState<string | null>(null);
  const copyText = async (key: string, value: string) => {
    await Clipboard.setStringAsync(value);
    setCopiedKey(key);
    setTimeout(() => setCopiedKey(k => (k === key ? null : k)), 2000);
  };

  // Apagar conserjería desde aquí mismo, sin ir a la pantalla de Grupos —
  // mismo texto/patrón que AdminGroupsScreen (sql/648). Lo pendiente que
  // ya esté en esta lista no se pierde: al desactivar, el grupo simplemente
  // puede entrar a su propia cuenta y responderlo él mismo desde ahora.
  const turnOffConcierge = (groupId: string, groupName: string) => {
    Alert.alert(
      'Desactivar modo conserjería',
      `${groupName} volverá a recibir y responder sus propias cotizaciones desde su cuenta.`,
      [
        { text: 'Cancelar', style: 'cancel' },
        {
          text: 'Desactivar',
          onPress: async () => {
            const { error } = await supabase.from('groups').update({ concierge_mode: false }).eq('id', groupId);
            if (error) {
              Alert.alert('Error', error.message);
              return;
            }
            setItems(prev => prev.filter(i => i.group_id !== groupId));
            setLiveItems(prev => prev.filter(i => i.group_id !== groupId));
          },
        },
      ],
    );
  };

  const loadQuotes = useCallback(async () => {
    const { data, error } = await supabase.rpc('admin_get_concierge_quotes', { p_limit: 100 });
    if (!error && data?.ok) setItems(data.items ?? []);
    setLoading(false);
    setRefreshing(false);
  }, []);

  const loadLive = useCallback(async () => {
    const { data, error } = await supabase.rpc('admin_get_concierge_live_reservations', { p_limit: 100 });
    if (!error && data?.ok) setLiveItems(data.items ?? []);
    setLiveLoading(false);
    setLiveRefreshing(false);
  }, []);

  useEffect(() => { loadQuotes(); }, [loadQuotes]);
  useEffect(() => { loadLive(); }, [loadLive]);

  const onRefresh = () => { setRefreshing(true); loadQuotes(); };
  const onRefreshLive = () => { setLiveRefreshing(true); loadLive(); };

  const openPriceModal = (item: QuoteItem) => {
    setPriceModal(item);
    setBasePrice('');
    setTravelCost('');
    setOvertime1h('');
    setOvertime2h('');
    setOvertime3h('');
    setNotes('');
  };

  const sendPrice = async () => {
    if (!priceModal) return;
    const price = Number(basePrice.replace(',', '.'));
    if (!Number.isFinite(price) || price <= 0) {
      Alert.alert('Precio inválido', 'Escribe el precio neto que pidió el grupo por teléfono.');
      return;
    }
    setSending(true);
    const { data, error } = await supabase.rpc('admin_respond_quote', {
      p_quote_id: priceModal.quote_id,
      p_base_price: price,
      p_travel_cost: travelCost ? Number(travelCost.replace(',', '.')) : 0,
      p_overtime_1h_price: overtime1h ? Number(overtime1h.replace(',', '.')) : null,
      p_overtime_2h_price: overtime2h ? Number(overtime2h.replace(',', '.')) : null,
      p_overtime_3h_price: overtime3h ? Number(overtime3h.replace(',', '.')) : null,
      p_notes: notes.trim() || null,
    });
    setSending(false);
    if (error || !data?.ok) {
      Alert.alert('Error', error?.message ?? data?.error ?? 'No se pudo enviar la cotización.');
      return;
    }
    setPriceModal(null);
    setItems(prev => prev.filter(i => i.quote_id !== priceModal.quote_id));
    Alert.alert('✅ Enviada', `Se le mandó la cotización al cliente. Total con tu comisión: $${Number(data.total_amount).toLocaleString('es-MX')}.`);
  };

  // Cada número de horas extra (1/2/3) tiene su PROPIO precio total ya
  // negociado — el grupo puede dar descuento por volumen (ej. 2h no es
  // necesariamente el doble de 1h), exactamente igual que cuando el grupo
  // responde su propia cotización. No es un precio por hora × N.
  const negotiatedFor = (item: LiveItem | null, hours: number): number | null => {
    if (!item) return null;
    if (hours === 1) return item.negotiated_1h;
    if (hours === 2) return item.negotiated_2h;
    if (hours === 3) return item.negotiated_3h;
    return null;
  };

  const openExtraModal = (item: LiveItem) => {
    setExtraModal(item);
    setExtraHours(1);
    // El precio ya negociado para 1h (el que capturaste al poner el precio
    // inicial) se precarga solo — no hay que volver a preguntarle al grupo,
    // a menos que quieras cambiarlo. Cambia solo si tocas otro chip de horas.
    const pre = negotiatedFor(item, 1);
    setExtraPrice(pre ? String(pre) : '');
    setExtraNotes('');
  };

  const selectExtraHours = (h: number) => {
    setExtraHours(h);
    const pre = negotiatedFor(extraModal, h);
    setExtraPrice(pre ? String(pre) : '');
  };

  const sendExtraHours = async () => {
    if (!extraModal) return;
    setSendingExtra(true);
    const { data, error } = await supabase.rpc('admin_propose_extra_hours', {
      p_reservation_id: extraModal.reservation_id,
      p_hours: extraHours,
      p_bundle_price_net: extraPrice ? Number(extraPrice.replace(',', '.')) : null,
      p_notes: extraNotes.trim() || null,
    });
    setSendingExtra(false);
    if (error || !data?.ok) {
      const err = data?.error;
      const msg =
        err === 'missing_price' ? 'No hay un precio de hora extra guardado para este grupo — escribe cuánto cobra.' :
        err === 'event_not_in_progress' ? 'Este evento ya no está en curso.' :
        error?.message ?? err ?? 'No se pudo proponer la hora extra.';
      Alert.alert('No se pudo', msg);
      return;
    }
    setExtraModal(null);
    Alert.alert('✅ Propuesta enviada', `Se le mandó al cliente ${extraHours}h extra por $${Number(data.total_extra_cost).toLocaleString('es-MX')}. Falta que la apruebe y pague.`);
  };

  return (
    <View style={s.container}>
      <SafeAreaView style={{ flex: 1 }}>
        <View style={s.header}>
          <Pressable style={s.backBtn} onPress={() => navigation.goBack()}>
            <ArrowLeft size={20} color={COLORS.text} />
          </Pressable>
          <Text style={s.headerTitle}>📞 Cotizaciones que manejo</Text>
          <View style={{ width: 40 }} />
        </View>

        <View style={s.tabs}>
          <Pressable style={[s.tabBtn, tab === 'quotes' && s.tabBtnActive]} onPress={() => setTab('quotes')}>
            <Text style={[s.tabBtnText, tab === 'quotes' && s.tabBtnTextActive]}>Cotizaciones</Text>
          </Pressable>
          <Pressable style={[s.tabBtn, tab === 'live' && s.tabBtnActive]} onPress={() => setTab('live')}>
            <Text style={[s.tabBtnText, tab === 'live' && s.tabBtnTextActive]}>🔴 En vivo</Text>
          </Pressable>
        </View>

        {tab === 'quotes' ? (
          loading ? (
            <View style={s.center}><ActivityIndicator size="large" color={COLORS.green} /></View>
          ) : items.length === 0 ? (
            <View style={s.center}>
              <Text style={{ fontSize: 40 }}>📞</Text>
              <Text style={s.emptyTitle}>Nada pendiente</Text>
              <Text style={s.emptyText}>Aquí aparecen las cotizaciones de grupos en modo conserjería.</Text>
            </View>
          ) : (
            <ScrollView
              contentContainerStyle={{ padding: SPACING.xl, gap: 12 }}
              refreshControl={<RefreshControl refreshing={refreshing} onRefresh={onRefresh} tintColor={COLORS.green} />}
            >
              {items.map(item => (
                <View key={item.quote_id} style={s.card}>
                  <View style={s.cardHeader}>
                    <View style={{ flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' }}>
                      <Text style={s.groupName} numberOfLines={1}>{item.group_name}</Text>
                      <Pressable onPress={() => turnOffConcierge(item.group_id, item.group_name)}>
                        <Text style={s.conciergeOffText}>Apagar conserjería</Text>
                      </Pressable>
                    </View>
                    <Text style={s.genre}>{item.group_genre ?? ''} · {item.country}</Text>
                  </View>

                  <Pressable style={s.callRow} onPress={() => call(item.group_phone)} disabled={!item.group_phone}>
                    <Phone size={13} color={COLORS.green} />
                    <Text style={s.callText}>Grupo: {item.group_phone ?? 'sin teléfono'}</Text>
                  </Pressable>
                  <Pressable style={s.callRow} onPress={() => call(item.client_phone)} disabled={!item.client_phone}>
                    <Phone size={13} color={COLORS.gold} />
                    <Text style={s.callText}>{item.client_name ?? 'Cliente'}: {item.client_phone ?? 'sin teléfono'}</Text>
                  </Pressable>

                  <View style={s.infoRow}>
                    <Calendar size={13} color={COLORS.muted2} />
                    <Text style={s.infoText}>
                      {fecha(item.event_date)}{item.event_time ? ` · ${hora(item.event_time)}` : ''}
                      {item.duration_hours ? ` · ${item.duration_hours}h` : ''}
                    </Text>
                  </View>

                  {/* Todo lo que llenó el cliente — el admin negocia por
                      teléfono en nombre del grupo, necesita verlo completo. */}
                  <View style={s.detailsBox}>
                    <Text style={s.detailsLine}>
                      {EVENT_TYPE_LABELS[item.event_type ?? ''] ?? item.event_type ?? '—'}
                      {item.num_personas ? ` · ${item.num_personas} personas` : ''}
                    </Text>
                    {(item.venue_covered || item.venue_size) && (
                      <Text style={s.detailsLine}>
                        {item.venue_size ? VENUE_LABELS[item.venue_size] ?? item.venue_size : ''}
                        {item.venue_covered ? ` · ${COVERED_LABELS[item.venue_covered] ?? item.venue_covered}` : ''}
                      </Text>
                    )}
                    {item.needs_sound && (
                      <Text style={s.detailsLine}>🎵 {SOUND_LABELS[item.needs_sound] ?? item.needs_sound}</Text>
                    )}
                    {item.needs_lighting && item.needs_lighting !== 'no' && (
                      <Text style={s.detailsLine}>💡 Iluminación: {LIGHTING_LABELS[item.needs_lighting] ?? item.needs_lighting}</Text>
                    )}
                    {item.needs_stage && item.needs_stage !== 'no' && (
                      <Text style={s.detailsLine}>🎭 Tarima: {STAGE_LABELS[item.needs_stage] ?? item.needs_stage}</Text>
                    )}
                    {item.needs_led && item.needs_led !== 'no' && (
                      <Text style={s.detailsLine}>📺 Pantalla LED: {LED_LABELS[item.needs_led] ?? item.needs_led}</Text>
                    )}
                    {item.category_details && Object.keys(item.category_details).length > 0 && (
                      <Text style={s.detailsLine}>
                        {Object.entries(item.category_details).map(([k, v]) => `${k}: ${Array.isArray(v) ? v.join(', ') : v}`).join(' · ')}
                      </Text>
                    )}
                    {item.is_gift && (
                      <Text style={s.detailsLine}>🎁 Regalo sorpresa{item.gift_recipient_name ? ` para ${item.gift_recipient_name}` : ''}</Text>
                    )}
                  </View>

                  {(item.event_address || item.event_municipio) && (() => {
                    const fullAddr = [item.event_address, item.event_municipio, item.event_estado].filter(Boolean).join(', ');
                    const addrKey = `q-${item.quote_id}`;
                    return (
                      <View style={s.infoRow}>
                        <MapPin size={13} color={COLORS.muted2} />
                        <Text style={[s.infoText, { flex: 1 }]}>{fullAddr}</Text>
                        <Pressable style={s.copyBtn} onPress={() => openInMaps(fullAddr)}>
                          <Text style={s.copyBtnText}>Ver mapa</Text>
                        </Pressable>
                        <Pressable style={s.copyBtn} onPress={() => copyText(addrKey, fullAddr)}>
                          {copiedKey === addrKey
                            ? <Check size={13} color={COLORS.green} />
                            : <Copy size={13} color={COLORS.muted2} />}
                        </Pressable>
                      </View>
                    );
                  })()}
                  {item.comments ? (
                    <View style={s.commentsRow}>
                      <Text style={s.comments}>"{item.comments}"</Text>
                      <Pressable style={s.copyBtn} onPress={() => copyText(`qc-${item.quote_id}`, item.comments!)}>
                        {copiedKey === `qc-${item.quote_id}`
                          ? <Check size={13} color={COLORS.green} />
                          : <Copy size={13} color={COLORS.muted2} />}
                      </Pressable>
                    </View>
                  ) : null}

                  <Pressable style={s.priceBtn} onPress={() => openPriceModal(item)}>
                    <DollarSign size={16} color={COLORS.bg} />
                    <Text style={s.priceBtnText}>Poner precio</Text>
                  </Pressable>
                </View>
              ))}
            </ScrollView>
          )
        ) : (
          liveLoading ? (
            <View style={s.center}><ActivityIndicator size="large" color={COLORS.green} /></View>
          ) : liveItems.length === 0 ? (
            <View style={s.center}>
              <Text style={{ fontSize: 40 }}>🔴</Text>
              <Text style={s.emptyTitle}>Nada en curso</Text>
              <Text style={s.emptyText}>Aquí aparecen los eventos que ya empezaron de grupos en modo conserjería, para proponerles horas extra al cliente.</Text>
            </View>
          ) : (
            <ScrollView
              contentContainerStyle={{ padding: SPACING.xl, gap: 12 }}
              refreshControl={<RefreshControl refreshing={liveRefreshing} onRefresh={onRefreshLive} tintColor={COLORS.green} />}
            >
              {liveItems.map(item => (
                <View key={item.reservation_id} style={s.card}>
                  <View style={s.cardHeader}>
                    <View style={{ flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' }}>
                      <Text style={s.groupName} numberOfLines={1}>🔴 {item.group_name}</Text>
                      <Pressable onPress={() => turnOffConcierge(item.group_id, item.group_name)}>
                        <Text style={s.conciergeOffText}>Apagar conserjería</Text>
                      </Pressable>
                    </View>
                    <Text style={s.genre}>{item.country}</Text>
                  </View>

                  <Pressable style={s.callRow} onPress={() => call(item.group_phone)} disabled={!item.group_phone}>
                    <Phone size={13} color={COLORS.green} />
                    <Text style={s.callText}>Grupo: {item.group_phone ?? 'sin teléfono'}</Text>
                  </Pressable>
                  <Pressable style={s.callRow} onPress={() => call(item.client_phone)} disabled={!item.client_phone}>
                    <Phone size={13} color={COLORS.gold} />
                    <Text style={s.callText}>{item.client_name ?? 'Cliente'}: {item.client_phone ?? 'sin teléfono'}</Text>
                  </Pressable>

                  <View style={s.infoRow}>
                    <Clock size={13} color={COLORS.muted2} />
                    <Text style={s.infoText}>
                      Contratadas: {item.hours_count ?? '—'}h
                      {item.event_started_at ? ` · empezó ${new Date(item.event_started_at).toLocaleTimeString('es-MX', { hour: 'numeric', minute: '2-digit' })}` : ''}
                    </Text>
                  </View>
                  {item.address && (
                    <View style={s.infoRow}>
                      <MapPin size={13} color={COLORS.muted2} />
                      <Text style={[s.infoText, { flex: 1 }]}>{item.address}</Text>
                      <Pressable style={s.copyBtn} onPress={() => openInMaps(item.address!)}>
                        <Text style={s.copyBtnText}>Ver mapa</Text>
                      </Pressable>
                      <Pressable style={s.copyBtn} onPress={() => copyText(`l-${item.reservation_id}`, item.address!)}>
                        {copiedKey === `l-${item.reservation_id}`
                          ? <Check size={13} color={COLORS.green} />
                          : <Copy size={13} color={COLORS.muted2} />}
                      </Pressable>
                    </View>
                  )}

                  <Pressable style={s.priceBtn} onPress={() => openExtraModal(item)}>
                    <Clock size={16} color={COLORS.bg} />
                    <Text style={s.priceBtnText}>Proponer horas extra</Text>
                  </Pressable>
                </View>
              ))}
            </ScrollView>
          )
        )}
      </SafeAreaView>

      {/* Modal: poner precio de cotización */}
      <Modal visible={!!priceModal} transparent animationType="slide" onRequestClose={() => setPriceModal(null)}>
        <View style={s.overlay}>
          <View style={s.sheet}>
            <Text style={s.sheetTitle}>{priceModal?.group_name}</Text>
            <Text style={s.sheetHint}>Escribe lo que el grupo pidió por teléfono — el sistema le agrega la comisión de Daricefy automáticamente, igual que si el grupo lo hubiera puesto él mismo.</Text>

            <Text style={s.label}>Precio del grupo (neto)</Text>
            <TextInput
              style={s.input}
              value={basePrice}
              onChangeText={setBasePrice}
              placeholder="Ej. 9000"
              placeholderTextColor={COLORS.muted}
              keyboardType="numeric"
            />

            <Text style={s.label}>Costo de traslado (opcional)</Text>
            <TextInput
              style={s.input}
              value={travelCost}
              onChangeText={setTravelCost}
              placeholder="0"
              placeholderTextColor={COLORS.muted}
              keyboardType="numeric"
            />

            <Text style={s.label}>Horas extra (opcional) — pregúntale al grupo cuánto cobra en total por quedarse 1, 2 o 3 horas más. Puede ser distinto a un simple múltiplo (ej. descuento por quedarse más tiempo).</Text>
            <View style={s.row3}>
              <View style={{ flex: 1 }}>
                <Text style={s.miniLabel}>Total por 1h extra</Text>
                <TextInput
                  style={s.input}
                  value={overtime1h}
                  onChangeText={setOvertime1h}
                  placeholder="Ej. 500"
                  placeholderTextColor={COLORS.muted}
                  keyboardType="numeric"
                />
              </View>
              <View style={{ flex: 1 }}>
                <Text style={s.miniLabel}>Total por 2h extra</Text>
                <TextInput
                  style={s.input}
                  value={overtime2h}
                  onChangeText={setOvertime2h}
                  placeholder="Ej. 900"
                  placeholderTextColor={COLORS.muted}
                  keyboardType="numeric"
                />
              </View>
              <View style={{ flex: 1 }}>
                <Text style={s.miniLabel}>Total por 3h extra</Text>
                <TextInput
                  style={s.input}
                  value={overtime3h}
                  onChangeText={setOvertime3h}
                  placeholder="Ej. 1300"
                  placeholderTextColor={COLORS.muted}
                  keyboardType="numeric"
                />
              </View>
            </View>
            <Text style={s.fieldNote}>Guárdalos una sola vez aquí — cuando el evento esté en curso, la pestaña "En vivo" ya los trae cargados, no hay que volver a preguntarlos.</Text>

            <Text style={s.label}>Nota interna (opcional)</Text>
            <TextInput
              style={[s.input, { height: 70, textAlignVertical: 'top' }]}
              value={notes}
              onChangeText={setNotes}
              placeholder="Ej. confirmó disponibilidad, pide anticipo..."
              placeholderTextColor={COLORS.muted}
              multiline
            />

            <View style={{ flexDirection: 'row', gap: 10, marginTop: 16 }}>
              <Pressable style={[s.modalBtn, s.modalBtnCancel]} onPress={() => setPriceModal(null)}>
                <Text style={s.modalBtnCancelText}>Cancelar</Text>
              </Pressable>
              <Pressable style={[s.modalBtn, s.modalBtnSend, sending && { opacity: 0.6 }]} onPress={sendPrice} disabled={sending}>
                {sending ? <ActivityIndicator size="small" color={COLORS.bg} /> : <Text style={s.modalBtnSendText}>Enviar al cliente</Text>}
              </Pressable>
            </View>
          </View>
        </View>
      </Modal>

      {/* Modal: proponer horas extra */}
      <Modal visible={!!extraModal} transparent animationType="slide" onRequestClose={() => setExtraModal(null)}>
        <View style={s.overlay}>
          <View style={s.sheet}>
            <Text style={s.sheetTitle}>{extraModal?.group_name}</Text>
            <Text style={s.sheetHint}>
              Se le manda al cliente para que apruebe y pague — igual que si el grupo se lo propusiera desde su propia cuenta.
              {negotiatedFor(extraModal, extraHours)
                ? ' Ya trae cargado el precio que negociaste al poner el precio inicial para estas horas — solo confirma o cámbialo si hace falta.'
                : ' No hay un precio guardado para este número de horas — escribe cuánto cobra el grupo en total.'}
            </Text>

            <Text style={s.label}>Horas extra</Text>
            <View style={s.hoursRow}>
              {[1, 2, 3].map(h => (
                <Pressable key={h} style={[s.hourChip, extraHours === h && s.hourChipActive]} onPress={() => selectExtraHours(h)}>
                  <Text style={[s.hourChipText, extraHours === h && s.hourChipTextActive]}>{h}h</Text>
                </Pressable>
              ))}
            </View>

            <Text style={s.label}>Precio total por {extraHours}h extra (neto)</Text>
            <TextInput
              style={s.input}
              value={extraPrice}
              onChangeText={setExtraPrice}
              placeholder="Ej. 500"
              placeholderTextColor={COLORS.muted}
              keyboardType="numeric"
            />

            <Text style={s.label}>Nota interna (opcional)</Text>
            <TextInput
              style={[s.input, { height: 70, textAlignVertical: 'top' }]}
              value={extraNotes}
              onChangeText={setExtraNotes}
              placeholder="Ej. el grupo confirmó por teléfono que puede quedarse"
              placeholderTextColor={COLORS.muted}
              multiline
            />

            <View style={{ flexDirection: 'row', gap: 10, marginTop: 8 }}>
              <Pressable style={[s.modalBtn, s.modalBtnCancel]} onPress={() => setExtraModal(null)}>
                <Text style={s.modalBtnCancelText}>Cancelar</Text>
              </Pressable>
              <Pressable style={[s.modalBtn, s.modalBtnSend, sendingExtra && { opacity: 0.6 }]} onPress={sendExtraHours} disabled={sendingExtra}>
                {sendingExtra ? <ActivityIndicator size="small" color={COLORS.bg} /> : <Text style={s.modalBtnSendText}>Enviar al cliente</Text>}
              </Pressable>
            </View>
          </View>
        </View>
      </Modal>
    </View>
  );
}

const s = StyleSheet.create({
  container: { flex: 1, backgroundColor: COLORS.bg },
  center: { flex: 1, alignItems: 'center', justifyContent: 'center', gap: 8, padding: SPACING.xl },
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

  tabs: { flexDirection: 'row', paddingHorizontal: SPACING.xl, paddingVertical: 10, gap: 8 },
  tabBtn: {
    flex: 1, paddingVertical: 9, borderRadius: RADIUS.md, alignItems: 'center',
    backgroundColor: COLORS.card, borderWidth: 1, borderColor: COLORS.border,
  },
  tabBtnActive: { backgroundColor: COLORS.greenMuted, borderColor: COLORS.green },
  tabBtnText: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted2 },
  tabBtnTextActive: { color: COLORS.green },

  emptyTitle: { fontFamily: FONTS.title, fontSize: 18, color: COLORS.text, marginTop: 4 },
  emptyText: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2, textAlign: 'center' },

  card: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border, padding: 14, gap: 6,
  },
  cardHeader: { marginBottom: 4 },
  conciergeOffText: { fontFamily: FONTS.bodyMedium, fontSize: 11, color: COLORS.muted2, textDecorationLine: 'underline' },
  groupName: { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.text },
  genre: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2 },

  callRow: { flexDirection: 'row', alignItems: 'center', gap: 6 },
  callText: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.text },

  infoRow: { flexDirection: 'row', alignItems: 'flex-start', gap: 6, marginTop: 2 },
  infoText: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, flex: 1 },
  comments: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted, fontStyle: 'italic', flex: 1 },
  commentsRow: { flexDirection: 'row', alignItems: 'flex-start', gap: 6, marginTop: 4 },
  detailsBox: {
    backgroundColor: COLORS.card2, borderRadius: RADIUS.md,
    padding: 10, marginTop: 6, gap: 3,
  },
  detailsLine: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2 },
  copyBtn: {
    flexDirection: 'row', alignItems: 'center', gap: 3,
    paddingHorizontal: 7, paddingVertical: 3, borderRadius: RADIUS.sm,
    backgroundColor: COLORS.card2,
  },
  copyBtnText: { fontFamily: FONTS.bodyMedium, fontSize: 11, color: COLORS.muted2 },

  priceBtn: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 6,
    backgroundColor: COLORS.green, borderRadius: RADIUS.md, paddingVertical: 11, marginTop: 8,
  },
  priceBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.bg },

  hoursRow: { flexDirection: 'row', gap: 8, marginBottom: 14 },
  hourChip: {
    flex: 1, alignItems: 'center', paddingVertical: 10, borderRadius: RADIUS.md,
    backgroundColor: COLORS.bg, borderWidth: 1, borderColor: COLORS.border,
  },
  hourChipActive: { backgroundColor: COLORS.green, borderColor: COLORS.green },
  hourChipText: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.muted2 },
  hourChipTextActive: { color: COLORS.bg },

  overlay: { flex: 1, backgroundColor: 'rgba(0,0,0,0.5)', justifyContent: 'flex-end' },
  sheet: {
    backgroundColor: COLORS.card, borderTopLeftRadius: 24, borderTopRightRadius: 24,
    padding: SPACING.xl, paddingBottom: 40,
  },
  sheetTitle: { fontFamily: FONTS.title, fontSize: 18, color: COLORS.text, marginBottom: 6 },
  sheetHint: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, marginBottom: 16, lineHeight: 17 },
  label: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted2, marginBottom: 6 },
  fieldNote: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted, marginTop: -10, marginBottom: 14, lineHeight: 15 },
  row3: { flexDirection: 'row', gap: 8 },
  miniLabel: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted2, marginBottom: 4 },
  input: {
    backgroundColor: COLORS.bg, borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: COLORS.border,
    paddingHorizontal: 14, paddingVertical: 12,
    fontFamily: FONTS.body, fontSize: 15, color: COLORS.text, marginBottom: 14,
  },
  modalBtn: { flex: 1, alignItems: 'center', justifyContent: 'center', paddingVertical: 13, borderRadius: RADIUS.md },
  modalBtnCancel: { backgroundColor: COLORS.card2, borderWidth: 1, borderColor: COLORS.border },
  modalBtnCancelText: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.muted2 },
  modalBtnSend: { backgroundColor: COLORS.green },
  modalBtnSendText: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.bg },
});
