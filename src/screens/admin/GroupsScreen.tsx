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
  Plus,
  Search,
  Shield,
  ShieldCheck,
  Sparkles,
  Star,
  X,
} from 'lucide-react-native';
import React, { useEffect, useMemo, useState } from 'react';
import { useTranslation } from 'react-i18next';
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
import {
  CatalogFieldKey,
  catalogErrorMessage,
  catalogFieldLabel,
  catalogFieldPlaceholder,
  catalogFieldsFor,
  catalogFormFrom,
  catalogWarning,
  EMPTY_CATALOG_FORM,
  parseCatalogInput,
  sanitizeCatalogInput,
  validateCatalog,
} from '../../constants/commercialCatalog';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';
import Particles from '../../components/ui/Particles';
import VerifiedBadge from '../../components/ui/VerifiedBadge';
import { pickAndUploadGroupImage } from '../../utils/uploadGroupImage';
import { pickAndUploadGroupVideoMulti } from '../../utils/uploadGroupVideo';
import { stateToCountry } from '../../utils/locationUtils';
import { PROVIDER_CATEGORIES, categoryKeyForGenre } from '../../constants/providerCategories';

type AdminView = 'list' | 'profile' | 'moderate';

// ─── Screen ───────────────────────────────────────────────────────────────────

