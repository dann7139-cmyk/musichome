import {
  ArrowLeft,
  CheckCircle,
  Clock,
  CreditCard,
  MapPin,
  Navigation,
  ShieldCheck,
  TrendingUp,
  Zap,
} from 'lucide-react-native';
import React, { useEffect, useRef, useState } from 'react';
import {
  ActivityIndicator,
  Alert,
  Linking,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import { Calendar } from 'react-native-calendars';
import { SafeAreaView } from 'react-native-safe-area-context';
import Button from '../../components/ui/Button';
import Input from '../../components/ui/Input';
import Particles from '../../components/ui/Particles';
import PolicyModal, { hasPoliciesAccepted } from '../../components/ui/PolicyModal';
import TimePickerModal from '../../components/ui/TimePickerModal';
import { supabase } from '../../config/supabase';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';
import {
  AnticipationAdj,
  BREAK_SURCHARGE_FIXED,
  SERVICE_FEE_RATE,
  calcDaysUntilEvent,
  calcMsiFee,
  calcMonthlyMsi,
  calcServiceFee,
  getAnticipationAdj,
} from '../../utils/calculations';
import { analyzeMessage } from '../../utils/phoneFilter';
import { checkGroupLogistics, currencyForCountry } from '../../utils/logistics';
import { buildGroupCalendarMarks } from '../../utils/groupCalendarAvailability';
import { useAuth } from '../../context/AuthContext';
import { useTranslation } from 'react-i18next';

// ─── Constantes ───────────────────────────────────────────────────────────────

const BREAK_OPTIONS = [
  { type: 'A', label: '15 min cada hora', desc: 'Descanso cada hora de servicio' },
  { type: 'B', label: '15 min único', desc: 'Un descanso a la mitad del evento' },
  { type: 'D', label: 'Sin descanso', desc: 'Solo para eventos de 3 horas exactas' },
];

const MSI_OPTIONS = [
  { months: 1, label: '1 pago',  key: '1_pago'  },
  { months: 3, label: '3 MSI',   key: '3_msi'   },
  { months: 6, label: '6 MSI',   key: '6_msi'   },
  { months: 9, label: '9 MSI',   key: '9_msi'   },
  { months: 12, label: '12 MSI', key: '12_msi'  },
];

// ─── Pantalla ─────────────────────────────────────────────────────────────────

export default function BookingScreen({ route, navigation }: any) {
  const { t } = useTranslation();
  const { group, package: pkg } = route.params;
  const { safeState } = useAuth();

  // Disponibilidad
  const [markedDates, setMarkedDates] = useState<any>({});
  const [selectedDate, setSelectedDate] = useState('');
  const [loadingDates, setLoadingDates] = useState(true);

  // Formulario
  const [eventTime, setEventTime] = useState('');
  const [showTimePicker, setShowTimePicker] = useState(false);
  const [address, setAddress] = useState('');
  const [addressConfirmed, setAddressConfirmed] = useState(false);
  const [eventCountry, setEventCountry] = useState<'MX' | 'US'>('MX');
  const [eventCity, setEventCity] = useState('');
  const [notes, setNotes] = useState('');
  const [notesError, setNotesError] = useState('');
  const [breakType, setBreakType] = useState('A');

  // Pricing
  const [adjustedPrice, setAdjustedPrice] = useState(pkg.price);
  const [loading, setLoading] = useState(false);
  const [demandMultiplier, setDemandMultiplier] = useState<number>(1.0);
  const authorizedPriceRef = useRef<{ base: number; commission: number; final: number; rate: number; multiplier: number } | null>(null);

  // Anticipación y demanda
  const [anticipationAdj, setAnticipationAdj] = useState<AnticipationAdj | null>(null);
  const [cityDemand, setCityDemand] = useState<{
    demand_level: 'low' | 'medium' | 'high';
    active_requests: number;
    available_groups: number;
    message: string;
  } | null>(null);

  // Express (priority response — sin costo extra)
  const [expressMode, setExpressMode] = useState(false);

  // MSI — preferencia del cliente (se guarda en la reserva)
  const [selectedMSI, setSelectedMSI] = useState<(typeof MSI_OPTIONS)[0]>(MSI_OPTIONS[0]);

  // Políticas
  const [showPolicyModal, setShowPolicyModal] = useState(false);
  const [policiesReady, setPoliciesReady] = useState(false);

  useEffect(() => {
    fetchUnavailableDates();
    fetchCityDemand();
    checkPolicies();
  }, []);

  useEffect(() => { recalcPrice(); }, [breakType, selectedDate]);

  const checkPolicies = async () => {
    const accepted = await hasPoliciesAccepted();
    setPoliciesReady(accepted);
  };

  const fetchCityDemand = async () => {
    const city = group?.city ?? group?.location ?? null;
    const { data } = await supabase.rpc('get_city_demand', { p_city: city });
    if (data) setCityDemand(data as any);
  };

  const recalcPrice = () => {
    const breakSurcharge = BREAK_SURCHARGE_FIXED[breakType] ?? 0;
    const adj = selectedDate ? getAnticipationAdj(calcDaysUntilEvent(selectedDate), pkg.price) : null;
    setAnticipationAdj(adj ?? null);
    const anticipationDelta = adj ? (adj.type === 'discount' ? -adj.amount : adj.amount) : 0;
    setAdjustedPrice(pkg.price + breakSurcharge + anticipationDelta);
  };

  const serviceFee  = calcServiceFee(adjustedPrice);
  const clientPrice = adjustedPrice;
  const msiFeeAmount  = calcMsiFee(clientPrice, selectedMSI.months);
  const clientTotal   = clientPrice + msiFeeAmount;             // lo que cobra Stripe
  const monthlyAmount = calcMonthlyMsi(clientPrice, selectedMSI.months);

  const fetchUnavailableDates = async () => {
    setLoadingDates(true);
    // Días ocupados vía RPC (la RLS de reservations bloquea —correctamente—
    // la lectura directa de reservas ajenas; el RPC devuelve solo fecha/hora)
    const today = new Date();
    const inOneYear = new Date(today);
    inOneYear.setFullYear(inOneYear.getFullYear() + 1);
    const toDateStr = (d: Date) =>
      `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
    const { data: reservations } = await supabase.rpc('get_group_busy_days', {
      p_group_id: group.id,
      p_from: toDateStr(today),
      p_to: toDateStr(inOneYear),
    });

    const { data: blocked } = await supabase
      .from('group_unavailability')
      .select('date')
      .eq('group_id', group.id);

    // Fase A (máximo 2 eventos/día): un día con reserva existente NO se
    // deshabilita — el grupo puede tener hasta 2 eventos el mismo día sin
    // traslape real. Solo el bloqueo manual (group_unavailability)
    // deshabilita el día; la disponibilidad real la decide el backend al
    // confirmar (create_booking_with_event).
    const marked = buildGroupCalendarMarks(
      reservations,
      blocked,
      { backgroundColor: 'rgba(255,179,0,0.18)', textColor: COLORS.gold },
      { backgroundColor: COLORS.card2, textColor: COLORS.muted },
    );
    setMarkedDates(marked);
    setLoadingDates(false);
  };

  const handleDateSelect = (day: any) => {
    const dateStr = day.dateString;
    if (markedDates[dateStr]?.disabled) {
      Alert.alert(t('booking.error_date_unavailable'), t('booking.error_date_past'));
      return;
    }
    const yesterday = new Date();
    yesterday.setDate(yesterday.getDate() - 1);
    const yesterdayStr = `${yesterday.getFullYear()}-${String(yesterday.getMonth()+1).padStart(2,'0')}-${String(yesterday.getDate()).padStart(2,'0')}`;
    if (dateStr <= yesterdayStr) {
      Alert.alert(t('common.error'), t('booking.error_date_past'));
      return;
    }
    setSelectedDate(dateStr);
    const newMarked = { ...markedDates };
    Object.keys(newMarked).forEach(key => {
      if (newMarked[key].selected && !newMarked[key].disabled) delete newMarked[key];
    });
    newMarked[dateStr] = {
      selected: true, selectedColor: COLORS.green, selectedTextColor: '#fff',
    };
    setMarkedDates(newMarked);
  };

  const openAddressInMaps = () => {
    if (!address.trim()) { Alert.alert(t('common.error'), t('booking.error_address')); return; }
    Linking.openURL(`https://www.google.com/maps/search/?api=1&query=${encodeURIComponent(address)}`);
  };

  const confirmAddress = () => {
    if (!address.trim()) { Alert.alert(t('common.error'), t('booking.error_address')); return; }
    Alert.alert(
      t('booking.address_confirm'),
      `¿La dirección del evento es correcta?\n\n"${address}"`,
      [
        { text: 'Corregir', style: 'cancel' },
        { text: 'Sí, es correcta', onPress: () => setAddressConfirmed(true) },
      ]
    );
  };

  const formatTime12h = (time: string) => {
    const [hStr, mStr] = time.split(':');
    const h = parseInt(hStr);
    const mer = h >= 12 ? 'PM' : 'AM';
    return `${h % 12 || 12}:${mStr} ${mer}`;
  };

  const validateNotes = (text: string): boolean => {
    const result = analyzeMessage(text);
    if (result.blocked) {
      setNotesError(
        'Por seguridad, no compartas datos de contacto aquí. El chat interno se habilita después de contratar.'
      );
      return false;
    }
    setNotesError('');
    return true;
  };

  const handleNotesChange = (text: string) => {
    setNotes(text);
    if (text.length > 3) validateNotes(text);
    else setNotesError('');
  };

  // ── Flujo principal ────────────────────────────────────────────────────────

  const handleBooking = async () => {
    if (loading) return;

    if (!selectedDate || !address) {
      Alert.alert(t('common.error'), t('booking.error_date_and_address'));
      return;
    }
    if (!addressConfirmed) {
      Alert.alert(t('booking.address_confirm'), t('booking.error_address_confirm'));
      return;
    }
    if (pkg.duration_hours != null && pkg.duration_hours < 3) {
      Alert.alert(t('common.error'), t('booking.error_min_hours'));
      return;
    }
    if (!validateNotes(notes)) return;

    // Mostrar políticas si no se han aceptado
    if (!policiesReady) {
      setShowPolicyModal(true);
      return;
    }

    await _prepareAndConfirm();
  };

  const _prepareAndConfirm = async () => {
    // Validar precio con backend
    const { data: priceData } = await supabase.rpc('calculate_final_price', {
      p_base_price: adjustedPrice,
      p_is_express: expressMode,
      p_state:      safeState ?? undefined,
    });

    const backendOk  = priceData?.ok === true;
    const finalPrice = backendOk ? priceData.final_price       : clientPrice;
    const commission = backendOk ? priceData.commission_amount  : serviceFee;
    const rate       = backendOk ? priceData.commission_rate    : Math.round(SERVICE_FEE_RATE * 100);
    const multiplier = backendOk ? (priceData.multiplier ?? 1.0) : 1.0;

    if (backendOk) setDemandMultiplier(multiplier);

    authorizedPriceRef.current = { base: adjustedPrice, commission, final: finalPrice, rate, multiplier };

    const msiLabel = selectedMSI.months > 1
      ? `${selectedMSI.months} MSI · $${monthlyAmount.toLocaleString()} × ${selectedMSI.months} meses`
      : 'Pago único';

    Alert.alert(
      t('booking.confirm_title'),
      t('booking.confirm_body', {
        group: group.name,
        package: pkg.name,
        date: selectedDate,
        amount: finalPrice?.toLocaleString(),
        currency: currencyForCountry(eventCountry),
        payment: msiLabel,
      }),
      [
        { text: t('common.review'), style: 'cancel' },
        { text: t('common.confirm'), onPress: () => _doBooking() },
      ]
    );
  };

  const _doBooking = async () => {
    setLoading(true);
    const { data: sessionData } = await supabase.auth.getSession();
    if (!sessionData.session) {
      Alert.alert(t('common.error'), t('booking.error_login'));
      setLoading(false);
      return;
    }

    // Fase A (máximo 2 eventos/día): la disponibilidad real (bloqueo manual,
    // límite diario, traslape) la decide el RPC create_booking_with_event()
    // en el servidor — única fuente de verdad, no se duplica aquí un
    // pre-check basado en "¿existe cualquier reserva ese día?".

    // Validación logística: tiempo de traslado entre eventos del grupo
    const logistics = await checkGroupLogistics({
      groupId:       group.id,
      eventDate:     selectedDate,
      eventTime:     eventTime || undefined,
      durationHours: pkg.duration_hours ?? 3,
    });

    if (logistics.conflict) {
      Alert.alert(
        t('booking.error_conflict'),
        logistics.messageClient ?? t('booking.error_conflict_body'),
      );
      setLoading(false);
      return;
    }

    const authorized   = authorizedPriceRef.current;
    const priceToCharge = authorized?.final ?? clientPrice;
    const baseToStore   = authorized?.base  ?? adjustedPrice;

    const { data: bookingResult, error } = await supabase.rpc('create_booking_with_event', {
      p_client_id:                  sessionData.session.user.id,
      p_group_id:                   group.id,
      p_package_id:                 pkg.id,
      p_event_date:                 selectedDate,
      p_event_time:                 eventTime || null,
      p_address:                    address,
      p_total_price:                priceToCharge,
      p_notes:                      notes || null,
      p_break_type:                 breakType,
      p_base_price:                 baseToStore,
      p_payment_mode:               'full',
      p_installment_plan:           selectedMSI.months > 1 ? selectedMSI.key : null,
      p_installment_months:         selectedMSI.months > 1 ? selectedMSI.months : null,
      p_installment_monthly_amount: selectedMSI.months > 1 ? monthlyAmount : null,
    });
    // MSI ya se guarda atómicamente en el RPC — no se necesita update separado

    // Guardar ubicación y moneda en la reserva (fire-and-forget)
    if (bookingResult?.reservation_id) {
      supabase
        .from('reservations')
        .update({
          event_country: eventCountry,
          event_city:    eventCity.trim() || null,
          currency_code: currencyForCountry(eventCountry),
        })
        .eq('id', bookingResult.reservation_id)
        .then(); // Supabase v2 es lazy — sin .then() el request nunca se envía
    }

    setLoading(false);

    // Candado server-side (sql/430 + Fase A): date_blocked lo devuelve el
    // RPC de forma controlada (return temprano, antes del INSERT). Pero
    // daily_event_limit/time_overlap los lanza el TRIGGER durante el
    // INSERT dentro del propio RPC — create_booking_with_event() no tiene
    // EXCEPTION WHEN OTHERS, así que llegan como excepción real de
    // Postgres en `error.message`, NUNCA en bookingResult.error.
    if (bookingResult?.error === 'date_blocked' || bookingResult?.error === 'date_taken') {
      Alert.alert(t('booking.error_date_unavailable'), t('booking.error_date_taken'));
      await fetchUnavailableDates();
      return;
    }
    // Límite de 3 grupos por evento (sql/556): el pre-check del RPC lo
    // devuelve controlado en bookingResult.error; si una carrera lo dejó
    // pasar hasta el INSERT, el trigger lo lanza como excepción real en
    // error.message — se cubren ambos casos, igual que daily_event_limit.
    if (bookingResult?.error === 'event_group_limit_reached' || error?.message?.includes('event_group_limit_reached')) {
      Alert.alert(t('booking.error_date_unavailable'), t('booking.error_group_limit'));
      return;
    }
    if (error?.message?.includes('daily_event_limit')) {
      Alert.alert(t('booking.error_date_unavailable'), t('booking.error_daily_limit'));
      await fetchUnavailableDates();
      return;
    }
    if (error?.message?.includes('time_overlap')) {
      Alert.alert(t('booking.error_date_unavailable'), t('booking.error_time_overlap'));
      await fetchUnavailableDates();
      return;
    }

    if (error || !bookingResult?.reservation_id) {
      Alert.alert(t('common.error'), error?.message ?? t('booking.error_create'));
    } else {
      Alert.alert(
        t('booking.success_title'),
        t('booking.success_body', { group: group.name }),
        [
          { text: t('booking.see_reservations'), onPress: () => navigation.navigate('ClientReservations') },
          { text: t('booking.go_home'), onPress: () => navigation.popToTop() },
        ]
      );
    }
  };

  const hasSurcharge = (BREAK_SURCHARGE_FIXED[breakType] ?? 0) > 0;
  const surchargeAmount = adjustedPrice - pkg.price;

  return (
    <View style={styles.container}>
      <Particles />
      <SafeAreaView edges={['top']} style={{ flex: 1 }}>
        {/* HEADER */}
        <View style={styles.header}>
          <Pressable style={styles.backBtn} onPress={() => navigation.goBack()}>
            <ArrowLeft size={20} color={COLORS.text} />
          </Pressable>
          <Text style={styles.headerTitle}>{t('booking.title')}</Text>
          <View style={{ width: 40 }} />
        </View>

        <ScrollView showsVerticalScrollIndicator={false} contentContainerStyle={styles.scroll}>

          {/* RESUMEN DE PAQUETE */}
          <View style={styles.pkgSummary}>
            <View style={styles.pkgInfo}>
              <Text style={styles.pkgGroup}>{group.name}</Text>
              <Text style={styles.pkgName}>{pkg.name}</Text>
              <View style={styles.pkgMeta}>
                <Clock size={13} color={COLORS.muted2} />
                <Text style={styles.pkgMetaText}>{pkg.duration_hours}h</Text>
              </View>
            </View>
            <View style={styles.pkgPriceBlock}>
              {hasSurcharge && (
                <Text style={styles.pkgBasePrice}>${pkg.price?.toLocaleString()}</Text>
              )}
              <Text style={styles.pkgPrice}>${adjustedPrice?.toLocaleString()}</Text>
            </View>
          </View>

          {/* BANNER ALTA DEMANDA */}
          {cityDemand?.demand_level === 'high' && (
            <View style={styles.demandBanner}>
              <TrendingUp size={14} color="#F59E0B" />
              <View style={{ flex: 1 }}>
                <Text style={styles.demandBannerText}>{cityDemand.message}</Text>
                <Text style={styles.demandBannerSub}>
                  {cityDemand.active_requests} solicitudes activas · {cityDemand.available_groups} grupos disponibles
                </Text>
              </View>
            </View>
          )}

          {/* MODO URGENTE (Express — sin costo extra, solo prioridad) */}
          <View style={styles.sectionCard}>
            <View style={styles.expressRow}>
              <View style={styles.expressIconBox}>
                <Zap size={18} color="#F59E0B" />
              </View>
              <View style={{ flex: 1 }}>
                <Text style={styles.expressTitle}>Modo Urgente</Text>
                <Text style={styles.expressSub}>
                  Prioridad en respuestas · El grupo confirma en menos de 2h
                </Text>
              </View>
              <Pressable
                style={[styles.expressToggle, expressMode && styles.expressToggleOn]}
                onPress={() => setExpressMode(v => !v)}
              >
                <View style={[styles.expressThumb, expressMode && styles.expressThumbOn]} />
              </Pressable>
            </View>
            {expressMode && (
              <View style={styles.expressActiveBox}>
                <Text style={styles.expressActiveText}>
                  ⚡ Modo Urgente activado — respuesta garantizada en 2h
                </Text>
                <Text style={styles.expressActiveReason}>
                  Sin costo adicional. La atención prioritaria está incluida.
                </Text>
              </View>
            )}
          </View>

          {/* CALENDARIO */}
          <Text style={styles.sectionTitle}>{t('booking.select_date')}</Text>
          <Text style={styles.sectionHint}>
            {t('booking.calendar_legend')}
          </Text>

          {loadingDates ? (
            <View style={styles.calendarLoading}>
              <ActivityIndicator size="large" color={COLORS.green} />
              <Text style={styles.loadingText}>Cargando disponibilidad...</Text>
            </View>
          ) : (
            <View style={styles.calendarWrapper}>
              <Calendar
                onDayPress={handleDateSelect}
                markedDates={markedDates}
                minDate={(() => {
                  const d = new Date();
                  d.setDate(d.getDate() - 1);
                  return `${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,'0')}-${String(d.getDate()).padStart(2,'0')}`;
                })()}
                theme={{
                  calendarBackground: COLORS.card,
                  textSectionTitleColor: COLORS.muted,
                  selectedDayBackgroundColor: COLORS.green,
                  selectedDayTextColor: '#fff',
                  todayTextColor: COLORS.green,
                  dayTextColor: COLORS.text,
                  textDisabledColor: COLORS.muted,
                  monthTextColor: COLORS.text,
                  textMonthFontFamily: FONTS.bodySemiBold,
                  textDayFontFamily: FONTS.body,
                  textDayHeaderFontFamily: FONTS.bodyMedium,
                  textDayFontSize: 14,
                  textMonthFontSize: 16,
                  textDayHeaderFontSize: 12,
                }}
                style={styles.calendar}
                markingType="custom"
              />
            </View>
          )}

          {selectedDate && (
            <View>
              <View style={styles.selectedDateBox}>
                <Text style={styles.selectedDateLabel}>Fecha seleccionada:</Text>
                <Text style={styles.selectedDateValue}>{selectedDate}</Text>
              </View>
              {anticipationAdj && anticipationAdj.type !== 'none' && (
                <View style={[
                  styles.anticipationBox,
                  anticipationAdj.type === 'discount' ? styles.anticipationDiscount : styles.anticipationSurcharge,
                ]}>
                  <Text style={[
                    styles.anticipationLabel,
                    anticipationAdj.type === 'discount' ? styles.anticipationLabelDiscount : styles.anticipationLabelSurcharge,
                  ]}>
                    {anticipationAdj.type === 'discount' ? '🎁' : '⏰'} {anticipationAdj.label}
                  </Text>
                  <Text style={styles.anticipationReason}>{anticipationAdj.reason}</Text>
                </View>
              )}
            </View>
          )}

          {/* DETALLES DEL EVENTO */}
          <Text style={styles.sectionTitle}>{t('booking.select_time')}</Text>
          <Pressable
            style={[styles.timeChip, eventTime && styles.timeChipSelected]}
            onPress={() => setShowTimePicker(true)}
          >
            <Clock size={16} color={eventTime ? COLORS.green : COLORS.muted2} />
            <Text style={[styles.timeChipText, eventTime && styles.timeChipTextSelected]}>
              {eventTime ? formatTime12h(eventTime) : 'Toca para elegir la hora'}
            </Text>
          </Pressable>

          <Input
            label={t('booking.address_label')}
            placeholder={t('booking.address_placeholder')}
            value={address}
            onChangeText={(v: string) => { setAddress(v); setAddressConfirmed(false); }}
            multiline
            numberOfLines={2}
            icon={<MapPin size={18} color={COLORS.muted} />}
          />

          {address.trim().length > 0 && (
            <View style={styles.mapConfirmSection}>
              {addressConfirmed ? (
                <View style={styles.mapConfirmed}>
                  <CheckCircle size={16} color={COLORS.green} />
                  <View style={{ flex: 1 }}>
                    <Text style={styles.mapConfirmedText}>{t('booking.address_confirmed')}</Text>
                    <Pressable onPress={openAddressInMaps}>
                      <Text style={styles.mapConfirmedLink}>Ver en Google Maps →</Text>
                    </Pressable>
                  </View>
                </View>
              ) : (
                <Pressable style={styles.mapConfirmBtn} onPress={confirmAddress}>
                  <Navigation size={15} color={COLORS.green} />
                  <Text style={styles.mapConfirmBtnText}>{t('booking.address_confirm')}</Text>
                </Pressable>
              )}
              <Text style={styles.mapHint}>El grupo usará esta dirección para llegar a tu evento</Text>
            </View>
          )}

          {/* PAÍS DEL EVENTO + CIUDAD */}
          <View style={styles.locationSection}>
            <Text style={styles.locationLabel}>{t('booking.country_label')}</Text>
            <View style={styles.countryRow}>
              <Pressable
                style={[styles.countryBtn, eventCountry === 'MX' && styles.countryBtnActive]}
                onPress={() => setEventCountry('MX')}
              >
                <Text style={[styles.countryBtnText, eventCountry === 'MX' && styles.countryBtnTextActive]}>
                  {t('booking.country_mx')}
                </Text>
              </Pressable>
              <Pressable
                style={[styles.countryBtn, eventCountry === 'US' && styles.countryBtnActive]}
                onPress={() => setEventCountry('US')}
              >
                <Text style={[styles.countryBtnText, eventCountry === 'US' && styles.countryBtnTextActive]}>
                  {t('booking.country_us')}
                </Text>
              </Pressable>
            </View>
            <Input
              label={t('booking.city_label')}
              placeholder={eventCountry === 'US' ? t('booking.city_placeholder_us') : t('booking.city_placeholder_mx')}
              value={eventCity}
              onChangeText={setEventCity}
            />
            {eventCountry === 'US' && (
              <View style={styles.usdNotice}>
                <Text style={styles.usdNoticeText}>{t('booking.usd_notice')}</Text>
              </View>
            )}
          </View>

          {/* NOTAS (con validación de datos de contacto) */}
          <View>
            <Input
              label={t('booking.notes_label')}
              placeholder={t('booking.notes_placeholder')}
              value={notes}
              onChangeText={handleNotesChange}
              multiline
              numberOfLines={3}
            />
            {notesError ? (
              <View style={styles.notesError}>
                <Text style={styles.notesErrorText}>{notesError}</Text>
              </View>
            ) : (
              <Text style={styles.notesHint}>
                ⚠️ No incluyas teléfonos, emails, @usuarios ni links. El chat se habilita al contratar.
              </Text>
            )}
          </View>

          {/* TIPO DE DESCANSO — oculto: el grupo elige en EventTimerScreen */}
          {false && (<>
          <Text style={styles.sectionTitle}>Tipo de descanso</Text>
          <Text style={styles.sectionHint}>
            Todos los tipos de descanso están incluidos sin costo adicional.
          </Text>
          <View style={styles.breakGrid}>
            {BREAK_OPTIONS.map((opt) => {
              const isActive = breakType === opt.type;
              return (
                <Pressable
                  key={opt.type}
                  style={[styles.breakOption, isActive && styles.breakOptionActive]}
                  onPress={() => setBreakType(opt.type)}
                >
                  <View style={styles.breakHeader}>
                    <Text style={[styles.breakLabel, isActive && styles.breakLabelActive]}>
                      {opt.label}
                    </Text>
                    {opt.extraLabel && (
                      <View style={styles.paidBadge}>
                        <Text style={styles.paidBadgeText}>{opt.extraLabel}</Text>
                      </View>
                    )}
                  </View>
                  <Text style={styles.breakDesc}>{opt.desc}</Text>
                </Pressable>
              );
            })}
          </View>
          </>)}

          {/* ── RESUMEN DE PAGO ─────────────────────────────────────────────── */}
          <View style={styles.priceSummary}>
            <Text style={styles.priceSummaryTitle}>💳 RESUMEN DE PAGO</Text>

            {/* Ajuste anticipación */}
            {anticipationAdj && anticipationAdj.type === 'discount' && (
              <View style={styles.priceRow}>
                <Text style={styles.priceRowLabel}>{anticipationAdj.label}</Text>
                <Text style={styles.priceRowDiscount}>-${anticipationAdj.amount.toLocaleString()}</Text>
              </View>
            )}
            {anticipationAdj && anticipationAdj.type === 'surcharge' && (
              <View style={styles.priceRow}>
                <Text style={styles.priceRowLabel}>{anticipationAdj.label}</Text>
                <Text style={styles.priceRowExtra}>+${anticipationAdj.amount.toLocaleString()}</Text>
              </View>
            )}

            {/* Recargo break */}
            {hasSurcharge && (
              <View style={styles.priceRow}>
                <Text style={styles.priceRowLabel}>
                  {breakType === 'B' ? 'Descanso 15 min único' : 'Sin descanso'}
                </Text>
                <Text style={styles.priceRowExtra}>+${surchargeAmount.toLocaleString()}</Text>
              </View>
            )}

            {/* Demanda dinámica */}
            {demandMultiplier !== 1.0 && (
              <View style={styles.priceRow}>
                <Text style={styles.priceRowLabel}>
                  {demandMultiplier > 1.0
                    ? `📈 Alta demanda (${Math.round((demandMultiplier - 1) * 100)}%)`
                    : `📉 Descuento zona nueva (${Math.round((1 - demandMultiplier) * 100)}%)`}
                </Text>
                <Text style={demandMultiplier > 1.0 ? styles.priceRowExtra : styles.priceRowDiscount}>
                  {demandMultiplier > 1.0 ? '+' : '-'}${Math.abs(Math.round(adjustedPrice * (demandMultiplier - 1))).toLocaleString()}
                </Text>
              </View>
            )}

            {/* Cargo MSI (solo si aplica) */}
            {msiFeeAmount > 0 && (
              <View style={styles.priceRow}>
                <View>
                  <Text style={styles.priceRowLabel}>{selectedMSI.months} MSI</Text>
                  <Text style={styles.priceRowSubLabel}>Cargo financiero incluido</Text>
                </View>
                <Text style={styles.priceRowExtra}>+${msiFeeAmount.toLocaleString()}</Text>
              </View>
            )}

            {/* Total */}
            <View style={styles.totalRow}>
              <Text style={styles.totalLabel}>{t('booking.total').toUpperCase()}</Text>
              <Text style={styles.totalValue}>${clientTotal.toLocaleString()}</Text>
            </View>
          </View>

          {/* ── PAGO EN MENSUALIDADES ──────────────────────────────────── */}
          <View style={styles.msiCard}>
            <View style={styles.msiHeader}>
              <CreditCard size={18} color={COLORS.blue} />
              <Text style={styles.msiTitle}>Paga en mensualidades</Text>
            </View>

            <Text style={styles.msiSub}>
              Elige cómo pagar con tu tarjeta de crédito participante.
            </Text>

            <View style={styles.msiOptions}>
              {MSI_OPTIONS.map((opt) => {
                const isActive = selectedMSI.key === opt.key;
                const monthly  = calcMonthlyMsi(clientPrice, opt.months);
                return (
                  <Pressable
                    key={opt.key}
                    style={[styles.msiOption, isActive && styles.msiOptionActive]}
                    onPress={() => setSelectedMSI(opt)}
                  >
                    <View style={styles.msiOptionCheck}>
                      {isActive && <CheckCircle size={15} color={COLORS.green} />}
                    </View>
                    <View style={{ flex: 1 }}>
                      <Text style={[styles.msiOptionLabel, isActive && styles.msiOptionLabelActive]}>
                        {opt.months > 1 ? `${opt.label} – $${monthly.toLocaleString()}/mes` : opt.label}
                      </Text>
                      {opt.months > 1 ? (
                        <Text style={styles.msiOptionAmount}>Cargo financiero incluido</Text>
                      ) : (
                        <Text style={styles.msiOptionAmount}>${clientPrice.toLocaleString()} total</Text>
                      )}
                    </View>
                    {opt.months > 1 && (
                      <View style={styles.msiBadge}>
                        <Text style={styles.msiBadgeText}>MSI</Text>
                      </View>
                    )}
                  </Pressable>
                );
              })}
            </View>

            <Text style={styles.msiDisclaimer}>
              ℹ️ Solo tarjetas de crédito participantes. Si tu tarjeta no aplica MSI, se hará un solo cobro de ${clientTotal.toLocaleString()}.
            </Text>

            {/* Hero del plan seleccionado */}
            <View style={styles.msiHero}>
              <Text style={styles.msiHeroLabel}>
                {selectedMSI.months > 1 ? `${selectedMSI.months} pagos de` : 'Total'}
              </Text>
              <Text style={styles.msiHeroAmount}>
                ${monthlyAmount.toLocaleString()}
              </Text>
              <Text style={styles.msiHeroInterests}>
                {selectedMSI.months > 1 ? 'Cargo financiero incluido' : 'Sin cargo adicional'}
              </Text>
            </View>
          </View>

          {/* PAGO PROTEGIDO */}
          <View style={styles.paymentProtection}>
            <ShieldCheck size={15} color={COLORS.green} />
            <Text style={styles.paymentProtectionText}>
              El pago se libera solo cuando el evento termina correctamente. Las horas extra se descuentan de tu saldo.
            </Text>
          </View>

          {/* POLÍTICA DE CANCELACIÓN */}
          <View style={styles.policyCard}>
            <Text style={styles.policyTitle}>Política de cancelación</Text>
            <View style={styles.policyRow}>
              <View style={styles.policyDot} />
              <View style={{ flex: 1 }}>
                <Text style={styles.policyRowTitle}>Más de 24 horas antes</Text>
                <Text style={styles.policyRowDesc}>Puedes reprogramar sin costo</Text>
              </View>
            </View>
            <View style={styles.policyDivider} />
            <View style={styles.policyRow}>
              <View style={[styles.policyDot, styles.policyDotRed]} />
              <View style={{ flex: 1 }}>
                <Text style={styles.policyRowTitle}>Menos de 24 horas antes</Text>
                <Text style={styles.policyRowDesc}>Sin reembolso · el pago no se devuelve</Text>
              </View>
            </View>
          </View>

          {/* BOTÓN PRINCIPAL */}
          <View style={{ marginTop: 8, marginBottom: 32 }}>
            <Button
              label={
                selectedMSI.months > 1
                  ? t('booking.btn_pay_msi', { months: selectedMSI.months, amount: monthlyAmount.toLocaleString(), currency: currencyForCountry(eventCountry) })
                  : t('booking.btn_pay', { amount: clientTotal.toLocaleString(), currency: currencyForCountry(eventCountry) })
              }
              onPress={handleBooking}
              loading={loading}
              size="lg"
            />
            <Text style={styles.payBtnNote}>🔒 Pago seguro y protegido</Text>
          </View>

        </ScrollView>
      </SafeAreaView>

      <TimePickerModal
        visible={showTimePicker}
        value={eventTime}
        title="Hora del evento"
        onConfirm={(t) => { setEventTime(t); setShowTimePicker(false); }}
        onClose={() => setShowTimePicker(false)}
      />

      {/* MODAL DE POLÍTICAS */}
      <PolicyModal
        visible={showPolicyModal}
        onAccept={() => {
          setShowPolicyModal(false);
          setPoliciesReady(true);
          _prepareAndConfirm();
        }}
        onClose={() => setShowPolicyModal(false)}
      />
    </View>
  );
}

// ─── Estilos ──────────────────────────────────────────────────────────────────

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: COLORS.bg },
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
  scroll: { padding: SPACING.xl },

  // Package summary
  pkgSummary: {
    flexDirection: 'row', justifyContent: 'space-between', alignItems: 'flex-start',
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border,
    padding: SPACING.lg, marginBottom: 20,
  },
  pkgInfo: { flex: 1 },
  pkgGroup: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2, marginBottom: 4 },
  pkgName: { fontFamily: FONTS.bodySemiBold, fontSize: 18, color: COLORS.text, marginBottom: 6 },
  pkgMeta: { flexDirection: 'row', alignItems: 'center', gap: 5 },
  pkgMetaText: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2 },
  pkgPriceBlock: { alignItems: 'flex-end' },
  pkgBasePrice: {
    fontFamily: FONTS.body, fontSize: 14, color: COLORS.muted,
    textDecorationLine: 'line-through', marginBottom: 2,
  },
  pkgPrice: { fontFamily: FONTS.title, fontSize: 26, color: COLORS.green },

  // Demand banner
  demandBanner: {
    flexDirection: 'row', alignItems: 'flex-start', gap: 10,
    backgroundColor: 'rgba(245,158,11,0.10)', borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: 'rgba(245,158,11,0.35)',
    paddingHorizontal: 14, paddingVertical: 12, marginBottom: 14,
  },
  demandBannerText: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: '#F59E0B' },
  demandBannerSub:  { fontFamily: FONTS.body, fontSize: 11, color: '#F59E0B', opacity: 0.8, marginTop: 2 },

  // Express mode
  sectionCard: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border, padding: 14, marginBottom: 20,
  },
  expressRow:    { flexDirection: 'row', alignItems: 'center', gap: 12 },
  expressIconBox: {
    width: 38, height: 38, borderRadius: RADIUS.md,
    backgroundColor: 'rgba(245,158,11,0.12)',
    alignItems: 'center', justifyContent: 'center',
  },
  expressTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.text },
  expressSub:   { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted2, marginTop: 2 },
  expressToggle: {
    width: 46, height: 26, borderRadius: 13,
    backgroundColor: COLORS.border, padding: 2, justifyContent: 'center',
  },
  expressToggleOn: { backgroundColor: '#F59E0B' },
  expressThumb: { width: 22, height: 22, borderRadius: 11, backgroundColor: COLORS.muted2 },
  expressThumbOn: { backgroundColor: '#fff', alignSelf: 'flex-end' },
  expressActiveBox: {
    marginTop: 12, backgroundColor: 'rgba(245,158,11,0.08)',
    borderRadius: RADIUS.md, borderWidth: 1, borderColor: 'rgba(245,158,11,0.25)', padding: 10,
  },
  expressActiveText:   { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: '#F59E0B' },
  expressActiveReason: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted2, marginTop: 3 },

  sectionTitle: { fontFamily: FONTS.title, fontSize: 16, color: COLORS.text, marginBottom: 8, marginTop: 8 },
  sectionHint:  { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted, marginBottom: 14 },

  // Calendar
  calendarLoading: { alignItems: 'center', paddingVertical: 60 },
  loadingText: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2, marginTop: 12 },
  calendarWrapper: {
    borderRadius: RADIUS.lg, overflow: 'hidden',
    borderWidth: 1, borderColor: COLORS.border, marginBottom: 16,
  },
  calendar: { backgroundColor: COLORS.card, paddingBottom: 10 },
  selectedDateBox: {
    backgroundColor: COLORS.greenMuted, borderWidth: 1, borderColor: COLORS.green,
    borderRadius: RADIUS.md, padding: 12, marginBottom: 16,
    flexDirection: 'row', alignItems: 'center', gap: 8,
  },
  selectedDateLabel: { fontFamily: FONTS.bodyMedium, fontSize: 14, color: COLORS.green },
  selectedDateValue: { fontFamily: FONTS.bodySemiBold, fontSize: 16, color: COLORS.green },

  // Anticipation
  anticipationBox: { borderRadius: RADIUS.md, borderWidth: 1, paddingHorizontal: 12, paddingVertical: 10, marginBottom: 16 },
  anticipationDiscount:  { backgroundColor: 'rgba(0,230,118,0.08)', borderColor: 'rgba(0,230,118,0.30)' },
  anticipationSurcharge: { backgroundColor: 'rgba(239,68,68,0.08)', borderColor: 'rgba(239,68,68,0.30)' },
  anticipationLabel:          { fontFamily: FONTS.bodySemiBold, fontSize: 13, marginBottom: 3 },
  anticipationLabelDiscount:  { color: COLORS.green },
  anticipationLabelSurcharge: { color: '#EF4444' },
  anticipationReason: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted2 },

  // Time chip
  timeChip: {
    flexDirection: 'row', alignItems: 'center', gap: 10,
    backgroundColor: COLORS.card, borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: COLORS.border,
    paddingHorizontal: 16, paddingVertical: 15, marginBottom: 16,
  },
  timeChipSelected: { borderColor: COLORS.green, backgroundColor: COLORS.greenMuted },
  timeChipText: { fontFamily: FONTS.body, fontSize: 15, color: COLORS.muted2, flex: 1 },
  timeChipTextSelected: { fontFamily: FONTS.bodySemiBold, color: COLORS.green },

  // Map confirmation
  mapConfirmSection: { marginBottom: 8, marginTop: -4 },
  mapConfirmBtn: {
    flexDirection: 'row', alignItems: 'center', gap: 8,
    backgroundColor: COLORS.greenMuted, borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: COLORS.green, paddingVertical: 11, paddingHorizontal: 14,
  },
  mapConfirmBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.green, flex: 1 },
  mapConfirmed: {
    flexDirection: 'row', alignItems: 'center', gap: 8,
    backgroundColor: 'rgba(0,230,118,0.08)', borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: COLORS.green, paddingVertical: 11, paddingHorizontal: 14,
  },
  mapConfirmedText: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.green },
  mapConfirmedLink: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.green, opacity: 0.7, marginTop: 2 },
  mapHint: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted, marginTop: 6, marginLeft: 4 },

  // Notes
  notesError: {
    backgroundColor: 'rgba(239,68,68,0.08)', borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: 'rgba(239,68,68,0.35)',
    paddingHorizontal: 12, paddingVertical: 9, marginTop: -4, marginBottom: 12,
  },
  notesErrorText: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: '#EF4444' },
  notesHint: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted, marginTop: -4, marginBottom: 12 },

  // Break options
  breakGrid: { gap: 10, marginBottom: 20 },
  breakOption: {
    padding: 14, borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: COLORS.border, backgroundColor: COLORS.card,
  },
  breakOptionActive: { borderColor: COLORS.green, backgroundColor: COLORS.greenMuted },
  breakHeader: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', marginBottom: 2 },
  breakLabel: { fontFamily: FONTS.bodyMedium, fontSize: 14, color: COLORS.muted2 },
  breakLabelActive: { color: COLORS.green },
  breakDesc: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted },
  paidBadge: {
    paddingHorizontal: 9, paddingVertical: 3, borderRadius: RADIUS.full,
    backgroundColor: COLORS.greenMuted, borderWidth: 1, borderColor: COLORS.green,
  },
  paidBadgeText: { fontFamily: FONTS.bodySemiBold, fontSize: 11, color: COLORS.green },

  // ── Price summary ──
  priceSummary: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border, padding: SPACING.lg, marginBottom: 16,
  },
  priceSummaryTitle: {
    fontFamily: FONTS.bodySemiBold, fontSize: 12, color: COLORS.muted,
    letterSpacing: 0.8, marginBottom: 14,
  },
  priceRow: {
    flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center',
    paddingVertical: 9, borderBottomWidth: 1, borderBottomColor: COLORS.border,
  },
  priceRowLabel:    { fontFamily: FONTS.body, fontSize: 14, color: COLORS.muted2 },
  priceRowSubLabel: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted, marginTop: 2 },
  priceRowValue:    { fontFamily: FONTS.bodyMedium, fontSize: 14, color: COLORS.text },
  priceRowExtra:    { fontFamily: FONTS.bodyMedium, fontSize: 14, color: COLORS.green },
  priceRowDiscount: { fontFamily: FONTS.bodyMedium, fontSize: 14, color: COLORS.green },
  totalRow: {
    flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center',
    paddingTop: 14, marginTop: 4,
  },
  totalLabel: { fontFamily: FONTS.bodySemiBold, fontSize: 16, color: COLORS.text },
  totalValue: { fontFamily: FONTS.title, fontSize: 30, color: COLORS.green },

  // ── MSI Card ──
  msiCard: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border, padding: SPACING.lg, marginBottom: 16,
  },
  msiHeader: { flexDirection: 'row', alignItems: 'center', gap: 10, marginBottom: 6 },
  msiTitle:  { fontFamily: FONTS.title, fontSize: 16, color: COLORS.text },
  msiSub:    { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2, marginBottom: 16 },
  msiOptions: { gap: 10, marginBottom: 14 },
  msiOption: {
    flexDirection: 'row', alignItems: 'center', gap: 12,
    backgroundColor: COLORS.card2, borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: COLORS.border, padding: 14,
  },
  msiOptionActive: { borderColor: COLORS.green, backgroundColor: COLORS.greenMuted },
  msiOptionCheck: { width: 20, alignItems: 'center' },
  msiOptionLabel: { fontFamily: FONTS.bodyMedium, fontSize: 15, color: COLORS.muted2 },
  msiOptionLabelActive: { color: COLORS.green },
  msiOptionAmount: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted, marginTop: 2 },
  msiBadge: {
    paddingHorizontal: 8, paddingVertical: 3,
    borderRadius: RADIUS.full, backgroundColor: 'rgba(66,133,244,0.12)',
    borderWidth: 1, borderColor: 'rgba(66,133,244,0.3)',
  },
  msiBadgeText: { fontFamily: FONTS.bodySemiBold, fontSize: 11, color: COLORS.blue },
  msiDisclaimer: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted, marginBottom: 16, lineHeight: 18 },
  msiHero: {
    alignItems: 'center',
    backgroundColor: COLORS.card2, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border, padding: SPACING.lg,
  },
  msiHeroLabel:     { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2, marginBottom: 4 },
  msiHeroAmount:    { fontFamily: FONTS.title, fontSize: 32, color: COLORS.green, marginBottom: 4 },
  msiHeroInterests: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.green },

  // Payment protection
  paymentProtection: {
    flexDirection: 'row', alignItems: 'flex-start', gap: 10,
    backgroundColor: COLORS.greenMuted, borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.3)',
    paddingHorizontal: 14, paddingVertical: 12, marginBottom: 12,
  },
  paymentProtectionText: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.green, flex: 1, lineHeight: 18 },

  // Policy card
  policyCard: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border, padding: SPACING.lg, marginBottom: 12,
  },
  policyTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.text, marginBottom: 14 },
  policyRow: { flexDirection: 'row', alignItems: 'flex-start', gap: 12 },
  policyDot: { width: 10, height: 10, borderRadius: 5, backgroundColor: COLORS.green, marginTop: 3 },
  policyDotRed: { backgroundColor: COLORS.red },
  policyRowTitle: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.text, marginBottom: 2 },
  policyRowDesc: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2 },
  policyDivider: { height: 1, backgroundColor: COLORS.border, marginVertical: 12 },

  // Pay button
  payBtnNote: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted, textAlign: 'center', marginTop: 10 },

  // Location / country selector
  locationSection: { marginTop: 4, marginBottom: 8 },
  locationLabel:   { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.muted, marginBottom: 8 },
  countryRow:      { flexDirection: 'row', gap: 10, marginBottom: 12 },
  countryBtn: {
    flex: 1, paddingVertical: 10, paddingHorizontal: 12,
    borderRadius: RADIUS.sm, borderWidth: 1, borderColor: COLORS.border,
    backgroundColor: COLORS.card2, alignItems: 'center',
  },
  countryBtnActive:     { borderColor: COLORS.green, backgroundColor: 'rgba(0,230,118,0.08)' },
  countryBtnText:       { fontFamily: FONTS.body, fontSize: 14, color: COLORS.muted2 },
  countryBtnTextActive: { color: COLORS.green, fontFamily: FONTS.bodySemiBold },
  usdNotice: {
    backgroundColor: 'rgba(245,158,11,0.10)',
    borderRadius: RADIUS.sm, padding: 10, marginTop: 4,
  },
  usdNoticeText: { fontFamily: FONTS.body, fontSize: 12, color: '#F59E0B' },
});
