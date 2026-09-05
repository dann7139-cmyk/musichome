import {
  ArrowLeft,
  Calendar,
  CheckCircle,
  Clock,
  DollarSign,
  MapPin,
  MessageSquare,
  Search,
  Send,
  Star,
  Users,
  X,
  Inbox,
} from 'lucide-react-native';
import * as Location from 'expo-location';
import React, { useEffect, useState } from 'react';
import {
  ActivityIndicator,
  Alert,
  Image,
  KeyboardAvoidingView,
  Modal,
  Platform,
  Pressable,
  RefreshControl,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  View,
} from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { useTranslation } from 'react-i18next';
import Particles from '../../components/ui/Particles';
import { supabase } from '../../config/supabase';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';

interface Talent {
  id: string;
  user_id: string;
  full_name: string;
  avatar_url: string | null;
  instrument_or_role: string;
  bio: string | null;
  experience_years: number;
  rating: number;
  total_jobs: number;
  availability_status: 'available' | 'busy';
  distance_km: number | null;
  video_url?: string | null;
  city?: string | null;
  musical_styles?: string[] | null;
  social_instagram?: string | null;
  social_tiktok?: string | null;
}

interface GroupEvent {
  id: string;         // reservation id (para UI)
  event_id: string;   // events.id (para job_invitations.event_id FK)
  event_date: string;
  event_time: string | null;
  address: string;
}

type InviteType = 'event' | 'membership';

