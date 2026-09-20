/**
 * AdminTalentsScreen — Gestión de talentos para administradores.
 *
 * 3 vistas (sin cambio de ruta):
 *   'list'     — listado de talentos con búsqueda y filtro por estado
 *   'profile'  — perfil completo + contacto
 *   'moderate' — verificar gratis + historial
 *
 * Fuente de datos: job_board_profiles UNION profiles(role='talent')
 * para garantizar que aparezcan todos los músicos del sistema.
 */
import {
  ArrowLeft,
  ChevronDown,
  ChevronRight,
  ChevronUp,
  Mail,
  MapPin,
  Phone,
  Search,
  Shield,
  ShieldCheck,
  Star,
  X,
} from 'lucide-react-native';
import React, { useEffect, useMemo, useState } from 'react';
import {
  ActivityIndicator,
  Alert,
  Image,
  Pressable,
  RefreshControl,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  View,
  useWindowDimensions,
} from 'react-native';
import { useTranslation } from 'react-i18next';
import { SafeAreaView } from 'react-native-safe-area-context';
import { supabase } from '../../config/supabase';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';
import Particles from '../../components/ui/Particles';
import VerifiedBadge from '../../components/ui/VerifiedBadge';
import { stateToCountry } from '../../utils/locationUtils';

type AdminView = 'list' | 'profile' | 'moderate';

interface Talent {
  id: string;
  user_id: string;
  full_name: string;
  avatar_url: string | null;
  instrument_or_role: string;
  bio: string | null;
  experience_years: number | null;
  rating: number;
  total_jobs: number;
  availability_status: string;
  group_name: string | null;
  phone: string | null;
  city: string | null;
  state: string | null;
  country: string | null;
  verification_status: string;
  admin_verified: boolean;
  id_document_url: string | null;
  selfie_url: string | null;
  created_at?: string | null;
}

// ─── Screen ───────────────────────────────────────────────────────────────────

