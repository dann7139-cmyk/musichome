import React, { useState, useEffect, useCallback } from 'react';
import {
  View,
  Text,
  StyleSheet,
  ScrollView,
  TouchableOpacity,
  Image,
  Alert,
  RefreshControl,
  ActivityIndicator,
  Platform,
} from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { LinearGradient } from 'expo-linear-gradient';
import { ArrowLeft, CheckCircle } from 'lucide-react-native';
import { supabase } from '../../config/supabase';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';
import VideoPlayer from '../../components/ui/VideoPlayer';

interface PendingGroup {
  id: string;
  name: string;
  profile_image: string | null;
  promo_video: string | null;
  photo_status: 'none' | 'pending' | 'approved' | 'rejected';
  video_status: 'none' | 'pending' | 'approved' | 'rejected';
  photo_reject_reason: string | null;
  video_reject_reason: string | null;
  owner_id: string;
}

const REJECT_REASONS = [
  'Número de teléfono visible',
  'Redes sociales visibles',
  'Contenido inapropiado',
  'Otro',
];

export default function MediaReviewScreen({ navigation }: { navigation: any; route: any }) {
  const [groups, setGroups] = useState<PendingGroup[]>([]);
  const [loading, setLoading] = useState(true);
  const [refreshing, setRefreshing] = useState(false);
  const [processingId, setProcessingId] = useState<string | null>(null);

  const fetchPending = useCallback(async () => {
    const { data, error } = await supabase
      .from('groups')
      .select('id, name, profile_image, promo_video, photo_status, video_status, photo_reject_reason, video_reject_reason, owner_id')
      .or('photo_status.eq.pending,video_status.eq.pending');

    if (!error && data) {
      setGroups(data as PendingGroup[]);
    }
  }, []);

  useEffect(() => {
    setLoading(true);
    fetchPending().finally(() => setLoading(false));
  }, [fetchPending]);

  const onRefresh = useCallback(async () => {
    setRefreshing(true);
    await fetchPending();
    setRefreshing(false);
  }, [fetchPending]);

  const sendNotification = async (ownerId: string, mediaType: 'foto' | 'video', reason: string) => {
    await supabase.from('notifications').insert({
      user_id: ownerId,
      type: 'system',
      title: mediaType === 'foto' ? '❌ Foto rechazada' : '❌ Video rechazado',
      body: `Tu ${mediaType} fue rechazado: ${reason}. Sube uno nuevo que cumpla los requisitos.`,
      data: { screen: 'Dashboard' },
    });
  };

  const removeOrUpdateGroup = (groupId: string, field: 'photo_status' | 'video_status') => {
    setGroups((prev) =>
      prev
        .map((g) => {
          if (g.id !== groupId) return g;
          const updated = { ...g, [field]: field === 'photo_status' ? 'approved' : 'approved' };
          return updated as PendingGroup;
        })
        .filter((g) => g.photo_status === 'pending' || g.video_status === 'pending'),
    );
  };

  // Photo actions
  const approvePhoto = async (group: PendingGroup) => {
    setProcessingId(group.id + '_photo');
    const { error } = await supabase
      .from('groups')
      .update({ photo_status: 'approved' })
      .eq('id', group.id);

    setProcessingId(null);
    if (error) {
      Alert.alert('Error', 'No se pudo aprobar la foto.');
      return;
    }
    setGroups((prev) =>
      prev
        .map((g) => (g.id === group.id ? { ...g, photo_status: 'approved' as const } : g))
        .filter((g) => g.photo_status === 'pending' || g.video_status === 'pending'),
    );
  };

  const rejectPhotoWithReason = async (group: PendingGroup, reason: string) => {
    setProcessingId(group.id + '_photo');
    const { error } = await supabase
      .from('groups')
      .update({ photo_status: 'rejected', photo_reject_reason: reason })
      .eq('id', group.id);

    if (!error) {
      await sendNotification(group.owner_id, 'foto', reason);
    }
    setProcessingId(null);
    if (error) {
      Alert.alert('Error', 'No se pudo rechazar la foto.');
      return;
    }
    setGroups((prev) =>
      prev
        .map((g) => (g.id === group.id ? { ...g, photo_status: 'rejected' as const } : g))
        .filter((g) => g.photo_status === 'pending' || g.video_status === 'pending'),
    );
  };

  const rejectPhoto = (group: PendingGroup) => {
    if (Platform.OS === 'ios') {
      Alert.prompt(
        'Rechazar foto',
        'Indica el motivo del rechazo:',
        [
          { text: 'Cancelar', style: 'cancel' },
          {
            text: 'Rechazar',
            style: 'destructive',
            onPress: (reason) => {
              if (reason && reason.trim()) {
                rejectPhotoWithReason(group, reason.trim());
              }
            },
          },
        ],
        'plain-text',
        '',
      );
    } else {
      Alert.alert('Rechazar foto', 'Selecciona el motivo del rechazo:', [
        ...REJECT_REASONS.map((r) => ({
          text: r,
          onPress: () => rejectPhotoWithReason(group, r),
        })),
        { text: 'Cancelar', style: 'cancel' as const },
      ]);
    }
  };

  // Video actions
  const approveVideo = async (group: PendingGroup) => {
    setProcessingId(group.id + '_video');
    const { error } = await supabase
      .from('groups')
      .update({ video_status: 'approved' })
      .eq('id', group.id);

    setProcessingId(null);
    if (error) {
      Alert.alert('Error', 'No se pudo aprobar el video.');
      return;
    }
    setGroups((prev) =>
      prev
        .map((g) => (g.id === group.id ? { ...g, video_status: 'approved' as const } : g))
        .filter((g) => g.photo_status === 'pending' || g.video_status === 'pending'),
    );
  };

  const rejectVideoWithReason = async (group: PendingGroup, reason: string) => {
    setProcessingId(group.id + '_video');
    const { error } = await supabase
      .from('groups')
      .update({ video_status: 'rejected', video_reject_reason: reason })
      .eq('id', group.id);

    if (!error) {
      await sendNotification(group.owner_id, 'video', reason);
    }
    setProcessingId(null);
    if (error) {
      Alert.alert('Error', 'No se pudo rechazar el video.');
      return;
    }
    setGroups((prev) =>
      prev
        .map((g) => (g.id === group.id ? { ...g, video_status: 'rejected' as const } : g))
        .filter((g) => g.photo_status === 'pending' || g.video_status === 'pending'),
    );
  };

  const rejectVideo = (group: PendingGroup) => {
    if (Platform.OS === 'ios') {
      Alert.prompt(
        'Rechazar video',
        'Indica el motivo del rechazo:',
        [
          { text: 'Cancelar', style: 'cancel' },
          {
            text: 'Rechazar',
            style: 'destructive',
            onPress: (reason) => {
              if (reason && reason.trim()) {
                rejectVideoWithReason(group, reason.trim());
              }
            },
          },
        ],
        'plain-text',
        '',
      );
    } else {
      Alert.alert('Rechazar video', 'Selecciona el motivo del rechazo:', [
        ...REJECT_REASONS.map((r) => ({
          text: r,
          onPress: () => rejectVideoWithReason(group, r),
        })),
        { text: 'Cancelar', style: 'cancel' as const },
      ]);
    }
  };

  const totalPending = groups.reduce((acc, g) => {
    let count = 0;
    if (g.photo_status === 'pending') count++;
    if (g.video_status === 'pending') count++;
    return acc + count;
  }, 0);

  return (
    <SafeAreaView style={styles.safeArea} edges={['top']}>
      {/* Header */}
      <View style={styles.header}>
        <TouchableOpacity onPress={() => navigation.goBack()} style={styles.backBtn}>
          <ArrowLeft size={22} color={COLORS.text} />
        </TouchableOpacity>
        <Text style={styles.headerTitle}>Revisión de Medios</Text>
        {totalPending > 0 ? (
          <View style={styles.badge}>
            <Text style={styles.badgeText}>{totalPending}</Text>
          </View>
        ) : (
          <View style={styles.badgePlaceholder} />
        )}
      </View>

      {loading ? (
        <View style={styles.centered}>
          <ActivityIndicator size="large" color={COLORS.green} />
        </View>
      ) : groups.length === 0 ? (
        <View style={styles.centered}>
          <CheckCircle size={48} color={COLORS.green} />
          <Text style={styles.emptyText}>Sin medios pendientes</Text>
        </View>
      ) : (
        <ScrollView
          style={styles.scroll}
          contentContainerStyle={styles.scrollContent}
          refreshControl={
            <RefreshControl
              refreshing={refreshing}
              onRefresh={onRefresh}
              tintColor={COLORS.green}
              colors={[COLORS.green]}
            />
          }
        >
          {groups.map((group) => (
            <View key={group.id} style={styles.card}>
              {/* Group name */}
              <Text style={styles.groupName}>{group.name}</Text>

              {/* Photo section */}
              {group.photo_status === 'pending' && (
                <View style={styles.section}>
                  <Text style={styles.sectionLabel}>FOTO DE PERFIL</Text>
                  {group.profile_image ? (
                    <Image
                      source={{ uri: group.profile_image }}
                      style={styles.photoPreview}
                      resizeMode="cover"
                    />
                  ) : (
                    <View style={[styles.photoPreview, styles.noMedia]}>
                      <Text style={styles.noMediaText}>Sin imagen</Text>
                    </View>
                  )}
                  <View style={styles.actionRow}>
                    <TouchableOpacity
                      style={[styles.btn, styles.btnApprove]}
                      onPress={() => approvePhoto(group)}
                      disabled={processingId === group.id + '_photo'}
                    >
                      {processingId === group.id + '_photo' ? (
                        <ActivityIndicator size="small" color={COLORS.bg} />
                      ) : (
                        <Text style={styles.btnApproveText}>✓ Aprobar foto</Text>
                      )}
                    </TouchableOpacity>
                    <TouchableOpacity
                      style={[styles.btn, styles.btnReject]}
                      onPress={() => rejectPhoto(group)}
                      disabled={processingId === group.id + '_photo'}
                    >
                      <Text style={styles.btnRejectText}>✗ Rechazar</Text>
                    </TouchableOpacity>
                  </View>
                </View>
              )}

              {/* Video section */}
              {group.video_status === 'pending' && (
                <View style={styles.section}>
                  <Text style={styles.sectionLabel}>VIDEO PROMOCIONAL</Text>
                  {group.promo_video ? (
                    <VideoPlayer uri={group.promo_video} style={styles.videoPreview} />
                  ) : (
                    <View style={[styles.videoPreview, styles.noMedia]}>
                      <Text style={styles.noMediaText}>Sin video</Text>
                    </View>
                  )}
                  <View style={styles.actionRow}>
                    <TouchableOpacity
                      style={[styles.btn, styles.btnApprove]}
                      onPress={() => approveVideo(group)}
                      disabled={processingId === group.id + '_video'}
                    >
                      {processingId === group.id + '_video' ? (
                        <ActivityIndicator size="small" color={COLORS.bg} />
                      ) : (
                        <Text style={styles.btnApproveText}>✓ Aprobar video</Text>
                      )}
                    </TouchableOpacity>
                    <TouchableOpacity
                      style={[styles.btn, styles.btnReject]}
                      onPress={() => rejectVideo(group)}
                      disabled={processingId === group.id + '_video'}
                    >
                      <Text style={styles.btnRejectText}>✗ Rechazar</Text>
                    </TouchableOpacity>
                  </View>
                </View>
              )}
            </View>
          ))}
        </ScrollView>
      )}
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  safeArea: {
    flex: 1,
    backgroundColor: COLORS.bg,
  },
  header: {
    flexDirection: 'row',
    alignItems: 'center',
    paddingHorizontal: SPACING.md,
    paddingVertical: SPACING.sm,
    borderBottomWidth: 1,
    borderBottomColor: COLORS.border,
  },
  backBtn: {
    padding: 4,
    marginRight: SPACING.sm,
  },
  headerTitle: {
    flex: 1,
    fontFamily: FONTS.title,
    fontSize: 18,
    color: COLORS.text,
  },
  badge: {
    backgroundColor: COLORS.green,
    borderRadius: RADIUS.full,
    minWidth: 24,
    height: 24,
    alignItems: 'center',
    justifyContent: 'center',
    paddingHorizontal: 6,
  },
  badgeText: {
    fontFamily: FONTS.bodySemiBold,
    fontSize: 12,
    color: COLORS.bg,
  },
  badgePlaceholder: {
    width: 24,
    height: 24,
  },
  centered: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    gap: 12,
  },
  emptyText: {
    fontFamily: FONTS.bodyMedium,
    fontSize: 16,
    color: COLORS.muted2,
    marginTop: 8,
  },
  scroll: {
    flex: 1,
  },
  scrollContent: {
    padding: SPACING.md,
    gap: SPACING.md,
    paddingBottom: SPACING.xxl,
  },
  card: {
    backgroundColor: COLORS.card,
    borderRadius: RADIUS.lg,
    borderWidth: 1,
    borderColor: COLORS.border,
    padding: SPACING.md,
    gap: SPACING.md,
  },
  groupName: {
    fontFamily: FONTS.bodySemiBold,
    fontSize: 15,
    color: COLORS.text,
  },
  section: {
    gap: 10,
  },
  sectionLabel: {
    fontFamily: FONTS.bodyMedium,
    fontSize: 11,
    color: COLORS.muted,
    letterSpacing: 0.8,
    textTransform: 'uppercase',
  },
  photoPreview: {
    width: '100%',
    height: 160,
    borderRadius: RADIUS.md,
    backgroundColor: COLORS.card2,
  },
  videoPreview: {
    width: '100%',
    height: 180,
    borderRadius: RADIUS.md,
    backgroundColor: COLORS.card2,
    overflow: 'hidden',
  },
  noMedia: {
    alignItems: 'center',
    justifyContent: 'center',
  },
  noMediaText: {
    fontFamily: FONTS.body,
    fontSize: 13,
    color: COLORS.muted,
  },
  actionRow: {
    flexDirection: 'row',
    gap: SPACING.xs,
  },
  btn: {
    paddingVertical: 8,
    paddingHorizontal: 16,
    borderRadius: RADIUS.md,
    alignItems: 'center',
    justifyContent: 'center',
    minHeight: 36,
  },
  btnApprove: {
    backgroundColor: COLORS.green,
  },
  btnApproveText: {
    fontFamily: FONTS.bodySemiBold,
    fontSize: 13,
    color: COLORS.bg,
  },
  btnReject: {
    backgroundColor: 'transparent',
    borderWidth: 1,
    borderColor: COLORS.red,
  },
  btnRejectText: {
    fontFamily: FONTS.bodySemiBold,
    fontSize: 13,
    color: COLORS.red,
  },
});
