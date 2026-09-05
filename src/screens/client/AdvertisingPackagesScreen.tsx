/**
 * AdvertisingPackagesScreen
 * Catálogo de paquetes publicitarios con selector por tipo.
 */
import { LinearGradient } from 'expo-linear-gradient';
import { ArrowLeft, Megaphone, Star, TrendingUp, Users } from 'lucide-react-native';
import React, { useEffect, useMemo, useRef, useState } from 'react';
import { useTranslation } from 'react-i18next';
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
import { calcAdPrice } from '../../constants/adPricing';

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

type TFn = (key: string, options?: Record<string, any>) => string;

// ─── Configuración de tipos (datos no traducibles) ───────────────────────────

const TYPE_META = {
  banner_home: {
    emoji:      '📢',
    reqMin:     8,
    reqMax:     15,
    reachBase:  3000,
    color:      COLORS.green,
    gradient:   ['rgba(0,230,118,0.14)', 'rgba(0,230,118,0.03)'] as [string, string],
  },
  sponsored_group: {
    emoji:      '⭐',
    reqMin:     5,
    reqMax:     10,
    reachBase:  1500,
    color:      '#FFD700',
    gradient:   ['rgba(255,215,0,0.14)', 'rgba(255,215,0,0.03)'] as [string, string],
  },
  profile_ad: {
    emoji:      '👤',
    reqMin:     3,
    reqMax:     8,
    reachBase:  800,
    color:      '#A78BFA',
    gradient:   ['rgba(167,139,250,0.14)', 'rgba(167,139,250,0.03)'] as [string, string],
  },
} as const;

type AdType = keyof typeof TYPE_META;

// ─── Textos de tipos (traducidos) ────────────────────────────────────────────

const getTypeText = (t: TFn): Record<AdType, {
  label: string; title: string; desc: string; benefit: string; visibility: string; requests: string;
}> => ({
  banner_home: {
    label:      t('advertisingPackagesScreen.types.banner_home.label'),
    title:      t('advertisingPackagesScreen.types.banner_home.title'),
    desc:       t('advertisingPackagesScreen.types.banner_home.desc'),
    benefit:    t('advertisingPackagesScreen.types.banner_home.benefit'),
    visibility: t('advertisingPackagesScreen.types.banner_home.visibility'),
    requests:   t('advertisingPackagesScreen.types.banner_home.requests'),
  },
  sponsored_group: {
    label:      t('advertisingPackagesScreen.types.sponsored_group.label'),
    title:      t('advertisingPackagesScreen.types.sponsored_group.title'),
    desc:       t('advertisingPackagesScreen.types.sponsored_group.desc'),
    benefit:    t('advertisingPackagesScreen.types.sponsored_group.benefit'),
    visibility: t('advertisingPackagesScreen.types.sponsored_group.visibility'),
    requests:   t('advertisingPackagesScreen.types.sponsored_group.requests'),
  },
  profile_ad: {
    label:      t('advertisingPackagesScreen.types.profile_ad.label'),
    title:      t('advertisingPackagesScreen.types.profile_ad.title'),
    desc:       t('advertisingPackagesScreen.types.profile_ad.desc'),
    benefit:    t('advertisingPackagesScreen.types.profile_ad.benefit'),
    visibility: t('advertisingPackagesScreen.types.profile_ad.visibility'),
    requests:   t('advertisingPackagesScreen.types.profile_ad.requests'),
  },
});

// ── Texto de comparación según nivel de demanda ───────────────────────────────
function getDemandComparisonText(t: TFn, demandLevel: string | null | undefined): string {
  if (demandLevel === 'high') return t('advertisingPackagesScreen.demandComparison.high');
  if (demandLevel === 'medium') return t('advertisingPackagesScreen.demandComparison.medium');
  return t('advertisingPackagesScreen.demandComparison.default');
}

