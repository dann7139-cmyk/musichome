/**
 * ProposeRequestScreen — Grupo llena cotización antes de proponer un evento.
 *
 * Igual al formulario de QuoteDetailScreen pero adaptado para solicitudes
 * abiertas (event_requests). Al enviar, llama a propose_event_request con
 * los precios y guarda la cotización en proposal_data.
 */
import React, { useEffect, useState } from 'react';
import {
  Alert,
  Image,
  KeyboardAvoidingView,
  Platform,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  View,
} from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { ArrowLeft, CheckCircle, Clock, DollarSign, Truck } from 'lucide-react-native';
import { supabase } from '../../config/supabase';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';
import TimePickerModal from '../../components/ui/TimePickerModal';
import { analyzeMessage, PHONE_WARNING } from '../../utils/phoneFilter';
import i18n from '../../i18n';


// ─── Labels ──────────────────────────────────────────────────────────────────
const EVENT_TYPE_LABELS: Record<string, string> = {
  fiesta_privada: '🎉 Fiesta privada',
  boda:           '💍 Boda',
  cumpleanos:     '🎂 Cumpleaños',
  graduacion:     '🎓 Graduación',
  empresarial:    '🏢 Empresarial',
  otro:           '🎵 Otro',
};

const COVERED_LABELS: Record<string, string> = {
  si:    'Sí, está techado',
  no:    'No, al aire libre',
  no_se: 'No sabe',
};

const VENUE_LABELS: Record<string, string> = {
  patio_pequeno:         '🏡 Patio pequeño',
  salon_mediano:         '🏛️ Salón mediano',
  jardin_grande:         '🌳 Jardín grande',
  escenario_profesional: '🎤 Escenario profesional',
};

const SOUND_LABELS: Record<string, string> = {
  si:       'Sí, necesita sonido',
  no:       'No necesita sonido',
  ya_tengo: 'Ya cuenta con sonido',
};

// ─── Helpers ─────────────────────────────────────────────────────────────────
function DetailRow({ label, value }: { label: string; value: string }) {
  return (
    <View style={s.detailRow}>
      <Text style={s.detailLabel}>{label}</Text>
      <Text style={s.detailValue}>{value}</Text>
    </View>
  );
}

function FieldLabel({ children }: { children: string }) {
  return <Text style={s.fieldLabel}>{children}</Text>;
}

