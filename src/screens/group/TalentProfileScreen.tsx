import {
  ArrowLeft,
  Calendar,
  CheckCircle,
  Clock,
  DollarSign,
  ExternalLink,
  MapPin,
  MessageSquare,
  Music2,
  Send,
  Star,
  X,
} from 'lucide-react-native';
import VideoPlayer from '../../components/ui/VideoPlayer';
import React, { useEffect, useState } from 'react';
import {
  ActivityIndicator,
  Alert,
  Image,
  KeyboardAvoidingView,
  Linking,
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
import { useTranslation } from 'react-i18next';
import { supabase } from '../../config/supabase';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';

// ─── Types ────────────────────────────────────────────────────────────────────

interface TalentFull {
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
  id: string;
  event_id: string;
  event_date: string;
  event_time: string | null;
  address: string;
}

type InviteType = 'event' | 'membership';

// ─── Screen ───────────────────────────────────────────────────────────────────

export default function TalentProfileScreen({ route, navigation }: any) {
  const { t } = useTranslation();
  const { talent, isUsa, groupId, canInvite } = route.params as {
    talent: TalentFull;
    isUsa: boolean;
    groupId: string | null;
    canInvite: boolean;
  };

  const isAvailable = talent.availability_status === 'available';
  const initial     = talent.full_name?.charAt(0)?.toUpperCase() ?? '?';

  // VideoPlayer (expo-video) libera su propio reproductor al desmontarse —
  // ya no hace falta un ref + limpieza manual como con expo-av.

  // Invite modal state
  const [modalVisible, setModalVisible]   = useState(false);
  const [inviteType, setInviteType]       = useState<InviteType>('event');
  const [events, setEvents]               = useState<GroupEvent[]>([]);
  const [selectedEvent, setSelectedEvent] = useState<GroupEvent | null>(null);
  const [payment, setPayment]             = useState('');
  const [message, setMessage]             = useState('');
  const [sending, setSending]             = useState(false);
  const [loadingEvents, setLoadingEvents] = useState(false);

  const openInviteModal = async () => {
    setInviteType('event');
    setSelectedEvent(null);
    setPayment('');
    setMessage('');

    if (groupId) {
      setLoadingEvents(true);
      const today = new Date().toISOString().split('T')[0];
      const { data } = await supabase
        .from('reservations')
        .select('id, event_id, event_date, event_time, address')
        .eq('group_id', groupId)
        .eq('status', 'confirmed')
        .gte('event_date', today)
        .order('event_date', { ascending: true });
      setEvents((data as GroupEvent[]) ?? []);
      setLoadingEvents(false);
    }

    setModalVisible(true);
  };

  const sendInvitation = async () => {
    if (!groupId) return;
    if (inviteType === 'event' && !selectedEvent) {
      Alert.alert(t('talentProfileScreen.error'), t('talentProfileScreen.selectEventRequired'));
      return;
    }
    if (inviteType === 'event' && selectedEvent && !selectedEvent.event_id) {
      Alert.alert(t('talentProfileScreen.error'), t('talentProfileScreen.invalidEventId'));
      return;
    }

    setSending(true);
    const payload: any = {
      group_id:                groupId,
      invited_user_id:         talent.user_id,
      proposed_payment_amount: payment ? parseFloat(payment) : null,
      message:                 message.trim() || null,
      status:                  'pending',
      event_id:                inviteType === 'event' && selectedEvent ? selectedEvent.event_id : null,
      // Hallazgo real (2026-09-05): este campo nunca se mandaba, así que
      // TODA invitación (incluso eligiendo "membresía" en este modal)
      // se guardaba con el default de la columna ('event') — nunca había
      // existido una sola fila invitation_type='membership' en producción.
      invitation_type:         inviteType,
    };

    const { error } = await supabase.from('job_invitations').insert(payload);
    setSending(false);

    if (error) {
      if (error.code === '23505') {
        Alert.alert(t('talentProfileScreen.notice'), t('talentProfileScreen.duplicateInvite'));
      } else {
        Alert.alert(t('talentProfileScreen.error'), error.message);
      }
    } else {
      setModalVisible(false);
      Alert.alert(
        t('talentProfileScreen.invitationSentTitle'),
        t('talentProfileScreen.invitationSentMessage', { name: talent.full_name })
      );
    }
  };

  const openSocial = (url: string) => {
    const fullUrl = url.startsWith('http') ? url : `https://${url}`;
    Linking.openURL(fullUrl).catch(() =>
      Alert.alert(t('talentProfileScreen.error'), t('talentProfileScreen.linkError'))
    );
  };

  function formatDistance(km: number): string {
    if (isUsa) {
      const mi = km * 0.621371;
      return mi < 10 ? `${mi.toFixed(1)} mi` : `${Math.round(mi)} mi`;
    }
    return km < 10 ? `${km.toFixed(1)} km` : `${Math.round(km)} km`;
  }

  return (
    <View style={s.container}>
      <SafeAreaView style={{ flex: 1 }}>

        {/* HEADER */}
        <View style={s.header}>
          <Pressable style={s.backBtn} onPress={() => navigation.goBack()}>
            <ArrowLeft size={20} color={COLORS.text} />
          </Pressable>
          <Text style={s.headerTitle}>{t('talentProfileScreen.headerTitle')}</Text>
          <View style={{ width: 40 }} />
        </View>

        <ScrollView showsVerticalScrollIndicator={false} contentContainerStyle={s.scroll}>

          {/* ── HERO ── */}
          <View style={s.heroCard}>
            {/* Avatar */}
            <View style={s.avatarSection}>
              {talent.avatar_url ? (
                <Image source={{ uri: talent.avatar_url }} style={s.avatar} />
              ) : (
                <View style={s.avatarFallback}>
                  <Text style={s.avatarInitial}>{initial}</Text>
                </View>
              )}
              <View style={[s.availDot, !isAvailable && s.availDotBusy]} />
            </View>

            {/* Name + role + availability */}
            <Text style={s.heroName}>{talent.full_name}</Text>
            <Text style={s.heroRole}>{talent.instrument_or_role}</Text>

            {/* Badges row */}
            <View style={s.badgesRow}>
              <View style={[s.availBadge, !isAvailable && s.availBadgeBusy]}>
                <Text style={[s.availBadgeText, !isAvailable && s.availBadgeTextBusy]}>
                  {isAvailable ? t('talentProfileScreen.available') : t('talentProfileScreen.busy')}
                </Text>
              </View>
              {talent.distance_km != null && (
                <View style={s.distBadge}>
                  <MapPin size={11} color={COLORS.green} />
                  <Text style={s.distBadgeText}>{formatDistance(talent.distance_km)}</Text>
                </View>
              )}
              {talent.city && (
                <View style={s.cityBadge}>
                  <MapPin size={11} color={COLORS.muted} />
                  <Text style={s.cityBadgeText}>{talent.city}</Text>
                </View>
              )}
            </View>
          </View>

          {/* ── STATS ── */}
          <View style={s.statsCard}>
            <View style={s.statItem}>
              <Star size={16} color={COLORS.green} fill={COLORS.green} />
              <Text style={s.statValue}>{talent.rating?.toFixed(1) ?? '5.0'}</Text>
              <Text style={s.statLabel}>{t('talentProfileScreen.rating')}</Text>
            </View>
            <View style={s.statDivider} />
            <View style={s.statItem}>
              <Music2 size={16} color={COLORS.green} />
              <Text style={s.statValue}>{talent.total_jobs}</Text>
              <Text style={s.statLabel}>{t('talentProfileScreen.jobs')}</Text>
            </View>
            <View style={s.statDivider} />
            <View style={s.statItem}>
              <Clock size={16} color={COLORS.green} />
              <Text style={s.statValue}>{talent.experience_years}</Text>
              <Text style={s.statLabel}>{t('talentProfileScreen.experience')}</Text>
            </View>
          </View>

          {/* ── BIO ── */}
          {talent.bio ? (
            <View style={s.section}>
              <Text style={s.sectionTitle}>{t('talentProfileScreen.about')}</Text>
              <Text style={s.bioText}>{talent.bio}</Text>
            </View>
          ) : null}

          {/* ── ESTILOS MUSICALES ── */}
          {talent.musical_styles && talent.musical_styles.length > 0 && (
            <View style={s.section}>
              <Text style={s.sectionTitle}>{t('talentProfileScreen.musicalStyles')}</Text>
              <View style={s.stylesRow}>
                {talent.musical_styles.map((style, i) => (
                  <View key={i} style={s.styleChip}>
                    <Text style={s.styleChipText}>{style}</Text>
                  </View>
                ))}
              </View>
            </View>
          )}

          {/* ── VIDEO PROFESIONAL ── */}
          {talent.video_url ? (
            <View style={s.section}>
              <Text style={s.sectionTitle}>{t('talentProfileScreen.videoSectionTitle')}</Text>
              <VideoPlayer
                uri={talent.video_url}
                style={s.video}
                nativeControls
                contentFit="contain"
              />
            </View>
          ) : null}

          {/* ── REDES SOCIALES ── */}
          {(talent.social_instagram || talent.social_tiktok) && (
            <View style={s.section}>
              <Text style={s.sectionTitle}>{t('talentProfileScreen.socialSectionTitle')}</Text>
              <View style={s.socialRow}>
                {talent.social_instagram && (
                  <Pressable
                    style={s.socialBtn}
                    onPress={() => openSocial(`https://instagram.com/${talent.social_instagram!.replace('@', '')}`)}
                  >
                    <Text style={s.socialIcon}>📷</Text>
                    <Text style={s.socialLabel} numberOfLines={1}>
                      @{talent.social_instagram.replace('@', '')}
                    </Text>
                    <ExternalLink size={13} color={COLORS.muted} />
                  </Pressable>
                )}
                {talent.social_tiktok && (
                  <Pressable
                    style={s.socialBtn}
                    onPress={() => openSocial(`https://tiktok.com/@${talent.social_tiktok!.replace('@', '')}`)}
                  >
                    <Text style={s.socialIcon}>🎵</Text>
                    <Text style={s.socialLabel} numberOfLines={1}>
                      @{talent.social_tiktok.replace('@', '')}
                    </Text>
                    <ExternalLink size={13} color={COLORS.muted} />
                  </Pressable>
                )}
              </View>
            </View>
          )}

          {/* Bottom padding */}
          <View style={{ height: canInvite ? 100 : 32 }} />
        </ScrollView>

        {/* ── INVITE BUTTON (fixed bottom) ── */}
        {canInvite && (
          <View style={s.inviteBarWrap}>
            <View style={s.inviteBar}>
              <Pressable style={s.inviteBtnTocada} onPress={() => { setInviteType('event'); openInviteModal(); }}>
                <Text style={s.inviteBtnText}>{t('talentProfileScreen.inviteForGig')}</Text>
              </Pressable>
              <Pressable style={s.inviteBtnGrupo} onPress={() => { setInviteType('membership'); openInviteModal(); }}>
                <Text style={s.inviteBtnText}>{t('talentProfileScreen.inviteToGroup')}</Text>
              </Pressable>
            </View>
          </View>
        )}
      </SafeAreaView>

      {/* ── INVITE MODAL ── */}
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

            <View style={modal.header}>
              <Text style={modal.title}>{t('talentProfileScreen.modalTitle', { name: talent.full_name })}</Text>
              <Pressable onPress={() => setModalVisible(false)}>
                <X size={20} color={COLORS.muted} />
              </Pressable>
            </View>

            <ScrollView showsVerticalScrollIndicator={false}>
              {/* Invite type selector */}
              <Text style={modal.label}>{t('talentProfileScreen.inviteTypeLabel')}</Text>
              <View style={modal.typeRow}>
                <Pressable
                  style={[modal.typeBtn, inviteType === 'event' && modal.typeBtnActive]}
                  onPress={() => setInviteType('event')}
                >
                  <Text style={modal.typeEmoji}>🎵</Text>
                  <Text style={[modal.typeLabel, inviteType === 'event' && modal.typeLabelActive]}>
                    {t('talentProfileScreen.typeGigLabel')}
                  </Text>
                  <Text style={modal.typeDesc}>{t('talentProfileScreen.typeGigDesc')}</Text>
                </Pressable>
                <Pressable
                  style={[modal.typeBtn, inviteType === 'membership' && modal.typeBtnActive]}
                  onPress={() => setInviteType('membership')}
                >
                  <Text style={modal.typeEmoji}>🎸</Text>
                  <Text style={[modal.typeLabel, inviteType === 'membership' && modal.typeLabelActive]}>
                    {t('talentProfileScreen.typeMembershipLabel')}
                  </Text>
                  <Text style={modal.typeDesc}>{t('talentProfileScreen.typeMembershipDesc')}</Text>
                </Pressable>
              </View>

              {/* Event selector */}
              {inviteType === 'event' && (
                <View>
                  <Text style={modal.label}>{t('talentProfileScreen.selectEventLabel')}</Text>
                  {loadingEvents ? (
                    <ActivityIndicator size="small" color={COLORS.green} style={{ marginBottom: 16 }} />
                  ) : events.length === 0 ? (
                    <View style={modal.noEvents}>
                      <Calendar size={20} color={COLORS.muted} />
                      <Text style={modal.noEventsText}>{t('talentProfileScreen.noEvents')}</Text>
                    </View>
                  ) : (
                    <ScrollView horizontal showsHorizontalScrollIndicator={false} style={{ marginBottom: 12 }}>
                      {events.map(ev => (
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
              <Text style={modal.label}>{t('talentProfileScreen.paymentLabel')}</Text>
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
              <Text style={modal.label}>{t('talentProfileScreen.messageLabel')}</Text>
              <View style={[modal.inputRow, { alignItems: 'flex-start', paddingTop: 12 }]}>
                <MessageSquare size={16} color={COLORS.muted} style={{ marginTop: 2 }} />
                <TextInput
                  style={[modal.input, { height: 80, textAlignVertical: 'top' }]}
                  placeholder={t('talentProfileScreen.messagePlaceholder')}
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
                  {sending ? t('talentProfileScreen.sending') : t('talentProfileScreen.sendInvitation')}
                </Text>
              </Pressable>
            </ScrollView>
          </View>
        </KeyboardAvoidingView>
      </Modal>
    </View>
  );
}

// ─── Styles ───────────────────────────────────────────────────────────────────

const s = StyleSheet.create({
  container: { flex: 1, backgroundColor: COLORS.bg },
  scroll:    { padding: SPACING.xl, paddingTop: 0 },

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

  // ── Hero card ──────────────────────────────────────────────────────────────
  heroCard: {
    alignItems: 'center',
    paddingVertical: SPACING.xl,
    marginBottom: 16,
  },
  avatarSection: { position: 'relative', marginBottom: 16 },
  avatar: {
    width: 110, height: 110, borderRadius: 55,
    borderWidth: 3, borderColor: COLORS.green,
  },
  avatarFallback: {
    width: 110, height: 110, borderRadius: 55,
    backgroundColor: COLORS.greenMuted, borderWidth: 3, borderColor: COLORS.green,
    alignItems: 'center', justifyContent: 'center',
  },
  avatarInitial: { fontFamily: FONTS.title, fontSize: 44, color: COLORS.green },
  availDot: {
    position: 'absolute', bottom: 4, right: 4,
    width: 18, height: 18, borderRadius: 9,
    backgroundColor: COLORS.green,
    borderWidth: 3, borderColor: COLORS.bg,
  },
  availDotBusy: { backgroundColor: '#EF5350' },

  heroName: { fontFamily: FONTS.title, fontSize: 24, color: COLORS.text, marginBottom: 4, textAlign: 'center' },
  heroRole: { fontFamily: FONTS.bodyMedium, fontSize: 15, color: COLORS.muted2, marginBottom: 14, textAlign: 'center' },

  badgesRow: { flexDirection: 'row', flexWrap: 'wrap', justifyContent: 'center', gap: 8 },
  availBadge: {
    paddingHorizontal: 12, paddingVertical: 5, borderRadius: RADIUS.full,
    backgroundColor: COLORS.greenMuted, borderWidth: 1, borderColor: COLORS.green,
  },
  availBadgeBusy: { backgroundColor: 'rgba(239,83,80,0.12)', borderColor: '#EF5350' },
  availBadgeText: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.green },
  availBadgeTextBusy: { color: '#EF5350' },
  distBadge: {
    flexDirection: 'row', alignItems: 'center', gap: 4,
    paddingHorizontal: 10, paddingVertical: 5, borderRadius: RADIUS.full,
    backgroundColor: COLORS.greenMuted, borderWidth: 1, borderColor: COLORS.green,
  },
  distBadgeText: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.green },
  cityBadge: {
    flexDirection: 'row', alignItems: 'center', gap: 4,
    paddingHorizontal: 10, paddingVertical: 5, borderRadius: RADIUS.full,
    backgroundColor: COLORS.card, borderWidth: 1, borderColor: COLORS.border,
  },
  cityBadgeText: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.muted2 },

  // ── Stats ──────────────────────────────────────────────────────────────────
  statsCard: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'space-around',
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border,
    paddingVertical: 18, marginBottom: 16,
  },
  statItem:    { flex: 1, alignItems: 'center', gap: 4 },
  statValue:   { fontFamily: FONTS.bodySemiBold, fontSize: 20, color: COLORS.text },
  statLabel:   { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted },
  statDivider: { width: 1, height: 36, backgroundColor: COLORS.border },

  // ── Sections ───────────────────────────────────────────────────────────────
  section: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border,
    padding: SPACING.lg, marginBottom: 16,
  },
  sectionTitle: {
    fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.text, marginBottom: 10,
  },
  bioText: { fontFamily: FONTS.body, fontSize: 14, color: COLORS.muted2, lineHeight: 21 },

  // ── Styles chips ───────────────────────────────────────────────────────────
  stylesRow: { flexDirection: 'row', flexWrap: 'wrap', gap: 8 },
  styleChip: {
    paddingHorizontal: 12, paddingVertical: 6, borderRadius: RADIUS.full,
    backgroundColor: COLORS.card2, borderWidth: 1, borderColor: COLORS.border,
  },
  styleChipText: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.muted2 },

  // ── Video ──────────────────────────────────────────────────────────────────
  video: {
    width: '100%', aspectRatio: 16 / 9,
    backgroundColor: '#000', borderRadius: RADIUS.md,
  },

  // ── Social ─────────────────────────────────────────────────────────────────
  socialRow: { gap: 10 },
  socialBtn: {
    flexDirection: 'row', alignItems: 'center', gap: 10,
    backgroundColor: COLORS.card2, borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: COLORS.border,
    paddingHorizontal: 14, paddingVertical: 12,
  },
  socialIcon:  { fontSize: 18 },
  socialLabel: { flex: 1, fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted2 },

  // ── Invite bar ─────────────────────────────────────────────────────────────
  inviteBarWrap: {
    position: 'absolute', bottom: 0, left: 0, right: 0,
    paddingBottom: Platform.OS === 'ios' ? 24 : 16,
    paddingHorizontal: SPACING.xl,
    paddingTop: 10,
    backgroundColor: COLORS.bg,
    borderTopWidth: 1, borderTopColor: COLORS.border,
  },
  inviteBar:     { flexDirection: 'row', gap: 10 },
  inviteBtnTocada: {
    flex: 1, backgroundColor: COLORS.green, borderRadius: RADIUS.md,
    paddingVertical: 14, alignItems: 'center', justifyContent: 'center',
  },
  inviteBtnGrupo: {
    flex: 1, backgroundColor: COLORS.green, borderRadius: RADIUS.md,
    paddingVertical: 14, alignItems: 'center', justifyContent: 'center',
    opacity: 0.82,
  },
  inviteBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.bg },
});

const modal = StyleSheet.create({
  overlay: { flex: 1, backgroundColor: 'rgba(0,0,0,0.5)' },
  sheet: {
    backgroundColor: COLORS.card, borderTopLeftRadius: 24, borderTopRightRadius: 24,
    padding: SPACING.xl, paddingBottom: 40, maxHeight: '85%',
  },
  handle: {
    width: 40, height: 4, borderRadius: 2, backgroundColor: COLORS.border,
    alignSelf: 'center', marginBottom: 20,
  },
  header:  { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', marginBottom: 20 },
  title:   { fontFamily: FONTS.title, fontSize: 18, color: COLORS.text },
  label:   { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted2, marginBottom: 10 },

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

  noEvents:     { alignItems: 'center', gap: 8, paddingVertical: 20, marginBottom: 12 },
  noEventsText: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted, textAlign: 'center' },

  eventCard: {
    width: 150, padding: 12, borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: COLORS.border, backgroundColor: COLORS.card2, marginRight: 10,
  },
  eventCardActive: { borderColor: COLORS.green, backgroundColor: COLORS.greenMuted },
  eventDate:    { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.text, marginBottom: 4 },
  eventTimeRow: { flexDirection: 'row', alignItems: 'center', gap: 4, marginBottom: 4 },
  eventTime:    { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted },
  eventAddr:    { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted2 },

  inputRow: {
    flexDirection: 'row', alignItems: 'center', gap: 10,
    backgroundColor: COLORS.card2, borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: COLORS.border,
    paddingHorizontal: 14, paddingVertical: 10, marginBottom: 16,
  },
  input: { flex: 1, fontFamily: FONTS.body, fontSize: 14, color: COLORS.text },

  sendBtn: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 8,
    backgroundColor: COLORS.green, borderRadius: RADIUS.md,
    paddingVertical: 14, marginTop: 4,
  },
  sendBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.bg },
});