export default function AdminTalentsScreen({ navigation }: any) {
  const { t } = useTranslation();
  const { width: screenW } = useWindowDimensions();
  const CARD_W = Math.floor((screenW - SPACING.xl * 2 - 6 * 3) / 4);

  const [view,       setView]       = useState<AdminView>('list');
  const [talents,    setTalents]    = useState<Talent[]>([]);
  const [selected,   setSelected]   = useState<Talent | null>(null);
  const [refreshing, setRefreshing] = useState(false);
  const [search,        setSearch]        = useState('');
  const [activeState,   setActiveState]   = useState<string | null>(null);
  const [activeCountry, setActiveCountry] = useState<string | null>(null);

  // Profile view
  const [ownerEmail,     setOwnerEmail]     = useState<string | null>(null);
  const [contactLoading, setContactLoading] = useState(false);

  // Moderate view
  const [moderateNote,  setModerateNote]  = useState('');
  const [actionLoading, setActionLoading] = useState(false);

  useEffect(() => { fetchTalents(); }, []);

  // ── Data ──────────────────────────────────────────────────────────────────

  const fetchTalents = async () => {
    // Dos queries en paralelo:
    // A) job_board_profiles (músicos con perfil profesional, cualquier role)
    // B) profiles WHERE role='talent' (talentos sin job_board_profile)
    const [jbpRes, talentRes] = await Promise.all([
      supabase.from('job_board_profiles').select(`
        id, user_id, instrument_or_role, bio, experience_years,
        rating, total_jobs, availability_status, is_visible,
        profile:profiles!job_board_profiles_user_id_fkey(
          full_name, avatar_url, phone, city, state, role,
          verification_status, admin_verified,
          id_document_url, selfie_url, created_at
        )
      `).order('rating', { ascending: false }),

      supabase.from('profiles').select(`
        id, full_name, avatar_url, phone, city, state,
        verification_status, admin_verified,
        id_document_url, selfie_url, created_at
      `).eq('role', 'talent').order('full_name'),
    ]);

    const jbps    = jbpRes.data    ?? [];
    const tProfs  = talentRes.data ?? [];

    const allIds = [...new Set([
      ...jbps.map((j: any) => j.user_id),
      ...tProfs.map((p: any) => p.id),
    ])];

    const { data: memberships } = allIds.length > 0
      ? await supabase
          .from('job_invitations')
          .select('invited_user_id, group:groups(name)')
          .in('invited_user_id', allIds)
          .eq('status', 'accepted')
          .is('event_id', null)
      : { data: [] };

    const memberMap: Record<string, string> = {};
    (memberships ?? []).forEach((m: any) => {
      memberMap[m.invited_user_id] = m.group?.name ?? '—';
    });

    const map = new Map<string, Talent>();

    tProfs.forEach((p: any) => {
      map.set(p.id, {
        id: p.id, user_id: p.id,
        full_name: p.full_name ?? t('adminTalentsScreen.defaults.noName'),
        avatar_url: p.avatar_url ?? null,
        instrument_or_role: '—', bio: null,
        experience_years: null, rating: 0, total_jobs: 0,
        availability_status: 'unknown',
        group_name: memberMap[p.id] ?? null,
        phone: p.phone ?? null,
        city: p.city ?? null, state: p.state ?? null, country: p.country ?? null,
        verification_status: p.verification_status ?? 'none',
        admin_verified: p.admin_verified ?? false,
        id_document_url: p.id_document_url ?? null,
        selfie_url: p.selfie_url ?? null,
        created_at: p.created_at ?? null,
      });
    });

    // Incluye job_board_profiles de role='talent' Y role='group' (dueños de grupo que
    // también se anuncian como talento individual, sql/245) — así el admin ve exactamente
    // lo mismo que search_talents() ya muestra a los clientes. Los clientes (role='client')
    // siguen excluidos: nunca deben aparecer aunque tengan una fila huérfana en la bolsa.
    // sql/21 crea esa fila AUTOMÁTICA y OCULTA (is_visible=false) para todo grupo nuevo —
    // es una opción para anunciarse también como talento, no algo activo por default. Bug
    // real reportado 2026-09-19: "cuando registro un grupo, aparece en talentos" — pasaba
    // porque antes no se filtraba por is_visible, así que TODO grupo nuevo aparecía aquí.
    jbps.filter((j: any) => j.profile?.role !== 'client' && (j.profile?.role !== 'group' || j.is_visible === true)).forEach((j: any) => {
      map.set(j.user_id, {
        id: j.id, user_id: j.user_id,
        full_name: j.profile?.full_name ?? t('adminTalentsScreen.defaults.noName'),
        avatar_url: j.profile?.avatar_url ?? null,
        instrument_or_role: j.instrument_or_role ?? '—',
        bio: j.bio ?? null,
        experience_years: j.experience_years ?? null,
        rating: j.rating ?? 0,
        total_jobs: j.total_jobs ?? 0,
        availability_status: j.availability_status ?? 'unknown',
        group_name: memberMap[j.user_id] ?? null,
        phone: j.profile?.phone ?? null,
        city: j.profile?.city ?? null, state: j.profile?.state ?? null, country: j.profile?.country ?? null,
        verification_status: j.profile?.verification_status ?? 'none',
        admin_verified: j.profile?.admin_verified ?? false,
        id_document_url: j.profile?.id_document_url ?? null,
        selfie_url: j.profile?.selfie_url ?? null,
        created_at: j.profile?.created_at ?? null,
      });
    });

    const result = Array.from(map.values());
    setTalents(result);
  };

  const countries = useMemo(() => {
    const c = new Set<string>();
    talents.forEach(t => c.add(stateToCountry(t.state)));
    return Array.from(c).sort();
  }, [talents]);

  const countryCounts = useMemo(() => {
    const c: Record<string, number> = {};
    talents.forEach(t => {
      const k = stateToCountry(t.state);
      c[k] = (c[k] ?? 0) + 1;
    });
    return c;
  }, [talents]);

  const states = useMemo(() => {
    const base = activeCountry
      ? talents.filter(t => stateToCountry(t.state) === activeCountry)
      : talents;
    const s = new Set<string>();
    base.forEach(t => { if (t.state?.trim()) s.add(t.state.trim()); });
    return Array.from(s).sort();
  }, [talents, activeCountry]);

  const stateCounts = useMemo(() => {
    const base = activeCountry
      ? talents.filter(t => stateToCountry(t.state) === activeCountry)
      : talents;
    const c: Record<string, number> = {};
    base.forEach(t => {
      const k = t.state?.trim();
      if (k) c[k] = (c[k] ?? 0) + 1;
    });
    return c;
  }, [talents, activeCountry]);

  const filtered = useMemo(() => {
    let list = talents;
    if (search.trim()) {
      const q = search.toLowerCase();
      list = list.filter(t =>
        t.full_name?.toLowerCase().includes(q) ||
        t.instrument_or_role?.toLowerCase().includes(q) ||
        t.state?.toLowerCase().includes(q)
      );
    }
    if (activeCountry) list = list.filter(t => stateToCountry(t.state) === activeCountry);
    if (activeState)   list = list.filter(t => t.state?.trim().toLowerCase() === activeState.toLowerCase());
    return list;
  }, [talents, search, activeCountry, activeState]);

  const toggleCountry = (country: string) => {
    if (activeCountry === country) {
      setActiveCountry(null);
      setActiveState(null);
    } else {
      setActiveCountry(country);
      setActiveState(null);
    }
  };

  const onRefresh = async () => { setRefreshing(true); await fetchTalents(); setRefreshing(false); };

  const openProfile = async (talent: Talent) => {
    setSelected(talent);
    setOwnerEmail(null);
    setView('profile');
    setContactLoading(true);
    const { data } = await supabase.rpc('admin_get_user_contact', { p_user_id: talent.user_id });
    if (data?.ok) setOwnerEmail(data.email ?? null);
    setContactLoading(false);
  };

  const openModerate = (talent: Talent) => {
    setSelected(talent);
    setModerateNote('');
    setView('moderate');
  };

  // ── Verificar talento ──────────────────────────────────────────────────────

  const handleVerify = async (verify: boolean) => {
    if (!selected) return;
    if (!verify && !moderateNote.trim()) {
      Alert.alert(
        t('adminTalentsScreen.alerts.noteRequiredTitle'),
        t('adminTalentsScreen.alerts.noteRequiredMessage')
      );
      return;
    }
    setActionLoading(true);
    const { data, error } = await supabase.rpc('admin_set_profile_verified', {
      p_user_id:  selected.user_id,
      p_verified: verify,
      p_note:     moderateNote.trim() || null,
    });
    setActionLoading(false);

    if (error || !data?.ok) {
      Alert.alert(
        t('adminTalentsScreen.alerts.errorTitle'),
        error?.message ?? data?.error ?? t('adminTalentsScreen.alerts.genericUpdateError')
      );
      return;
    }

    const updated = { ...selected, admin_verified: verify, verification_status: verify ? 'approved' : 'none' };
    setSelected(updated);
    setTalents(prev => prev.map(t =>
      t.user_id === selected.user_id
        ? { ...t, admin_verified: verify, verification_status: verify ? 'approved' : 'none' }
        : t
    ));
    setModerateNote('');
    Alert.alert(
      verify ? t('adminTalentsScreen.alerts.verifiedTitle') : t('adminTalentsScreen.alerts.doneTitle'),
      verify
        ? t('adminTalentsScreen.alerts.verifiedMessage', { name: selected.full_name })
        : t('adminTalentsScreen.alerts.unverifiedMessage')
    );
  };

  // ── VISTA: LISTA ──────────────────────────────────────────────────────────

  if (view === 'list') {
    return (
      <View style={s.container}>
        <Particles />
        <SafeAreaView edges={['top']} style={{ flex: 1 }}>
          <View style={s.header}>
            <Pressable style={s.backBtn} onPress={() => navigation.goBack()}>
              <ArrowLeft size={20} color={COLORS.text} />
            </Pressable>
            <Text style={s.headerTitle}>{t('adminTalentsScreen.list.title')}</Text>
            <View style={s.countBadge}>
              <Text style={s.countBadgeText}>{talents.length}</Text>
            </View>
          </View>

          {/* Buscador */}
          <View style={s.searchRow}>
            <Search size={14} color={COLORS.muted} />
            <TextInput
              style={s.searchInput}
              placeholder={t('adminTalentsScreen.list.searchPlaceholder')}
              placeholderTextColor={COLORS.muted}
              value={search}
              onChangeText={setSearch}
            />
            {search.length > 0 && (
              <Pressable onPress={() => setSearch('')}>
                <X size={14} color={COLORS.muted} />
              </Pressable>
            )}
          </View>

          {/* Filtro: país → estados */}
          {countries.length > 0 && (
            <View style={s.pillsWrap}>
              <ScrollView
                horizontal
                showsHorizontalScrollIndicator={false}
                contentContainerStyle={s.pillsRow}
                bounces={false}
                style={{ flex: 1 }}
              >
                {countries.map(country => (
                  <React.Fragment key={country}>
                    <Pressable
                      style={[s.pill, s.pillCountry, activeCountry === country && s.pillCountryActive]}
                      onPress={() => toggleCountry(country)}
                    >
                      <Text style={[s.pillText, s.pillTextCountry, activeCountry === country && s.pillTextActive]}>
                        {country}
                      </Text>
                      <Text style={[s.pillCount, s.pillCountCountry, activeCountry === country && s.pillCountActive]}>
                        {countryCounts[country] ?? 0}
                      </Text>
                      {activeCountry === country
                        ? <ChevronUp size={9} color={COLORS.bg} />
                        : <ChevronDown size={9} color={COLORS.green} />}
                    </Pressable>
                    {activeCountry === country && states.map(st => (
                      <Pressable
                        key={st}
                        style={[s.pill, s.pillState, activeState === st && s.pillActive]}
                        onPress={() => setActiveState(activeState === st ? null : st)}
                      >
                        <MapPin size={8} color={activeState === st ? COLORS.bg : COLORS.muted} />
                        <Text style={[s.pillText, activeState === st && s.pillTextActive]}>{st}</Text>
                        <Text style={[s.pillCount, activeState === st && s.pillCountActive]}>
                          {stateCounts[st] ?? 0}
                        </Text>
                      </Pressable>
                    ))}
                  </React.Fragment>
                ))}
              </ScrollView>
            </View>
          )}

          {(search || activeState || activeCountry) && (
            <Text style={s.resultCount}>{filtered.length} de {talents.length} talentos</Text>
          )}

          <ScrollView
            style={{ flex: 1 }}
            contentContainerStyle={s.list}
            showsVerticalScrollIndicator={false}
            refreshControl={<RefreshControl refreshing={refreshing} onRefresh={onRefresh} tintColor={COLORS.green} />}
          >
            {filtered.length === 0 && (
              <View style={s.empty}>
                <Text style={s.emptyText}>{search || activeState ? 'Sin coincidencias' : 'Sin talentos registrados'}</Text>
              </View>
            )}
            {filtered.map(t => (
              <View key={t.user_id} style={[s.gridCard, { width: CARD_W }]}>
                {/* Avatar + badge de verificación */}
                <View style={s.gridAvatarWrap}>
                  {t.avatar_url ? (
                    <Image source={{ uri: t.avatar_url }} style={s.gridAvatar} />
                  ) : (
                    <View style={[s.gridAvatar, s.gridAvatarEmpty]}>
                      <Text style={s.gridAvatarInitial}>{t.full_name.charAt(0).toUpperCase()}</Text>
                    </View>
                  )}
                  {t.admin_verified && (
                    <VerifiedBadge size={16} style={{ position: 'absolute', bottom: -2, right: -2 }} />
                  )}
                </View>

                <Text style={s.gridName} numberOfLines={1}>{t.full_name}</Text>
                <Text style={s.gridSub} numberOfLines={1}>{t.instrument_or_role}</Text>

                <View style={s.gridMetas}>
                  {t.city ? (
                    <View style={s.gridMetaRow}>
                      <MapPin size={9} color={COLORS.muted} />
                      <Text style={s.gridMetaText} numberOfLines={1}>{t.city}</Text>
                    </View>
                  ) : null}
                  {t.rating > 0 ? (
                    <View style={s.gridMetaRow}>
                      <Star size={9} color={COLORS.gold} fill={COLORS.gold} />
                      <Text style={s.gridMetaRating}>{t.rating.toFixed(1)}</Text>
                    </View>
                  ) : null}
                </View>

                <View style={s.gridActions}>
                  <Pressable style={s.gridActionBtn} onPress={() => openProfile(t)} hitSlop={6}>
                    <ChevronRight size={13} color={COLORS.muted2} />
                  </Pressable>
                  <Pressable style={[s.gridActionBtn, s.gridModBtn]} onPress={() => openModerate(t)} hitSlop={6}>
                    <Shield size={12} color={COLORS.green} />
                  </Pressable>
                </View>
              </View>
            ))}
          </ScrollView>
        </SafeAreaView>
      </View>
    );
  }

  // ── VISTA: PERFIL ──────────────────────────────────────────────────────────

  if (view === 'profile' && selected) {
    const memberMonths = selected.created_at
      ? Math.floor((Date.now() - new Date(selected.created_at).getTime()) / (1000 * 60 * 60 * 24 * 30))
      : null;
    const memberLabel = memberMonths === null ? '—'
      : memberMonths === 0 ? 'Menos de 1 mes'
      : `${memberMonths} mes${memberMonths !== 1 ? 'es' : ''}`;

    return (
      <View style={s.container}>
        <Particles />
        <SafeAreaView edges={['top']} style={{ flex: 1 }}>
          <View style={s.header}>
            <Pressable style={s.backBtn} onPress={() => setView('list')}>
              <ArrowLeft size={20} color={COLORS.text} />
            </Pressable>
            <Text style={s.headerTitle} numberOfLines={1}>{selected.full_name}</Text>
            <Pressable style={s.iconBtn} onPress={() => openModerate(selected)}>
              <Shield size={17} color={COLORS.green} />
            </Pressable>
          </View>

          <ScrollView contentContainerStyle={s.scroll} showsVerticalScrollIndicator={false}>
            {/* Avatar */}
            <View style={s.profilePhotoWrap}>
              {selected.avatar_url ? (
                <Image source={{ uri: selected.avatar_url }} style={s.profilePhoto} />
              ) : (
                <View style={[s.profilePhoto, s.profilePhotoEmpty]}>
                  <Text style={s.profilePhotoInitial}>{selected.full_name.charAt(0).toUpperCase()}</Text>
                </View>
              )}
            </View>

            {/* Chips de estado */}
            <View style={s.statusRow}>
              <View style={[s.statusChip, selected.admin_verified ? s.chipVerified : s.chipNone]}>
                {selected.admin_verified
                  ? <ShieldCheck size={11} color={COLORS.blue} />
                  : <Shield size={11} color={COLORS.muted} />}
                <Text style={[s.statusChipText, selected.admin_verified && { color: COLORS.blue }]}>
                  {selected.admin_verified ? 'Verificado' : 'Sin verificar'}
                </Text>
              </View>
              {selected.group_name && (
                <View style={[s.statusChip, s.chipActive]}>
                  <Text style={[s.statusChipText, { color: COLORS.green }]}>En grupo</Text>
                </View>
              )}
            </View>

            {/* Info */}
            <View style={s.infoCard}>
              <Text style={s.infoCardTitle}>Información del talento</Text>
              <InfoRow label="Nombre"      value={selected.full_name} />
              <InfoRow label="Instrumento" value={selected.instrument_or_role} />
              <InfoRow label="Ciudad"      value={[selected.city, selected.state].filter(Boolean).join(', ') || '—'} />
              <InfoRow label="Antigüedad"  value={memberLabel} />
              {selected.group_name && (
                <InfoRow label="Grupo"     value={selected.group_name} />
              )}
              {selected.bio && (
                <View style={s.infoRowFull}>
                  <Text style={s.infoLabel}>Bio</Text>
                  <Text style={s.infoValueMulti}>{selected.bio}</Text>
                </View>
              )}
            </View>

            {/* Actividad */}
            <View style={s.infoCard}>
              <Text style={s.infoCardTitle}>Actividad</Text>
              {selected.rating > 0 ? (
                <InfoRow label="Rating" value={`★ ${selected.rating.toFixed(1)}  (${selected.total_jobs} trabajos)`} />
              ) : (
                <InfoRow label="Rating" value="Sin trabajos aún" />
              )}
              {selected.experience_years != null && (
                <InfoRow label="Experiencia" value={`${selected.experience_years} años`} />
              )}
            </View>

            {/* Contacto */}
            <View style={s.infoCard}>
              <Text style={s.infoCardTitle}>Contacto</Text>
              <View style={s.contactRow}>
                <View style={s.contactIcon}><Phone size={14} color={COLORS.green} /></View>
                <View style={{ flex: 1 }}>
                  <Text style={s.contactLabel}>Teléfono</Text>
                  <Text style={s.contactValue}>{selected.phone ?? '—'}</Text>
                </View>
              </View>
              <View style={[s.contactRow, { borderBottomWidth: 0 }]}>
                <View style={s.contactIcon}><Mail size={14} color={COLORS.green} /></View>
                <View style={{ flex: 1 }}>
                  <Text style={s.contactLabel}>Correo electrónico</Text>
                  {contactLoading
                    ? <ActivityIndicator size="small" color={COLORS.green} style={{ alignSelf: 'flex-start', marginTop: 4 }} />
                    : <Text style={s.contactValue}>{ownerEmail ?? '—'}</Text>}
                </View>
              </View>
            </View>

            {/* Ir a moderar */}
            <Pressable style={s.moderateFullBtn} onPress={() => openModerate(selected)}>
              <Shield size={16} color={COLORS.bg} />
              <Text style={s.moderateFullBtnText}>Ir a moderar este talento</Text>
            </Pressable>

            <View style={{ height: 32 }} />
          </ScrollView>
        </SafeAreaView>
      </View>
    );
  }

  // ── VISTA: MODERAR ─────────────────────────────────────────────────────────

  if (view === 'moderate' && selected) {
    return (
      <View style={s.container}>
        <Particles />
        <SafeAreaView edges={['top']} style={{ flex: 1 }}>
          <View style={s.header}>
            <Pressable style={s.backBtn} onPress={() => setView('list')}>
              <ArrowLeft size={20} color={COLORS.text} />
            </Pressable>
            <Text style={s.headerTitle} numberOfLines={1}>
              Moderar · {selected.full_name}
            </Text>
            <Pressable style={s.iconBtn} onPress={() => openProfile(selected)}>
              <ChevronRight size={17} color={COLORS.muted2} />
            </Pressable>
          </View>

          <ScrollView
            contentContainerStyle={s.scroll}
            showsVerticalScrollIndicator={false}
            keyboardShouldPersistTaps="handled"
          >
            {/* Estado actual */}
            <View style={s.moderateCard}>
              <Text style={s.moderateCardTitle}>Estado actual</Text>
              <View style={s.statusRow}>
                <View style={[s.statusChip, selected.admin_verified ? s.chipVerified : s.chipNone]}>
                  {selected.admin_verified
                    ? <ShieldCheck size={11} color={COLORS.blue} />
                    : <Shield size={11} color={COLORS.muted} />}
                  <Text style={[s.statusChipText, selected.admin_verified && { color: COLORS.blue }]}>
                    {selected.admin_verified ? 'Verificado' : 'Sin verificar'}
                  </Text>
                </View>
                {selected.verification_status === 'pending' && (
                  <View style={[s.statusChip, { backgroundColor: 'rgba(255,152,0,0.1)', borderColor: 'rgba(255,152,0,0.4)' }]}>
                    <Text style={[s.statusChipText, { color: COLORS.orange }]}>Solicitud pendiente</Text>
                  </View>
                )}
              </View>
            </View>

            {/* Nota interna */}
            <View style={s.moderateCard}>
              <Text style={s.moderateCardTitle}>Nota interna</Text>
              <Text style={s.moderateCardHint}>
                Requerida al quitar verificación. Opcional al verificar.
              </Text>
              <TextInput
                style={s.notesInput}
                value={moderateNote}
                onChangeText={setModerateNote}
                placeholder="Razón o comentario..."
                placeholderTextColor={COLORS.muted}
                multiline
                numberOfLines={3}
                textAlignVertical="top"
              />
            </View>

            {/* Acciones */}
            <View style={s.moderateCard}>
              <Text style={s.moderateCardTitle}>Acciones</Text>
              <View style={{ gap: 10 }}>
                {selected.admin_verified ? (
                  <Pressable
                    style={[s.modActionBtn, s.modActionBtnRed, actionLoading && { opacity: 0.6 }]}
                    onPress={() => handleVerify(false)}
                    disabled={actionLoading}
                  >
                    {actionLoading
                      ? <ActivityIndicator size="small" color="#fff" />
                      : <>
                          <X size={16} color="#fff" />
                          <Text style={[s.modActionBtnText, { color: '#fff' }]}>Quitar verificación</Text>
                        </>}
                  </Pressable>
                ) : (
                  <Pressable
                    style={[s.modActionBtn, s.modActionBtnGreen, actionLoading && { opacity: 0.6 }]}
                    onPress={() => handleVerify(true)}
                    disabled={actionLoading}
                  >
                    {actionLoading
                      ? <ActivityIndicator size="small" color={COLORS.bg} />
                      : <>
                          <ShieldCheck size={16} color={COLORS.bg} />
                          <Text style={[s.modActionBtnText, { color: COLORS.bg }]}>Verificar talento gratis</Text>
                        </>}
                  </Pressable>
                )}
              </View>
            </View>

            <View style={{ height: 32 }} />
          </ScrollView>
        </SafeAreaView>
      </View>
    );
  }

  return null;
}