// ─── Screen ──────────────────────────────────────────────────────────────────
export default function ProposeRequestScreen({ route, navigation }: any) {
  const { request, dispatchId } = route.params as { request: any; dispatchId?: string };

  // ── Campos del formulario ─────────────────────────────────────────────────
  const [pricePerHour, setPricePerHour] = useState('');
  const [travelCost,   setTravelCost]   = useState('0');
  const [overtime1h,   setOvertime1h]   = useState('');
  const [overtime2h,   setOvertime2h]   = useState('');
  const [overtime3h,   setOvertime3h]   = useState('');
  const [groupNotes,   setGroupNotes]   = useState('');
  const [notesWarn,    setNotesWarn]    = useState(false);
  const [arrivalTime,     setArrivalTime]     = useState('');
  const [startTime,       setStartTime]       = useState('');
  const [showTimePicker,  setShowTimePicker]  = useState(false);
  const [showStartPicker, setShowStartPicker] = useState(false);
  const [memberAmounts, setMemberAmounts] = useState<string[]>([]);
  const [groupMembers, setGroupMembers] = useState<
    { id: string; full_name: string; avatar_url: string | null; isOwner: boolean }[]
  >([]);
  const [loading, setLoading] = useState(false);

  // ── Cargar integrantes del grupo ──────────────────────────────────────────
  useEffect(() => {
    (async () => {
      const { data: { user } } = await supabase.auth.getUser();
      if (!user) return;

      const { data: grp } = await supabase
        .from('groups')
        .select('id, owner_id')
        .eq('owner_id', user.id)
        .single();
      if (!grp) return;

      const [{ data: ownerProfile }, { data: memberships }] = await Promise.all([
        supabase.from('profiles').select('id, full_name, avatar_url').eq('id', grp.owner_id).single(),
        supabase
          .from('job_invitations')
          .select('invited_user_id')
          .eq('group_id', grp.id)
          .eq('status', 'accepted')
          .is('event_id', null),
      ]);

      const memberIds = (memberships ?? []).map((m: any) => m.invited_user_id).filter(Boolean);
      let memberProfiles: any[] = [];
      if (memberIds.length > 0) {
        const { data: profiles } = await supabase
          .from('profiles')
          .select('id, full_name, avatar_url')
          .in('id', memberIds);
        memberProfiles = profiles ?? [];
      }

      const memberList: typeof groupMembers = [];
      if (ownerProfile) memberList.push({ ...ownerProfile, isOwner: true });
      const seenIds = new Set<string>(ownerProfile ? [ownerProfile.id] : []);
      memberProfiles.forEach((p: any) => {
        if (!seenIds.has(p.id)) {
          seenIds.add(p.id);
          memberList.push({ ...p, isOwner: false });
        }
      });
      setGroupMembers(memberList);
      setMemberAmounts(Array.from({ length: Math.max(0, memberList.length - 1) }, () => ''));
    })();
  }, []);

  // ── Cálculos automáticos ──────────────────────────────────────────────────
  const pph        = parseFloat(pricePerHour) || 0;
  const travel     = parseFloat(travelCost)   || 0;
  const hours      = request.hours ?? 3;
  const base       = pph * hours;
  const total      = base + travel;                      // precio base sin multiplier
  const multiplier = Number(request.demand_multiplier ?? 1);
  const adjTotal   = multiplier > 1 ? Math.round(total * multiplier) : total; // precio final
  const hasSurge   = multiplier > 1 && total > 0;
  const surgeExtra = adjTotal - total;

  // El grupo recibe su precio completo (la app añade 15% encima al cliente)
  const earnings = adjTotal;

  const memberTotal = memberAmounts.reduce((sum, v) => sum + (parseFloat(v) || 0), 0);
  const ownerNet    = Math.max(earnings - memberTotal, 0);

  const ot1Val = parseFloat(overtime1h) || 0;
  const ot2Val = parseFloat(overtime2h) || 0;
  const ot3Val = parseFloat(overtime3h) || 0;
  const ot1Pct = null;
  const ot2Pct = null;
  const ot3Pct = null;

  const numAdditional = Math.max(0, groupMembers.length - 1);

  const updateMemberAmount = (idx: number, val: string) => {
    setMemberAmounts(prev => {
      const next = [...prev];
      next[idx] = val.replace(/[^0-9.]/g, '');
      return next;
    });
  };

  // ── Validación ────────────────────────────────────────────────────────────
  const canSend = () =>
    pph > 0 &&
    !!arrivalTime &&
    !notesWarn;

  // ── Enviar propuesta ──────────────────────────────────────────────────────
  const handleSend = async () => {
    if (!canSend()) {
      if (notesWarn) {
        Alert.alert(i18n.t('moderation.title'), i18n.t('moderation.no_contact'));
      } else {
        Alert.alert('Precio requerido', 'Ingresa el precio por hora del servicio.');
      }
      return;
    }

    const memberDistribution = memberAmounts
      .map((amt, i) => ({ integrante: i + 1, amount: parseFloat(amt) || 0 }))
      .filter(m => m.amount > 0);

    if (!arrivalTime) {
      Alert.alert('Hora requerida', 'Indica la hora exacta a la que llegará tu grupo al evento.');
      return;
    }

    const startLine = startTime ? `\nInicio de tocada: ${startTime}` : '';
    Alert.alert(
      'Confirmar propuesta',
      `Total al cliente: $${adjTotal.toLocaleString()} MXN\nGanancia neta: $${earnings.toLocaleString()} MXN\nHora de llegada: ${arrivalTime}${startLine}\n\n¿Enviar tu cotización al cliente?`,
      [
        { text: 'Revisar', style: 'cancel' },
        {
          text: 'Enviar propuesta',
          onPress: async () => {
            setLoading(true);
            const { data, error } = await supabase.rpc('propose_event_request', {
              p_request_id:     request.id,
              p_price_per_hour: pph,
              p_travel_cost:    travel,
              p_overtime_1h:    parseFloat(overtime1h) || null,
              p_overtime_2h:    parseFloat(overtime2h) || null,
              p_overtime_3h:    parseFloat(overtime3h) || null,
              p_notes:          groupNotes.trim() || null,
              p_member_dist:    memberDistribution.length > 0 ? memberDistribution : null,
              p_arrival_time:   arrivalTime,
              p_start_time:     startTime || null,
            });
            setLoading(false);

            if (error || !data?.ok) {
              const code = data?.error ?? error?.message ?? '';
              const msg =
                code === 'not_available'   ? 'Otro grupo ya entró en negociación con este cliente.' :
                code === 'request_expired' ? 'Esta solicitud ya expiró.' :
                code === 'genre_mismatch'  ? 'El género no coincide con tu grupo.' :
                `Error: ${code || 'No se pudo enviar. Inténtalo de nuevo.'}`;
              Alert.alert('No disponible', msg);
            } else {
              if (dispatchId) {
                // Awaited — ensures DB status='quoted' fires Realtime UPDATE
                // on IncomingExpressScreen before we navigate back.
                await supabase.rpc('complete_express_dispatch', { p_dispatch_id: dispatchId });
                // Signal success via params so IncomingExpressScreen shows
                // the cinematic quoted state without waiting for the Realtime round-trip.
                navigation.navigate('IncomingExpress', { dispatchId, quotedSuccess: true });
              } else {
                navigation.goBack();
              }
            }
          },
        },
      ],
    );
  };

  const eventDateStr = new Date(request.event_date + 'T12:00:00').toLocaleDateString('es-MX', {
    weekday: 'long', year: 'numeric', month: 'long', day: 'numeric',
  });

  // ─── Render ──────────────────────────────────────────────────────────────
  return (
    <View style={s.root}>
      <SafeAreaView edges={['top']} style={s.header}>
        <Pressable style={s.backBtn} onPress={() => navigation.goBack()}>
          <ArrowLeft size={20} color={COLORS.text} />
        </Pressable>
        <Text style={s.headerTitle}>Tu cotización</Text>
        <View style={{ width: 40 }} />
      </SafeAreaView>

      <KeyboardAvoidingView style={{ flex: 1 }} behavior={Platform.OS === 'ios' ? 'padding' : undefined}>
        <ScrollView contentContainerStyle={s.scroll} showsVerticalScrollIndicator={false}>

          {/* ── Detalles del evento ─────────────────────────────────────── */}
          <View style={s.section}>
            <Text style={s.sectionTitle}>Detalles del evento</Text>
            <DetailRow label="Tipo"     value={EVENT_TYPE_LABELS[request.event_type] ?? request.event_type} />
            <DetailRow label="Fecha"    value={eventDateStr} />
            {request.event_time ? <DetailRow label="Hora" value={request.event_time} /> : null}
            <DetailRow label="Duración" value={`${hours} hora${hours !== 1 ? 's' : ''}`} />
            {request.guest_count ? <DetailRow label="Personas" value={`~${request.guest_count}`} /> : null}
          </View>

          {/* ── Zona del evento (sin dirección exacta) ─────────────────── */}
          <View style={s.section}>
            <Text style={s.sectionTitle}>Zona del evento</Text>
            <Text style={s.locationCity}>
              📍 {request.location_city}
              {request.location_municipio ? `, ${request.location_municipio}` : ''}, {request.location_estado}
            </Text>
            <Text style={s.locationNote}>
              La dirección exacta se comparte después de confirmar el pago.
            </Text>
          </View>

          {/* ── Condiciones del lugar ───────────────────────────────────── */}
          {(request.venue_covered || request.venue_size || request.needs_sound) ? (
            <View style={s.section}>
              <Text style={s.sectionTitle}>Condiciones del lugar</Text>
              {request.venue_covered ? <DetailRow label="Techado" value={COVERED_LABELS[request.venue_covered] ?? request.venue_covered} /> : null}
              {request.venue_size    ? <DetailRow label="Espacio" value={VENUE_LABELS[request.venue_size]     ?? request.venue_size}     /> : null}
              {request.needs_sound   ? <DetailRow label="Sonido"  value={SOUND_LABELS[request.needs_sound]   ?? request.needs_sound}   /> : null}
            </View>
          ) : null}

          {/* ── Comentarios del cliente ─────────────────────────────────── */}
          {request.comments ? (
            <View style={s.section}>
              <Text style={s.sectionTitle}>Comentarios del cliente</Text>
              <View style={s.commentBox}>
                <Text style={s.commentText}>"{request.comments}"</Text>
              </View>
            </View>
          ) : null}

          {/* ── Tu respuesta ────────────────────────────────────────────── */}
          <View style={s.section}>
            <Text style={s.sectionTitle}>Tu respuesta</Text>

            {/* Precio por hora */}
            <FieldLabel>Precio por hora *</FieldLabel>
            <View style={s.currencyRow}>
              <DollarSign size={16} color={COLORS.muted2} />
              <TextInput
                style={s.currencyInput}
                placeholder="0"
                placeholderTextColor={COLORS.muted}
                value={pricePerHour}
                onChangeText={setPricePerHour}
                keyboardType="numeric"
              />
              <Text style={s.currencyUnit}>/hora</Text>
            </View>
            {pph > 0 && (
              <Text style={s.calcHint}>
                {hours}h × ${pph.toLocaleString()} = ${base.toLocaleString()} MXN
              </Text>
            )}

            {/* Traslado */}
            <FieldLabel>Costo extra por traslado</FieldLabel>
            <View style={s.currencyRow}>
              <Truck size={16} color={COLORS.muted2} />
              <TextInput
                style={s.currencyInput}
                placeholder="0  (0 = sin costo)"
                placeholderTextColor={COLORS.muted}
                value={travelCost}
                onChangeText={setTravelCost}
                keyboardType="numeric"
              />
            </View>

            {/* Distribución entre integrantes */}
            {groupMembers.length > 0 && (
              <>
                <FieldLabel>Distribución de pago</FieldLabel>
                <Text style={s.hint}>Define cuánto recibe cada integrante. El dueño recibe el resto.</Text>
                <View style={s.membersList}>
                  {groupMembers.map((m) => {
                    const isOwnerMember = m.isOwner;
                    const memberIdx = groupMembers.filter(x => !x.isOwner).indexOf(m);
                    return (
                      <View key={m.id} style={s.memberChip}>
                        {m.avatar_url ? (
                          <Image source={{ uri: m.avatar_url }} style={s.memberAvatar} />
                        ) : (
                          <View style={s.memberAvatarFallback}>
                            <Text style={s.memberAvatarInitial}>
                              {m.full_name?.charAt(0)?.toUpperCase() ?? '?'}
                            </Text>
                          </View>
                        )}
                        <View style={{ flex: 1 }}>
                          <Text style={s.memberChipName} numberOfLines={1}>{m.full_name}</Text>
                          {isOwnerMember && <Text style={s.memberChipRole}>Dueño</Text>}
                        </View>
                        {isOwnerMember ? (
                          <View style={s.memberAmountBox}>
                            <Text style={s.memberAmountOwner}>
                              ${earnings > 0 ? ownerNet.toLocaleString() : '—'}
                            </Text>
                            <Text style={s.memberAmountResto}>resto</Text>
                          </View>
                        ) : (
                          <View style={[s.currencyRow, s.memberAmountInput]}>
                            <DollarSign size={13} color={COLORS.muted2} />
                            <TextInput
                              style={[s.currencyInput, { fontSize: 15, paddingVertical: 8 }]}
                              placeholder="0"
                              placeholderTextColor={COLORS.muted}
                              value={memberAmounts[memberIdx] ?? ''}
                              onChangeText={v => updateMemberAmount(memberIdx, v)}
                              keyboardType="numeric"
                            />
                          </View>
                        )}
                      </View>
                    );
                  })}
                </View>
              </>
            )}

            {/* Hora de llegada (requerida) */}
            <FieldLabel>Hora de llegada al evento *</FieldLabel>
            <Pressable
              style={[s.currencyRow, arrivalTime ? s.timeSelected : null]}
              onPress={() => setShowTimePicker(true)}
            >
              <Clock size={16} color={arrivalTime ? COLORS.green : COLORS.muted2} />
              <Text style={[s.currencyInput, { paddingVertical: 14, fontSize: 16, color: arrivalTime ? COLORS.green : COLORS.muted }]}>
                {arrivalTime || 'Seleccionar hora'}
              </Text>
            </Pressable>
            <Text style={[s.hint, { marginTop: -2, marginBottom: 14 }]}>
              Hora en que llegará el grupo para instalarse.
            </Text>

            {/* Hora de inicio de tocada (opcional, para instalación de sonido) */}
            <FieldLabel>Hora de inicio de tocada</FieldLabel>
            <Pressable
              style={[s.currencyRow, startTime ? s.timeSelected : null]}
              onPress={() => setShowStartPicker(true)}
            >
              <Clock size={16} color={startTime ? COLORS.green : COLORS.muted2} />
              <Text style={[s.currencyInput, { paddingVertical: 14, fontSize: 16, color: startTime ? COLORS.green : COLORS.muted }]}>
                {startTime || 'Seleccionar hora (opcional)'}
              </Text>
            </Pressable>
            <Text style={[s.hint, { marginTop: -2, marginBottom: 14 }]}>
              Hora en que comienza la música. El cliente verá este horario si necesitas tiempo para instalar sonido.
            </Text>

            {/* Notas para el cliente */}
            <FieldLabel>Notas para el cliente</FieldLabel>
            <TextInput
              style={s.notesInput}
              placeholder={'Ej: "Incluye sonido" · "No incluye transporte de equipo"'}
              placeholderTextColor={COLORS.muted}
              value={groupNotes}
              onChangeText={v => {
                let clean = v.replace(/[0-9]/g, '');
                const NUM_WORDS = /\b(cero|uno|dos|tres|cuatro|cinco|seis|siete|ocho|nueve)(\s+(cero|uno|dos|tres|cuatro|cinco|seis|siete|ocho|nueve)){2,}/gi;
                clean = clean.replace(NUM_WORDS, '');
                const result = analyzeMessage(clean);
                if (result.blocked) {
                  setNotesWarn(true);
                  supabase.auth.getUser().then(({ data: { user } }) => {
                    if (user) supabase.from('contact_violation_logs').insert({
                      user_id: user.id, sender_role: 'group',
                      attempted_message: clean.slice(0, 200),
                      violation_type: result.type!, detected_pattern: result.pattern ?? null,
                    });
                  });
                } else {
                  setNotesWarn(false);
                }
                setGroupNotes(clean);
              }}
              multiline
              maxLength={300}
              textAlignVertical="top"
            />
            {notesWarn && (
              <View style={s.contactWarnBox}>
                <Text style={s.contactWarnText}>⚠️ {PHONE_WARNING}</Text>
              </View>
            )}

            {/* Resumen financiero */}
            {pph > 0 && (
              <View style={s.priceBreakdown}>
                <Text style={s.breakdownTitle}>Resumen financiero</Text>

                <View style={s.breakdownRow}>
                  <Text style={s.breakdownLabel}>Precio base ({hours}h × ${pph.toLocaleString()})</Text>
                  <Text style={s.breakdownVal}>${base.toLocaleString()}</Text>
                </View>
                {travel > 0 && (
                  <View style={s.breakdownRow}>
                    <Text style={s.breakdownLabel}>Traslado</Text>
                    <Text style={s.breakdownVal}>+${travel.toLocaleString()}</Text>
                  </View>
                )}
                {hasSurge && (
                  <View style={s.surgeRow}>
                    <Text style={s.surgeLabel}>✨ Servicio con respaldo garantizado</Text>
                  </View>
                )}
                <View style={s.earningsCard}>
                  <Text style={s.earningsLabel}>Tu ganancia</Text>
                  <Text style={s.earningsVal}>${earnings.toLocaleString()} MXN</Text>
                </View>

                {numAdditional > 0 && earnings > 0 && (
                  <>
                    <View style={s.divider} />
                    <Text style={[s.breakdownTitle, { marginBottom: 8 }]}>Distribución interna</Text>
                    {memberAmounts.slice(0, numAdditional).map((amt, i) => (
                      <View key={i} style={s.breakdownRow}>
                        <Text style={s.breakdownLabel}>Integrante {i + 1}</Text>
                        <Text style={s.breakdownVal}>${(parseFloat(amt) || 0).toLocaleString()}</Text>
                      </View>
                    ))}
                    <View style={s.breakdownRow}>
                      <Text style={[s.breakdownLabel, { color: COLORS.green }]}>Dueño (resto)</Text>
                      <Text style={[s.breakdownVal, { color: COLORS.green }]}>${ownerNet.toLocaleString()}</Text>
                    </View>
                  </>
                )}
              </View>
            )}
          </View>

          {/* ── Paquetes de horas extra (opcionales) ───────────────────── */}
          <View style={s.section}>
            <Text style={s.sectionTitle}>Paquetes de horas extra</Text>
            <Text style={s.hint}>
              Opcional. Si los llenas, el cliente podrá contratar horas extra desde la app durante el evento.
            </Text>

            <View style={s.overtimeGrid}>
              {/* +1h */}
              <View style={s.overtimeCard}>
                <View style={s.overtimeHeader}>
                  <Clock size={14} color={COLORS.green} />
                  <Text style={s.overtimeLabel}>+1 hora extra</Text>
                </View>
                <View style={s.currencyRow}>
                  <DollarSign size={14} color={COLORS.muted2} />
                  <TextInput
                    style={[s.currencyInput, { fontSize: 16 }]}
                    placeholder="0"
                    placeholderTextColor={COLORS.muted}
                    value={overtime1h}
                    onChangeText={setOvertime1h}
                    keyboardType="numeric"
                  />
                </View>
                {ot1Pct !== null && (
                  <Text style={s.otCommNote}>App: {ot1Pct}% · Tú: ${ot1Val.toLocaleString()}</Text>
                )}
              </View>

              {/* +2h */}
              <View style={s.overtimeCard}>
                <View style={s.overtimeHeader}>
                  <Clock size={14} color={COLORS.green} />
                  <Text style={s.overtimeLabel}>+2 horas extra</Text>
                </View>
                <View style={s.currencyRow}>
                  <DollarSign size={14} color={COLORS.muted2} />
                  <TextInput
                    style={[s.currencyInput, { fontSize: 16 }]}
                    placeholder="0"
                    placeholderTextColor={COLORS.muted}
                    value={overtime2h}
                    onChangeText={setOvertime2h}
                    keyboardType="numeric"
                  />
                </View>
                {ot2Pct !== null && (
                  <Text style={s.otCommNote}>App: {ot2Pct}% · Tú: ${ot2Val.toLocaleString()}</Text>
                )}
              </View>

              {/* +3h */}
              <View style={s.overtimeCard}>
                <View style={s.overtimeHeader}>
                  <Clock size={14} color={COLORS.green} />
                  <Text style={s.overtimeLabel}>+3 horas extra</Text>
                </View>
                <View style={s.currencyRow}>
                  <DollarSign size={14} color={COLORS.muted2} />
                  <TextInput
                    style={[s.currencyInput, { fontSize: 16 }]}
                    placeholder="0"
                    placeholderTextColor={COLORS.muted}
                    value={overtime3h}
                    onChangeText={setOvertime3h}
                    keyboardType="numeric"
                  />
                </View>
                {ot3Pct !== null && (
                  <Text style={s.otCommNote}>App: {ot3Pct}% · Tú: ${ot3Val.toLocaleString()}</Text>
                )}
              </View>
            </View>

          </View>

          {/* ── Botón enviar ────────────────────────────────────────────── */}
          <Pressable
            style={[s.sendBtn, (!canSend() || loading) && s.sendBtnDisabled]}
            onPress={handleSend}
            disabled={!canSend() || loading}
          >
            <CheckCircle size={18} color={canSend() ? COLORS.bg : COLORS.muted} />
            <Text style={[s.sendBtnText, !canSend() && { color: COLORS.muted }]}>
              {loading ? 'Enviando...' : 'Enviar propuesta al cliente'}
            </Text>
          </Pressable>

          <View style={{ height: 40 }} />
        </ScrollView>
      </KeyboardAvoidingView>

      <TimePickerModal
        visible={showTimePicker}
        value={arrivalTime || '18:00'}
        onConfirm={(t) => { setArrivalTime(t); setShowTimePicker(false); }}
        onClose={() => setShowTimePicker(false)}
      />
      <TimePickerModal
        visible={showStartPicker}
        value={startTime || arrivalTime || '19:00'}
        onConfirm={(t) => { setStartTime(t); setShowStartPicker(false); }}
        onClose={() => setShowStartPicker(false)}
      />
    </View>
  );
}

