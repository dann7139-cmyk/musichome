/**
 * CreateAdvertisementScreen
 * Flujo de 4 pasos para que cualquier usuario compre publicidad:
 *   1. Tipo de anuncio (banner_home / sponsored_group / profile_ad)
 *   2. Contenido (media, título, subtítulo, CTA)
 *   3. Selección de paquete (precio, duración)
 *   4. Resumen + Pago (Stripe / Conekta)
 */
import VideoPlayer from '../../components/ui/VideoPlayer';
import * as ImagePicker from 'expo-image-picker';
import { ArrowLeft, CheckCircle, ChevronRight, Image as ImageIcon, Megaphone, Play, ShieldCheck, Video, X } from 'lucide-react-native';
import React, { useEffect, useState } from 'react';
import { useAuth } from '../../context/AuthContext';
import { useStripe } from '@stripe/stripe-react-native';
import {
  ActivityIndicator,
  Alert,
  Image,
  KeyboardAvoidingView,
  Platform,
  Pressable,
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
import { normalizeCity } from '../../utils/cityUtils';
import { startPromoConektaCheckout } from '../../utils/conektaCheckout';

// ─── Tipos ────────────────────────────────────────────────────────────────────

type AdType = 'banner_home' | 'sponsored_group' | 'profile_ad';

interface AdPackage {
  id: string;
  name: string;
  type: AdType;
  tier?: 'top_1_3' | 'top_4_10' | null;
  duration_days: number;
  price: number;
  description: string | null;
  location_scope?: string;
}

type LocationType = 'city' | 'multi_city' | 'national' | 'international';

const LOCATION_OPTIONS: { type: LocationType; emoji: string; label: string; desc: string; color: string }[] = [
  { type: 'city',          emoji: '📍', label: 'Mi ciudad',       desc: 'Aparece solo en tu ciudad · Precio base',              color: '#22D3EE' },
  { type: 'multi_city',    emoji: '🗺️', label: 'Varias ciudades', desc: 'Elige hasta 5 ciudades · Precio ×1.5',                  color: '#F59E0B' },
  { type: 'national',      emoji: '🌎', label: 'Todo el País',     desc: 'Alcance nacional · Mayor visibilidad · ×2 el precio',   color: '#00E676' },
  { type: 'international', emoji: '🌍', label: 'Internacional',    desc: 'Alcance global · Máxima visibilidad · ×3.5 el precio',  color: '#8B5CF6' },
];

// Multiplicador de alcance (para cálculo live en modo custom)
const LOCATION_MULT: Record<LocationType, number> = {
  city:          1.0,
  multi_city:    1.5,
  national:      2.0,
  international: 3.5,
};

// Precio base por día para el modo personalizado (en MXN)
const BASE_PER_DAY: Record<AdType, number> = {
  banner_home:     65,
  sponsored_group: 55,
  profile_ad:      55,
};

// ── Precios tier banner_home (espejo de AdvertisingPackagesScreen) ────────────
// Fuente de verdad: si pkg.tier está definido, este mapa toma precedencia sobre pkg.price.
const BANNER_TIER_PRICES: Record<string, Record<number, number>> = {
  top_1_3:  { 7: 699,  14: 1199, 30: 1999 },
  top_4_10: { 7: 499,  14: 899,  30: 1499 },
};

function getBannerBasePrice(pkg: AdPackage): number {
  if (pkg.type === 'banner_home' && pkg.tier && pkg.tier in BANNER_TIER_PRICES) {
    return BANNER_TIER_PRICES[pkg.tier][pkg.duration_days] ?? pkg.price;
  }
  return pkg.price;
}

// ── Fuente única de verdad para precio final ─────────────────────────────────
// Usar en: step 3 cards, step 4 resumen, step 4 botón pagar, handlePay.
// dMult = demandInfo.multiplier, lMult = LOCATION_MULT[locationType],
// cMult = cityStatus.price_multiplier
function calcFinalPrice(opts: {
  pkg?: AdPackage | null;
  adType?: AdType | null;
  dMult: number;
  lMult: number;
  cMult: number;
  customDays?: number;
}): number {
  const { pkg, adType, dMult, lMult, cMult, customDays = 1 } = opts;
  if (pkg) {
    return Math.ceil(getBannerBasePrice(pkg) * dMult * lMult * cMult);
  }
  const basePerDay = adType ? BASE_PER_DAY[adType] : 0;
  return Math.ceil(basePerDay * Math.max(1, customDays) * dMult * lMult * cMult);
}

// ─── Constantes ───────────────────────────────────────────────────────────────

// sponsored_group solo se contrata desde el panel del grupo
const AD_TYPES: { type: AdType; emoji: string; label: string; desc: string; color: string }[] = [
  {
    type:  'banner_home',
    emoji: '📢',
    label: 'Banner en Inicio',
    desc:  'Tu anuncio aparece en el carousel de la pantalla principal. Lo ven todos los usuarios al abrir la app.',
    color: '#00E676',
  },
  {
    type:  'profile_ad',
    emoji: '👤',
    label: 'Publicidad en Perfiles',
    desc:  'Tu anuncio aparece dentro de los perfiles de grupos musicales cuando los clientes los visitan.',
    color: '#7C3AED',
  },
];

// Steps: 0=Tipo 1=Contenido 2=Ubicación 3=Paquete 4=Pago
const STEP_LABELS       = ['Tipo', 'Contenido', 'Ubicación', 'Paquete', 'Pago'];
const STEP_LABELS_SHORT = ['Contenido', 'Ubicación', 'Pago']; // cuando el paquete viene pre-seleccionado

// ─── Validación de contacto externo ──────────────────────────────────────────

const PHONE_REGEX  = /(\+?\d[\d\s\-().]{7,}\d|\b\d{10,}\b)/;
const HANDLE_REGEX = /@[a-zA-Z0-9_.]+/;

function containsContactInfo(text: string): boolean {
  return PHONE_REGEX.test(text) || HANDLE_REGEX.test(text);
}

const YOUTUBE_REGEX = /^https?:\/\/(www\.)?(youtube\.com\/watch\?v=|youtu\.be\/)[\w\-]+/;
function isValidYoutubeUrl(url: string): boolean {
  return YOUTUBE_REGEX.test(url.trim());
}

// ── Texto de comparación según nivel de demanda ───────────────────────────────
function getDemandComparisonText(demandLevel: string | null | undefined): string {
  if (demandLevel === 'high') return 'Mayor que el promedio en tu ciudad';
  if (demandLevel === 'medium') return 'Similar a otros grupos activos';
  return 'Buen momento para posicionarte antes que otros';
}

// ─── Helper: tipos "simples" (sin media ni diseño de anuncio) ─────────────────
// sponsored_group no necesita contenido ni ubicación (estado = grupo siempre).
// profile_ad ahora pasa por Ubicación para permitir segmentación multi-estado.
const isSimpleAdType = (t: AdType | null | undefined): boolean =>
  t === 'sponsored_group';

const MEXICO_STATES = [
  'Aguascalientes','Baja California','Baja California Sur','Campeche',
  'Chiapas','Chihuahua','Ciudad de México','Coahuila','Colima','Durango',
  'Guanajuato','Guerrero','Hidalgo','Jalisco','Estado de México',
  'Michoacán','Morelos','Nayarit','Nuevo León','Oaxaca','Puebla',
  'Querétaro','Quintana Roo','San Luis Potosí','Sinaloa','Sonora',
  'Tabasco','Tamaulipas','Tlaxcala','Veracruz','Yucatán','Zacatecas',
];

// Estimación de solicitudes para paquetes simples
function calcSimpleEstimates(
  adType: AdType | null,
  durationDays: number,
  demandLevel: string | null | undefined,
): { min: number; max: number } {
  const baseMin = adType === 'sponsored_group' ? 5 : 3;
  const baseMax = adType === 'sponsored_group' ? 10 : 8;
  const dMult =
    demandLevel === 'high'   ? 1.6 :
    demandLevel === 'medium' ? 1.2 :
    demandLevel === 'low'    ? 0.7 :
    demandLevel === 'new'    ? 0.5 : 1.0;
  const durFactor = durationDays / 7;
  return {
    min: Math.max(1, Math.round(baseMin * dMult * durFactor)),
    max: Math.max(2, Math.round(baseMax * dMult * durFactor)),
  };
}

// ─── Componente ───────────────────────────────────────────────────────────────

export default function CreateAdvertisementScreen({ navigation, route }: any) {
  const { profile: authProfile, role: authRole, safeCity } = useAuth();
  const { initPaymentSheet, presentPaymentSheet } = useStripe();

  // Paquete pre-seleccionado desde AdvertisingPackagesScreen
  const preSelected: AdPackage | null = route?.params?.preSelectedPackage ?? null;
  // Tipo pre-definido cuando viene de "Personalizar anuncio" (customMode)
  const routeAdType: AdType | null    = route?.params?.adType ?? null;
  // Si viene con customMode=true desde AdvertisingPackagesScreen, abrir tab personalizado
  const routeCustomMode: boolean      = route?.params?.customMode ?? false;

  // Tipos de anuncio visibles según rol:
  //   · groups    → solo banner_home (profile_ad no aplica para grupos)
  //   · clients   → banner_home + profile_ad (sin sponsored_group, ese es interno)
  const visibleAdTypes = AD_TYPES.filter(t =>
    authRole === 'group' ? t.type !== 'profile_ad' : true
  );

  // ── Paso actual ──────────────────────────────────────────────────────────
  // Steps: 0=Tipo 1=Contenido 2=Ubicación 3=Paquete 4=Pago
  // Tipos simples (sponsored_group, profile_ad): saltar Contenido y Ubicación.
  //   · Con paquete pre-seleccionado → paso 4 directo
  //   · Con tipo pero sin paquete    → paso 3 (selección de paquete)
  //   · Banner/sin tipo              → paso 1 (contenido) o paso 0 (selector)
  const knownType = preSelected?.type ?? routeAdType;
  const simpleStart = isSimpleAdType(knownType ?? null);
  const startStep = !knownType ? 0 : simpleStart ? (preSelected ? 4 : 3) : 1;
  const [step, setStep] = useState(startStep);

  // ── Paso 1: tipo ─────────────────────────────────────────────────────────
  const [adType, setAdType] = useState<AdType | null>(knownType ?? null);

  // ── Paso 2: contenido ────────────────────────────────────────────────────
  const [title,      setTitle]      = useState('');
  const [subtitle,   setSubtitle]   = useState('');
  const [buttonText, setButtonText] = useState('Contratar');
  const [linkType,   setLinkType]   = useState<'none' | 'group' | 'video'>('none');
  const [linkGroupId, setLinkGroupId] = useState<string | null>(null);
  const [youtubeUrl,  setYoutubeUrl]  = useState('');
  const [userGroups,  setUserGroups]  = useState<{ id: string; name: string }[]>([]);
  const [mediaUri,        setMediaUri]        = useState<string | null>(null);
  const [mediaType,       setMediaType]       = useState<'none' | 'image' | 'video'>('none');
  const [uploading,       setUploading]       = useState(false);
  const [mediaUrl,        setMediaUrl]        = useState<string | null>(null);
  const [durationSeconds, setDurationSeconds] = useState<number | null>(null);

  // ── Paso 2: ubicación ────────────────────────────────────────────────────
  const [locationType,    setLocationType]    = useState<LocationType>('national');
  const [locationCities,  setLocationCities]  = useState<string[]>([]);
  const [cityInput,       setCityInput]       = useState('');

  // Segmentación por estado (banner_home y profile_ad únicamente)
  // [] = nacional (sin restricción); [estados...] = solo esos estados
  const [targetStates,  setTargetStates]  = useState<string[]>([]);
  const [stateSearch,   setStateSearch]   = useState('');
  const [targetCountry, setTargetCountry] = useState<string | null>(null);

  const toggleState = (st: string) => {
    setTargetStates(prev =>
      prev.includes(st) ? prev.filter(x => x !== st) : [...prev, st]
    );
  };

  // ── Paso 3: paquete ──────────────────────────────────────────────────────
  const [packages,        setPackages]        = useState<AdPackage[]>([]);
  const [selectedPackage, setSelectedPackage] = useState<AdPackage | null>(preSelected ?? null);
  const [loadingPkgs,     setLoadingPkgs]     = useState(false);

  // ── Paso 3: modo personalizado ────────────────────────────────────────────
  const [pkgMode,    setPkgMode]    = useState<'packages' | 'custom'>(routeCustomMode ? 'custom' : 'packages');
  const [customDays, setCustomDays] = useState('7');

  // ── Paso 4: pago ─────────────────────────────────────────────────────────
  const [paying,  setPaying]  = useState(false);
  const [success, setSuccess] = useState(false);

  // ── Validación de contacto externo ───────────────────────────────────────
  const [titleError,    setTitleError]    = useState('');
  const [subtitleError, setSubtitleError] = useState('');

  // ── Demanda dinámica ──────────────────────────────────────────────────────
  const [demandInfo, setDemandInfo] = useState<{
    demand_level: 'low' | 'medium' | 'high';
    multiplier: number;
    message: string;
    demand_score: number;
  } | null>(null);

  // ── Estado de ciudad (seeding → precio ×0.7) ──────────────────────────────
  const [cityStatus, setCityStatus] = useState<{ status: string; price_multiplier: number; is_seeding: boolean } | null>(null);

  // ─── Cargar paquetes al llegar al paso 3 ──────────────────────────────────
  useEffect(() => {
    if (step === 3 && adType) {
      loadPackages();
    }
  }, [step, adType]);

  // ─── Cargar grupos del usuario al montar ──────────────────────────────────
  useEffect(() => {
    supabase.auth.getSession().then(({ data: sd }) => {
      const uid = sd.session?.user.id;
      if (!uid) return;
      supabase.from('groups').select('id, name').eq('owner_id', uid)
        .then(({ data }) => {
          const groups = (data as any[]) ?? [];
          setUserGroups(groups);
          // Para sponsored_group, pre-llenar el título con el nombre del grupo
          if (adType === 'sponsored_group' && groups.length > 0) {
            setTitle(prev => prev.trim() === '' ? groups[0].name : prev);
          }
        });
    });
  }, []);

  // ─── Tipos simples: auto-rellenar título + fijar alcance a ciudad ────────
  useEffect(() => {
    if (!adType || !isSimpleAdType(adType)) return;
    // Título automático (sin sobreescribir si el usuario ya escribió algo)
    if (!title.trim()) {
      if (adType === 'sponsored_group') {
        const groupName = userGroups[0]?.name;
        setTitle(groupName ?? 'Grupo Destacado');
      } else {
        setTitle('Anuncio en Perfil');
      }
    }
    // Ubicación: ciudad del perfil (sponsored_group siempre es local)
    // safeCity nunca es undefined (fallback garantizado en AuthContext)
    const normalizedCity = normalizeCity(safeCity);
    console.log('[CreateAd] city usada:', safeCity, 'normalized:', normalizedCity);
    setLocationType('city');
    setLocationCities([normalizedCity]);
  }, [adType, userGroups, safeCity]);

  // ─── Fetch demanda al cambiar ubicación ───────────────────────────────────
  useEffect(() => {
    const city = locationType !== 'national' && locationCities.length > 0
      ? locationCities[0]
      : null;
    supabase.rpc('get_demand_info', { p_city: city })
      .then(({ data }) => { if (data) setDemandInfo(data as any); });
  }, [locationType, locationCities]);

  const loadPackages = async () => {
    setLoadingPkgs(true);
    const nCity = normalizeCity(safeCity);
    const [{ data }, { data: csData }] = await Promise.all([
      supabase.from('ad_packages').select('*').eq('type', adType).eq('is_active', true).order('price', { ascending: true }),
      supabase.rpc('get_city_status', { p_city: nCity }),
    ]);
    setPackages((data as AdPackage[]) ?? []);
    if ((csData as any)?.ok) setCityStatus(csData as any);
    setLoadingPkgs(false);
  };

  // ─── Subir media a Storage ────────────────────────────────────────────────
  const IMAGE_MAX_BYTES    = 5  * 1024 * 1024;
  const VIDEO_MAX_BYTES    = 20 * 1024 * 1024;
  const VIDEO_MAX_MS       = 30_000;
  const ALLOWED_IMG_MIMES  = ['image/jpeg','image/jpg','image/png','image/webp'];

  const pickMedia = async (type: 'image' | 'video') => {
    try {
      const result = await ImagePicker.launchImageLibraryAsync({
        mediaTypes:    type === 'image' ? 'images' : 'videos',
        allowsEditing: type === 'image',
        aspect:        type === 'image' ? [16, 9] : undefined,
        quality:       type === 'image' ? 0.65 : 1,
      });
      if (result.canceled) return;

      const asset = result.assets[0];
      const mime  = (asset.mimeType ?? (type === 'image' ? 'image/jpeg' : 'video/mp4')).toLowerCase();

      // ── Validaciones ──
      if (type === 'image') {
        if (!ALLOWED_IMG_MIMES.includes(mime)) {
          Alert.alert('Formato no válido', 'Solo se aceptan imágenes JPG, PNG o WebP.');
          return;
        }
        if (asset.fileSize && asset.fileSize > IMAGE_MAX_BYTES) {
          Alert.alert('Imagen muy grande', `Pesa ${(asset.fileSize/1024/1024).toFixed(1)} MB. El máximo es 5 MB.`);
          return;
        }
      } else {
        if (!mime.includes('mp4')) {
          Alert.alert('Formato no válido', 'Solo se aceptan videos MP4.');
          return;
        }
        if (asset.fileSize && asset.fileSize > VIDEO_MAX_BYTES) {
          Alert.alert('Video muy grande', `Pesa ${(asset.fileSize/1024/1024).toFixed(1)} MB. El máximo es 20 MB.`);
          return;
        }
        if (asset.duration && asset.duration > VIDEO_MAX_MS) {
          Alert.alert('Video muy largo', `Dura ${Math.ceil(asset.duration/1000)}s. El máximo es 30 segundos.`);
          return;
        }
      }

      setMediaUri(asset.uri);
      setMediaType(type);
      setMediaUrl(null);
      setDurationSeconds(asset.duration ? Math.ceil(asset.duration / 1000) : null);

      await uploadMedia(asset.uri, mime, type);
    } catch (e: any) {
      Alert.alert('Error', e.message ?? 'No se pudo seleccionar el archivo.');
    }
  };

  const uploadMedia = async (uri: string, mime: string, type: 'image' | 'video') => {
    setUploading(true);
    try {
      const { data: sd } = await supabase.auth.getSession();
      const uid = sd.session?.user.id;
      if (!uid) throw new Error('Sin sesión');

      const ext  = type === 'video' ? 'mp4' : mime.includes('png') ? 'png' : mime.includes('webp') ? 'webp' : 'jpg';
      const path = `${uid}/ad_${Date.now()}.${ext}`;
      const buf  = await fetch(uri).then(r => r.arrayBuffer());

      const { error: upErr } = await supabase.storage
        .from('advertisements')
        .upload(path, buf, { contentType: mime, upsert: false });

      if (upErr) throw upErr;

      const { data: urlData } = supabase.storage.from('advertisements').getPublicUrl(path);
      setMediaUrl(urlData.publicUrl);
    } catch (e: any) {
      Alert.alert('Error al subir', e.message ?? 'Intenta de nuevo.');
      setMediaUri(null);
      setMediaType('none');
    } finally {
      setUploading(false);
    }
  };

  const removeMedia = () => {
    setMediaUri(null);
    setMediaType('none');
    setMediaUrl(null);
    setDurationSeconds(null);
  };

  // ─── Handlers con validación de contacto externo ─────────────────────────
  const handleTitleChange = (val: string) => {
    setTitle(val);
    if (containsContactInfo(val)) {
      setTitleError('Por seguridad, no se permiten teléfonos ni @usuarios en el título.');
    } else {
      setTitleError('');
    }
  };

  const handleSubtitleChange = (val: string) => {
    setSubtitle(val);
    if (containsContactInfo(val)) {
      setSubtitleError('Por seguridad, no se permiten teléfonos ni @usuarios.');
    } else {
      setSubtitleError('');
    }
  };

  // ─── Crear anuncio + Pagar ────────────────────────────────────────────────
  const handlePay = async () => {
    if (!adType) {
      Alert.alert('Error', 'Selecciona el tipo de anuncio.');
      return;
    }
    const isCustomMode = pkgMode === 'custom' && !preSelected;
    if (!isCustomMode && !selectedPackage) {
      Alert.alert('Error', 'Selecciona un paquete.');
      return;
    }
    // Para tipos simples el título se auto-rellena; para banner_home es obligatorio
    if (!title.trim() && !isSimpleAdType(adType)) {
      Alert.alert('Error', 'Escribe un título para tu anuncio.');
      return;
    }
    const customDaysNum = parseInt(customDays, 10);
    if (isCustomMode && (isNaN(customDaysNum) || customDaysNum < 1)) {
      Alert.alert('Error', 'Ingresa un número de días válido.');
      return;
    }
    // 📜 Declaración de derechos ANTES de pagar (Términos §6): la
    // responsabilidad del contenido del anuncio es de quien lo sube.
    const rightsOk = await new Promise<boolean>(resolve => {
      Alert.alert(
        '📜 Sobre el contenido de tu anuncio',
        'Al pagar declaras BAJO TU RESPONSABILIDAD que las imágenes, videos y música de tu anuncio son tuyos o tienes autorización para usarlos. Si hay un reclamo de derechos de autor, Daricefy puede retirar el anuncio y la responsabilidad es de quien lo subió.\n\nTodo anuncio pasa revisión antes de publicarse.',
        [
          { text: 'Cancelar', style: 'cancel', onPress: () => resolve(false) },
          { text: 'Acepto, continuar', onPress: () => resolve(true) },
        ],
      );
    });
    if (!rightsOk) return;
    setPaying(true);
    try {
      // 🚦 CUPO: preguntar ANTES de cobrar si hay lugar donde saldría el
      // anuncio (por estado; nacional/internacional usa la bolsa global).
      // El candado real también vive en create_advertisement_order.
      const checkStates = locationType === 'international'
        ? null
        : (targetStates.length > 0 ? targetStates : null);
      const { data: avail } = await supabase.rpc('check_ad_availability', {
        p_type:   adType,
        p_states: checkStates,
      });
      if (avail && avail.ok === false && avail.error === 'no_capacity') {
        const fullList = (avail.full_states ?? []) as string[];
        Alert.alert(
          '📢 Espacios llenos',
          avail.scope === 'global'
            ? 'Por ahora ya no hay lugares para publicidad nacional/internacional de este tipo. Intenta por estado, o vuelve cuando se libere un espacio.'
            : `Ya no hay lugares de este tipo de publicidad en: ${fullList.join(', ')}.\n\nQuita esos estados o vuelve cuando se libere un espacio (se liberan al vencer las campañas activas).`,
        );
        return;
      }
      // Paso 1: Crear el registro del anuncio
      const resolvedLinkType = adType === 'sponsored_group' ? 'group' : linkType;
      // Para sponsored_group: link_id = el grupo del usuario (sin él, approve_ad no crea
      // el registro en sponsored_groups y el grupo nunca aparece como destacado).
      const resolvedLinkId   = adType === 'sponsored_group'
        ? (userGroups[0]?.id ?? null)
        : (linkType === 'group' ? linkGroupId : null);
      const resolvedYoutube  = linkType === 'video' ? youtubeUrl.trim() || null : null;

      const dMultPay = demandInfo?.multiplier ?? 1.0;
      const lMultPay = LOCATION_MULT[locationType] ?? 1.0;
      const cMultPay = cityStatus?.price_multiplier ?? 1.0;

      // Precio final: fuente única — mismo valor que muestra la UI
      const finalPrice = calcFinalPrice({
        pkg:        isCustomMode ? null : selectedPackage,
        adType:     isCustomMode ? adType : null,
        dMult:      dMultPay,
        lMult:      lMultPay,
        cMult:      cMultPay,
        customDays: isCustomMode ? customDaysNum : 1,
      });

      // Fallback de título para tipos simples (auto-rellenado por useEffect)
      const effectiveTitle = title.trim() || (
        adType === 'sponsored_group' ? (userGroups[0]?.name ?? 'Grupo Destacado') : 'Anuncio en Perfil'
      );

      console.log('[PAYMENT]', {
        type:       adType,
        finalPrice,
        pkg:        selectedPackage ? { id: selectedPackage.id, tier: selectedPackage.tier, days: selectedPackage.duration_days } : null,
        cityStatus: cityStatus ? { is_seeding: cityStatus.is_seeding, price_multiplier: cityStatus.price_multiplier } : null,
        dMult: dMultPay, lMult: lMultPay, cMult: cMultPay,
        customMode: isCustomMode, customDays: isCustomMode ? customDaysNum : null,
      });

      const { data: orderData, error: orderErr } = await supabase.rpc('create_advertisement_order', {
        p_type:             adType,
        p_title:            effectiveTitle,
        p_subtitle:         subtitle.trim() || null,
        p_button_text:      buttonText.trim() || 'Contratar',
        p_media_url:        mediaUrl ?? null,
        p_media_type:       mediaType,
        p_package_id:       isCustomMode ? null : (selectedPackage?.id ?? null),
        p_link_type:        resolvedLinkType,
        p_link_id:          resolvedLinkId,
        p_location_type:    locationType,
        p_locations:        (locationType === 'city' || locationType === 'multi_city') && locationCities.length > 0
                              ? locationCities
                              : null,
        p_duration_seconds: durationSeconds ?? null,
        p_youtube_url:      resolvedYoutube,
        p_custom_days:      isCustomMode ? customDaysNum : null,
        p_total_price:      finalPrice,
        p_target_states:    (adType === 'banner_home' || adType === 'profile_ad')
                              && locationType !== 'international'
                              && targetStates.length > 0
                              ? targetStates
                              : null,
        p_target_country:   locationType === 'international' ? (targetCountry ?? 'global') : null,
      } as any);

      console.log('[handlePay] order creada:', orderData, 'error:', orderErr);

      if (orderErr) throw new Error(orderErr.message);
      if (!orderData?.ok) {
        if (orderData?.error === 'no_capacity') {
          const fl = (orderData?.full_states ?? []) as string[];
          throw new Error(fl.length > 0
            ? `Ya no hay espacio de publicidad en: ${fl.join(', ')}. Vuelve cuando se libere un lugar.`
            : 'Ya no hay espacios de publicidad nacional/internacional por ahora. Intenta por estado.');
        }
        if (orderData?.error === 'price_below_minimum') {
          throw new Error(`El precio mínimo para esta publicidad es $${orderData?.minimum}.`);
        }
        throw new Error(orderData?.error ?? 'No se pudo crear el anuncio');
      }

      const adId = orderData.ad_id as string;

      // Paso 1.5: elegir método — Stripe (tarjeta), Conekta (OXXO/SPEI) o,
      // para Destacados de 30 días, suscripción mensual que se renueva sola
      const offerSub = adType === 'sponsored_group'
        && !isCustomMode
        && selectedPackage?.duration_days === 30;
      const payMode = await new Promise<'stripe' | 'conekta' | 'sub' | null>(resolve => {
        const buttons: any[] = [
          { text: 'Cancelar', style: 'cancel', onPress: () => resolve(null) },
          { text: '💳 Tarjeta', onPress: () => resolve('stripe') },
          { text: '💵 OXXO, SPEI o tarjeta', onPress: () => resolve('conekta') },
        ];
        if (offerSub) {
          buttons.push({ text: '🔁 Mensual — se renueva solo', onPress: () => resolve('sub') });
        }
        Alert.alert(
          `Pagar $${finalPrice.toLocaleString('es-MX')} MXN`,
          '¿Cómo quieres pagar tu anuncio?',
          buttons,
        );
      });
      if (payMode === null) return;

      if (payMode === 'conekta') {
        // El webhook confirma y deja el anuncio en revisión — igual que Stripe
        const res = await startPromoConektaCheckout('ad', adId);
        if (!res.ok) throw new Error(res.error ?? 'No se pudo iniciar el pago');
        Alert.alert(
          '⏳ Esperando confirmación',
          'Con tarjeta se acredita en segundos; con OXXO o SPEI, cuando hagas el depósito. Al acreditarse, tu anuncio pasa a revisión y te avisamos cuando se apruebe.',
        );
        setSuccess(true);
        return;
      }

      if (payMode === 'sub') {
        // 🔁 Suscripción mensual del Destacado: primer cobro HOY; cada mes
        // se renueva solo (el webhook extiende 30 días con dinero real)
        const { data: { session: subSession } } = await supabase.auth.getSession();
        if (!subSession) throw new Error('Sesión expirada. Vuelve a iniciar sesión.');
        const { data: subData, error: subErr } = await supabase.functions.invoke('create-promo-subscription', {
          body:    { kind: 'sponsored', ad_id: adId },
          headers: { Authorization: `Bearer ${subSession.access_token}` },
        });
        if (subErr) throw new Error(subErr.message ?? 'Error de función');
        if ((subData as any)?.error) throw new Error((subData as any).error);
        const subSecret = (subData as any)?.payment_intent_client_secret as string | undefined;
        if (!subSecret) throw new Error('No se recibió el token de pago.');

        const { error: subInitErr } = await initPaymentSheet({
          paymentIntentClientSecret: subSecret,
          merchantDisplayName:       'Daricefy Ads',
          style:                     'alwaysDark',
        });
        if (subInitErr) throw new Error(subInitErr.message);
        const { error: subPayErr } = await presentPaymentSheet();
        if (subPayErr) {
          if (subPayErr.code === 'Canceled') {
            Alert.alert('Pago cancelado', 'Puedes intentarlo de nuevo cuando quieras.');
            return;
          }
          throw new Error(subPayErr.message);
        }
        Alert.alert(
          '✅ Suscripción activa',
          'Tu Destacado pasa a revisión y se activa al aprobarse. Cada mes se renueva solo — cancelas cuando quieras.',
        );
        setSuccess(true);
        return;
      }

      // Paso 2: Crear PaymentIntent en Stripe
      const { data: { session: paySession } } = await supabase.auth.getSession();
      if (!paySession) throw new Error('Sesión expirada. Vuelve a iniciar sesión.');
      const { data: stripeData, error: stripeErr } = await supabase.functions.invoke('create-ad-payment', {
        body: { ad_id: adId },
        headers: { Authorization: `Bearer ${paySession.access_token}` },
      });

      // No loguear stripeData completo: contiene el client_secret de Stripe
      console.log('[handlePay] ok:', !!(stripeData as any)?.client_secret, 'error:', stripeErr?.message ?? 'none');

      if (stripeErr) throw new Error(`Error de función: ${stripeErr.message ?? JSON.stringify(stripeErr)}`);
      if (!stripeData) throw new Error('Sin respuesta del servidor de pagos.');
      if (stripeData.error) throw new Error(`Stripe Error: ${stripeData.error}`);

      const clientSecret: string = stripeData.client_secret;
      if (!clientSecret) throw new Error('No se recibió el token de pago.');

      // Paso 3: Inicializar PaymentSheet de Stripe
      const { error: initError } = await initPaymentSheet({
        paymentIntentClientSecret: clientSecret,
        merchantDisplayName: 'Daricefy Ads',
        style: 'alwaysDark',
      });

      if (initError) throw new Error(`Error al inicializar pago: ${initError.message}`);

      // Paso 4: Mostrar hoja de pago nativa
      const { error: payError } = await presentPaymentSheet();

      if (payError) {
        if (payError.code === 'Canceled') {
          Alert.alert('Pago cancelado', 'Puedes intentarlo de nuevo cuando quieras.');
          return;
        }
        throw new Error(payError.message);
      }

      setSuccess(true);
    } catch (e: any) {
      console.error('[handlePay] Error:', e.message);
      Alert.alert('Error al generar pago', e.message ?? 'Intenta de nuevo.');
    } finally {
      setPaying(false);
    }
  };

  // ─── Navegación entre pasos ───────────────────────────────────────────────
  const canGoNext = () => {
    if (step === 0) return adType !== null;
    if (step === 1) return (
      title.trim().length >= 3 && !uploading &&
      !titleError && !subtitleError &&
      !(linkType === 'group' && userGroups.length > 0 && linkGroupId === null) &&
      !(linkType === 'video' && !isValidYoutubeUrl(youtubeUrl))
    );
    if (step === 2) {
      if (locationType === 'national' || locationType === 'international') return true;
      return locationCities.length > 0;
    }
    if (step === 3) {
      if (pkgMode === 'custom') return parseInt(customDays, 10) >= 1;
      return selectedPackage !== null;
    }
    return false;
  };

  const goNext = () => {
    if (step === 0 && isSimpleAdType(adType)) {
      setStep(3); // tipos simples desde selector: saltar contenido + ubicación
    } else if (isSimpleAdType(adType) && step === 3) {
      setStep(4); // tipos simples: paquetes → pago
    } else if (preSelected && step === 2) {
      setStep(4); // saltar selección de paquete, ya viene pre-seleccionado
    } else if (step < 4) {
      setStep(s => s + 1);
    }
  };

  const goBack = () => {
    if (isSimpleAdType(adType) && step === 3) {
      // Si el usuario eligió el tipo en el paso 0, volver ahí; si vino de navegación, salir
      startStep === 0 ? setStep(0) : navigation.goBack();
    } else if (isSimpleAdType(adType) && step === 4) {
      setStep(3); // tipos simples: pago → paquetes
    } else if (preSelected && step === 1) {
      navigation.goBack(); // volver a AdvertisingPackagesScreen
    } else if (preSelected && step === 2) {
      setStep(1);
    } else if (preSelected && step === 4) {
      setStep(2); // saltar hacia atrás sobre el paso de paquete
    } else if (step > 0) {
      setStep(s => s - 1);
    } else {
      navigation.goBack();
    }
  };

  // ─── Pantalla de éxito ────────────────────────────────────────────────────
  if (success) {
    return (
      <View style={s.container}>
        <Particles />
        <SafeAreaView style={s.successCenter}>
          <View style={s.successCard}>
            <CheckCircle size={56} color={COLORS.green} fill="rgba(0,230,118,0.15)" />
            <Text style={s.successTitle}>¡Anuncio enviado!</Text>
            <Text style={s.successSub}>
              Tu anuncio fue creado y está en revisión.{'\n'}
              Lo activaremos en 24h hábiles tras confirmar el pago.
            </Text>
            <View style={s.successSteps}>
              {['Pago confirmado', 'Revisión de contenido', 'Anuncio activo'].map((t, i) => (
                <View key={i} style={s.successStep}>
                  <View style={[s.successStepDot, i === 0 && s.successStepDotActive]} />
                  <Text style={s.successStepText}>{t}</Text>
                </View>
              ))}
            </View>
            <Pressable style={s.successBtn} onPress={() => navigation.goBack()}>
              <Text style={s.successBtnText}>Volver al inicio</Text>
            </Pressable>
          </View>
        </SafeAreaView>
      </View>
    );
  }

  // ─── Render principal ─────────────────────────────────────────────────────
  return (
    <View style={s.container}>
      <Particles />
      <SafeAreaView style={{ flex: 1 }}>
        {/* ── Header ── */}
        {(() => {
          const isSimple = isSimpleAdType(adType);
          const screenTitle = adType === 'sponsored_group' ? 'Promocionar grupo'
            : adType === 'profile_ad' ? 'Publicidad en Perfiles'
            : 'Crear anuncio';
          let subLabel = '';
          if (isSimple) {
            subLabel = step === 0 ? 'Paso 1 de 3 · Tipo'
              : step === 3 ? 'Paso 2 de 3 · Duración' : 'Paso 3 de 3 · Pago';
          } else if (preSelected) {
            subLabel = `Paso ${step === 1 ? 1 : step === 2 ? 2 : 3} de 3 · ${step === 1 ? 'Contenido' : step === 2 ? 'Ubicación' : 'Pago'}`;
          } else {
            subLabel = `Paso ${step + 1} de 5 · ${STEP_LABELS[step]}`;
          }
          return (
            <View style={s.header}>
              <Pressable style={s.backBtn} onPress={goBack}>
                <ArrowLeft size={20} color={COLORS.text} />
              </Pressable>
              <View style={{ flex: 1 }}>
                <Text style={s.headerTitle}>{screenTitle}</Text>
                <Text style={s.headerSub}>{subLabel}</Text>
              </View>
            </View>
          );
        })()}

        {/* ── Barra de progreso ── */}
        <View style={s.progressBar}>
          {(() => {
            const isSimple = isSimpleAdType(adType);
            if (isSimple) {
              // 3 segmentos: Tipo (step 0) → Duración (step 3) → Pago (step 4)
              return [0, 1, 2].map(i => {
                const activeI = step === 0 ? 0 : step === 3 ? 1 : 2;
                return <View key={i} style={[s.progressSegment, i <= activeI && s.progressSegmentActive]} />;
              });
            }
            return (preSelected ? STEP_LABELS_SHORT : STEP_LABELS).map((_, i) => {
              const preStepMap: Record<number, number> = { 1: 0, 2: 1, 4: 2 };
              const activeI = preSelected ? (preStepMap[step] ?? 0) : step;
              return <View key={i} style={[s.progressSegment, i <= activeI && s.progressSegmentActive]} />;
            });
          })()}
        </View>

        <KeyboardAvoidingView
          style={{ flex: 1 }}
          behavior={Platform.OS === 'ios' ? 'padding' : undefined}
        >
          <ScrollView
            contentContainerStyle={s.scroll}
            showsVerticalScrollIndicator={false}
            keyboardShouldPersistTaps="handled"
          >
            {/* ══════════════════════════════════════════════════════════
                PASO 1 — Tipo de anuncio
            ══════════════════════════════════════════════════════════ */}
            {step === 0 && (
              <View>
                <Text style={s.stepTitle}>¿Qué tipo de publicidad quieres?</Text>
                <Text style={s.stepSub}>Elige el formato que mejor se adapte a tu objetivo.</Text>

                {visibleAdTypes.map(at => (
                  <Pressable
                    key={at.type}
                    style={[s.typeCard, adType === at.type && { borderColor: at.color, backgroundColor: `${at.color}10` }]}
                    onPress={() => setAdType(at.type)}
                  >
                    <View style={[s.typeEmoji, { backgroundColor: `${at.color}20` }]}>
                      <Text style={{ fontSize: 26 }}>{at.emoji}</Text>
                    </View>
                    <View style={{ flex: 1 }}>
                      <Text style={[s.typeLabel, adType === at.type && { color: at.color }]}>{at.label}</Text>
                      <Text style={s.typeDesc}>{at.desc}</Text>
                    </View>
                    {adType === at.type && (
                      <CheckCircle size={20} color={at.color} fill={`${at.color}30`} />
                    )}
                  </Pressable>
                ))}

                {adType === 'sponsored_group' && (
                  <View style={s.notice}>
                    <Text style={s.noticeText}>
                      ⭐ Tu grupo aparecerá en la posición #1 de "Destacados" mientras el paquete esté activo.
                    </Text>
                  </View>
                )}
              </View>
            )}

            {/* ══════════════════════════════════════════════════════════
                PASO 2 — Contenido del anuncio
            ══════════════════════════════════════════════════════════ */}
            {step === 1 && (
              <View>
                <Text style={s.stepTitle}>Diseña tu anuncio</Text>
                <Text style={s.stepSub}>Agrega imagen o video y escribe el texto que verán los usuarios.</Text>

                {/* ── Media picker ── */}
                <Text style={s.label}>Imagen o Video <Text style={s.labelOptional}>(opcional)</Text></Text>
                {mediaUri ? (
                  <View style={s.mediaPreview}>
                    {mediaType === 'image' && (
                      <Image source={{ uri: mediaUri }} style={s.mediaImg} resizeMode="cover" />
                    )}
                    {mediaType === 'video' && (
                      <VideoPlayer
                        uri={mediaUri!}
                        style={s.mediaImg}
                        contentFit="cover"
                        nativeControls
                      />
                    )}
                    {uploading && (
                      <View style={s.mediaUploading}>
                        <ActivityIndicator color={COLORS.green} />
                        <Text style={s.mediaUploadingText}>Subiendo...</Text>
                      </View>
                    )}
                    {!uploading && mediaUrl && (
                      <View style={s.mediaReady}>
                        <CheckCircle size={14} color={COLORS.green} />
                        <Text style={s.mediaReadyText}>Listo</Text>
                      </View>
                    )}
                    <Pressable style={s.mediaRemove} onPress={removeMedia}>
                      <X size={16} color="#fff" />
                    </Pressable>
                  </View>
                ) : (
                  <>
                    <View style={s.mediaPicker}>
                      <Pressable style={s.mediaPickBtn} onPress={() => pickMedia('image')}>
                        <ImageIcon size={22} color={COLORS.green} />
                        <Text style={s.mediaPickText}>Imagen</Text>
                      </Pressable>
                      <View style={s.mediaDivider} />
                      <Pressable style={s.mediaPickBtn} onPress={() => pickMedia('video')}>
                        <Video size={22} color={COLORS.muted2} />
                        <Text style={[s.mediaPickText, { color: COLORS.muted2 }]}>Video</Text>
                      </Pressable>
                    </View>
                    <Text style={s.mediaHint}>Imagen: JPG/PNG/WebP · máx 5 MB &nbsp;·&nbsp; Video: MP4 · máx 20 MB · 30 s</Text>
                  </>
                )}

                {/* ── Nota de seguridad ── */}
                <View style={s.securityNote}>
                  <ShieldCheck size={14} color={COLORS.green} />
                  <Text style={s.securityNoteText}>
                    Por seguridad, las contrataciones se realizan dentro de la app. No se permiten teléfonos, @usuarios ni enlaces a redes sociales.
                  </Text>
                </View>

                {/* ── Título ── */}
                <Text style={s.label}>Título <Text style={s.labelRequired}>*</Text></Text>
                <TextInput
                  style={[s.input, !!titleError && s.inputError]}
                  value={title}
                  onChangeText={handleTitleChange}
                  placeholder="Ej: Música en vivo para tu boda"
                  placeholderTextColor={COLORS.muted}
                  maxLength={60}
                  autoCapitalize="sentences"
                />
                {titleError ? (
                  <Text style={s.fieldError}>{titleError}</Text>
                ) : (
                  <Text style={s.charCount}>{title.length}/60</Text>
                )}

                {/* ── Subtítulo ── */}
                <Text style={s.label}>Subtítulo <Text style={s.labelOptional}>(opcional)</Text></Text>
                <TextInput
                  style={[s.input, !!subtitleError && s.inputError]}
                  value={subtitle}
                  onChangeText={handleSubtitleChange}
                  placeholder="Ej: Cotizaciones desde $3,000 MXN"
                  placeholderTextColor={COLORS.muted}
                  maxLength={80}
                />
                {!!subtitleError && <Text style={s.fieldError}>{subtitleError}</Text>}

                {/* ── Botón CTA ── */}
                <Text style={s.label}>Texto del botón</Text>
                <View style={s.ctaRow}>
                  {['Contratar', 'Ver más', 'Reservar', 'Cotizar'].map(opt => (
                    <Pressable
                      key={opt}
                      style={[s.ctaChip, buttonText === opt && s.ctaChipActive]}
                      onPress={() => setButtonText(opt)}
                    >
                      <Text style={[s.ctaChipText, buttonText === opt && s.ctaChipTextActive]}>
                        {opt}
                      </Text>
                    </Pressable>
                  ))}
                </View>
                <TextInput
                  style={[s.input, { marginTop: 8 }]}
                  value={buttonText}
                  onChangeText={setButtonText}
                  placeholder="O escribe tu propio texto..."
                  placeholderTextColor={COLORS.muted}
                  maxLength={24}
                />

                {/* ── Enlace del botón CTA ── */}
                {adType !== 'sponsored_group' && (
                  <>
                    <Text style={s.label}>Enlace del botón <Text style={s.labelOptional}>(opcional)</Text></Text>
                    <View style={s.ctaRow}>
                      {([
                        { type: 'none',  label: 'Sin enlace' },
                        { type: 'group', label: 'Perfil de grupo' },
                        { type: 'video', label: '▶ Video YouTube' },
                      ] as const).map(opt => (
                        <Pressable
                          key={opt.type}
                          style={[s.ctaChip, linkType === opt.type && s.ctaChipActive]}
                          onPress={() => {
                            setLinkType(opt.type);
                            if (opt.type !== 'group') setLinkGroupId(null);
                            if (opt.type !== 'video') setYoutubeUrl('');
                          }}
                        >
                          <Text style={[s.ctaChipText, linkType === opt.type && s.ctaChipTextActive]}>{opt.label}</Text>
                        </Pressable>
                      ))}
                    </View>
                    {linkType === 'group' && userGroups.length > 0 && (
                      <View style={{ marginTop: 8 }}>
                        {userGroups.map(g => (
                          <Pressable
                            key={g.id}
                            style={[s.typeCard, { marginBottom: 8 }, linkGroupId === g.id && { borderColor: COLORS.green, backgroundColor: `${COLORS.green}10` }]}
                            onPress={() => setLinkGroupId(g.id)}
                          >
                            <Text style={[s.typeLabel, linkGroupId === g.id && { color: COLORS.green }]}>{g.name}</Text>
                            {linkGroupId === g.id && <CheckCircle size={18} color={COLORS.green} fill={`${COLORS.green}30`} />}
                          </Pressable>
                        ))}
                        {!linkGroupId && <Text style={s.fieldError}>Selecciona un grupo</Text>}
                      </View>
                    )}
                    {linkType === 'group' && userGroups.length === 0 && (
                      <Text style={s.fieldHint}>No tienes grupos registrados. El botón no tendrá enlace.</Text>
                    )}
                    {linkType === 'video' && (
                      <View style={{ marginTop: 8 }}>
                        <TextInput
                          style={s.input}
                          value={youtubeUrl}
                          onChangeText={setYoutubeUrl}
                          placeholder="https://youtube.com/watch?v=..."
                          placeholderTextColor={COLORS.muted}
                          autoCapitalize="none"
                          keyboardType="url"
                        />
                        {youtubeUrl.length > 0 && !isValidYoutubeUrl(youtubeUrl) && (
                          <Text style={s.fieldError}>Ingresa un link válido de YouTube</Text>
                        )}
                        {isValidYoutubeUrl(youtubeUrl) && (
                          <Text style={[s.fieldHint, { color: COLORS.green }]}>✓ Link de YouTube válido</Text>
                        )}
                        <Text style={s.fieldHint}>El video se reproducirá dentro de la app. Solo se permiten links de YouTube.</Text>
                      </View>
                    )}
                  </>
                )}

                {/* ── Vista previa mini ── */}
                {title.trim().length > 0 && (
                  <View style={s.preview}>
                    <Text style={s.previewLabel}>Vista previa</Text>
                    <View style={s.previewCard}>
                      {mediaUri && mediaType === 'image' && (
                        <Image source={{ uri: mediaUri }} style={s.previewImg} resizeMode="cover" />
                      )}
                      {mediaUri && mediaType === 'video' && (
                        <View style={[s.previewImg, s.previewVideoThumb]}>
                          <Play size={18} color={COLORS.green} fill={COLORS.green} />
                          {durationSeconds ? <Text style={s.previewVideoDur}>{durationSeconds}s</Text> : null}
                        </View>
                      )}
                      <View style={s.previewBody}>
                        <Text style={s.previewTag}>PUBLICIDAD</Text>
                        <Text style={s.previewTitle} numberOfLines={1}>{title}</Text>
                        {subtitle ? <Text style={s.previewSub} numberOfLines={1}>{subtitle}</Text> : null}
                        <View style={s.previewBtn}>
                          <Text style={s.previewBtnText}>{buttonText} →</Text>
                        </View>
                      </View>
                    </View>
                  </View>
                )}
              </View>
            )}

            {/* ══════════════════════════════════════════════════════════
                PASO 2 — Ubicación / Alcance geográfico
            ══════════════════════════════════════════════════════════ */}
            {step === 2 && (
              <View>
                <Text style={s.stepTitle}>¿Dónde quieres aparecer?</Text>
                <Text style={s.stepSub}>Elige el alcance geográfico de tu anuncio. El precio varía según el alcance.</Text>

                {(() => {
                  const countryLabel = (authProfile as any)?.country ?? 'México';
                  return LOCATION_OPTIONS.map(opt => {
                    const label = opt.type === 'national' ? `Todo ${countryLabel}` : opt.label;
                    const pricePerDay = adType
                      ? Math.ceil(BASE_PER_DAY[adType] * LOCATION_MULT[opt.type])
                      : null;
                    return (
                      <Pressable
                        key={opt.type}
                        style={[s.typeCard, locationType === opt.type && { borderColor: opt.color, backgroundColor: `${opt.color}10` }]}
                        onPress={() => {
                          setLocationType(opt.type);
                          if (opt.type === 'city' && locationCities.length === 0 && authProfile?.city) {
                            setLocationCities([authProfile.city]);
                          }
                          if (opt.type === 'national' || opt.type === 'international') {
                            setLocationCities([]);
                          }
                          if (opt.type === 'international') {
                            setTargetCountry('global');
                          } else {
                            setTargetCountry(null);
                          }
                        }}
                      >
                        <View style={[s.typeEmoji, { backgroundColor: `${opt.color}20` }]}>
                          <Text style={{ fontSize: 24 }}>{opt.emoji}</Text>
                        </View>
                        <View style={{ flex: 1 }}>
                          <Text style={[s.typeLabel, locationType === opt.type && { color: opt.color }]}>{label}</Text>
                          <Text style={s.typeDesc}>{opt.desc}</Text>
                          {pricePerDay !== null && (
                            <Text style={[s.locPriceHint, locationType === opt.type && { color: opt.color }]}>
                              Desde ${pricePerDay.toLocaleString('es-MX')} / día
                            </Text>
                          )}
                        </View>
                        {locationType === opt.type && (
                          <CheckCircle size={20} color={opt.color} fill={`${opt.color}30`} />
                        )}
                      </Pressable>
                    );
                  });
                })()}

                {/* Badge de demanda */}
                {demandInfo && demandInfo.demand_level !== 'medium' && (
                  <View style={[
                    s.demandBadge,
                    demandInfo.demand_level === 'high' ? s.demandBadgeHigh : s.demandBadgeLow,
                  ]}>
                    <Text style={[
                      s.demandBadgeText,
                      demandInfo.demand_level === 'high' ? s.demandBadgeTextHigh : s.demandBadgeTextLow,
                    ]}>
                      {demandInfo.demand_level === 'high' ? '🔥' : '🟢'} {demandInfo.message}
                      {demandInfo.demand_level === 'high' ? ' · Los precios se ajustan a la demanda' : ''}
                    </Text>
                  </View>
                )}

                {/* Info banner para internacional */}
                {locationType === 'international' && (
                  <View style={s.intlBanner}>
                    <Text style={s.intlBannerText}>
                      🌍 Tu anuncio se mostrará a usuarios de cualquier país. Ideal para grupos con proyección internacional o que viajan al extranjero.
                    </Text>
                  </View>
                )}

                {/* Segmentación por estado — solo para banner_home y profile_ad, no internacional */}
                {(adType === 'banner_home' || adType === 'profile_ad') && locationType !== 'international' && (
                  <View style={{ marginTop: 20 }}>
                    <Text style={s.label}>
                      Segmentación por estado
                      <Text style={s.labelOptional}> (opcional)</Text>
                    </Text>
                    <Text style={[s.stepSub, { marginBottom: 8, marginTop: 2 }]}>
                      {targetStates.length === 0
                        ? 'Sin restricción — visible en todo el país'
                        : `${targetStates.length} estado${targetStates.length > 1 ? 's' : ''} seleccionado${targetStates.length > 1 ? 's' : ''}`}
                    </Text>

                    {/* Chip "Sin restricción" */}
                    <Pressable
                      style={[
                        s.cityChip,
                        { marginBottom: 10 },
                        targetStates.length === 0 && { backgroundColor: COLORS.green + '30', borderColor: COLORS.green },
                      ]}
                      onPress={() => setTargetStates([])}
                    >
                      <Text style={[s.cityChipText, targetStates.length === 0 && { color: COLORS.green }]}>
                        🌎 Todo el país
                      </Text>
                    </Pressable>

                    {/* Buscador de estados */}
                    <TextInput
                      style={[s.input, { marginBottom: 10 }]}
                      value={stateSearch}
                      onChangeText={setStateSearch}
                      placeholder="Buscar estado..."
                      placeholderTextColor={COLORS.muted}
                      autoCapitalize="words"
                      autoCorrect={false}
                    />

                    {/* Grid de estados filtrados */}
                    <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 6 }}>
                      {MEXICO_STATES
                        .filter(st => !stateSearch.trim() || st.toLowerCase().includes(stateSearch.toLowerCase().trim()))
                        .map(st => {
                          const selected = targetStates.includes(st);
                          return (
                            <Pressable
                              key={st}
                              onPress={() => toggleState(st)}
                              style={[
                                s.cityChip,
                                selected && { backgroundColor: COLORS.green + '25', borderColor: COLORS.green },
                              ]}
                            >
                              <Text style={[s.cityChipText, selected && { color: COLORS.green }]}>
                                {selected ? '✓ ' : ''}{st}
                              </Text>
                            </Pressable>
                          );
                        })}
                    </View>
                  </View>
                )}

                {/* Selector de ciudades para city / multi_city */}
                {(locationType === 'city' || locationType === 'multi_city') && (
                  <View style={s.citiesBox}>
                    <Text style={s.label}>
                      {locationType === 'city' ? 'Ciudad objetivo' : 'Ciudades objetivo'}
                      {locationType === 'multi_city' && <Text style={s.labelOptional}> (mínimo 2, máximo 5)</Text>}
                    </Text>

                    {/* Chips de ciudades seleccionadas */}
                    {locationCities.length > 0 && (
                      <View style={s.cityChipsRow}>
                        {locationCities.map(c => (
                          <View key={c} style={s.cityChip}>
                            <Text style={s.cityChipText}>📍 {c}</Text>
                            <Pressable
                              onPress={() => setLocationCities(prev => prev.filter(x => x !== c))}
                              style={s.cityChipRemove}
                            >
                              <X size={12} color="#fff" />
                            </Pressable>
                          </View>
                        ))}
                      </View>
                    )}

                    {/* Input para agregar ciudad */}
                    {((locationType === 'city' && locationCities.length < 1) ||
                      (locationType === 'multi_city' && locationCities.length < 5)) && (
                      <View style={s.cityInputRow}>
                        <TextInput
                          style={[s.input, { flex: 1 }]}
                          value={cityInput}
                          onChangeText={setCityInput}
                          placeholder="Ej: Guadalajara"
                          placeholderTextColor={COLORS.muted}
                          autoCapitalize="words"
                          autoCorrect={false}
                          onSubmitEditing={() => {
                            const city = cityInput.trim();
                            if (city && !locationCities.includes(city)) {
                              setLocationCities(prev => [...prev, city]);
                              setCityInput('');
                            }
                          }}
                        />
                        <Pressable
                          style={[s.cityAddBtn, !cityInput.trim() && { opacity: 0.4 }]}
                          disabled={!cityInput.trim()}
                          onPress={() => {
                            const city = cityInput.trim();
                            if (city && !locationCities.includes(city)) {
                              setLocationCities(prev => [...prev, city]);
                              setCityInput('');
                            }
                          }}
                        >
                          <Text style={s.cityAddBtnText}>+ Agregar</Text>
                        </Pressable>
                      </View>
                    )}
                  </View>
                )}
              </View>
            )}

            {/* ══════════════════════════════════════════════════════════
                PASO 3 — Seleccionar paquete
            ══════════════════════════════════════════════════════════ */}
            {step === 3 && (() => {
              const dMult    = demandInfo?.multiplier ?? 1.0;
              const lMult    = LOCATION_MULT[locationType];
              const cMult    = cityStatus?.price_multiplier ?? 1.0;
              const perDay   = adType ? BASE_PER_DAY[adType] : 0;
              const cDays    = Math.max(1, parseInt(customDays, 10) || 1);
              const cPrice   = Math.ceil(perDay * cDays * dMult * lMult * cMult);
              return (
              <View>
                <Text style={s.stepTitle}>
                  {isSimpleAdType(adType) ? 'Selecciona la duración' : 'Elige tu plan'}
                </Text>
                <Text style={s.stepSub}>
                  {adType === 'banner_home'
                    ? 'Tu anuncio aparecerá en el carousel del inicio durante el periodo elegido.'
                    : adType === 'sponsored_group'
                    ? 'Tu grupo aparecerá primero en "Destacados" durante el periodo elegido. Solo elige cuántos días.'
                    : 'Tu anuncio aparecerá en los perfiles de grupos durante el periodo elegido. Solo elige cuántos días.'}
                </Text>

                {/* Tabs Paquetes / Personalizar — oculto en tipos simples */}
                {!isSimpleAdType(adType) && (
                  <View style={s.pkgModeTabs}>
                    <Pressable
                      style={[s.pkgModeTab, pkgMode === 'packages' && s.pkgModeTabActive]}
                      onPress={() => setPkgMode('packages')}
                    >
                      <Text style={[s.pkgModeTabText, pkgMode === 'packages' && s.pkgModeTabTextActive]}>
                        📦 Paquetes
                      </Text>
                    </Pressable>
                    <Pressable
                      style={[s.pkgModeTab, pkgMode === 'custom' && s.pkgModeTabActive]}
                      onPress={() => { setPkgMode('custom'); setSelectedPackage(null); }}
                    >
                      <Text style={[s.pkgModeTabText, pkgMode === 'custom' && s.pkgModeTabTextActive]}>
                        ✏️ Personalizar
                      </Text>
                    </Pressable>
                  </View>
                )}

                {/* Banner de demanda */}
                {demandInfo && demandInfo.demand_level !== 'medium' && (
                  <View style={[
                    s.demandBadge,
                    demandInfo.demand_level === 'high' ? s.demandBadgeHigh : s.demandBadgeLow,
                    { marginBottom: 16 },
                  ]}>
                    <Text style={[
                      s.demandBadgeText,
                      demandInfo.demand_level === 'high' ? s.demandBadgeTextHigh : s.demandBadgeTextLow,
                    ]}>
                      {demandInfo.demand_level === 'high'
                        ? `🔥 Alta demanda · ×${dMult}`
                        : `🟢 Precio especial disponible`}
                    </Text>
                  </View>
                )}

                {/* ── MODO PAQUETES ── */}
                {pkgMode === 'packages' && (
                  loadingPkgs ? (
                    <ActivityIndicator color={COLORS.green} style={{ marginTop: 40 }} />
                  ) : packages.filter(p => !p.location_scope || p.location_scope === locationType).length === 0 ? (
                    <View style={s.emptyPkgs}>
                      <Megaphone size={32} color={COLORS.muted} />
                      <Text style={s.emptyPkgsText}>No hay paquetes disponibles para el alcance seleccionado.</Text>
                    </View>
                  ) : (
                    packages
                      .filter(p => !p.location_scope || p.location_scope === locationType)
                      // Dedup: mismo type + tier + duration_days (por si hay filas duplicadas en DB)
                      .filter((pkg, i, arr) =>
                        arr.findIndex(p =>
                          p.type === pkg.type &&
                          (p.tier ?? '') === (pkg.tier ?? '') &&
                          p.duration_days === pkg.duration_days
                        ) === i
                      )
                      .map(pkg => {
                      const finalPrice = calcFinalPrice({ pkg, dMult, lMult, cMult });
                      const isSimple = isSimpleAdType(adType);
                      const est = isSimple
                        ? calcSimpleEstimates(adType, pkg.duration_days, demandInfo?.demand_level)
                        : null;
                      return (
                        <Pressable
                          key={pkg.id}
                          style={[s.pkgCard, selectedPackage?.id === pkg.id && s.pkgCardSelected,
                            isSimple && { flexDirection: 'column', alignItems: 'stretch' }]}
                          onPress={() => setSelectedPackage(pkg)}
                        >
                          {/* Fila principal: nombre + precio */}
                          <View style={{ flexDirection: 'row', alignItems: 'center' }}>
                            <View style={{ flex: 1 }}>
                              <View style={s.pkgHeader}>
                                <Text style={s.pkgName}>{pkg.name}</Text>
                                {selectedPackage?.id === pkg.id && (
                                  <CheckCircle size={18} color={COLORS.green} fill="rgba(0,230,118,0.2)" />
                                )}
                              </View>
                              {pkg.description && (
                                <Text style={s.pkgDesc}>{pkg.description}</Text>
                              )}
                              <View style={s.pkgMeta}>
                                <View style={s.pkgDuration}>
                                  <Text style={s.pkgDurationText}>
                                    {pkg.duration_days >= 30
                                      ? `${Math.round(pkg.duration_days / 30)} mes${pkg.duration_days >= 60 ? 'es' : ''}`
                                      : `${pkg.duration_days} días`}
                                  </Text>
                                </View>
                                {lMult > 1 && (
                                  <Text style={s.pkgScopeBadge}>
                                    {locationType === 'multi_city'    ? '×1.5 alcance'
                                      : locationType === 'international' ? '×3.5 global'
                                      : '×2 nacional'}
                                  </Text>
                                )}
                              </View>
                            </View>
                            <View style={{ alignItems: 'flex-end', marginLeft: 12 }}>
                              <Text style={[s.pkgPrice, selectedPackage?.id === pkg.id && s.pkgPriceActive]}>
                                ${finalPrice.toLocaleString('es-MX', { minimumFractionDigits: 0 })}
                                <Text style={s.pkgCurrency}> MXN</Text>
                              </Text>
                              {(dMult > 1 || lMult > 1) && (
                                <Text style={s.pkgBasePrice}>
                                  base ${pkg.price.toLocaleString('es-MX', { minimumFractionDigits: 0 })}
                                </Text>
                              )}
                            </View>
                          </View>

                          {/* Bloque de valor percibido — solo tipos simples */}
                          {isSimple && est && (
                            <View style={s.simpleValueBox}>
                              <Text style={s.simpleValueLine}>
                                {adType === 'sponsored_group'
                                  ? '⭐ Tu grupo aparecerá primero en tu ciudad'
                                  : '👤 Más clientes verán tu perfil'}
                              </Text>
                              <Text style={s.simpleValueEst}>
                                Recibirás aproximadamente {est.min}–{est.max} solicitudes
                              </Text>
                              <Text style={s.simpleValueSub}>
                                La mayoría de los grupos activos reciben clientes en este rango
                              </Text>
                              <Text style={s.simpleValueComparison}>
                                {getDemandComparisonText(demandInfo?.demand_level)}
                              </Text>
                              {demandInfo?.demand_level === 'high' && (
                                <Text style={s.simpleValueHigh}>
                                  🔥 Otros grupos ya están aprovechando esta demanda
                                </Text>
                              )}
                            </View>
                          )}
                        </Pressable>
                      );
                    })
                  )
                )}

                {/* ── MODO PERSONALIZADO ── */}
                {pkgMode === 'custom' && (
                  <View style={s.customPanel}>
                    <Text style={s.customPanelTitle}>Configura tu anuncio</Text>

                    {/* Días */}
                    <Text style={s.label}>Número de días</Text>
                    <View style={s.customDaysRow}>
                      {[3, 7, 14, 30].map(d => (
                        <Pressable
                          key={d}
                          style={[s.customDayChip, customDays === String(d) && s.customDayChipActive]}
                          onPress={() => setCustomDays(String(d))}
                        >
                          <Text style={[s.customDayChipText, customDays === String(d) && s.customDayChipTextActive]}>
                            {d}d
                          </Text>
                        </Pressable>
                      ))}
                      <TextInput
                        style={s.customDaysInput}
                        value={customDays}
                        onChangeText={v => setCustomDays(v.replace(/[^0-9]/g, ''))}
                        keyboardType="numeric"
                        placeholder="días"
                        placeholderTextColor={COLORS.muted}
                        maxLength={3}
                      />
                    </View>

                    {/* Desglose de precio */}
                    <View style={s.customPriceBox}>
                      <View style={s.customPriceRow}>
                        <Text style={s.customPriceLabel}>Base ({cDays} días × ${perDay}/día)</Text>
                        <Text style={s.customPriceVal}>${(perDay * cDays).toLocaleString()}</Text>
                      </View>
                      {dMult > 1 && (
                        <View style={s.customPriceRow}>
                          <Text style={s.customPriceLabel}>Demanda</Text>
                          <Text style={[s.customPriceVal, { color: '#ef4444' }]}>×{dMult}</Text>
                        </View>
                      )}
                      <View style={s.customPriceRow}>
                        <Text style={s.customPriceLabel}>
                          Alcance ({locationType === 'city' ? 'ciudad'
                            : locationType === 'multi_city' ? 'varias ciudades'
                            : locationType === 'international' ? 'internacional'
                            : 'nacional'})
                        </Text>
                        <Text style={[s.customPriceVal, lMult > 1 ? { color: '#F59E0B' } : {}]}>×{lMult}</Text>
                      </View>
                      <View style={[s.customPriceRow, s.customPriceTotalRow]}>
                        <Text style={s.customPriceTotalLabel}>Total</Text>
                        <Text style={s.customPriceTotalVal}>${cPrice.toLocaleString()} MXN</Text>
                      </View>
                    </View>
                  </View>
                )}
              </View>
              );
            })()}

            {/* ══════════════════════════════════════════════════════════
                PASO 4 — Resumen y Pago
            ══════════════════════════════════════════════════════════ */}
            {step === 4 && (
              <View>
                <Text style={s.stepTitle}>Resumen y Pago</Text>
                <Text style={s.stepSub}>Revisa los detalles de tu anuncio antes de pagar.</Text>

                {/* Resumen del anuncio */}
                <View style={s.summaryCard}>
                  <Text style={s.summarySection}>Tu promoción</Text>
                  <View style={s.summaryRow}>
                    <Text style={s.summaryKey}>Tipo</Text>
                    <Text style={s.summaryVal}>
                      {adType === 'sponsored_group' ? '⭐ Grupo Destacado'
                        : adType === 'profile_ad'   ? '👤 Anuncio en Perfiles'
                        : (AD_TYPES.find(t => t.type === adType)?.label ?? adType)}
                    </Text>
                  </View>
                  {!isSimpleAdType(adType) && (
                    <>
                      {mediaUri && mediaType === 'image' && (
                        <Image source={{ uri: mediaUri }} style={s.summaryImg} resizeMode="cover" />
                      )}
                      <View style={s.summaryRow}>
                        <Text style={s.summaryKey}>Título</Text>
                        <Text style={s.summaryVal} numberOfLines={1}>{title}</Text>
                      </View>
                      {subtitle ? (
                        <View style={s.summaryRow}>
                          <Text style={s.summaryKey}>Subtítulo</Text>
                          <Text style={s.summaryVal} numberOfLines={1}>{subtitle}</Text>
                        </View>
                      ) : null}
                      <View style={s.summaryRow}>
                        <Text style={s.summaryKey}>Botón</Text>
                        <Text style={s.summaryVal}>{buttonText} →</Text>
                      </View>
                      {mediaType !== 'none' && (
                        <View style={s.summaryRow}>
                          <Text style={s.summaryKey}>Media</Text>
                          <Text style={[s.summaryVal, { color: COLORS.green }]}>
                            {mediaType === 'image' ? '✓ Imagen subida' : '✓ Video subido'}
                          </Text>
                        </View>
                      )}
                      <View style={s.summaryRow}>
                        <Text style={s.summaryKey}>Alcance</Text>
                        <Text style={s.summaryVal}>
                          {locationType === 'international' ? '🌍 Internacional'
                            : locationType === 'national'   ? `🌎 Todo ${(authProfile as any)?.country ?? 'el País'}`
                            : locationType === 'multi_city' ? `🗺️ ${locationCities.join(', ')}`
                            : `📍 ${locationCities[0] ?? 'Mi ciudad'}`}
                        </Text>
                      </View>
                    </>
                  )}
                  {isSimpleAdType(adType) && locationCities[0] && (
                    <View style={s.summaryRow}>
                      <Text style={s.summaryKey}>Ciudad</Text>
                      <Text style={s.summaryVal}>📍 {locationCities[0]}</Text>
                    </View>
                  )}
                </View>

                {/* Resumen del paquete o plan personalizado */}
                {(selectedPackage || pkgMode === 'custom') && (() => {
                  const dMult    = demandInfo?.multiplier ?? 1.0;
                  const lMult    = LOCATION_MULT[locationType];
                  const cMult    = cityStatus?.price_multiplier ?? 1.0;
                  const cDays    = Math.max(1, parseInt(customDays, 10) || 1);
                  const isCustom = pkgMode === 'custom' && !selectedPackage;
                  const totalPrice = calcFinalPrice({
                    pkg:        isCustom ? null : selectedPackage,
                    adType:     isCustom ? adType : null,
                    dMult, lMult, cMult,
                    customDays: cDays,
                  });
                  return (
                    <View style={s.summaryCard}>
                      <Text style={s.summarySection}>{isCustom ? 'Plan personalizado' : 'Paquete seleccionado'}</Text>
                      <View style={s.summaryRow}>
                        <Text style={s.summaryKey}>Plan</Text>
                        <Text style={s.summaryVal}>
                          {isCustom ? `${cDays} días personalizados` : selectedPackage!.name}
                        </Text>
                      </View>
                      <View style={s.summaryRow}>
                        <Text style={s.summaryKey}>Duración</Text>
                        <Text style={s.summaryVal}>
                          {isCustom
                            ? `${cDays} días`
                            : selectedPackage!.duration_days >= 30
                              ? `${Math.round(selectedPackage!.duration_days / 30)} mes${selectedPackage!.duration_days >= 60 ? 'es' : ''}`
                              : `${selectedPackage!.duration_days} días`}
                        </Text>
                      </View>
                      {lMult > 1 && (
                        <View style={s.summaryRow}>
                          <Text style={s.summaryKey}>Multiplicador</Text>
                          <Text style={[s.summaryVal, { color: locationType === 'international' ? '#8B5CF6' : '#F59E0B' }]}>
                            {locationType === 'multi_city'    ? 'Varias ciudades ×1.5'
                              : locationType === 'international' ? 'Internacional ×3.5'
                              : 'Nacional ×2.0'}
                          </Text>
                        </View>
                      )}
                      {dMult > 1 && (
                        <View style={s.summaryRow}>
                          <Text style={s.summaryKey}>Demanda</Text>
                          <Text style={[s.summaryVal, { color: '#ef4444' }]}>×{dMult} 🔥</Text>
                        </View>
                      )}
                      <View style={[s.summaryRow, s.summaryRowTotal]}>
                        <Text style={s.summaryTotalKey}>Total</Text>
                        <Text style={s.summaryTotalVal}>
                          ${totalPrice.toLocaleString('es-MX', { minimumFractionDigits: 0 })} MXN
                        </Text>
                      </View>
                    </View>
                  );
                })()}

                {/* Info de flujo */}
                <View style={s.flowInfo}>
                  {[
                    { n: '1', t: 'Pago seguro', d: 'Tarjeta, OXXO o SPEI — tú eliges' },
                    { n: '2', t: 'Revisión', d: 'Nuestro equipo revisa el contenido en 24h' },
                    { n: '3', t: 'Tu anuncio en vivo', d: 'Aparece automáticamente al ser aprobado' },
                  ].map(item => (
                    <View key={item.n} style={s.flowStep}>
                      <View style={s.flowNum}>
                        <Text style={s.flowNumText}>{item.n}</Text>
                      </View>
                      <View style={{ flex: 1 }}>
                        <Text style={s.flowTitle}>{item.t}</Text>
                        <Text style={s.flowDesc}>{item.d}</Text>
                      </View>
                    </View>
                  ))}
                </View>

                {/* Botón de pago */}
                <Pressable
                  style={[s.payBtn, paying && s.payBtnDisabled]}
                  onPress={handlePay}
                  disabled={paying}
                >
                  {paying ? (
                    <ActivityIndicator color="#000" />
                  ) : (
                    <Text style={s.payBtnText}>
                      💳 Pagar ${calcFinalPrice({
                        pkg:        (pkgMode !== 'custom' && selectedPackage) ? selectedPackage : null,
                        adType:     (pkgMode === 'custom' || !selectedPackage) ? adType : null,
                        dMult:      demandInfo?.multiplier ?? 1.0,
                        lMult:      LOCATION_MULT[locationType],
                        cMult:      cityStatus?.price_multiplier ?? 1.0,
                        customDays: Math.max(1, parseInt(customDays, 10) || 1),
                      }).toLocaleString('es-MX')} MXN
                    </Text>
                  )}
                </Pressable>

                <Text style={s.payNote}>
                  Pago único: eliges tarjeta, OXXO o SPEI al continuar. Solo la opción "Mensual" del Destacado se renueva sola cada mes (cancelas cuando quieras).
                </Text>
              </View>
            )}

            {/* ── Spacer ── */}
            <View style={{ height: 24 }} />
          </ScrollView>
        </KeyboardAvoidingView>

        {/* ── Botón continuar (pasos 0-3) ── */}
        {step < 4 && (
          <View style={s.footer}>
            <Pressable
              style={[s.nextBtn, !canGoNext() && s.nextBtnDisabled]}
              onPress={goNext}
              disabled={!canGoNext()}
            >
              <Text style={s.nextBtnText}>
                {step === 3 ? 'Continuar al pago' : 'Continuar'}
              </Text>
              <ChevronRight size={18} color={canGoNext() ? '#000' : COLORS.muted} />
            </Pressable>
          </View>
        )}
      </SafeAreaView>
    </View>
  );
}

