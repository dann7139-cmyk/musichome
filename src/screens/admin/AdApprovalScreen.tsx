import VideoPlayer from '../../components/ui/VideoPlayer';
import { LinearGradient } from 'expo-linear-gradient';
import { AlertCircle, Check, Clock, Eye, Pause, Play, Trash2, X } from 'lucide-react-native';
import React, { useEffect, useMemo, useRef, useState } from 'react';
import {
  ActivityIndicator,
  Alert,
  Image,
  Modal,
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

const STATUS_TABS = [
  { key: 'all',            label: 'Todos',      color: '#94A3B8' },
  { key: 'active',         label: 'Activos',    color: COLORS.green },
  { key: 'pending_review', label: 'Pendientes', color: '#F59E0B' },
  { key: 'paused',         label: 'Pausados',   color: COLORS.muted2 },
  { key: 'rejected',       label: 'Rechazados', color: '#EF4444' },
  { key: 'expired',        label: 'Expirados',  color: '#6B7280' },
] as const;

const TYPE_LABELS: Record<string, string> = {
  banner_home:       'Banner Home',
  sponsored_group:   'Grupo Destacado',
  profile_ad:        'Anuncio en Perfil',
  bid_order:         'Bidding',
  recommendation_ad: 'Recomendado',
};

const TYPE_COLORS: Record<string, string> = {
  banner_home:       '#00E676',
  sponsored_group:   '#C9A84C',
  profile_ad:        '#4285F4',
  bid_order:         '#A78BFA',
  recommendation_ad: '#FF6D00',
};

const TYPE_FILTERS = [
  { key: null,                label: 'Todos' },
  { key: 'banner_home',       label: '📢 Banner' },
  { key: 'sponsored_group',   label: '⭐ Destacado' },
  { key: 'profile_ad',        label: '👤 Perfil' },
  { key: 'bid_order',         label: '⬆️ Bidding' },
  { key: 'recommendation_ad', label: '🔥 Reco.' },
];

// ── Tipos para el modal de creación ─────────────────────────────────────────
const IMAGE_AD_TYPES = [
  { key: 'banner_home', label: 'Banner', icon: '📢', color: '#00E676' },
  { key: 'profile_ad',  label: 'Perfil', icon: '👤', color: '#4285F4' },
];

const GROUP_PROMO_TYPES = [
  { key: 'sponsored'      as const, label: 'Destacado',   icon: '⭐', color: '#C9A84C' },
  { key: 'recommendation' as const, label: 'Recomendado', icon: '🔥', color: '#FF6D00' },
  { key: 'bidding'        as const, label: 'Bidding',      icon: '⬆️', color: '#A78BFA' },
];

// Colores por tipo para los botones de la pestaña Grupos
const GROUP_ACT_COLORS: Record<string, string> = {
  sponsored:      '#C9A84C',
  recommendation: '#FF6D00',
  bidding:        '#A78BFA',
};

const FREE_DURATIONS = [
  { days: 7,  label: '7 días' },
  { days: 30, label: '30 días' },
  { days: 60, label: '60 días' },
  { days: 0,  label: 'Sin límite' },
];

function isExpired(ad: any) {
  return ad.ends_at && new Date(ad.ends_at).getTime() < Date.now();
}

function calcMonetizationScore(ad: any): number {
  const amount     = Number(ad.budget ?? ad.amount ?? 0);
  const days       = Number(ad.duration_days ?? 1);
  const isRecent   = ad.created_at && new Date(ad.created_at).getTime() > Date.now() - 2 * 86400000;
  const nearExpiry = ad.ends_at && new Date(ad.ends_at).getTime() < Date.now() + 86400000;
  return amount + (days * 10) + (isRecent ? 50 : 0) - (nearExpiry ? 30 : 0);
}

function sortAds(list: any[], tabKey: string) {
  return [...list].sort((a, b) => {
    if (tabKey === 'active')         return calcMonetizationScore(b) - calcMonetizationScore(a);
    if (tabKey === 'pending_review') return new Date(a.created_at ?? 0).getTime() - new Date(b.created_at ?? 0).getTime();
    if (tabKey === 'expired')        return new Date(b.ends_at ?? 0).getTime() - new Date(a.ends_at ?? 0).getTime();
    if (tabKey === 'all') {
      const order: Record<string, number> = { active: 0, pending_review: 1, paused: 2, rejected: 3, expired: 4 };
      const aOrd = order[a.status] ?? 5;
      const bOrd = order[b.status] ?? 5;
      if (aOrd !== bOrd) return aOrd - bOrd;
      return new Date(b.created_at ?? 0).getTime() - new Date(a.created_at ?? 0).getTime();
    }
    return 0;
  });
}

export default function AdApprovalScreen({ navigation }: any) {
  const [ads, setAds]               = useState<any[]>([]);
  const [tab, setTab]               = useState<string>('all');
  const [typeFilter, setTypeFilter] = useState<string | null>(null);
  const [loading, setLoading]       = useState(true);
  const [refreshing, setRefreshing] = useState(false);
  const [rejectModal, setRejectModal] = useState<{ id: string; title: string } | null>(null);
  const [rejectReason, setRejectReason] = useState('');
  const [preview, setPreview]       = useState<any | null>(null);
  const [walletIncome, setWalletIncome] = useState({ ad: 0, bid: 0, rec: 0, total: 0 });

  // ── Vista "Grupos" ──────────────────────────────────────────────────────────
  const [viewMode, setViewMode]         = useState<'ads' | 'groups'>('ads');
  const [groups, setGroups]             = useState<any[]>([]);
  const [groupsLoading, setGroupsLoading] = useState(false);
  const [activating, setActivating]     = useState<string | null>(null);

  // ── Modal "Crear anuncio gratis" ────────────────────────────────────────────
  const [createModal, setCreateModal]   = useState(false);
  const [freeSegment, setFreeSegment]   = useState<0 | 1>(0); // 0=imagen, 1=grupo
  // Campos imagen
  const [freeType, setFreeType]         = useState('banner_home');
  const [freeTitle, setFreeTitle]       = useState('');
  const [freeSub, setFreeSub]           = useState('');
  const [freeBtnText, setFreeBtnText]   = useState('Ver más');
  const [freeImageUrl, setFreeImageUrl] = useState('');
  const [freeState, setFreeState]       = useState('');
  // Campos grupo
  const [freeGroupPromoType, setFreeGroupPromoType] = useState<'sponsored' | 'recommendation' | 'bidding'>('sponsored');
  const [freeGroupId, setFreeGroupId]   = useState<string | null>(null);
  const [freeGroupSearch, setFreeGroupSearch] = useState('');
  const [freeGroupSearchDisplay, setFreeGroupSearchDisplay] = useState('');
  const [searchLoading, setSearchLoading] = useState(false);
  const searchTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const [freeBidAmount, setFreeBidAmount] = useState(100);
  // Duración compartida
  const [freeDays, setFreeDays]         = useState(30);
  const [freeCreating, setFreeCreating] = useState(false);

  // ── Mini-modal de activación desde pestaña Grupos ──────────────────────────
  const [activateModal, setActivateModal] = useState<{
    groupId: string;
    groupName: string;
    type: 'sponsored' | 'recommendation' | 'bidding';
  } | null>(null);
  const [activateDays, setActivateDays]         = useState(30);
  const [activateBidAmount, setActivateBidAmount] = useState(100);
  const [activateLoading, setActivateLoading]   = useState(false);

  useEffect(() => { fetchAds(); }, []);
  useEffect(() => {
    const unsub = navigation.addListener('focus', fetchAds);
    return unsub;
  }, [navigation]);
  useEffect(() => { if (viewMode === 'groups') fetchGroups(); }, [viewMode]);

  const fetchAds = async () => {
    setLoading(true);
    const now = new Date();

    const [adsRes, bidsRes, recRes, sponRes, txRes] = await Promise.all([
      supabase.from('advertisements').select('*').order('created_at', { ascending: false }),
      supabase.from('bid_orders')
        .select('id, group_id, amount, duration_days, status, starts_at, ends_at, created_at, group:groups(name, city)')
        .order('created_at', { ascending: false }),
      supabase.from('recommendation_orders')
        .select('id, group_id, amount, duration_days, status, stripe_payment_id, starts_at, ends_at, city, created_at, group:groups(name)')
        .order('created_at', { ascending: false }),
      supabase.from('sponsored_groups')
        .select('id, group_id, advertiser_id, starts_at, ends_at, is_active, created_at, group:groups(name, city)')
        .order('created_at', { ascending: false }),
      supabase.from('wallet_transactions')
        .select('type, amount, status')
        .in('type', ['ad_income', 'bid_income', 'recommendation_income'])
        .eq('status', 'completed'),
    ]);

    const txList = txRes.data ?? [];
    const adInc  = txList.filter(t => t.type === 'ad_income').reduce((s, t) => s + Number(t.amount), 0);
    const bidInc = txList.filter(t => t.type === 'bid_income').reduce((s, t) => s + Number(t.amount), 0);
    const recInc = txList.filter(t => t.type === 'recommendation_income').reduce((s, t) => s + Number(t.amount), 0);
    setWalletIncome({ ad: adInc, bid: bidInc, rec: recInc, total: adInc + bidInc + recInc });

    const normalizedBids = (bidsRes.data ?? []).map((b: any) => {
      const expired = b.ends_at && new Date(b.ends_at) <= now;
      const status  = b.status === 'paid' && !expired ? 'active'
                    : b.status === 'paid' && expired  ? 'expired'
                    : b.status === 'expired'           ? 'expired'
                    : 'pending_review';
      return {
        id: b.id, type: 'bid_order',
        title: (b.group as any)?.name ?? 'Grupo',
        subtitle: `Posicionamiento · ${b.duration_days ?? 1}d`,
        status, budget: b.amount, ends_at: b.ends_at, starts_at: b.starts_at,
        created_at: b.created_at, group_name: (b.group as any)?.name,
        advertiser_name: (b.group as any)?.name, city: (b.group as any)?.city, _source: 'bid',
      };
    });

    const normalizedRecs = (recRes.data ?? []).map((r: any) => {
      const expired = r.ends_at && new Date(r.ends_at) <= now;
      const status  = r.status === 'paid' && !expired ? 'active'
                    : r.status === 'paid' && expired  ? 'expired'
                    : r.status === 'expired'           ? 'expired'
                    : r.status === 'cancelled'         ? 'rejected'
                    : 'pending_review';
      return {
        id: r.id, type: 'recommendation_ad',
        title: (r.group as any)?.name ?? 'Grupo',
        subtitle: `Aparecer como recomendado · ${r.duration_days}d`,
        status, budget: r.amount, ends_at: r.ends_at, starts_at: r.starts_at,
        created_at: r.created_at, group_name: (r.group as any)?.name,
        advertiser_name: (r.group as any)?.name, city: r.city, _source: 'rec',
      };
    });

    const coveredByAd = new Set(
      (adsRes.data ?? [])
        .filter((a: any) => a.type === 'sponsored_group' && a.link_id)
        .map((a: any) => a.link_id as string)
    );

    const normalizedSponsored = (sponRes.data ?? [])
      .filter((s: any) => !coveredByAd.has(s.group_id))
      .map((s: any) => {
        const expired = s.ends_at && new Date(s.ends_at) <= now;
        const status  = s.is_active && !expired ? 'active' : 'expired';
        return {
          id: s.id, type: 'sponsored_group',
          title: (s.group as any)?.name ?? 'Grupo',
          subtitle: 'Grupo destacado (directo)',
          status, budget: null, ends_at: s.ends_at, starts_at: s.starts_at,
          created_at: s.created_at, group_name: (s.group as any)?.name,
          advertiser_name: (s.group as any)?.name, city: (s.group as any)?.city, _source: 'sponsored',
        };
      });

    const all = [
      ...(adsRes.data ?? []),
      ...normalizedBids,
      ...normalizedRecs,
      ...normalizedSponsored,
    ].sort((a, b) => new Date(b.created_at).getTime() - new Date(a.created_at).getTime());

    setAds(all);
    setLoading(false);
    setRefreshing(false);
  };

  const stats = useMemo(() => {
    const active = ads.filter(a => a.status === 'active');
    const totalImpressions = active.reduce((s, a) => s + (a.impressions ?? 0), 0);
    const totalClicks      = active.reduce((s, a) => s + (a.clicks ?? 0), 0);
    const avgCtr = totalImpressions > 0
      ? ((totalClicks / totalImpressions) * 100).toFixed(1) : '0.0';
    return { activeCount: active.length, totalImpressions, avgCtr };
  }, [ads]);

  const tabCount = (key: string) => {
    if (key === 'all')     return ads.length;
    if (key === 'expired') return ads.filter(a => isExpired(a) && a.status !== 'rejected').length;
    return ads.filter(a => a.status === key && !isExpired(a)).length;
  };

  const filtered = useMemo(() => {
    let list: any[];
    if (tab === 'all')          list = [...ads];
    else if (tab === 'expired') list = ads.filter(a => isExpired(a) && a.status !== 'rejected');
    else                        list = ads.filter(a => a.status === tab && !isExpired(a));
    if (typeFilter) list = list.filter(a => a.type === typeFilter);
    return sortAds(list, tab);
  }, [ads, tab, typeFilter]);

  // ── Actions ────────────────────────────────────────────────────────────────
  const handleApprove = async (id: string, title: string) => {
    Alert.alert('Aprobar anuncio', `¿Aprobar "${title}"?`, [
      { text: 'Cancelar', style: 'cancel' },
      {
        text: 'Aprobar', style: 'default',
        onPress: async () => {
          const { data, error } = await supabase.rpc('approve_ad', { p_id: id, p_duration_days: null });
          if (error) { Alert.alert('Error', error.message); return; }
          if (data?.ok === false) {
            const msg = data.error === 'limit_reached'
              ? `Límite alcanzado: ya hay ${data.count} anuncios activos de tipo "${data.type}" (máx ${data.limit}).`
              : (data.error ?? 'No se pudo aprobar');
            Alert.alert('No se puede aprobar', msg);
            return;
          }
          fetchAds();
        },
      },
    ]);
  };

  const handleReject = async () => {
    if (!rejectModal) return;
    const { error } = await supabase.rpc('reject_ad', {
      p_id: rejectModal.id, p_reason: rejectReason.trim() || null,
    });
    if (error) { Alert.alert('Error', error.message); return; }
    setRejectModal(null);
    setRejectReason('');
    fetchAds();
  };

  const handleToggle = async (id: string, title: string, status: string) => {
    const action = status === 'active' ? 'pausar' : 'reactivar';
    Alert.alert(`¿${action} anuncio?`, title, [
      { text: 'Cancelar', style: 'cancel' },
      {
        text: action.charAt(0).toUpperCase() + action.slice(1), style: 'default',
        onPress: async () => {
          const { error } = await supabase.rpc('toggle_ad', { p_id: id });
          if (error) { Alert.alert('Error', error.message); return; }
          fetchAds();
        },
      },
    ]);
  };

  const handleDelete = (id: string, title: string) => {
    Alert.alert(
      'Eliminar anuncio',
      `¿Eliminar permanentemente "${title}"?`,
      [
        { text: 'Cancelar', style: 'cancel' },
        {
          text: 'Eliminar', style: 'destructive',
          onPress: async () => {
            const { data, error } = await supabase.rpc('delete_ad', { p_id: id });
            if (error) { Alert.alert('Error', error.message); return; }
            if (data?.ok === false) { Alert.alert('Error', data.error ?? 'No se pudo eliminar'); return; }
            fetchAds();
          },
        },
      ]
    );
  };

  // ── Crear anuncio gratis ───────────────────────────────────────────────────
  const resetCreateForm = () => {
    setFreeTitle(''); setFreeSub(''); setFreeBtnText('Ver más');
    setFreeImageUrl(''); setFreeState(''); setFreeDays(30);
    setFreeType('banner_home'); setFreeSegment(0);
    setFreeGroupId(null); setFreeGroupSearch(''); setFreeGroupSearchDisplay('');
    setFreeGroupPromoType('sponsored'); setFreeBidAmount(100);
    setSearchLoading(false);
    if (searchTimer.current) clearTimeout(searchTimer.current);
  };

  // Buscador con debounce 300ms para no filtrar en cada tecla
  const handleGroupSearch = (text: string) => {
    setFreeGroupSearchDisplay(text);
    setSearchLoading(true);
    if (searchTimer.current) clearTimeout(searchTimer.current);
    searchTimer.current = setTimeout(() => {
      setFreeGroupSearch(text);
      setSearchLoading(false);
    }, 300);
  };

  const openCreateModal = () => {
    setCreateModal(true);
    if (groups.length === 0) fetchGroups();
  };

  const handleCreateFreeAd = async () => {
    setFreeCreating(true);
    try {
      if (freeSegment === 0) {
        // Anuncio de imagen
        if (!freeTitle.trim()) {
          Alert.alert('Título requerido', 'Escribe un título para el anuncio.');
          return;
        }
        const { data, error } = await supabase.rpc('create_free_ad', {
          p_type:          freeType,
          p_title:         freeTitle.trim(),
          p_subtitle:      freeSub.trim() || null,
          p_button_text:   freeBtnText.trim() || 'Ver más',
          p_media_url:     freeImageUrl.trim() || null,
          p_media_type:    freeImageUrl.trim() ? 'image' : null,
          p_target_state:  freeState.trim() || null,
          p_duration_days: freeDays > 0 ? freeDays : null,
        });
        if (error || data?.ok === false) {
          Alert.alert('Error', error?.message ?? data?.error ?? 'No se pudo crear');
          return;
        }
      } else {
        // Promoción de grupo
        if (!freeGroupId) {
          Alert.alert('Grupo requerido', 'Selecciona un grupo para promocionar.');
          return;
        }
        const rpc = freeGroupPromoType === 'sponsored'      ? 'admin_activate_sponsored'
                  : freeGroupPromoType === 'recommendation' ? 'admin_activate_recommendation'
                  :                                           'admin_activate_bidding';
        const params: any = { p_group_id: freeGroupId, p_days: freeDays > 0 ? freeDays : 30 };
        if (freeGroupPromoType === 'bidding') params.p_bid_amount = freeBidAmount;
        const { data, error } = await supabase.rpc(rpc, params);
        if (error || data?.ok === false) {
          Alert.alert('Error', error?.message ?? data?.error ?? 'No se pudo activar');
          return;
        }
      }
      setCreateModal(false);
      resetCreateForm();
      fetchAds();
      if (viewMode === 'groups') fetchGroups();
    } finally {
      setFreeCreating(false);
    }
  };

  // ── Fetch grupos ───────────────────────────────────────────────────────────
  const fetchGroups = async () => {
    setGroupsLoading(true);
    const now = new Date().toISOString();
    const [grpRes, sponRes, recRes, bidRes] = await Promise.all([
      supabase.from('groups').select('id, name, city, state').eq('is_active', true).order('name'),
      supabase.from('sponsored_groups').select('group_id, ends_at').eq('is_active', true),
      supabase.from('recommendation_orders').select('group_id, ends_at').eq('status', 'paid').or(`ends_at.is.null,ends_at.gt.${now}`),
      supabase.from('bid_orders').select('group_id, ends_at').eq('status', 'paid').or(`ends_at.is.null,ends_at.gt.${now}`),
    ]);
    const sponMap = new Map((sponRes.data ?? []).map((s: any) => [s.group_id, s.ends_at]));
    const recMap  = new Map((recRes.data ?? []).map((r: any) => [r.group_id, r.ends_at]));
    const bidMap  = new Map((bidRes.data ?? []).map((b: any) => [b.group_id, b.ends_at]));
    setGroups((grpRes.data ?? []).map((g: any) => ({
      ...g,
      sponsored: sponMap.has(g.id),   sponsoredEndsAt: sponMap.get(g.id) ?? null,
      recommended: recMap.has(g.id),  recommendedEndsAt: recMap.get(g.id) ?? null,
      bidding: bidMap.has(g.id),      biddingEndsAt: bidMap.get(g.id) ?? null,
    })));
    setGroupsLoading(false);
  };

  // ── Activar/desactivar grupo (desde pestaña Grupos) ───────────────────────
  const handleActivate = (
    groupId: string, groupName: string,
    type: 'sponsored' | 'recommendation' | 'bidding',
    isActive: boolean,
  ) => {
    if (isActive) {
      const typeLabel = type === 'sponsored' ? 'Destacado' : type === 'recommendation' ? 'Recomendado' : 'Bidding';
      Alert.alert(`Desactivar ${typeLabel}`, `¿Desactivar para "${groupName}"?`, [
        { text: 'Cancelar', style: 'cancel' },
        {
          text: 'Desactivar', style: 'destructive',
          onPress: async () => {
            setActivating(`${groupId}_${type}`);
            try {
              const { data, error } = await supabase.rpc('admin_deactivate_group', {
                p_group_id: groupId, p_type: type,
              });
              if (error || data?.ok === false) {
                Alert.alert('Error', error?.message ?? data?.error ?? 'No se pudo desactivar');
                return;
              }
              await fetchGroups();
            } finally {
              setActivating(null);
            }
          },
        },
      ]);
    } else {
      setActivateModal({ groupId, groupName, type });
      setActivateDays(30);
      setActivateBidAmount(100);
    }
  };

  const handleActivateConfirm = async () => {
    if (!activateModal) return;
    const { groupId, type } = activateModal;
    setActivateLoading(true);
    try {
      const rpc = type === 'sponsored'      ? 'admin_activate_sponsored'
                : type === 'recommendation' ? 'admin_activate_recommendation'
                :                             'admin_activate_bidding';
      const params: any = { p_group_id: groupId, p_days: activateDays };
      if (type === 'bidding') params.p_bid_amount = activateBidAmount;
      const { data, error } = await supabase.rpc(rpc, params);
      if (error || data?.ok === false) {
        Alert.alert('Error', error?.message ?? data?.error ?? 'No se pudo activar');
        return;
      }

      // Optimistic update: enciende el botón inmediatamente sin esperar fetchGroups
      const optimisticEndsAt = activateDays > 0
        ? new Date(Date.now() + activateDays * 86_400_000).toISOString()
        : null;
      setGroups(prev => prev.map(g => {
        if (g.id !== groupId) return g;
        if (type === 'sponsored')      return { ...g, sponsored: true,   sponsoredEndsAt:   optimisticEndsAt };
        if (type === 'recommendation') return { ...g, recommended: true, recommendedEndsAt: optimisticEndsAt };
        return                                { ...g, bidding: true,     biddingEndsAt:     optimisticEndsAt };
      }));

      setActivateModal(null);
      // Fetch real en background para sincronizar con la BD
      fetchGroups();
    } finally {
      setActivateLoading(false);
      setActivating(null);
    }
  };

  // ── Helpers ────────────────────────────────────────────────────────────────
  const daysLeft = (endsAt: string | null) => {
    if (!endsAt) return null;
    return Math.ceil((new Date(endsAt).getTime() - Date.now()) / 86400000);
  };

  const daysColor = (days: number | null) => {
    if (days === null) return COLORS.muted2;
    if (days <= 0)  return '#EF4444';
    if (days <= 7)  return '#F59E0B';
    return COLORS.green;
  };

  const calcCtr = (impressions: number, clicks: number) => {
    if (!impressions) return null;
    return ((clicks / impressions) * 100).toFixed(1);
  };

  // Grupos filtrados para el buscador del modal
  const modalFilteredGroups = groups
    .filter(g => !freeGroupSearch || g.name.toLowerCase().includes(freeGroupSearch.toLowerCase()))
    .slice(0, 8);

  // ── Render ─────────────────────────────────────────────────────────────────
  return (
    <SafeAreaView style={s.container}>
      {/* Header */}
      <View style={s.header}>
        <Pressable style={s.backBtn} onPress={() => navigation.goBack()}>
          <Text style={s.backBtnText}>← Volver</Text>
        </Pressable>
        <View style={s.viewToggle}>
          <Pressable
            style={[s.viewToggleBtn, viewMode === 'ads' && s.viewToggleBtnActive]}
            onPress={() => setViewMode('ads')}
          >
            <Text style={[s.viewToggleBtnText, viewMode === 'ads' && s.viewToggleBtnTextActive]}>Anuncios</Text>
          </Pressable>
          <Pressable
            style={[s.viewToggleBtn, viewMode === 'groups' && s.viewToggleBtnActive]}
            onPress={() => setViewMode('groups')}
          >
            <Text style={[s.viewToggleBtnText, viewMode === 'groups' && s.viewToggleBtnTextActive]}>Grupos</Text>
          </Pressable>
        </View>
        <Pressable style={s.createFreeBtn} onPress={openCreateModal}>
          <Text style={s.createFreeBtnText}>+ Gratis</Text>
        </Pressable>
      </View>

      {/* ── VISTA: ANUNCIOS ─────────────────────────────────────────────────── */}
      {viewMode === 'ads' && (<>
        <View style={s.statsRow}>
          <View style={[s.statCard, s.statCardGreen]}>
            <Text style={s.statVal}>{stats.activeCount}</Text>
            <Text style={s.statLabel}>Activos</Text>
          </View>
          <View style={[s.statCard, s.statCardGold]}>
            <Text style={[s.statVal, s.statValGold]}>
              ${walletIncome.total > 0 ? walletIncome.total.toLocaleString() : '—'}
            </Text>
            <Text style={s.statLabel}>Ingresos</Text>
          </View>
          <View style={s.statCard}>
            <Text style={s.statVal}>{stats.totalImpressions.toLocaleString()}</Text>
            <Text style={s.statLabel}>Impresiones</Text>
          </View>
          <View style={s.statCard}>
            <Text style={s.statVal}>{stats.avgCtr}%</Text>
            <Text style={s.statLabel}>CTR</Text>
          </View>
        </View>

        {walletIncome.total > 0 && (
          <View style={s.incomeRow}>
            {walletIncome.ad > 0 && (
              <View style={s.incomeChip}>
                <Text style={s.incomeChipText}>📢 ${walletIncome.ad.toLocaleString()}</Text>
              </View>
            )}
            {walletIncome.bid > 0 && (
              <View style={[s.incomeChip, s.incomeChipBid]}>
                <Text style={[s.incomeChipText, s.incomeChipTextBid]}>⬆️ ${walletIncome.bid.toLocaleString()}</Text>
              </View>
            )}
            {walletIncome.rec > 0 && (
              <View style={[s.incomeChip, s.incomeChipRec]}>
                <Text style={[s.incomeChipText, s.incomeChipTextRec]}>🔥 ${walletIncome.rec.toLocaleString()}</Text>
              </View>
            )}
          </View>
        )}

        <ScrollView horizontal showsHorizontalScrollIndicator={false} style={s.tabsScroll} contentContainerStyle={s.tabs}>
          {STATUS_TABS.map(t => {
            const count = tabCount(t.key);
            return (
              <Pressable
                key={t.key}
                style={[s.tab, tab === t.key && { borderColor: t.color, backgroundColor: `${t.color}18` }]}
                onPress={() => setTab(t.key)}
              >
                <Text style={[s.tabText, tab === t.key && { color: t.color }]}>{t.label}</Text>
                {count > 0 && (
                  <View style={[s.tabBadge, { backgroundColor: t.color }]}>
                    <Text style={s.tabBadgeText}>{count}</Text>
                  </View>
                )}
              </Pressable>
            );
          })}
        </ScrollView>

        <ScrollView horizontal showsHorizontalScrollIndicator={false} style={s.filterScroll} contentContainerStyle={s.filters}>
          {TYPE_FILTERS.map(f => (
            <Pressable
              key={String(f.key)}
              style={[s.filterChip, typeFilter === f.key && s.filterChipActive]}
              onPress={() => setTypeFilter(f.key)}
            >
              <Text style={[s.filterChipText, typeFilter === f.key && s.filterChipTextActive]}>{f.label}</Text>
            </Pressable>
          ))}
        </ScrollView>

        <ScrollView
          style={{ flex: 1 }}
          contentContainerStyle={{ padding: SPACING.xl, paddingBottom: 40 }}
          refreshControl={<RefreshControl refreshing={refreshing} onRefresh={() => { setRefreshing(true); fetchAds(); }} tintColor={COLORS.green} />}
        >
          {loading ? (
            <ActivityIndicator color={COLORS.green} style={{ marginTop: 60 }} />
          ) : filtered.length === 0 ? (
            <View style={s.empty}>
              <AlertCircle size={40} color={COLORS.muted} />
              <Text style={s.emptyText}>Sin anuncios en esta categoría</Text>
            </View>
          ) : (
            filtered.map((ad, idx) => {
              const days            = daysLeft(ad.ends_at);
              const effectiveStatus = tab === 'all'
                ? (isExpired(ad) && ad.status !== 'rejected' ? 'expired' : ad.status)
                : tab;
              const tabCfg     = STATUS_TABS.find(t => t.key === effectiveStatus) ?? STATUS_TABS[0];
              const ctrVal     = calcCtr(ad.impressions ?? 0, ad.clicks ?? 0);
              const advertiser = ad.advertiser_name ?? ad.advertiser_email ?? '—';
              const budget     = ad.budget ?? ad.total_budget ?? null;
              const hasMetrics = (ad.impressions ?? 0) > 0 || (ad.clicks ?? 0) > 0;
              const isTopActive = (tab === 'active' || tab === 'all') && idx === 0 && effectiveStatus === 'active';

              return (
                <View key={ad.id} style={[s.card, effectiveStatus === 'active' && s.cardActive]}>
                  {isTopActive && (
                    <View style={s.topBadge}>
                      <Text style={s.topBadgeText}>🔥 Más alto pago</Text>
                    </View>
                  )}
                  {ad.media_url && ad.media_type === 'image' ? (
                    <Image source={{ uri: ad.media_url }} style={s.cardMedia} resizeMode="cover" />
                  ) : ad.media_url && ad.media_type === 'video' ? (
                    <Pressable style={s.cardMediaVideo} onPress={() => setPreview(ad)}>
                      <LinearGradient
                        colors={['rgba(0,0,0,0.55)', 'rgba(0,0,0,0.25)']}
                        style={StyleSheet.absoluteFill}
                        start={{ x: 0, y: 0 }} end={{ x: 1, y: 1 }}
                      />
                      <Play size={26} color="#fff" fill="rgba(255,255,255,0.9)" />
                      <Text style={s.cardMediaVideoText}>Reproducir video</Text>
                    </Pressable>
                  ) : (
                    <LinearGradient
                      colors={['rgba(0,230,118,0.10)', 'rgba(0,0,0,0)']}
                      style={s.cardMediaPlaceholder}
                      start={{ x: 0, y: 0 }} end={{ x: 1, y: 1 }}
                    >
                      <Text style={{ fontSize: 28 }}>📢</Text>
                    </LinearGradient>
                  )}

                  <View style={s.cardBody}>
                    <View style={s.cardTopRow}>
                      {(() => {
                        const tc = TYPE_COLORS[ad.type] ?? COLORS.green;
                        return (
                          <View style={[s.typeBadge, { backgroundColor: tc + '20', borderColor: tc + '55' }]}>
                            <Text style={[s.typeBadgeText, { color: tc }]}>{TYPE_LABELS[ad.type] ?? ad.type}</Text>
                          </View>
                        );
                      })()}
                      {ad.is_free && (
                        <View style={s.freeBadge}>
                          <Text style={s.freeBadgeText}>GRATIS</Text>
                        </View>
                      )}
                      <View style={[s.statusBadge, { backgroundColor: `${tabCfg.color}22`, borderColor: `${tabCfg.color}55` }]}>
                        <Text style={[s.statusBadgeText, { color: tabCfg.color }]}>{tabCfg.label}</Text>
                      </View>
                      {days !== null && (
                        <View style={[s.daysPill, { borderColor: daysColor(days) + '55', backgroundColor: daysColor(days) + '18' }]}>
                          <Clock size={10} color={daysColor(days)} />
                          <Text style={[s.daysPillText, { color: daysColor(days) }]}>
                            {days <= 0 ? 'Expirado' : `${days}d`}
                          </Text>
                        </View>
                      )}
                    </View>

                    <Text style={s.cardTitle} numberOfLines={1}>{ad.title}</Text>
                    {ad.subtitle && <Text style={s.cardSub} numberOfLines={1}>{ad.subtitle}</Text>}

                    <View style={s.metaRow}>
                      <Text style={s.metaItem}>👤 {advertiser}</Text>
                      {ad.package_name && <Text style={s.metaItem}>📦 {ad.package_name}</Text>}
                    </View>

                    {budget && !ad.is_free ? (
                      <View style={s.incomeBar}>
                        <Text style={s.incomeBarIcon}>
                          {ad.type === 'bid_order' ? '⬆️' : ad.type === 'recommendation_ad' ? '🔥' : '📢'}
                        </Text>
                        <Text style={s.incomeBarLabel}>Ingreso:</Text>
                        <Text style={s.incomeBarAmount}>${Number(budget).toLocaleString()}</Text>
                        <View style={s.incomeBarPill}>
                          <Text style={s.incomeBarPillText}>
                            {ad.status === 'active' ? '✓ En billetera' : 'Pendiente pago'}
                          </Text>
                        </View>
                      </View>
                    ) : null}

                    {(ad.starts_at || ad.ends_at) && (
                      <Text style={s.dateText}>
                        📅 {ad.starts_at ? new Date(ad.starts_at).toLocaleDateString('es', { day: '2-digit', month: 'short' }) : '—'}
                        {' → '}
                        {ad.ends_at ? new Date(ad.ends_at).toLocaleDateString('es', { day: '2-digit', month: 'short', year: '2-digit' }) : '∞'}
                      </Text>
                    )}

                    {ad.rejection_reason && (
                      <View style={s.rejectionBox}>
                        <Text style={s.rejectionText}>❌ {ad.rejection_reason}</Text>
                      </View>
                    )}

                    {hasMetrics && (
                      <View style={s.metricsRow}>
                        <View style={s.metricChip}>
                          <Eye size={12} color={COLORS.muted2} />
                          <Text style={s.metricText}>{(ad.impressions ?? 0).toLocaleString()}</Text>
                        </View>
                        <View style={s.metricChip}>
                          <Text style={s.metricText}>🖱 {(ad.clicks ?? 0).toLocaleString()}</Text>
                        </View>
                        {ctrVal !== null && (
                          <View style={[s.metricChip, s.metricCtr]}>
                            <Text style={[s.metricText, { color: COLORS.green }]}>CTR {ctrVal}%</Text>
                          </View>
                        )}
                      </View>
                    )}

                    {(ad._source === 'bid' || ad._source === 'rec') && effectiveStatus === 'pending_review' && (
                      <View style={s.autoActivateNote}>
                        <Text style={s.autoActivateNoteText}>
                          ⚡ Se activa automáticamente al confirmar el pago
                        </Text>
                      </View>
                    )}

                    <View style={s.actions}>
                      <Pressable style={s.actionBtn} onPress={() => setPreview(ad)}>
                        <Eye size={14} color={COLORS.muted2} />
                        <Text style={s.actionBtnText}>Ver</Text>
                      </Pressable>
                      {!ad._source && !ad.is_free && effectiveStatus === 'pending_review' && (
                        <>
                          <Pressable style={[s.actionBtn, s.actionApprove]} onPress={() => handleApprove(ad.id, ad.title)}>
                            <Check size={14} color="#000" />
                            <Text style={[s.actionBtnText, { color: '#000' }]}>Aprobar</Text>
                          </Pressable>
                          <Pressable
                            style={[s.actionBtn, s.actionReject]}
                            onPress={() => { setRejectModal({ id: ad.id, title: ad.title }); setRejectReason(''); }}
                          >
                            <X size={14} color="#fff" />
                            <Text style={[s.actionBtnText, { color: '#fff' }]}>Rechazar</Text>
                          </Pressable>
                        </>
                      )}
                      {!ad._source && (effectiveStatus === 'active' || effectiveStatus === 'paused') && (
                        <Pressable
                          style={[s.actionBtn, effectiveStatus === 'active' ? s.actionPause : s.actionApprove]}
                          onPress={() => handleToggle(ad.id, ad.title, ad.status)}
                        >
                          {effectiveStatus === 'active'
                            ? <><Pause size={14} color={COLORS.muted2} /><Text style={s.actionBtnText}>Pausar</Text></>
                            : <><Play size={14} color="#000" /><Text style={[s.actionBtnText, { color: '#000' }]}>Reactivar</Text></>
                          }
                        </Pressable>
                      )}
                      <Pressable style={[s.actionBtn, s.actionDelete]} onPress={() => handleDelete(ad.id, ad.title)}>
                        <Trash2 size={14} color="#EF4444" />
                      </Pressable>
                    </View>
                  </View>
                </View>
              );
            })
          )}
        </ScrollView>
      </>)}

      {/* ── VISTA: GRUPOS ───────────────────────────────────────────────────── */}
      {viewMode === 'groups' && (
        <ScrollView
          style={{ flex: 1 }}
          contentContainerStyle={{ padding: SPACING.xl, paddingBottom: 40 }}
          refreshControl={<RefreshControl refreshing={groupsLoading} onRefresh={fetchGroups} tintColor={COLORS.green} />}
        >
          {groupsLoading && groups.length === 0 ? (
            <ActivityIndicator color={COLORS.green} style={{ marginTop: 60 }} />
          ) : groups.length === 0 ? (
            <View style={s.empty}><Text style={s.emptyText}>Sin grupos activos</Text></View>
          ) : (
            groups.map((g: any) => {
              const ACTS = [
                { key: 'sponsored'      as const, label: 'Destacado',   icon: '⭐', isActive: g.sponsored,   endsAt: g.sponsoredEndsAt,   color: GROUP_ACT_COLORS.sponsored },
                { key: 'recommendation' as const, label: 'Recomendado', icon: '🔥', isActive: g.recommended, endsAt: g.recommendedEndsAt, color: GROUP_ACT_COLORS.recommendation },
                { key: 'bidding'        as const, label: 'Bidding',      icon: '⬆️', isActive: g.bidding,     endsAt: g.biddingEndsAt,     color: GROUP_ACT_COLORS.bidding },
              ];
              return (
                <View key={g.id} style={s.groupCard}>
                  <View style={s.groupCardHeader}>
                    <Text style={s.groupCardName}>{g.name}</Text>
                    <Text style={s.groupCardCity}>{[g.city, g.state].filter(Boolean).join(', ')}</Text>
                  </View>
                  <View style={s.groupCardActions}>
                    {ACTS.map(t => {
                      const busy = activating === `${g.id}_${t.key}`;
                      const days = t.endsAt ? daysLeft(t.endsAt) : null;
                      return (
                        <Pressable
                          key={t.key}
                          style={[
                            s.groupActBtn,
                            t.isActive
                              ? { backgroundColor: t.color + '22', borderColor: t.color }
                              : { borderColor: t.color + '55' },
                          ]}
                          onPress={() => handleActivate(g.id, g.name, t.key, t.isActive)}
                          disabled={!!activating}
                        >
                          {busy && <ActivityIndicator size={10} color={t.color} style={{ marginRight: 4 }} />}
                          <Text style={[s.groupActBtnText, { color: t.isActive ? t.color : t.color + 'AA' }]}>
                            {t.icon} {t.label}
                          </Text>
                          {t.isActive && days !== null && (
                            <View style={[s.groupActBtnDaysPill, { backgroundColor: t.color + '33' }]}>
                              <Text style={[s.groupActBtnDaysText, { color: t.color }]}>
                                {days <= 0 ? 'exp' : `${days}d`}
                              </Text>
                            </View>
                          )}
                        </Pressable>
                      );
                    })}
                  </View>
                </View>
              );
            })
          )}
        </ScrollView>
      )}

      {/* ════════════════════════════════════════════════════════════════════
          MODAL: Crear anuncio gratis — con SegmentedControl
          ════════════════════════════════════════════════════════════════════ */}
      <Modal visible={createModal} transparent animationType="slide" onRequestClose={() => { setCreateModal(false); resetCreateForm(); }}>
        <Pressable style={s.overlay} onPress={() => { setCreateModal(false); resetCreateForm(); }}>
          <Pressable style={[s.sheet, { maxHeight: '92%' }]} onPress={() => {}}>
            <ScrollView showsVerticalScrollIndicator={false} keyboardShouldPersistTaps="handled">
              <View style={s.sheetHandle} />
              <Text style={s.sheetTitle}>Crear anuncio gratis</Text>
              <Text style={s.sheetSub}>Se activa inmediatamente sin cobro</Text>

              {/* ── SegmentedControl ─────────────────────────────────────── */}
              <View style={s.segmentRow}>
                <Pressable
                  style={[s.segmentBtn, freeSegment === 0 && s.segmentBtnActive]}
                  onPress={() => setFreeSegment(0)}
                >
                  <Text style={[s.segmentBtnText, freeSegment === 0 && s.segmentBtnTextActive]}>
                    📷 Anuncios de Imagen
                  </Text>
                </Pressable>
                <Pressable
                  style={[s.segmentBtn, freeSegment === 1 && s.segmentBtnActive]}
                  onPress={() => setFreeSegment(1)}
                >
                  <Text style={[s.segmentBtnText, freeSegment === 1 && s.segmentBtnTextActive]}>
                    👥 Promociones de Grupo
                  </Text>
                </Pressable>
              </View>

              {/* ── SEGMENTO 0: Imagen (Banner / Perfil) ─────────────────── */}
              {freeSegment === 0 && (<>
                <Text style={s.sheetLabel}>Tipo</Text>
                <View style={s.chipRow}>
                  {IMAGE_AD_TYPES.map(t => (
                    <Pressable
                      key={t.key}
                      style={[
                        s.typeChip,
                        freeType === t.key
                          ? { backgroundColor: t.color + '22', borderColor: t.color }
                          : { borderColor: t.color + '44' },
                      ]}
                      onPress={() => setFreeType(t.key)}
                    >
                      <Text style={{ fontSize: 16 }}>{t.icon}</Text>
                      <Text style={[s.typeChipText, { color: freeType === t.key ? t.color : COLORS.muted2 }]}>
                        {t.label}
                      </Text>
                    </Pressable>
                  ))}
                </View>

                <Text style={s.sheetLabel}>Título *</Text>
                <TextInput
                  style={s.sheetInput}
                  value={freeTitle} onChangeText={setFreeTitle}
                  placeholder="Ej: ¡Descubre los mejores grupos!"
                  placeholderTextColor={COLORS.muted}
                />

                <Text style={s.sheetLabel}>Subtítulo (opcional)</Text>
                <TextInput
                  style={s.sheetInput}
                  value={freeSub} onChangeText={setFreeSub}
                  placeholder="Ej: Reserva con descuento"
                  placeholderTextColor={COLORS.muted}
                />

                <Text style={s.sheetLabel}>Texto del botón</Text>
                <TextInput
                  style={s.sheetInput}
                  value={freeBtnText} onChangeText={setFreeBtnText}
                  placeholder="Ver más"
                  placeholderTextColor={COLORS.muted}
                />

                <Text style={s.sheetLabel}>URL de imagen (opcional)</Text>
                <TextInput
                  style={s.sheetInput}
                  value={freeImageUrl} onChangeText={setFreeImageUrl}
                  placeholder="https://..."
                  placeholderTextColor={COLORS.muted}
                  autoCapitalize="none" keyboardType="url"
                />

                <Text style={s.sheetLabel}>Estado (opcional, ej: jalisco)</Text>
                <TextInput
                  style={s.sheetInput}
                  value={freeState} onChangeText={setFreeState}
                  placeholder="Dejar vacío = nacional"
                  placeholderTextColor={COLORS.muted}
                  autoCapitalize="none"
                />
              </>)}

              {/* ── SEGMENTO 1: Promociones de grupo ─────────────────────── */}
              {freeSegment === 1 && (<>
                <Text style={s.sheetLabel}>Tipo de promoción</Text>
                <View style={s.chipRow}>
                  {GROUP_PROMO_TYPES.map(t => (
                    <Pressable
                      key={t.key}
                      style={[
                        s.typeChip,
                        freeGroupPromoType === t.key
                          ? { backgroundColor: t.color + '22', borderColor: t.color }
                          : { borderColor: t.color + '44' },
                      ]}
                      onPress={() => setFreeGroupPromoType(t.key)}
                    >
                      <Text style={{ fontSize: 16 }}>{t.icon}</Text>
                      <Text style={[s.typeChipText, { color: freeGroupPromoType === t.key ? t.color : COLORS.muted2 }]}>
                        {t.label}
                      </Text>
                    </Pressable>
                  ))}
                </View>

                <Text style={s.sheetLabel}>Buscar grupo</Text>
                <TextInput
                  style={[s.sheetInput, { minHeight: 44, marginBottom: 8 }]}
                  value={freeGroupSearchDisplay} onChangeText={handleGroupSearch}
                  placeholder="Nombre del grupo..."
                  placeholderTextColor={COLORS.muted}
                />

                {groupsLoading || searchLoading ? (
                  <ActivityIndicator color={COLORS.green} style={{ marginBottom: 16 }} />
                ) : (
                  <View style={s.groupPickerList}>
                    {modalFilteredGroups.length === 0 ? (
                      <Text style={[s.sheetLabel, { textAlign: 'center', marginBottom: 8 }]}>
                        Sin resultados
                      </Text>
                    ) : modalFilteredGroups.map(g => (
                      <Pressable
                        key={g.id}
                        style={[
                          s.groupPickerItem,
                          freeGroupId === g.id && s.groupPickerItemActive,
                        ]}
                        onPress={() => setFreeGroupId(g.id)}
                      >
                        <Text style={[s.groupPickerItemText, freeGroupId === g.id && { color: COLORS.green }]}>
                          {g.name}
                        </Text>
                        <Text style={s.groupPickerItemSub}>{[g.city, g.state].filter(Boolean).join(', ')}</Text>
                      </Pressable>
                    ))}
                  </View>
                )}

                {freeGroupPromoType === 'bidding' && (
                  <>
                    <Text style={s.sheetLabel}>Monto ficticio para ranking ($)</Text>
                    <TextInput
                      style={[s.sheetInput, { minHeight: 44, marginBottom: 16 }]}
                      value={String(freeBidAmount)}
                      onChangeText={v => setFreeBidAmount(Number(v.replace(/[^0-9]/g, '')) || 0)}
                      placeholder="Ej: 100"
                      placeholderTextColor={COLORS.muted}
                      keyboardType="numeric"
                    />
                  </>
                )}
              </>)}

              {/* ── Duración (compartida) ────────────────────────────────── */}
              <Text style={[s.sheetLabel, { marginTop: 4 }]}>Duración</Text>
              <View style={s.chipRow}>
                {FREE_DURATIONS.map(d => (
                  <Pressable
                    key={d.days}
                    style={[s.freeTypePill, freeDays === d.days && s.freeTypePillActive]}
                    onPress={() => setFreeDays(d.days)}
                  >
                    <Text style={[s.freeTypePillText, freeDays === d.days && s.freeTypePillTextActive]}>
                      {d.label}
                    </Text>
                  </Pressable>
                ))}
              </View>

              <View style={{ flexDirection: 'row', gap: 12, marginTop: 8 }}>
                <Pressable
                  style={[s.sheetBtn, { flex: 1, backgroundColor: COLORS.card }]}
                  onPress={() => { setCreateModal(false); resetCreateForm(); }}
                >
                  <Text style={[s.sheetBtnText, { color: COLORS.muted2 }]}>Cancelar</Text>
                </Pressable>
                <Pressable
                  style={[s.sheetBtn, { flex: 2, backgroundColor: COLORS.green, opacity: freeCreating ? 0.6 : 1 }]}
                  onPress={handleCreateFreeAd}
                  disabled={freeCreating}
                >
                  <Text style={[s.sheetBtnText, { color: '#000' }]}>
                    {freeCreating ? 'Creando...' : '✓ Crear gratis'}
                  </Text>
                </Pressable>
              </View>
            </ScrollView>
          </Pressable>
        </Pressable>
      </Modal>

      {/* ════════════════════════════════════════════════════════════════════
          MINI-MODAL: Confirmar activación de grupo
          ════════════════════════════════════════════════════════════════════ */}
      <Modal visible={!!activateModal} transparent animationType="slide" onRequestClose={() => setActivateModal(null)}>
        <Pressable style={s.overlay} onPress={() => setActivateModal(null)}>
          <Pressable style={s.sheet} onPress={() => {}}>
            <View style={s.sheetHandle} />
            {activateModal && (() => {
              const promoColor = GROUP_ACT_COLORS[activateModal.type];
              const promoLabel = activateModal.type === 'sponsored' ? '⭐ Destacado'
                               : activateModal.type === 'recommendation' ? '🔥 Recomendado'
                               : '⬆️ Bidding';
              return (<>
                <Text style={s.sheetTitle}>Activar {promoLabel}</Text>
                <Text style={s.sheetSub} numberOfLines={1}>
                  ¿Cuántos días para "{activateModal.groupName}"?
                </Text>

                <View style={[s.chipRow, { marginBottom: 20 }]}>
                  {FREE_DURATIONS.filter(d => d.days > 0).map(d => (
                    <Pressable
                      key={d.days}
                      style={[
                        s.freeTypePill,
                        activateDays === d.days && { backgroundColor: promoColor + '22', borderColor: promoColor },
                      ]}
                      onPress={() => setActivateDays(d.days)}
                    >
                      <Text style={[
                        s.freeTypePillText,
                        activateDays === d.days && { color: promoColor },
                      ]}>
                        {d.label}
                      </Text>
                    </Pressable>
                  ))}
                </View>

                {activateModal.type === 'bidding' && (
                  <>
                    <Text style={s.sheetLabel}>Monto ficticio para ranking ($)</Text>
                    <TextInput
                      style={[s.sheetInput, { minHeight: 44, marginBottom: 20 }]}
                      value={String(activateBidAmount)}
                      onChangeText={v => setActivateBidAmount(Number(v.replace(/[^0-9]/g, '')) || 0)}
                      placeholder="Ej: 100"
                      placeholderTextColor={COLORS.muted}
                      keyboardType="numeric"
                    />
                  </>
                )}

                <View style={{ flexDirection: 'row', gap: 12 }}>
                  <Pressable
                    style={[s.sheetBtn, { flex: 1, backgroundColor: COLORS.card }]}
                    onPress={() => setActivateModal(null)}
                  >
                    <Text style={[s.sheetBtnText, { color: COLORS.muted2 }]}>Cancelar</Text>
                  </Pressable>
                  <Pressable
                    style={[s.sheetBtn, { flex: 2, backgroundColor: promoColor, opacity: activateLoading ? 0.6 : 1 }]}
                    onPress={handleActivateConfirm}
                    disabled={activateLoading}
                  >
                    <Text style={[s.sheetBtnText, { color: activateModal.type === 'sponsored' ? '#000' : '#fff' }]}>
                      {activateLoading ? 'Activando...' : `✓ Activar ${activateDays}d`}
                    </Text>
                  </Pressable>
                </View>
              </>);
            })()}
          </Pressable>
        </Pressable>
      </Modal>

      {/* Modal: Reject */}
      <Modal visible={!!rejectModal} transparent animationType="slide" onRequestClose={() => setRejectModal(null)}>
        <Pressable style={s.overlay} onPress={() => setRejectModal(null)}>
          <Pressable style={s.sheet} onPress={() => {}}>
            <View style={s.sheetHandle} />
            <Text style={s.sheetTitle}>Rechazar anuncio</Text>
            <Text style={s.sheetSub} numberOfLines={1}>{rejectModal?.title}</Text>
            <Text style={s.sheetLabel}>Motivo del rechazo (opcional)</Text>
            <TextInput
              style={s.sheetInput}
              value={rejectReason} onChangeText={setRejectReason}
              placeholder="Ej: Contenido no apropiado, imagen de baja calidad..."
              placeholderTextColor={COLORS.muted}
              multiline numberOfLines={3} textAlignVertical="top"
            />
            <View style={{ flexDirection: 'row', gap: 12, marginTop: 4 }}>
              <Pressable style={[s.sheetBtn, { flex: 1, backgroundColor: COLORS.card }]} onPress={() => setRejectModal(null)}>
                <Text style={[s.sheetBtnText, { color: COLORS.muted2 }]}>Cancelar</Text>
              </Pressable>
              <Pressable style={[s.sheetBtn, { flex: 1, backgroundColor: '#EF4444' }]} onPress={handleReject}>
                <Text style={[s.sheetBtnText, { color: '#fff' }]}>Rechazar</Text>
              </Pressable>
            </View>
          </Pressable>
        </Pressable>
      </Modal>

      {/* Modal: Preview */}
      <Modal visible={!!preview} transparent animationType="fade" onRequestClose={() => setPreview(null)}>
        <Pressable style={s.overlay} onPress={() => setPreview(null)}>
          <View style={s.previewSheet}>
            <Text style={s.sheetTitle}>{preview?.title}</Text>
            {preview?.subtitle && <Text style={s.sheetSub}>{preview?.subtitle}</Text>}
            {preview?.media_url && preview?.media_type === 'image' && (
              <Image source={{ uri: preview.media_url }} style={s.previewImage} resizeMode="cover" />
            )}
            {preview?.media_url && preview?.media_type === 'video' && (
              <VideoPlayer
                uri={preview.media_url}
                style={s.previewImage}
                contentFit="cover"
                nativeControls
                autoPlay
              />
            )}
            <View style={s.previewRow}>
              <Text style={s.previewLabel}>Tipo</Text>
              <Text style={s.previewVal}>{TYPE_LABELS[preview?.type] ?? preview?.type}</Text>
            </View>
            <View style={s.previewRow}>
              <Text style={s.previewLabel}>Anunciante</Text>
              <Text style={s.previewVal} numberOfLines={1}>{preview?.advertiser_name ?? preview?.advertiser_email ?? '—'}</Text>
            </View>
            {(preview?.budget ?? preview?.total_budget) ? (
              <View style={s.previewRow}>
                <Text style={s.previewLabel}>Presupuesto</Text>
                <Text style={s.previewVal}>${(preview.budget ?? preview.total_budget).toLocaleString()}</Text>
              </View>
            ) : null}
            <View style={s.previewRow}>
              <Text style={s.previewLabel}>Botón CTA</Text>
              <Text style={s.previewVal}>{preview?.button_text ?? '—'}</Text>
            </View>
            {preview?.ends_at && (
              <View style={s.previewRow}>
                <Text style={s.previewLabel}>Expira</Text>
                <Text style={s.previewVal}>{new Date(preview.ends_at).toLocaleDateString()}</Text>
              </View>
            )}
            {(preview?.impressions ?? 0) > 0 && (
              <View style={s.previewRow}>
                <Text style={s.previewLabel}>CTR</Text>
                <Text style={[s.previewVal, { color: COLORS.green }]}>
                  {calcCtr(preview.impressions, preview.clicks ?? 0)}%
                </Text>
              </View>
            )}
            <Pressable style={[s.sheetBtn, { backgroundColor: COLORS.green, marginTop: 16 }]} onPress={() => setPreview(null)}>
              <Text style={[s.sheetBtnText, { color: '#000' }]}>Cerrar</Text>
            </Pressable>
          </View>
        </Pressable>
      </Modal>
    </SafeAreaView>
  );
}

const s = StyleSheet.create({
  container: { flex: 1, backgroundColor: COLORS.bg },
  header: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between',
    paddingHorizontal: SPACING.xl, paddingVertical: 12,
  },
  backBtn:     { paddingVertical: 4 },
  backBtnText: { fontFamily: FONTS.bodyMedium, fontSize: 14, color: COLORS.green },
  title:       { fontFamily: FONTS.title, fontSize: 20, color: COLORS.text },

  // Botón "+ Gratis" más prominente
  createFreeBtn: {
    backgroundColor: COLORS.green, borderRadius: RADIUS.full,
    paddingHorizontal: 14, paddingVertical: 8,
  },
  createFreeBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: '#000' },

  // ── Stats ──────────────────────────────────────────────────────────────────
  statsRow: { flexDirection: 'row', paddingHorizontal: SPACING.xl, paddingBottom: 12, gap: 8 },
  statCard: {
    flex: 1, backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    padding: 10, alignItems: 'center', borderWidth: 1, borderColor: COLORS.border,
  },
  statCardGreen: { borderColor: 'rgba(0,230,118,0.3)', backgroundColor: 'rgba(0,230,118,0.08)' },
  statCardGold:  { borderColor: 'rgba(201,168,76,0.4)', backgroundColor: 'rgba(201,168,76,0.08)' },
  statVal:       { fontFamily: FONTS.bodySemiBold, fontSize: 16, color: COLORS.text },
  statValGold:   { color: '#C9A84C' },
  statLabel:     { fontFamily: FONTS.body, fontSize: 10, color: COLORS.muted2, marginTop: 2 },

  // ── Income row ─────────────────────────────────────────────────────────────
  incomeRow: { flexDirection: 'row', gap: 8, paddingHorizontal: SPACING.xl, paddingBottom: 10, flexWrap: 'wrap' },
  incomeChip: {
    backgroundColor: 'rgba(201,168,76,0.12)', borderWidth: 1, borderColor: 'rgba(201,168,76,0.35)',
    borderRadius: RADIUS.full, paddingHorizontal: 12, paddingVertical: 5,
  },
  incomeChipText:    { fontFamily: FONTS.bodySemiBold, fontSize: 12, color: '#C9A84C' },
  incomeChipBid:     { backgroundColor: 'rgba(167,139,250,0.12)', borderColor: 'rgba(167,139,250,0.35)' },
  incomeChipTextBid: { color: '#A78BFA' },
  incomeChipRec:     { backgroundColor: 'rgba(255,109,0,0.12)', borderColor: 'rgba(255,109,0,0.35)' },
  incomeChipTextRec: { color: '#FF6D00' },

  // ── Tabs ───────────────────────────────────────────────────────────────────
  tabsScroll: { flexGrow: 0 },
  tabs: { paddingHorizontal: SPACING.xl, gap: 10, marginBottom: 4 },
  tab: {
    flexDirection: 'row', alignItems: 'center', gap: 6,
    paddingHorizontal: 16, paddingVertical: 8, borderRadius: RADIUS.full,
    backgroundColor: COLORS.card, borderWidth: 1, borderColor: COLORS.border,
  },
  tabText:      { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted2 },
  tabBadge:     { minWidth: 18, height: 18, borderRadius: 9, alignItems: 'center', justifyContent: 'center', paddingHorizontal: 4 },
  tabBadgeText: { fontFamily: FONTS.bodySemiBold, fontSize: 10, color: '#000' },

  // ── Filter ─────────────────────────────────────────────────────────────────
  filterScroll: { flexGrow: 0, marginBottom: 4 },
  filters: { paddingHorizontal: SPACING.xl, gap: 8, paddingBottom: 8 },
  filterChip: {
    paddingHorizontal: 12, paddingVertical: 6, borderRadius: RADIUS.full,
    backgroundColor: COLORS.card, borderWidth: 1, borderColor: COLORS.border,
  },
  filterChipActive:     { backgroundColor: 'rgba(0,230,118,0.15)', borderColor: COLORS.green },
  filterChipText:       { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.muted2 },
  filterChipTextActive: { color: COLORS.green },

  // ── Empty ──────────────────────────────────────────────────────────────────
  empty:     { alignItems: 'center', paddingTop: 60, gap: 12 },
  emptyText: { fontFamily: FONTS.body, fontSize: 14, color: COLORS.muted2 },

  // ── Ad Card ────────────────────────────────────────────────────────────────
  card: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.xl,
    borderWidth: 1, borderColor: COLORS.border, overflow: 'hidden', marginBottom: 16,
  },
  cardActive:          { borderColor: 'rgba(0,230,118,0.25)' },
  topBadge: {
    backgroundColor: 'rgba(255,109,0,0.15)', borderBottomWidth: 1, borderBottomColor: 'rgba(255,109,0,0.3)',
    paddingHorizontal: 14, paddingVertical: 5,
  },
  topBadgeText:        { fontFamily: FONTS.bodyMedium, fontSize: 11, color: '#FF6D00' },
  cardMedia:           { width: '100%', height: 100 },
  cardMediaPlaceholder:{ width: '100%', height: 70, alignItems: 'center', justifyContent: 'center' },
  cardMediaVideo: {
    width: '100%', height: 90, backgroundColor: '#111',
    alignItems: 'center', justifyContent: 'center', flexDirection: 'row', gap: 10,
  },
  cardMediaVideoText:  { fontFamily: FONTS.bodyMedium, fontSize: 13, color: '#fff' },
  cardBody:            { padding: 14 },
  cardTopRow:          { flexDirection: 'row', alignItems: 'center', gap: 8, marginBottom: 8, flexWrap: 'wrap' },
  typeBadge: {
    borderRadius: RADIUS.full, paddingHorizontal: 10, paddingVertical: 3, borderWidth: 1,
  },
  typeBadgeText:   { fontFamily: FONTS.bodyMedium, fontSize: 11 },
  statusBadge:     { borderRadius: RADIUS.full, paddingHorizontal: 10, paddingVertical: 3, borderWidth: 1 },
  statusBadgeText: { fontFamily: FONTS.bodyMedium, fontSize: 11 },
  daysPill: {
    flexDirection: 'row', alignItems: 'center', gap: 3,
    borderRadius: RADIUS.full, paddingHorizontal: 8, paddingVertical: 3, borderWidth: 1,
  },
  daysPillText:    { fontFamily: FONTS.bodySemiBold, fontSize: 10 },
  cardTitle:       { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.text, marginBottom: 2 },
  cardSub:         { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2, marginBottom: 8 },
  metaRow:         { gap: 4, marginBottom: 6 },
  metaItem:        { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2 },
  dateText:        { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, marginBottom: 8 },
  rejectionBox: {
    backgroundColor: 'rgba(239,68,68,0.1)', borderRadius: RADIUS.md, padding: 10, marginBottom: 8,
    borderWidth: 1, borderColor: 'rgba(239,68,68,0.3)',
  },
  rejectionText:   { fontFamily: FONTS.body, fontSize: 12, color: '#EF4444' },
  metricsRow:      { flexDirection: 'row', gap: 8, marginBottom: 8, flexWrap: 'wrap' },
  metricChip: {
    flexDirection: 'row', alignItems: 'center', gap: 4,
    backgroundColor: COLORS.card2, borderRadius: RADIUS.full, paddingHorizontal: 10, paddingVertical: 4,
  },
  metricCtr:  { backgroundColor: 'rgba(0,230,118,0.1)', borderWidth: 1, borderColor: 'rgba(0,230,118,0.25)' },
  metricText: { fontFamily: FONTS.bodyMedium, fontSize: 11, color: COLORS.muted2 },
  actions: { flexDirection: 'row', gap: 8, flexWrap: 'wrap', marginTop: 4 },
  actionBtn: {
    flexDirection: 'row', alignItems: 'center', gap: 5,
    paddingHorizontal: 14, paddingVertical: 8, borderRadius: RADIUS.full,
    backgroundColor: COLORS.card2, borderWidth: 1, borderColor: COLORS.border,
  },
  actionBtnText: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.muted2 },
  actionApprove: { backgroundColor: COLORS.green, borderColor: COLORS.green },
  actionReject:  { backgroundColor: '#EF4444', borderColor: '#EF4444' },
  actionPause:   { backgroundColor: COLORS.card2, borderColor: COLORS.border },
  actionDelete:  { paddingHorizontal: 10, borderColor: 'rgba(239,68,68,0.4)' },
  autoActivateNote: {
    backgroundColor: 'rgba(0,230,118,0.08)', borderWidth: 1, borderColor: 'rgba(0,230,118,0.25)',
    borderRadius: RADIUS.md, paddingHorizontal: 12, paddingVertical: 8, marginBottom: 10,
  },
  autoActivateNoteText: { fontFamily: FONTS.bodyMedium, fontSize: 11, color: COLORS.green },
  incomeBar: {
    flexDirection: 'row', alignItems: 'center', gap: 6,
    backgroundColor: 'rgba(201,168,76,0.10)', borderWidth: 1, borderColor: 'rgba(201,168,76,0.3)',
    borderRadius: RADIUS.md, paddingHorizontal: 10, paddingVertical: 6, marginTop: 6,
  },
  incomeBarIcon:     { fontSize: 13 },
  incomeBarLabel:    { fontFamily: FONTS.bodyMedium, fontSize: 11, color: COLORS.muted2 },
  incomeBarAmount:   { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: '#C9A84C', flex: 1 },
  incomeBarPill:     { backgroundColor: 'rgba(0,230,118,0.12)', borderRadius: RADIUS.full, paddingHorizontal: 8, paddingVertical: 2 },
  incomeBarPillText: { fontFamily: FONTS.bodyMedium, fontSize: 10, color: COLORS.green },

  freeBadge: {
    backgroundColor: 'rgba(0,230,118,0.15)', borderRadius: RADIUS.full,
    paddingHorizontal: 8, paddingVertical: 3, borderWidth: 1, borderColor: 'rgba(0,230,118,0.45)',
  },
  freeBadgeText: { fontFamily: FONTS.bodySemiBold, fontSize: 10, color: COLORS.green },

  // ── View toggle ────────────────────────────────────────────────────────────
  viewToggle: {
    flexDirection: 'row', backgroundColor: COLORS.card2,
    borderRadius: RADIUS.full, borderWidth: 1, borderColor: COLORS.border, overflow: 'hidden',
  },
  viewToggleBtn:         { paddingHorizontal: 14, paddingVertical: 6 },
  viewToggleBtnActive:   { backgroundColor: COLORS.green },
  viewToggleBtnText:     { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted2 },
  viewToggleBtnTextActive: { color: '#000' },

  // ── Groups view ────────────────────────────────────────────────────────────
  groupCard: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.xl,
    borderWidth: 1, borderColor: COLORS.border, padding: 14, marginBottom: 12,
  },
  groupCardHeader:  { marginBottom: 10 },
  groupCardName:    { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.text },
  groupCardCity:    { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, marginTop: 2 },
  groupCardActions: { flexDirection: 'row', gap: 8, flexWrap: 'wrap' },
  groupActBtn: {
    flexDirection: 'row', alignItems: 'center', gap: 4,
    paddingHorizontal: 12, paddingVertical: 7, borderRadius: RADIUS.full,
    backgroundColor: 'transparent', borderWidth: 1.5,
  },
  groupActBtnText: { fontFamily: FONTS.bodyMedium, fontSize: 12 },
  groupActBtnDaysPill: {
    borderRadius: RADIUS.full, paddingHorizontal: 6, paddingVertical: 2, marginLeft: 2,
  },
  groupActBtnDaysText: { fontFamily: FONTS.bodySemiBold, fontSize: 10 },

  // ── Modals ─────────────────────────────────────────────────────────────────
  overlay: { flex: 1, backgroundColor: 'rgba(0,0,0,0.6)', justifyContent: 'flex-end' },
  sheet: {
    backgroundColor: COLORS.card2, borderTopLeftRadius: 24, borderTopRightRadius: 24,
    padding: SPACING.xl, paddingBottom: 36,
  },
  sheetHandle: {
    width: 40, height: 4, borderRadius: 2, backgroundColor: COLORS.border,
    alignSelf: 'center', marginBottom: 18,
  },
  sheetTitle: { fontFamily: FONTS.title, fontSize: 18, color: COLORS.text, marginBottom: 4 },
  sheetSub:   { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2, marginBottom: 16 },
  sheetLabel: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted2, marginBottom: 8 },
  sheetInput: {
    backgroundColor: COLORS.bg, borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: COLORS.border,
    paddingHorizontal: 14, paddingVertical: 12,
    fontFamily: FONTS.body, fontSize: 14, color: COLORS.text,
    minHeight: 44, marginBottom: 16,
  },
  sheetBtn:     { borderRadius: RADIUS.md, paddingVertical: 14, alignItems: 'center', justifyContent: 'center' },
  sheetBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 15 },

  previewSheet: {
    backgroundColor: COLORS.card2, borderRadius: 24,
    margin: SPACING.xl, padding: SPACING.xl,
  },
  previewImage: { width: '100%', height: 140, borderRadius: RADIUS.lg, marginVertical: 12 },
  previewRow: {
    flexDirection: 'row', justifyContent: 'space-between',
    paddingVertical: 6, borderBottomWidth: 1, borderBottomColor: COLORS.border,
  },
  previewLabel: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted2 },
  previewVal:   { fontFamily: FONTS.body, fontSize: 13, color: COLORS.text, maxWidth: '60%', textAlign: 'right' },

  // ── SegmentedControl ───────────────────────────────────────────────────────
  segmentRow: {
    flexDirection: 'row', backgroundColor: COLORS.bg,
    borderRadius: RADIUS.lg, borderWidth: 1, borderColor: COLORS.border,
    marginBottom: 20, overflow: 'hidden',
  },
  segmentBtn: {
    flex: 1, paddingVertical: 10, alignItems: 'center', justifyContent: 'center',
  },
  segmentBtnActive: { backgroundColor: COLORS.green },
  segmentBtnText:   { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.muted2 },
  segmentBtnTextActive: { color: '#000' },

  // ── Type chips con color ───────────────────────────────────────────────────
  chipRow: { flexDirection: 'row', gap: 8, flexWrap: 'wrap', marginBottom: 16 },
  typeChip: {
    flexDirection: 'row', alignItems: 'center', gap: 6,
    paddingHorizontal: 14, paddingVertical: 9,
    borderRadius: RADIUS.full, borderWidth: 1.5,
    backgroundColor: 'transparent',
  },
  typeChipText: { fontFamily: FONTS.bodyMedium, fontSize: 13 },

  // ── Group picker en modal ──────────────────────────────────────────────────
  groupPickerList: {
    borderRadius: RADIUS.lg, borderWidth: 1, borderColor: COLORS.border,
    backgroundColor: COLORS.bg, marginBottom: 16, overflow: 'hidden',
  },
  groupPickerItem: {
    paddingHorizontal: 14, paddingVertical: 12,
    borderBottomWidth: 1, borderBottomColor: COLORS.border,
  },
  groupPickerItemActive: { backgroundColor: 'rgba(0,230,118,0.08)' },
  groupPickerItemText:   { fontFamily: FONTS.bodyMedium, fontSize: 14, color: COLORS.text },
  groupPickerItemSub:    { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted2, marginTop: 2 },

  // ── Duration pills (reutilizados en ambos modales) ─────────────────────────
  freeTypePill: {
    paddingHorizontal: 12, paddingVertical: 7, borderRadius: RADIUS.full,
    backgroundColor: COLORS.card2, borderWidth: 1, borderColor: COLORS.border,
  },
  freeTypePillActive:     { backgroundColor: 'rgba(0,230,118,0.15)', borderColor: COLORS.green },
  freeTypePillText:       { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.muted2 },
  freeTypePillTextActive: { color: COLORS.green },
});