// ─── Styles ──────────────────────────────────────────────────────────────────
const s = StyleSheet.create({
  root: { flex: 1, backgroundColor: COLORS.bg },

  header: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between',
    paddingHorizontal: SPACING.xl, paddingVertical: 12,
    borderBottomWidth: 1, borderBottomColor: COLORS.border,
  },
  backBtn: {
    width: 40, height: 40, borderRadius: 12,
    backgroundColor: COLORS.card, borderWidth: 1, borderColor: COLORS.border,
    alignItems: 'center', justifyContent: 'center',
  },
  headerTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 17, color: COLORS.text },

  scroll: { padding: SPACING.xl },

  section: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.xl,
    borderWidth: 1, borderColor: COLORS.border,
    padding: SPACING.lg, marginBottom: 16,
  },
  sectionTitle: {
    fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.muted2,
    textTransform: 'uppercase', letterSpacing: 0.8, marginBottom: 14,
  },

  detailRow:   { flexDirection: 'row', justifyContent: 'space-between', paddingVertical: 7, borderBottomWidth: 1, borderBottomColor: COLORS.border },
  detailLabel: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted2 },
  detailValue: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.text, flex: 1, textAlign: 'right' },

  locationCity: { fontFamily: FONTS.bodyMedium, fontSize: 14, color: COLORS.text, marginBottom: 6 },
  locationNote: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, lineHeight: 18 },

  commentBox: {
    backgroundColor: COLORS.card2, borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: COLORS.border, padding: 12,
  },
  commentText: { fontFamily: FONTS.body, fontSize: 14, color: COLORS.text, lineHeight: 22, fontStyle: 'italic' },

  budgetBanner: {
    backgroundColor: 'rgba(0,230,118,0.06)', borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.25)',
    padding: 12, marginBottom: 16,
  },
  budgetText: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.green, lineHeight: 19 },

  fieldLabel: {
    fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted2,
    marginBottom: 8, marginTop: 14,
  },
  hint: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, lineHeight: 18, marginBottom: 12 },

  currencyRow: {
    flexDirection: 'row', alignItems: 'center', gap: 10,
    backgroundColor: COLORS.bg, borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: COLORS.border,
    paddingHorizontal: 14, marginBottom: 4,
  },
  currencyInput: {
    flex: 1, paddingVertical: 13,
    fontFamily: FONTS.bodySemiBold, fontSize: 18, color: COLORS.text,
  },
  currencyUnit: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2 },
  calcHint: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.green, marginBottom: 4, marginTop: 2 },

  membersList: { gap: 8, marginBottom: 12, marginTop: 8 },
  memberChip: {
    flexDirection: 'row', alignItems: 'center', gap: 10,
    backgroundColor: COLORS.bg, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border,
    paddingHorizontal: 12, paddingVertical: 8,
  },
  memberAvatar:         { width: 36, height: 36, borderRadius: 18 },
  memberAvatarFallback: {
    width: 36, height: 36, borderRadius: 18,
    backgroundColor: COLORS.card2, borderWidth: 1, borderColor: COLORS.border,
    alignItems: 'center', justifyContent: 'center',
  },
  memberAvatarInitial: { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.green },
  memberChipName:      { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.text },
  memberChipRole:      { fontFamily: FONTS.body, fontSize: 11, color: COLORS.green, marginTop: 1 },
  memberAmountBox:     { alignItems: 'flex-end' },
  memberAmountOwner:   { fontFamily: FONTS.title, fontSize: 16, color: COLORS.green },
  memberAmountResto:   { fontFamily: FONTS.body, fontSize: 10, color: COLORS.muted2 },
  memberAmountInput:   { flex: 0, width: 110, marginBottom: 0 },

  notesInput: {
    backgroundColor: COLORS.bg, borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: COLORS.border,
    paddingHorizontal: 14, paddingVertical: 13,
    fontFamily: FONTS.body, fontSize: 14, color: COLORS.text,
    minHeight: 80, marginBottom: 4,
  },

  priceBreakdown: {
    backgroundColor: COLORS.bg, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border,
    padding: 16, marginTop: 16,
  },
  breakdownTitle:      { fontFamily: FONTS.bodySemiBold, fontSize: 12, color: COLORS.muted2, textTransform: 'uppercase', letterSpacing: 0.8, marginBottom: 12 },
  breakdownRow:        { flexDirection: 'row', justifyContent: 'space-between', paddingVertical: 5 },
  breakdownLabel:      { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2, flex: 1, paddingRight: 8 },
  breakdownVal:        { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.text },
  breakdownTotal:      { paddingTop: 8, marginTop: 4, borderTopWidth: 1, borderTopColor: COLORS.border },
  breakdownTotalLabel: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.text },
  breakdownTotalVal:   { fontFamily: FONTS.bodySemiBold, fontSize: 17, color: COLORS.text },
  divider:             { height: 1, backgroundColor: COLORS.border, marginVertical: 10 },
  commNote:            { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted, marginTop: 12, textAlign: 'center' },
  earningsCard: {
    flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center',
    backgroundColor: 'rgba(0,230,118,0.07)', borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.25)',
    paddingHorizontal: 12, paddingVertical: 9, marginTop: 4,
  },
  earningsLabel: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.green },
  earningsVal:   { fontFamily: FONTS.bodySemiBold, fontSize: 16, color: COLORS.green },
  lowPriceWarning:     { backgroundColor: 'rgba(255,152,0,0.1)', borderRadius: RADIUS.md, borderWidth: 1, borderColor: 'rgba(255,152,0,0.5)', padding: 10, marginTop: 10 },
  lowPriceWarningText: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: 'rgba(255,152,0,1)', lineHeight: 18 },

  overtimeGrid:   { gap: 10 },
  overtimeCard: {
    backgroundColor: COLORS.bg, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border, padding: 12,
  },
  overtimeHeader: { flexDirection: 'row', alignItems: 'center', gap: 6, marginBottom: 8 },
  overtimeLabel:  { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.text, flex: 1 },
  reqDot:         { fontFamily: FONTS.bodySemiBold, fontSize: 16, color: COLORS.red },
  otCommNote:     { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted2, marginTop: 4 },
  requiredNote: {
    marginTop: 10, padding: 10, borderRadius: RADIUS.md,
    backgroundColor: 'rgba(255,152,0,0.08)', borderWidth: 1, borderColor: 'rgba(255,152,0,0.4)',
  },
  requiredNoteText: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: 'rgba(255,152,0,1)' },

  timeSelected: {
    borderColor: COLORS.green,
    backgroundColor: 'rgba(0,230,118,0.06)',
  },

  sendBtn: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 10,
    paddingVertical: 17, borderRadius: RADIUS.lg,
    backgroundColor: COLORS.green, marginTop: 8,
  },
  sendBtnDisabled: { backgroundColor: COLORS.card, borderWidth: 1, borderColor: COLORS.border },
  sendBtnText:     { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.bg },

  surgeRow: {
    paddingVertical: 7, paddingHorizontal: 12,
    backgroundColor: 'rgba(0,230,118,0.07)',
    borderRadius: RADIUS.md, marginBottom: 6,
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.20)',
  },
  surgeLabel: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.green },
  surgeVal:   { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.green },

  contactWarnBox: {
    backgroundColor: 'rgba(255,179,0,0.10)',
    borderRadius: RADIUS.md, borderWidth: 1, borderColor: 'rgba(255,179,0,0.35)',
    paddingHorizontal: 12, paddingVertical: 9, marginTop: 6,
  },
  contactWarnText: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: '#FFB300', lineHeight: 17 },
});
