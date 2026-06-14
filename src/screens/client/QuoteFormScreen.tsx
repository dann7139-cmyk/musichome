/**
 * QuoteFormScreen — Cliente solicita cotización personalizada a un grupo.
 * Mínimo 3 horas. El break lo elige el grupo al iniciar, no el cliente.
 */
import React, { useState } from 'react';
import {
  Alert,
  KeyboardAvoidingView,
  Modal,
  Platform,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  View,
} from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { ArrowLeft, CheckCircle, Clock, Send } from 'lucide-react-native';
import { Calendar } from 'react-native-calendars';
import { supabase } from '../../config/supabase';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';
import TimePickerModal from '../../components/ui/TimePickerModal';
import MapAddressPicker, { AddressResult } from '../../components/ui/MapAddressPicker';
import { analyzeMessage, PHONE_WARNING } from '../../utils/phoneFilter';
import { containsBlockedContact } from '../../utils/contentModeration';
import i18n from '../../i18n';

// ─── Opciones ────────────────────────────────────────────────────────────────

const EVENT_TYPES = [
  { key: 'fiesta_privada', label: '🎉 Fiesta privada' },
  { key: 'boda',           label: '💍 Boda' },
  { key: 'cumpleanos',     label: '🎂 Cumpleaños' },
  { key: 'graduacion',     label: '🎓 Graduación' },
  { key: 'empresarial',    label: '🏢 Empresarial' },
  { key: 'otro',           label: '🎵 Otro' },
];

// Mínimo 3 horas por regla del negocio
const DURATION_OPTIONS = [
  { value: 3,  label: '3 horas' },
  { value: 4,  label: '4 horas' },
  { value: 5,  label: '5 horas' },
  { value: 6,  label: '6 horas' },
  { value: 7,  label: '7 horas' },
  { value: 8,  label: '8+ horas' },
];

const COVERED_OPTIONS = [
  { key: 'si',    label: 'Sí' },
  { key: 'no',    label: 'No' },
  { key: 'no_se', label: 'No sé' },
];

const VENUE_SIZES = [
  { key: 'patio_pequeno',         label: '🏡 Patio pequeño' },
  { key: 'salon_mediano',         label: '🏛️ Salón mediano' },
  { key: 'jardin_grande',         label: '🌳 Jardín grande' },
  { key: 'escenario_profesional', label: '🎤 Escenario profesional' },
];

const SOUND_OPTIONS = [
  { key: 'si',       label: 'Sí, necesito' },
  { key: 'no',       label: 'No necesito' },
  { key: 'ya_tengo', label: 'Ya cuento con sonido' },
];

// ─── Helpers ─────────────────────────────────────────────────────────────────

function SectionTitle({ children }: { children: React.ReactNode }) {
  return <Text style={s.sectionTitle}>{children}</Text>;
}

function ChipRow<T extends string | number>({
  options, selected, onSelect,
}: {
  options: { key: T; label: string }[];
  selected: T | null;
  onSelect: (v: T) => void;
}) {
  return (
    <View style={s.chipRow}>
      {options.map(o => (
        <Pressable
          key={String(o.key)}
          style={[s.chip, selected === o.key && s.chipActive]}
          onPress={() => onSelect(o.key)}
        >
          <Text style={[s.chipText, selected === o.key && s.chipTextActive]}>
            {o.label}
          </Text>
        </Pressable>
      ))}
    </View>
  );
}

// ─── Screen ──────────────────────────────────────────────────────────────────

