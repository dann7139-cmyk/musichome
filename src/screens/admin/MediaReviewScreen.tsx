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
import { useTranslation } from 'react-i18next';
import type { TFunction } from 'i18next';
import { supabase } from '../../config/supabase';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';
import VideoPlayer from '../../components/ui/VideoPlayer';
import { useAdminClaims } from '../../hooks/useAdminClaims';
import { ClaimBar } from '../../components/ui/ClaimBar';

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

interface PendingEventPost {
  id: string;
  group_id: string;
  caption: string | null;
  photos: { id: string; url: string; position: number }[];
  groups: { name: string; owner_id: string } | null;
}

interface PendingVideo {
  id: string;
  group_id: string;
  url: string;
  groups: { name: string; owner_id: string } | null;
}

const getRejectReasons = (t: TFunction) => [
  t('adminMediaReviewScreen.rejectReasons.phoneVisible'),
  t('adminMediaReviewScreen.rejectReasons.socialVisible'),
  t('adminMediaReviewScreen.rejectReasons.inappropriate'),
  t('adminMediaReviewScreen.rejectReasons.other'),
];

export default function MediaReviewScreen({ navigation }: { navigation: any; route: any }) {
  const { t } = useTranslation();
  const REJECT_REASONS = getRejectReasons(t);
  const [groups, setGroups] = useState<PendingGroup[]>([]);
  const [eventPosts, setEventPosts] = useState<PendingEventPost[]>([]);
  const [pendingVideos, setPendingVideos] = useState<PendingVideo[]>([]);
  const [loading, setLoading] = useState(true);
  const [refreshing, setRefreshing] = useState(false);
  const [processingId, setProcessingId] = useState<string | null>(null);

  // sql/660 (2026-09-16) — "en trabajo", una entrada por cada elemento
  // aprobable de forma independiente (misma clave que ya usaba processingId).
  const claimIds = [
    ...groups.flatMap((g) => [
      g.photo_status === 'pending' ? g.id + '_photo' : null,
      g.video_status === 'pending' ? g.id + '_video' : null,
    ]),
    ...eventPosts.map((p) => p.id + '_eventpost'),
    ...pendingVideos.map((v) => v.id + '_carouselvideo'),
  ].filter((x): x is string => !!x);
  const { claims, claim, release, refresh: refreshClaims, busyId: claimBusyId } = useAdminClaims('media', claimIds);
  const isLockedByOther = (id: string) => { const c = claims[id]; return !!c && !c.is_mine; };

  // sql/641 (2026-09-11) — antes eran 3 queries directas sin filtro (RLS
  // restringía a role='admin', sin noción de país). Ahora es 1 sola RPC
  // que ya separa por país: admin_ops (EE.UU.) solo ve/aprueba lo suyo,
  // el admin completo sigue viendo todo igual que siempre.
  const fetchPending = useCallback(async () => {
    const { data, error } = await supabase.rpc('admin_get_pending_media', { p_limit: 50 });
    if (error || (data as any)?.ok === false) {
      console.warn('[MediaReview] admin_get_pending_media error:', error?.message ?? (data as any)?.error);
      return;
    }
    const result = data as any;
    setGroups((result.groups ?? []) as PendingGroup[]);
    setEventPosts((result.event_posts ?? []) as PendingEventPost[]);
    setPendingVideos((result.videos ?? []) as PendingVideo[]);
  }, []);

  useEffect(() => {
    setLoading(true);
    fetchPending().finally(() => setLoading(false));
  }, [fetchPending]);

  const onRefresh = useCallback(async () => {
    setRefreshing(true);
    await fetchPending();
    await refreshClaims();
    setRefreshing(false);
  }, [fetchPending, refreshClaims]);

  const sendNotification = async (ownerId: string, mediaType: 'foto' | 'video', reason: string) => {
    const mediaTypeLabel = mediaType === 'foto'
      ? t('adminMediaReviewScreen.notifications.mediaTypePhoto')
      : t('adminMediaReviewScreen.notifications.mediaTypeVideo');
    await supabase.from('notifications').insert({
      user_id: ownerId,
      type: 'system',
      title: mediaType === 'foto'
        ? t('adminMediaReviewScreen.notifications.photoRejectedTitle')
        : t('adminMediaReviewScreen.notifications.videoRejectedTitle'),
      body: t('adminMediaReviewScreen.notifications.rejectedBody', { mediaType: mediaTypeLabel, reason }),
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
    const { data: rpcData, error } = await supabase
      .rpc('approve_group_photo', { p_group_id: group.id });

    setProcessingId(null);
    if (error || (rpcData && rpcData.ok === false)) {
      Alert.alert(t('adminMediaReviewScreen.common.error'), t('adminMediaReviewScreen.errors.approvePhotoFailed'));
      return;
    }
    await release(group.id + '_photo');
    setGroups((prev) =>
      prev
        .map((g) => (g.id === group.id ? { ...g, photo_status: 'approved' as const } : g))
        .filter((g) => g.photo_status === 'pending' || g.video_status === 'pending'),
    );
  };

  const rejectPhotoWithReason = async (group: PendingGroup, reason: string) => {
    setProcessingId(group.id + '_photo');
    const { data: rpcData, error } = await supabase
      .rpc('reject_group_photo', { p_group_id: group.id, p_reason: reason });

    if (!error && !(rpcData && rpcData.ok === false)) {
      await sendNotification(group.owner_id, 'foto', reason);
    }
    setProcessingId(null);
    if (error || (rpcData && rpcData.ok === false)) {
      Alert.alert(t('adminMediaReviewScreen.common.error'), t('adminMediaReviewScreen.errors.rejectPhotoFailed'));
      return;
    }
    await release(group.id + '_photo');
    setGroups((prev) =>
      prev
        .map((g) => (g.id === group.id ? { ...g, photo_status: 'rejected' as const } : g))
        .filter((g) => g.photo_status === 'pending' || g.video_status === 'pending'),
    );
  };

  const rejectPhoto = (group: PendingGroup) => {
    if (Platform.OS === 'ios') {
      Alert.prompt(
        t('adminMediaReviewScreen.prompts.rejectPhotoTitle'),
        t('adminMediaReviewScreen.prompts.reasonPrompt'),
        [
          { text: t('adminMediaReviewScreen.common.cancel'), style: 'cancel' },
          {
            text: t('adminMediaReviewScreen.common.rejectAction'),
            style: 'destructive',
            onPress: (reason?: string) => {
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
      Alert.alert(t('adminMediaReviewScreen.prompts.rejectPhotoTitle'), t('adminMediaReviewScreen.prompts.reasonSelect'), [
        ...REJECT_REASONS.map((r) => ({
          text: r,
          onPress: () => rejectPhotoWithReason(group, r),
        })),
        { text: t('adminMediaReviewScreen.common.cancel'), style: 'cancel' as const },
      ]);
    }
  };

  // Video actions
  const approveVideo = async (group: PendingGroup) => {
    setProcessingId(group.id + '_video');
    const { data: rpcData, error } = await supabase
      .rpc('approve_group_video', { p_group_id: group.id });

    setProcessingId(null);
    if (error || (rpcData && rpcData.ok === false)) {
      Alert.alert(t('adminMediaReviewScreen.common.error'), t('adminMediaReviewScreen.errors.approveVideoFailed'));
      return;
    }
    await release(group.id + '_video');
    setGroups((prev) =>
      prev
        .map((g) => (g.id === group.id ? { ...g, video_status: 'approved' as const } : g))
        .filter((g) => g.photo_status === 'pending' || g.video_status === 'pending'),
    );
  };

  const rejectVideoWithReason = async (group: PendingGroup, reason: string) => {
    setProcessingId(group.id + '_video');
    const { data: rpcData, error } = await supabase
      .rpc('reject_group_video', { p_group_id: group.id, p_reason: reason });

    if (!error && !(rpcData && rpcData.ok === false)) {
      await sendNotification(group.owner_id, 'video', reason);
    }
    setProcessingId(null);
    if (error || (rpcData && rpcData.ok === false)) {
      Alert.alert(t('adminMediaReviewScreen.common.error'), t('adminMediaReviewScreen.errors.rejectVideoFailed'));
      return;
    }
    await release(group.id + '_video');
    setGroups((prev) =>
      prev
        .map((g) => (g.id === group.id ? { ...g, video_status: 'rejected' as const } : g))
        .filter((g) => g.photo_status === 'pending' || g.video_status === 'pending'),
    );
  };

  const rejectVideo = (group: PendingGroup) => {
    if (Platform.OS === 'ios') {
      Alert.prompt(
        t('adminMediaReviewScreen.prompts.rejectVideoTitle'),
        t('adminMediaReviewScreen.prompts.reasonPrompt'),
        [
          { text: t('adminMediaReviewScreen.common.cancel'), style: 'cancel' },
          {
            text: t('adminMediaReviewScreen.common.rejectAction'),
            style: 'destructive',
            onPress: (reason?: string) => {
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
      Alert.alert(t('adminMediaReviewScreen.prompts.rejectVideoTitle'), t('adminMediaReviewScreen.prompts.reasonSelect'), [
        ...REJECT_REASONS.map((r) => ({
          text: r,
          onPress: () => rejectVideoWithReason(group, r),
        })),
        { text: t('adminMediaReviewScreen.common.cancel'), style: 'cancel' as const },
      ]);
    }
  };

  // Event post actions (sql/561) — UPDATE directo, RLS ya restringe a admin
  const approveEventPost = async (post: PendingEventPost) => {
    setProcessingId(post.id + '_eventpost');
    const { error } = await supabase
      .from('group_event_posts')
      .update({ status: 'approved' })
      .eq('id', post.id);

    setProcessingId(null);
    if (error) {
      Alert.alert(t('adminMediaReviewScreen.common.error'), t('adminMediaReviewScreen.errors.approvePostFailed'));
      return;
    }
    await release(post.id + '_eventpost');
    setEventPosts((prev) => prev.filter((p) => p.id !== post.id));

    // 👥 Avisar a los seguidores del grupo (sql/563) que hay publicación nueva
    const { data: followers } = await supabase
      .from('group_follows')
      .select('user_id')
      .eq('group_id', post.group_id);
    if (followers && followers.length > 0) {
      await supabase.from('notifications').insert(
        followers.map((f: any) => ({
          user_id: f.user_id,
          type: 'system',
          title: t('adminMediaReviewScreen.notifications.newPostTitle'),
          body: t('adminMediaReviewScreen.notifications.newPostBody', {
            groupName: post.groups?.name ?? t('adminMediaReviewScreen.notifications.defaultGroupFollow'),
          }),
          data: { screen: 'GroupDetail', group_id: post.group_id },
        }))
      );
    }
  };

  const rejectEventPostWithReason = async (post: PendingEventPost, reason: string) => {
    setProcessingId(post.id + '_eventpost');
    const { error } = await supabase
      .from('group_event_posts')
      .update({ status: 'rejected', review_note: reason })
      .eq('id', post.id);

    if (!error && post.groups?.owner_id) {
      await sendNotification(post.groups.owner_id, 'foto', reason);
    }
    setProcessingId(null);
    if (error) {
      Alert.alert(t('adminMediaReviewScreen.common.error'), t('adminMediaReviewScreen.errors.rejectPostFailed'));
      return;
    }
    await release(post.id + '_eventpost');
    setEventPosts((prev) => prev.filter((p) => p.id !== post.id));
  };

  const rejectEventPost = (post: PendingEventPost) => {
    if (Platform.OS === 'ios') {
      Alert.prompt(
        t('adminMediaReviewScreen.prompts.rejectPostTitle'),
        t('adminMediaReviewScreen.prompts.reasonPrompt'),
        [
          { text: t('adminMediaReviewScreen.common.cancel'), style: 'cancel' },
          {
            text: t('adminMediaReviewScreen.common.rejectAction'),
            style: 'destructive',
            onPress: (reason?: string) => {
              if (reason && reason.trim()) {
                rejectEventPostWithReason(post, reason.trim());
              }
            },
          },
        ],
        'plain-text',
        '',
      );
    } else {
      Alert.alert(t('adminMediaReviewScreen.prompts.rejectPostTitle'), t('adminMediaReviewScreen.prompts.reasonSelect'), [
        ...REJECT_REASONS.map((r) => ({
          text: r,
          onPress: () => rejectEventPostWithReason(post, r),
        })),
        { text: t('adminMediaReviewScreen.common.cancel'), style: 'cancel' as const },
      ]);
    }
  };

  // 🎬 Video del carrusel — mismo patrón que event posts, UPDATE directo
  const approveVideoCarousel = async (video: PendingVideo) => {
    setProcessingId(video.id + '_carouselvideo');
    const { error } = await supabase
      .from('group_videos')
      .update({ status: 'approved' })
      .eq('id', video.id);

    setProcessingId(null);
    if (error) {
      Alert.alert(t('adminMediaReviewScreen.common.error'), t('adminMediaReviewScreen.errors.approveVideoFailed'));
      return;
    }
    await release(video.id + '_carouselvideo');
    setPendingVideos((prev) => prev.filter((v) => v.id !== video.id));
  };

  const rejectVideoCarouselWithReason = async (video: PendingVideo, reason: string) => {
    setProcessingId(video.id + '_carouselvideo');
    const { error } = await supabase
      .from('group_videos')
      .update({ status: 'rejected', review_note: reason })
      .eq('id', video.id);

    if (!error && video.groups?.owner_id) {
      await sendNotification(video.groups.owner_id, 'video', reason);
    }
    setProcessingId(null);
    if (error) {
      Alert.alert(t('adminMediaReviewScreen.common.error'), t('adminMediaReviewScreen.errors.rejectVideoFailed'));
      return;
    }
    await release(video.id + '_carouselvideo');
    setPendingVideos((prev) => prev.filter((v) => v.id !== video.id));
  };

  const rejectVideoCarousel = (video: PendingVideo) => {
    if (Platform.OS === 'ios') {
      Alert.prompt(
        t('adminMediaReviewScreen.prompts.rejectVideoTitle'),
        t('adminMediaReviewScreen.prompts.reasonPrompt'),
        [
          { text: t('adminMediaReviewScreen.common.cancel'), style: 'cancel' },
          {
            text: t('adminMediaReviewScreen.common.rejectAction'),
            style: 'destructive',
            onPress: (reason?: string) => {
              if (reason && reason.trim()) {
                rejectVideoCarouselWithReason(video, reason.trim());
              }
            },
          },
        ],
        'plain-text',
        '',
      );
    } else {
      Alert.alert(t('adminMediaReviewScreen.prompts.rejectVideoTitle'), t('adminMediaReviewScreen.prompts.reasonSelect'), [
        ...REJECT_REASONS.map((r) => ({
          text: r,
          onPress: () => rejectVideoCarouselWithReason(video, r),
        })),
        { text: t('adminMediaReviewScreen.common.cancel'), style: 'cancel' as const },
      ]);
    }
  };

  const totalPending = groups.reduce((acc, g) => {
    let count = 0;
    if (g.photo_status === 'pending') count++;
    if (g.video_status === 'pending') count++;
    return acc + count;
  }, 0) + eventPosts.length + pendingVideos.length;

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
      ) : groups.length === 0 && eventPosts.length === 0 && pendingVideos.length === 0 ? (
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
                  <ClaimBar
                    claim={claims[group.id + '_photo']}
                    busy={claimBusyId === group.id + '_photo'}
                    onClaim={() => claim(group.id + '_photo')}
                    onRelease={() => release(group.id + '_photo')}
                  />
                  <View style={styles.actionRow}>
                    <TouchableOpacity
                      style={[styles.btn, styles.btnApprove]}
                      onPress={() => approvePhoto(group)}
                      disabled={processingId === group.id + '_photo' || isLockedByOther(group.id + '_photo')}
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
                      disabled={processingId === group.id + '_photo' || isLockedByOther(group.id + '_photo')}
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
                    <VideoPlayer
                      uri={group.promo_video}
                      style={styles.videoPreview}
                      nativeControls
                      autoPlay
                      muted
                    />
                  ) : (
                    <View style={[styles.videoPreview, styles.noMedia]}>
                      <Text style={styles.noMediaText}>Sin video</Text>
                    </View>
                  )}
                  <ClaimBar
                    claim={claims[group.id + '_video']}
                    busy={claimBusyId === group.id + '_video'}
                    onClaim={() => claim(group.id + '_video')}
                    onRelease={() => release(group.id + '_video')}
                  />
                  <View style={styles.actionRow}>
                    <TouchableOpacity
                      style={[styles.btn, styles.btnApprove]}
                      onPress={() => approveVideo(group)}
                      disabled={processingId === group.id + '_video' || isLockedByOther(group.id + '_video')}
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
                      disabled={processingId === group.id + '_video' || isLockedByOther(group.id + '_video')}
                    >
                      <Text style={styles.btnRejectText}>✗ Rechazar</Text>
                    </TouchableOpacity>
                  </View>
                </View>
              )}
            </View>
          ))}

          {/* 📸 Publicaciones de eventos pendientes (sql/561) — 1 tarjeta por
                publicación, con todas sus fotos en fila */}
          {eventPosts.map((post) => (
            <View key={post.id} style={styles.card}>
              <Text style={styles.groupName}>{post.groups?.name ?? 'Grupo'}</Text>
              <View style={styles.section}>
                <Text style={styles.sectionLabel}>
                  PUBLICACIÓN {post.photos?.length > 1 ? `· ${post.photos.length} FOTOS` : ''}
                </Text>
                {post.caption && (
                  <Text style={styles.noMediaText}>{post.caption}</Text>
                )}
                <ScrollView horizontal showsHorizontalScrollIndicator={false}>
                  {(post.photos ?? []).map((ph) => (
                    <Image key={ph.id} source={{ uri: ph.url }} style={[styles.photoPreview, { width: 160, marginRight: 8 }]} resizeMode="cover" />
                  ))}
                </ScrollView>
                <ClaimBar
                  claim={claims[post.id + '_eventpost']}
                  busy={claimBusyId === post.id + '_eventpost'}
                  onClaim={() => claim(post.id + '_eventpost')}
                  onRelease={() => release(post.id + '_eventpost')}
                />
                <View style={styles.actionRow}>
                  <TouchableOpacity
                    style={[styles.btn, styles.btnApprove]}
                    onPress={() => approveEventPost(post)}
                    disabled={processingId === post.id + '_eventpost' || isLockedByOther(post.id + '_eventpost')}
                  >
                    {processingId === post.id + '_eventpost' ? (
                      <ActivityIndicator size="small" color={COLORS.bg} />
                    ) : (
                      <Text style={styles.btnApproveText}>✓ Aprobar publicación</Text>
                    )}
                  </TouchableOpacity>
                  <TouchableOpacity
                    style={[styles.btn, styles.btnReject]}
                    onPress={() => rejectEventPost(post)}
                    disabled={processingId === post.id + '_eventpost' || isLockedByOther(post.id + '_eventpost')}
                  >
                    <Text style={styles.btnRejectText}>✗ Rechazar</Text>
                  </TouchableOpacity>
                </View>
              </View>
            </View>
          ))}

          {/* 🎬 Videos del carrusel pendientes (sql/492) — antes no aparecían
                aquí ni en ningún otro lado; se quedaban 'pending' para
                siempre sin forma de aprobarlos. */}
          {pendingVideos.map((video) => (
            <View key={video.id} style={styles.card}>
              <Text style={styles.groupName}>{video.groups?.name ?? 'Grupo'}</Text>
              <View style={styles.section}>
                <Text style={styles.sectionLabel}>VIDEO DEL CARRUSEL</Text>
                <VideoPlayer
                  uri={video.url}
                  style={styles.videoPreview}
                  contentFit="cover"
                  autoPlay
                  muted
                />
                <ClaimBar
                  claim={claims[video.id + '_carouselvideo']}
                  busy={claimBusyId === video.id + '_carouselvideo'}
                  onClaim={() => claim(video.id + '_carouselvideo')}
                  onRelease={() => release(video.id + '_carouselvideo')}
                />
                <View style={styles.actionRow}>
                  <TouchableOpacity
                    style={[styles.btn, styles.btnApprove]}
                    onPress={() => approveVideoCarousel(video)}
                    disabled={processingId === video.id + '_carouselvideo' || isLockedByOther(video.id + '_carouselvideo')}
                  >
                    {processingId === video.id + '_carouselvideo' ? (
                      <ActivityIndicator size="small" color={COLORS.bg} />
                    ) : (
                      <Text style={styles.btnApproveText}>✓ Aprobar video</Text>
                    )}
                  </TouchableOpacity>
                  <TouchableOpacity
                    style={[styles.btn, styles.btnReject]}
                    onPress={() => rejectVideoCarousel(video)}
                    disabled={processingId === video.id + '_carouselvideo' || isLockedByOther(video.id + '_carouselvideo')}
                  >
                    <Text style={styles.btnRejectText}>✗ Rechazar</Text>
                  </TouchableOpacity>
                </View>
              </View>
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
