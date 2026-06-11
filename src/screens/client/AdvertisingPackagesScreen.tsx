/**
 * AdvertisingPackagesScreen
 * Catálogo de paquetes publicitarios con selector por tipo.
 */
import { LinearGradient } from 'expo-linear-gradient';
import { ArrowLeft, Megaphone, Settings2, Star, TrendingUp, Users } from 'lucide-react-native';
import React, { useEffect, useRef, useState } from 'react';
import { useAuth } from '../../context/AuthContext';
import {
  ActivityIndicator,
  Animated,
  Pressable,
  RefreshControl,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { supabase } from '../../config/supabase';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';
import Particles from '../../components/ui/Particles';
import { normalizeCity } from '../../utils/cityUtils';

// ─── Tipos ────────────────────────────────────────────────────────────────────

interface AdPackage {
  id: string;
  name: string;
  type: 'banner_home' | 'sponsored_group' | 'profile_ad';
  tier?: 'top_1_3' | 'top_4_10' | null;
  duration_days: number;
  price: number;
  description: string | null;
  is_active: boolean;
}

// ─── Configuración de tipos ───────────────────────────────────────────────────

const TYPE_CFG = {
  banner_home: {
    emoji:      '📢',
    label:      'Banner en Inicio',
    title:      'Máxima visibilidad',
    desc:       'Tu anuncio aparece en el carousel de la pantalla principal. Lo ven todos los usuarios al abrir la app.',
    benefit:    '🎯 Mayor alcance de la plataforma',
    visibility: '+35% visibilidad',
    requests:   '8–15 solicitudes estimadas',
    reqMin:     8,
    reqMax:     15,
    reachBase:  3000,
    color:      COLORS.green,
    gradient:   ['rgba(0,230,118,0.14)', 'rgba(0,230,118,0.03)'] as [string, string],
  },
  sponsored_group: {
    emoji:      '⭐',
    label:      'Grupo Destacado',
    title:      'Aparece primero',
    desc:       'Tu grupo aparece al tope de "Destacados" antes que el resto. Más visitas, más contrataciones.',
    benefit:    '🚀 Más contrataciones garantizadas',
    visibility: '+20% visibilidad',
    requests:   '5–10 solicitudes estimadas',
    reqMin:     5,
    reqMax:     10,
    reachBase:  1500,
    color:      '#FFD700',
    gradient:   ['rgba(255,215,0,0.14)', 'rgba(255,215,0,0.03)'] as [string, string],
  },
  profile_ad: {
    emoji:      '👤',
    label:      'Anuncio en Perfiles',
    title:      'Llega al momento de decisión',
    desc:       'Tu anuncio aparece dentro de los perfiles de grupos, justo cuando el cliente está decidiendo contratar.',
    benefit:    '💡 Alta intención de compra',
    visibility: '+15% visibilidad',
    requests:   '3–8 solicitudes estimadas',
    reqMin:     3,
    reqMax:     8,
    reachBase:  800,
    color:      '#A78BFA',
    gradient:   ['rgba(167,139,250,0.14)', 'rgba(167,139,250,0.03)'] as [string, string],
  },
} as const;

// ── Texto de comparación según nivel de demanda ───────────────────────────────
function getDemandComparisonText(demandLevel: string | null | undefined): string {
  if (demandLevel === 'high') return 'Mayor que el promedio en tu ciudad';
  if (demandLevel === 'medium') return 'Similar a otros grupos activos';
  return 'Buen momento para posicionarte antes que otros';
}

// ── Estimación de retorno ─────────────────────────────────────────────────────
// Multiplica rangos base por nivel de demanda y duración del paquete.
function calcEstimates(
  type: AdType,
  durationDays: number,
  demandLevel: string | null | undefined,
): { reqMin: number; reqMax: number; views: number } {
  const base = TYPE_CFG[type];
  const demandMult =
    demandLevel === 'high'   ? 1.6 :
    demandLevel === 'medium' ? 1.2 :
    demandLevel === 'low'    ? 0.7 :
    demandLevel === 'new'    ? 0.5 : 1.0;
  const durFactor = durationDays / 7;
  return {
    reqMin: Math.max(1, Math.round(base.reqMin * demandMult * durFactor)),
    reqMax: Math.max(2, Math.round(base.reqMax * demandMult * durFactor)),
    views:  Math.round(base.reachBase * durFactor * (demandLevel === 'high' ? 1.3 : demandLevel === 'medium' ? 1.1 : 1.0)),
  };
}

function getPositionTier(idx: number): { label: string; color: string; bg: string } {
  if (idx >= 2) return { label: 'Top 1–3 🟢',   color: COLORS.green, bg: 'rgba(0,230,118,0.14)' };
  if (idx === 1) return { label: 'Top 4–10 🟡',  color: '#F59E0B',   bg: 'rgba(245,158,11,0.14)' };
  return                { label: 'Top 11–20 ⚪', color: '#94A3B8',   bg: 'rgba(148,163,184,0.12)' };
}

// ── Precios canónicos por tier (fuente de verdad en frontend) ─────────────────
// Permite mostrar precios correctos aunque el DB aún no esté actualizado.
// dynPrice() multiplica este valor por demandMultiplier × cityMultiplier.
const BANNER_HOME_PRICES: Record<'top_1_3' | 'top_4_10', Record<number, number>> = {
  top_1_3:  { 7: 699,  14: 1199, 30: 1999 },
  top_4_10: { 7: 499,  14: 899,  30: 1499 },
};

function getBasePrice(pkg: AdPackage): number {
  if (pkg.type === 'banner_home' && pkg.tier && pkg.tier in BANNER_HOME_PRICES) {
    return BANNER_HOME_PRICES[pkg.tier as 'top_1_3' | 'top_4_10'][pkg.duration_days] ?? pkg.price;
  }
  return pkg.price;
}

// Usa pkg.tier cuando está disponible; cae en getPositionTier(idx) para otros tipos.
function getTierBadge(pkg: AdPackage, idx: number): { label: string; color: string; bg: string } {
  if (pkg.tier === 'top_1_3')  return { label: 'Top 1–3 🟢',   color: COLORS.green, bg: 'rgba(0,230,118,0.14)' };
  if (pkg.tier === 'top_4_10') return { label: 'Top 4–10 🟡',  color: '#F59E0B',   bg: 'rgba(245,158,11,0.14)' };
  return getPositionTier(idx);
}

type AdType = keyof typeof TYPE_CFG;
// sponsored_group solo se vende desde el panel del grupo (no aquí)
// profile_ad solo aplica a clientes/talentos — grupos solo ven banner_home
const TYPE_ORDER_GROUP:  AdType[] = ['banner_home'];
const TYPE_ORDER_CLIENT: AdType[] = ['banner_home', 'profile_ad'];

// Badges dinámicos: paquete del medio = Recomendado, último = Mejor valor
const REC_BADGE  = { label: '⭐ Recomendado',       color: '#000', bg: COLORS.green };
const PREM_BADGE = { label: '🔥 Más vendido',         color: '#000', bg: '#F59E0B'   };
const REC_MSG    = 'Más visibilidad por menor costo diario';
const PREM_MSG   = '🔥 Más elegido por grupos exitosos';

// ─── Status labels ────────────────────────────────────────────────────────────

const STATUS_LABEL: Record<string, { text: string; color: string }> = {
  active:          { text: 'Activo',      color: COLORS.green  },
  pending_review:  { text: 'En revisión', color: '#F59E0B'     },
  pending_payment: { text: 'Sin pago',    color: '#EF4444'     },
  paused:          { text: 'Pausado',     color: COLORS.muted2 },
  rejected:        { text: 'Rechazado',   color: '#EF4444'     },
  expired:         { text: 'Vencido',     color: COLORS.muted  },
};

// ─── Componente ───────────────────────────────────────────────────────────────

export default function AdvertisingPackagesScreen({ navigation, route }: any) {
  const { profile: authProfile, role: authRole, safeCity } = useAuth();
  const TYPE_ORDER = authRole === 'group' ? TYPE_ORDER_GROUP : TYPE_ORDER_CLIENT;
  const initialType = (route?.params?.initialType as AdType | undefined) ?? 'banner_home';

  const [packages,     setPackages]     = useState<AdPackage[]>([]);
  const [myAds,        setMyAds]        = useState<any[]>([]);
  const [loading,      setLoading]      = useState(true);
  const [refreshing,   setRefreshing]   = useState(false);
  const [selectedType, setSelectedType] = useState<AdType>(initialType);
  const [demandInfo,   setDemandInfo]   = useState<{
    demand_level: 'low' | 'medium' | 'high';
    multiplier: number;
    message: string;
    active_bids?: number;
  } | null>(null);
  const [adSlots, setAdSlots] = useState<{
    banner_free: number; featured_free: number;
    banner_used: number; featured_used: number; profile_used: number;
  } | null>(null);
  const [showAll,  setShowAll]  = useState(false);
  const [fomoMsg,  setFomoMsg]  = useState<string | null>(null);
  const [cityStatus, setCityStatus] = useState<{ status: string; price_multiplier: number; is_seeding: boolean } | null>(null);
  const [seedingSlots, setSeedingSlots] = useState<{ slots_total: number; slots_used: number; slots_available: number } | null>(null);
  const pulseAnim    = useRef(new Animated.Value(1)).current;
  const fomoTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  useEffect(() => { fetchAll(); }, []);

  // Reset showAll al cambiar tipo
  useEffect(() => { setShowAll(false); }, [selectedType]);

  // Animación pulsante para escasez crítica (1 espacio)
  useEffect(() => {
    const anim = Animated.loop(
      Animated.sequence([
        Animated.timing(pulseAnim, { toValue: 0.35, duration: 550, useNativeDriver: true }),
        Animated.timing(pulseAnim, { toValue: 1,    duration: 550, useNativeDriver: true }),
      ])
    );
    anim.start();
    return () => anim.stop();
  }, []);

  // FOMO: escuchar cambios de bids en la ciudad
  useEffect(() => {
    const city = normalizeCity(safeCity);
    if (!city) return;
    const ch = supabase
      .channel('adpkg-fomo-' + city)
      .on('postgres_changes', {
        event: 'UPDATE', schema: 'public', table: 'groups',
        filter: `city=eq.${city}`,
      }, () => {
        setFomoMsg('⚡ Un grupo acaba de actualizar su promoción en tu ciudad');
        if (fomoTimerRef.current) clearTimeout(fomoTimerRef.current);
        fomoTimerRef.current = setTimeout(() => setFomoMsg(null), 5000);
      })
      .subscribe();
    return () => {
      supabase.removeChannel(ch);
      if (fomoTimerRef.current) clearTimeout(fomoTimerRef.current);
    };
  }, []);

  const onRefresh = async () => { setRefreshing(true); await fetchAll(); setRefreshing(false); };

  const fetchAll = async () => {
    const city = normalizeCity(safeCity);
    console.log('[AdvertisingPackages] city usada:', city);
    const [{ data: pkgs }, { data: ads }] = await Promise.all([
      supabase.from('ad_packages').select('*').eq('is_active', true).order('price', { ascending: true }),
      supabase.rpc('get_my_advertisement_orders'),
    ]);
    setPackages((pkgs as AdPackage[]) ?? []);
    setMyAds((ads ?? []) as any[]);
    setLoading(false);

    // Demanda + slots + estado de ciudad en paralelo
    const [{ data: demand }, { data: slots }, { data: csData }, { data: launchData }] = await Promise.all([
      supabase.rpc('get_demand_info', { p_city: city }),
      supabase.rpc('check_city_ad_slots', { p_city: city }),
      supabase.rpc('get_city_status', { p_city: city }),
      supabase.rpc('get_seeding_launch_slots', { p_city: city }),
    ]);
    if (demand) setDemandInfo(demand as any);
    if (slots)  setAdSlots(slots as any);
    if ((csData as any)?.ok) setCityStatus(csData as any);
    if ((launchData as any)?.ok) setSeedingSlots(launchData as any);
  };

  const dynPrice = (base: number) =>
    Math.ceil(base * (demandInfo?.multiplier ?? 1.0) * (cityStatus?.price_multiplier ?? 1.0));

  const pkgsOf = (type: AdType): AdPackage[] => {
    const all = packages.filter(p => p.type === type);
    // Dedup: eliminar paquetes con mismo type + tier + duration_days
    const deduped = all.filter((pkg, i, arr) =>
      arr.findIndex(p =>
        p.type === pkg.type &&
        (p.tier ?? '') === (pkg.tier ?? '') &&
        p.duration_days === pkg.duration_days
      ) === i
    );
    // Orden: top_4_10 primero (baja barrera), luego top_1_3 (upsell premium)
    // Dentro de cada tier, por duración ascendente
    const tierOrder = (t: string | null | undefined) =>
      t === 'top_4_10' ? 0 : t === 'top_1_3' ? 1 : 2;
    return deduped.sort((a, b) => {
      const td = tierOrder(a.tier) - tierOrder(b.tier);
      return td !== 0 ? td : a.duration_days - b.duration_days;
    });
  };

  const handleSelect = (pkg: AdPackage) => {
    navigation.navigate('CreateAdvertisement', { preSelectedPackage: pkg });
  };

  // ── Loading ──────────────────────────────────────────────────────────────────
  if (loading) {
    return (
      <View style={[s.container, s.centered]}>
        <ActivityIndicator color={COLORS.green} size="large" />
      </View>
    );
  }

  const cfg      = TYPE_CFG[selectedType];
  const typePkgs = pkgsOf(selectedType);
  // recIdx: demanda alta/media → paquete medio; demanda baja/nueva → básico (índice 0)
  const lvlForRec = demandInfo?.demand_level;
  const recIdx  = (lvlForRec === 'high' || lvlForRec === 'medium')
    ? Math.floor((typePkgs.length - 1) / 2)
    : 0;
  const premIdx  = typePkgs.length - 1;
  const visiblePkgs = showAll ? typePkgs : typePkgs.slice(0, 3);

  // ── Render ───────────────────────────────────────────────────────────────────
  return (
    <View style={s.container}>
      <Particles />
      <SafeAreaView style={{ flex: 1 }}>

        {/* ── Header ── */}
        <View style={s.header}>
          <Pressable style={s.backBtn} onPress={() => navigation.goBack()}>
            <ArrowLeft size={20} color={COLORS.text} />
          </Pressable>
          <View style={{ flex: 1 }}>
            <Text style={s.headerTitle}>Consigue más eventos</Text>
            <Text style={s.headerSub}>Aumenta tu visibilidad y recibe más solicitudes</Text>
          </View>
        </View>

        <ScrollView showsVerticalScrollIndicator={false} contentContainerStyle={s.scroll} refreshControl={<RefreshControl refreshing={refreshing} onRefresh={onRefresh} tintColor={COLORS.green} />}>

          {/* ── Seeding urgency banner ── */}
          {cityStatus?.is_seeding && (
            <View style={s.seedingUrgencyBanner}>
              <Text style={s.seedingUrgencyTitle}>⏳ Precio de lanzamiento por tiempo limitado</Text>
              {seedingSlots && (
                <Text style={s.seedingUrgencySub}>
                  Solo por los primeros {seedingSlots.slots_total} grupos en la ciudad
                </Text>
              )}
              {seedingSlots && seedingSlots.slots_available <= seedingSlots.slots_total && (
                <View style={s.seedingScarcityRow}>
                  <Text style={s.seedingScarcityText}>
                    {seedingSlots.slots_available <= 0
                      ? '🔴 Todos los lugares de lanzamiento están ocupados'
                      : seedingSlots.slots_available <= 3
                      ? `🔴 Solo ${seedingSlots.slots_available} espacio${seedingSlots.slots_available !== 1 ? 's' : ''} disponible${seedingSlots.slots_available !== 1 ? 's' : ''} con precio de lanzamiento`
                      : `🟡 ${seedingSlots.slots_available} espacios disponibles con precio de lanzamiento`}
                  </Text>
                </View>
              )}
            </View>
          )}

          {/* ── FOMO banner ── */}
          {fomoMsg && (
            <View style={s.fomoBanner}>
              <Text style={s.fomoText}>{fomoMsg}</Text>
            </View>
          )}

          {/* ── FOMO: sin anuncios activos ── */}
          {!loading && myAds.filter(a => a.status === 'active').length === 0 && (
            <View style={s.noAdsFomoBanner}>
              <Text style={s.noAdsFomoText}>
                ⚠️ Sin promoción estás perdiendo visibilidad frente a otros grupos
              </Text>
              {demandInfo?.demand_level === 'high' && (
                <Text style={[s.noAdsFomoText, { color: '#ef4444', marginTop: 4 }]}>
                  🔥 Otros grupos ya están aprovechando esta demanda
                </Text>
              )}
            </View>
          )}

          {/* ── Stats strip ── */}
          <View style={s.statsStrip}>
            {[
              { icon: Users,      value: '+500',  label: 'Usuarios activos' },
              { icon: TrendingUp, value: '24h',   label: 'Aprobación' },
              { icon: Star,       value: '3',      label: 'Formatos' },
            ].map((stat, i) => (
              <View key={i} style={s.statItem}>
                <stat.icon size={14} color={COLORS.green} />
                <Text style={s.statValue}>{stat.value}</Text>
                <Text style={s.statLabel}>{stat.label}</Text>
              </View>
            ))}
          </View>

          {/* ── Banner de demanda (todos los niveles) ── */}
          {demandInfo && (() => {
            const lvl = demandInfo.demand_level;
            const isHigh = lvl === 'high';
            const isMed  = lvl === 'medium';
            const cfg2 = isHigh
              ? { bg: 'rgba(239,68,68,0.08)', border: 'rgba(239,68,68,0.3)', color: '#ef4444',
                  msg: `⚡ Alta demanda en tu zona — si no te posicionas hoy pierdes eventos` }
              : isMed
              ? { bg: 'rgba(245,158,11,0.08)', border: 'rgba(245,158,11,0.3)', color: '#F59E0B',
                  msg: `🔥 Buen momento para promocionarte — la competencia está creciendo` }
              : { bg: 'rgba(0,230,118,0.08)', border: 'rgba(0,230,118,0.3)', color: COLORS.green,
                  msg: `🟢 Precio especial disponible · Sé el primero en tu ciudad` };
            return (
              <View style={[s.demandBanner, { backgroundColor: cfg2.bg, borderColor: cfg2.border }]}>
                <Text style={[s.demandBannerText, { color: cfg2.color }]}>{cfg2.msg}</Text>
                {demandInfo.multiplier > 1.0 && (
                  <>
                    <Text style={[s.demandBannerText, { color: cfg2.color, opacity: 0.75, marginTop: 3 }]}>
                      Precio dinámico activo ×{demandInfo.multiplier}
                    </Text>
                    <View style={s.pricingRisingBadge}>
                      <Text style={s.pricingRisingText}>🔥 Precio subiendo por alta demanda</Text>
                    </View>
                  </>
                )}
              </View>
            );
          })()}

          {/* ── Escasez + prueba social ── */}
          {(adSlots || demandInfo) && (() => {
            const bannerFree    = adSlots?.banner_free   ?? 3;
            const featuredFree  = adSlots?.featured_free ?? 10;
            // Prueba social: anuncios activos + bids activos
            const totalPromoted = (adSlots?.banner_used ?? 0)
              + (adSlots?.featured_used  ?? 0)
              + (adSlots?.profile_used   ?? 0)
              + (demandInfo?.active_bids ?? 0);
            const spotsLeft = selectedType === 'banner_home' ? bannerFree : featuredFree;
            const scarcityText = spotsLeft === 0
              ? '🔴 Sin espacios disponibles hoy — lista de espera'
              : spotsLeft <= 2
              ? `🔴 Solo ${spotsLeft} espacio${spotsLeft !== 1 ? 's' : ''} disponible${spotsLeft !== 1 ? 's' : ''} — actúa rápido`
              : spotsLeft <= 5
              ? `🟡 ${spotsLeft} espacios disponibles hoy`
              : null;
            const isCritical = spotsLeft <= 1 && spotsLeft > 0;
            return (
              <View style={s.socialProofRow}>
                {totalPromoted > 0 && (
                  <View style={s.socialProofChip}>
                    <Text style={s.socialProofText}>
                      +{totalPromoted} grupos ya se están promocionando en tu ciudad
                    </Text>
                  </View>
                )}
                {scarcityText && (
                  isCritical ? (
                    <Animated.View style={[
                      s.socialProofChip,
                      { backgroundColor: 'rgba(239,68,68,0.08)', borderColor: 'rgba(239,68,68,0.25)', opacity: pulseAnim },
                    ]}>
                      <Text style={[s.socialProofText, { color: '#ef4444' }]}>{scarcityText}</Text>
                    </Animated.View>
                  ) : (
                    <View style={[s.socialProofChip, { backgroundColor: 'rgba(239,68,68,0.08)', borderColor: 'rgba(239,68,68,0.25)' }]}>
                      <Text style={[s.socialProofText, { color: '#ef4444' }]}>{scarcityText}</Text>
                    </View>
                  )
                )}
              </View>
            );
          })()}

          {/* ── Selector de tipo (tabs) — oculto si viene pre-filtrado ── */}
          {!route?.params?.initialType && (
            <View style={s.tabsWrapper}>
              {TYPE_ORDER.map(type => {
                const c   = TYPE_CFG[type];
                const sel = type === selectedType;
                return (
                  <Pressable
                    key={type}
                    style={[s.tab, sel && { borderColor: c.color, backgroundColor: `${c.color}18` }]}
                    onPress={() => setSelectedType(type)}
                  >
                    <Text style={s.tabEmoji}>{c.emoji}</Text>
                    <Text style={[s.tabLabel, sel && { color: c.color }]} numberOfLines={2}>
                      {c.label}
                    </Text>
                    {sel && <View style={[s.tabDot, { backgroundColor: c.color }]} />}
                  </Pressable>
                );
              })}
            </View>
          )}

          {/* ── Hero del tipo seleccionado ── */}
          <View style={[s.typeHero, { borderColor: `${cfg.color}40` }]}>
            <LinearGradient
              colors={cfg.gradient}
              style={StyleSheet.absoluteFillObject}
              start={{ x: 0, y: 0 }} end={{ x: 1, y: 1 }}
            />
            <View style={s.typeHeroTop}>
              <Text style={s.typeHeroEmoji}>{cfg.emoji}</Text>
              <View style={{ flex: 1 }}>
                <Text style={[s.typeHeroTitle, { color: cfg.color }]}>{cfg.title}</Text>
                <Text style={s.typeHeroDesc}>{cfg.desc}</Text>
              </View>
            </View>
            {/* Impact metrics row */}
            <View style={s.impactRow}>
              <View style={[s.impactChip, { backgroundColor: `${cfg.color}14`, borderColor: `${cfg.color}30` }]}>
                <TrendingUp size={11} color={cfg.color} />
                <Text style={[s.impactChipText, { color: cfg.color }]}>{cfg.visibility}</Text>
              </View>
              <View style={[s.impactChip, { backgroundColor: `${cfg.color}14`, borderColor: `${cfg.color}30` }]}>
                <Users size={11} color={cfg.color} />
                <Text style={[s.impactChipText, { color: cfg.color }]}>{cfg.requests}</Text>
              </View>
            </View>
            <View style={[s.typeHeroBenefit, { backgroundColor: `${cfg.color}18`, borderColor: `${cfg.color}30` }]}>
              <Text style={[s.typeHeroBenefitText, { color: cfg.color }]}>{cfg.benefit}</Text>
            </View>
          </View>

          {/* ── Paquetes del tipo seleccionado ── */}
          {typePkgs.length === 0 ? (
            <View style={s.emptyBox}>
              <Megaphone size={32} color={COLORS.muted} />
              <Text style={s.emptyText}>Sin paquetes disponibles</Text>
              <Text style={s.emptySub}>Vuelve pronto, estamos preparando nuevas opciones.</Text>
            </View>
          ) : (
            <View style={s.pkgList}>
              {visiblePkgs.map((pkg, idx) => {
                const isRec   = idx === recIdx;
                const isPrem  = idx === premIdx && typePkgs.length > 1;
                const badgeCfg = isRec ? REC_BADGE : isPrem ? PREM_BADGE : null;
                const tier    = getTierBadge(pkg, idx);
                const finalPrice = dynPrice(getBasePrice(pkg));
                const perDay  = Math.round(finalPrice / pkg.duration_days);
                const reach   = Math.round(cfg.reachBase * (pkg.duration_days / 7));
                return (
                  <Pressable
                    key={pkg.id}
                    style={[s.pkgCard, (isRec || isPrem) && { borderColor: cfg.color }]}
                    onPress={() => handleSelect(pkg)}
                  >
                    <LinearGradient
                      colors={(isRec || isPrem) ? cfg.gradient : ['transparent', 'transparent']}
                      style={StyleSheet.absoluteFillObject}
                      start={{ x: 0, y: 0 }} end={{ x: 1, y: 1 }}
                    />

                    {/* Badges row */}
                    <View style={s.pkgBadgeRow}>
                      {badgeCfg && (
                        <View style={[s.badge, { backgroundColor: badgeCfg.bg }]}>
                          <Text style={[s.badgeText, { color: badgeCfg.color }]}>{badgeCfg.label}</Text>
                        </View>
                      )}
                      {cityStatus?.is_seeding && (
                        <View style={[s.badge, { backgroundColor: 'rgba(0,230,118,0.18)', borderWidth: 1, borderColor: 'rgba(0,230,118,0.4)' }]}>
                          <Text style={[s.badgeText, { color: COLORS.green }]}>🚀 Precio de lanzamiento</Text>
                        </View>
                      )}
                      <View style={[s.positionBadge, { backgroundColor: tier.bg }]}>
                        <Text style={[s.positionBadgeText, { color: tier.color }]}>{tier.label}</Text>
                      </View>
                    </View>

                    {/* Contenido principal */}
                    <View style={s.pkgTop}>
                      {/* Info izquierda */}
                      <View style={{ flex: 1 }}>
                        <Text style={s.pkgName}>{pkg.name}</Text>
                        <View style={s.pkgDurRow}>
                          <View style={[s.pkgDurChip, { borderColor: `${cfg.color}40`, backgroundColor: `${cfg.color}12` }]}>
                            <Text style={[s.pkgDurText, { color: cfg.color }]}>{pkg.duration_days} días</Text>
                          </View>
                        </View>
                        {pkg.tier === 'top_1_3' && (
                          <Text style={[s.pkgTierDesc, { color: COLORS.green }]}>Máxima visibilidad en tu ciudad</Text>
                        )}
                        {pkg.tier === 'top_4_10' && (
                          <Text style={[s.pkgTierDesc, { color: '#F59E0B' }]}>Alta visibilidad a menor costo</Text>
                        )}
                        {pkg.description && (
                          <Text style={s.pkgDesc} numberOfLines={2}>{pkg.description}</Text>
                        )}
                        <Text style={s.pkgReach}>
                          👥 Alcance estimado: +{reach >= 1000 ? `${(reach / 1000).toFixed(1)}k` : reach} personas
                        </Text>
                      </View>

                      {/* Precio derecha */}
                      <View style={s.pkgPriceBlock}>
                        <Text style={[s.pkgPrice, { color: cfg.color }]}>
                          ${finalPrice.toLocaleString()}
                        </Text>
                        {cityStatus?.is_seeding ? (
                          <>
                            <Text style={[s.pkgCityLabel, { color: COLORS.green }]}>-30% lanzamiento</Text>
                            <Text style={s.pkgBasePrice}>
                              Normal ${Math.ceil(pkg.price * (demandInfo?.multiplier ?? 1.0)).toLocaleString()}
                            </Text>
                          </>
                        ) : demandInfo && demandInfo.multiplier > 1.0 ? (
                          <>
                            <Text style={s.pkgCityLabel}>Tu ciudad ×{demandInfo.multiplier}</Text>
                            <Text style={s.pkgBasePrice}>
                              Base ${pkg.price.toLocaleString()}
                            </Text>
                          </>
                        ) : (
                          <Text style={s.pkgCityLabel}>Precio base</Text>
                        )}
                        <Text style={s.pkgPerDay}>${perDay.toLocaleString()}/día</Text>
                      </View>
                    </View>

                    {/* Mensaje de valor / prueba social */}
                    {isRec && (
                      <Text style={s.pkgValueMsg}>{REC_MSG}</Text>
                    )}
                    {isPrem && (
                      <Text style={s.pkgSocialMsg}>{PREM_MSG}</Text>
                    )}

                    {/* Botón */}
                    <View style={[s.pkgBtn, { backgroundColor: isRec ? cfg.color : COLORS.card2, borderWidth: isRec ? 0 : 1, borderColor: COLORS.border }]}>
                      <Text style={[s.pkgBtnText, { color: isRec ? '#000' : COLORS.text }]}>
                        {isRec ? '👉 Continuar con recomendado' : 'Contratar'}
                      </Text>
                    </View>

                    {/* Estimación de retorno — paquete recomendado: completo; otros: compacto */}
                    {(() => {
                      const est = calcEstimates(selectedType, pkg.duration_days, demandInfo?.demand_level);
                      const viewsLabel = est.views >= 1000
                        ? `${(est.views / 1000).toFixed(1)}k`
                        : est.views.toLocaleString();
                      const comparisonText = getDemandComparisonText(demandInfo?.demand_level);
                      if (isRec) {
                        return (
                          <View style={s.estBox}>
                            <View style={s.estRow}>
                              <Text style={s.estIcon}>📨</Text>
                              <Text style={s.estText}>
                                Recibirás aproximadamente {est.reqMin}–{est.reqMax} solicitudes
                              </Text>
                            </View>
                            <Text style={s.estDisclaimer}>
                              La mayoría de los grupos activos reciben clientes en este rango
                            </Text>
                            <View style={s.estRow}>
                              <Text style={s.estIcon}>👁</Text>
                              <Text style={s.estText}>
                                ≈ {viewsLabel} clientes verán tu grupo
                              </Text>
                            </View>
                            <Text style={[s.estDisclaimer, { color: COLORS.green }]}>
                              {comparisonText}
                            </Text>
                            {demandInfo?.demand_level === 'high' && (
                              <Text style={[s.estDisclaimer, { color: '#ef4444', marginTop: 2 }]}>
                                🔥 Otros grupos ya están aprovechando esta demanda
                              </Text>
                            )}
                          </View>
                        );
                      }
                      // Versión compacta para paquetes no recomendados
                      return (
                        <View style={[s.estBox, { gap: 4, paddingTop: 10 }]}>
                          <Text style={[s.estText, { fontSize: 11 }]}>
                            📨 Recibirás ≈ {est.reqMin}–{est.reqMax} solicitudes · 👁 ≈ {viewsLabel} vistas
                          </Text>
                          <Text style={[s.estDisclaimer, { color: COLORS.green }]}>
                            {comparisonText}
                          </Text>
                        </View>
                      );
                    })()}
                  </Pressable>
                );
              })}

            </View>
          )}

          {/* ── Botón personalizar ── */}
          <Pressable
            style={s.customBtn}
            onPress={() => navigation.navigate('CreateAdvertisement', {
              customMode: true,
              adType: selectedType,
            })}
          >
            <View style={s.customBtnLeft}>
              <View style={s.customBtnIcon}>
                <Settings2 size={18} color={cfg.color} />
              </View>
              <View>
                <Text style={[s.customBtnTitle, { color: cfg.color }]}>Personalizar anuncio</Text>
                <Text style={s.customBtnSub}>Elige días, alcance y precio a tu medida</Text>
              </View>
            </View>
            <Text style={[s.customBtnArrow, { color: cfg.color }]}>→</Text>
          </Pressable>

          {/* ── Mis anuncios ── */}
          {myAds.length > 0 && (
            <View style={s.myAdsCard}>
              <Text style={s.myAdsTitle}>Mis anuncios</Text>
              {myAds.map((ad, i) => {
                const st       = STATUS_LABEL[ad.status] ?? { text: ad.status, color: COLORS.muted2 };
                const isActive = ad.status === 'active';
                const daysLeft = ad.ends_at
                  ? Math.max(0, Math.ceil((new Date(ad.ends_at).getTime() - Date.now()) / 86_400_000))
                  : null;

                return (
                  <View key={ad.id} style={[s.myAdRow, i === 0 && { borderTopWidth: 0 }]}>
                    {/* Status + meta */}
                    <View style={s.myAdHeader}>
                      <View style={{ flex: 1 }}>
                        <Text style={s.myAdName} numberOfLines={1}>{ad.title}</Text>
                        <Text style={s.myAdPkg}>{ad.package_name ?? '—'}</Text>
                      </View>
                      <View style={[s.myAdBadge, { backgroundColor: `${st.color}18` }]}>
                        <View style={[s.myAdDot, { backgroundColor: st.color }]} />
                        <Text style={[s.myAdBadgeText, { color: st.color }]}>{st.text}</Text>
                      </View>
                    </View>

                    {/* Preview visual del anuncio si está activo */}
                    {isActive && (
                      <View style={s.adPreviewBox}>
                        {/* Miniatura del banner */}
                        <View style={s.adPreviewBanner}>
                          <LinearGradient
                            colors={['rgba(0,230,118,0.15)', 'rgba(0,200,83,0.05)']}
                            style={StyleSheet.absoluteFillObject}
                            start={{ x: 0, y: 0 }} end={{ x: 1, y: 1 }}
                          />
                          <Text style={s.adPreviewTag}>PUBLICIDAD</Text>
                          <Text style={s.adPreviewTitle} numberOfLines={1}>{ad.title}</Text>
                          {ad.subtitle ? (
                            <Text style={s.adPreviewSub} numberOfLines={1}>{ad.subtitle}</Text>
                          ) : null}
                          <View style={s.adPreviewLive}>
                            <View style={s.adPreviewLiveDot} />
                            <Text style={s.adPreviewLiveText}>En vivo ahora</Text>
                          </View>
                        </View>

                        {/* Stats row */}
                        <View style={s.adStatsRow}>
                          <View style={s.adStatItem}>
                            <Text style={s.adStatNum}>{(ad.impressions ?? 0).toLocaleString()}</Text>
                            <Text style={s.adStatLabel}>Vistas</Text>
                          </View>
                          <View style={s.adStatDivider} />
                          <View style={s.adStatItem}>
                            <Text style={s.adStatNum}>{(ad.clicks ?? 0).toLocaleString()}</Text>
                            <Text style={s.adStatLabel}>Clics</Text>
                          </View>
                          <View style={s.adStatDivider} />
                          <View style={s.adStatItem}>
                            <Text style={[s.adStatNum, { color: daysLeft && daysLeft <= 3 ? COLORS.orange : COLORS.green }]}>
                              {daysLeft ?? '—'}d
                            </Text>
                            <Text style={s.adStatLabel}>Restantes</Text>
                          </View>
                        </View>
                      </View>
                    )}

                    {/* Rechazo con motivo */}
                    {ad.status === 'rejected' && ad.rejection_reason && (
                      <View style={s.adRejectedBox}>
                        <Text style={s.adRejectedText}>❌ {ad.rejection_reason}</Text>
                      </View>
                    )}
                  </View>
                );
              })}
            </View>
          )}

          {/* ── Cómo funciona ── */}
          <View style={s.howCard}>
            <Text style={s.howTitle}>¿Cómo funciona?</Text>
            {[
              { n: '1', t: 'Elige tu paquete',  d: 'Selecciona el tipo y duración que más te conviene.' },
              { n: '2', t: 'Sube tu contenido', d: 'Imagen o video + título + texto del botón.' },
              { n: '3', t: 'Realiza el pago',   d: 'Pago seguro a través de Mercado Pago.' },
              { n: '4', t: 'Revisión en 24h',   d: 'El equipo revisa tu anuncio y lo activa automáticamente.' },
            ].map(item => (
              <View key={item.n} style={s.howItem}>
                <View style={s.howNum}>
                  <Text style={s.howNumText}>{item.n}</Text>
                </View>
                <View style={{ flex: 1 }}>
                  <Text style={s.howItemTitle}>{item.t}</Text>
                  <Text style={s.howItemDesc}>{item.d}</Text>
                </View>
              </View>
            ))}
          </View>

        </ScrollView>
      </SafeAreaView>
    </View>
  );
}

// ─── Estilos ──────────────────────────────────────────────────────────────────

const s = StyleSheet.create({
  container: { flex: 1, backgroundColor: COLORS.bg },
  centered:  { justifyContent: 'center', alignItems: 'center' },

  header: {
    flexDirection: 'row', alignItems: 'center', gap: 12,
    paddingHorizontal: SPACING.xl, paddingTop: 8, paddingBottom: 10,
  },
  backBtn: {
    width: 38, height: 38, borderRadius: 10,
    backgroundColor: COLORS.card, borderWidth: 1, borderColor: COLORS.border,
    alignItems: 'center', justifyContent: 'center',
  },
  headerTitle: { fontFamily: FONTS.title,      fontSize: 20, color: COLORS.text },
  headerSub:   { fontFamily: FONTS.body,        fontSize: 12, color: COLORS.muted2, marginTop: 1 },

  scroll: { paddingHorizontal: SPACING.xl, paddingBottom: 48 },

  // Stats strip
  statsStrip: {
    flexDirection: 'row', justifyContent: 'space-around',
    backgroundColor: COLORS.card, borderRadius: RADIUS.xl,
    borderWidth: 1, borderColor: COLORS.border,
    paddingVertical: 14, marginBottom: 20,
  },
  statItem:  { alignItems: 'center', gap: 4 },
  statValue: { fontFamily: FONTS.title,     fontSize: 15, color: COLORS.green },
  statLabel: { fontFamily: FONTS.body,      fontSize: 10, color: COLORS.muted2 },

  // Demand banner
  demandBanner: {
    borderRadius: RADIUS.lg, borderWidth: 1,
    paddingHorizontal: 14, paddingVertical: 10, marginBottom: 16,
  },
  demandBannerHigh: { backgroundColor: 'rgba(239,68,68,0.08)', borderColor: 'rgba(239,68,68,0.3)' },
  demandBannerLow:  { backgroundColor: 'rgba(0,230,118,0.08)', borderColor: 'rgba(0,230,118,0.3)' },
  demandBannerText:     { fontFamily: FONTS.bodyMedium, fontSize: 12, textAlign: 'center' as const },
  demandBannerTextHigh: { color: '#ef4444' },
  demandBannerTextLow:  { color: COLORS.green },

  // Tabs
  tabsWrapper: {
    flexDirection: 'row', gap: 8, marginBottom: 18,
  },
  tab: {
    flex: 1, alignItems: 'center', gap: 4,
    backgroundColor: COLORS.card, borderRadius: RADIUS.xl,
    borderWidth: 1.5, borderColor: COLORS.border,
    paddingVertical: 12, paddingHorizontal: 6,
  },
  tabEmoji: { fontSize: 20 },
  tabLabel: {
    fontFamily: FONTS.bodyMedium, fontSize: 10, color: COLORS.muted2,
    textAlign: 'center', lineHeight: 13,
  },
  tabDot: {
    width: 6, height: 6, borderRadius: 3, marginTop: 2,
  },

  // Type hero
  typeHero: {
    borderRadius: RADIUS.xl, borderWidth: 1.5,
    padding: 18, marginBottom: 20, overflow: 'hidden',
  },
  typeHeroTop: {
    flexDirection: 'row', alignItems: 'flex-start', gap: 14, marginBottom: 14,
  },
  typeHeroEmoji: { fontSize: 32, lineHeight: 38 },
  typeHeroTitle: { fontFamily: FONTS.title,        fontSize: 18, marginBottom: 6 },
  typeHeroDesc:  { fontFamily: FONTS.body,          fontSize: 13, color: COLORS.muted2, lineHeight: 19 },
  typeHeroBenefit: {
    alignSelf: 'flex-start', borderRadius: RADIUS.full, borderWidth: 1,
    paddingHorizontal: 14, paddingVertical: 6,
  },
  typeHeroBenefitText: { fontFamily: FONTS.bodySemiBold, fontSize: 12 },

  // Package list
  pkgList: { gap: 12, marginBottom: 28 },

  // Package card
  pkgCard: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border,
    padding: 12, overflow: 'hidden',
  },
  badge: {
    alignSelf: 'flex-start', borderRadius: RADIUS.full,
    paddingHorizontal: 10, paddingVertical: 4,
  },
  badgeText: { fontFamily: FONTS.bodySemiBold, fontSize: 11 },

  // Impact chips in hero
  impactRow:     { flexDirection: 'row', gap: 8, marginBottom: 14 },
  impactChip:    { flexDirection: 'row', alignItems: 'center', gap: 5, borderRadius: RADIUS.full, borderWidth: 1, paddingHorizontal: 10, paddingVertical: 5 },
  impactChipText: { fontFamily: FONTS.bodyMedium, fontSize: 11 },

  pkgBadgeRow: { flexDirection: 'row', gap: 5, marginBottom: 7, flexWrap: 'wrap' as const },
  positionBadge: { alignSelf: 'flex-start', borderRadius: RADIUS.full, paddingHorizontal: 8, paddingVertical: 3 },
  positionBadgeText: { fontFamily: FONTS.bodySemiBold, fontSize: 10 },

  pkgTop: {
    flexDirection: 'row', alignItems: 'flex-start', gap: 10, marginBottom: 10,
  },
  pkgName: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.text, marginBottom: 4 },
  pkgDurRow: { flexDirection: 'row', alignItems: 'center', gap: 7, marginBottom: 4 },
  pkgDurChip: {
    alignSelf: 'flex-start', borderRadius: RADIUS.full, borderWidth: 1,
    paddingHorizontal: 8, paddingVertical: 3,
  },
  pkgDurText:  { fontFamily: FONTS.bodyMedium, fontSize: 10 },
  pkgPerDay:   { fontFamily: FONTS.body, fontSize: 10, color: COLORS.muted2, marginTop: 1 },
  pkgDesc:     { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted2, lineHeight: 15, marginBottom: 4 },
  pkgTierDesc: { fontFamily: FONTS.bodyMedium, fontSize: 11, lineHeight: 15, marginTop: 2, marginBottom: 2 },
  pkgValueMsg: { fontFamily: FONTS.bodyMedium, fontSize: 11, color: COLORS.green, marginBottom: 8, marginTop: -2 },
  pkgSocialMsg:{ fontFamily: FONTS.bodyMedium, fontSize: 11, color: '#F59E0B', marginBottom: 8, marginTop: -2 },
  pkgReach:    { fontFamily: FONTS.body, fontSize: 10, color: COLORS.muted2 },

  pkgPriceBlock: { alignItems: 'flex-end', flexShrink: 0 },
  pkgPrice:   { fontFamily: FONTS.title, fontSize: 20 },
  pkgCurrency:  { fontFamily: FONTS.body,  fontSize: 10, color: COLORS.muted2 },
  pkgBasePrice: { fontFamily: FONTS.body, fontSize: 9, color: COLORS.muted, textDecorationLine: 'line-through' as const, marginTop: 1 },

  pkgBtn: {
    borderRadius: RADIUS.md,
    paddingVertical: 9,
    alignItems: 'center', justifyContent: 'center',
  },
  pkgBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: '#000' },

  // Empty
  emptyBox: {
    alignItems: 'center', paddingVertical: 40, gap: 8,
    backgroundColor: COLORS.card, borderRadius: RADIUS.xl,
    borderWidth: 1, borderColor: COLORS.border, marginBottom: 28,
  },
  emptyText: { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.muted2 },
  emptySub:  { fontFamily: FONTS.body,          fontSize: 12, color: COLORS.muted, textAlign: 'center', paddingHorizontal: 20 },

  // Custom button
  customBtn: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between',
    backgroundColor: COLORS.card, borderRadius: RADIUS.xl,
    borderWidth: 1.5, borderColor: COLORS.border,
    borderStyle: 'dashed' as const,
    padding: 16, marginBottom: 20,
  },
  customBtnLeft:  { flexDirection: 'row', alignItems: 'center', gap: 12, flex: 1 },
  customBtnIcon:  {
    width: 40, height: 40, borderRadius: 12,
    backgroundColor: COLORS.card2, borderWidth: 1, borderColor: COLORS.border,
    alignItems: 'center', justifyContent: 'center',
  },
  customBtnTitle: { fontFamily: FONTS.bodyMedium, fontSize: 14 },
  customBtnSub:   { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted2, marginTop: 1 },
  customBtnArrow: { fontFamily: FONTS.title, fontSize: 18 },

  // My ads
  myAdsCard: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.xl,
    borderWidth: 1, borderColor: COLORS.border,
    padding: 16, marginBottom: 24,
  },
  myAdsTitle:    { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.text, marginBottom: 8 },
  myAdRow: {
    flexDirection: 'column', gap: 10,
    paddingVertical: 10, borderTopWidth: 1, borderTopColor: COLORS.border,
  },
  myAdHeader: {
    flexDirection: 'row', alignItems: 'center', gap: 10,
  },
  myAdDot: {
    width: 6, height: 6, borderRadius: 3,
  },
  myAdName:      { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.text },
  myAdPkg:       { fontFamily: FONTS.body,       fontSize: 11, color: COLORS.muted2, marginTop: 2 },
  myAdBadge:     { flexDirection: 'row', alignItems: 'center', gap: 5, paddingHorizontal: 10, paddingVertical: 4, borderRadius: RADIUS.full },
  myAdBadgeText: { fontFamily: FONTS.bodyMedium, fontSize: 11 },

  // Ad preview (active)
  adPreviewBox: {
    borderRadius: 14, overflow: 'hidden',
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.20)',
    backgroundColor: '#061008',
  },
  adPreviewBanner: {
    paddingHorizontal: 14, paddingVertical: 12, gap: 4, overflow: 'hidden',
  },
  adPreviewTag: {
    fontFamily: FONTS.bodySemiBold, fontSize: 9, color: COLORS.green,
    letterSpacing: 1.5,
  },
  adPreviewTitle: {
    fontFamily: FONTS.title, fontSize: 15, color: COLORS.text,
  },
  adPreviewSub: {
    fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2,
  },
  adPreviewLive: {
    flexDirection: 'row', alignItems: 'center', gap: 5, marginTop: 6,
    alignSelf: 'flex-start',
    backgroundColor: 'rgba(0,230,118,0.12)', borderRadius: 20,
    paddingHorizontal: 10, paddingVertical: 4,
  },
  adPreviewLiveDot: {
    width: 6, height: 6, borderRadius: 3, backgroundColor: COLORS.green,
  },
  adPreviewLiveText: {
    fontFamily: FONTS.bodyMedium, fontSize: 11, color: COLORS.green,
  },

  // Ad stats row
  adStatsRow: {
    flexDirection: 'row', alignItems: 'center',
    borderTopWidth: 1, borderTopColor: 'rgba(0,230,118,0.12)',
    paddingVertical: 10,
  },
  adStatItem: {
    flex: 1, alignItems: 'center', gap: 2,
  },
  adStatNum: {
    fontFamily: FONTS.title, fontSize: 16, color: COLORS.green,
  },
  adStatLabel: {
    fontFamily: FONTS.body, fontSize: 10, color: COLORS.muted2,
  },
  adStatDivider: {
    width: 1, height: 28, backgroundColor: 'rgba(255,255,255,0.07)',
  },

  // Rejected box
  adRejectedBox: {
    backgroundColor: 'rgba(239,68,68,0.08)', borderRadius: 10,
    borderWidth: 1, borderColor: 'rgba(239,68,68,0.20)',
    paddingHorizontal: 12, paddingVertical: 8,
  },
  adRejectedText: {
    fontFamily: FONTS.body, fontSize: 12, color: '#ef4444', lineHeight: 18,
  },

  // How it works
  howCard: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.xl,
    borderWidth: 1, borderColor: COLORS.border, padding: 20,
  },
  howTitle:     { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.text, marginBottom: 16 },
  howItem:      { flexDirection: 'row', gap: 14, marginBottom: 14 },
  howNum: {
    width: 26, height: 26, borderRadius: 13,
    backgroundColor: COLORS.greenMuted, borderWidth: 1, borderColor: COLORS.green,
    alignItems: 'center', justifyContent: 'center', flexShrink: 0,
  },
  howNumText:   { fontFamily: FONTS.bodySemiBold, fontSize: 12, color: COLORS.green },
  howItemTitle: { fontFamily: FONTS.bodyMedium,   fontSize: 13, color: COLORS.text,   marginBottom: 2 },
  howItemDesc:  { fontFamily: FONTS.body,          fontSize: 12, color: COLORS.muted2 },

  // Escasez + prueba social
  socialProofRow: { flexDirection: 'row', flexWrap: 'wrap' as const, gap: 8, marginBottom: 16 },
  socialProofChip: {
    backgroundColor: 'rgba(0,230,118,0.08)', borderRadius: RADIUS.full,
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.25)',
    paddingHorizontal: 12, paddingVertical: 6,
  },
  socialProofText: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.green },

  // Seeding urgency banner
  seedingUrgencyBanner: {
    backgroundColor: 'rgba(0,230,118,0.07)',
    borderRadius: RADIUS.lg,
    borderWidth: 1,
    borderColor: 'rgba(0,230,118,0.30)',
    paddingHorizontal: 14,
    paddingVertical: 10,
    marginBottom: 12,
    gap: 4,
  },
  seedingUrgencyTitle: {
    fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.green,
  },
  seedingUrgencySub: {
    fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted2,
  },
  seedingScarcityRow: {
    marginTop: 4,
    backgroundColor: 'rgba(239,68,68,0.10)',
    borderRadius: 6,
    paddingHorizontal: 10,
    paddingVertical: 5,
  },
  seedingScarcityText: {
    fontFamily: FONTS.bodySemiBold, fontSize: 12, color: '#EF4444',
  },

  // FOMO banner
  fomoBanner: {
    backgroundColor: 'rgba(251,146,60,0.10)', borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: 'rgba(251,146,60,0.30)',
    paddingHorizontal: 14, paddingVertical: 8, marginBottom: 12,
  },
  fomoText: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: '#FB923C', textAlign: 'center' as const },

  // Precio subiendo badge
  pricingRisingBadge: {
    alignSelf: 'flex-start' as const, borderRadius: RADIUS.full,
    backgroundColor: 'rgba(239,68,68,0.12)', borderWidth: 1, borderColor: 'rgba(239,68,68,0.3)',
    paddingHorizontal: 10, paddingVertical: 4, marginTop: 6,
  },
  pricingRisingText: { fontFamily: FONTS.bodyMedium, fontSize: 11, color: '#ef4444' },

  // Precio base / ciudad en tarjeta de paquete
  pkgCityLabel: { fontFamily: FONTS.bodyMedium, fontSize: 9, color: COLORS.green, marginTop: 1 },

  // Ver más opciones
  showMoreBtn: {
    alignItems: 'center' as const, paddingVertical: 12,
    borderRadius: RADIUS.lg, borderWidth: 1, borderColor: COLORS.border,
    backgroundColor: COLORS.card, marginTop: -4,
  },
  showMoreText: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted2 },

  // Estimación de retorno
  estBox: {
    marginTop: 10,
    backgroundColor: 'rgba(0,230,118,0.06)',
    borderRadius: RADIUS.md,
    borderWidth: 1,
    borderColor: 'rgba(0,230,118,0.18)',
    paddingHorizontal: 12,
    paddingVertical: 10,
    gap: 6,
  },
  estRow: { flexDirection: 'row' as const, alignItems: 'flex-start' as const, gap: 8 },
  estIcon: { fontSize: 13, lineHeight: 18 },
  estText: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.text, flex: 1, lineHeight: 18 },
  estDisclaimer: {
    fontFamily: FONTS.body, fontSize: 10, color: COLORS.muted,
    marginTop: 2, fontStyle: 'italic' as const,
  },

  // FOMO — sin anuncios activos
  noAdsFomoBanner: {
    marginHorizontal: SPACING.xl,
    marginBottom: 14,
    backgroundColor: 'rgba(239,68,68,0.07)',
    borderRadius: RADIUS.lg,
    borderWidth: 1,
    borderColor: 'rgba(239,68,68,0.25)',
    paddingHorizontal: 14,
    paddingVertical: 10,
  },
  noAdsFomoText: {
    fontFamily: FONTS.bodyMedium,
    fontSize: 12,
    color: '#ef4444',
    lineHeight: 18,
  },
});
