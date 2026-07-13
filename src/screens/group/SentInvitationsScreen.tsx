import {
  ArrowLeft,
  Calendar,
  Clock,
  DollarSign,
  MapPin,
  Trash2,
  UserMinus,
  Users,
} from 'lucide-react-native';
import React, { useCallback, useEffect, useState } from 'react';
import {
  ActivityIndicator,
  Alert,
  Image,
  Pressable,
  RefreshControl,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import Particles from '../../components/ui/Particles';
import { supabase } from '../../config/supabase';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';

// ─── Types ────────────────────────────────────────────────────────────────────

interface SentInvitation {
  id: string;
  status: 'pending' | 'accepted' | 'rejected';
  invited_user_id: string | null;
  event_id: string | null;
  proposed_payment_amount: number | null;
  message: string | null;
  created_at: string;
  talent: {
    full_name: string;
    avatar_url: string | null;
  } | null;
  event: {
    event_date: string;
    address: string;
  } | null;
}

// ─── Screen ───────────────────────────────────────────────────────────────────

export default function SentInvitationsScreen({ navigation }: any) {
  const [invitations, setInvitations] = useState<SentInvitation[]>([]);
  const [groupId, setGroupId]         = useState<string | null>(null);
  const [loading, setLoading]         = useState(true);
  const [refreshing, setRefreshing]   = useState(false);

  useEffect(() => { load(); }, []);

  const load = async (isRefresh = false) => {
    if (isRefresh) setRefreshing(true); else setLoading(true);

    const { data: grp } = await supabase.rpc('get_my_group').maybeSingle();
    const gid = (grp as any)?.id ?? null;
    setGroupId(gid);

    if (gid) {
      const { data, error } = await supabase
        .from('job_invitations')
        .select(`
          id,
          status,
          invited_user_id,
          event_id,
          proposed_payment_amount,
          message,
          created_at,
          talent:invited_user_id (full_name, avatar_url),
          event:event_id (event_date, address)
        `)
        .eq('group_id', gid)
        .order('created_at', { ascending: false });

      if (!error && data) {
        setInvitations(data as unknown as SentInvitation[]);
      }
    }

    if (isRefresh) setRefreshing(false); else setLoading(false);
  };

  // Shared delete via SECURITY DEFINER RPC (bypasses RLS issues)
  const deleteInvitation = async (id: string): Promise<string | null> => {
    const { data, error } = await supabase
      .rpc('delete_group_invitation', { p_invitation_id: id });
    if (error) return error.message;
    if ((data as any)?.error) return (data as any).error;
    return null;
  };

  // Cancel a pending invitation
  const handleCancel = useCallback((inv: SentInvitation) => {
    const type = inv.event_id ? 'para la tocada' : 'de membresía';
    Alert.alert(
      'Cancelar invitación',
      `¿Cancelar la invitación ${type} a ${inv.talent?.full_name ?? 'este talento'}?`,
      [
        { text: 'No', style: 'cancel' },
        {
          text: 'Sí, cancelar',
          style: 'destructive',
          onPress: async () => {
            const err = await deleteInvitation(inv.id);
            if (err) { Alert.alert('Error', err); }
            else { setInvitations(prev => prev.filter(i => i.id !== inv.id)); }
          },
        },
      ]
    );
  }, []);

  // Remove an accepted member / tocada talent
  const handleRemove = useCallback((inv: SentInvitation) => {
    const isMember = !inv.event_id;
    const title   = isMember ? 'Quitar integrante' : 'Quitar de tocada';
    const msg     = isMember
      ? `¿Quitar a ${inv.talent?.full_name ?? 'este talento'} del grupo?`
      : `¿Quitar a ${inv.talent?.full_name ?? 'este talento'} de la tocada?`;
    Alert.alert(title, msg, [
      { text: 'Cancelar', style: 'cancel' },
      {
        text: 'Sí, quitar',
        style: 'destructive',
        onPress: async () => {
          const err = await deleteInvitation(inv.id);
          if (err) { Alert.alert('Error', err); }
          else { setInvitations(prev => prev.filter(i => i.id !== inv.id)); }
        },
      },
    ]);
  }, []);

  // ── Stats ─────────────────────────────────────────────────────────────────
  const accepted = invitations.filter(i => i.status === 'accepted').length;
  const pending  = invitations.filter(i => i.status === 'pending').length;
  const rejected = invitations.filter(i => i.status === 'rejected').length;

  // Sort: accepted first, then pending, then rejected
  const sorted = [
    ...invitations.filter(i => i.status === 'accepted'),
    ...invitations.filter(i => i.status === 'pending'),
    ...invitations.filter(i => i.status === 'rejected'),
  ];

  return (
    <View style={s.container}>
      <Particles />
      <SafeAreaView style={{ flex: 1 }}>

        {/* Header */}
        <View style={s.header}>
          <Pressable style={s.backBtn} onPress={() => navigation.goBack()}>
            <ArrowLeft size={20} color={COLORS.text} />
          </Pressable>
          <View style={s.headerTitle}>
            <Users size={18} color={COLORS.green} />
            <Text style={s.headerTitleText}>Gestión de Talentos</Text>
          </View>
          <View style={{ width: 40 }} />
        </View>

        {loading ? (
          <View style={s.center}>
            <ActivityIndicator size="large" color={COLORS.green} />
            <Text style={s.loadingText}>Cargando...</Text>
          </View>
        ) : (
          <ScrollView
            showsVerticalScrollIndicator={false}
            contentContainerStyle={s.list}
            refreshControl={
              <RefreshControl
                refreshing={refreshing}
                onRefresh={() => load(true)}
                tintColor={COLORS.green}
              />
            }
          >
            {/* Stats row */}
            <View style={s.statsRow}>
              <StatChip label="Aceptadas"  value={accepted} color={COLORS.green} />
              <StatChip label="Pendientes" value={pending}  color={COLORS.muted2} />
              <StatChip label="Rechazadas" value={rejected} color={COLORS.red} />
            </View>

            {sorted.length === 0 ? (
              <View style={s.emptySection}>
                <Text style={s.emptyIcon}>📬</Text>
                <Text style={s.emptyTitle}>Sin invitaciones</Text>
                <Text style={s.emptyText}>
                  Aún no has enviado invitaciones a ningún talento.
                </Text>
              </View>
            ) : (
              sorted.map(inv => (
                <InvitationCard
                  key={inv.id}
                  invitation={inv}
                  onCancel={() => handleCancel(inv)}
                  onRemove={() => handleRemove(inv)}
                  onChat={groupId && inv.invited_user_id
                    ? () => navigation.navigate('GroupChat', {
                        groupId, mode: 'dm', peerId: inv.invited_user_id,
                      })
                    : undefined}
                />
              ))
            )}

            <View style={{ height: 20 }} />
          </ScrollView>
        )}
      </SafeAreaView>
    </View>
  );
}

// ─── Stat Chip ────────────────────────────────────────────────────────────────

function StatChip({ label, value, color }: { label: string; value: number; color: string }) {
  return (
    <View style={chip.container}>
      <Text style={[chip.value, { color }]}>{value}</Text>
      <Text style={chip.label}>{label}</Text>
    </View>
  );
}

// ─── Invitation Card ──────────────────────────────────────────────────────────

function InvitationCard({
  invitation: inv,
  onCancel,
  onRemove,
  onChat,
}: {
  invitation: SentInvitation;
  onCancel: () => void;
  onRemove: () => void;
  onChat?: () => void;
}) {
  const isPending  = inv.status === 'pending';
  const isAccepted = inv.status === 'accepted';
  // Use truthiness check (handles both null and undefined from PostgREST)
  const isTocada   = !!inv.event_id;

  const statusColor =
    isAccepted              ? COLORS.green  :
    inv.status === 'rejected' ? COLORS.red    :
    COLORS.muted2;

  const statusLabel =
    isAccepted              ? '✅ Aceptada'  :
    inv.status === 'rejected' ? '❌ Rechazada' :
    '⏳ Pendiente';

  const initial    = inv.talent?.full_name?.charAt(0)?.toUpperCase() ?? '?';
  const avatarUrl  = inv.talent?.avatar_url ?? null;

  return (
    <View style={icard.container}>
      {/* Top: avatar + name + badges */}
      <View style={icard.topRow}>
        <View style={icard.avatar}>
          {avatarUrl ? (
            <Image source={{ uri: avatarUrl }} style={icard.avatarImg} />
          ) : (
            <Text style={icard.avatarText}>{initial}</Text>
          )}
        </View>
        <View style={{ flex: 1 }}>
          <Text style={icard.name}>{inv.talent?.full_name ?? '—'}</Text>
          <View style={icard.badges}>
            <View style={[icard.typeBadge, isTocada && icard.typeBadgeTocada]}>
              <Text style={[icard.typeBadgeText, isTocada && icard.typeBadgeTextTocada]}>
                {isTocada ? '🎵 Tocada' : '🎸 Membresía'}
              </Text>
            </View>
            <View style={[icard.statusBadge, { borderColor: statusColor }]}>
              <Text style={[icard.statusText, { color: statusColor }]}>{statusLabel}</Text>
            </View>
          </View>
        </View>

        {/* Cancel button — pending only */}
        {isPending && (
          <Pressable style={icard.cancelBtn} onPress={onCancel}>
            <Trash2 size={16} color={COLORS.red} />
          </Pressable>
        )}

        {/* Chat 1:1 con el talento — accepted only */}
        {isAccepted && onChat && (
          <Pressable style={icard.chatBtn} onPress={onChat} hitSlop={6}>
            <Text style={{ fontSize: 14 }}>💬</Text>
          </Pressable>
        )}

        {/* Remove button — accepted only */}
        {isAccepted && (
          <Pressable style={icard.removeBtn} onPress={onRemove}>
            <UserMinus size={16} color={COLORS.red} />
          </Pressable>
        )}
      </View>

      {/* Event info (tocada only) */}
      {isTocada && inv.event && (
        <View style={icard.infoRow}>
          <View style={icard.infoItem}>
            <Calendar size={13} color={COLORS.muted} />
            <Text style={icard.infoText}>{inv.event.event_date}</Text>
          </View>
          {inv.event.address ? (
            <View style={icard.infoItem}>
              <MapPin size={13} color={COLORS.muted} />
              <Text style={icard.infoText} numberOfLines={1}>{inv.event.address}</Text>
            </View>
          ) : null}
        </View>
      )}

      {/* Payment + date */}
      <View style={icard.infoRow}>
        {inv.proposed_payment_amount != null && (
          <View style={icard.infoItem}>
            <DollarSign size={13} color={COLORS.green} />
            <Text style={[icard.infoText, { color: COLORS.green }]}>
              ${inv.proposed_payment_amount.toLocaleString()}
            </Text>
          </View>
        )}
        <View style={icard.infoItem}>
          <Clock size={13} color={COLORS.muted} />
          <Text style={icard.infoText}>
            {new Date(inv.created_at).toLocaleDateString('es-MX', {
              day: '2-digit', month: 'short', year: 'numeric',
            })}
          </Text>
        </View>
      </View>

      {/* Message */}
      {inv.message ? (
        <Text style={icard.message} numberOfLines={2}>"{inv.message}"</Text>
      ) : null}
    </View>
  );
}

// ─── Styles ───────────────────────────────────────────────────────────────────

const s = StyleSheet.create({
  container:       { flex: 1, backgroundColor: COLORS.bg },
  center:          { flex: 1, alignItems: 'center', justifyContent: 'center', gap: 10 },
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
  headerTitle:     { flexDirection: 'row', alignItems: 'center', gap: 8 },
  headerTitleText: { fontFamily: FONTS.bodySemiBold, fontSize: 16, color: COLORS.text },
  loadingText:     { fontFamily: FONTS.body, fontSize: 14, color: COLORS.muted2, marginTop: 12 },
  list:            { padding: SPACING.xl, gap: 10, paddingBottom: 40 },
  statsRow:        { flexDirection: 'row', gap: 10, marginBottom: 4 },
  emptySection: {
    alignItems: 'center', paddingVertical: 40,
    backgroundColor: COLORS.card, borderRadius: RADIUS.xl,
    borderWidth: 1, borderColor: COLORS.border,
  },
  emptyIcon:  { fontSize: 36, marginBottom: 8 },
  emptyTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 16, color: COLORS.text, marginBottom: 4 },
  emptyText:  { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2, textAlign: 'center', paddingHorizontal: 20 },
});