// ─── Sub-component ────────────────────────────────────────────────────────────

function InfoRow({ label, value, color }: { label: string; value: string; color?: string }) {
  return (
    <View style={s.infoRow}>
      <Text style={s.infoLabel}>{label}</Text>
      <Text style={[s.infoValue, color ? { color } : null]} numberOfLines={2}>{value}</Text>
    </View>
  );
}

// ─── Styles ───────────────────────────────────────────────────────────────────

const s = StyleSheet.create({
  container: { flex: 1, backgroundColor: COLORS.bg },

  header: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between',
    paddingHorizontal: SPACING.xl, paddingVertical: 14,
    borderBottomWidth: 1, borderBottomColor: COLORS.border,
  },
  backBtn: {
    width: 40, height: 40, borderRadius: 12,
    backgroundColor: COLORS.card, borderWidth: 1, borderColor: COLORS.border,
    alignItems: 'center', justifyContent: 'center',
  },
  iconBtn: {
    width: 40, height: 40, borderRadius: 12,
    backgroundColor: COLORS.card, borderWidth: 1, borderColor: COLORS.border,
    alignItems: 'center', justifyContent: 'center',
  },
  headerTitle: {
    fontFamily: FONTS.bodySemiBold, fontSize: 16, color: COLORS.text,
    flex: 1, textAlign: 'center', marginHorizontal: 8,
  },
  countBadge: {
    backgroundColor: COLORS.greenMuted, borderRadius: RADIUS.full,
    borderWidth: 1, borderColor: COLORS.green,
    paddingHorizontal: 10, paddingVertical: 3, minWidth: 40, alignItems: 'center',
  },
  countBadgeText: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.green },

  list: { flexDirection: 'row', flexWrap: 'wrap', gap: 6, padding: SPACING.xl, paddingBottom: 40 },
  scroll:    { padding: SPACING.xl, gap: 16, paddingBottom: 40 },
  empty:     { alignItems: 'center', paddingTop: 60 },
  emptyText: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted, textAlign: 'center' },

  searchRow: {
    flexDirection: 'row', alignItems: 'center', gap: 10,
    backgroundColor: COLORS.card, borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: COLORS.border,
    paddingHorizontal: 14, paddingVertical: 10,
    marginHorizontal: SPACING.xl, marginBottom: 6,
  },
  searchInput: { flex: 1, fontFamily: FONTS.body, fontSize: 13, color: COLORS.text },
  pillsWrap: {
    height: 44,
  },
  pillsRow: {
    flexDirection: 'row',
    alignItems: 'center',
    paddingHorizontal: SPACING.xl,
    gap: 6,
  },
  pill: {
    height: 28,
    borderRadius: 14,
    borderWidth: 1,
    borderColor: '#2a2a2a',
    flexDirection: 'row',
    alignItems: 'center',
    paddingHorizontal: 10,
    gap: 4,
  },
  pillActive:        { backgroundColor: COLORS.green, borderColor: COLORS.green },
  pillState:         { borderColor: '#303030' },
  pillCountry:       { borderColor: `${COLORS.green}60` },
  pillCountryActive: { backgroundColor: COLORS.green, borderColor: COLORS.green },
  pillText:          { fontFamily: FONTS.bodyMedium, fontSize: 10, color: COLORS.muted },
  pillTextCountry:   { color: COLORS.green },
  pillTextActive:    { color: COLORS.bg },
  pillCount:         { fontFamily: FONTS.bodyMedium, fontSize: 9, color: COLORS.muted },
  pillCountCountry:  { color: COLORS.green },
  pillCountActive:   { color: 'rgba(0,0,0,0.45)' },
  resultCount:    { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted, paddingHorizontal: SPACING.xl, marginBottom: 4 },

  // Grid card — 4 columnas
  gridCard: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border,
    padding: 7, alignItems: 'center', overflow: 'hidden',
  },
  gridAvatarWrap: { position: 'relative', marginBottom: 5 },
  gridAvatar: { width: 38, height: 38, borderRadius: 19 },
  gridAvatarEmpty: {
    backgroundColor: COLORS.card2, borderWidth: 1, borderColor: COLORS.border,
    alignItems: 'center', justifyContent: 'center',
  },
  gridAvatarInitial: { fontFamily: FONTS.title, fontSize: 13, color: COLORS.green },
  gridVerifiedBadge: {
    position: 'absolute', bottom: -2, right: -2,
    backgroundColor: COLORS.bg, borderRadius: 7, padding: 1,
  },
  gridName: {
    fontFamily: FONTS.bodySemiBold, fontSize: 10, color: COLORS.text,
    textAlign: 'center', width: '100%',
  },
  gridSub: {
    fontFamily: FONTS.body, fontSize: 9, color: COLORS.muted2,
    textAlign: 'center', width: '100%', marginTop: 1,
  },
  gridMetas: { width: '100%', gap: 2, marginTop: 3 },
  gridMetaRow: { flexDirection: 'row', alignItems: 'center', gap: 3 },
  gridMetaText: { fontFamily: FONTS.body, fontSize: 9, color: COLORS.muted, flex: 1 },
  gridMetaRating: { fontFamily: FONTS.bodyMedium, fontSize: 9, color: COLORS.gold },
  gridActions: {
    flexDirection: 'row', gap: 4, width: '100%',
    marginTop: 5, paddingTop: 5,
    borderTopWidth: 1, borderTopColor: COLORS.border,
  },
  gridActionBtn: {
    flex: 1, alignItems: 'center', justifyContent: 'center',
    paddingVertical: 4, borderRadius: RADIUS.sm,
    backgroundColor: COLORS.card2,
  },
  gridModBtn: { backgroundColor: COLORS.greenMuted },

  // Status chips
  statusRow: { flexDirection: 'row', gap: 8, flexWrap: 'wrap', marginBottom: 4 },
  statusChip: {
    flexDirection: 'row', alignItems: 'center', gap: 5,
    paddingHorizontal: 10, paddingVertical: 5,
    borderRadius: RADIUS.full, borderWidth: 1,
  },
  statusChipText: { fontFamily: FONTS.bodyMedium, fontSize: 11, color: COLORS.muted2 },
  statusDot: { width: 7, height: 7, borderRadius: 4 },
  chipVerified:  { backgroundColor: 'rgba(66,133,244,0.1)',  borderColor: 'rgba(66,133,244,0.35)' },
  chipNone:      { backgroundColor: COLORS.card2,            borderColor: COLORS.border },
  chipActive:    { backgroundColor: COLORS.greenMuted,       borderColor: `${COLORS.green}50` },

  // Profile view
  profilePhotoWrap: { alignSelf: 'center', marginBottom: 8 },
  profilePhoto:     { width: 90, height: 90, borderRadius: 45 },
  profilePhotoEmpty: {
    backgroundColor: COLORS.card2, borderWidth: 1.5, borderColor: COLORS.border,
    alignItems: 'center', justifyContent: 'center',
  },
  profilePhotoInitial: { fontFamily: FONTS.title, fontSize: 34, color: COLORS.green },

  // Info cards
  infoCard: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border, padding: SPACING.lg,
  },
  infoCardTitle: {
    fontFamily: FONTS.bodySemiBold, fontSize: 11, color: COLORS.muted2,
    textTransform: 'uppercase', letterSpacing: 0.8, marginBottom: 12,
  },
  infoRow: {
    flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center',
    paddingVertical: 8, borderBottomWidth: 1, borderBottomColor: COLORS.border,
  },
  infoRowFull: { paddingVertical: 8, borderBottomWidth: 1, borderBottomColor: COLORS.border },
  infoLabel:      { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted2 },
  infoValue:      { fontFamily: FONTS.body, fontSize: 13, color: COLORS.text, textAlign: 'right', flex: 1, marginLeft: 12 },
  infoValueMulti: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.text, marginTop: 4, lineHeight: 20 },

  // Contact
  contactRow: {
    flexDirection: 'row', alignItems: 'flex-start', gap: 12,
    paddingVertical: 10, borderBottomWidth: 1, borderBottomColor: COLORS.border,
  },
  contactIcon: {
    width: 32, height: 32, borderRadius: 8,
    backgroundColor: COLORS.greenMuted, borderWidth: 1, borderColor: `${COLORS.green}40`,
    alignItems: 'center', justifyContent: 'center',
  },
  contactLabel: { fontFamily: FONTS.bodyMedium, fontSize: 11, color: COLORS.muted2, marginBottom: 3 },
  contactValue: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.text },

  // Moderate full button
  moderateFullBtn: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 10,
    backgroundColor: COLORS.green, borderRadius: RADIUS.lg, paddingVertical: 14,
  },
  moderateFullBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.bg },

  // Moderate cards
  moderateCard: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border, padding: SPACING.lg,
  },
  moderateCardTitle: {
    fontFamily: FONTS.bodySemiBold, fontSize: 11, color: COLORS.muted2,
    textTransform: 'uppercase', letterSpacing: 0.8, marginBottom: 12,
  },
  moderateCardHint: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted, marginBottom: 10 },
  notesInput: {
    backgroundColor: COLORS.bg, borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: COLORS.border,
    padding: 12, fontFamily: FONTS.body, fontSize: 14, color: COLORS.text, minHeight: 80,
  },

  modActionBtn: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'center',
    gap: 8, paddingVertical: 13, borderRadius: RADIUS.md,
  },
  modActionBtnText:    { fontFamily: FONTS.bodySemiBold, fontSize: 14 },
  modActionBtnGreen:   { backgroundColor: COLORS.green },
  modActionBtnRed:     { backgroundColor: '#EF5350' },
});
