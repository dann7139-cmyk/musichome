/**
 * ProposeRequestScreen — wrapper delgado.
 * Lógica: propose_event_request RPC, time pickers, surge multiplier.
 * UI delegada a QuoteFormShared (mode='propose').
 */
import React, { useEffect, useState } from 'react';
import { Alert, Platform, StyleSheet, Text, View } from 'react-native';
import { Pressable } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { ArrowLeft } from 'lucide-react-native';
import { supabase } from '../../config/supabase';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';
import TimePickerModal from '../../components/ui/TimePickerModal';
import { analyzeMessage, PHONE_WARNING } from '../../utils/phoneFilter';
import i18n from '../../i18n';
import QuoteFormShared, { GroupMember } from '../../components/quote/QuoteFormShared';

export default function ProposeRequestScreen({ route, navigation }: any) {
  const { request, dispatchId } = route.params as { request: any; dispatchId?: string };

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
  const [groupMembers, setGroupMembers]   = useState<GroupMember[]>([]);
  const [loading, setLoading] = useState(false);

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
  const numAdditional = Math.max(0, groupMembers.length - 1);
  const memberTotal   = memberAmounts.reduce((sum, v) => sum + (parseFloat(v) || 0), 0);
  const ownerNet      = Math.max(earnings - memberTotal, 0);

  const ot1Val = parseFloat(overtime1h) || 0;
  const ot2Val = parseFloat(overtime2h) || 0;
  const ot3Val = parseFloat(overtime3h) || 0;

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

  const canSend = () => pph > 0 && !!arrivalTime && !notesWarn;

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
                await supabase.rpc('complete_express_dispatch', { p_dispatch_id: dispatchId });
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
        // Financial (no platform fee deducted en propose mode)
        earnings={earnings}
        contadoPublico={adjTotal}
        commission={0}
        commPct="0"
        ownerNet={ownerNet}
        // Event info
        eventType={request.event_type}
        eventDateStr={eventDateStr}
        eventTime={request.event_time}
        durationLabel={`${hours} hora${hours !== 1 ? 's' : ''}`}
        numPersonas={request.guest_count}
        comments={request.comments}
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
        ot1ClientPrice={0}
        ot2ClientPrice={0}
        ot3ClientPrice={0}
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
        hasSurge={hasSurge}
        isOvertimeRequired={false}
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
});
