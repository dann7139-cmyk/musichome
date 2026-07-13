import {
  ArrowLeft,
  Camera,
  CheckCircle,
  ChevronRight,
  Copy,
  Eye,
  EyeOff,
  Gift,
  LogOut,
  MapPin,
  Share2,
  Star,
  X,
  Users,
} from 'lucide-react-native';
import React, { useEffect, useRef, useState } from 'react';
import {
  ActivityIndicator,
  Alert,
  AppState,
  FlatList,
  Image,
  ImageBackground,
  Linking,
  Modal,
  Pressable,
  RefreshControl,
  ScrollView,
  Share,
  StyleSheet,
  Text,
  TextInput,
  View,
} from 'react-native';
import { LinearGradient } from 'expo-linear-gradient';
import * as Location from 'expo-location';

import { SafeAreaView } from 'react-native-safe-area-context';
import { pickAndUploadProfileImage } from '../../utils/uploadProfileImage';
import { openSupportEmail, openSupportWhatsApp, SUPPORT_HOURS } from '../../utils/support';
import { supabase } from '../../config/supabase';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';
import Particles from '../../components/ui/Particles';
import { useAuth } from '../../context/AuthContext';
import { isoToCountryName } from '../../utils/locationUtils';
import VerifiedBadge from '../../components/ui/VerifiedBadge';

// Lista base de estados — respaldo cuando get_active_cities() devuelve vacío
const FALLBACK_STATES = [
  // México
  { id: 'fs-jal',  name: 'Jalisco',            country_name: 'México' },
  { id: 'fs-cdmx', name: 'Ciudad de México',   country_name: 'México' },
  { id: 'fs-nl',   name: 'Nuevo León',         country_name: 'México' },
  { id: 'fs-pue',  name: 'Puebla',             country_name: 'México' },
  { id: 'fs-bc',   name: 'Baja California',    country_name: 'México' },
  { id: 'fs-qro',  name: 'Querétaro',          country_name: 'México' },
  { id: 'fs-ags',  name: 'Aguascalientes',     country_name: 'México' },
  { id: 'fs-sin',  name: 'Sinaloa',            country_name: 'México' },
  { id: 'fs-yuc',  name: 'Yucatán',            country_name: 'México' },
  { id: 'fs-ver',  name: 'Veracruz',           country_name: 'México' },
  { id: 'fs-oax',  name: 'Oaxaca',             country_name: 'México' },
  { id: 'fs-chi',  name: 'Chihuahua',          country_name: 'México' },
  { id: 'fs-mex',  name: 'Estado de México',   country_name: 'México' },
  { id: 'fs-son',  name: 'Sonora',             country_name: 'México' },
  { id: 'fs-slp',  name: 'San Luis Potosí',    country_name: 'México' },
  { id: 'fs-gto',  name: 'Guanajuato',         country_name: 'México' },
  { id: 'fs-mich', name: 'Michoacán',          country_name: 'México' },
  { id: 'fs-tam',  name: 'Tamaulipas',         country_name: 'México' },
  { id: 'fs-col',  name: 'Colima',             country_name: 'México' },
  { id: 'fs-nay',  name: 'Nayarit',            country_name: 'México' },
  // Estados Unidos
  { id: 'fs-ca',   name: 'California',         country_name: 'Estados Unidos' },
  { id: 'fs-tx',   name: 'Texas',              country_name: 'Estados Unidos' },
  { id: 'fs-ny',   name: 'New York',           country_name: 'Estados Unidos' },
  { id: 'fs-fl',   name: 'Florida',            country_name: 'Estados Unidos' },
  { id: 'fs-il',   name: 'Illinois',           country_name: 'Estados Unidos' },
  { id: 'fs-nv',   name: 'Nevada',             country_name: 'Estados Unidos' },
  { id: 'fs-wa',   name: 'Washington',         country_name: 'Estados Unidos' },
  { id: 'fs-az',   name: 'Arizona',            country_name: 'Estados Unidos' },
  { id: 'fs-co',   name: 'Colorado',           country_name: 'Estados Unidos' },
];

