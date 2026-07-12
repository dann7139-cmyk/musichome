/**
 * ProposeRequestScreen — wrapper delgado.
 * Lógica: propose_event_request RPC, time pickers, surge multiplier.
 * UI delegada a QuoteFormShared (mode='propose').
 */
import React, { useEffect, useRef, useState } from 'react';
import { Alert, Animated, Platform, StyleSheet, Text, View } from 'react-native';
import { Pressable } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { ArrowLeft } from 'lucide-react-native';
import { supabase } from '../../config/supabase';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';
import TimePickerModal from '../../components/ui/TimePickerModal';
import { analyzeMessage, PHONE_WARNING } from '../../utils/phoneFilter';
import { calcClientPrice, calcPlatformFee, getCommissionRate } from '../../utils/calculations';
import i18n from '../../i18n';
import QuoteFormShared, { GroupMember } from '../../components/quote/QuoteFormShared';
import ClientProfileModal from '../../components/requests/ClientProfileModal';
import { markExpressDispatchQuoted } from '../../context/ExpressContext';
import { checkGroupLogistics, maxExtraHoursAfter } from '../../utils/logistics';

export default function ProposeRequestScreen({ route, navigation }: any) {
  const { request, dispatchId } = route.params as { request: any; dispatchId?: string };
  const [profileClientId, setProfileClientId] = useState<string | null>(null);

  const [pricePerHour, setPricePerHour] = useState('');
  const [travelCost,   setTravelCost]   = useState('0');
  const [overtime1h,   setOvertime1h]   = useState('');
  const [overtime2h,   setOvertime2h]   = useState('');
  const [overtime3h,   setOvertime3h]   = useState('');
  const [groupNotes,   setGroupNotes]   = useState('');
  const [myGroupId,    setMyGroupId]    = useState<string | null>(null);
  // Otra tocada después ese día → sin horas extra en esta propuesta
  const [boxedIn,      setBoxedIn]      = useState(false);
  // Tocadas del grupo el día de la solicitud → rejilla de horas disponibles
  const [busyRanges,   setBusyRanges]   = useState<{ bs: number; be: number }[]>([]);
  const [notesWarn,    setNotesWarn]    = useState(false);
  const [arrivalTime,     setArrivalTime]     = useState('');
  const [startTime,       setStartTime]       = useState('');
  const [showTimePicker,  setShowTimePicker]  = useState(false);
  const [showStartPicker, setShowStartPicker] = useState(false);
  const [memberAmounts, setMemberAmounts] = useState<string[]>([]);
  const [groupMembers, setGroupMembers]   = useState<GroupMember[]>([]);
  const [loading, setLoading] = useState(false);
  const [sent,    setSent]    = useState(false);
  const [clientProfile, setClientProfile] = useState<any>(null);
  const sentOpacity = useRef(new Animated.Value(0)).current;

  // Perfil PÚBLICO del cliente (sin teléfono/email — sql/435)
  useEffect(() => {
    if (!request?.client_id) return;
    supabase
      .rpc('get_client_public_profile', { p_client_id: request.client_id })
      .then(({ data }) => { if (data?.ok) setClientProfile(data); });
  }, []);

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
      setMyGroupId(grp.id);

      // Con otra tocada DESPUÉS ese día no se ofrecen horas extra
      if (request?.event_date) {
        maxExtraHoursAfter({
          groupId:       grp.id,
          eventDate:     request.event_date,
          eventTime:     request.event_time,
          durationHours: request.hours ?? 3,
        }).then(cap => setBoxedIn(cap <= 0));

        // Sus tocadas de ese día (programadas o express) para la rejilla
        supabase.rpc('get_group_busy_days', {
          p_group_id: grp.id,
          p_from:     request.event_date,
          p_to:       request.event_date,
        }).then(({ data: busy }) => {
          setBusyRanges(
            (Array.isArray(busy) ? busy : [])
              .filter((b: any) => b.event_time)
              .map((b: any) => {
                const [hh, mm] = String(b.event_time).split(':').map(Number);
                const bs = hh + (mm || 0) / 60;
                return { bs, be: bs + (Number(b.hours_count) || 3) };
              })
          );
        });
      }

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

      const memberList: GroupMember[] = [];
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

  // ── Cálculos ──────────────────────────────────────────────────────────────
  const pph        = parseFloat(pricePerHour) || 0;
  const travel     = parseFloat(travelCost)   || 0;
  const hours      = request.hours ?? 3;
  const base       = pph * hours;
  const total      = base + travel;
  const multiplier = Number(request.demand_multiplier ?? 1);
  const adjTotal   = multiplier > 1 ? Math.round(total * multiplier) : total;
  const hasSurge   = multiplier > 1 && total > 0;

  const earnings      = adjTotal;
  const platformFee   = adjTotal > 0 ? calcPlatformFee(adjTotal) : 0;
  const clientPrice   = adjTotal > 0 ? calcClientPrice(adjTotal) : 0;
  const commRate      = adjTotal > 0 ? Math.round(getCommissionRate(adjTotal) * 100) : 10;
  const numAdditional = Math.max(0, groupMembers.length - 1);
  const memberTotal   = memberAmounts.reduce((sum, v) => sum + (parseFloat(v) || 0), 0);
  const ownerNet      = Math.max(earnings - memberTotal, 0);

  const ot1Val = parseFloat(overtime1h) || 0;
  const ot2Val = parseFloat(overtime2h) || 0;
  const ot3Val = parseFloat(overtime3h) || 0;

  // Precio que pagaría el cliente (la plataforma añade su comisión encima)
  const ot1ClientPrice = ot1Val > 0 ? calcClientPrice(ot1Val) : 0;
  const ot2ClientPrice = ot2Val > 0 ? calcClientPrice(ot2Val) : 0;
  const ot3ClientPrice = ot3Val > 0 ? calcClientPrice(ot3Val) : 0;

  const updateMemberAmount = (idx: number, val: string) => {
    setMemberAmounts(prev => {
      const next = [...prev];
      next[idx] = val.replace(/[^0-9.]/g, '');
      return next;
    });
  };

  const autoDistributeEqual = () => {
    if (numAdditional <= 0 || earnings <= 0) return;
    const perMember = Math.floor(earnings / groupMembers.length);
    setMemberAmounts(Array.from({ length: numAdditional }, () => String(perMember)));
  };

  const handleNotesChange = (v: string) => {
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
  };

  const canSend = () =>
    pph > 0 && !!arrivalTime && !notesWarn &&
    (boxedIn || (!!overtime1h && !!overtime2h && !!overtime3h));

  const handleSend = async () => {
    if (!canSend()) {
      if (notesWarn) {
        Alert.alert(i18n.t('moderation.title'), i18n.t('moderation.no_contact'));
      } else {
        Alert.alert('Precio requerido', 'Ingresa el precio por hora del servicio.');
      }
      return;
    }
    if (!arrivalTime) {
      Alert.alert('Hora requerida', 'Indica la hora exacta a la que llegará tu grupo al evento.');
      return;
    }

    // ⏰ Candado logístico: no proponerse si choca con otra tocada del grupo
    // (traslape, colchón de 2h o traslado imposible entre eventos)
    if (myGroupId) {
      const logistics = await checkGroupLogistics({
        groupId:       myGroupId,
        eventDate:     request.event_date,
        eventTime:     startTime || arrivalTime || request.event_time || undefined,
        durationHours: request.hours ?? 3,
        lat:           request.latitude ?? request.event_lat ?? undefined,
        lng:           request.longitude ?? request.event_lng ?? undefined,
      });
      // Margen justo (≥1h, solo colchón): el grupo decide — "nos queda cerca,
      // sí alcanzamos a llegar". Traslape o traslado imposible sí bloquean.
      const tightButPossible =
        logistics.conflict &&
        logistics.reason === 'time_buffer' &&
        (logistics.gapMinutes ?? 0) >= 60;
      if (logistics.conflict && !tightButPossible) {
        Alert.alert(
          '⏰ Choca con otra tocada tuya',
          logistics.messageGroup ??
            'Ya tienes un evento muy cerca de ese horario y no alcanzarías a llegar. Revisa tu agenda antes de proponerte.',
        );
        return;
      }
      if (tightButPossible) {
        const goAnyway = await new Promise<boolean>(resolve => {
          Alert.alert(
            '🕐 Te queda muy pegado a otra tocada',
            `Entre este evento y tu otra tocada te queda ~${Math.round((logistics.gapMinutes ?? 60) / 60 * 10) / 10}h para desconectar y trasladarte. ¿Seguros que alcanzan a llegar?`,
            [
              { text: 'Mejor no', style: 'cancel', onPress: () => resolve(false) },
              { text: 'Sí alcanzamos, proponer', onPress: () => resolve(true) },
            ],
          );
        });
        if (!goAnyway) return;
      }
    }

    const memberDistribution = memberAmounts
      .map((amt, i) => ({ integrante: i + 1, amount: parseFloat(amt) || 0 }))
      .filter(m => m.amount > 0);

    const startLine = startTime ? `\nInicio de tocada: ${startTime}` : '';
    Alert.alert(
      'Confirmar propuesta',
      `Tu ganancia neta: $${earnings.toLocaleString()} MXN\nHora de llegada: ${arrivalTime}${startLine}\n\n¿Enviar tu cotización al cliente?`,
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
              p_overtime_1h:    boxedIn ? null : (parseFloat(overtime1h) || null),
              p_overtime_2h:    boxedIn ? null : (parseFloat(overtime2h) || null),
              p_overtime_3h:    boxedIn ? null : (parseFloat(overtime3h) || null),
              p_notes:          groupNotes.trim() || null,
              p_member_dist:    memberDistribution.length > 0 ? memberDistribution : null,
              p_arrival_time:   arrivalTime,
              p_start_time:     startTime || null,
              p_dispatch_id:    dispatchId ?? null,
            });
            setLoading(false);

            if (error || !data?.ok) {
              const code = data?.error ?? error?.message ?? '';
              const msg =
                code === 'not_available'      ? 'Esta solicitud ya no está disponible — otro grupo llegó primero.' :
                code === 'request_expired'    ? 'Esta solicitud ya venció. El cliente tendrá que crear una nueva.' :
                code === 'genre_mismatch'     ? 'El género no coincide con tu grupo.' :
                code === 'too_close_to_event' ? 'Esta solicitud es muy próxima al evento. Ya no es posible cotizar (necesita al menos 2 horas de margen).' :
                `Error: ${code || 'No se pudo enviar. Inténtalo de nuevo.'}`;
              Alert.alert('No disponible', msg);
            } else {
              // Si esta propuesta cae DESPUÉS de una tocada suya ese día,
              // avisar al cliente del primer evento que decida pronto sus
              // horas extra (best-effort, no bloquea el flujo).
              try {
                const tSel = startTime || arrivalTime;
                if (tSel && busyRanges.length > 0) {
                  const h0 = parseInt(tSel.split(':')[0], 10);
                  const hSel = h0 <= 2 ? h0 + 24 : h0;
                  if (busyRanges.some(r => hSel >= r.be)) {
                    void supabase.rpc('notify_prior_event_extra_hours', {
                      p_group_id:   myGroupId,
                      p_event_date: request.event_date,
                      p_event_time: tSel,
                    });
                  }
                }
              } catch {}

              if (dispatchId) {
                // 1) Quitar la tarjeta del carrusel YA (local, no depende del
                //    RPC/realtime). 2) Persistir status='quoted' en la DB.
                markExpressDispatchQuoted(dispatchId);
                await supabase.rpc('complete_express_dispatch', { p_dispatch_id: dispatchId });
                setSent(true);
                Animated.timing(sentOpacity, { toValue: 1, duration: 280, useNativeDriver: true }).start();
                setTimeout(() => navigation.goBack(), 2200);
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

  return (
    <View style={s.root}>
      <SafeAreaView edges={['top']} style={s.header}>
        <Pressable style={s.backBtn} onPress={() => navigation.goBack()}>
          <ArrowLeft size={20} color={COLORS.text} />
        </Pressable>
        <Text style={[s.headerTitle, { flex: 1 }]}>Tu cotización</Text>
      </SafeAreaView>

      <QuoteFormShared
        mode="propose"
        // Financial: grupo gana adjTotal; cliente paga clientPrice (tarifa añadida encima)
        earnings={earnings}
        contadoPublico={clientPrice}
        commission={platformFee}
        commPct={String(commRate)}
        ownerNet={ownerNet}
        // Event info
        eventType={request.event_type}
        eventDateStr={eventDateStr}
        eventTime={request.event_time}
        durationLabel={`${hours} hora${hours !== 1 ? 's' : ''}`}
        numPersonas={request.guest_count}
        comments={request.comments}
        clientProfile={clientProfile}
        onViewClientProfile={request.client_id ? () => setProfileClientId(request.client_id) : undefined}
        // Location (zona, no dirección exacta)
        locationCity={request.location_city}
        locationMunicipio={request.location_municipio}
        locationEstado={request.location_estado}
        // Venue
        venueCovered={request.venue_covered}
        venueSize={request.venue_size}
        needsSound={request.needs_sound}
        // Form state
        pricePerHour={pricePerHour}
        onPriceChange={setPricePerHour}
        travelCost={travelCost}
        onTravelChange={setTravelCost}
        overtime1h={overtime1h}
        overtime2h={overtime2h}
        overtime3h={overtime3h}
        onOt1Change={setOvertime1h}
        onOt2Change={setOvertime2h}
        onOt3Change={setOvertime3h}
        groupNotes={groupNotes}
        onNotesChange={handleNotesChange}
        notesWarn={notesWarn}
        // Computed hints
        hours={hours}
        pph={pph}
        base={base}
        travel={travel}
        ot1Val={ot1Val}
        ot2Val={ot2Val}
        ot3Val={ot3Val}
        ot1ClientPrice={ot1ClientPrice}
        ot2ClientPrice={ot2ClientPrice}
        ot3ClientPrice={ot3ClientPrice}
        // Members
        groupMembers={groupMembers}
        memberAmounts={memberAmounts}
        onMemberAmountChange={updateMemberAmount}
        onAutoDistribute={autoDistributeEqual}
        numAdditional={numAdditional}
        // Propose-only
        arrivalTime={arrivalTime}
        onArrivalTimePress={() => setShowTimePicker(true)}
        startTime={startTime}
        onStartTimePress={() => setShowStartPicker(true)}
        busyRanges={busyRanges}
        proposeDurationHours={request?.hours ?? 3}
        onPickStartHour={(h: number) => {
          const hh = h % 24;
          setStartTime(`${String(hh).padStart(2, '0')}:00`);
          // Llegada sugerida 30 min antes para instalarse (solo si no la ha puesto)
          if (!arrivalTime) {
            const am = h * 60 - 30;
            setArrivalTime(`${String(Math.floor(am / 60) % 24).padStart(2, '0')}:${String(am % 60).padStart(2, '0')}`);
          }
        }}
        hasSurge={hasSurge}
        isOvertimeRequired={!boxedIn}
        hideOvertime={boxedIn}
        // Actions
        canSend={canSend()}
        loading={loading}
        onSend={handleSend}
      />

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

      {sent && (
        <Animated.View style={[s.sentOverlay, { opacity: sentOpacity }]} pointerEvents="none">
          <Text style={s.sentCheck}>✓</Text>
          <Text style={s.sentTitle}>Cotización enviada.</Text>
          <Text style={s.sentBody}>El cliente la está revisando ahora.</Text>
        </Animated.View>
      )}

      {/* Perfil público del cliente (RPC 435 — sin teléfono/email) */}
      <ClientProfileModal clientId={profileClientId} onClose={() => setProfileClientId(null)} />
    </View>
  );
}

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

  sentOverlay: {
    ...StyleSheet.absoluteFillObject,
    backgroundColor: COLORS.bg,
    alignItems: 'center',
    justifyContent: 'center',
    gap: 14,
  },
  sentCheck: { fontSize: 60, color: COLORS.green },
  sentTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 22, color: COLORS.text },
  sentBody:  { fontFamily: FONTS.body, fontSize: 14, color: COLORS.muted },
});
