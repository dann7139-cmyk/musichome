import VideoPlayer from '../../components/ui/VideoPlayer';
import { LinearGradient } from 'expo-linear-gradient';
import * as WebBrowser from 'expo-web-browser';
import React, { useEffect, useRef, useState } from 'react';
import { useTranslation } from 'react-i18next';
import {
  ActivityIndicator,
  Alert,
  Animated,
  Dimensions,
  Easing,
  FlatList,
  Image,
  KeyboardAvoidingView,
  Modal,
  PanResponder,
  Platform,
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
const SCREEN_H = Dimensions.get('window').height;
// Petición real (2026-09-03): "la imagen sale bien pero lo demás de
// abajo" — la foto de portada ya es edge-to-edge; el cuerpo (bio,
// contacto, reseñas, fotos del evento, etc.) usaba SPACING.xl (24px) y se
// sentía más metido hacia adentro que la imagen. Local a esta pantalla,
// mismo criterio que ya se aplicó en HomeScreen — no se toca el token
// global SPACING.xl.
const H_PAD = 14;
import { SafeAreaView, useSafeAreaInsets } from 'react-native-safe-area-context';
import { ArrowLeft, CheckCircle, ChevronLeft, ChevronRight, MapPin, Music2, Play, Share2, Shield, Star, FileText, Navigation, Award, TrendingUp, ShieldCheck, ThumbsUp, Zap, Headphones, Heart, MessageCircle, X, Send, Gift as GiftIcon, Volume2, VolumeX } from 'lucide-react-native';
import * as Location from 'expo-location';
import { captureRef } from 'react-native-view-shot';
import * as FileSystem from 'expo-file-system/legacy';
import { supabase } from '../../config/supabase';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';
import Particles from '../../components/ui/Particles';
import LevelBadge from '../../components/ui/LevelBadge';
import VerifiedBadge from '../../components/ui/VerifiedBadge';
import PhotoViewerModal from '../../components/ui/PhotoViewerModal';
import { useAuth } from '../../context/AuthContext';
import { validateComment } from '../../utils/offensiveWordsFilter';
import GiftPickerModal from '../../components/gifts/GiftPickerModal';

// 🎬 Baraja de videos — MISMO efecto que MiniDeck del explorador:
// el del frente opaco y grande; los de los lados ATRASITO (fijos,
// más chicos y semitransparentes). Tap en un lado o deslizar cambia
// cuál pasa al frente. Los espacios sin video son tarjetas 🔒.
function VideoDeck({ slots }: { slots: any[] }) {
  const { t } = useTranslation();
  const insets = useSafeAreaInsets();
  const [idx, setIdx] = useState(0);
  const [fsVisible, setFsVisible] = useState(false);
  const [fsIndex, setFsIndex] = useState(0);
  // Cambia solo al ABRIR (no en cada swipe) — sirve de key para que el
  // ScrollView arranque en el índice correcto sin pelearse con el gesto
  // del usuario mientras desliza.
  const [fsOpenToken, setFsOpenToken] = useState(0);
  const n = slots.length;

  const go = (d: number) => setIdx(i => (i + d + n) % n);
  const goRef = useRef(go);
  goRef.current = go;

  // Deslizar izq/der — solo captura gestos horizontales (no roba taps ni el scroll vertical)
  const pan = useRef(
    PanResponder.create({
      onMoveShouldSetPanResponder: (_, g) => Math.abs(g.dx) > 10 && Math.abs(g.dx) > Math.abs(g.dy) * 1.4,
      onPanResponderRelease: (_, g) => {
        if (g.dx > 20) goRef.current(-1);
        else if (g.dx < -20) goRef.current(1);
      },
    })
  ).current;

  // Solo los videos reales (sin los espacios 🔒) entran a la vista en
  // grande — ahí sí tiene sentido deslizar entre ellos.
  const playable = slots.filter(s => !s.locked);

  const openFullscreen = (item: any) => {
    if (item.locked) return;
    const i = playable.findIndex(p => p.id === item.id);
    setFsIndex(Math.max(0, i));
    setFsOpenToken(t => t + 1);
    setFsVisible(true);
  };

  if (n === 0) return null;

  const bodyW  = SCREEN_W - H_PAD * 2;
  const cardW  = Math.round(bodyW * 0.60);   // más chico (pedido 2026-07-16)
  const cardH  = 160;
  const peek   = Math.round(cardW * 0.28);   // cuánto asoman los de atrás
  const leftC  = Math.round((bodyW - cardW) / 2);

  const renderCard = (item: any, isFront: boolean, role: number) =>
    item.locked ? (
      <View style={[styles.videoCard, styles.videoCardLocked, { width: cardW, height: cardH, marginTop: 0 }]}>
        <Text style={{ fontSize: isFront ? 30 : 24 }}>🔒</Text>
        <Text style={styles.videoLockedTx}>{t('groupDetailScreen.videoDeck.unavailable')}</Text>
      </View>
    ) : (
      <Pressable
        style={[styles.videoCard, { width: cardW, marginTop: 0 }]}
        onPress={() => (isFront ? openFullscreen(item) : go(role === 1 ? 1 : -1))}
      >
        <VideoPlayer
          uri={item.url}
          style={{ width: '100%', height: cardH }}
          contentFit={isFront ? 'contain' : 'cover'}
          nativeControls={false}
          posterFrame
          muted
        />
        {/* Ícono de play chico y del mismo tamaño siempre — antes usaba los
            controles nativos en la tarjeta de al frente y se veían enormes
            para lo chica que es la tarjeta. */}
        <View style={styles.videoDeckPlay} pointerEvents="none">
          <Play size={isFront ? 20 : 16} color="#fff" fill="#fff" />
        </View>
      </Pressable>
    );

  return (
    <>
      <View
        {...pan.panHandlers}
        style={{ width: bodyW, height: cardH + 14, justifyContent: 'center', alignItems: 'center', marginTop: 8 }}
      >
        {/* Cada video tiene SU PROPIO reproductor con key estable por id —
            al deslizar solo se le mueve posición/escala/opacidad, nunca se
            le cambia el uri a un reproductor ajeno. Antes había 3
            reproductores fijos por POSICIÓN (frente/atrás-izq/atrás-der) y
            cada swipe les reasignaba qué video mostrar, así que recargaban
            desde cero (con su "cargando") aunque ese video ya se hubiera
            visto un momento antes en la posición de al lado. */}
        {slots.map((item, i) => {
          const role = (i - idx + n) % n; // 0 = frente, 1 = siguiente (derecha), 2 = anterior (izquierda)
          if (role === 0) {
            return <View key={item.id} style={{ zIndex: 3 }}>{renderCard(item, true, role)}</View>;
          }
          if (role === 1 && n > 2) {
            return (
              <View
                key={item.id}
                style={{
                  position: 'absolute', top: 7, left: leftC, zIndex: 1, opacity: 0.45,
                  transform: [{ translateX: peek }, { scale: 0.82 }],
                }}
              >
                {renderCard(item, false, role)}
              </View>
            );
          }
          if (role === n - 1 && n > 1) {
            return (
              <View
                key={item.id}
                style={{
                  position: 'absolute', top: 7, left: leftC, zIndex: 1, opacity: 0.45,
                  transform: [{ translateX: -peek }, { scale: 0.82 }],
                }}
              >
                {renderCard(item, false, role)}
              </View>
            );
          }
          return null;
        })}
      </View>
      {/* Flechitas + puntos — para que se note que se puede cambiar el video */}
      {n > 1 && (
        <View style={styles.videoDeckNav}>
          <Pressable onPress={() => go(-1)} hitSlop={10} style={styles.videoDeckArrow}>
            <ChevronLeft size={15} color="#fff" />
          </Pressable>
          <View style={[styles.videoDots, { marginTop: 0 }]}>
            {slots.map((_: any, i: number) => (
              <View key={i} style={[styles.videoDot, i === idx % n && styles.videoDotOn]} />
            ))}
          </View>
          <Pressable onPress={() => go(1)} hitSlop={10} style={styles.videoDeckArrow}>
            <ChevronRight size={15} color="#fff" />
          </Pressable>
        </View>
      )}

      {/* 🔎 Vista en grande — desliza entre todos los videos reales del grupo */}
      <Modal visible={fsVisible} animationType="fade" onRequestClose={() => setFsVisible(false)}>
        <View style={styles.videoFsSafe}>
          <View style={[styles.videoFsHeader, { paddingTop: insets.top + 14 }]}>
            <Pressable hitSlop={10} onPress={() => setFsVisible(false)}>
              <X size={24} color="#fff" />
            </Pressable>
            {playable.length > 1 && (
              <Text style={styles.videoFsCounter}>{fsIndex + 1}/{playable.length}</Text>
            )}
            <View style={{ width: 24 }} />
          </View>
          <ScrollView
            key={`fs-${fsOpenToken}`}
            horizontal
            pagingEnabled
            showsHorizontalScrollIndicator={false}
            contentOffset={{ x: fsIndex * SCREEN_W, y: 0 }}
            onMomentumScrollEnd={e => setFsIndex(Math.round(e.nativeEvent.contentOffset.x / SCREEN_W))}
          >
            {playable.map((v, i) => (
              <View key={v.id} style={{ width: SCREEN_W, alignItems: 'center', justifyContent: 'center' }}>
                {fsVisible && Math.abs(i - fsIndex) <= 1 && (
                  <VideoPlayer
                    uri={v.url}
                    style={{ width: SCREEN_W, height: '100%' }}
                    contentFit="contain"
                    nativeControls
                    autoPlay={i === fsIndex}
                  />
                )}
              </View>
            ))}
          </ScrollView>
          {playable.length > 1 && (
            <View style={[styles.videoDots, { marginBottom: 24 }]}>
              {playable.map((_, i) => (
                <View key={i} style={[styles.videoDot, i === fsIndex && styles.videoDotOn]} />
              ))}
            </View>
          )}
        </View>
      </Modal>
    </>
  );
}

// Distancia Haversine en km entre dos puntos GPS
// 📸 "Hace N días" para fotos de eventos (sql/558)
function formatPhotoTimeAgo(timestamp: string, t: (key: string, opts?: any) => string): string {
  const diffMs = Date.now() - new Date(timestamp).getTime();
  const diffMins  = Math.floor(diffMs / 60000);
  const diffHours = Math.floor(diffMs / 3600000);
  const diffDays  = Math.floor(diffMs / 86400000);
  if (diffMins < 1) return t('groupDetailScreen.timeAgo.justNow');
  if (diffMins < 60) return t('groupDetailScreen.timeAgo.minutes', { count: diffMins });
  if (diffHours < 24) return t('groupDetailScreen.timeAgo.hours', { count: diffHours });
  if (diffDays === 1) return t('groupDetailScreen.timeAgo.yesterday');
  if (diffDays < 30) return t('groupDetailScreen.timeAgo.days', { count: diffDays });
  const months = Math.floor(diffDays / 30);
  return t('groupDetailScreen.timeAgo.months', { count: months });
}

function haversineKm(lat1: number, lon1: number, lat2: number, lon2: number): number {
  const R = 6371;
  const dLat = ((lat2 - lat1) * Math.PI) / 180;
  const dLon = ((lon2 - lon1) * Math.PI) / 180;
  const a =
    Math.sin(dLat / 2) ** 2 +
    Math.cos((lat1 * Math.PI) / 180) * Math.cos((lat2 * Math.PI) / 180) * Math.sin(dLon / 2) ** 2;
  return R * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

// Umbral: más de 40 km se considera "lejos"
const FAR_THRESHOLD_KM = 40;

interface Review {
  review_id: string;
  rating: number;
  comment: string | null;
  created_at: string;
  client_name: string;
  client_avatar?: string | null;   // desde sql/436; tolera RPC anterior sin la columna
}

// 🎉 Confeti cayendo desde arriba del perfil — SOLO para quien acaba de
// pagar un regalo (no para otros viendo el perfil), una sola vez. Mismo
// patrón sin librería externa que ya usa GiftPickerModal, pero cayendo
// desde arriba en vez de aparecer centrado, para que se sienta como que
// "llueve" sobre el perfil del grupo.
const PROFILE_CONFETTI_COLORS = [COLORS.green, COLORS.gold, COLORS.blue, COLORS.purple, COLORS.red, COLORS.orange];
function ProfileGiftConfetti() {
  const particles = useRef(
    Array.from({ length: 30 }, () => ({
      left: Math.random() * 100,
      color: PROFILE_CONFETTI_COLORS[Math.floor(Math.random() * PROFILE_CONFETTI_COLORS.length)],
      size: 6 + Math.random() * 7,
      delay: Math.random() * 300,
      duration: 1400 + Math.random() * 900,
      rotateTo: `${Math.round(360 + Math.random() * 360)}deg`,
      anim: new Animated.Value(0),
    })),
  ).current;

  useEffect(() => {
    Animated.parallel(
      particles.map(p =>
        Animated.timing(p.anim, {
          toValue: 1, duration: p.duration, delay: p.delay,
          easing: Easing.in(Easing.quad), useNativeDriver: true,
        }),
      ),
    ).start();
  }, []);

  return (
    <View style={styles.profileConfettiLayer} pointerEvents="none">
      {particles.map((p, i) => (
        <Animated.View
          key={i}
          style={{
            position: 'absolute',
            left: `${p.left}%`,
            top: -20,
            width: p.size, height: p.size * 1.6,
            borderRadius: 2,
            backgroundColor: p.color,
            opacity: p.anim.interpolate({ inputRange: [0, 0.06, 0.85, 1], outputRange: [0, 1, 1, 0] }),
            transform: [
              { translateY: p.anim.interpolate({ inputRange: [0, 1], outputRange: [0, SCREEN_H] }) },
              { rotate: p.anim.interpolate({ inputRange: [0, 1], outputRange: ['0deg', p.rotateTo] }) },
            ],
          }}
        />
      ))}
    </View>
  );
}

// 🎁 Botón de regalo del hero — antes era una cajita estática, fácil de
// ignorar. Ahora respira (escala + brillo) en loop, azul con blanco, para
// que se note que ahí se puede apoyar al grupo. También mide su posición
// REAL en pantalla (measureInWindow) y se la manda al padre — así el
// efecto de "sale de la cajita" nace justo de este botón, no de una
// posición fija adivinada que no coincidía en todos los celulares.
function GiftCallToAction({ onPress, onMeasured }: { onPress: () => void; onMeasured?: (pos: { x: number; y: number }) => void }) {
  const pulse = useRef(new Animated.Value(0)).current;
  const btnRef = useRef<View>(null);

  useEffect(() => {
    const loop = Animated.loop(
      Animated.sequence([
        Animated.timing(pulse, { toValue: 1, duration: 950, easing: Easing.inOut(Easing.sin), useNativeDriver: true }),
        Animated.timing(pulse, { toValue: 0, duration: 950, easing: Easing.inOut(Easing.sin), useNativeDriver: true }),
      ]),
    );
    loop.start();
    return () => loop.stop();
  }, []);

  const measure = () => {
    btnRef.current?.measureInWindow((x, y, width, height) => {
      if (width > 0) onMeasured?.({ x: x + width / 2, y: y + height / 2 });
    });
  };

  const scale       = pulse.interpolate({ inputRange: [0, 1], outputRange: [1, 1.14] });
  const glowOpacity = pulse.interpolate({ inputRange: [0, 1], outputRange: [0.25, 0.75] });
  const glowScale    = pulse.interpolate({ inputRange: [0, 1], outputRange: [1, 1.35] });

  return (
    <Pressable ref={btnRef} style={styles.heroGiftBtn} onPress={onPress} onLayout={measure} hitSlop={6}>
      <Animated.View
        pointerEvents="none"
        style={[styles.heroGiftGlow, { opacity: glowOpacity, transform: [{ scale: glowScale }] }]}
      />
      <Animated.View style={{ transform: [{ scale }] }}>
        <GiftIcon size={18} color="#fff" />
      </Animated.View>
    </Pressable>
  );
}

function StarRow({ rating, size = 14 }: { rating: number; size?: number }) {
  return (
    <View style={{ flexDirection: 'row', gap: 2 }}>
      {[1, 2, 3, 4, 5].map(i => (
        <Star
          key={i}
          size={size}
          color={COLORS.gold}
          fill={i <= rating ? COLORS.gold : 'transparent'}
        />
      ))}
    </View>
  );
}

export default function GroupDetailScreen({ route, navigation }: any) {
  const { t } = useTranslation();
  const { role, user } = useAuth();
  const insets = useSafeAreaInsets();
  const isExplorer = role === 'group' || role === 'talent';

  const params        = route.params ?? {};
  // Soporta { group } (normal) y { groupId } (deep link daricefy://group/{id})
  const initialGroup  = params.group ?? (params.groupId ? { id: params.groupId } : null);
  const isGift        = !!params.isGift;   // 🎁 modo regalo (viene del explorador)
  // sql/585 (Fase 1) — contexto de "agregar otro proveedor a mi evento",
  // llega desde HomeScreen cuando el cliente navegó con un evento activo.
  const eventCtxParams = params.eventId
    ? { eventId: params.eventId, eventDate: params.eventDate ?? null, eventAddress: params.eventAddress ?? null }
    : null;
  const openPostId     = params.openPostId; // 📸 abre directo el detalle de esta publicación (viene del feed "Inicio")
  const openedPostRef  = useRef(false);
  // Si venimos del feed "Inicio" ya trae la publicación completa (foto,
  // descripción) — se abre el modal DESDE EL PRIMER RENDER (sin esperar a
  // que cargue el perfil completo) para que no se alcance a ver el perfil
  // detrás ni un parpadeo antes del detalle.
  const initialOpenPost = params.openPost ?? null;

  const [group,            setGroup]            = useState<any>(initialGroup);
  const [loading,          setLoading]          = useState(!initialGroup || !initialGroup.description);
  const [refreshing,       setRefreshing]       = useState(false);
  const [reviews,          setReviews]          = useState<Review[]>([]);
  const [expandedReviewId, setExpandedReviewId] = useState<string | null>(null);
  const [eventPosts,       setEventPosts]       = useState<any[]>([]);
  const [postCounts,       setPostCounts]       = useState<Record<string, { likes: number; comments: number }>>({});
  const [postLikedMap,     setPostLikedMap]     = useState<Record<string, boolean>>({});
  // 📚 "Ver más" — cuadrícula con TODAS las publicaciones, no solo el
  // carrusel horizontal (pedido real 2026-09-02).
  const [showAllPosts,     setShowAllPosts]     = useState(false);
  // 👥 Seguidores (sql/563)
  const [followerCount,   setFollowerCount]   = useState(0);
  const [isFollowing,     setIsFollowing]     = useState(false);
  const [followLoading,   setFollowLoading]   = useState(false);
  // 📤 Compartir con foto real
  const shareCardRef = useRef<View>(null);
  const [sharingCard, setSharingCard] = useState(false);
  const [shareCardData, setShareCardData] = useState<{ imageUri: string; title: string } | null>(null);
  // 📸 Detalle de publicación (varias fotos, likes + comentarios, sql/561-562)
  const [selectedPost,    setSelectedPost]    = useState<any>(initialOpenPost);
  const [carouselIndex,   setCarouselIndex]   = useState(0);
  const [postLikeCount,   setPostLikeCount]   = useState(0);
  const [postLikedByMe,   setPostLikedByMe]   = useState(false);
  const [likeLoading,     setLikeLoading]     = useState(false);
  const [postComments,    setPostComments]    = useState<any[]>([]);
  const [commentLikes,    setCommentLikes]    = useState<Record<string, { count: number; likedByMe: boolean }>>({});
  const [commentsLoading, setCommentsLoading] = useState(false);
  const [newCommentText,  setNewCommentText]  = useState('');
  const [commentSubmitting, setCommentSubmitting] = useState(false);
  // 💬 Respuestas a comentarios (sql/565) + "ver más" si hay muchos
  const [visibleTopComments, setVisibleTopComments] = useState(5);
  const [expandedReplies,    setExpandedReplies]    = useState<Record<string, boolean>>({});
  const [replyingTo,         setReplyingTo]         = useState<{ id: string; name: string } | null>(null);
  // null = sin datos | true = cerca | false = lejos
  const [isNearby,         setIsNearby]         = useState<boolean | null>(null);
  const [photoOpen,        setPhotoOpen]        = useState(false);
  const [activitySnapshot,    setActivitySnapshot]    = useState<any>(null);
  const [groupCompletedCount, setGroupCompletedCount] = useState<number | null>(null);
  const [similarGroups,    setSimilarGroups]    = useState<any[]>([]);
  const [profileAds,       setProfileAds]       = useState<any[]>([]);
  // 🎬 Carrusel de videos del perfil (sql/492) + expandir cosas compactas
  const [profileVideos,    setProfileVideos]    = useState<any[]>([]);
  const [trustExpanded,    setTrustExpanded]    = useState(false);
  // 🎁 Regalos/donaciones (sql/566-567)
  const [giftModalVisible, setGiftModalVisible] = useState(false);
  const [giftModalPostId,  setGiftModalPostId]  = useState<string | undefined>(undefined);
  // 🎆 Animación en vivo del regalo (Realtime, sql/570) — solo mientras esta
  // publicación está abierta, para quien esté viéndola en ese momento.
  const [floatingGifts, setFloatingGifts] = useState<{ id: string; emoji: string; anim: Animated.Value }[]>([]);
  // 🎁 Igual pero a nivel de TODO el perfil (no solo dentro de una
  // publicación) — si alguien le manda un regalo al grupo mientras varias
  // personas están viendo su perfil, a todas les sale el emoji saliendo de
  // la cajita, en vivo. Solo en el momento — no queda nada guardado ni se
  // vuelve a mostrar después. Tope de 5 a la vez para no saturar si llegan
  // varios de golpe (pedido explícito: "que salgan pocos").
  const [liveGifts, setLiveGifts] = useState<{ id: string; emoji: string; anim: Animated.Value }[]>([]);
  // Posición REAL en pantalla del botón de regalo (medida por GiftCallToAction
  // con measureInWindow) — de ahí nace el efecto de "sale de la cajita".
  const [giftBtnPos, setGiftBtnPos] = useState<{ x: number; y: number } | null>(null);
  const liveGiftsCountRef = useRef(0);
  // Empuja UNA insignia (cajita + emoji) a la capa flotante — misma
  // animación sin importar quién la disparó (en vivo para otros, la
  // propia al pagar, o el recordatorio de 24h de abajo).
  const spawnGiftBox = (emoji: string) => {
    const id = `box-${Date.now()}-${Math.random()}`;
    const anim = new Animated.Value(0);
    setLiveGifts(prev => [...prev, { id, emoji, anim }]);
    Animated.timing(anim, { toValue: 1, duration: 2400, easing: Easing.out(Easing.quad), useNativeDriver: true }).start(() => {
      setLiveGifts(prev => prev.filter(g => g.id !== id));
    });
  };
  // 🎉 Celebración PROPIA — solo para quien acaba de pagar, garantizada
  // (no depende de que el Realtime alcance a reconectar justo a tiempo
  // después de volver del navegador de Conekta, a diferencia del efecto
  // de arriba que es para OTROS viendo el perfil al mismo tiempo). Se
  // dispara desde onSent del GiftPickerModal — una sola vez, con confeti.
  const [ownCelebrating, setOwnCelebrating] = useState(false);
  const celebrateOwnGift = (info?: { emoji: string }) => {
    if (!info) return;
    spawnGiftBox(info.emoji);
    setOwnCelebrating(true);
    setTimeout(() => setOwnCelebrating(false), 1900);
  };
  const [profileAdIdx,     setProfileAdIdx]     = useState(0);
  const [profileAdImgErr,  setProfileAdImgErr]  = useState(false);
  const [profileAdMuted,   setProfileAdMuted]   = useState(false);
  const profileAdFade = useRef(new Animated.Value(1)).current;

  // Auto-rotate profile ads every 6 seconds when more than 1 exist.
  // 'len' se captura en variable local para evitar stale closure:
  // si profileAds cambiara entre renders, el closure usaría el valor
  // correcto del momento en que se creó el timer (safe read-only).
  useEffect(() => {
    if (profileAds.length <= 1) return;
    const len = profileAds.length;   // captura local — sin stale closure
    const timer = setInterval(() => {
      Animated.timing(profileAdFade, { toValue: 0, duration: 250, useNativeDriver: true }).start(() => {
        setProfileAdIdx(prev => (prev + 1) % len);
        setProfileAdImgErr(false);
        Animated.timing(profileAdFade, { toValue: 1, duration: 250, useNativeDriver: true }).start();
      });
    }, 6000);
    return () => clearInterval(timer);   // cleanup: sin fuga de memoria
  }, [profileAds.length]);

  const onRefresh = async () => {
    setRefreshing(true);
    const id = group?.id ?? initialGroup?.id;
    if (id) {
      const { data } = await supabase.from('groups').select('*').eq('id', id).single();
      if (data) setGroup(data);
      await loadReviews();
    }
    setRefreshing(false);
  };

  // 🎁 Recibir regalos es exclusivo de grupos con Plus vigente (sql/571) —
  // el cliente no puede comprarle Plus al grupo, así que aquí solo se
  // avisa, sin botón de compra (ese gancho va del lado del grupo).
  const openGiftModal = (postId?: string) => {
    const plusVigente = !!(group as any)?.is_plus_active &&
      (!(group as any)?.plus_expires_at || new Date((group as any).plus_expires_at) > new Date());
    if (!plusVigente) {
      Alert.alert(t('groupDetailScreen.gifts.unavailableTitle'), t('groupDetailScreen.gifts.unavailableBody'));
      return;
    }
    setGiftModalPostId(postId);
    setGiftModalVisible(true);
  };

  // ─── Compartir con foto real (no solo texto) ────────────────────────────
  // Se captura la tarjeta oculta (shareCardRef) como imagen y se comparte
  // junto con el link — así el share sheet nativo ofrece "Compartir en
  // Instagram Historia", WhatsApp, etc. con la foto de verdad, no solo
  // un mensaje pelón. Si algo falla (sin foto, error de captura), cae a
  // compartir solo el texto/link — nunca se queda sin poder compartir.
  const captureAndShare = async (imageUri: string | null, title: string, message: string) => {
    if (sharingCard) return;
    setSharingCard(true);
    try {
      if (imageUri) {
        setShareCardData({ imageUri, title });
        await new Promise(resolve => setTimeout(resolve, 350)); // deja pintar la imagen de fondo
        const rawUri = await captureRef(shareCardRef, { format: 'jpg', quality: 0.92 });
        // captureRef guarda el archivo con un nombre feo (hash/numeros) —
        // algunas apps (Mensajes, Instagram) muestran ese nombre tal cual
        // en la vista previa de compartir en vez de nuestro mensaje. Le
        // damos un nombre presentable antes de compartir; si falla, se
        // comparte igual con el nombre original.
        let shareUri = rawUri;
        try {
          const combiningMarks = new RegExp(String.fromCharCode(0x5c, 0x75, 0x30, 0x33, 0x30, 0x30, 0x2d, 0x5c, 0x75, 0x30, 0x33, 0x36, 0x66), 'g');
          const safeName = title
            .normalize('NFD').replace(combiningMarks, '')
            .replace(/[^a-zA-Z0-9]+/g, '-').replace(/^-+|-+$/g, '') || 'grupo';
          const niceUri = `${FileSystem.cacheDirectory}Daricefy-${safeName}.jpg`;
          await FileSystem.copyAsync({ from: rawUri, to: niceUri });
          shareUri = niceUri;
        } catch {}
        await Share.share({ url: shareUri, message });
      } else {
        await Share.share({ message, title });
      }
    } catch (_) {
      try { await Share.share({ message, title }); } catch {} // usuario canceló, o reintento sin imagen
    } finally {
      setShareCardData(null);
      setSharingCard(false);
    }
  };

  // Antes se agregaba un link "daricefy://group/..." al final del mensaje,
  // pero WhatsApp/Instagram/SMS solo hacen apretable un link http(s) — un
  // esquema propio como ese se muestra como texto plano, nunca clickeable.
  // Se quita hasta tener un dominio real con hosting al que sí se pueda
  // mandar a la gente (y desde ahí abrir la app).
  const handleShare = () => {
    captureAndShare(
      group?.profile_image ?? null,
      group?.name ?? 'Daricefy',
      t('groupDetailScreen.share.groupMessage', { name: group?.name ?? t('groupDetailScreen.share.defaultGroupName') }),
    );
  };

  // ─── Compartir una publicación puntual ──────────────────────────────────
  const sharePost = (post: any) => {
    const groupName = group?.name ?? t('groupDetailScreen.share.defaultGroupName');
    captureAndShare(
      post?.photos?.[0]?.url ?? null,
      groupName,
      (post?.caption ? t('groupDetailScreen.share.captionPrefix', { caption: post.caption }) : '') +
        t('groupDetailScreen.share.postMessage', { name: groupName }),
    );
  };

  useEffect(() => {
    if (!initialGroup) return;
    // Si el objeto recibido es incompleto (viene del mapa, RPC o deep link), cargar datos completos.
    // También recarga si video_status no vino en los params (RPC no lo retorna).
    const needsFullLoad = !initialGroup.description
      || !initialGroup.promo_video
      || initialGroup.video_status === undefined;
    if (needsFullLoad) {
      supabase
        .from('groups')
        .select('*')
        .eq('id', initialGroup.id)
        .single()
        .then(({ data }) => {
          if (data) setGroup(data);
          setLoading(false);
        });
    }
    checkProximity();
    loadReviews();

    // 👥 Seguidores (sql/563)
    supabase
      .from('group_follows')
      .select('id', { count: 'exact', head: true })
      .eq('group_id', initialGroup.id)
      .then(({ count }) => setFollowerCount(count ?? 0));
    if (user) {
      supabase
        .from('group_follows')
        .select('id')
        .eq('group_id', initialGroup.id)
        .eq('user_id', user.id)
        .maybeSingle()
        .then(({ data }) => setIsFollowing(!!data));
    }

    // 📸 Publicaciones de eventos del grupo (sql/561, varias fotos c/u) —
    // RLS ya filtra: el público solo ve aprobadas. Las más recientes primero.
    supabase
      .from('group_event_posts')
      .select('id, caption, created_at, photos:group_event_photos(id, url, position)')
      .eq('group_id', initialGroup.id)
      .eq('status', 'approved')
      .order('created_at', { ascending: false })
      .then(async ({ data }) => {
        if (!data) return;
        const posts = (data as any[]).map(p => ({
          ...p,
          photos: (p.photos ?? []).slice().sort((a: any, b: any) => a.position - b.position),
        }));
        setEventPosts(posts);
        const ids = posts.map(p => p.id);
        if (ids.length === 0) return;
        // ❤️ 💬 Conteo de likes/comentarios por publicación — para mostrarlo
        // en la tarjeta de la galería sin tener que abrir el detalle (sql/562).
        const [likesRes, commentsRes] = await Promise.all([
          supabase.from('group_event_post_likes').select('post_id').in('post_id', ids),
          supabase.from('group_event_post_comments').select('post_id').in('post_id', ids),
        ]);
        const counts: Record<string, { likes: number; comments: number }> = {};
        ids.forEach(id => { counts[id] = { likes: 0, comments: 0 }; });
        (likesRes.data as any[] ?? []).forEach(r => { counts[r.post_id].likes++; });
        (commentsRes.data as any[] ?? []).forEach(r => { counts[r.post_id].comments++; });
        setPostCounts(counts);

        // ❤️ ¿Cuáles ya le dio like ESTE cliente? — para pintar el corazón
        // rojo en la tarjeta de la galería sin abrir el detalle.
        if (user) {
          const { data: mine } = await supabase
            .from('group_event_post_likes')
            .select('post_id')
            .eq('user_id', user.id)
            .in('post_id', ids);
          const likedMap: Record<string, boolean> = {};
          (mine as any[] ?? []).forEach(r => { likedMap[r.post_id] = true; });
          setPostLikedMap(likedMap);
        }
      });

    // 🎬 Videos del perfil (carrusel): hasta 3, o 5 con Plus (sql/492).
    // RLS ya filtra: el público solo ve aprobados.
    supabase
      .from('group_videos')
      .select('id, url, position')
      .eq('group_id', initialGroup.id)
      .eq('status', 'approved')
      .order('position', { ascending: true })
      .order('created_at', { ascending: true })
      .then(({ data }) => { if (data) setProfileVideos(data as any[]); });

    // Registrar vista (fire-and-forget)
    supabase.rpc('track_group_view', { p_group_id: initialGroup.id });

    // Señales de actividad + urgencia
    supabase.rpc('get_group_activity_snapshot', { p_group_id: initialGroup.id })
      .maybeSingle()
      .then(({ data }) => { if (data) setActivitySnapshot(data); });

    // Grupos similares
    supabase.rpc('get_similar_groups', { p_group_id: initialGroup.id })
      .then(({ data }) => { if (data) setSimilarGroups((data as any[]).slice(0, 8)); });

    // Eventos completados reales del grupo — RPC (sql/560): la consulta
    // directa a reservations siempre daba 0 para un cliente que nunca
    // contrató a este grupo (RLS solo deja ver las reservas propias).
    supabase
      .rpc('get_group_completed_events_count', { p_group_id: initialGroup.id })
      .then(({ data }) => { setGroupCompletedCount(data ?? 0); });

    // Anuncios de perfil (segmentados por ciudad y estado del grupo)
    const profileAdState = (initialGroup as any).state ?? (group as any)?.state ?? null;
    console.log('[PROFILE_ADS]', { group_id: initialGroup.id, city: initialGroup.city, state: profileAdState });
    supabase.rpc('get_profile_ads', {
      p_group_id: initialGroup.id,
      p_city:     initialGroup.city ?? null,
      p_state:    profileAdState,
    })
      .then(({ data, error }) => {
        console.log('[PROFILE_ADS] result:', JSON.stringify(data), 'error:', error?.message);
        if (data && (data as any[]).length > 0) {
          setProfileAds(data as any[]);
          setProfileAdIdx(0);
        }
      });
  }, []);

  const loadReviews = async () => {
    const { data, error } = await supabase.rpc('get_group_reviews', {
      p_group_id: initialGroup.id,
      p_limit: 10,
    });
    if (error) console.warn('[GroupDetail] get_group_reviews:', error.message);
    if (data && (data as any[]).length > 0) {
      setReviews((data as any[]).map(r => ({
        review_id:     r.id,
        rating:        r.rating,
        comment:       r.comment,
        created_at:    r.created_at,
        client_name:   r.client_name,
        client_avatar: r.client_avatar,
      })));
      return;
    }

    // Plan B: leer la tabla directo (RLS pública de sql/93) — por si el RPC
    // de la BD es una versión vieja o falla. Así los comentarios SIEMPRE salen.
    const { data: raw, error: rawErr } = await supabase
      .from('reviews')
      .select('id, rating, comment, created_at, client:profiles!client_id(full_name, avatar_url)')
      .eq('group_id', initialGroup.id)
      .order('created_at', { ascending: false })
      .limit(10);
    if (rawErr) { console.warn('[GroupDetail] reviews fallback:', rawErr.message); return; }
    if (raw && raw.length > 0) {
      setReviews((raw as any[]).map(r => ({
        review_id:     r.id,
        rating:        r.rating,
        comment:       r.comment,
        created_at:    r.created_at,
        client_name:   r.client?.full_name ?? t('groupDetailScreen.reviews.defaultClientName'),
        client_avatar: r.client?.avatar_url ?? null,
      })) as any);
    }
  };

  // ── 📸 Detalle de publicación: likes + comentarios (sql/561-562) ───────
  const openPostDetail = async (post: any) => {
    setSelectedPost(post);
    setCarouselIndex(0);
    setPostComments([]);
    setCommentLikes({});
    setPostLikeCount(0);
    setPostLikedByMe(false);
    setCommentsLoading(true);
    setVisibleTopComments(5);
    setExpandedReplies({});
    setReplyingTo(null);

    const [{ count }, mine, commentsRes] = await Promise.all([
      supabase.from('group_event_post_likes').select('id', { count: 'exact', head: true }).eq('post_id', post.id),
      user
        ? supabase.from('group_event_post_likes').select('id').eq('post_id', post.id).eq('user_id', user.id).maybeSingle()
        : Promise.resolve({ data: null }),
      supabase
        .from('group_event_post_comments')
        .select('id, comment, created_at, parent_comment_id, author:profiles!user_id(full_name, avatar_url)')
        .eq('post_id', post.id)
        .order('created_at', { ascending: true }),
    ]);

    setPostLikeCount(count ?? 0);
    setPostLikedByMe(!!(mine as any)?.data);
    const comments = (commentsRes.data as any[]) ?? [];
    setPostComments(comments);

    // ❤️ Likes por comentario (sql/562)
    if (comments.length > 0) {
      const commentIds = comments.map(c => c.id);
      const [likesRes, mineRes] = await Promise.all([
        supabase.from('group_event_post_comment_likes').select('comment_id').in('comment_id', commentIds),
        user
          ? supabase.from('group_event_post_comment_likes').select('comment_id').eq('user_id', user.id).in('comment_id', commentIds)
          : Promise.resolve({ data: [] }),
      ]);
      const myLiked = new Set((mineRes.data as any[] ?? []).map(r => r.comment_id));
      const map: Record<string, { count: number; likedByMe: boolean }> = {};
      commentIds.forEach(id => { map[id] = { count: 0, likedByMe: myLiked.has(id) }; });
      (likesRes.data as any[] ?? []).forEach(r => { map[r.comment_id].count++; });
      setCommentLikes(map);
    }
    setCommentsLoading(false);
  };

  const closePostDetail = () => {
    // Si llegamos directo desde el feed "Inicio" a ver esta publicación,
    // cerrar debe regresar a Inicio — no dejar al usuario viendo el perfil
    // completo del grupo, que nunca pidió ver.
    if (initialOpenPost) {
      navigation.goBack();
      return;
    }
    setSelectedPost(null);
    setNewCommentText('');
  };

  // 📸 Llegó desde el feed "Inicio" con la publicación ya completa — el
  // modal ya se ve desde el primer render (selectedPost inicia con ella),
  // aquí solo se cargan los likes/comentarios de fondo, sin esperar a que
  // termine de cargar el perfil completo del grupo (evita el parpadeo).
  useEffect(() => {
    if (openedPostRef.current || !initialOpenPost) return;
    openedPostRef.current = true;
    openPostDetail(initialOpenPost);
  }, []);

  // 📸 Fallback: si solo llega el id (no la publicación completa), ábrela
  // en cuanto carguen las publicaciones del grupo.
  useEffect(() => {
    if (openedPostRef.current || !openPostId || eventPosts.length === 0) return;
    const target = eventPosts.find((p: any) => p.id === openPostId);
    if (target) {
      openedPostRef.current = true;
      openPostDetail(target);
    }
  }, [openPostId, eventPosts]);

  // 🎆 Regalo en vivo — mientras esta publicación está abierta, escucha
  // cuando algún group_gifts de este post pasa a 'paid' (confirm_gift_payment,
  // sql/569) y anima el emoji flotando. Se desuscribe al cerrar/cambiar
  // de publicación para no dejar canales abiertos de fondo.
  useEffect(() => {
    if (!selectedPost?.id) return;
    const postId = selectedPost.id;
    const channel = supabase
      .channel(`gift-post-${postId}`)
      .on(
        'postgres_changes',
        { event: 'UPDATE', schema: 'public', table: 'group_gifts', filter: `post_id=eq.${postId}` },
        async (payload: any) => {
          if (payload.new?.status !== 'paid') return;
          const { data: giftInfo } = await supabase
            .from('gift_catalog').select('emoji').eq('id', payload.new.gift_id).single();
          const emoji = giftInfo?.emoji ?? '🎁';
          const id = payload.new.id as string;
          const anim = new Animated.Value(0);
          setFloatingGifts(prev => [...prev, { id, emoji, anim }]);
          Animated.timing(anim, { toValue: 1, duration: 2200, useNativeDriver: true }).start(() => {
            setFloatingGifts(prev => prev.filter(g => g.id !== id));
          });
        },
      )
      .subscribe();
    return () => { supabase.removeChannel(channel); };
  }, [selectedPost?.id]);

  // 🎁 Igual pero para TODO el perfil (no solo dentro de una publicación) —
  // corre mientras el perfil del grupo esté abierto. Si alguien le manda
  // un regalo mientras varias personas están viendo el perfil, a todas
  // les sale el emoji saliendo de la cajita, en vivo, en ese momento —
  // nada queda guardado ni se vuelve a mostrar después de refrescar.
  useEffect(() => {
    if (!group?.id) return;
    const groupId = group.id;
    const channel = supabase
      .channel(`gift-profile-${groupId}`)
      .on(
        'postgres_changes',
        { event: 'UPDATE', schema: 'public', table: 'group_gifts', filter: `group_id=eq.${groupId}` },
        async (payload: any) => {
          if (payload.new?.status !== 'paid') return;
          // Tope de 5 a la vez — si llegan varios de golpe, que salgan
          // pocos y no se sature la pantalla (pedido explícito).
          if (liveGiftsCountRef.current >= 5) return;
          liveGiftsCountRef.current++;
          const { data: giftInfo } = await supabase
            .from('gift_catalog').select('emoji').eq('id', payload.new.gift_id).single();
          spawnGiftBox(giftInfo?.emoji ?? '🎁');
          setTimeout(() => { liveGiftsCountRef.current--; }, 2400);
        },
      )
      .subscribe();
    return () => { supabase.removeChannel(channel); };
  }, [group?.id]);

  // 🎁 Recordatorio de 24h para el CLIENTE que regaló — si ya le mandó un
  // regalo a este grupo en las últimas 24 horas, cada vez que vuelva a su
  // perfil ve la cajita + emoji saliendo (sin confeti — eso es SOLO del
  // momento exacto del pago, esto es solo un recordatorio visual). Después
  // de 24h deja de aparecer.
  useEffect(() => {
    if (!group?.id || !user?.id) return;
    (async () => {
      const since = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString();
      const { data } = await supabase
        .from('group_gifts')
        .select('paid_at, gift_catalog(emoji)')
        .eq('group_id', group.id)
        .eq('sender_id', user.id)
        .eq('status', 'paid')
        .gte('paid_at', since)
        .order('paid_at', { ascending: false })
        .limit(1)
        .maybeSingle();
      if (data) spawnGiftBox((data as any).gift_catalog?.emoji ?? '🎁');
    })();
  }, [group?.id, user?.id]);

  // 🔔 Avisa al dueño del grupo y a los integrantes (talento) ya aceptados
  // en el grupo cuando alguien da like o comenta una publicación —
  // mismo criterio de "integrante permanente" ya usado en TalentsScreen.tsx
  // (job_invitations aceptado, membership/job, sin event_id).
  const notifyGroupAboutActivity = async (kind: 'like' | 'comment') => {
    if (!selectedPost) return;
    const { data: members } = await supabase
      .from('job_invitations')
      .select('invited_user_id')
      .eq('group_id', group.id)
      .eq('status', 'accepted')
      .in('invitation_type', ['membership', 'job'])
      .is('event_id', null);

    const recipientIds = new Set<string>();
    if (group.owner_id) recipientIds.add(group.owner_id);
    (members ?? []).forEach((m: any) => recipientIds.add(m.invited_user_id));
    if (user?.id) recipientIds.delete(user.id); // no notificarse a sí mismo
    if (recipientIds.size === 0) return;

    const title = kind === 'like' ? t('groupDetailScreen.notifications.likeTitle') : t('groupDetailScreen.notifications.commentTitle');
    const body = kind === 'like'
      ? t('groupDetailScreen.notifications.likeBody')
      : t('groupDetailScreen.notifications.commentBody');
    await supabase.from('notifications').insert(
      Array.from(recipientIds).map(uid => ({
        user_id: uid,
        type: 'system',
        title,
        body,
        data: { screen: 'Dashboard' },
      }))
    );
  };

  // 👥 Seguir / dejar de seguir (sql/563)
  const toggleFollow = async () => {
    if (!user || followLoading) return;
    setFollowLoading(true);
    if (isFollowing) {
      await supabase.from('group_follows').delete()
        .eq('group_id', group.id).eq('user_id', user.id);
      setIsFollowing(false);
      setFollowerCount(c => Math.max(0, c - 1));
    } else {
      const { error } = await supabase.from('group_follows').insert({ group_id: group.id, user_id: user.id });
      if (error) {
        Alert.alert(t('groupDetailScreen.follow.errorTitle'), error.message.includes('self_follow_not_allowed') ? t('groupDetailScreen.follow.errorSelfBody') : t('groupDetailScreen.follow.errorGenericBody'));
      } else {
        setIsFollowing(true);
        setFollowerCount(c => c + 1);
      }
    }
    setFollowLoading(false);
  };

  const toggleLike = async () => {
    if (!user || !selectedPost || likeLoading) return;
    setLikeLoading(true);
    if (postLikedByMe) {
      await supabase.from('group_event_post_likes').delete()
        .eq('post_id', selectedPost.id).eq('user_id', user.id);
      setPostLikedByMe(false);
      setPostLikeCount(c => Math.max(0, c - 1));
      setPostCounts(prev => ({ ...prev, [selectedPost.id]: { likes: Math.max(0, (prev[selectedPost.id]?.likes ?? 1) - 1), comments: prev[selectedPost.id]?.comments ?? 0 } }));
      setPostLikedMap(prev => ({ ...prev, [selectedPost.id]: false }));
    } else {
      await supabase.from('group_event_post_likes').insert({ post_id: selectedPost.id, user_id: user.id });
      setPostLikedByMe(true);
      setPostLikeCount(c => c + 1);
      setPostCounts(prev => ({ ...prev, [selectedPost.id]: { likes: (prev[selectedPost.id]?.likes ?? 0) + 1, comments: prev[selectedPost.id]?.comments ?? 0 } }));
      setPostLikedMap(prev => ({ ...prev, [selectedPost.id]: true }));
      notifyGroupAboutActivity('like'); // fire-and-forget, solo al dar like (no al quitarlo)
    }
    setLikeLoading(false);
  };

  // ❤️ Like a un comentario individual (sql/562)
  const toggleCommentLike = async (commentId: string) => {
    if (!user) return;
    const current = commentLikes[commentId] ?? { count: 0, likedByMe: false };
    if (current.likedByMe) {
      await supabase.from('group_event_post_comment_likes').delete()
        .eq('comment_id', commentId).eq('user_id', user.id);
      setCommentLikes(prev => ({ ...prev, [commentId]: { count: Math.max(0, current.count - 1), likedByMe: false } }));
    } else {
      await supabase.from('group_event_post_comment_likes').insert({ comment_id: commentId, user_id: user.id });
      setCommentLikes(prev => ({ ...prev, [commentId]: { count: current.count + 1, likedByMe: true } }));
    }
  };

  const submitComment = async () => {
    if (!user || !selectedPost) return;
    const check = validateComment(newCommentText);
    if (!check.valid) {
      Alert.alert(t('groupDetailScreen.comments.errorTitle'), check.error);
      return;
    }
    setCommentSubmitting(true);
    const { data, error } = await supabase
      .from('group_event_post_comments')
      .insert({
        post_id: selectedPost.id,
        user_id: user.id,
        comment: newCommentText.trim(),
        parent_comment_id: replyingTo?.id ?? null,
      })
      .select('id, comment, created_at, parent_comment_id, author:profiles!user_id(full_name, avatar_url)')
      .single();
    setCommentSubmitting(false);
    if (error) {
      Alert.alert(t('groupDetailScreen.comments.genericErrorTitle'), t('groupDetailScreen.comments.genericErrorBody'));
      return;
    }
    setPostComments(prev => [...prev, data as any]);
    setCommentLikes(prev => ({ ...prev, [(data as any).id]: { count: 0, likedByMe: false } }));
    setPostCounts(prev => ({ ...prev, [selectedPost.id]: { likes: prev[selectedPost.id]?.likes ?? 0, comments: (prev[selectedPost.id]?.comments ?? 0) + 1 } }));
    if (replyingTo) setExpandedReplies(prev => ({ ...prev, [replyingTo.id]: true }));
    setReplyingTo(null);
    setNewCommentText('');
    notifyGroupAboutActivity('comment'); // fire-and-forget
  };

  const checkProximity = async () => {
    try {
      // Si el grupo tiene coordenadas en DB, usarlas; si no, intentar geolocalizar su ciudad
      // Por ahora usamos la ubicación del dispositivo vs. la ciudad del grupo (via geocode)
      const { status } = await Location.requestForegroundPermissionsAsync();
      if (status !== 'granted') return;

      const loc = await Location.getCurrentPositionAsync({ accuracy: Location.Accuracy.Low });

      // Intentar geocodificar la ciudad del grupo para comparar distancia
      if (group.city) {
        const results = await Location.geocodeAsync(`${group.city}, ${group.country ?? ''}`);
        if (results.length > 0) {
          const km = haversineKm(
            loc.coords.latitude, loc.coords.longitude,
            results[0].latitude,  results[0].longitude,
          );
          setIsNearby(km <= FAR_THRESHOLD_KM);
        }
      }
    } catch {
      // Falla silenciosa — no mostrar etiqueta si no hay datos
    }
  };

  return (
    <View style={styles.container}>
      <Particles />

      {/* 🎁 Regalo en vivo a nivel de todo el perfil (Realtime, sql/570) —
          fijo en pantalla (no se mueve con el scroll) para que se vea sin
          importar en qué parte del perfil esté quien lo esté viendo. */}
      <View style={styles.liveGiftsLayer} pointerEvents="none">
        {(() => {
          // Si todavía no se midió el botón real (measureInWindow tarda un
          // frame), cae a una posición fija razonable cerca de donde vive
          // el botón, para no dejar el efecto sin salir la primera vez.
          const anchorX = giftBtnPos?.x ?? (SCREEN_W - 60);
          const anchorY = giftBtnPos?.y ?? (insets.top + 250);
          return liveGifts.map((g, i) => {
            const jitter = (i % 3) * 12 - 12;
            return (
              <React.Fragment key={g.id}>
                {/* 🔵 Solo la "cajita" — azul con blanco, nace justo del botón
                    real. Sin emoji volando: con la notificación de
                    agradecimiento ya queda claro que se mandó/recibió. */}
                <Animated.View
                  style={[
                    styles.liveGiftBox,
                    {
                      left: anchorX - 15 + jitter,
                      top: anchorY - 15,
                      opacity: g.anim.interpolate({ inputRange: [0, 0.06, 0.85, 1], outputRange: [0, 1, 1, 0] }),
                      transform: [
                        { scale: g.anim.interpolate({ inputRange: [0, 0.15, 0.3], outputRange: [0.3, 1.25, 1] }) },
                        { rotate: g.anim.interpolate({ inputRange: [0, 0.1, 0.2, 0.3], outputRange: ['0deg', '-8deg', '8deg', '0deg'] }) },
                      ],
                    },
                  ]}
                >
                  <GiftIcon size={16} color="#fff" />
                </Animated.View>
              </React.Fragment>
            );
          });
        })()}
      </View>
      {ownCelebrating && <ProfileGiftConfetti />}

      {/* ScrollView al nivel raíz para que la imagen llegue al borde superior */}
      <ScrollView showsVerticalScrollIndicator={false} bounces={false} style={{ flex: 1 }} refreshControl={<RefreshControl refreshing={refreshing} onRefresh={onRefresh} tintColor={COLORS.green} />}>

        {/* ── HERO: Imagen full-bleed hasta los bordes del celular ── */}
        <View style={styles.heroContainer}>
          {group.profile_image ? (
            <Image source={{ uri: group.profile_image }} style={styles.heroBg} resizeMode="cover" />
          ) : (
            <View style={[styles.heroBg, styles.heroPlaceholder]}>
              <Text style={styles.heroPlaceholderText}>♪</Text>
            </View>
          )}

          <LinearGradient
            colors={['rgba(4,4,4,0)', 'rgba(4,4,4,0.25)', 'rgba(4,4,4,0.88)', COLORS.bg]}
            locations={[0, 0.38, 0.72, 1]}
            style={StyleSheet.absoluteFill}
          />

          {/* Tocar la foto la abre en grande (los botones/contenido quedan encima) */}
          {group.profile_image && (
            <Pressable style={StyleSheet.absoluteFill} onPress={() => setPhotoOpen(true)} />
          )}

          {/* Botones flotantes: back (izq) + compartir (der) */}
          <SafeAreaView edges={['top']} style={styles.heroSafeTop}>
            <View style={styles.heroTopRow}>
              <Pressable style={styles.heroBackBtn} onPress={() => navigation.goBack()}>
                <ArrowLeft size={20} color="#fff" />
              </Pressable>
              <Pressable style={styles.heroShareBtn} onPress={handleShare} disabled={sharingCard}>
                {sharingCard
                  ? <ActivityIndicator size="small" color="#fff" />
                  : <Share2 size={18} color="#fff" />}
              </Pressable>
            </View>
          </SafeAreaView>


          {/* Info superpuesta sobre el gradiente */}
          <View style={styles.heroContent}>
            {group.nivel && <LevelBadge nivel={group.nivel} size="sm" />}

            {/* Nombre + verificado + Seguir en la misma fila */}
            <View style={styles.heroNameRow}>
              <Text style={styles.heroName} numberOfLines={2}>{group.name}</Text>
              {group.is_verified && (
                <VerifiedBadge
                  size={22}
                  tier={(!!(group as any).is_plus_active &&
                    (!(group as any).plus_expires_at || new Date((group as any).plus_expires_at) > new Date()))
                    ? 'plus' : 'free'}
                />
              )}
              <View style={{ flex: 1 }} />
              {user && (
                <Pressable
                  style={[styles.heroFollowBtnSmall, isFollowing && styles.heroFollowBtnActive, followLoading && { opacity: 0.6 }]}
                  onPress={toggleFollow}
                  disabled={followLoading}
                >
                  <Text style={[styles.heroFollowBtnTx, isFollowing && styles.heroFollowBtnTxActive]}>
                    {isFollowing ? t('groupDetailScreen.follow.following') : t('groupDetailScreen.follow.followBtn')}
                  </Text>
                </Pressable>
              )}
            </View>

            <View style={styles.heroSubRow}>
              {group.genre && (
                <View style={styles.heroGenreTag}>
                  <Music2 size={13} color={COLORS.green} />
                  <Text style={styles.heroGenreText}>{group.genre}</Text>
                </View>
              )}
              {(group.city || group.country) && (
                <View style={styles.heroMeta}>
                  <MapPin size={12} color="rgba(255,255,255,0.6)" />
                  <Text style={styles.heroMetaText}>
                    {[group.city, group.country].filter(Boolean).join(', ')}
                  </Text>
                </View>
              )}
            </View>

            {/* Cercanía — el rating con estrella ya no va aquí (las reseñas
                están más abajo, esta estrellita quedaba redundante) */}
            <View style={styles.heroStatsRow}>
              {isNearby === true && (
                <View style={styles.nearbyChip}>
                  <Navigation size={10} color={COLORS.green} />
                  <Text style={styles.nearbyChipText}>{t('groupDetailScreen.nearby.yourZone')}</Text>
                </View>
              )}
              {isNearby === false && (
                <View style={styles.farChip}>
                  <Navigation size={10} color={COLORS.orange} />
                  <Text style={styles.farChipText}>{t('groupDetailScreen.nearby.outOfZone')}</Text>
                </View>
              )}
            </View>

            {/* Chip de confianza (eventos realizados) + COTIZAR hasta la derecha */}
            {(() => {
              const hasEvents = groupCompletedCount !== null && groupCompletedCount > 0;
              return (
                <View style={styles.heroTrustRow}>
                  {hasEvents && (
                    <View style={styles.trustChip}>
                      <Text style={styles.trustChipText}>
                        {t('groupDetailScreen.trust.eventsRealized', { count: groupCompletedCount })}
                      </Text>
                    </View>
                  )}
                  {followerCount > 0 && (
                    <View style={styles.trustChip}>
                      <Text style={styles.trustChipText}>
                        <Text style={styles.followerCountNum}>{followerCount}</Text> {t('groupDetailScreen.trust.followers', { count: followerCount })}
                      </Text>
                    </View>
                  )}
                  <View style={{ flex: 1 }} />
                  {user && group.owner_id !== user.id && (
                    <GiftCallToAction onPress={() => openGiftModal(undefined)} onMeasured={setGiftBtnPos} />
                  )}
                  <Pressable
                    style={styles.heroQuoteBtn}
                    onPress={() => navigation.navigate('QuoteForm', { group, isGift, ...(eventCtxParams ?? {}) })}
                  >
                    <Text style={styles.heroQuoteBtnTx}>{t('groupDetailScreen.trust.quote')}</Text>
                  </Pressable>
                </View>
              );
            })()}

            {/* Badges de rendimiento */}
            <View style={styles.heroBadges}>
              {!group.is_verified && (
                <View style={styles.unverifiedChip}>
                  <Shield size={12} color="rgba(255,255,255,0.45)" />
                  <Text style={styles.unverifiedChipText}>{t('groupDetailScreen.badges.unverified')}</Text>
                </View>
              )}
              {group.badges?.includes('quick_response') && (
                <View style={styles.quickResponseChip}>
                  <Zap size={11} color="#F59E0B" />
                  <Text style={styles.quickResponseChipText}>{t('groupDetailScreen.badges.quickResponse')}</Text>
                </View>
              )}
              {group.badges?.includes('trusted_group') && (
                <View style={styles.trustedChip}>
                  <ShieldCheck size={11} color={COLORS.green} />
                  <Text style={styles.trustedChipText}>{t('groupDetailScreen.badges.trustedGroup')}</Text>
                </View>
              )}
            </View>
          </View>
        </View>

        {/* ── CONTENIDO ── */}
        <View style={styles.body}>

          {/* 🎬 VIDEOS — carrusel estilo explorador: tarjeta reducida con los
              de al lado asomándose. Espacios sin video = tarjeta 🔒 "no
              disponible" (hasta que el grupo suba/pague). Si el Plus expiró,
              solo se muestran los primeros 3. */}
          {(profileVideos.length > 0 || (group.promo_video && group.video_status === 'approved')) && (() => {
            const plusActive = !!(group as any).is_plus_active &&
              (!(group as any).plus_expires_at || new Date((group as any).plus_expires_at) > new Date());
            // 🎬 GRATIS: 1 video · con PLUS vigente: 3 (corrección 2026-07-16)
            const maxSlots = plusActive ? 3 : 1;
            // El video "legacy" (promo_video) y los del carrusel (group_videos)
            // son DOS fuentes distintas — antes una tapaba a la otra (si había
            // algún video en el carrusel, el legacy ya aprobado desaparecía
            // del todo). Ahora se combinan: legacy primero, luego el carrusel.
            const real = [
              ...(group.promo_video && group.video_status === 'approved'
                ? [{ id: 'legacy', url: group.promo_video }]
                : []),
              ...profileVideos,
            ].slice(0, maxSlots);   // 🔒 sin Plus vigente, solo el primero
            // Siempre 3 espacios: el real al frente, los 🔒 atrasito a los
            // lados (al pagar Plus se vuelven sus videos reales)
            const slots: any[] = [
              ...real.map(v => ({ ...v, locked: false })),
              ...Array.from({ length: Math.max(0, 3 - real.length) }, (_, i) => ({ id: `lock-${i}`, locked: true })),
            ];
            return (
              <View style={styles.videoSection}>
                <Text style={styles.sectionTitle}>{t('groupDetailScreen.sections.videos')}</Text>
                {/* Baraja estilo explorador: el del frente grande y opaco,
                    los de los lados ATRASITO (chicos, semitransparentes) */}
                <VideoDeck slots={slots} />
              </View>
            );
          })()}

          {/* Cargando datos completos del grupo */}
          {loading && (
            <View style={styles.loadingBox}>
              <ActivityIndicator size="large" color={COLORS.green} />
            </View>
          )}

          {/* ── INSIGNIAS ── */}
          {group.badges && group.badges.length > 0 && (
            <View style={styles.badgesRow}>
              {group.badges.includes('top_artist') && (
                <View style={styles.badgeChip}>
                  <Award size={13} color={COLORS.gold} />
                  <Text style={styles.badgeChipText}>{t('groupDetailScreen.badges.topArtist')}</Text>
                </View>
              )}
              {group.badges.includes('high_demand') && (
                <View style={[styles.badgeChip, styles.badgeChipGreen]}>
                  <TrendingUp size={13} color={COLORS.green} />
                  <Text style={[styles.badgeChipText, { color: COLORS.green }]}>{t('groupDetailScreen.badges.highDemand')}</Text>
                </View>
              )}
              {group.badges.includes('trusted_group') && (
                <View style={[styles.badgeChip, styles.badgeChipBlue]}>
                  <ShieldCheck size={13} color="#90CAF9" />
                  <Text style={[styles.badgeChipText, { color: '#90CAF9' }]}>{t('groupDetailScreen.badges.trustedGroup')}</Text>
                </View>
              )}
              {group.badges.includes('high_acceptance') && (
                <View style={[styles.badgeChip, styles.badgeChipBlue]}>
                  <ThumbsUp size={13} color="#90CAF9" />
                  <Text style={[styles.badgeChipText, { color: '#90CAF9' }]}>{t('groupDetailScreen.badges.highAcceptance')}</Text>
                </View>
              )}
              {group.badges.includes('quick_response') && (
                <View style={[styles.badgeChip, styles.badgeChipBlue]}>
                  <Zap size={13} color="#90CAF9" />
                  <Text style={[styles.badgeChipText, { color: '#90CAF9' }]}>{t('groupDetailScreen.badges.quickResponseAlt')}</Text>
                </View>
              )}
              {group.badges.includes('top_ciudad') && (
                <View style={[styles.badgeChip, styles.badgeChipGold]}>
                  <Award size={13} color="#FFB300" />
                  <Text style={[styles.badgeChipText, { color: '#FFB300' }]}>{t('groupDetailScreen.badges.topCity')}</Text>
                </View>
              )}
            </View>
          )}

          {/* ── SEÑALES DE URGENCIA / ACTIVIDAD ── */}
          {activitySnapshot?.badges?.length > 0 && (
            <View style={styles.activityPanel}>
              {(activitySnapshot.badges as any[]).map((badge: any, i: number) => (
                <View key={i} style={styles.activityBadge}>
                  <Text style={styles.activityBadgeIcon}>{badge.icon}</Text>
                  <Text style={styles.activityBadgeText}>{badge.message}</Text>
                </View>
              ))}
            </View>
          )}

          {/* ── PUBLICACIONES (sql/561) — solo las que el admin aprobó, cada
                 una puede traer varias fotos ── */}
          {eventPosts.length > 0 && (
            <View style={styles.reviewsSection}>
              <View style={[styles.reviewsHeader, { justifyContent: 'space-between' }]}>
                <Text style={styles.reviewsTitle}>{t('groupDetailScreen.sections.posts')}</Text>
                {eventPosts.length > 3 && (
                  <Pressable style={styles.seeMorePostsBtn} onPress={() => setShowAllPosts(true)}>
                    <Text style={styles.seeMorePostsBtnText}>{t('groupDetailScreen.sections.seeMore')}</Text>
                  </Pressable>
                )}
              </View>
              <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={{ gap: 10, paddingRight: 4 }}>
                {eventPosts.map((post, i) => (
                  <Pressable
                    key={post.id}
                    style={[styles.eventPhotoCard, i === 0 && styles.eventPhotoCardLatest]}
                    onPress={() => openPostDetail(post)}
                  >
                    {/* Estilo Facebook: descripción arriba, foto abajo */}
                    <View style={styles.eventPhotoCaptionBox}>
                      {post.caption ? (
                        <Text style={styles.eventPhotoCaption} numberOfLines={1} ellipsizeMode="tail">{post.caption}</Text>
                      ) : null}
                      <Text style={styles.eventPhotoDate}>{formatPhotoTimeAgo(post.created_at, t)}</Text>
                    </View>
                    <View>
                      <Image source={{ uri: post.photos?.[0]?.url }} style={styles.eventPhotoImg} resizeMode="cover" />
                      {post.photos?.length > 1 && (
                        <View style={styles.eventPhotoMultiBadge}>
                          <Text style={styles.eventPhotoMultiBadgeText}>1/{post.photos.length}</Text>
                        </View>
                      )}
                    </View>
                    <View style={styles.eventPhotoCountsRow}>
                      <Heart
                        size={12}
                        color={postLikedMap[post.id] ? '#EF5350' : COLORS.muted2}
                        fill={postLikedMap[post.id] ? '#EF5350' : 'transparent'}
                      />
                      <Text style={styles.eventPhotoCountsText}>{postCounts[post.id]?.likes ?? 0}</Text>
                      <MessageCircle size={12} color={COLORS.muted2} style={{ marginLeft: 8 }} />
                      <Text style={styles.eventPhotoCountsText}>{postCounts[post.id]?.comments ?? 0}</Text>
                    </View>
                  </Pressable>
                ))}
              </ScrollView>
            </View>
          )}

          {/* ── RESEÑAS — debajo de las publicaciones (pedido 2026-08-24).
                 Carrusel deslizable. Foto+nombre del cliente reseñador
                 visible en pequeño; NO ampliable (regla de producto: los
                 clientes no ven fotos de otros clientes en grande).
                 Tocar el comentario lo expande completo. ── */}
          {reviews.length > 0 && (
            <View style={styles.reviewsSection}>
              <View style={styles.reviewsHeader}>
                <Star size={15} color={COLORS.gold} fill={COLORS.gold} />
                <Text style={styles.reviewsTitle}>
                  {group.average_rating?.toFixed(1)} · {t('groupDetailScreen.reviews.countLabel', { count: group.total_reviews })}
                </Text>
              </View>
              <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={{ gap: 10, paddingRight: 4 }}>
                {reviews.map(rv => (
                  <Pressable
                    key={rv.review_id}
                    style={styles.reviewCardH}
                    onPress={() => setExpandedReviewId(id => id === rv.review_id ? null : rv.review_id)}
                  >
                    <View style={styles.reviewerRow}>
                      {rv.client_avatar
                        ? <Image source={{ uri: rv.client_avatar }} style={styles.reviewerAvatar} />
                        : (
                          <View style={styles.reviewerAvatarPh}>
                            <Text style={styles.reviewerAvatarInitial}>
                              {(rv.client_name ?? '?').charAt(0).toUpperCase()}
                            </Text>
                          </View>
                        )
                      }
                      <View style={{ flex: 1 }}>
                        <Text style={styles.reviewClient} numberOfLines={1}>{rv.client_name}</Text>
                        <Text style={styles.reviewDate}>
                          {new Date(rv.created_at).toLocaleDateString('es-MX', { month: 'short', year: 'numeric' })}
                        </Text>
                      </View>
                      <StarRow rating={rv.rating} size={10} />
                    </View>
                    {rv.comment ? (
                      <Text style={styles.reviewComment} numberOfLines={expandedReviewId === rv.review_id ? undefined : 3}>
                        {rv.comment}
                      </Text>
                    ) : (
                      <Text style={[styles.reviewComment, { color: COLORS.muted }]}>{t('groupDetailScreen.reviews.noComment')}</Text>
                    )}
                  </Pressable>
                ))}
              </ScrollView>
            </View>
          )}

          {/* ── GARANTÍA DARICEFY — compacta, se expande al tocar (más abajo, pedido 2026-08-22) ── */}
          <Pressable style={styles.trustCompact} onPress={() => setTrustExpanded(v => !v)}>
            <View style={styles.trustHeader}>
              <ShieldCheck size={14} color={COLORS.green} />
              <Text style={styles.trustCompactTitle}>{t('groupDetailScreen.guarantee.title')}</Text>
              <Text style={styles.trustChevron}>{trustExpanded ? '▲' : '▼'}</Text>
            </View>
            {trustExpanded && (
              <>
                <Text style={styles.trustSubtitle}>
                  {t('groupDetailScreen.guarantee.subtitle')}
                </Text>
                <View style={styles.trustBenefits}>
                  <View style={styles.trustBenefitRow}>
                    <CheckCircle size={12} color={COLORS.green} />
                    <Text style={styles.trustBenefitText}>{t('groupDetailScreen.guarantee.benefitVerified')}</Text>
                  </View>
                  <View style={styles.trustBenefitRow}>
                    <Headphones size={12} color={COLORS.green} />
                    <Text style={styles.trustBenefitText}>{t('groupDetailScreen.guarantee.benefitSupport')}</Text>
                  </View>
                  <View style={styles.trustBenefitRow}>
                    <Star size={12} color={COLORS.green} fill={COLORS.green} />
                    <Text style={styles.trustBenefitText}>{t('groupDetailScreen.guarantee.benefitHistory')}</Text>
                  </View>
                </View>
                <View style={styles.safetyNotice}>
                  <Shield size={11} color={COLORS.muted2} />
                  <Text style={styles.safetyNoticeText}>
                    {t('groupDetailScreen.guarantee.safetyNotice')}
                  </Text>
                </View>
              </>
            )}
          </Pressable>

          {/* ── GRUPOS SIMILARES ── */}
          {similarGroups.length > 0 && (
            <View style={styles.similarSection}>
              <Text style={styles.sectionTitle}>{t('groupDetailScreen.sections.alsoLike')}</Text>
              <ScrollView horizontal showsHorizontalScrollIndicator={false} style={{ marginTop: 10 }} contentContainerStyle={{ gap: 12, paddingRight: 4 }}>
                {similarGroups.map((sg: any) => (
                  <Pressable
                    key={sg.group_id}
                    style={styles.similarCard}
                    onPress={() => navigation.push('GroupDetail', { group: { id: sg.group_id, name: sg.name, genre: sg.genre, city: sg.city, average_rating: sg.average_rating, total_reviews: sg.total_reviews } })}
                  >
                    <Text style={styles.similarName} numberOfLines={2}>{sg.name}</Text>
                    {sg.genre ? <Text style={styles.similarGenre} numberOfLines={1}>{sg.genre}</Text> : null}
                    {sg.average_rating > 0 && (
                      <View style={styles.similarRating}>
                        <Star size={10} color={COLORS.gold} fill={COLORS.gold} />
                        <Text style={styles.similarRatingText}>{(sg.average_rating as number).toFixed(1)}</Text>
                      </View>
                    )}
                  </Pressable>
                ))}
              </ScrollView>
            </View>
          )}

          {/* (El botón de cotizar se movió ARRIBA, a la derecha de los chips
              de confianza — pedido 2026-07-16. Esta sección quedó fuera.) */}

          {/* ── ANUNCIO EN PERFIL — rota si hay varios ── */}
          {profileAds.length > 0 && (() => {
            const ad = profileAds[profileAdIdx % profileAds.length];
            return (
              <Animated.View style={{ opacity: profileAdFade }}>
                <View style={styles.profileAdCard}>
                  <View style={styles.profileAdTag}>
                    <Text style={styles.profileAdTagText}>{t('groupDetailScreen.ad.label')}</Text>
                    {profileAds.length > 1 && (
                      <Text style={[styles.profileAdTagText, { marginLeft: 6 }]}>
                        {profileAdIdx + 1}/{profileAds.length}
                      </Text>
                    )}
                  </View>
                  {ad.media_url && ad.media_type === 'image' && !profileAdImgErr && (
                    <Image
                      source={{ uri: ad.media_url }}
                      style={styles.profileAdImage}
                      resizeMode="cover"
                      onError={() => setProfileAdImgErr(true)}
                    />
                  )}
                  {ad.media_url && ad.media_type === 'video' && (
                    <View>
                      <VideoPlayer
                        uri={ad.media_url}
                        style={styles.profileAdImage}
                        contentFit="cover"
                        autoPlay
                        muted={profileAdMuted}
                        loop
                      />
                      <Pressable style={styles.profileAdMuteBtn} onPress={() => setProfileAdMuted(m => !m)} hitSlop={8}>
                        {profileAdMuted ? <VolumeX size={15} color="#fff" /> : <Volume2 size={15} color="#fff" />}
                      </Pressable>
                    </View>
                  )}
                  <View style={styles.profileAdBody}>
                    <Text style={styles.profileAdTitle} numberOfLines={1}>{ad.title}</Text>
                    {ad.subtitle && <Text style={styles.profileAdSub} numberOfLines={2}>{ad.subtitle}</Text>}
                    {/* Botón oculto si el anuncio no tiene destino real —
                        antes se mostraba siempre y no hacía nada al
                        tocarlo cuando link_type='none' (2026-09-05). */}
                    {((ad.link_type === 'group' && ad.link_id) ||
                      (ad.link_type === 'video' && ad.youtube_url) ||
                      (ad.link_type === 'url' && ad.link_url)) && (
                      <Pressable
                        style={styles.profileAdBtn}
                        onPress={async () => {
                          if (ad.link_type === 'group' && ad.link_id) {
                            const { data } = await supabase.from('groups').select('*').eq('id', ad.link_id).single();
                            if (data) navigation.push('GroupDetail', { group: data });
                            return;
                          }
                          if (ad.link_type === 'video' && ad.youtube_url) {
                            WebBrowser.openBrowserAsync(ad.youtube_url, {
                              dismissButtonStyle: 'close',
                              presentationStyle: WebBrowser.WebBrowserPresentationStyle.PAGE_SHEET,
                            });
                            return;
                          }
                          // Enlace externo del botón (anuncios gratis del admin)
                          if (ad.link_type === 'url' && ad.link_url) {
                            WebBrowser.openBrowserAsync(ad.link_url, {
                              dismissButtonStyle: 'close',
                              presentationStyle: WebBrowser.WebBrowserPresentationStyle.PAGE_SHEET,
                            });
                          }
                        }}
                      >
                        <Text style={styles.profileAdBtnText}>{ad.button_text ?? t('groupDetailScreen.ad.more')} →</Text>
                      </Pressable>
                    )}
                  </View>
                </View>
              </Animated.View>
            );
          })()}

          {/* 🚩 Reportar contenido — cierra el círculo del takedown (Términos §6) */}
          <Pressable
            style={styles.reportProfileLink}
            hitSlop={8}
            onPress={() => {
              const send = async (reason: string) => {
                const { data, error } = await supabase.rpc('report_group_content', {
                  p_group_id: group.id,
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
                { text: t('groupDetailScreen.report.reasonInappropriate'), onPress: () => send('Contenido inapropiado en el perfil') },
                { text: t('groupDetailScreen.report.reasonFalseInfo'), onPress: () => send('Información falsa o engañosa en el perfil') },
                { text: t('groupDetailScreen.report.cancel'), style: 'cancel' },
              ]);
            }}
          >
            <Text style={styles.reportProfileText}>{t('groupDetailScreen.report.linkText')}</Text>
          </Pressable>

          <View style={{ height: 48 }} />
        </View>
      </ScrollView>

      <PhotoViewerModal
        uri={photoOpen ? (group.profile_image ?? null) : null}
        onClose={() => setPhotoOpen(false)}
      />

      {/* ── 📸 Detalle de foto de evento: like + comentarios (sql/559) ── */}
      <Modal visible={!!selectedPost} animationType="slide" onRequestClose={closePostDetail}>
        <View style={[styles.postDetailSafe, { paddingTop: insets.top }]}>
          {/* 🎆 Emojis flotando en vivo cuando alguien regala (sql/570) */}
          <View style={styles.floatingGiftsLayer} pointerEvents="none">
            {floatingGifts.map((g, i) => (
              <Animated.Text
                key={g.id}
                style={[
                  styles.floatingGiftEmoji,
                  {
                    left: `${15 + (i % 4) * 20}%`,
                    opacity: g.anim.interpolate({ inputRange: [0, 0.15, 0.8, 1], outputRange: [0, 1, 1, 0] }),
                    transform: [
                      { translateY: g.anim.interpolate({ inputRange: [0, 1], outputRange: [0, -260] }) },
                      { scale: g.anim.interpolate({ inputRange: [0, 0.2, 1], outputRange: [0.4, 1.2, 1] }) },
                    ],
                  },
                ]}
              >
                {g.emoji}
              </Animated.Text>
            ))}
          </View>

          {/* 🎁 Regalar desde DENTRO de la publicación — se monta aquí (no
              a nivel raíz) porque este bloque ya vive dentro del <Modal>
              nativo del detalle; un segundo <Modal> apilado no funciona
              bien en Android, así que el picker (que ya no usa <Modal>
              propio) necesita renderizarse en el mismo árbol nativo. */}
          {user && giftModalVisible && giftModalPostId && (
            <GiftPickerModal
              visible={giftModalVisible}
              onClose={() => setGiftModalVisible(false)}
              groupId={group.id}
              groupName={group.name}
              groupCountry={group.country ?? null}
              postId={giftModalPostId}
              onSent={celebrateOwnGift}
            />
          )}

          <View style={[styles.postDetailHeader, { paddingTop: 14 }]}>
            {group.profile_image ? (
              <Image source={{ uri: group.profile_image }} style={styles.postDetailAvatar} />
            ) : (
              <View style={[styles.postDetailAvatar, styles.heroPlaceholder]} />
            )}
            <View style={{ flex: 1, flexDirection: 'row', alignItems: 'center', gap: 4 }}>
              <Text style={styles.postDetailGroupName} numberOfLines={1}>{group.name}</Text>
              {group.is_verified && (
                <VerifiedBadge
                  size={16}
                  tier={(!!(group as any).is_plus_active &&
                    (!(group as any).plus_expires_at || new Date((group as any).plus_expires_at) > new Date()))
                    ? 'plus' : 'free'}
                />
              )}
            </View>
            <Pressable hitSlop={10} onPress={closePostDetail}>
              <X size={22} color={COLORS.text} />
            </Pressable>
          </View>

          {selectedPost && (
            <ScrollView contentContainerStyle={{ paddingBottom: 24 }}>
              <View style={styles.postDetailCaptionBox}>
                {selectedPost.caption ? (
                  <Text style={styles.postDetailCaption}>{selectedPost.caption}</Text>
                ) : null}
                <Text style={styles.postDetailDate}>{formatPhotoTimeAgo(selectedPost.created_at, t)}</Text>
              </View>

              {/* Carrusel — varias fotos por publicación (sql/561) */}
              <ScrollView
                horizontal
                pagingEnabled
                showsHorizontalScrollIndicator={false}
                onMomentumScrollEnd={e => setCarouselIndex(Math.round(e.nativeEvent.contentOffset.x / SCREEN_W))}
              >
                {(selectedPost.photos ?? []).map((ph: any) => (
                  <Image key={ph.id} source={{ uri: ph.url }} style={[styles.postDetailImg, { width: SCREEN_W }]} resizeMode="contain" />
                ))}
              </ScrollView>
              {selectedPost.photos?.length > 1 && (
                <View style={styles.videoDots}>
                  {selectedPost.photos.map((_: any, i: number) => (
                    <View key={i} style={[styles.videoDot, i === carouselIndex && styles.videoDotOn]} />
                  ))}
                </View>
              )}

              <View style={styles.postDetailActions}>
                <View style={styles.postDetailActionsLeft}>
                  <Pressable style={styles.postDetailLikeBtn} onPress={toggleLike} disabled={!user || likeLoading}>
                    <Heart size={20} color={postLikedByMe ? '#EF5350' : COLORS.muted2} fill={postLikedByMe ? '#EF5350' : 'transparent'} />
                    <Text style={styles.postDetailLikeCount}>{postLikeCount}</Text>
                  </Pressable>
                  <View style={styles.postDetailCommentCountRow}>
                    <MessageCircle size={18} color={COLORS.muted2} />
                    <Text style={styles.postDetailLikeCount}>{postComments.length}</Text>
                  </View>
                </View>
                <View style={styles.postDetailActionsRight}>
                  {user && group.owner_id !== user.id && (
                    <Pressable style={styles.postDetailGiftBtn} onPress={() => openGiftModal(selectedPost.id)}>
                      <GiftIcon size={16} color="#fff" />
                    </Pressable>
                  )}
                  <Pressable style={styles.postDetailShareBtn} onPress={() => sharePost(selectedPost)}>
                    <Share2 size={18} color={COLORS.muted2} />
                  </Pressable>
                </View>
              </View>

              {/* Comentarios — la lista entera va dentro del ScrollView de la
                  pantalla, así que con muchos comentarios se puede deslizar
                  para verlos todos. */}
              <View style={styles.postDetailCommentsBox}>
                {commentsLoading ? (
                  <ActivityIndicator size="small" color={COLORS.green} style={{ marginTop: 12 }} />
                ) : postComments.length === 0 ? (
                  <Text style={styles.postDetailNoComments}>{t('groupDetailScreen.postDetail.noComments')}</Text>
                ) : (() => {
                  const topLevel = postComments.filter(c => !c.parent_comment_id);
                  const repliesByParent: Record<string, any[]> = {};
                  postComments.forEach(c => {
                    if (c.parent_comment_id) {
                      if (!repliesByParent[c.parent_comment_id]) repliesByParent[c.parent_comment_id] = [];
                      repliesByParent[c.parent_comment_id].push(c);
                    }
                  });
                  const shown = topLevel.slice(0, visibleTopComments);
                  const renderComment = (c: any, isReply: boolean) => (
                    <View key={c.id} style={[styles.postDetailCommentRow, isReply && styles.postDetailReplyRow]}>
                      {c.author?.avatar_url ? (
                        <Image source={{ uri: c.author.avatar_url }} style={[styles.postDetailCommentAvatar, isReply && styles.postDetailReplyAvatar]} />
                      ) : (
                        <View style={[styles.postDetailCommentAvatarPh, isReply && styles.postDetailReplyAvatar]}>
                          <Text style={styles.reviewerAvatarInitial}>
                            {(c.author?.full_name ?? '?').charAt(0).toUpperCase()}
                          </Text>
                        </View>
                      )}
                      <View style={{ flex: 1 }}>
                        <Text style={styles.postDetailCommentAuthor}>{c.author?.full_name ?? t('groupDetailScreen.postDetail.defaultUser')}</Text>
                        <Text style={styles.postDetailCommentText}>{c.comment}</Text>
                        {user && (
                          <Pressable
                            hitSlop={6}
                            onPress={() => setReplyingTo({ id: isReply ? c.parent_comment_id : c.id, name: c.author?.full_name ?? t('groupDetailScreen.postDetail.defaultUser') })}
                          >
                            <Text style={styles.postDetailReplyBtn}>{t('groupDetailScreen.postDetail.reply')}</Text>
                          </Pressable>
                        )}
                      </View>
                      <Pressable style={styles.postDetailCommentLikeBtn} onPress={() => toggleCommentLike(c.id)} disabled={!user}>
                        <Heart
                          size={14}
                          color={commentLikes[c.id]?.likedByMe ? '#EF5350' : '#8A8A84'}
                          fill={commentLikes[c.id]?.likedByMe ? '#EF5350' : 'transparent'}
                        />
                        {commentLikes[c.id]?.count > 0 && (
                          <Text style={styles.postDetailCommentLikeCount}>{commentLikes[c.id].count}</Text>
                        )}
                      </Pressable>
                    </View>
                  );
                  return (
                    <>
                      {shown.map(c => {
                        const replies = repliesByParent[c.id] ?? [];
                        return (
                          <View key={c.id}>
                            {renderComment(c, false)}
                            {replies.length > 0 && (
                              <Pressable
                                style={styles.postDetailViewRepliesBtn}
                                onPress={() => setExpandedReplies(prev => ({ ...prev, [c.id]: !prev[c.id] }))}
                              >
                                <View style={styles.postDetailReplyLine} />
                                <Text style={styles.postDetailViewRepliesText}>
                                  {expandedReplies[c.id]
                                    ? t('groupDetailScreen.postDetail.hideReplies')
                                    : t('groupDetailScreen.postDetail.viewReplies', { count: replies.length })}
                                </Text>
                              </Pressable>
                            )}
                            {expandedReplies[c.id] && replies.map(r => renderComment(r, true))}
                          </View>
                        );
                      })}
                      {topLevel.length > visibleTopComments && (
                        <Pressable onPress={() => setVisibleTopComments(v => v + 10)}>
                          <Text style={styles.postDetailViewMoreText}>
                            {t('groupDetailScreen.postDetail.viewMoreComments', { count: topLevel.length - visibleTopComments })}
                          </Text>
                        </Pressable>
                      )}
                    </>
                  );
                })()}
              </View>
            </ScrollView>
          )}

          {user && (
            <KeyboardAvoidingView behavior={Platform.OS === 'ios' ? 'padding' : undefined}>
              {replyingTo && (
                <View style={styles.postDetailReplyingChip}>
                  <Text style={styles.postDetailReplyingChipText}>{t('groupDetailScreen.postDetail.replyingTo', { name: replyingTo.name })}</Text>
                  <Pressable hitSlop={8} onPress={() => setReplyingTo(null)}>
                    <X size={14} color={COLORS.muted} />
                  </Pressable>
                </View>
              )}
              <View style={styles.postDetailInputRow}>
                <TextInput
                  style={styles.postDetailInput}
                  value={newCommentText}
                  onChangeText={setNewCommentText}
                  placeholder={replyingTo ? t('groupDetailScreen.postDetail.placeholderReplyTo', { name: replyingTo.name }) : t('groupDetailScreen.postDetail.placeholderComment')}
                  placeholderTextColor={COLORS.muted}
                  maxLength={300}
                />
                <Pressable
                  style={[styles.postDetailSendBtn, commentSubmitting && { opacity: 0.5 }]}
                  onPress={submitComment}
                  disabled={commentSubmitting}
                >
                  {commentSubmitting
                    ? <ActivityIndicator size="small" color={COLORS.bg} />
                    : <Send size={16} color={COLORS.bg} />}
                </Pressable>
              </View>
            </KeyboardAvoidingView>
          )}
        </View>
      </Modal>

      {/* 📚 "Ver más" — cuadrícula con TODAS las publicaciones del grupo.
          Fondo oscurecido (no blur real — sin dependencia nueva de
          expo-blur en el proyecto) en vez del carrusel de solo 3 a la vez.
          Tocar una tarjeta abre el MISMO detalle que ya usa el carrusel
          (openPostDetail) — sin duplicar esa lógica. */}
      <Modal visible={showAllPosts} animationType="slide" onRequestClose={() => setShowAllPosts(false)}>
        <View style={styles.allPostsOverlay}>
          {/* HALLAZGO REAL (2026-09-02): <SafeAreaView> no calcula bien el
              área segura DENTRO de un <Modal> nativo (mismo problema que ya
              existe en el modal de detalle, línea ~1651) — la X salía
              pegada arriba, debajo del status bar. Mismo arreglo que ya
              usa ese otro modal: insets.top manual en vez de SafeAreaView. */}
          <View style={[styles.allPostsHeader, { paddingTop: insets.top + 12 }]}>
            <Text style={styles.allPostsTitle}>{t('groupDetailScreen.sections.posts')}</Text>
            <Pressable style={styles.allPostsCloseBtn} onPress={() => setShowAllPosts(false)} hitSlop={8}>
              <X size={18} color={COLORS.text} />
            </Pressable>
          </View>
          <FlatList
            data={eventPosts}
            keyExtractor={(post) => post.id}
            numColumns={3}
            contentContainerStyle={{ paddingHorizontal: 3, paddingBottom: insets.bottom + 24 }}
            renderItem={({ item: post }) => (
              <Pressable
                style={styles.allPostsGridCell}
                onPress={() => { setShowAllPosts(false); openPostDetail(post); }}
              >
                <Image source={{ uri: post.photos?.[0]?.url }} style={styles.allPostsGridImg} resizeMode="cover" />
                {post.photos?.length > 1 && (
                  <View style={styles.allPostsGridBadge}>
                    <Text style={styles.allPostsGridBadgeText}>{post.photos.length}📷</Text>
                  </View>
                )}
                {/* Descripción de cada publicación, sobre la foto (pedido real) */}
                {!!post.caption && (
                  <View style={styles.allPostsGridCaptionBox}>
                    <Text style={styles.allPostsGridCaptionText} numberOfLines={2}>{post.caption}</Text>
                  </View>
                )}
              </Pressable>
            )}
          />
        </View>
      </Modal>

      {/* 🎁 Regalar desde el perfil (sin publicación abierta) — a nivel raíz,
          fuera del <Modal> del detalle. La instancia de arriba cubre el
          caso "dentro de una publicación". */}
      {user && giftModalVisible && !giftModalPostId && (
        <GiftPickerModal
          visible={giftModalVisible}
          onClose={() => setGiftModalVisible(false)}
          groupId={group.id}
          groupName={group.name}
          groupCountry={group.country ?? null}
          postId={giftModalPostId}
          onSent={celebrateOwnGift}
        />
      )}

      {/* 🖼️ Tarjeta oculta para compartir con foto real — fuera de la
          pantalla (top:-4000) pero montada, para que captureRef pueda
          leerla. Mismo patrón ya probado en TicketScreen.tsx. */}
      {shareCardData && (
        <View style={styles.shareCardWrap} pointerEvents="none">
          <View ref={shareCardRef} collapsable={false} style={styles.shareCard}>
            <Image source={{ uri: shareCardData.imageUri }} style={StyleSheet.absoluteFill} resizeMode="cover" />
            <LinearGradient colors={['transparent', 'rgba(0,0,0,0.88)']} locations={[0.4, 1]} style={StyleSheet.absoluteFill} />
            <View style={styles.shareCardFooter}>
              <Text style={styles.shareCardTitle} numberOfLines={2}>{shareCardData.title}</Text>
              <Text style={styles.shareCardBrand}>🎵 Daricefy</Text>
            </View>
          </View>
        </View>
      )}

    </View>
  );
}

const styles = StyleSheet.create({
  // 🖼️ Tarjeta oculta para compartir (foto real, formato historia 9:16)
  shareCardWrap: { position: 'absolute', top: -4000, left: 0 },
  shareCard: {
    width: 320, height: 568, backgroundColor: COLORS.bg,
    justifyContent: 'flex-end', overflow: 'hidden',
  },
  shareCardFooter: { padding: 22 },
  shareCardTitle: { fontFamily: FONTS.title, fontSize: 24, color: '#fff' },
  shareCardBrand: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.green, marginTop: 6 },
  container: { flex: 1, backgroundColor: COLORS.bg },

  // ── Hero full-bleed ──
  heroContainer: { width: '100%', height: 460, position: 'relative' },
  heroBg: { width: '100%', height: '100%', position: 'absolute' },
  heroPlaceholder: { backgroundColor: COLORS.card, alignItems: 'center', justifyContent: 'center' },
  heroPlaceholderText: { fontSize: 80, color: COLORS.muted },

  heroSafeTop: { position: 'absolute', top: 0, left: 0, right: 0 },
  heroTopRow: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between',
    paddingHorizontal: SPACING.xl, paddingTop: 10,
  },
  heroBackBtn: {
    width: 40, height: 40, borderRadius: 12,
    backgroundColor: 'rgba(4,4,4,0.55)', borderWidth: 1, borderColor: 'rgba(255,255,255,0.12)',
    alignItems: 'center', justifyContent: 'center',
  },
  heroShareBtn: {
    width: 40, height: 40, borderRadius: 12,
    backgroundColor: 'rgba(4,4,4,0.55)', borderWidth: 1, borderColor: 'rgba(255,255,255,0.12)',
    alignItems: 'center', justifyContent: 'center',
  },
  // 💬 Cotizar arriba — chico, visible, con brillo de marca
  heroQuoteBtn: {
    paddingHorizontal: 14, height: 40, borderRadius: 12,
    backgroundColor: COLORS.green, alignItems: 'center', justifyContent: 'center',
    shadowColor: '#00E676', shadowOpacity: 0.5, shadowRadius: 8,
    shadowOffset: { width: 0, height: 2 }, elevation: 6,
  },
  heroQuoteBtnTx: { fontFamily: FONTS.bodySemiBold, fontSize: 13.5, color: '#04110A' },
  heroGiftBtn: {
    width: 40, height: 40, borderRadius: 12, marginRight: 8,
    borderWidth: 1.5, borderColor: '#60A5FA',
    backgroundColor: '#3B82F6',
    alignItems: 'center', justifyContent: 'center',
  },
  heroGiftBtnTx: { fontSize: 18 },
  heroGiftGlow: {
    position: 'absolute', width: 40, height: 40, borderRadius: 12,
    backgroundColor: '#60A5FA',
  },
  heroFollowBtnSmall: {
    paddingHorizontal: 10, height: 26, borderRadius: 13,
    borderWidth: 1.5, borderColor: 'rgba(255,255,255,0.5)',
    alignItems: 'center', justifyContent: 'center',
  },
  heroFollowBtnActive: { borderColor: COLORS.green, backgroundColor: 'rgba(0,230,118,0.12)' },
  heroFollowBtnTx: { fontFamily: FONTS.bodySemiBold, fontSize: 11.5, color: '#fff' },
  heroFollowBtnTxActive: { color: COLORS.green },
  shareToast: {
    position: 'absolute', bottom: 16, alignSelf: 'center',
    backgroundColor: 'rgba(0,0,0,0.8)', borderRadius: RADIUS.full,
    paddingHorizontal: 18, paddingVertical: 9,
  },
  shareToastText: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: '#fff' },
  heroContent: {
    position: 'absolute', bottom: 0, left: 0, right: 0,
    paddingHorizontal: SPACING.xl, paddingBottom: 22,
  },
  heroNameRow: {
    flexDirection: 'row', alignItems: 'center', gap: 8,
    marginBottom: 2, marginTop: 6, flexShrink: 1,
  },
  heroVerifiedBadge: {
    width: 24, height: 24, borderRadius: 12,
    backgroundColor: 'rgba(66,133,244,0.25)',
    borderWidth: 1, borderColor: 'rgba(66,133,244,0.5)',
    alignItems: 'center', justifyContent: 'center',
    flexShrink: 0,
  },
  heroName: {
    fontFamily: FONTS.title, fontSize: 18, color: '#fff',
    lineHeight: 23, letterSpacing: 0.2, flexShrink: 1,
  },
  heroSubRow: { flexDirection: 'row', alignItems: 'center', gap: 14, marginBottom: 6, flexWrap: 'wrap' },
  heroGenreTag: { flexDirection: 'row', alignItems: 'center', gap: 6 },
  heroGenreText: { fontFamily: FONTS.bodyMedium, fontSize: 14, color: COLORS.green },
  heroMeta: { flexDirection: 'row', alignItems: 'center', gap: 5 },
  heroMetaText: { fontFamily: FONTS.body, fontSize: 13, color: 'rgba(255,255,255,0.6)' },

  heroStatsRow: { flexDirection: 'row', gap: 8, marginBottom: 6, flexWrap: 'wrap' },
  heroPricePill: {
    backgroundColor: COLORS.greenMuted, borderRadius: RADIUS.full,
    borderWidth: 1, borderColor: COLORS.green,
    paddingHorizontal: 10, paddingVertical: 5,
  },
  heroPricePillText: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.green },

  heroTrustRow: { flexDirection: 'row', gap: 6, flexWrap: 'wrap', marginBottom: 6 },
  trustChip: {
    paddingHorizontal: 2, paddingVertical: 4,
  },
  trustChipText: { fontFamily: FONTS.bodyMedium, fontSize: 11, color: 'rgba(255,255,255,0.85)' },
  followerCountNum: { fontFamily: FONTS.bodySemiBold, fontSize: 12, color: '#fff' },
  heroBadges: { flexDirection: 'row', gap: 8, flexWrap: 'wrap' },
  verifiedChip: {
    flexDirection: 'row', alignItems: 'center', gap: 5,
    backgroundColor: 'rgba(66,133,244,0.25)', borderRadius: RADIUS.full,
    borderWidth: 1, borderColor: 'rgba(66,133,244,0.5)',
    paddingHorizontal: 10, paddingVertical: 4,
  },
  verifiedChipText: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: '#90CAF9' },
  unverifiedChip: {
    flexDirection: 'row', alignItems: 'center', gap: 5,
    backgroundColor: 'rgba(255,255,255,0.08)', borderRadius: RADIUS.full,
    borderWidth: 1, borderColor: 'rgba(255,255,255,0.2)',
    paddingHorizontal: 10, paddingVertical: 4,
  },
  unverifiedChipText: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: 'rgba(255,255,255,0.5)' },
  nearbyChip: {
    flexDirection: 'row', alignItems: 'center', gap: 5,
    backgroundColor: 'rgba(0,230,118,0.2)', borderRadius: RADIUS.full,
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.5)',
    paddingHorizontal: 10, paddingVertical: 5,
  },
  nearbyChipText: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.green },
  farChip: {
    flexDirection: 'row', alignItems: 'center', gap: 5,
    backgroundColor: 'rgba(255,152,0,0.15)', borderRadius: RADIUS.full,
    borderWidth: 1, borderColor: 'rgba(255,152,0,0.4)',
    paddingHorizontal: 10, paddingVertical: 5,
  },
  farChipText: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.orange },

  // ── Body ──
  body: { paddingHorizontal: H_PAD, paddingTop: 20 },

  // 🎬 Carrusel de videos — efecto "destacado" del explorador
  videoSection: { marginBottom: 20 },
  videoCard: {
    borderRadius: 20, overflow: 'hidden', backgroundColor: '#060c06', marginTop: 8,
    borderWidth: 1.5, borderColor: 'rgba(0,230,118,0.35)',
    shadowColor: '#00E676', shadowOpacity: 0.25, shadowRadius: 12,
    shadowOffset: { width: 0, height: 4 }, elevation: 6,
  },
  videoDots:  { flexDirection: 'row', justifyContent: 'center', gap: 6, marginTop: 10 },
  videoDot:   { width: 6, height: 6, borderRadius: 3, backgroundColor: 'rgba(255,255,255,0.2)' },
  videoDotOn: { backgroundColor: COLORS.green, width: 16 },
  videoCardLocked: {
    height: 200, alignItems: 'center', justifyContent: 'center', gap: 8,
    borderColor: 'rgba(255,255,255,0.12)', borderStyle: 'dashed',
    shadowOpacity: 0, elevation: 0, backgroundColor: COLORS.card2,
  },
  videoLockedTx: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.muted },
  videoDeckPlay: {
    ...StyleSheet.absoluteFill,
    alignItems: 'center', justifyContent: 'center',
    backgroundColor: 'rgba(0,0,0,0.28)',
  },
  // 🔎 Vista en grande del video (tap en la tarjeta de al frente)
  videoFsSafe: { flex: 1, backgroundColor: '#000' },
  videoFsHeader: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between',
    paddingHorizontal: H_PAD, paddingBottom: 12,
  },
  videoFsCounter: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: 'rgba(255,255,255,0.8)' },
  videoDeckNav: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'center',
    gap: 14, marginTop: 10,
  },
  videoDeckArrow: {
    width: 26, height: 26, borderRadius: 13,
    alignItems: 'center', justifyContent: 'center',
    backgroundColor: 'rgba(255,255,255,0.08)',
    borderWidth: 1, borderColor: 'rgba(255,255,255,0.16)',
  },

  videoWrapper: { borderRadius: RADIUS.lg, overflow: 'hidden', backgroundColor: '#000', marginTop: 8 },
  video: { width: '100%', height: 200 },

  // Section
  sectionRow: { flexDirection: 'row', alignItems: 'center', gap: 7, marginBottom: 14 },
  sectionTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.text },

  // Loading / empty
  loadingBox: { alignItems: 'center', paddingVertical: 40 },
  emptyBox: {
    alignItems: 'center', paddingVertical: 40,
    backgroundColor: COLORS.card, borderRadius: RADIUS.xl,
    borderWidth: 1, borderColor: COLORS.border,
  },
  emptyTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 16, color: COLORS.text, marginBottom: 4 },
  emptyText: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2 },

  // Packages section
  packagesSection: { marginBottom: 20 },
  minHoursNotice: {
    flexDirection: 'row', alignItems: 'flex-start', gap: 8,
    backgroundColor: COLORS.greenMuted, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.green,
    padding: SPACING.md, marginBottom: 14,
  },
  minHoursText: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.green, flex: 1, lineHeight: 17 },

  // Package card
  packageCard: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.xl,
    borderWidth: 1, borderColor: COLORS.border,
    marginBottom: 14, overflow: 'hidden',
  },
  pkgTop: {
    flexDirection: 'row', justifyContent: 'space-between', alignItems: 'flex-start',
    padding: SPACING.lg, paddingBottom: 10,
  },
  packageName: { fontFamily: FONTS.bodySemiBold, fontSize: 17, color: COLORS.text, marginBottom: 4 },
  pkgMeta: { flexDirection: 'row', alignItems: 'center', gap: 5, marginBottom: 6 },
  pkgMetaText: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2 },
  pkgPriceCol: { alignItems: 'flex-end', minWidth: 80 },
  packagePrice: { fontFamily: FONTS.title, fontSize: 26, color: COLORS.green, lineHeight: 30 },
  pkgPriceSub: { fontFamily: FONTS.body, fontSize: 10, color: COLORS.muted, textAlign: 'right' },
  packageDescription: {
    fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2, lineHeight: 19,
    paddingHorizontal: SPACING.lg, paddingBottom: 10,
  },
  pkgAction: {
    backgroundColor: COLORS.green, paddingVertical: 13, alignItems: 'center',
  },
  pkgActionText: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.bg },

  // ── Badges row ──
  badgesRow: { flexDirection: 'row', gap: 8, flexWrap: 'wrap', marginBottom: 16 },
  badgeChip: {
    flexDirection: 'row', alignItems: 'center', gap: 5,
    backgroundColor: 'rgba(255,179,0,0.12)', borderRadius: RADIUS.full,
    borderWidth: 1, borderColor: 'rgba(255,179,0,0.4)',
    paddingHorizontal: 12, paddingVertical: 6,
  },
  badgeChipGreen: {
    backgroundColor: COLORS.greenMuted,
    borderColor: COLORS.green,
  },
  badgeChipBlue: {
    backgroundColor: 'rgba(66,133,244,0.12)',
    borderColor: 'rgba(66,133,244,0.4)',
  },
  badgeChipGold: {
    backgroundColor: 'rgba(255,179,0,0.12)',
    borderColor: 'rgba(255,179,0,0.4)',
  },
  badgeChipText: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.gold },

  // ── Reviews ──
  reviewsSection: { marginBottom: 20 },
  reviewsHeader: { flexDirection: 'row', alignItems: 'center', gap: 7, marginBottom: 12 },
  reviewsTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.text },
  seeMorePostsBtn: { paddingVertical: 4, paddingHorizontal: 4 },
  seeMorePostsBtnText: { fontFamily: FONTS.bodyMedium, fontSize: 12.5, color: COLORS.green },
  // 📚 Modal "ver más publicaciones" — cuadrícula, fondo oscurecido en vez
  // de blur real (sin dependencia nueva de expo-blur en el proyecto).
  allPostsOverlay: { flex: 1, backgroundColor: 'rgba(4,4,4,0.94)' },
  allPostsHeader: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between',
    paddingHorizontal: H_PAD, paddingTop: 14, paddingBottom: 10,
  },
  allPostsTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 16, color: COLORS.text },
  allPostsCloseBtn: {
    width: 32, height: 32, borderRadius: 16, alignItems: 'center', justifyContent: 'center',
    backgroundColor: COLORS.card, borderWidth: 1, borderColor: COLORS.border,
  },
  allPostsGridCell: { width: '33.33%', padding: 3 },
  allPostsGridImg: { width: '100%', aspectRatio: 1, borderRadius: RADIUS.md, backgroundColor: '#060c06' },
  allPostsGridBadge: {
    position: 'absolute', top: 6, right: 6,
    backgroundColor: 'rgba(0,0,0,0.65)', borderRadius: RADIUS.full,
    paddingHorizontal: 6, paddingVertical: 2,
  },
  allPostsGridBadgeText: { fontFamily: FONTS.bodyMedium, fontSize: 9.5, color: '#fff' },
  // Descripción sobre la foto (pedido real 2026-09-02) — franja oscura
  // pegada abajo para que el texto se lea sin importar el color de la foto.
  allPostsGridCaptionBox: {
    position: 'absolute', left: 3, right: 3, bottom: 3,
    backgroundColor: 'rgba(0,0,0,0.6)', borderBottomLeftRadius: RADIUS.md, borderBottomRightRadius: RADIUS.md,
    paddingHorizontal: 6, paddingVertical: 4,
  },
  allPostsGridCaptionText: { fontFamily: FONTS.bodyMedium, fontSize: 10, color: '#fff', lineHeight: 13 },
  reviewCardH: {
    width: 250,
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border,
    padding: SPACING.md, gap: 8,
  },
  reviewerRow: { flexDirection: 'row', alignItems: 'center', gap: 8 },
  reviewerAvatar:   { width: 26, height: 26, borderRadius: 13 },
  reviewerAvatarPh: {
    width: 26, height: 26, borderRadius: 13,
    backgroundColor: 'rgba(0,230,118,0.12)', alignItems: 'center', justifyContent: 'center',
  },
  reviewerAvatarInitial: { fontFamily: FONTS.bodySemiBold, fontSize: 12, color: COLORS.green },
  reviewDate: { fontFamily: FONTS.body, fontSize: 10, color: COLORS.muted2 },
  reviewClient: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.text },
  reviewComment: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, lineHeight: 18 },
  // 📸 Fotos de eventos (sql/558)
  // Achicado (2026-09-02, pedido real): antes 160px de ancho dejaba ver
  // apenas ~2 tarjetas completas en pantalla — reducido para que quepan
  // 3 cómodas sin scroll horizontal inmediato.
  eventPhotoCard: {
    width: 122, borderRadius: RADIUS.lg, overflow: 'hidden',
    backgroundColor: COLORS.card, borderWidth: 1, borderColor: COLORS.border,
  },
  // La publicación más reciente (índice 0) lleva un marco más llamativo —
  // las demás se quedan con el borde discreto de eventPhotoCard.
  eventPhotoCardLatest: {
    borderWidth: 1.5, borderColor: 'rgba(0,230,118,0.55)',
    shadowColor: '#00E676', shadowOpacity: 0.3, shadowRadius: 8,
    shadowOffset: { width: 0, height: 3 }, elevation: 5,
  },
  eventPhotoImg: { width: '100%', height: 110, backgroundColor: '#060c06' },
  eventPhotoCaptionBox: { height: 42, paddingHorizontal: 10, paddingVertical: 7, backgroundColor: '#0c0c0c' },
  eventPhotoCaption: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: 'rgba(255,255,255,0.94)' },
  eventPhotoDate: { fontFamily: FONTS.body, fontSize: 10, color: COLORS.muted2, marginTop: 2 },
  eventPhotoCountsRow: {
    flexDirection: 'row', alignItems: 'center',
    paddingHorizontal: 10, paddingVertical: 6,
  },
  eventPhotoCountsText: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted2, marginLeft: 4 },
  eventPhotoMultiBadge: {
    position: 'absolute', top: 6, right: 6,
    backgroundColor: 'rgba(0,0,0,0.6)', borderRadius: RADIUS.full,
    paddingHorizontal: 8, paddingVertical: 3,
  },
  eventPhotoMultiBadgeText: { fontFamily: FONTS.bodyMedium, fontSize: 10, color: '#fff' },
  // 📸 Detalle de foto de evento — likes + comentarios (sql/559)
  postDetailSafe: { flex: 1, backgroundColor: COLORS.bg },
  floatingGiftsLayer: {
    ...StyleSheet.absoluteFill, zIndex: 50, elevation: 50,
  },
  floatingGiftEmoji: { position: 'absolute', bottom: 120, fontSize: 34 },
  liveGiftsLayer: {
    ...StyleSheet.absoluteFill, zIndex: 60, elevation: 60,
  },
  liveGiftBox: {
    position: 'absolute', width: 30, height: 30, borderRadius: 9,
    backgroundColor: '#3B82F6', borderWidth: 1.5, borderColor: '#fff',
    alignItems: 'center', justifyContent: 'center',
  },
  profileConfettiLayer: {
    ...StyleSheet.absoluteFill, zIndex: 61, elevation: 61,
  },
  postDetailHeader: {
    flexDirection: 'row', alignItems: 'center', gap: 10,
    paddingHorizontal: H_PAD, paddingVertical: 12,
    borderBottomWidth: 1, borderBottomColor: COLORS.border,
  },
  postDetailAvatar: { width: 32, height: 32, borderRadius: 16, backgroundColor: COLORS.card2 },
  postDetailGroupName: { flexShrink: 1, fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.text },
  postDetailCaptionBox: { backgroundColor: COLORS.bg, paddingBottom: 10 },
  postDetailCaption: {
    fontFamily: FONTS.body, fontSize: 14, color: 'rgba(255,255,255,0.95)', lineHeight: 20,
    paddingHorizontal: H_PAD, marginTop: 12,
  },
  postDetailDate: {
    fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted2,
    paddingHorizontal: H_PAD, marginTop: 4,
  },
  postDetailImg: { width: '100%', height: 380, backgroundColor: '#060c06' },
  postDetailActions: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between',
    paddingHorizontal: H_PAD, paddingVertical: 12,
    borderBottomWidth: 1, borderBottomColor: COLORS.border,
  },
  postDetailActionsLeft:  { flexDirection: 'row', alignItems: 'center', gap: 20 },
  postDetailActionsRight: { flexDirection: 'row', alignItems: 'center', gap: 18 },
  postDetailLikeBtn: { flexDirection: 'row', alignItems: 'center', gap: 6 },
  postDetailLikeCount: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.text },
  postDetailCommentCountRow: { flexDirection: 'row', alignItems: 'center', gap: 6 },
  postDetailGiftBtn: {
    width: 30, height: 30, borderRadius: 9,
    borderWidth: 1.5, borderColor: '#60A5FA', backgroundColor: '#3B82F6',
    alignItems: 'center', justifyContent: 'center',
  },
  postDetailGiftBtnTx: { fontSize: 19 },
  postDetailShareBtn: { alignItems: 'center', justifyContent: 'center' },
  postDetailCommentsBox: {
    paddingHorizontal: H_PAD, paddingTop: 12, paddingBottom: 16, gap: 12,
    backgroundColor: COLORS.bg, flexGrow: 1,
  },
  postDetailNoComments: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted, textAlign: 'center', marginTop: 20 },
  postDetailCommentRow: { flexDirection: 'row', gap: 10, alignItems: 'flex-start' },
  postDetailCommentAvatar: { width: 28, height: 28, borderRadius: 14 },
  postDetailCommentAvatarPh: {
    width: 28, height: 28, borderRadius: 14, backgroundColor: COLORS.card2,
    alignItems: 'center', justifyContent: 'center',
  },
  postDetailCommentAuthor: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.text },
  postDetailCommentText: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2, marginTop: 2, lineHeight: 18 },
  postDetailCommentLikeBtn: { flexDirection: 'row', alignItems: 'center', gap: 3, paddingLeft: 8, paddingTop: 2 },
  postDetailCommentLikeCount: { fontFamily: FONTS.body, fontSize: 11, color: '#8A8A84' },
  // 💬 Respuestas a comentarios (sql/565), estilo Instagram
  postDetailReplyBtn: { fontFamily: FONTS.bodyMedium, fontSize: 11, color: COLORS.muted2, marginTop: 4 },
  postDetailReplyRow: { marginLeft: 38, marginTop: 10 },
  postDetailReplyAvatar: { width: 24, height: 24, borderRadius: 12 },
  postDetailViewRepliesBtn: {
    flexDirection: 'row', alignItems: 'center', gap: 8,
    marginLeft: 38, marginTop: 6,
  },
  postDetailReplyLine: { width: 20, height: 1, backgroundColor: COLORS.border },
  postDetailViewRepliesText: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.muted2 },
  postDetailViewMoreText: {
    fontFamily: FONTS.bodyMedium, fontSize: 12.5, color: COLORS.green,
    marginTop: 12,
  },
  postDetailReplyingChip: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between',
    paddingHorizontal: H_PAD, paddingTop: 8,
  },
  postDetailReplyingChipText: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.green },
  postDetailInputRow: {
    flexDirection: 'row', alignItems: 'center', gap: 10,
    paddingHorizontal: H_PAD, paddingVertical: 10,
    borderTopWidth: 1, borderTopColor: COLORS.border,
  },
  postDetailInput: {
    flex: 1, backgroundColor: COLORS.card2, borderRadius: RADIUS.full,
    borderWidth: 1, borderColor: COLORS.border,
    paddingHorizontal: 14, paddingVertical: 9,
    fontFamily: FONTS.body, fontSize: 13, color: COLORS.text,
  },
  postDetailSendBtn: {
    width: 36, height: 36, borderRadius: 18, backgroundColor: COLORS.green,
    alignItems: 'center', justifyContent: 'center',
  },

  // ── Quote section ──
  quoteSection: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.xl,
    borderWidth: 1, borderColor: 'rgba(255,152,0,0.3)',
    padding: SPACING.lg, marginTop: 4,
  },
  quoteHeader: { flexDirection: 'row', alignItems: 'flex-start', gap: 10, marginBottom: 10 },
  quoteTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.orange, flex: 1, lineHeight: 20 },
  quoteDesc: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2, lineHeight: 20, marginBottom: 16 },
  quoteBtn: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 8,
    backgroundColor: COLORS.orange, borderRadius: RADIUS.lg, paddingVertical: 13,
  },
  quoteBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.bg },

  // ── Activity / urgency panel ──
  activityPanel: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.xl,
    borderWidth: 1, borderColor: COLORS.border,
    padding: SPACING.md, marginBottom: 20, gap: 8,
  },
  activityBadge: { flexDirection: 'row', alignItems: 'center', gap: 10 },
  activityBadgeIcon: { fontSize: 18, lineHeight: 24 },
  activityBadgeText: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.text, flex: 1, lineHeight: 18 },

  // ── Similar groups ──
  similarSection: { marginBottom: 24 },
  similarCard: {
    width: 140, backgroundColor: COLORS.card,
    borderRadius: RADIUS.lg, borderWidth: 1, borderColor: COLORS.border,
    padding: SPACING.md, justifyContent: 'space-between',
  },
  similarName: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.text, marginBottom: 4, lineHeight: 18 },
  similarGenre: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.green, marginBottom: 6 },
  similarRating: { flexDirection: 'row', alignItems: 'center', gap: 4 },
  similarRatingText: { fontFamily: FONTS.bodyMedium, fontSize: 11, color: COLORS.gold },
  profileAdCard: {
    backgroundColor: COLORS.card2,
    borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: 'rgba(255,255,255,0.09)',
    overflow: 'hidden', marginBottom: 24,
  },
  profileAdTag: {
    flexDirection: 'row', alignItems: 'center', gap: 6,
    paddingHorizontal: 12, paddingVertical: 6,
    borderBottomWidth: 1, borderBottomColor: 'rgba(255,255,255,0.06)',
  },
  profileAdTagText: { fontFamily: FONTS.bodyMedium, fontSize: 9, color: COLORS.muted2, letterSpacing: 1.4 },
  profileAdImage: { width: '100%', height: 170 },
  profileAdMuteBtn: {
    position: 'absolute', top: 8, right: 8,
    width: 30, height: 30, borderRadius: 15,
    alignItems: 'center', justifyContent: 'center',
    backgroundColor: 'rgba(0,0,0,0.5)',
    borderWidth: 1, borderColor: 'rgba(255,255,255,0.15)',
  },
  profileAdBody: { padding: 14 },
  profileAdTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.text, marginBottom: 4 },
  profileAdSub: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, marginBottom: 12 },
  profileAdBtn: {
    alignSelf: 'flex-start',
    backgroundColor: 'rgba(0,230,118,0.12)',
    borderRadius: RADIUS.full,
    borderWidth: 1, borderColor: COLORS.green,
    paddingHorizontal: 16, paddingVertical: 7,
  },
  profileAdBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 12, color: COLORS.green },
  reportProfileLink: { alignSelf: 'center', marginTop: 18, paddingVertical: 6, paddingHorizontal: 14 },
  reportProfileText: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted, textDecorationLine: 'underline' },

  // ── Trust / Garantía — compacta y plegable ──
  trustCompact: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.25)',
    paddingHorizontal: 14, paddingVertical: 11, marginBottom: 16,
  },
  trustCompactTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 12.5, color: COLORS.green, flex: 1 },
  trustChevron: { fontFamily: FONTS.body, fontSize: 10, color: COLORS.muted2 },
  trustCard: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.xl,
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.3)',
    padding: SPACING.lg, marginBottom: 20,
  },
  trustHeader: { flexDirection: 'row', alignItems: 'center', gap: 8, marginBottom: 6 },
  trustTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.green, flex: 1 },
  trustSubtitle: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2, lineHeight: 19, marginBottom: 14 },
  trustDivider: { height: 1, backgroundColor: COLORS.border, marginBottom: 12 },
  trustBenefits: { gap: 10, marginBottom: 14 },
  trustBenefitRow: { flexDirection: 'row', alignItems: 'center', gap: 9 },
  trustBenefitText: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.text },
  trustBadgeRow: { flexDirection: 'row', gap: 8 },
  trustBadge: {
    paddingHorizontal: 12, paddingVertical: 5,
    borderRadius: RADIUS.full,
    backgroundColor: COLORS.greenMuted,
    borderWidth: 1, borderColor: COLORS.green,
  },
  trustBadgeText: { fontFamily: FONTS.bodySemiBold, fontSize: 11, color: COLORS.green },
  safetyNotice: {
    flexDirection: 'row', alignItems: 'center', gap: 7,
    marginTop: 12, paddingTop: 12,
    borderTopWidth: 1, borderTopColor: COLORS.border,
  },
  safetyNoticeText: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted, flex: 1, lineHeight: 17 },

  // Rendimiento chips en hero
  quickResponseChip: {
    flexDirection: 'row', alignItems: 'center', gap: 4,
    backgroundColor: 'rgba(245,158,11,0.18)', borderRadius: RADIUS.full,
    borderWidth: 1, borderColor: 'rgba(245,158,11,0.5)',
    paddingHorizontal: 9, paddingVertical: 4,
  },
  quickResponseChipText: { fontFamily: FONTS.bodyMedium, fontSize: 11, color: '#F59E0B' },
  trustedChip: {
    flexDirection: 'row', alignItems: 'center', gap: 4,
    backgroundColor: COLORS.greenMuted, borderRadius: RADIUS.full,
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.5)',
    paddingHorizontal: 9, paddingVertical: 4,
  },
  trustedChipText: { fontFamily: FONTS.bodyMedium, fontSize: 11, color: COLORS.green },
});