export default function AdminGroupsScreen({ navigation }: any) {
  const { t } = useTranslation();
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
  const [videoLoading,   setVideoLoading]   = useState(false);
  const [groupVideos,    setGroupVideos]    = useState<{ id: string; url: string; status: string }[]>([]);

  // Catálogo comercial del proveedor (sql/720). Admin lo completa por el mismo
  // grupo y con la MISMA RPC que usa el dueño — no hay catálogo aparte para
  // Admin, es la misma fuente de verdad (groups.id).
  // Se guarda { a qué grupo pertenece lo tecleado, y lo tecleado }. Así el
  // formulario se DERIVA en render del grupo abierto y no hace falta un
  // useEffect que lo siembre (eso dispara renders en cascada).
  const [catalogEdits,   setCatalogEdits]   = useState<{ id: string | null; form: Record<CatalogFieldKey, string> }>({
    id: null, form: EMPTY_CATALOG_FORM,
  });
  const [catalogSaving,  setCatalogSaving]  = useState(false);

  // Moderate view
  const [moderateNote,        setModerateNote]        = useState('');
  const [actionLoading,       setActionLoading]       = useState(false);
  const [verificationHistory, setVerificationHistory] = useState<any[]>([]);

  useEffect(() => { fetchGroups(); }, []);

  // Mientras no se haya tecleado nada de ESTE grupo, el formulario muestra lo
  // que ya está guardado (vacío = NULL, que es un valor legítimo).
  const catalogForm = catalogEdits.id && catalogEdits.id === selected?.id
    ? catalogEdits.form
    : catalogFormFrom(selected);
  const setCatalogField = (field: CatalogFieldKey, v: string) =>
    setCatalogEdits({
      id: selected?.id ?? null,
      form: { ...catalogForm, [field]: sanitizeCatalogInput(field, v) },
    });

  const catalogFields = catalogFieldsFor(selected ? categoryKeyForGenre(selected.genre) : null);
  const catalogValues = {
    min_hours:        catalogFields.includes('min_hours')        ? parseCatalogInput('min_hours', catalogForm.min_hours)               : null,
    included_hours:   catalogFields.includes('included_hours')   ? parseCatalogInput('included_hours', catalogForm.included_hours)     : null,
    extra_hour_price: catalogFields.includes('extra_hour_price') ? parseCatalogInput('extra_hour_price', catalogForm.extra_hour_price) : null,
    capacity_max:     catalogFields.includes('capacity_max')     ? parseCatalogInput('capacity_max', catalogForm.capacity_max)         : null,
  };
  const catalogAviso = catalogWarning(catalogValues);

  const handleSaveCatalog = async () => {
    if (!selected || catalogSaving) return;
    const invalido = validateCatalog(catalogValues);
    if (invalido) { Alert.alert('Revisa los datos', invalido); return; }
    setCatalogSaving(true);
    const { data, error } = await supabase.rpc('set_group_commercial_catalog', {
      p_group_id:         selected.id,
      p_min_hours:        catalogValues.min_hours,
      p_included_hours:   catalogValues.included_hours,
      p_extra_hour_price: catalogValues.extra_hour_price,
      p_capacity_max:     catalogValues.capacity_max,
    });
    setCatalogSaving(false);
    if (error || !data?.ok) {
      Alert.alert('No se guardó', error?.message ?? catalogErrorMessage(data?.error));
      return;
    }
    setSelected((prev: any) => (prev ? { ...prev, ...catalogValues } : prev));
    setGroups(prev => prev.map(g => (g.id === selected.id ? { ...g, ...catalogValues } : g)));
    // Lo teclado ya es lo guardado: se suelta para volver a derivar del grupo.
    setCatalogEdits({ id: null, form: EMPTY_CATALOG_FORM });
    Alert.alert('Guardado', 'El catálogo comercial de este proveedor quedó actualizado.');
  };

  // ── Data ──────────────────────────────────────────────────────────────────

  const fetchGroups = async () => {
    const { data } = await supabase
      .from('groups')
      .select(`
        id, name, city, state, country, genre, description,
        is_verified, admin_verified, is_active,
        is_plus_active, plus_expires_at, plus_subscription_id,
        admin_highlight,
        concierge_mode,
        min_hours, included_hours, extra_hour_price, capacity_max,
        rating, total_reviews, created_at,
        profile_image, owner_id,
        verification_status, strike_count,
        owner:profiles!owner_id(id, full_name, phone, country)
      `)
      .order('created_at', { ascending: false });
    if (data) setGroups(data);
  };

  // Bug real reportado 2026-09-19 (web): adivinar el país por el nombre del
  // estado dejaba grupos reales de EE.UU./Canadá cayendo a México cuando su
  // estado no estaba en la lista a mano. `groups.country` ya es una columna
  // real y confiable (uno de los 3 valores reales: México/Estados Unidos/
  // Canadá) — se usa directo, con el heurístico solo como respaldo si algún
  // registro viejo no la tuviera capturada.
  const groupCountry = (g: any) => g.country ?? stateToCountry(g.state);

  const countries = useMemo(() => {
    const c = new Set<string>();
    groups.forEach(g => c.add(groupCountry(g)));
    return Array.from(c).sort();
  }, [groups]);

  const countryCounts = useMemo(() => {
    const c: Record<string, number> = {};
    groups.forEach(g => {
      const k = groupCountry(g);
      c[k] = (c[k] ?? 0) + 1;
    });
    return c;
  }, [groups]);

  const states = useMemo(() => {
    const base = activeCountry
      ? groups.filter(g => groupCountry(g) === activeCountry)
      : groups;
    const s = new Set<string>();
    base.forEach(g => { if (g.state?.trim()) s.add(g.state.trim()); });
    return Array.from(s).sort();
  }, [groups, activeCountry]);

  const stateCounts = useMemo(() => {
    const base = activeCountry
      ? groups.filter(g => groupCountry(g) === activeCountry)
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
    if (activeCountry) list = list.filter(g => groupCountry(g) === activeCountry);
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

  // Petición real (2026-09-19): "quiero ver cuántos tengo de cada categoría,
  // divididos por estado — voy a empezar por Jalisco, después Monterrey,
  // para no hacerme bolas de lo que ya tengo y lo que me falta agregar."
  // Se apoya en el mismo filtro de país/estado que ya existe arriba —
  // filteredGroups YA respeta activeState, así que este desglose se
  // recalcula solo en cuanto tocas un estado.
  const [showCategoryStats, setShowCategoryStats] = useState(false);
  const [expandedStatCats, setExpandedStatCats] = useState<Set<string>>(new Set());

  const toggleState = (st: string) => {
    setActiveState(prev => (prev === st ? null : st));
    setShowCategoryStats(true);
  };

  const toggleStatCat = (key: string) => {
    setExpandedStatCats(prev => {
      const next = new Set(prev);
      if (next.has(key)) next.delete(key); else next.add(key);
      return next;
    });
  };

  const categoryStats = useMemo(() => {
    return PROVIDER_CATEGORIES.map(cat => {
      const counts: Record<string, number> = {};
      cat.genres.forEach(g => { counts[g] = 0; });
      let total = 0;
      filteredGroups.forEach(g => {
        if (categoryKeyForGenre(g.genre) === cat.key) {
          total += 1;
          counts[g.genre as string] = (counts[g.genre as string] ?? 0) + 1;
        }
      });
      const present = Object.entries(counts)
        .filter(([, n]) => n > 0)
        .sort((a, b) => cat.genres.indexOf(a[0]) - cat.genres.indexOf(b[0]));
      const missing = cat.genres.filter(g => !counts[g]);
      return { ...cat, total, present, missing };
    });
  }, [filteredGroups]);

  const statsScopeLabel = activeState
    ? `en ${activeState}`
    : activeCountry
      ? `en ${activeCountry} (todos los estados)`
      : '(todos los países)';

  const onRefresh = async () => {
    setRefreshing(true);
    await fetchGroups();
    setRefreshing(false);
  };

  const openProfile = async (group: any) => {
    setSelected(group);
    setOwnerEmail(null);
    setCompletedCount(0);
    setGroupVideos([]);
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

    loadGroupVideos(group.id);
  };

  const loadGroupVideos = async (groupId: string) => {
    const { data } = await supabase
      .from('group_videos')
      .select('id, url, status')
      .eq('group_id', groupId)
      .neq('status', 'rejected')
      .order('created_at', { ascending: true });
    setGroupVideos(data ?? []);
  };

  const handleDeleteVideo = (videoId: string, index: number) => {
    Alert.alert('Eliminar video', `¿Quitar el Video ${index + 1} del perfil?`, [
      { text: 'Cancelar', style: 'cancel' },
      {
        text: 'Eliminar', style: 'destructive',
        onPress: async () => {
          const { error } = await supabase.from('group_videos').delete().eq('id', videoId);
          if (error) {
            Alert.alert(t('adminGroupsScreen.alerts.genericErrorTitle'), error.message);
            return;
          }
          setGroupVideos(prev => prev.filter(v => v.id !== videoId));
        },
      },
    ]);
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
      Alert.alert(
        t('adminGroupsScreen.alerts.noteRequiredTitle'),
        t('adminGroupsScreen.alerts.noteRequiredMessage')
      );
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
      Alert.alert(
        t('adminGroupsScreen.alerts.genericErrorTitle'),
        error?.message ?? data?.error ?? t('adminGroupsScreen.alerts.updateFailed')
      );
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
      verified
        ? t('adminGroupsScreen.alerts.verifiedTitle')
        : t('adminGroupsScreen.alerts.doneTitle'),
      verified
        ? t('adminGroupsScreen.alerts.groupNowVerified', { name: selected.name })
        : t('adminGroupsScreen.alerts.verificationRemoved')
    );
  };

  const handleToggleActive = async () => {
    if (!selected || actionLoading) return;
    const newVal = !selected.is_active;
    Alert.alert(
      newVal
        ? t('adminGroupsScreen.alerts.activateGroupTitle')
        : t('adminGroupsScreen.alerts.suspendGroupTitle'),
      newVal
        ? t('adminGroupsScreen.alerts.confirmActivateMessage', { name: selected.name })
        : t('adminGroupsScreen.alerts.confirmSuspendMessage', { name: selected.name }),
      [
        { text: t('adminGroupsScreen.alerts.cancel'), style: 'cancel' },
        {
          text: newVal ? t('adminGroupsScreen.alerts.activate') : t('adminGroupsScreen.alerts.suspend'),
          style: newVal ? 'default' : 'destructive',
          onPress: async () => {
            setActionLoading(true);
            const { error } = await supabase.from('groups')
              .update({ is_active: newVal })
              .eq('id', selected.id);
            setActionLoading(false);
            if (error) {
              Alert.alert(
                t('adminGroupsScreen.alerts.genericErrorTitle'),
                t('adminGroupsScreen.alerts.updateStatusFailed')
              );
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

  // ── Plus: activar/revocar manualmente (cortesía, embajadores, alianzas) ────
  // RPCs de sql/327 — admin_grant_plus bloquea si hay suscripción Stripe real.

  const isStripePlus = (g: any) =>
    !!g?.is_plus_active &&
    !!g?.plus_subscription_id &&
    !String(g.plus_subscription_id).startsWith('admin_grant_');

  const grantPlusFor = async (months: number) => {
    if (!selected || actionLoading) return;
    setActionLoading(true);
    const expiresAt = new Date();
    expiresAt.setMonth(expiresAt.getMonth() + months);
    const { data, error } = await supabase.rpc('admin_grant_plus', {
      p_group_id:   selected.id,
      p_expires_at: expiresAt.toISOString(),
      p_notes:      moderateNote.trim() || null,
    });
    setActionLoading(false);
    if (error || !data?.ok) {
      Alert.alert(
        t('adminGroupsScreen.alerts.genericErrorTitle'),
        error?.message ?? data?.error ?? t('adminGroupsScreen.alerts.grantPlusFailed')
      );
      return;
    }
    const updated = {
      ...selected,
      is_plus_active: true,
      plus_expires_at: data.expires_at,
      plus_subscription_id: data.sub_id,
      // sql/664 — admin_grant_plus también verifica el grupo del lado del
      // servidor; se refleja aquí para no mostrar "Sin verificar" hasta
      // el próximo refresh.
      is_verified: true,
      admin_verified: true,
    };
    setSelected(updated);
    setGroups(prev => prev.map(g => (g.id === selected.id ? { ...g, ...updated } : g)));
    setModerateNote('');
    Alert.alert(
      t('adminGroupsScreen.alerts.plusActivatedTitle'),
      t('adminGroupsScreen.alerts.plusActivatedMessage', {
        name: selected.name,
        date: new Date(data.expires_at).toLocaleDateString('es-MX'),
      })
    );
  };

  const handleGrantPlus = () => {
    if (!selected || actionLoading) return;
    Alert.alert(
      t('adminGroupsScreen.alerts.grantPlusTitle'),
      t('adminGroupsScreen.alerts.grantPlusMessage', { name: selected.name }),
      [
        { text: t('adminGroupsScreen.alerts.cancel'), style: 'cancel' },
        { text: t('adminGroupsScreen.alerts.oneMonth'),  onPress: () => grantPlusFor(1) },
        { text: t('adminGroupsScreen.alerts.twoMonths'), onPress: () => grantPlusFor(2) },
        { text: t('adminGroupsScreen.alerts.oneYear'),   onPress: () => grantPlusFor(12) },
      ],
    );
  };

  const handleRevokePlus = () => {
    if (!selected || actionLoading) return;
    const stripeWarning = isStripePlus(selected)
      ? t('adminGroupsScreen.alerts.stripeWarning')
      : '';
    Alert.alert(
      t('adminGroupsScreen.alerts.revokePlusTitle'),
      t('adminGroupsScreen.alerts.revokePlusMessage', { name: selected.name, warning: stripeWarning }),
      [
        { text: t('adminGroupsScreen.alerts.cancel'), style: 'cancel' },
        {
          text: t('adminGroupsScreen.alerts.revokePlusTitle'),
          style: 'destructive',
          onPress: async () => {
            setActionLoading(true);
            const { data, error } = await supabase.rpc('admin_revoke_plus', {
              p_group_id: selected.id,
              p_notes:    moderateNote.trim() || null,
            });
            setActionLoading(false);
            if (error || !data?.ok) {
              Alert.alert(
                t('adminGroupsScreen.alerts.genericErrorTitle'),
                error?.message ?? data?.error ?? t('adminGroupsScreen.alerts.revokePlusFailed')
              );
              return;
            }
            const updated = {
              ...selected,
              is_plus_active: false,
              plus_expires_at: null,
              plus_subscription_id: null,
            };
            setSelected(updated);
            setGroups(prev => prev.map(g => (g.id === selected.id ? { ...g, ...updated } : g)));
            setModerateNote('');
            Alert.alert(
              t('adminGroupsScreen.alerts.doneTitle'),
              t('adminGroupsScreen.alerts.plusRevoked')
            );
          },
        },
      ],
    );
  };

  // ── Brillo de marco (sql/665) — interruptor cosmético manual, sin
  // relación con patrocinio/boost real. Petición real (2026-09-17):
  // "quiero otro botón que si lo activo salga un efecto en el marco del
  // grupo... en el explorador... el puro marco".
  const handleToggleHighlight = () => {
    if (!selected || actionLoading) return;
    const turningOn = !selected.admin_highlight;
    Alert.alert(
      turningOn ? 'Activar brillo de marco' : 'Quitar brillo de marco',
      turningOn
        ? `El marco de ${selected.name} va a brillar en el Explorador (solo el borde de su tarjeta) — es solo visual, no afecta patrocinio ni orden real.`
        : `${selected.name} vuelve a verse con el marco normal.`,
      [
        { text: 'Cancelar', style: 'cancel' },
        {
          text: turningOn ? 'Activar' : 'Quitar',
          onPress: async () => {
            setActionLoading(true);
            const { data, error } = await supabase.rpc('admin_set_group_highlight', {
              p_group_id: selected.id,
              p_on: turningOn,
            });
            setActionLoading(false);
            if (error || !data?.ok) {
              Alert.alert(
                t('adminGroupsScreen.alerts.genericErrorTitle'),
                error?.message ?? data?.error ?? 'No se pudo cambiar el brillo de marco.'
              );
              return;
            }
            const updated = { ...selected, admin_highlight: turningOn };
            setSelected(updated);
            setGroups(prev => prev.map(g => (g.id === selected.id ? { ...g, ...updated } : g)));
          },
        },
      ],
    );
  };

  // ── Modo conserjería (2026-09-13, sql/648) ──────────────────────────────
  // Mientras esté prendido, las cotizaciones de este grupo NO le llegan a
  // él — le llegan a Daniel (o al admin del país correspondiente), que
  // llama por teléfono y pone el precio desde "Cotizaciones que manejo".
  const handleToggleConcierge = () => {
    if (!selected || actionLoading) return;
    const turningOn = !selected.concierge_mode;
    Alert.alert(
      turningOn ? 'Activar modo conserjería' : 'Desactivar modo conserjería',
      turningOn
        ? `Desde ahora, las cotizaciones nuevas de ${selected.name} te van a llegar a ti (o al admin de su país) en vez de a ellos. Tú les llamas y pones el precio.`
        : `${selected.name} volverá a recibir y responder sus propias cotizaciones.`,
      [
        { text: 'Cancelar', style: 'cancel' },
        {
          text: turningOn ? 'Activar' : 'Desactivar',
          onPress: async () => {
            setActionLoading(true);
            const { error } = await supabase
              .from('groups')
              .update({ concierge_mode: turningOn })
              .eq('id', selected.id);
            setActionLoading(false);
            if (error) {
              Alert.alert(t('adminGroupsScreen.alerts.genericErrorTitle'), error.message);
              return;
            }
            const updated = { ...selected, concierge_mode: turningOn };
            setSelected(updated);
            setGroups(prev => prev.map(g => (g.id === selected.id ? { ...g, concierge_mode: turningOn } : g)));
          },
        },
      ],
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
      Alert.alert(
        t('adminGroupsScreen.alerts.genericErrorTitle'),
        e.message ?? t('adminGroupsScreen.alerts.photoUploadFailed')
      );
    } finally {
      setPhotoLoading(false);
    }
  };

  // Solo para grupos en modo conserjería — el grupo no entra a su cuenta a
  // subir esto él mismo, así que tú lo haces por él (foto/videos que te
  // mandó por WhatsApp). sql/654 le da permiso al admin/admin_ops.
  const handleVideo = async () => {
    if (!selected) return;
    try {
      setVideoLoading(true);
      const ok = await pickAndUploadGroupVideoMulti(selected.id);
      if (ok) {
        await loadGroupVideos(selected.id);
        Alert.alert('✅ Video subido', 'Se publicó directo — tú ya lo revisaste antes de aprobar al proveedor.');
      }
    } catch (e: any) {
      Alert.alert(t('adminGroupsScreen.alerts.genericErrorTitle'), e.message ?? 'No se pudo subir el video.');
    } finally {
      setVideoLoading(false);
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
            <Text style={s.headerTitle}>{t('adminGroupsScreen.list.title')}</Text>
            <View style={{ flexDirection: 'row', alignItems: 'center', gap: 8 }}>
              <View style={s.countBadge}>
                <Text style={s.countBadgeText}>{groups.length}</Text>
              </View>
              <Pressable style={s.backBtn} onPress={() => navigation.navigate('AdminProviderApplications')}>
                <Plus size={20} color={COLORS.green} />
              </Pressable>
            </View>
          </View>

          {/* Buscador */}
          <View style={s.searchRow}>
            <Search size={14} color={COLORS.muted} />
            <TextInput
              style={s.searchInput}
              placeholder={t('adminGroupsScreen.list.searchPlaceholder')}
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
                        onPress={() => toggleState(st)}
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

          <Pressable style={s.statsHeader} onPress={() => setShowCategoryStats(v => !v)}>
            <Text style={s.statsHeaderTitle}>📊 Proveedores por categoría {statsScopeLabel}</Text>
            {showCategoryStats ? <ChevronUp size={14} color={COLORS.muted} /> : <ChevronDown size={14} color={COLORS.muted} />}
          </Pressable>
          {showCategoryStats && (
            <ScrollView style={s.statsPanel} contentContainerStyle={{ paddingBottom: 4 }}>
              {categoryStats.map(cat => (
                <View key={cat.key} style={s.statsCatBlock}>
                  <View style={s.statsCatHeader}>
                    <Text style={s.statsCatTitle}>{cat.emoji} {t(cat.labelKey)}</Text>
                    <Text style={s.statsCatTotal}>{cat.total}</Text>
                  </View>
                  {cat.present.length > 0 ? (
                    <View style={s.statsChipsRow}>
                      {cat.present.map(([genre, n]) => (
                        <View key={genre} style={s.statsChip}>
                          <Text style={s.statsChipText}>{genre}</Text>
                          <Text style={s.statsChipCount}>{n}</Text>
                        </View>
                      ))}
                    </View>
                  ) : (
                    <Text style={s.statsEmptyText}>Sin ninguno registrado todavía</Text>
                  )}
                  {cat.missing.length > 0 && (
                    <Pressable onPress={() => toggleStatCat(cat.key)} hitSlop={6}>
                      <Text style={s.statsMissingToggle}>
                        {expandedStatCats.has(cat.key) ? '▾' : '▸'} Te faltan {cat.missing.length}
                      </Text>
                    </Pressable>
                  )}
                  {expandedStatCats.has(cat.key) && cat.missing.length > 0 && (
                    <Text style={s.statsMissingList}>{cat.missing.join(', ')}</Text>
                  )}
                </View>
              ))}
            </ScrollView>
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

    const plusOn = !!selected.is_plus_active && !!selected.plus_expires_at && new Date(selected.plus_expires_at) > new Date();
    const maxVideos = plusOn ? 3 : 1;

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

            {/* Catálogo comercial (sql/720). Muchos proveedores los administra
                Daniel, así que Admin necesita poder capturar esto por ellos —
                pero escribiendo el MISMO groups.id con la MISMA RPC que usa el
                dueño, no un catálogo aparte. Vacío = NULL, que es válido y no
                debe bloquear al proveedor. Nada de esto es un precio final: la
                quote real sigue mandando. */}
            {catalogFields.length > 0 && (
              <View style={s.moderateCard}>
                <Text style={s.moderateCardTitle}>📋 Catálogo comercial</Text>
                <Text style={s.moderateCardHint}>
                  Sirve para filtrar, ordenar y dar una estimación inicial. NO es el
                  precio final: ese sigue siendo la cotización de cada evento.
                </Text>
                {catalogFields.map(field => (
                  <View key={field} style={{ marginTop: 10 }}>
                    <Text style={s.moderateCardHint}>{catalogFieldLabel(field, categoryKeyForGenre(selected.genre))}</Text>
                    <TextInput
                      style={s.catalogInput}
                      value={catalogForm[field]}
                      onChangeText={v => setCatalogField(field, v)}
                      placeholder={catalogFieldPlaceholder(field, categoryKeyForGenre(selected.genre))}
                      placeholderTextColor={COLORS.muted}
                      keyboardType="numeric"
                    />
                  </View>
                ))}
                {!!catalogAviso && (
                  <Text style={[s.moderateCardHint, { color: COLORS.gold, marginTop: 8 }]}>⚠️ {catalogAviso}</Text>
                )}
                <Pressable
                  style={[s.modActionBtn, s.modActionBtnOutlineGreen, { marginTop: 12 }, catalogSaving && { opacity: 0.6 }]}
                  onPress={handleSaveCatalog}
                  disabled={catalogSaving}
                >
                  {catalogSaving
                    ? <ActivityIndicator size="small" color={COLORS.green} />
                    : <Text style={[s.modActionBtnText, { color: COLORS.green }]}>Guardar catálogo</Text>}
                </Pressable>
              </View>
            )}

            {/* Modo conserjería — visible aquí mismo, sin tener que ir a moderar */}
            <View style={s.moderateCard}>
              <Text style={s.moderateCardTitle}>🎯 Modo conserjería</Text>
              {selected.concierge_mode ? (
                <>
                  <Text style={s.moderateCardHint}>
                    📞 Activo — las cotizaciones de este grupo te llegan a ti (o al admin de su país), no a ellos.
                  </Text>
                  <Pressable
                    style={[s.modActionBtn, s.modActionBtnOutlineRed, actionLoading && { opacity: 0.6 }]}
                    onPress={handleToggleConcierge}
                    disabled={actionLoading}
                  >
                    {actionLoading
                      ? <ActivityIndicator size="small" color="#EF5350" />
                      : <Text style={[s.modActionBtnText, { color: '#EF5350' }]}>Desactivar — que ya maneje sus cotizaciones</Text>}
                  </Pressable>

                  {/* La foto se edita tocando la foto de perfil arriba — esto
                      es solo para el video, que no tiene otra entrada aquí. */}
                  <Text style={[s.moderateCardHint, { marginTop: 12, fontFamily: FONTS.bodyMedium }]}>
                    🎬 Videos del perfil · {groupVideos.length}/{maxVideos}{plusOn ? ' (Plus: 2 extra desbloqueados)' : ''}
                  </Text>
                  {groupVideos.map((v, i) => (
                    <View key={v.id} style={s.adminVideoRow}>
                      <Text style={s.adminVideoName} numberOfLines={1}>Video {i + 1} · ✅ Publicado</Text>
                      <Pressable hitSlop={8} onPress={() => handleDeleteVideo(v.id, i)}>
                        <Text style={{ fontSize: 14 }}>🗑️</Text>
                      </Pressable>
                    </View>
                  ))}
                  {groupVideos.length < maxVideos ? (
                    <Pressable
                      style={[s.modActionBtn, s.modActionBtnGreen, { marginTop: 10 }, videoLoading && { opacity: 0.6 }]}
                      onPress={handleVideo}
                      disabled={videoLoading}
                    >
                      {videoLoading
                        ? <ActivityIndicator size="small" color={COLORS.bg} />
                        : <>
                            <Camera size={16} color={COLORS.bg} />
                            <Text style={[s.modActionBtnText, { color: COLORS.bg }]}>Subir video del grupo</Text>
                          </>}
                    </Pressable>
                  ) : (
                    <Text style={s.moderateCardHint}>
                      Ya tiene el máximo de {maxVideos} video{maxVideos !== 1 ? 's' : ''} con su plan actual{!plusOn ? ' — con Plus desbloquea 2 más' : ''}. Elimina uno para subir otro.
                    </Text>
                  )}
                </>
              ) : (
                <>
                  <Text style={s.moderateCardHint}>
                    Para grupos que aún no confían en manejar su cuenta. Tú (o el admin de su país) recibes y pones precio a sus cotizaciones en vez de ellos.
                  </Text>
                  <Pressable
                    style={[s.modActionBtn, s.modActionBtnGreen, actionLoading && { opacity: 0.6 }]}
                    onPress={handleToggleConcierge}
                    disabled={actionLoading}
                  >
                    {actionLoading
                      ? <ActivityIndicator size="small" color={COLORS.bg} />
                      : <>
                          <Phone size={16} color={COLORS.bg} />
                          <Text style={[s.modActionBtnText, { color: COLORS.bg }]}>Activar modo conserjería</Text>
                        </>}
                  </Pressable>
                </>
              )}
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
                {selected.is_plus_active && (
                  <View style={[s.statusChip, s.chipPlus]}>
                    <Sparkles size={11} color={COLORS.gold} />
                    <Text style={[s.statusChipText, { color: COLORS.gold }]}>
                      Plus{isStripePlus(selected) ? ' · Stripe' : ' · Cortesía'}
                    </Text>
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

            {/* Daricefy Plus — activar/revocar cortesía */}
            <View style={s.moderateCard}>
              <Text style={s.moderateCardTitle}>Daricefy Plus</Text>
              {selected.is_plus_active ? (
                <>
                  <Text style={s.moderateCardHint}>
                    {isStripePlus(selected)
                      ? '💳 Suscripción Stripe de pago activa.'
                      : `✨ Cortesía activa${selected.plus_expires_at
                          ? ` — vence el ${new Date(selected.plus_expires_at).toLocaleDateString('es-MX')}`
                          : ''}.`}
                  </Text>
                  <Pressable
                    style={[s.modActionBtn, s.modActionBtnOutlineRed, actionLoading && { opacity: 0.6 }]}
                    onPress={handleRevokePlus}
                    disabled={actionLoading}
                  >
                    <Text style={[s.modActionBtnText, { color: '#EF5350' }]}>Quitar Plus</Text>
                  </Pressable>
                </>
              ) : (
                <>
                  <Text style={s.moderateCardHint}>
                    Activa Plus gratis (1, 2 meses o 1 año) para patrocinios, embajadores o alianzas — sin pasar por Stripe.
                    La nota interna de arriba se guarda como motivo.
                  </Text>
                  <Pressable
                    style={[s.modActionBtn, s.modActionBtnGold, actionLoading && { opacity: 0.6 }]}
                    onPress={handleGrantPlus}
                    disabled={actionLoading}
                  >
                    {actionLoading
                      ? <ActivityIndicator size="small" color={COLORS.bg} />
                      : <>
                          <Sparkles size={16} color={COLORS.bg} />
                          <Text style={[s.modActionBtnText, { color: COLORS.bg }]}>
                            Activar Plus (cortesía)
                          </Text>
                        </>}
                  </Pressable>
                </>
              )}
            </View>

            {/* ✨ Brillo de marco (sql/665) — puramente cosmético, manual */}
            <View style={s.moderateCard}>
              <Text style={s.moderateCardTitle}>✨ Brillo de marco</Text>
              <Text style={s.moderateCardHint}>
                {selected.admin_highlight
                  ? 'Activo — su tarjeta brilla en el Explorador (solo el marco). Es visual, no afecta patrocinio ni orden real.'
                  : 'Resalta el marco de la tarjeta de este grupo en el Explorador — solo visual, sin tocar patrocinio ni orden real.'}
              </Text>
              <Pressable
                style={[
                  s.modActionBtn,
                  selected.admin_highlight ? s.modActionBtnOutlineRed : s.modActionBtnGreen,
                  actionLoading && { opacity: 0.6 },
                ]}
                onPress={handleToggleHighlight}
                disabled={actionLoading}
              >
                {actionLoading
                  ? <ActivityIndicator size="small" color={selected.admin_highlight ? '#EF5350' : COLORS.bg} />
                  : <Text style={[s.modActionBtnText, { color: selected.admin_highlight ? '#EF5350' : COLORS.bg }]}>
                      {selected.admin_highlight ? 'Quitar brillo de marco' : 'Activar brillo de marco'}
                    </Text>}
              </Pressable>
            </View>

            {/* Modo conserjería — tú manejas sus cotizaciones */}
            <View style={s.moderateCard}>
              <Text style={s.moderateCardTitle}>🎯 Modo conserjería</Text>
              {selected.concierge_mode ? (
                <>
                  <Text style={s.moderateCardHint}>
                    📞 Activo — las cotizaciones de este grupo te llegan a ti (o al admin de su país), no a ellos.
                  </Text>
                  <Pressable
                    style={[s.modActionBtn, s.modActionBtnOutlineRed, actionLoading && { opacity: 0.6 }]}
                    onPress={handleToggleConcierge}
                    disabled={actionLoading}
                  >
                    <Text style={[s.modActionBtnText, { color: '#EF5350' }]}>Desactivar — que ya maneje sus cotizaciones</Text>
                  </Pressable>
                </>
              ) : (
                <>
                  <Text style={s.moderateCardHint}>
                    Para grupos que aún no confían en manejar su cuenta. Tú (o el admin de su país) recibes y pones precio a sus cotizaciones en vez de ellos.
                  </Text>
                  <Pressable
                    style={[s.modActionBtn, s.modActionBtnGreen, actionLoading && { opacity: 0.6 }]}
                    onPress={handleToggleConcierge}
                    disabled={actionLoading}
                  >
                    {actionLoading
                      ? <ActivityIndicator size="small" color={COLORS.bg} />
                      : <>
                          <Phone size={16} color={COLORS.bg} />
                          <Text style={[s.modActionBtnText, { color: COLORS.bg }]}>Activar modo conserjería</Text>
                        </>}
                  </Pressable>
                </>
              )}
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

  // ── Desglose de proveedores por categoría/estado (2026-09-19) ──────────
  statsHeader: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between',
    paddingHorizontal: SPACING.xl, paddingVertical: 10,
  },
  statsHeaderTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.text, flex: 1, marginRight: 8 },
  statsPanel: { maxHeight: 300, paddingHorizontal: SPACING.xl },
  statsCatBlock: { marginBottom: 16 },
  statsCatHeader: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', marginBottom: 6 },
  statsCatTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 12, color: COLORS.text },
  statsCatTotal: { fontFamily: FONTS.bodySemiBold, fontSize: 12, color: COLORS.green },
  statsChipsRow: { flexDirection: 'row', flexWrap: 'wrap', gap: 6 },
  statsChip: {
    flexDirection: 'row', alignItems: 'center', gap: 4,
    paddingHorizontal: 8, paddingVertical: 4, borderRadius: RADIUS.sm,
    backgroundColor: COLORS.card2, borderWidth: 1, borderColor: COLORS.border,
  },
  statsChipText: { fontFamily: FONTS.bodyMedium, fontSize: 11, color: COLORS.text },
  statsChipCount: { fontFamily: FONTS.bodySemiBold, fontSize: 11, color: COLORS.green },
  statsEmptyText: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted, fontStyle: 'italic' },
  statsMissingToggle: { fontFamily: FONTS.bodyMedium, fontSize: 11, color: COLORS.muted, marginTop: 6 },
  statsMissingList: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted2, marginTop: 4, lineHeight: 16 },

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
  chipPlus:          { backgroundColor: 'rgba(255,215,0,0.10)',  borderColor: 'rgba(255,215,0,0.40)' },

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
  adminVideoRow: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between',
    paddingVertical: 8, borderBottomWidth: 1, borderBottomColor: COLORS.border,
  },
  adminVideoName: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.text, flex: 1 },
  catalogInput: {
    backgroundColor: COLORS.bg, borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: COLORS.border,
    paddingHorizontal: 12, paddingVertical: 10, marginTop: 4,
    fontFamily: FONTS.body, fontSize: 14, color: COLORS.text,
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
  modActionBtnGold:         { backgroundColor: COLORS.gold },
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
