import { LinearGradient } from 'expo-linear-gradient';
import * as Location from 'expo-location';
import * as WebBrowser from 'expo-web-browser';
import VideoPlayer from '../../components/ui/VideoPlayer';
import { Bell, CheckCircle, ChevronRight, MapPin, Navigation, Search, Star, TrendingUp, X, Zap } from 'lucide-react-native';
import React, { useEffect, useMemo, useRef, useState } from 'react';
import {
  ActivityIndicator,
  Animated,
  Dimensions,
  FlatList,
  Image,
  Pressable,
  RefreshControl,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  View,
} from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { supabase } from '../../config/supabase';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';
import Particles from '../../components/ui/Particles';
import LevelBadge from '../../components/ui/LevelBadge';
import { useAuth } from '../../context/AuthContext';
import { getSafeCity } from '../../utils/cityUtils';

interface Promotion {
  id: string;
  title: string;
  subtitle: string | null;
  tag: string;
  button_text: string;
  link_type: 'none' | 'group' | 'talent';
  link_id: string | null;
  media_url: string | null;
  media_type: 'none' | 'image' | 'video';
  media_offset: number | null;
}

const { width } = Dimensions.get('window');
const CARD_W = width - SPACING.xl * 2;
const FEAT_W = width * 0.23;   // tarjetas compactas — caben 3-4 en pantalla

// ── Grupos demo para mostrar el carrusel cuando no hay datos reales ─────────
const MOCK_GROUPS: any[] = [
  { id: '__m1',  name: 'Orquesta Sabor',     city: 'Bogotá',      rating: 4.9, profile_image: null, is_verified: true, _is_mock: true },
  { id: '__m2',  name: 'DJ Vibra Pro',        city: 'Medellín',    rating: 4.8, profile_image: null, is_verified: true, _is_mock: true },
  { id: '__m3',  name: 'Mariachi El Sol',     city: 'Cali',        rating: 4.7, profile_image: null, is_verified: true, _is_mock: true },
  { id: '__m4',  name: 'Banda Caribe Live',   city: 'Cartagena',   rating: 4.9, profile_image: null, is_verified: true, _is_mock: true },
  { id: '__m5',  name: 'Los Soneros',         city: 'Barranquilla', rating: 4.6, profile_image: null, is_verified: true, _is_mock: true },
  { id: '__m6',  name: 'Quartet Jazz',        city: 'Bogotá',      rating: 4.8, profile_image: null, is_verified: true, _is_mock: true },
  { id: '__m7',  name: 'Cumbia Kings',        city: 'Medellín',    rating: 4.7, profile_image: null, is_verified: true, _is_mock: true },
  { id: '__m8',  name: 'Pop Stars Band',      city: 'Cali',        rating: 4.9, profile_image: null, is_verified: true, _is_mock: true },
  { id: '__m9',  name: 'Rock en Vivo',        city: 'Bogotá',      rating: 4.8, profile_image: null, is_verified: true, _is_mock: true },
  { id: '__m10', name: 'Vallenato Real',      city: 'Valledupar',  rating: 4.9, profile_image: null, is_verified: true, _is_mock: true },
  { id: '__m11', name: 'Reggaeton Fire',      city: 'Pereira',     rating: 4.6, profile_image: null, is_verified: true, _is_mock: true },
  { id: '__m12', name: 'Grupo Clásico',       city: 'Manizales',   rating: 4.7, profile_image: null, is_verified: true, _is_mock: true },
  { id: '__m13', name: 'Electro Sound',       city: 'Bucaramanga', rating: 4.8, profile_image: null, is_verified: true, _is_mock: true },
  { id: '__m14', name: 'Marimba Pacífico',    city: 'Quibdó',      rating: 4.9, profile_image: null, is_verified: true, _is_mock: true },
  { id: '__m15', name: 'Los Románticos',      city: 'Santa Marta', rating: 4.7, profile_image: null, is_verified: true, _is_mock: true },
  { id: '__m16', name: 'Salsa Brava',         city: 'Cali',        rating: 4.8, profile_image: null, is_verified: true, _is_mock: true },
  { id: '__m17', name: 'Banda Show Total',    city: 'Bogotá',      rating: 4.7, profile_image: null, is_verified: true, _is_mock: true },
  { id: '__m18', name: 'Piano & Voz',         city: 'Medellín',    rating: 4.9, profile_image: null, is_verified: true, _is_mock: true },
  { id: '__m19', name: 'Tambores del Caribe', city: 'Cartagena',   rating: 4.8, profile_image: null, is_verified: true, _is_mock: true },
  { id: '__m20', name: 'DJ Fusión',           city: 'Bogotá',      rating: 4.6, profile_image: null, is_verified: true, _is_mock: true },
];


const CATEGORY_ICONS: Record<string, string> = {
  music:         '🎵',
  entertainment: '🎪',
  service:       '🎛️',
  rental:        '🏕️',
  audio:         '💡',
  decoration:    '🎨',
  multimedia:    '📸',
};

