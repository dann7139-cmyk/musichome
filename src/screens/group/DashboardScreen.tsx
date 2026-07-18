import VideoPlayer from '../../components/ui/VideoPlayer';
import { openScheduledQuotes } from '../../components/requests/ScheduledQuotesCarousel';
import { LinearGradient } from 'expo-linear-gradient';

import {
  Bell,
  CalendarDays,
  CalendarOff,
  Camera,
  ChevronRight,
  Clock,
  Film,
  Pencil,
  Rocket,
  Shield,
  Star,
  TrendingUp,
  UserMinus,
  X,
  Zap,
} from 'lucide-react-native';
import React, { useCallback, useEffect, useRef, useState } from 'react';
import {
  ActivityIndicator,
  Alert,
  Animated,
  AppState,
  Image,
  KeyboardAvoidingView,
  Modal,
  Platform,
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
import LevelBadge from '../../components/ui/LevelBadge';
import Particles from '../../components/ui/Particles';
import VerifiedBadge from '../../components/ui/VerifiedBadge';
import PlusDashboardCard from '../../components/ui/PlusDashboardCard';
import { pickAndUploadGroupImage } from '../../utils/uploadGroupImage';
import { pickAndUploadGroupVideo, pickAndUploadGroupVideoMulti } from '../../utils/uploadGroupVideo';
import { normalizeCity } from '../../utils/cityUtils';
import { stateToCountry } from '../../utils/locationUtils';
import { validatePublicText } from '../../utils/textValidation';
import { useAuth } from '../../context/AuthContext';
import { useExpress } from '../../context/ExpressContext';
import { useGroupBadges } from '../../context/GroupBadgesContext';
import { useBackgroundLocation } from '../../hooks/useBackgroundLocation';
import * as Haptics from 'expo-haptics';

// ─── Types ────────────────────────────────────────────────────────────────────

interface Group {
  id: string;
  name: string;
  description: string | null;
  genre: string | null;
  city: string | null;
  state: string | null;
  country: string | null;
  is_verified: boolean;
  is_active: boolean;
  rating: number | null;
  profile_image: string | null;
  promo_video: string | null;
  owner_id: string;
  nivel?: string | null;
  photo_status?: 'none' | 'pending' | 'approved' | 'rejected';
  video_status?: 'none' | 'pending' | 'approved' | 'rejected';
  photo_reject_reason?: string | null;
  video_reject_reason?: string | null;
  referral_code?: string | null;
  badges?: string[] | null;
  recent_completions?: number | null;
  has_sound?:             boolean | null;
  sound_capacity_max?:    number | null;
  has_lighting?:          boolean | null;
  lighting_level?:        string | null;
  has_stage?:             boolean | null;
  stage_sizes_available?: string[] | null;
  has_led_screen?:        boolean | null;
  led_sizes_available?:   string[] | null;
  power_amps?:            number | null;
  needs_parking?:         boolean | null;
  setup_minutes?:         number | null;
  includes_text?:         string | null;
}

interface FinancialStats {
  netEarnings: number;
  monthNetEarnings: number;
  pendingCount: number;
  completedCount: number;
  cancellationCount: number;
  totalCount: number;
}

// ─── Constants ────────────────────────────────────────────────────────────────

const EVENT_EMOJI: Record<string, string> = {
  fiesta_privada: '🎉', boda: '💍', cumpleanos: '🎂',
  graduacion: '🎓', empresarial: '🏢', otro: '🎵',
};

function fmt(n: number) {
  return n.toLocaleString('es-MX', { minimumFractionDigits: 0 });
}

// ─── Equipment options (modal Mi Equipo) ──────────────────────────────────────
const LIGHTING_LEVEL_OPTIONS = [
  { key: 'simple',  label: 'Sencilla' },
  { key: 'pro',     label: 'Profesional' },
  { key: 'premium', label: 'Premium' },
];
const STAGE_SIZE_OPTIONS = [
  { key: 'small',   label: 'Chico 3×2m' },
  { key: 'medium',  label: 'Mediano 4×3m' },
  { key: 'wedding', label: 'Grande boda 6×4m' },
];
const LED_SIZE_OPTIONS = [
  { key: 'medium', label: 'Mediana' },
  { key: 'large',  label: 'Grande' },
  { key: 'xl',     label: 'XL boda' },
];
function toggleItem(arr: string[], item: string): string[] {
  return arr.includes(item) ? arr.filter(x => x !== item) : [...arr, item];
}

// ─── Main Screen ──────────────────────────────────────────────────────────────

export default function GroupDashboardScreen({ navigation }: any) {
  const { profile: authProfile } = useAuth();
  const { setPendingQuotesCount } = useGroupBadges();
  const { dispatches: expressDispatches, hasDismissed: expressHasDismissed, reviveAll: expressReviveAll } = useExpress();
  useBackgroundLocation(); // GPS en vivo — actualiza group_locations en background
  const [group, setGroup]               = useState<Group | null>(null);
  const [stats, setStats] = useState<FinancialStats>({
    netEarnings: 0,
    monthNetEarnings: 0, pendingCount: 0, completedCount: 0,
    cancellationCount: 0, totalCount: 0,
  });
  const [_message, setMessage] = useState('');

  const [loading, setLoading]     = useState(true);
  const [error, setError]         = useState<string | null>(null);
  const [noGroup, setNoGroup]     = useState(false);
  const [createForm, setCreateForm] = useState({ name: '', genre: '', state: '' });
  const [creating, setCreating]   = useState(false);
  const [refreshing, setRefreshing] = useState(false);
  const [editVisible, setEditVisible] = useState(false);
  const [editForm, setEditForm] = useState({
    name: '', description: '', genre: '', state: '',
    has_sound: false,      sound_capacity_max: '',
    has_lighting: false,   lighting_level: '',
    has_stage: false,      stage_sizes_available: [] as string[],
    has_led_screen: false, led_sizes_available: [] as string[],
    power_amps: '', needs_parking: false, setup_minutes: '', includes_text: '',
  });
  const [editSaving, setEditSaving] = useState(false);
  const [photoLoading, setPhotoLoading] = useState(false);
  const [videoLoading, setVideoLoading] = useState(false);
  const [multiVideoLoading, setMultiVideoLoading] = useState(false);
  const [myVideos, setMyVideos] = useState<any[]>([]);
  const [videoSuccessMsg, setVideoSuccessMsg] = useState(false);
  const [unreadNotifications, setUnreadNotifications] = useState(0);
  const [ownerArtist, setOwnerArtist] = useState<any | null>(null);
  const [members, setMembers] = useState<any[]>([]);
  const [pendingInvitationsCount, setPendingInvitationsCount] = useState(0);
  const [selectedMember, setSelectedMember] = useState<any | null>(null);
  const [stripeInfo, setStripeInfo] = useState<{
    stripe_account_id: string | null;
    stripe_onboarding_completed: boolean;
    pending_message: string | null;
  }>({ stripe_account_id: null, stripe_onboarding_completed: false, pending_message: null });
  const [pendingQuotes,      setPendingQuotes]      = useState<any[]>([]);
  const [walletBalance,      setWalletBalance]      = useState<number>(0);
  const [loyalClients,       setLoyalClients]       = useState<any[]>([]);
  const [zoneStats,          setZoneStats]          = useState<any>(null);
  const [cityDemand,         setCityDemand]         = useState<any>(null);
  const [rankingPos,         setRankingPos]         = useState<any>(null);
  const [adSlots,            setAdSlots]            = useState<any>(null);
  const [competitorAlert,    setCompetitorAlert]    = useState<'rising' | 'displaced' | null>(null);
  const [descriptionError, setDescriptionError] = useState<string | null>(null);
  const [includesError,    setIncludesError]    = useState<string | null>(null);
  const prevRankPosRef  = useRef<number | null>(null);
  const promoPulseAnim  = useRef(new Animated.Value(1)).current;
  const rankSuccessAnim = useRef(new Animated.Value(0)).current;
  const [rankSuccessPos, setRankSuccessPos] = useState<number | null>(null);
  const rankDropAnim    = useRef(new Animated.Value(0)).current;
  const rankShakeAnim   = useRef(new Animated.Value(0)).current;
  const [rankDropVisible, setRankDropVisible] = useState(false);
  const [idleAlert, setIdleAlert]           = useState<'position' | 'demand' | null>(null);
  const [retentionAlert, setRetentionAlert] = useState(false);
  const idleTimerRef        = useRef<ReturnType<typeof setTimeout> | null>(null);
  const retentionShownRef   = useRef(false);
  const [biddingLoading, setBiddingLoading] = useState(false);
  const [focusAlert, setFocusAlert]         = useState(false);
  const hasVisitedRef  = useRef(false);
  const almostUpPulse  = useRef(new Animated.Value(1)).current;
  const almostUpAnim       = useRef<Animated.CompositeAnimation | null>(null);
  const expressBannerSlide = useRef(new Animated.Value(-50)).current;
  const expressPulse       = useRef(new Animated.Value(1)).current;
  const [groupAvailability,  setGroupAvailability]  = useState<string>('available');
  const [availabilityLoading, setAvailabilityLoading] = useState(false);
  const [cityStatus,         setCityStatus]         = useState<{ status: string; price_multiplier: number; is_seeding: boolean } | null>(null);
  const [seedingSlots,       setSeedingSlots]       = useState<{ slots_total: number; slots_used: number; slots_available: number } | null>(null);
  const [openExpressCount,   setOpenExpressCount]   = useState(0);

  const groupIdRef  = useRef<string | null>(null);
  const appStateRef = useRef(AppState.currentState);

  useEffect(() => { fetchData(); fetchMessage(); fetchWallet(); }, []);

  // Animación pulsante para escasez crítica en promo card
  useEffect(() => {
    const anim = Animated.loop(
      Animated.sequence([
        Animated.timing(promoPulseAnim, { toValue: 0.35, duration: 550, useNativeDriver: true }),
        Animated.timing(promoPulseAnim, { toValue: 1,    duration: 550, useNativeDriver: true }),
      ])
    );
    anim.start();
    return () => anim.stop();
  }, []);

  // Alerta de inactividad — mostrar si el usuario tiene bid activo y no actúa (8–12s)
  useEffect(() => {
    if (idleTimerRef.current) clearTimeout(idleTimerRef.current);
    if (!rankingPos?.my_bid) return;
    const delay = 8000 + Math.random() * 4000;
    idleTimerRef.current = setTimeout(() => {
      const isHighDemand = cityDemand?.demand_level === 'high' || cityDemand?.demand_level === 'very_high';
      setIdleAlert(isHighDemand ? 'demand' : 'position');
      setTimeout(() => setIdleAlert(null), 5000);
    }, delay);
    return () => { if (idleTimerRef.current) clearTimeout(idleTimerRef.current); };
  }, [rankingPos]);

  // Micro-retención: recordatorio único a los 30–60s si tiene bid activo
  useEffect(() => {
    if (retentionShownRef.current) return;
    if (!rankingPos?.my_bid) return;
    const delay = 30_000 + Math.random() * 30_000;
    const t = setTimeout(() => {
      if (retentionShownRef.current) return;
      if (idleAlert || rankDropVisible || rankSuccessPos != null) return;
      retentionShownRef.current = true;
      setRetentionAlert(true);
      setTimeout(() => setRetentionAlert(false), 3000);
    }, delay);
    return () => clearTimeout(t);
  }, [rankingPos]);

  // Retención al regresar — focus event (se dispara al volver desde Bidding, etc.)
  useEffect(() => {
    const unsub = navigation.addListener('focus', () => {
      if (!hasVisitedRef.current) { hasVisitedRef.current = true; return; }
      if (!rankingPos?.my_bid) return;
      setFocusAlert(true);
      setTimeout(() => setFocusAlert(false), 2500);
    });
    return unsub;
  }, [navigation, rankingPos]);

  // Animación pulse para "casi subes" (gapReal <= 80)
  useEffect(() => {
    const gapReal = rankingPos?.gap_to_next as number | null | undefined;
    const isAlmostUp = gapReal != null && gapReal > 0 && gapReal <= 80;
    if (isAlmostUp) {
      almostUpAnim.current = Animated.loop(
        Animated.sequence([
          Animated.timing(almostUpPulse, { toValue: 1.04, duration: 500, useNativeDriver: true }),
          Animated.timing(almostUpPulse, { toValue: 1,    duration: 500, useNativeDriver: true }),
        ])
      );
      almostUpAnim.current.start();
    } else {
      almostUpAnim.current?.stop();
      almostUpPulse.setValue(1);
    }
    return () => { almostUpAnim.current?.stop(); };
  }, [rankingPos]);

  // Slide-in + pulse cuando hay solicitudes express (activas o ignoradas)
  const expressVisible = expressDispatches.length > 0 || expressHasDismissed;
  useEffect(() => {
    if (expressVisible) {
      Animated.spring(expressBannerSlide, {
        toValue: 0, useNativeDriver: true, tension: 80, friction: 10,
      }).start();
      const loop = Animated.loop(
        Animated.sequence([
          Animated.timing(expressPulse, { toValue: 1.025, duration: 900, useNativeDriver: true }),
          Animated.timing(expressPulse, { toValue: 1,     duration: 900, useNativeDriver: true }),
        ])
      );
      loop.start();
      return () => loop.stop();
    } else {
      expressBannerSlide.setValue(-50);
      expressPulse.setValue(1);
    }
  }, [expressVisible]);

  const fetchWallet = useCallback(async () => {
    const { data } = await supabase.rpc('get_my_wallet');
    if (data?.ok) {
      setWalletBalance(data.wallet?.available_balance ?? 0);
    }
  }, []);

  // ── Realtime: wallet del grupo ────────────────────────────────────────────
  useEffect(() => {
    const sub = supabase
      .channel('dashboard-wallet-realtime')
      .on('postgres_changes',
        { event: 'UPDATE', schema: 'public', table: 'group_wallets' },
        () => fetchWallet())
      .on('postgres_changes',
        { event: 'INSERT', schema: 'public', table: 'wallet_transactions' },
        () => fetchWallet())
      .subscribe();
    return () => { supabase.removeChannel(sub); };
  }, [fetchWallet]);

  // ── Realtime: actualizar badge de campana en tiempo real ─────────────────
  useEffect(() => {
    let channel: ReturnType<typeof supabase.channel> | null = null;
    supabase.auth.getSession().then(({ data: { session } }) => {
      if (!session) return;
      channel = supabase
        .channel('notif-badge-group')
        .on('postgres_changes', {
          event: 'INSERT',
          schema: 'public',
          table: 'notifications',
          filter: `user_id=eq.${session.user.id}`,
        }, (payload: any) => {
          if (payload.new && !payload.new.is_read) {
            setUnreadNotifications(prev => prev + 1);
          }
        })
        .subscribe();
    });
    return () => { if (channel) supabase.removeChannel(channel); };
  }, []);

  // ── Realtime: detectar competencia de bids en la ciudad ─────────────────
  useEffect(() => {
    if (!group?.id || !group?.city) return;
    const ch = supabase
      .channel('bid-competition-dash-' + group.city)
      .on('postgres_changes', {
        event: 'UPDATE', schema: 'public', table: 'groups',
        filter: `city=eq.${group.city}`,
      }, async (payload: any) => {
        if (payload.new?.id === group.id) return; // ignorar cambios propios
        // Mostrar alerta de competencia activa
        setCompetitorAlert('rising');
        // Después de 2s re-fetchear ranking y comparar posición
        setTimeout(async () => {
          const { data } = await supabase.rpc('get_group_ranking_position', {
            p_group_id: group.id, p_city: group.city,
          });
          if ((data as any)?.ok) {
            const newPos = (data as any).position as number | null;
            if (prevRankPosRef.current !== null && newPos !== null) {
              if (newPos > prevRankPosRef.current) {
                // Bajó posición — haptic + shake + banner
                setCompetitorAlert('displaced');
                Haptics.notificationAsync(Haptics.NotificationFeedbackType.Warning);
                setRankDropVisible(true);
                rankDropAnim.setValue(0);
                Animated.sequence([
                  Animated.timing(rankDropAnim, { toValue: 1, duration: 250, useNativeDriver: true }),
                  Animated.delay(2000),
                  Animated.timing(rankDropAnim, { toValue: 0, duration: 350, useNativeDriver: true }),
                ]).start(() => setRankDropVisible(false));
                Animated.sequence([
                  Animated.timing(rankShakeAnim, { toValue: 6, duration: 55, useNativeDriver: true }),
                  Animated.timing(rankShakeAnim, { toValue: -6, duration: 55, useNativeDriver: true }),
                  Animated.timing(rankShakeAnim, { toValue: 4, duration: 55, useNativeDriver: true }),
                  Animated.timing(rankShakeAnim, { toValue: 0, duration: 55, useNativeDriver: true }),
                ]).start();
              } else if (newPos < prevRankPosRef.current) {
                // ¡Subió posición! — animación de éxito
                setCompetitorAlert(null);
                setRankSuccessPos(newPos);
                Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success);
                rankSuccessAnim.setValue(0);
                Animated.sequence([
                  Animated.timing(rankSuccessAnim, { toValue: 1, duration: 300, useNativeDriver: true }),
                  Animated.delay(2200),
                  Animated.timing(rankSuccessAnim, { toValue: 0, duration: 400, useNativeDriver: true }),
                ]).start(() => setRankSuccessPos(null));
              } else {
                setCompetitorAlert(null);
              }
            }
            prevRankPosRef.current = newPos;
            setRankingPos(data);
          }
        }, 2000);
        // Auto-limpiar alerta tras 6s si no fue displaced
        setTimeout(() => setCompetitorAlert(prev => prev === 'rising' ? null : prev), 6000);
      })
      .subscribe();
    return () => { supabase.removeChannel(ch); };
  }, [group?.id, group?.city]);

  useEffect(() => {
    const unsubscribe = navigation.addListener('focus', async () => {
      fetchUnreadNotifications();
      fetchMembers();
      // Refrescar solicitudes de cotización al volver al dashboard
      if (groupIdRef.current) {
        supabase
          .from('quotes')
          .select('id, group_id, status, event_type, event_date, duration_hours, created_at, client:profiles!client_id(full_name)')
          .eq('group_id', groupIdRef.current)
          .in('status', ['pending', 'quoted'])
          .order('created_at', { ascending: false })
          .limit(5)
          .then(({ data }) => { if (data) { setPendingQuotes(data); setPendingQuotesCount(data.length); } });
      }
      if (groupIdRef.current) {
        const { data: { session } } = await supabase.auth.getSession();
        const token = session?.access_token;
        if (token) {
          const { data: verifyData } = await supabase.functions.invoke('verify-stripe-account', {
            body:    { group_id: groupIdRef.current },
            headers: { Authorization: `Bearer ${token}` },
          });
          applyVerifyResult(verifyData);
          // Solo re-lee DB si el verify no tiene datos útiles
          if (!verifyData) fetchStripeInfo(groupIdRef.current);
        } else {
          fetchStripeInfo(groupIdRef.current);
        }
      }
    });
    return unsubscribe;
  }, [navigation]);

  // Verifica estado real en Stripe cuando el usuario vuelve del browser de onboarding
  useEffect(() => {
    const sub = AppState.addEventListener('change', async (nextState) => {
      if (appStateRef.current.match(/inactive|background/) && nextState === 'active') {
        if (groupIdRef.current) {
          const { data: { session } } = await supabase.auth.getSession();
          const token = session?.access_token;
          if (token) {
            const { data: verifyData } = await supabase.functions.invoke('verify-stripe-account', {
              body:    { group_id: groupIdRef.current },
              headers: { Authorization: `Bearer ${token}` },
            });
            applyVerifyResult(verifyData);
            if (!verifyData) fetchStripeInfo(groupIdRef.current);
          } else {
            fetchStripeInfo(groupIdRef.current);
          }
        }
      }
      appStateRef.current = nextState;
    });
    return () => sub.remove();
  }, []);

  // ── Fetch ──────────────────────────────────────────────────────────────────

  const fetchMembers = async () => {
    const gid = groupIdRef.current;
    if (!gid) return;

    const { data: invData } = await supabase
      .from('job_invitations')
      .select(`
        id, status,
        invited_user:profiles!job_invitations_invited_user_id_fkey(id, full_name, avatar_url, phone_verified, id_verified)
      `)
      .eq('group_id', gid)
      .eq('status', 'accepted')
      .is('event_id', null);

    if (!invData) return;

    // Contar invitaciones pendientes para el badge
    const { count: pendingCount } = await supabase
      .from('job_invitations')
      .select('id', { count: 'exact', head: true })
      .eq('group_id', gid)
      .eq('status', 'pending');
    setPendingInvitationsCount(pendingCount ?? 0);

    const userIds = invData.map((inv: any) => inv.invited_user?.id).filter(Boolean);
    let artistMap: Record<string, any> = {};
    if (userIds.length > 0) {
      const { data: artistData } = await supabase
        .from('job_board_profiles')
        .select('user_id, instrument_or_role, availability_status')
        .in('user_id', userIds);
      artistData?.forEach((ap: any) => { artistMap[ap.user_id] = ap; });
    }

    setMembers(invData.map((inv: any) => ({
      ...inv,
      artist: artistMap[inv.invited_user?.id] ?? null,
    })));
  };

  const fetchStripeInfo = async (groupId: string) => {
    const { data } = await supabase
      .from('groups')
      .select('stripe_account_id, stripe_onboarding_completed')
      .eq('id', groupId)
      .single();
    if (data) {
      setStripeInfo(prev => ({
        ...prev,
        stripe_account_id:           data.stripe_account_id ?? null,
        stripe_onboarding_completed: data.stripe_onboarding_completed ?? false,
      }));
    }
  };

  // Aplica el resultado de verify-stripe-account directamente al estado
  // (evita una segunda lectura de DB con potencial race condition)
  const applyVerifyResult = (verifyData: any) => {
    if (!verifyData) return;
    if (verifyData.verified) {
      setStripeInfo(prev => ({
        ...prev,
        stripe_onboarding_completed: true,
        pending_message: null,
      }));
    } else if (verifyData.pending_message) {
      setStripeInfo(prev => ({
        ...prev,
        pending_message: verifyData.pending_message,
      }));
    }
  };

  const fetchUnreadNotifications = async () => {
    const { data: sd } = await supabase.auth.getSession();
    if (!sd.session) return;

    const { count } = await supabase
      .from('notifications')
      .select('*', { count: 'exact', head: true })
      .eq('user_id', sd.session.user.id)
      .eq('is_read', false);

    setUnreadNotifications(count ?? 0);
  };

  const toggleAvailability = async () => {
    const next = groupAvailability === 'available' ? 'offline' : 'available';
    setAvailabilityLoading(true);
    const { data, error } = await supabase.rpc('set_group_availability', { p_availability: next });
    if (error) {
      Alert.alert('Error', 'No se pudo actualizar la disponibilidad. Intenta de nuevo.');
    } else if (data?.ok) {
      setGroupAvailability(next);
    } else if (data?.error) {
      Alert.alert('Error', data.error === 'no_group_found' ? 'No se encontró tu grupo.' : data.error);
    }
    setAvailabilityLoading(false);
  };

  const fetchData = async () => {
    try {
      setError(null);
      const uid = authProfile?.id;
      if (!uid) throw new Error('Sin sesión activa.');

      // Fetch unread notifications
      fetchUnreadNotifications();

      // Usa RPC SECURITY DEFINER para evitar bloqueos de RLS en groups.
      // También garantiza LIMIT 1, por lo que maybeSingle() nunca falla con PGRST116.
      const { data: grpRaw, error: ge } = await supabase
        .rpc('get_my_group')
        .maybeSingle();
      if (ge) throw new Error('Error al cargar grupo: ' + ge.message);
      if (!grpRaw) { setNoGroup(true); setLoading(false); return; }
      const grp = grpRaw as Group;
      setNoGroup(false);
      setGroup(grp);
      groupIdRef.current = grp.id;
      fetchStripeInfo(grp.id);

      // 🎬 Mis videos del perfil (carrusel, sql/492)
      supabase.from('group_videos').select('id, url, status, created_at')
        .eq('group_id', grp.id).order('created_at', { ascending: true })
        .then(({ data: vids }) => setMyVideos(vids ?? []));

      // Leer availability directo desde el grupo ya cargado (get_my_group retorna SETOF groups)
      if ((grp as any).availability) {
        setGroupAvailability((grp as any).availability);
      }

      // Solicitudes de cotización activas
      const { data: quotesData } = await supabase
        .from('quotes')
        .select('id, group_id, status, event_type, event_date, duration_hours, created_at, client:profiles!client_id(full_name)')
        .eq('group_id', grp.id)
        .in('status', ['pending', 'quoted'])
        .order('created_at', { ascending: false })
        .limit(5);
      setPendingQuotes(quotesData ?? []);
      setPendingQuotesCount((quotesData ?? []).length);

      const now   = new Date();
      const monthStart = new Date(now.getFullYear(), now.getMonth(), 1).toISOString();

      // Todas las reservas para stats — 🔒 solo group_earnings: el grupo no
      // recibe total_price ni comisiones de plataforma
      const allRes = await supabase
        .from('reservations')
        .select('group_earnings, status, created_at')
        .eq('group_id', grp.id);

      if (allRes.data) {
        const all = allRes.data as any[];

        // ── Solo contar reservas completed o paid ──────────────────────────────
        const paid = all.filter(r => r.status === 'completed' || r.status === 'paid');

        const netEarnings    = paid.reduce((s, r) => s + (r.group_earnings ?? 0), 0);

        const monthNetEarnings = paid
          .filter(r => r.created_at >= monthStart)
          .reduce((s, r) => s + (r.group_earnings ?? 0), 0);

        const pendingCount       = all.filter(r => r.status === 'pending').length;
        const completedCount     = paid.length;
        const cancellationCount  = all.filter(r => r.status === 'cancelled').length;
        const totalCount         = all.filter(r => r.status !== 'pending').length;

        setStats({
          netEarnings,
          monthNetEarnings, pendingCount, completedCount,
          cancellationCount, totalCount,
        });
      }

      // ── Perfil artístico del dueño ───────────────────────────────────────────
      const { data: artistData } = await supabase
        .from('job_board_profiles')
        .select('id, instrument_or_role, bio, experience_years, rating, total_jobs, availability_status, is_visible')
        .eq('user_id', uid)
        .maybeSingle();
      setOwnerArtist(artistData ?? null);

      // ── Clientes frecuentes (loyalty) ────────────────────────────────────────
      const { data: loyalData } = await supabase.rpc('get_loyal_clients', { p_group_id: grp.id });
      setLoyalClients((loyalData ?? []).slice(0, 5));

      // ── Actividad de la zona ──────────────────────────────────────────────
      const { data: zoneData } = await supabase.rpc('get_my_zone_stats').maybeSingle();
      setZoneStats(zoneData ?? null);

      // ── Demanda de la ciudad + Posición en ranking + Slots de anuncios ──
      if (grp?.city) {
        const nCity = normalizeCity(grp.city);
        const [{ data: demandData }, { data: rankData }, { data: slotsData }, { data: cityStatusData }, { data: launchData }] = await Promise.all([
          supabase.rpc('get_city_demand_score', { p_city: nCity }),
          supabase.rpc('get_group_ranking_position', { p_group_id: grp.id, p_city: nCity }),
          supabase.rpc('check_city_ad_slots', { p_city: nCity }),
          supabase.rpc('get_city_status', { p_city: nCity }),
          supabase.rpc('get_seeding_launch_slots', { p_city: nCity }),
        ]);
        if ((demandData as any)?.ok) setCityDemand(demandData);
        if ((rankData as any)?.ok)   setRankingPos(rankData);
        if (slotsData) setAdSlots(slotsData);
        if ((cityStatusData as any)?.ok) setCityStatus(cityStatusData as any);
        if ((launchData as any)?.ok) setSeedingSlots(launchData as any);
      }

      // ── Solicitudes express abiertas (para banner del dashboard) ────────────
      if (grp.city && grp.genre) {
        const nCity = normalizeCity(grp.city);
        supabase
          .from('event_requests')
          .select('id', { count: 'exact', head: true })
          .or(`city.ilike.${nCity},location_city.ilike.${grp.city}`)
          .eq('genre', grp.genre)
          .eq('status', 'open')
          .gt('expires_at', new Date().toISOString())
          .then(({ count }) => setOpenExpressCount(count ?? 0));
      }

      // ── Miembros aceptados del grupo ─────────────────────────────────────────
      // Paso 1: invitaciones aceptadas + datos del invitado
      const { data: invitationsData } = await supabase
        .from('job_invitations')
        .select(`
          id, status,
          invited_user:profiles!job_invitations_invited_user_id_fkey(id, full_name, avatar_url, phone_verified, id_verified)
        `)
        .eq('group_id', grp.id)
        .eq('status', 'accepted')
        .is('event_id', null);  // solo miembros permanentes, no tocadas

      // Paso 2: perfiles artísticos de los miembros (join manual)
      const memberUserIds = (invitationsData ?? [])
        .map((inv: any) => inv.invited_user?.id)
        .filter(Boolean);

      let memberArtistMap: Record<string, { instrument_or_role: string; availability_status: string }> = {};
      if (memberUserIds.length > 0) {
        const { data: artistProfiles } = await supabase
          .from('job_board_profiles')
          .select('user_id, instrument_or_role, availability_status')
          .in('user_id', memberUserIds);
        if (artistProfiles) {
          artistProfiles.forEach((ap: any) => {
            memberArtistMap[ap.user_id] = {
              instrument_or_role: ap.instrument_or_role,
              availability_status: ap.availability_status,
            };
          });
        }
      }

      const mergedMembers = (invitationsData ?? []).map((inv: any) => ({
        ...inv,
        artist: memberArtistMap[inv.invited_user?.id] ?? null,
      }));
      setMembers(mergedMembers);

    } catch (e: any) {
      setError(e.message ?? 'Error al cargar el panel.');
    } finally {
      setLoading(false);
    }
  };

  const fetchMessage = async () => {
    const wk = Math.ceil(new Date().getDate() / 7);
    const { data } = await supabase
      .from('motivational_messages').select('message_es')
      .eq('week_number', wk).limit(1).maybeSingle();
    setMessage(data?.message_es ?? 'Daricefy cree en tu talento. ¡Sigue creciendo! 🎵');
  };

  const onRefresh = async () => { setRefreshing(true); await fetchData(); setRefreshing(false); };

  // ── Crear grupo (primera vez) ────────────────────────────────────────────────

  const handleCreateGroup = async () => {
    const name  = createForm.name.trim();
    const state = createForm.state.trim();
    if (!name)  { Alert.alert('Error', 'El nombre del grupo es obligatorio.'); return; }
    if (!state) { Alert.alert('Error', 'El estado es obligatorio.'); return; }
    const uid = authProfile?.id;
    if (!uid) return;

    // País se deriva automáticamente del estado (no campo manual)
    const country = stateToCountry(state);

    setCreating(true);
    const { data: newGrp, error: ce } = await supabase
      .from('groups')
      .insert([{
        owner_id:   uid,
        name,
        genre:      createForm.genre.trim() || null,
        state,
        country,
        is_active:  true,
        is_verified: false,
        verification_status: 'none',
      }])
      .select()
      .single();
    setCreating(false);

    if (ce) { Alert.alert('Error', 'No se pudo crear el grupo: ' + ce.message); return; }

    // Sincronizar state y country al perfil del dueño para que aparezca
    // en los filtros de talentos con la ubicación correcta del grupo.
    await supabase.from('profiles')
      .update({ state, country })
      .eq('id', uid);

    // Auto-crear perfil artístico del dueño
    await supabase.from('job_board_profiles').upsert({
      user_id:             uid,
      instrument_or_role:  'Músico',
      experience_years:    0,
      rating:              5.0,
      total_jobs:          0,
      availability_status: 'available',
      is_visible:          false,
    }, { onConflict: 'user_id' });

    setNoGroup(false);
    setGroup(newGrp);
    groupIdRef.current = newGrp.id;
    setLoading(false);
    fetchData();   // recargar para obtener artist profile y stats
  };

  // ── Edit ────────────────────────────────────────────────────────────────────

  const openEdit = () => {
    if (!group) return;
    setEditForm({
      name:                  group.name ?? '',
      description:           group.description ?? '',
      genre:                 group.genre ?? '',
      state:                 (group as any).state ?? '',
      has_sound:             group.has_sound ?? false,
      sound_capacity_max:    String(group.sound_capacity_max ?? ''),
      has_lighting:          group.has_lighting ?? false,
      lighting_level:        group.lighting_level ?? '',
      has_stage:             group.has_stage ?? false,
      stage_sizes_available: group.stage_sizes_available ?? [],
      has_led_screen:        group.has_led_screen ?? false,
      led_sizes_available:   group.led_sizes_available ?? [],
      power_amps:            String(group.power_amps ?? ''),
      needs_parking:         group.needs_parking ?? false,
      setup_minutes:         String(group.setup_minutes ?? ''),
      includes_text:         group.includes_text ?? '',
    });
    setEditVisible(true);
  };

  const saveEdit = async () => {
    if (!group) return;
    const name  = editForm.name.trim();
    // Usar el estado del formulario; si está vacío, conservar el del grupo (no romper grupos sin estado)
    const state = editForm.state.trim() || group.state || '';
    if (!name)  { Alert.alert('Error', 'El nombre no puede estar vacío.'); return; }
    if (!state) { Alert.alert('Error', 'El estado es obligatorio. Ingresa tu estado para continuar.'); return; }

    // Validación anti-bypass
    const descVal = validatePublicText(editForm.description);
    if (!descVal.valid) { Alert.alert('Texto no permitido', descVal.error); return; }
    const inclVal = validatePublicText(editForm.includes_text);
    if (!inclVal.valid) { Alert.alert('Texto no permitido', inclVal.error); return; }

    // País se deriva del estado automáticamente; conservar country existente como fallback
    const country = stateToCountry(state) || group.country || 'México';

    // Convertir numéricos con .trim() para evitar NaN por espacios
    const soundCap  = editForm.sound_capacity_max.trim() ? parseInt(editForm.sound_capacity_max) : null;
    const powerAmps = editForm.power_amps.trim()         ? parseInt(editForm.power_amps)         : null;
    const setupMins = editForm.setup_minutes.trim()      ? parseInt(editForm.setup_minutes)      : null;

    const updatePayload = {
      name,
      description:           editForm.description.trim() || null,
      genre:                 editForm.genre.trim() || null,
      state,
      country,
      has_sound:             editForm.has_sound,
      sound_capacity_max:    soundCap,
      has_lighting:          editForm.has_lighting,
      lighting_level:        editForm.lighting_level || null,
      has_stage:             editForm.has_stage,
      stage_sizes_available: editForm.stage_sizes_available,
      has_led_screen:        editForm.has_led_screen,
      led_sizes_available:   editForm.led_sizes_available,
      power_amps:            powerAmps,
      needs_parking:         editForm.needs_parking,
      setup_minutes:         setupMins,
      includes_text:         editForm.includes_text.trim() || null,
    };

    setEditSaving(true);
    const { error: ue } = await supabase
      .from('groups')
      .update(updatePayload)
      .eq('id', group.id);

    if (!ue) {
      await supabase.rpc('update_my_location', { p_state: state, p_country: country });
    }
    setEditSaving(false);
    if (ue) { Alert.alert('Error', 'No se pudieron guardar los cambios.'); return; }
    setGroup(p => p ? { ...p, ...updatePayload, state, country } : p);
    setEditVisible(false);
  };

  // ── Photo ────────────────────────────────────────────────────────────────────

  const handlePhoto = async () => {
    const gid = groupIdRef.current;
    if (!gid) return;
    try {
      setPhotoLoading(true);
      const url = await pickAndUploadGroupImage(gid);
      if (url) setGroup(p => p ? { ...p, profile_image: url } : p);
    } catch (e: any) {
      Alert.alert('Error', e.message ?? 'No se pudo subir la foto.');
    } finally {
      setPhotoLoading(false);
    }
  };

  const handleVideo = async () => {
    const gid = groupIdRef.current;
    if (!gid) return;
    // 🎵 Declaración de derechos ANTES de subir (protege a la plataforma:
    // la responsabilidad del contenido es de quien lo sube — Términos §6)
    const accepted = await new Promise<boolean>(resolve => {
      Alert.alert(
        '🎵 Antes de subir tu video',
        'Al subir declaras BAJO TU RESPONSABILIDAD que:\n\n' +
        '• Es TU GRUPO tocando (interpretación propia, en vivo).\n' +
        '• Si es un cover, reconoces al autor original de la canción.\n' +
        '• NO es música grabada de otros artistas (pistas o canciones ajenas están prohibidas).\n' +
        '• Cualquier reclamo de derechos de autor es responsabilidad tuya; Daricefy puede retirar el contenido si hay un reclamo.\n\n' +
        'Detalles en Perfil → Términos y condiciones.',
        [
          { text: 'Cancelar', style: 'cancel', onPress: () => resolve(false) },
          { text: 'Acepto, subir video', onPress: () => resolve(true) },
        ],
      );
    });
    if (!accepted) return;
    try {
      setVideoLoading(true);
      const url = await pickAndUploadGroupVideo(gid);
      if (url) {
        setGroup(p => p ? { ...p, promo_video: url, video_status: 'pending' } : p);
        setVideoSuccessMsg(true);
        setTimeout(() => setVideoSuccessMsg(false), 4000);
      }
    } catch (e: any) {
      Alert.alert('Error al subir video', e.message ?? 'No se pudo subir el video.');
    } finally {
      setVideoLoading(false);
    }
  };

  const firstName = authProfile?.full_name?.split(' ')[0] ?? 'Músico';

  // 🏆 Plus EFECTIVO: activo Y no vencido (las banderas viejas de pruebas
  // quedaban en true — bug de la palomita fantasma, 2026-07-16)
  const plusOn = !!(group as any)?.is_plus_active &&
    (!(group as any)?.plus_expires_at || new Date((group as any).plus_expires_at) > new Date());

  // ── Remove member ────────────────────────────────────────────────────────────
  const handleRemoveMember = () => {
    const invId = selectedMember?.invitationId;
    if (!invId) return;
    Alert.alert(
      'Quitar integrante',
      `¿Quitar a ${selectedMember?.name ?? 'este talento'} del grupo?`,
      [
        { text: 'Cancelar', style: 'cancel' },
        {
          text: 'Sí, quitar',
          style: 'destructive',
          onPress: async () => {
            const { data, error } = await supabase
              .rpc('delete_group_invitation', { p_invitation_id: invId });
            if (error || (data as any)?.error) {
              Alert.alert('Error', error?.message ?? (data as any)?.error ?? 'No se pudo quitar');
              return;
            }
            setMembers(prev => prev.filter(m => m.id !== invId));
            setSelectedMember(null);
          },
        },
      ]
    );
  };

  // ── Loading / Error ────────────────────────────────────────────────────────

  if (loading) {
    return (
      <View style={s.container}>
        <Particles />
        <View style={s.center}>
          <ActivityIndicator size="large" color={COLORS.green} />
          <Text style={s.loadingText}>Cargando panel...</Text>
        </View>
      </View>
    );
  }

  if (noGroup) {
    return (
      <View style={s.container}>
        <Particles />
        <SafeAreaView style={{ flex: 1 }}>
          <ScrollView contentContainerStyle={[s.center, { paddingHorizontal: 28, paddingVertical: 60 }]}
            keyboardShouldPersistTaps="handled">
            <Text style={{ fontSize: 52, marginBottom: 16 }}>🎸</Text>
            <Text style={[s.errorTitle, { textAlign: 'center', marginBottom: 8 }]}>Crea tu grupo</Text>
            <Text style={[s.errorMsg, { textAlign: 'center', marginBottom: 28 }]}>
              Configura tu perfil de grupo para empezar a recibir reservas.
            </Text>

            <TextInput
              style={[s.input, { width: '100%' }]}
              placeholder="Nombre del grupo *"
              placeholderTextColor={COLORS.muted}
              value={createForm.name}
              onChangeText={v => setCreateForm(f => ({ ...f, name: v }))}
              autoCapitalize="words"
              maxLength={80}
            />
            <TextInput
              style={[s.input, { width: '100%' }]}
              placeholder="Género musical (Norteño, Pop, Rock...)"
              placeholderTextColor={COLORS.muted}
              value={createForm.genre}
              onChangeText={v => setCreateForm(f => ({ ...f, genre: v }))}
              autoCapitalize="words"
              maxLength={60}
            />
            <TextInput
              style={[s.input, { width: '100%' }]}
              placeholder="Estado *"
              placeholderTextColor={COLORS.muted}
              value={createForm.state}
              onChangeText={v => setCreateForm(f => ({ ...f, state: v }))}
              autoCapitalize="words"
              maxLength={60}
            />
            <Pressable
              style={[s.retryBtn, { width: '100%', alignItems: 'center', opacity: creating ? 0.6 : 1 }]}
              onPress={handleCreateGroup}
              disabled={creating}
            >
              <Text style={s.retryText}>{creating ? 'Creando...' : 'Crear grupo'}</Text>
            </Pressable>
          </ScrollView>
        </SafeAreaView>
      </View>
    );
  }

  if (error) {
    return (
      <View style={s.container}>
        <Particles />
        <View style={s.center}>
          <Text style={{ fontSize: 44 }}>⚠️</Text>
          <Text style={s.errorTitle}>Algo salió mal</Text>
          <Text style={s.errorMsg}>{error}</Text>
          <Pressable style={s.retryBtn} onPress={() => { setLoading(true); fetchData(); }}>
            <Text style={s.retryText}>Reintentar</Text>
          </Pressable>
        </View>
      </View>
    );
  }

  // ── Render ─────────────────────────────────────────────────────────────────

  return (
    <View style={s.container}>
      <Particles />
      <SafeAreaView style={{ flex: 1 }}>
        <ScrollView
          showsVerticalScrollIndicator={false}
          refreshControl={<RefreshControl refreshing={refreshing} onRefresh={onRefresh} tintColor={COLORS.green} />}
        >

          {/* ══ BLOQUE 1: HÉROE ══════════════════════════════════════ */}
          <View style={s.heroContainer}>
            {group?.profile_image ? (
              <Image source={{ uri: group.profile_image }} style={s.heroImage} resizeMode="cover" />
            ) : (
              <View style={[s.heroImage, s.heroImagePlaceholder]}>
                <Text style={{ fontSize: 72 }}>🎸</Text>
              </View>
            )}

            {/* Gradient overlay con info del grupo */}
            <LinearGradient
              colors={['transparent', 'rgba(4,4,4,0.80)', COLORS.bg]}
              style={s.heroOverlay}
            >
              <View style={s.heroInfo}>
                <View style={{ flexDirection: 'row', alignItems: 'center', gap: 8, flexWrap: 'wrap' }}>
                  <Text style={s.heroName} numberOfLines={1}>{group?.name ?? 'Tu grupo'}</Text>
                  {group?.is_verified && (
                    <VerifiedBadge size={20} tier={plusOn ? "plus" : "free"} />
                  )}
                </View>
                <View style={{ flexDirection: 'row', alignItems: 'center', gap: 8, marginTop: 6, flexWrap: 'wrap' }}>
                  {group?.rating != null && (
                    <View style={s.heroRatingPill}>
                      <Star size={11} color={COLORS.gold} fill={COLORS.gold} />
                      <Text style={s.heroRating}>{group.rating.toFixed(1)}</Text>
                    </View>
                  )}
                  {group?.genre ? (
                    <View style={s.heroGenrePill}>
                      <Text style={s.heroGenreText}>{group.genre}</Text>
                    </View>
                  ) : null}
                  {group?.nivel ? <LevelBadge nivel={group.nivel} /> : null}
                </View>
              </View>
            </LinearGradient>

            {/* Barra de botones en la parte superior */}
            <View style={s.heroTopBar}>
              <View style={{ flexDirection: 'row', gap: 8 }}>
                <Pressable style={s.heroIconBtn} onPress={() => navigation.navigate('GroupStats')}>
                  <TrendingUp size={17} color={COLORS.text} />
                </Pressable>
                <Pressable style={s.heroIconBtn} onPress={() => navigation.navigate('Notifications')}>
                  <Bell size={17} color={COLORS.text} />
                  {unreadNotifications > 0 && (
                    <View style={s.notifBadge}>
                      <Text style={s.notifBadgeText}>{unreadNotifications > 9 ? '9+' : unreadNotifications}</Text>
                    </View>
                  )}
                </Pressable>
              </View>
              <Pressable style={s.heroIconBtn} onPress={openEdit}>
                <Pencil size={15} color={COLORS.text} />
              </Pressable>
            </View>
          </View>

          {/* ══ BLOQUE 2: CENTRO DE CONTROL ═══════════════════════ */}
          <View style={s.controlBlock}>
            {/* Fila de dinero */}
            <View style={s.moneyCard}>
              <View style={s.moneyItem}>
                <Text style={s.moneyLabel}>Saldo disponible</Text>
                <Text style={s.moneyValue}>${fmt(walletBalance)}</Text>
              </View>
              <View style={s.moneyDivider} />
              <View style={s.moneyItem}>
                <Text style={s.moneyLabel}>Este mes</Text>
                <Text style={[s.moneyValue, { color: COLORS.green }]}>${fmt(stats.monthNetEarnings)}</Text>
              </View>
              <View style={s.moneyDivider} />
              <View style={s.moneyItem}>
                <Text style={s.moneyLabel}>Total ganado</Text>
                <Text style={s.moneyValue}>${fmt(stats.netEarnings)}</Text>
              </View>
            </View>

            {/* 📈 Mi desempeño — vive AQUÍ (movido desde Billetera, 2026-07-18) */}
            <Pressable style={s.perfBtn} onPress={() => navigation.navigate('GroupPerformance')}>
              <Text style={s.perfBtnTx}>📈 Mi desempeño</Text>
              <Text style={s.perfBtnSub}>Calificación, eventos, ganancias, tendencia y comentarios →</Text>
            </Pressable>

            {/* Fila de disponibilidad + calendario */}
            <View style={s.controlRow}>
              <Pressable
                style={[s.controlToggle, groupAvailability === 'available' && s.controlToggleActive]}
                onPress={toggleAvailability}
                disabled={availabilityLoading}
              >
                <View style={[s.controlToggleDot, groupAvailability === 'available' && { backgroundColor: COLORS.green }]} />
                <View style={{ flex: 1 }}>
                  <Text style={[s.controlToggleTitle, groupAvailability === 'available' && { color: COLORS.green }]}>
                    {availabilityLoading ? 'Actualizando...' : groupAvailability === 'available' ? 'Express ON' : 'Express OFF'}
                  </Text>
                  <Text style={s.controlToggleSub}>
                    {groupAvailability === 'available' ? 'Recibes solicitudes' : 'Toca para activar'}
                  </Text>
                </View>
              </Pressable>

              <Pressable style={s.controlCalBtn} onPress={() => navigation.navigate('GroupCalendar')}>
                <CalendarDays size={17} color={COLORS.text} />
                <Text style={s.controlCalText}>Mi Disponibilidad</Text>
              </Pressable>
            </View>

            {/* Nudge de alta demanda — solo cuando Express está OFF */}
            {(() => {
              const demandLevel = cityDemand?.demand_level as string | undefined;
              const isHigh = demandLevel === 'high' || demandLevel === 'very_high';
              if (!isHigh || groupAvailability === 'available') return null;
              return (
                <Pressable style={s.demandNudge} onPress={toggleAvailability}>
                  <Text style={s.demandNudgeTx}>
                    ⚡ Alta demanda en {group?.city} · Activa Express para recibir solicitudes
                  </Text>
                </Pressable>
              );
            })()}

          </View>

          {/* ── Banner animado: solicitudes express ──────────────────── */}
          {expressVisible && (
            <Animated.View style={{ transform: [{ translateY: expressBannerSlide }, { scale: expressPulse }] }}>
              <Pressable style={s.expressBanner} onPress={expressReviveAll}>
                <Text style={s.expressBannerEmoji}>⚡</Text>
                <View style={{ flex: 1 }}>
                  <Text style={s.expressBannerTitle}>
                    {expressDispatches.length > 0
                      ? `${expressDispatches.length} solicitud${expressDispatches.length !== 1 ? 'es' : ''} express para ti`
                      : 'Tienes solicitudes express esperando'}
                  </Text>
                  <Text style={s.expressBannerSub}>Toca para verlas · responde rápido</Text>
                </View>
                <ChevronRight size={16} color="#FF6B35" />
              </Pressable>
            </Animated.View>
          )}

          {/* ── Banner animado: cotizaciones programadas (experiencia exprés) ── */}
          {(() => {
            const pendCount = pendingQuotes.filter((q: any) => q.status === 'pending').length;
            if (pendCount === 0) return null;
            return (
              <Animated.View style={{ transform: [{ scale: expressPulse }] }}>
                <Pressable
                  style={s.scheduledBanner}
                  onPress={() => openScheduledQuotes()}
                >
                  <Text style={s.expressBannerEmoji}>📅</Text>
                  <View style={{ flex: 1 }}>
                    <Text style={s.scheduledBannerTitle}>
                      {pendCount === 1
                        ? '1 cotización programada para ti'
                        : `${pendCount} cotizaciones programadas para ti`}
                    </Text>
                    <Text style={s.expressBannerSub}>Toca para verlas · responde rápido</Text>
                  </View>
                  <ChevronRight size={16} color={COLORS.green} />
                </Pressable>
              </Animated.View>
            );
          })()}

          {/* ══ BLOQUE 3: RENDIMIENTO Y MERCADO ══════════════════════ */}
          <View style={s.sectionBlock}>
            <Text style={s.sectionTitle}>Rendimiento</Text>

            {/* Ranking card */}
            {rankingPos?.ok && (
              <Animated.View style={[s.rankCard, { transform: [{ translateX: rankShakeAnim }] }]}>
                <View style={s.rankLeft}>
                  <Text style={s.rankNumber}>#{rankingPos.position ?? '—'}</Text>
                  <View style={{ flex: 1 }}>
                    <Text style={s.rankLabel}>Posición en {group?.city}</Text>
                    <Text style={s.rankSub} numberOfLines={2}>
                      {rankingPos.total_groups ?? 0} grupos ·{' '}
                      {rankingPos.gap_to_next != null && rankingPos.gap_to_next > 0
                        ? `Faltan $${fmt(rankingPos.gap_to_next)} para subir`
                        : rankingPos.position === 1
                          ? '¡Eres #1! 🏆'
                          : 'Actualiza tu bid para subir'}
                    </Text>
                  </View>
                </View>
                <Pressable style={s.rankBidBtn} onPress={() => navigation.navigate('Bidding', { group })}>
                  <Text style={s.rankBidText}>Bid</Text>
                </Pressable>
              </Animated.View>
            )}


            {/* Stats row */}
            <View style={s.statsRow}>
              <View style={s.statPill}>
                <Text style={s.statPillNum}>{stats.completedCount}</Text>
                <Text style={s.statPillLabel}>Completados</Text>
              </View>
              <View style={s.statPill}>
                <Text style={s.statPillNum}>{stats.pendingCount}</Text>
                <Text style={s.statPillLabel}>Pendientes</Text>
              </View>
            </View>
          </View>

          {/* ══ BLOQUE 3B: VERIFICACIÓN PLUS ══════════════════════════ */}
          <PlusDashboardCard navigation={navigation} groupId={groupIdRef.current} />

          {/* ══ BLOQUE 4: GESTIÓN OPERATIVA ══════════════════════════ */}
          <View style={s.sectionBlock}>
            <Text style={s.sectionTitle}>Operaciones</Text>

            {/* Team card: lineup + clientes frecuentes */}
            <View style={s.teamCard}>
              <View style={s.teamCardHead}>
                <Text style={[s.teamCardTitle, { marginBottom: 0, flex: 1 }]}>🎸 Formación</Text>
                {/* 💬 Chat grupal: dueño + integrantes fijos (fotos/videos/números OK) */}
                {members.length > 0 && group?.id && (
                  <Pressable
                    style={s.teamChatBtn}
                    onPress={() => navigation.navigate('GroupChat', { groupId: group.id, mode: 'general' })}
                  >
                    <Text style={s.teamChatBtnTx}>💬 Chat del grupo</Text>
                  </Pressable>
                )}
              </View>
              <ScrollView horizontal showsHorizontalScrollIndicator={false} style={{ marginBottom: 4 }}>
                {/* Dueño */}
                <View style={s.memberChip}>
                  {authProfile?.avatar_url
                    ? <Image source={{ uri: authProfile.avatar_url }} style={s.memberChipAvatar} />
                    : <View style={[s.memberChipAvatar, s.memberChipAvatarEmpty]}>
                        <Text style={s.memberChipInitial}>{firstName.charAt(0)}</Text>
                      </View>
                  }
                  <Text style={s.memberChipName} numberOfLines={1}>{firstName.split(' ')[0]}</Text>
                  <Text style={s.memberChipRole}>Dueño</Text>
                </View>

                {members.map(m => {
                  const name = m.invited_user?.full_name ?? 'Talento';
                  return (
                    <Pressable
                      key={m.id}
                      style={s.memberChip}
                      onPress={() => setSelectedMember({
                        id: m.id,
                        invitationId: m.id,
                        name,
                        avatarUrl: m.invited_user?.avatar_url ?? null,
                        instrument: m.artist?.instrument_or_role ?? null,
                        isVerified: m.invited_user?.id_verified ?? false,
                      })}
                    >
                      <View>
                        {m.invited_user?.avatar_url
                          ? <Image source={{ uri: m.invited_user.avatar_url }} style={s.memberChipAvatar} />
                          : <View style={[s.memberChipAvatar, s.memberChipAvatarEmpty]}>
                              <Text style={s.memberChipInitial}>{name.charAt(0).toUpperCase()}</Text>
                            </View>
                        }
                        {/* 💬 arribita de la foto → chat 1:1 con este talento */}
                        {group?.id && m.invited_user?.id && (
                          <Pressable
                            style={s.memberChatBadge}
                            hitSlop={6}
                            onPress={() => navigation.navigate('GroupChat', {
                              groupId: group.id, mode: 'dm', peerId: m.invited_user.id,
                            })}
                          >
                            <Text style={{ fontSize: 10 }}>💬</Text>
                          </Pressable>
                        )}
                      </View>
                      <Text style={s.memberChipName} numberOfLines={1}>{name.split(' ')[0]}</Text>
                      {m.artist?.instrument_or_role && (
                        <Text style={s.memberChipRole} numberOfLines={1}>{m.artist.instrument_or_role}</Text>
                      )}
                    </Pressable>
                  );
                })}

                {/* Botón añadir */}
                <Pressable style={[s.memberChip]} onPress={() => navigation.navigate('GroupTalentSearch')}>
                  <View style={[s.memberChipAvatar, s.memberChipAvatarAdd]}>
                    <Text style={{ fontSize: 22, color: COLORS.green }}>+</Text>
                  </View>
                  <Text style={[s.memberChipName, { color: COLORS.green }]}>Añadir</Text>
                </Pressable>
              </ScrollView>

              {/* Invitaciones enviadas */}
              <Pressable
                style={s.sentInvBtn}
                onPress={() => navigation.navigate('GroupSentInvitations')}
              >
                <Text style={s.sentInvBtnText}>📨 Ver invitaciones enviadas</Text>
                {pendingInvitationsCount > 0 && (
                  <View style={s.invBadge}>
                    <Text style={s.invBadgeText}>{pendingInvitationsCount}</Text>
                  </View>
                )}
              </Pressable>

              {loyalClients.length > 0 && (
                <>
                  <View style={s.teamDivider} />
                  <Text style={s.teamCardTitle}>❤️ Clientes frecuentes</Text>
                  <ScrollView horizontal showsHorizontalScrollIndicator={false}>
                    {loyalClients.map((c: any, i: number) => (
                      <View key={i} style={s.loyalChip}>
                        {c.avatar_url
                          ? <Image source={{ uri: c.avatar_url }} style={s.loyalAvatar} />
                          : <View style={[s.loyalAvatar, s.loyalAvatarEmpty]}>
                              <Text style={s.loyalInitial}>{c.full_name?.charAt(0)?.toUpperCase() ?? '?'}</Text>
                            </View>
                        }
                        <Text style={s.loyalName} numberOfLines={1}>{c.full_name?.split(' ')[0] ?? '?'}</Text>
                        <Text style={s.loyalCount}>{c.event_count ?? 1}x</Text>
                      </View>
                    ))}
                  </ScrollView>
                </>
              )}
            </View>
          </View>

          <View style={{ height: 40 }} />
        </ScrollView>
      </SafeAreaView>

      {/* ── EDIT MODAL ── */}
      <Modal visible={editVisible} transparent animationType="slide" onRequestClose={() => setEditVisible(false)}>
        <KeyboardAvoidingView behavior={Platform.OS === 'ios' ? 'padding' : 'height'} style={{ flex: 1 }}>
          <View style={s.overlay}>
            <View style={s.sheet}>
              <View style={s.sheetHeader}>
                <Text style={s.sheetTitle}>Información del grupo</Text>
                <Pressable onPress={() => setEditVisible(false)} style={s.sheetClose}>
                  <X size={18} color={COLORS.muted2} />
                </Pressable>
              </View>

              <ScrollView keyboardShouldPersistTaps="handled" showsVerticalScrollIndicator={false} contentContainerStyle={{ paddingBottom: 100 }}>
              <Text style={s.label}>Nombre del grupo *</Text>
              <TextInput style={s.input} value={editForm.name}
                onChangeText={v => setEditForm(f => ({ ...f, name: v }))}
                placeholder="Nombre de tu banda o grupo"
                placeholderTextColor={COLORS.muted} autoCapitalize="words" maxLength={80} />

              <Text style={s.label}>Estado *</Text>
              <TextInput style={s.input} value={editForm.state}
                onChangeText={v => setEditForm(f => ({ ...f, state: v }))}
                placeholder="Ej: Jalisco, Ciudad de México..."
                placeholderTextColor={COLORS.muted} autoCapitalize="words" maxLength={60} />


              <Text style={s.label}>Género musical</Text>
              <TextInput style={s.input} value={editForm.genre}
                onChangeText={v => setEditForm(f => ({ ...f, genre: v }))}
                placeholder="Norteño, Pop, Rock, Banda..."
                placeholderTextColor={COLORS.muted} autoCapitalize="words" maxLength={60} />

              <Text style={s.label}>Descripción</Text>
              <TextInput
                style={[s.input, s.inputMulti, !!descriptionError && s.inputError]}
                value={editForm.description}
                onChangeText={v => {
                  setEditForm(f => ({ ...f, description: v }));
                  const r = validatePublicText(v);
                  setDescriptionError(r.valid ? null : r.error!);
                }}
                placeholder="Describe a tu grupo, experiencia, estilo..."
                placeholderTextColor={COLORS.muted}
                multiline numberOfLines={4} textAlignVertical="top" maxLength={500}
              />
              {descriptionError && (
                <Text style={s.errorText}>⚠️ {descriptionError}</Text>
              )}
              <Text style={s.charCount}>{editForm.description.length}/500</Text>

              {/* ── Video promocional ─────────────────────────────────────────── */}
              <Text style={s.label}>Video promocional</Text>

              {group?.promo_video ? (
                <View style={s.videoPreviewBox}>
                  <VideoPlayer
                    uri={group.promo_video}
                    style={s.videoPreview}
                    contentFit="contain"
                    nativeControls
                  />
                  <Pressable
                    style={[s.videoBtnOutline, videoLoading && { opacity: 0.5 }]}
                    onPress={handleVideo}
                    disabled={videoLoading}
                  >
                    {videoLoading
                      ? <ActivityIndicator size="small" color={COLORS.green} />
                      : <Film size={15} color={COLORS.green} />}
                    <Text style={s.videoBtnOutlineText}>
                      {videoLoading ? 'Subiendo...' : 'Cambiar video'}
                    </Text>
                  </Pressable>
                </View>
              ) : (
                <Pressable
                  style={[s.videoBtnSolid, videoLoading && { opacity: 0.5 }]}
                  onPress={handleVideo}
                  disabled={videoLoading}
                >
                  {videoLoading
                    ? <ActivityIndicator size="small" color={COLORS.bg} />
                    : <Film size={17} color={COLORS.bg} />}
                  <Text style={s.videoBtnSolidText}>
                    {videoLoading ? 'Subiendo video...' : 'Subir video promocional'}
                  </Text>
                </Pressable>
              )}
              {videoSuccessMsg && (
                <View style={s.videoSuccessBanner}>
                  <Text style={s.videoSuccessText}>✅ ¡Listo! Video guardado y enviado a revisión. No necesitas presionar "Guardar perfil".</Text>
                </View>
              )}
              {!videoSuccessMsg && group?.video_status === 'pending' && (
                <View style={[s.mediaStatusBadge, { position: 'relative', marginBottom: 6, marginTop: -4 }]}>
                  <Text style={s.mediaStatusText}>🎬 Video en revisión por el equipo</Text>
                </View>
              )}
              {group?.video_status === 'rejected' && (
                <View style={[s.mediaStatusBadge, { position: 'relative', marginBottom: 6, marginTop: -4, backgroundColor: 'rgba(255,82,82,0.85)' }]}>
                  <Text style={s.mediaStatusText}>❌ Video rechazado · {group.video_reject_reason ?? 'Sube un nuevo video'}</Text>
                </View>
              )}
              <Text style={s.videoHint}>MP4, MOV o WebM · máx. 50 MB{'\n'}⚠️ Sin redes sociales, teléfonos ni logos externos</Text>

              {/* ── 🎬 MIS VIDEOS DEL PERFIL (carrusel del cliente) ──────────
                    1 video gratis; con Plus vigente 2 más (3 en total).
                    Cada uno pasa por revisión del admin (sql/492-494). */}
              <Text style={s.equipSectionTitle}>
                🎬 Mis videos del perfil · {myVideos.filter(v => v.status !== 'rejected').length}/{plusOn ? 3 : 1}
              </Text>
              {plusOn && (group as any)?.plus_expires_at && (
                <Text style={s.plusActiveTx}>
                  🏆 Plus activo · <Text style={{ color: COLORS.gold }}>2 videos más</Text> desbloqueados (3 en total) hasta el{' '}
                  {new Date((group as any).plus_expires_at).toLocaleDateString('es-MX', { day: 'numeric', month: 'long', year: 'numeric' })}
                </Text>
              )}
              {/* Vista previa reducida — como el carrusel que ve el cliente */}
              {myVideos.filter(v => v.url && v.status !== 'rejected').length > 0 && (
                <ScrollView horizontal showsHorizontalScrollIndicator={false} style={{ marginBottom: 10 }}>
                  {myVideos.filter(v => v.url && v.status !== 'rejected').map(v => (
                    <View key={`prev-${v.id}`} style={s.myVideoPreview}>
                      <VideoPlayer uri={v.url} style={{ width: '100%', height: '100%' }} contentFit="cover" nativeControls />
                    </View>
                  ))}
                </ScrollView>
              )}
              {myVideos.map((v, i) => (
                <View key={v.id} style={s.myVideoRow}>
                  <Text style={s.myVideoName}>Video {i + 1}</Text>
                  <Text style={[
                    s.myVideoStatus,
                    v.status === 'approved' && { color: COLORS.green },
                    v.status === 'pending'  && { color: '#FFC107' },
                    v.status === 'rejected' && { color: '#EF5350' },
                  ]}>
                    {v.status === 'approved' ? '✅ Publicado' : v.status === 'pending' ? '⏳ En revisión' : '❌ Rechazado'}
                  </Text>
                  <Pressable
                    hitSlop={8}
                    onPress={() => Alert.alert('Eliminar video', `¿Quitar el Video ${i + 1} de tu perfil?`, [
                      { text: 'Cancelar', style: 'cancel' },
                      {
                        text: 'Eliminar', style: 'destructive',
                        onPress: async () => {
                          await supabase.from('group_videos').delete().eq('id', v.id);
                          setMyVideos(prev => prev.filter(x => x.id !== v.id));
                        },
                      },
                    ])}
                  >
                    <Text style={{ fontSize: 14 }}>🗑️</Text>
                  </Pressable>
                </View>
              ))}
              <Pressable
                style={[s.videoBtnOutline, multiVideoLoading && { opacity: 0.5 }]}
                disabled={multiVideoLoading}
                onPress={async () => {
                  const gid = groupIdRef.current;
                  if (!gid) return;
                  // 🔒 Límite en la app (el trigger SQL es el candado final):
                  // 1 video gratis · 3 con Plus VIGENTE (no basta la bandera)
                  const activos = myVideos.filter(v => v.status !== 'rejected').length;
                  if (activos >= (plusOn ? 3 : 1)) {
                    if (plusOn) {
                      Alert.alert('🎬 Límite alcanzado', 'Ya tienes 3 videos (el máximo con Plus). Elimina uno para subir otro.');
                    } else {
                      Alert.alert(
                        '🏆 Desbloquea 2 videos más',
                        'Tu plan incluye 1 video en el perfil. Con la insignia Plus desbloqueas 2 más (3 en total) y tu badge verde en el explorador.',
                        [
                          { text: 'Ahora no', style: 'cancel' },
                          { text: 'Ver Plus', onPress: () => navigation.navigate('Plus') },
                        ],
                      );
                    }
                    return;
                  }
                  // Declaración de derechos (Términos §6) — igual que el video legacy
                  const accepted = await new Promise<boolean>(resolve => {
                    Alert.alert(
                      '🎵 Antes de subir tu video',
                      'Al subir declaras BAJO TU RESPONSABILIDAD que es TU GRUPO tocando (interpretación propia); si es cover reconoces al autor; y NO es música grabada de otros artistas.',
                      [
                        { text: 'Cancelar', style: 'cancel', onPress: () => resolve(false) },
                        { text: 'Acepto, subir', onPress: () => resolve(true) },
                      ],
                    );
                  });
                  if (!accepted) return;
                  try {
                    setMultiVideoLoading(true);
                    const ok = await pickAndUploadGroupVideoMulti(gid);
                    if (ok) {
                      const { data: vids } = await supabase
                        .from('group_videos').select('id, url, status, created_at')
                        .eq('group_id', gid).order('created_at', { ascending: true });
                      setMyVideos(vids ?? []);
                      Alert.alert('✅ Video subido', 'Quedó en revisión — se publica en tu perfil al aprobarse.');
                    }
                  } catch (e: any) {
                    const msg = e?.message ?? 'No se pudo subir el video.';
                    // El límite lo dicta el servidor — incluye el upsell de Plus
                    if (msg.includes("Plus") && !plusOn) {
                      Alert.alert('🏆 Desbloquea más videos', msg, [
                        { text: 'Ahora no', style: 'cancel' },
                        { text: 'Ver Plus', onPress: () => navigation.navigate('Plus') },
                      ]);
                    } else {
                      Alert.alert('Error', msg);
                    }
                  } finally {
                    setMultiVideoLoading(false);
                  }
                }}
              >
                {multiVideoLoading
                  ? <ActivityIndicator size="small" color={COLORS.green} />
                  : <Film size={15} color={COLORS.green} />}
                <Text style={s.videoBtnOutlineText}>
                  {multiVideoLoading ? 'Subiendo…' : '➕ Agregar video al carrusel'}
                </Text>
              </Pressable>
              {!plusOn && (
                <Pressable style={s.plusUpsell} onPress={() => navigation.navigate('Plus')}>
                  <Text style={s.plusUpsellTx}>
                    🏆 Con la insignia Plus desbloqueas <Text style={{ color: COLORS.gold }}>2 videos más</Text> en tu perfil (hasta 3) →
                  </Text>
                </Pressable>
              )}

              {/* ── Mi Equipo ──────────────────────────────────────────────── */}
              <Text style={s.equipSectionTitle}>Mi Equipo</Text>

              {/* Sonido */}
              <View style={s.equipRow}>
                <Text style={s.equipLabel}>🔊 Sonido propio</Text>
                <Pressable
                  style={[s.equipToggle, editForm.has_sound && s.equipToggleOn]}
                  onPress={() => setEditForm(f => ({ ...f, has_sound: !f.has_sound }))}
                >
                  <Text style={[s.equipToggleText, editForm.has_sound && s.equipToggleTextOn]}>
                    {editForm.has_sound ? 'Sí' : 'No'}
                  </Text>
                </Pressable>
              </View>
              {editForm.has_sound && (
                <TextInput
                  style={s.input}
                  placeholder="Capacidad máx. personas (ej: 200)"
                  placeholderTextColor={COLORS.muted}
                  keyboardType="numeric"
                  value={editForm.sound_capacity_max}
                  onChangeText={v => setEditForm(f => ({ ...f, sound_capacity_max: v.replace(/[^0-9]/g, '') }))}
                />
              )}

              {/* Iluminación */}
              <View style={s.equipRow}>
                <Text style={s.equipLabel}>💡 Iluminación propia</Text>
                <Pressable
                  style={[s.equipToggle, editForm.has_lighting && s.equipToggleOn]}
                  onPress={() => setEditForm(f => ({ ...f, has_lighting: !f.has_lighting, lighting_level: f.has_lighting ? '' : f.lighting_level }))}
                >
                  <Text style={[s.equipToggleText, editForm.has_lighting && s.equipToggleTextOn]}>
                    {editForm.has_lighting ? 'Sí' : 'No'}
                  </Text>
                </Pressable>
              </View>
              {editForm.has_lighting && (
                <View style={s.equipChipRow}>
                  {LIGHTING_LEVEL_OPTIONS.map(opt => (
                    <Pressable
                      key={opt.key}
                      style={[s.equipChip, editForm.lighting_level === opt.key && s.equipChipActive]}
                      onPress={() => setEditForm(f => ({ ...f, lighting_level: opt.key }))}
                    >
                      <Text style={[s.equipChipText, editForm.lighting_level === opt.key && s.equipChipTextActive]}>
                        {opt.label}
                      </Text>
                    </Pressable>
                  ))}
                </View>
              )}

              {/* Tarima */}
              <View style={s.equipRow}>
                <Text style={s.equipLabel}>🎭 Tarima / Escenario</Text>
                <Pressable
                  style={[s.equipToggle, editForm.has_stage && s.equipToggleOn]}
                  onPress={() => setEditForm(f => ({ ...f, has_stage: !f.has_stage, stage_sizes_available: f.has_stage ? [] : f.stage_sizes_available }))}
                >
                  <Text style={[s.equipToggleText, editForm.has_stage && s.equipToggleTextOn]}>
                    {editForm.has_stage ? 'Sí' : 'No'}
                  </Text>
                </Pressable>
              </View>
              {editForm.has_stage && (
                <View style={s.equipChipRow}>
                  {STAGE_SIZE_OPTIONS.map(opt => (
                    <Pressable
                      key={opt.key}
                      style={[s.equipChip, editForm.stage_sizes_available.includes(opt.key) && s.equipChipActive]}
                      onPress={() => setEditForm(f => ({ ...f, stage_sizes_available: toggleItem(f.stage_sizes_available, opt.key) }))}
                    >
                      <Text style={[s.equipChipText, editForm.stage_sizes_available.includes(opt.key) && s.equipChipTextActive]}>
                        {opt.label}
                      </Text>
                    </Pressable>
                  ))}
                </View>
              )}

              {/* Pantalla LED */}
              <View style={s.equipRow}>
                <Text style={s.equipLabel}>📺 Pantalla LED</Text>
                <Pressable
                  style={[s.equipToggle, editForm.has_led_screen && s.equipToggleOn]}
                  onPress={() => setEditForm(f => ({ ...f, has_led_screen: !f.has_led_screen, led_sizes_available: f.has_led_screen ? [] : f.led_sizes_available }))}
                >
                  <Text style={[s.equipToggleText, editForm.has_led_screen && s.equipToggleTextOn]}>
                    {editForm.has_led_screen ? 'Sí' : 'No'}
                  </Text>
                </Pressable>
              </View>
              {editForm.has_led_screen && (
                <View style={s.equipChipRow}>
                  {LED_SIZE_OPTIONS.map(opt => (
                    <Pressable
                      key={opt.key}
                      style={[s.equipChip, editForm.led_sizes_available.includes(opt.key) && s.equipChipActive]}
                      onPress={() => setEditForm(f => ({ ...f, led_sizes_available: toggleItem(f.led_sizes_available, opt.key) }))}
                    >
                      <Text style={[s.equipChipText, editForm.led_sizes_available.includes(opt.key) && s.equipChipTextActive]}>
                        {opt.label}
                      </Text>
                    </Pressable>
                  ))}
                </View>
              )}

              {/* Corriente */}
              <Text style={s.label}>⚡ Corriente requerida (amperes)</Text>
              <TextInput
                style={s.input}
                placeholder="Ej: 30  (vacío si no aplica)"
                placeholderTextColor={COLORS.muted}
                keyboardType="numeric"
                value={editForm.power_amps}
                onChangeText={v => setEditForm(f => ({ ...f, power_amps: v.replace(/[^0-9]/g, '') }))}
              />

              {/* Parking */}
              <View style={s.equipRow}>
                <Text style={s.equipLabel}>🅿️ Requiere estacionamiento</Text>
                <Pressable
                  style={[s.equipToggle, editForm.needs_parking && s.equipToggleOn]}
                  onPress={() => setEditForm(f => ({ ...f, needs_parking: !f.needs_parking }))}
                >
                  <Text style={[s.equipToggleText, editForm.needs_parking && s.equipToggleTextOn]}>
                    {editForm.needs_parking ? 'Sí' : 'No'}
                  </Text>
                </Pressable>
              </View>

              {/* Instalación */}
              <Text style={s.label}>⏱ Tiempo de instalación (minutos)</Text>
              <TextInput
                style={s.input}
                placeholder="Ej: 60"
                placeholderTextColor={COLORS.muted}
                keyboardType="numeric"
                value={editForm.setup_minutes}
                onChangeText={v => setEditForm(f => ({ ...f, setup_minutes: v.replace(/[^0-9]/g, '') }))}
              />

              {/* ¿Qué incluye? */}
              <Text style={s.label}>📋 ¿Qué incluye tu precio base?</Text>
              <TextInput
                style={[s.input, s.inputMulti, !!includesError && s.inputError]}
                placeholder={'Ej: "Sonido, luces básicas y transporte"\n"Solo músicos, sin equipo"'}
                placeholderTextColor={COLORS.muted}
                value={editForm.includes_text}
                onChangeText={v => {
                  setEditForm(f => ({ ...f, includes_text: v }));
                  const r = validatePublicText(v);
                  setIncludesError(r.valid ? null : r.error!);
                }}
                multiline maxLength={300} textAlignVertical="top"
              />
              {includesError && (
                <Text style={s.errorText}>⚠️ {includesError}</Text>
              )}

              <Pressable
                style={[s.saveBtn, (editSaving || !!descriptionError || !!includesError) && { opacity: 0.5 }]}
                onPress={saveEdit}
                disabled={editSaving || !!descriptionError || !!includesError}
              >
                <Text style={s.saveBtnText}>{editSaving ? 'Guardando...' : 'Guardar perfil'}</Text>
              </Pressable>
              </ScrollView>
            </View>
          </View>
        </KeyboardAvoidingView>
      </Modal>

      {/* ── MEMBER DETAIL MODAL ── */}
      <Modal
        visible={!!selectedMember}
        transparent
        animationType="slide"
        onRequestClose={() => setSelectedMember(null)}
      >
        <View style={s.overlay}>
          <View style={[s.sheet, { paddingBottom: 36 }]}>
            <View style={s.sheetHeader}>
              <Text style={s.sheetTitle}>
                {selectedMember?.isOwner ? 'Tu perfil artístico' : 'Perfil del miembro'}
              </Text>
              <Pressable onPress={() => setSelectedMember(null)} style={s.sheetClose}>
                <X size={18} color={COLORS.muted2} />
              </Pressable>
            </View>

            {selectedMember && (
              <View style={{ gap: 16 }}>
                {/* Avatar + name */}
                <View style={{ alignItems: 'center', gap: 10 }}>
                  <View style={s.memberDetailAvatar}>
                    {selectedMember.avatar
                      ? <Image source={{ uri: selectedMember.avatar }} style={s.memberDetailAvatarImg} />
                      : (
                        <View style={s.memberDetailAvatarPlaceholder}>
                          <Text style={s.memberDetailAvatarInitial}>
                            {selectedMember.name.charAt(0).toUpperCase()}
                          </Text>
                        </View>
                      )
                    }
                  </View>
                  <View style={{ alignItems: 'center' }}>
                    <View style={{ flexDirection: 'row', alignItems: 'center', gap: 8 }}>
                      <Text style={s.memberDetailName}>{selectedMember.name}</Text>
                      {selectedMember.isOwner && (
                        <View style={s.ownerBadge}><Text style={s.ownerBadgeText}>Dueño</Text></View>
                      )}
                    </View>
                    {selectedMember.role && (
                      <Text style={s.memberDetailRole}>{selectedMember.role}</Text>
                    )}
                  </View>
                </View>

                {/* Stats */}
                <View style={s.memberDetailStats}>
                  <View style={s.memberDetailStat}>
                    <Star size={14} color={COLORS.gold} fill={COLORS.gold} />
                    <Text style={[s.memberDetailStatVal, { color: COLORS.gold }]}>
                      {selectedMember.rating?.toFixed(1) ?? '5.0'}
                    </Text>
                    <Text style={s.memberDetailStatLabel}>Rating</Text>
                  </View>
                  <View style={s.memberDetailDivider} />
                  <View style={s.memberDetailStat}>
                    <Text style={{ fontSize: 14 }}>
                      {selectedMember.availability === 'available' ? '🟢' : '🔴'}
                    </Text>
                    <Text style={s.memberDetailStatVal}>
                      {selectedMember.availability === 'available' ? 'Disponible' : 'Ocupado'}
                    </Text>
                    <Text style={s.memberDetailStatLabel}>Estado</Text>
                  </View>
                  {selectedMember.experience != null && (
                    <>
                      <View style={s.memberDetailDivider} />
                      <View style={s.memberDetailStat}>
                        <Text style={{ fontSize: 14 }}>🎵</Text>
                        <Text style={s.memberDetailStatVal}>{selectedMember.experience}</Text>
                        <Text style={s.memberDetailStatLabel}>Años exp.</Text>
                      </View>
                    </>
                  )}
                </View>

                {/* Verification */}
                <View style={{ flexDirection: 'row', gap: 10, justifyContent: 'center' }}>
                  <View style={[s.verifiedChip, !selectedMember.phone_verified && { borderColor: COLORS.border, backgroundColor: 'transparent' }]}>
                    <Shield size={11} color={selectedMember.phone_verified ? COLORS.blue : COLORS.muted} />
                    <Text style={[s.verifiedChipText, !selectedMember.phone_verified && { color: COLORS.muted }]}>
                      Tel. {selectedMember.phone_verified ? 'verificado' : 'no verificado'}
                    </Text>
                  </View>
                  <View style={[s.verifiedChip, !selectedMember.id_verified && { borderColor: COLORS.border, backgroundColor: 'transparent' }]}>
                    <Shield size={11} color={selectedMember.id_verified ? COLORS.blue : COLORS.muted} />
                    <Text style={[s.verifiedChipText, !selectedMember.id_verified && { color: COLORS.muted }]}>
                      ID {selectedMember.id_verified ? 'verificada' : 'no verificada'}
                    </Text>
                  </View>
                </View>

                {/* If member (not owner) → button to remove from group */}
                {!selectedMember.isOwner && (
                  <Pressable style={s.removeMemberBtn} onPress={handleRemoveMember}>
                    <UserMinus size={16} color={COLORS.red} />
                    <Text style={s.removeMemberBtnText}>Quitar del grupo</Text>
                  </Pressable>
                )}
              </View>
            )}
          </View>
        </View>
      </Modal>
    </View>
  );
}