// ─── Estilos ──────────────────────────────────────────────────────────────────

const s = StyleSheet.create({
  container: { flex: 1, backgroundColor: COLORS.bg },

  // Header
  header: {
    flexDirection: 'row', alignItems: 'center', gap: 12,
    paddingHorizontal: SPACING.xl, paddingVertical: 14,
    borderBottomWidth: 1, borderBottomColor: COLORS.border,
  },
  backBtn: {
    width: 40, height: 40, borderRadius: 12,
    backgroundColor: COLORS.card, borderWidth: 1, borderColor: COLORS.border,
    alignItems: 'center', justifyContent: 'center',
  },
  headerTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 16, color: COLORS.text },
  headerSub:   { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted, marginTop: 1 },

  // Progress bar
  progressBar: {
    flexDirection: 'row', gap: 4,
    paddingHorizontal: SPACING.xl, paddingVertical: 10,
  },
  progressSegment: {
    flex: 1, height: 3, borderRadius: 2,
    backgroundColor: COLORS.card2,
  },
  progressSegmentActive: { backgroundColor: COLORS.green },

  scroll: { paddingHorizontal: SPACING.xl, paddingTop: 20 },

  stepTitle: { fontFamily: FONTS.title, fontSize: 22, color: COLORS.text, marginBottom: 6 },
  stepSub:   { fontFamily: FONTS.body, fontSize: 14, color: COLORS.muted2, lineHeight: 20, marginBottom: 24 },

  // Tipo de anuncio
  typeCard: {
    flexDirection: 'row', alignItems: 'flex-start', gap: 14,
    backgroundColor: COLORS.card, borderRadius: RADIUS.xl,
    borderWidth: 1, borderColor: COLORS.border,
    padding: 16, marginBottom: 12,
  },
  typeEmoji: {
    width: 52, height: 52, borderRadius: RADIUS.lg,
    alignItems: 'center', justifyContent: 'center',
  },
  typeLabel: { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.text, marginBottom: 4 },
  typeDesc:  { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, lineHeight: 18 },
  notice: {
    backgroundColor: 'rgba(255,215,0,0.08)', borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: 'rgba(255,215,0,0.25)',
    padding: 14, marginTop: 8,
  },
  noticeText: { fontFamily: FONTS.body, fontSize: 13, color: '#FFD700', lineHeight: 20 },

  // Precio preview por opción de ubicación
  locPriceHint: {
    fontFamily: FONTS.bodyMedium, fontSize: 11, color: COLORS.muted, marginTop: 4,
  },

  // Banner internacional
  intlBanner: {
    backgroundColor: 'rgba(139,92,246,0.09)', borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: 'rgba(139,92,246,0.3)',
    padding: 12, marginTop: 8,
  },
  intlBannerText: {
    fontFamily: FONTS.body, fontSize: 12, color: '#C4B5FD', lineHeight: 18,
  },

  // Ubicación
  citiesBox: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border,
    padding: 14, marginTop: 12,
  },
  cityChipsRow: {
    flexDirection: 'row', flexWrap: 'wrap', gap: 8, marginBottom: 10,
  },
  cityChip: {
    flexDirection: 'row', alignItems: 'center', gap: 6,
    backgroundColor: 'rgba(0,230,118,0.12)', borderRadius: RADIUS.full,
    borderWidth: 1, borderColor: COLORS.green,
    paddingHorizontal: 12, paddingVertical: 6,
  },
  cityChipText: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.green },
  cityChipRemove: {
    width: 18, height: 18, borderRadius: 9,
    backgroundColor: 'rgba(0,230,118,0.25)',
    alignItems: 'center', justifyContent: 'center',
  },
  cityInputRow: { flexDirection: 'row', gap: 10, alignItems: 'center' },
  cityAddBtn: {
    backgroundColor: COLORS.green, borderRadius: RADIUS.md,
    paddingHorizontal: 14, paddingVertical: 12,
  },
  cityAddBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: '#000' },

  // Demand badge
  demandBadge: {
    borderRadius: RADIUS.lg, borderWidth: 1,
    paddingHorizontal: 14, paddingVertical: 10,
    marginTop: 10, marginBottom: 4,
  },
  demandBadgeHigh: {
    backgroundColor: 'rgba(239,68,68,0.1)',
    borderColor: 'rgba(239,68,68,0.35)',
  },
  demandBadgeLow: {
    backgroundColor: 'rgba(0,230,118,0.08)',
    borderColor: 'rgba(0,230,118,0.30)',
  },
  demandBadgeText: { fontFamily: FONTS.bodyMedium, fontSize: 12 },
  demandBadgeTextHigh: { color: '#ef4444' },
  demandBadgeTextLow:  { color: COLORS.green },

  // Dynamic price
  pkgBasePrice: { fontFamily: FONTS.body, fontSize: 10, color: COLORS.muted, textDecorationLine: 'line-through', marginTop: 1 },

  // Contenido
  label:         { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted2, marginBottom: 8, marginTop: 16 },
  labelRequired: { color: COLORS.green },
  labelOptional: { color: COLORS.muted },
  input: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: COLORS.border,
    paddingHorizontal: 14, paddingVertical: 12,
    fontFamily: FONTS.body, fontSize: 15, color: COLORS.text,
  },
  charCount: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted, textAlign: 'right', marginTop: 4 },

  // Media picker
  mediaPicker: {
    flexDirection: 'row', backgroundColor: COLORS.card,
    borderRadius: RADIUS.lg, borderWidth: 1, borderColor: COLORS.border,
    overflow: 'hidden', height: 100,
  },
  mediaPickBtn: {
    flex: 1, alignItems: 'center', justifyContent: 'center', gap: 8,
  },
  mediaPickText: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.green },
  mediaDivider: { width: 1, backgroundColor: COLORS.border },

  mediaPreview: {
    borderRadius: RADIUS.lg, overflow: 'hidden',
    borderWidth: 1, borderColor: COLORS.border,
    height: 130, backgroundColor: COLORS.card,
    justifyContent: 'center', alignItems: 'center',
  },
  mediaImg:    { width: '100%', height: '100%', position: 'absolute' },
  mediaVideoPlaceholder: { alignItems: 'center', gap: 8 },
  mediaVideoText: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.green },
  mediaHint: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted, marginTop: 6, textAlign: 'center' },
  mediaUploading: {
    position: 'absolute', bottom: 8, left: 12,
    flexDirection: 'row', alignItems: 'center', gap: 8,
    backgroundColor: 'rgba(0,0,0,0.7)', borderRadius: 8, paddingHorizontal: 10, paddingVertical: 6,
  },
  mediaUploadingText: { fontFamily: FONTS.body, fontSize: 12, color: '#fff' },
  mediaReady: {
    position: 'absolute', bottom: 8, left: 12,
    flexDirection: 'row', alignItems: 'center', gap: 6,
    backgroundColor: 'rgba(0,0,0,0.7)', borderRadius: 8, paddingHorizontal: 10, paddingVertical: 6,
  },
  mediaReadyText: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.green },
  mediaRemove: {
    position: 'absolute', top: 8, right: 8,
    width: 28, height: 28, borderRadius: 14,
    backgroundColor: 'rgba(0,0,0,0.7)', alignItems: 'center', justifyContent: 'center',
  },

  // Security note
  securityNote: {
    flexDirection: 'row', alignItems: 'flex-start', gap: 8,
    backgroundColor: 'rgba(0,230,118,0.07)', borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.25)',
    padding: 12, marginBottom: 4,
  },
  securityNoteText: {
    flex: 1, fontFamily: FONTS.body, fontSize: 12,
    color: COLORS.muted2, lineHeight: 17,
  },

  // Field errors / hints
  fieldError: { fontFamily: FONTS.body, fontSize: 11, color: '#EF4444', marginTop: 4 },
  fieldHint:  { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted, marginTop: 4 },
  inputError: { borderColor: '#EF4444' },

  // CTA chips
  ctaRow: { flexDirection: 'row', flexWrap: 'wrap', gap: 8, marginTop: 4 },
  ctaChip: {
    paddingHorizontal: 14, paddingVertical: 8,
    backgroundColor: COLORS.card, borderRadius: RADIUS.full,
    borderWidth: 1, borderColor: COLORS.border,
  },
  ctaChipActive: { backgroundColor: 'rgba(0,230,118,0.12)', borderColor: COLORS.green },
  ctaChipText:   { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2 },
  ctaChipTextActive: { color: COLORS.green, fontFamily: FONTS.bodyMedium },

  // Preview
  preview: { marginTop: 24 },
  previewLabel: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.muted, marginBottom: 10, letterSpacing: 0.8 },
  previewCard: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border, overflow: 'hidden',
  },
  previewImg:        { width: '100%', height: 80 },
  previewVideoThumb: { backgroundColor: COLORS.card2, alignItems: 'center', justifyContent: 'center', flexDirection: 'row', gap: 6 },
  previewVideoDur:   { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.muted2 },
  previewBody:   { padding: 12 },
  previewTag:    { fontFamily: FONTS.bodyMedium, fontSize: 9, color: COLORS.muted, letterSpacing: 1.2, marginBottom: 4 },
  previewTitle:  { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.text, marginBottom: 3 },
  previewSub:    { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, marginBottom: 8 },
  previewBtn: {
    alignSelf: 'flex-start',
    backgroundColor: COLORS.green, borderRadius: RADIUS.full,
    paddingHorizontal: 12, paddingVertical: 6,
  },
  previewBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 12, color: '#000' },

  // Paquetes
  pkgCard: {
    flexDirection: 'row', alignItems: 'center',
    backgroundColor: COLORS.card, borderRadius: RADIUS.xl,
    borderWidth: 1, borderColor: COLORS.border,
    padding: 16, marginBottom: 12,
  },
  pkgCardSelected: {
    borderColor: COLORS.green,
    backgroundColor: 'rgba(0,230,118,0.06)',
  },
  pkgHeader:   { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', marginBottom: 4 },
  pkgName:     { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.text, flex: 1, marginRight: 8 },
  pkgDesc:     { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, lineHeight: 17, marginBottom: 8 },
  pkgMeta:     { flexDirection: 'row', gap: 8 },
  pkgDuration: {
    backgroundColor: COLORS.card2, borderRadius: RADIUS.full,
    paddingHorizontal: 10, paddingVertical: 4,
    borderWidth: 1, borderColor: COLORS.border,
  },
  pkgDurationText: { fontFamily: FONTS.bodyMedium, fontSize: 11, color: COLORS.muted2 },
  pkgPrice:        { fontFamily: FONTS.title, fontSize: 20, color: COLORS.text, marginLeft: 12 },
  pkgPriceActive:  { color: COLORS.green },
  pkgCurrency:     { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2 },

  emptyPkgs:     { alignItems: 'center', padding: 40, gap: 12 },
  emptyPkgsText: { fontFamily: FONTS.body, fontSize: 14, color: COLORS.muted, textAlign: 'center' },

  pkgScopeBadge: {
    fontFamily: FONTS.bodyMedium, fontSize: 10, color: '#F59E0B',
    marginLeft: 8, marginTop: 2,
  },

  // Tabs paquetes / personalizar (paso 3)
  pkgModeTabs: {
    flexDirection: 'row', gap: 8, marginBottom: 16,
  },
  pkgModeTab: {
    flex: 1, paddingVertical: 10, alignItems: 'center',
    borderRadius: RADIUS.lg, borderWidth: 1.5, borderColor: COLORS.border,
    backgroundColor: COLORS.card,
  },
  pkgModeTabActive: {
    borderColor: COLORS.green,
    backgroundColor: 'rgba(0,230,118,0.08)',
  },
  pkgModeTabText: {
    fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted2,
  },
  pkgModeTabTextActive: { color: COLORS.green },

  // Panel personalizado
  customPanel: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.xl,
    borderWidth: 1, borderColor: COLORS.border,
    padding: 16, marginBottom: 12,
  },
  customPanelTitle: {
    fontFamily: FONTS.bodyMedium, fontSize: 14, color: COLORS.text, marginBottom: 14,
  },
  customDaysRow: {
    flexDirection: 'row', gap: 8, alignItems: 'center', marginBottom: 16, flexWrap: 'wrap' as const,
  },
  customDayChip: {
    paddingHorizontal: 14, paddingVertical: 8,
    borderRadius: RADIUS.lg, borderWidth: 1.5, borderColor: COLORS.border,
    backgroundColor: COLORS.card2,
  },
  customDayChipActive: { borderColor: COLORS.green, backgroundColor: 'rgba(0,230,118,0.1)' },
  customDayChipText:       { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted2 },
  customDayChipTextActive: { color: COLORS.green },
  customDaysInput: {
    flex: 1, minWidth: 60, height: 38,
    backgroundColor: COLORS.card2, borderRadius: RADIUS.lg,
    borderWidth: 1.5, borderColor: COLORS.border,
    paddingHorizontal: 10,
    fontFamily: FONTS.body, fontSize: 13, color: COLORS.text,
    textAlign: 'center' as const,
  },
  customPriceBox: {
    backgroundColor: COLORS.card2, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border,
    padding: 12, gap: 8,
  },
  customPriceRow:      { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center' },
  customPriceLabel:    { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2 },
  customPriceVal:      { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.text },
  customPriceTotalRow: {
    borderTopWidth: 1, borderTopColor: COLORS.border, paddingTop: 8, marginTop: 4,
  },
  customPriceTotalLabel: { fontFamily: FONTS.bodyMedium, fontSize: 14, color: COLORS.text },
  customPriceTotalVal:   { fontFamily: FONTS.title, fontSize: 18, color: COLORS.green },

  // Resumen (paso 4)
  summaryCard: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.xl,
    borderWidth: 1, borderColor: COLORS.border,
    padding: 16, marginBottom: 16, overflow: 'hidden',
  },
  summarySection:  { fontFamily: FONTS.bodyMedium, fontSize: 11, color: COLORS.muted, letterSpacing: 1, marginBottom: 12 },
  summaryImg:      { width: '100%', height: 90, borderRadius: RADIUS.md, marginBottom: 12 },
  summaryRow:      { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center', paddingVertical: 7, borderTopWidth: 1, borderTopColor: COLORS.border },
  summaryRowTotal: { borderTopWidth: 1, borderTopColor: COLORS.border, marginTop: 4, paddingTop: 12 },
  summaryKey:      { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted },
  summaryVal:      { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.text, maxWidth: '60%', textAlign: 'right' },
  summaryTotalKey: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.text },
  summaryTotalVal: { fontFamily: FONTS.title, fontSize: 20, color: COLORS.green },

  // Flujo info
  flowInfo: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.xl,
    borderWidth: 1, borderColor: COLORS.border,
    padding: 16, marginBottom: 24, gap: 16,
  },
  flowStep:    { flexDirection: 'row', alignItems: 'flex-start', gap: 12 },
  flowNum: {
    width: 28, height: 28, borderRadius: 14,
    backgroundColor: 'rgba(0,230,118,0.12)',
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.3)',
    alignItems: 'center', justifyContent: 'center',
  },
  flowNumText:  { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.green },
  flowTitle:    { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.text, marginBottom: 2 },
  flowDesc:     { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2 },

  // Botón pago
  payBtn: {
    backgroundColor: COLORS.green, borderRadius: RADIUS.lg,
    paddingVertical: 16, alignItems: 'center', justifyContent: 'center',
    marginBottom: 12,
  },
  payBtnDisabled: { opacity: 0.5 },
  payBtnText:     { fontFamily: FONTS.bodySemiBold, fontSize: 16, color: '#000' },
  payNote:        { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted, textAlign: 'center', lineHeight: 18 },

  // Footer (botón continuar)
  footer: {
    paddingHorizontal: SPACING.xl, paddingVertical: 12,
    borderTopWidth: 1, borderTopColor: COLORS.border,
    backgroundColor: COLORS.bg,
  },
  nextBtn: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 8,
    backgroundColor: COLORS.green, borderRadius: RADIUS.lg, paddingVertical: 15,
  },
  nextBtnDisabled: { backgroundColor: COLORS.card, borderWidth: 1, borderColor: COLORS.border },
  nextBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 16, color: '#000' },

  // Éxito
  successCenter: { flex: 1, alignItems: 'center', justifyContent: 'center', padding: SPACING.xl },
  successCard: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.xl,
    borderWidth: 1, borderColor: COLORS.border,
    padding: 28, alignItems: 'center', width: '100%',
  },
  successTitle: { fontFamily: FONTS.title, fontSize: 24, color: COLORS.text, marginTop: 16, marginBottom: 10, textAlign: 'center' },
  successSub:   { fontFamily: FONTS.body, fontSize: 14, color: COLORS.muted2, textAlign: 'center', lineHeight: 22, marginBottom: 24 },
  successSteps: { width: '100%', gap: 12, marginBottom: 28 },
  successStep:  { flexDirection: 'row', alignItems: 'center', gap: 12 },
  successStepDot: {
    width: 10, height: 10, borderRadius: 5,
    backgroundColor: COLORS.card2, borderWidth: 1, borderColor: COLORS.border,
  },
  successStepDotActive: { backgroundColor: COLORS.green, borderColor: COLORS.green },
  successStepText: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2 },
  successBtn: {
    width: '100%', backgroundColor: COLORS.green,
    borderRadius: RADIUS.lg, paddingVertical: 14, alignItems: 'center',
  },
  successBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: '#000' },

  // Valor percibido — bloque debajo del precio en tipos simples
  simpleValueBox: {
    marginTop: 12,
    paddingTop: 12,
    borderTopWidth: 1,
    borderTopColor: COLORS.border,
    gap: 5,
  },
  simpleValueLine: {
    fontFamily: FONTS.bodyMedium,
    fontSize: 12,
    color: COLORS.muted2,
  },
  simpleValueEst: {
    fontFamily: FONTS.bodySemiBold,
    fontSize: 13,
    color: COLORS.green,
  },
  simpleValueSub: {
    fontFamily: FONTS.body,
    fontSize: 11,
    color: COLORS.muted,
    fontStyle: 'italic' as const,
  },
  simpleValueComparison: {
    fontFamily: FONTS.bodyMedium,
    fontSize: 11,
    color: COLORS.green,
    marginTop: 2,
  },
  simpleValueHigh: {
    fontFamily: FONTS.bodyMedium,
    fontSize: 12,
    color: '#ef4444',
    marginTop: 2,
  },
});