export default function HomeScreen({ navigation }: any) {
  const { detectedCity, safeState } = useAuth();
  const [groups, setGroups] = useState<any[]>([]);
  const [filtered, setFiltered] = useState<any[]>([]);
  const [categories, setCategories] = useState<{ id: string; name: string; type: string }[]>([]);
  const [subcatNames, setSubcatNames] = useState<Record<string, string[]>>({});
  const [selectedCategoryId, setSelectedCategoryId] = useState<string | null>(null);
  const [search, setSearch] = useState('');
  const [profile, setProfile] = useState<any>(null);
  const [groupHasActiveAds, setGroupHasActiveAds] = useState(false);
  const [nearbyCity, setNearbyCity] = useState<string | null>(null);
  const [locationLoading, setLocationLoading] = useState(false);
  const [unreadCount, setUnreadCount] = useState(0);
  const [liveEvent, setLiveEvent] = useState<any>(null);
  const [pendingPayment, setPendingPayment] = useState<any>(null);
  const [paymentFailed, setPaymentFailed] = useState<any>(null);
  const [pendingQuotes, setPendingQuotes] = useState<any[]>([]);
  const [pendingExpressProposals, setPendingExpressProposals] = useState<any[]>([]);
  const [myOpenRequests, setMyOpenRequests] = useState<any[]>([]);
  const [promotions, setPromotions] = useState<Promotion[]>([]);
  const [bannerAds, setBannerAds] = useState<any[]>([]);
  const [currentAdIndex, setCurrentAdIndex] = useState(0);
  const [bannerImgError, setBannerImgError] = useState(false);
  const [sponsoredGroupIds, setSponsoredGroupIds] = useState<Set<string>>(new Set());
  const [loyalty,    setLoyalty]    = useState<any>(null);
  const [cityDemand, setCityDemand] = useState<any>(null);
  const [topRecs,          setTopRecs]          = useState<any[]>([]);
  const [refreshing, setRefreshing] = useState(false);
  const headerOpacity = useRef(new Animated.Value(0)).current;
  const adFade = useRef(new Animated.Value(1)).current;

  useEffect(() => {
    fetchData();
    fetchCategories();
    fetchPromotions();
    Animated.timing(headerOpacity, { toValue: 1, duration: 500, useNativeDriver: true }).start();
  }, []);

  useEffect(() => {
    const unsubscribe = navigation.addListener('focus', () => {
      fetchUnreadCount();
      fetchData();
    });
    return unsubscribe;
  }, [navigation]);

  // Registrar impresión cada vez que cambia el anuncio visible (fire-and-forget)
  useEffect(() => {
    if (bannerAds.length === 0) return;
    const ad = bannerAds[currentAdIndex];
    if (ad?.id) supabase.rpc('track_ad_impression', { p_ad_id: ad.id }).then(() => {});
  }, [currentAdIndex, bannerAds.length]);

  // Carousel automático de anuncios (cada 5 segundos)
  useEffect(() => {
    const total = bannerAds.length > 0 ? bannerAds.length : promotions.length;
    if (total <= 1) return;
    const timer = setInterval(() => {
      Animated.timing(adFade, { toValue: 0, duration: 280, useNativeDriver: true }).start(() => {
        setCurrentAdIndex(prev => (prev + 1) % total);
        setBannerImgError(false);
        Animated.timing(adFade, { toValue: 1, duration: 280, useNativeDriver: true }).start();
      });
    }, 5000);
    return () => clearInterval(timer);
  }, [bannerAds.length, promotions.length]);


  // Realtime: cuando el evento pasa a completed, quitar el banner del home
  useEffect(() => {
    const sub = supabase
      .channel('home-live-event')
      .on('postgres_changes', {
        event: 'UPDATE',
        schema: 'public',
        table: 'reservations',
      }, (payload: any) => {
        const upd = payload.new;
        if (upd.status === 'completed' || upd.status === 'cancelled') {
          setLiveEvent((prev: any) => prev?.id === upd.id ? null : prev);
          // Si el cobro final falló, mostrar banner urgente sin refetch completo
          if (upd.status === 'completed' && upd.payment_status === 'remaining_pending') {
            fetchData();
          }
        } else if (upd.status === 'in_progress') {
          if (!liveEvent) fetchData();
        }
      })
      .subscribe();
    return () => { supabase.removeChannel(sub); };
  }, [liveEvent]);

  useEffect(() => {
    let result = groups;
    if (selectedCategoryId) {
      const names = subcatNames[selectedCategoryId] ?? [];
      result = result.filter(g => names.includes(g.genre));
    }
    if (search) result = result.filter(g =>
      g.name?.toLowerCase().includes(search.toLowerCase()) ||
      g.city?.toLowerCase().includes(search.toLowerCase())
    );
    if (nearbyCity) result = result.filter(g => {
      const cityMatch = g.city?.toLowerCase().includes(nearbyCity.toLowerCase());
      const serviceMatch = Array.isArray(g.service_cities)
        ? g.service_cities.some((sc: string) => sc.toLowerCase().includes(nearbyCity.toLowerCase()))
        : false;
      return cityMatch || serviceMatch;
    });
    setFiltered(result);
  }, [groups, selectedCategoryId, subcatNames, search, nearbyCity]);

  const onRefresh = async () => {
    setRefreshing(true);
    await Promise.all([fetchData(), fetchPromotions()]);
    setRefreshing(false);
  };

  const fetchData = async () => {
    let userCity: string | null = null;
    // Estado del usuario: viene del contexto (persiste entre sesiones)
    const detectedState = safeState;
    const { data: sessionData } = await supabase.auth.getSession();
    if (sessionData.session) {
      const { data: prof } = await supabase
        .from('profiles')
        .select('*')
        .eq('id', sessionData.session.user.id)
        .single();
      setProfile(prof);
      userCity = getSafeCity((prof as any)?.city, detectedCity);
      console.log('[HomeScreen] city usada:', userCity);
      fetchUnreadCount();

      // Loyalty
      const { data: loyData } = await supabase.rpc('get_client_loyalty').maybeSingle();
      if (loyData && ((loyData as any).loyalty_events_count ?? 0) > 0) setLoyalty(loyData);
      else setLoyalty(null);

      // Demanda de la ciudad del cliente
      if (userCity) {
        const { data: demandData } = await supabase.rpc('get_city_demand_score', { p_city: userCity });
        if ((demandData as any)?.ok) setCityDemand(demandData);
      }

      // Si es grupo, verificar si tiene anuncios activos (RPC ligera — solo boolean)
      if ((prof as any)?.role === 'group') {
        const { data: hasAds } = await supabase.rpc('has_active_ads');
        setGroupHasActiveAds(hasAds === true);
      }

      const { data: live } = await supabase
        .from('reservations')
        .select('*, group:groups(id, name, genre, city, profile_image, owner_id), package:packages(name, duration_hours)')
        .eq('client_id', sessionData.session.user.id)
        .eq('status', 'in_progress')
        .limit(1)
        .maybeSingle();
      setLiveEvent(live);

      // Reserva confirmada pero sin anticipo pagado
      const { data: pendPay } = await supabase
        .from('reservations')
        .select('*, group:groups(name)')
        .eq('client_id', sessionData.session.user.id)
        .eq('status', 'confirmed')
        .not('payment_status', 'in', '("deposit_paid","fully_paid")')
        .order('event_date', { ascending: true })
        .limit(1)
        .maybeSingle();
      setPendingPayment(pendPay);

      // Evento completado pero el cobro del 50% final falló (tarjeta declinada / sin método)
      const { data: failedPay } = await supabase
        .from('reservations')
        .select('*, group:groups(name)')
        .eq('client_id', sessionData.session.user.id)
        .eq('status', 'completed')
        .eq('payment_status', 'remaining_pending')
        .order('event_date', { ascending: false })
        .limit(1)
        .maybeSingle();
      setPaymentFailed(failedPay);

      // Todas las cotizaciones pendientes o con respuesta del grupo
      const { data: quotesData } = await supabase
        .from('quotes')
        .select('*, group:groups(name)')
        .eq('client_id', sessionData.session.user.id)
        .in('status', ['pending', 'quoted'])
        .order('updated_at', { ascending: false });
      setPendingQuotes(quotesData ?? []);

      // Todas las propuestas express recibidas (en negociación)
      const { data: exprData } = await supabase
        .from('event_requests')
        .select('*, _group:groups!inner(id, name, profile_image, owner_id)')
        .eq('client_id', sessionData.session.user.id)
        .eq('status', 'en_negociacion')
        .order('created_at', { ascending: false });
      const normalizedProposals = (exprData ?? []).map((r: any) => {
        const grpRaw = r._group;
        return { ...r, _group: Array.isArray(grpRaw) ? grpRaw[0] : grpRaw };
      });
      setPendingExpressProposals(normalizedProposals);

      // Solicitudes express/programadas enviadas y aún abiertas
      const { data: myReqData } = await supabase
        .from('event_requests')
        .select('id, request_type, event_type, genre, created_at, expires_at')
        .eq('client_id', sessionData.session.user.id)
        .eq('status', 'open')
        .gt('expires_at', new Date().toISOString())
        .order('created_at', { ascending: false });
      setMyOpenRequests(myReqData ?? []);
    }
    // Anuncios banner pagados (filtrar por ciudad y estado del usuario)
    // p_state solo se pasa si está disponible (requiere SQL 175 en DB)
    const bannerParams: Record<string, any> = { p_city: userCity };
    if (detectedState) bannerParams.p_state = detectedState;
    const { data: adsData, error: adsErr } = await supabase.rpc('get_active_banner_ads', bannerParams);
    console.log('BANNER ADS:', JSON.stringify(adsData)?.slice(0, 300), 'error:', adsErr?.message);
    if (adsData && (adsData as any[]).length > 0) {
      const paid = (adsData as any[]).filter((a: any) => !a.is_free);
      const free = (adsData as any[]).filter((a: any) => a.is_free);
      // Paid always first; all free ads follow (admin creates them deliberately)
      setBannerAds([...paid, ...free]);
      setCurrentAdIndex(0);
    }

    // Grupos patrocinados
    const { data: sponData } = await supabase.rpc('get_sponsored_group_ids', {
      p_city: userCity,
    });
    const sponSet = new Set<string>((sponData ?? []).map((s: any) => s.group_id));
    setSponsoredGroupIds(sponSet);

    // Grupos rankeados por ciudad. Si la ciudad no devuelve resultados,
    // se hace un segundo fetch sin filtro de ciudad (fallback global).
    let rawGroups: any[] = [];
    const groupParams: Record<string, any> = { p_city: userCity, p_limit: 80 };
    if (detectedState) groupParams.p_state = detectedState;
    const { data: cityData } = await supabase.rpc('get_groups_ranked_by_city', groupParams);
    if (cityData && (cityData as any[]).length > 0) {
      rawGroups = cityData as any[];
    } else if (userCity) {
      // Fallback: sin filtro de ciudad (pero mantenemos filtro de estado si aplica)
      const fallbackParams: Record<string, any> = { p_city: null, p_limit: 80 };
      if (detectedState) fallbackParams.p_state = detectedState;
      const { data: allData } = await supabase.rpc('get_groups_ranked_by_city', fallbackParams);
      rawGroups = (allData as any[]) ?? [];
    }
    if (rawGroups.length > 0) {
      const scored = rawGroups.map(g => ({
        ...g,
        is_sponsored: sponSet.has(g.id),
      }));
      setGroups(scored);
      setFiltered(scored);
    }

    // Grupos que pagaron para aparecer como recomendados (hasta 20)
    // get_active_recommendations devuelve: id, name, city, genre, rating,
    // profile_image, is_verified (actualizado en 170_ad_monetization_ordering.sql)
    const recParams: Record<string, any> = { p_city: userCity, p_limit: 20 };
    if (detectedState) recParams.p_state = detectedState;
    const { data: recTop } = await supabase.rpc('get_active_recommendations', recParams);
    const paid = recTop
      ? recTop.map((r: any) => ({
          id:            r.id            ?? r.group_id,
          name:          r.name          ?? r.group_name,
          city:          r.city,
          genre:         r.genre,
          rating:        r.rating,
          profile_image: r.profile_image,
          is_verified:   r.is_verified,
          price_from:    r.price_from    ?? null,
          _is_recommended: true,
        }))
      : [];
    setTopRecs(paid);
  };

  const fetchCategories = async () => {
    const { data } = await supabase
      .from('categories')
      .select('id, name, type, parent_id')
      .eq('active', true);
    if (!data) return;
    const roots = data.filter(c => !c.parent_id);
    const map: Record<string, string[]> = {};
    for (const root of roots) {
      map[root.id] = data.filter(c => c.parent_id === root.id).map(c => c.name);
    }
    setCategories(roots);
    setSubcatNames(map);
  };

  const fetchUnreadCount = async () => {
    const { data: sessionData } = await supabase.auth.getSession();
    if (!sessionData.session) return;
    const { count } = await supabase
      .from('notifications')
      .select('*', { count: 'exact', head: true })
      .eq('user_id', sessionData.session.user.id)
      .eq('is_read', false);
    setUnreadCount(count ?? 0);
  };

  const handleNearby = async () => {
    if (nearbyCity) { setNearbyCity(null); return; }
    setLocationLoading(true);
    try {
      const { status } = await Location.requestForegroundPermissionsAsync();
      if (status !== 'granted') { setLocationLoading(false); return; }
      const loc = await Location.getCurrentPositionAsync({ accuracy: Location.Accuracy.Balanced });
      const [place] = await Location.reverseGeocodeAsync({
        latitude: loc.coords.latitude,
        longitude: loc.coords.longitude,
      });
      setNearbyCity(place?.city ?? place?.subregion ?? null);
    } catch { /* silent */ }
    setLocationLoading(false);
  };

  const fetchPromotions = async () => {
    const now = new Date().toISOString();
    const { data } = await supabase
      .from('promotions')
      .select('id, title, subtitle, tag, button_text, link_type, link_id, media_url, media_type, media_offset')
      .eq('is_active', true)
      .or(`starts_at.is.null,starts_at.lte.${now}`)
      .or(`ends_at.is.null,ends_at.gte.${now}`)
      .order('order_index', { ascending: true });
    if (data) setPromotions(data as Promotion[]);
  };

  const handlePromoBannerPress = (promo: Promotion) => {
    if (promo.link_type === 'group' && promo.link_id) {
      const grp = groups.find(g => g.id === promo.link_id);
      if (grp) { navigation.navigate('GroupDetail', { group: grp }); return; }
    }
    if (promo.link_type === 'talent' && promo.link_id) {
      return;
    }
    // Sin link específico: llevar a paquetes de publicidad
    navigation.navigate('AdvertisingPackages');
  };

  const openAdDestination = (ad: any) => {
    if (ad.link_type === 'group' && ad.link_id) {
      const grp = groups.find((g: any) => g.id === ad.link_id);
      if (grp) { navigation.navigate('GroupDetail', { group: grp }); return; }
      supabase.from('groups').select('*').eq('id', ad.link_id).single()
        .then(({ data }) => { if (data) navigation.navigate('GroupDetail', { group: data }); });
      return;
    }
    if (ad.link_type === 'video' && ad.youtube_url) {
      WebBrowser.openBrowserAsync(ad.youtube_url, {
        dismissButtonStyle: 'close',
        presentationStyle: WebBrowser.WebBrowserPresentationStyle.PAGE_SHEET,
      });
      return;
    }
  };

  // Press del banner completo — registra clic y navega
  const handleAdPress = (ad: any) => {
    if (ad?.id) supabase.rpc('track_ad_click', { p_ad_id: ad.id }).then(() => {});
    openAdDestination(ad);
  };

  // Press del botón CTA — registra clic y navega
  const handleAdCtaPress = (ad: any) => {
    if (ad?.id) supabase.rpc('track_ad_click', { p_ad_id: ad.id }).then(() => {});
    openAdDestination(ad);
  };

  // ── Bid rank map: position of each group among active bids (1 = highest) ──
  const bidRankMap = useMemo(() => {
    const now = Date.now();
    const active = filtered
      .filter(g => (g.bid_amount ?? 0) > 0 && g.bid_ends_at && new Date(g.bid_ends_at).getTime() > now)
      .sort((a, b) => (b.bid_amount ?? 0) - (a.bid_amount ?? 0));
    return new Map<string, number>(active.map((g, i) => [g.id, i + 1]));
  }, [filtered]);

  // ── Anti-saturation: interleave organic groups so max 2 promoted in a row ──
  const interleavedGroups = useMemo(() => {
    const now = Date.now();
    const isBidActive = (g: any) =>
      (g.bid_amount ?? 0) > 0 && g.bid_ends_at && new Date(g.bid_ends_at).getTime() > now;
    const isPromoted = (g: any) => isBidActive(g) || (g.boost_score ?? 0) > 0;

    const promoted: any[] = [];
    const organic: any[] = [];
    for (const g of filtered) {
      if (isPromoted(g)) promoted.push(g);
      else organic.push(g);
    }

    const result: any[] = [];
    let pi = 0, oi = 0;
    let streak = 0;
    while (pi < promoted.length || oi < organic.length) {
      if (pi < promoted.length && streak < 2) {
        result.push(promoted[pi++]);
        streak++;
      } else if (oi < organic.length) {
        result.push(organic[oi++]);
        streak = 0;
      } else {
        result.push(promoted[pi++]);
      }
    }
    return result;
  }, [filtered]);

  return (
    <View style={styles.container}>
      <Particles />
      <SafeAreaView style={{ flex: 1 }}>
        {/* HEADER */}
        <Animated.View style={[styles.header, { opacity: headerOpacity }]}>
          <View>
            <Text style={styles.logoText}>Darice<Text style={styles.logoGreen}>fy</Text></Text>
            <Text style={styles.subGreeting}>Hola 👋</Text>
          </View>
          <Pressable style={styles.iconBtn} onPress={() => navigation.navigate('Notifications')}>
            <Bell size={18} color={COLORS.muted2} />
            {unreadCount > 0 && (
              <View style={styles.notifDot}>
                <Text style={styles.notifDotText}>{unreadCount > 9 ? '9+' : unreadCount}</Text>
              </View>
            )}
          </Pressable>
        </Animated.View>

        {/* LIVE EVENT BANNER */}
        {liveEvent && (
          <Pressable
            style={styles.liveBanner}
            onPress={() => navigation.navigate('EventTimer', { reservation: liveEvent, readOnly: true, userRole: 'client' })}
          >
            <LinearGradient
              colors={['rgba(0,230,118,0.15)', 'rgba(0,200,83,0.05)']}
              style={StyleSheet.absoluteFillObject}
              start={{ x: 0, y: 0 }} end={{ x: 1, y: 1 }}
            />
            <View style={styles.liveDot} />
            <View style={{ flex: 1 }}>
              <Text style={styles.liveBannerTitle}>Evento en curso</Text>
              <Text style={styles.liveBannerGroup}>{liveEvent.group?.name ?? 'Tu grupo'}</Text>
            </View>
            <View style={styles.liveBannerBtn}>
              <Text style={styles.liveBannerBtnText}>Ver en vivo</Text>
              <ChevronRight size={13} color={COLORS.bg} />
            </View>
          </Pressable>
        )}

        {/* PAGO FALLIDO POST-EVENTO — cobro del 50% declinado */}
        {paymentFailed && !liveEvent && (
          <Pressable
            style={styles.failedChargeBanner}
            onPress={() => navigation.navigate('ClientReservations')}
          >
            <LinearGradient
              colors={['rgba(239,83,80,0.20)', 'rgba(239,83,80,0.05)']}
              style={StyleSheet.absoluteFillObject}
              start={{ x: 0, y: 0 }} end={{ x: 1, y: 1 }}
            />
            <Text style={styles.failedChargeIcon}>💳</Text>
            <View style={{ flex: 1 }}>
              <Text style={styles.failedChargeTitle}>Pago pendiente del evento</Text>
              <Text style={styles.failedChargeGroup}>
                {paymentFailed.group?.name ?? 'Tu evento'} · El cobro del saldo final no pudo procesarse
              </Text>
            </View>
            <View style={styles.failedChargeBtn}>
              <Text style={styles.failedChargeBtnText}>Resolver →</Text>
            </View>
          </Pressable>
        )}

        {/* PENDING PAYMENT BANNER */}
        {pendingPayment && !liveEvent && (
          <Pressable
            style={styles.payBanner}
            onPress={() => navigation.navigate('ClientReservations')}
          >
            <LinearGradient
              colors={['rgba(255,152,0,0.18)', 'rgba(255,152,0,0.05)']}
              style={StyleSheet.absoluteFillObject}
              start={{ x: 0, y: 0 }} end={{ x: 1, y: 1 }}
            />
            <Text style={styles.payBannerIcon}>⚡</Text>
            <View style={{ flex: 1 }}>
              <Text style={styles.payBannerTitle}>Anticipo pendiente</Text>
              <Text style={styles.payBannerGroup}>
                {pendingPayment.group?.name ?? 'Tu reserva'} · {pendingPayment.event_date}
              </Text>
            </View>
            <View style={styles.payBannerBtn}>
              <Text style={styles.payBannerBtnText}>Pagar →</Text>
            </View>
          </Pressable>
        )}

        {/* QUOTE BANNER — acumulativo */}
        {pendingQuotes.length > 0 && !liveEvent && (() => {
          const first = pendingQuotes[0];
          const count = pendingQuotes.length;
          const hasResponse = pendingQuotes.some(q => q.status === 'quoted');
          const title = hasResponse ? '¡Cotización recibida!' : 'Cotización en espera';
          const groupText = count === 1
            ? `${first.group?.name ?? 'Grupo'} · ${first.duration_hours}h`
            : `${first.group?.name ?? 'Grupo'} y ${count - 1} más han cotizado`;
          const onPress = count === 1
            ? () => navigation.navigate('ClientQuoteDetail', { quoteId: first.id })
            : () => navigation.navigate('ClientReservations', { initialTab: 'quotes' });
          return (
            <Pressable style={styles.quoteBanner} onPress={onPress}>
              <LinearGradient
                colors={['rgba(66,133,244,0.18)', 'rgba(66,133,244,0.05)']}
                style={StyleSheet.absoluteFillObject}
                start={{ x: 0, y: 0 }} end={{ x: 1, y: 1 }}
              />
              <Text style={styles.quoteBannerIcon}>{hasResponse ? '📋' : '⏳'}</Text>
              <View style={{ flex: 1 }}>
                <Text style={styles.quoteBannerTitle}>{title}</Text>
                <Text style={styles.quoteBannerGroup}>{groupText}</Text>
              </View>
              <View style={styles.quoteBannerBtn}>
                <Text style={styles.quoteBannerBtnText}>{count > 1 ? 'Ver todas →' : 'Ver →'}</Text>
              </View>
            </Pressable>
          );
        })()}

        {/* MIS SOLICITUDES ENVIADAS — aún esperando propuestas */}
        {myOpenRequests.length > 0 && !liveEvent && (() => {
          const first = myOpenRequests[0];
          const count = myOpenRequests.length;
          const typeLabel = first.request_type === 'express' ? 'Express' : 'Programada';
          const subText = count === 1
            ? `Solicitud ${typeLabel} · Esperando propuestas de grupos`
            : `${count} solicitudes activas · Esperando propuestas`;
          return (
            <Pressable
              style={styles.myRequestBanner}
              onPress={() => navigation.navigate('OpenRequest', { tab: 'mine' })}
            >
              <LinearGradient
                colors={['rgba(255,107,53,0.18)', 'rgba(255,107,53,0.05)']}
                style={StyleSheet.absoluteFillObject}
                start={{ x: 0, y: 0 }} end={{ x: 1, y: 1 }}
              />
              <Text style={styles.myRequestBannerIcon}>📡</Text>
              <View style={{ flex: 1 }}>
                <Text style={styles.myRequestBannerTitle}>
                  {count === 1 ? '¡Tu solicitud está activa!' : `¡${count} solicitudes activas!`}
                </Text>
                <Text style={styles.myRequestBannerSub}>{subText}</Text>
              </View>
              <View style={styles.myRequestBannerBtn}>
                <Text style={styles.myRequestBannerBtnText}>Ver →</Text>
              </View>
            </Pressable>
          );
        })()}

        {/* EXPRESS PROPOSAL BANNER — acumulativo */}
        {pendingExpressProposals.length > 0 && !liveEvent && (() => {
          const first = pendingExpressProposals[0];
          const count = pendingExpressProposals.length;
          const groupName = first._group?.name ?? 'Un grupo';
          const subText = count === 1
            ? `${groupName} quiere tocar en tu evento${first.proposal_data?.arrival_time ? ` · Llegan a las ${first.proposal_data.arrival_time}` : ''}`
            : `${groupName} y ${count - 1} más han propuesto`;
          const onPress = () => navigation.navigate('OpenRequest', { tab: 'mine' });
          return (
            <Pressable style={styles.expressBanner} onPress={onPress}>
              <LinearGradient
                colors={['rgba(0,230,118,0.18)', 'rgba(0,200,83,0.05)']}
                style={StyleSheet.absoluteFillObject}
                start={{ x: 0, y: 0 }} end={{ x: 1, y: 1 }}
              />
              <Text style={styles.expressBannerIcon}>⚡</Text>
              <View style={{ flex: 1 }}>
                <Text style={styles.expressBannerTitle}>
                  {count === 1 ? '¡Recibiste una propuesta!' : `¡${count} propuestas recibidas!`}
                </Text>
                <Text style={styles.expressBannerGroup}>{subText}</Text>
              </View>
              <View style={styles.expressBannerBtn}>
                <Text style={styles.expressBannerBtnText}>{count > 1 ? 'Ver todas →' : 'Ver →'}</Text>
              </View>
            </Pressable>
          );
        })()}

        {/* SOLICITAR GRUPO AHORA — hero CTA premium */}
        <Pressable
          style={styles.requestNowBanner}
          onPress={() => navigation.navigate('GuidedRequest')}
        >
          <LinearGradient
            colors={['rgba(0,230,118,0.14)', 'rgba(0,200,83,0.04)']}
            style={StyleSheet.absoluteFillObject}
            start={{ x: 0, y: 0 }} end={{ x: 1, y: 1 }}
          />
          <View style={styles.requestNowGlow} pointerEvents="none" />

          <View style={styles.requestNowIconChip}>
            <Zap size={16} color={COLORS.green} />
          </View>

          <View style={{ flex: 1 }}>
            <View style={styles.requestNowEyebrow}>
              <View style={styles.requestNowDot} />
              <Text style={styles.requestNowEyebrowText}>Express · En minutos</Text>
            </View>
            <Text style={styles.requestNowTitle}>Recibe propuestas en minutos</Text>
            <Text style={styles.requestNowSub}>Contrata música para tu evento</Text>
            <View style={styles.requestNowPill}>
              <Text style={styles.requestNowPillText}>Solicitar ahora →</Text>
            </View>
          </View>
        </Pressable>

        {/* VER GRUPOS EN MAPA — elegante */}
        <Pressable
          style={styles.groupsMapBanner}
          onPress={() => navigation.navigate('GroupsMap')}
        >
          <View style={styles.groupsMapIconBox}>
            <Text style={{ fontSize: 18 }}>🗺️</Text>
          </View>
          <View style={{ flex: 1 }}>
            <Text style={styles.groupsMapTitle}>Ver grupos en el mapa</Text>
            <Text style={styles.groupsMapSub}>Descubre qué hay cerca de ti</Text>
          </View>
          <Text style={styles.groupsMapArrow}>›</Text>
        </Pressable>

        <ScrollView
          showsVerticalScrollIndicator={false}
          contentContainerStyle={styles.listContent}
          refreshControl={<RefreshControl refreshing={refreshing} onRefresh={onRefresh} tintColor={COLORS.green} />}
        >

          {/* BUSCADOR */}
          <View style={styles.searchRow}>
            <View style={styles.searchWrapper}>
              <Search size={17} color={COLORS.muted} style={{ marginRight: 10 }} />
              <TextInput
                style={styles.searchInput}
                placeholder="Buscar grupo, género o ciudad..."
                placeholderTextColor={COLORS.muted}
                value={search}
                onChangeText={setSearch}
              />
              {search.length > 0 && (
                <Pressable onPress={() => setSearch('')}>
                  <X size={16} color={COLORS.muted} />
                </Pressable>
              )}
            </View>
            <Pressable
              style={[styles.locationBtn, nearbyCity && styles.locationBtnActive]}
              onPress={handleNearby}
            >
              {locationLoading
                ? <ActivityIndicator size="small" color={COLORS.green} />
                : <Navigation size={18} color={nearbyCity ? COLORS.green : COLORS.muted2} />
              }
            </Pressable>
          </View>
          {nearbyCity && (
            <View style={styles.nearbyChip}>
              <MapPin size={13} color={COLORS.green} />
              <Text style={styles.nearbyText}>Cerca de {nearbyCity}</Text>
              <Pressable onPress={() => setNearbyCity(null)}>
                <X size={13} color={COLORS.muted2} />
              </Pressable>
            </View>
          )}

          {/* DEMANDA CIUDAD */}
          {cityDemand && (cityDemand.demand_level === 'very_high' || cityDemand.demand_level === 'high') && (
            <View style={[
              styles.demandBanner,
              cityDemand.demand_level === 'very_high' && styles.demandBannerHot,
            ]}>
              <View style={{ flex: 1 }}>
                <Text style={styles.demandBannerTitle}>
                  {cityDemand.demand_level === 'very_high'
                    ? `🔥 Alta demanda en ${cityDemand.city}`
                    : `⚡ Buen momento en ${cityDemand.city}`}
                </Text>
                <Text style={styles.demandBannerSub}>
                  {profile?.role === 'group'
                    ? 'Alta demanda, promociónate ahora y consigue más eventos'
                    : profile?.role === 'talent'
                    ? 'Alta demanda en tu zona · Más oportunidades de trabajo'
                    : cityDemand.demand_level === 'very_high'
                    ? 'Pocos espacios disponibles · Agenda antes de que se llenen'
                    : 'Alta competencia entre grupos · Mejores precios ahora'}
                </Text>
              </View>
              <Zap size={18} color={cityDemand.demand_level === 'very_high' ? '#FF6D00' : COLORS.green} />
            </View>
          )}

          {/* LOYALTY CARD */}
          {loyalty && <LoyaltyCard loyalty={loyalty} navigation={navigation} />}

          {/* RECOMENDADOS — carrusel auto-scroll, hasta 20 grupos */}
          {(() => {
            const surgeMultiplier =
              cityDemand?.demand_level === 'very_high' ? 1.5
              : cityDemand?.demand_level === 'high'     ? 1.2
              : 1;
            // Rellenar con mocks si hay menos de 20 recomendados reales
            const recMockIds = new Set(topRecs.map(r => r.id));
            const recs = topRecs.length >= 20
              ? topRecs
              : [
                  ...topRecs,
                  ...MOCK_GROUPS.filter(m => !recMockIds.has(m.id)).slice(0, 20 - topRecs.length),
                ];
            return (
              <>
                <View style={styles.sectionRow}>
                  <View style={styles.sectionRowLeft}>
                    <Star size={13} color={COLORS.gold} fill={COLORS.gold} />
                    <Text style={styles.sectionLabel}>Recomendados</Text>
                  </View>
                </View>
                <AutoScrollCarousel
                  items={recs}
                  itemWidth={FEAT_W}
                  autoInterval={2800}
                  renderItem={(item, i) => (
                    <FeaturedCard
                      key={item.id}
                      group={item}
                      index={i}
                      navigation={item._is_mock ? null : navigation}
                      isRecommended={!item._is_mock}
                      surgeMultiplier={surgeMultiplier}
                    />
                  )}
                />
                <View style={{ height: 20 }} />
              </>
            );
          })()}

          {/* DESTACADOS — carrusel auto-scroll, hasta 20 grupos */}
          {(() => {
            const recIds = new Set(topRecs.map(r => r.id));
            const _now   = Date.now();
            // Patrocinados directos + grupos con bid activo
            const sponsored = groups.filter(g =>
              (g.is_sponsored || (g.bid_amount > 0 && g.bid_ends_at && new Date(g.bid_ends_at).getTime() > _now))
              && !recIds.has(g.id)
            );
            // Rellenar con mocks si hay menos de 20
            const destMockIds = new Set([...recIds, ...sponsored.map(g => g.id)]);
            const dest = sponsored.length >= 20
              ? sponsored.slice(0, 20)
              : [
                  ...sponsored,
                  ...MOCK_GROUPS.filter(m => !destMockIds.has(m.id)).slice(0, 20 - sponsored.length),
                ];
            return (
              <>
                <View style={styles.sectionRow}>
                  <View style={styles.sectionRowLeft}>
                    <Star size={13} color='#C9A84C' fill='#C9A84C' />
                    <Text style={styles.sectionLabel}>Destacados</Text>
                  </View>
                </View>
                <AutoScrollCarousel
                  items={dest}
                  itemWidth={FEAT_W}
                  autoInterval={3200}
                  renderItem={(item, i) => (
                    <FeaturedCard
                      key={item.id}
                      group={item}
                      index={i}
                      navigation={item._is_mock ? null : navigation}
                      isRecommended={false}
                    />
                  )}
                />
                <View style={{ height: 24 }} />
              </>
            );
          })()}

          {/* PUBLICIDAD — Carousel automático */}
          {(() => {
            // Prioridad: anuncios pagados (bannerAds) > promotions legacy
            const ads = bannerAds.length > 0 ? bannerAds : promotions;
            const isNewAds = bannerAds.length > 0;
            const total = ads.length;
            if (total === 0) return null;
            const safeIndex = currentAdIndex % total;
            const item = ads[safeIndex] as any;
            return (
              <View style={{ marginBottom: 20 }}>
                <Animated.View style={{ opacity: adFade }}>
                  <Pressable
                    style={[styles.promoBanner, item.is_free && { opacity: 0.82 }]}
                    onPress={() => isNewAds ? handleAdPress(item) : handlePromoBannerPress(item)}
                  >
                    <View style={styles.promoBannerInner}>
                      {/* Imagen/video de fondo a pantalla completa */}
                      {item.media_type === 'video' && item.media_url ? (
                        <VideoPlayer
                          uri={item.media_url}
                          style={styles.promoBannerBg}
                          contentFit="cover"
                          autoPlay muted loop
                        />
                      ) : item.media_url && !bannerImgError ? (
                        <Image
                          source={{ uri: item.media_url }}
                          style={styles.promoBannerBg}
                          resizeMode="cover"
                          onError={() => setBannerImgError(true)}
                        />
                      ) : (
                        <LinearGradient
                          colors={['#0d1f0d', '#030a03']}
                          style={styles.promoBannerBg}
                        />
                      )}
                      {/* Gradiente oscuro desde el centro hacia abajo */}
                      <LinearGradient
                        colors={['transparent', 'rgba(0,0,0,0.72)', 'rgba(0,0,0,0.93)']}
                        locations={[0.25, 0.65, 1]}
                        style={styles.promoBannerGrad}
                      />
                      {/* Chip "PUBLICIDAD" en la esquina superior izquierda */}
                      <View style={styles.promoBannerTagChip}>
                        <Text style={styles.promoBannerTagText}>{item.tag ?? 'PUBLICIDAD'}</Text>
                      </View>
                      {/* Texto y botón sobrepuestos en la parte inferior */}
                      <View style={styles.promoBannerOverlay}>
                        <View style={{ flex: 1 }}>
                          <Text style={styles.promoBannerTitle} numberOfLines={1}>{item.title}</Text>
                          {item.subtitle ? (
                            <Text style={styles.promoBannerSub} numberOfLines={1}>{item.subtitle}</Text>
                          ) : null}
                        </View>
                        <Pressable
                          style={styles.promoBannerBtn}
                          onPress={() => isNewAds ? handleAdCtaPress(item) : navigation.navigate('AdvertisingPackages')}
                        >
                          <Text style={styles.promoBannerBtnText}>{item.button_text ?? 'Ver más'} →</Text>
                        </Pressable>
                      </View>
                    </View>
                  </Pressable>
                </Animated.View>
                {/* Dots del carousel */}
                {total > 1 && (
                  <View style={styles.carouselDots}>
                    {ads.map((_: any, i: number) => (
                      <Pressable
                        key={i}
                        onPress={() => {
                          Animated.timing(adFade, { toValue: 0, duration: 200, useNativeDriver: true }).start(() => {
                            setCurrentAdIndex(i);
                            Animated.timing(adFade, { toValue: 1, duration: 200, useNativeDriver: true }).start();
                          });
                        }}
                      >
                        <View style={[styles.carouselDot, i === safeIndex && styles.carouselDotActive]} />
                      </Pressable>
                    ))}
                  </View>
                )}
              </View>
            );
          })()}

          {/* POPULARES EN TU ZONA — solo si no hay anuncios activos */}
          {(() => {
            const _now = Date.now();
            const hasActiveBids = groups.some(
              g => (g.bid_amount ?? 0) > 0 && g.bid_ends_at && new Date(g.bid_ends_at).getTime() > _now
            );
            const hasAds = bannerAds.length > 0 || sponsoredGroupIds.size > 0 || hasActiveBids;

            const trending = !hasAds
              ? [...groups]
                  .filter(g => (g.total_reviews ?? 0) > 0 || (g.ranking_score ?? 0) > 0)
                  .sort((a, b) => (b.ranking_score ?? 0) - (a.ranking_score ?? 0))
                  .slice(0, 8)
              : [];

            return (
              <>
                {trending.length > 0 && (
                  <>
                    <View style={styles.sectionRow}>
                      <View style={styles.sectionRowLeft}>
                        <TrendingUp size={14} color={COLORS.green} />
                        <Text style={styles.sectionLabel}>Populares en tu zona</Text>
                      </View>
                    </View>
                    <ScrollView
                      horizontal
                      showsHorizontalScrollIndicator={false}
                      contentContainerStyle={styles.featuredList}
                      style={{ marginBottom: 28 }}
                    >
                      {trending.map((group, i) => (
                        <FeaturedCard key={group.id} group={group} index={i} navigation={navigation} />
                      ))}
                    </ScrollView>
                  </>
                )}
              </>
            );
          })()}

          {/* CATEGORÍAS */}
          <ScrollView
            horizontal
            showsHorizontalScrollIndicator={false}
            contentContainerStyle={styles.genreList}
            style={{ marginBottom: 18 }}
          >
            <Pressable
              style={[styles.genreChip, selectedCategoryId === null && styles.genreChipActive]}
              onPress={() => setSelectedCategoryId(null)}
            >
              <Text style={[styles.genreText, selectedCategoryId === null && styles.genreTextActive]}>Todos</Text>
            </Pressable>
            {categories.map((cat) => (
              <Pressable
                key={cat.id}
                style={[styles.genreChip, selectedCategoryId === cat.id && styles.genreChipActive]}
                onPress={() => setSelectedCategoryId(cat.id)}
              >
                <Text style={[styles.genreText, selectedCategoryId === cat.id && styles.genreTextActive]}>
                  {CATEGORY_ICONS[cat.type] ?? '📋'} {cat.name}
                </Text>
              </Pressable>
            ))}
          </ScrollView>

          {/* TODOS LOS GRUPOS — grid 3 columnas */}
          <View style={styles.groupsHeader}>
            <Text style={styles.sectionLabel}>
              {nearbyCity ? `Grupos en ${nearbyCity}` : 'Todos los grupos'}
            </Text>
            <View style={styles.countChip}>
              <Text style={styles.countChipText}>{interleavedGroups.length}</Text>
            </View>
          </View>

          {interleavedGroups.length === 0 ? (
            <View style={styles.empty}>
              <Text style={styles.emptyEmoji}>🔍</Text>
              <Text style={styles.emptyText}>Sin resultados</Text>
              <Text style={styles.emptySub}>Intenta con otro género o ciudad</Text>
            </View>
          ) : (() => {
            // Promo banner después de la primera fila (3 grupos)
            const rows: React.ReactNode[] = [];
            for (let i = 0; i < interleavedGroups.length; i += 3) {
              const rowGroups = interleavedGroups.slice(i, i + 3);
              rows.push(
                <View key={`row-${i}`} style={styles.gridRow}>
                  {rowGroups.map((group, ri) => (
                    <GroupGridCard
                      key={group.id}
                      group={group}
                      index={i + ri}
                      navigation={navigation}
                      bidRank={bidRankMap.get(group.id) ?? null}
                    />
                  ))}
                  {/* Relleno si la fila no está completa */}
                  {rowGroups.length < 3 && Array.from({ length: 3 - rowGroups.length }).map((_, fi) => (
                    <View key={`fill-${fi}`} style={styles.gridCell} />
                  ))}
                </View>
              );
            }
            return <>{rows}</>;
          })()}
        </ScrollView>
      </SafeAreaView>

    </View>
  );
}