// ─── Sub-components ────────────────────────────────────────────────────────────

function FinCol({ label, value, color, sub }: { label: string; value: string; color: string; sub: string }) {
  return (
    <View style={{ flex: 1, alignItems: 'center', paddingHorizontal: 2 }}>
      <Text
        style={{ fontFamily: FONTS.bodyMedium, fontSize: 11, color, marginBottom: 1 }}
        numberOfLines={1}
        adjustsFontSizeToFit
        minimumFontScale={0.6}
      >
        {value}
      </Text>
      <Text style={{ fontFamily: FONTS.bodyMedium, fontSize: 9, color: COLORS.muted2, textAlign: 'center', marginBottom: 1 }}>{label}</Text>
      <Text style={{ fontFamily: FONTS.body, fontSize: 8, color: COLORS.muted, textAlign: 'center' }}>{sub}</Text>
    </View>
  );
}

function MiniStat({ icon, label, value, color, small, onPress }: any) {
  return (
    <Pressable style={[s.miniStat, { borderColor: `${color}25` }]} onPress={onPress}>
      <View style={[s.miniStatIcon, { backgroundColor: `${color}15` }]}>{icon}</View>
      <Text style={[s.miniStatValue, { color, fontSize: small ? 11 : 16 }]}>{value}</Text>
      <Text style={s.miniStatLabel}>{label}</Text>
    </Pressable>
  );
}