// ── Estimación de retorno ─────────────────────────────────────────────────────
// Solo escala por duración — el multiplicador de demanda se quitó junto
// con el precio dinámico (sql/612, decisión del usuario 2026-09-05):
// precio y estimaciones fijas y predecibles, sin variar según qué tan
// ocupada esté la ciudad.
function calcEstimates(
  type: AdType,
  durationDays: number,
): { reqMin: number; reqMax: number; views: number } {
  const base = TYPE_META[type];
  const durFactor = durationDays / 7;
  return {
    reqMin: Math.max(1, Math.round(base.reqMin * durFactor)),
    reqMax: Math.max(2, Math.round(base.reqMax * durFactor)),
    views:  Math.round(base.reachBase * durFactor),
  };
}

// sql/612 (2026-09-05): se quitó la distinción de posición "top_1_3"/
// "top_4_10" del Banner Home (un solo precio por duración) — simplifica
// tanto el precio como esta pantalla. Solo queda por si algún paquete
// viejo desactivado aún trae un tier — los nuevos ya no lo tienen.
function getTierBadge(t: TFn, pkg: AdPackage, idx: number): { label: string; color: string; bg: string } | null {
  if (pkg.tier === 'top_1_3')  return { label: t('advertisingPackagesScreen.positionTier.top1_3'),  color: COLORS.green, bg: 'rgba(0,230,118,0.14)' };
  if (pkg.tier === 'top_4_10') return { label: t('advertisingPackagesScreen.positionTier.top4_10'), color: '#F59E0B',   bg: 'rgba(245,158,11,0.14)' };
  return null;
}

// sponsored_group solo se vende desde el panel del grupo (no aquí).
// 2026-09-04 (sql/607+608): profile_ad ya aplica también a grupos (se
// oculta en perfiles de su misma categoría, no se bloquea la compra) —
// clientes ya no pueden comprar nada de esto (tab quitado + bloqueado en
// el servidor), así que solo queda group/talent, mismo catálogo para
// los dos.
const TYPE_ORDER: AdType[] = ['banner_home', 'profile_ad'];

// ─── Componente ───────────────────────────────────────────────────────────────