// ── Loyalty card ─────────────────────────────────────────────────────────────

const TIER_CONFIG: Record<string, { emoji: string; label: string; color: string }> = {
  bronze: { emoji: '🥉', label: 'Bronce',  color: '#CD7F32' },
  silver: { emoji: '🥈', label: 'Plata',   color: '#A8A9AD' },
  gold:   { emoji: '🥇', label: 'Oro',     color: COLORS.gold },
  vip:    { emoji: '💎', label: 'VIP',     color: '#A78BFA' },
};

function LoyaltyCard({ loyalty, navigation }: { loyalty: any; navigation: any }) {
  const tier       = loyalty.loyalty_tier   ?? 'bronze';
  const points     = loyalty.loyalty_points ?? 0;
  const toNext     = loyalty.points_to_next_tier ?? 0;
  const nextTier   = loyalty.next_tier      ?? 'silver';
  const discount   = loyalty.discount_pct   ?? 0;
  const cfg        = TIER_CONFIG[tier] ?? TIER_CONFIG.bronze;
  const nextCfg    = TIER_CONFIG[nextTier] ?? TIER_CONFIG.silver;

  // Progress within current tier band
  const tierMin: Record<string, number> = { bronze: 0, silver: 50, gold: 150, vip: 300 };
  const tierMax: Record<string, number> = { bronze: 50, silver: 150, gold: 300, vip: 300 };
  const min = tierMin[tier] ?? 0;
  const max = tierMax[tier] ?? 50;
  const progress = tier === 'vip' ? 1 : Math.min(1, (points - min) / (max - min));

  return (
    <Pressable
      style={styles.loyaltyCard}
      onPress={() => navigation.navigate('ClientReservations')}
    >
      <LinearGradient
        colors={['rgba(0,230,118,0.06)', 'rgba(0,0,0,0)']}
        style={StyleSheet.absoluteFillObject}
        start={{ x: 0, y: 0 }} end={{ x: 1, y: 1 }}
      />
      {/* Left: tier icon */}
      <View style={styles.loyaltyIcon}>
        <Text style={styles.loyaltyEmoji}>{cfg.emoji}</Text>
      </View>

      {/* Center: info */}
      <View style={{ flex: 1 }}>
        <View style={styles.loyaltyTierRow}>
          <Text style={[styles.loyaltyTierLabel, { color: cfg.color }]}>{cfg.label}</Text>
          <Text style={styles.loyaltyPoints}>{points} pts</Text>
        </View>
        {/* Progress bar */}
        <View style={styles.loyaltyBarBg}>
          <View style={[styles.loyaltyBarFill, { width: `${Math.round(progress * 100)}%` as any, backgroundColor: cfg.color }]} />
        </View>
        <Text style={styles.loyaltyNextLabel}>
          {tier === 'vip'
            ? '¡Nivel máximo alcanzado!'
            : `${toNext} pts para ${nextCfg.emoji} ${nextCfg.label}`}
        </Text>
      </View>

      {/* Right: discount badge */}
      {discount > 0 && (
        <View style={[styles.loyaltyDiscountBadge, { borderColor: cfg.color }]}>
          <Text style={[styles.loyaltyDiscountText, { color: cfg.color }]}>{discount}%{'\n'}OFF</Text>
        </View>
      )}
    </Pressable>
  );
}



