import { LinearGradient } from 'expo-linear-gradient';
import * as Location from 'expo-location';
import * as WebBrowser from 'expo-web-browser';
import VideoPlayer from '../../components/ui/VideoPlayer';
import { Bell, ChevronLeft, ChevronRight, MapPin, Navigation, Search, Star, TrendingUp, Volume2, VolumeX, X, Zap } from 'lucide-react-native';
import { useIsFocused } from '@react-navigation/native';
import React, { useEffect, useMemo, useRef, useState } from 'react';
import {
  ActivityIndicator,
  Alert,
  Animated,
  Dimensions,
  FlatList,
  Image,
  Modal,
  PanResponder,
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
import VerifiedBadge from '../../components/ui/VerifiedBadge';
import AccountSwitcher from '../../components/ui/AccountSwitcher';
import { useTranslation } from 'react-i18next';
import { useAuth } from '../../context/AuthContext';
import { getSafeCity } from '../../utils/cityUtils';
import { stateToCountry } from '../../utils/locationUtils';
import { useBackgroundLocation } from '../../hooks/useBackgroundLocation';
import LocationBanner from '../../components/ui/LocationBanner';
import { reviveClientProposals } from '../../context/ClientProposalContext';
import { PROVIDER_CATEGORIES, NON_MUSICIAN_GENRES, CATEGORY_DETAIL_FIELDS, genreMatches } from '../../constants/providerCategories';

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
  duration_seconds: number | null;
  video_start_seconds: number | null;
}

const { width } = Dimensions.get('window');
// Petición real (2026-09-03): "está más reducido... que esté un poco más
// casi a la orilla" (bajado primero a 16) — "lo puedes hacer un poco más
// a la orilla también" (segunda vuelta, bajado a 14) — margen de pantalla
// del Explorador, antes SPACING.xl (24px cada lado). Local a esta
// pantalla, no se toca el token global SPACING.xl (eso afectaría TODAS
// las demás pantallas de la app).
const H_PAD = 14;
const CARD_W = width - H_PAD * 2;
const FEAT_W = Math.round(width * 0.46);   // tarjetas del carrusel (con peek del siguiente)
const FEAT_H = Math.round(FEAT_W * 0.92);




// NON_MUSICIAN_GENRES y PROVIDER_CATEGORIES ahora vienen de
// src/constants/providerCategories.ts (2026-09-03) — misma lista que usa
// "agregar otro proveedor", para que Explorador nunca vuelva a mostrar
// categorías distintas. CATEGORY_ICONS ya no hace falta: los chips ahora
// muestran el emoji + label de PROVIDER_CATEGORIES, no el `type` de la
// tabla `categories`.

// 🎁 Selector de regalo: País → todos sus estados. El filtro de grupos es por
// estado (los nombres no chocan entre MX y US), así que basta con el estado.
const GIFT_COUNTRIES = ['México', 'Estados Unidos', 'Canadá'] as const;
const GIFT_STATES: Record<string, string[]> = {
  'México': [
    'Aguascalientes', 'Baja California', 'Baja California Sur', 'Campeche',
    'Chiapas', 'Chihuahua', 'Ciudad de México', 'Coahuila', 'Colima', 'Durango',
    'Estado de México', 'Guanajuato', 'Guerrero', 'Hidalgo', 'Jalisco',
    'Michoacán', 'Morelos', 'Nayarit', 'Nuevo León', 'Oaxaca', 'Puebla',
    'Querétaro', 'Quintana Roo', 'San Luis Potosí', 'Sinaloa', 'Sonora',
    'Tabasco', 'Tamaulipas', 'Tlaxcala', 'Veracruz', 'Yucatán', 'Zacatecas',
  ],
  'Estados Unidos': [
    'Alabama', 'Alaska', 'Arizona', 'Arkansas', 'California', 'Colorado',
    'Connecticut', 'Delaware', 'Florida', 'Georgia', 'Hawaii', 'Idaho',
    'Illinois', 'Indiana', 'Iowa', 'Kansas', 'Kentucky', 'Louisiana', 'Maine',
    'Maryland', 'Massachusetts', 'Michigan', 'Minnesota', 'Mississippi',
    'Missouri', 'Montana', 'Nebraska', 'Nevada', 'New Hampshire', 'New Jersey',
    'New Mexico', 'New York', 'North Carolina', 'North Dakota', 'Ohio',
    'Oklahoma', 'Oregon', 'Pennsylvania', 'Rhode Island', 'South Carolina',
    'South Dakota', 'Tennessee', 'Texas', 'Utah', 'Vermont', 'Virginia',
    'Washington', 'West Virginia', 'Wisconsin', 'Wyoming',
  ],
  'Canadá': [
    'Alberta', 'British Columbia', 'Manitoba', 'New Brunswick',
    'Newfoundland and Labrador', 'Northwest Territories', 'Nova Scotia',
    'Nunavut', 'Ontario', 'Prince Edward Island', 'Quebec',
    'Saskatchewan', 'Yukon',
  ],
};