export default function TalentSearchScreen({ navigation }: any) {
  const { t } = useTranslation();
  const [talents, setTalents]         = useState<Talent[]>([]);
  const [filtered, setFiltered]       = useState<Talent[]>([]);
  const [loading, setLoading]         = useState(true);
  const [refreshing, setRefreshing]   = useState(false);
  const [roleFilter, setRoleFilter]   = useState('');
  const [availFilter, setAvailFilter] = useState<'all' | 'available' | 'busy'>('all');
  const [groupId, setGroupId]         = useState<string | null>(null);
  const [isAdmin, setIsAdmin]         = useState(false);
  const [isUsa, setIsUsa]             = useState(false);

  // Modal state
  const [modalVisible, setModalVisible] = useState(false);
  const [selectedTalent, setSelectedTalent] = useState<Talent | null>(null);
  const [inviteType, setInviteType]   = useState<InviteType>('event');
  const [events, setEvents]           = useState<GroupEvent[]>([]);
  const [selectedEvent, setSelectedEvent] = useState<GroupEvent | null>(null);
  const [payment, setPayment]         = useState('');
  const [message, setMessage]         = useState('');
  const [sending, setSending]         = useState(false);

  useEffect(() => {
    init();
  }, []);

  useEffect(() => {
    applyFilter();
  }, [talents, roleFilter, availFilter]);

  const onRefresh = async () => { setRefreshing(true); await init(); setRefreshing(false); };

  const init = async () => {
    setLoading(true);
    const { data: session } = await supabase.auth.getSession();
    const uid = session.session?.user.id;
    if (!uid) { setLoading(false); return; }

    // Check user role
    const { data: profile } = await supabase
      .from('profiles')
      .select('role')
      .eq('id', uid)
      .maybeSingle();
    const adminMode = profile?.role === 'admin';
    setIsAdmin(adminMode);

    // Get group only if not admin — usa RPC para evitar bloqueos de RLS
    if (!adminMode) {
      const { data: grp } = await supabase.rpc('get_my_group').maybeSingle();
      if (grp) setGroupId((grp as any).id);
    }

    // Obtener ubicación GPS (non-blocking — sin GPS la búsqueda igual funciona)
    let lat: number | null = null;
    let lng: number | null = null;
    try {
      const { status } = await Location.requestForegroundPermissionsAsync();
      if (status === 'granted') {
        const pos = await Location.getCurrentPositionAsync({
          accuracy: Location.Accuracy.Low,
        });
        lat = pos.coords.latitude;
        lng = pos.coords.longitude;
        // USA: longitud < -90 y latitud > 25 (cubre Texas/Florida hacia el norte)
        setIsUsa(pos.coords.longitude < -90 && pos.coords.latitude > 25);
      }
    } catch {
      // Sin permiso o GPS no disponible — continúa sin coords
    }

    // Fetch visible talents con distancia si hay GPS, sin distancia si no
    const rpcArgs: Record<string, number> = {};
    if (lat !== null && lng !== null) {
      rpcArgs.p_lat = lat;
      rpcArgs.p_lng = lng;
    }
    const { data } = await supabase.rpc('search_talents', rpcArgs);
    if (data) setTalents(data as Talent[]);
    setLoading(false);
  };

  const applyFilter = () => {
    let list = [...talents];
    if (roleFilter) {
      list = list.filter(t =>
        t.instrument_or_role.toLowerCase().includes(roleFilter.toLowerCase())
      );
    }
    if (availFilter !== 'all') {
      list = list.filter(t => t.availability_status === availFilter);
    }
    setFiltered(list);
  };

  const openInviteModal = async (talent: Talent, type: InviteType = 'event') => {
    setSelectedTalent(talent);
    setInviteType(type);
    setSelectedEvent(null);
    setPayment('');
    setMessage('');

    // Fetch group's upcoming confirmed reservations
    if (groupId) {
      const today = new Date().toISOString().split('T')[0];
      const { data } = await supabase
        .from('reservations')
        .select('id, event_id, event_date, event_time, address')
        .eq('group_id', groupId)
        .eq('status', 'confirmed')
        .gte('event_date', today)
        .order('event_date', { ascending: true });
      setEvents((data as GroupEvent[]) ?? []);
    }
    setModalVisible(true);
  };

  const sendInvitation = async () => {
    if (!groupId || !selectedTalent) return;
    if (inviteType === 'event' && !selectedEvent) {
      Alert.alert(t('talentSearchScreen.error'), t('talentSearchScreen.selectEventRequired'));
      return;
    }
    if (inviteType === 'event' && selectedEvent && !selectedEvent.event_id) {
      Alert.alert(t('talentSearchScreen.error'), t('talentSearchScreen.invalidEventId'));
      return;
    }

    setSending(true);
    const payload: any = {
      group_id:                groupId,
      invited_user_id:         selectedTalent.user_id,
      proposed_payment_amount: payment ? parseFloat(payment) : null,
      message:                 message.trim() || null,
      status:                  'pending',
      // event_id null = membresía permanente; event_id presente = tocada
      // selectedEvent.event_id es el FK a events.id (no el id de la reserva)
      event_id: inviteType === 'event' && selectedEvent ? selectedEvent.event_id : null,
      // Hallazgo real (2026-09-05): faltaba este campo — toda invitación
      // (incluso "membresía") se guardaba con el default de la columna
      // ('event'), nunca había existido una fila invitation_type='membership'.
      invitation_type: inviteType,
    };

    const { error } = await supabase.from('job_invitations').insert(payload);
    setSending(false);

    if (error) {
      if (error.code === '23505') {
        Alert.alert(t('talentSearchScreen.notice'), t('talentSearchScreen.duplicateInvite'));
      } else {
        Alert.alert(t('talentSearchScreen.error'), error.message);
      }
    } else {
      setModalVisible(false);
      Alert.alert(
        t('talentSearchScreen.invitationSentTitle'),
        t('talentSearchScreen.invitationSentMessage', { name: selectedTalent.full_name })
      );
    }
  };

  return (
    <View style={styles.container}>
      <Particles />
      <SafeAreaView style={{ flex: 1 }}>
        {/* HEADER */}
        <View style={styles.header}>
          {navigation.canGoBack() ? (
            <Pressable style={styles.backBtn} onPress={() => navigation.goBack()}>
              <ArrowLeft size={20} color={COLORS.text} />
            </Pressable>
          ) : (
            <View style={{ width: 40 }} />
          )}
          <View style={styles.headerTitle}>
            <Users size={18} color={COLORS.green} />
            <Text style={styles.headerTitleText}>{t('talentSearchScreen.headerTitle')}</Text>
          </View>
          {/* Botón: ver invitaciones enviadas */}
          <Pressable
            style={styles.backBtn}
            onPress={() => navigation.navigate('GroupSentInvitations')}
          >
            <Inbox size={20} color={COLORS.green} />
          </Pressable>
        </View>

        {/* FILTERS */}
        <View style={styles.filterSection}>
          {/* Text search by role */}
          <View style={styles.searchBox}>
            <Search size={16} color={COLORS.muted} />
            <TextInput
              style={styles.searchInput}
              placeholder={t('talentSearchScreen.searchPlaceholder')}
              placeholderTextColor={COLORS.muted}
              value={roleFilter}
              onChangeText={setRoleFilter}
            />
            {roleFilter ? (
              <Pressable onPress={() => setRoleFilter('')}>
                <X size={16} color={COLORS.muted} />
              </Pressable>
            ) : null}
          </View>

          {/* Availability filter chips */}
          <ScrollView horizontal showsHorizontalScrollIndicator={false} style={styles.chipScroll}>
            {(['all', 'available', 'busy'] as const).map((a) => (
              <Pressable
                key={a}
                style={[styles.chip, availFilter === a && styles.chipActive]}
                onPress={() => setAvailFilter(a)}
              >
                <Text style={[styles.chipText, availFilter === a && styles.chipTextActive]}>
                  {a === 'all' ? t('talentSearchScreen.filterAll') : a === 'available' ? t('talentSearchScreen.filterAvailable') : t('talentSearchScreen.filterBusy')}
                </Text>
              </Pressable>
            ))}
          </ScrollView>
        </View>

        {/* TALENT LIST */}
        {loading ? (
          <View style={styles.center}>
            <ActivityIndicator size="large" color={COLORS.green} />
            <Text style={styles.loadingText}>{t('talentSearchScreen.loading')}</Text>
          </View>
        ) : filtered.length === 0 ? (
          <View style={styles.center}>
            <Text style={{ fontSize: 40 }}>🎵</Text>
            <Text style={styles.emptyTitle}>{t('talentSearchScreen.emptyTitle')}</Text>
            <Text style={styles.emptyText}>{t('talentSearchScreen.emptyText')}</Text>
          </View>
        ) : (
          <ScrollView showsVerticalScrollIndicator={false} contentContainerStyle={styles.list} refreshControl={<RefreshControl refreshing={refreshing} onRefresh={onRefresh} tintColor={COLORS.green} />}>
            <Text style={styles.resultsText}>
              {t('talentSearchScreen.resultsFound', { count: filtered.length })}
            </Text>
            {isAdmin && (
              <Text style={styles.adminBadge}>{t('talentSearchScreen.adminBadge')}</Text>
            )}
            {filtered.map((t) => (
              <TalentCard
                key={t.id}
                talent={t}
                showInvite={!isAdmin}
                isUsa={isUsa}
                onInvite={(type) => openInviteModal(t, type)}
                onViewProfile={() =>
                  navigation.navigate('TalentProfile', {
                    talent: t,
                    isUsa,
                    groupId,
                    canInvite: !isAdmin && !!groupId,
                  })
                }
              />
            ))}
          </ScrollView>
        )}
      </SafeAreaView>

      {/* INVITE MODAL */}
      <Modal
        visible={modalVisible}
        transparent
        animationType="slide"
        onRequestClose={() => setModalVisible(false)}
      >
        <KeyboardAvoidingView
          style={{ flex: 1 }}
          behavior={Platform.OS === 'ios' ? 'padding' : undefined}
        >
          <Pressable style={modal.overlay} onPress={() => setModalVisible(false)} />
          <View style={modal.sheet}>
            <View style={modal.handle} />

            <View style={modal.sheetHeader}>
              <Text style={modal.sheetTitle}>
                {t('talentSearchScreen.modalTitle', { name: selectedTalent?.full_name })}
              </Text>
              <Pressable onPress={() => setModalVisible(false)}>
                <X size={20} color={COLORS.muted} />
              </Pressable>
            </View>

            <ScrollView showsVerticalScrollIndicator={false}>
              {/* Invite type selector */}
              <Text style={modal.label}>{t('talentSearchScreen.inviteTypeLabel')}</Text>
              <View style={modal.typeRow}>
                <Pressable
                  style={[modal.typeBtn, inviteType === 'event' && modal.typeBtnActive]}
                  onPress={() => setInviteType('event')}
                >
                  <Text style={modal.typeEmoji}>🎵</Text>
                  <Text style={[modal.typeLabel, inviteType === 'event' && modal.typeLabelActive]}>
                    {t('talentSearchScreen.typeGigLabel')}
                  </Text>
                  <Text style={modal.typeDesc}>{t('talentSearchScreen.typeGigDesc')}</Text>
                </Pressable>
                <Pressable
                  style={[modal.typeBtn, inviteType === 'membership' && modal.typeBtnActive]}
                  onPress={() => setInviteType('membership')}
                >
                  <Text style={modal.typeEmoji}>🎸</Text>
                  <Text style={[modal.typeLabel, inviteType === 'membership' && modal.typeLabelActive]}>
                    {t('talentSearchScreen.typeMembershipLabel')}
                  </Text>
                  <Text style={modal.typeDesc}>{t('talentSearchScreen.typeMembershipDesc')}</Text>
                </Pressable>
              </View>

              {/* Event selector (only for tocada) */}
              {inviteType === 'event' && (
                <View>
                  <Text style={modal.label}>{t('talentSearchScreen.selectEventLabel')}</Text>
                  {events.length === 0 ? (
                    <View style={modal.noEvents}>
                      <Calendar size={20} color={COLORS.muted} />
                      <Text style={modal.noEventsText}>
                        {t('talentSearchScreen.noEvents')}
                      </Text>
                    </View>
                  ) : (
                    <ScrollView horizontal showsHorizontalScrollIndicator={false} style={{ marginBottom: 12 }}>
                      {events.map((ev) => (
                        <Pressable
                          key={ev.id}
                          style={[modal.eventCard, selectedEvent?.id === ev.id && modal.eventCardActive]}
                          onPress={() => setSelectedEvent(ev)}
                        >
                          <Text style={modal.eventDate}>{ev.event_date}</Text>
                          {ev.event_time && (
                            <View style={modal.eventTimeRow}>
                              <Clock size={11} color={COLORS.muted} />
                              <Text style={modal.eventTime}>{ev.event_time.slice(0, 5)}</Text>
                            </View>
                          )}
                          <Text style={modal.eventAddr} numberOfLines={2}>{ev.address}</Text>
                          {selectedEvent?.id === ev.id && (
                            <CheckCircle size={14} color={COLORS.green} style={{ marginTop: 4 }} />
                          )}
                        </Pressable>
                      ))}
                    </ScrollView>
                  )}
                </View>
              )}

              {/* Payment */}
              <Text style={modal.label}>{t('talentSearchScreen.paymentLabel')}</Text>
              <View style={modal.inputRow}>
                <DollarSign size={16} color={COLORS.muted} />
                <TextInput
                  style={modal.input}
                  placeholder="0.00"
                  placeholderTextColor={COLORS.muted}
                  value={payment}
                  onChangeText={setPayment}
                  keyboardType="numeric"
                />
              </View>

              {/* Message */}
              <Text style={modal.label}>{t('talentSearchScreen.messageLabel')}</Text>
              <View style={[modal.inputRow, { alignItems: 'flex-start', paddingTop: 12 }]}>
                <MessageSquare size={16} color={COLORS.muted} style={{ marginTop: 2 }} />
                <TextInput
                  style={[modal.input, { height: 80, textAlignVertical: 'top' }]}
                  placeholder={t('talentSearchScreen.messagePlaceholder')}
                  placeholderTextColor={COLORS.muted}
                  value={message}
                  onChangeText={setMessage}
                  multiline
                />
              </View>

              {/* Send */}
              <Pressable
                style={[modal.sendBtn, sending && { opacity: 0.6 }]}
                onPress={sendInvitation}
                disabled={sending}
              >
                <Send size={16} color={COLORS.bg} />
                <Text style={modal.sendBtnText}>
                  {sending ? t('talentSearchScreen.sending') : t('talentSearchScreen.sendInvitation')}
                </Text>
              </Pressable>
            </ScrollView>
          </View>
        </KeyboardAvoidingView>
      </Modal>
    </View>
  );
}

