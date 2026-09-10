import { Camera, Compass, Flag, Gift as GiftIcon, Heart, MessageCircle, Music2, Share2 } from 'lucide-react-native';
import VerifiedBadge from '../../components/ui/VerifiedBadge';
import React, { useCallback, useEffect, useState } from 'react';
import { useTranslation } from 'react-i18next';
import {
  ActivityIndicator,
  Alert,
  Dimensions,
  FlatList,
  Image,
  Pressable,
  RefreshControl,
  ScrollView,
  Share,
  StyleSheet,
  Text,
  TextInput,
  View,
} from 'react-native';

const SCREEN_W = Dimensions.get('window').width;
import { SafeAreaView } from 'react-native-safe-area-context';
import { useFocusEffect } from '@react-navigation/native';
import { supabase } from '../../config/supabase';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';
import { useAuth } from '../../context/AuthContext';
import GiftPickerModal from '../../components/gifts/GiftPickerModal';
import type { ImagePickerAsset } from 'expo-image-picker';
import { pickGroupEventPhotos, uploadGroupEventPost } from '../../utils/uploadGroupEventPhoto';
import BannerAdCarousel from '../../components/ui/BannerAdCarousel';

function timeAgo(timestamp: string, t: (key: string, opts?: any) => string): string {
  const diffMs = Date.now() - new Date(timestamp).getTime();
  const diffMins  = Math.floor(diffMs / 60000);
  const diffHours = Math.floor(diffMs / 3600000);
  const diffDays  = Math.floor(diffMs / 86400000);
  if (diffMins < 1) return t('feedScreen.timeAgoJustNow');
  if (diffMins < 60) return t('feedScreen.timeAgoMinutes', { count: diffMins });
  if (diffHours < 24) return t('feedScreen.timeAgoHours', { count: diffHours });
  if (diffDays === 1) return t('feedScreen.timeAgoYesterday');
  if (diffDays < 30) return t('feedScreen.timeAgoDays', { count: diffDays });
  const months = Math.floor(diffDays / 30);
  return t('feedScreen.timeAgoMonths', { count: months });
}

function PostPhotos({ photos, onPress }: { photos: { id: string; url: string }[]; onPress: () => void }) {
  const [idx, setIdx] = useState(0);

  if (photos.length <= 1) {
    return (
      <Pressable onPress={onPress}>
        <Image source={{ uri: photos[0].url }} style={s.photo} resizeMode="cover" />
      </Pressable>
    );
  }

  return (
    <View>
      <ScrollView
        horizontal
        pagingEnabled
        showsHorizontalScrollIndicator={false}
        onMomentumScrollEnd={e => setIdx(Math.round(e.nativeEvent.contentOffset.x / SCREEN_W))}
      >
        {photos.map(p => (
          <Pressable key={p.id} onPress={onPress}>
            <Image source={{ uri: p.url }} style={[s.photo, { width: SCREEN_W }]} resizeMode="cover" />
          </Pressable>
        ))}
      </ScrollView>
      <View style={s.multiBadge}>
        <Text style={s.multiBadgeText}>{idx + 1}/{photos.length}</Text>
      </View>
      <View style={s.dotsRow} pointerEvents="none">
        {photos.map((_, i) => (
          <View key={i} style={[s.dot, i === idx && s.dotOn]} />
        ))}
      </View>
    </View>
  );
}

