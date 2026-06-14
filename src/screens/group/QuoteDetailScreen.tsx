/**
 * GroupQuoteDetailScreen — El grupo responde una solicitud de cotización.
 * • Comisión: $150 MXN fijos por hora. El grupo NO la puede editar.
 * • Precio/hora → total calculado automáticamente.
 * • Los 3 paquetes de horas extra son OBLIGATORIOS para enviar.
 * • Distribución entre integrantes visible solo para el grupo.
 */
import React, { useEffect, useState } from 'react';
import {
  Alert,
  Image,
  KeyboardAvoidingView,
  Linking,
  Platform,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  View,
} from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import {
  ArrowLeft, CheckCircle, XCircle,
  DollarSign, Truck, Clock, MapPin,
} from 'lucide-react-native';
import { supabase } from '../../config/supabase';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';
import { analyzeMessage, PHONE_WARNING } from '../../utils/phoneFilter';
import { containsBlockedContact } from '../../utils/contentModeration';
import i18n from '../../i18n';

// ─── Comisión de plataforma: 10% sobre el precio del grupo ───────────────────
const PLATFORM_FEE_RATE = 0.10;

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

export default function GroupQuoteDetailScreen({ route, navigation }: any) {
  const { quote: initialQuote } = route.params as { quote: any };
  const [quote, setQuote] = useState(initialQuote);

  // ── Estado de respuesta ─────────────────────────────────────────────────
  const [pricePerHour,   setPricePerHour]   = useState(quote.price_per_hour?.toString() ?? '');
  const [travelCost,     setTravelCost]     = useState(quote.travel_cost?.toString() ?? '0');
  const [overtime1h,     setOvertime1h]     = useState(quote.overtime_1h_price?.toString() ?? '');
  const [overtime2h,     setOvertime2h]     = useState(quote.overtime_2h_price?.toString() ?? '');
  const [overtime3h,     setOvertime3h]     = useState(quote.overtime_3h_price?.toString() ?? '');
  const [groupNotes,     setGroupNotes]     = useState(quote.group_notes ?? '');
  const [notesWarn,      setNotesWarn]      = useState(false);
  const [numIntegrantes, setNumIntegrantes] = useState(
    quote.num_integrantes?.toString() ?? '1',
  );
  // Distribución: array de montos por integrante
  const [memberAmounts, setMemberAmounts] = useState<string[]>(() => {
    if (quote.member_distribution?.length) {
      return (quote.member_distribution as any[]).map((m: any) => m.amount?.toString() ?? '');
    }
    return [''];
  });
  const [loading, setLoading] = useState(false);
  const [isOwner, setIsOwner] = useState<boolean | null>(null);
  const [groupMembers, setGroupMembers] = useState<{ id: string; full_name: string; avatar_url: string | null; isOwner: boolean }[]>([]);


  useEffect(() => {
    supabase.auth.getUser().then(async ({ data }) => {
      if (!data.user) return;
      const { data: grp } = await supabase
        .from('groups').select('owner_id').eq('id', quote.group_id).single();
      const ownerIsCurrentUser = grp?.owner_id === data.user.id;
      setIsOwner(ownerIsCurrentUser);

      // 1. Obtener IDs de integrantes
      const [{ data: ownerProfile }, { data: memberships }] = await Promise.all([
        supabase.from('profiles').select('id, full_name, avatar_url').eq('id', grp?.owner_id).single(),
        supabase
          .from('job_invitations')
          .select('invited_user_id')
          .eq('group_id', quote.group_id)
          .eq('status', 'accepted')
          .is('event_id', null),
      ]);

      // 2. Obtener perfiles de integrantes por sus IDs
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

      // Pre-llenar num_integrantes si aún no fue respondida la cotización
      if (quote.status === 'pending' && !quote.num_integrantes) {
        const total = memberList.length || 1;
        setNumIntegrantes(String(total));
        setMemberAmounts(Array.from({ length: Math.max(0, total - 1) }, () => ''));
      }

    });
  }, []);

  const isReadOnly = quote.status !== 'pending';

  // ── Cálculos automáticos ───────────────────────────────────────────────
  const pph      = parseFloat(pricePerHour) || 0;
  const travel   = parseFloat(travelCost) || 0;
  const hours    = quote.duration_hours ?? 3;
  const base     = pph * hours;
  // total = precio NETO del grupo (lo que recibirán)
  const total    = base + travel;
  // contadoPublico = precio al cliente = total / (1 - 10%)
  const contadoPublico = total > 0 ? Math.round(total / (1 - PLATFORM_FEE_RATE)) : 0;
  // commission = lo que toma la plataforma (diferencia entre precio público y neto del grupo)
  const commission = contadoPublico - total;
  const commPct    = (PLATFORM_FEE_RATE * 100).toFixed(0);
  // earnings = grupo siempre recibe exactamente lo que escribió
  const earnings   = total;

  // Distribución: cuánto gana el dueño (lo que queda del neto del grupo)
  const memberTotal = memberAmounts.reduce((sum, v) => sum + (parseFloat(v) || 0), 0);
  const ownerNet    = Math.max(earnings - memberTotal, 0);

  const priceTooLow = false;

  // Horas extra: grupo escribe su precio NETO; se calcula precio público al cliente
  const ot1Val  = parseFloat(overtime1h) || 0;
  const ot2Val  = parseFloat(overtime2h) || 0;
  const ot3Val  = parseFloat(overtime3h) || 0;
  // Precios cliente para horas extra (lo que verá y pagará el cliente)
  const ot1ClientPrice = ot1Val > 0 ? Math.round(ot1Val / (1 - PLATFORM_FEE_RATE)) : 0;
  const ot2ClientPrice = ot2Val > 0 ? Math.round(ot2Val / (1 - PLATFORM_FEE_RATE)) : 0;
  const ot3ClientPrice = ot3Val > 0 ? Math.round(ot3Val / (1 - PLATFORM_FEE_RATE)) : 0;

  const openInMaps = () => {
    const addr = encodeURIComponent(
      `${quote.event_address}, ${quote.event_municipio}, ${quote.event_estado}, México`
    );
    Linking.openURL(`https://maps.google.com/maps?q=${addr}`);
  };

  const updateMemberAmount = (idx: number, val: string) => {
    setMemberAmounts(prev => {
      const next = [...prev];
      next[idx] = val.replace(/[^0-9.]/g, '');
      return next;
    });
  };

  const autoDistributeEqual = () => {
    if (numAdditional <= 0 || earnings <= 0) return;
    const perMember = Math.floor(earnings / numIntegrantesNum);
    setMemberAmounts(Array.from({ length: numAdditional }, () => String(perMember)));
  };

  // ── Validación antes de enviar ─────────────────────────────────────────
  const canSend = () =>
    pph > 0 &&
    !priceTooLow &&
    parseFloat(overtime1h) > 0 &&
    parseFloat(overtime2h) > 0 &&
    parseFloat(overtime3h) > 0;

  // ── Enviar cotización ─────────────────────────────────────────────────
  const handleSendQuote = async () => {
    if (notesWarn || containsBlockedContact(groupNotes)) {
      Alert.alert(i18n.t('moderation.title'), i18n.t('moderation.no_contact'));
      return;
    }
    if (!canSend()) {
      if (priceTooLow) {
        Alert.alert('Precio insuficiente', `El precio no cubre la comisión de $${commission.toLocaleString()}.`);
      } else if (!parseFloat(overtime1h) || !parseFloat(overtime2h) || !parseFloat(overtime3h)) {
        Alert.alert('Paquetes requeridos', 'Debes llenar el precio de los 3 paquetes de horas extra para continuar.');
      } else {
        Alert.alert('Precio requerido', 'Ingresa el precio por hora del servicio.');
      }
      return;
    }

    const memberDistribution = memberAmounts
      .map((amt, i) => ({ integrante: i + 1, amount: parseFloat(amt) || 0 }))
      .filter(m => m.amount > 0);

    Alert.alert(
      'Confirmar cotización',
      `Tu precio neto: $${total.toLocaleString()}\nTotal al cliente (contado): $${contadoPublico.toLocaleString()}\nTu ganancia garantizada: $${total.toLocaleString()}\n\n¿Enviar esta cotización?`,
      [
        { text: 'Cancelar', style: 'cancel' },
        {
          text: 'Enviar',
          onPress: async () => {
            setLoading(true);
            const { error } = await supabase
              .from('quotes')
              .update({
                status:              'quoted',
                price_per_hour:      pph,
                base_price:          base,
                travel_cost:         travel,
                commission_amount:   commission,
                commission_pct:      parseFloat(commPct),
                total_amount:        contadoPublico,    // precio público al cliente (contado)
                group_earnings:      total,             // neto del grupo (lo que escribieron)
                overtime_1h_price:   ot1ClientPrice,    // precio al cliente por 1h extra
                overtime_2h_price:   ot2ClientPrice,    // precio al cliente por 2h extra
                overtime_3h_price:   ot3ClientPrice,    // precio al cliente por 3h extra
                num_integrantes:     parseInt(numIntegrantes),
                member_distribution: memberDistribution,
                group_notes:         groupNotes.trim() || null,
              })
              .eq('id', quote.id);

            if (!error) {
              // Notificar al cliente
              await supabase.from('notifications').insert({
                user_id: quote.client_id,
                type:    'quote_received',
                title:   '📋 Recibiste una cotización',
                body:    `${quote.group?.name ?? 'El grupo'} respondió tu solicitud. Total: $${contadoPublico.toLocaleString()} MXN. Toca para aceptar o cancelar.`,
                data:    { quote_id: quote.id },
              });

              // Notificar a los integrantes del grupo
              const { data: members } = await supabase
                .from('job_invitations')
                .select('invited_user_id')
                .eq('group_id', quote.group_id)
                .eq('status', 'accepted')
                .is('event_id', null);

              if (members && members.length > 0) {
                await supabase.from('notifications').insert(
                  members.map((m: any) => ({
                    user_id: m.invited_user_id,
                    type:    'quote_sent_to_client',
                    title:   '📋 Cotización enviada al cliente',
                    body:    `El dueño envió la cotización. Tu ganancia neta: $${total.toLocaleString()} MXN. Toca para ver tu distribución.`,
                    data:    { quote_id: quote.id },
                  }))
                );
              }
            }

            setLoading(false);
            if (error) {
              Alert.alert('Error', 'No se pudo enviar la cotización.');
            } else {
              setQuote((prev: any) => ({ ...prev, status: 'quoted', total_amount: contadoPublico }));
              Alert.alert(
                '✅ Cotización enviada',
                'El cliente recibirá una notificación con tu propuesta.',
                [{ text: 'OK', onPress: () => navigation.goBack() }],
              );
            }
          },
        },
      ],
    );
  };

  // ── Rechazar solicitud ────────────────────────────────────────────────
  const handleDecline = async () => {
    Alert.alert(
      'Rechazar solicitud',
      '¿Estás seguro de que quieres rechazar esta cotización?',
      [
        { text: 'Cancelar', style: 'cancel' },
        {
          text: 'Rechazar',
          style: 'destructive',
          onPress: async () => {
            setLoading(true);
            await supabase.from('quotes').update({ status: 'rejected' }).eq('id', quote.id);
            setLoading(false);
            navigation.goBack();
          },
        },
      ],
    );
  };

  const eventDateStr = new Date(quote.event_date + 'T12:00:00').toLocaleDateString('es-MX', {
    weekday: 'long', year: 'numeric', month: 'long', day: 'numeric',
  });

  const durationLabel = `${hours} hora${hours !== 1 ? 's' : ''}`;
  const numIntegrantesNum = parseInt(numIntegrantes) || 1;
  // Número de integrantes adicionales (excluyendo al dueño)
  const numAdditional = Math.max(0, numIntegrantesNum - 1);

  return (
    <View style={s.root}>
      <SafeAreaView edges={['top']} style={s.header}>
        <Pressable style={s.backBtn} onPress={() => navigation.goBack()}>
          <ArrowLeft size={20} color={COLORS.text} />
        </Pressable>
        <Text style={[s.headerTitle, { flex: 1 }]}>Solicitud de cotización</Text>
      </SafeAreaView>

      <KeyboardAvoidingView style={{ flex: 1 }} behavior={Platform.OS === 'ios' ? 'padding' : undefined}>
        <ScrollView contentContainerStyle={s.scroll} showsVerticalScrollIndicator={false}>

          {/* ── Banner solo para integrantes (no dueño) ──────── */}
          {isOwner === false && (
            <View style={s.memberBanner}>
              <Text style={s.memberBannerText}>
                👑 Solo el dueño del grupo puede enviar el precio al cliente.
                Puedes ver los detalles de la solicitud.
              </Text>
            </View>
          )}

          {/* ── Cliente ─────────────────────────────────────────── */}
          <View style={s.clientCard}>
            <Text style={s.clientEmoji}>👤</Text>
            <View>
              <Text style={s.clientName}>{quote.client?.full_name ?? 'Cliente'}</Text>
              <Text style={s.clientSub}>
                {new Date(quote.created_at).toLocaleDateString('es-MX', { day: 'numeric', month: 'long', year: 'numeric' })}
              </Text>
            </View>
          </View>

          {/* ── DATOS DEL EVENTO ──────────────────────────────────── */}
          <View style={s.section}>
            <Text style={s.sectionTitle}>Detalles del evento</Text>
            <DetailRow label="Tipo"      value={EVENT_TYPE_LABELS[quote.event_type] ?? quote.event_type} />
            <DetailRow label="Fecha"     value={eventDateStr} />
            <DetailRow label="Hora"      value={quote.event_time} />
            <DetailRow label="Duración"  value={durationLabel} />
            {quote.num_personas ? (
              <DetailRow label="Personas" value={`~${quote.num_personas}`} />
            ) : null}
          </View>

          {/* ── UBICACIÓN ─────────────────────────────────────────── */}
          <View style={s.section}>
            <Text style={s.sectionTitle}>Ubicación</Text>
            <Pressable style={s.locationBlock} onPress={openInMaps}>
              <View style={{ flex: 1 }}>
                <Text style={s.locationAddr}>{quote.event_address}</Text>
                <Text style={s.locationCity}>{quote.event_municipio}, {quote.event_estado}</Text>
              </View>
              <View style={s.mapsBtn}>
                <MapPin size={14} color={COLORS.green} />
                <Text style={s.mapsBtnText}>Maps</Text>
              </View>
            </Pressable>
          </View>

          {/* ── CONDICIONES ───────────────────────────────────────── */}
          <View style={s.section}>
            <Text style={s.sectionTitle}>Condiciones del lugar</Text>
            <DetailRow label="Techado" value={COVERED_LABELS[quote.venue_covered] ?? quote.venue_covered} />
            <DetailRow label="Espacio" value={VENUE_LABELS[quote.venue_size]  ?? quote.venue_size} />
            <DetailRow label="Sonido"  value={SOUND_LABELS[quote.needs_sound] ?? quote.needs_sound} />
          </View>

          {/* Comentarios */}
          {quote.comments ? (
            <View style={s.section}>
              <Text style={s.sectionTitle}>Comentarios del cliente</Text>
              <View style={s.commentBox}>
                <Text style={s.commentText}>"{quote.comments}"</Text>
              </View>
            </View>
          ) : null}

          {/* ── RESPUESTA DEL GRUPO ───────────────────────────────── */}
          <View style={s.section}>
            <Text style={s.sectionTitle}>
              {isReadOnly ? 'Tu cotización enviada' : 'Tu respuesta'}
            </Text>


            {/* Precio por hora */}
            <FieldLabel>Tu precio neto por hora (lo que recibirás) *</FieldLabel>
            <View style={s.currencyRow}>
              <DollarSign size={16} color={COLORS.muted2} />
              <TextInput
                style={s.currencyInput}
                placeholder="0"
                placeholderTextColor={COLORS.muted}
                value={pricePerHour}
                onChangeText={setPricePerHour}
                keyboardType="numeric"
                editable={!isReadOnly}
              />
              <Text style={s.currencyUnit}>/hora</Text>
            </View>
            {pph > 0 && (
              <Text style={s.calcHint}>
                {hours}h × ${pph.toLocaleString()} = ${base.toLocaleString()} MXN (tu precio neto)
              </Text>
            )}

            {/* Costo de traslado */}
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
                editable={!isReadOnly}
              />
            </View>

            {/* Distribución de pago */}
            <FieldLabel>Distribución de pago</FieldLabel>
            {!isReadOnly && (
              <>
                <Text style={s.hint}>Define cuánto recibe cada integrante. El dueño recibe el resto.</Text>
                {numAdditional > 0 && earnings > 0 && (
                  <Pressable style={s.autoSplitBtn} onPress={autoDistributeEqual}>
                    <Text style={s.autoSplitBtnText}>⚖️ Igualar partes</Text>
                  </Pressable>
                )}
              </>
            )}
            <View style={s.membersList}>
              {groupMembers.map((m) => {
                const isOwnerMember = m.isOwner;
                // El dueño va primero y recibe el resto automáticamente
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
                          editable={!isReadOnly}
                        />
                      </View>
                    )}
                  </View>
                );
              })}
              {/* Fallback si aún no cargaron los miembros */}
              {groupMembers.length === 0 && numAdditional > 0 && Array.from({ length: numAdditional }).map((_, i) => (
                <View key={i} style={s.memberChip}>
                  <View style={s.memberAvatarFallback}>
                    <Text style={s.memberAvatarInitial}>{i + 1}</Text>
                  </View>
                  <Text style={[s.memberChipName, { flex: 1 }]}>Integrante {i + 1}</Text>
                  <View style={[s.currencyRow, s.memberAmountInput]}>
                    <DollarSign size={13} color={COLORS.muted2} />
                    <TextInput
                      style={[s.currencyInput, { fontSize: 15, paddingVertical: 8 }]}
                      placeholder="0"
                      placeholderTextColor={COLORS.muted}
                      value={memberAmounts[i] ?? ''}
                      onChangeText={v => updateMemberAmount(i, v)}
                      keyboardType="numeric"
                      editable={!isReadOnly}
                    />
                  </View>
                </View>
              ))}
            </View>

            {/* Notas del grupo */}
            <FieldLabel>Notas para el cliente</FieldLabel>
            <TextInput
              style={s.notesInput}
              placeholder={'Ej: "Incluye sonido" · "No incluye transporte de equipo"'}
              placeholderTextColor={COLORS.muted}
              value={groupNotes}
              onChangeText={v => { setGroupNotes(v); setNotesWarn(containsBlockedContact(v)); }}
              multiline
              maxLength={300}
              editable={!isReadOnly}
              textAlignVertical="top"
            />

            {/* ── Resumen financiero ─────────────────────────── */}
            {pph > 0 && (
              <View style={s.priceBreakdown}>
                <Text style={s.breakdownTitle}>Resumen de tu cotización</Text>

                <View style={s.breakdownRow}>
                  <Text style={s.breakdownLabel}>Tu precio base ({hours}h × ${pph.toLocaleString()})</Text>
                  <Text style={s.breakdownVal}>${base.toLocaleString()}</Text>
                </View>
                {travel > 0 && (
                  <View style={s.breakdownRow}>
                    <Text style={s.breakdownLabel}>Traslado</Text>
                    <Text style={s.breakdownVal}>+${travel.toLocaleString()}</Text>
                  </View>
                )}
                <View style={[s.breakdownRow, s.breakdownTotal]}>
                  <Text style={s.breakdownTotalLabel}>Tu precio neto</Text>
                  <Text style={s.breakdownTotalVal}>${total.toLocaleString()}</Text>
                </View>

                <View style={s.divider} />

                <View style={s.breakdownRow}>
                  <Text style={s.breakdownLabel}>
                    {`Tarifa de servicio (${commPct}%)`}
                  </Text>
                  <Text style={[s.breakdownVal, { color: COLORS.muted2 }]}>
                    +${commission.toLocaleString()}
                  </Text>
                </View>
                <View style={s.breakdownRow}>
                  <Text style={s.breakdownLabel}>Precio al cliente (contado)</Text>
                  <Text style={[s.breakdownVal, { color: COLORS.green }]}>${contadoPublico.toLocaleString()}</Text>
                </View>
                <View style={s.earningsCard}>
                  <Text style={s.earningsLabel}>Tu ganancia garantizada</Text>
                  <Text style={s.earningsVal}>${earnings.toLocaleString()} MXN</Text>
                </View>

                {/* Distribución entre integrantes */}
                {numAdditional > 0 && earnings > 0 && (
                  <>
                    <View style={s.divider} />
                    <Text style={[s.breakdownTitle, { marginBottom: 8 }]}>Distribución interna</Text>
                    {memberAmounts.slice(0, numAdditional).map((amt, i) => {
                      const a = parseFloat(amt) || 0;
                      return (
                        <View key={i} style={s.breakdownRow}>
                          <Text style={s.breakdownLabel}>Integrante {i + 1}</Text>
                          <Text style={s.breakdownVal}>${a.toLocaleString()}</Text>
                        </View>
                      );
                    })}
                    <View style={s.breakdownRow}>
                      <Text style={[s.breakdownLabel, { color: COLORS.green }]}>Dueño (resto)</Text>
                      <Text style={[s.breakdownVal, { color: COLORS.green }]}>${ownerNet.toLocaleString()}</Text>
                    </View>
                  </>
                )}

                <Text style={s.commNote}>
                  {`Tu precio al público será de $${contadoPublico.toLocaleString()}. Este monto incluye la comisión de la plataforma y los costos de procesamiento de pago, garantizando que recibas íntegramente lo que estableciste. Tu pago se depositará directamente a tu cuenta una vez confirmada la contratación.`}
                </Text>
              </View>
            )}
          </View>

          {/* ── PAQUETES DE HORAS EXTRA (obligatorio) ─────────────── */}
          <View style={s.section}>
            <Text style={s.sectionTitle}>Paquetes de horas extra *</Text>
            <Text style={s.hint}>
              Obligatorio. El cliente podrá contratar horas extra desde la app durante el evento.
            </Text>

            <View style={s.overtimeGrid}>
              {/* 1 hora extra */}
              <View style={s.overtimeCard}>
                <View style={s.overtimeHeader}>
                  <Clock size={14} color={COLORS.green} />
                  <Text style={s.overtimeLabel}>+1 hora extra</Text>
                  {!isReadOnly && !overtime1h && <Text style={s.reqDot}>*</Text>}
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
                    editable={!isReadOnly}
                  />
                </View>
                {ot1Val > 0 && (
                  <Text style={s.otCommNote}>Tú recibirás: ${ot1Val.toLocaleString()} · Cliente pagará: ${ot1ClientPrice.toLocaleString()}</Text>
                )}
              </View>

              {/* 2 horas extra */}
              <View style={s.overtimeCard}>
                <View style={s.overtimeHeader}>
                  <Clock size={14} color={COLORS.green} />
                  <Text style={s.overtimeLabel}>+2 horas extra</Text>
                  {!isReadOnly && !overtime2h && <Text style={s.reqDot}>*</Text>}
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
                    editable={!isReadOnly}
                  />
                </View>
                {ot2Val > 0 && (
                  <Text style={s.otCommNote}>Tú recibirás: ${ot2Val.toLocaleString()} · Cliente pagará: ${ot2ClientPrice.toLocaleString()}</Text>
                )}
              </View>

              {/* 3 horas extra */}
              <View style={s.overtimeCard}>
                <View style={s.overtimeHeader}>
                  <Clock size={14} color={COLORS.green} />
                  <Text style={s.overtimeLabel}>+3 horas extra</Text>
                  {!isReadOnly && !overtime3h && <Text style={s.reqDot}>*</Text>}
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
                    editable={!isReadOnly}
                  />
                </View>
                {ot3Val > 0 && (
                  <Text style={s.otCommNote}>Tú recibirás: ${ot3Val.toLocaleString()} · Cliente pagará: ${ot3ClientPrice.toLocaleString()}</Text>
                )}
              </View>
            </View>

            {!isReadOnly && (!overtime1h || !overtime2h || !overtime3h) && (
              <View style={s.requiredNote}>
                <Text style={s.requiredNoteText}>
                  ⚠️ Debes llenar los 3 paquetes para poder enviar la cotización.
                </Text>
              </View>
            )}
          </View>

          {/* ── ACCIONES ──────────────────────────────────────────── */}
          {!isReadOnly && (
            <View style={s.actions}>
              <Pressable style={s.declineBtn} onPress={handleDecline} disabled={loading}>
                <XCircle size={18} color={COLORS.red} />
                <Text style={s.declineBtnText}>Rechazar</Text>
              </Pressable>
              <Pressable
                style={[s.sendBtn, (!canSend() || loading) && s.sendBtnDisabled]}
                onPress={handleSendQuote}
                disabled={!canSend() || loading}
              >
                <CheckCircle size={18} color={canSend() ? COLORS.bg : COLORS.muted} />
                <Text style={[s.sendBtnText, !canSend() && { color: COLORS.muted }]}>
                  {loading ? 'Enviando...' : 'Enviar cotización'}
                </Text>
              </Pressable>
            </View>
          )}

          {/* Banners de estado */}
          {isReadOnly && quote.status === 'quoted' && (
            <View style={s.quotedBanner}>
              <CheckCircle size={16} color={COLORS.blue} />
              <Text style={s.quotedBannerText}>Cotización enviada — esperando respuesta del cliente</Text>
            </View>
          )}
          {isReadOnly && quote.status === 'accepted' && (
            <View style={[s.quotedBanner, { borderColor: 'rgba(0,230,118,0.4)', backgroundColor: 'rgba(0,230,118,0.08)' }]}>
              <CheckCircle size={16} color={COLORS.green} />
              <Text style={[s.quotedBannerText, { color: COLORS.green }]}>El cliente aceptó tu cotización ✅</Text>
            </View>
          )}
          {isReadOnly && quote.status === 'rejected' && (
            <View style={[s.quotedBanner, { borderColor: 'rgba(239,83,80,0.4)', backgroundColor: 'rgba(239,83,80,0.08)' }]}>
              <XCircle size={16} color={COLORS.red} />
              <Text style={[s.quotedBannerText, { color: COLORS.red }]}>Esta solicitud fue rechazada</Text>
            </View>
          )}

          <View style={{ height: 40 }} />
        </ScrollView>
      </KeyboardAvoidingView>
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

  scroll: { padding: SPACING.xl },

  clientCard: {
    flexDirection: 'row', alignItems: 'center', gap: 14,
    backgroundColor: COLORS.card, borderRadius: RADIUS.xl,
    borderWidth: 1, borderColor: COLORS.border,
    padding: SPACING.lg, marginBottom: 20,
  },
  clientEmoji: { fontSize: 32 },
  clientName:  { fontFamily: FONTS.title, fontSize: 20, color: COLORS.text },
  clientSub:   { fontFamily: FONTS.body,  fontSize: 12, color: COLORS.muted2 },

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

  locationBlock: { flexDirection: 'row', alignItems: 'center', gap: 10 },
  locationAddr:  { fontFamily: FONTS.bodyMedium, fontSize: 14, color: COLORS.text },
  locationCity:  { fontFamily: FONTS.body,       fontSize: 13, color: COLORS.muted2 },
  mapsBtn: {
    flexDirection: 'row', alignItems: 'center', gap: 4,
    paddingHorizontal: 10, paddingVertical: 6,
    borderRadius: RADIUS.md, backgroundColor: COLORS.greenMuted,
    borderWidth: 1, borderColor: COLORS.green,
  },
  mapsBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 12, color: COLORS.green },

  otCommNote: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted2, marginTop: 4 },

  commentBox: {
    backgroundColor: COLORS.card2, borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: COLORS.border, padding: 12,
  },
  commentText: { fontFamily: FONTS.body, fontSize: 14, color: COLORS.text, lineHeight: 22, fontStyle: 'italic' },

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
  calcHint: {
    fontFamily: FONTS.body, fontSize: 12, color: COLORS.green,
    marginBottom: 4, marginTop: 2,
  },

  // Counter de integrantes
  counterRow: {
    flexDirection: 'row', alignItems: 'center', gap: 16,
    marginBottom: 4,
  },
  counterBtn: {
    width: 36, height: 36, borderRadius: 10,
    backgroundColor: COLORS.card2, borderWidth: 1, borderColor: COLORS.border,
    alignItems: 'center', justifyContent: 'center',
  },
  counterVal: {
    flexDirection: 'row', alignItems: 'center', gap: 8,
    minWidth: 60, justifyContent: 'center',
  },
  counterText: { fontFamily: FONTS.title, fontSize: 22, color: COLORS.text },

  // Lista de integrantes con foto
  membersList: { gap: 8, marginBottom: 12, marginTop: 8 },
  memberChip: {
    flexDirection: 'row', alignItems: 'center', gap: 10,
    backgroundColor: COLORS.bg, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border,
    paddingHorizontal: 12, paddingVertical: 8,
  },
  memberAvatar: { width: 36, height: 36, borderRadius: 18 },
  memberAvatarFallback: {
    width: 36, height: 36, borderRadius: 18,
    backgroundColor: COLORS.card2, borderWidth: 1, borderColor: COLORS.border,
    alignItems: 'center', justifyContent: 'center',
  },
  memberAvatarInitial: { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.green },
  memberChipName: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.text },
  memberChipRole: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.green, marginTop: 1 },
  memberAmountBox: { alignItems: 'flex-end' },
  memberAmountOwner: { fontFamily: FONTS.title, fontSize: 16, color: COLORS.green },
  memberAmountResto: { fontFamily: FONTS.body, fontSize: 10, color: COLORS.muted2 },
  memberAmountInput: { flex: 0, width: 110, marginBottom: 0 },
  autoSplitBtn: {
    alignSelf: 'flex-start', flexDirection: 'row', alignItems: 'center',
    paddingHorizontal: 12, paddingVertical: 6, borderRadius: RADIUS.full,
    borderWidth: 1, borderColor: COLORS.green, backgroundColor: 'rgba(0,230,118,0.08)',
    marginBottom: 8,
  },
  autoSplitBtnText: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.green },

  // Fila de integrante (distribución de pago)
  memberRow: {
    flexDirection: 'row', alignItems: 'center', gap: 12,
    marginBottom: 8,
  },
  memberLabel: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted2, width: 90 },

  notesInput: {
    backgroundColor: COLORS.bg, borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: COLORS.border,
    paddingHorizontal: 14, paddingVertical: 13,
    fontFamily: FONTS.body, fontSize: 14, color: COLORS.text,
    minHeight: 80, marginBottom: 4,
  },

  // Resumen financiero
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

  // Paquetes de horas extra
  overtimeGrid: { gap: 10 },
  overtimeCard: {
    backgroundColor: COLORS.bg, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border, padding: 12,
  },
  overtimeHeader: { flexDirection: 'row', alignItems: 'center', gap: 6, marginBottom: 8 },
  overtimeLabel:  { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.text, flex: 1 },
  reqDot:         { fontFamily: FONTS.bodySemiBold, fontSize: 16, color: COLORS.red },
  requiredNote: {
    marginTop: 10, padding: 10, borderRadius: RADIUS.md,
    backgroundColor: 'rgba(255,152,0,0.08)', borderWidth: 1, borderColor: 'rgba(255,152,0,0.4)',
  },
  requiredNoteText: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: 'rgba(255,152,0,1)' },

  // Acciones
  actions: { flexDirection: 'row', gap: 12, marginTop: 8, marginBottom: 12 },
  declineBtn: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 8,
    flex: 1, paddingVertical: 15,
    borderRadius: RADIUS.lg, borderWidth: 1,
    borderColor: 'rgba(239,83,80,0.4)', backgroundColor: 'rgba(239,83,80,0.08)',
  },
  declineBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.red },
  sendBtn: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 8,
    flex: 2, paddingVertical: 15,
    borderRadius: RADIUS.lg, backgroundColor: COLORS.green,
  },
  sendBtnDisabled: { opacity: 0.4 },
  sendBtnText:     { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.bg },

  quotedBanner: {
    flexDirection: 'row', alignItems: 'center', gap: 10,
    padding: 14, borderRadius: RADIUS.lg, borderWidth: 1,
    borderColor: 'rgba(66,133,244,0.4)', backgroundColor: 'rgba(66,133,244,0.08)',
    marginBottom: 12,
  },
  quotedBannerText: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.blue, flex: 1 },

  memberBanner: {
    backgroundColor: 'rgba(255,152,0,0.08)', borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: 'rgba(255,152,0,0.4)',
    padding: 14, marginBottom: 16,
  },
  memberBannerText: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: 'rgba(255,152,0,1)', lineHeight: 20 },
});