// ── Featured horizontal card ────────────────────────────────────────────────

// ── Auto-scroll carousel ───────────────────────────────────────────────────
function AutoScrollCarousel({ items, renderItem, itemWidth, autoInterval = 3500 }: {
  items: any[];
  renderItem: (item: any, index: number) => React.ReactNode;
  itemWidth: number;
  autoInterval?: number;
}) {
  const ref = useRef<FlatList>(null);
  const idxRef = useRef(0);

  useEffect(() => {
    if (items.length <= 1) return;
    const t = setInterval(() => {
      idxRef.current = (idxRef.current + 1) % items.length;
      ref.current?.scrollToIndex({ index: idxRef.current, animated: true });
    }, autoInterval);
    return () => clearInterval(t);
  }, [items.length, autoInterval]);

  return (
    <FlatList
      ref={ref}
      data={items}
      horizontal
      showsHorizontalScrollIndicator={false}
      keyExtractor={(item, i) => item.id ?? String(i)}
      renderItem={({ item, index }) => renderItem(item, index) as React.ReactElement}
      snapToInterval={itemWidth + 10}
      decelerationRate="fast"
      contentContainerStyle={styles.featuredList}
      onScrollToIndexFailed={() => {}}
    />
  );
}

function FeaturedCard({ group, index, navigation, isRecommended, surgeMultiplier = 1 }: any) {
  const fade = useRef(new Animated.Value(0)).current;
  useEffect(() => {
    Animated.timing(fade, { toValue: 1, duration: 350, delay: index * 40, useNativeDriver: true }).start();
  }, []);

  return (
    <Animated.View style={{ opacity: fade }}>
      <Pressable
        style={styles.featCard}
        onPress={() => navigation && !group._is_mock && navigation.navigate('GroupDetail', { group })}
      >
        {/* Photo area */}
        <View style={styles.featPhotoBox}>
          {group.profile_image ? (
            <Image source={{ uri: group.profile_image }} style={styles.featImage} resizeMode="cover" />
          ) : (
            <View style={[styles.featImage, styles.featImagePlaceholder]}>
              <Text style={{ fontSize: 28, color: COLORS.muted }}>♪</Text>
            </View>
          )}
          {group._is_mock ? (
            <View style={styles.featMockBadge}>
              <Text style={styles.featMockBadgeText}>Demo</Text>
            </View>
          ) : isRecommended ? (
            <View style={styles.featRecommended}>
              <Text style={styles.featRecommendedText}>⭐ Reco.</Text>
            </View>
          ) : group.is_sponsored ? (
            <View style={styles.featSponsored}>
              <Text style={styles.featSponsoredText}>⭐ Dest.</Text>
            </View>
          ) : (group.is_bid_active || (group.boost_score ?? 0) > 0) ? (
            <View style={styles.featBoosted}>
              <Text style={styles.featBoostedText}>🔥</Text>
            </View>
          ) : null}
        </View>

        {/* Text content */}
        <View style={styles.featContent}>
          <View style={styles.featNameRow}>
            <Text style={styles.featName} numberOfLines={1}>{group.name}</Text>
            {group.is_verified && (
              <View style={styles.featVerifiedBadge}>
                <CheckCircle size={11} color="#90CAF9" />
              </View>
            )}
          </View>
          <View style={styles.featMeta}>
            <Star size={10} color={COLORS.gold} fill={COLORS.gold} />
            <Text style={styles.featRating}>{group.rating?.toFixed(1) ?? '4.8'}</Text>
            <Text style={styles.featDot}>·</Text>
            <MapPin size={10} color={COLORS.muted2} />
            <Text style={styles.featCity} numberOfLines={1}>{group.city ?? '—'}</Text>
          </View>
          {/* precio omitido en tarjetas del carrusel */}
        </View>
      </Pressable>
    </Animated.View>
  );
}