// ─── Styles ───────────────────────────────────────────────────────────────────

const s = StyleSheet.create({
  container:   { flex: 1, backgroundColor: COLORS.bg },
  center:      { flex: 1, alignItems: 'center', justifyContent: 'center', gap: 14, padding: 40 },
  loadingText: { fontFamily: FONTS.bodyMedium, fontSize: 14, color: COLORS.muted2 },
  errorTitle:  { fontFamily: FONTS.title, fontSize: 22, color: COLORS.text, textAlign: 'center' },
  errorMsg:    { fontFamily: FONTS.body, fontSize: 14, color: COLORS.muted2, textAlign: 'center', lineHeight: 20 },
  retryBtn:    { backgroundColor: COLORS.green, borderRadius: RADIUS.lg, paddingHorizontal: 32, paddingVertical: 13, marginTop: 8 },
  retryText:   { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.bg },

  // Header
  header: {
    flexDirection: 'row', justifyContent: 'space-between', alignItems: 'flex-start',
    paddingHorizontal: SPACING.xl, paddingTop: 14, paddingBottom: 16,
  },
  greeting:  { fontFamily: FONTS.title, fontSize: 22, color: COLORS.text },
  groupName: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.green },
  bellBtn: {
    width: 40, height: 40, borderRadius: 12,
    backgroundColor: COLORS.card, borderWidth: 1, borderColor: COLORS.border,
    alignItems: 'center', justifyContent: 'center',
  },
  notifBadge: {
    position: 'absolute', top: 6, right: 6,
    minWidth: 18, height: 18, borderRadius: 9,
    backgroundColor: COLORS.green, borderWidth: 1.5, borderColor: COLORS.bg,
    alignItems: 'center', justifyContent: 'center',
    paddingHorizontal: 4,
  },
  notifBadgeText: {
    fontFamily: FONTS.bodySemiBold, fontSize: 10, color: COLORS.bg,
  },

  // Identity hero (imagen completa + info encima)
  identityHero: {
    marginHorizontal: SPACING.xl, marginBottom: 20,
    borderRadius: RADIUS.xl, overflow: 'hidden',
    borderWidth: 1, borderColor: COLORS.border,
    height: 190,
    position: 'relative',
  },
  identityHeroImg: {
    position: 'absolute', top: 0, left: 0, right: 0, bottom: 0,
    borderRadius: RADIUS.xl,
  },
  identityHeroPlaceholder: {
    backgroundColor: COLORS.card2,
    alignItems: 'center', justifyContent: 'center',
  },
  identityHeroInitial: { fontFamily: FONTS.title, fontSize: 80, color: COLORS.green, opacity: 0.3 },
  identityHeroGradient: {
    position: 'absolute', left: 0, right: 0, bottom: 0,
    height: 160,
  },
  identityHeroCameraBtn: {
    width: 30, height: 30, borderRadius: 15,
    backgroundColor: 'rgba(0,0,0,0.55)',
    alignItems: 'center', justifyContent: 'center',
    borderWidth: 1, borderColor: 'rgba(255,255,255,0.25)',
  },
  identityHeroFloatBtn: {
    width: 30, height: 30, borderRadius: 15,
    backgroundColor: 'rgba(0,230,118,0.25)',
    alignItems: 'center', justifyContent: 'center',
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.5)',
  },
  identityHeroInfo: {
    position: 'absolute', left: 0, right: 0, bottom: 0,
    padding: 16,
  },
  identityHeroName:      { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: '#fff', flex: 1, letterSpacing: 0.5 },
  identityHeroGenre:     { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.green, marginBottom: 4 },
  identityHeroDesc:      { fontFamily: FONTS.body, fontSize: 12, color: 'rgba(255,255,255,0.7)', lineHeight: 17, marginBottom: 4 },
  identityHeroDescEmpty: { fontFamily: FONTS.body, fontSize: 12, color: 'rgba(255,255,255,0.4)', fontStyle: 'italic', marginBottom: 4 },
  identityHeroChip: {
    flexDirection: 'row', alignItems: 'center', gap: 4,
    backgroundColor: 'rgba(255,255,255,0.12)', borderRadius: RADIUS.full,
    borderWidth: 1, borderColor: 'rgba(255,255,255,0.25)',
    paddingHorizontal: 8, paddingVertical: 3,
  },
  identityHeroChipText: { fontFamily: FONTS.bodyMedium, fontSize: 10, color: '#fff' },

  // Verificado badge sólido (prominente)
  verifiedBadgeSolid: {
    flexDirection: 'row', alignItems: 'center', gap: 4,
    backgroundColor: COLORS.blue, borderRadius: RADIUS.full,
    paddingHorizontal: 8, paddingVertical: 3,
  },
  verifiedBadgeSolidText: { fontFamily: FONTS.bodySemiBold, fontSize: 10, color: '#fff' },
  unverifiedBadge: {
    flexDirection: 'row', alignItems: 'center', gap: 4,
    backgroundColor: 'rgba(255,152,0,0.2)', borderRadius: RADIUS.full,
    borderWidth: 1, borderColor: 'rgba(255,152,0,0.6)',
    paddingHorizontal: 8, paddingVertical: 3,
  },
  unverifiedBadgeText: { fontFamily: FONTS.bodySemiBold, fontSize: 10, color: COLORS.orange },

  // Stats strip overlay (top of hero photo)
  groupStatsStrip: {
    position: 'absolute', top: 0, left: 0, right: 0,
    flexDirection: 'row', alignItems: 'center',
    backgroundColor: 'rgba(0,0,0,0.58)',
    paddingVertical: 10,
    borderBottomWidth: 1, borderBottomColor: 'rgba(255,255,255,0.08)',
  },
  groupStatStripItem:  { flex: 1, alignItems: 'center', gap: 2 },
  groupStatStripDiv:   { width: 1, height: 28, backgroundColor: 'rgba(255,255,255,0.15)' },
  groupStatStripVal:   { fontFamily: FONTS.bodySemiBold, fontSize: 12, color: '#fff' },
  groupStatStripLabel: { fontFamily: FONTS.body, fontSize: 9, color: 'rgba(255,255,255,0.55)', textTransform: 'uppercase', letterSpacing: 0.3 },

  // Chips reutilizables (modal de miembro)
  verifiedChip: {
    flexDirection: 'row', alignItems: 'center', gap: 4,
    backgroundColor: 'rgba(66,133,244,0.1)', borderRadius: RADIUS.full,
    borderWidth: 1, borderColor: 'rgba(66,133,244,0.3)', paddingHorizontal: 8, paddingVertical: 3,
  },
  verifiedChipText: { fontFamily: FONTS.bodyMedium, fontSize: 11, color: COLORS.blue },

  // Stripe Connect banner
  stripeBanner: {
    marginHorizontal: SPACING.xl, marginBottom: 14,
    flexDirection: 'row', alignItems: 'center', gap: 10,
    borderRadius: RADIUS.xl, borderWidth: 1,
    padding: SPACING.lg,
  },
  stripeBannerAlert:   { backgroundColor: 'rgba(0,230,118,0.07)', borderColor: 'rgba(0,230,118,0.3)' },
  stripeBannerWarning: { backgroundColor: 'rgba(255,152,0,0.07)', borderColor: 'rgba(255,152,0,0.35)' },
  stripeBannerIcon:    { fontSize: 26 },
  stripeBannerBody:    { flex: 1, gap: 2 },
  stripeBannerTitle:   { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.text },
  stripeBannerSub:     { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted2, lineHeight: 16 },
  stripeConnectedRow: {
    flexDirection: 'row', alignItems: 'center', gap: 12,
    marginHorizontal: SPACING.xl, marginBottom: 14,
    backgroundColor: 'rgba(0,230,118,0.07)', borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.3)',
    padding: 14,
  },
  stripeConnectedText: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.green },
  stripeConnectedSub:  { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted2, marginTop: 2 },

  // Quote mini-cards
  sectionLabelAction: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.muted2 },
  quoteItem: {
    flexDirection: 'row', alignItems: 'center', gap: 12,
    marginHorizontal: SPACING.xl, marginBottom: 8,
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border,
    paddingHorizontal: 14, paddingVertical: 10,
  },
  quoteItemEmoji:    { fontSize: 20 },
  quoteItemClient:   { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.text },
  quoteItemDate:     { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted2, marginTop: 1 },
  quoteItemChip: {
    paddingHorizontal: 8, paddingVertical: 3,
    borderRadius: 8, borderWidth: 1,
  },
  quoteItemChipPending: { backgroundColor: 'rgba(255,152,0,0.08)', borderColor: 'rgba(255,152,0,0.4)' },
  quoteItemChipQuoted:  { backgroundColor: 'rgba(66,133,244,0.08)', borderColor: 'rgba(66,133,244,0.4)' },
  quoteItemChipText:    { fontFamily: FONTS.bodySemiBold, fontSize: 10 },

  // Package cards
  pkgCard: {
    width: 160, borderRadius: RADIUS.lg,
    backgroundColor: COLORS.card, borderWidth: 1, borderColor: COLORS.border,
    padding: 14, overflow: 'hidden',
  },
  pkgName:     { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.text, marginBottom: 2 },
  pkgDuration: { fontFamily: FONTS.bodyMedium, fontSize: 11, color: COLORS.green, marginBottom: 4 },
  pkgDesc:     { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted2, marginBottom: 8, lineHeight: 15 },
  pkgPrice:    { fontFamily: FONTS.title, fontSize: 18, color: COLORS.green },

  // Section label
  sectionLabel: {
    flexDirection: 'row', alignItems: 'center', gap: 7,
    paddingHorizontal: SPACING.xl, marginBottom: 10,
  },
  sectionLabelText: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.green, flex: 1 },
  seeAllBtn: { flexDirection: 'row', alignItems: 'center', gap: 2 },
  seeAllText: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.green },

  // Financial card
  finCard: {
    marginHorizontal: SPACING.xl, marginBottom: 16,
    backgroundColor: COLORS.card, borderRadius: RADIUS.xl,
    borderWidth: 1, borderColor: COLORS.border,
    overflow: 'hidden',
  },
  finGradient: { ...StyleSheet.absoluteFillObject },
  finMain: {
    padding: SPACING.lg, borderBottomWidth: 1, borderBottomColor: COLORS.border,
  },
  finMainLabel: { fontFamily: FONTS.bodyMedium, fontSize: 11, color: COLORS.muted2, marginBottom: 3 },
  finMainValue: { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.text, marginBottom: 2 },
  finMainSub:   { fontFamily: FONTS.body, fontSize: 10, color: COLORS.muted },
  finRow: {
    flexDirection: 'row', paddingHorizontal: SPACING.md, paddingVertical: SPACING.lg,
  },
  finDivider: { width: 1, backgroundColor: COLORS.border, marginHorizontal: 4 },

  // Mini stats
  miniStats: {
    flexDirection: 'row', gap: 10,
    paddingHorizontal: SPACING.xl, marginBottom: 24,
  },
  miniStat: {
    flex: 1, alignItems: 'center', paddingVertical: 14,
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1,
  },
  miniStatIcon:  { marginBottom: 6, width: 32, height: 32, borderRadius: 8, alignItems: 'center', justifyContent: 'center' },
  miniStatValue: { fontFamily: FONTS.title, fontSize: 16, marginBottom: 2 },
  miniStatLabel: { fontFamily: FONTS.body, fontSize: 10, color: COLORS.muted, textAlign: 'center' },

  // Live event banner
  liveBanner: {
    flexDirection: 'row', alignItems: 'center', gap: 12,
    marginHorizontal: SPACING.xl, marginBottom: 16,
    backgroundColor: COLORS.card, borderRadius: RADIUS.xl,
    borderWidth: 1.5, borderColor: COLORS.green,
    padding: SPACING.lg, overflow: 'hidden', position: 'relative',
  },
  liveBannerDot: {
    width: 10, height: 10, borderRadius: 5,
    backgroundColor: COLORS.red,
  },
  liveBannerTitle: {
    fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.green, marginBottom: 2,
  },
  liveBannerClient: {
    fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.text,
  },
  liveBannerAddress: {
    fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, marginTop: 2,
  },
  liveBannerBtn: {
    flexDirection: 'row', alignItems: 'center', gap: 4,
    backgroundColor: COLORS.green, borderRadius: RADIUS.md,
    paddingHorizontal: 12, paddingVertical: 8,
  },
  liveBannerBtnText: {
    fontFamily: FONTS.bodySemiBold, fontSize: 12, color: COLORS.bg,
  },

  // Member card
  memberCard: {
    flexDirection: 'row', alignItems: 'center', gap: 12,
    marginHorizontal: SPACING.xl, marginBottom: 8,
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border, padding: 14,
  },
  memberAvatar: {
    width: 44, height: 44, borderRadius: 22,
    backgroundColor: COLORS.greenMuted, borderWidth: 1.5, borderColor: COLORS.green,
    alignItems: 'center', justifyContent: 'center',
  },
  memberAvatarText: { fontFamily: FONTS.title, fontSize: 18, color: COLORS.green },
  memberName:  { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.text },
  memberRole:  { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, marginTop: 2 },
  memberDot:   { width: 8, height: 8, borderRadius: 4 },
  ownerBadge:  {
    backgroundColor: COLORS.greenMuted, borderRadius: RADIUS.full,
    borderWidth: 1, borderColor: COLORS.green,
    paddingHorizontal: 7, paddingVertical: 2,
  },
  ownerBadgeText: { fontFamily: FONTS.bodyMedium, fontSize: 10, color: COLORS.green },

  // Upcoming card
  upcomingCard: {
    flexDirection: 'row', alignItems: 'stretch',
    marginHorizontal: SPACING.xl, marginBottom: 10,
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border, overflow: 'hidden',
  },
  dateBubble: { width: 54, alignItems: 'center', justifyContent: 'center', paddingVertical: 12 },
  dateDay:    { fontFamily: FONTS.title, fontSize: 22, color: COLORS.bg },
  dateMon:    { fontFamily: FONTS.bodyMedium, fontSize: 10, color: COLORS.bg, letterSpacing: 0.5 },
  upClient:   { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.text, flex: 1, marginRight: 6 },
  upPkg:      { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2 },
  upMeta:     { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted },
  upEarnings: {
    paddingHorizontal: 12, justifyContent: 'center', alignItems: 'flex-end',
    borderLeftWidth: 1, borderLeftColor: COLORS.border,
  },
  upEarningsValue: { fontFamily: FONTS.title, fontSize: 13, color: COLORS.green },
  upEarningsSub:   { fontFamily: FONTS.body, fontSize: 9, color: COLORS.muted },
  upcomingCardExpress: { borderColor: 'rgba(255,179,0,0.40)', backgroundColor: 'rgba(255,179,0,0.04)' },
  upExpressBadge: {
    backgroundColor: 'rgba(255,179,0,0.15)', borderRadius: 20,
    paddingHorizontal: 7, paddingVertical: 3,
    borderWidth: 1, borderColor: 'rgba(255,179,0,0.40)',
  },
  upExpressBadgeText: { fontFamily: FONTS.bodyMedium, fontSize: 10, color: '#FFB300' },
  paidExpressBadge: {
    backgroundColor: 'rgba(255,179,0,0.12)', borderRadius: 20,
    paddingHorizontal: 6, paddingVertical: 2,
    borderWidth: 1, borderColor: 'rgba(255,179,0,0.35)',
  },
  paidExpressBadgeText: { fontFamily: FONTS.bodyMedium, fontSize: 9, color: '#FFB300' },

  // ── Calendar strip ───────────────────────────────────────────
  calDay: {
    width: 44, alignItems: 'center', paddingVertical: 8, borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: 'transparent',
  },
  calDayToday: {
    borderColor: `${COLORS.green}50`,
    backgroundColor: `${COLORS.green}0A`,
  },
  calDayEvent: {
    borderColor: COLORS.green,
    backgroundColor: `${COLORS.green}15`,
  },
  calDayName: { fontFamily: FONTS.body, fontSize: 10, color: COLORS.muted, marginBottom: 4 },
  calDayNum:  { fontFamily: FONTS.bodyMedium, fontSize: 16, color: COLORS.muted2 },
  calDot: {
    width: 5, height: 5, borderRadius: 3,
    backgroundColor: COLORS.green, marginTop: 4,
  },

  // Paid events row
  paidRow: {
    flexDirection: 'row', alignItems: 'center', gap: 14,
    marginHorizontal: SPACING.xl, marginBottom: 10,
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border, padding: 14,
  },
  paidDate: {
    width: 48, height: 48, borderRadius: 12,
    backgroundColor: COLORS.card2, borderWidth: 1, borderColor: COLORS.border,
    alignItems: 'center', justifyContent: 'center',
  },
  paidDay:  { fontFamily: FONTS.title, fontSize: 18, color: COLORS.muted2, lineHeight: 18 },
  paidMon:  { fontFamily: FONTS.bodyMedium, fontSize: 9, color: COLORS.muted, letterSpacing: 0.5, textTransform: 'uppercase' },
  paidClient:   { fontFamily: FONTS.bodyMedium, fontSize: 14, color: COLORS.muted2, marginBottom: 2 },
  paidPkg:      { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted, marginBottom: 1 },
  paidDate2:    { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted },
  paidEarnings: { fontFamily: FONTS.title, fontSize: 16, color: COLORS.muted2, marginBottom: 2 },
  paidGross:    { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted },

  // Empty state
  emptyCard: {
    alignItems: 'center', paddingVertical: 32,
    marginHorizontal: SPACING.xl, marginBottom: 24,
    backgroundColor: COLORS.card, borderRadius: RADIUS.xl,
    borderWidth: 1, borderColor: COLORS.border, gap: 6,
  },
  emptyIcon:  { fontSize: 36 },
  emptyTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.text },
  emptyText:  { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted },

  // Modal
  overlay: { flex: 1, backgroundColor: 'rgba(0,0,0,0.65)', justifyContent: 'flex-end' },
  sheet: {
    backgroundColor: COLORS.card, borderTopLeftRadius: 24, borderTopRightRadius: 24,
    padding: SPACING.xl, paddingBottom: 44,
    borderTopWidth: 1, borderColor: COLORS.border,
    maxHeight: '85%',
  },
  videoSuccessBanner: {
    backgroundColor: 'rgba(0,230,118,0.15)', borderRadius: RADIUS.sm,
    borderWidth: 1, borderColor: COLORS.green,
    paddingHorizontal: 12, paddingVertical: 8, marginTop: 8, marginBottom: 6,
  },
  videoSuccessText: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.green },

  mediaStatusBadge: {
    position: 'absolute', bottom: 48, left: 12,
    backgroundColor: 'rgba(0,0,0,0.78)', borderRadius: RADIUS.sm,
    paddingHorizontal: 10, paddingVertical: 5,
  },
  mediaStatusText: { fontFamily: FONTS.bodyMedium, fontSize: 11, color: '#fff' },

  sheetHeader: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center', marginBottom: 20, paddingRight: 4 },
  sheetTitle:  { fontFamily: FONTS.title, fontSize: 20, color: COLORS.text, flex: 1 },
  sheetClose:  { width: 32, height: 32, borderRadius: 8, backgroundColor: COLORS.bg, alignItems: 'center', justifyContent: 'center', marginLeft: 8 },
  label:       { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted2, marginBottom: 8 },
  input: {
    backgroundColor: COLORS.bg, borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: COLORS.border,
    paddingHorizontal: 14, paddingVertical: 13,
    fontFamily: FONTS.body, fontSize: 15, color: COLORS.text, marginBottom: 16,
  },
  inputMulti:  { height: 100, marginBottom: 4 },
  charCount:   { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted, textAlign: 'right', marginBottom: 16 },
  saveBtn:     { backgroundColor: COLORS.green, borderRadius: RADIUS.lg, paddingVertical: 15, alignItems: 'center', marginTop: 8 },
  saveBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.bg },
  removeMemberBtn: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 8,
    borderRadius: RADIUS.lg, paddingVertical: 13, marginTop: 4,
    backgroundColor: 'rgba(239,83,80,0.1)', borderWidth: 1, borderColor: 'rgba(239,83,80,0.35)',
  },
  removeMemberBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.red },

  // Video promocional
  videoPreviewBox: { marginBottom: 4 },
  videoPreview: {
    width: '100%', height: 180,
    borderRadius: RADIUS.lg, backgroundColor: '#000',
    marginBottom: 10,
  },
  videoBtnOutline: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 8,
    borderWidth: 1, borderColor: COLORS.green,
    borderRadius: RADIUS.lg, paddingVertical: 13, marginBottom: 4,
  },
  videoBtnOutlineText: { fontFamily: FONTS.bodyMedium, fontSize: 14, color: COLORS.green },
  videoBtnSolid: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 8,
    backgroundColor: COLORS.green, borderRadius: RADIUS.lg, paddingVertical: 14, marginBottom: 4,
  },
  videoBtnSolidText: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.bg },
  videoHint: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted, textAlign: 'center', marginBottom: 20 },
  // 🎬 Gestor de videos del carrusel
  myVideoRow: {
    flexDirection: 'row', alignItems: 'center', gap: 10,
    backgroundColor: COLORS.card2, borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: COLORS.border,
    paddingHorizontal: 12, paddingVertical: 9, marginBottom: 6,
  },
  myVideoName:   { fontFamily: FONTS.bodyMedium, fontSize: 12.5, color: COLORS.text, flex: 1 },
  myVideoPreview: {
    width: 150, height: 96, borderRadius: 14, overflow: 'hidden', marginRight: 10,
    backgroundColor: '#060c06', borderWidth: 1.5, borderColor: 'rgba(0,230,118,0.35)',
  },
  myVideoStatus: { fontFamily: FONTS.bodySemiBold, fontSize: 11 },
  plusUpsell: {
    marginTop: 8, marginBottom: 4, padding: 12,
    backgroundColor: 'rgba(201,168,76,0.08)', borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: 'rgba(201,168,76,0.35)',
  },
  plusUpsellTx: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.text, lineHeight: 17 },
  plusActiveTx: {
    fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.green,
    lineHeight: 17, marginBottom: 10,
  },

  // Lineup horizontal
  lineupRow: { paddingHorizontal: SPACING.xl, gap: 16, paddingBottom: 20 },
  lineupItem: { alignItems: 'center', width: 72 },
  lineupAvatarWrap: {
    width: 64, height: 64, borderRadius: 32,
    borderWidth: 2, borderColor: COLORS.green,
    marginBottom: 6, position: 'relative',
    overflow: 'visible',
  },
  lineupAvatarImg:  { width: 60, height: 60, borderRadius: 30, margin: 2 },
  lineupAvatarPlaceholder: {
    width: 60, height: 60, borderRadius: 30, margin: 2,
    backgroundColor: COLORS.greenMuted,
    alignItems: 'center', justifyContent: 'center',
  },
  lineupAvatarInitial: { fontFamily: FONTS.title, fontSize: 24, color: COLORS.green },
  lineupOwnerBadge: {
    position: 'absolute', bottom: -2, right: -2,
    width: 18, height: 18, borderRadius: 9,
    backgroundColor: COLORS.green, borderWidth: 2, borderColor: COLORS.bg,
  },
  lineupAddBtn: {
    borderColor: COLORS.border, borderStyle: 'dashed',
    backgroundColor: COLORS.card2,
    alignItems: 'center', justifyContent: 'center',
  },
  lineupName: { fontFamily: FONTS.bodySemiBold, fontSize: 11, color: COLORS.text, textAlign: 'center' },
  lineupRole: { fontFamily: FONTS.body, fontSize: 10, color: COLORS.muted, textAlign: 'center' },

  // Promo card (dorada) — "Promociona tu grupo"
  promocionarseCard: {
    marginHorizontal: SPACING.xl, marginTop: 24, borderRadius: RADIUS.lg,
    overflow: 'hidden', borderWidth: 1, borderColor: 'rgba(201,168,76,0.35)',
  },
  promocionarseGradient: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', padding: 16,
  },
  promocionarseLeft: { flexDirection: 'row', alignItems: 'center', gap: 12, flex: 1 },
  promocionarseIconWrap: {
    width: 40, height: 40, borderRadius: 20,
    backgroundColor: 'rgba(201,168,76,0.18)',
    alignItems: 'center', justifyContent: 'center',
  },
  promocionarseTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: '#E8C85A', marginBottom: 2 },
  promocionarseSub: { fontFamily: FONTS.body, fontSize: 12, color: 'rgba(201,168,76,0.7)', lineHeight: 17 },

  // Benefits banner
  benefitsBanner: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between',
    marginHorizontal: SPACING.xl, marginTop: 24,
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.25)',
    padding: 16,
  },
  benefitsBannerLeft: { flexDirection: 'row', alignItems: 'center', gap: 12, flex: 1 },
  benefitsBannerEmoji: { fontSize: 24 },
  benefitsBannerTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.text, marginBottom: 2 },
  benefitsBannerSub: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, lineHeight: 17 },

  quotesBanner: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between',
    marginHorizontal: SPACING.xl, marginTop: 12,
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: 'rgba(255,152,0,0.3)',
    padding: 16,
  },
  quotesBannerTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.orange, marginBottom: 2 },

  statsBanner: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between',
    marginHorizontal: SPACING.xl, marginTop: 12,
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: 'rgba(66,133,244,0.3)',
    padding: 16,
  },
  statsBannerTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.blue, marginBottom: 2 },

  // Member detail modal
  memberDetailAvatar: { position: 'relative' },
  memberDetailAvatarImg: { width: 80, height: 80, borderRadius: 40 },
  memberDetailAvatarPlaceholder: {
    width: 80, height: 80, borderRadius: 40,
    backgroundColor: COLORS.greenMuted, borderWidth: 2, borderColor: COLORS.green,
    alignItems: 'center', justifyContent: 'center',
  },
  memberDetailAvatarInitial: { fontFamily: FONTS.title, fontSize: 34, color: COLORS.green },
  memberDetailName:  { fontFamily: FONTS.title, fontSize: 20, color: COLORS.text },
  memberDetailRole:  { fontFamily: FONTS.body, fontSize: 14, color: COLORS.green, marginTop: 2 },
  memberDetailStats: {
    flexDirection: 'row', alignItems: 'center',
    backgroundColor: COLORS.bg, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border,
    paddingVertical: 14, paddingHorizontal: 10,
  },
  memberDetailStat:      { flex: 1, alignItems: 'center', gap: 4 },
  memberDetailStatVal:   { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.text },
  memberDetailStatLabel: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted },
  memberDetailDivider:   { width: 1, height: 36, backgroundColor: COLORS.border },

  // Boost / promotion section (legacy — kept for styles that may be referenced)
  boostSection: {
    marginHorizontal: SPACING.xl, marginBottom: 20,
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border,
    paddingHorizontal: SPACING.lg, paddingVertical: 12,
    gap: 10,
  },
  boostSectionTitle: { fontFamily: FONTS.bodyMedium, fontSize: 11, color: COLORS.muted2, textTransform: 'uppercase' as const, letterSpacing: 0.8 },
  boostRow: { flexDirection: 'row', gap: 10 },
  boostChip: {
    flex: 1, flexDirection: 'row', alignItems: 'center', gap: 7,
    backgroundColor: COLORS.card2, borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: COLORS.border,
    paddingHorizontal: 12, paddingVertical: 10,
  },
  boostChipEmoji: { fontSize: 14 },
  boostChipLabel: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted2, flex: 1 },

  // Promo card prominente (nuevo)
  promoCard: {
    marginHorizontal: SPACING.xl, marginBottom: 14,
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.25)',
    paddingHorizontal: SPACING.md, paddingVertical: 12,
    overflow: 'hidden' as const, gap: 7,
  },
  promoUrgency: {
    fontFamily: FONTS.bodySemiBold, fontSize: 13,
    lineHeight: 18,
  },
  promoSocial: {
    fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted2, lineHeight: 16,
  },
  promoScarcityRow: {
    backgroundColor: 'rgba(239,68,68,0.10)', borderRadius: RADIUS.sm,
    paddingHorizontal: 10, paddingVertical: 5, alignSelf: 'flex-start',
  },
  promoScarcityText: {
    fontFamily: FONTS.bodyMedium, fontSize: 11, color: '#EF4444',
  },
  promoMainBtn: {
    backgroundColor: COLORS.green, borderRadius: RADIUS.md,
    height: 46, alignItems: 'center', justifyContent: 'center',
    marginTop: 2,
  },
  promoMainBtnText: {
    fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.bg,
  },
  promoSecRow: { flexDirection: 'row', gap: 8 },
  promoSecChip: {
    flex: 1, alignItems: 'center', justifyContent: 'center',
    backgroundColor: COLORS.card2, borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: COLORS.border,
    paddingVertical: 9,
  },
  promoSecChipText: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.muted2 },

  // ── Ranking card (legacy — reemplazada en bloque 3) ──────────────────────
  rankHeader: { flexDirection: 'row', alignItems: 'center', gap: 6 },
  rankTitle:  { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.text, flex: 1 },
  rankBadge:  {
    backgroundColor: 'rgba(251,146,60,0.15)', borderRadius: RADIUS.sm,
    paddingHorizontal: 8, paddingVertical: 3,
    borderWidth: 1, borderColor: 'rgba(251,146,60,0.35)',
  },
  rankBadgeText: { fontFamily: FONTS.bodyMedium, fontSize: 11, color: '#FB923C' },
  rankStatsRow:  { flexDirection: 'row', alignItems: 'center', gap: 0 },
  rankStat:      { flex: 1, alignItems: 'center' },
  rankStatNum:   { fontFamily: FONTS.title, fontSize: 22, color: COLORS.text },
  rankStatLabel: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted, marginTop: 1 },
  rankStatDivider: { width: 1, height: 32, backgroundColor: COLORS.border },
  rankTop3: { gap: 4 },
  rankTop3Row: {
    flexDirection: 'row', alignItems: 'center', gap: 8,
    paddingHorizontal: 8, paddingVertical: 5,
    borderRadius: RADIUS.sm,
  },
  rankTop3RowMe: { backgroundColor: 'rgba(0,230,118,0.08)', borderWidth: 1, borderColor: 'rgba(0,230,118,0.25)' },
  rankTop3Emoji: { fontSize: 14, width: 20 },
  rankTop3Name:  { flex: 1, fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted2 },
  rankTop3Bid:   { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted },
  rankGap: { flexDirection: 'row', alignItems: 'center', gap: 5 },
  rankGapText: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, flex: 1 },
  rankBtn: {
    backgroundColor: 'rgba(0,230,118,0.12)', borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.35)',
    paddingVertical: 10, alignItems: 'center', marginTop: 2,
  },
  rankBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.green },
  rankScarcity: {
    fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted,
    textAlign: 'center', marginTop: 2,
  },
  rankAlertDisplaced: {
    backgroundColor: 'rgba(239,68,68,0.10)', borderRadius: RADIUS.sm,
    borderWidth: 1, borderColor: 'rgba(239,68,68,0.30)',
    paddingHorizontal: 10, paddingVertical: 8, gap: 2,
  },
  rankAlertRising: {
    flexDirection: 'row', alignItems: 'center', gap: 7,
    backgroundColor: 'rgba(251,146,60,0.10)', borderRadius: RADIUS.sm,
    borderWidth: 1, borderColor: 'rgba(251,146,60,0.25)',
    paddingHorizontal: 10, paddingVertical: 7,
  },
  rankAlertText: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: '#EF4444' },
  rankLiveDot: {
    width: 7, height: 7, borderRadius: 4, backgroundColor: '#FB923C',
  },
  rankStatusRow: {
    borderRadius: RADIUS.sm, borderWidth: 1,
    paddingHorizontal: 10, paddingVertical: 6, alignSelf: 'flex-start',
  },
  rankStatusText: { fontFamily: FONTS.bodyMedium, fontSize: 12 },
  rankProgressTrack: {
    height: 5, backgroundColor: COLORS.border, borderRadius: 3, overflow: 'hidden',
  },
  rankProgressFill: {
    height: '100%', backgroundColor: COLORS.green, borderRadius: 3,
  },
  rankSuperarBtn: {
    backgroundColor: COLORS.green, borderRadius: RADIUS.md,
    paddingVertical: 11, alignItems: 'center',
  },
  rankSuperarBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.bg },
  rankTop3Protection: {
    fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted,
    lineHeight: 16, paddingHorizontal: 2,
  },
  promoDynamic: {
    fontFamily: FONTS.bodyMedium, fontSize: 11, color: '#FB923C', lineHeight: 16,
  },
  seedingBadge: {
    alignSelf: 'flex-start',
    backgroundColor: 'rgba(0,230,118,0.12)',
    borderRadius: 6,
    borderWidth: 1,
    borderColor: 'rgba(0,230,118,0.35)',
    paddingHorizontal: 10,
    paddingVertical: 4,
    marginTop: 2,
  },
  seedingBadgeText: {
    fontFamily: FONTS.bodySemiBold, fontSize: 11, color: COLORS.green,
  },
  seedingScarcityInline: {
    backgroundColor: 'rgba(239,68,68,0.08)',
    borderRadius: 6,
    borderWidth: 1,
    borderColor: 'rgba(239,68,68,0.25)',
    paddingHorizontal: 10,
    paddingVertical: 5,
    marginTop: 4,
  },
  seedingScarcityInlineText: {
    fontFamily: FONTS.bodyMedium, fontSize: 11, color: '#EF4444',
  },
  seedingRankBadge: {
    backgroundColor: 'rgba(0,230,118,0.10)',
    borderRadius: 6,
    borderWidth: 1,
    borderColor: 'rgba(0,230,118,0.25)',
    paddingHorizontal: 10,
    paddingVertical: 6,
    marginBottom: 8,
  },
  seedingRankText: {
    fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.green,
  },
  rankSuccessBanner: {
    backgroundColor: 'rgba(0,230,118,0.15)',
    borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.5)',
    paddingHorizontal: 14, paddingVertical: 10,
    alignItems: 'center',
  },
  rankSuccessText: {
    fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.green, textAlign: 'center',
  },
  rankIdleAlert: {
    backgroundColor: 'rgba(251,146,60,0.10)', borderRadius: RADIUS.sm,
    borderWidth: 1, borderColor: 'rgba(251,146,60,0.30)',
    paddingHorizontal: 10, paddingVertical: 7,
  },
  rankIdleText: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: '#FB923C' },
  rankNearAlert: {
    backgroundColor: 'rgba(0,230,118,0.10)', borderRadius: RADIUS.sm,
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.30)',
    paddingHorizontal: 10, paddingVertical: 7,
  },
  rankNearText: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.green },
  rankAlmostUpAlert: {
    backgroundColor: 'rgba(0,230,118,0.14)', borderRadius: RADIUS.sm,
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.5)',
    paddingHorizontal: 12, paddingVertical: 9, alignItems: 'center' as const,
  },
  rankAlmostUpText: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.green },
  rankFocusAlert: {
    backgroundColor: 'rgba(99,102,241,0.12)', borderRadius: RADIUS.sm,
    borderWidth: 1, borderColor: 'rgba(99,102,241,0.30)',
    paddingHorizontal: 10, paddingVertical: 7,
  },
  rankFocusText: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: '#818CF8' },
  rankRetentionAlert: {
    backgroundColor: 'rgba(99,102,241,0.10)', borderRadius: RADIUS.sm,
    borderWidth: 1, borderColor: 'rgba(99,102,241,0.25)',
    paddingHorizontal: 10, paddingVertical: 7,
  },
  rankRetentionText: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: '#818CF8' },
  rankDropBanner: {
    backgroundColor: 'rgba(239,68,68,0.12)', borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: 'rgba(239,68,68,0.40)',
    paddingHorizontal: 14, paddingVertical: 10, alignItems: 'center' as const,
  },
  rankDropText: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: '#EF4444', textAlign: 'center' as const },

  // Boost / promotion banner (legacy, kept for reference)
  boostBanner: {
    flexDirection: 'row', alignItems: 'center', gap: 12,
    marginHorizontal: SPACING.xl, marginBottom: 12,
    backgroundColor: 'rgba(124,58,237,0.12)',
    borderRadius: RADIUS.lg, borderWidth: 1, borderColor: 'rgba(124,58,237,0.35)',
    paddingHorizontal: SPACING.lg, paddingVertical: 13,
  },
  boostBannerTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: '#c084fc', marginBottom: 2 },
  boostBannerSub:   { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2 },
  boostBannerBtn: {
    backgroundColor: '#7c3aed',
    borderRadius: RADIUS.md,
    paddingHorizontal: 12, paddingVertical: 7,
  },
  boostBannerBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 12, color: '#fff' },

  // Recommendation widget
  recWidget: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between',
    marginHorizontal: SPACING.xl, marginBottom: 12,
    backgroundColor: 'rgba(255,193,7,0.07)',
    borderRadius: RADIUS.lg, borderWidth: 1, borderColor: 'rgba(255,193,7,0.3)',
    paddingHorizontal: SPACING.md, paddingVertical: 11,
    gap: 8,
  },
  recWidgetTitle:  { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.gold },
  recWidgetSub:    { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted2, marginTop: 2 },
  recWidgetArrow:  { fontFamily: FONTS.bodySemiBold, fontSize: 16, color: COLORS.gold },

  // Wallet widget
  walletWidget: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between',
    marginHorizontal: SPACING.xl, marginBottom: 12,
    backgroundColor: COLORS.greenMuted,
    borderRadius: RADIUS.lg, borderWidth: 1, borderColor: COLORS.green + '50',
    paddingHorizontal: SPACING.md, paddingVertical: 9,
  },
  walletWidgetLeft:   { gap: 2 },
  walletWidgetLabel:  { fontFamily: FONTS.bodyMedium, fontSize: 10, color: COLORS.muted2 },
  walletWidgetAmount: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.green },
  walletWidgetSub:    { fontFamily: FONTS.body, fontSize: 9, color: COLORS.muted },
  walletWidgetRight:  { alignItems: 'flex-end' },
  walletWidgetAction: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.green },

  // Open requests banner
  pendingProposalBanner: {
    flexDirection: 'row', alignItems: 'center', gap: 12,
    marginHorizontal: SPACING.xl, marginBottom: 12,
    backgroundColor: 'rgba(0,230,118,0.08)',
    borderRadius: RADIUS.lg, borderWidth: 1, borderColor: COLORS.green,
    paddingHorizontal: SPACING.lg, paddingVertical: 13,
  },
  pendingProposalEmoji: { fontSize: 24 },
  pendingProposalTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.green },
  pendingProposalSub:   { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, marginTop: 2 },

  availabilityBtn: {
    flexDirection: 'row' as const, alignItems: 'center' as const, gap: 12,
    marginHorizontal: SPACING.xl, marginBottom: 16,
    backgroundColor: COLORS.card,
    borderRadius: RADIUS.lg, borderWidth: 1, borderColor: COLORS.border,
    paddingHorizontal: SPACING.lg, paddingVertical: 13,
  },
  availabilityBtnActive: {
    backgroundColor: 'rgba(0,230,118,0.07)',
    borderColor: 'rgba(0,230,118,0.40)',
  },
  availabilityBtnTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.text as string },
  availabilityBtnSub:   { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2 as string, marginTop: 2 },

  openRequestsBanner: {
    flexDirection: 'row', alignItems: 'center', gap: 12,
    marginHorizontal: SPACING.xl, marginBottom: 16,
    backgroundColor: 'rgba(0,230,118,0.07)',
    borderRadius: RADIUS.lg, borderWidth: 1, borderColor: 'rgba(0,230,118,0.25)',
    paddingHorizontal: SPACING.lg, paddingVertical: 13,
  },
  openRequestsBannerActive: {
    backgroundColor: 'rgba(0,230,118,0.13)',
    borderColor: COLORS.green,
    shadowColor: COLORS.green,
    shadowOffset: { width: 0, height: 0 },
    shadowOpacity: 0.35,
    shadowRadius: 10,
    elevation: 6,
  },
  openRequestsEmoji: { fontSize: 26 },
  openRequestsTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.muted2 },
  openRequestsSub:   { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted, marginTop: 2 },
  openRequestsBadge: {
    width: 26, height: 26, borderRadius: 13,
    backgroundColor: COLORS.green,
    alignItems: 'center', justifyContent: 'center',
  },
  openRequestsBadgeText: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.bg },

  // Referral + badges card
  referralCard: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.xl,
    borderWidth: 1, borderColor: COLORS.border,
    padding: SPACING.lg, marginBottom: 16,
  },
  badgesRow: { flexDirection: 'row', flexWrap: 'wrap', gap: 6, marginBottom: 10 },
  badgeChip: {
    backgroundColor: 'rgba(0,230,118,0.08)', borderRadius: RADIUS.full,
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.25)',
    paddingHorizontal: 10, paddingVertical: 4,
  },
  badgeChipText: { fontFamily: FONTS.bodyMedium, fontSize: 11, color: COLORS.green },
  completionsRow: { flexDirection: 'row', alignItems: 'center', gap: 6, marginBottom: 12 },
  completionsText: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.green },
  complianceTip: {
    flexDirection: 'row', alignItems: 'center', gap: 8,
    marginHorizontal: SPACING.xl, marginBottom: 14,
    backgroundColor: 'rgba(0,230,118,0.06)', borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.15)',
    paddingHorizontal: 12, paddingVertical: 9,
  },
  complianceTipText: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.muted2, flex: 1 },
  referralLabel: { fontFamily: FONTS.bodyMedium, fontSize: 11, color: COLORS.muted2, marginBottom: 8, textTransform: 'uppercase', letterSpacing: 0.8 },
  referralCodeRow: { flexDirection: 'row', alignItems: 'center', gap: 8, marginBottom: 6 },
  referralCode: { fontFamily: FONTS.title, fontSize: 20, color: COLORS.text, flex: 1, letterSpacing: 2 },
  referralCopyBtn: {
    width: 34, height: 34, borderRadius: 10,
    backgroundColor: COLORS.card2, borderWidth: 1, borderColor: COLORS.border,
    alignItems: 'center', justifyContent: 'center',
  },
  referralShareBtn: {
    flexDirection: 'row', alignItems: 'center', gap: 6,
    backgroundColor: COLORS.green, borderRadius: 10,
    paddingHorizontal: 14, paddingVertical: 8,
  },
  referralShareText: { fontFamily: FONTS.bodySemiBold, fontSize: 12, color: COLORS.bg },
  referralSub: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted, marginTop: 2 },
  referralStatsRow: {
    flexDirection: 'row', alignItems: 'center',
    backgroundColor: COLORS.card2, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border,
    paddingVertical: 10, paddingHorizontal: 8,
    marginTop: 12,
  },
  referralStat: { flex: 1, alignItems: 'center' },
  referralStatNum: { fontFamily: FONTS.title, fontSize: 18, color: COLORS.text, lineHeight: 22 },
  referralStatLabel: { fontFamily: FONTS.body, fontSize: 10, color: COLORS.muted, marginTop: 2 },
  referralStatDivider: { width: 1, height: 32, backgroundColor: COLORS.border },

  // Loyal clients
  loyalCard: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.xl,
    borderWidth: 1, borderColor: COLORS.border,
    padding: SPACING.lg, marginBottom: 16,
  },
  loyalRow: {
    flexDirection: 'row', alignItems: 'center',
    paddingVertical: 8, borderBottomWidth: 1, borderBottomColor: COLORS.border,
    gap: 8,
  },
  loyalNameRow: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.text, flex: 1 },
  loyalMeta:  { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2 },
  loyalTier:  { fontSize: 16 },

  // Zone activity card
  zoneCard: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.xl,
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.25)',
    padding: SPACING.lg, marginBottom: 16,
  },
  zoneStatsRow: { flexDirection: 'row', alignItems: 'center', marginBottom: 14 },
  zoneStat: { flex: 1, alignItems: 'center', gap: 4 },
  zoneStatValue: { fontFamily: FONTS.title, fontSize: 26, color: COLORS.text },
  zoneStatLabel: { fontFamily: FONTS.body, fontSize: 10, color: COLORS.muted2, textAlign: 'center', lineHeight: 14 },
  zoneStatDivider: { width: 1, height: 36, backgroundColor: COLORS.border },
  trendUp: {
    backgroundColor: 'rgba(0,230,118,0.15)', borderRadius: RADIUS.full,
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.4)',
    paddingHorizontal: 8, paddingVertical: 3,
  },
  trendUpText: { fontFamily: FONTS.bodyMedium, fontSize: 10, color: COLORS.green },
  zoneActionBtn: {
    backgroundColor: COLORS.greenMuted, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.green,
    paddingVertical: 10, alignItems: 'center',
  },
  zoneActionBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.green },

  // Referral share banner
  referralShareBanner: {
    backgroundColor: COLORS.greenMuted, borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.3)',
    paddingHorizontal: 12, paddingVertical: 10, marginBottom: 12,
  },
  referralShareBannerText: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.green },
  referralShareBannerSub: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted2, marginTop: 2 },

  // ── Rendimiento ──────────────────────────────────────────────────────────
  perfCard: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.xl,
    borderWidth: 1, borderColor: COLORS.border,
    padding: SPACING.lg, marginBottom: 16,
  },
  perfMotivation: {
    flexDirection: 'row', alignItems: 'center', gap: 8,
    backgroundColor: COLORS.greenMuted, borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.3)',
    paddingHorizontal: 12, paddingVertical: 9, marginBottom: 14,
  },
  perfMotivationText: {
    fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.green, flex: 1, lineHeight: 17,
  },
  perfRatingRow: {
    flexDirection: 'row', alignItems: 'center', gap: 8, marginBottom: 12,
  },
  perfRatingVal: { fontFamily: FONTS.bodySemiBold, fontSize: 16, color: COLORS.gold },
  perfRatingCount: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2 },
  perfChipsRow: { flexDirection: 'row', flexWrap: 'wrap', gap: 8, marginBottom: 12 },
  perfChip: {
    flexDirection: 'row', alignItems: 'center', gap: 5,
    backgroundColor: COLORS.greenMuted, borderRadius: RADIUS.full,
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.4)',
    paddingHorizontal: 10, paddingVertical: 5,
  },
  perfChipBlue: {
    backgroundColor: 'rgba(66,133,244,0.12)',
    borderColor: 'rgba(66,133,244,0.4)',
  },
  perfChipText: { fontFamily: FONTS.bodyMedium, fontSize: 11, color: COLORS.green },
  perfCancelRow: {
    flexDirection: 'row', alignItems: 'center', gap: 8,
    marginBottom: 10,
  },
  perfCancelDot: {
    width: 8, height: 8, borderRadius: 4, backgroundColor: COLORS.green,
  },
  perfCancelDotRed: { backgroundColor: COLORS.red },
  perfCancelText: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, flex: 1, lineHeight: 17 },
  perfCancelTextRed: { color: '#EF4444' },
  perfRewardBanner: {
    backgroundColor: 'rgba(255,179,0,0.10)', borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: 'rgba(255,179,0,0.35)',
    paddingHorizontal: 14, paddingVertical: 10, marginTop: 4,
  },
  perfRewardText: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.gold },
  perfRewardSub: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted2, marginTop: 2 },
  perfPenaltyBanner: {
    backgroundColor: 'rgba(239,68,68,0.08)', borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: 'rgba(239,68,68,0.25)',
    paddingHorizontal: 14, paddingVertical: 10, marginTop: 4,
  },
  perfPenaltyText: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: '#EF4444' },
  perfPenaltySub: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted2, marginTop: 2 },

  // ── HERO ──────────────────────────────────────────────────────────────────
  heroContainer: { width: '100%', height: 280, position: 'relative' },
  heroImage: { width: '100%', height: '100%' },
  heroImagePlaceholder: {
    backgroundColor: COLORS.card,
    alignItems: 'center', justifyContent: 'center',
  },
  heroOverlay: {
    position: 'absolute', left: 0, right: 0, bottom: 0, height: 180,
    justifyContent: 'flex-end', paddingHorizontal: SPACING.xl, paddingBottom: 16,
  },
  heroInfo: { gap: 2 },
  heroName: {
    fontFamily: FONTS.title, fontSize: 26, color: COLORS.text,
  },
  heroRatingPill: {
    flexDirection: 'row', alignItems: 'center', gap: 4,
    backgroundColor: 'rgba(255,179,0,0.15)', borderRadius: 20,
    paddingHorizontal: 8, paddingVertical: 3,
  },
  heroRating: { fontFamily: FONTS.bodySemiBold, fontSize: 12, color: COLORS.gold },
  heroGenrePill: {
    backgroundColor: 'rgba(255,255,255,0.10)', borderRadius: 20,
    paddingHorizontal: 8, paddingVertical: 3,
  },
  heroGenreText: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2 },
  heroVerifiedBadge: {
    width: 20, height: 20, borderRadius: 10,
    backgroundColor: 'rgba(66,133,244,0.25)',
    borderWidth: 1, borderColor: 'rgba(66,133,244,0.5)',
    alignItems: 'center', justifyContent: 'center', flexShrink: 0,
  },
  heroTopBar: {
    position: 'absolute', top: 0, left: 0, right: 0,
    flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between',
    paddingHorizontal: SPACING.xl, paddingTop: 14,
  },
  heroIconBtn: {
    width: 38, height: 38, borderRadius: 12,
    backgroundColor: 'rgba(4,4,4,0.55)', borderWidth: 1, borderColor: 'rgba(255,255,255,0.10)',
    alignItems: 'center', justifyContent: 'center',
  },

  // ── BLOQUE 2: CONTROL ─────────────────────────────────────────────────────
  controlBlock: { marginHorizontal: SPACING.xl, marginTop: 16, gap: 10 },
  moneyCard: {
    flexDirection: 'row', alignItems: 'center',
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border, padding: 14,
  },
  moneyItem: { flex: 1, alignItems: 'center', gap: 2 },
  moneyLabel: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted, textTransform: 'uppercase', letterSpacing: 0.5 },
  moneyValue: { fontFamily: FONTS.bodySemiBold, fontSize: 16, color: COLORS.text },
  moneyDivider: { width: 1, height: 32, backgroundColor: COLORS.border, marginHorizontal: 8 },
  // 📈 Mi desempeño
  perfBtn: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1.5, borderColor: 'rgba(0,230,118,0.45)',
    padding: 13, gap: 3,
  },
  perfBtnTx:  { fontFamily: FONTS.bodySemiBold, fontSize: 14.5, color: COLORS.green },
  perfBtnSub: { fontFamily: FONTS.body, fontSize: 11.5, color: COLORS.muted2 },
  controlRow: { flexDirection: 'row', gap: 10 },
  controlToggle: {
    flex: 1, flexDirection: 'row', alignItems: 'center', gap: 10,
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border, padding: 14,
  },
  controlToggleActive: { borderColor: 'rgba(0,230,118,0.4)', backgroundColor: 'rgba(0,230,118,0.06)' },
  controlToggleDot: { width: 9, height: 9, borderRadius: 5, backgroundColor: COLORS.muted },
  controlToggleTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.muted2 },
  controlToggleSub: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted, marginTop: 1 },
  controlCalBtn: {
    flexDirection: 'row', alignItems: 'center', gap: 8,
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border, paddingHorizontal: 14, paddingVertical: 14,
  },
  controlCalText: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.text },

  // ── BLOQUE 3 / 4 / 5: SECCIÓN GENÉRICA ───────────────────────────────────
  sectionBlock: { marginHorizontal: SPACING.xl, marginTop: 24 },
  sectionTitle: {
    fontFamily: FONTS.bodySemiBold, fontSize: 11, color: COLORS.muted,
    textTransform: 'uppercase', letterSpacing: 0.8, marginBottom: 12,
  },

  // Ranking card
  rankCard: {
    flexDirection: 'row', alignItems: 'center',
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border,
    padding: 14, marginBottom: 10,
  },
  rankLeft: { flexDirection: 'row', alignItems: 'center', gap: 12, flex: 1 },
  rankNumber: { fontFamily: FONTS.title, fontSize: 36, color: COLORS.gold, minWidth: 52 },
  rankLabel: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.text },
  rankSub: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, marginTop: 2, lineHeight: 17 },
  rankBidBtn: {
    backgroundColor: COLORS.green, borderRadius: RADIUS.md,
    paddingHorizontal: 16, paddingVertical: 9,
  },
  rankBidText: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.bg },

  // Demand nudge near express toggle
  demandNudge: {
    marginTop: 8,
    backgroundColor: 'rgba(255,179,0,0.07)',
    borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: 'rgba(255,179,0,0.25)',
    paddingHorizontal: 12, paddingVertical: 8,
  },
  demandNudgeTx: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: '#FFB300', lineHeight: 17 },

  // Demand widget
  demandWidget: {
    flexDirection: 'row', alignItems: 'center', gap: 12,
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border,
    padding: 14, marginBottom: 10,
  },
  demandWidgetHigh: { borderColor: 'rgba(255,107,53,0.35)', backgroundColor: 'rgba(255,107,53,0.06)' },
  demandEmoji: { fontSize: 28 },
  demandTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.text },
  demandSub: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, marginTop: 2 },

  // Stats row
  statsRow: { flexDirection: 'row', gap: 8, marginTop: 4 },
  statPill: {
    flex: 1, alignItems: 'center', backgroundColor: COLORS.card,
    borderRadius: RADIUS.md, borderWidth: 1, borderColor: COLORS.border,
    paddingVertical: 12,
  },
  statPillNum: { fontFamily: FONTS.bodySemiBold, fontSize: 18, color: COLORS.text },
  statPillLabel: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted, marginTop: 2 },

  // Quotes block
  quotesBlock: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border,
    padding: 14, marginBottom: 10,
  },
  quotesBlockHeader: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', marginBottom: 10 },
  quotesBlockTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.text },
  quotesBlockLink: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.green },
  quoteRow: { flexDirection: 'row', alignItems: 'center', gap: 10, paddingVertical: 8, borderTopWidth: 1, borderTopColor: COLORS.border },
  quoteAvatar: {
    width: 36, height: 36, borderRadius: 18,
    backgroundColor: 'rgba(0,230,118,0.12)', alignItems: 'center', justifyContent: 'center',
  },
  quoteAvatarText: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.green },
  quoteRowName: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.text },
  quoteRowType: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted2, marginTop: 1 },

  // Team card
  teamCard: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border,
    padding: 14,
  },
  teamCardTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.text, marginBottom: 12 },
  teamCardHead:  { flexDirection: 'row', alignItems: 'center', gap: 8, marginBottom: 12 },
  teamChatBtn: {
    paddingHorizontal: 12, paddingVertical: 6, borderRadius: 999,
    backgroundColor: 'rgba(0,230,118,0.08)', borderWidth: 1, borderColor: 'rgba(0,230,118,0.35)',
  },
  teamChatBtnTx: { fontFamily: FONTS.bodySemiBold, fontSize: 11, color: COLORS.green },
  memberChatBadge: {
    position: 'absolute', top: -3, right: -3,
    width: 20, height: 20, borderRadius: 10, alignItems: 'center', justifyContent: 'center',
    backgroundColor: COLORS.card, borderWidth: 1, borderColor: 'rgba(0,230,118,0.45)',
  },
  teamDivider: { height: 1, backgroundColor: COLORS.border, marginVertical: 14 },

  // Member chips (horizontal scroll)
  memberChip: { alignItems: 'center', width: 68, marginRight: 10 },
  memberChipAvatar: { width: 48, height: 48, borderRadius: 24, marginBottom: 4 },
  memberChipAvatarEmpty: { backgroundColor: 'rgba(255,255,255,0.08)', alignItems: 'center', justifyContent: 'center' },
  memberChipAvatarAdd: { backgroundColor: 'rgba(0,230,118,0.10)', borderWidth: 1.5, borderColor: COLORS.green, borderStyle: 'dashed', alignItems: 'center', justifyContent: 'center' },
  memberChipInitial: { fontFamily: FONTS.bodySemiBold, fontSize: 18, color: COLORS.muted2 },
  memberChipName: { fontFamily: FONTS.bodyMedium, fontSize: 11, color: COLORS.text, textAlign: 'center' },
  memberChipRole: { fontFamily: FONTS.body, fontSize: 10, color: COLORS.muted, textAlign: 'center', marginTop: 1 },

  sentInvBtn: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between',
    marginTop: 12, paddingVertical: 11, paddingHorizontal: 14,
    backgroundColor: 'rgba(0,230,118,0.06)',
    borderRadius: RADIUS.md, borderWidth: 1, borderColor: 'rgba(0,230,118,0.25)',
  },
  sentInvBtnText: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.green },
  invBadge: {
    backgroundColor: COLORS.green, borderRadius: RADIUS.full,
    minWidth: 22, height: 22, alignItems: 'center', justifyContent: 'center',
    paddingHorizontal: 6,
  },
  invBadgeText: { fontFamily: FONTS.bodySemiBold, fontSize: 11, color: COLORS.bg },

  // Loyal clients chips
  loyalChip: { alignItems: 'center', width: 60, marginRight: 10, marginTop: 4 },
  loyalAvatar: { width: 38, height: 38, borderRadius: 19, marginBottom: 4 },
  loyalAvatarEmpty: { backgroundColor: 'rgba(255,255,255,0.08)', alignItems: 'center', justifyContent: 'center' },
  loyalInitial: { fontFamily: FONTS.bodySemiBold, fontSize: 16, color: COLORS.muted2 },
  loyalName: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted2, textAlign: 'center' },
  loyalCount: { fontFamily: FONTS.bodySemiBold, fontSize: 10, color: COLORS.green, textAlign: 'center' },

  // ── Banner express: solicitudes abiertas ─────────────────────────────────
  expressBanner: {
    flexDirection: 'row', alignItems: 'center', gap: 12,
    marginHorizontal: SPACING.xl, marginTop: 8, marginBottom: 4,
    backgroundColor: 'rgba(255,107,53,0.10)',
    borderRadius: RADIUS.lg, borderWidth: 1, borderColor: 'rgba(255,107,53,0.40)',
    paddingHorizontal: SPACING.lg, paddingVertical: 14,
  },
  expressBannerEmoji: { fontSize: 26 },
  expressBannerTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: '#FF6B35', marginBottom: 2 },
  expressBannerSub:   { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2 },
  scheduledBanner: {
    flexDirection: 'row', alignItems: 'center', gap: 12,
    marginHorizontal: SPACING.xl, marginTop: 8, marginBottom: 4,
    backgroundColor: 'rgba(0,230,118,0.08)',
    borderRadius: RADIUS.lg, borderWidth: 1, borderColor: 'rgba(0,230,118,0.40)',
    paddingHorizontal: SPACING.lg, paddingVertical: 14,
  },
  scheduledBannerTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.green, marginBottom: 2 },
  expressBtn: {
    flexDirection: 'row', alignItems: 'center', gap: 8,
    marginHorizontal: SPACING.xl, marginTop: 10,
    backgroundColor: COLORS.card2,
    borderRadius: RADIUS.md, borderWidth: 1, borderColor: COLORS.border,
    paddingHorizontal: SPACING.lg, paddingVertical: 11,
  },
  expressBtnActive: {
    borderColor: 'rgba(255,107,53,0.45)',
    backgroundColor: 'rgba(255,107,53,0.07)',
  },
  expressBtnText: {
    flex: 1, fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted2,
  },
  expressBtnBadge: {
    backgroundColor: '#FF6B35', borderRadius: 10,
    minWidth: 20, height: 20, alignItems: 'center', justifyContent: 'center',
    paddingHorizontal: 5,
  },
  expressBtnBadgeText: { fontFamily: FONTS.bodySemiBold, fontSize: 11, color: '#fff' },

  // ── Validación texto ──────────────────────────────────────────────────────────
  inputError: { borderColor: '#EF5350', borderWidth: 1.5 },
  errorText:  { fontFamily: FONTS.body, fontSize: 12, color: '#EF5350', marginTop: -10, marginBottom: 12 },

  // ── Mi Equipo (modal edit) ────────────────────────────────────────────────────
  equipSectionTitle: {
    fontFamily: FONTS.bodySemiBold, fontSize: 12, color: COLORS.muted2,
    textTransform: 'uppercase', letterSpacing: 0.6,
    marginTop: 24, marginBottom: 14,
    paddingTop: 16, borderTopWidth: 1, borderTopColor: COLORS.border,
  },
  equipRow:          { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', marginBottom: 10 },
  equipLabel:        { fontFamily: FONTS.bodyMedium, fontSize: 14, color: COLORS.text, flex: 1 },
  equipToggle:       { paddingHorizontal: 16, paddingVertical: 8, borderRadius: RADIUS.full, backgroundColor: COLORS.bg, borderWidth: 1, borderColor: COLORS.border },
  equipToggleOn:     { backgroundColor: 'rgba(0,230,118,0.12)', borderColor: COLORS.green },
  equipToggleText:   { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.muted2 },
  equipToggleTextOn: { color: COLORS.green },
  equipChipRow:      { flexDirection: 'row', flexWrap: 'wrap', gap: 8, marginBottom: 14 },
  equipChip:         { paddingHorizontal: 12, paddingVertical: 8, borderRadius: RADIUS.full, backgroundColor: COLORS.bg, borderWidth: 1, borderColor: COLORS.border },
  equipChipActive:   { backgroundColor: 'rgba(0,230,118,0.12)', borderColor: COLORS.green },
  equipChipText:     { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted2 },
  equipChipTextActive: { color: COLORS.green },
});
