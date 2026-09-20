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
import { ArrowLeft, CheckCircle, XCircle } from 'lucide-react-native';
import { useTranslation } from 'react-i18next';
import type { TFunction } from 'i18next';
import { supabase } from '../../config/supabase';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';
import RequestZoneMap from '../../components/requests/RequestZoneMap';
import { eventCardCenter } from '../../utils/mapUtils';
import { getClientActiveEvents, resolveEventContext } from '../../utils/eventBuilder';
import { categoryKeyForGenre, FLAT_RATE_CATEGORIES } from '../../constants/providerCategories';

// Etiquetas de tipo de evento — se generan dentro del componente con `t`.
const getEventTypeLabels = (t: TFunction): Record<string, string> => ({
  fiesta_privada: t('clientQuoteDetailScreen.eventTypes.fiesta_privada'),
  boda:           t('clientQuoteDetailScreen.eventTypes.boda'),
  cumpleanos:     t('clientQuoteDetailScreen.eventTypes.cumpleanos'),
  graduacion:     t('clientQuoteDetailScreen.eventTypes.graduacion'),
  empresarial:    t('clientQuoteDetailScreen.eventTypes.empresarial'),
  otro:           t('clientQuoteDetailScreen.eventTypes.otro'),
});

function Row({ label, value, bold }: { label: string; value: string; bold?: boolean }) {
  return (
    <View style={s.row}>
      <Text style={s.rowLabel}>{label}</Text>
      <Text style={[s.rowValue, bold && s.rowValueBold]}>{value}</Text>
    </View>
  );
}