// ── Grid card (3 columnas) ──────────────────────────────────────────────────

const GRID_COLS = 3;
const GRID_GAP  = 8;
const GRID_W    = (width - SPACING.xl * 2 - GRID_GAP * (GRID_COLS - 1)) / GRID_COLS;
const GRID_IMG  = Math.round(GRID_W * 0.9);

function GroupGridCard({ group, index, navigation, bidRank }: any) {
  const fade = useRef(new Animated.Value(0)).current;
  useEffect(() => {
    Animated.timing(fade, { toValue: 1, duration: 300, delay: (index % 9) * 40, useNativeDriver: true }).start();
  }, []);

  const now = Date.now();
  const isBidActive = (group.bid_amount ?? 0) > 0 && group.bid_ends_at && new Date(group.bid_ends_at).getTime() > now;
  const isPromoted  = isBidActive || (group.boost_score ?? 0) > 0;
  const badgeLabel  = isBidActive && bidRank
    ? bidRank <= 3 ? '🔥 Top 3' : bidRank <= 5 ? '🔥 Top 5' : '🔥'
    : isPromoted ? '🔥' : group.is_sponsored ? '⭐' : null;
  const badgeColor  = isBidActive ? '#FF6D00' : '#C9A84C';

  return (
    <Animated.View style={[styles.gridCell, { opacity: fade }]}>
      <Pressable
        style={styles.gridCard}
        onPress={() => navigation.navigate('GroupDetail', { group })}
      >
        {/* Foto */}
        <View style={styles.gridImgBox}>
          {group.profile_image && (group.photo_status === 'approved' || !group.photo_status || group.photo_status === 'none')
            ? <Image source={{ uri: group.profile_image }} style={styles.gridImg} resizeMode="cover" />
            : <View style={[styles.gridImg, styles.gridImgPlaceholder]}>
                <Text style={{ fontSize: 28, color: COLORS.muted }}>♪</Text>
              </View>
          }
          {badgeLabel && (
            <View style={[styles.gridBadge, { backgroundColor: badgeColor }]}>
              <Text style={styles.gridBadgeText}>{badgeLabel}</Text>
            </View>
          )}
          {group.is_verified && (
            <View style={styles.gridVerified}>
              <CheckCircle size={10} color="#90CAF9" />
            </View>
          )}
        </View>
        {/* Info */}
        <View style={styles.gridInfo}>
          <Text style={styles.gridName} numberOfLines={1}>{group.name}</Text>
          <View style={styles.gridMeta}>
            <Star size={9} color={COLORS.gold} fill={COLORS.gold} />
            <Text style={styles.gridRating}>{group.rating?.toFixed(1) ?? '4.8'}</Text>
            <Text style={styles.gridDot}>·</Text>
            <Text style={styles.gridCity} numberOfLines={1}>{group.city ?? '—'}</Text>
          </View>
        </View>
      </Pressable>
    </Animated.View>
  );
}

// ── Full-width group card ───────────────────────────────────────────────────

function GroupCard({ group, index, navigation, bidRank }: any) {
  const fadeAnim  = useRef(new Animated.Value(0)).current;
  const slideAnim = useRef(new Animated.Value(24)).current;

  useEffect(() => {
    Animated.parallel([
      Animated.timing(fadeAnim,  { toValue: 1, duration: 380, delay: index * 70, useNativeDriver: true }),
      Animated.timing(slideAnim, { toValue: 0, duration: 380, delay: index * 70, useNativeDriver: true }),
    ]).start();
  }, []);

  // Señales de urgencia basadas en datos reales del servidor
  const lastBookedHoursAgo = group.last_booked_at
    ? Math.floor((Date.now() - new Date(group.last_booked_at).getTime()) / 3_600_000)
    : null;
  const showLastBooked = lastBookedHoursAgo !== null && lastBookedHoursAgo < 24;
  const showUrgency    = group.is_high_demand || showLastBooked;

  return (
    <Animated.View style={{ opacity: fadeAnim, transform: [{ translateY: slideAnim }], marginBottom: 16 }}>
      <Pressable
        style={styles.card}
        onPress={() => navigation.navigate('GroupDetail', { group })}
      >
        {group.profile_image && (group.photo_status === 'approved' || !group.photo_status || group.photo_status === 'none') ? (
          <Image source={{ uri: group.profile_image }} style={styles.cardImage} />
        ) : (
          <View style={[styles.cardImage, styles.cardImagePlaceholder]}>
            <Text style={{ fontSize: 52, color: COLORS.muted }}>♪</Text>
          </View>
        )}
        <LinearGradient
          colors={['transparent', 'rgba(4,4,4,0.97)']}
          style={styles.gradient}
        />
        {((group.boost_score ?? 0) > 0 ||
          ((group.bid_amount ?? 0) > 0 && group.bid_ends_at && new Date(group.bid_ends_at).getTime() > Date.now())
        ) && (() => {
          const isBid = (group.bid_amount ?? 0) > 0 && group.bid_ends_at && new Date(group.bid_ends_at).getTime() > Date.now();
          let label = '🔥 Promocionado';
          let extra = {};
          if (isBid && bidRank) {
            if (bidRank <= 3)  { label = '🔥 Top 3';  extra = styles.boostedBadgeTop3; }
            else if (bidRank <= 5)  { label = '🔥 Top 5';  extra = styles.boostedBadgeTop5; }
            else if (bidRank <= 10) { label = '🔥 Top 10'; }
          }
          return (
            <View style={[styles.boostedBadge, extra]}>
              <Text style={styles.boostedBadgeText}>{label}</Text>
            </View>
          );
        })()}
        {(group.recent_completions ?? 0) > 0 && (
          <View style={[styles.hotBadge, ((group.boost_score ?? 0) > 0 || (group.bid_amount ?? 0) > 0) && { top: 42 }]}>
            <Text style={styles.hotBadgeText}>🔥 {group.recent_completions} este mes</Text>
          </View>
        )}
        <View style={styles.cardContent}>
          <View style={styles.cardTitleRow}>
            <Text style={styles.cardTitle} numberOfLines={1}>{group.name}</Text>
            {group.is_verified && (
              <View style={styles.cardVerifiedBadge}>
                <CheckCircle size={11} color="#90CAF9" />
              </View>
            )}
          </View>
          {group.nivel && <LevelBadge nivel={group.nivel} size="sm" />}
          <View style={styles.cardMeta}>
            <View style={styles.metaItem}>
              <Star size={13} color={COLORS.gold} fill={COLORS.gold} />
              <Text style={styles.metaText}>{group.rating?.toFixed(1) ?? '4.8'}</Text>
            </View>
            <View style={styles.metaItem}>
              <MapPin size={13} color={COLORS.muted2} />
              <Text style={styles.metaText}>{group.city ?? 'Sin ciudad'}</Text>
            </View>
            {Array.isArray(group.service_cities) && group.service_cities.length > 0 && (
              <View style={styles.serviceCitiesChip}>
                <Text style={styles.serviceCitiesText} numberOfLines={1}>
                  +{group.service_cities.length} ciudad{group.service_cities.length > 1 ? 'es' : ''}
                </Text>
              </View>
            )}
          </View>

          {/* ── Señales de urgencia (solo si hay datos reales) ── */}
          {showUrgency && (
            <View style={styles.urgencyRow}>
              {group.is_high_demand && (
                <View style={styles.urgencyChipRed}>
                  <Text style={styles.urgencyChipText}>🔥 Alta demanda</Text>
                </View>
              )}
              {showLastBooked && (
                <View style={styles.urgencyChipAmber}>
                  <Text style={styles.urgencyChipText}>
                    ✅ {lastBookedHoursAgo === 0 ? 'Reservado hace menos de 1 h' : `Reservado hace ${lastBookedHoursAgo} h`}
                  </Text>
                </View>
              )}
            </View>
          )}

          <View style={styles.cardVerPerfilRow}>
            <View style={styles.cardVerPerfilBtn}>
              <Text style={styles.cardVerPerfilText}>Ver perfil →</Text>
            </View>
          </View>
        </View>
      </Pressable>
    </Animated.View>
  );
}

