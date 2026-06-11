/**
 * AdminGroupsScreen — Gestión de grupos para administradores.
 *
 * 3 vistas internas (sin cambio de ruta):
 *   'list'     — listado de grupos con acciones rápidas
 *   'profile'  — perfil completo del grupo + contacto del propietario
 *   'moderate' — verificar/suspender + historial de acciones
 *
 * Paquetes eliminados en su totalidad (los grupos ya no usan paquetes).
 * Email y teléfono solo visibles para el administrador.
 */
import {
  ArrowLeft,
  Camera,
  CheckCircle,
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
import { SafeAreaView } from 'react-native-safe-area-context';
import { supabase } from '../../config/supabase';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';
import Particles from '../../components/ui/Particles';
import VerifiedBadge from '../../components/ui/VerifiedBadge';
import { pickAndUploadGroupImage } from '../../utils/uploadGroupImage';
import { stateToCountry } from '../../utils/locationUtils';

type AdminView = 'list' | 'profile' | 'moderate';

// ─── Screen ───────────────────────────────────────────────────────────────────

export default function AdminGroupsScreen({ navigation }: any) {
  const { width: screenW } = useWindowDimensions();
  const CARD_W = Math.floor((screenW - SPACING.xl * 2 - 6 * 3) / 4);

  const [view,        setView]        = useState<AdminView>('list');
  const [groups,      setGroups]      = useState<any[]>([]);
  const [selected,    setSelected]    = useState<any>(null);
  const [refreshing,  setRefreshing]  = useState(false);
  const [search,        setSearch]        = useState('');
  const [activeState,   setActiveState]   = useState<string | null>(null);
  const [activeCountry, setActiveCountry] = useState<string | null>(null);

  // Profile view
  const [ownerEmail,     setOwnerEmail]     = useState<string | null>(null);
  const [contactLoading, setContactLoading] = useState(false);
  const [completedCount, setCompletedCount] = useState(0);
  const [photoLoading,   setPhotoLoading]   = useState(false);

  // Moderate view
  const [moderateNote,        setModerateNote]        = useState('');
  const [actionLoading,       setActionLoading]       = useState(false);
  const [verificationHistory, setVerificationHistory] = useState<any[]>([]);

  useEffect(() => { fetchGroups(); }, []);

  // ── Data ──────────────────────────────────────────────────────────────────

  const fetchGroups = async () => {
    const { data } = await supabase
      .from('groups')
      .select(`
        id, name, city, state, genre, description,
        is_verified, admin_verified, is_active,
        is_plus_active,
        rating, total_reviews, created_at,
        profile_image, owner_id,
        verification_status, strike_count,
        owner:profiles!owner_id(id, full_name, phone, country)
      `)
      .order('created_at', { ascending: false });
    if (data) setGroups(data);
  };

  const countries = useMemo(() => {
    const c = new Set<string>();
    groups.forEach(g => c.add(stateToCountry(g.state)));
    return Array.from(c).sort();
  }, [groups]);

  const countryCounts = useMemo(() => {
    const c: Record<string, number> = {};
    groups.forEach(g => {
      const k = stateToCountry(g.state);
      c[k] = (c[k] ?? 0) + 1;
    });
    return c;
  }, [groups]);

  const states = useMemo(() => {
    const base = activeCountry
      ? groups.filter(g => stateToCountry(g.state) === activeCountry)
      : groups;
    const s = new Set<string>();
    base.forEach(g => { if (g.state?.trim()) s.add(g.state.trim()); });
    return Array.from(s).sort();
  }, [groups, activeCountry]);

  const stateCounts = useMemo(() => {
    const base = activeCountry
      ? groups.filter(g => stateToCountry(g.state) === activeCountry)
      : groups;
    const c: Record<string, number> = {};
    base.forEach(g => {
      const k = g.state?.trim();
      if (k) c[k] = (c[k] ?? 0) + 1;
    });
    return c;
  }, [groups, activeCountry]);

  const filteredGroups = useMemo(() => {
    let list = groups;
    if (search.trim()) {
      const q = search.toLowerCase();
      list = list.filter(g =>
        g.name?.toLowerCase().includes(q) ||
        g.state?.toLowerCase().includes(q)
      );
    }
    if (activeCountry) list = list.filter(g => stateToCountry(g.state) === activeCountry);
    if (activeState)   list = list.filter(g => g.state?.trim().toLowerCase() === activeState.toLowerCase());
    return list;
  }, [groups, search, activeCountry, activeState]);

  const toggleCountry = (country: string) => {
    if (activeCountry === country) {
      setActiveCountry(null);
      setActiveState(null);
    } else {
      setActiveCountry(country);
      setActiveState(null);
    }
  };

  const onRefresh = async () => {
    setRefreshing(true);
    await fetchGroups();
    setRefreshing(false);
  };

  const openProfile = async (group: any) => {
    setSelected(group);
    setOwnerEmail(null);
    setCompletedCount(0);
    setView('profile');

    setContactLoading(true);
    const { data } = await supabase.rpc('admin_get_user_contact', {
      p_user_id: group.owner_id,
    });
    if (data?.ok) setOwnerEmail(data.email ?? null);
    setContactLoading(false);

    const { count } = await supabase
      .from('reservations')
      .select('id', { count: 'exact', head: true })
      .eq('group_id', group.id)
      .eq('status', 'completed');
    setCompletedCount(count ?? 0);
  };

  const openModerate = async (group: any) => {
    setSelected(group);
    setModerateNote('');
    setView('moderate');

    const { data: hist } = await supabase
      .from('verification_requests')
      .select('id, status, admin_notes, submitted_at, reviewed_at')
      .eq('group_id', group.id)
      .order('submitted_at', { ascending: false })
      .limit(10);
    setVerificationHistory(hist ?? []);
  };

  const handleVerify = async (verified: boolean) => {
    if (!selected) return;
    if (!verified && !moderateNote.trim()) {
      Alert.alert('Nota requerida', 'Agrega una nota explicando por qué se quita la verificación.');
      return;
    }
    setActionLoading(true);
    const { data, error } = await supabase.rpc('admin_set_group_verified', {
      p_group_id: selected.id,
      p_verified: verified,
      p_note:     moderateNote.trim() || null,
    });
    setActionLoading(false);

    if (error || !data?.ok) {
      Alert.alert('Error', error?.message ?? data?.error ?? 'No se pudo actualizar.');
      return;
    }

    const newStatus = verified ? 'approved' : 'rejected';
    const updated = {
      ...selected,
      is_verified:         verified,
      admin_verified:      verified,
      verification_status: newStatus,
    };
    setSelected(updated);
    setGroups(prev => prev.map(g =>
      g.id === selected.id
        ? { ...g, is_verified: verified, admin_verified: verified, verification_status: newStatus }
        : g
    ));
    setModerateNote('');

    const { data: hist } = await supabase
      .from('verification_requests')
      .select('id, status, admin_notes, submitted_at, reviewed_at')
      .eq('group_id', selected.id)
      .order('submitted_at', { ascending: false })
      .limit(10);
    setVerificationHistory(hist ?? []);

    Alert.alert(
      verified ? '✅ Verificado' : '✓ Listo',
      verified
        ? `${selected.name} ahora está verificado.`
        : 'Verificación removida correctamente.'
    );
  };

  const handleToggleActive = async () => {
    if (!selected || actionLoading) return;
    const newVal = !selected.is_active;
    Alert.alert(
      newVal ? 'Activar grupo' : 'Suspender grupo',
      `¿${newVal ? 'Activar' : 'Suspender'} a ${selected.name}?`,
      [
        { text: 'Cancelar', style: 'cancel' },
        {
          text: newVal ? 'Activar' : 'Suspender',
          style: newVal ? 'default' : 'destructive',
          onPress: async () => {
            setActionLoading(true);
            const { error } = await supabase.from('groups')
              .update({ is_active: newVal })
              .eq('id', selected.id);
            setActionLoading(false);
            if (error) {
              Alert.alert('Error', 'No se pudo actualizar el estado. Intenta de nuevo.');
              return;
            }
            const updated = { ...selected, is_active: newVal };
            setSelected(updated);
            setGroups(prev => prev.map(g =>
              g.id === selected.id ? { ...g, is_active: newVal } : g
            ));
          },
        },
      ]
    );
  };

  const handlePhoto = async () => {
    if (!selected) return;
    try {
      setPhotoLoading(true);
      const url = await pickAndUploadGroupImage(selected.id);
      if (url) {
        const updated = { ...selected, profile_image: url };
        setSelected(updated);
        setGroups(prev => prev.map(g =>
          g.id === selected.id ? { ...g, profile_image: url } : g
        ));
      }
    } catch (e: any) {
      Alert.alert('Error', e.message ?? 'No se pudo subir la imagen');
    } finally {
      setPhotoLoading(false);
    }
  };

  // ── VISTA: LISTA ───────────────────────────────────────────────────────────

  if (view === 'list') {
    return (
      <View style={s.container}>
        <Particles />
        <SafeAreaView style={{ flex: 1 }}>
          <View style={s.header}>
            <Pressable style={s.backBtn} onPress={() => navigation.goBack()}>
              <ArrowLeft size={20} color={COLORS.text} />
            </Pressable>
            <Text style={s.headerTitle}>Grupos registrados</Text>
            <View style={s.countBadge}>
              <Text style={s.countBadgeText}>{groups.length}</Text>
            </View>
          </View>

          {/* Buscador */}
          <View style={s.searchRow}>
            <Search size={14} color={COLORS.muted} />
            <TextInput
              style={s.searchInput}
              placeholder="Buscar por nombre, ciudad o estado..."
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
            <Text style={s.resultCount}>{filteredGroups.length} de {groups.length} grupos</Text>
          )}

          <ScrollView
            style={{ flex: 1 }}
            contentContainerStyle={s.list}
            showsVerticalScrollIndicator={false}
            refreshControl={
              <RefreshControl refreshing={refreshing} onRefresh={onRefresh} tintColor={COLORS.green} />
            }
          >
            {filteredGroups.length === 0 && (
              <View style={s.empty}>
                <Text style={s.emptyText}>{search || activeState ? 'Sin coincidencias' : 'Sin grupos registrados'}</Text>
              </View>
            )}
            {filteredGroups.map(group => (
              <View key={group.id} style={[s.gridCard, { width: CARD_W }]}>
                {/* Foto + indicadores */}
                <View style={s.gridPhotoWrap}>
                  {group.profile_image ? (
                    <Image source={{ uri: group.profile_image }} style={s.gridPhoto} />
                  ) : (
                    <View style={[s.gridPhoto, s.gridPhotoEmpty]}>
                      <Text style={s.gridPhotoInitial}>
                        {group.name?.charAt(0)?.toUpperCase() ?? '?'}
                      </Text>
                    </View>
                  )}
                  <View style={[s.gridActiveDot, {
                    backgroundColor: group.is_active ? COLORS.green : '#EF5350',
                  }]} />
                  {group.is_verified && (
                    <VerifiedBadge
                      size={16}
                      tier={group.is_plus_active ? 'plus' : 'free'}
                      style={{ position: 'absolute', bottom: 0, right: 0 }}
                    />
                  )}
                </View>

                <Text style={s.gridName} numberOfLines={1}>{group.name}</Text>
                <Text style={s.gridSub} numberOfLines={1}>{group.genre ?? '—'}</Text>

                <View style={s.gridMetas}>
                  {group.city ? (
                    <View style={s.gridMetaRow}>
                      <MapPin size={9} color={COLORS.muted} />
                      <Text style={s.gridMetaText} numberOfLines={1}>{group.city}</Text>
                    </View>
                  ) : null}
                  {group.rating != null && Number(group.rating) > 0 ? (
                    <View style={s.gridMetaRow}>
                      <Star size={9} color={COLORS.gold} fill={COLORS.gold} />
                      <Text style={s.gridMetaRating}>{Number(group.rating).toFixed(1)}</Text>
                    </View>
                  ) : null}
                </View>

                <View style={s.gridActions}>
                  <Pressable style={s.gridActionBtn} onPress={() => openProfile(group)} hitSlop={6}>
                    <ChevronRight size={13} color={COLORS.muted2} />
                  </Pressable>
                  <Pressable style={[s.gridActionBtn, s.gridModBtn]} onPress={() => openModerate(group)} hitSlop={6}>
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
    const memberMonths = Math.floor(
      (Date.now() - new Date(selected.created_at).getTime()) / (1000 * 60 * 60 * 24 * 30)
    );
    const memberLabel = memberMonths === 0
      ? 'Menos de 1 mes'
      : `${memberMonths} mes${memberMonths !== 1 ? 'es' : ''}`;

    return (
      <View style={s.container}>
        <Particles />
        <SafeAreaView style={{ flex: 1 }}>
          <View style={s.header}>
            <Pressable style={s.backBtn} onPress={() => setView('list')}>
              <ArrowLeft size={20} color={COLORS.text} />
            </Pressable>
            <Text style={s.headerTitle} numberOfLines={1}>{selected.name}</Text>
            <Pressable style={s.iconBtn} onPress={() => openModerate(selected)}>
              <Shield size={17} color={COLORS.green} />
            </Pressable>
          </View>

          <ScrollView
            contentContainerStyle={s.scroll}
            showsVerticalScrollIndicator={false}
          >
            {/* Foto editable */}
            <Pressable style={s.profilePhotoWrap} onPress={handlePhoto} disabled={photoLoading}>
              {selected.profile_image ? (
                <Image source={{ uri: selected.profile_image }} style={s.profilePhoto} />
              ) : (
                <View style={[s.profilePhoto, s.profilePhotoEmpty]}>
                  <Text style={s.profilePhotoInitial}>
                    {selected.name?.charAt(0)?.toUpperCase() ?? '?'}
                  </Text>
                </View>
              )}
              <View style={s.profileCameraBtn}>
                {photoLoading
                  ? <ActivityIndicator size="small" color="#fff" />
                  : <Camera size={14} color="#fff" />}
              </View>
            </Pressable>

            {/* Chips de estado */}
            <View style={s.statusRow}>
              <View style={[s.statusChip,
                selected.is_verified ? s.chipVerified : s.chipNone]}>
                {selected.is_verified
                  ? <ShieldCheck size={11} color={COLORS.blue} />
                  : <Shield size={11} color={COLORS.muted} />}
                <Text style={[s.statusChipText,
                  selected.is_verified && { color: COLORS.blue }]}>
                  {selected.is_verified ? 'Verificado' : 'Sin verificar'}
                </Text>
              </View>
              <View style={[s.statusChip,
                selected.is_active ? s.chipActive : s.chipInactive]}>
                <View style={[s.statusDot, {
                  backgroundColor: selected.is_active ? COLORS.green : '#EF5350',
                }]} />
                <Text style={[s.statusChipText, {
                  color: selected.is_active ? COLORS.green : '#EF5350',
                }]}>
                  {selected.is_active ? 'Activo' : 'Inactivo'}
                </Text>
              </View>
              {selected.admin_verified && (
                <View style={[s.statusChip, s.chipAdminVerified]}>
                  <CheckCircle size={11} color={COLORS.green} />
                  <Text style={[s.statusChipText, { color: COLORS.green }]}>Admin ✓</Text>
                </View>
              )}
            </View>

            {/* Info básica */}
            <View style={s.infoCard}>
              <Text style={s.infoCardTitle}>Información del grupo</Text>
              <InfoRow label="Nombre"     value={selected.name} />
              <InfoRow label="Género"     value={selected.genre ?? '—'} />
              <InfoRow label="Ciudad"     value={selected.city  ?? '—'} />
              <InfoRow label="Alta"       value={new Date(selected.created_at).toLocaleDateString('es-MX')} />
              <InfoRow label="Antigüedad" value={memberLabel} />
              {selected.description ? (
                <View style={s.infoRowFull}>
                  <Text style={s.infoLabel}>Descripción</Text>
                  <Text style={s.infoValueMulti}>{selected.description}</Text>
                </View>
              ) : null}
            </View>

            {/* Actividad */}
            <View style={s.infoCard}>
              <Text style={s.infoCardTitle}>Actividad</Text>
              {selected.rating != null ? (
                <InfoRow
                  label="Rating"
                  value={`★ ${Number(selected.rating).toFixed(1)}  (${selected.total_reviews ?? 0} reseñas)`}
                />
              ) : (
                <InfoRow label="Rating" value="Sin reseñas" />
              )}
              <InfoRow label="Eventos completados" value={String(completedCount)} />
              {(selected.strike_count ?? 0) > 0 && (
                <InfoRow label="Strikes" value={String(selected.strike_count)} color="#EF5350" />
              )}
            </View>

            {/* Contacto — solo visible para el admin */}
            <View style={s.infoCard}>
              <Text style={s.infoCardTitle}>Contacto del propietario</Text>
              <View style={s.contactRow}>
                <View style={s.contactIcon}>
                  <Phone size={14} color={COLORS.green} />
                </View>
                <View style={{ flex: 1 }}>
                  <Text style={s.contactLabel}>Teléfono</Text>
                  <Text style={s.contactValue}>{selected.owner?.phone ?? '—'}</Text>
                </View>
              </View>
              <View style={[s.contactRow, { borderBottomWidth: 0 }]}>
                <View style={s.contactIcon}>
                  <Mail size={14} color={COLORS.green} />
                </View>
                <View style={{ flex: 1 }}>
                  <Text style={s.contactLabel}>Correo electrónico</Text>
                  {contactLoading
                    ? <ActivityIndicator size="small" color={COLORS.green}
                        style={{ alignSelf: 'flex-start', marginTop: 4 }} />
                    : <Text style={s.contactValue}>{ownerEmail ?? '—'}</Text>}
                </View>
              </View>
            </View>

            {/* Botón ir a moderar */}
            <Pressable style={s.moderateFullBtn} onPress={() => openModerate(selected)}>
              <Shield size={16} color={COLORS.bg} />
              <Text style={s.moderateFullBtnText}>Ir a moderar este grupo</Text>
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
        <SafeAreaView style={{ flex: 1 }}>
          <View style={s.header}>
            <Pressable style={s.backBtn} onPress={() => setView('list')}>
              <ArrowLeft size={20} color={COLORS.text} />
            </Pressable>
            <Text style={s.headerTitle} numberOfLines={1}>
              Moderar · {selected.name}
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
                <View style={[s.statusChip,
                  selected.is_verified ? s.chipVerified : s.chipNone]}>
                  {selected.is_verified
                    ? <ShieldCheck size={11} color={COLORS.blue} />
                    : <Shield size={11} color={COLORS.muted} />}
                  <Text style={[s.statusChipText,
                    selected.is_verified && { color: COLORS.blue }]}>
                    {selected.is_verified ? 'Verificado' : 'Sin verificar'}
                  </Text>
                </View>
                <View style={[s.statusChip,
                  selected.is_active ? s.chipActive : s.chipInactive]}>
                  <View style={[s.statusDot, {
                    backgroundColor: selected.is_active ? COLORS.green : '#EF5350',
                  }]} />
                  <Text style={[s.statusChipText, {
                    color: selected.is_active ? COLORS.green : '#EF5350',
                  }]}>
                    {selected.is_active ? 'Activo' : 'Inactivo'}
                  </Text>
                </View>
                {selected.admin_verified && (
                  <View style={[s.statusChip, s.chipAdminVerified]}>
                    <CheckCircle size={11} color={COLORS.green} />
                    <Text style={[s.statusChipText, { color: COLORS.green }]}>Admin ✓</Text>
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

                {selected.is_verified ? (
                  <Pressable
                    style={[s.modActionBtn, s.modActionBtnRed,
                      actionLoading && { opacity: 0.6 }]}
                    onPress={() => handleVerify(false)}
                    disabled={actionLoading}
                  >
                    {actionLoading
                      ? <ActivityIndicator size="small" color="#fff" />
                      : <>
                          <X size={16} color="#fff" />
                          <Text style={[s.modActionBtnText, { color: '#fff' }]}>
                            Quitar verificación
                          </Text>
                        </>}
                  </Pressable>
                ) : (
                  <Pressable
                    style={[s.modActionBtn, s.modActionBtnGreen,
                      actionLoading && { opacity: 0.6 }]}
                    onPress={() => handleVerify(true)}
                    disabled={actionLoading}
                  >
                    {actionLoading
                      ? <ActivityIndicator size="small" color={COLORS.bg} />
                      : <>
                          <ShieldCheck size={16} color={COLORS.bg} />
                          <Text style={[s.modActionBtnText, { color: COLORS.bg }]}>
                            Verificar grupo
                          </Text>
                        </>}
                  </Pressable>
                )}

                <Pressable
                  style={[
                    s.modActionBtn,
                    selected.is_active ? s.modActionBtnOutlineRed : s.modActionBtnOutlineGreen,
                    actionLoading && { opacity: 0.6 },
                  ]}
                  onPress={handleToggleActive}
                  disabled={actionLoading}
                >
                  <Text style={[s.modActionBtnText, {
                    color: selected.is_active ? '#EF5350' : COLORS.green,
                  }]}>
                    {selected.is_active ? 'Suspender grupo' : 'Activar grupo'}
                  </Text>
                </Pressable>
              </View>
            </View>

            {/* Historial */}
            <View style={s.moderateCard}>
              <Text style={s.moderateCardTitle}>
                Historial{verificationHistory.length > 0 ? ` (${verificationHistory.length})` : ''}
              </Text>
              {verificationHistory.length === 0 ? (
                <Text style={s.emptyText}>Sin solicitudes anteriores</Text>
              ) : (
                verificationHistory.map((h, i) => (
                  <View
                    key={h.id ?? i}
                    style={[
                      s.historyRow,
                      i < verificationHistory.length - 1 && s.historyRowDivider,
                    ]}
                  >
                    <View style={[s.historyDot, {
                      backgroundColor:
                        h.status === 'approved' ? COLORS.green  :
                        h.status === 'rejected' ? '#EF5350' :
                        COLORS.orange,
                    }]} />
                    <View style={{ flex: 1, gap: 2 }}>
                      <Text style={s.historyStatus}>
                        {h.status === 'approved' ? '✓ Aprobado'  :
                         h.status === 'rejected' ? '✗ Rechazado' : '⏳ Pendiente'}
                      </Text>
                      {h.admin_notes ? (
                        <Text style={s.historyNotes}>{h.admin_notes}</Text>
                      ) : null}
                      <Text style={s.historyDate}>
                        {new Date(h.reviewed_at ?? h.submitted_at).toLocaleDateString('es-MX', {
                          day: 'numeric', month: 'short', year: 'numeric',
                        })}
                      </Text>
                    </View>
                  </View>
                ))
              )}
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
      <Text style={[s.infoValue, color ? { color } : null]} numberOfLines={2}>
        {value}
      </Text>
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

  // Search + filter
  searchRow: {
    flexDirection: 'row', alignItems: 'center', gap: 10,
    backgroundColor: COLORS.card, borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: COLORS.border,
    paddingHorizontal: 14, paddingVertical: 10,
    marginHorizontal: SPACING.xl, marginBottom: 6,
  },
  searchInput: {
    flex: 1, fontFamily: FONTS.body, fontSize: 13, color: COLORS.text,
  },
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
  resultCount: {
    fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted,
    paddingHorizontal: SPACING.xl, marginBottom: 4,
  },

  // Grid card — 4 columnas
  gridCard: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border,
    padding: 7, alignItems: 'center', overflow: 'hidden',
  },
  gridPhotoWrap: { position: 'relative', marginBottom: 5 },
  gridPhoto: { width: 38, height: 38, borderRadius: 10 },
  gridPhotoEmpty: {
    backgroundColor: COLORS.card2, borderWidth: 1, borderColor: COLORS.border,
    alignItems: 'center', justifyContent: 'center',
  },
  gridPhotoInitial: { fontFamily: FONTS.title, fontSize: 13, color: COLORS.green },
  gridActiveDot: {
    position: 'absolute', top: 1, right: 1,
    width: 7, height: 7, borderRadius: 4,
    borderWidth: 1.5, borderColor: COLORS.bg,
  },
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
  statusRow: {
    flexDirection: 'row', gap: 8, flexWrap: 'wrap',
    marginBottom: 4,
  },
  statusChip: {
    flexDirection: 'row', alignItems: 'center', gap: 5,
    paddingHorizontal: 10, paddingVertical: 5,
    borderRadius: RADIUS.full, borderWidth: 1,
  },
  statusChipText: { fontFamily: FONTS.bodyMedium, fontSize: 11, color: COLORS.muted2 },
  statusDot:      { width: 7, height: 7, borderRadius: 4 },
  chipVerified:      { backgroundColor: 'rgba(66,133,244,0.1)',  borderColor: 'rgba(66,133,244,0.35)' },
  chipNone:          { backgroundColor: COLORS.card2,            borderColor: COLORS.border },
  chipActive:        { backgroundColor: COLORS.greenMuted,       borderColor: `${COLORS.green}50` },
  chipInactive:      { backgroundColor: 'rgba(239,83,80,0.08)',  borderColor: 'rgba(239,83,80,0.35)' },
  chipAdminVerified: { backgroundColor: COLORS.greenMuted,       borderColor: COLORS.green },

  // Profile photo
  profilePhotoWrap: { alignSelf: 'center', position: 'relative', marginBottom: 8 },
  profilePhoto: { width: 90, height: 90, borderRadius: 22 },
  profilePhotoEmpty: {
    backgroundColor: COLORS.card2, borderWidth: 1.5, borderColor: COLORS.border,
    alignItems: 'center', justifyContent: 'center',
  },
  profilePhotoInitial: { fontFamily: FONTS.title, fontSize: 34, color: COLORS.green },
  profileCameraBtn: {
    position: 'absolute', bottom: 0, right: 0,
    width: 28, height: 28, borderRadius: 14,
    backgroundColor: 'rgba(0,0,0,0.65)',
    alignItems: 'center', justifyContent: 'center',
    borderWidth: 2, borderColor: COLORS.bg,
  },

  // Info cards
  infoCard: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border,
    padding: SPACING.lg,
  },
  infoCardTitle: {
    fontFamily: FONTS.bodySemiBold, fontSize: 11, color: COLORS.muted2,
    textTransform: 'uppercase', letterSpacing: 0.8, marginBottom: 12,
  },
  infoRow: {
    flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center',
    paddingVertical: 8, borderBottomWidth: 1, borderBottomColor: COLORS.border,
  },
  infoRowFull: {
    paddingVertical: 8, borderBottomWidth: 1, borderBottomColor: COLORS.border,
  },
  infoLabel:      { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted2 },
  infoValue:      {
    fontFamily: FONTS.body, fontSize: 13, color: COLORS.text,
    textAlign: 'right', flex: 1, marginLeft: 12,
  },
  infoValueMulti: {
    fontFamily: FONTS.body, fontSize: 13, color: COLORS.text,
    marginTop: 4, lineHeight: 20,
  },

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

  // Moderar full button
  moderateFullBtn: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 10,
    backgroundColor: COLORS.green, borderRadius: RADIUS.lg, paddingVertical: 14,
  },
  moderateFullBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.bg },

  // Moderate cards
  moderateCard: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border,
    padding: SPACING.lg, gap: 0,
  },
  moderateCardTitle: {
    fontFamily: FONTS.bodySemiBold, fontSize: 11, color: COLORS.muted2,
    textTransform: 'uppercase', letterSpacing: 0.8, marginBottom: 12,
  },
  moderateCardHint: {
    fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted, marginBottom: 10,
  },
  notesInput: {
    backgroundColor: COLORS.bg, borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: COLORS.border,
    padding: 12, fontFamily: FONTS.body, fontSize: 14, color: COLORS.text,
    minHeight: 80,
  },

  // Action buttons
  modActionBtn: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'center',
    gap: 8, paddingVertical: 13, borderRadius: RADIUS.md,
  },
  modActionBtnText:         { fontFamily: FONTS.bodySemiBold, fontSize: 14 },
  modActionBtnGreen:        { backgroundColor: COLORS.green },
  modActionBtnRed:          { backgroundColor: '#EF5350' },
  modActionBtnOutlineGreen: { borderWidth: 1, borderColor: COLORS.green },
  modActionBtnOutlineRed:   { borderWidth: 1, borderColor: '#EF5350' },

  // History
  historyRow: {
    flexDirection: 'row', alignItems: 'flex-start',
    gap: 12, paddingVertical: 10,
  },
  historyRowDivider: { borderBottomWidth: 1, borderBottomColor: COLORS.border },
  historyDot:    { width: 10, height: 10, borderRadius: 5, marginTop: 4, flexShrink: 0 },
  historyStatus: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.text },
  historyNotes:  { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, lineHeight: 18 },
  historyDate:   { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted },
});