// ── Talent Card ───────────────────────────────────────────────────────────────

function formatDistance(km: number, usa: boolean): string {
  if (usa) {
    const mi = km * 0.621371;
    return mi < 10 ? `${mi.toFixed(1)} mi` : `${Math.round(mi)} mi`;
  }
  return km < 10 ? `${km.toFixed(1)} km` : `${Math.round(km)} km`;
}

function TalentCard({
  talent,
  showInvite,
  isUsa,
  onInvite,
  onViewProfile,
}: {
  talent: Talent;
  showInvite: boolean;
  isUsa: boolean;
  onInvite: (type: InviteType) => void;
  onViewProfile: () => void;
}) {
  const { t } = useTranslation();
  const isAvailable = talent.availability_status === 'available';
  const initial = talent.full_name?.charAt(0)?.toUpperCase() ?? '?';

  return (
    <View style={card.container}>
      {/* Header row: avatar + name/role + availability badge */}
      <View style={card.headerRow}>
        {/* Avatar */}
        <View style={card.avatarWrap}>
          {talent.avatar_url ? (
            <Image source={{ uri: talent.avatar_url }} style={card.avatarImg} />
          ) : (
            <View style={card.avatarFallback}>
              <Text style={card.avatarText}>{initial}</Text>
            </View>
          )}
          <View style={[card.availDot, !isAvailable && card.availDotBusy]} />
        </View>

        {/* Name + role + availability */}
        <View style={card.headerInfo}>
          <View style={card.nameRow}>
            <Text style={card.name} numberOfLines={1}>{talent.full_name}</Text>
            <View style={[card.availBadge, !isAvailable && card.availBadgeBusy]}>
              <Text style={[card.availBadgeText, !isAvailable && card.availBadgeTextBusy]}>
                {isAvailable ? t('talentSearchScreen.available') : t('talentSearchScreen.busy')}
              </Text>
            </View>
          </View>
          <Text style={card.role}>{talent.instrument_or_role}</Text>
          {talent.distance_km != null && (
            <View style={card.distanceRow}>
              <MapPin size={11} color={COLORS.green} />
              <Text style={card.distanceText}>{formatDistance(talent.distance_km, isUsa)}</Text>
            </View>
          )}
          {talent.bio ? (
            <Text style={card.bio} numberOfLines={1}>{talent.bio}</Text>
          ) : null}
        </View>
      </View>

      {/* Stats row */}
      <View style={card.statsRow}>
        <View style={card.statItem}>
          <Star size={13} color={COLORS.green} fill={COLORS.green} />
          <Text style={card.statValue}>{talent.rating?.toFixed(1) ?? '5.0'}</Text>
          <Text style={card.statLabel}>{t('talentSearchScreen.rating')}</Text>
        </View>
        <View style={card.statDivider} />
        <View style={card.statItem}>
          <Text style={card.statValue}>{talent.experience_years}</Text>
          <Text style={card.statLabel}>{t('talentSearchScreen.yearsExp')}</Text>
        </View>
        <View style={card.statDivider} />
        <View style={card.statItem}>
          <Text style={card.statValue}>{talent.total_jobs}</Text>
          <Text style={card.statLabel}>{t('talentSearchScreen.jobs')}</Text>
        </View>
      </View>

      {/* Ver perfil + Invite buttons */}
      <View style={card.btnRow}>
        <Pressable style={card.btnPerfil} onPress={onViewProfile}>
          <Text style={card.btnPerfilText}>{t('talentSearchScreen.viewProfile')}</Text>
        </Pressable>
      </View>
    </View>
  );
}