// ── Styles ──────────────────────────────────────────────────────────────────

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: COLORS.bg },

  // Header
  header: {
    flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center',
    paddingHorizontal: SPACING.xl, paddingTop: 6, paddingBottom: 6,
  },
  logoText: { fontFamily: FONTS.title, fontSize: 22, color: COLORS.text },
  logoGreen: { color: COLORS.green },
  subGreeting: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2, marginTop: 2 },
  headerActions: { flexDirection: 'row', alignItems: 'center', gap: 8 },
  iconBtn: {
    width: 38, height: 38, borderRadius: 10,
    backgroundColor: COLORS.card, borderWidth: 1, borderColor: COLORS.border,
    alignItems: 'center', justifyContent: 'center',
  },
  notifDot: {
    position: 'absolute', top: 5, right: 5,
    minWidth: 16, height: 16, borderRadius: 8,
    backgroundColor: COLORS.green, borderWidth: 1.5, borderColor: COLORS.bg,
    alignItems: 'center', justifyContent: 'center', paddingHorizontal: 3,
  },
  notifDotText: { fontFamily: FONTS.bodySemiBold, fontSize: 9, color: COLORS.bg },
  avatarBtn: {
    width: 38, height: 38, borderRadius: 19,
    backgroundColor: COLORS.greenMuted, borderWidth: 1.5, borderColor: COLORS.green,
    alignItems: 'center', justifyContent: 'center',
  },
  avatarLetter: { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.green },

  // Live banner
  liveBanner: {
    flexDirection: 'row', alignItems: 'center', gap: 12,
    marginHorizontal: SPACING.xl, marginBottom: 12,
    backgroundColor: COLORS.card, borderRadius: RADIUS.xl,
    borderWidth: 1.5, borderColor: COLORS.green,
    padding: 14, overflow: 'hidden',
  },
  liveDot: { width: 9, height: 9, borderRadius: 5, backgroundColor: COLORS.red },
  liveBannerTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.green, marginBottom: 2 },
  liveBannerGroup: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.text },
  liveBannerBtn: {
    flexDirection: 'row', alignItems: 'center', gap: 4,
    backgroundColor: COLORS.green, borderRadius: RADIUS.md,
    paddingHorizontal: 12, paddingVertical: 8,
  },
  liveBannerBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 12, color: COLORS.bg },

  // Pending payment banner
  payBanner: {
    flexDirection: 'row', alignItems: 'center', gap: 12,
    marginHorizontal: SPACING.xl, marginBottom: 12,
    backgroundColor: COLORS.card, borderRadius: RADIUS.xl,
    borderWidth: 1.5, borderColor: COLORS.orange,
    padding: 14, overflow: 'hidden',
  },
  payBannerIcon: { fontSize: 22 },
  payBannerTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.orange, marginBottom: 2 },
  payBannerGroup: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.muted2 },
  payBannerBtn: {
    backgroundColor: COLORS.orange, borderRadius: RADIUS.md,
    paddingHorizontal: 14, paddingVertical: 8,
  },
  payBannerBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 12, color: '#000' },

  // Quote banner
  quoteBanner: {
    flexDirection: 'row', alignItems: 'center', gap: 12,
    marginHorizontal: SPACING.xl, marginBottom: 10,
    borderRadius: RADIUS.xl, overflow: 'hidden',
    borderWidth: 1, borderColor: 'rgba(66,133,244,0.35)',
    paddingHorizontal: 16, paddingVertical: 12,
  },
  quoteBannerIcon:    { fontSize: 22 },
  quoteBannerTitle:   { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: '#4285F4' },
  quoteBannerGroup:   { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted2, marginTop: 1 },
  quoteBannerBtn: {
    paddingHorizontal: 10, paddingVertical: 6,
    borderRadius: RADIUS.md, backgroundColor: 'rgba(66,133,244,0.18)',
  },
  quoteBannerBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 12, color: '#4285F4' },

  // Express proposal banner
  expressBanner: {
    flexDirection: 'row', alignItems: 'center', gap: 12,
    marginHorizontal: SPACING.xl, marginBottom: 10,
    borderRadius: RADIUS.xl, overflow: 'hidden',
    borderWidth: 1.5, borderColor: COLORS.green,
    paddingHorizontal: 16, paddingVertical: 12,
  },
  expressBannerIcon:    { fontSize: 22 },
  expressBannerTitle:   { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.green, marginBottom: 2 },
  expressBannerGroup:   { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted2 },
  expressBannerBtn: {
    paddingHorizontal: 10, paddingVertical: 6,
    borderRadius: RADIUS.md, backgroundColor: 'rgba(0,230,118,0.18)',
  },
  expressBannerBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 12, color: COLORS.green },

  // My open requests banner
  myRequestBanner: {
    flexDirection: 'row', alignItems: 'center', gap: 12,
    marginHorizontal: SPACING.xl, marginBottom: 10,
    borderRadius: RADIUS.xl, overflow: 'hidden',
    borderWidth: 1.5, borderColor: 'rgba(255,107,53,0.6)',
    paddingHorizontal: 16, paddingVertical: 12,
  },
  myRequestBannerIcon:  { fontSize: 22 },
  myRequestBannerTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: '#FF6B35', marginBottom: 2 },
  myRequestBannerSub:   { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted2 },
  myRequestBannerBtn: {
    paddingHorizontal: 10, paddingVertical: 6,
    borderRadius: RADIUS.md, backgroundColor: 'rgba(255,107,53,0.18)',
  },
  myRequestBannerBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 12, color: '#FF6B35' },

  // Solicitar ahora banner
  // ── Botón Propuestas (hero) ──
  requestNowBanner: {
    marginHorizontal: SPACING.xl, marginBottom: 10,
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.22)',
    borderRadius: 18, padding: 13,
    overflow: 'hidden',
    backgroundColor: '#061008',
    shadowColor: COLORS.green,
    shadowOffset: { width: 0, height: 0 },
    shadowOpacity: 0.15,
    shadowRadius: 14,
    elevation: 4,
    flexDirection: 'row', alignItems: 'center', gap: 12,
  },
  requestNowGlow: {
    position: 'absolute', top: -20, left: -20,
    width: 80, height: 80, borderRadius: 40,
    backgroundColor: 'rgba(0,230,118,0.08)',
  },
  requestNowIconChip: {
    width: 36, height: 36, borderRadius: 11,
    backgroundColor: 'rgba(0,230,118,0.15)',
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.3)',
    alignItems: 'center', justifyContent: 'center',
    flexShrink: 0,
  },
  requestNowEyebrow:     { flexDirection: 'row', alignItems: 'center', gap: 5, marginBottom: 2 },
  requestNowDot:         { width: 5, height: 5, borderRadius: 3, backgroundColor: COLORS.green },
  requestNowEyebrowText: { fontFamily: FONTS.bodyMedium, fontSize: 9, color: COLORS.green, letterSpacing: 0.8, textTransform: 'uppercase' as const },
  requestNowTitle: { fontFamily: FONTS.title, fontSize: 14, color: COLORS.text, lineHeight: 18, marginBottom: 2 },
  requestNowSub:   { fontFamily: FONTS.body, fontSize: 11, color: '#4a7a5a', marginBottom: 8 },
  requestNowPill: {
    alignSelf: 'flex-start' as const,
    paddingHorizontal: 12, paddingVertical: 5,
    borderRadius: 16, backgroundColor: COLORS.green,
  },
  requestNowPillText: { fontFamily: FONTS.bodySemiBold, fontSize: 11, color: '#000' },

  // ── Botón Mapa ──
  groupsMapBanner: {
    flexDirection: 'row', alignItems: 'center', gap: 12,
    marginHorizontal: SPACING.xl, marginBottom: 12,
    backgroundColor: 'rgba(255,255,255,0.03)',
    borderWidth: 1, borderColor: 'rgba(255,255,255,0.07)',
    borderRadius: 18, padding: 13,
    elevation: 2,
  },
  groupsMapIconBox: {
    width: 40, height: 40, borderRadius: 12,
    backgroundColor: 'rgba(66,133,244,0.12)',
    borderWidth: 1, borderColor: 'rgba(66,133,244,0.25)',
    alignItems: 'center', justifyContent: 'center',
  },
  groupsMapTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.text },
  groupsMapSub:   { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted, marginTop: 2 },
  groupsMapArrow: { fontFamily: FONTS.title, fontSize: 24, color: COLORS.muted },

  // Search
  searchRow: {
    flexDirection: 'row', alignItems: 'center', gap: 10,
    marginBottom: 10,
  },
  searchWrapper: {
    flex: 1, flexDirection: 'row', alignItems: 'center',
    backgroundColor: COLORS.card, borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: COLORS.border, paddingHorizontal: 14,
  },
  searchInput: {
    flex: 1, paddingVertical: 13,
    fontFamily: FONTS.body, fontSize: 14, color: COLORS.text,
  },
  locationBtn: {
    width: 46, height: 46, borderRadius: RADIUS.md,
    backgroundColor: COLORS.card, borderWidth: 1, borderColor: COLORS.border,
    alignItems: 'center', justifyContent: 'center',
  },
  locationBtnActive: { borderColor: COLORS.green, backgroundColor: COLORS.greenMuted },
  nearbyChip: {
    flexDirection: 'row', alignItems: 'center', gap: 6,
    marginBottom: 10,
    backgroundColor: COLORS.greenMuted, borderRadius: RADIUS.full,
    borderWidth: 1, borderColor: COLORS.green,
    paddingHorizontal: 14, paddingVertical: 7, alignSelf: 'flex-start',
  },
  nearbyText: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.green, flex: 1 },

  listContent: { paddingHorizontal: SPACING.xl, paddingBottom: 32 },

  // Promo banner — imagen dominante con texto sobrepuesto
  promoBanner: {
    borderRadius: RADIUS.xl, overflow: 'hidden',
    borderWidth: 1, borderColor: COLORS.greenGlow, marginBottom: 20,
  },
  promoBannerInner: { height: 190, position: 'relative' },
  promoBannerBg: {
    position: 'absolute', top: 0, left: 0, right: 0, bottom: 0,
    width: '100%', height: '100%',
  },
  promoBannerGrad: {
    position: 'absolute', top: 0, left: 0, right: 0, bottom: 0,
  },
  promoBannerTagChip: {
    position: 'absolute', top: 10, left: 10,
    backgroundColor: 'rgba(0,0,0,0.52)',
    borderRadius: RADIUS.full, paddingHorizontal: 9, paddingVertical: 4,
    borderWidth: 1, borderColor: 'rgba(255,255,255,0.16)',
  },
  promoBannerTagText: {
    fontFamily: FONTS.bodyMedium, fontSize: 9,
    color: 'rgba(255,255,255,0.82)', letterSpacing: 1.2,
  },
  promoBannerOverlay: {
    position: 'absolute', bottom: 0, left: 0, right: 0,
    flexDirection: 'row', alignItems: 'flex-end', gap: 10,
    paddingHorizontal: SPACING.md, paddingBottom: 14,
  },
  promoBannerTitle: {
    fontFamily: FONTS.bodySemiBold, fontSize: 15, color: '#fff', marginBottom: 3,
    textShadowColor: 'rgba(0,0,0,0.6)', textShadowOffset: { width: 0, height: 1 }, textShadowRadius: 4,
  },
  promoBannerSub: {
    fontFamily: FONTS.body, fontSize: 12, color: 'rgba(255,255,255,0.78)',
    textShadowColor: 'rgba(0,0,0,0.5)', textShadowOffset: { width: 0, height: 1 }, textShadowRadius: 3,
  },
  promoBannerBtn: {
    paddingHorizontal: 12, paddingVertical: 8,
    borderRadius: RADIUS.md, backgroundColor: COLORS.green, flexShrink: 0,
  },
  promoBannerBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 12, color: '#000' },

  // Sections
  sectionRow: {
    flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center', marginBottom: 12,
  },
  sectionRowLeft: { flexDirection: 'row', alignItems: 'center', gap: 6 },
  sectionLabel: { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.text },
  sectionCount: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2 },

  // Event type quick actions
  eventTypeList: { gap: 10, paddingRight: SPACING.xl },
  eventTypeChip: {
    alignItems: 'center', gap: 6,
    backgroundColor: COLORS.card, borderWidth: 1, borderColor: COLORS.border,
    borderRadius: RADIUS.lg, paddingHorizontal: 14, paddingVertical: 10,
  },
  eventTypeEmoji: { fontSize: 22 },
  eventTypeLabel: { fontFamily: FONTS.bodyMedium, fontSize: 11, color: COLORS.muted2 },

  // Featured horizontal
  featuredList: { gap: 8, paddingRight: SPACING.xl },
  featCard: {
    width: FEAT_W,
    borderRadius: RADIUS.xl, overflow: 'hidden',
    backgroundColor: COLORS.card, borderWidth: 1, borderColor: COLORS.border,
  },
  featPhotoBox: { width: '100%', height: 70, position: 'relative' },
  featImage: { width: '100%', height: '100%' },
  featImagePlaceholder: { backgroundColor: COLORS.card2, alignItems: 'center', justifyContent: 'center' },
  featGradient: { position: 'absolute', left: 0, right: 0, bottom: 0, height: '60%' },
  featSponsored: {
    position: 'absolute', top: 4, left: 4,
    backgroundColor: '#C9A84C', paddingHorizontal: 5, paddingVertical: 2,
    borderRadius: RADIUS.full,
  },
  featSponsoredText: { fontFamily: FONTS.bodySemiBold, fontSize: 8, color: '#000' },
  featBoosted: {
    position: 'absolute', top: 4, left: 4,
    backgroundColor: '#7C3AED', paddingHorizontal: 5, paddingVertical: 2,
    borderRadius: RADIUS.full,
  },
  featBoostedText: { fontFamily: FONTS.bodySemiBold, fontSize: 8, color: '#fff' },
  featMockBadge: {
    position: 'absolute', top: 4, left: 4,
    backgroundColor: 'rgba(0,0,0,0.55)', paddingHorizontal: 5, paddingVertical: 2,
    borderRadius: RADIUS.full,
  },
  featMockBadgeText: { fontFamily: FONTS.bodySemiBold, fontSize: 8, color: COLORS.muted2 },
  featContent: { padding: 7 },
  featNameRow: { flexDirection: 'row', alignItems: 'center', gap: 4, marginBottom: 2 },
  featVerifiedBadge: {
    width: 14, height: 14, borderRadius: 7,
    backgroundColor: 'rgba(66,133,244,0.25)',
    borderWidth: 1, borderColor: 'rgba(66,133,244,0.5)',
    alignItems: 'center', justifyContent: 'center',
    flexShrink: 0,
  },
  featGenre: {
    alignSelf: 'flex-start',
    backgroundColor: COLORS.greenMuted, paddingHorizontal: 5, paddingVertical: 1,
    borderRadius: RADIUS.full, marginBottom: 2,
  },
  featGenreText: { fontFamily: FONTS.bodyMedium, fontSize: 8, color: COLORS.green },
  featName: { fontFamily: FONTS.bodySemiBold, fontSize: 11, color: COLORS.text, lineHeight: 14, flex: 1 },
  featMeta: { flexDirection: 'row', alignItems: 'center', gap: 2 },
  featRating: { fontFamily: FONTS.bodyMedium, fontSize: 9, color: COLORS.gold },
  featDot: { fontFamily: FONTS.body, fontSize: 9, color: COLORS.muted },
  featCity: { fontFamily: FONTS.body, fontSize: 9, color: COLORS.muted2, flex: 1 },
  featPrice:       { fontFamily: FONTS.bodySemiBold, fontSize: 9, color: COLORS.green, marginTop: 2 },
  featPriceStrike: { textDecorationLine: 'line-through', color: COLORS.muted, fontSize: 8, marginTop: 1 },
  featPriceSurge:  { color: '#FF6D00', marginTop: 0 },

  // Category chips
  genreList: { gap: 8, flexDirection: 'row', paddingRight: SPACING.xl },
  genreChip: {
    paddingHorizontal: 16, paddingVertical: 8, borderRadius: RADIUS.full,
    backgroundColor: COLORS.card, borderWidth: 1, borderColor: COLORS.border,
  },
  genreChipActive: { backgroundColor: COLORS.greenMuted, borderColor: COLORS.green },
  genreText: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted2 },
  genreTextActive: { color: COLORS.green },

  // Groups header
  groupsHeader: { flexDirection: 'row', alignItems: 'center', gap: 10, marginBottom: 14 },
  countChip: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.full,
    borderWidth: 1, borderColor: COLORS.border,
    paddingHorizontal: 10, paddingVertical: 3,
  },
  countChipText: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.muted2 },

  // Grid 3 columnas
  gridRow:  { flexDirection: 'row', gap: GRID_GAP, marginBottom: GRID_GAP },
  gridCell: { width: GRID_W },
  gridCard: {
    width: GRID_W, borderRadius: RADIUS.lg, overflow: 'hidden',
    backgroundColor: COLORS.card, borderWidth: 1, borderColor: COLORS.border,
  },
  gridImgBox:         { width: GRID_W, height: GRID_IMG, position: 'relative' },
  gridImg:            { width: '100%', height: '100%' },
  gridImgPlaceholder: { backgroundColor: COLORS.card2, alignItems: 'center', justifyContent: 'center' },
  gridBadge: {
    position: 'absolute', top: 4, left: 4,
    paddingHorizontal: 5, paddingVertical: 2, borderRadius: RADIUS.full,
  },
  gridBadgeText: { fontFamily: FONTS.bodySemiBold, fontSize: 8, color: '#fff' },
  gridVerified: {
    position: 'absolute', top: 4, right: 4,
    width: 16, height: 16, borderRadius: 8,
    backgroundColor: 'rgba(66,133,244,0.3)', borderWidth: 1, borderColor: 'rgba(66,133,244,0.6)',
    alignItems: 'center', justifyContent: 'center',
  },
  gridInfo:   { padding: 6 },
  gridName:   { fontFamily: FONTS.bodySemiBold, fontSize: 11, color: COLORS.text, marginBottom: 2 },
  gridMeta:   { flexDirection: 'row', alignItems: 'center', gap: 2, flexWrap: 'nowrap' },
  gridRating: { fontFamily: FONTS.bodyMedium, fontSize: 9, color: COLORS.gold },
  gridDot:    { fontFamily: FONTS.body, fontSize: 9, color: COLORS.muted },
  gridCity:   { fontFamily: FONTS.body, fontSize: 9, color: COLORS.muted2, flex: 1 },
  gridPrice:  { fontFamily: FONTS.bodyMedium, fontSize: 9, color: COLORS.green, marginTop: 2 },

  // Card
  card: {
    width: CARD_W, height: 230,
    borderRadius: RADIUS.xl, overflow: 'hidden',
    backgroundColor: COLORS.card, borderWidth: 1, borderColor: COLORS.border,
  },
  cardImage: { width: '100%', height: '100%', position: 'absolute' },
  cardImagePlaceholder: { backgroundColor: COLORS.card2, alignItems: 'center', justifyContent: 'center' },
  gradient: { position: 'absolute', left: 0, right: 0, bottom: 0, height: '70%' },
  verifiedBadge: {
    position: 'absolute', top: 12, right: 12,
    backgroundColor: 'rgba(66,133,244,0.85)',
    paddingHorizontal: 10, paddingVertical: 4, borderRadius: RADIUS.full,
  },
  verifiedText: { fontFamily: FONTS.bodyMedium, fontSize: 11, color: '#fff' },
  cardContent: { position: 'absolute', bottom: 0, left: 0, right: 0, padding: 16 },
  genreTag: {
    alignSelf: 'flex-start',
    backgroundColor: COLORS.greenMuted, paddingHorizontal: 10, paddingVertical: 3,
    borderRadius: RADIUS.full, marginBottom: 6,
  },
  genreTagText: { fontFamily: FONTS.bodyMedium, fontSize: 11, color: COLORS.green },
  cardTitleRow: { flexDirection: 'row', alignItems: 'center', gap: 6, marginBottom: 6 },
  cardVerifiedBadge: {
    width: 20, height: 20, borderRadius: 10,
    backgroundColor: 'rgba(66,133,244,0.25)',
    borderWidth: 1, borderColor: 'rgba(66,133,244,0.5)',
    alignItems: 'center', justifyContent: 'center', flexShrink: 0,
  },
  cardTitle: { fontFamily: FONTS.title, fontSize: 20, color: COLORS.text, flex: 1 },
  cardMeta: { flexDirection: 'row', alignItems: 'center', gap: 10, flexWrap: 'wrap' },
  metaItem: { flexDirection: 'row', alignItems: 'center', gap: 4 },
  metaText: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2 },
  serviceCitiesChip: {
    backgroundColor: 'rgba(0,230,118,0.10)',
    borderRadius: 6,
    paddingHorizontal: 6,
    paddingVertical: 2,
  },
  serviceCitiesText: {
    fontFamily: FONTS.bodyMedium,
    fontSize: 11,
    color: COLORS.green,
  },
  priceTag: {
    marginLeft: 'auto' as any,
    backgroundColor: COLORS.greenMuted, paddingHorizontal: 10, paddingVertical: 4,
    borderRadius: RADIUS.full,
  },
  priceText: { fontFamily: FONTS.bodySemiBold, fontSize: 12, color: COLORS.green },
  boostedBadge: {
    position: 'absolute', top: 12, left: 12,
    backgroundColor: '#7C3AED',
    paddingHorizontal: 10, paddingVertical: 4, borderRadius: RADIUS.full,
  },
  boostedBadgeTop3: { backgroundColor: '#DC2626' },
  boostedBadgeTop5: { backgroundColor: '#EA580C' },
  boostedBadgeText: { fontFamily: FONTS.bodyMedium, fontSize: 11, color: '#fff' },
  hotBadge: {
    position: 'absolute', top: 12, left: 12,
    backgroundColor: 'rgba(255,80,0,0.85)',
    paddingHorizontal: 9, paddingVertical: 3,
    borderRadius: RADIUS.full,
  },
  hotBadgeText: { fontFamily: FONTS.bodyMedium, fontSize: 10, color: '#fff' },
  // Urgency signals
  urgencyRow: { flexDirection: 'row', flexWrap: 'wrap', gap: 6, marginTop: 8, marginBottom: 2 },
  urgencyChipRed: {
    flexDirection: 'row', alignItems: 'center',
    backgroundColor: 'rgba(239,68,68,0.12)',
    borderWidth: 1, borderColor: 'rgba(239,68,68,0.35)',
    borderRadius: RADIUS.full,
    paddingHorizontal: 10, paddingVertical: 4,
  },
  urgencyChipAmber: {
    flexDirection: 'row', alignItems: 'center',
    backgroundColor: 'rgba(245,158,11,0.12)',
    borderWidth: 1, borderColor: 'rgba(245,158,11,0.35)',
    borderRadius: RADIUS.full,
    paddingHorizontal: 10, paddingVertical: 4,
  },
  urgencyChipText: { fontFamily: FONTS.bodyMedium, fontSize: 11, color: COLORS.text },

  cardVerPerfilRow: { flexDirection: 'row', marginTop: 10 },
  cardVerPerfilBtn: {
    backgroundColor: 'rgba(0,230,118,0.12)',
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.35)',
    borderRadius: RADIUS.full,
    paddingHorizontal: 14, paddingVertical: 6,
  },
  cardVerPerfilText: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.green },

  // Contact modal
  contactOverlay: { flex: 1, backgroundColor: 'rgba(0,0,0,0.6)', justifyContent: 'flex-end' },
  contactSheet: {
    backgroundColor: COLORS.card2, borderTopLeftRadius: 24, borderTopRightRadius: 24,
    padding: SPACING.xl, paddingBottom: 36,
  },
  contactHandle: {
    width: 40, height: 4, borderRadius: 2, backgroundColor: COLORS.border,
    alignSelf: 'center', marginBottom: 20,
  },
  contactTitle: { fontFamily: FONTS.title, fontSize: 18, color: COLORS.text, marginBottom: 4 },
  contactSub: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2, marginBottom: 18 },
  contactLabel: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted2, marginBottom: 6 },
  contactInput: {
    backgroundColor: COLORS.bg, borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: COLORS.border,
    paddingHorizontal: 14, paddingVertical: 12,
    fontFamily: FONTS.body, fontSize: 14, color: COLORS.text, marginBottom: 14,
  },
  contactTextArea: { height: 100, textAlignVertical: 'top', paddingTop: 12 },
  contactSendBtn: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 10,
    backgroundColor: COLORS.green, borderRadius: RADIUS.md, paddingVertical: 14, marginTop: 4,
  },
  contactSendText: { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.bg },

  // Empty
  empty: { alignItems: 'center', paddingTop: 60, paddingBottom: 40 },
  emptyEmoji: { fontSize: 42, marginBottom: 14 },
  emptyText: { fontFamily: FONTS.bodySemiBold, color: COLORS.muted2, fontSize: 16, marginBottom: 6 },
  emptySub: { fontFamily: FONTS.body, color: COLORS.muted, fontSize: 13 },

  // Recent completions indicators
  featCompletions: {
    fontFamily: FONTS.body, fontSize: 10, color: COLORS.green,
    marginTop: 2, marginBottom: 1,
  },
  completionsBadge: {
    flexDirection: 'row', alignItems: 'center', gap: 4,
    marginTop: 6, alignSelf: 'flex-start',
    backgroundColor: 'rgba(0,230,118,0.08)', borderRadius: 6,
    paddingHorizontal: 7, paddingVertical: 3,
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.2)',
  },
  completionsBadgeText: {
    fontFamily: FONTS.body, fontSize: 11, color: COLORS.green,
  },

  // Loyalty card
  loyaltyCard: {
    flexDirection: 'row', alignItems: 'center', gap: 12,
    backgroundColor: COLORS.card, borderRadius: RADIUS.xl,
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.25)',
    padding: 14, marginBottom: 20, overflow: 'hidden',
  },
  loyaltyIcon: {
    width: 44, height: 44, borderRadius: 22,
    backgroundColor: COLORS.bg, borderWidth: 1, borderColor: COLORS.border,
    alignItems: 'center', justifyContent: 'center',
  },
  loyaltyEmoji:    { fontSize: 22 },
  loyaltyTierRow:  { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center', marginBottom: 6 },
  loyaltyTierLabel:{ fontFamily: FONTS.bodySemiBold, fontSize: 13 },
  loyaltyPoints:   { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.muted2 },
  loyaltyBarBg:    { height: 5, backgroundColor: COLORS.border, borderRadius: 3, overflow: 'hidden', marginBottom: 4 },
  loyaltyBarFill:  { height: '100%', borderRadius: 3 },
  loyaltyNextLabel:{ fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted },
  loyaltyDiscountBadge: {
    width: 40, height: 40, borderRadius: 8,
    borderWidth: 1.5, alignItems: 'center', justifyContent: 'center',
    backgroundColor: 'rgba(0,0,0,0.4)',
  },
  loyaltyDiscountText: { fontFamily: FONTS.bodySemiBold, fontSize: 11, textAlign: 'center', lineHeight: 14 },

  // ── Past groups ("Reserva nuevamente") ──
  pastGroupCard: {
    width: 130, backgroundColor: COLORS.card,
    borderRadius: RADIUS.lg, borderWidth: 1, borderColor: COLORS.border,
    overflow: 'hidden',
  },
  pastGroupImg: { width: '100%', height: 80 },
  pastGroupImgPlaceholder: { backgroundColor: COLORS.card2, alignItems: 'center', justifyContent: 'center' },
  pastGroupInfo: { padding: 10, gap: 2 },
  pastGroupName: { fontFamily: FONTS.bodySemiBold, fontSize: 12, color: COLORS.text, lineHeight: 17 },
  pastGroupGenre: { fontFamily: FONTS.body, fontSize: 10, color: COLORS.green },
  pastGroupMeta: { flexDirection: 'row', alignItems: 'center', gap: 8, marginTop: 4 },
  pastGroupTimes: { fontFamily: FONTS.bodyMedium, fontSize: 10, color: COLORS.muted2 },
  pastGroupRating: { fontFamily: FONTS.bodyMedium, fontSize: 10, color: COLORS.gold },

  // Carousel dots
  carouselDots: {
    flexDirection: 'row', justifyContent: 'center', alignItems: 'center',
    gap: 6, marginTop: 10,
  },
  carouselDot: {
    width: 6, height: 6, borderRadius: 3,
    backgroundColor: COLORS.border,
  },
  carouselDotActive: {
    width: 18, backgroundColor: COLORS.green,
  },

  featRecommended: {
    position: 'absolute', top: 6, left: 6,
    backgroundColor: COLORS.green,
    paddingHorizontal: 7, paddingVertical: 3,
    borderRadius: RADIUS.full,
  },
  featRecommendedText: { fontFamily: FONTS.bodySemiBold, fontSize: 9, color: '#000' },

  // ── Promo slot card (espacio sin anuncios) ──────────────────────────────
  promoSlotCard: {
    marginHorizontal: 16, marginBottom: 20,
    borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.green + '30',
    overflow: 'hidden',
  },
  promoSlotGradient: {
    padding: 18, gap: 6,
  },
  promoSlotBadge: {
    alignSelf: 'flex-start',
    backgroundColor: COLORS.green + '20',
    borderRadius: 6, borderWidth: 1, borderColor: COLORS.green + '50',
    paddingHorizontal: 8, paddingVertical: 3,
    marginBottom: 4,
  },
  promoSlotBadgeText: {
    fontFamily: FONTS.bodySemiBold, fontSize: 9,
    color: COLORS.green, letterSpacing: 1,
  },
  promoSlotTitle: {
    fontFamily: FONTS.title, fontSize: 17, color: '#fff',
  },
  promoSlotSub: {
    fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted,
  },
  promoSlotBtn: {
    marginTop: 10, alignSelf: 'flex-start',
    backgroundColor: COLORS.green, borderRadius: RADIUS.md,
    paddingHorizontal: 16, paddingVertical: 9,
  },
  promoSlotBtnText: {
    fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.bg,
  },

  // ── Demanda ciudad ─────────────────────────────────────────────────────────
  demandBanner: {
    flexDirection: 'row', alignItems: 'center', gap: 12,
    marginHorizontal: SPACING.xl, marginBottom: 12,
    backgroundColor: 'rgba(0,230,118,0.07)', borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.3)',
    paddingHorizontal: 14, paddingVertical: 12,
  },
  demandBannerHot: {
    backgroundColor: 'rgba(255,109,0,0.08)',
    borderColor: 'rgba(255,109,0,0.35)',
  },
  demandBannerTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.text, marginBottom: 2 },
  demandBannerSub:   { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, lineHeight: 17 },

  // ── Compact promo block (group sin ads activos, tras 3er grupo) ──────────────
  compactPromoBlock: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between',
    marginHorizontal: SPACING.xl, marginBottom: 10,
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.25)',
    paddingHorizontal: 14, paddingVertical: 12,
  },
  compactPromoText: {
    fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.text, flex: 1,
  },
  compactPromoBtn: {
    backgroundColor: COLORS.green, borderRadius: RADIUS.md,
    paddingHorizontal: 12, paddingVertical: 7, marginLeft: 10,
  },
  compactPromoBtnText: {
    fontFamily: FONTS.bodySemiBold, fontSize: 12, color: COLORS.bg,
  },

  // Banner: pago fallido post-evento (50% restante declinado)
  failedChargeBanner: {
    flexDirection: 'row', alignItems: 'center', gap: 10,
    marginHorizontal: SPACING.xl, marginBottom: 10,
    borderRadius: RADIUS.lg, overflow: 'hidden',
    borderWidth: 1, borderColor: 'rgba(239,83,80,0.35)',
    paddingHorizontal: 14, paddingVertical: 12,
  },
  failedChargeIcon: { fontSize: 22 },
  failedChargeTitle: {
    fontFamily: FONTS.bodySemiBold, fontSize: 14,
    color: '#EF5350', marginBottom: 2,
  },
  failedChargeGroup: {
    fontFamily: FONTS.body, fontSize: 12,
    color: COLORS.muted2, lineHeight: 17,
  },
  failedChargeBtn: {
    backgroundColor: '#EF5350', borderRadius: RADIUS.md,
    paddingHorizontal: 12, paddingVertical: 7,
  },
  failedChargeBtnText: {
    fontFamily: FONTS.bodySemiBold, fontSize: 12, color: '#fff',
  },

});
