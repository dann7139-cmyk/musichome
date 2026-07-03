import { ArrowLeft, Calendar, CheckCircle, Clock, ExternalLink, MapPin, Navigation, Shield, ShieldCheck, Star, Users, XCircle } from 'lucide-react-native';
import React, { useCallback, useEffect, useState } from 'react';
import {
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
import Badge from '../../components/ui/Badge';
import Button from '../../components/ui/Button';
import Particles from '../../components/ui/Particles';
import { breakTypeLabel } from '../../utils/calculations';

const STATUS_MAP: Record<string, { label: string; variant: any }> = {
  pending:                     { label: 'Pendiente',      variant: 'orange' },
  pending_payment:             { label: 'Pago pendiente', variant: 'orange' },
  pending_group_confirmation:  { label: 'Por confirmar',  variant: 'orange' },
  accepted:                    { label: 'Aceptada',       variant: 'green' },
  confirmed:                   { label: 'Confirmada',     variant: 'green' },
  in_progress:                 { label: 'En curso',       variant: 'blue' },
  completed:                   { label: 'Completada',     variant: 'muted' },
  cancelled:                   { label: 'Cancelada',      variant: 'red' },
  rejected:                    { label: 'Rechazada',      variant: 'red' },
  expired:                     { label: 'Expirada',       variant: 'red' },
};

interface MemberConfirmation {
  id: string;
  reservation_id: string;
  user_id: string;
  status: 'pending' | 'confirmed' | 'declined';
  confirmed_at: string | null;
  full_name: string;
  avatar_url: string | null;
  is_owner: boolean;
}

export default function GroupConfirmBookingScreen({ route, navigation }: any) {
  const { reservation: initialReservation, readOnly = false } = route.params;
  const [reservation, setReservation] = useState<any>(initialReservation);
  const [loading, setLoading]               = useState(false);
  const [confirmLoading, setConfirmLoading] = useState(false);
  const [chargeLoading, setChargeLoading]   = useState(false);
  const [clientProfile, setClientProfile]           = useState<any>(null);
  const [clientCompletedCount, setClientCompletedCount] = useState<number>(0);
  const [groupStripeComplete, setGroupStripeComplete] = useState(true); // optimistic
  const [members, setMembers]               = useState<MemberConfirmation[]>([]);
  const [currentUserId, setCurrentUserId]   = useState<string | null>(null);
  const [distAmounts, setDistAmounts]       = useState<Record<string, string>>({});
  const [distSaving, setDistSaving]         = useState(false);
  const s = STATUS_MAP[reservation.status] ?? STATUS_MAP.pending;

  useEffect(() => {
    loadData();
  }, []);

  // Refrescar cuando la pantalla recupera el foco (ej. tras el pago)
  useEffect(() => {
    const unsubscribe = navigation.addListener('focus', () => { loadData(); });
    return unsubscribe;
  }, [navigation]);

  const loadData = useCallback(async () => {
    const { data: sd } = await supabase.auth.getSession();
    const uid = sd.session?.user.id ?? null;
    setCurrentUserId(uid);

    // Refrescar datos de la reserva desde la DB (evita datos obsoletos)
    // Se intenta unir con quotes para que el temporizador tenga la duración correcta en reservas de cotización
    const { data: freshRes } = await supabase
      .from('reservations')
      .select('*, client:profiles(full_name), quote:quotes(duration_hours, overtime_1h_price, overtime_2h_price, overtime_3h_price, event_address, event_municipio, event_estado, comments)')
      .eq('id', initialReservation.id)
      .single();
    if (freshRes) setReservation({ ...initialReservation, ...freshRes });

    // Cargar perfil del cliente
    if (initialReservation.client_id) {
      supabase
        .from('profiles')
        .select('rating, city, state, verification_status, admin_verified, id_verified, full_name, created_at, avatar_url, role, group_name')
        .eq('id', initialReservation.client_id)
        .single()
        .then(({ data }) => { if (data) setClientProfile(data); });

      // Eventos completados reales del cliente (independiente — no bloquea el render)
      supabase
        .from('reservations')
        .select('id', { count: 'exact', head: true })
        .eq('client_id', initialReservation.client_id)
        .eq('status', 'completed')
        .then(({ count }) => { setClientCompletedCount(count ?? 0); });
    }

    // Verificar estado Stripe del grupo (solo para dueño, no readOnly)
    if (!readOnly && initialReservation.group_id) {
      supabase
        .from('groups')
        .select('stripe_onboarding_completed')
        .eq('id', initialReservation.group_id)
        .single()
        .then(({ data }) => {
          setGroupStripeComplete(data?.stripe_onboarding_completed ?? false);
        });
    }

    // Cargar confirmaciones de integrantes
    const { data: conf } = await supabase.rpc('get_reservation_confirmations', {
      p_reservation_id: initialReservation.id,
    });
    if (conf) setMembers(conf as MemberConfirmation[]);

    // Pre-cargar distribución express si ya existe
    if (initialReservation.event_request_id) {
      const { data: existingPayouts } = await supabase
        .from('event_payouts')
        .select('user_id, amount')
        .eq('reservation_id', initialReservation.id)
        .eq('role', 'member');
      if (existingPayouts?.length) {
        const amounts: Record<string, string> = {};
        existingPayouts.forEach(p => { amounts[p.user_id] = String(p.amount); });
        setDistAmounts(amounts);
      }
    }
  }, [initialReservation.id, initialReservation.client_id]);

  const myConfirmation = members.find(m => m.user_id === currentUserId);

  const clientRating   = clientProfile?.rating ?? null;
  const clientVerified = clientProfile?.verification_status === 'approved' ||
                         clientProfile?.admin_verified === true;
  const clientCity     = clientProfile?.city;
  const clientState    = clientProfile?.state;

  const saveExpressDist = async () => {
    const nonOwners = members.filter(m => !m.is_owner);
    const net = reservation.group_earnings ?? 0;
    const assigned = nonOwners.reduce((sum, m) => sum + (parseFloat(distAmounts[m.user_id] ?? '0') || 0), 0);
    if (assigned > net) {
      Alert.alert('Error', `Los montos asignados ($${assigned.toLocaleString()}) superan la ganancia neta ($${net.toLocaleString()}).`);
      return;
    }
    setDistSaving(true);
    const rows = nonOwners.map(m => ({
      reservation_id: reservation.id,
      user_id: m.user_id,
      role: 'member',
      amount: parseFloat(distAmounts[m.user_id] ?? '0') || 0,
      payout_status: 'pending',
      is_informational: true,
    }));
    const { error } = await supabase
      .from('event_payouts')
      .upsert(rows, { onConflict: 'reservation_id,user_id' });
    setDistSaving(false);
    if (error) { Alert.alert('Error', error.message); return; }
    Alert.alert('✅ Distribución guardada', 'Los montos fueron asignados a cada integrante.');
  };

  // ── Acciones del dueño ──────────────────────────────────────────────────────
  const handleConfirm = async () => {
    setLoading(true);
    const paymentDeadline = new Date(Date.now() + 24 * 60 * 60 * 1000).toISOString();
    const { error } = await supabase
      .from('reservations')
      .update({ status: 'accepted', booking_expiration_at: paymentDeadline })
      .eq('id', reservation.id);

    if (!error && reservation.client_id) {
      await supabase.from('notifications').insert([{
        user_id: reservation.client_id,
        type: 'reservation',
        title: '✅ ¡Reserva aceptada!',
        message: reservation.total_price
          ? `Tu reserva fue aceptada 🎉 Completa el pago de $${reservation.total_price.toLocaleString()} MXN para confirmarla.`
          : 'Tu reserva fue aceptada. Completa el pago para confirmarla.',
        reference_id: reservation.id,
      }]);
    }

    setLoading(false);
    if (error) { Alert.alert('Error', error.message); return; }
    Alert.alert('¡Aceptada! ✅', 'El cliente recibirá una notificación para completar el pago.', [
      { text: 'OK', onPress: () => navigation.goBack() },
    ]);
  };

  const handleReject = async () => {
    Alert.alert('Rechazar reserva', '¿Estás seguro de rechazar esta reserva?', [
      { text: 'Cancelar', style: 'cancel' },
      {
        text: 'Rechazar', style: 'destructive',
        onPress: async () => {
          setLoading(true);
          await supabase.from('reservations').update({ status: 'rejected' }).eq('id', reservation.id);
          setLoading(false);
          navigation.goBack();
        },
      },
    ]);
  };

  const handleFinishEvent = async () => {
    Alert.alert(
      'Finalizar evento',
      '¿Confirmas que el evento ha terminado? El pago ya fue procesado.',
      [
        { text: 'Cancelar', style: 'cancel' },
        {
          text: 'Finalizar y cobrar',
          onPress: async () => {
            setChargeLoading(true);
            try {
              const { data: sd } = await supabase.auth.getSession();
              const token = sd.session?.access_token;
              const { data, error } = await supabase.functions.invoke('charge-remaining', {
                body:    { reservation_id: reservation.id },
                headers: { Authorization: `Bearer ${token}` },
              });

              setChargeLoading(false);

              if (error || data?.error) {
                Alert.alert('Error', data?.error ?? 'No se pudo cobrar. Intenta de nuevo.');
                return;
              }

              if (!data?.success && data?.reason === 'no_payment_method') {
                Alert.alert(
                  'Sin tarjeta guardada',
                  'El cliente no tiene tarjeta guardada. Se le envió una notificación para que pague manualmente.',
                );
              } else if (!data?.success && data?.reason === 'charge_failed') {
                Alert.alert(
                  '⚠️ Cobro fallido',
                  `No se pudo cobrar la tarjeta del cliente: ${data.message}. Se le notificó para que actualice su método de pago.`,
                );
              } else {
                Alert.alert('✅ Evento finalizado', 'El saldo fue cobrado exitosamente. ¡Buen trabajo!', [
                  { text: 'OK', onPress: () => navigation.goBack() },
                ]);
              }
            } catch (e: any) {
              setChargeLoading(false);
              Alert.alert('Error', e.message ?? 'Error al finalizar el evento');
            }
          },
        },
      ],
    );
  };

  const handleArrive = () => {
    // La llegada se registra en el Temporizador con verificación GPS
    // (release_half_on_arrival, sql/424) — una sola ruta de llegada.
    navigation.navigate('EventTimer', { reservation });
  };

  const handleStartEvent = () => {
    // El temporizador controla el inicio real del evento, la selección de descanso
    // y las notificaciones al cliente — no hacemos nada en la DB aquí.
    navigation.navigate('EventTimer', { reservation });
  };

  // ── Confirmación personal del integrante ─────────────────────────────────
  const handleMemberConfirm = async (status: 'confirmed' | 'declined') => {
    setConfirmLoading(true);
    const { error } = await supabase.rpc('confirm_member_attendance', {
      p_reservation_id: reservation.id,
      p_status: status,
    });
    setConfirmLoading(false);
    if (error) { Alert.alert('Error', error.message); return; }

    const label = status === 'confirmed' ? 'Confirmaste tu asistencia ✅' : 'Marcaste que no puedes ir';
    Alert.alert(label, '');
    loadData(); // Refrescar la lista
  };

  const confirmed   = members.filter(m => m.status === 'confirmed').length;
  const totalMembers = members.length;

  return (
    <View style={styles.container}>
      <Particles />
      <SafeAreaView style={{ flex: 1 }}>
        {/* HEADER */}
        <View style={styles.header}>
          <Pressable style={styles.backBtn} onPress={() => navigation.goBack()}>
            <ArrowLeft size={20} color={COLORS.text} />
          </Pressable>
          <Text style={styles.headerTitle}>
            {readOnly ? 'Detalle de Reserva' : 'Detalle de Reserva'}
          </Text>
          <View style={{ width: 40 }} />
        </View>

        <ScrollView showsVerticalScrollIndicator={false} contentContainerStyle={styles.scroll}>
          {/* STATUS */}
          <View style={styles.statusRow}>
            <Badge label={s.label} variant={s.variant} dot />
            <Text style={styles.reservationId}>#{reservation.id?.slice(0, 8)}</Text>
          </View>

          {/* ── CONFIRMACIÓN DEL EQUIPO ── */}
          {members.length > 0 && (
            <View style={styles.teamCard}>
              <View style={styles.teamHeader}>
                <Users size={15} color={COLORS.green} />
                <Text style={styles.teamTitle}>Confirmación del equipo</Text>
                <View style={styles.teamProgress}>
                  <Text style={styles.teamProgressText}>
                    {confirmed}/{totalMembers}
                  </Text>
                </View>
              </View>

              {/* Barra de progreso */}
              <View style={styles.progressBar}>
                <View
                  style={[
                    styles.progressFill,
                    { width: totalMembers > 0 ? `${(confirmed / totalMembers) * 100}%` : '0%' },
                  ]}
                />
              </View>

              {/* Lista de integrantes */}
              {members.map(member => (
                <View key={member.id} style={styles.memberRow}>
                  {/* Avatar */}
                  {member.avatar_url
                    ? <Image source={{ uri: member.avatar_url }} style={styles.memberAvatar} />
                    : (
                      <View style={styles.memberAvatarPlaceholder}>
                        <Text style={styles.memberAvatarInitial}>
                          {member.full_name?.charAt(0)?.toUpperCase() ?? '?'}
                        </Text>
                      </View>
                    )
                  }
                  {/* Nombre + rol */}
                  <View style={{ flex: 1 }}>
                    <Text style={styles.memberName}>{member.full_name ?? 'Sin nombre'}</Text>
                    {member.is_owner && (
                      <Text style={styles.memberRole}>Dueño del grupo</Text>
                    )}
                  </View>
                  {/* Estado */}
                  <MemberStatusChip status={member.status} />
                </View>
              ))}

              {/* Botones de confirmación para el integrante actual */}
              {myConfirmation?.status === 'pending' && (
                <View style={styles.myConfirmRow}>
                  <Text style={styles.myConfirmLabel}>¿Puedes asistir?</Text>
                  <View style={styles.myConfirmBtns}>
                    <Pressable
                      style={[styles.myConfirmBtn, styles.myConfirmDecline]}
                      onPress={() => handleMemberConfirm('declined')}
                      disabled={confirmLoading}
                    >
                      <XCircle size={15} color="#EF5350" />
                      <Text style={styles.myConfirmDeclineText}>No puedo</Text>
                    </Pressable>
                    <Pressable
                      style={[styles.myConfirmBtn, styles.myConfirmAccept]}
                      onPress={() => handleMemberConfirm('confirmed')}
                      disabled={confirmLoading}
                    >
                      <CheckCircle size={15} color={COLORS.bg} />
                      <Text style={styles.myConfirmAcceptText}>Confirmar</Text>
                    </Pressable>
                  </View>
                </View>
              )}
              {myConfirmation?.status === 'confirmed' && (
                <View style={styles.myConfirmDone}>
                  <CheckCircle size={14} color={COLORS.green} />
                  <Text style={styles.myConfirmDoneText}>Confirmaste tu asistencia</Text>
                </View>
              )}
              {myConfirmation?.status === 'declined' && (
                <View style={[styles.myConfirmDone, { borderColor: '#EF535033' }]}>
                  <XCircle size={14} color="#EF5350" />
                  <Text style={[styles.myConfirmDoneText, { color: '#EF5350' }]}>Marcaste que no puedes ir</Text>
                </View>
              )}
            </View>
          )}

          {/* CLIENT INFO */}
          <View style={styles.card}>
            <View style={styles.clientHeader}>
              <Text style={styles.cardTitle}>Quién contrata</Text>
              {clientVerified && (
                <View style={styles.verifiedChip}>
                  <ShieldCheck size={12} color={COLORS.blue} />
                  <Text style={styles.verifiedChipText}>Verificado</Text>
                </View>
              )}
              {!clientVerified && clientProfile && (
                <View style={styles.unverifiedChip}>
                  <Shield size={12} color={COLORS.muted2} />
                  <Text style={styles.unverifiedChipText}>Sin verificar</Text>
                </View>
              )}
            </View>

            {/* Avatar + nombre + tipo de contratante */}
            <View style={styles.contractorRow}>
              {clientProfile?.avatar_url
                ? <Image source={{ uri: clientProfile.avatar_url }} style={styles.contractorAvatar} />
                : (
                  <View style={styles.contractorAvatarPlaceholder}>
                    <Text style={styles.contractorAvatarInitial}>
                      {(clientProfile?.full_name ?? reservation.client?.full_name ?? '?').charAt(0).toUpperCase()}
                    </Text>
                  </View>
                )
              }
              <View style={{ flex: 1 }}>
                <Text style={styles.contractorName}>
                  {clientProfile?.full_name ?? reservation.client?.full_name ?? 'Sin nombre'}
                </Text>
                <View style={styles.contractorTypeBadge}>
                  <Text style={styles.contractorTypeText}>
                    {clientProfile?.role === 'group'
                      ? `🎸 Grupo${clientProfile.group_name ? `: ${clientProfile.group_name}` : ''}`
                      : clientProfile?.role === 'talent'
                      ? '🎵 Músico independiente'
                      : '👤 Cliente particular'}
                  </Text>
                </View>
              </View>
            </View>
            {(clientCity || clientState) && (
              <View style={styles.infoRow}>
                <MapPin size={14} color={COLORS.muted2} />
                <Text style={styles.infoText}>
                  {[clientCity, clientState].filter(Boolean).join(', ')}
                </Text>
              </View>
            )}
            <View style={styles.clientMetaRow}>
              <View style={styles.clientRatingRow}>
                <Star size={14} color={COLORS.gold} fill={COLORS.gold} />
                <Text style={styles.clientRatingText}>
                  {clientRating != null ? clientRating.toFixed(1) : '—'}
                </Text>
              </View>
              {clientProfile?.created_at && (
                <Text style={styles.clientSinceText}>
                  Miembro desde {new Date(clientProfile.created_at).toLocaleDateString('es-MX', { month: 'short', year: 'numeric' })}
                </Text>
              )}
            </View>
            {clientCompletedCount > 0 && (
              <View style={styles.clientEventsRow}>
                <CheckCircle size={13} color={COLORS.green} />
                <Text style={styles.clientEventsText}>
                  {clientCompletedCount} evento{clientCompletedCount !== 1 ? 's' : ''} realizad{clientCompletedCount !== 1 ? 'os' : 'o'}
                </Text>
              </View>
            )}
          </View>

          {/* EVENT INFO */}
          <View style={styles.card}>
            <Text style={styles.cardTitle}>Evento</Text>
            <View style={styles.infoRow}>
              <Calendar size={15} color={COLORS.muted2} />
              <Text style={styles.infoText}>{reservation.event_date}</Text>
            </View>
            {reservation.event_time && (
              <View style={styles.infoRow}>
                <Clock size={15} color={COLORS.muted2} />
                <Text style={styles.infoText}>{reservation.event_time}</Text>
              </View>
            )}
            <View style={styles.infoRow}>
              <MapPin size={15} color={COLORS.muted2} />
              <Text style={[styles.infoText, { flex: 1 }]}>{reservation.address}</Text>
            </View>
            {reservation.address && (
              <Pressable
                style={styles.mapBtn}
                onPress={() => {
                  const url = `https://www.google.com/maps/search/?api=1&query=${encodeURIComponent(reservation.address)}`;
                  Linking.openURL(url);
                }}
              >
                <Navigation size={14} color={COLORS.green} />
                <Text style={styles.mapBtnText}>Abrir en Google Maps</Text>
                <ExternalLink size={12} color={COLORS.green} />
              </Pressable>
            )}
            {reservation.notes && (
              <View style={[styles.infoRow, { alignItems: 'flex-start' }]}>
                <Text style={styles.noteIcon}>📝</Text>
                <Text style={[styles.infoText, { flex: 1 }]}>{reservation.notes}</Text>
              </View>
            )}
          </View>

          {/* PACKAGE */}
          <View style={styles.card}>
            <Text style={styles.cardTitle}>Detalles del evento</Text>
            <Text style={styles.pkgName}>
              {reservation.quote?.duration_hours ? `${reservation.quote.duration_hours}h de servicio` : '—'}
            </Text>
            {false && reservation.break_type && (
              <View style={styles.breakBox}>
                <Text style={styles.breakBoxIcon}>☕</Text>
                <View style={{ flex: 1 }}>
                  <Text style={styles.breakBoxLabel}>Tipo de descanso elegido</Text>
                  <Text style={styles.breakBoxValue}>{breakTypeLabel(reservation.break_type)}</Text>
                  {reservation.break_type === 'D' && (
                    <Text style={styles.breakBoxNote}>
                      Sin pausas — asegúrate de que el equipo esté preparado para tocar corrido
                    </Text>
                  )}
                </View>
              </View>
            )}
          </View>

          {/* STRIPE ALERT — grupo sin cuenta bancaria activa */}
          {!readOnly && !groupStripeComplete && (
            <View style={styles.stripeWarnCard}>
              <Text style={styles.payWaitIcon}>💳</Text>
              <View style={{ flex: 1 }}>
                <Text style={styles.stripeWarnTitle}>Cuenta bancaria no conectada</Text>
                <Text style={styles.stripeWarnDesc}>
                  Conecta tu cuenta bancaria en tu Perfil para recibir los pagos de este evento automáticamente.
                </Text>
              </View>
            </View>
          )}

          {/* GANANCIA DEL GRUPO */}
          {!readOnly && (
            <View style={styles.clientPriceSummary}>
              <Text style={styles.clientPriceTitle}>Tu ganancia</Text>
              <View style={styles.clientPriceTotalRow}>
                <Text style={styles.clientPriceTotalLabel}>Ganarás</Text>
                <Text style={styles.clientPriceTotalValue}>${(reservation.group_earnings ?? 0).toLocaleString()} MXN</Text>
              </View>
            </View>
          )}

          {/* MSI INFO — informar al grupo que el cliente puede pagar en meses */}
          {!readOnly && (
            <View style={styles.msiInfoCard}>
              <Text style={styles.msiInfoIcon}>💳</Text>
              <View style={{ flex: 1 }}>
                <Text style={styles.msiInfoTitle}>Pago en mensualidades disponible</Text>
                <Text style={styles.msiInfoDesc}>
                  El cliente puede elegir pagar en 3, 6, 9 o 12 mensualidades con su tarjeta. Tú recibes el 100% de tu ganancia sin importar el plan elegido.
                </Text>
              </View>
            </View>
          )}

          {/* DISTRIBUCIÓN EXPRESS — solo para el dueño, solo en cotizaciones express */}
          {!readOnly && reservation.event_request_id && members.filter(m => !m.is_owner).length > 0 && (
            <View style={styles.distCard}>
              <Text style={styles.distTitle}>Distribución de ganancias</Text>
              <Text style={styles.distSubtitle}>Asigna cuánto recibe cada integrante de la ganancia neta</Text>

              <View style={styles.distNetRow}>
                <Text style={styles.distNetLabel}>Ganancia neta del grupo</Text>
                <Text style={styles.distNetValue}>${(reservation.group_earnings ?? 0).toLocaleString()}</Text>
              </View>

              {members.filter(m => !m.is_owner).map(m => (
                <View key={m.user_id} style={styles.distMemberRow}>
                  {m.avatar_url
                    ? <Image source={{ uri: m.avatar_url }} style={styles.distAvatar} />
                    : (
                      <View style={styles.distAvatarPlaceholder}>
                        <Text style={styles.distAvatarInitial}>{m.full_name?.charAt(0)?.toUpperCase() ?? '?'}</Text>
                      </View>
                    )
                  }
                  <Text style={styles.distMemberName} numberOfLines={1}>{m.full_name ?? 'Integrante'}</Text>
                  <View style={styles.distInputWrap}>
                    <Text style={styles.distInputPrefix}>$</Text>
                    <TextInput
                      style={styles.distInput}
                      value={distAmounts[m.user_id] ?? ''}
                      onChangeText={v => setDistAmounts(prev => ({ ...prev, [m.user_id]: v.replace(/[^0-9]/g, '') }))}
                      keyboardType="numeric"
                      placeholder="0"
                      placeholderTextColor={COLORS.muted}
                    />
                  </View>
                </View>
              ))}

              {(() => {
                const net = reservation.group_earnings ?? 0;
                const assigned = members.filter(m => !m.is_owner).reduce((sum, m) => sum + (parseFloat(distAmounts[m.user_id] ?? '0') || 0), 0);
                const remaining = net - assigned;
                return (
                  <View style={styles.distRemainingRow}>
                    <Text style={styles.distRemainingLabel}>Para el dueño del grupo</Text>
                    <Text style={[styles.distRemainingValue, remaining < 0 && { color: '#EF5350' }]}>
                      ${remaining.toLocaleString()}
                    </Text>
                  </View>
                );
              })()}

              <Button
                label="Guardar distribución"
                onPress={saveExpressDist}
                loading={distSaving}
                size="lg"
              />
            </View>
          )}

          {/* Banner: esperando pago completo (solo dueño) */}
          {!readOnly && reservation.status === 'accepted' &&
            reservation.payment_status !== 'paid' &&
            reservation.payment_status !== 'deposit_paid' &&
            reservation.payment_status !== 'fully_paid' && (
            <View style={styles.payWaitCard}>
              <Text style={styles.payWaitIcon}>⏳</Text>
              <View style={{ flex: 1 }}>
                <Text style={styles.payWaitTitle}>Esperando pago del cliente</Text>
                <Text style={styles.payWaitDesc}>
                  El cliente debe completar el pago para confirmar el evento.
                </Text>
              </View>
            </View>
          )}

          {/* Banner de estado de pago para integrantes (readOnly) */}
          {readOnly && (reservation.status === 'accepted' || reservation.status === 'confirmed') && (() => {
            const ps = reservation.payment_status;
            const paid = ps === 'paid' || ps === 'deposit_paid' || ps === 'fully_paid';
            const icon  = paid ? '✅' : '⏳';
            const title = paid               ? 'Pago confirmado'
                        : ps === 'deposit_pending' ? 'Pago en proceso...'
                        : 'Pago pendiente';
            const desc  = paid               ? 'El cliente realizó el pago completo del evento.'
                        : ps === 'deposit_pending' ? 'El cliente inició el pago. Se confirmará en breve.'
                        : 'El cliente aún no ha completado el pago del evento.';
            return (
              <View style={paid ? styles.payPaidCard : styles.payWaitCard}>
                <Text style={styles.payWaitIcon}>{icon}</Text>
                <View style={{ flex: 1 }}>
                  <Text style={paid ? styles.payPaidTitle : styles.payWaitTitle}>{title}</Text>
                  <Text style={styles.payWaitDesc}>{desc}</Text>
                </View>
              </View>
            );
          })()}

          {/* ACTIONS — sólo el dueño del grupo (no readOnly) */}
          {!readOnly && (
            <View style={styles.actions}>
              {(reservation.status === 'pending' ||
                reservation.status === 'pending_payment' ||
                reservation.status === 'pending_group_confirmation') && (
                <>
                  <Button label="✅ Confirmar reserva" onPress={handleConfirm} loading={loading} size="lg" />
                  <View style={{ height: 10 }} />
                  <Button label="Rechazar" onPress={handleReject} variant="danger" size="lg" />
                </>
              )}
              {reservation.status === 'confirmed' && (
                <>
                  <Button label="📍 Llegué al evento" onPress={handleArrive} variant="outline" size="lg" />
                  <View style={{ height: 10 }} />
                  <Button label="🎵 Iniciar evento" onPress={handleStartEvent} size="lg" />
                  {reservation.payment_status !== 'paid' &&
                   reservation.payment_status !== 'deposit_paid' &&
                   reservation.payment_status !== 'fully_paid' && (
                    <Text style={styles.noPayWarning}>
                      ⚠️ El pago del cliente aún no ha sido confirmado
                    </Text>
                  )}
                </>
              )}
              {reservation.status === 'in_progress' && (
                <>
                  <Button
                    label="⏱ Ver temporizador"
                    onPress={() => navigation.navigate('EventTimer', { reservation })}
                    variant="outline"
                    size="lg"
                  />
                  <View style={{ height: 10 }} />
                  <Button
                    label={chargeLoading ? 'Finalizando...' : '🏁 Finalizar evento'}
                    onPress={handleFinishEvent}
                    loading={chargeLoading}
                    size="lg"
                  />
                </>
              )}
            </View>
          )}

          {/* Integrante: ver temporizador si el evento está en curso */}
          {readOnly && reservation.status === 'in_progress' && (
            <View style={styles.actions}>
              <Button
                label="⏱ Ver temporizador en vivo"
                onPress={() => navigation.navigate('EventTimer', { reservation, readOnly: true })}
                size="lg"
              />
            </View>
          )}
        </ScrollView>
      </SafeAreaView>
    </View>
  );
}

// ── Sub-componente: chip de estado del miembro ───────────────────────────────
function MemberStatusChip({ status }: { status: 'pending' | 'confirmed' | 'declined' }) {
  if (status === 'confirmed') {
    return (
      <View style={[chip.wrap, chip.green]}>
        <CheckCircle size={11} color={COLORS.green} />
        <Text style={[chip.text, { color: COLORS.green }]}>Confirmó</Text>
      </View>
    );
  }
  if (status === 'declined') {
    return (
      <View style={[chip.wrap, chip.red]}>
        <XCircle size={11} color="#EF5350" />
        <Text style={[chip.text, { color: '#EF5350' }]}>No puede</Text>
      </View>
    );
  }
  return (
    <View style={[chip.wrap, chip.gray]}>
      <Clock size={11} color={COLORS.muted} />
      <Text style={[chip.text, { color: COLORS.muted }]}>Pendiente</Text>
    </View>
  );
}

// ── Styles ───────────────────────────────────────────────────────────────────

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
  scroll: { padding: SPACING.xl, gap: 16 },
  statusRow: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center', marginBottom: 4 },
  reservationId: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted },

  // ── Team card ──────────────────────────────────────────────────────────────
  teamCard: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.green + '40',
    padding: SPACING.lg,
  },
  teamHeader: { flexDirection: 'row', alignItems: 'center', gap: 8, marginBottom: 10 },
  teamTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.text, flex: 1 },
  teamProgress: {
    backgroundColor: COLORS.greenMuted, borderRadius: RADIUS.full,
    borderWidth: 1, borderColor: COLORS.green,
    paddingHorizontal: 9, paddingVertical: 3,
  },
  teamProgressText: { fontFamily: FONTS.bodySemiBold, fontSize: 12, color: COLORS.green },
  progressBar: {
    height: 4, backgroundColor: COLORS.card2, borderRadius: 2, marginBottom: 14, overflow: 'hidden',
  },
  progressFill: { height: '100%', backgroundColor: COLORS.green, borderRadius: 2 },
  memberRow: { flexDirection: 'row', alignItems: 'center', gap: 12, marginBottom: 10 },
  memberAvatar: { width: 38, height: 38, borderRadius: 19 },
  memberAvatarPlaceholder: {
    width: 38, height: 38, borderRadius: 19,
    backgroundColor: COLORS.greenMuted, borderWidth: 1, borderColor: COLORS.green,
    alignItems: 'center', justifyContent: 'center',
  },
  memberAvatarInitial: { fontFamily: FONTS.title, fontSize: 16, color: COLORS.green },
  memberName: { fontFamily: FONTS.bodyMedium, fontSize: 14, color: COLORS.text },
  memberRole: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted2 },

  myConfirmRow: {
    marginTop: 12, paddingTop: 12, borderTopWidth: 1, borderTopColor: COLORS.border,
  },
  myConfirmLabel: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted2, marginBottom: 10 },
  myConfirmBtns: { flexDirection: 'row', gap: 10 },
  myConfirmBtn: {
    flex: 1, flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 7,
    paddingVertical: 11, borderRadius: RADIUS.md, borderWidth: 1,
  },
  myConfirmAccept: { backgroundColor: COLORS.green, borderColor: COLORS.green },
  myConfirmDecline: { backgroundColor: 'rgba(239,83,80,0.08)', borderColor: 'rgba(239,83,80,0.35)' },
  myConfirmAcceptText: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.bg },
  myConfirmDeclineText: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: '#EF5350' },
  myConfirmDone: {
    flexDirection: 'row', alignItems: 'center', gap: 8,
    marginTop: 12, paddingTop: 12, borderTopWidth: 1, borderTopColor: COLORS.green + '33',
  },
  myConfirmDoneText: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.green },

  // ── Generic card ───────────────────────────────────────────────────────────
  card: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border, padding: SPACING.lg,
  },
  cardTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.muted2, marginBottom: 12, textTransform: 'uppercase', letterSpacing: 0.8 },
  infoRow: { flexDirection: 'row', alignItems: 'center', gap: 10, marginBottom: 8 },
  infoText: { fontFamily: FONTS.body, fontSize: 14, color: COLORS.text },
  mapBtn: {
    flexDirection: 'row', alignItems: 'center', gap: 8,
    backgroundColor: COLORS.greenMuted, borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: COLORS.green,
    paddingVertical: 10, paddingHorizontal: 14, marginBottom: 8,
  },
  mapBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.green, flex: 1 },
  noteIcon: { fontSize: 14 },
  clientHeader: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center', marginBottom: 12 },
  verifiedChip: {
    flexDirection: 'row', alignItems: 'center', gap: 5,
    paddingHorizontal: 10, paddingVertical: 4, borderRadius: RADIUS.full,
    backgroundColor: 'rgba(66,133,244,0.1)', borderWidth: 1, borderColor: 'rgba(66,133,244,0.3)',
  },
  verifiedChipText: { fontFamily: FONTS.bodyMedium, fontSize: 11, color: COLORS.blue },
  unverifiedChip: {
    flexDirection: 'row', alignItems: 'center', gap: 5,
    paddingHorizontal: 10, paddingVertical: 4, borderRadius: RADIUS.full,
    backgroundColor: COLORS.card2, borderWidth: 1, borderColor: COLORS.border,
  },
  unverifiedChipText: { fontFamily: FONTS.bodyMedium, fontSize: 11, color: COLORS.muted2 },
  clientMetaRow: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', marginTop: 10,
    paddingTop: 10, borderTopWidth: 1, borderTopColor: COLORS.border,
  },
  clientRatingRow: { flexDirection: 'row', alignItems: 'center', gap: 6 },
  clientRatingText: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.gold },
  clientSinceText:   { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted },
  clientEventsRow:   { flexDirection: 'row', alignItems: 'center', gap: 6, marginTop: 6 },
  clientEventsText:  { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.green },
  pkgName: { fontFamily: FONTS.bodySemiBold, fontSize: 18, color: COLORS.text, marginBottom: 4 },
  pkgDuration: { fontFamily: FONTS.body, fontSize: 14, color: COLORS.muted2, marginBottom: 12 },
  breakBox: {
    flexDirection: 'row', alignItems: 'flex-start', gap: 10,
    backgroundColor: COLORS.bg, borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: COLORS.border, padding: 12, marginTop: 4,
  },
  breakBoxSurcharge: { borderColor: COLORS.gold, backgroundColor: 'rgba(255,200,0,0.05)' },
  breakBoxIcon: { fontSize: 16, marginTop: 1 },
  breakBoxLabel: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted, marginBottom: 2, textTransform: 'uppercase', letterSpacing: 0.5 },
  breakBoxValue: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.text },
  breakBoxValueSurcharge: { color: COLORS.gold },
  breakBoxNote: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.gold, marginTop: 2 },
  sectionTitle: { fontFamily: FONTS.title, fontSize: 16, color: COLORS.text, marginTop: 4 },
  clientPriceSummary: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border, padding: SPACING.lg,
  },
  clientPriceTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.muted2, marginBottom: 12, textTransform: 'uppercase', letterSpacing: 0.8 },
  clientPriceRow: {
    flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center',
    paddingVertical: 8, borderBottomWidth: 1, borderBottomColor: COLORS.border,
  },
  clientPriceLabel: { fontFamily: FONTS.body, fontSize: 14, color: COLORS.muted2 },
  clientPriceValue: { fontFamily: FONTS.bodyMedium, fontSize: 14, color: COLORS.text },
  clientPriceExtra: { fontFamily: FONTS.bodyMedium, fontSize: 14, color: COLORS.green },
  clientPriceTotalRow: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center', paddingTop: 12, marginTop: 4 },
  clientPriceTotalLabel: { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.text },
  clientPriceTotalValue: { fontFamily: FONTS.title, fontSize: 22, color: COLORS.green },
  actions: { marginTop: 8, marginBottom: 32 },

  // Pay-wait banner
  payWaitCard: {
    flexDirection: 'row', alignItems: 'flex-start', gap: 12,
    backgroundColor: 'rgba(255,152,0,0.08)', borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: 'rgba(255,152,0,0.35)',
    padding: SPACING.lg, marginTop: 4,
  },
  payPaidCard: {
    flexDirection: 'row', alignItems: 'flex-start', gap: 12,
    backgroundColor: 'rgba(0,230,118,0.08)', borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.35)',
    padding: SPACING.lg, marginTop: 4,
  },
  payWaitIcon: { fontSize: 20, marginTop: 1 },
  payWaitTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.orange, marginBottom: 3 },
  payPaidTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.green, marginBottom: 3 },
  payWaitDesc:  { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2, lineHeight: 19 },
  noPayWarning: {
    fontFamily: FONTS.body, fontSize: 12, color: COLORS.orange,
    textAlign: 'center', marginTop: 8,
  },
  stripeWarnCard: {
    flexDirection: 'row', alignItems: 'flex-start', gap: 12,
    backgroundColor: 'rgba(255,152,0,0.08)', borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: 'rgba(255,152,0,0.35)',
    padding: SPACING.lg,
  },
  stripeWarnTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.orange, marginBottom: 3 },
  stripeWarnDesc:  { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2, lineHeight: 18 },

  msiInfoCard: {
    flexDirection: 'row', alignItems: 'flex-start', gap: 12,
    backgroundColor: 'rgba(66,133,244,0.08)', borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: 'rgba(66,133,244,0.25)',
    padding: SPACING.lg, marginTop: 4,
  },
  msiInfoIcon:  { fontSize: 20, marginTop: 1 },
  msiInfoTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: '#4285F4', marginBottom: 3 },
  msiInfoDesc:  { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2, lineHeight: 19 },

  // ── Distribución express ────────────────────────────────────────────────────
  distCard: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.green + '40',
    padding: SPACING.lg, gap: 12,
  },
  distTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.text },
  distSubtitle: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2, marginTop: -6 },
  distNetRow: {
    flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center',
    backgroundColor: COLORS.card2, borderRadius: RADIUS.md, padding: 12,
  },
  distNetLabel: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted2 },
  distNetValue: { fontFamily: FONTS.title, fontSize: 18, color: COLORS.green },
  distMemberRow: { flexDirection: 'row', alignItems: 'center', gap: 10 },
  distAvatar: { width: 34, height: 34, borderRadius: 17 },
  distAvatarPlaceholder: {
    width: 34, height: 34, borderRadius: 17,
    backgroundColor: COLORS.greenMuted, borderWidth: 1, borderColor: COLORS.green,
    alignItems: 'center', justifyContent: 'center',
  },
  distAvatarInitial: { fontFamily: FONTS.title, fontSize: 14, color: COLORS.green },
  distMemberName: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.text, flex: 1 },
  distInputWrap: {
    flexDirection: 'row', alignItems: 'center', gap: 4,
    backgroundColor: COLORS.bg, borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: COLORS.border,
    paddingHorizontal: 10, paddingVertical: 8, minWidth: 100,
  },
  distInputPrefix: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.muted2 },
  distInput: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.text, minWidth: 70, padding: 0 },
  distRemainingRow: {
    flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center',
    paddingTop: 10, borderTopWidth: 1, borderTopColor: COLORS.border,
  },
  distRemainingLabel: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted2 },
  distRemainingValue: { fontFamily: FONTS.title, fontSize: 18, color: COLORS.text },

  // Contractor identity
  contractorRow: { flexDirection: 'row', alignItems: 'center', gap: 12, marginBottom: 12 },
  contractorAvatar: { width: 48, height: 48, borderRadius: 24 },
  contractorAvatarPlaceholder: {
    width: 48, height: 48, borderRadius: 24,
    backgroundColor: 'rgba(0,230,118,0.12)', alignItems: 'center', justifyContent: 'center',
  },
  contractorAvatarInitial: { fontFamily: FONTS.bodySemiBold, fontSize: 20, color: COLORS.green },
  contractorName: { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.text, marginBottom: 4 },
  contractorTypeBadge: {
    alignSelf: 'flex-start', backgroundColor: 'rgba(255,255,255,0.06)',
    borderRadius: 8, paddingHorizontal: 8, paddingVertical: 3,
    borderWidth: 1, borderColor: COLORS.border,
  },
  contractorTypeText: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2 },
});

const chip = StyleSheet.create({
  wrap: {
    flexDirection: 'row', alignItems: 'center', gap: 4,
    paddingHorizontal: 8, paddingVertical: 4, borderRadius: RADIUS.full, borderWidth: 1,
  },
  text: { fontFamily: FONTS.bodyMedium, fontSize: 11 },
  green: { backgroundColor: COLORS.greenMuted, borderColor: COLORS.green + '60' },
  red:   { backgroundColor: 'rgba(239,83,80,0.08)', borderColor: 'rgba(239,83,80,0.35)' },
  gray:  { backgroundColor: COLORS.card2, borderColor: COLORS.border },
});