// ── Styles ────────────────────────────────────────────────────────────────────

const styles = StyleSheet.create({
  container:       { flex: 1, backgroundColor: COLORS.bg },
  center:          { flex: 1, alignItems: 'center', justifyContent: 'center', gap: 10 },
  header:          {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between',
    paddingHorizontal: SPACING.xl, paddingVertical: 14,
    borderBottomWidth: 1, borderBottomColor: COLORS.border,
  },
  backBtn:         {
    width: 40, height: 40, borderRadius: 12,
    backgroundColor: COLORS.card, borderWidth: 1, borderColor: COLORS.border,
    alignItems: 'center', justifyContent: 'center',
  },
  headerTitle:     { flexDirection: 'row', alignItems: 'center', gap: 8 },
  headerTitleText: { fontFamily: FONTS.bodySemiBold, fontSize: 16, color: COLORS.text },

  filterSection:  { padding: SPACING.xl, paddingBottom: 8, gap: 10 },
  searchBox:      {
    flexDirection: 'row', alignItems: 'center', gap: 10,
    backgroundColor: COLORS.card, borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: COLORS.border,
    paddingHorizontal: 14, paddingVertical: 10,
  },
  searchInput:    { flex: 1, fontFamily: FONTS.body, fontSize: 14, color: COLORS.text },
  chipScroll:     { marginHorizontal: -SPACING.xl, paddingHorizontal: SPACING.xl },
  chip:           {
    paddingHorizontal: 14, paddingVertical: 7, borderRadius: RADIUS.full,
    backgroundColor: COLORS.card, borderWidth: 1, borderColor: COLORS.border, marginRight: 8,
  },
  chipActive:     { borderColor: COLORS.green, backgroundColor: COLORS.greenMuted },
  chipText:       { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted },
  chipTextActive: { color: COLORS.green },

  list:         { padding: SPACING.xl, gap: 12, paddingBottom: 32 },
  resultsText:  { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted, marginBottom: 4 },
  adminBadge:   { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.muted2, textAlign: 'center', paddingVertical: 6, marginBottom: 4 },
  loadingText:  { fontFamily: FONTS.body, fontSize: 14, color: COLORS.muted2, marginTop: 12 },
  emptyTitle:   { fontFamily: FONTS.title, fontSize: 20, color: COLORS.text, marginTop: 12 },
  emptyText:    { fontFamily: FONTS.body, fontSize: 14, color: COLORS.muted2, textAlign: 'center' },
});