export default function FeedScreen({ navigation, route }: any) {
  const { t } = useTranslation();
  const { user, role, safeState, safeCountry } = useAuth();
  const canPost = !!route?.params?.canPost && role === 'group';
  const [posts,       setPosts]       = useState<any[]>([]);
  const [loading,     setLoading]     = useState(true);
  const [refreshing,  setRefreshing]  = useState(false);
  const [followsAny,  setFollowsAny]  = useState(true);
  const [likeBusy,    setLikeBusy]    = useState<Record<string, boolean>>({});
  // ➕ Publicar (solo grupo, sql/561) — accesible directo desde Inicio
  const [myGroupId,     setMyGroupId]     = useState<string | null>(null);
  // 🏆 Plus vigente — publicar fotos ya es gratis (sql/637); solo se usa
  //    para el aviso de "con Plus ganas dinero con regalos".
  const [myGroupPlus,   setMyGroupPlus]   = useState(false);
  const [newCaption,    setNewCaption]    = useState('');
  const [posting,       setPosting]       = useState(false);
  // Fotos ya elegidas pero AÚN sin publicar — vista previa (2026-09-05)
  const [pendingPhotos, setPendingPhotos] = useState<ImagePickerAsset[] | null>(null);
  // 🎁 Regalar directo desde una tarjeta del feed (sql/566-568)
  const [giftTarget, setGiftTarget] = useState<{ groupId: string; groupName: string; groupCountry: string | null; postId: string } | null>(null);

  useEffect(() => {
    if (!canPost || !user) return;
    supabase.from('groups').select('id, is_plus_active, plus_expires_at').eq('owner_id', user.id).maybeSingle()
      .then(({ data }) => {
        setMyGroupId(data?.id ?? null);
        setMyGroupPlus(!!data?.is_plus_active && (!data.plus_expires_at || new Date(data.plus_expires_at) > new Date()));
      });
  }, [canPost, user]);

  // Paso 1: elegir fotos — NO publica todavía, solo las guarda para
  // previsualizar (hallazgo real 2026-09-05: antes un solo toque elegía Y
  // publicaba de una vez).
  const handlePickPhotos = async () => {
    if (!myGroupId || posting) return;
    // sql/637: publicar fotos ya NO requiere Plus (los regalos sí).
    const assets = await pickGroupEventPhotos();
    if (assets) setPendingPhotos(assets);
  };

  // Paso 2: publicar de verdad, con las fotos ya elegidas y el pie de foto actual.
  const handlePublish = async () => {
    if (!myGroupId || !pendingPhotos || posting) return;
    try {
      setPosting(true);
      const post = await uploadGroupEventPost(myGroupId, newCaption, pendingPhotos);
      if (post) {
        setNewCaption('');
        setPendingPhotos(null);
        Alert.alert(t('feedScreen.uploadSuccessTitle'), t('feedScreen.uploadSuccessBody'));
      }
    } catch (e: any) {
      Alert.alert(t('common.error'), e?.message ?? t('feedScreen.uploadErrorBody'));
    } finally {
      setPosting(false);
    }
  };

  const fetchFeed = useCallback(async () => {
    if (!user) { setLoading(false); return; }

    const { data: follows } = await supabase
      .from('group_follows')
      .select('group_id')
      .eq('user_id', user.id);
    const groupIds = (follows ?? []).map((f: any) => f.group_id);

    if (groupIds.length === 0) {
      setFollowsAny(false);
      setPosts([]);
      setLoading(false);
      return;
    }
    setFollowsAny(true);

    const { data } = await supabase
      .from('group_event_posts')
      .select('id, group_id, caption, created_at, groups(id, name, profile_image, is_verified, is_plus_active, plus_expires_at, country, owner_id), photos:group_event_photos(id, url, position)')
      .in('group_id', groupIds)
      .eq('status', 'approved')
      .order('created_at', { ascending: false })
      .limit(50);

    const rows = (data as any[] ?? []).map(p => ({
      ...p,
      photos: (p.photos ?? []).slice().sort((a: any, b: any) => a.position - b.position),
    }));

    if (rows.length > 0) {
      const ids = rows.map(p => p.id);
      const [likesRes, commentsRes, mineRes] = await Promise.all([
        supabase.from('group_event_post_likes').select('post_id').in('post_id', ids),
        supabase.from('group_event_post_comments').select('post_id').in('post_id', ids),
        supabase.from('group_event_post_likes').select('post_id').eq('user_id', user.id).in('post_id', ids),
      ]);
      const likeCounts: Record<string, number> = {};
      const commentCounts: Record<string, number> = {};
      ids.forEach(id => { likeCounts[id] = 0; commentCounts[id] = 0; });
      (likesRes.data as any[] ?? []).forEach(r => { likeCounts[r.post_id]++; });
      (commentsRes.data as any[] ?? []).forEach(r => { commentCounts[r.post_id]++; });
      const likedByMe = new Set((mineRes.data as any[] ?? []).map((r: any) => r.post_id));

      rows.forEach(p => {
        p.likeCount = likeCounts[p.id] ?? 0;
        p.commentCount = commentCounts[p.id] ?? 0;
        p.likedByMe = likedByMe.has(p.id);
      });
    }

    setPosts(rows);
    setLoading(false);
  }, [user]);

  useFocusEffect(useCallback(() => { fetchFeed(); }, [fetchFeed]));

  const onRefresh = async () => {
    setRefreshing(true);
    await fetchFeed();
    setRefreshing(false);
  };

  const toggleLike = async (post: any) => {
    if (!user || likeBusy[post.id]) return;
    setLikeBusy(prev => ({ ...prev, [post.id]: true }));
    const wasLiked = post.likedByMe;
    setPosts(prev => prev.map(p => p.id === post.id
      ? { ...p, likedByMe: !wasLiked, likeCount: Math.max(0, p.likeCount + (wasLiked ? -1 : 1)) }
      : p));
    if (wasLiked) {
      await supabase.from('group_event_post_likes').delete()
        .eq('post_id', post.id).eq('user_id', user.id);
    } else {
      await supabase.from('group_event_post_likes').insert({ post_id: post.id, user_id: user.id });
    }
    setLikeBusy(prev => ({ ...prev, [post.id]: false }));
  };

  const sharePost = async (post: any) => {
    const groupName = post.groups?.name ?? t('feedScreen.defaultGroupName');
    const captionPrefix = post.caption ? `"${post.caption}" — ` : '';
    try {
      await Share.share({
        message: `${captionPrefix}${t('feedScreen.shareMessage', { groupName, groupId: post.group_id })}`,
        title: groupName,
      });
    } catch (_) { /* usuario canceló */ }
  };

  // 🚩 Reportar directo desde el feed (hallazgo real 2026-09-05: antes solo
  // se podía reportar entrando al perfil del grupo — la gente ve las
  // publicaciones aquí, no ahí). Mismas opciones y RPC que ya usa
  // GroupDetailScreen.tsx (Términos §6, cierra el círculo del takedown).
  const reportPost = (post: any) => {
    const send = async (reason: string) => {
      const { data, error } = await supabase.rpc('report_group_content', {
        p_group_id: post.group_id,
        p_reason:   reason,
      });
      if (error || (data as any)?.ok === false) {
        Alert.alert(t('groupDetailScreen.report.sendErrorTitle'), (data as any)?.error ?? error?.message ?? t('groupDetailScreen.report.tryAgain'));
        return;
      }
      Alert.alert(t('groupDetailScreen.report.sentTitle'), t('groupDetailScreen.report.sentBody'));
    };
    Alert.alert(t('groupDetailScreen.report.promptTitle'), t('groupDetailScreen.report.promptQuestion'), [
      { text: t('groupDetailScreen.report.reasonCopyright'), onPress: () => send('Posible infracción de derechos de autor en foto/video/música') },
      { text: t('groupDetailScreen.report.reasonInappropriate'), onPress: () => send('Contenido inapropiado en una publicación del feed') },
      { text: t('groupDetailScreen.report.reasonFalseInfo'), onPress: () => send('Información falsa o engañosa en una publicación') },
      { text: t('groupDetailScreen.report.cancel'), style: 'cancel' },
    ]);
  };

  return (
    <SafeAreaView style={s.safe} edges={['top']}>
      {/* Petición real (2026-09-03): "no es necesario que diga [el nombre
          de la pantalla], solo en Explorador lo de Daricefy sí déjalo" —
          el tab de abajo ya dice "Inicio", repetirlo arriba era redundante. */}
      {canPost && myGroupId && (
        <View style={s.composerBlock}>
          {/* Hallazgo real (2026-09-05): el input redondo estilo "píldora"
              se confundía con un buscador, y "Publicar" no dejaba claro que
              ahí mismo se elige la foto (un solo toque hace las dos cosas).
              Se agrega una etiqueta arriba y se aclara el botón. */}
          <Text style={s.composerLabel}>{t('feedScreen.composerLabel')}</Text>
          <View style={s.composer}>
            <TextInput
              style={s.composerInput}
              value={newCaption}
              onChangeText={setNewCaption}
              placeholder={t('feedScreen.composerPlaceholder')}
              placeholderTextColor={COLORS.muted}
              maxLength={60}
            />
            {!pendingPhotos && (
              <Pressable style={s.composerBtn} onPress={handlePickPhotos}>
                <Camera size={15} color="#04110A" />
                <Text style={s.composerBtnTx}>{t('feedScreen.publish')}</Text>
              </Pressable>
            )}
          </View>

          {/* Vista previa — las fotos ya se eligieron pero TODAVÍA no se
              publican, hasta tocar "Publicar" (2026-09-05). */}
          {pendingPhotos && (
            <View style={s.composerPreviewRow}>
              <ScrollView horizontal showsHorizontalScrollIndicator={false} style={{ flex: 1 }}>
                {pendingPhotos.map((a, i) => (
                  <Image key={i} source={{ uri: a.uri }} style={s.composerPreviewThumb} />
                ))}
              </ScrollView>
              <Pressable style={s.composerCancelBtn} disabled={posting} onPress={() => setPendingPhotos(null)}>
                <Text style={s.composerCancelTx}>Cancelar</Text>
              </Pressable>
              <Pressable style={[s.composerBtn, posting && { opacity: 0.5 }]} disabled={posting} onPress={handlePublish}>
                {posting && <ActivityIndicator size="small" color="#04110A" />}
                <Text style={s.composerBtnTx}>{posting ? t('feedScreen.uploading') : t('feedScreen.publishConfirm')}</Text>
              </Pressable>
            </View>
          )}
        </View>
      )}
      {canPost && myGroupId && !myGroupPlus && (
        <Pressable style={s.plusHint} onPress={() => navigation.navigate('Plus')}>
          <Text style={s.plusHintTx}>
            {t('feedScreen.plusHintPrefix')}<Text style={{ color: COLORS.gold }}>Plus</Text>{t('feedScreen.plusHintSuffix')}
          </Text>
        </Pressable>
      )}

      {/* Petición real (2026-09-03): "que el banner home también aparezca
          en Inicio... donde salen las publicaciones" — el tipo de anuncio
          'banner_home' ya prometía esto en su propia descripción pero
          antes solo vivía en HomeScreen (tab Explorar). Mismo componente,
          mismos anuncios activos (get_active_banner_ads), independiente
          de si el cliente sigue a algún grupo o no. */}
      <View style={{ paddingHorizontal: SPACING.xl, paddingTop: 12 }}>
        <BannerAdCarousel navigation={navigation} state={safeState} country={safeCountry} />
      </View>

      {loading ? (
        <View style={s.center}><ActivityIndicator color={COLORS.green} /></View>
      ) : !followsAny ? (
        <View style={s.center}>
          <Compass size={40} color={COLORS.muted} />
          <Text style={s.emptyTitle}>{t('feedScreen.emptyFollowTitle')}</Text>
          <Text style={s.emptyText}>{t('feedScreen.emptyFollowText')}</Text>
          <Pressable style={s.exploreBtn} onPress={() => navigation.navigate('Explorar')}>
            <Text style={s.exploreBtnTx}>{t('feedScreen.exploreGroups')}</Text>
          </Pressable>
        </View>
      ) : posts.length === 0 ? (
        <View style={s.center}>
          <Compass size={40} color={COLORS.muted} />
          <Text style={s.emptyTitle}>{t('feedScreen.emptyPostsTitle')}</Text>
          <Text style={s.emptyText}>{t('feedScreen.emptyPostsText')}</Text>
        </View>
      ) : (
        <FlatList
          data={posts}
          keyExtractor={item => item.id}
          contentContainerStyle={{ paddingBottom: 24 }}
          refreshControl={<RefreshControl refreshing={refreshing} onRefresh={onRefresh} tintColor={COLORS.green} />}
          renderItem={({ item }) => {
            const grp = item.groups;
            return (
              <View style={s.card}>
                <Pressable style={s.cardHeader} onPress={() => navigation.navigate('GroupDetail', { group: grp })}>
                  {grp?.profile_image ? (
                    <Image source={{ uri: grp.profile_image }} style={s.avatar} />
                  ) : (
                    <View style={[s.avatar, s.avatarPh]}><Music2 size={16} color={COLORS.muted} /></View>
                  )}
                  <View style={{ flex: 1 }}>
                    <View style={{ flexDirection: 'row', alignItems: 'center', gap: 3 }}>
                      <Text style={s.groupName} numberOfLines={1}>{grp?.name ?? t('feedScreen.defaultGroupLabel')}</Text>
                      {grp?.is_verified && (
                        <VerifiedBadge
                          size={14}
                          tier={(!!grp.is_plus_active &&
                            (!grp.plus_expires_at || new Date(grp.plus_expires_at) > new Date()))
                            ? 'plus' : 'free'}
                        />
                      )}
                    </View>
                    <Text style={s.postTime}>{timeAgo(item.created_at, t)}</Text>
                  </View>
                </Pressable>

                {item.caption ? <Text style={s.caption}>{item.caption}</Text> : null}

                {item.photos.length > 0 && (
                  <PostPhotos
                    photos={item.photos}
                    onPress={() => navigation.navigate('GroupDetail', { group: grp, openPost: item })}
                  />
                )}

                <View style={s.actionsRow}>
                  <View style={s.actionsLeft}>
                    <Pressable style={s.actionBtn} onPress={() => toggleLike(item)}>
                      <Heart size={18} color={item.likedByMe ? '#EF5350' : COLORS.muted2} fill={item.likedByMe ? '#EF5350' : 'transparent'} />
                      <Text style={s.actionCount}>{item.likeCount}</Text>
                    </Pressable>
                    <Pressable style={s.actionBtn} onPress={() => navigation.navigate('GroupDetail', { group: grp, openPost: item })}>
                      <MessageCircle size={18} color={COLORS.muted2} />
                      <Text style={s.actionCount}>{item.commentCount}</Text>
                    </Pressable>
                  </View>
                  <View style={s.actionsRight}>
                    {user && grp && grp.owner_id !== user.id && (
                      <Pressable
                        style={s.giftBtn}
                        onPress={() => setGiftTarget({ groupId: grp.id, groupName: grp.name, groupCountry: grp.country ?? null, postId: item.id })}
                      >
                        <GiftIcon size={16} color="#fff" />
                      </Pressable>
                    )}
                    <Pressable style={s.shareBtn} onPress={() => sharePost(item)}>
                      <Share2 size={18} color={COLORS.muted2} />
                    </Pressable>
                    <Pressable style={s.shareBtn} onPress={() => reportPost(item)} hitSlop={6}>
                      <Flag size={16} color={COLORS.muted2} />
                    </Pressable>
                  </View>
                </View>
              </View>
            );
          }}
        />
      )}

      {giftTarget && (
        <GiftPickerModal
          visible={!!giftTarget}
          onClose={() => setGiftTarget(null)}
          groupId={giftTarget.groupId}
          groupName={giftTarget.groupName}
          groupCountry={giftTarget.groupCountry}
          postId={giftTarget.postId}
        />
      )}
    </SafeAreaView>
  );
}

