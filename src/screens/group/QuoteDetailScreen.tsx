/**
 * GroupQuoteDetailScreen — wrapper delgado.
 * Toda la lógica de negocio vive aquí; el UI se delega a QuoteFormShared.
 */
import React, { useEffect, useState } from 'react';
import { Alert, Linking, Platform, StyleSheet, Text, View } from 'react-native';
import { Pressable } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { ArrowLeft } from 'lucide-react-native';
import { supabase } from '../../config/supabase';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';
import { containsBlockedContact } from '../../utils/contentModeration';
import { analyzeMessage } from '../../utils/phoneFilter';
import i18n from '../../i18n';
import QuoteFormShared, { GroupMember } from '../../components/quote/QuoteFormShared';
import ClientProfileModal from '../../components/requests/ClientProfileModal';
import { calcClientPrice } from '../../utils/calculations';
import { maxExtraHoursAfter } from '../../utils/logistics';

export default function GroupQuoteDetailScreen({ route, navigation }: any) {
  const { quote: initialQuote } = route.params as { quote: any };
  const [quote, setQuote] = useState(initialQuote);
  const [profileClientId, setProfileClientId] = useState<string | null>(null);

  const [pricePerHour, setPricePerHour] = useState(quote.price_per_hour?.toString() ?? '');
  const [travelCost,   setTravelCost]   = useState(quote.travel_cost?.toString() ?? '0');
  const [overtime1h,   setOvertime1h]   = useState(
    quote.overtime_1h_price ? Math.round(quote.overtime_1h_price / 1.20).toString() : ''
  );
  const [overtime2h,   setOvertime2h]   = useState(
    quote.overtime_2h_price ? Math.round(quote.overtime_2h_price / 1.20).toString() : ''
  );
  const [overtime3h,   setOvertime3h]   = useState(
    quote.overtime_3h_price ? Math.round(quote.overtime_3h_price / 1.20).toString() : ''
  );
  const [groupNotes,   setGroupNotes]   = useState(quote.group_notes ?? '');
  const [notesWarn,    setNotesWarn]    = useState(false);
  const [numIntegrantes, setNumIntegrantes] = useState(
    quote.num_integrantes?.toString() ?? '1',
  );
  const [memberAmounts, setMemberAmounts] = useState<string[]>(() => {
    if (quote.member_distribution?.length) {
      return (quote.member_distribution as any[]).map((m: any) => m.amount?.toString() ?? '');
    }
    return [''];
  });
  const [loading,      setLoading]      = useState(false);
  const [isOwner,      setIsOwner]      = useState<boolean | null>(null);
  const [ownerName,    setOwnerName]    = useState<string>('');
  const [groupMembers, setGroupMembers] = useState<GroupMember[]>([]);
  // El grupo tiene otra tocada DESPUÉS ese día → sin horas extra en este evento
  const [boxedIn,      setBoxedIn]      = useState(false);

  useEffect(() => {
    maxExtraHoursAfter({
      groupId:       quote.group_id,
      eventDate:     quote.event_date,
      eventTime:     quote.event_time,
      durationHours: quote.duration_hours,
    }).then(cap => setBoxedIn(cap <= 0));
  }, []);

  useEffect(() => {
    supabase.auth.getUser().then(async ({ data }) => {
      if (!data.user) return;
      const { data: grp } = await supabase
        .from('groups').select('owner_id').eq('id', quote.group_id).single();
      const ownerIsCurrentUser = grp?.owner_id === data.user.id;
      setIsOwner(ownerIsCurrentUser);

      const [{ data: ownerProfile }, { data: memberships }] = await Promise.all([
        supabase.from('profiles').select('id, full_name, avatar_url').eq('id', grp?.owner_id).single(),
        supabase
          .from('job_invitations')
          .select('invited_user_id')
          .eq('group_id', quote.group_id)
          .eq('status', 'accepted')
          .is('event_id', null),
      ]);

      if (ownerProfile?.full_name) setOwnerName(ownerProfile.full_name);

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

      if (quote.status === 'pending' && !quote.num_integrantes) {
        const total = memberList.length || 1;
        setNumIntegrantes(String(total));
        setMemberAmounts(Array.from({ length: Math.max(0, total - 1) }, () => ''));
      }
    });
  }, []);

  const isReadOnly = quote.status !== 'pending';

  // ── Cálculos ──────────────────────────────────────────────────────────────
  const pph     = parseFloat(pricePerHour) || 0;
  const travel  = parseFloat(travelCost)   || 0;
  const hours   = quote.duration_hours ?? 3;
  const base    = pph * hours;
  const total   = base + travel;
  const contadoPublico = total > 0 ? calcClientPrice(total) : 0;
  const commission     = contadoPublico - total;
  const commPct        = '20';
  const earnings       = total;

  const numIntegrantesNum = parseInt(numIntegrantes) || 1;
  const numAdditional     = Math.max(0, numIntegrantesNum - 1);
  const memberTotal       = memberAmounts.reduce((sum, v) => sum + (parseFloat(v) || 0), 0);
  const ownerNet          = Math.max(earnings - memberTotal, 0);

  const ot1Val = parseFloat(overtime1h) || 0;
  const ot2Val = parseFloat(overtime2h) || 0;
  const ot3Val = parseFloat(overtime3h) || 0;
  const ot1ClientPrice = ot1Val > 0 ? calcClientPrice(ot1Val) : 0;
  const ot2ClientPrice = ot2Val > 0 ? calcClientPrice(ot2Val) : 0;
  const ot3ClientPrice = ot3Val > 0 ? calcClientPrice(ot3Val) : 0;

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

  // Con otra tocada después, los paquetes de horas extra no aplican
  const canSend = () => pph > 0 && (boxedIn || (!!overtime1h && !!overtime2h && !!overtime3h));

  const handleSendQuote = async () => {
    if (notesWarn || containsBlockedContact(groupNotes)) {
      Alert.alert(i18n.t('moderation.title'), i18n.t('moderation.no_contact'));
      return;
    }
    if (!canSend()) {
      Alert.alert('Precio requerido', 'Ingresa el precio por hora del servicio.');
      return;
    }

    const memberDistribution = memberAmounts
      .map((amt, i) => ({ integrante: i + 1, amount: parseFloat(amt) || 0 }))
      .filter(m => m.amount > 0);

    Alert.alert(
      'Confirmar cotización',
      `Tu ganancia neta: $${total.toLocaleString()} MXN\n\nEsta cotización se enviará al cliente.`,
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
                total_amount:        contadoPublico,
                group_earnings:      total,
                overtime_1h_price:   boxedIn ? null : ot1ClientPrice,
                overtime_2h_price:   boxedIn ? null : ot2ClientPrice,
                overtime_3h_price:   boxedIn ? null : ot3ClientPrice,
                num_integrantes:     parseInt(numIntegrantes),
                member_distribution: memberDistribution,
                group_notes:         groupNotes.trim() || null,
              })
              .eq('id', quote.id);

            if (!error) {
              await supabase.from('notifications').insert({
                user_id: quote.client_id,
                type:    'quote_received',
                title:   '📋 Recibiste una cotización',
                body:    `${quote.group?.name ?? 'El grupo'} respondió tu solicitud. Total: $${contadoPublico.toLocaleString()} MXN. Toca para aceptar o cancelar.`,
                data:    { quote_id: quote.id },
              });

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
                    body:    `El dueño envió la cotización. Tu ganancia neta: $${total.toLocaleString()} MXN.`,
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

  const handleNotesChange = (v: string) => {
    setGroupNotes(v);
    setNotesWarn(containsBlockedContact(v));
  };

  const eventDateStr = new Date(quote.event_date + 'T12:00:00').toLocaleDateString('es-MX', {
    weekday: 'long', year: 'numeric', month: 'long', day: 'numeric',
  });
  const durationLabel = `${hours} hora${hours !== 1 ? 's' : ''}`;
  const clientCreatedAt = new Date(quote.created_at).toLocaleDateString('es-MX', {
    day: 'numeric', month: 'long', year: 'numeric',
  });

  return (
    <View style={s.root}>
      <SafeAreaView edges={['top']} style={s.header}>
        <Pressable style={s.backBtn} onPress={() => navigation.goBack()}>
          <ArrowLeft size={20} color={COLORS.text} />
        </Pressable>
        <Text style={[s.headerTitle, { flex: 1 }]}>Solicitud de cotización</Text>
      </SafeAreaView>

      <QuoteFormShared
        mode="quote"
        // Financial
        earnings={earnings}
        contadoPublico={contadoPublico}
        commission={commission}
        commPct={commPct}
        ownerNet={ownerNet}
        // Quote state
        isReadOnly={isReadOnly}
        quoteStatus={quote.status}
        isOwner={isOwner}
        ownerName={ownerName}
        // Event info
        eventType={quote.event_type}
        eventDateStr={eventDateStr}
        eventTime={quote.event_time}
        durationLabel={durationLabel}
        numPersonas={quote.num_personas}
        comments={quote.comments}
        // Location
        quoteId={quote.id}
        eventAddress={quote.event_address}
        eventLatitude={quote.latitude ?? null}
        eventLongitude={quote.longitude ?? null}
        eventMunicipio={quote.event_municipio}
        eventEstado={quote.event_estado}
        onOpenMaps={openInMaps}
        // Venue
        venueCovered={quote.venue_covered}
        venueSize={quote.venue_size}
        needsSound={quote.needs_sound}
        needsLighting={quote.needs_lighting}
        needsStage={quote.needs_stage}
        needsLed={quote.needs_led}
        // Client card — foto + Ver perfil, como ExpressCard
        clientName={quote.client?.full_name ?? 'Cliente'}
        clientCreatedAt={clientCreatedAt}
        clientAvatarUrl={quote.client?.avatar_url ?? null}
        onViewClientProfile={quote.client_id ? () => setProfileClientId(quote.client_id) : undefined}
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
        // Overtime
        isOvertimeRequired={false}
        hideOvertime={boxedIn}
        // Actions
        canSend={canSend()}
        loading={loading}
        onSend={handleSendQuote}
        onDecline={handleDecline}
      />

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
});