export default function ProfileScreen({ navigation }: any) {
  const { refetchProfile, signOut } = useAuth();
  const [profile, setProfile]       = useState<any>(null);
  const [group, setGroup]           = useState<any>(null);
  const [groupRole, setGroupRole]   = useState<'owner' | 'member' | null>(null);

  // Stripe Connect (para talent y group)
  const [stripeStatus, setStripeStatus] = useState<{
    stripe_account_id: string | null;
    stripe_onboarding_completed: boolean;
    stripe_payouts_enabled: boolean;
  }>({ stripe_account_id: null, stripe_onboarding_completed: false, stripe_payouts_enabled: false });
  const [stripeLoading, setStripeLoading] = useState(false);

  // Modals
  const [editVisible, setEditVisible]       = useState(false);
  const [passVisible, setPassVisible]       = useState(false);
  const [supportVisible, setSupportVisible] = useState(false);

  // Edit profile form
  const [editName, setEditName]     = useState('');
  const [editLoading, setEditLoading] = useState(false);

  // Avatar personal
  const [avatarUrl, setAvatarUrl]       = useState<string | null>(null);
  const [avatarLoading, setAvatarLoading] = useState(false);

  // Change password
  const [newPass, setNewPass]         = useState('');
  const [confirmPass, setConfirmPass] = useState('');
  const [showNew, setShowNew]         = useState(false);
  const [showConfirm, setShowConfirm] = useState(false);
  const [passLoading, setPassLoading] = useState(false);

  const [refreshing, setRefreshing] = useState(false);

  // Loyalty (solo clientes)
  const [loyalty, setLoyalty] = useState<any>(null);

  // Referral
  const [referralInput,   setReferralInput]   = useState('');
  const [applyingCode,    setApplyingCode]    = useState(false);
  const [referralApplied, setReferralApplied] = useState(false);
  const [referralStats,   setReferralStats]   = useState<{ total: number; pending: number; earned: number } | null>(null);

  // Ciudades de servicio (solo grupos)
  const [serviceCitiesModal,    setServiceCitiesModal]    = useState(false);
  const [serviceCitiesSelected, setServiceCitiesSelected] = useState<string[]>([]);
  const [serviceCitiesSaving,   setServiceCitiesSaving]   = useState(false);
  const [serviceCitiesSearch,   setServiceCitiesSearch]   = useState('');

  // Cambiar ciudad
  const [cityModalVisible, setCityModalVisible] = useState(false);
  const [cityOptions, setCityOptions]           = useState<any[]>([]);
  const [cityFiltered, setCityFiltered]         = useState<any[]>([]);
  const [citySearch, setCitySearch]             = useState('');
  const [citySelected, setCitySelected]         = useState<any>(null);
  const [cityLoading, setCityLoading]           = useState(false);
  const [citySaving, setCitySaving]             = useState(false);
  const [gpsLoading, setGpsLoading]             = useState(false);

  const appStateRef = useRef(AppState.currentState);

  useEffect(() => { fetchProfile(); }, []);

  // Verifica estado real en Stripe cuando el usuario vuelve del browser de onboarding
  useEffect(() => {
    const sub = AppState.addEventListener('change', async (nextState) => {
      if (appStateRef.current.match(/inactive|background/) && nextState === 'active') {
        const { data: sessionData } = await supabase.auth.getSession();
        const token = sessionData.session?.access_token;
        if (token) {
          await supabase.functions.invoke('verify-stripe-account', {
            headers: { Authorization: `Bearer ${token}` },
          });
        }
        fetchProfile();
      }
      appStateRef.current = nextState;
    });
    return () => sub.remove();
  }, []);

  const onRefresh = async () => {
    setRefreshing(true);
    await fetchProfile();
    setRefreshing(false);
  };

  const fetchProfile = async () => {
    const { data: sessionData } = await supabase.auth.getSession();
    if (!sessionData.session) return;
    const uid = sessionData.session.user.id;

    const { data: prof } = await supabase
      .from('profiles')
      .select('*')
      .eq('id', uid)
      .single();
    setProfile(prof);
    setEditName(prof?.full_name ?? '');
    setAvatarUrl(prof?.avatar_url ?? null);

    if (prof?.role === 'client') {
      const { data: loyData } = await supabase.rpc('get_client_loyalty').maybeSingle();
      setLoyalty(loyData && (loyData as any).loyalty_events_count > 0 ? loyData : null);
    }

    setStripeStatus({
      stripe_account_id:           prof?.stripe_account_id ?? null,
      stripe_onboarding_completed: prof?.stripe_onboarding_completed ?? false,
      stripe_payouts_enabled:      prof?.stripe_payouts_enabled ?? false,
    });

    // ── Cargar grupo: owner O miembro aceptado ─────────────────────────────
    if (prof?.role === 'group') {
      const { data: grp } = await supabase.rpc('get_my_group').maybeSingle();
      if (grp) {
        setGroup(grp);
        setGroupRole('owner');
        if ((grp as any).id) fetchReferralStats((grp as any).id);
        // Pre-cargar ciudades de servicio actuales
        const sc = (grp as any).service_cities;
        if (Array.isArray(sc)) setServiceCitiesSelected(sc);
      }
    } else {
      // Verificar si es miembro aceptado de un grupo (membresía, event_id IS NULL)
      const { data: inv } = await supabase
        .from('job_invitations')
        .select('group_id')
        .eq('invited_user_id', uid)
        .eq('status', 'accepted')
        .is('event_id', null)
        .maybeSingle();

      if (inv?.group_id) {
        const { data: grpData } = await supabase
          .from('groups')
          .select('id, name, genre, city, country, profile_image, is_verified, is_plus_active, rating')
          .eq('id', inv.group_id)
          .maybeSingle();
        if (grpData) { setGroup(grpData); setGroupRole('member'); }
      }
    }
  };

  const fetchReferralStats = async (groupId: string) => {
    const { data } = await supabase.rpc('get_referral_stats', { p_group_id: groupId });
    if ((data as any)?.ok) {
      setReferralStats({
        total:  (data as any).total  ?? 0,
        pending:(data as any).pending ?? 0,
        earned: (data as any).earned  ?? 0,
      });
    }
  };

  const handleApplyReferral = async () => {
    const code = referralInput.trim().toUpperCase();
    if (!code) return;
    setApplyingCode(true);
    const { data, error } = await supabase.rpc('register_referral', {
      p_referral_code: code,
    });
    setApplyingCode(false);
    if (!error && data?.ok !== false) {
      setReferralApplied(true);
      setProfile((prev: any) => ({ ...prev, _referralApplied: true }));
      Alert.alert('✅ Código aplicado', 'Recibirás un beneficio en tu primera reserva.');
    } else {
      const msg = data?.error ?? error?.message ?? 'Código inválido o ya utilizado.';
      Alert.alert('Código no válido', msg);
    }
  };

  const handleSignOut = () => { signOut(); };

  const openCityModal = async () => {
    setCityModalVisible(true);
    setCityLoading(true);
    setCitySearch('');
    setCitySelected(null);
    const { data } = await supabase.rpc('get_active_cities');
    const dbList = (data as any[]) ?? [];
    const source = dbList.length > 0 ? dbList : FALLBACK_STATES;

    // Convertir ciudades a estados únicos (deduplicated)
    const stateMap = new Map<string, any>();
    source.forEach((c: any) => {
      const stateName = c.state_name || c.name || null;
      const country   = c.country_name || null;
      if (!stateName) return;
      if (!stateMap.has(stateName)) {
        stateMap.set(stateName, {
          id:           `state-${stateName}`,
          name:         stateName,
          state_name:   stateName,
          country_name: country,
        });
      }
    });

    const stateList = Array.from(stateMap.values()).sort((a, b) => {
      if (a.country_name === b.country_name) return a.name.localeCompare(b.name, 'es');
      if (a.country_name === 'México') return -1;
      if (b.country_name === 'México') return 1;
      return (a.country_name ?? '').localeCompare(b.country_name ?? '');
    });

    setCityOptions(stateList);
    setCityFiltered(stateList);
    setCityLoading(false);
  };

  const handleCitySearch = (q: string) => {
    setCitySearch(q);
    const norm = (s: string) => s.toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '');
    const lower = norm(q);
    setCityFiltered(
      q.trim()
        ? cityOptions.filter(c =>
            norm(c.name).includes(lower) ||
            norm(c.country_name ?? '').includes(lower)
          )
        : cityOptions
    );
  };

  const handleConfirmCity = async () => {
    if (!citySelected) return;
    setCitySaving(true);
    const newState   = citySelected.name || null;
    const newCountry = citySelected.country_name || null;
    const { error } = await supabase.rpc('update_my_location', {
      p_state:   newState,
      p_country: newCountry,
    });
    if (!error) {
      if (profile?.role === 'group' && group?.id && newState) {
        await supabase.from('groups')
          .update({ state: newState, country: newCountry })
          .eq('id', group.id)
          .eq('owner_id', profile.id);
      }
      await refetchProfile();
      setProfile((prev: any) => ({
        ...prev,
        state:   newState   ?? prev.state,
        country: newCountry ?? prev.country,
      }));
      setCityModalVisible(false);
      Alert.alert('¡Listo!', `Tu estado fue actualizado a ${newState}${newCountry ? ` · ${newCountry}` : ''}.`);
    } else {
      Alert.alert('Error', 'No se pudo actualizar tu estado. Intenta de nuevo.');
    }
    setCitySaving(false);
  };

  const handleDetectByGPS = async () => {
    setGpsLoading(true);
    try {
      const { status } = await Location.requestForegroundPermissionsAsync();
      if (status !== 'granted') {
        Alert.alert('Permiso necesario', 'Activa el permiso de ubicación en Configuración para que podamos detectar tu estado.');
        return;
      }
      const loc = await Promise.race([
        Location.getCurrentPositionAsync({ accuracy: Location.Accuracy.Balanced }),
        new Promise<never>((_, reject) => setTimeout(() => reject(new Error('timeout')), 8000)),
      ]);
      const [place] = await Location.reverseGeocodeAsync({
        latitude:  loc.coords.latitude,
        longitude: loc.coords.longitude,
      });
      const stateName   = place?.region ?? null;
      const countryIso  = place?.isoCountryCode ?? null;
      const countryName = countryIso ? isoToCountryName(countryIso) : null;

      if (!stateName) {
        Alert.alert('Sin resultado', 'No pudimos detectar tu estado. Búscalo manualmente en la lista.');
        return;
      }

      setCitySaving(true);
      const { error } = await supabase.rpc('update_my_location', {
        p_state:   stateName,
        p_country: countryName,
      });
      if (!error) {
        if (profile?.role === 'group' && group?.id) {
          await supabase.from('groups')
            .update({ state: stateName, country: countryName })
            .eq('id', group.id)
            .eq('owner_id', profile.id);
        }
        await refetchProfile();
        setProfile((prev: any) => ({
          ...prev,
          state:   stateName,
          country: countryName ?? prev?.country,
        }));
        setCityModalVisible(false);
        Alert.alert(
          '¡Listo!',
          `Tu estado fue actualizado a ${stateName}${countryName ? ` · ${countryName}` : ''}.`
        );
      } else {
        Alert.alert('Error', 'No se pudo guardar tu ubicación. Intenta de nuevo.');
      }
    } catch {
      Alert.alert('Error', 'No pudimos obtener tu ubicación. Verifica tu conexión e intenta de nuevo.');
    } finally {
      setGpsLoading(false);
      setCitySaving(false);
    }
  };

  const handleSaveServiceCities = async () => {
    if (!group?.id) return;
    setServiceCitiesSaving(true);
    const { data } = await supabase.rpc('update_my_service_cities', {
      p_group_id:       group.id,
      p_service_cities: JSON.stringify(serviceCitiesSelected),
    });
    setServiceCitiesSaving(false);
    if ((data as any)?.ok) {
      setGroup((prev: any) => ({ ...prev, service_cities: serviceCitiesSelected }));
      setServiceCitiesModal(false);
    } else {
      Alert.alert('Error', 'No se pudo guardar las ciudades de servicio.');
    }
  };

  const toggleServiceCity = (cityName: string) => {
    setServiceCitiesSelected(prev =>
      prev.includes(cityName)
        ? prev.filter(c => c !== cityName)
        : prev.length < 10 ? [...prev, cityName] : prev
    );
  };

  const handleSaveProfile = async () => {
    if (!editName.trim()) return;
    setEditLoading(true);
    const { data: sessionData } = await supabase.auth.getSession();
    if (!sessionData.session) { setEditLoading(false); return; }
    const { error } = await supabase
      .from('profiles')
      .update({ full_name: editName.trim() })
      .eq('id', sessionData.session.user.id);
    setEditLoading(false);
    if (error) {
      Alert.alert('Error', 'No se pudo actualizar el perfil.');
    } else {
      setProfile((prev: any) => ({ ...prev, full_name: editName.trim() }));
      setEditVisible(false);
      Alert.alert('✓ Listo', 'Nombre actualizado correctamente.');
    }
  };

  const handleChangePassword = async () => {
    if (newPass.length < 6) { Alert.alert('Error', 'La contraseña debe tener al menos 6 caracteres.'); return; }
    if (newPass !== confirmPass) { Alert.alert('Error', 'Las contraseñas no coinciden.'); return; }
    setPassLoading(true);
    const { error } = await supabase.auth.updateUser({ password: newPass });
    setPassLoading(false);
    if (error) {
      Alert.alert('Error', error.message);
    } else {
      setNewPass(''); setConfirmPass(''); setPassVisible(false);
      Alert.alert('✓ Listo', 'Contraseña cambiada correctamente.');
    }
  };

  const handleChangeAvatar = async () => {
    const { data: sessionData } = await supabase.auth.getSession();
    const uid = sessionData.session?.user.id;
    if (!uid) return;
    try {
      setAvatarLoading(true);
      const url = await pickAndUploadProfileImage(uid);
      if (url) {
        setAvatarUrl(url);
        await refetchProfile();
      }
    } catch (e: any) {
      Alert.alert('Error', e.message ?? 'No se pudo subir la foto.');
    } finally {
      setAvatarLoading(false);
    }
  };

  const handleConnectStripeProfile = async () => {
    setStripeLoading(true);
    try {
      const { data: sd } = await supabase.auth.getSession();
      const token = sd.session?.access_token;
      if (!token) {
        Alert.alert('Error', 'Sesión no encontrada. Vuelve a iniciar sesión.');
        return;
      }

      // ── Verificar estado real en Stripe PRIMERO (si ya tiene cuenta) ──
      if (stripeStatus.stripe_account_id) {
        const { data: verifyData } = await supabase.functions.invoke('verify-stripe-account', {
          headers: { Authorization: `Bearer ${token}` },
        });
        if (verifyData?.verified) {
          await fetchProfile();
        }
      }

      const { data, error } = await supabase.functions.invoke('stripe-connect-profile', {
        headers: { Authorization: `Bearer ${token}` },
      });

      if (error) {
        Alert.alert('Error de red', error.message ?? 'No se pudo contactar el servidor.');
        return;
      }
      if (data?.error) {
        Alert.alert('Error', data.error);
        return;
      }
      if (data?.already_completed) {
        await fetchProfile();
        const loginUrl = data?.login_url;
        if (loginUrl) {
          Alert.alert(
            '✅ Cuenta bancaria activa',
            '¿Deseas abrir el portal de Stripe para gestionar tu cuenta o actualizar tus datos bancarios?',
            [
              { text: 'Gestionar cuenta', onPress: () => Linking.openURL(loginUrl) },
              { text: 'Cerrar', style: 'cancel' },
            ],
          );
        } else {
          Alert.alert('✅ Cuenta activa', 'Tu cuenta ya está conectada y verificada.');
        }
        return;
      }
      if (data?.url) {
        await Linking.openURL(data.url);
      } else {
        Alert.alert('Error', 'No se recibió URL de Stripe. Intenta de nuevo.');
      }
    } catch (e: any) {
      Alert.alert('Error inesperado', e.message ?? 'Ocurrió un error');
    } finally {
      setStripeLoading(false);
    }
  };

  const roleLabel =
    profile?.role === 'talent' ? '🎸 Artista' :
    profile?.role === 'group'  ? '🎵 Músico / Dueño' :
    profile?.role === 'client' ? '🎉 Cliente' :
    '⚙️ Admin';

  const initial = profile?.full_name?.charAt(0)?.toUpperCase() ?? '?';

  return (
    <View style={st.container}>
      <Particles />
      <SafeAreaView style={{ flex: 1 }}>

        {/* Header */}
        <View style={st.header}>
          {navigation.canGoBack() ? (
            <Pressable style={st.backBtn} onPress={() => navigation.goBack()}>
              <ArrowLeft size={20} color={COLORS.text} />
            </Pressable>
          ) : (
            <View style={{ width: 40 }} />
          )}
          <Text style={st.headerTitle}>Mi Perfil</Text>
          <View style={{ width: 40 }} />
        </View>

        <ScrollView showsVerticalScrollIndicator={false} refreshControl={<RefreshControl refreshing={refreshing} onRefresh={onRefresh} tintColor={COLORS.green} />}>

            {/* ── HERO ARTISTA (foto grande, full-width) ── */}
          <View style={st.artistHero}>
            {avatarUrl ? (
              <ImageBackground
                source={{ uri: avatarUrl }}
                style={st.artistHeroImg}
                resizeMode="cover"
              >
                <LinearGradient
                  colors={['transparent', 'rgba(0,0,0,0.68)', 'rgba(0,0,0,0.92)']}
                  style={st.artistHeroGradient}
                  start={{ x: 0, y: 0 }} end={{ x: 0, y: 1 }}
                >
                  <Pressable style={st.artistHeroCam} onPress={handleChangeAvatar} disabled={avatarLoading}>
                    {avatarLoading
                      ? <ActivityIndicator size="small" color="#fff" />
                      : <Camera size={16} color="#fff" />}
                  </Pressable>
                  <View style={st.artistHeroInfo}>
                    <View style={{ flexDirection: 'row', alignItems: 'center', gap: 6 }}>
                      <Text style={st.artistHeroName}>{profile?.full_name ?? '—'}</Text>
                      {(profile?.id_verified || (profile as any)?.admin_verified) && (
                        <VerifiedBadge size={16} />
                      )}
                    </View>
                    <Text style={st.artistHeroEmail}>{profile?.email ?? '—'}</Text>
                    <View style={st.artistHeroRolePill}>
                      <Text style={st.artistHeroRolePillText}>{roleLabel}</Text>
                    </View>
                    {(profile?.city || profile?.state) && (
                      <View style={st.artistHeroLocRow}>
                        <MapPin size={11} color={COLORS.muted2} />
                        <Text style={st.artistHeroLoc}>
                          {[profile.city, profile.state].filter(Boolean).join(', ')}
                        </Text>
                      </View>
                    )}
                  </View>
                </LinearGradient>
              </ImageBackground>
            ) : (
              /* Sin foto: placeholder oscuro con inicial */
              <View style={[st.artistHeroImg, st.artistHeroPlaceholder]}>
                <Pressable style={st.artistHeroCam} onPress={handleChangeAvatar} disabled={avatarLoading}>
                  {avatarLoading
                    ? <ActivityIndicator size="small" color="#fff" />
                    : <Camera size={16} color="#fff" />}
                </Pressable>
                <Text style={st.artistHeroInitialBig}>{initial}</Text>
                <LinearGradient
                  colors={['transparent', 'rgba(0,0,0,0.82)', 'rgba(0,0,0,0.96)']}
                  style={st.artistHeroGradient}
                  start={{ x: 0, y: 0 }} end={{ x: 0, y: 1 }}
                >
                  <View style={st.artistHeroInfo}>
                    <View style={{ flexDirection: 'row', alignItems: 'center', gap: 6 }}>
                      <Text style={st.artistHeroName}>{profile?.full_name ?? '—'}</Text>
                      {(profile?.id_verified || (profile as any)?.admin_verified) && (
                        <VerifiedBadge size={16} />
                      )}
                    </View>
                    <Text style={st.artistHeroEmail}>{profile?.email ?? '—'}</Text>
                    <View style={st.artistHeroRolePill}>
                      <Text style={st.artistHeroRolePillText}>{roleLabel}</Text>
                    </View>
                    {(profile?.city || profile?.state) && (
                      <View style={st.artistHeroLocRow}>
                        <MapPin size={11} color={COLORS.muted2} />
                        <Text style={st.artistHeroLoc}>
                          {[profile.city, profile.state].filter(Boolean).join(', ')}
                        </Text>
                      </View>
                    )}
                  </View>
                </LinearGradient>
              </View>
            )}
          </View>

          {/* ── TARJETA DE GRUPO (compacta: foto pequeña + info al lado) ── */}
          {group && (
            <View style={st.groupCompactCard}>
              {/* Foto cuadrada */}
              {group.profile_image ? (
                <Image source={{ uri: group.profile_image }} style={st.groupCompactImg} resizeMode="cover" />
              ) : (
                <View style={[st.groupCompactImg, st.groupCompactImgPlaceholder]}>
                  <Text style={st.groupCompactInitialText}>{group.name?.charAt(0)?.toUpperCase() ?? '?'}</Text>
                </View>
              )}

              {/* Info */}
              <View style={{ flex: 1 }}>
                <View style={{ flexDirection: 'row', alignItems: 'center', gap: 8, marginBottom: 2 }}>
                  <Text style={[st.groupCompactName, { flex: 1 }]} numberOfLines={1}>{group.name}</Text>
                  {group.is_verified && (
                    <VerifiedBadge size={16} tier={(group as any).is_plus_active ? 'plus' : 'free'} />
                  )}
                  <View style={[st.groupRolePill, groupRole === 'member' && { backgroundColor: 'rgba(99,102,241,0.22)', borderColor: 'rgba(99,102,241,0.5)' }]}>
                    <Text style={[st.groupRolePillText, groupRole === 'member' && { color: '#a5b4fc' }]}>
                      {groupRole === 'owner' ? 'Dueño' : 'Integrante'}
                    </Text>
                  </View>
                </View>
                {group.genre && <Text style={st.groupCompactGenre}>{group.genre}</Text>}
                {(group.city || group.country) && (
                  <View style={{ flexDirection: 'row', alignItems: 'center', gap: 4, marginTop: 2 }}>
                    <MapPin size={10} color={COLORS.muted} />
                    <Text style={st.groupCompactLoc}>{[group.city, group.country].filter(Boolean).join(', ')}</Text>
                  </View>
                )}
                <View style={{ flexDirection: 'row', gap: 6, marginTop: 6, flexWrap: 'wrap' }}>
                  {group.rating != null && (
                    <View style={st.groupCompactChip}>
                      <Star size={9} color={COLORS.gold} fill={COLORS.gold} />
                      <Text style={[st.groupCompactChipText, { color: COLORS.gold }]}>{group.rating.toFixed(1)}</Text>
                    </View>
                  )}
                  {groupRole === 'member' && (
                    <View style={st.groupCompactChip}>
                      <Users size={9} color={COLORS.green} />
                      <Text style={[st.groupCompactChipText, { color: COLORS.green }]}>Activo</Text>
                    </View>
                  )}
                </View>
              </View>
            </View>
          )}


          {/* ── REFERIDOS: GRUPO ── */}
          {profile?.role === 'group' && group && (group as any).referral_code && (
            <View style={st.referralCard}>
              <View style={st.referralTopRow}>
                <Gift size={15} color={COLORS.green} />
                <Text style={st.referralCardTitle}>Comparte tu código y gana beneficios</Text>
              </View>
              <Text style={st.referralCardSub}>
                Gana $100 por cada cliente que se registre y haga su primera reserva con tu código
              </Text>
              <View style={st.referralCodeRow}>
                <Text style={st.referralCodeText}>{(group as any).referral_code}</Text>
                <Pressable
                  style={st.referralCopyBtn}
                  onPress={() => Alert.alert('Tu código de referido', (group as any).referral_code)}
                >
                  <Copy size={14} color={COLORS.green} />
                </Pressable>
                <Pressable
                  style={st.referralShareBtn}
                  onPress={() => Share.share({
                    message: `¡Contrata música para tu evento! 🎵\nDescarga DARICEFY y usa mi código ${(group as any).referral_code} al registrarte.\n\ndaricefy://g/${(group as any).referral_code}`,
                  })}
                >
                  <Share2 size={13} color={COLORS.bg} />
                  <Text style={st.referralShareBtnText}>Compartir</Text>
                </Pressable>
              </View>
              {referralStats !== null && (
                <View style={st.referralStatsRow}>
                  <View style={st.referralStat}>
                    <Text style={st.referralStatNum}>{referralStats.total}</Text>
                    <Text style={st.referralStatLabel}>Invitados</Text>
                  </View>
                  <View style={st.referralStatDivider} />
                  <View style={st.referralStat}>
                    <Text style={st.referralStatNum}>{referralStats.pending}</Text>
                    <Text style={st.referralStatLabel}>Pendientes</Text>
                  </View>
                  <View style={st.referralStatDivider} />
                  <View style={st.referralStat}>
                    <Text style={[st.referralStatNum, { color: COLORS.green }]}>${referralStats.earned}</Text>
                    <Text style={st.referralStatLabel}>Ganado</Text>
                  </View>
                </View>
              )}
            </View>
          )}

          {/* ── LEALTAD: CLIENTE ── */}
          {profile?.role === 'client' && loyalty && (
            <ProfileLoyaltyCard loyalty={loyalty} navigation={navigation} />
          )}

          {/* ── REFERIDOS: CLIENTE ── */}
          {profile?.role === 'client' && (
            <View style={st.referralCard}>
              {profile?.referred_by_group_id || referralApplied ? (
                <>
                  <View style={st.referralTopRow}>
                    <CheckCircle size={15} color={COLORS.green} />
                    <Text style={st.referralCardTitle}>Código de referido aplicado</Text>
                  </View>
                  <Text style={st.referralCardSub}>
                    Recibirás un beneficio al completar tu primera reserva
                  </Text>
                </>
              ) : (
                <>
                  <View style={st.referralTopRow}>
                    <Gift size={15} color={COLORS.green} />
                    <Text style={st.referralCardTitle}>¿Tienes un código de invitación?</Text>
                  </View>
                  <Text style={st.referralCardSub}>
                    Ingresa el código que te compartió un grupo y recibe un beneficio en tu primera reserva
                  </Text>
                  <View style={st.referralInputRow}>
                    <TextInput
                      style={st.referralInput}
                      placeholder="Ej: TROVADORES10"
                      placeholderTextColor={COLORS.muted}
                      value={referralInput}
                      onChangeText={(t) => setReferralInput(t.toUpperCase())}
                      autoCapitalize="characters"
                    />
                    <Pressable
                      style={[st.referralApplyBtn, (!referralInput.trim() || applyingCode) && { opacity: 0.5 }]}
                      onPress={handleApplyReferral}
                      disabled={!referralInput.trim() || applyingCode}
                    >
                      {applyingCode
                        ? <ActivityIndicator size="small" color={COLORS.bg} />
                        : <Text style={st.referralApplyBtnText}>Aplicar</Text>
                      }
                    </Pressable>
                  </View>
                </>
              )}
            </View>
          )}

          {/* ── MENÚ ── */}
          <View style={st.menu}>
            <MenuItem icon="👤" label="Editar perfil"        onPress={() => setEditVisible(true)} />
            {profile?.role !== 'admin' && (
              <MenuItem icon="🎸" label="Foto de artista"    onPress={handleChangeAvatar} loading={avatarLoading} />
            )}
            <MenuItem icon="🔔" label="Notificaciones"       onPress={() => navigation.navigate('Notifications')} />
            <MenuItem icon="🔒" label="Cambiar contraseña"   onPress={() => setPassVisible(true)} />
            {/* Clientes no pueden cambiar estado manualmente — lo detecta el GPS */}
            {profile?.role !== 'admin' && profile?.role !== 'client' && (
              <MenuItem icon="📍" label="Cambiar estado"      onPress={openCityModal} />
            )}

            {/* Billetera interna solo para dueños de grupo */}
            {profile?.role === 'group' && (
              <MenuItem
                icon="💰"
                label="Mi Billetera"
                onPress={() => navigation.navigate('Wallet')}
              />
            )}

            {/* Opciones solo para dueños de grupo */}
            {profile?.role === 'group' && (
              <>
                <MenuItem icon="✅" label="Verificación"     onPress={() => navigation.navigate('GroupVerification')} />
              </>
            )}

            {/* Verificación para clientes y talentos */}
            {(profile?.role === 'client' || profile?.role === 'talent') && (
              <MenuItem icon="🛡️" label="Verificación"       onPress={() => navigation.navigate('ClientVerification')} />
            )}

            <MenuItem icon="❓" label="Ayuda y soporte"      onPress={() => setSupportVisible(true)} />
            <MenuItem icon="📜" label="Términos y condiciones" onPress={() => navigation.navigate('Legal', { doc: 'terms' })} />
            <MenuItem icon="🔐" label="Aviso de privacidad"    onPress={() => navigation.navigate('Legal', { doc: 'privacy' })} />
          </View>

          {/* LOGOUT */}
          <Pressable style={st.logoutBtn} onPress={handleSignOut}>
            <LogOut size={18} color={COLORS.red} />
            <Text style={st.logoutText}>Cerrar sesión</Text>
          </Pressable>

          <Text style={st.version}>Daricefy v1.0</Text>
        </ScrollView>
      </SafeAreaView>

      {/* ── MODAL: EDITAR PERFIL ── */}
      <Modal visible={editVisible} transparent animationType="slide">
        <View style={st.overlay}>
          <View style={st.sheet}>
            <View style={st.sheetHeader}>
              <Text style={st.sheetTitle}>Editar perfil</Text>
              <Pressable onPress={() => setEditVisible(false)}>
                <X size={20} color={COLORS.muted2} />
              </Pressable>
            </View>
            <Text style={st.inputLabel}>Nombre completo</Text>
            <TextInput
              style={st.input}
              value={editName}
              onChangeText={setEditName}
              placeholder="Tu nombre"
              placeholderTextColor={COLORS.muted}
              autoCapitalize="words"
            />
            <Pressable
              style={[st.saveBtn, editLoading && st.saveBtnDisabled]}
              onPress={handleSaveProfile}
              disabled={editLoading}
            >
              <Text style={st.saveBtnText}>{editLoading ? 'Guardando...' : 'Guardar cambios'}</Text>
            </Pressable>
          </View>
        </View>
      </Modal>

      {/* ── MODAL: CAMBIAR CONTRASEÑA ── */}
      <Modal visible={passVisible} transparent animationType="slide">
        <View style={st.overlay}>
          <View style={st.sheet}>
            <View style={st.sheetHeader}>
              <Text style={st.sheetTitle}>Cambiar contraseña</Text>
              <Pressable onPress={() => { setPassVisible(false); setNewPass(''); setConfirmPass(''); }}>
                <X size={20} color={COLORS.muted2} />
              </Pressable>
            </View>
            <Text style={st.inputLabel}>Nueva contraseña</Text>
            <View style={st.passRow}>
              <TextInput
                style={[st.input, { flex: 1, marginBottom: 0 }]}
                value={newPass}
                onChangeText={setNewPass}
                placeholder="Mínimo 6 caracteres"
                placeholderTextColor={COLORS.muted}
                secureTextEntry={!showNew}
                autoCapitalize="none"
              />
              <Pressable style={st.eyeBtn} onPress={() => setShowNew(v => !v)}>
                {showNew ? <EyeOff size={18} color={COLORS.muted2} /> : <Eye size={18} color={COLORS.muted2} />}
              </Pressable>
            </View>
            <Text style={[st.inputLabel, { marginTop: 16 }]}>Confirmar contraseña</Text>
            <View style={st.passRow}>
              <TextInput
                style={[st.input, { flex: 1, marginBottom: 0 }]}
                value={confirmPass}
                onChangeText={setConfirmPass}
                placeholder="Repite la contraseña"
                placeholderTextColor={COLORS.muted}
                secureTextEntry={!showConfirm}
                autoCapitalize="none"
              />
              <Pressable style={st.eyeBtn} onPress={() => setShowConfirm(v => !v)}>
                {showConfirm ? <EyeOff size={18} color={COLORS.muted2} /> : <Eye size={18} color={COLORS.muted2} />}
              </Pressable>
            </View>
            <Pressable
              style={[st.saveBtn, { marginTop: 24 }, passLoading && st.saveBtnDisabled]}
              onPress={handleChangePassword}
              disabled={passLoading}
            >
              <Text style={st.saveBtnText}>{passLoading ? 'Cambiando...' : 'Cambiar contraseña'}</Text>
            </Pressable>
          </View>
        </View>
      </Modal>

      {/* ── MODAL: CAMBIAR UBICACIÓN ── */}
      <Modal visible={cityModalVisible} transparent animationType="slide">
        <View style={st.overlay}>
          <View style={[st.sheet, { maxHeight: '85%' }]}>
            <View style={st.sheetHeader}>
              <Text style={st.sheetTitle}>¿En qué estado estás?</Text>
              <Pressable onPress={() => setCityModalVisible(false)}>
                <X size={20} color={COLORS.muted2} />
              </Pressable>
            </View>

            {/* Botón GPS — detecta estado sin depender de la lista */}
            <Pressable
              style={[st.gpsBtn, (gpsLoading || citySaving) && { opacity: 0.6 }]}
              onPress={handleDetectByGPS}
              disabled={gpsLoading || citySaving}
            >
              {gpsLoading
                ? <ActivityIndicator size="small" color={COLORS.green} />
                : <MapPin size={15} color={COLORS.green} />
              }
              <Text style={st.gpsBtnText}>
                {gpsLoading ? 'Detectando...' : 'Detectar mi ubicación'}
              </Text>
            </Pressable>

            <View style={st.orDivider}>
              <View style={st.orLine} />
              <Text style={st.orText}>o busca manualmente</Text>
              <View style={st.orLine} />
            </View>

            <TextInput
              style={[st.input, { marginBottom: 8 }]}
              placeholder="Ej: Jalisco, Nuevo León, California..."
              placeholderTextColor={COLORS.muted}
              value={citySearch}
              onChangeText={handleCitySearch}
              autoCapitalize="words"
              returnKeyType="search"
            />

            {cityLoading ? (
              <ActivityIndicator size="small" color={COLORS.green} style={{ marginVertical: 24 }} />
            ) : (
              <FlatList
                data={cityFiltered}
                keyExtractor={(item) => item.id?.toString() ?? item.name}
                style={{ maxHeight: 300 }}
                keyboardShouldPersistTaps="handled"
                ListEmptyComponent={
                  <View style={st.cityEmpty}>
                    <Text style={st.cityEmptyIcon}>🔍</Text>
                    <Text style={st.cityEmptyText}>
                      {citySearch.trim()
                        ? `No encontramos "${citySearch}".\nEscribe ej: Jalisco, Nuevo León, California.`
                        : 'Escribe tu estado arriba.'}
                    </Text>
                  </View>
                }
                renderItem={({ item }) => {
                  const isSelected = citySelected?.id === item.id || citySelected?.name === item.name;
                  return (
                    <Pressable
                      style={[st.cityRow, isSelected && st.cityRowSelected]}
                      onPress={() => setCitySelected(item)}
                    >
                      <View style={{ flex: 1 }}>
                        <Text style={[st.cityRowName, isSelected && { color: COLORS.green }]}>
                          {item.name}
                        </Text>
                        {item.country_name && (
                          <Text style={st.cityRowState}>{item.country_name}</Text>
                        )}
                      </View>
                      {isSelected && <CheckCircle size={16} color={COLORS.green} />}
                    </Pressable>
                  );
                }}
              />
            )}

            {citySelected && (
              <View style={st.citySelectedBanner}>
                <MapPin size={13} color={COLORS.green} />
                <Text style={st.citySelectedText}>
                  {citySelected.name}
                  {citySelected.country_name ? ` · ${citySelected.country_name}` : ''}
                </Text>
              </View>
            )}

            <Pressable
              style={[st.saveBtn, { marginTop: 12 }, (!citySelected || citySaving) && st.saveBtnDisabled]}
              onPress={handleConfirmCity}
              disabled={!citySelected || citySaving}
            >
              <Text style={st.saveBtnText}>{citySaving ? 'Guardando...' : 'Confirmar ubicación'}</Text>
            </Pressable>
          </View>
        </View>
      </Modal>

      {/* ── MODAL: CIUDADES DE SERVICIO ── */}
      <Modal visible={serviceCitiesModal} transparent animationType="slide">
        <View style={st.overlay}>
          <View style={st.sheet}>
            <View style={st.sheetHeader}>
              <Text style={st.sheetTitle}>Ciudades de servicio</Text>
              <Pressable onPress={() => setServiceCitiesModal(false)}>
                <X size={20} color={COLORS.muted2} />
              </Pressable>
            </View>
            <Text style={[st.cityRowState, { marginBottom: 12 }]}>
              Selecciona hasta 10 ciudades adicionales donde aceptas trabajar (distinta a tu ciudad base).
            </Text>
            <TextInput
              style={[st.input, { marginBottom: 12 }]}
              placeholder="Buscar ciudad..."
              placeholderTextColor={COLORS.muted}
              value={serviceCitiesSearch}
              onChangeText={setServiceCitiesSearch}
              autoCapitalize="none"
            />
            <FlatList
              data={cityOptions.filter(c =>
                serviceCitiesSearch.trim()
                  ? c.name.toLowerCase().includes(serviceCitiesSearch.toLowerCase()) ||
                    c.state_name?.toLowerCase().includes(serviceCitiesSearch.toLowerCase())
                  : true
              )}
              keyExtractor={(item) => item.id?.toString() ?? item.name}
              style={{ maxHeight: 300 }}
              keyboardShouldPersistTaps="handled"
              renderItem={({ item }) => {
                const isSelected = serviceCitiesSelected.includes(item.name);
                return (
                  <Pressable
                    style={[st.cityRow, isSelected && st.cityRowSelected]}
                    onPress={() => toggleServiceCity(item.name)}
                  >
                    <View style={{ flex: 1 }}>
                      <Text style={[st.cityRowName, isSelected && { color: COLORS.green }]}>
                        {item.name}
                      </Text>
                      {item.state_name && (
                        <Text style={st.cityRowState}>{item.state_name}</Text>
                      )}
                    </View>
                    {isSelected && <CheckCircle size={16} color={COLORS.green} />}
                  </Pressable>
                );
              }}
            />
            {serviceCitiesSelected.length > 0 && (
              <Text style={[st.cityRowState, { marginTop: 8, textAlign: 'center' }]}>
                {serviceCitiesSelected.length}/10 ciudades seleccionadas
              </Text>
            )}
            <Pressable
              style={[st.saveBtn, { marginTop: 16 }, serviceCitiesSaving && st.saveBtnDisabled]}
              onPress={handleSaveServiceCities}
              disabled={serviceCitiesSaving}
            >
              <Text style={st.saveBtnText}>{serviceCitiesSaving ? 'Guardando...' : 'Guardar ciudades'}</Text>
            </Pressable>
          </View>
        </View>
      </Modal>

      {/* ── MODAL: AYUDA Y SOPORTE ── */}
      <Modal visible={supportVisible} transparent animationType="slide">
        <View style={st.overlay}>
          <View style={st.sheet}>
            <View style={st.sheetHeader}>
              <Text style={st.sheetTitle}>Ayuda y soporte</Text>
              <Pressable onPress={() => setSupportVisible(false)}>
                <X size={20} color={COLORS.muted2} />
              </Pressable>
            </View>
            <Text style={st.supportText}>
              ¿Tienes algún problema o duda? Contáctanos y te ayudaremos lo antes posible.
            </Text>
            <Pressable
              style={st.supportBtn}
              onPress={() => openSupportEmail()}
            >
              <Text style={st.supportBtnText}>📧 Enviar correo</Text>
            </Pressable>
            <Pressable
              style={[st.supportBtn, { backgroundColor: 'rgba(37,211,102,0.12)', borderColor: 'rgba(37,211,102,0.4)' }]}
              onPress={() => openSupportWhatsApp()}
            >
              <Text style={[st.supportBtnText, { color: '#25D366' }]}>💬 WhatsApp</Text>
            </Pressable>
            <Text style={st.supportNote}>Horario: {SUPPORT_HOURS}</Text>
          </View>
        </View>
      </Modal>
    </View>
  );
}

