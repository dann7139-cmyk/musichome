import VideoPlayer from '../../components/ui/VideoPlayer';
import { LinearGradient } from 'expo-linear-gradient';
import * as WebBrowser from 'expo-web-browser';
import React, { useEffect, useRef, useState } from 'react';
import {
  ActivityIndicator,
  Animated,
  Image,
  Pressable,
  RefreshControl,
  ScrollView,
  Share,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { ArrowLeft, CheckCircle, MapPin, Music2, Share2, Shield, Star, FileText, Navigation, Award, TrendingUp, ShieldCheck, ThumbsUp, Zap, Headphones } from 'lucide-react-native';
import * as Location from 'expo-location';
import { supabase } from '../../config/supabase';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';
import Particles from '../../components/ui/Particles';
import LevelBadge from '../../components/ui/LevelBadge';
import VerifiedBadge from '../../components/ui/VerifiedBadge';
import { useAuth } from '../../context/AuthContext';

// Distancia Haversine en km entre dos puntos GPS
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
  const { role } = useAuth();
  const isExplorer = role === 'group' || role === 'talent';

  const params        = route.params ?? {};
  // Soporta { group } (normal) y { groupId } (deep link daricefy://group/{id})
  const initialGroup  = params.group ?? (params.groupId ? { id: params.groupId } : null);

  const [group,            setGroup]            = useState<any>(initialGroup);
  const [loading,          setLoading]          = useState(!initialGroup || !initialGroup.description);
  const [refreshing,       setRefreshing]       = useState(false);
  const [reviews,          setReviews]          = useState<Review[]>([]);
  // null = sin datos | true = cerca | false = lejos
  const [isNearby,         setIsNearby]         = useState<boolean | null>(null);
  const [activitySnapshot,    setActivitySnapshot]    = useState<any>(null);
  const [groupCompletedCount, setGroupCompletedCount] = useState<number | null>(null);
  const [similarGroups,    setSimilarGroups]    = useState<any[]>([]);
  const [profileAds,       setProfileAds]       = useState<any[]>([]);
  const [profileAdIdx,     setProfileAdIdx]     = useState(0);
  const [profileAdImgErr,  setProfileAdImgErr]  = useState(false);
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

  // ─── Compartir link del grupo ────────────────────────────────────────────
  const handleShare = async () => {
    const link = `daricefy://group/${group?.id ?? initialGroup?.id}`;
    try {
      await Share.share({
        message: `Mira a ${group?.name ?? 'este grupo'} en Daricefy 🎵\n${link}`,
        title: group?.name,
      });
    } catch (_) { /* usuario canceló */ }
  };

  useEffect(() => {
    if (!initialGroup) return;
    // Si el objeto recibido es incompleto (viene del mapa o deep link), cargar datos completos
    if (!initialGroup.description && !initialGroup.promo_video) {
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

    // Registrar vista (fire-and-forget)
    supabase.rpc('track_group_view', { p_group_id: initialGroup.id });

    // Señales de actividad + urgencia
    supabase.rpc('get_group_activity_snapshot', { p_group_id: initialGroup.id })
      .maybeSingle()
      .then(({ data }) => { if (data) setActivitySnapshot(data); });

    // Grupos similares
    supabase.rpc('get_similar_groups', { p_group_id: initialGroup.id })
      .then(({ data }) => { if (data) setSimilarGroups((data as any[]).slice(0, 8)); });

    // Eventos completados reales del grupo (reservations.status = 'completed')
    supabase
      .from('reservations')
      .select('id', { count: 'exact', head: true })
      .eq('group_id', initialGroup.id)
      .eq('status', 'completed')
      .then(({ count }) => { setGroupCompletedCount(count ?? 0); });

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
    const { data } = await supabase.rpc('get_group_reviews', {
      p_group_id: initialGroup.id,
      p_limit: 5,
    });
    if (data) setReviews(data);
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
            style={StyleSheet.absoluteFillObject}
          />

          {/* Botones flotantes: back (izq) + compartir (der) */}
          <SafeAreaView style={styles.heroSafeTop} edges={['top']}>
            <View style={styles.heroTopRow}>
              <Pressable style={styles.heroBackBtn} onPress={() => navigation.goBack()}>
                <ArrowLeft size={20} color="#fff" />
              </Pressable>
              <Pressable style={styles.heroShareBtn} onPress={handleShare}>
                <Share2 size={18} color="#fff" />
              </Pressable>
            </View>
          </SafeAreaView>


          {/* Info superpuesta sobre el gradiente */}
          <View style={styles.heroContent}>
            {group.nivel && <LevelBadge nivel={group.nivel} size="sm" />}

            {/* Nombre + verificado en la misma fila */}
            <View style={styles.heroNameRow}>
              <Text style={styles.heroName} numberOfLines={2}>{group.name}</Text>
              {group.is_verified && (
                <VerifiedBadge size={22} tier={(group as any).is_plus_active ? 'plus' : 'free'} />
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

            {/* Stats: rating + cercanía */}
            <View style={styles.heroStatsRow}>
              {(group.average_rating > 0 || group.rating != null) && (
                <View style={styles.heroStatPill}>
                  <Star size={13} color={COLORS.gold} fill={COLORS.gold} />
                  <Text style={styles.heroStatPillText}>
                    {(group.average_rating || group.rating)?.toFixed(1)}
                    {group.total_reviews > 0 ? ` (${group.total_reviews})` : ''}
                  </Text>
                </View>
              )}
              {isNearby === true && (
                <View style={styles.nearbyChip}>
                  <Navigation size={10} color={COLORS.green} />
                  <Text style={styles.nearbyChipText}>Tu zona</Text>
                </View>
              )}
              {isNearby === false && (
                <View style={styles.farChip}>
                  <Navigation size={10} color={COLORS.orange} />
                  <Text style={styles.farChipText}>Fuera de tu zona</Text>
                </View>
              )}
            </View>

            {/* Chips de confianza: tiempo en plataforma + eventos completados */}
            {(() => {
              const months = group.created_at
                ? Math.floor((Date.now() - new Date(group.created_at).getTime()) / (1000 * 60 * 60 * 24 * 30))
                : 0;
              const hasTime   = months > 0;
              const hasEvents = groupCompletedCount !== null && groupCompletedCount > 0;
              if (!hasTime && !hasEvents) return null;
              return (
                <View style={styles.heroTrustRow}>
                  {hasTime && (
                    <View style={styles.trustChip}>
                      <Text style={styles.trustChipText}>
                        {months >= 12
                          ? `${Math.floor(months / 12)} año${Math.floor(months / 12) !== 1 ? 's' : ''} en plataforma`
                          : `${months} mes${months !== 1 ? 'es' : ''} en plataforma`}
                      </Text>
                    </View>
                  )}
                  {hasEvents && (
                    <View style={styles.trustChip}>
                      <Text style={styles.trustChipText}>
                        {groupCompletedCount} evento{groupCompletedCount !== 1 ? 's' : ''} realizado{groupCompletedCount !== 1 ? 's' : ''}
                      </Text>
                    </View>
                  )}
                </View>
              );
            })()}

            {/* Badges de rendimiento */}
            <View style={styles.heroBadges}>
              {!group.is_verified && (
                <View style={styles.unverifiedChip}>
                  <Shield size={12} color="rgba(255,255,255,0.45)" />
                  <Text style={styles.unverifiedChipText}>Sin verificar</Text>
                </View>
              )}
              {group.badges?.includes('quick_response') && (
                <View style={styles.quickResponseChip}>
                  <Zap size={11} color="#F59E0B" />
                  <Text style={styles.quickResponseChipText}>Responde rápido</Text>
                </View>
              )}
              {group.badges?.includes('trusted_group') && (
                <View style={styles.trustedChip}>
                  <ShieldCheck size={11} color={COLORS.green} />
                  <Text style={styles.trustedChipText}>Grupo confiable</Text>
                </View>
              )}
            </View>
          </View>
        </View>

        {/* ── CONTENIDO ── */}
        <View style={styles.body}>

          {/* Descripción */}
          {group.description && (
            <View style={styles.descCard}>
              <Text style={styles.descLabel}>Sobre el grupo</Text>
              <Text style={styles.descText}>{group.description}</Text>
            </View>
          )}

          {/* Video */}
          {group.promo_video && group.video_status === 'approved' && (
            <View style={styles.videoSection}>
              <Text style={styles.sectionTitle}>Video promocional</Text>
              <View style={styles.videoWrapper}>
                <VideoPlayer
                  uri={group.promo_video}
                  style={styles.video}
                  contentFit="contain"
                  nativeControls
                />
              </View>
            </View>
          )}

          {/* Cargando datos completos del grupo */}
          {loading && (
            <View style={styles.loadingBox}>
              <ActivityIndicator size="large" color={COLORS.green} />
            </View>
          )}

          {/* ── GARANTÍA DARICEFY ── */}
          <View style={styles.trustCard}>
            <View style={styles.trustHeader}>
              <ShieldCheck size={17} color={COLORS.green} />
              <Text style={styles.trustTitle}>Reserva protegida por Daricefy</Text>
            </View>
            <Text style={styles.trustSubtitle}>
              Si el grupo no llega, te ayudamos o te devolvemos el dinero
            </Text>
            <View style={styles.trustDivider} />
            <View style={styles.trustBenefits}>
              <View style={styles.trustBenefitRow}>
                <CheckCircle size={13} color={COLORS.green} />
                <Text style={styles.trustBenefitText}>Grupos verificados por el equipo</Text>
              </View>
              <View style={styles.trustBenefitRow}>
                <Headphones size={13} color={COLORS.green} />
                <Text style={styles.trustBenefitText}>Soporte durante el evento</Text>
              </View>
              <View style={styles.trustBenefitRow}>
                <Star size={13} color={COLORS.green} fill={COLORS.green} />
                <Text style={styles.trustBenefitText}>Historial y calificaciones reales</Text>
              </View>
            </View>
            <View style={styles.safetyNotice}>
              <Shield size={12} color={COLORS.muted2} />
              <Text style={styles.safetyNoticeText}>
                Para tu seguridad, mantén toda la contratación dentro de la app
              </Text>
            </View>
            <View style={styles.trustBadgeRow}>
              <View style={styles.trustBadge}>
                <Text style={styles.trustBadgeText}>Seguro</Text>
              </View>
              <View style={styles.trustBadge}>
                <Text style={styles.trustBadgeText}>Verificado</Text>
              </View>
              <View style={styles.trustBadge}>
                <Text style={styles.trustBadgeText}>Protegido</Text>
              </View>
            </View>
          </View>

          {/* ── INSIGNIAS ── */}
          {group.badges && group.badges.length > 0 && (
            <View style={styles.badgesRow}>
              {group.badges.includes('top_artist') && (
                <View style={styles.badgeChip}>
                  <Award size={13} color={COLORS.gold} />
                  <Text style={styles.badgeChipText}>Top artista</Text>
                </View>
              )}
              {group.badges.includes('high_demand') && (
                <View style={[styles.badgeChip, styles.badgeChipGreen]}>
                  <TrendingUp size={13} color={COLORS.green} />
                  <Text style={[styles.badgeChipText, { color: COLORS.green }]}>Alta demanda</Text>
                </View>
              )}
              {group.badges.includes('trusted_group') && (
                <View style={[styles.badgeChip, styles.badgeChipBlue]}>
                  <ShieldCheck size={13} color="#90CAF9" />
                  <Text style={[styles.badgeChipText, { color: '#90CAF9' }]}>Grupo confiable</Text>
                </View>
              )}
              {group.badges.includes('high_acceptance') && (
                <View style={[styles.badgeChip, styles.badgeChipBlue]}>
                  <ThumbsUp size={13} color="#90CAF9" />
                  <Text style={[styles.badgeChipText, { color: '#90CAF9' }]}>Alta aceptación</Text>
                </View>
              )}
              {group.badges.includes('quick_response') && (
                <View style={[styles.badgeChip, styles.badgeChipBlue]}>
                  <Zap size={13} color="#90CAF9" />
                  <Text style={[styles.badgeChipText, { color: '#90CAF9' }]}>Respuesta rápida</Text>
                </View>
              )}
              {group.badges.includes('top_ciudad') && (
                <View style={[styles.badgeChip, styles.badgeChipGold]}>
                  <Award size={13} color="#FFB300" />
                  <Text style={[styles.badgeChipText, { color: '#FFB300' }]}>Top en tu ciudad</Text>
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

          {/* ── RESEÑAS ── */}
          {reviews.length > 0 && (
            <View style={styles.reviewsSection}>
              <View style={styles.reviewsHeader}>
                <Star size={15} color={COLORS.gold} fill={COLORS.gold} />
                <Text style={styles.reviewsTitle}>
                  {group.average_rating?.toFixed(1)} · {group.total_reviews} reseña{group.total_reviews !== 1 ? 's' : ''}
                </Text>
              </View>
              {reviews.map(rv => (
                <View key={rv.review_id} style={styles.reviewCard}>
                  <View style={styles.reviewTop}>
                    <StarRow rating={rv.rating} size={13} />
                    <Text style={styles.reviewDate}>
                      {new Date(rv.created_at).toLocaleDateString('es-MX', { month: 'short', year: 'numeric' })}
                    </Text>
                  </View>
                  <Text style={styles.reviewClient}>{rv.client_name}</Text>
                  {rv.comment ? <Text style={styles.reviewComment}>{rv.comment}</Text> : null}
                </View>
              ))}
            </View>
          )}

          {/* ── GRUPOS SIMILARES ── */}
          {similarGroups.length > 0 && (
            <View style={styles.similarSection}>
              <Text style={styles.sectionTitle}>También te puede gustar</Text>
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

          {/* ── COTIZACIÓN POR DISTANCIA ── */}
          <View style={styles.quoteSection}>
            <View style={styles.quoteHeader}>
              <FileText size={16} color={COLORS.orange} />
              <Text style={styles.quoteTitle}>
                {isExplorer ? 'Información y disponibilidad' : '¿Necesitas precio personalizado?'}
              </Text>
            </View>
            <Text style={styles.quoteDesc}>
              {isExplorer
                ? 'Puedes solicitar información o contratar directamente desde aquí.'
                : 'Solicita una cotización. El grupo calculará el precio incluyendo traslado y detalles especiales.'}
            </Text>
            <Pressable
              style={styles.quoteBtn}
              onPress={() => navigation.navigate('QuoteForm', { group })}
            >
              <FileText size={15} color={COLORS.bg} />
              <Text style={styles.quoteBtnText}>
                {isExplorer ? 'Solicitar información' : 'Solicitar cotización personalizada'}
              </Text>
            </Pressable>
          </View>

          {/* ── ANUNCIO EN PERFIL — rota si hay varios ── */}
          {profileAds.length > 0 && (() => {
            const ad = profileAds[profileAdIdx % profileAds.length];
            return (
              <Animated.View style={{ opacity: profileAdFade }}>
                <View style={[styles.profileAdCard, ad.is_free && { opacity: 0.70 }]}>
                  <View style={styles.profileAdTag}>
                    <Text style={styles.profileAdTagText}>PUBLICIDAD</Text>
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
                    <VideoPlayer
                      uri={ad.media_url}
                      style={styles.profileAdImage}
                      contentFit="cover"
                      autoPlay muted loop
                    />
                  )}
                  <View style={styles.profileAdBody}>
                    <Text style={styles.profileAdTitle} numberOfLines={1}>{ad.title}</Text>
                    {ad.subtitle && <Text style={styles.profileAdSub} numberOfLines={2}>{ad.subtitle}</Text>}
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
                        }
                      }}
                    >
                      <Text style={styles.profileAdBtnText}>{ad.button_text ?? 'Ver más'} →</Text>
                    </Pressable>
                  </View>
                </View>
              </Animated.View>
            );
          })()}

          <View style={{ height: 48 }} />
        </View>
      </ScrollView>
    </View>
  );
}

const styles = StyleSheet.create({
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
    marginBottom: 8, marginTop: 6, flexShrink: 1,
  },
  heroVerifiedBadge: {
    width: 24, height: 24, borderRadius: 12,
    backgroundColor: 'rgba(66,133,244,0.25)',
    borderWidth: 1, borderColor: 'rgba(66,133,244,0.5)',
    alignItems: 'center', justifyContent: 'center',
    flexShrink: 0,
  },
  heroName: {
    fontFamily: FONTS.title, fontSize: 22, color: '#fff',
    lineHeight: 28, letterSpacing: 0.2, flexShrink: 1,
  },
  heroSubRow: { flexDirection: 'row', alignItems: 'center', gap: 14, marginBottom: 12, flexWrap: 'wrap' },
  heroGenreTag: { flexDirection: 'row', alignItems: 'center', gap: 6 },
  heroGenreText: { fontFamily: FONTS.bodyMedium, fontSize: 14, color: COLORS.green },
  heroMeta: { flexDirection: 'row', alignItems: 'center', gap: 5 },
  heroMetaText: { fontFamily: FONTS.body, fontSize: 13, color: 'rgba(255,255,255,0.6)' },

  heroStatsRow: { flexDirection: 'row', gap: 8, marginBottom: 12, flexWrap: 'wrap' },
  heroStatPill: {
    flexDirection: 'row', alignItems: 'center', gap: 5,
    backgroundColor: 'rgba(0,0,0,0.45)', borderRadius: RADIUS.full,
    borderWidth: 1, borderColor: 'rgba(255,179,0,0.4)',
    paddingHorizontal: 10, paddingVertical: 5,
  },
  heroStatPillText: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.gold },
  heroPricePill: {
    backgroundColor: COLORS.greenMuted, borderRadius: RADIUS.full,
    borderWidth: 1, borderColor: COLORS.green,
    paddingHorizontal: 10, paddingVertical: 5,
  },
  heroPricePillText: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.green },

  heroTrustRow: { flexDirection: 'row', gap: 6, flexWrap: 'wrap', marginBottom: 6 },
  trustChip: {
    backgroundColor: 'rgba(0,0,0,0.45)', borderRadius: RADIUS.full,
    paddingHorizontal: 9, paddingVertical: 4,
    borderWidth: 1, borderColor: 'rgba(255,255,255,0.15)',
  },
  trustChipText: { fontFamily: FONTS.bodyMedium, fontSize: 11, color: 'rgba(255,255,255,0.85)' },
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
  body: { paddingHorizontal: SPACING.xl, paddingTop: 20 },

  // Description
  descCard: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.xl,
    borderWidth: 1, borderColor: COLORS.border,
    padding: SPACING.lg, marginBottom: 20,
  },
  descLabel: {
    fontFamily: FONTS.bodySemiBold, fontSize: 11, color: COLORS.muted2,
    textTransform: 'uppercase', letterSpacing: 1, marginBottom: 10,
  },
  descText: { fontFamily: FONTS.body, fontSize: 14, color: COLORS.text, lineHeight: 22 },

  // Video
  videoSection: { marginBottom: 20 },
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
  reviewCard: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border,
    padding: SPACING.md, marginBottom: 10,
  },
  reviewTop: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center', marginBottom: 4 },
  reviewDate: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted2 },
  reviewClient: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.muted2, marginBottom: 4 },
  reviewComment: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.text, lineHeight: 20 },

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
    borderWidth: 1, borderColor: 'rgba(255,255,255,0.07)',
    overflow: 'hidden', marginBottom: 24,
    opacity: 0.92,   // pagados: 0.92 — gratis: 0.70 (override inline)
  },
  profileAdTag: {
    flexDirection: 'row', alignItems: 'center', gap: 6,
    backgroundColor: 'rgba(255,255,255,0.04)',
    paddingHorizontal: 12, paddingVertical: 5,
    borderBottomWidth: 1, borderBottomColor: 'rgba(255,255,255,0.06)',
  },
  profileAdTagText: { fontFamily: FONTS.bodyMedium, fontSize: 9, color: COLORS.muted, letterSpacing: 1.4 },
  profileAdImage: { width: '100%', height: 90 },
  profileAdBody: { padding: 12 },
  profileAdTitle: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted2, marginBottom: 3 },
  profileAdSub: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted, marginBottom: 10 },
  profileAdBtn: {
    alignSelf: 'flex-start',
    backgroundColor: 'transparent',
    borderRadius: RADIUS.full,
    borderWidth: 1, borderColor: 'rgba(255,255,255,0.15)',
    paddingHorizontal: 14, paddingVertical: 6,
  },
  profileAdBtnText: { fontFamily: FONTS.bodyMedium, fontSize: 11, color: COLORS.muted2 },

  // ── Trust / Garantía ──
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