const chip = StyleSheet.create({
  container: {
    flex: 1, alignItems: 'center', paddingVertical: 10,
    backgroundColor: COLORS.card, borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: COLORS.border,
  },
  value: { fontFamily: FONTS.title, fontSize: 20 },
  label: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted, marginTop: 2 },
});

const icard = StyleSheet.create({
  container: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border,
    padding: SPACING.lg, gap: 10,
  },
  topRow:    { flexDirection: 'row', alignItems: 'flex-start', gap: 12 },
  avatar: {
    width: 44, height: 44, borderRadius: 22,
    backgroundColor: COLORS.greenMuted, borderWidth: 1, borderColor: COLORS.green,
    alignItems: 'center', justifyContent: 'center', overflow: 'hidden',
  },
  avatarImg:   { width: 44, height: 44, borderRadius: 22 },
  avatarText:  { fontFamily: FONTS.title, fontSize: 18, color: COLORS.green },
  name:        { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.text, marginBottom: 5 },
  badges:      { flexDirection: 'row', gap: 8, flexWrap: 'wrap' },
  typeBadge: {
    paddingHorizontal: 10, paddingVertical: 3, borderRadius: RADIUS.full,
    backgroundColor: COLORS.card2, borderWidth: 1, borderColor: COLORS.border,
  },
  typeBadgeTocada:     { borderColor: COLORS.green, backgroundColor: COLORS.greenMuted },
  typeBadgeText:       { fontFamily: FONTS.bodyMedium, fontSize: 11, color: COLORS.muted2 },
  typeBadgeTextTocada: { color: COLORS.green },
  statusBadge: {
    paddingHorizontal: 10, paddingVertical: 3, borderRadius: RADIUS.full,
    borderWidth: 1,
  },
  statusText: { fontFamily: FONTS.bodyMedium, fontSize: 11 },
  cancelBtn: {
    width: 36, height: 36, borderRadius: 10,
    backgroundColor: 'rgba(239,83,80,0.1)',
    borderWidth: 1, borderColor: 'rgba(239,83,80,0.3)',
    alignItems: 'center', justifyContent: 'center',
  },
  removeBtn: {
    width: 36, height: 36, borderRadius: 10,
    backgroundColor: 'rgba(239,83,80,0.1)',
    borderWidth: 1, borderColor: 'rgba(239,83,80,0.3)',
    alignItems: 'center', justifyContent: 'center',
  },
  chatBtn: {
    width: 36, height: 36, borderRadius: 10, marginRight: 6,
    backgroundColor: 'rgba(0,230,118,0.08)',
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.35)',
    alignItems: 'center', justifyContent: 'center',
  },
  infoRow:   { flexDirection: 'row', gap: 16, flexWrap: 'wrap' },
  infoItem:  { flexDirection: 'row', alignItems: 'center', gap: 5 },
  infoText:  { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2 },
  message: {
    fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted,
    fontStyle: 'italic', lineHeight: 18,
  },
});
