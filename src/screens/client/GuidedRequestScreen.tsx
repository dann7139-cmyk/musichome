/**
 * GuidedRequestScreen — Solicitud guiada paso a paso.
 *
 * Flujo en 3 pasos:
 *   Paso 1 → Tipo de evento
 *   Paso 2 → Detalles (género, ciudad, fecha, hora, invitados, duración)
 *   Paso 3 → Lugar + enviar (dirección, techo, tamaño, sonido)
 *
 * Reutiliza los mismos campos de event_requests que OpenRequestScreen.
 * Al insertar, llama notify_wave_1 para alertar grupos cercanos.
 */
import * as Location from 'expo-location';
import { LinearGradient } from 'expo-linear-gradient';
import { ArrowLeft, ChevronRight, MapPin, Zap } from 'lucide-react-native';
import { normalizeCity } from '../../utils/cityUtils';
import React, { useEffect, useRef, useState } from 'react';
import {
  ActivityIndicator,
  Alert,
  Animated,
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
import TimePickerModal from '../../components/ui/TimePickerModal';
import MapAddressPicker, { AddressResult } from '../../components/ui/MapAddressPicker';
import { analyzeMessage, PHONE_WARNING } from '../../utils/phoneFilter';
import { containsBlockedContact } from '../../utils/contentModeration';
import i18n from '../../i18n';
import { useTranslation } from 'react-i18next';

// ─── Datos ────────────────────────────────────────────────────────────────────

const EVENT_TYPES = [
  { key: 'boda',        label: 'Boda',        emoji: '💍' },
  { key: 'cumpleanos',  label: 'Cumpleaños',  emoji: '🎂' },
  { key: 'fiesta',      label: 'Fiesta',      emoji: '🎉' },
  { key: 'empresarial', label: 'Empresarial', emoji: '🏢' },
  { key: 'serenata',    label: 'Serenata',    emoji: '🎶' },
  { key: 'graduacion',  label: 'Graduación',  emoji: '🎓' },
  { key: 'otro',        label: 'Otro',        emoji: '🎵' },
];

const MUSIC_GENRES = [
  { key: 'Norteño',           emoji: '🪗' },
  { key: 'Banda',             emoji: '🎺' },
  { key: 'Mariachi',          emoji: '🎻' },
  { key: 'Grupero',           emoji: '🎸' },
  { key: 'Cumbia',            emoji: '🥁' },
  { key: 'Salsa',             emoji: '💃' },
  { key: 'Jazz',              emoji: '🎷' },
  { key: 'Rock',              emoji: '🤘' },
  { key: 'Pop',               emoji: '🎤' },
  { key: 'Regional Mexicano', emoji: '🇲🇽' },
  { key: 'Tropical',          emoji: '🌴' },
  { key: 'Ranchero',          emoji: '🤠' },
  { key: 'Electrónica',       emoji: '🎧' },
  { key: 'Barra de mixología', emoji: '🍸' },
  { key: 'Sonido / Iluminación', emoji: '🔊' },
  { key: 'Otro',              emoji: '🎵' },
];

const DURATION_OPTIONS = [
  { value: 3, label: '3h' }, { value: 4, label: '4h' },
  { value: 5, label: '5h' }, { value: 6, label: '6h' }, { value: 8, label: '8h+' },
];

const COVERED_OPTIONS = [
  { key: 'si',    label: 'Sí' },
  { key: 'no',    label: 'No' },
  { key: 'no_se', label: 'No sé' },
];

const VENUE_SIZES = [
  { key: 'patio_pequeno',         label: 'Patio pequeño',      emoji: '🏡' },
  { key: 'salon_mediano',         label: 'Salón mediano',      emoji: '🏛️' },
  { key: 'jardin_grande',         label: 'Jardín grande',      emoji: '🌳' },
  { key: 'escenario_profesional', label: 'Escenario profesional', emoji: '🎤' },
];

const SOUND_OPTIONS = [
  { key: 'si',       label: 'Necesito sonido' },
  { key: 'no',       label: 'No necesito' },
  { key: 'ya_tengo', label: 'Ya tengo sonido' },
];

function todayStr() {
  const n = new Date();
  return `${n.getFullYear()}-${String(n.getMonth() + 1).padStart(2, '0')}-${String(n.getDate()).padStart(2, '0')}`;
}

function nowTimeStr() {
  const now = new Date();
  return `${String(now.getHours()).padStart(2, '0')}:${String(now.getMinutes()).padStart(2, '0')}`;
}

// ─── Components ───────────────────────────────────────────────────────────────

function StepHeader({ step, total, label }: { step: number; total: number; label: string }) {
  return (
    <View style={s.stepHeader}>
      <View style={s.progressBarTrack}>
        <View style={[s.progressBarFill, { width: `${(step / total) * 100}%` as any }]} />
      </View>
      <Text style={s.stepCounter}>{step} / {total}</Text>
      <Text style={s.stepLabel}>{label}</Text>
    </View>
  );
}

function Chip({
  label, active, onPress,
}: { label: string; active: boolean; onPress: () => void }) {
  return (
    <Pressable style={[s.chip, active && s.chipActive]} onPress={onPress}>
      <Text style={[s.chipText, active && s.chipTextActive]}>{label}</Text>
    </Pressable>
  );
}

// ─── Screen ──────────────────────────────────────────────────────────────────

export default function GuidedRequestScreen({ navigation, route }: any) {
  const { t } = useTranslation();
  const preselectedType = route?.params?.event_type;

  // Step state
  const [step, setStep] = useState<1 | 2 | 3>(preselectedType ? 2 : 1);

  // Step 1
  const [eventType, setEventType] = useState<string | null>(() => {
    if (!preselectedType) return null;
    const found = EVENT_TYPES.find(e =>
      e.label.toLowerCase() === preselectedType.toLowerCase() ||
      e.key.toLowerCase() === preselectedType.toLowerCase()
    );
    return found?.key ?? null;
  });

  // Step 2
  const [genre,      setGenre]      = useState<string | null>(null);
  const [city,       setCity]       = useState('');
  const [estado,     setEstado]     = useState('');
  const eventDate = todayStr();
  const [eventTime,  setEventTime]  = useState(nowTimeStr());
  const [guestCount, setGuestCount] = useState('');
  const [hours,      setHours]      = useState<number>(3);

  // GPS location
  const [locationLoading,    setLocationLoading]    = useState(false);
  const [locationDetected,   setLocationDetected]   = useState(false);
  const [showLocationInputs, setShowLocationInputs] = useState(false);

  // Time picker
  const [showTimePicker, setShowTimePicker] = useState(false);

  // Step 3
  const [address,      setAddress]      = useState('');
  const [municipio,    setMunicipio]    = useState('');
  const [latitude,     setLatitude]     = useState<number | null>(null);
  const [longitude,    setLongitude]    = useState<number | null>(null);
  const [venueCovered, setVenueCovered] = useState<string | null>(null);
  const [venueSize,    setVenueSize]    = useState<string | null>(null);
  const [needsSound,   setNeedsSound]   = useState<string | null>(null);
  const [comments,     setComments]     = useState('');
  const [commentsWarn, setCommentsWarn] = useState(false);

  // Map picker
  const [mapPickerOpen, setMapPickerOpen] = useState(false);
  const [showManualAddress, setShowManualAddress] = useState(false);

  const [loading, setLoading] = useState(false);

  const slideAnim = useRef(new Animated.Value(0)).current;

  // Auto-detect GPS location on mount
  useEffect(() => {
    (async () => {
      setLocationLoading(true);
      try {
        const { status } = await Location.requestForegroundPermissionsAsync();
        if (status === 'granted') {
          const pos = await Location.getCurrentPositionAsync({ accuracy: Location.Accuracy.Balanced });
          const [geo] = await Location.reverseGeocodeAsync(pos.coords);
          if (geo) {
            // subregion = municipio real (Zapopan, Guadalajara…)
            // city devuelve la colonia (Valle de los Molinos) — no sirve para matching
            const detectedMunicipio = geo.subregion ?? '';
            const detectedCity      = detectedMunicipio || (geo.city ?? '');
            setCity(detectedCity);
            if (detectedMunicipio) setMunicipio(detectedMunicipio);
            setEstado(geo.region ?? '');
            setLocationDetected(true);
          }
        }
      } catch (_) {}
      setLocationLoading(false);
    })();
  }, []);

  const goToStep = (next: 1 | 2 | 3) => {
    Animated.sequence([
      Animated.timing(slideAnim, { toValue: -20, duration: 100, useNativeDriver: true }),
      Animated.timing(slideAnim, { toValue: 0,   duration: 200, useNativeDriver: true }),
    ]).start();
    setStep(next);
  };

  const onConfirmAddress = (result: AddressResult) => {
    setAddress(result.address);
    setMunicipio(result.municipio);
    if (!city.trim())   setCity(result.city);
    if (!estado.trim()) setEstado(result.estado);
    setLatitude(result.latitude);
    setLongitude(result.longitude);
    setMapPickerOpen(false);
    setShowManualAddress(false);
  };

  // Validations
  const step2Valid = !!genre && !!city.trim() && !!estado.trim() && !!guestCount && parseInt(guestCount) > 0 && !!hours;
  const step3Valid = !!address.trim() && !!venueCovered && !!venueSize && !!needsSound;

  const handleSubmit = async () => {
    if (!step3Valid) {
      Alert.alert(t('guidedRequestScreen.alerts.incompleteFieldsTitle'), t('guidedRequestScreen.alerts.incompleteFieldsBody'));
      return;
    }

    if (comments.trim() && containsBlockedContact(comments)) {
      Alert.alert(i18n.t('moderation.title'), i18n.t('moderation.no_contact'));
      return;
    }

    const { data: { user } } = await supabase.auth.getUser();
    if (!user) { Alert.alert(t('guidedRequestScreen.alerts.error'), t('guidedRequestScreen.alerts.sessionNotFound')); return; }

    setLoading(true);

    const { data: inserted, error } = await supabase
      .from('event_requests')
      .insert({
        client_id:          user.id,
        genre,
        event_type:         eventType,
        event_date:         eventDate,
        event_time:         eventTime,
        hours,
        guest_count:        parseInt(guestCount),
        location_city:      city.trim(),
        location_municipio: municipio.trim() || null,
        location_estado:    estado.trim(),
        location_address:   address.trim(),
        latitude,
        longitude,
        venue_covered:      venueCovered,
        venue_size:         venueSize,
        needs_sound:        needsSound,
        comments:           comments.trim() || null,
        city:               normalizeCity(city), // normalizado para que coincida con groups.city
      })
      .select()
      .single();

    if (error || !inserted) {
      setLoading(false);
      Alert.alert(t('guidedRequestScreen.alerts.error'), error?.message ?? t('guidedRequestScreen.alerts.submitFailed'));
      return;
    }

    // GPS para ordenar grupos por proximidad
    let eventLat: number | null = null;
    let eventLng: number | null = null;
    try {
      const { status } = await Location.requestForegroundPermissionsAsync();
      if (status === 'granted') {
        const pos = await Location.getCurrentPositionAsync({ accuracy: Location.Accuracy.Balanced });
        eventLat = pos.coords.latitude;
        eventLng = pos.coords.longitude;
      }
    } catch (_) {}

    // Notificar grupos — ola 1 (in-app notifications)
    const { data: rpcResult } = await supabase.rpc('notify_wave_1', {
      p_request_id: inserted.id,
      p_event_lat:  eventLat,
      p_event_lng:  eventLng,
      p_radius_km:  50,
    });

    // Dispatch express → crea express_dispatches → trigger envía push type='express_dispatch'
    // para que AppNavigator lleve al grupo al dashboard con el carousel Uber-style
    await supabase.rpc('dispatch_express_request', {
      p_request_id: inserted.id,
    });

    setLoading(false);

    const notified = rpcResult?.notified ?? 0;
    Alert.alert(
      t('guidedRequestScreen.alerts.sentTitle'),
      t('guidedRequestScreen.alerts.sentBody', { count: notified, genre }),
      [{ text: t('guidedRequestScreen.alerts.viewRequests'), onPress: () => navigation.replace('OpenRequest', { tab: 'mine' }) }],
    );
  };

  // ── Render ──────────────────────────────────────────────────────────────────

  return (
    <View style={s.container}>
      <LinearGradient
        colors={['rgba(0,230,118,0.06)', 'rgba(4,4,4,0)']}
        style={StyleSheet.absoluteFill}
        start={{ x: 0, y: 0 }} end={{ x: 1, y: 0.5 }}
      />
      <SafeAreaView style={{ flex: 1 }}>
        {/* Header */}
        <View style={s.header}>
          <Pressable style={s.backBtn} onPress={() => {
            if (step > 1) goToStep((step - 1) as 1 | 2 | 3);
            else navigation.goBack();
          }}>
            <ArrowLeft size={20} color={COLORS.text} />
          </Pressable>
          <Text style={s.headerTitle}>{t('guidedRequestScreen.header.title')}</Text>
          <View style={{ width: 40 }} />
        </View>

        <Animated.View style={[{ flex: 1 }, { transform: [{ translateX: slideAnim }] }]}>
          <ScrollView
            showsVerticalScrollIndicator={false}
            contentContainerStyle={s.content}
            keyboardShouldPersistTaps="handled"
          >

            {/* ── PASO 1: TIPO DE EVENTO ── */}
            {step === 1 && (
              <>
                <StepHeader step={1} total={3} label={t('guidedRequestScreen.step1.label')} />
                <View style={s.eventTypeGrid}>
                  {EVENT_TYPES.map(et => (
                    <Pressable
                      key={et.key}
                      style={[s.eventTypeCard, eventType === et.key && s.eventTypeCardActive]}
                      onPress={() => {
                        setEventType(et.key);
                        setTimeout(() => goToStep(2), 200);
                      }}
                    >
                      <Text style={s.eventTypeEmoji}>{et.emoji}</Text>
                      <Text style={[s.eventTypeLabel, eventType === et.key && s.eventTypeLabelActive]}>
                        {t(`guidedRequestScreen.step1.eventTypes.${et.key}`)}
                      </Text>
                    </Pressable>
                  ))}
                </View>
              </>
            )}

            {/* ── PASO 2: DETALLES ── */}
            {step === 2 && (
              <>
                <StepHeader step={2} total={3} label={t('guidedRequestScreen.step2.label')} />

                {/* Tipo de música */}
                <Text style={s.fieldLabel}>{t('guidedRequestScreen.step2.genreLabel')}</Text>
                <View style={s.chipWrap}>
                  {MUSIC_GENRES.map(g => (
                    <Pressable
                      key={g.key}
                      style={[s.chip, genre === g.key && s.chipActive]}
                      onPress={() => setGenre(g.key)}
                    >
                      <Text style={s.chipEmoji}>{g.emoji}</Text>
                      <Text style={[s.chipText, genre === g.key && s.chipTextActive]}>{g.key}</Text>
                    </Pressable>
                  ))}
                </View>

                {/* Ubicación — GPS auto-detect */}
                <Text style={s.fieldLabel}>{t('guidedRequestScreen.step2.locationLabel')}</Text>
                {locationLoading ? (
                  <View style={s.locationLoadingRow}>
                    <ActivityIndicator size="small" color={COLORS.green} />
                    <Text style={s.locationLoadingText}>{t('guidedRequestScreen.step2.locationDetecting')}</Text>
                  </View>
                ) : locationDetected && !showLocationInputs ? (
                  <View style={s.locationCard}>
                    <View style={{ flex: 1 }}>
                      <Text style={s.locationCardCity}>{city}</Text>
                      <Text style={s.locationCardEstado}>{estado}</Text>
                    </View>
                    <Pressable style={s.locationEditBtn} onPress={() => setShowLocationInputs(true)}>
                      <Text style={s.locationEditBtnText}>{t('guidedRequestScreen.step2.editBtn')}</Text>
                    </Pressable>
                  </View>
                ) : (
                  <View style={s.row}>
                    <View style={{ flex: 1.2 }}>
                      <TextInput
                        style={s.input}
                        value={city}
                        onChangeText={setCity}
                        placeholder={t('guidedRequestScreen.step2.cityPlaceholder')}
                        placeholderTextColor={COLORS.muted}
                      />
                    </View>
                    <View style={{ flex: 1 }}>
                      <TextInput
                        style={s.input}
                        value={estado}
                        onChangeText={setEstado}
                        placeholder={t('guidedRequestScreen.step2.statePlaceholder')}
                        placeholderTextColor={COLORS.muted}
                      />
                    </View>
                  </View>
                )}

                {/* Hora de inicio */}
                <Text style={s.fieldLabel}>{t('guidedRequestScreen.step2.timeLabel')}</Text>
                <Pressable
                  style={[s.chip, s.timeChip, !!eventTime && s.chipActive]}
                  onPress={() => setShowTimePicker(true)}
                >
                  <Text style={[s.chipText, !!eventTime && s.chipTextActive]}>
                    {eventTime || t('guidedRequestScreen.step2.selectTimePlaceholder')}
                  </Text>
                </Pressable>

                {/* Invitados */}
                <Text style={s.fieldLabel}>{t('guidedRequestScreen.step2.guestsLabel')}</Text>
                <TextInput
                  style={s.input}
                  value={guestCount}
                  onChangeText={setGuestCount}
                  placeholder={t('guidedRequestScreen.step2.guestsPlaceholder')}
                  placeholderTextColor={COLORS.muted}
                  keyboardType="number-pad"
                />

                {/* Duración */}
                <Text style={s.fieldLabel}>{t('guidedRequestScreen.step2.durationLabel')}</Text>
                <View style={s.chipWrap}>
                  {DURATION_OPTIONS.map(d => (
                    <Chip key={d.value} label={d.label} active={hours === d.value} onPress={() => setHours(d.value)} />
                  ))}
                </View>

                <Pressable
                  style={[s.nextBtn, !step2Valid && s.nextBtnDisabled]}
                  onPress={() => step2Valid && goToStep(3)}
                >
                  <Text style={s.nextBtnText}>{t('guidedRequestScreen.step2.continueBtn')}</Text>
                  <ChevronRight size={18} color={step2Valid ? COLORS.bg : COLORS.muted} />
                </Pressable>
              </>
            )}

            {/* ── PASO 3: LUGAR + ENVIAR ── */}
            {step === 3 && (
              <>
                <StepHeader step={3} total={3} label={t('guidedRequestScreen.step3.label')} />

                {/* Dirección */}
                <Text style={s.fieldLabel}>{t('guidedRequestScreen.step3.addressLabel')}</Text>

                {address && !showManualAddress ? (
                  <Pressable style={s.addressCard} onPress={() => setMapPickerOpen(true)}>
                    <MapPin size={16} color={COLORS.green} style={{ marginTop: 1, flexShrink: 0 }} />
                    <View style={{ flex: 1 }}>
                      <Text style={s.addressCardText} numberOfLines={2}>{address}</Text>
                      {municipio ? <Text style={s.addressCardSub}>{municipio}</Text> : null}
                    </View>
                    <Text style={s.addressCardEdit}>{t('guidedRequestScreen.step3.changeBtn')}</Text>
                  </Pressable>
                ) : showManualAddress ? (
                  <>
                    <TextInput
                      style={s.input}
                      value={address}
                      onChangeText={setAddress}
                      placeholder={t('guidedRequestScreen.step3.streetPlaceholder')}
                      placeholderTextColor={COLORS.muted}
                    />
                    <TextInput
                      style={[s.input, { marginTop: 8 }]}
                      value={municipio}
                      onChangeText={setMunicipio}
                      placeholder={t('guidedRequestScreen.step3.municipioPlaceholder')}
                      placeholderTextColor={COLORS.muted}
                    />
                    <Pressable onPress={() => setMapPickerOpen(true)} style={s.useMapBtn}>
                      <Text style={s.useMapBtnText}>{t('guidedRequestScreen.step3.useMapBtn')}</Text>
                    </Pressable>
                  </>
                ) : (
                  <>
                    <Pressable style={s.mapPickerBtn} onPress={() => setMapPickerOpen(true)}>
                      <MapPin size={18} color={COLORS.green} />
                      <Text style={s.mapPickerBtnText}>{t('guidedRequestScreen.step3.selectOnMapBtn')}</Text>
                    </Pressable>
                    <Pressable onPress={() => setShowManualAddress(true)} style={s.manualFallback}>
                      <Text style={s.manualFallbackText}>{t('guidedRequestScreen.step3.manualAddressBtn')}</Text>
                    </Pressable>
                  </>
                )}

                {/* ¿Espacio techado? */}
                <Text style={s.fieldLabel}>{t('guidedRequestScreen.step3.coveredLabel')}</Text>
                <View style={s.chipWrap}>
                  {COVERED_OPTIONS.map(o => (
                    <Chip key={o.key} label={t(`guidedRequestScreen.step3.coveredOptions.${o.key}`)} active={venueCovered === o.key} onPress={() => setVenueCovered(o.key)} />
                  ))}
                </View>

                {/* Tamaño del lugar */}
                <Text style={s.fieldLabel}>{t('guidedRequestScreen.step3.venueSizeLabel')}</Text>
                <View style={s.venueGrid}>
                  {VENUE_SIZES.map(vs => (
                    <Pressable
                      key={vs.key}
                      style={[s.venueCard, venueSize === vs.key && s.venueCardActive]}
                      onPress={() => setVenueSize(vs.key)}
                    >
                      <Text style={s.venueEmoji}>{vs.emoji}</Text>
                      <Text style={[s.venueLabel, venueSize === vs.key && s.venueLabelActive]} numberOfLines={2}>
                        {t(`guidedRequestScreen.step3.venueSizes.${vs.key}`)}
                      </Text>
                    </Pressable>
                  ))}
                </View>

                {/* Sonido */}
                <Text style={s.fieldLabel}>{t('guidedRequestScreen.step3.soundLabel')}</Text>
                <View style={s.chipWrap}>
                  {SOUND_OPTIONS.map(o => (
                    <Chip key={o.key} label={t(`guidedRequestScreen.step3.soundOptions.${o.key}`)} active={needsSound === o.key} onPress={() => setNeedsSound(o.key)} />
                  ))}
                </View>

                {/* Comentarios */}
                <Text style={s.fieldLabel}>{t('guidedRequestScreen.step3.commentsLabel')}</Text>
                <TextInput
                  style={[s.input, s.textArea]}
                  value={comments}
                  onChangeText={v => {
                    let c = v.replace(/[0-9]/g, '');
                    const NUM_WORDS = /\b(cero|uno|dos|tres|cuatro|cinco|seis|siete|ocho|nueve)([\s\-./]+(cero|uno|dos|tres|cuatro|cinco|seis|siete|ocho|nueve)){2,}/gi;
                    c = c.replace(NUM_WORDS, '');
                    const result = analyzeMessage(c);
                    setCommentsWarn(result.blocked);
                    setComments(c);
                  }}
                  placeholder={t('guidedRequestScreen.step3.commentsPlaceholder')}
                  placeholderTextColor={COLORS.muted}
                  multiline
                  numberOfLines={3}
                  maxLength={500}
                  textAlignVertical="top"
                />
                {commentsWarn && (
                  <View style={s.warnBox}>
                    <Text style={s.warnText}>⚠️ {PHONE_WARNING}</Text>
                  </View>
                )}

                {/* Resumen rápido */}
                <View style={s.summaryCard}>
                  <Text style={s.summaryTitle}>{t('guidedRequestScreen.step3.summaryTitle')}</Text>
                  <Text style={s.summaryLine}>
                    {EVENT_TYPES.find(e => e.key === eventType)?.emoji ?? '🎵'}{' '}
                    {eventType ? t(`guidedRequestScreen.step1.eventTypes.${eventType}`) : eventType}
                    {'  ·  '}
                    {MUSIC_GENRES.find(g => g.key === genre)?.emoji ?? '🎵'} {genre}
                  </Text>
                  <Text style={s.summaryLine}>
                    📍 {city}{estado ? `, ${estado}` : ''}
                    {'  ·  '}
                    👥 {t('guidedRequestScreen.step3.summaryGuests', { count: guestCount })}
                  </Text>
                  <Text style={s.summaryLine}>
                    📅 {eventDate}  ⏰ {eventTime}  ⏱ {hours}h
                  </Text>
                </View>

                {/* Botón enviar */}
                <Pressable
                  style={[s.submitBtn, (!step3Valid || loading) && s.submitBtnDisabled]}
                  onPress={handleSubmit}
                  disabled={!step3Valid || loading}
                >
                  {loading
                    ? <ActivityIndicator color={COLORS.bg} />
                    : <>
                        <Zap size={18} color={COLORS.bg} />
                        <Text style={s.submitBtnText}>{t('guidedRequestScreen.step3.submitBtn')}</Text>
                      </>
                  }
                </Pressable>

                <Text style={s.submitHint}>
                  {t('guidedRequestScreen.step3.submitHint')}
                </Text>
              </>
            )}

            <View style={{ height: 40 }} />
          </ScrollView>
        </Animated.View>
      </SafeAreaView>

      <TimePickerModal
        visible={showTimePicker}
        value={eventTime}
        onConfirm={(t) => { setEventTime(t); setShowTimePicker(false); }}
        onClose={() => setShowTimePicker(false)}
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
  container: { flex: 1, backgroundColor: COLORS.bg },

  header: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between',
    paddingHorizontal: SPACING.xl, paddingVertical: 12,
  },
  backBtn: {
    width: 40, height: 40, borderRadius: 12,
    backgroundColor: COLORS.card, borderWidth: 1, borderColor: COLORS.border,
    alignItems: 'center', justifyContent: 'center',
  },
  headerTitle: { fontFamily: FONTS.title, fontSize: 18, color: COLORS.text },

  content: { paddingHorizontal: SPACING.xl, paddingTop: 8 },

  // Step indicator
  stepHeader: { alignItems: 'center', marginBottom: 28 },
  progressBarTrack: { width: '100%', height: 4, backgroundColor: COLORS.border, borderRadius: 2, marginBottom: 8 },
  progressBarFill: { height: 4, backgroundColor: COLORS.green, borderRadius: 2 },
  stepCounter: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, marginBottom: 8 },
  stepLabel: { fontFamily: FONTS.title, fontSize: 22, color: COLORS.text, textAlign: 'center' },

  // Event type grid
  eventTypeGrid: { flexDirection: 'row', flexWrap: 'wrap', gap: 12 },
  eventTypeCard: {
    width: '47%', backgroundColor: COLORS.card,
    borderRadius: RADIUS.xl, borderWidth: 1, borderColor: COLORS.border,
    padding: 20, alignItems: 'center', gap: 10,
  },
  eventTypeCardActive: { borderColor: COLORS.green, backgroundColor: 'rgba(0,230,118,0.08)' },
  eventTypeEmoji:      { fontSize: 36 },
  eventTypeLabel:      { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.muted2, textAlign: 'center' },
  eventTypeLabelActive:{ color: COLORS.green },

  // Fields
  fieldLabel: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.muted2, marginBottom: 10, marginTop: 18 },
  input: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: COLORS.border,
    paddingHorizontal: 14, paddingVertical: 12,
    fontFamily: FONTS.body, fontSize: 14, color: COLORS.text,
  },
  textArea: { height: 80, paddingTop: 12 },
  row: { flexDirection: 'row', gap: 10 },

  // Chips
  chipWrap: { flexDirection: 'row', flexWrap: 'wrap', gap: 8 },
  chip: {
    flexDirection: 'row', alignItems: 'center', gap: 5,
    backgroundColor: COLORS.card, borderRadius: RADIUS.full,
    borderWidth: 1, borderColor: COLORS.border,
    paddingHorizontal: 12, paddingVertical: 8,
  },
  chipActive:    { backgroundColor: 'rgba(0,230,118,0.12)', borderColor: COLORS.green },
  chipEmoji:     { fontSize: 14 },
  chipText:      { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted2 },
  chipTextActive:{ color: COLORS.green },

  // Venue grid
  venueGrid: { flexDirection: 'row', flexWrap: 'wrap', gap: 10 },
  venueCard: {
    width: '47%', backgroundColor: COLORS.card,
    borderRadius: RADIUS.lg, borderWidth: 1, borderColor: COLORS.border,
    padding: 14, alignItems: 'center', gap: 6,
  },
  venueCardActive:  { borderColor: COLORS.green, backgroundColor: 'rgba(0,230,118,0.08)' },
  venueEmoji:       { fontSize: 26 },
  venueLabel:       { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.muted2, textAlign: 'center' },
  venueLabelActive: { color: COLORS.green },

  // Summary
  summaryCard: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.xl,
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.3)',
    padding: SPACING.lg, marginTop: 20, gap: 6,
  },
  summaryTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.green, marginBottom: 4 },
  summaryLine:  { fontFamily: FONTS.body, fontSize: 13, color: COLORS.text, lineHeight: 20 },

  // Navigation
  nextBtn: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 8,
    backgroundColor: COLORS.green, borderRadius: RADIUS.lg, paddingVertical: 14, marginTop: 24,
  },
  nextBtnDisabled: { opacity: 0.4 },
  nextBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.bg },

  // Submit
  submitBtn: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 10,
    backgroundColor: COLORS.green, borderRadius: RADIUS.lg, paddingVertical: 16, marginTop: 24,
  },
  submitBtnDisabled: { opacity: 0.4 },
  submitBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 16, color: COLORS.bg },
  submitHint: {
    fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted,
    textAlign: 'center', marginTop: 12, lineHeight: 18,
  },

  // GPS location card
  locationLoadingRow: { flexDirection: 'row', alignItems: 'center', gap: 10, paddingVertical: 12 },
  locationLoadingText: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted },
  locationCard: {
    flexDirection: 'row', alignItems: 'center',
    backgroundColor: 'rgba(0,230,118,0.08)', borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.35)',
    paddingHorizontal: 14, paddingVertical: 12,
  },
  locationCardCity: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.text },
  locationCardEstado: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted, marginTop: 2 },
  locationEditBtn: { paddingHorizontal: 10, paddingVertical: 6 },
  locationEditBtnText: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.green },

  // Time chip
  timeChip: { alignSelf: 'flex-start', paddingHorizontal: 18, paddingVertical: 10 },

  // Map address picker
  mapPickerBtn: {
    flexDirection: 'row', alignItems: 'center', gap: 10,
    backgroundColor: 'rgba(0,230,118,0.08)',
    borderRadius: RADIUS.md, borderWidth: 1, borderColor: COLORS.green,
    paddingVertical: 14, paddingHorizontal: 14, marginBottom: 8,
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

  warnBox:  { backgroundColor: 'rgba(239,83,80,0.10)', borderRadius: 8, padding: 10, marginTop: 6, borderWidth: 1, borderColor: 'rgba(239,83,80,0.3)' },
  warnText: { fontFamily: FONTS.body, fontSize: 12, color: '#EF5350', lineHeight: 17 },
});