const s = StyleSheet.create({
  safe: { flex: 1, backgroundColor: COLORS.bg },
  header: {
    paddingHorizontal: SPACING.xl, paddingVertical: 14,
    borderBottomWidth: 1, borderBottomColor: COLORS.border,
  },
  headerTitle: { fontFamily: FONTS.title, fontSize: 20, color: '#fff' },
  center: { flex: 1, alignItems: 'center', justifyContent: 'center', gap: 10, paddingHorizontal: 40 },
  emptyTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: '#fff', textAlign: 'center' },
  emptyText: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted, textAlign: 'center', lineHeight: 19 },
  exploreBtn: {
    marginTop: 6, backgroundColor: COLORS.green, borderRadius: RADIUS.full,
    paddingHorizontal: 20, paddingVertical: 10,
  },
  exploreBtnTx: { fontFamily: FONTS.bodySemiBold, fontSize: 13.5, color: '#04110A' },

  composerBlock: {
    paddingHorizontal: SPACING.xl, paddingTop: 10, paddingBottom: 10,
    borderBottomWidth: 1, borderBottomColor: COLORS.border,
    gap: 6,
  },
  composerLabel: { fontFamily: FONTS.bodySemiBold, fontSize: 12.5, color: COLORS.muted2 },
  composer: {
    flexDirection: 'row', alignItems: 'center', gap: 8,
  },
  // Antes RADIUS.full (píldora) — se confundía con un buscador. Ahora un
  // rectángulo redondeado, mismo lenguaje visual que un cuadro de texto.
  composerInput: {
    flex: 1, backgroundColor: COLORS.card2, borderRadius: RADIUS.md,
    paddingHorizontal: 14, paddingVertical: 9, fontSize: 13,
    fontFamily: FONTS.body, color: '#fff',
  },
  composerBtn: {
    flexDirection: 'row', alignItems: 'center', gap: 5,
    backgroundColor: COLORS.green, borderRadius: RADIUS.full,
    paddingHorizontal: 14, paddingVertical: 9,
  },
  composerBtnTx: { fontFamily: FONTS.bodySemiBold, fontSize: 12.5, color: '#04110A' },
  composerPreviewRow: { flexDirection: 'row', alignItems: 'center', gap: 8, marginTop: 4 },
  composerPreviewThumb: {
    width: 44, height: 44, borderRadius: RADIUS.md, marginRight: 6,
    backgroundColor: COLORS.card2,
  },
  composerCancelBtn: { paddingHorizontal: 10, paddingVertical: 9 },
  composerCancelTx: { fontFamily: FONTS.bodyMedium, fontSize: 12.5, color: COLORS.muted2 },
  plusHint: {
    paddingHorizontal: SPACING.xl, paddingVertical: 8,
    borderBottomWidth: 1, borderBottomColor: COLORS.border,
  },
  plusHintTx: { fontFamily: FONTS.bodyMedium, fontSize: 11.5, color: COLORS.muted2 },

  card: {
    backgroundColor: COLORS.card, borderBottomWidth: 8, borderBottomColor: COLORS.bg,
    paddingTop: 12, paddingBottom: 10,
  },
  cardHeader: {
    flexDirection: 'row', alignItems: 'center', gap: 10,
    paddingHorizontal: SPACING.xl, marginBottom: 8,
  },
  avatar: { width: 38, height: 38, borderRadius: 19, backgroundColor: COLORS.card2 },
  avatarPh: { alignItems: 'center', justifyContent: 'center' },
  groupName: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: '#fff', flexShrink: 1 },
  postTime: { fontFamily: FONTS.body, fontSize: 11.5, color: COLORS.muted, marginTop: 1 },
  caption: {
    fontFamily: FONTS.body, fontSize: 13.5, color: 'rgba(255,255,255,0.9)', lineHeight: 19,
    paddingHorizontal: SPACING.xl, marginBottom: 10,
  },
  photo: { width: '100%', height: 320, backgroundColor: '#060c06' },
  multiBadge: {
    position: 'absolute', top: 10, right: 10,
    backgroundColor: 'rgba(0,0,0,0.6)', borderRadius: RADIUS.full,
    paddingHorizontal: 8, paddingVertical: 3,
  },
  multiBadgeText: { fontFamily: FONTS.bodyMedium, fontSize: 10, color: '#fff' },
  dotsRow: {
    position: 'absolute', bottom: 10, left: 0, right: 0,
    flexDirection: 'row', justifyContent: 'center', gap: 6,
  },
  dot: { width: 6, height: 6, borderRadius: 3, backgroundColor: 'rgba(255,255,255,0.35)' },
  dotOn: { backgroundColor: COLORS.green, width: 16 },
  actionsRow: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between',
    paddingHorizontal: SPACING.xl, paddingTop: 10,
  },
  actionsLeft:  { flexDirection: 'row', alignItems: 'center', gap: 20 },
  actionsRight: { flexDirection: 'row', alignItems: 'center', gap: 16 },
  actionBtn: { flexDirection: 'row', alignItems: 'center', gap: 6 },
  giftBtn: {
    width: 30, height: 30, borderRadius: 9,
    borderWidth: 1.5, borderColor: '#60A5FA', backgroundColor: '#3B82F6',
    alignItems: 'center', justifyContent: 'center',
  },
  giftBtnTx: { fontSize: 19 },
  shareBtn: { alignItems: 'center', justifyContent: 'center' },
  actionCount: { fontFamily: FONTS.bodyMedium, fontSize: 12.5, color: COLORS.muted2 },
});