const card = StyleSheet.create({
  container: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border,
    overflow: 'hidden',
  },

  // ── Header row ───────────────────────────────────────────────────────────
  headerRow: {
    flexDirection: 'row', alignItems: 'center',
    gap: 10, padding: 10,
  },
  avatarWrap: { position: 'relative' },
  avatarImg: {
    width: 46, height: 46, borderRadius: 23,
    borderWidth: 2, borderColor: COLORS.green,
  },
  avatarFallback: {
    width: 46, height: 46, borderRadius: 23,
    backgroundColor: COLORS.greenMuted, borderWidth: 2, borderColor: COLORS.green,
    alignItems: 'center', justifyContent: 'center',
  },
  avatarText: { fontFamily: FONTS.title, fontSize: 18, color: COLORS.green },
  availDot: {
    position: 'absolute', bottom: 1, right: 1,
    width: 11, height: 11, borderRadius: 6,
    backgroundColor: COLORS.green,
    borderWidth: 2, borderColor: COLORS.card,
  },
  availDotBusy: { backgroundColor: '#EF5350' },

  headerInfo: { flex: 1, paddingTop: 0 },
  nameRow: { flexDirection: 'row', alignItems: 'center', gap: 6, marginBottom: 2, flexWrap: 'wrap' },
  name: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.text, flexShrink: 1 },
  availBadge: {
    paddingHorizontal: 6, paddingVertical: 2, borderRadius: RADIUS.full,
    backgroundColor: COLORS.greenMuted, borderWidth: 1, borderColor: COLORS.green,
  },
  availBadgeBusy: { backgroundColor: 'rgba(239,83,80,0.12)', borderColor: '#EF5350' },
  availBadgeText: { fontFamily: FONTS.bodyMedium, fontSize: 9, color: COLORS.green },
  availBadgeTextBusy: { color: '#EF5350' },
  role: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.muted2, marginBottom: 2 },
  bio: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted, lineHeight: 15 },

  // ── Stats row ────────────────────────────────────────────────────────────
  statsRow: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'space-around',
    paddingVertical: 7,
    borderTopWidth: 1, borderTopColor: COLORS.border,
    borderBottomWidth: 1, borderBottomColor: COLORS.border,
    backgroundColor: COLORS.card2,
  },
  statItem: { flex: 1, alignItems: 'center', gap: 1 },
  statValue: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.text },
  statLabel: { fontFamily: FONTS.body, fontSize: 9, color: COLORS.muted },
  statDivider: { width: 1, height: 22, backgroundColor: COLORS.border },

  // ── Buttons ──────────────────────────────────────────────────────────────
  btnRow: { flexDirection: 'row' },
  btnPerfil: {
    flex: 3, alignItems: 'center', justifyContent: 'center',
    backgroundColor: COLORS.card2, paddingVertical: 9,
    borderTopWidth: 0,
  },
  btnPerfilText: { fontFamily: FONTS.bodySemiBold, fontSize: 12, color: COLORS.text },
  btnTocada: {
    flex: 1, alignItems: 'center', justifyContent: 'center',
    borderLeftWidth: 1, borderLeftColor: COLORS.border,
    backgroundColor: COLORS.green, paddingVertical: 9,
  },
  btnTocadaText: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.bg },
  btnGrupo: {
    flex: 1, alignItems: 'center', justifyContent: 'center',
    borderLeftWidth: 1, borderLeftColor: COLORS.bg,
    backgroundColor: COLORS.green, paddingVertical: 9, opacity: 0.82,
  },
  btnGrupoText: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.bg },

  // ── Distance badge ───────────────────────────────────────────
  distanceRow: { flexDirection: 'row', alignItems: 'center', gap: 3, marginBottom: 2 },
  distanceText: { fontFamily: FONTS.bodyMedium, fontSize: 10, color: COLORS.green },
});