export default function QuoteFormScreen({ route, navigation }: any) {
  const { group } = route.params as { group: any };

  // ── Estado del formulario ────────────────────────────────────────────────
  const [eventType,    setEventType]    = useState<string | null>(null);
  const [address,      setAddress]      = useState('');
  const [municipio,    setMunicipio]    = useState('');
  const [estado,       setEstado]       = useState('');
  const [eventDate,    setEventDate]    = useState('');   // 'YYYY-MM-DD'
  const [eventTime,    setEventTime]    = useState('');   // 'HH:MM'
  const [duration,     setDuration]     = useState<number | null>(null);
  const [numPersonas,  setNumPersonas]  = useState('');
  const [venueCovered, setVenueCovered] = useState<string | null>(null);
  const [venueSize,    setVenueSize]    = useState<string | null>(null);
  const [needsSound,   setNeedsSound]   = useState<string | null>(null);
  const [comments,     setComments]     = useState('');
  const [commentsWarn, setCommentsWarn] = useState(false);
  const [latitude,     setLatitude]     = useState<number | null>(null);
  const [longitude,    setLongitude]    = useState<number | null>(null);
  const [addressConfirmed, setAddressConfirmed] = useState(false);
  const [loading,      setLoading]      = useState(false);
  const [calendarOpen, setCalendarOpen] = useState(false);
  const [timePickerOpen, setTimePickerOpen] = useState(false);
  const [mapPickerOpen, setMapPickerOpen] = useState(false);
  const [showManualAddress, setShowManualAddress] = useState(false);

  const onConfirmAddress = (result: AddressResult) => {
    setAddress(result.address);
    setMunicipio(result.municipio);
    setEstado(result.estado);
    setLatitude(result.latitude);
    setLongitude(result.longitude);
    setAddressConfirmed(true);
    setMapPickerOpen(false);
    setShowManualAddress(false);
  };

  const formatTime12h = (t: string) => {
    const [hStr, mStr] = t.split(':');
    const h = parseInt(hStr, 10);
    const ampm = h >= 12 ? 'PM' : 'AM';
    const h12 = h % 12 || 12;
    return `${h12}:${mStr} ${ampm}`;
  };

  // ── Validación ───────────────────────────────────────────────────────────
  const canSubmit = () =>
    !!eventType && address.trim() && municipio.trim() && estado.trim() &&
    addressConfirmed &&
    !!eventDate && !!eventTime && !!duration &&
    !!numPersonas && parseInt(numPersonas) > 0 &&
    !!venueCovered && !!venueSize && !!needsSound;

  // ── Enviar ───────────────────────────────────────────────────────────────
  const handleSubmit = async () => {
    if (!canSubmit()) {
      Alert.alert('Campos incompletos', 'Por favor completa todos los campos requeridos.');
      return;
    }

    if (comments.trim() && containsBlockedContact(comments)) {
      Alert.alert(i18n.t('moderation.title'), i18n.t('moderation.no_contact'));
      return;
    }

    const { data: { user } } = await supabase.auth.getUser();
    if (!user) { Alert.alert('Error', 'Sesión no encontrada.'); return; }

    setLoading(true);
    const { error } = await supabase.from('quotes').insert({
      group_id:        group.id,
      client_id:       user.id,
      event_type:      eventType!,
      event_address:   address.trim(),
      event_municipio: municipio.trim(),
      event_estado:    estado.trim(),
      latitude,
      longitude,
      event_date:      eventDate,
      event_time:      eventTime,
      break_type:      'A' as const,
      duration_hours:  duration!,
      num_personas:    parseInt(numPersonas),
      venue_covered:   venueCovered,
      venue_size:      venueSize,
      needs_sound:     needsSound,
      comments:        comments.trim() || null,
    });
    setLoading(false);

    if (error) {
      Alert.alert('Error', 'No se pudo enviar la solicitud. Inténtalo de nuevo.');
    } else {
      // Notificar al grupo
      const { data: groupData } = await supabase
        .from('groups')
        .select('owner_id')
        .eq('id', group.id)
        .single();
      if (groupData?.owner_id) {
        // Notificar al dueño
        await supabase.from('notifications').insert({
          user_id: groupData.owner_id,
          type:    'new_quote_request',
          title:   '📋 Nueva solicitud de cotización',
          body:    `Un cliente solicita cotización para un evento de ${duration}h. Revisa y envía el precio.`,
          data:    { group_id: group.id },
        });

        // Notificar a los integrantes del grupo
        const { data: members } = await supabase
          .from('job_invitations')
          .select('invited_user_id')
          .eq('group_id', group.id)
          .eq('invitation_type', 'membership')
          .eq('status', 'accepted');

        if (members && members.length > 0) {
          await supabase.from('notifications').insert(
            members.map((m: any) => ({
              user_id: m.invited_user_id,
              type:    'new_quote_request',
              title:   '📋 Nueva solicitud de cotización',
              body:    `Tu grupo recibió una solicitud de cotización de ${duration}h. El dueño enviará el precio.`,
              data:    { group_id: group.id },
            }))
          );
        }

        // Notificar a invitados de trabajo aceptados
        const { data: jobInvites } = await supabase
          .from('job_invitations')
          .select('invited_user_id')
          .eq('group_id', group.id)
          .eq('invitation_type', 'job')
          .eq('status', 'accepted');

        if (jobInvites && jobInvites.length > 0) {
          await supabase.from('notifications').insert(
            jobInvites.map((m: any) => ({
              user_id: m.invited_user_id,
              type:    'new_quote_request',
              title:   '📋 Nueva solicitud de cotización',
              body:    `Tu grupo recibió una solicitud de cotización de ${duration}h. El dueño enviará el precio.`,
              data:    { group_id: group.id },
            }))
          );
        }
      }
      Alert.alert(
        '✅ Solicitud enviada',
        `Tu solicitud de cotización a "${group.name}" fue enviada. Te notificaremos cuando el grupo responda.`,
        [{ text: 'Entendido', onPress: () => navigation.goBack() }],
      );
    }
  };

  // ── Render ───────────────────────────────────────────────────────────────
  return (
    <View style={s.root}>
      <SafeAreaView edges={['top']} style={s.header}>
        <Pressable style={s.backBtn} onPress={() => navigation.goBack()}>
          <ArrowLeft size={20} color={COLORS.text} />
        </Pressable>
        <View style={{ flex: 1 }}>
          <Text style={s.headerTitle}>Solicitar cotización</Text>
          <Text style={s.headerSub}>{group.name}</Text>
        </View>
      </SafeAreaView>

      {/* ── Progreso ─────────────────────────────────────────────────────────── */}
      {(() => {
        const sections = [
          !!eventType,
          !!(address.trim() && addressConfirmed),
          !!eventDate,
          !!eventTime,
          !!duration,
          !!(numPersonas && parseInt(numPersonas, 10) > 0),
          !!venueCovered,
          !!venueSize,
          !!needsSound,
        ];
        const completed = sections.filter(Boolean).length;
        const total = sections.length;
        return (
          <View style={s.progressWrap}>
            <View style={s.progressTrack}>
              <View style={[s.progressFill, { width: `${Math.round((completed / total) * 100)}%` as any }]} />
            </View>
            <Text style={s.progressLabel}>{completed} de {total} completadas</Text>
          </View>
        );
      })()}

      <KeyboardAvoidingView
        style={{ flex: 1 }}
        behavior={Platform.OS === 'ios' ? 'padding' : undefined}
      >
        <ScrollView contentContainerStyle={s.scroll} showsVerticalScrollIndicator={false}>

          {/* Info banner */}
          <View style={s.infoBanner}>
            <Text style={s.infoBannerText}>
              📍 El grupo revisará tu solicitud y te enviará un precio personalizado. Mínimo 3 horas de servicio.
            </Text>
          </View>

          {/* ─── 1. TIPO DE EVENTO ──────────────────────────────── */}
          <SectionTitle>1. Tipo de evento *</SectionTitle>
          <View style={s.chipGrid}>
            {EVENT_TYPES.map(o => (
              <Pressable
                key={o.key}
                style={[s.chipWide, eventType === o.key && s.chipActive]}
                onPress={() => setEventType(o.key)}
              >
                <Text style={[s.chipText, eventType === o.key && s.chipTextActive]}>
                  {o.label}
                </Text>
              </Pressable>
            ))}
          </View>

          {/* ─── 2. UBICACIÓN ───────────────────────────────────── */}
          <SectionTitle>2. Ubicación del evento *</SectionTitle>

          {address && !showManualAddress ? (
            /* Address confirmed via map */
            <View style={s.addressCard}>
              <CheckCircle size={16} color={COLORS.green} style={{ marginTop: 2, flexShrink: 0 }} />
              <View style={{ flex: 1 }}>
                <Text style={s.addressCardText} numberOfLines={2}>{address}</Text>
                {(municipio || estado) ? (
                  <Text style={s.addressCardSub}>{[municipio, estado].filter(Boolean).join(', ')}</Text>
                ) : null}
              </View>
              <Pressable onPress={() => setMapPickerOpen(true)}>
                <Text style={s.addressCardEdit}>Cambiar</Text>
              </Pressable>
            </View>
          ) : showManualAddress ? (
            /* Manual input fallback */
            <>
              <TextInput
                style={s.input}
                placeholder="Dirección completa"
                placeholderTextColor={COLORS.muted}
                value={address}
                onChangeText={t => { setAddress(t); setAddressConfirmed(false); }}
              />
              <View style={s.row2}>
                <TextInput
                  style={[s.input, { flex: 1 }]}
                  placeholder="Municipio"
                  placeholderTextColor={COLORS.muted}
                  value={municipio}
                  onChangeText={t => { setMunicipio(t); setAddressConfirmed(false); }}
                />
                <TextInput
                  style={[s.input, { flex: 1 }]}
                  placeholder="Estado"
                  placeholderTextColor={COLORS.muted}
                  value={estado}
                  onChangeText={t => { setEstado(t); setAddressConfirmed(false); }}
                />
              </View>
              <Pressable onPress={() => setMapPickerOpen(true)} style={s.useMapBtn}>
                <Text style={s.useMapBtnText}>📍 Usar mapa</Text>
              </Pressable>
            </>
          ) : (
            /* Default: open map picker */
            <>
              <Pressable style={s.mapPickerBtn} onPress={() => setMapPickerOpen(true)}>
                <Text style={s.mapPickerBtnText}>📍 Seleccionar en el mapa</Text>
              </Pressable>
              <Pressable onPress={() => setShowManualAddress(true)} style={s.manualFallback}>
                <Text style={s.manualFallbackText}>Escribir dirección manualmente</Text>
              </Pressable>
            </>
          )}

          {/* ─── 3. FECHA ────────────────────────────────────────── */}
          <SectionTitle>3. Fecha del evento *</SectionTitle>
          <Pressable style={s.dateBtn} onPress={() => setCalendarOpen(true)}>
            <Text style={[s.dateBtnText, !eventDate && { color: COLORS.muted }]}>
              {eventDate
                ? new Date(eventDate + 'T12:00:00').toLocaleDateString('es-MX', { weekday: 'long', year: 'numeric', month: 'long', day: 'numeric' })
                : '📅 Seleccionar fecha'}
            </Text>
          </Pressable>

          {/* ─── 4. HORA ─────────────────────────────────────────── */}
          <SectionTitle>4. Hora de inicio *</SectionTitle>
          <Pressable
            style={[s.timeChip, !!eventTime && s.timeChipActive]}
            onPress={() => setTimePickerOpen(true)}
          >
            <Clock size={16} color={eventTime ? COLORS.green : COLORS.muted2} />
            <Text style={[s.timeChipText, !!eventTime && s.timeChipTextActive]}>
              {eventTime ? formatTime12h(eventTime) : 'Toca para elegir la hora'}
            </Text>
          </Pressable>

          {/* ─── 5. DURACIÓN ─────────────────────────────────────── */}
          <SectionTitle>5. Duración *  <Text style={s.minNote}>(mínimo 3 horas)</Text></SectionTitle>
          <ChipRow
            options={DURATION_OPTIONS.map(d => ({ key: d.value, label: d.label }))}
            selected={duration}
            onSelect={v => setDuration(Number(v))}
          />

          {/* ─── 6. NÚMERO DE PERSONAS ───────────────────────────── */}
          <SectionTitle>6. Número aproximado de personas *</SectionTitle>
          <TextInput
            style={s.input}
            placeholder="Ej: 50"
            placeholderTextColor={COLORS.muted}
            value={numPersonas}
            onChangeText={t => setNumPersonas(t.replace(/[^0-9]/g, ''))}
            keyboardType="numeric"
            maxLength={4}
          />

          {/* ─── 7. ¿TECHADO? ────────────────────────────────────── */}
          <SectionTitle>7. ¿El lugar está techado? *</SectionTitle>
          <ChipRow
            options={COVERED_OPTIONS as any}
            selected={venueCovered}
            onSelect={setVenueCovered}
          />

          {/* ─── 8. ESPACIO ──────────────────────────────────────── */}
          <SectionTitle>8. Espacio aproximado *</SectionTitle>
          <View style={s.chipGrid}>
            {VENUE_SIZES.map(o => (
              <Pressable
                key={o.key}
                style={[s.chipWide, venueSize === o.key && s.chipActive]}
                onPress={() => setVenueSize(o.key)}
              >
                <Text style={[s.chipText, venueSize === o.key && s.chipTextActive]}>
                  {o.label}
                </Text>
              </Pressable>
            ))}
          </View>

          {/* ─── 9. SONIDO ───────────────────────────────────────── */}
          <SectionTitle>9. ¿Necesitas sonido incluido? *</SectionTitle>
          <ChipRow
            options={SOUND_OPTIONS as any}
            selected={needsSound}
            onSelect={setNeedsSound}
          />

          {/* ─── 10. COMENTARIOS ──────────────────────────────────── */}
          <SectionTitle>10. Comentarios adicionales</SectionTitle>
          <TextInput
            style={[s.input, s.inputMulti]}
            placeholder={'Ej: "El evento es en rancho a 30 min de la ciudad"\n"Es al aire libre"\n"Queremos música variada"'}
            placeholderTextColor={COLORS.muted}
            value={comments}
            onChangeText={v => {
              let c = v.replace(/[0-9]/g, '');
              const NUM_WORDS = /\b(cero|uno|dos|tres|cuatro|cinco|seis|siete|ocho|nueve)([\s\-./]+(cero|uno|dos|tres|cuatro|cinco|seis|siete|ocho|nueve)){2,}/gi;
              c = c.replace(NUM_WORDS, '');
              const result = analyzeMessage(c);
              setCommentsWarn(result.blocked);
              setComments(c);
            }}
            multiline
            maxLength={500}
            textAlignVertical="top"
          />
          <Text style={s.charCount}>{comments.length}/500</Text>
          {commentsWarn && (
            <View style={s.warnBox}>
              <Text style={s.warnText}>⚠️ {PHONE_WARNING}</Text>
            </View>
          )}

          {/* ─── BOTÓN ENVIAR ────────────────────────────────────── */}
          <Pressable
            style={[s.submitBtn, (!canSubmit() || loading) && s.submitBtnDisabled]}
            onPress={handleSubmit}
            disabled={!canSubmit() || loading}
          >
            <Send size={18} color={canSubmit() ? COLORS.bg : COLORS.muted} />
            <Text style={[s.submitBtnText, !canSubmit() && { color: COLORS.muted }]}>
              {loading ? 'Enviando...' : 'Enviar solicitud de cotización'}
            </Text>
          </Pressable>

          <View style={{ height: 40 }} />
        </ScrollView>
      </KeyboardAvoidingView>

      {/* ── Modal Calendario ─────────────────────────────────────────────────── */}
      <Modal visible={calendarOpen} transparent animationType="slide">
        <View style={s.calOverlay}>
          <View style={s.calSheet}>
            <Text style={s.calTitle}>Selecciona la fecha</Text>
            <Calendar
              onDayPress={(day: any) => {
                setEventDate(day.dateString);
                setCalendarOpen(false);
              }}
              markedDates={eventDate ? { [eventDate]: { selected: true, selectedColor: COLORS.green } } : {}}
              minDate={(() => { const d = new Date(); d.setDate(d.getDate() - 1); return d.toISOString().split('T')[0]; })()}
              theme={{
                backgroundColor: COLORS.card,
                calendarBackground: COLORS.card,
                textSectionTitleColor: COLORS.muted2,
                selectedDayBackgroundColor: COLORS.green,
                selectedDayTextColor: COLORS.bg,
                todayTextColor: COLORS.green,
                dayTextColor: COLORS.text,
                textDisabledColor: COLORS.muted,
                arrowColor: COLORS.green,
                monthTextColor: COLORS.text,
              }}
            />
            <Pressable style={s.calClose} onPress={() => setCalendarOpen(false)}>
              <Text style={s.calCloseText}>Cancelar</Text>
            </Pressable>
          </View>
        </View>
      </Modal>
      <TimePickerModal
        visible={timePickerOpen}
        value={eventTime}
        title="Hora de inicio"
        onConfirm={(t) => { setEventTime(t); setTimePickerOpen(false); }}
        onClose={() => setTimePickerOpen(false)}
      />

      <MapAddressPicker
        visible={mapPickerOpen}
        onConfirm={onConfirmAddress}
        onClose={() => setMapPickerOpen(false)}
        initialLatitude={latitude ?? undefined}
        initialLongitude={longitude ?? undefined}
      />
    </View>
  );
}