export default function ClientQuoteDetailScreen({ route, navigation }: any) {
  const { t } = useTranslation();
  const { quoteId } = route.params as { quoteId: string };
  const EVENT_TYPE_LABELS = getEventTypeLabels(t);

  const [quote, setQuote]           = useState<any>(null);
  const [loading, setLoading]       = useState(true);
  const [acting, setActing]         = useState(false);

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
      .eq('invitation_type', 'event')
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
      if (authErr || !clientId) throw new Error(t('clientQuoteDetailScreen.errors.noSession'));

      const total     = quote.total_amount ?? 0;
      const addrParts = [quote.event_address, quote.event_municipio, quote.event_estado].filter(Boolean);
      const address   = addrParts.join(', ') || null;

      // Resolver evento — SIGUE siendo del lado de la app (Alert.alert de
      // "¿es tu evento del [fecha]?" es UI, no puede vivir en SQL). Solo
      // importa de verdad para cotizaciones viejas sin su propio event_id
      // — sql/593 usa el de la cotización directamente cuando ya existe.
      const activeEvents = quote.event_id ? [] : await getClientActiveEvents();
      const resolvedEventId = await resolveEventContext({
        t,
        presetEventId: quote.event_id ?? null,
        activeEvents,
      });

      // sql/593 (2026-09-01) — crear la reserva y marcar la cotización
      // aceptada en UNA sola llamada atómica. Hallazgo real del recorrido
      // de los 3 roles: antes eran 2 pasos separados (insert + update);
      // si la conexión se cortaba justo entre ambos, la cotización se
      // quedaba "viva" con una reserva ya creada, y un reintento podía
      // duplicarla (riesgo real de doble cobro). La función es además
      // idempotente: reintentar tras una falla ya resuelta regresa la
      // MISMA reserva en vez de crear otra.
      const { data: acceptResult, error: acceptErr } = await supabase.rpc('client_accept_quote', {
        p_quote_id:   quote.id,
        p_event_id:   resolvedEventId,
        p_msi_months: msiMonths,
      });
      if (acceptErr || !acceptResult?.ok) {
        const code = acceptErr?.message ?? acceptResult?.error ?? '';
        if (code.includes('date_blocked') || code.includes('date_taken')) {
          throw new Error(t('clientQuoteDetailScreen.errors.dateBlocked'));
        }
        if (code.includes('daily_event_limit')) {
          throw new Error(t('clientQuoteDetailScreen.errors.dailyLimit'));
        }
        if (code.includes('time_overlap')) {
          throw new Error(t('clientQuoteDetailScreen.errors.timeOverlap'));
        }
        if (code.includes('event_group_limit_reached')) {
          throw new Error(t('clientQuoteDetailScreen.errors.groupLimitReached'));
        }
        throw new Error(t('clientQuoteDetailScreen.errors.reservationCreateFailed'));
      }
      const reservationId: string = acceptResult.reservation_id;
      const eventId: string       = acceptResult.event_id;

      // Notificar al grupo — solo en una aceptación nueva de verdad; un
      // reintento idempotente ya notificó la primera vez.
      if (quote.group?.owner_id && !acceptResult.already_accepted) {
        await notifyGroup(
          quote.group.id,
          quote.group.owner_id,
          'quote_accepted',
          t('clientQuoteDetailScreen.notifications.quoteAcceptedTitle'),
          t('clientQuoteDetailScreen.notifications.quoteAcceptedBody', { amount: total.toLocaleString() }),
        );
      }

      // Navegar a la pantalla unificada de pago (QuotePaymentScreen)
      navigation.navigate('QuotePayment', {
        reservation: {
          id:          reservationId,
          event_id:    eventId,
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
      Alert.alert(t('clientQuoteDetailScreen.errors.genericProblemTitle'), err.message ?? t('clientQuoteDetailScreen.errors.genericProblemMessage'));
    } finally {
      setActing(false);
    }
  };

  // ── Confirmación antes de crear la reserva ────────────────────────────────
  const handleAccept = () => {
    if (acting) return;
    const baseTotal = quote.total_amount ?? 0;
    Alert.alert(
      t('clientQuoteDetailScreen.confirmDialog.title'),
      t('clientQuoteDetailScreen.confirmDialog.message', { amount: baseTotal.toLocaleString() }),
      [
        { text: t('clientQuoteDetailScreen.confirmDialog.review'), style: 'cancel' },
        { text: t('clientQuoteDetailScreen.confirmDialog.continue'), onPress: () => handleConfirmPayment(1) },
      ],
    );
  };

  // ── Cancelar ───────────────────────────────────────────────────────────────
  const handleCancel = () => {
    Alert.alert(
      t('clientQuoteDetailScreen.cancelDialog.title'),
      t('clientQuoteDetailScreen.cancelDialog.message'),
      [
        { text: t('clientQuoteDetailScreen.cancelDialog.no'), style: 'cancel' },
        {
          text: t('clientQuoteDetailScreen.cancelDialog.yesCancel'),
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
                t('clientQuoteDetailScreen.notifications.quoteCancelledTitle'),
                t('clientQuoteDetailScreen.notifications.quoteCancelledBody'),
              );
            }

            setActing(false);
            if (error) {
              Alert.alert(t('clientQuoteDetailScreen.cancelResult.errorTitle'), t('clientQuoteDetailScreen.cancelResult.errorMessage'));
            } else {
              Alert.alert(
                t('clientQuoteDetailScreen.cancelResult.cancelledTitle'),
                t('clientQuoteDetailScreen.cancelResult.cancelledMessage'),
                [
                  { text: t('clientQuoteDetailScreen.cancelResult.noThanks'), onPress: () => navigation.goBack() },
                  {
                    text: t('clientQuoteDetailScreen.cancelResult.requote'),
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
        <SafeAreaView edges={['top']} style={s.center}>
          <ActivityIndicator size="large" color={COLORS.green} />
        </SafeAreaView>
      </View>
    );
  }

  if (!quote) {
    return (
      <View style={s.root}>
        <SafeAreaView edges={['top']} style={s.center}>
          <Text style={s.errorText}>{t('clientQuoteDetailScreen.loading.notFound')}</Text>
        </SafeAreaView>
      </View>
    );
  }

  const isPending   = quote.status === 'quoted';
  const isAccepted  = quote.status === 'accepted';
  const isCancelled = quote.status === 'rejected';

  const total   = quote.total_amount ?? 0;

  // Comida/Renta cobran por contrato, no por hora (2026-09-05) — no se le
  // pidió duración al cliente, así que no se le muestra de vuelta aquí.
  const quoteCategoryKey = categoryKeyForGenre(quote.group?.genre);
  const isFlatRateQuote  = quoteCategoryKey != null && FLAT_RATE_CATEGORIES.has(quoteCategoryKey);

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
            <Text style={s.headerTitle}>{t('clientQuoteDetailScreen.header.title')}</Text>
            <Text style={s.headerSub}>{quote.group?.name ?? t('clientQuoteDetailScreen.genericGroupName')}</Text>
          </View>
          {quote.group?.id && (
            <Pressable
              onPress={() => navigation.navigate('GroupDetail', { group: quote.group })}
              hitSlop={8}
              style={({ pressed }) => [s.viewProfileBtn, pressed && { opacity: 0.6 }]}
            >
              <Text style={s.viewProfileTx}>{t('clientQuoteDetailScreen.header.viewProfile')}</Text>
            </Pressable>
          )}
        </View>
      </SafeAreaView>

      <ScrollView contentContainerStyle={s.scroll} showsVerticalScrollIndicator={false}>

        {/* Estado */}
        {isAccepted && (
          <View style={[s.statusBanner, s.statusGreen]}>
            <CheckCircle size={16} color={COLORS.green} />
            <Text style={[s.statusText, { color: COLORS.green }]}>{t('clientQuoteDetailScreen.status.accepted')}</Text>
          </View>
        )}
        {isCancelled && (
          <View style={[s.statusBanner, s.statusRed]}>
            <XCircle size={16} color={COLORS.red} />
            <Text style={[s.statusText, { color: COLORS.red }]}>{t('clientQuoteDetailScreen.status.cancelled')}</Text>
          </View>
        )}

        {/* Mapa estilo ExpressCard: tu zona + el grupo viniendo desde su ciudad */}
        {(() => {
          const center = eventCardCenter(quote);
          if (!center) return null;
          // Sin marcador falso del grupo: a este zoom quedaba encima del
          // círculo del evento. El cliente solo ve la zona de su evento.
          return (
            <View style={s.mapCard}>
              <RequestZoneMap
                mapId={String(quote.id)} center={center} typeLabel={t('clientQuoteDetailScreen.map.scheduled')}
                userLocation={null} groupPhotoUrl={null}
              />
            </View>
          );
        })()}

        {/* Precio total */}
        <View style={[s.priceCard, { borderColor: isAccepted ? COLORS.green : isCancelled ? COLORS.red : COLORS.border }]}>
          <Text style={s.priceLabel}>{t('clientQuoteDetailScreen.price.label')}</Text>
          <Text style={s.priceValue}>${total.toLocaleString()} MXN</Text>
          {quote.travel_cost > 0 && (
            <Text style={s.priceNote}>{t('clientQuoteDetailScreen.price.travelNote', { amount: quote.travel_cost?.toLocaleString() })}</Text>
          )}
        </View>

        {/* Detalles del evento */}
        <View style={s.section}>
          <Text style={s.sectionTitle}>{t('clientQuoteDetailScreen.eventDetails.title')}</Text>
          <Row label={t('clientQuoteDetailScreen.eventDetails.type')}      value={EVENT_TYPE_LABELS[quote.event_type] ?? quote.event_type} />
          <Row label={t('clientQuoteDetailScreen.eventDetails.date')}     value={eventDateStr} />
          {!isFlatRateQuote && (
            <Row label={t('clientQuoteDetailScreen.eventDetails.duration')}  value={t('clientQuoteDetailScreen.eventDetails.durationValue', { hours: quote.duration_hours })} />
          )}
          {quote.event_time ? <Row label={t('clientQuoteDetailScreen.eventDetails.time')} value={quote.event_time} /> : null}
        </View>

        {/* Horas extra disponibles */}
        {(quote.overtime_1h_price || quote.overtime_2h_price || quote.overtime_3h_price) && (
          <View style={s.section}>
            <Text style={s.sectionTitle}>{t('clientQuoteDetailScreen.overtime.title')}</Text>
            <Text style={s.overtimeNote}>
              {t('clientQuoteDetailScreen.overtime.note')}
            </Text>
            {quote.overtime_1h_price ? <Row label={t('clientQuoteDetailScreen.overtime.plus1')} value={`$${quote.overtime_1h_price?.toLocaleString()}`} /> : null}
            {quote.overtime_2h_price ? <Row label={t('clientQuoteDetailScreen.overtime.plus2')} value={`$${quote.overtime_2h_price?.toLocaleString()}`} /> : null}
            {quote.overtime_3h_price ? <Row label={t('clientQuoteDetailScreen.overtime.plus3')} value={`$${quote.overtime_3h_price?.toLocaleString()}`} /> : null}
          </View>
        )}

        {/* Notas del grupo */}
        {quote.group_notes ? (
          <View style={s.section}>
            <Text style={s.sectionTitle}>{t('clientQuoteDetailScreen.groupNotes.title')}</Text>
            <View style={s.noteBox}>
              <Text style={s.noteText}>"{quote.group_notes}"</Text>
            </View>
          </View>
        ) : null}

        {/* La forma de pago se elige UNA sola vez, en el checkout
            (QuotePaymentScreen). Aquí solo se acepta la cotización. */}

        {/* Acciones */}
        {isPending && (
          <View style={s.actions}>
            <Pressable
              style={[s.cancelBtn, acting && { opacity: 0.5 }]}
              onPress={handleCancel}
              disabled={acting}
            >
              <XCircle size={18} color={COLORS.red} />
              <Text style={s.cancelBtnText}>{t('clientQuoteDetailScreen.actions.cancel')}</Text>
            </Pressable>
            <Pressable
              style={[s.acceptBtn, acting && { opacity: 0.5 }]}
              onPress={handleAccept}
              disabled={acting}
            >
              {acting
                ? <ActivityIndicator size="small" color={COLORS.bg} />
                : <CheckCircle size={18} color={COLORS.bg} />}
              <Text style={s.acceptBtnText}>{t('clientQuoteDetailScreen.actions.hireAndPay')}</Text>
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
            <Text style={s.acceptBtnText}>{t('clientQuoteDetailScreen.actions.requoteAgain')}</Text>
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