export default function HomeScreen({ navigation, route }: any) {
  const { t, i18n } = useTranslation();
  const { detectedCity, safeState, safeCountry, detectedState: gpsState } = useAuth();
  useBackgroundLocation(); // GPS en vivo — actualiza client_locations en background
  const hour = new Date().getHours();
  const greeting = hour < 12
    ? t('home.greeting_morning')
    : hour < 19
    ? t('home.greeting_afternoon')
    : t('home.greeting_evening');
  const [groups, setGroups] = useState<any[]>([]);
  const [filtered, setFiltered] = useState<any[]>([]);
  // 2026-09-03 — antes se leían de la tabla `categories` en vivo (raíces
  // desordenadas/duplicadas, "Comida" ni existía como fila) — ahora usa
  // PROVIDER_CATEGORIES, la MISMA lista que "agregar otro proveedor"
  // (src/constants/providerCategories.ts), para que nunca se desincronicen.
  // selectedCategoryId guarda el `key` de PROVIDER_CATEGORIES, no un uuid.
  const [selectedCategoryId, setSelectedCategoryId] = useState<string | null>(null);
  // 2026-09-16 — petición real: "cuando le aprieto a grupos musicales no
  // salen todas los géneros como sale en la web". El chip de categoría ya
  // filtraba por TODOS los géneros de golpe (grupo=58 géneros mezclados);
  // esta es la lista de géneros DENTRO de la categoría activa (Banda,
  // Mariachi, Sierreño...), igual que el <select> agrupado de la web.
  // null = "todos los de la categoría" (comportamiento de siempre).
  const [selectedGenre, setSelectedGenre] = useState<string | null>(null);
  // 2026-09-05 — sub-filtros dentro de una categoría (ej. Renta: qué
  // renta) usando category_details. Keyed por field.key, valores = chips
  // prendidos de ese campo. Se limpia cada vez que cambia la categoría.
  const [categoryFilterSelections, setCategoryFilterSelections] = useState<Record<string, string[]>>({});
  // 2026-09-05 — valores que los proveedores de esta categoría ya usaron
  // en su propio perfil (sql/624 get_category_field_values) — se ofrecen
  // como filtro extra en cuanto existan, sin que nadie los dé de alta a mano.
  const [communityFilterValues, setCommunityFilterValues] = useState<Record<string, string[]>>({});
  // sql/585 (Fase 1) — contexto de "agregar otro proveedor a mi evento":
  // llega vía route.params desde EventCategoryPickerScreen. presetGenres es
  // un filtro EXACTO (nombres reales de categories.name), independiente del
  // sistema de chips por categoría raíz — no lo reemplaza, solo tiene prioridad
  // cuando está presente.
  const [eventCtx, setEventCtx] = useState<{ eventId: string; eventDate: string | null; eventAddress: string | null } | null>(null);
  const [presetGenres, setPresetGenres] = useState<string[] | null>(null);
  const [presetCategoryLabel, setPresetCategoryLabel] = useState<string | null>(null);
  const [search, setSearch] = useState('');
  // sql/605 — petición real (2026-09-03): cuando una categoría (Payasos,
  // Comida, etc.) no tiene proveedores todavía, botón "avísame" que crea
  // un lead para el admin (con el teléfono del cliente) en vez de dejar
  // al cliente en una pantalla vacía sin nada que hacer.
  const [interestSentFor, setInterestSentFor] = useState<string | null>(null);
  const [sendingInterest, setSendingInterest] = useState(false);
  const [profile, setProfile] = useState<any>(null);
  const [locationMode, setLocationMode] = useState<'home' | 'here'>('home');
  // [Corregido 2026-09-13] El banner de "pareces estar en otro estado" se
  // quedaba pegado en pantalla para siempre — su condición de visibilidad
  // nunca revisaba si el usuario ya había elegido "Aquí"/"mi casa", solo
  // comparaba profile.state vs GPS (que no cambian al presionar el botón).
  // Los botones sí funcionaban (recargaban con el filtro correcto), pero
  // parecía que "no hacían nada" porque el aviso nunca desaparecía.
  const [locationBannerDismissed, setLocationBannerDismissed] = useState(false);
  // 🎁 Modo regalo: explorar grupos de otra ciudad para regalar (o contratar a distancia).
  // Todo va detrás de giftMode → cuando está apagado, el Home queda idéntico.
  const [giftMode,    setGiftMode]    = useState(false);
  const [giftState,   setGiftState]   = useState<string | null>(null);
  const [giftCity,    setGiftCity]    = useState<string | null>(null);
  const [citySelOpen,    setCitySelOpen]    = useState(false);
  const [citySelCountry, setCitySelCountry] = useState<string>('México');
  const [groupHasActiveAds, setGroupHasActiveAds] = useState(false);
  const [nearbyCity, setNearbyCity] = useState<string | null>(null);
  const [locationLoading, setLocationLoading] = useState(false);
  const [unreadCount, setUnreadCount] = useState(0);
  const [liveEvent, setLiveEvent] = useState<any>(null);
  const [pendingPayment, setPendingPayment] = useState<any>(null);
  const [paymentFailed, setPaymentFailed] = useState<any>(null);
  const [pendingQuotes, setPendingQuotes] = useState<any[]>([]);
  const [myOpenRequests, setMyOpenRequests] = useState<any[]>([]);
  const [promotions, setPromotions] = useState<Promotion[]>([]);
  const [bannerAds, setBannerAds] = useState<any[]>([]);
  const [currentAdIndex, setCurrentAdIndex] = useState(0);
  const [bannerImgError, setBannerImgError] = useState(false);
  const [adMuted, setAdMuted] = useState(false);
  const isFocused = useIsFocused();
  const [sponsoredGroupIds, setSponsoredGroupIds] = useState<Set<string>>(new Set());
  const [cityDemand, setCityDemand] = useState<any>(null);
  const [topRecs,          setTopRecs]          = useState<any[]>([]);
  const [refreshing, setRefreshing] = useState(false);
  const [demandVisible, setDemandVisible] = useState(true);
  const demandShown     = useRef(false);
  const headerOpacity   = useRef(new Animated.Value(0)).current;
  const adFade          = useRef(new Animated.Value(1)).current;
  const demandFade      = useRef(new Animated.Value(1)).current;

  useEffect(() => {
    fetchData();
    fetchPromotions();
    Animated.timing(headerOpacity, { toValue: 1, duration: 500, useNativeDriver: true }).start();
  }, []);

  // sql/585 (Fase 1) — llega desde EventCategoryPickerScreen (o directo desde
  // BookingScreen "agregar otro proveedor"). Puramente aditivo: si no hay
  // params, eventCtx/presetGenres quedan null y el Home se comporta idéntico
  // a como se comportaba antes de esta fase.
  useEffect(() => {
    const p = route?.params;
    if (p?.eventId) {
      setEventCtx({ eventId: p.eventId, eventDate: p.eventDate ?? null, eventAddress: p.eventAddress ?? null });
    }
    if (p?.categoryGenres) {
      setPresetGenres(p.categoryGenres);
      setPresetCategoryLabel(p.categoryLabel ?? null);
      setSelectedCategoryId(null);
    }
    // Hallazgo real de auditoría (2026-09-04): React Navigation FUSIONA
    // params nuevos con los existentes en vez de reemplazarlos — sin este
    // setParams, eventId/categoryGenres quedarían pegados en route.params
    // para siempre después del primer uso, y el banner "Agregando a tu
    // evento" reaparecería en cualquier visita normal futura a Explorar
    // (incluso sin venir de "agregar otro proveedor"). Se limpian los
    // params ya consumidos, dejando el estado local (eventCtx/presetGenres)
    // como única fuente de verdad durante esta sesión de pantalla.
    if (p?.eventId || p?.categoryGenres) {
      navigation.setParams({ eventId: undefined, eventDate: undefined, eventAddress: undefined, categoryGenres: undefined, categoryLabel: undefined });
    }
  }, [route?.params?.eventId, route?.params?.categoryGenres, route?.params?.categoryLabel]);

  const clearPresetCategory = () => { setPresetGenres(null); setPresetCategoryLabel(null); };
  // Mismo hallazgo: sin esto, el banner de evento nunca se podía cerrar —
  // quedaba visible el resto de la sesión de la app una vez usado.
  const clearEventCtx = () => { setEventCtx(null); clearPresetCategory(); };

  // sql/605 — categoría activa (chip normal o preset de "agregar otro
  // proveedor"), null si se está viendo "Todos" o buscando por texto.
  // Se usa para decidir cuándo mostrar el botón "avísame" en resultados
  // vacíos, y qué mandar a la fila de interés.
  const activeCategoryContext = (): { label: string; genres: string[] } | null => {
    if (presetGenres && presetCategoryLabel) return { label: presetCategoryLabel, genres: presetGenres };
    if (selectedCategoryId) {
      const cat = PROVIDER_CATEGORIES.find(c => c.key === selectedCategoryId);
      if (cat) {
        if (selectedGenre) return { label: selectedGenre, genres: [selectedGenre] };
        return { label: t(cat.labelKey), genres: cat.genres };
      }
    }
    return null;
  };

  const handleRequestCategoryInterest = async () => {
    const ctx = activeCategoryContext();
    if (!ctx || sendingInterest) return;
    setSendingInterest(true);
    try {
      const activeState = giftMode && giftState ? giftState : (locationMode === 'here' && gpsState ? gpsState : safeState);
      const { data, error } = await supabase.rpc('request_category_interest', {
        p_category_label: ctx.label,
        p_genres: ctx.genres,
        p_city: nearbyCity ?? null,
        p_state: activeState ?? null,
      });
      if (!error && (data as any)?.ok) {
        setInterestSentFor(ctx.label);
      } else {
        Alert.alert(t('common.error'), t('home.interestErrorBody'));
      }
    } catch {
      Alert.alert(t('common.error'), t('home.interestErrorBody'));
    } finally {
      setSendingInterest(false);
    }
  };

  useEffect(() => {
    const unsubscribe = navigation.addListener('focus', () => {
      fetchUnreadCount();
      fetchData();
    });
    return unsubscribe;
  }, [navigation]);

  // Re-cargar grupos cuando el usuario cambia entre "Aquí" y "Mi casa"
  const locationModeInitialized = useRef(false);
  useEffect(() => {
    if (!locationModeInitialized.current) { locationModeInitialized.current = true; return; }
    fetchData();
  }, [locationMode]);

  // 🎁 Re-cargar grupos al cambiar la ciudad del modo regalo
  const giftInitialized = useRef(false);
  useEffect(() => {
    if (!giftInitialized.current) { giftInitialized.current = true; return; }
    fetchData();
  }, [giftMode, giftState]);

  const openGiftCitySelector = () => setCitySelOpen(true);

  const pickGiftState = (stateName: string) => {
    setGiftState(stateName);
    setGiftCity(stateName);
    setGiftMode(true);
    setCitySelOpen(false);
  };
  const exitGiftMode = () => {
    setGiftMode(false);
    setGiftState(null);
    setGiftCity(null);
  };

  // Registrar impresión cada vez que cambia el anuncio visible (fire-and-forget)
  useEffect(() => {
    if (bannerAds.length === 0) return;
    const ad = bannerAds[currentAdIndex];
    if (ad?.id) supabase.rpc('track_ad_impression', { p_ad_id: ad.id }).then(() => {});
  }, [currentAdIndex, bannerAds.length]);

  // Carousel automático para imágenes — 5 s por defecto (o duration_seconds).
  // Videos: no hay timer aquí; el carousel avanza vía onEnd del VideoPlayer
  // cuando el video termina de reproducirse completamente.
  useEffect(() => {
    const list: any[] = bannerAds.length > 0 ? bannerAds : promotions;
    const total = list.length;
    if (total <= 1) return;
    const current = list[currentAdIndex % total];
    if (current?.media_type === 'video') return;
    const secs = current?.duration_seconds ?? 5;
    const timer = setTimeout(() => {
      Animated.timing(adFade, { toValue: 0, duration: 280, useNativeDriver: true }).start(() => {
        setCurrentAdIndex(prev => (prev + 1) % total);
        setBannerImgError(false);
        Animated.timing(adFade, { toValue: 1, duration: 280, useNativeDriver: true }).start();
      });
    }, secs * 1000);
    return () => clearTimeout(timer);
  }, [bannerAds.length, promotions.length, currentAdIndex]);



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

  // 2026-09-05 — al cambiar de categoría, los sub-filtros de la categoría
  // anterior (ej. "Brincolines" de Renta) no deben quedarse pegados al
  // entrar a Comida.
  useEffect(() => {
    setCategoryFilterSelections({});
    setSelectedGenre(null);
  }, [selectedCategoryId]);

  // 2026-09-05 — trae, por cada campo chips/multiChips de la categoría
  // elegida, los valores que otros proveedores ya usaron (sql/624).
  useEffect(() => {
    const fields = (selectedCategoryId ? CATEGORY_DETAIL_FIELDS[selectedCategoryId] : null) ?? [];
    const chipFields = fields.filter(f => f.type === 'chips' || f.type === 'multiChips');
    if (chipFields.length === 0) { setCommunityFilterValues({}); return; }
    let cancelled = false;
    (async () => {
      const entries = await Promise.all(chipFields.map(async field => {
        const { data } = await supabase.rpc('get_category_field_values', { p_category_key: selectedCategoryId, p_field_key: field.key });
        return [field.key, (data ?? []).map((r: any) => r.value)] as [string, string[]];
      }));
      if (!cancelled) setCommunityFilterValues(Object.fromEntries(entries));
    })();
    return () => { cancelled = true; };
  }, [selectedCategoryId]);

  useEffect(() => {
    let result = groups;
    if (presetGenres) {
      // Filtro de categoría real (sql/585, "agregar otro proveedor") — nombre
      // exacto de groups.genre, tiene prioridad sobre el chip raíz.
      // 2026-09-26 — un grupo puede registrar mas de un estilo separado por
      // "/" ("Norteño/Sierreño", proveedor real). La comparacion exacta lo
      // dejaba invisible en el Explorador; el helper general revisa cada
      // estilo por separado (mismo criterio que genre_matches del servidor).
      result = result.filter(g => presetGenres.some(pg => genreMatches(g.genre, pg)));
    } else if (selectedCategoryId) {
      // 2026-09-03 — mismas categorías que "agregar otro proveedor"
      // (PROVIDER_CATEGORIES), ya no se leen de la tabla `categories`.
      const cat = PROVIDER_CATEGORIES.find(c => c.key === selectedCategoryId);
      if (cat) {
        // 2026-09-16 — dentro del chip de categoría, un género específico
        // (Sierreño, Banda...) filtra exacto; sin elegir uno, se comporta
        // como siempre (todos los géneros de la categoría).
        if (selectedGenre) result = result.filter(g => genreMatches(g.genre, selectedGenre));
        else result = result.filter(g => cat.genres.some(cg => genreMatches(g.genre, cg)));
      }
    }
    // 2026-09-05 — sub-filtros por category_details ("qué tiene" el
    // proveedor: items_needed de Renta, tipo de show de Payasos, etc.).
    // Mismo campo = OR (Brincolines + Toro mecánico = cualquiera de los
    // dos); campos distintos = AND (debe cumplir ambos).
    const activeFilterEntries = Object.entries(categoryFilterSelections).filter(([, vals]) => vals.length > 0);
    if (activeFilterEntries.length > 0) {
      result = result.filter(g => activeFilterEntries.every(([fieldKey, vals]) => {
        const gv = g.category_details?.[fieldKey];
        if (Array.isArray(gv)) return vals.some(v => gv.includes(v));
        return vals.includes(gv);
      }));
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
  }, [groups, selectedCategoryId, selectedGenre, presetGenres, search, nearbyCity, categoryFilterSelections]);

  const onRefresh = async () => {
    setRefreshing(true);
    await Promise.all([fetchData(), fetchPromotions()]);
    setRefreshing(false);
  };

  const fetchData = async () => {
    let userCity: string | null = null;
    // Estado del usuario: viene del contexto (persiste entre sesiones)
    const detectedState = safeState;
    // Si el usuario eligió ver grupos "aquí" (viajando), usa el GPS; si no, su estado de perfil.
    const activeGroupState = giftMode && giftState
      ? giftState
      : (locationMode === 'here' && gpsState ? gpsState : safeState);
    // 🎁 En modo regalo filtramos SOLO por estado (omitimos país) → sirve MX y US.
    const activeGroupCountry = giftMode ? null : safeCountry;
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
        .select('*, group:groups(id, name, genre, city, profile_image, owner_id), quote:quotes(duration_hours, overtime_1h_price, overtime_2h_price, overtime_3h_price)')
        .eq('client_id', sessionData.session.user.id)
        .eq('status', 'in_progress')
        .limit(1)
        .maybeSingle();
      setLiveEvent(live);

      // Reserva aceptada/pendiente sin pago (incluye 'accepted' que es el estado post-cotización)
      const { data: pendPay } = await supabase
        .from('reservations')
        .select('*, group:groups(id, name, profile_image)')
        .eq('client_id', sessionData.session.user.id)
        .in('status', ['accepted', 'confirmed', 'pending_payment'])
        .not('payment_status', 'in', '("paid","deposit_paid","fully_paid")')
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

      // Solicitudes express/programadas enviadas y aún abiertas
      const { data: myReqData } = await supabase
        .from('event_requests')
        // Auditoria 2026-09-27: aqui se pedia `request_type`, que NO existe en
        // event_requests ni en ninguna tabla del esquema. PostgREST responde
        // 400/42703 ("column ... does not exist") y se pierde TODA la consulta,
        // no solo esa columna -> `myOpenRequests` quedaba siempre vacio y el
        // banner "Tu solicitud esta activa" nunca se mostraba.
        .select('id, event_type, genre, created_at, expires_at')
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
    if (safeCountry)   bannerParams.p_country = safeCountry.toLowerCase();
    const { data: adsData } = await supabase.rpc('get_active_banner_ads', bannerParams);
    if (adsData && (adsData as any[]).length > 0) {
      const paid = (adsData as any[]).filter((a: any) => !a.is_free);
      const free = (adsData as any[]).filter((a: any) => a.is_free);
      // Paid always first; all free ads follow (admin creates them deliberately)
      setBannerAds([...paid, ...free]);
      setCurrentAdIndex(0);
    } else {
      // Sin anuncios activos → limpiar cualquier anuncio previo (evita foto fantasma)
      setBannerAds([]);
    }

    // Grupos patrocinados
    const sponParams: Record<string, any> = { p_city: userCity };
    if (activeGroupState)   sponParams.p_state   = activeGroupState;
    if (activeGroupCountry) sponParams.p_country = activeGroupCountry.toLowerCase();
    const { data: sponData } = await supabase.rpc('get_sponsored_group_ids', sponParams);
    const sponSet = new Set<string>((sponData ?? []).map((s: any) => s.group_id));
    setSponsoredGroupIds(sponSet);

    // Grupos rankeados por estado (arquitectura País → Estado).
    // p_city=null + p_state=safeState → todos los grupos del estado + nacionales.
    let rawGroups: any[] = [];
    const groupParams: Record<string, any> = { p_city: null, p_limit: 80 };
    if (activeGroupState)   groupParams.p_state   = activeGroupState;
    if (activeGroupCountry) groupParams.p_country = activeGroupCountry.toLowerCase();
    const { data: stateData } = await supabase.rpc('get_groups_ranked_by_city', groupParams);
    if (stateData && (stateData as any[]).length > 0) {
      rawGroups = stateData as any[];
    } else if (giftMode) {
      // 🎁 En regalo respetamos el estado elegido aunque no tenga grupos (SIN fallback a todos)
      rawGroups = [];
    } else {
      // Fallback (flujo normal): sin estado — filtra solo por país
      const fallbackParams: Record<string, any> = { p_city: null, p_limit: 80 };
      if (activeGroupCountry) fallbackParams.p_country = activeGroupCountry.toLowerCase();
      const { data: allData } = await supabase.rpc('get_groups_ranked_by_city', fallbackParams);
      rawGroups = (allData as any[]) ?? [];
    }
    // El RPC filtra por estado y país en DB; grupos con state/country=null son nacionales y siempre se incluyen.
    // En regalo actualizamos siempre (aunque venga vacío) para limpiar la lista al cambiar de estado.
    if (rawGroups.length > 0 || giftMode) {
      // 2026-09-05 — category_details no lo regresa get_groups_ranked_by_city
      // (RPC de ranking, no se toca); se pide aparte y se mezcla, mismo
      // patrón que sponSet arriba. Necesario para los sub-filtros de
      // Explorador (Renta: qué renta, Payasos: tipo de show, etc.).
      const catDetailsMap = new Map<string, any>();
      if (rawGroups.length > 0) {
        const { data: catData } = await supabase
          .from('groups')
          .select('id, category_details')
          .in('id', rawGroups.map(g => g.id));
        (catData ?? []).forEach((row: any) => catDetailsMap.set(row.id, row.category_details));
      }
      const scored = rawGroups.map(g => ({
        ...g,
        is_sponsored: sponSet.has(g.id),
        category_details: catDetailsMap.get(g.id) ?? {},
      }));
      setGroups(scored);
      setFiltered(scored);
    }

    // Grupos que pagaron para aparecer como recomendados (hasta 20)
    // get_active_recommendations devuelve: id, name, city, genre, rating,
    // profile_image, is_verified (actualizado en 170_ad_monetization_ordering.sql)
    const recParams: Record<string, any> = { p_city: null, p_limit: 20 };
    if (activeGroupState)   recParams.p_state   = activeGroupState;
    if (activeGroupCountry) recParams.p_country = activeGroupCountry.toLowerCase();
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
      .select('id, title, subtitle, tag, button_text, link_type, link_id, media_url, media_type, media_offset, duration_seconds, video_start_seconds')
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
    // Enlace externo del botón (anuncios gratis del admin y futuros con link_url)
    if (ad.link_type === 'url' && ad.link_url) {
      WebBrowser.openBrowserAsync(ad.link_url, {
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
  const interleave = (list: any[]) => {
    const now = Date.now();
    const isBidActive = (g: any) =>
      (g.bid_amount ?? 0) > 0 && g.bid_ends_at && new Date(g.bid_ends_at).getTime() > now;
    const isPromoted = (g: any) => isBidActive(g) || (g.boost_score ?? 0) > 0;

    const promoted: any[] = [];
    const organic: any[] = [];
    for (const g of list) {
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
  };

  const interleavedGroups = useMemo(() => {
    // Petición real (2026-09-03): "que salga todo... pero primero los
    // músicos" — en la vista "Todos los grupos" (sin filtro de categoría),
    // los grupos musicales/solista/DJ/luz-sonido van primero, y el resto
    // (Comediante, Payasos, Comida, Renta, Fotógrafos) después — cada
    // bloque conserva su propio intercalado de pagado/orgánico, así que
    // un anuncio pagado de un Comida no compite por posición contra un
    // grupo musical orgánico. Constante NON_MUSICIAN_GENRES a nivel de
    // módulo (arriba) — la reutiliza también el deck de Destacados abajo.
    const musicians: any[] = [];
    const others: any[] = [];
    for (const g of filtered) {
      (NON_MUSICIAN_GENRES.has(g.genre) ? others : musicians).push(g);
    }
    return [...interleave(musicians), ...interleave(others)];
  }, [filtered]);

  return (
    <View style={styles.container}>
      <Particles />
      <SafeAreaView edges={['top']} style={{ flex: 1 }}>
        {/* HEADER */}
        <Animated.View style={[styles.header, { opacity: headerOpacity }]}>
          <View>
            <Text style={styles.logoText}>Darice<Text style={styles.logoGreen}>fy</Text></Text>
          </View>
          <View style={{ flexDirection: 'row', gap: 8 }}>
            {/* 🔀 Cambiar rápido a otra cuenta ya guardada (petición real
                2026-09-18: "irme rápido a la cuenta del cliente de Lala"). */}
            <AccountSwitcher />
            <Pressable style={styles.iconBtn} onPress={() => navigation.navigate('Notifications')}>
              <Bell size={18} color={COLORS.muted2} />
              {unreadCount > 0 && (
                <View style={styles.notifDot}>
                  <Text style={styles.notifDotText}>{unreadCount > 99 ? '99+' : unreadCount}</Text>
                </View>
              )}
            </Pressable>
          </View>
        </Animated.View>

        {/* LIVE EVENT BANNER */}
        {liveEvent && (
          <Pressable
            style={styles.liveBanner}
            onPress={() => navigation.navigate('EventTimer', { reservation: liveEvent, readOnly: true, userRole: 'client' })}
          >
            <LinearGradient
              colors={['rgba(0,230,118,0.15)', 'rgba(0,200,83,0.05)']}
              style={StyleSheet.absoluteFill}
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
              style={StyleSheet.absoluteFill}
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
            onPress={() => navigation.navigate('QuotePayment', { reservation: pendingPayment })}
          >
            <LinearGradient
              colors={['rgba(255,152,0,0.18)', 'rgba(255,152,0,0.05)']}
              style={StyleSheet.absoluteFill}
              start={{ x: 0, y: 0 }} end={{ x: 1, y: 1 }}
            />
            <Text style={styles.payBannerIcon}>⚡</Text>
            <View style={{ flex: 1 }}>
              <Text style={styles.payBannerTitle}>Pago pendiente</Text>
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
          // Hallazgo real con captura (2026-09-03): con 2+ solicitudes SIEMPRE
          // decía "han cotizado" (pasado, como si el proveedor ya hubiera
          // respondido) aunque ninguna tuviera status='quoted' todavía — es
          // decir, el título decía "en espera" pero el texto de abajo decía
          // lo contrario. Ahora el texto también distingue si de verdad ya
          // respondieron o siguen en espera, igual que ya hacía el título.
          const groupText = count === 1
            ? `${first.group?.name ?? 'Grupo'} · ${first.duration_hours}h`
            : hasResponse
              ? `${first.group?.name ?? 'Grupo'} y ${count - 1} más han cotizado`
              : `${first.group?.name ?? 'Grupo'} y ${count - 1} más — esperando respuesta`;
          // Con respuesta → abrir el CARRUSEL tipo Uber (2026-07-11); sin
          // respuesta aún → detalle/lista como antes.
          const onPress = hasResponse
            ? () => { void reviveClientProposals(); }
            : count === 1
              ? () => navigation.navigate('ClientQuoteDetail', { quoteId: first.id })
              // Hallazgo real (2026-09-03): ReservationsScreen solo reconoce
              // initialTab === 'pendientes' (ver línea `const initialTab =
              // route?.params?.initialTab === 'pendientes' ? ...`) — 'quotes'
              // no calzaba con nada y caía siempre al tab por defecto
              // ("eventos"), aunque las cotizaciones en espera viven en
              // "pendientes". "Ver todas" mandaba al lugar equivocado.
              : () => navigation.navigate('ClientReservations', { initialTab: 'pendientes' });
          return (
            <Pressable style={styles.quoteBanner} onPress={onPress}>
              <LinearGradient
                colors={['rgba(66,133,244,0.18)', 'rgba(66,133,244,0.05)']}
                style={StyleSheet.absoluteFill}
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
          const count = myOpenRequests.length;
          // El tipo NO es un dato de la fila: toda solicitud de `event_requests`
          // nace del canal expres (OpenRequestScreen) o de la guiada, que es "el
          // mismo flujo express" (docs/FLUJO_EVENTOS_EXPRESS_Y_PROGRAMADOS.md, 1).
          // Lo programado vive en la tabla `quotes`, no aqui. Por eso la rama
          // "Programada" era inalcanzable y dependia de una columna inexistente.
          const typeLabel = 'Express';
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
                style={StyleSheet.absoluteFill}
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
                placeholder={t('home.search_placeholder')}
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
              <Text style={styles.nearbyText}>{t('home.section_near')} · {nearbyCity}</Text>
              <Pressable onPress={() => setNearbyCity(null)}>
                <X size={13} color={COLORS.muted2} />
              </Pressable>
            </View>
          )}

          {/* BANNER UBICACIÓN — solo si el usuario está viajando fuera de su estado
              Y todavía no ha elegido "Aquí"/"mi casa" en esta visita. */}
          {!locationBannerDismissed && profile?.state && gpsState && profile.state.toLowerCase() !== gpsState.toLowerCase() && (
            <LocationBanner
              profileState={profile.state}
              detectedState={gpsState}
              onUseHere={() => { setLocationMode('here'); setLocationBannerDismissed(true); }}
              onUseHome={() => { setLocationMode('home'); setLocationBannerDismissed(true); }}
            />
          )}

          {/* ⚡ Express + 🌎 Otra ciudad — dos formas de empezar */}
          {!giftMode && !search && !selectedCategoryId && (
            <View style={styles.actionRow}>
              <Pressable
                style={({ pressed }) => [styles.actionCard, styles.actionCardExpress, pressed && styles.actionCardPressed]}
                onPress={() => navigation.navigate('GuidedRequest')}
              >
                <View style={styles.actionTitleRow}>
                  <Text style={styles.actionTitle}>Express</Text>
                  <View style={styles.actionChipGold}>
                    <Zap size={10} color={COLORS.gold} />
                    <Text style={styles.actionChipGoldTx}>HOY</Text>
                  </View>
                </View>
                <Text style={styles.actionSub}>Recibe propuestas de grupos hoy mismo</Text>
                <View style={styles.actionCta}>
                  <Text style={styles.actionCtaTx}>Solicitar</Text>
                  <ChevronRight size={15} color={COLORS.text} />
                </View>
              </Pressable>

              <Pressable
                style={({ pressed }) => [styles.actionCard, styles.actionCardCity, pressed && styles.actionCardPressed]}
                onPress={openGiftCitySelector}
              >
                <View style={styles.actionTitleRow}>
                  <Text style={styles.actionTitle}>Otra ciudad</Text>
                  <Text style={styles.actionEmoji}>🌎</Text>
                </View>
                <Text style={styles.actionSub}>Explora o regala en otro estado</Text>
                <View style={styles.actionCta}>
                  <Text style={styles.actionCtaTx}>Explorar</Text>
                  <ChevronRight size={15} color={COLORS.text} />
                </View>
              </Pressable>
            </View>
          )}
          {giftMode && (
            <View style={styles.giftBanner}>
              <Text style={styles.giftEntryEmoji}>🌎</Text>
              <View style={{ flex: 1 }}>
                <Text style={styles.giftBannerTitle}>Explorando {giftCity ?? giftState}</Text>
                <Text style={styles.giftBannerSub}>Grupos disponibles en esta ciudad</Text>
              </View>
              <Pressable onPress={openGiftCitySelector} hitSlop={8}>
                <Text style={styles.giftBannerAction}>Cambiar</Text>
              </Pressable>
              <Pressable onPress={exitGiftMode} hitSlop={8} style={{ marginLeft: 12 }}>
                <X size={16} color={COLORS.muted2} />
              </Pressable>
            </View>
          )}


          {/* 🎁 Selector de país/estado (modo regalo) */}
          <Modal visible={citySelOpen} transparent animationType="slide" onRequestClose={() => setCitySelOpen(false)}>
            <Pressable style={styles.citySelBackdrop} onPress={() => setCitySelOpen(false)} />
            <View style={styles.citySelSheet}>
              <View style={styles.citySelHead}>
                <Text style={styles.citySelTitle}>¿En qué estado es el regalo?</Text>
                <Pressable onPress={() => setCitySelOpen(false)} hitSlop={8}>
                  <X size={20} color={COLORS.muted2} />
                </Pressable>
              </View>
              <Text style={styles.citySelHint}>Elige país y estado; verás los grupos disponibles ahí.</Text>
              <View style={styles.countryTabs}>
                {GIFT_COUNTRIES.map(co => (
                  <Pressable
                    key={co}
                    style={[styles.countryTab, citySelCountry === co && styles.countryTabActive]}
                    onPress={() => setCitySelCountry(co)}
                  >
                    <Text style={[styles.countryTabText, citySelCountry === co && styles.countryTabTextActive]}>
                      {co}
                    </Text>
                  </Pressable>
                ))}
              </View>
              <ScrollView style={{ maxHeight: 340 }} keyboardShouldPersistTaps="handled">
                {(GIFT_STATES[citySelCountry] ?? []).map((st, i) => (
                  <Pressable key={`${st}-${i}`} style={styles.cityRow} onPress={() => pickGiftState(st)}>
                    <MapPin size={15} color={COLORS.green} />
                    <Text style={styles.cityRowText}>{st}</Text>
                  </Pressable>
                ))}
              </ScrollView>
            </View>
          </Modal>

          {/* DESTACADOS · RECOMENDADOS · POPULARES — carruseles del estado del
              cliente. Petición real (2026-09-03): "cuando cambio de
              categorías se quitan porque solo aparecen los de los grupos...
              cada proveedor si paga aparecerá en su categoría" — antes
              dependía de `!selectedCategoryId` y usaba `groups` (sin
              filtrar), así que al elegir una categoría (Comida, Payasos,
              etc.) esta fila desaparecía por completo — un Comida que
              pagara por patrocinio/boost nunca se veía destacado dentro de
              su propia categoría, solo en "Todos". Ahora usa `filtered`
              (ya trae aplicado el chip de categoría O el preset de
              "agregar otro proveedor") y también escala `topRecs` (pagado,
              sql/170) al mismo filtro de genre — así si el cliente entra a
              Comida, ve destacados/recomendados/populares SOLO de Comida.
              2026-09-03 (aclaración del mismo pedido): en "Todos" (sin
              categoría) esta fila muestra SOLO músicos — el resto de
              categorías ya tiene su propio Destacados/Recomendados al
              entrar a esa categoría específica, no hace falta mezclarlos
              aquí también. El grid de abajo ("Todos los grupos") sigue
              mostrando TODAS las categorías, eso no cambia. */}
          {!search && !nearbyCity && (() => {
            const activeGenres = presetGenres ?? (selectedCategoryId ? (selectedGenre ? [selectedGenre] : (PROVIDER_CATEGORIES.find(c => c.key === selectedCategoryId)?.genres ?? null)) : null);
            const real = filtered.filter((g: any) => !g._is_mock && (activeGenres || !NON_MUSICIAN_GENRES.has(g.genre)));
            const byRating = [...real].sort((a: any, b: any) => (b.rating ?? 0) - (a.rating ?? 0));

            const sponsored = real.filter((g: any) => g.is_sponsored || (g.boost_score ?? 0) > 0);
            const recReal   = topRecs.filter((r: any) =>
              !!r.id && (activeGenres ? activeGenres.includes(r.genre) : !NON_MUSICIAN_GENRES.has(r.genre))
            );

            let destacados: any[], recomendados: any[], populares: any[];

            // 2026-09-17 — bug real reportado: "hay unos que he agregado y
            // se ponen como en recomendados o destacados, quítalos porque
            // yo no los he puesto". Antes, si no había al menos 3 grupos
            // REALMENTE patrocinados/recomendados, se rellenaba Destacados
            // y Recomendados con cualquier grupo del estado ordenado por
            // calificación — un grupo recién dado de alta podía terminar
            // en "Destacado" sin que nadie pagara ni lo eligiera. Ahora
            // Destacados/Recomendados SOLO muestran patrocinio/recomendación
            // real, aunque eso signifique menos de 3 (o ninguno — la
            // columna simplemente no aparece, ver `.filter` de abajo).
            // Populares sigue siendo legítimamente "mejor calificados".
            destacados = sponsored.slice(0, 20);
            const destIds = new Set(destacados.map((g: any) => g.id));
            recomendados = recReal.filter((r: any) => !destIds.has(r.id)).slice(0, 20);
            const recIds = new Set(recomendados.map((g: any) => g.id));
            populares = byRating.filter((g: any) => !destIds.has(g.id) && !recIds.has(g.id)).slice(0, 20);

            // 💎 El Destacado (más caro) va AL CENTRO — el lugar de honor
            const sections = [
              { key: 'reco', label: t('home.section_recommendations'), color: COLORS.green, border: 'rgba(0,230,118,0.5)', grad: ['rgba(0,230,118,0.24)', 'rgba(0,230,118,0.03)'], items: recomendados },
              { key: 'dest', label: t('home.section_featured'),        color: '#E6C25A', border: 'rgba(201,168,76,0.55)', grad: ['rgba(201,168,76,0.28)', 'rgba(201,168,76,0.04)'], items: destacados },
              { key: 'pop',  label: 'Populares',                       color: '#FFFFFF', border: 'rgba(255,255,255,0.28)', grad: ['rgba(255,255,255,0.16)', 'rgba(255,255,255,0.02)'], items: populares },
            ].filter(s => s.items.length > 0);

            if (sections.length === 0) return null;

            // Hallazgo real con captura (2026-09-03): "sigue grande" — el
            // ancho de columna se dividía entre `sections.length` (cuántas
            // de las 3 traían datos), así que con una sola categoría con 1
            // solo grupo (ej. DJ), al haber solo 1 sección con datos, esa
            // columna se estiraba a TODO el ancho de pantalla. El tamaño de
            // tarjeta debe ser fijo (como si siempre hubiera 3 columnas),
            // no repartirse entre las que de casualidad tengan contenido.
            const deckGap = 10;
            const colW = Math.floor((width - H_PAD * 2 - deckGap * 2) / 3);

            return (
              <View style={styles.deckRow}>
                {sections.map(sec => (
                  <View key={sec.key} style={{ width: colW, alignItems: 'center' }}>
                    <LinearGradient
                      colors={sec.grad as any}
                      start={{ x: 0, y: 0 }}
                      end={{ x: 1, y: 1 }}
                      style={[styles.deckLabelChip, { borderColor: sec.border }]}
                    >
                      <Text style={[styles.deckLabel, { color: sec.color }]} numberOfLines={1} adjustsFontSizeToFit minimumFontScale={0.8}>{sec.label}</Text>
                    </LinearGradient>
                    <MiniDeck
                      items={sec.items}
                      navigation={navigation}
                      isGift={giftMode}
                      variant={sec.key}
                      colWidth={colW}
                    />
                  </View>
                ))}
              </View>
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
                    style={styles.promoBanner}
                    onPress={() => isNewAds ? handleAdPress(item) : handlePromoBannerPress(item)}
                  >
                    <View style={styles.promoBannerInner}>
                      {/* Imagen/video de fondo a pantalla completa */}
                      {item.media_type === 'video' && item.media_url ? (
                        <VideoPlayer
                          uri={item.media_url}
                          style={styles.promoBannerBg}
                          contentFit="cover"
                          startTime={item.video_start_seconds ?? 0}
                          // 2026-09-17 — bug real: "el video jala pero
                          // después ya no se reproduce". autoPlay era
                          // literal `true`, así que solo se aplicaba UNA
                          // vez al montar — si el sistema operativo pausaba
                          // el video al salir de foco (llamada, cambiar de
                          // pantalla, apagar pantalla), nada lo volvía a
                          // mandar a reproducir al regresar. Atado a
                          // isFocused reusa el mismo mecanismo que ya
                          // existe en VideoPlayer para pausar/reanudar
                          // cuando el prop autoPlay cambia después del montaje.
                          autoPlay={isFocused}
                          muted={adMuted || !isFocused}
                          loop={total <= 1}
                          onEnd={total > 1 ? () => {
                            Animated.timing(adFade, { toValue: 0, duration: 280, useNativeDriver: true }).start(() => {
                              setCurrentAdIndex(prev => (prev + 1) % total);
                              setBannerImgError(false);
                              Animated.timing(adFade, { toValue: 1, duration: 280, useNativeDriver: true }).start();
                            });
                          } : undefined}
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
                      {/* Gradiente solo en la franja inferior para legibilidad del texto */}
                      <LinearGradient
                        colors={['transparent', 'rgba(0,0,0,0.48)', 'rgba(0,0,0,0.78)']}
                        locations={[0.48, 0.76, 1]}
                        style={styles.promoBannerGrad}
                      />
                      {/* Chip "ANUNCIO" en la esquina superior izquierda */}
                      <View style={styles.promoBannerTagChip}>
                        <Text style={styles.promoBannerTagText}>ANUNCIO</Text>
                      </View>
                      {/* Botón silenciar — solo en anuncios de video */}
                      {item.media_type === 'video' && item.media_url && (
                        <Pressable
                          style={styles.promoBannerMute}
                          onPress={() => setAdMuted(m => !m)}
                          hitSlop={8}
                        >
                          {adMuted
                            ? <VolumeX size={15} color="#fff" />
                            : <Volume2 size={15} color="#fff" />}
                        </Pressable>
                      )}
                      {/* Título, subtítulo y botón (opcional) en la parte inferior */}
                      <View style={styles.promoBannerOverlay}>
                        <View style={{ flex: 1 }}>
                          <Text style={styles.promoBannerTitle} numberOfLines={1}>{item.title}</Text>
                          {item.subtitle ? (
                            <Text style={styles.promoBannerSub} numberOfLines={1}>{item.subtitle}</Text>
                          ) : null}
                        </View>
                        {!!item.button_text && (
                          <Pressable
                            style={styles.promoBannerBtn}
                            onPress={() => isNewAds ? handleAdCtaPress(item) : navigation.navigate('AdvertisingPackages')}
                          >
                            <Text style={styles.promoBannerBtnText}>{item.button_text} →</Text>
                          </Pressable>
                        )}
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


          {/* sql/585 (Fase 1) — banner "agregando a mi evento existente".
              Solo aparece si se llegó con eventId (desde EventCategoryPicker
              o "agregar otro proveedor"); en el uso normal del Home no se
              muestra nada de esto. */}
          {!!eventCtx && (
            <View style={styles.eventCtxBanner}>
              <View style={{ flexDirection: 'row', alignItems: 'flex-start', justifyContent: 'space-between', gap: 8 }}>
                <Text style={[styles.eventCtxBannerText, { flex: 1 }]}>
                  {t('home.eventCtxBanner', {
                    date: eventCtx.eventDate
                      ? new Date(eventCtx.eventDate + 'T12:00:00').toLocaleDateString(i18n.language?.startsWith('en') ? 'en-US' : 'es-MX', { day: 'numeric', month: 'long' })
                      : '—',
                    address: eventCtx.eventAddress ?? '',
                  })}
                </Text>
                {/* Hallazgo de auditoría: sin esto, el banner no se podía
                    cerrar y quedaba pegado en cualquier visita futura al
                    explorador, aunque el cliente ya no estuviera agregando
                    un proveedor. */}
                <Pressable onPress={clearEventCtx} hitSlop={8}>
                  <X size={16} color={COLORS.green} />
                </Pressable>
              </View>
              {!!presetCategoryLabel && (
                <View style={styles.eventCtxChipRow}>
                  <Text style={styles.eventCtxCategoryChip}>{presetCategoryLabel}</Text>
                  <Pressable onPress={clearPresetCategory} hitSlop={8}>
                    <Text style={styles.eventCtxClear}>{t('home.eventCtxClearFilter')}</Text>
                  </Pressable>
                </View>
              )}
            </View>
          )}

          {/* HEADER — SECCIÓN PROGRAMADA */}
          <View style={styles.scheduledHeader}>
            <Text style={styles.scheduledTag}>FECHA PROGRAMADA</Text>
            <Text style={styles.scheduledTitle}>Reserva tu grupo</Text>
          </View>

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
              <Text style={[styles.genreText, selectedCategoryId === null && styles.genreTextActive]}>{t('common.all')}</Text>
            </Pressable>
            {PROVIDER_CATEGORIES.map((cat) => (
              <Pressable
                key={cat.key}
                style={[styles.genreChip, selectedCategoryId === cat.key && styles.genreChipActive]}
                onPress={() => setSelectedCategoryId(cat.key)}
              >
                <Text style={[styles.genreText, selectedCategoryId === cat.key && styles.genreTextActive]}>
                  {t(cat.labelKey)}
                </Text>
              </Pressable>
            ))}
          </ScrollView>

          {/* GÉNEROS de la categoría activa — 2026-09-16, petición real:
              "cuando le aprieto a grupos musicales no salen todas los
              géneros como sale en la web". Mismo criterio que el <select>
              agrupado de la web: elegir la categoría no filtra ya con
              TODOS sus géneros mezclados, primero deja elegir uno exacto
              (o "Todos los géneros" para el comportamiento de siempre). */}
          {selectedCategoryId && !presetGenres && (() => {
            const cat = PROVIDER_CATEGORIES.find(c => c.key === selectedCategoryId);
            if (!cat || cat.genres.length <= 1) return null;
            return (
              <ScrollView
                horizontal
                showsHorizontalScrollIndicator={false}
                contentContainerStyle={styles.genreList}
                style={{ marginTop: -8, marginBottom: 18 }}
              >
                <Pressable
                  style={[styles.genreChip, selectedGenre === null && styles.genreChipActive]}
                  onPress={() => setSelectedGenre(null)}
                >
                  <Text style={[styles.genreText, selectedGenre === null && styles.genreTextActive]}>
                    {t('common.allGenres')}
                  </Text>
                </Pressable>
                {cat.genres.map((g) => (
                  <Pressable
                    key={g}
                    style={[styles.genreChip, selectedGenre === g && styles.genreChipActive]}
                    onPress={() => setSelectedGenre(g)}
                  >
                    <Text style={[styles.genreText, selectedGenre === g && styles.genreTextActive]}>{g}</Text>
                  </Pressable>
                ))}
              </ScrollView>
            );
          })()}

          {/* SUB-FILTROS de la categoría activa — "qué tiene" el proveedor
              (category_details, sql/623). Solo aparece en categorías con
              campos chips/multiChips (Comida/Renta/Payasos/Fotógrafos);
              música (Banda/DJ/etc.) no tiene, así que no cambia nada ahí.
              2026-09-05 — petición real: "que pueda filtrar como en
              Amazon" dentro de Renta (brincolines, toro mecánico...). */}
          {selectedCategoryId && !presetGenres && (() => {
            const fields = (CATEGORY_DETAIL_FIELDS[selectedCategoryId] ?? [])
              .filter(f => f.type === 'chips' || f.type === 'multiChips');
            if (fields.length === 0) return null;
            return (
              <View style={{ marginBottom: 14 }}>
                {fields.map(field => (
                  <View key={field.key} style={{ marginBottom: 10 }}>
                    <Text style={styles.subFilterLabel}>{t(field.labelKey)}</Text>
                    <ScrollView
                      horizontal
                      showsHorizontalScrollIndicator={false}
                      contentContainerStyle={styles.genreList}
                    >
                      {field.options?.map(opt => {
                        const selected = (categoryFilterSelections[field.key] ?? []).includes(opt.key);
                        return (
                          <Pressable
                            key={opt.key}
                            style={[styles.subFilterChip, selected && styles.genreChipActive]}
                            onPress={() => setCategoryFilterSelections(prev => {
                              const cur = prev[field.key] ?? [];
                              const next = cur.includes(opt.key) ? cur.filter(k => k !== opt.key) : [...cur, opt.key];
                              return { ...prev, [field.key]: next };
                            })}
                          >
                            <Text style={[styles.genreText, selected && styles.genreTextActive]}>
                              {t(opt.labelKey)}
                            </Text>
                          </Pressable>
                        );
                      })}
                      {/* Lo que otros proveedores ya escribieron y aún no
                          está en la lista fija (sql/624) — mismo chip,
                          sin traducir (es texto libre). */}
                      {(communityFilterValues[field.key] ?? [])
                        .filter(v => !field.options?.some(o => o.key === v))
                        .map(v => {
                          const selected = (categoryFilterSelections[field.key] ?? []).includes(v);
                          return (
                            <Pressable
                              key={v}
                              style={[styles.subFilterChip, selected && styles.genreChipActive]}
                              onPress={() => setCategoryFilterSelections(prev => {
                                const cur = prev[field.key] ?? [];
                                const next = cur.includes(v) ? cur.filter(k => k !== v) : [...cur, v];
                                return { ...prev, [field.key]: next };
                              })}
                            >
                              <Text style={[styles.genreText, selected && styles.genreTextActive]}>{v}</Text>
                            </Pressable>
                          );
                        })}
                    </ScrollView>
                  </View>
                ))}
              </View>
            );
          })()}

          {/* TODOS LOS GRUPOS — grid 3 columnas */}
          <View style={styles.groupsHeader}>
            <Text style={styles.sectionLabel}>
              {nearbyCity ? `Grupos en ${nearbyCity}` : 'Todos los grupos'}
            </Text>
            <View style={styles.countChip}>
              <Text style={styles.countChipText}>{interleavedGroups.length}</Text>
            </View>
          </View>

          {interleavedGroups.length === 0 ? (() => {
            const ctx = !search ? activeCategoryContext() : null;
            const alreadySent = !!ctx && interestSentFor === ctx.label;
            return (
              <View style={styles.empty}>
                <Text style={styles.emptyEmoji}>🔍</Text>
                <Text style={styles.emptyText}>
                  {ctx ? t('home.noProvidersYet', { category: ctx.label }) : t('common.no_results')}
                </Text>
                <Text style={styles.emptySub}>
                  {ctx ? t('home.noProvidersYetSub') : t('common.try_again')}
                </Text>
                {ctx && (
                  alreadySent ? (
                    <View style={styles.interestSentPill}>
                      <Bell size={13} color={COLORS.green} />
                      <Text style={styles.interestSentText}>{t('home.interestSent')}</Text>
                    </View>
                  ) : (
                    <Pressable
                      style={[styles.interestBtn, sendingInterest && { opacity: 0.6 }]}
                      onPress={handleRequestCategoryInterest}
                      disabled={sendingInterest}
                    >
                      {sendingInterest
                        ? <ActivityIndicator size="small" color={COLORS.bg} />
                        : <Bell size={14} color={COLORS.bg} />}
                      <Text style={styles.interestBtnText}>{t('home.notifyMe')}</Text>
                    </Pressable>
                  )
                )}
              </View>
            );
          })() : (() => {
            const rows: React.ReactNode[] = [];
            for (let i = 0; i < interleavedGroups.length; i += 4) {
              const rowGroups = interleavedGroups.slice(i, i + 4);
              rows.push(
                <View key={`row-${i}`} style={styles.gridRow}>
                  {rowGroups.map((group, ri) => (
                    <GroupGridCard
                      key={group.id}
                      isGift={giftMode}
                      group={group}
                      index={i + ri}
                      navigation={navigation}
                      bidRank={bidRankMap.get(group.id) ?? null}
                      eventCtx={eventCtx}
                    />
                  ))}
                  {/* Relleno si la fila no está completa */}
                  {rowGroups.length < 4 && Array.from({ length: 4 - rowGroups.length }).map((_, fi) => (
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

// ── Mini baraja (1 al frente opaca + 2 atrás asomando por los lados) ─────────
function MiniDeck({ items, navigation, isGift, variant, colWidth }: any) {
  const [idx, setIdx] = useState(0);
  const pausedUntil = useRef(0);
  const n = items.length;

  useEffect(() => {
    if (n <= 1) return;
    const t = setInterval(() => {
      if (Date.now() < pausedUntil.current) return;
      setIdx(i => (i + 1) % n);
    }, 2200);
    return () => clearInterval(t);
  }, [n]);

  const go = (d: number) => { pausedUntil.current = Date.now() + 6000; setIdx(i => (i + d + n) % n); };
  const goRef = useRef(go);
  goRef.current = go;

  // Deslizar con el dedo (izq/der). Solo captura el gesto si es horizontal → no roba los taps.
  const pan = useRef(
    PanResponder.create({
      onMoveShouldSetPanResponder: (_, g) => Math.abs(g.dx) > 10 && Math.abs(g.dx) > Math.abs(g.dy) * 1.4,
      onPanResponderGrant: () => { pausedUntil.current = Date.now() + 6000; },
      onPanResponderRelease: (_, g) => {
        if (g.dx > 20) goRef.current(-1);        // arrastrar a la derecha → regresa
        else if (g.dx < -20) goRef.current(1);   // a la izquierda → avanza
      },
    })
  ).current;

  if (n === 0) return null;

  // Petición real (2026-09-03): "quiero que esté el mismo tamaño como
  // aparecen los demás" — el Destacado ya no se agranda (0.92 vs 0.80),
  // las 3 columnas usan el mismo tamaño de tarjeta. Se distingue solo por
  // su marco dorado con brillo (ver estilos más abajo), no por tamaño.
  const scale = 0.80;
  const cardW = Math.round(colWidth * scale);
  const cardH = Math.round(cardW * 1.32);
  const peek  = Math.round(cardW * 0.22);   // asoman poco → no invaden la columna vecina
  const leftC = Math.round((colWidth - cardW) / 2);

  const front = items[idx % n];
  const prev  = items[(idx - 1 + n) % n];
  const next  = items[(idx + 1) % n];

  return (
    <View
      {...pan.panHandlers}
      style={{ width: colWidth, height: cardH + 12, justifyContent: 'center', alignItems: 'center' }}
    >
      {/* Detrás izquierda */}
      {n > 1 && (
        <Pressable
          onPress={() => go(-1)}
          style={{ position: 'absolute', top: 6, left: leftC, zIndex: 1, opacity: 0.5, transform: [{ translateX: -peek }, { scale: 0.8 }] }}
        >
          <DeckCard group={prev} w={cardW} h={cardH} variant={variant} />
        </Pressable>
      )}
      {/* Detrás derecha */}
      {n > 2 && (
        <Pressable
          onPress={() => go(1)}
          style={{ position: 'absolute', top: 6, left: leftC, zIndex: 1, opacity: 0.5, transform: [{ translateX: peek }, { scale: 0.8 }] }}
        >
          <DeckCard group={next} w={cardW} h={cardH} variant={variant} />
        </Pressable>
      )}
      {/* Al frente (opaca, arriba de todo) */}
      <Pressable
        onPress={() => navigation && !front._is_mock && navigation.navigate('GroupDetail', { group: front, isGift })}
        style={{ zIndex: 3 }}
      >
        <DeckCard group={front} w={cardW} h={cardH} variant={variant} />
      </Pressable>
      {/* Flechitas — indican que se puede deslizar */}
      {n > 1 && (
        <>
          <Pressable onPress={() => go(-1)} hitSlop={6} style={[styles.deckArrow, { left: 0 }]}>
            <ChevronLeft size={14} color="#fff" />
          </Pressable>
          <Pressable onPress={() => go(1)} hitSlop={6} style={[styles.deckArrow, { right: 0 }]}>
            <ChevronRight size={14} color="#fff" />
          </Pressable>
        </>
      )}
    </View>
  );
}

function DeckCard({ group, w, h, variant }: any) {
  // 📸 Fotos limpias (pedido 2026-07-17): nada encima de la imagen —
  // la columna ya dice Destacados/Recomendados/Populares arriba.
  // El Destacado se distingue por su marco dorado con brillo.
  return (
    <View style={[styles.deckCard, variant === 'dest' && styles.deckCardDest, { width: w, height: h }]}>
      {group.profile_image ? (
        <Image source={{ uri: group.profile_image }} style={styles.featImage} resizeMode="cover" />
      ) : (
        <View style={[styles.featImage, styles.featImagePlaceholder]}>
          <Text style={{ fontSize: 26, color: COLORS.muted }}>♪</Text>
        </View>
      )}
      <LinearGradient
        colors={['transparent', 'rgba(0,0,0,0.9)']}
        locations={[0.42, 1]}
        style={styles.featGradient}
      />
      {group.is_verified && (
        <VerifiedBadge
          size={16}
          style={{ position: 'absolute', top: 6, right: 6 }}
          tier={group.is_plus_active ? 'plus' : 'free'}
        />
      )}
      <View style={styles.deckOverlay}>
        <Text style={styles.deckName} numberOfLines={1}>{group.name}</Text>
        <View style={styles.deckMeta}>
          <Star size={9} color={COLORS.gold} fill={COLORS.gold} />
          <Text style={styles.deckRating}>{group.rating?.toFixed(1) ?? '5.0'}</Text>
        </View>
      </View>
    </View>
  );
}

// ── Grid card (5 columnas) ──────────────────────────────────────────────────
// 2026-09-18 — petición real: "quiero que en el explorador los grupos se
// vean más chicos". Antes 4 columnas; con 5 cada tarjeta ocupa menos
// espacio — todo lo demás (imagen, texto, badges) ya usa GRID_W/GRID_IMG
// calculados, así que se achica solo, sin tocar tamaños fijos.

const GRID_COLS = 5;
const GRID_GAP  = 6;
const GRID_W    = (width - H_PAD * 2 - GRID_GAP * (GRID_COLS - 1)) / GRID_COLS;
const GRID_IMG  = Math.round(GRID_W * 0.78);

function GroupGridCard({ group, index, navigation, bidRank, isGift = false, eventCtx }: any) {
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
        style={[styles.gridCard, group.admin_highlight && styles.gridCardHighlight]}
        onPress={() => navigation.navigate('GroupDetail', {
          group, isGift,
          ...(eventCtx ? { eventId: eventCtx.eventId, eventDate: eventCtx.eventDate, eventAddress: eventCtx.eventAddress } : {}),
        })}
      >
        {/* Foto */}
        <View style={styles.gridImgBox}>
          {group.profile_image && (group.photo_status === 'approved' || !group.photo_status || group.photo_status === 'none')
            ? <Image source={{ uri: group.profile_image }} style={styles.gridImg} resizeMode="cover" />
            : <View style={[styles.gridImg, styles.gridImgPlaceholder]}>
                <Text style={{ fontSize: 18, color: COLORS.muted }}>♪</Text>
              </View>
          }
          {badgeLabel && (
            <View style={[styles.gridBadge, { backgroundColor: badgeColor }]}>
              <Text style={styles.gridBadgeText}>{badgeLabel}</Text>
            </View>
          )}
          {group.is_verified && (
            <VerifiedBadge
              size={15}
              style={{ position: 'absolute', top: 3, right: 3 }}
              tier={group.is_plus_active ? 'plus' : 'free'}
            />
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
    <Animated.View style={{ opacity: fadeAnim, transform: [{ translateY: slideAnim }], marginBottom: 10 }}>
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
              <VerifiedBadge size={18} tier={group.is_plus_active ? 'plus' : 'free'} />
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

  eventCtxBanner: {
    backgroundColor: 'rgba(0,230,118,0.08)', borderWidth: 1, borderColor: 'rgba(0,230,118,0.25)',
    borderRadius: RADIUS.lg, padding: 12, marginHorizontal: H_PAD, marginBottom: 14, gap: 8,
  },
  eventCtxBannerText: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.green, lineHeight: 18 },
  eventCtxChipRow: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' },
  eventCtxCategoryChip: {
    fontFamily: FONTS.bodySemiBold, fontSize: 12, color: COLORS.text,
    backgroundColor: COLORS.card2, borderRadius: RADIUS.full, paddingHorizontal: 10, paddingVertical: 4,
  },
  eventCtxClear: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, textDecorationLine: 'underline' },

  // Header
  header: {
    flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center',
    paddingHorizontal: H_PAD, paddingTop: 6, paddingBottom: 6,
  },
  // Petición real (2026-09-03): "lo de Daricefy sí déjalo, pero un poco
  // más chico" — bajado de 22 a 18.
  logoText: { fontFamily: FONTS.title, fontSize: 18, color: COLORS.text },
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
    marginHorizontal: H_PAD, marginBottom: 12,
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
    marginHorizontal: H_PAD, marginBottom: 12,
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
    marginHorizontal: H_PAD, marginBottom: 10,
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

  // My open requests banner
  myRequestBanner: {
    flexDirection: 'row', alignItems: 'center', gap: 12,
    marginHorizontal: H_PAD, marginBottom: 10,
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
  expressCtaBtn: {
    flexDirection: 'row', alignItems: 'center', gap: 10,
    marginHorizontal: H_PAD, marginBottom: 10,
    backgroundColor: 'rgba(0,230,118,0.11)',
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.45)',
    borderRadius: RADIUS.lg,
    paddingHorizontal: 14, paddingVertical: 12,
  },
  expressCtaIcon: {
    width: 38, height: 38, borderRadius: 12,
    backgroundColor: COLORS.greenMuted,
    borderWidth: 1, borderColor: COLORS.green,
    alignItems: 'center', justifyContent: 'center',
    flexShrink: 0,
  },
  expressCtaTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.text, flex: 1 },
  expressCtaSub:   { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted2, marginTop: 2 },

  // ── Botón Mapa ──
  groupsMapBanner: {
    flexDirection: 'row', alignItems: 'center', gap: 12,
    marginHorizontal: H_PAD, marginBottom: 12,
    backgroundColor: COLORS.card,
    borderWidth: 1, borderColor: COLORS.border,
    borderRadius: 18, padding: 13,
    elevation: 2,
    shadowColor: '#000', shadowOffset: { width: 0, height: 1 }, shadowOpacity: 0.06, shadowRadius: 4,
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

  // 🎁 Regalar evento / modo regalo
  giftEntry: {
    flexDirection: 'row', alignItems: 'center', gap: 12,
    marginHorizontal: H_PAD, marginBottom: 14,
    backgroundColor: 'rgba(0,230,118,0.06)', borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.25)',
    paddingHorizontal: 16, paddingVertical: 13,
  },
  giftEntryEmoji: { fontSize: 22 },
  giftEntryTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.text },
  giftEntrySub:   { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, marginTop: 1, flexShrink: 1 },
  giftEntrySubRow:    { flexDirection: 'row', alignItems: 'center', gap: 5, marginTop: 1 },
  giftEntryGiftEmoji: { fontSize: 14 },

  // ── ⚡/🌎 Tarjetas de acción (Express + Otra ciudad) ──
  actionRow: { flexDirection: 'row', gap: 10, marginHorizontal: H_PAD, marginBottom: 14 },
  actionCard: {
    flex: 1, backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border, padding: 14, minHeight: 96,
  },
  actionCardExpress: { borderColor: 'rgba(255,255,255,0.14)', backgroundColor: 'rgba(255,255,255,0.03)' },
  actionCardCity:    { borderColor: 'rgba(255,255,255,0.14)', backgroundColor: 'rgba(255,255,255,0.03)' },
  actionCardPressed: { opacity: 0.6, transform: [{ scale: 0.98 }] },
  actionCardTop: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', marginBottom: 10, minHeight: 22 },
  actionTitleRow: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', gap: 6, marginBottom: 6, minHeight: 22 },
  actionCta: { flexDirection: 'row', alignItems: 'center', gap: 3, marginTop: 6 },
  actionCtaTx: { fontFamily: FONTS.bodySemiBold, fontSize: 12, color: COLORS.text },
  actionChipGold: {
    flexDirection: 'row', alignItems: 'center', gap: 4,
    backgroundColor: 'rgba(255,179,0,0.12)', borderRadius: RADIUS.full,
    paddingHorizontal: 8, paddingVertical: 3,
  },
  actionChipGoldTx: { fontFamily: FONTS.bodySemiBold, fontSize: 9, color: COLORS.gold, letterSpacing: 1 },
  actionEmoji:      { fontSize: 20 },
  actionTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.text },
  actionSub:   { fontFamily: FONTS.body, fontSize: 11.5, color: COLORS.muted2, marginTop: 2, lineHeight: 15 },
  giftBanner: {
    flexDirection: 'row', alignItems: 'center', gap: 12,
    marginHorizontal: H_PAD, marginBottom: 14,
    backgroundColor: 'rgba(0,230,118,0.10)', borderRadius: RADIUS.lg,
    borderWidth: 1.5, borderColor: COLORS.green,
    paddingHorizontal: 16, paddingVertical: 12,
  },
  giftBannerTitle:  { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.green },
  giftBannerSub:    { fontFamily: FONTS.body, fontSize: 11.5, color: COLORS.muted2, marginTop: 1 },
  giftBannerAction: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.green },

  // 🎁 Selector de ciudad
  citySelBackdrop: { flex: 1, backgroundColor: 'rgba(0,0,0,0.55)' },
  citySelSheet: {
    position: 'absolute', left: 0, right: 0, bottom: 0,
    backgroundColor: COLORS.card, borderTopLeftRadius: 22, borderTopRightRadius: 22,
    borderWidth: 1, borderColor: COLORS.border,
    paddingHorizontal: SPACING.xl, paddingTop: 18, paddingBottom: 34,
  },
  citySelHead:  { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' },
  citySelTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 17, color: COLORS.text, flex: 1 },
  citySelHint:  { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2, marginTop: 4, marginBottom: 12 },
  countryTabs:  { flexDirection: 'row', gap: 8, marginBottom: 6 },
  countryTab: {
    flex: 1, alignItems: 'center', paddingVertical: 10, borderRadius: RADIUS.md,
    backgroundColor: COLORS.card2, borderWidth: 1, borderColor: COLORS.border,
  },
  countryTabActive: { backgroundColor: 'rgba(0,230,118,0.12)', borderColor: COLORS.green },
  countryTabText:       { fontFamily: FONTS.bodyMedium, fontSize: 14, color: COLORS.muted2 },
  countryTabTextActive: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.green },
  cityRow: {
    flexDirection: 'row', alignItems: 'center', gap: 10,
    paddingVertical: 13, borderBottomWidth: 1, borderBottomColor: COLORS.border,
  },
  cityRowText: { fontFamily: FONTS.bodyMedium, fontSize: 15, color: COLORS.text },

  listContent: { paddingHorizontal: H_PAD, paddingBottom: 32 },

  // Promo banner — imagen dominante con texto sobrepuesto
  promoBanner: {
    borderRadius: RADIUS.xl, overflow: 'hidden',
    borderWidth: 1, borderColor: COLORS.greenGlow, marginBottom: 20,
  },
  promoBannerInner: { height: 132, position: 'relative' },
  promoBannerMute: {
    position: 'absolute', top: 8, right: 8,
    width: 30, height: 30, borderRadius: 15,
    alignItems: 'center', justifyContent: 'center',
    backgroundColor: 'rgba(0,0,0,0.5)',
    borderWidth: 1, borderColor: 'rgba(255,255,255,0.15)',
  },
  promoBannerBg: {
    position: 'absolute', top: 0, left: 0, right: 0, bottom: 0,
    width: '100%', height: '100%',
  },
  promoBannerGrad: {
    position: 'absolute', top: 0, left: 0, right: 0, bottom: 0,
  },
  promoBannerTagChip: {
    position: 'absolute', top: 8, left: 8,
    backgroundColor: 'rgba(0,0,0,0.45)',
    borderRadius: RADIUS.full, paddingHorizontal: 7, paddingVertical: 3,
    borderWidth: 1, borderColor: 'rgba(255,255,255,0.12)',
  },
  promoBannerTagText: {
    fontFamily: FONTS.bodyMedium, fontSize: 7,
    color: 'rgba(255,255,255,0.70)', letterSpacing: 1.0,
  },
  promoBannerOverlay: {
    position: 'absolute', bottom: 0, left: 0, right: 0,
    flexDirection: 'row', alignItems: 'flex-end', gap: 8,
    paddingHorizontal: SPACING.md, paddingBottom: 11,
  },
  promoBannerTitle: {
    fontFamily: FONTS.bodySemiBold, fontSize: 12.5, color: '#fff', marginBottom: 2,
    textShadowColor: 'rgba(0,0,0,0.6)', textShadowOffset: { width: 0, height: 1 }, textShadowRadius: 4,
  },
  promoBannerSub: {
    fontFamily: FONTS.body, fontSize: 10.5, color: 'rgba(255,255,255,0.78)',
    textShadowColor: 'rgba(0,0,0,0.5)', textShadowOffset: { width: 0, height: 1 }, textShadowRadius: 3,
  },
  promoBannerBtn: {
    paddingHorizontal: 8, paddingVertical: 4,
    borderRadius: RADIUS.sm, backgroundColor: COLORS.green, flexShrink: 0,
  },
  promoBannerBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 9.5, color: '#000' },

  // Sections
  sectionRow: {
    flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center', marginBottom: 12,
  },
  sectionRowLeft: { flexDirection: 'row', alignItems: 'center', gap: 6 },
  sectionLabel: { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.text },
  sectionCount: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2 },

  // Event type quick actions
  eventTypeList: { gap: 10, paddingRight: H_PAD },
  eventTypeChip: {
    alignItems: 'center', gap: 6,
    backgroundColor: COLORS.card, borderWidth: 1, borderColor: COLORS.border,
    borderRadius: RADIUS.lg, paddingHorizontal: 14, paddingVertical: 10,
  },
  eventTypeEmoji: { fontSize: 22 },
  eventTypeLabel: { fontFamily: FONTS.bodyMedium, fontSize: 11, color: COLORS.muted2 },

  // Featured horizontal
  featuredList: { gap: 12, paddingLeft: H_PAD, paddingRight: H_PAD },
  featCard: {
    width: FEAT_W, height: FEAT_H,
    borderRadius: RADIUS.xl, overflow: 'hidden', position: 'relative',
    backgroundColor: COLORS.card2, borderWidth: 1, borderColor: COLORS.border,
  },
  featImage: { ...StyleSheet.absoluteFill, width: '100%', height: '100%' },
  featImagePlaceholder: { backgroundColor: COLORS.card2, alignItems: 'center', justifyContent: 'center' },
  featGradient: { position: 'absolute', left: 0, right: 0, bottom: 0, height: '80%' },
  featBadgePill: {
    position: 'absolute', top: 8, left: 8,
    borderRadius: RADIUS.full, paddingHorizontal: 8, paddingVertical: 3,
  },
  featBadgePillTx: { fontFamily: FONTS.bodySemiBold, fontSize: 8, color: '#000', letterSpacing: 0.6 },

  // ── Mini baraja (3 columnas: Destacados · Recomendados · Populares) ──
  deckRow: { flexDirection: 'row', justifyContent: 'center', gap: 10, paddingHorizontal: H_PAD, marginBottom: 24 },
  deckLabelChip: {
    alignSelf: 'center', maxWidth: '100%', marginBottom: 11,
    paddingHorizontal: 8, paddingVertical: 4.5,
    borderRadius: RADIUS.full, borderWidth: 1,
  },
  deckLabel: { fontFamily: FONTS.bodySemiBold, fontSize: 9.5, letterSpacing: 0.1, textAlign: 'center' },
  deckArrow: {
    position: 'absolute', top: 0, bottom: 0, width: 22,
    alignItems: 'center', justifyContent: 'center', zIndex: 5,
  },
  deckCard: {
    borderRadius: RADIUS.lg, overflow: 'hidden', position: 'relative',
    backgroundColor: COLORS.card2, borderWidth: 1, borderColor: 'rgba(255,255,255,0.10)',
  },
  // 💎 Destacado: marco dorado con brillo — se nota que es el premium
  deckCardDest: {
    borderWidth: 1.5, borderColor: 'rgba(230,194,90,0.85)',
    shadowColor: '#E6C25A', shadowOpacity: 0.45, shadowRadius: 10,
    shadowOffset: { width: 0, height: 3 }, elevation: 8,
  },
  deckBadge: { position: 'absolute', top: 5, left: 5, borderRadius: RADIUS.full, paddingHorizontal: 5, paddingVertical: 2 },
  deckBadgeTx: { fontFamily: FONTS.bodySemiBold, fontSize: 6.5, color: '#000', letterSpacing: 0.4 },
  deckPopEmoji: {
    position: 'absolute', top: 4, left: 5, fontSize: 13,
    textShadowColor: 'rgba(0,0,0,0.8)', textShadowOffset: { width: 0, height: 1 }, textShadowRadius: 3,
  },
  deckOverlay: { position: 'absolute', left: 0, right: 0, bottom: 0, paddingHorizontal: 6, paddingBottom: 6, paddingTop: 14 },
  deckName: { fontFamily: FONTS.bodySemiBold, fontSize: 9.5, color: '#fff', lineHeight: 12,
    textShadowColor: 'rgba(0,0,0,0.7)', textShadowOffset: { width: 0, height: 1 }, textShadowRadius: 3 },
  deckMeta: { flexDirection: 'row', alignItems: 'center', gap: 2, marginTop: 1 },
  deckRating: { fontFamily: FONTS.bodySemiBold, fontSize: 8.5, color: COLORS.gold },
  featOverlay: { position: 'absolute', left: 0, right: 0, bottom: 0, paddingHorizontal: 11, paddingBottom: 11, paddingTop: 20 },
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
  featMockBadgeText: { fontFamily: FONTS.bodySemiBold, fontSize: 8, color: '#fff' },
  featContent: { padding: 5 },
  featNameRow: { flexDirection: 'row', alignItems: 'center', gap: 4, marginBottom: 3 },
  featVerifiedBadge: {
    width: 12, height: 12, borderRadius: 6,
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
  featName: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: '#fff', lineHeight: 17, flex: 1,
    textShadowColor: 'rgba(0,0,0,0.6)', textShadowOffset: { width: 0, height: 1 }, textShadowRadius: 4 },
  featMeta: { flexDirection: 'row', alignItems: 'center', gap: 3 },
  featRating: { fontFamily: FONTS.bodySemiBold, fontSize: 11, color: COLORS.gold },
  featDot: { fontFamily: FONTS.body, fontSize: 11, color: 'rgba(255,255,255,0.6)' },
  featCity: { fontFamily: FONTS.body, fontSize: 10.5, color: 'rgba(255,255,255,0.8)', flex: 1 },
  featPrice:       { fontFamily: FONTS.bodySemiBold, fontSize: 9, color: COLORS.green, marginTop: 2 },
  featPriceStrike: { textDecorationLine: 'line-through', color: COLORS.muted, fontSize: 8, marginTop: 1 },
  featPriceSurge:  { color: '#FF6D00', marginTop: 0 },

  // Category chips
  genreList: { gap: 8, flexDirection: 'row', paddingRight: H_PAD },
  genreChip: {
    paddingHorizontal: 16, paddingVertical: 8, borderRadius: RADIUS.full,
    backgroundColor: COLORS.card, borderWidth: 1, borderColor: COLORS.border,
  },
  genreChipActive: { backgroundColor: COLORS.greenMuted, borderColor: COLORS.green },
  genreText: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted2 },
  genreTextActive: { color: COLORS.green },
  subFilterLabel: {
    fontFamily: FONTS.body, fontSize: 12, color: 'rgba(255,255,255,0.5)',
    marginBottom: 6, marginLeft: 2,
  },
  subFilterChip: {
    paddingHorizontal: 13, paddingVertical: 7, borderRadius: RADIUS.full,
    backgroundColor: COLORS.card, borderWidth: 1, borderColor: COLORS.border,
  },

  // Groups header
  groupsHeader: { flexDirection: 'row', alignItems: 'center', gap: 10, marginBottom: 14 },
  countChip: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.full,
    borderWidth: 1, borderColor: COLORS.border,
    paddingHorizontal: 10, paddingVertical: 3,
  },
  countChipText: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.muted2 },

  // Grid 4 columnas
  gridRow:  { flexDirection: 'row', gap: GRID_GAP, marginBottom: GRID_GAP },
  gridCell: { width: GRID_W },
  gridCard: {
    width: GRID_W, borderRadius: RADIUS.md, overflow: 'hidden',
    backgroundColor: COLORS.card, borderWidth: 1, borderColor: COLORS.border,
  },
  // ✨ sql/665 — "brillo de marco" manual (interruptor de admin, nada que
  // ver con patrocinio/boost). Petición real: "el puro marco" — mismo
  // criterio visual que deckCardDest (marco + resplandor), solo el borde.
  gridCardHighlight: {
    borderWidth: 1.5, borderColor: 'rgba(0,230,118,0.85)',
    shadowColor: COLORS.green, shadowOpacity: 0.55, shadowRadius: 8,
    shadowOffset: { width: 0, height: 0 }, elevation: 8,
  },
  gridImgBox:         { width: GRID_W, height: GRID_IMG, position: 'relative' },
  gridImg:            { width: '100%', height: '100%' },
  gridImgPlaceholder: { backgroundColor: COLORS.card2, alignItems: 'center', justifyContent: 'center' },
  gridBadge: {
    position: 'absolute', top: 3, left: 3,
    paddingHorizontal: 3, paddingVertical: 1, borderRadius: RADIUS.full,
  },
  gridBadgeText: { fontFamily: FONTS.bodySemiBold, fontSize: 7, color: '#fff' },
  gridVerified: {
    position: 'absolute', top: 3, right: 3,
    width: 13, height: 13, borderRadius: 7,
    backgroundColor: 'rgba(66,133,244,0.3)', borderWidth: 1, borderColor: 'rgba(66,133,244,0.6)',
    alignItems: 'center', justifyContent: 'center',
  },
  gridInfo:   { padding: 4 },
  gridName:   { fontFamily: FONTS.bodySemiBold, fontSize: 10, color: COLORS.text, marginBottom: 1 },
  gridMeta:   { flexDirection: 'row', alignItems: 'center', gap: 2, flexWrap: 'nowrap' },
  gridRating: { fontFamily: FONTS.bodyMedium, fontSize: 8, color: COLORS.gold },
  gridDot:    { fontFamily: FONTS.body, fontSize: 8, color: COLORS.muted },
  gridCity:   { fontFamily: FONTS.body, fontSize: 8, color: COLORS.muted2, flex: 1 },
  gridPrice:  { fontFamily: FONTS.bodyMedium, fontSize: 8, color: COLORS.green, marginTop: 1 },

  // Card
  card: {
    width: CARD_W, height: 185,
    borderRadius: RADIUS.xl, overflow: 'hidden',
    backgroundColor: COLORS.card, borderWidth: 1, borderColor: COLORS.border,
  },
  cardImage: { width: '100%', height: '100%', position: 'absolute' },
  cardImagePlaceholder: { backgroundColor: COLORS.card2, alignItems: 'center', justifyContent: 'center' },
  gradient: { position: 'absolute', left: 0, right: 0, bottom: 0, height: '70%' },
  verifiedBadge: {
    position: 'absolute', top: 10, right: 10,
    backgroundColor: 'rgba(66,133,244,0.85)',
    paddingHorizontal: 8, paddingVertical: 3, borderRadius: RADIUS.full,
  },
  verifiedText: { fontFamily: FONTS.bodyMedium, fontSize: 10, color: '#fff' },
  cardContent: { position: 'absolute', bottom: 0, left: 0, right: 0, padding: 12 },
  genreTag: {
    alignSelf: 'flex-start',
    backgroundColor: COLORS.greenMuted, paddingHorizontal: 8, paddingVertical: 2,
    borderRadius: RADIUS.full, marginBottom: 4,
  },
  genreTagText: { fontFamily: FONTS.bodyMedium, fontSize: 10, color: COLORS.green },
  cardTitleRow: { flexDirection: 'row', alignItems: 'center', gap: 5, marginBottom: 4 },
  cardVerifiedBadge: {
    width: 16, height: 16, borderRadius: 8,
    backgroundColor: 'rgba(66,133,244,0.25)',
    borderWidth: 1, borderColor: 'rgba(66,133,244,0.5)',
    alignItems: 'center', justifyContent: 'center', flexShrink: 0,
  },
  cardTitle: { fontFamily: FONTS.title, fontSize: 17, color: COLORS.text, flex: 1 },
  cardMeta: { flexDirection: 'row', alignItems: 'center', gap: 8, flexWrap: 'wrap' },
  metaItem: { flexDirection: 'row', alignItems: 'center', gap: 4 },
  metaText: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2 },
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
  emptySub: { fontFamily: FONTS.body, color: COLORS.muted, fontSize: 13, textAlign: 'center', paddingHorizontal: 24 },
  interestBtn: {
    flexDirection: 'row', alignItems: 'center', gap: 8, marginTop: 18,
    backgroundColor: COLORS.green, borderRadius: RADIUS.full, paddingVertical: 11, paddingHorizontal: 22,
  },
  interestBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.bg },
  interestSentPill: {
    flexDirection: 'row', alignItems: 'center', gap: 6, marginTop: 18,
    backgroundColor: COLORS.greenMuted, borderRadius: RADIUS.full, paddingVertical: 10, paddingHorizontal: 18,
  },
  interestSentText: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.green },

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
    marginHorizontal: H_PAD, marginBottom: 12,
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
    marginHorizontal: H_PAD, marginBottom: 10,
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
    marginHorizontal: H_PAD, marginBottom: 10,
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

  // ── Chip "EXPRÉS · PARA HOY" ──────────────────────────────────────────────
  expressSectionChip: {
    flexDirection: 'row', alignItems: 'center', gap: 5,
    alignSelf: 'flex-start',
    backgroundColor: 'rgba(255,179,0,0.10)',
    borderWidth: 1, borderColor: 'rgba(255,179,0,0.35)',
    borderRadius: RADIUS.full, paddingHorizontal: 10, paddingVertical: 4,
  },
  expressSectionChipText: {
    fontFamily: FONTS.bodySemiBold, fontSize: 10,
    color: COLORS.gold, letterSpacing: 1.2,
  },

  // ── Header sección programada ─────────────────────────────────────────────
  scheduledHeader: { marginBottom: 14 },
  scheduledTag: {
    fontFamily: FONTS.bodySemiBold, fontSize: 10,
    color: COLORS.gold, letterSpacing: 1.4, marginBottom: 6,
  },
  scheduledTitle: {
    fontFamily: FONTS.title, fontSize: 17,
    color: COLORS.text, marginBottom: 3,
  },
  scheduledSub: {
    fontFamily: FONTS.body, fontSize: 13,
    color: COLORS.gold,
    opacity: 0.75,
  },

});
