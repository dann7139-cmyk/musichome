import { ArrowLeft, Store, Volume2 } from 'lucide-react-native';
import React, { useEffect, useState } from 'react';
import {
  ActivityIndicator,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { useTranslation } from 'react-i18next';
import { supabase } from '../../config/supabase';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';
import Badge from '../../components/ui/Badge';

// sql/585 (Fase 1, NO desplegado todavía) — consume admin_get_event_detail().
// Pantalla nueva, aditiva, registrada en AppNavigator pero SIN un punto de
// entrada pulido todavía (admin_expediente_detail no expone event_id —
// pendiente, no se tocó para no expandir el alcance sin autorización).
// Muestra el evento real (event_id compartido) con todos sus proveedores
// agrupados — nunca mezcla dinero ni estados entre ellos, cada `provider`
// es su propia reserva/pago intacto.
//
// Ícono genérico (Store) en vez de uno musical: hasta que las categorías
// reales (provider_categories) estén conectadas a esta consulta, esta
// pantalla NO sabe si un proveedor es música/DJ/comida/renta — mostrar un
// ícono de nota musical fijo sería engañoso para los que no lo son.

interface EventProvider {
  reservation_id: string;
  group_id: string;
  group_name: string | null;
  genre: string | null;
  status: string;
  total_price: number | null;
  currency?: string | null;
  currency_code?: string | null;
  needs_sound?: string | null;
  needs_lighting?: string | null;
  has_own_sound?: boolean | null;
  has_own_lighting?: boolean | null;
  quote?: {
    id: string;
    status: string;
    needs_sound: string | null;
    needs_lighting: string | null;
    needs_stage: string | null;
    needs_led: string | null;
  } | null;
}

interface EventDetail {
  id: string;
  event_date: string;
  event_time?: string | null;
  address: string;
  client_id: string;
  client_name?: string | null;
}

interface SoundSummary {
  needs_review: boolean;
  max_needs_sound?: string | null;
  requested_by?: string[];
}

export default function AdminEventDetailScreen({ navigation, route }: any) {
  const { t, i18n } = useTranslation();
  const eventId: string = route?.params?.eventId;
  const [loading, setLoading]   = useState(true);
  const [event, setEvent]       = useState<EventDetail | null>(null);
  const [providers, setProviders] = useState<EventProvider[]>([]);
  const [soundSummary, setSoundSummary] = useState<SoundSummary | null>(null);

  const dateLocale = i18n.language?.startsWith('en') ? 'en-US' : 'es-MX';

  const STATUS_LABEL: Record<string, { label: string; variant: any }> = {
    pending:                    { label: t('adminEventDetailScreen.status.pending'),                    variant: 'orange' },
    pending_payment:            { label: t('adminEventDetailScreen.status.pending_payment'),            variant: 'orange' },
    pending_group_confirmation: { label: t('adminEventDetailScreen.status.pending_group_confirmation'), variant: 'orange' },
    accepted:                   { label: t('adminEventDetailScreen.status.accepted'),                   variant: 'green' },
    confirmed:                  { label: t('adminEventDetailScreen.status.confirmed'),                  variant: 'green' },
    in_progress:                { label: t('adminEventDetailScreen.status.in_progress'),                variant: 'blue' },
    completed:                  { label: t('adminEventDetailScreen.status.completed'),                  variant: 'muted' },
    cancelled:                  { label: t('adminEventDetailScreen.status.cancelled'),                  variant: 'red' },
    rejected:                   { label: t('adminEventDetailScreen.status.rejected'),                   variant: 'red' },
  };

  const NEEDS_SOUND_LABEL: Record<string, string> = {
    si_50:  t('adminEventDetailScreen.needsSound.si_50'),
    si_100: t('adminEventDetailScreen.needsSound.si_100'),
    si_200: t('adminEventDetailScreen.needsSound.si_200'),
    si:     t('adminEventDetailScreen.needsSound.si'),
  };

  const load = async () => {
    setLoading(true);
    const { data, error } = await supabase.rpc('admin_get_event_detail', { p_event_id: eventId });
    if (!error && data?.ok) {
      setEvent(data.event);
      setProviders(data.providers ?? []);
      setSoundSummary(data.sound_summary ?? { needs_review: false });
    }
    setLoading(false);
  };

  useEffect(() => { if (eventId) load(); }, [eventId]);

  // sql/585 v2 — la bandera viene DIRECTO del backend (admin_get_event_detail.
  // sound_summary), que se calcula EXCLUSIVAMENTE de lo que el cliente/grupo
  // declaró en sus cotizaciones (quotes.needs_sound/lighting/stage/led).
  // Decisión explícita del usuario: nunca se activa por cantidad de
  // proveedores ni por tamaño del evento — una fiesta con 3 grupos y sonido
  // normal no debe encender esta alerta, y una fiesta con 1 grupo que pidió
  // sonido grande sí debe encenderla.
  const needsSoundReview = soundSummary?.needs_review ?? false;

  if (loading) {
    return (
      <View style={{ flex: 1, backgroundColor: COLORS.bg, alignItems: 'center', justifyContent: 'center' }}>
        <ActivityIndicator color={COLORS.green} />
      </View>
    );
  }

  if (!event) {
    return (
      <SafeAreaView style={s.container} edges={['top']}>
        <View style={s.header}>
          <Pressable onPress={() => navigation.goBack()} hitSlop={8}>
            <ArrowLeft size={20} color={COLORS.text} />
          </Pressable>
          <Text style={s.headerTitle}>{t('adminEventDetailScreen.notFound')}</Text>
        </View>
      </SafeAreaView>
    );
  }

  return (
    <View style={{ flex: 1, backgroundColor: COLORS.bg }}>
      <SafeAreaView edges={['top']} style={s.header}>
        <Pressable onPress={() => navigation.goBack()} hitSlop={8}>
          <ArrowLeft size={20} color={COLORS.text} />
        </Pressable>
        <Text style={s.headerTitle}>{t('adminEventDetailScreen.headerTitle')}</Text>
        <View style={{ width: 20 }} />
      </SafeAreaView>

      <ScrollView contentContainerStyle={s.body}>
        <View style={s.eventCard}>
          <Text style={s.eventDate}>
            📅 {new Date(event.event_date + 'T12:00:00').toLocaleDateString(dateLocale, { weekday: 'long', day: 'numeric', month: 'long', year: 'numeric' })}
          </Text>
          <Text style={s.eventAddress}>📍 {event.address}</Text>
          {!!event.client_name && <Text style={s.eventClient}>👤 {event.client_name}</Text>}
        </View>

        {needsSoundReview && (
          <View style={s.soundAlert}>
            <Volume2 size={18} color={COLORS.orange} />
            <View style={{ flex: 1 }}>
              <Text style={s.soundAlertText}>
                {t('adminEventDetailScreen.soundReviewPrefix')}{soundSummary?.max_needs_sound && NEEDS_SOUND_LABEL[soundSummary.max_needs_sound]
                  ? ` — ${NEEDS_SOUND_LABEL[soundSummary.max_needs_sound]}`
                  : ''}
              </Text>
              {!!soundSummary?.requested_by?.length && (
                <Text style={s.soundAlertSub}>{t('adminEventDetailScreen.soundRequestedBy', { names: soundSummary.requested_by.join(', ') })}</Text>
              )}
            </View>
          </View>
        )}

        <Text style={s.sectionTitle}>{t('adminEventDetailScreen.providersSection', { count: providers.length })}</Text>
        {providers.map(p => {
          const st = STATUS_LABEL[p.status] ?? { label: p.status, variant: 'muted' };
          const cur = p.currency ?? p.currency_code ?? 'MXN';
          // "categoría" hoy = groups.genre — no existe todavía un campo
          // category/provider_type separado (ver hallazgo de categorías en
          // el reporte). Se muestra tal cual, sin inventar una etiqueta.
          const providerSoundNeeds = [
            p.quote?.needs_sound && p.quote.needs_sound !== 'no' && p.quote.needs_sound !== 'no_group_brings' && p.quote.needs_sound !== 'ya_tengo'
              ? t('adminEventDetailScreen.needsSound.' + p.quote.needs_sound, { defaultValue: p.quote.needs_sound }) : null,
            p.quote?.needs_lighting && p.quote.needs_lighting !== 'no' ? p.quote.needs_lighting : null,
            p.quote?.needs_stage && p.quote.needs_stage !== 'no' ? p.quote.needs_stage : null,
            p.quote?.needs_led && p.quote.needs_led !== 'no' ? p.quote.needs_led : null,
          ].filter(Boolean);
          return (
            <View key={p.reservation_id} style={s.providerCard}>
              <View style={s.providerRow}>
                <Store size={16} color={COLORS.muted2} />
                <Text style={s.providerName} numberOfLines={1}>{p.group_name ?? '—'}</Text>
                <Badge label={st.label} variant={st.variant} />
              </View>
              {!!p.genre && <Text style={s.providerGenre}>{p.genre}</Text>}
              <View style={s.providerRow}>
                <Text style={s.providerPrice}>
                  {cur === 'USD' ? 'US$' : '$'}{Number(p.total_price ?? 0).toLocaleString(dateLocale)} {cur}
                </Text>
                {p.has_own_sound && <Text style={s.providerTag}>{t('adminEventDetailScreen.ownSoundTag')}</Text>}
              </View>
              {!!p.quote && (
                <Text style={s.providerQuoteLine}>
                  {t('adminEventDetailScreen.quoteStatusPrefix')} {p.quote.status}
                  {providerSoundNeeds.length > 0 ? ` · ${t('adminEventDetailScreen.soundReviewPrefix')} ${providerSoundNeeds.join(', ')}` : ''}
                </Text>
              )}
            </View>
          );
        })}
      </ScrollView>
    </View>
  );
}

const s = StyleSheet.create({
  container: { flex: 1, backgroundColor: COLORS.bg },
  header: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between',
    paddingHorizontal: SPACING.xl, paddingBottom: 12,
  },
  headerTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 16, color: COLORS.text },
  body: { padding: SPACING.xl, gap: 14 },
  eventCard: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg, borderWidth: 1,
    borderColor: COLORS.border, padding: 16, gap: 6,
  },
  eventDate: { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.text },
  eventAddress: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2 },
  eventClient: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2 },
  soundAlert: {
    flexDirection: 'row', alignItems: 'center', gap: 10,
    backgroundColor: 'rgba(255,152,0,0.12)', borderWidth: 1, borderColor: COLORS.orange + '50',
    borderRadius: RADIUS.lg, padding: 14,
  },
  soundAlertText: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.orange },
  soundAlertSub: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.orange, opacity: 0.8, marginTop: 2 },
  sectionTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.text, marginTop: 4 },
  providerCard: {
    backgroundColor: COLORS.card2, borderRadius: RADIUS.lg, borderWidth: 1,
    borderColor: COLORS.border, padding: 14, gap: 8,
  },
  providerRow: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', gap: 8 },
  providerName: { flex: 1, fontFamily: FONTS.bodyMedium, fontSize: 14, color: COLORS.text },
  providerPrice: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.green },
  providerTag: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted2 },
  providerGenre: { fontFamily: FONTS.body, fontSize: 11.5, color: COLORS.muted2, marginTop: -4 },
  providerQuoteLine: { fontFamily: FONTS.body, fontSize: 11.5, color: COLORS.orange },
});