const modal = StyleSheet.create({
  overlay:       { flex: 1, backgroundColor: 'rgba(0,0,0,0.5)' },
  sheet:         {
    backgroundColor: COLORS.card, borderTopLeftRadius: 24, borderTopRightRadius: 24,
    padding: SPACING.xl, paddingBottom: 40, maxHeight: '85%',
  },
  handle:        {
    width: 40, height: 4, borderRadius: 2, backgroundColor: COLORS.border,
    alignSelf: 'center', marginBottom: 20,
  },
  sheetHeader:   { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', marginBottom: 20 },
  sheetTitle:    { fontFamily: FONTS.title, fontSize: 18, color: COLORS.text },
  label:         { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted2, marginBottom: 10 },

  typeRow:        { flexDirection: 'row', gap: 12, marginBottom: 20 },
  typeBtn:        {
    flex: 1, alignItems: 'center', padding: 14, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border, backgroundColor: COLORS.card2, gap: 4,
  },
  typeBtnActive:  { borderColor: COLORS.green, backgroundColor: COLORS.greenMuted },
  typeEmoji:      { fontSize: 24 },
  typeLabel:      { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.muted2 },
  typeLabelActive: { color: COLORS.green },
  typeDesc:       { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted },

  noEvents:      { alignItems: 'center', gap: 8, paddingVertical: 20, marginBottom: 12 },
  noEventsText:  { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted, textAlign: 'center' },

  eventCard:      {
    width: 150, padding: 12, borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: COLORS.border, backgroundColor: COLORS.card2, marginRight: 10,
  },
  eventCardActive: { borderColor: COLORS.green, backgroundColor: COLORS.greenMuted },
  eventDate:      { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.text, marginBottom: 4 },
  eventTimeRow:   { flexDirection: 'row', alignItems: 'center', gap: 4, marginBottom: 4 },
  eventTime:      { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted },
  eventAddr:      { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted2 },

  inputRow:       {
    flexDirection: 'row', alignItems: 'center', gap: 10,
    backgroundColor: COLORS.card2, borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: COLORS.border,
    paddingHorizontal: 14, paddingVertical: 10, marginBottom: 16,
  },
  input:          { flex: 1, fontFamily: FONTS.body, fontSize: 14, color: COLORS.text },

  sendBtn:        {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 10,
    backgroundColor: COLORS.green, borderRadius: RADIUS.md,
    paddingVertical: 14, marginTop: 8,
  },
  sendBtnText:    { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.bg },
});