// ─── MenuItem ─────────────────────────────────────────────────────────────────

function MenuItem({ icon, label, onPress, loading }: {
  icon: string; label: string; onPress: () => void; loading?: boolean;
}) {
  return (
    <Pressable style={[st.menuItem, loading && { opacity: 0.6 }]} onPress={onPress} disabled={loading}>
      <Text style={st.menuIcon}>{icon}</Text>
      <Text style={st.menuLabel}>{label}</Text>
      {loading
        ? <ActivityIndicator size="small" color={COLORS.green} />
        : <ChevronRight size={16} color={COLORS.muted} />}
    </Pressable>
  );
}

// ─── Loyalty card (solo clientes) ────────────────────────────────────────────

const LOYALTY_TIERS: Record<string, { emoji: string; label: string; color: string }> = {
  bronze: { emoji: '🥉', label: 'Bronce', color: '#CD7F32' },
  silver: { emoji: '🥈', label: 'Plata',  color: '#A8A9AD' },
  gold:   { emoji: '🥇', label: 'Oro',    color: '#FFD700' },
  vip:    { emoji: '💎', label: 'VIP',    color: '#A78BFA' },
};

function ProfileLoyaltyCard({ loyalty, navigation }: { loyalty: any; navigation: any }) {
  const tier     = loyalty.loyalty_tier       ?? 'bronze';
  const points   = loyalty.loyalty_points     ?? 0;
  const toNext   = loyalty.points_to_next_tier ?? 0;
  const nextTier = loyalty.next_tier          ?? 'silver';
  const discount = loyalty.discount_pct       ?? 0;
  const cfg      = LOYALTY_TIERS[tier]     ?? LOYALTY_TIERS.bronze;
  const nextCfg  = LOYALTY_TIERS[nextTier] ?? LOYALTY_TIERS.silver;

  const tierMin: Record<string, number> = { bronze: 0, silver: 50, gold: 150, vip: 300 };
  const tierMax: Record<string, number> = { bronze: 50, silver: 150, gold: 300, vip: 300 };
  const min      = tierMin[tier] ?? 0;
  const max      = tierMax[tier] ?? 50;
  const progress = tier === 'vip' ? 1 : Math.min(1, (points - min) / (max - min));

  return (
    <Pressable
      style={[st.loyaltyCard, { borderColor: cfg.color + '40' }]}
      onPress={() => navigation.navigate('ClientReservations')}
    >
      <LinearGradient
        colors={[cfg.color + '12', 'transparent']}
        style={StyleSheet.absoluteFillObject}
        start={{ x: 0, y: 0 }} end={{ x: 1, y: 1 }}
      />
      <View style={[st.loyaltyIcon, { borderColor: cfg.color + '50' }]}>
        <Text style={{ fontSize: 22 }}>{cfg.emoji}</Text>
      </View>
      <View style={{ flex: 1 }}>
        <View style={st.loyaltyRow}>
          <Text style={[st.loyaltyTier, { color: cfg.color }]}>{cfg.label}</Text>
          <Text style={st.loyaltyPts}>{points} pts</Text>
        </View>
        <View style={st.loyaltyBarBg}>
          <View style={[st.loyaltyBarFill, { width: `${Math.round(progress * 100)}%` as any, backgroundColor: cfg.color }]} />
        </View>
        <Text style={st.loyaltyNext}>
          {tier === 'vip' ? '¡Nivel máximo alcanzado!' : `${toNext} pts para ${nextCfg.emoji} ${nextCfg.label}`}
        </Text>
      </View>
      {discount > 0 && (
        <View style={[st.loyaltyDiscount, { borderColor: cfg.color }]}>
          <Text style={[st.loyaltyDiscountTxt, { color: cfg.color }]}>{discount}%{'\n'}OFF</Text>
        </View>
      )}
    </Pressable>
  );
}