export default function AdvertisingPackagesScreen({ navigation, route }: any) {
  const { t } = useTranslation();
  const { profile: authProfile, role: authRole, safeCity } = useAuth();
  const initialType = (route?.params?.initialType as AdType | undefined) ?? 'banner_home';

  const typeText = useMemo(() => getTypeText(t), [t]);

  // Badges dinámicos: paquete del medio = Recomendado, último = Mejor valor
  const REC_BADGE  = useMemo(() => ({ label: t('advertisingPackagesScreen.recommendedBadge'), color: '#000', bg: COLORS.green }), [t]);
  const PREM_BADGE = useMemo(() => ({ label: t('advertisingPackagesScreen.bestSellerBadge'),  color: '#000', bg: '#F59E0B'   }), [t]);
  const REC_MSG    = t('advertisingPackagesScreen.recommendedMsg');
  const PREM_MSG   = t('advertisingPackagesScreen.bestSellerMsg');

  const STATUS_LABEL: Record<string, { text: string; color: string }> = useMemo(() => ({
    active:          { text: t('advertisingPackagesScreen.status.active'),          color: COLORS.green  },
    pending_review:  { text: t('advertisingPackagesScreen.status.pending_review'),  color: '#F59E0B'     },
    pending_payment: { text: t('advertisingPackagesScreen.status.pending_payment'), color: '#EF4444'     },
    paused:          { text: t('advertisingPackagesScreen.status.paused'),          color: COLORS.muted2 },
    rejected:        { text: t('advertisingPackagesScreen.status.rejected'),        color: '#EF4444'     },
    expired:         { text: t('advertisingPackagesScreen.status.expired'),         color: COLORS.muted  },
  }), [t]);

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
        setFomoMsg(t('advertisingPackagesScreen.fomoGroupUpdated'));
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

  // Petición real (2026-09-04, sql/608): clientes no pueden comprar
  // publicidad — tab quitado + bloqueado en el servidor, esto es refuerzo
  // por si llegan aquí desde un link viejo/directo.
  if (authRole === 'client') {
    return (
      <View style={[s.container, s.centered]}>
        <Text style={{ fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.text, textAlign: 'center', paddingHorizontal: 30 }}>
          La publicidad está disponible solo para grupos y talentos.
        </Text>
      </View>
    );
  }

  const cfg      = { ...TYPE_META[selectedType], ...typeText[selectedType] };
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
            <Text style={s.headerTitle}>{t('advertisingPackagesScreen.headerTitle')}</Text>
            <Text style={s.headerSub}>{t('advertisingPackagesScreen.headerSub')}</Text>
          </View>
        </View>

        <ScrollView showsVerticalScrollIndicator={false} contentContainerStyle={s.scroll} refreshControl={<RefreshControl refreshing={refreshing} onRefresh={onRefresh} tintColor={COLORS.green} />}>

          {/* ── Seeding urgency banner ── */}
          {cityStatus?.is_seeding && (
            <View style={s.seedingUrgencyBanner}>
              <Text style={s.seedingUrgencyTitle}>{t('advertisingPackagesScreen.seedingUrgencyTitle')}</Text>
              {seedingSlots && (
                <Text style={s.seedingUrgencySub}>
                  {t('advertisingPackagesScreen.seedingUrgencySub', { count: seedingSlots.slots_total })}
                </Text>
              )}
              {seedingSlots && seedingSlots.slots_available <= seedingSlots.slots_total && (
                <View style={s.seedingScarcityRow}>
                  <Text style={s.seedingScarcityText}>
                    {seedingSlots.slots_available <= 0
                      ? t('advertisingPackagesScreen.seedingScarcityAllTaken')
                      : seedingSlots.slots_available <= 3
                      ? t('advertisingPackagesScreen.seedingScarcityCritical', { count: seedingSlots.slots_available })
                      : t('advertisingPackagesScreen.seedingScarcityAvailable', { count: seedingSlots.slots_available })}
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
                {t('advertisingPackagesScreen.noAdsFomoText')}
              </Text>
              {demandInfo?.demand_level === 'high' && (
                <Text style={[s.noAdsFomoText, { color: '#ef4444', marginTop: 4 }]}>
                  {t('advertisingPackagesScreen.highDemandFomo')}
                </Text>
              )}
            </View>
          )}

          {/* ── Stats strip ── */}
          <View style={s.statsStrip}>
            {[
              { icon: Users,      value: '+500',  label: t('advertisingPackagesScreen.stats.activeUsers') },
              { icon: TrendingUp, value: '24h',   label: t('advertisingPackagesScreen.stats.approval') },
              { icon: Star,       value: '3',      label: t('advertisingPackagesScreen.stats.formats') },
            ].map((stat, i) => (
              <View key={i} style={s.statItem}>
                <stat.icon size={14} color={COLORS.green} />
                <Text style={s.statValue}>{stat.value}</Text>
                <Text style={s.statLabel}>{stat.label}</Text>
              </View>
            ))}
          </View>

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
              ? t('advertisingPackagesScreen.scarcityWaitlist')
              : spotsLeft <= 2
              ? t('advertisingPackagesScreen.scarcityCritical', { count: spotsLeft })
              : spotsLeft <= 5
              ? t('advertisingPackagesScreen.scarcityAvailable', { count: spotsLeft })
              : null;
            const isCritical = spotsLeft <= 1 && spotsLeft > 0;
            return (
              <View style={s.socialProofRow}>
                {totalPromoted > 0 && (
                  <View style={s.socialProofChip}>
                    <Text style={s.socialProofText}>
                      {t('advertisingPackagesScreen.socialProofGroups', { count: totalPromoted })}
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
                const c   = { ...TYPE_META[type], ...typeText[type] };
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
              style={StyleSheet.absoluteFill}
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
              <Text style={s.emptyText}>{t('advertisingPackagesScreen.emptyTitle')}</Text>
              <Text style={s.emptySub}>{t('advertisingPackagesScreen.emptySub')}</Text>
            </View>
          ) : (
            <View style={s.pkgList}>
              {visiblePkgs.map((pkg, idx) => {
                const isRec   = idx === recIdx;
                const isPrem  = idx === premIdx && typePkgs.length > 1;
                const badgeCfg = isRec ? REC_BADGE : isPrem ? PREM_BADGE : null;
                const tier    = getTierBadge(t, pkg, idx);
                const finalPrice = Math.ceil(calcAdPrice(pkg.type, pkg.duration_days, 'city', false));
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
                      style={StyleSheet.absoluteFill}
                      start={{ x: 0, y: 0 }} end={{ x: 1, y: 1 }}
                    />

                    {/* Badges row */}
                    <View style={s.pkgBadgeRow}>
                      {badgeCfg && (
                        <View style={[s.badge, { backgroundColor: badgeCfg.bg }]}>
                          <Text style={[s.badgeText, { color: badgeCfg.color }]}>{badgeCfg.label}</Text>
                        </View>
                      )}
                      {tier && (
                        <View style={[s.positionBadge, { backgroundColor: tier.bg }]}>
                          <Text style={[s.positionBadgeText, { color: tier.color }]}>{tier.label}</Text>
                        </View>
                      )}
                    </View>

                    {/* Contenido principal */}
                    <View style={s.pkgTop}>
                      {/* Info izquierda */}
                      <View style={{ flex: 1 }}>
                        <Text style={s.pkgName}>{pkg.name}</Text>
                        <View style={s.pkgDurRow}>
                          <View style={[s.pkgDurChip, { borderColor: `${cfg.color}40`, backgroundColor: `${cfg.color}12` }]}>
                            <Text style={[s.pkgDurText, { color: cfg.color }]}>{t('advertisingPackagesScreen.durationDays', { count: pkg.duration_days })}</Text>
                          </View>
                        </View>
                        {pkg.tier === 'top_1_3' && (
                          <Text style={[s.pkgTierDesc, { color: COLORS.green }]}>{t('advertisingPackagesScreen.tierTop1_3Desc')}</Text>
                        )}
                        {pkg.tier === 'top_4_10' && (
                          <Text style={[s.pkgTierDesc, { color: '#F59E0B' }]}>{t('advertisingPackagesScreen.tierTop4_10Desc')}</Text>
                        )}
                        {pkg.description && (
                          <Text style={s.pkgDesc} numberOfLines={2}>{pkg.description}</Text>
                        )}
                        <Text style={s.pkgReach}>
                          {t('advertisingPackagesScreen.estimatedReach', { reach: reach >= 1000 ? `${(reach / 1000).toFixed(1)}k` : reach })}
                        </Text>
                      </View>

                      {/* Precio derecha */}
                      <View style={s.pkgPriceBlock}>
                        <Text style={[s.pkgPrice, { color: cfg.color }]}>
                          ${finalPrice.toLocaleString()}
                        </Text>
                        <Text style={s.pkgCityLabel}>{t('advertisingPackagesScreen.basePriceLabel')}</Text>
                        <Text style={s.pkgPerDay}>{t('advertisingPackagesScreen.perDay', { price: perDay.toLocaleString() })}</Text>
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
                        {isRec ? t('advertisingPackagesScreen.continueRecommended') : t('advertisingPackagesScreen.hire')}
                      </Text>
                    </View>

                    {/* Estimación de retorno — paquete recomendado: completo; otros: compacto */}
                    {(() => {
                      const est = calcEstimates(selectedType, pkg.duration_days);
                      const viewsLabel = est.views >= 1000
                        ? `${(est.views / 1000).toFixed(1)}k`
                        : est.views.toLocaleString();
                      const comparisonText = getDemandComparisonText(t, demandInfo?.demand_level);
                      if (isRec) {
                        return (
                          <View style={s.estBox}>
                            <View style={s.estRow}>
                              <Text style={s.estIcon}>📨</Text>
                              <Text style={s.estText}>
                                {t('advertisingPackagesScreen.estReceiveRange', { min: est.reqMin, max: est.reqMax })}
                              </Text>
                            </View>
                            <Text style={s.estDisclaimer}>
                              {t('advertisingPackagesScreen.estDisclaimerMain')}
                            </Text>
                            <View style={s.estRow}>
                              <Text style={s.estIcon}>👁</Text>
                              <Text style={s.estText}>
                                {t('advertisingPackagesScreen.estViews', { views: viewsLabel })}
                              </Text>
                            </View>
                            <Text style={[s.estDisclaimer, { color: COLORS.green }]}>
                              {comparisonText}
                            </Text>
                            {demandInfo?.demand_level === 'high' && (
                              <Text style={[s.estDisclaimer, { color: '#ef4444', marginTop: 2 }]}>
                                {t('advertisingPackagesScreen.highDemandFomo')}
                              </Text>
                            )}
                          </View>
                        );
                      }
                      // Versión compacta para paquetes no recomendados
                      return (
                        <View style={[s.estBox, { gap: 4, paddingTop: 10 }]}>
                          <Text style={[s.estText, { fontSize: 11 }]}>
                            {t('advertisingPackagesScreen.estCompact', { min: est.reqMin, max: est.reqMax, views: viewsLabel })}
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

          {/* ── Mis anuncios ── */}
          {myAds.length > 0 && (
            <View style={s.myAdsCard}>
              <Text style={s.myAdsTitle}>{t('advertisingPackagesScreen.myAdsTitle')}</Text>
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
                            style={StyleSheet.absoluteFill}
                            start={{ x: 0, y: 0 }} end={{ x: 1, y: 1 }}
                          />
                          <Text style={s.adPreviewTag}>{t('advertisingPackagesScreen.advertisingTag')}</Text>
                          <Text style={s.adPreviewTitle} numberOfLines={1}>{ad.title}</Text>
                          {ad.subtitle ? (
                            <Text style={s.adPreviewSub} numberOfLines={1}>{ad.subtitle}</Text>
                          ) : null}
                          <View style={s.adPreviewLive}>
                            <View style={s.adPreviewLiveDot} />
                            <Text style={s.adPreviewLiveText}>{t('advertisingPackagesScreen.liveNow')}</Text>
                          </View>
                        </View>

                        {/* Stats row */}
                        <View style={s.adStatsRow}>
                          <View style={s.adStatItem}>
                            <Text style={s.adStatNum}>{(ad.impressions ?? 0).toLocaleString()}</Text>
                            <Text style={s.adStatLabel}>{t('advertisingPackagesScreen.views')}</Text>
                          </View>
                          <View style={s.adStatDivider} />
                          <View style={s.adStatItem}>
                            <Text style={s.adStatNum}>{(ad.clicks ?? 0).toLocaleString()}</Text>
                            <Text style={s.adStatLabel}>{t('advertisingPackagesScreen.clicks')}</Text>
                          </View>
                          <View style={s.adStatDivider} />
                          <View style={s.adStatItem}>
                            <Text style={[s.adStatNum, { color: daysLeft && daysLeft <= 3 ? COLORS.orange : COLORS.green }]}>
                              {daysLeft ?? '—'}d
                            </Text>
                            <Text style={s.adStatLabel}>{t('advertisingPackagesScreen.remaining')}</Text>
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
            <Text style={s.howTitle}>{t('advertisingPackagesScreen.howItWorksTitle')}</Text>
            {[
              { n: '1', t: t('advertisingPackagesScreen.steps.step1.title'), d: t('advertisingPackagesScreen.steps.step1.desc') },
              { n: '2', t: t('advertisingPackagesScreen.steps.step2.title'), d: t('advertisingPackagesScreen.steps.step2.desc') },
              { n: '3', t: t('advertisingPackagesScreen.steps.step3.title'), d: t('advertisingPackagesScreen.steps.step3.desc') },
              { n: '4', t: t('advertisingPackagesScreen.steps.step4.title'), d: t('advertisingPackagesScreen.steps.step4.desc') },
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