// ─── Styles ──────────────────────────────────────────────────────────────────

const s = StyleSheet.create({
  root: { flex: 1, backgroundColor: COLORS.bg },

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

  scroll: { padding: SPACING.xl },

  infoBanner: {
    backgroundColor: 'rgba(0,230,118,0.08)',
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.25)',
    borderRadius: RADIUS.lg, padding: 14, marginBottom: 24,
  },
  infoBannerText: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.green, lineHeight: 20 },

  sectionTitle: {
    fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.text,
    marginTop: 24, marginBottom: 12,
  },
  minNote: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, fontWeight: 'normal' },

  // ── Inputs ────────────────────────────────────────────────────────────────
  input: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: COLORS.border,
    paddingHorizontal: 14, paddingVertical: 13,
    fontFamily: FONTS.body, fontSize: 14, color: COLORS.text,
    marginBottom: 10,
  },
  inputMulti: { minHeight: 100, paddingTop: 13 },
  charCount:  { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted, textAlign: 'right', marginTop: 2, marginBottom: 10 },
  row2:       { flexDirection: 'row', gap: 10 },

  // ── Map confirm ───────────────────────────────────────────────────────────
  mapConfirmSection: { marginBottom: 10, marginTop: -4 },
  mapConfirmBtn: {
    flexDirection: 'row', alignItems: 'center', gap: 8,
    backgroundColor: 'rgba(0,230,118,0.08)', borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: COLORS.green,
    paddingVertical: 11, paddingHorizontal: 14,
  },
  mapConfirmBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.green, flex: 1 },
  mapConfirmed: {
    flexDirection: 'row', alignItems: 'center', gap: 8,
    backgroundColor: 'rgba(0,230,118,0.08)', borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: COLORS.green,
    paddingVertical: 11, paddingHorizontal: 14,
  },
  mapConfirmedText: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.green },
  mapConfirmedLink: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.green, opacity: 0.7, marginTop: 2 },
  mapHint: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted, marginTop: 6, marginLeft: 4 },

  // ── Time chip ─────────────────────────────────────────────────────────────
  timeChip: {
    flexDirection: 'row', alignItems: 'center', gap: 10,
    backgroundColor: COLORS.card, borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: COLORS.border,
    paddingHorizontal: 14, paddingVertical: 15, marginBottom: 10,
  },
  timeChipActive:     { borderColor: COLORS.green, backgroundColor: 'rgba(0,230,118,0.08)' },
  timeChipText:       { fontFamily: FONTS.body, fontSize: 15, color: COLORS.muted2, flex: 1 },
  timeChipTextActive: { fontFamily: FONTS.bodySemiBold, color: COLORS.green },

  // ── Date btn ──────────────────────────────────────────────────────────────
  dateBtn: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: COLORS.border,
    paddingHorizontal: 14, paddingVertical: 14,
    marginBottom: 10,
  },
  dateBtnText: { fontFamily: FONTS.bodyMedium, fontSize: 14, color: COLORS.text },

  // ── Chips ─────────────────────────────────────────────────────────────────
  chipRow:  { flexDirection: 'row', gap: 8, flexWrap: 'wrap', marginBottom: 4 },
  chipGrid: { flexDirection: 'row', gap: 10, flexWrap: 'wrap', marginBottom: 4 },
  chip: {
    paddingHorizontal: 14, paddingVertical: 10,
    borderRadius: RADIUS.full,
    backgroundColor: COLORS.card, borderWidth: 1, borderColor: COLORS.border,
  },
  chipWide: {
    paddingHorizontal: 14, paddingVertical: 10,
    borderRadius: RADIUS.lg,
    backgroundColor: COLORS.card, borderWidth: 1, borderColor: COLORS.border,
  },
  chipActive:     { backgroundColor: 'rgba(0,230,118,0.12)', borderColor: COLORS.green },
  chipText:       { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted2 },
  chipTextActive: { color: COLORS.green },

  // ── Progreso ──────────────────────────────────────────────────────────────
  progressWrap:  { paddingHorizontal: SPACING.xl, paddingTop: 10, paddingBottom: 6 },
  progressTrack: { width: '100%', height: 4, backgroundColor: COLORS.border, borderRadius: 2, marginBottom: 6 },
  progressFill:  { height: 4, backgroundColor: COLORS.green, borderRadius: 2 },
  progressLabel: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, textAlign: 'right' },

  // ── Submit ────────────────────────────────────────────────────────────────
  submitBtn: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 10,
    backgroundColor: COLORS.green, borderRadius: RADIUS.lg,
    paddingVertical: 16, marginTop: 28,
  },
  submitBtnDisabled: { opacity: 0.4 },
  submitBtnText:     { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.bg },

  // ── Calendar modal ────────────────────────────────────────────────────────
  calOverlay: { flex: 1, backgroundColor: 'rgba(0,0,0,0.7)', justifyContent: 'flex-end' },
  calSheet: {
    backgroundColor: COLORS.card, borderTopLeftRadius: 24, borderTopRightRadius: 24,
    paddingTop: 20, paddingBottom: 32,
    borderTopWidth: 1, borderTopColor: COLORS.border,
  },
  calTitle:     { fontFamily: FONTS.title, fontSize: 20, color: COLORS.text, textAlign: 'center', marginBottom: 12 },
  calClose:     { marginTop: 16, alignItems: 'center' },
  calCloseText: { fontFamily: FONTS.bodyMedium, fontSize: 14, color: COLORS.muted2 },

  // GPS location card
  locationLoadingRow: { flexDirection: 'row', alignItems: 'center', gap: 10, paddingVertical: 12, marginBottom: 10 },
  locationLoadingText: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted },
  locationCard: {
    flexDirection: 'row', alignItems: 'center',
    backgroundColor: 'rgba(0,230,118,0.08)', borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.35)',
    paddingHorizontal: 14, paddingVertical: 12, marginBottom: 10,
  },
  locationCardCity:   { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.text },
  locationCardEstado: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted, marginTop: 2 },
  locationEditBtn:     { paddingHorizontal: 10, paddingVertical: 6 },
  locationEditBtnText: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.green },

  // Map address picker
  mapPickerBtn: {
    backgroundColor: 'rgba(0,230,118,0.08)',
    borderRadius: RADIUS.md, borderWidth: 1, borderColor: COLORS.green,
    paddingVertical: 14, paddingHorizontal: 14, marginBottom: 8,
    alignItems: 'center',
  },
  mapPickerBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.green },

  addressCard: {
    flexDirection: 'row', alignItems: 'flex-start', gap: 10,
    backgroundColor: 'rgba(0,230,118,0.08)',
    borderRadius: RADIUS.md, borderWidth: 1, borderColor: 'rgba(0,230,118,0.35)',
    paddingVertical: 12, paddingHorizontal: 14, marginBottom: 8,
  },
  addressCardText: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.text, lineHeight: 18 },
  addressCardSub:  { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, marginTop: 2 },
  addressCardEdit: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.green, marginLeft: 4 },

  manualFallback:     { alignSelf: 'center', paddingVertical: 6, marginBottom: 4 },
  manualFallbackText: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2 },

  useMapBtn:     { alignSelf: 'flex-start', paddingVertical: 6, marginTop: 4, marginBottom: 4 },
  useMapBtnText: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.green },

  warnBox:  { backgroundColor: 'rgba(239,83,80,0.10)', borderRadius: RADIUS.sm, padding: 10, marginTop: 6, borderWidth: 1, borderColor: 'rgba(239,83,80,0.3)' },
  warnText: { fontFamily: FONTS.body, fontSize: 12, color: '#EF5350', lineHeight: 17 },
});