// ─── Styles ───────────────────────────────────────────────────────────────────

const st = StyleSheet.create({
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
  headerTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 16, color: COLORS.text },

  // ── Hero artista (foto grande, full-width) ─────────────────────────────────
  artistHero: {
    marginBottom: 16,
    borderBottomWidth: 1, borderBottomColor: COLORS.border,
  },
  artistHeroImg: {
    width: '100%', height: 240,
    justifyContent: 'flex-end',
  },
  artistHeroPlaceholder: {
    backgroundColor: COLORS.card2,
    alignItems: 'center', justifyContent: 'center',
    overflow: 'hidden',
  },
  artistHeroInitialBig: {
    position: 'absolute',
    fontFamily: FONTS.title, fontSize: 100, color: COLORS.green, opacity: 0.18,
  },
  artistHeroGradient: {
    paddingHorizontal: SPACING.xl, paddingTop: 40, paddingBottom: 20,
  },
  artistHeroCam: {
    position: 'absolute', top: 12, right: 12,
    width: 36, height: 36, borderRadius: 18,
    backgroundColor: 'rgba(0,0,0,0.55)',
    alignItems: 'center', justifyContent: 'center',
    borderWidth: 1, borderColor: 'rgba(255,255,255,0.25)',
  },
  artistHeroInfo: { gap: 4 },
  artistHeroName:  { fontFamily: FONTS.title, fontSize: 24, color: '#fff' },
  artistHeroEmail: { fontFamily: FONTS.body, fontSize: 13, color: 'rgba(255,255,255,0.65)', marginBottom: 8 },
  artistHeroRolePill: {
    alignSelf: 'flex-start',
    backgroundColor: 'rgba(255,255,255,0.15)', borderRadius: RADIUS.full,
    borderWidth: 1, borderColor: 'rgba(255,255,255,0.3)',
    paddingHorizontal: 12, paddingVertical: 4,
  },
  artistHeroRolePillText: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: '#fff' },
  artistHeroLocRow: { flexDirection: 'row', alignItems: 'center', gap: 4, marginTop: 6 },
  artistHeroLoc: { fontFamily: FONTS.body, fontSize: 12, color: 'rgba(255,255,255,0.65)' },

  // ── Grupo compacto (foto pequeña + info al lado) ───────────────────────────
  groupCompactCard: {
    flexDirection: 'row', alignItems: 'center', gap: 14,
    marginHorizontal: SPACING.xl, marginBottom: 20,
    backgroundColor: COLORS.card, borderRadius: RADIUS.xl,
    borderWidth: 1, borderColor: COLORS.border,
    padding: 14, overflow: 'hidden',
  },
  groupCompactImg: {
    width: 70, height: 70, borderRadius: RADIUS.lg,
  },
  groupCompactImgPlaceholder: {
    backgroundColor: COLORS.card2,
    alignItems: 'center', justifyContent: 'center',
  },
  groupCompactInitialText: { fontFamily: FONTS.title, fontSize: 28, color: COLORS.green, opacity: 0.6 },
  groupCompactName:  { fontFamily: FONTS.title, fontSize: 16, color: COLORS.text, flex: 1 },
  groupCompactGenre: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.green, marginTop: 1 },
  groupCompactLoc:   { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted },
  groupRolePill: {
    paddingHorizontal: 7, paddingVertical: 2, borderRadius: RADIUS.full,
    backgroundColor: 'rgba(0,230,118,0.15)', borderWidth: 1, borderColor: 'rgba(0,230,118,0.45)',
  },
  groupRolePillText: { fontFamily: FONTS.bodyMedium, fontSize: 10, color: COLORS.green },
  groupCompactChip: {
    flexDirection: 'row', alignItems: 'center', gap: 3,
    paddingHorizontal: 7, paddingVertical: 2, borderRadius: RADIUS.full,
    backgroundColor: COLORS.card2, borderWidth: 1, borderColor: COLORS.border,
  },
  groupCompactChipText: { fontFamily: FONTS.bodyMedium, fontSize: 10, color: COLORS.text },

  // ── Stripe Connect ─────────────────────────────────────────────────────────
  stripeBanner: {
    flexDirection: 'row', alignItems: 'center', gap: 12,
    marginHorizontal: SPACING.xl, marginBottom: 16,
    backgroundColor: 'rgba(0,230,118,0.07)', borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.35)',
    padding: 14,
  },
  stripeBannerWarn: {
    backgroundColor: 'rgba(255,179,0,0.07)',
    borderColor: 'rgba(255,179,0,0.4)',
  },
  stripeBannerIcon: { fontSize: 22 },
  stripeBannerTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.text, marginBottom: 2 },
  stripeBannerSub:   { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2 },
  stripeActiveRow: {
    flexDirection: 'row', alignItems: 'center', gap: 6,
    marginHorizontal: SPACING.xl, marginBottom: 16,
    paddingVertical: 10, paddingHorizontal: 14,
    backgroundColor: 'rgba(0,230,118,0.08)', borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.25)',
  },
  stripeActiveText: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.green },
  stripeActiveSub:  { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted2, marginTop: 2 },

  // ── Menú ───────────────────────────────────────────────────────────────────
  menu: { paddingHorizontal: SPACING.xl, marginBottom: 20 },
  menuItem: {
    flexDirection: 'row', alignItems: 'center', gap: 14,
    paddingVertical: 16,
    borderBottomWidth: 1, borderBottomColor: COLORS.border,
  },
  menuIcon:  { fontSize: 18, width: 24, textAlign: 'center' },
  menuLabel: { fontFamily: FONTS.bodyMedium, fontSize: 15, color: COLORS.text, flex: 1 },

  premiumBtn: {
    marginHorizontal: SPACING.xl, paddingVertical: 13, marginBottom: 12,
    borderRadius: RADIUS.lg, borderWidth: 1,
    borderColor: 'rgba(255,179,0,0.4)', backgroundColor: 'rgba(255,179,0,0.07)',
    alignItems: 'center',
  },
  premiumBtnText: { fontFamily: FONTS.bodyMedium, fontSize: 14, color: COLORS.gold },

  logoutBtn: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 10,
    marginHorizontal: SPACING.xl, paddingVertical: 16,
    borderRadius: RADIUS.lg, borderWidth: 1, borderColor: 'rgba(239,83,80,0.3)',
    backgroundColor: 'rgba(239,83,80,0.08)', marginBottom: 20,
  },
  logoutText: { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.red },
  version: { textAlign: 'center', fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted, marginBottom: 32 },

  // ── Modals ──────────────────────────────────────────────────────────────────
  overlay: { flex: 1, backgroundColor: 'rgba(0,0,0,0.6)', justifyContent: 'flex-end' },
  sheet: {
    backgroundColor: COLORS.card, borderTopLeftRadius: 24, borderTopRightRadius: 24,
    padding: SPACING.xl, paddingBottom: 40,
    borderTopWidth: 1, borderColor: COLORS.border,
  },
  sheetHeader: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center', marginBottom: 24 },
  sheetTitle:  { fontFamily: FONTS.title, fontSize: 20, color: COLORS.text },
  inputLabel:  { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted2, marginBottom: 8 },
  input: {
    backgroundColor: COLORS.bg, borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: COLORS.border,
    paddingHorizontal: 14, paddingVertical: 13,
    fontFamily: FONTS.body, fontSize: 15, color: COLORS.text,
    marginBottom: 20,
  },
  saveBtn: {
    backgroundColor: COLORS.green, borderRadius: RADIUS.md,
    paddingVertical: 14, alignItems: 'center',
  },
  saveBtnDisabled: { opacity: 0.6 },
  saveBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.bg },
  passRow: { flexDirection: 'row', alignItems: 'center', gap: 10, marginBottom: 8 },
  eyeBtn: { padding: 8 },
  supportText: { fontFamily: FONTS.body, fontSize: 14, color: COLORS.muted2, lineHeight: 22, marginBottom: 20 },
  supportBtn: {
    paddingVertical: 14, borderRadius: RADIUS.md, alignItems: 'center',
    borderWidth: 1, borderColor: COLORS.border,
    backgroundColor: COLORS.card2, marginBottom: 12,
  },
  supportBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.text },
  supportNote: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted, textAlign: 'center', marginTop: 8 },

  // ── Referidos ─────────────────────────────────────────────────────────────
  referralCard: {
    marginHorizontal: SPACING.xl, marginBottom: 16,
    backgroundColor: COLORS.card, borderRadius: RADIUS.xl,
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.3)',
    padding: SPACING.lg,
  },
  referralTopRow: { flexDirection: 'row', alignItems: 'center', gap: 8, marginBottom: 4 },
  referralCardTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.text, flex: 1 },
  referralCardSub: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, lineHeight: 17, marginBottom: 14 },
  referralCodeRow: { flexDirection: 'row', alignItems: 'center', gap: 8, marginBottom: 12 },
  referralCodeText: {
    fontFamily: FONTS.title, fontSize: 22, color: COLORS.green,
    flex: 1, letterSpacing: 1,
  },
  referralCopyBtn: {
    width: 36, height: 36, borderRadius: RADIUS.md,
    backgroundColor: COLORS.greenMuted, borderWidth: 1, borderColor: COLORS.green,
    alignItems: 'center', justifyContent: 'center',
  },
  referralShareBtn: {
    flexDirection: 'row', alignItems: 'center', gap: 6,
    backgroundColor: COLORS.green, borderRadius: RADIUS.md,
    paddingHorizontal: 14, paddingVertical: 9,
  },
  referralShareBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.bg },
  referralStatsRow: {
    flexDirection: 'row', alignItems: 'center',
    backgroundColor: COLORS.card2, borderRadius: RADIUS.md,
    paddingVertical: 12, paddingHorizontal: 8,
  },
  referralStat: { flex: 1, alignItems: 'center' },
  referralStatNum: { fontFamily: FONTS.title, fontSize: 20, color: COLORS.text },
  referralStatLabel: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted2, marginTop: 2 },
  referralStatDivider: { width: 1, height: 30, backgroundColor: COLORS.border },
  referralInputRow: { flexDirection: 'row', alignItems: 'center', gap: 10 },
  referralInput: {
    flex: 1, backgroundColor: COLORS.card2, borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: COLORS.border,
    paddingHorizontal: 14, paddingVertical: 11,
    fontFamily: FONTS.bodySemiBold, fontSize: 15,
    color: COLORS.text, letterSpacing: 1,
  },
  referralApplyBtn: {
    backgroundColor: COLORS.green, borderRadius: RADIUS.md,
    paddingHorizontal: 18, paddingVertical: 12,
    alignItems: 'center', justifyContent: 'center',
  },
  referralApplyBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.bg },

  // ── Ciudad ─────────────────────────────────────────────────────────────────
  gpsBtn: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 8,
    backgroundColor: COLORS.greenMuted,
    borderWidth: 1.5, borderColor: COLORS.green,
    borderRadius: RADIUS.lg, paddingVertical: 13,
    marginBottom: 16,
  },
  gpsBtnText: {
    fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.green,
  },
  orDivider: {
    flexDirection: 'row', alignItems: 'center', gap: 10, marginBottom: 14,
  },
  orLine: { flex: 1, height: 1, backgroundColor: COLORS.border },
  orText:  { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted },

  cityRow: {
    flexDirection: 'row', alignItems: 'center',
    paddingVertical: 12, paddingHorizontal: 4,
    borderBottomWidth: 1, borderBottomColor: COLORS.border,
  },
  cityRowSelected: {
    backgroundColor: 'rgba(0,230,118,0.06)',
    borderRadius: RADIUS.sm,
    borderBottomColor: 'transparent',
    paddingHorizontal: 8,
  },
  cityHint: {
    fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2,
    marginBottom: 12, lineHeight: 18,
  },
  cityRowName:  { fontFamily: FONTS.bodyMedium, fontSize: 15, color: COLORS.text },
  cityRowState: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted, marginTop: 1 },
  cityEmpty: {
    alignItems: 'center', paddingVertical: 32, gap: 8,
  },
  cityEmptyIcon: { fontSize: 28 },
  cityEmptyText: {
    fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2,
    textAlign: 'center', lineHeight: 20,
  },
  citySelectedBanner: {
    flexDirection: 'row', alignItems: 'center', gap: 6,
    backgroundColor: COLORS.greenMuted, borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: `${COLORS.green}44`,
    paddingHorizontal: 12, paddingVertical: 8, marginTop: 8,
  },
  citySelectedText: {
    fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.green, flex: 1,
  },

  loyaltyCard: {
    flexDirection: 'row', alignItems: 'center', gap: 12,
    backgroundColor: COLORS.card, borderRadius: RADIUS.xl,
    borderWidth: 1, padding: 14, overflow: 'hidden', marginBottom: 12,
  },
  loyaltyIcon: {
    width: 44, height: 44, borderRadius: 22,
    backgroundColor: COLORS.bg, borderWidth: 1,
    alignItems: 'center', justifyContent: 'center',
  },
  loyaltyRow:        { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center', marginBottom: 6 },
  loyaltyTier:       { fontFamily: FONTS.bodySemiBold, fontSize: 14 },
  loyaltyPts:        { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.muted2 },
  loyaltyBarBg:      { height: 5, backgroundColor: COLORS.border, borderRadius: 3, overflow: 'hidden', marginBottom: 4 },
  loyaltyBarFill:    { height: '100%' as any, borderRadius: 3 },
  loyaltyNext:       { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted },
  loyaltyDiscount:   { width: 40, height: 40, borderRadius: 8, borderWidth: 1.5, alignItems: 'center', justifyContent: 'center', backgroundColor: 'rgba(0,0,0,0.4)' },
  loyaltyDiscountTxt:{ fontFamily: FONTS.bodySemiBold, fontSize: 11, textAlign: 'center', lineHeight: 14 },
});
