/**
 * ClientQuoteDetailScreen — El cliente ve la cotización del grupo y puede aceptarla o cancelarla.
 */
import React, { useCallback, useEffect, useState } from 'react';
import {
  ActivityIndicator,
  Alert,
  Image,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { useFocusEffect } from '@react-navigation/native';
import { ArrowLeft, CheckCircle, CreditCard, XCircle } from 'lucide-react-native';
import { supabase } from '../../config/supabase';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';
import { MSI_OPTIONS, MsiOption } from '../../utils/calculations';
import { calculateFinancedPrice, calculateMonthlyPayment, PUBLIC_MSI_FEE_RATES } from '../../utils/publicPricing';
import RequestZoneMap from '../../components/requests/RequestZoneMap';
import { approxGroupLocation, clampDistanceKm, eventCardCenter } from '../../utils/mapUtils';

const EVENT_TYPE_LABELS: Record<string, string> = {
  fiesta_privada: '🎉 Fiesta privada',
  boda:           '💍 Boda',
  cumpleanos:     '🎂 Cumpleaños',
  graduacion:     '🎓 Graduación',
  empresarial:    '🏢 Empresarial',
  otro:           '🎵 Otro',
};

function Row({ label, value, bold }: { label: string; value: string; bold?: boolean }) {
  return (
    <View style={s.row}>
      <Text style={s.rowLabel}>{label}</Text>
      <Text style={[s.rowValue, bold && s.rowValueBold]}>{value}</Text>
    </View>
  );
}

export default function ClientQuoteDetailScreen({ route, navigation }: any) {
  const { quoteId } = route.params as { quoteId: string };

  const [quote, setQuote]           = useState<any>(null);
  const [loading, setLoading]       = useState(true);
  const [acting, setActing]         = useState(false);
  const [selectedMSI, setSelectedMSI] = useState<MsiOption>(MSI_OPTIONS[0]);

  const fetchQuote = useCallback(async () => {
    const { data } = await supabase
      .from('quotes')
      .select('*, group:groups(id, name, owner_id, profile_image, genre, city, state, average_rating, total_reviews)')
      .eq('id', quoteId)
      .single();
    setQuote(data);
    setLoading(false);
  }, [quoteId]);

  useEffect(() => { fetchQuote(); }, [fetchQuote]);

  // ── Notificar a dueño + integrantes del grupo ──────────────────────────────
  const notifyGroup = async (
    groupId: string,
    ownerId: string,
    type: 'quote_accepted' | 'quote_cancelled',
    title: string,
    body: string,
  ) => {
    const notifications: any[] = [{ user_id: ownerId, type, title, body, data: { quote_id: quoteId } }];

    const { data: members } = await supabase
      .from('job_invitations')
      .select('invited_user_id')
      .eq('group_id', groupId)
      .eq('invitation_type', 'membership')
      .eq('status', 'accepted');

    if (members?.length) {
      members.forEach((m: any) =>
        notifications.push({ user_id: m.invited_user_id, type, title, body, data: { quote_id: quoteId } })
      );
    }

    const { data: invited } = await supabase
      .from('job_invitations')
      .select('invited_user_id')
      .eq('group_id', groupId)
      .eq('invitation_type', 'job')
      .eq('status', 'accepted');

    if (invited?.length) {
      invited.forEach((m: any) =>
        notifications.push({ user_id: m.invited_user_id, type, title, body, data: { quote_id: quoteId } })
      );
    }

    await supabase.from('notifications').insert(notifications);
  };

  // Refrescar la cotización al volver desde QuotePaymentScreen
  useFocusEffect(useCallback(() => { fetchQuote(); }, [fetchQuote]));

  // ── Crear evento + reserva y navegar a la pantalla de pago premium ────────
  const handleConfirmPayment = async (msiMonths: number) => {
    setActing(true);
    try {
      const { data: { user }, error: authErr } = await supabase.auth.getUser();
      const clientId = user?.id;
      if (authErr || !clientId) throw new Error('No hay sesión activa.');

      const total     = quote.total_amount ?? 0;
      const addrParts = [quote.event_address, quote.event_municipio, quote.event_estado].filter(Boolean);
      const address   = addrParts.join(', ') || null;

      // 1. Crear evento padre
      const { data: eventData, error: eventErr } = await supabase
        .from('events')
        .insert({
          client_id:  clientId,
          event_date: quote.event_date,
          event_time: quote.event_time ?? null,
          address,
          status:     'active',
        })
        .select('id')
        .single();
      if (eventErr || !eventData?.id) throw new Error('No se pudo registrar el evento. Intenta de nuevo.');

      // 2. Crear reserva
      const { data: resData, error: resErr } = await supabase
        .from('reservations')
        .insert({
          event_id:    eventData.id,
          client_id:   clientId,
          group_id:    quote.group_id,
          event_date:  quote.event_date,
          event_time:  quote.event_time ?? null,
          address,
          total_price: total,
          status:      'accepted',
          quote_id:    quote.id,
          notes:       quote.comments ?? null,
          ...(msiMonths > 1 ? { msi_months: msiMonths } : {}),
        })
        .select('id')
        .single();
      if (resErr || !resData?.id) {
        // Candado universal (trigger sql/431): la fecha se bloqueó/ocupó en el camino
        const code = resErr?.message ?? '';
        if (code.includes('date_blocked') || code.includes('date_taken')) {
          throw new Error('Esa fecha ya no está disponible para el grupo (se ocupó o la bloqueó). Coordina otra fecha antes de aceptar.');
        }
        throw new Error('No se pudo crear la reserva. Intenta de nuevo.');
      }

      // 3. Marcar cotización como aceptada
      await supabase.from('quotes').update({ status: 'accepted' }).eq('id', quote.id);

      // 4. Notificar al grupo
      if (quote.group?.owner_id) {
        await notifyGroup(
          quote.group.id,
          quote.group.owner_id,
          'quote_accepted',
          '✅ Cotización aceptada',
          `Cliente aceptó tu cotización de $${total.toLocaleString()} MXN.`,
        );
      }

      // 5. Navegar a la pantalla unificada de pago (QuotePaymentScreen)
      navigation.navigate('QuotePayment', {
        reservation: {
          id:          resData.id,
          total_price: total,
          event_date:  quote.event_date,
          event_time:  quote.event_time ?? null,
          address,
          msi_months:  msiMonths > 1 ? msiMonths : null,
          quote_id:    quote.id,
          group:       quote.group,
          status:      'accepted',
        },
      });

    } catch (err: any) {
      Alert.alert('Ocurrió un problema', err.message ?? 'No se pudo procesar tu solicitud. Intenta de nuevo.');
    } finally {
      setActing(false);
    }
  };

  // ── Confirmación antes de crear la reserva ────────────────────────────────
  const handleAccept = () => {
    if (acting) return;
    const baseTotal = quote.total_amount ?? 0;
    Alert.alert(
      '¿Confirmar contratación?',
      `Total: $${baseTotal.toLocaleString()} MXN\n\nPodrás elegir pago único o en mensualidades en el siguiente paso.\n\nEl pago se libera al finalizar el evento.`,
      [
        { text: 'Revisar', style: 'cancel' },
        { text: 'Continuar al pago', onPress: () => handleConfirmPayment(selectedMSI.months) },
      ],
    );
  };

  // ── Cancelar ───────────────────────────────────────────────────────────────
  const handleCancel = () => {
    Alert.alert(
      'Cancelar cotización',
      '¿Estás seguro de que quieres cancelar esta cotización?',
      [
        { text: 'No', style: 'cancel' },
        {
          text: 'Sí, cancelar',
          style: 'destructive',
          onPress: async () => {
            setActing(true);
            const { error } = await supabase
              .from('quotes')
              .update({ status: 'rejected' })
              .eq('id', quoteId);

            if (!error && quote?.group) {
              await notifyGroup(
                quote.group.id,
                quote.group.owner_id,
                'quote_cancelled',
                '❌ Cotización cancelada',
                'El cliente canceló la cotización.',
              );
            }

            setActing(false);
            if (error) {
              Alert.alert('Error', 'No se pudo procesar. Intenta de nuevo.');
            } else {
              Alert.alert(
                'Cancelada',
                '¿Quieres volver a cotizar con este grupo?',
                [
                  { text: 'No, gracias', onPress: () => navigation.goBack() },
                  {
                    text: 'Volver a cotizar',
                    onPress: () => {
                      navigation.goBack();
                      navigation.navigate('QuoteForm', { group: quote.group });
                    },
                  },
                ],
              );
            }
          },
        },
      ],
    );
  };

  if (loading) {
    return (
      <View style={s.root}>
        <SafeAreaView style={s.center}>
          <ActivityIndicator size="large" color={COLORS.green} />
        </SafeAreaView>
      </View>
    );
  }

  if (!quote) {
    return (
      <View style={s.root}>
        <SafeAreaView style={s.center}>
          <Text style={s.errorText}>No se encontró la cotización.</Text>
        </SafeAreaView>
      </View>
    );
  }

  const isPending   = quote.status === 'quoted';
  const isAccepted  = quote.status === 'accepted';
  const isCancelled = quote.status === 'rejected';

  const total   = quote.total_amount ?? 0;

  const eventDateStr = quote.event_date
    ? new Date(quote.event_date + 'T12:00:00').toLocaleDateString('es-MX', {
        weekday: 'long', year: 'numeric', month: 'long', day: 'numeric',
      })
    : '—';

  return (
    <View style={s.root}>
      <SafeAreaView edges={['top']} style={s.header}>
        <Pressable style={s.backBtn} onPress={() => navigation.goBack()}>
          <ArrowLeft size={20} color={COLORS.text} />
        </Pressable>
        <View style={s.headerCenter}>
          <View style={s.groupAvatarBox}>
            {quote.group?.profile_image ? (
              <Image source={{ uri: quote.group.profile_image }} style={s.groupAvatarImg} />
            ) : (
              <Text style={s.groupAvatarInitial}>
                {(quote.group?.name ?? 'G').charAt(0).toUpperCase()}
              </Text>
            )}
          </View>
          <View style={{ flex: 1 }}>
            <Text style={s.headerTitle}>Cotización recibida</Text>
            <Text style={s.headerSub}>{quote.group?.name ?? 'Grupo'}</Text>
          </View>
          {quote.group?.id && (
            <Pressable
              onPress={() => navigation.navigate('GroupDetail', { group: quote.group })}
              hitSlop={8}
              style={({ pressed }) => [s.viewProfileBtn, pressed && { opacity: 0.6 }]}
            >
              <Text style={s.viewProfileTx}>Ver perfil ›</Text>
            </Pressable>
          )}
        </View>
      </SafeAreaView>

      <ScrollView contentContainerStyle={s.scroll} showsVerticalScrollIndicator={false}>

        {/* Estado */}
        {isAccepted && (
          <View style={[s.statusBanner, s.statusGreen]}>
            <CheckCircle size={16} color={COLORS.green} />
            <Text style={[s.statusText, { color: COLORS.green }]}>Cotización aceptada ✅</Text>
          </View>
        )}
        {isCancelled && (
          <View style={[s.statusBanner, s.statusRed]}>
            <XCircle size={16} color={COLORS.red} />
            <Text style={[s.statusText, { color: COLORS.red }]}>Cotización cancelada</Text>
          </View>
        )}

        {/* Mapa estilo ExpressCard: tu zona + el grupo viniendo desde su ciudad */}
        {(() => {
          const center = eventCardCenter(quote);
          if (!center) return null;
          const rawGroupLoc = approxGroupLocation(quote.group?.id ?? String(quote.id), quote.group?.city, quote.group?.state, center);
          // Encuadre: si el grupo queda muy lejos, acércalo (misma dirección)
          // para que el mapa no se aleje y el evento se vea claro.
          const groupLoc = clampDistanceKm(center, rawGroupLoc, 12);
          return (
            <View style={s.mapCard}>
              <RequestZoneMap
                mapId={String(quote.id)} center={center} typeLabel="📅 Programada"
                userLocation={groupLoc} groupPhotoUrl={quote.group?.profile_image ?? null}
              />
            </View>
          );
        })()}

        {/* Precio total */}
        <View style={[s.priceCard, { borderColor: isAccepted ? COLORS.green : isCancelled ? COLORS.red : COLORS.border }]}>
          <Text style={s.priceLabel}>Total cotizado</Text>
          <Text style={s.priceValue}>${total.toLocaleString()} MXN</Text>
          {quote.travel_cost > 0 && (
            <Text style={s.priceNote}>Incluye ${quote.travel_cost?.toLocaleString()} de traslado</Text>
          )}
        </View>

        {/* Detalles del evento */}
        <View style={s.section}>
          <Text style={s.sectionTitle}>Detalles del evento</Text>
          <Row label="Tipo"      value={EVENT_TYPE_LABELS[quote.event_type] ?? quote.event_type} />
          <Row label="Fecha"     value={eventDateStr} />
          <Row label="Duración"  value={`${quote.duration_hours} horas`} />
          {quote.event_time ? <Row label="Hora" value={quote.event_time} /> : null}
        </View>

        {/* Horas extra disponibles */}
        {(quote.overtime_1h_price || quote.overtime_2h_price || quote.overtime_3h_price) && (
          <View style={s.section}>
            <Text style={s.sectionTitle}>Horas extra disponibles</Text>
            <Text style={s.overtimeNote}>
              ⏱ Al finalizar el evento podrás contratar horas extra directamente desde la app, antes de que concluya el servicio.
            </Text>
            {quote.overtime_1h_price ? <Row label="+1 hora extra" value={`$${quote.overtime_1h_price?.toLocaleString()}`} /> : null}
            {quote.overtime_2h_price ? <Row label="+2 horas extra" value={`$${quote.overtime_2h_price?.toLocaleString()}`} /> : null}
            {quote.overtime_3h_price ? <Row label="+3 horas extra" value={`$${quote.overtime_3h_price?.toLocaleString()}`} /> : null}
          </View>
        )}

        {/* Notas del grupo */}
        {quote.group_notes ? (
          <View style={s.section}>
            <Text style={s.sectionTitle}>Notas del grupo</Text>
            <View style={s.noteBox}>
              <Text style={s.noteText}>"{quote.group_notes}"</Text>
            </View>
          </View>
        ) : null}

        {/* ── Selector MSI (solo cuando está pending) ─────────────────────────── */}
        {isPending && (
          <View style={s.msiCard}>
            <View style={s.msiHeader}>
              <CreditCard size={16} color={COLORS.blue} />
              <Text style={s.msiTitle}>Elige la opción de pago que mejor se adapte a ti</Text>
            </View>
            <Text style={s.msiHint}>
              {'El precio varía según el plan seleccionado debido a los costos de financiamiento. En todos los casos, tu contratación queda confirmada de inmediato al completar el pago.'}
            </Text>
            <View style={s.msiRow}>
              {MSI_OPTIONS.map((opt) => {
                const isActive = selectedMSI.key === opt.key;
                const feeRate  = PUBLIC_MSI_FEE_RATES[opt.months] ?? 0;
                return (
                  <Pressable
                    key={opt.key}
                    style={[s.msiChip, isActive && s.msiChipActive]}
                    onPress={() => setSelectedMSI(opt)}
                  >
                    <Text style={[s.msiChipText, isActive && s.msiChipTextActive]}>
                      {opt.label}
                    </Text>
                    {opt.months > 1 && (
                      <Text style={[s.msiChipFee, isActive && s.msiChipFeeActive]}>
                        +{(feeRate * 100).toFixed(0)}%
                      </Text>
                    )}
                  </Pressable>
                );
              })}
            </View>
            {selectedMSI.months > 1 && (
              <Text style={s.msiHint}>
                {selectedMSI.months} pagos de ${calculateMonthlyPayment(total, selectedMSI.months).toLocaleString()} MXN · cargo adicional: ${(calculateFinancedPrice(total, selectedMSI.months) - total).toLocaleString()}
              </Text>
            )}
          </View>
        )}

        {/* Acciones */}
        {isPending && (
          <View style={s.actions}>
            <Pressable
              style={[s.cancelBtn, acting && { opacity: 0.5 }]}
              onPress={handleCancel}
              disabled={acting}
            >
              <XCircle size={18} color={COLORS.red} />
              <Text style={s.cancelBtnText}>Cancelar</Text>
            </Pressable>
            <Pressable
              style={[s.acceptBtn, acting && { opacity: 0.5 }]}
              onPress={handleAccept}
              disabled={acting}
            >
              {acting
                ? <ActivityIndicator size="small" color={COLORS.bg} />
                : <CheckCircle size={18} color={COLORS.bg} />}
              <Text style={s.acceptBtnText}>Contratar y pagar</Text>
            </Pressable>
          </View>
        )}

        {isCancelled && (
          <Pressable
            style={s.acceptBtn}
            onPress={() => {
              navigation.goBack();
              navigation.navigate('QuoteForm', { group: quote.group });
            }}
          >
            <Text style={s.acceptBtnText}>Volver a cotizar</Text>
          </Pressable>
        )}

        <View style={{ height: 40 }} />
      </ScrollView>

    </View>
  );
}

const s = StyleSheet.create({
  root:   { flex: 1, backgroundColor: COLORS.bg },
  center: { flex: 1, alignItems: 'center', justifyContent: 'center' },
  errorText: { fontFamily: FONTS.body, fontSize: 15, color: COLORS.muted2 },

  header: {
    flexDirection: 'row', alignItems: 'center', gap: 14,
    paddingHorizontal: SPACING.xl, paddingVertical: 12,
    borderBottomWidth: 1, borderBottomColor: COLORS.border,
  },
  backBtn: {
    width: 40, height: 40, borderRadius: 12,
    backgroundColor: COLORS.card, borderWidth: 1, borderColor: COLORS.border,
    alignItems: 'center', justifyContent: 'center',
  },
  headerTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 16, color: COLORS.text },
  headerSub:   { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, marginTop: 1 },
  viewProfileBtn: {
    backgroundColor: 'rgba(0,230,118,0.10)', borderRadius: 20,
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.35)',
    paddingHorizontal: 10, paddingVertical: 5,
  },
  viewProfileTx: { fontFamily: FONTS.bodySemiBold, fontSize: 11, color: COLORS.green },
  mapCard: {
    borderRadius: 20, overflow: 'hidden',
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.35)',
    marginBottom: 14,
  },

  scroll: { padding: SPACING.xl },

  statusBanner: {
    flexDirection: 'row', alignItems: 'center', gap: 10,
    padding: 14, borderRadius: RADIUS.lg, borderWidth: 1, marginBottom: 16,
  },
  statusGreen: { backgroundColor: 'rgba(0,230,118,0.08)', borderColor: 'rgba(0,230,118,0.4)' },
  statusRed:   { backgroundColor: 'rgba(239,83,80,0.08)', borderColor: 'rgba(239,83,80,0.4)' },
  statusText:  { fontFamily: FONTS.bodySemiBold, fontSize: 14 },

  priceCard: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.xl,
    borderWidth: 1,
    padding: SPACING.xl, alignItems: 'center', marginBottom: 20,
  },
  priceLabel: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted2, marginBottom: 8 },
  priceValue: { fontFamily: FONTS.title, fontSize: 26, color: COLORS.green },
  priceNote:  { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted, marginTop: 6 },

  section: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.xl,
    borderWidth: 1, borderColor: COLORS.border,
    padding: SPACING.lg, marginBottom: 14,
  },
  sectionTitle: {
    fontFamily: FONTS.bodySemiBold, fontSize: 12, color: COLORS.muted2,
    textTransform: 'uppercase', letterSpacing: 0.8, marginBottom: 12,
  },
  row: {
    flexDirection: 'row', justifyContent: 'space-between',
    paddingVertical: 8, borderBottomWidth: 1, borderBottomColor: COLORS.border,
  },
  rowLabel:      { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted2 },
  rowValue:      { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.text, textAlign: 'right', flex: 1, marginLeft: 12 },
  rowValueBold:  { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.green },

  noteBox:      { backgroundColor: COLORS.card2, borderRadius: RADIUS.md, borderWidth: 1, borderColor: COLORS.border, padding: 12 },
  noteText:     { fontFamily: FONTS.body, fontSize: 14, color: COLORS.text, lineHeight: 22, fontStyle: 'italic' },
  overtimeNote: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, lineHeight: 18, marginBottom: 12 },

  actions: { flexDirection: 'row', gap: 12, marginTop: 8 },
  cancelBtn: {
    flex: 1, flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 8,
    paddingVertical: 15, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: 'rgba(239,83,80,0.4)', backgroundColor: 'rgba(239,83,80,0.08)',
  },
  cancelBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.red },
  acceptBtn: {
    flex: 2, flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 8,
    paddingVertical: 15, borderRadius: RADIUS.lg, backgroundColor: COLORS.green,
  },
  acceptBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.bg },

  // ── MSI selector ──
  msiCard: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.xl,
    borderWidth: 1, borderColor: 'rgba(66,133,244,0.3)',
    padding: SPACING.lg, marginBottom: 14,
  },
  msiHeader: { flexDirection: 'row', alignItems: 'center', gap: 8, marginBottom: 12 },
  msiTitle:  { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.text },
  msiRow:    { flexDirection: 'row', gap: 8, flexWrap: 'wrap' },
  msiChip: {
    paddingHorizontal: 12, paddingVertical: 8, borderRadius: RADIUS.full,
    backgroundColor: COLORS.card2, borderWidth: 1, borderColor: COLORS.border,
    alignItems: 'center',
  },
  msiChipActive:      { borderColor: COLORS.green, backgroundColor: 'rgba(0,230,118,0.10)' },
  msiChipText:        { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted2 },
  msiChipTextActive:  { color: COLORS.green },
  msiChipFee:         { fontFamily: FONTS.body, fontSize: 10, color: COLORS.muted, marginTop: 1 },
  msiChipFeeActive:   { color: COLORS.green },
  msiHint: {
    fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2,
    marginTop: 10, lineHeight: 17,
  },

  headerCenter: { flex: 1, flexDirection: 'row', alignItems: 'center', gap: 10 },
  groupAvatarBox: {
    width: 38, height: 38, borderRadius: 19, overflow: 'hidden',
    backgroundColor: COLORS.card2, borderWidth: 1, borderColor: COLORS.border,
    alignItems: 'center', justifyContent: 'center',
  },
  groupAvatarImg:     { width: 38, height: 38, borderRadius: 19 },
  groupAvatarInitial: { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.muted2 },
});
