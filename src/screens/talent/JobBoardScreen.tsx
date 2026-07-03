import {
  Bell,
  Briefcase,
  Calendar,
  Camera,
  CheckCircle,
  ChevronRight,
  Clock,
  DollarSign,
  Edit3,
  Eye,
  EyeOff,
  FileText,
  MapPin,
  Music2,
  Save,
  Shield,
  Star,
  Users,
  X,
  XCircle,
} from 'lucide-react-native';
import { LinearGradient } from 'expo-linear-gradient';
import VideoPlayer from '../../components/ui/VideoPlayer';
import * as ImagePicker from 'expo-image-picker';
import React, { useEffect, useRef, useState } from 'react';
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
} from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import Particles from '../../components/ui/Particles';
import VerifiedBadge from '../../components/ui/VerifiedBadge';
import { supabase, supabaseUrl, supabaseAnonKey } from '../../config/supabase';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';
import { pickAndUploadProfileImage } from '../../utils/uploadProfileImage';
import { isUpcoming } from '../../utils/eventFilter';
import { useAuth } from '../../context/AuthContext';
import { useBackgroundLocation } from '../../hooks/useBackgroundLocation';

// ─── Constants ────────────────────────────────────────────────────────────────

const EVENT_EMOJI: Record<string, string> = {
  fiesta_privada: '🎉', boda: '💍', cumpleanos: '🎂',
  graduacion: '🎓', empresarial: '🏢', otro: '🎵',
};

// ─── Types ────────────────────────────────────────────────────────────────────

interface JobProfile {
  id: string;
  instrument_or_role: string;
  bio: string | null;
  experience_years: number;
  rating: number;
  total_jobs: number;
  availability_status: 'available' | 'busy';
  is_visible: boolean;
  video_url: string | null;
  city: string | null;
  musical_styles: string[] | null;
  social_instagram: string | null;
  social_tiktok: string | null;
}

interface Invitation {
  id: string;
  event_id: string | null;
  proposed_payment_amount: number | null;
  message: string | null;
  status: 'pending' | 'accepted' | 'rejected';
  created_at: string;
  group: {
    id: string;
    name: string;
    genre: string | null;
    profile_image: string | null;
    rating: number | null;
    total_reviews: number | null;
    members_count: number | null;
    // Campos nuevos (sql/250) — opcionales para backward compat
    is_verified?: boolean;
    created_at?: string | null;
    completed_events?: number;
  } | null;
  event: {
    event_date: string;
    address: string;
    reservations: Array<{
      event_time: string | null;
      hours_count: number | null;
      quote: { event_type: string | null; duration_hours: number | null } | null;
    }>;
  } | null;
}

type InvFilter = 'pending' | 'all';

interface GroupReservation {
  id: string;
  status: string;
  event_date: string;
  event_time: string | null;
  address: string;
  total_price: number | null;
  group_id: string;
  event_id: string | null;
  event_started_at: string | null;
  break_type: string | null;
  hours_count: number | null;
  quote: { event_type: string | null; duration_hours: number | null } | null;
}

interface GroupQuote {
  id: string;
  status: string;
  event_type: string;
  event_date: string | null;
  duration_hours: number;
  created_at: string;
  client: { full_name: string } | null;
}

// ─── Screen ───────────────────────────────────────────────────────────────────

export default function TalentJobBoardScreen({ navigation }: any) {
  const { refetchProfile } = useAuth();
  useBackgroundLocation(); // GPS en vivo — actualiza talent_locations en background
  const [jobProfile, setJobProfile]   = useState<JobProfile | null>(null);
  const [fullName, setFullName]       = useState('');
  const [invitations, setInvitations] = useState<Invitation[]>([]);
  const [loading, setLoading]         = useState(true);
  const [refreshing, setRefreshing]   = useState(false);
  const [saving, setSaving]           = useState(false);
  const [editing, setEditing]         = useState(false);
  const [userId, setUserId]           = useState<string | null>(null);
  const [unread, setUnread]           = useState(0);
  const [avatar, setAvatar]           = useState<string | null>(null);
  const [photoLoading, setPhotoLoading] = useState(false);
  const [invFilter, setInvFilter]       = useState<InvFilter>('pending');
  const [verified, setVerified]         = useState(false);
  const [groupReservations, setGroupReservations] = useState<GroupReservation[]>([]);
  const [pendingQuotes, setPendingQuotes] = useState<GroupQuote[]>([]);

  // Edit form
  const [editInstrument, setEditInstrument] = useState('');
  const [editBio, setEditBio]               = useState('');
  const [editExpYears, setEditExpYears]      = useState('');
  const [editCity, setEditCity]             = useState('');
  const [editStyles, setEditStyles]         = useState('');
  const [editInstagram, setEditInstagram]   = useState('');
  const [editTiktok, setEditTiktok]         = useState('');
  const [videoUploading, setVideoUploading] = useState(false);
  const [uploadProgress, setUploadProgress] = useState(0);
  const mountedRef  = useRef(true);
  const videoRef    = useRef<any>(null);

  useEffect(() => { load(); }, []);
  useEffect(() => {
    const unsub = navigation.addListener('focus', fetchUnread);
    return unsub;
  }, [navigation]);
  useEffect(() => {
    mountedRef.current = true;
    return () => {
      mountedRef.current = false;
      videoRef.current?.unloadAsync?.();
    };
  }, []);

  const fetchUnread = async () => {
    const { data: sd } = await supabase.auth.getSession();
    if (!sd.session) return;
    const { count } = await supabase
      .from('notifications')
      .select('*', { count: 'exact', head: true })
      .eq('user_id', sd.session.user.id)
      .eq('is_read', false);
    setUnread(count ?? 0);
  };

  const load = async (isRefresh = false) => {
    if (isRefresh) setRefreshing(true); else setLoading(true);
    const { data: sessionData } = await supabase.auth.getSession();
    const uid = sessionData.session?.user.id;
    if (!uid) { setLoading(false); setRefreshing(false); return; }
    setUserId(uid);

    const [profileRes, invRes, profRes] = await Promise.all([
      supabase.from('job_board_profiles').select('*').eq('user_id', uid).maybeSingle(),
      supabase.rpc('get_my_job_invitations'),
      supabase.from('profiles').select('full_name, avatar_url, phone_verified, id_verified, verification_status, admin_verified').eq('id', uid).maybeSingle(),
    ]);

    if (profileRes.data) {
      setJobProfile(profileRes.data);
      setEditInstrument(profileRes.data.instrument_or_role ?? '');
      setEditBio(profileRes.data.bio ?? '');
      setEditExpYears(String(profileRes.data.experience_years ?? 0));
      setEditCity(profileRes.data.city ?? '');
      setEditStyles((profileRes.data.musical_styles ?? []).join(', '));
      setEditInstagram(profileRes.data.social_instagram ?? '');
      setEditTiktok(profileRes.data.social_tiktok ?? '');
    }
    if (invRes.error) console.error('[JobBoard] invitations RPC error:', invRes.error);
    if (invRes.data)  setInvitations(invRes.data as any);
    if (profRes.data) {
      setFullName(profRes.data.full_name ?? '');
      if (profRes.data.avatar_url) setAvatar(profRes.data.avatar_url);
      setVerified(
        (profRes.data.phone_verified ?? false) ||
        (profRes.data.id_verified ?? false) ||
        (profRes.data.verification_status === 'approved')
      );
    }

    // Cargar reservas del grupo si el talento es integrante aceptado
    const acceptedGroups = (invRes.data as any[])?.filter(
      (i: any) => i.status === 'accepted' && !i.event_id
    ) ?? [];
    if (acceptedGroups.length > 0) {
      const groupId = acceptedGroups[0]?.group?.id;
      if (groupId) {
        const [resData, quotesData] = await Promise.all([
          supabase
            .from('reservations')
            .select(`
              id, status, event_date, event_time, address, total_price, group_id,
              event_id, event_started_at, break_type, hours_count, quote_id,
              quote:quotes!left(event_type, duration_hours)
            `)
            .eq('group_id', groupId)
            .in('status', ['pending', 'pending_group_confirmation', 'confirmed', 'in_progress'])
            .order('event_date', { ascending: true }),
          supabase
            .from('quotes')
            .select('id, status, event_type, event_date, duration_hours, created_at, client:profiles!client_id(full_name)')
            .eq('group_id', groupId)
            .in('status', ['pending', 'quoted'])
            .order('created_at', { ascending: false })
            .limit(5),
        ]);
        if (resData.data) setGroupReservations(resData.data as any);
        if (quotesData.data) setPendingQuotes(quotesData.data as any);
      }
    }

    fetchUnread();
    if (isRefresh) setRefreshing(false); else setLoading(false);
  };

  const handlePhoto = async () => {
    if (!userId) return;
    try {
      setPhotoLoading(true);
      const url = await pickAndUploadProfileImage(userId);
      if (url) { setAvatar(url); await refetchProfile(); }
    } catch {
      Alert.alert('Error', 'No se pudo subir la foto.');
    } finally { setPhotoLoading(false); }
  };

  const toggleVisibility = async () => {
    if (!jobProfile || !userId) return;
    const newVal = !jobProfile.is_visible;
    await supabase.from('job_board_profiles').update({ is_visible: newVal }).eq('user_id', userId);
    setJobProfile(p => p ? { ...p, is_visible: newVal } : p);
  };

  const toggleAvailability = async () => {
    if (!jobProfile || !userId) return;
    const newStatus = jobProfile.availability_status === 'available' ? 'busy' : 'available';
    await supabase.from('job_board_profiles').update({ availability_status: newStatus }).eq('user_id', userId);
    setJobProfile(p => p ? { ...p, availability_status: newStatus } : p);
  };

  const saveProfile = async () => {
    if (!userId) return;
    if (!editInstrument.trim()) { Alert.alert('Error', 'El instrumento o rol no puede estar vacío'); return; }
    setSaving(true);
    const parsedStyles = editStyles.trim()
      ? editStyles.split(',').map(s => s.trim()).filter(Boolean)
      : null;

    const { error } = await supabase
      .from('job_board_profiles')
      .update({
        instrument_or_role: editInstrument.trim(),
        bio:                editBio.trim() || null,
        experience_years:   parseInt(editExpYears) || 0,
        city:               editCity.trim() || null,
        musical_styles:     parsedStyles,
        social_instagram:   editInstagram.trim() || null,
        social_tiktok:      editTiktok.trim() || null,
      })
      .eq('user_id', userId);
    if (!error) {
      setJobProfile(p => p ? {
        ...p,
        instrument_or_role: editInstrument.trim(),
        bio:                editBio.trim() || null,
        experience_years:   parseInt(editExpYears) || 0,
        city:               editCity.trim() || null,
        musical_styles:     parsedStyles,
        social_instagram:   editInstagram.trim() || null,
        social_tiktok:      editTiktok.trim() || null,
      } : p);
      setEditing(false);
    } else { Alert.alert('Error', 'No se pudo guardar'); }
    setSaving(false);
  };

  const handleVideoUpload = async () => {
    if (!userId || videoUploading) return;

    const perm = await ImagePicker.requestMediaLibraryPermissionsAsync();
    if (!perm.granted) {
      Alert.alert('Permiso requerido', 'Necesitamos acceso a tu galería para subir videos.');
      return;
    }

    const result = await ImagePicker.launchImageLibraryAsync({
      mediaTypes: 'videos' as any,
      videoMaxDuration: 60,   // máx 1 min → archivos más ligeros
      quality: 0.5,           // compresión en Android; iOS comprime al exportar
    });
    if (result.canceled || !result.assets[0]) return;

    setVideoUploading(true);
    setUploadProgress(0);
    try {
      const asset = result.assets[0];
      const rawExt = asset.uri.split('.').pop()?.toLowerCase() ?? 'mp4';
      const ext      = rawExt === 'mov' ? 'mov' : 'mp4';
      const mimeType = ext === 'mov' ? 'video/quicktime' : 'video/mp4';
      const filePath = `${userId}/profile.${ext}`;

      const formData = new FormData();
      formData.append('', { uri: asset.uri, type: mimeType, name: `profile.${ext}` } as any);

      const { data: sd } = await supabase.auth.getSession();
      const token = sd.session?.access_token;
      if (!token) throw new Error('Sin sesión activa. Vuelve a iniciar sesión.');

      // XMLHttpRequest en lugar de fetch — permite reportar progreso real de subida
      await new Promise<void>((resolve, reject) => {
        const xhr = new XMLHttpRequest();
        xhr.open('POST', `${supabaseUrl}/storage/v1/object/talent-videos/${filePath}`);
        xhr.setRequestHeader('Authorization', `Bearer ${token}`);
        xhr.setRequestHeader('apikey', supabaseAnonKey);
        xhr.setRequestHeader('x-upsert', 'true');

        xhr.upload.onprogress = (event) => {
          if (event.lengthComputable && mountedRef.current) {
            setUploadProgress(Math.round((event.loaded / event.total) * 100));
          }
        };

        xhr.onload = () => {
          if (xhr.status >= 200 && xhr.status < 300) {
            resolve();
          } else {
            reject(new Error(`Storage ${xhr.status}: ${xhr.responseText}`));
          }
        };

        xhr.onerror = () => reject(new Error('Error de red al subir el video. Verifica tu conexión.'));
        xhr.send(formData);
      });

      const { data: urlData } = supabase.storage
        .from('talent-videos')
        .getPublicUrl(filePath);
      const videoUrl = `${urlData.publicUrl}?t=${Date.now()}`;

      await supabase
        .from('job_board_profiles')
        .update({ video_url: videoUrl })
        .eq('user_id', userId);

      if (mountedRef.current) {
        setJobProfile(p => p ? { ...p, video_url: videoUrl } : p);
        Alert.alert('¡Listo!', 'Video subido correctamente.');
      }
    } catch (err: any) {
      if (mountedRef.current) {
        Alert.alert('Error al subir video', err?.message ?? 'Error desconocido');
      }
    } finally {
      if (mountedRef.current) {
        setVideoUploading(false);
        setUploadProgress(0);
      }
    }
  };

  const handleVideoDelete = () => {
    if (!userId || !jobProfile?.video_url) return;
    Alert.alert(
      'Eliminar video',
      '¿Seguro que deseas eliminar tu video profesional?',
      [
        { text: 'Cancelar', style: 'cancel' },
        {
          text: 'Eliminar',
          style: 'destructive',
          onPress: async () => {
            try {
              // Desmontar el player antes de eliminar el archivo
              await videoRef.current?.unloadAsync?.();
              // Eliminar ambas variantes de extensión (iOS=.mov, Android=.mp4)
              await supabase.storage
                .from('talent-videos')
                .remove([`${userId}/profile.mp4`, `${userId}/profile.mov`]);
              const { error } = await supabase
                .from('job_board_profiles')
                .update({ video_url: null })
                .eq('user_id', userId);
              if (error) throw error;
              if (mountedRef.current) {
                setJobProfile(p => p ? { ...p, video_url: null } : p);
              }
            } catch (err: any) {
              Alert.alert('Error', `No se pudo eliminar: ${err?.message ?? 'Error desconocido'}`);
            }
          },
        },
      ]
    );
  };

  const respondToInvitation = async (invId: string, status: 'accepted' | 'rejected') => {
    Alert.alert(
      status === 'accepted' ? 'Aceptar invitación' : 'Rechazar invitación',
      `¿Seguro que deseas ${status === 'accepted' ? 'aceptar' : 'rechazar'} esta invitación?`,
      [
        { text: 'Cancelar', style: 'cancel' },
        {
          text: status === 'accepted' ? 'Aceptar' : 'Rechazar',
          style: status === 'rejected' ? 'destructive' : 'default',
          onPress: async () => {
            const { error } = await supabase.from('job_invitations').update({ status }).eq('id', invId);
            if (!error) setInvitations(prev => prev.map(i => i.id === invId ? { ...i, status } : i));
            else Alert.alert('Error', 'No se pudo actualizar');
          },
        },
      ]
    );
  };

  if (loading) {
    return (
      <View style={s.container}>
        <Particles />
        <View style={s.center}><ActivityIndicator size="large" color={COLORS.green} /></View>
      </View>
    );
  }

  const pendingInvitations = invitations.filter(i => i.status === 'pending');
  const myGroups           = invitations.filter(i => i.status === 'accepted' && !i.event_id);
  const displayInvitations = invFilter === 'pending' ? pendingInvitations : invitations;
  // Solo mostrar reservas en curso o con fecha futura — descartar pasadas sin completar
  const displayGroupRes    = groupReservations.filter(
    r => r.status === 'in_progress' || isUpcoming(r.event_date, r.event_time)
  );

  return (
    <View style={s.container}>
      <Particles />
      <SafeAreaView style={{ flex: 1 }}>

        {/* HEADER */}
        <View style={s.header}>
          <View>
            <Text style={s.logoText}>Darice<Text style={s.logoGreen}>fy</Text></Text>
            <Text style={s.headerSub}>
              {fullName ? `Hola, ${fullName.split(' ')[0]} 🎵` : 'Bolsa de Trabajo'}
            </Text>
          </View>
          <Pressable style={s.bellBtn} onPress={() => navigation.navigate('Notifications')}>
            <Bell size={18} color={COLORS.text} />
            {unread > 0 && (
              <View style={s.notifDot}>
                <Text style={s.notifDotText}>{unread > 9 ? '9+' : unread}</Text>
              </View>
            )}
          </Pressable>
        </View>

        {/* QUICK STATS */}
        <View style={s.quickStatsRow}>
          <View style={s.quickStat}>
            <Text style={s.quickStatVal}>{pendingInvitations.length}</Text>
            <Text style={s.quickStatLabel}>Invitaciones</Text>
          </View>
          <View style={s.quickStatDiv} />
          <View style={s.quickStat}>
            <Text style={s.quickStatVal}>{myGroups.length}</Text>
            <Text style={s.quickStatLabel}>Grupos</Text>
          </View>
          <View style={s.quickStatDiv} />
          <View style={s.quickStat}>
            <Text style={s.quickStatVal}>{groupReservations.filter(r => r.status === 'in_progress' || isUpcoming(r.event_date, r.event_time)).length}</Text>
            <Text style={s.quickStatLabel}>Próximos eventos</Text>
          </View>
          <View style={s.quickStatDiv} />
          <View style={s.quickStat}>
            <View style={[s.availPill, jobProfile?.availability_status === 'available' ? s.availPillGreen : s.availPillRed]} />
            <Text style={[s.quickStatVal, { color: jobProfile?.availability_status === 'available' ? COLORS.green : '#EF5350', fontSize: 11 }]}>
              {jobProfile?.availability_status === 'available' ? 'Activo' : 'Ocupado'}
            </Text>
            <Text style={s.quickStatLabel}>Estado</Text>
          </View>
        </View>

        <ScrollView
          showsVerticalScrollIndicator={false}
          contentContainerStyle={s.scroll}
          refreshControl={<RefreshControl refreshing={refreshing} onRefresh={() => load(true)} tintColor={COLORS.green} />}
        >

          {/* ── PROFILE HERO ── */}
          <View style={s.heroCard}>

            {/* Imagen / Placeholder */}
            <View style={s.heroImgBg}>
              {avatar ? (
                <Image source={{ uri: avatar }} style={StyleSheet.absoluteFillObject} resizeMode="cover" />
              ) : (
                <View style={[StyleSheet.absoluteFillObject, s.heroImgPlaceholder]}>
                  <Text style={s.heroImgInitial}>{fullName?.charAt(0)?.toUpperCase() ?? '?'}</Text>
                </View>
              )}

              {/* Gradiente: oscuro arriba (stats) + oscuro abajo (info) */}
              <LinearGradient
                colors={['rgba(0,0,0,0.68)', 'transparent', 'rgba(0,0,0,0.88)']}
                locations={[0, 0.42, 1]}
                style={StyleSheet.absoluteFillObject}
                start={{ x: 0, y: 0 }} end={{ x: 0, y: 1 }}
                pointerEvents="none"
              />

              {/* Botones flotantes arriba derecha */}
              <View style={{ position: 'absolute', top: 10, right: 12, flexDirection: 'row', gap: 8 }}>
                <Pressable
                  style={[s.heroFloatBtn, editing && { backgroundColor: 'rgba(0,0,0,0.55)', borderColor: 'rgba(255,255,255,0.3)' }]}
                  onPress={() => setEditing(v => !v)}
                >
                  {editing ? <X size={13} color="#fff" /> : <Edit3 size={13} color={COLORS.green} />}
                </Pressable>
                <Pressable style={s.heroCameraBtn} onPress={handlePhoto} disabled={photoLoading}>
                  {photoLoading ? <ActivityIndicator size="small" color="#fff" /> : <Camera size={13} color="#fff" />}
                </Pressable>
              </View>

              {/* Info abajo */}
              <View style={s.heroImgInfo}>
                {/* Fila 1: nombre + badge verificación */}
                <View style={{ flexDirection: 'row', alignItems: 'center', gap: 6, marginBottom: 6 }}>
                  <Text style={s.heroNameLarge} numberOfLines={1}>{fullName || 'Mi perfil'}</Text>
                  {verified ? (
                    <VerifiedBadge size={20} />
                  ) : (
                    <View style={s.heroPendingBadge}>
                      <Shield size={10} color={COLORS.orange} />
                      <Text style={s.heroPendingText}>Pendiente</Text>
                    </View>
                  )}
                </View>

                {/* Fila 2: chips compactos */}
                <View style={{ flexDirection: 'row', alignItems: 'center', gap: 5, flexWrap: 'wrap' }}>
                  {jobProfile?.instrument_or_role && (
                    <View style={s.heroChip}>
                      <Text style={s.heroChipText}>{jobProfile.instrument_or_role}</Text>
                    </View>
                  )}
                  {(jobProfile?.rating ?? 0) > 0 && (
                    <View style={s.heroChip}>
                      <Star size={9} color={COLORS.gold} fill={COLORS.gold} />
                      <Text style={[s.heroChipText, { color: COLORS.gold }]}>{jobProfile!.rating.toFixed(1)}</Text>
                    </View>
                  )}
                  {(jobProfile?.total_jobs ?? 0) > 0 && (
                    <View style={s.heroChip}>
                      <CheckCircle size={9} color={COLORS.green} />
                      <Text style={[s.heroChipText, { color: COLORS.green }]}>{jobProfile!.total_jobs} trabajos</Text>
                    </View>
                  )}
                  <View style={s.heroChip}>
                    <Clock size={9} color="rgba(255,255,255,0.6)" />
                    <Text style={s.heroChipText}>{jobProfile?.experience_years ?? 0} años</Text>
                  </View>
                  <View style={[s.heroChip, { borderColor: jobProfile?.availability_status === 'available' ? 'rgba(0,230,118,0.5)' : 'rgba(239,83,80,0.5)' }]}>
                    <View style={{ width: 6, height: 6, borderRadius: 3, backgroundColor: jobProfile?.availability_status === 'available' ? COLORS.green : '#EF5350' }} />
                    <Text style={[s.heroChipText, { color: jobProfile?.availability_status === 'available' ? COLORS.green : '#EF5350' }]}>
                      {jobProfile?.availability_status === 'available' ? 'Activo' : 'Ocupado'}
                    </Text>
                  </View>
                </View>
              </View>
            </View>

            {/* ── Bio ── */}
            {!editing && jobProfile?.bio && (
              <Text style={s.bioText}>{jobProfile.bio}</Text>
            )}

            {/* ── Edit form ── */}
            {editing && (
              <View style={s.editForm}>
                <View style={s.editRow}>
                  <Text style={s.editLabel}>Instrumento / Rol *</Text>
                  <TextInput
                    style={s.editInput}
                    value={editInstrument}
                    onChangeText={setEditInstrument}
                    placeholder="Guitarrista, Vocalista, DJ..."
                    placeholderTextColor={COLORS.muted}
                  />
                </View>
                <View style={s.editRow}>
                  <Text style={s.editLabel}>Años de experiencia</Text>
                  <TextInput
                    style={s.editInput}
                    value={editExpYears}
                    onChangeText={setEditExpYears}
                    keyboardType="numeric"
                    placeholder="0"
                    placeholderTextColor={COLORS.muted}
                  />
                </View>
                <View style={s.editRow}>
                  <Text style={s.editLabel}>Bio</Text>
                  <TextInput
                    style={[s.editInput, { height: 72, textAlignVertical: 'top', paddingTop: 10 }]}
                    value={editBio}
                    onChangeText={setEditBio}
                    multiline
                    placeholder="Cuéntanos sobre ti..."
                    placeholderTextColor={COLORS.muted}
                  />
                </View>
                <View style={s.editRow}>
                  <Text style={s.editLabel}>Ciudad</Text>
                  <TextInput
                    style={s.editInput}
                    value={editCity}
                    onChangeText={setEditCity}
                    placeholder="Ciudad de México, Monterrey..."
                    placeholderTextColor={COLORS.muted}
                  />
                </View>
                <View style={s.editRow}>
                  <Text style={s.editLabel}>Estilos musicales (separados por coma)</Text>
                  <TextInput
                    style={s.editInput}
                    value={editStyles}
                    onChangeText={setEditStyles}
                    placeholder="Rock, Jazz, Pop, Cumbia..."
                    placeholderTextColor={COLORS.muted}
                  />
                </View>
                <View style={s.editRow}>
                  <Text style={s.editLabel}>Instagram (usuario)</Text>
                  <TextInput
                    style={s.editInput}
                    value={editInstagram}
                    onChangeText={setEditInstagram}
                    placeholder="@tu_usuario"
                    placeholderTextColor={COLORS.muted}
                    autoCapitalize="none"
                  />
                </View>
                <View style={s.editRow}>
                  <Text style={s.editLabel}>TikTok (usuario)</Text>
                  <TextInput
                    style={s.editInput}
                    value={editTiktok}
                    onChangeText={setEditTiktok}
                    placeholder="@tu_usuario"
                    placeholderTextColor={COLORS.muted}
                    autoCapitalize="none"
                  />
                </View>
                <Pressable style={[s.saveBtn, saving && { opacity: 0.6 }]} onPress={saveProfile} disabled={saving}>
                  <Save size={15} color={COLORS.bg} />
                  <Text style={s.saveBtnText}>{saving ? 'Guardando...' : 'Guardar cambios'}</Text>
                </Pressable>
              </View>
            )}

            {/* ── Video profesional (view mode) ── */}
            {!editing && (
              <View style={s.videoSection}>
                <Text style={s.videoSectionLabel}>🎬 Video profesional</Text>
                {jobProfile?.video_url ? (
                  <View>
                    <VideoPlayer
                      uri={jobProfile.video_url}
                      style={s.videoPlayer}
                      nativeControls
                      contentFit="contain"
                    />
                    <View style={s.videoBtnsRow}>
                      <Pressable
                        style={[s.videoBtnReplace, videoUploading && { opacity: 0.6 }]}
                        onPress={handleVideoUpload}
                        disabled={videoUploading}
                      >
                        {videoUploading
                          ? <Text style={s.videoBtnReplaceText}>{uploadProgress > 0 ? `Subiendo ${uploadProgress}%` : 'Preparando...'}</Text>
                          : <Text style={s.videoBtnReplaceText}>Reemplazar video</Text>}
                      </Pressable>
                      <Pressable style={s.videoBtnDelete} onPress={handleVideoDelete}>
                        <X size={14} color="#EF5350" />
                      </Pressable>
                    </View>
                  </View>
                ) : (
                  <Pressable
                    style={[s.videoUploadBtn, videoUploading && { opacity: 0.6 }]}
                    onPress={handleVideoUpload}
                    disabled={videoUploading}
                  >
                    {videoUploading ? (
                      <Text style={s.videoUploadText}>
                        {uploadProgress > 0 ? `Subiendo ${uploadProgress}%...` : 'Preparando video...'}
                      </Text>
                    ) : (
                      <Text style={s.videoUploadText}>＋ Subir video (máx. 1 min)</Text>
                    )}
                  </Pressable>
                )}
              </View>
            )}
          </View>

          {/* ── VISIBILITY TOGGLES ── */}
          <View style={s.togglesRow}>
            <Pressable
              style={[s.togglePill, jobProfile?.is_visible && s.togglePillActive]}
              onPress={toggleVisibility}
            >
              {jobProfile?.is_visible
                ? <Eye size={14} color={COLORS.green} />
                : <EyeOff size={14} color={COLORS.muted} />}
              <Text style={[s.togglePillText, jobProfile?.is_visible && s.togglePillTextActive]}>
                {jobProfile?.is_visible ? 'Visible' : 'Oculto'}
              </Text>
            </Pressable>
            <Pressable
              style={[s.togglePill, jobProfile?.availability_status === 'available' && s.togglePillActive]}
              onPress={toggleAvailability}
            >
              <View style={[s.availDot, jobProfile?.availability_status === 'available' ? s.availDotGreen : s.availDotRed]} />
              <Text style={[s.togglePillText, jobProfile?.availability_status === 'available' && s.togglePillTextActive]}>
                {jobProfile?.availability_status === 'available' ? 'Disponible' : 'Ocupado'}
              </Text>
            </Pressable>
          </View>

          {/* ── COTIZACIONES RECIENTES ── */}
          {pendingQuotes.length > 0 && (
            <>
              <SectionHeader
                icon={<FileText size={15} color={COLORS.green} />}
                title="Cotizaciones recientes"
                badge={pendingQuotes.filter(q => q.status === 'pending').length || undefined}
              />
              {pendingQuotes.map(q => {
                const dateStr = q.event_date
                  ? new Date(q.event_date + 'T12:00:00').toLocaleDateString('es-MX', { day: 'numeric', month: 'short' })
                  : '—';
                const isPending = q.status === 'pending';
                return (
                  <Pressable
                    key={q.id}
                    style={s.quoteCard}
                    onPress={() => navigation.navigate('GroupQuoteDetail', { quote: q })}
                  >
                    <Text style={s.quoteCardEmoji}>{EVENT_EMOJI[q.event_type] ?? '🎵'}</Text>
                    <View style={{ flex: 1 }}>
                      <Text style={s.quoteCardClient} numberOfLines={1}>
                        {q.client?.full_name ?? 'Cliente'}
                      </Text>
                      <Text style={s.quoteCardDate}>{dateStr} · {q.duration_hours}h</Text>
                    </View>
                    <View style={[s.quoteCardChip, { backgroundColor: isPending ? 'rgba(255,152,0,0.12)' : 'rgba(66,133,244,0.12)', borderColor: isPending ? 'rgba(255,152,0,0.4)' : 'rgba(66,133,244,0.4)' }]}>
                      <Text style={[s.quoteCardChipText, { color: isPending ? COLORS.orange : COLORS.blue }]}>
                        {isPending ? 'Pendiente' : 'Enviada'}
                      </Text>
                    </View>
                    <ChevronRight size={14} color={COLORS.muted} style={{ marginLeft: 4 }} />
                  </Pressable>
                );
              })}
            </>
          )}

          {/* ── MI GRUPO ── */}
          {myGroups.length > 0 && (
            <>
              <SectionHeader icon={<Users size={15} color={COLORS.green} />} title="Mi Grupo" />
              {myGroups.map(inv => inv.group && (
                <View key={inv.id} style={s.groupCard}>
                  {/* Top row: photo + info */}
                  <View style={s.groupCardTop}>
                    {inv.group.profile_image
                      ? <Image source={{ uri: inv.group.profile_image }} style={s.groupCardPhoto} />
                      : (
                        <View style={s.groupCardPhotoPlaceholder}>
                          <Text style={s.groupCardInitial}>{inv.group.name.charAt(0).toUpperCase()}</Text>
                        </View>
                      )
                    }
                    <View style={{ flex: 1 }}>
                      <Text style={s.groupCardName}>{inv.group.name}</Text>
                      {inv.group.genre && <Text style={s.groupCardGenre}>{inv.group.genre}</Text>}
                      <View style={s.memberBadge}>
                        <CheckCircle size={11} color={COLORS.green} />
                        <Text style={s.memberBadgeText}>Integrante activo</Text>
                      </View>
                    </View>
                  </View>
                  {/* Stats */}
                  <View style={s.groupCardStats}>
                    <GroupStat icon={<Star size={12} color={COLORS.gold} fill={COLORS.gold} />}
                      value={inv.group.rating?.toFixed(1) ?? '—'} label="Rating" />
                    <View style={s.groupStatDivider} />
                    <GroupStat icon={<Text style={{ fontSize: 12 }}>🎵</Text>}
                      value={String(inv.group.total_reviews ?? 0)} label="Reseñas" />
                    <View style={s.groupStatDivider} />
                    <GroupStat icon={<Users size={12} color={COLORS.green} />}
                      value={String(inv.group.members_count ?? 1)} label="Integrantes" />
                  </View>
                </View>
              ))}
            </>
          )}

          {/* ── RESERVAS DEL GRUPO ── */}
          {displayGroupRes.length > 0 && (
            <>
              <SectionHeader
                icon={<Music2 size={15} color={COLORS.green} />}
                title="Reservas del grupo"
                badge={displayGroupRes.filter(r => r.status === 'pending' || r.status === 'pending_group_confirmation').length || undefined}
              />
              {displayGroupRes.map(res => (
                <Pressable
                  key={res.id}
                  style={s.resCard}
                  onPress={() => {
                    if (res.status === 'in_progress' || res.status === 'confirmed') {
                      navigation.navigate('EventTimer', { reservation: res, readOnly: true });
                    } else {
                      navigation.navigate('GroupReservationDetail', { reservation: res, readOnly: true });
                    }
                  }}
                >
                  {/* Accent bar por estado */}
                  <View style={[s.resAccent, {
                    backgroundColor:
                      res.status === 'in_progress' ? COLORS.blue :
                      res.status === 'confirmed'   ? COLORS.green :
                      COLORS.gold,
                  }]} />
                  <View style={s.resContent}>
                    <View style={s.resTopRow}>
                      <Text style={s.resPkgName}>{res.quote?.event_type ?? 'Reserva'}</Text>
                      <View style={[s.resStatusChip, {
                        backgroundColor:
                          res.status === 'in_progress' ? 'rgba(66,133,244,0.12)' :
                          res.status === 'confirmed'   ? COLORS.greenMuted :
                          'rgba(255,180,0,0.12)',
                        borderColor:
                          res.status === 'in_progress' ? COLORS.blue + '60' :
                          res.status === 'confirmed'   ? COLORS.green :
                          COLORS.gold + '60',
                      }]}>
                        <Text style={[s.resStatusText, {
                          color:
                            res.status === 'in_progress' ? COLORS.blue :
                            res.status === 'confirmed'   ? COLORS.green :
                            COLORS.gold,
                        }]}>
                          {res.status === 'in_progress' ? '⏱ En curso' :
                           res.status === 'confirmed'   ? '✅ Confirmada' :
                           '⏳ Por confirmar'}
                        </Text>
                      </View>
                    </View>
                    <View style={s.resInfoRow}>
                      <Calendar size={12} color={COLORS.muted2} />
                      <Text style={s.resInfoText}>{res.event_date}
                        {res.event_time ? `  •  ${res.event_time}` : ''}
                      </Text>
                    </View>
                    <View style={s.resInfoRow}>
                      <MapPin size={12} color={COLORS.muted2} />
                      <Text style={s.resInfoText} numberOfLines={1}>{res.address}</Text>
                    </View>
                    {(res.hours_count ?? res.quote?.duration_hours) ? (
                      <View style={s.resInfoRow}>
                        <Clock size={12} color={COLORS.muted2} />
                        <Text style={s.resInfoText}>{res.hours_count ?? res.quote?.duration_hours}h de servicio</Text>
                      </View>
                    ) : null}
                  </View>
                  <ChevronRight size={16} color={COLORS.muted} />
                </Pressable>
              ))}
            </>
          )}

          {/* ── INVITACIONES ── */}
          <View style={s.invHeader}>
            <SectionHeader
              icon={<Briefcase size={15} color={COLORS.green} />}
              title="Invitaciones"
              badge={pendingInvitations.length > 0 ? pendingInvitations.length : undefined}
            />
            {/* Filter tabs */}
            <View style={s.filterTabs}>
              <Pressable
                style={[s.filterTab, invFilter === 'pending' && s.filterTabActive]}
                onPress={() => setInvFilter('pending')}
              >
                <Text style={[s.filterTabText, invFilter === 'pending' && s.filterTabTextActive]}>
                  Pendientes
                </Text>
              </Pressable>
              <Pressable
                style={[s.filterTab, invFilter === 'all' && s.filterTabActive]}
                onPress={() => setInvFilter('all')}
              >
                <Text style={[s.filterTabText, invFilter === 'all' && s.filterTabTextActive]}>
                  Todas ({invitations.length})
                </Text>
              </Pressable>
            </View>
          </View>

          {displayInvitations.length === 0 ? (
            <View style={s.emptyBox}>
              <Text style={{ fontSize: 40, marginBottom: 12 }}>📬</Text>
              <Text style={s.emptyTitle}>
                {invFilter === 'pending' ? 'Sin invitaciones pendientes' : 'Sin invitaciones'}
              </Text>
              <Text style={s.emptyHint}>
                {invFilter === 'pending'
                  ? 'Activa tu visibilidad para que los grupos puedan encontrarte'
                  : 'Aún no has recibido ninguna invitación'}
              </Text>
            </View>
          ) : (
            displayInvitations.map(inv => (
              <InvitationCard
                key={inv.id}
                inv={inv}
                onAccept={() => respondToInvitation(inv.id, 'accepted')}
                onReject={() => respondToInvitation(inv.id, 'rejected')}
              />
            ))
          )}

        </ScrollView>
      </SafeAreaView>
    </View>
  );
}

// ─── Sub-components ───────────────────────────────────────────────────────────

function GroupStat({ icon, value, label }: any) {
  return (
    <View style={s.groupStat}>
      {icon}
      <Text style={s.groupStatValue}>{value}</Text>
      <Text style={s.groupStatLabel}>{label}</Text>
    </View>
  );
}

function SectionHeader({ icon, title, badge }: any) {
  return (
    <View style={s.sectionHeader}>
      {icon}
      <Text style={s.sectionTitle}>{title}</Text>
      {badge != null && (
        <View style={s.sectionBadge}>
          <Text style={s.sectionBadgeText}>{badge}</Text>
        </View>
      )}
    </View>
  );
}

function InvitationCard({ inv, onAccept, onReject }: { inv: Invitation; onAccept: () => void; onReject: () => void }) {
  const isMembership = !inv.event_id;
  const isPending    = inv.status === 'pending';
  const isAccepted   = inv.status === 'accepted';
  const isRejected   = inv.status === 'rejected';

  const statusColor  = isAccepted ? COLORS.green : isRejected ? '#EF5350' : COLORS.muted2;
  const statusLabel  = isAccepted ? '✅ Aceptada' : isRejected ? '❌ Rechazada' : '⏳ Pendiente';

  return (
    <View style={[ic.card, isPending && ic.cardPending]}>
      {/* Group photo + name */}
      <View style={ic.topRow}>
        {inv.group?.profile_image
          ? <Image source={{ uri: inv.group.profile_image }} style={ic.groupPhoto} />
          : (
            <View style={ic.groupPhotoPlaceholder}>
              <Text style={ic.groupPhotoInitial}>{inv.group?.name?.charAt(0)?.toUpperCase() ?? '?'}</Text>
            </View>
          )
        }
        <View style={{ flex: 1 }}>
          <View style={{ flexDirection: 'row', alignItems: 'center', gap: 6, flexWrap: 'wrap' }}>
            <Text style={ic.groupName}>{inv.group?.name ?? 'Grupo desconocido'}</Text>
            {inv.group?.is_verified && (
              <VerifiedBadge size={16} tier={inv.group?.is_plus_active ? 'plus' : 'free'} />
            )}
          </View>
          {inv.group?.genre && <Text style={ic.groupGenre}>{inv.group.genre}</Text>}
          {/* Confianza: tiempo en plataforma + eventos completados */}
          {(inv.group?.created_at || (inv.group?.completed_events ?? 0) > 0) && (
            <View style={{ flexDirection: 'row', gap: 8, flexWrap: 'wrap', marginTop: 4 }}>
              {inv.group?.created_at && (() => {
                const months = Math.floor(
                  (Date.now() - new Date(inv.group!.created_at!).getTime()) / (1000 * 60 * 60 * 24 * 30)
                );
                return months > 0 ? (
                  <Text style={ic.trustText}>
                    {months >= 12
                      ? `${Math.floor(months / 12)}a en plataforma`
                      : `${months}m en plataforma`}
                  </Text>
                ) : null;
              })()}
              {(inv.group?.completed_events ?? 0) > 0 && (
                <Text style={ic.trustText}>
                  {inv.group!.completed_events} evento{inv.group!.completed_events !== 1 ? 's' : ''}
                </Text>
              )}
            </View>
          )}
        </View>
        <View style={[ic.statusChip, { borderColor: statusColor }]}>
          <Text style={[ic.statusText, { color: statusColor }]}>{statusLabel}</Text>
        </View>
      </View>

      {/* Type + info */}
      <View style={ic.infoRow}>
        <View style={[ic.typeBadge, isMembership ? ic.typeBadgeMember : ic.typeBadgeTocada]}>
          <Text style={[ic.typeText, isMembership ? ic.typeTextMember : ic.typeTextTocada]}>
            {isMembership ? '🎸 Unirse al grupo' : '🎵 Para una tocada'}
          </Text>
        </View>
        <Text style={ic.dateText}>
          {new Date(inv.created_at).toLocaleDateString('es-MX', { day: '2-digit', month: 'short' })}
        </Text>
      </View>

      {/* Event info (tocada only) */}
      {inv.event && (() => {
        const res = inv.event.reservations?.[0];
        const fmtDate = new Date(inv.event.event_date + 'T12:00:00')
          .toLocaleDateString('es-MX', { weekday: 'short', day: 'numeric', month: 'short', year: 'numeric' });
        return (
          <View style={ic.eventBox}>
            <View style={ic.eventRow}>
              <Calendar size={12} color={COLORS.green} />
              <Text style={ic.eventText}>{fmtDate}</Text>
              {res?.event_time && (
                <>
                  <Clock size={12} color={COLORS.muted} />
                  <Text style={ic.eventText}>{res.event_time.slice(0, 5)}</Text>
                </>
              )}
            </View>
            <View style={ic.eventRow}>
              <MapPin size={12} color={COLORS.muted} />
              <Text style={[ic.eventText, { flex: 1 }]} numberOfLines={2}>{inv.event.address}</Text>
            </View>
            {(res?.hours_count ?? res?.quote?.duration_hours) ? (
              <View style={ic.eventRow}>
                <Music2 size={12} color={COLORS.muted} />
                <Text style={ic.eventText}>{res?.quote?.event_type ?? 'Cotización'} · {res?.hours_count ?? res?.quote?.duration_hours}h</Text>
              </View>
            ) : null}
          </View>
        );
      })()}

      {/* Payment */}
      {inv.proposed_payment_amount != null && (
        <View style={ic.payBlock}>
          <View style={ic.payRow}>
            <DollarSign size={13} color={COLORS.green} />
            <Text style={ic.payText}>Lo que te paga el grupo: ${inv.proposed_payment_amount.toLocaleString()}</Text>
          </View>
          <Text style={ic.payNote}>Pago directo del grupo. Acordado fuera de la plataforma.</Text>
        </View>
      )}

      {/* Message */}
      {inv.message && (
        <Text style={ic.messageText}>"{inv.message}"</Text>
      )}

      {/* Actions (only for pending) */}
      {isPending && (
        <View style={ic.actions}>
          <Pressable style={ic.rejectBtn} onPress={onReject}>
            <XCircle size={16} color="#EF5350" />
            <Text style={ic.rejectText}>Rechazar</Text>
          </Pressable>
          <Pressable style={ic.acceptBtn} onPress={onAccept}>
            <CheckCircle size={16} color={COLORS.bg} />
            <Text style={ic.acceptText}>Aceptar</Text>
          </Pressable>
        </View>
      )}
    </View>
  );
}

// ─── Styles ───────────────────────────────────────────────────────────────────

const s = StyleSheet.create({
  container: { flex: 1, backgroundColor: COLORS.bg },
  center:    { flex: 1, alignItems: 'center', justifyContent: 'center' },

  header: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between',
    paddingHorizontal: SPACING.xl, paddingTop: 14, paddingBottom: 12,
  },
  logoText:  { fontFamily: FONTS.title, fontSize: 22, color: COLORS.text },
  logoGreen: { color: COLORS.green },
  headerSub: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2, marginTop: 2 },
  headerLeft:  { flexDirection: 'row', alignItems: 'center', gap: 8 },
  headerTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 16, color: COLORS.text },

  // Quick stats bar
  quickStatsRow: {
    flexDirection: 'row', alignItems: 'center',
    marginHorizontal: SPACING.xl, marginBottom: 16,
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border,
    paddingVertical: 12,
  },
  quickStat:      { flex: 1, alignItems: 'center', gap: 2 },
  quickStatDiv:   { width: 1, height: 32, backgroundColor: COLORS.border },
  quickStatVal:   { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.text },
  quickStatLabel: { fontFamily: FONTS.body, fontSize: 10, color: COLORS.muted, textTransform: 'uppercase' as const, letterSpacing: 0.3 },
  availPill:      { width: 8, height: 8, borderRadius: 4, marginBottom: 2 },
  availPillGreen: { backgroundColor: COLORS.green },
  availPillRed:   { backgroundColor: '#EF5350' },
  bellBtn: {
    width: 40, height: 40, borderRadius: 12,
    backgroundColor: COLORS.card, borderWidth: 1, borderColor: COLORS.border,
    alignItems: 'center', justifyContent: 'center',
  },
  notifDot: {
    position: 'absolute', top: -4, right: -4,
    minWidth: 16, height: 16, borderRadius: 8,
    backgroundColor: COLORS.green, alignItems: 'center', justifyContent: 'center', paddingHorizontal: 3,
  },
  notifDotText: { fontFamily: FONTS.bodySemiBold, fontSize: 9, color: COLORS.bg },

  scroll: { padding: SPACING.xl, paddingBottom: 40, gap: 0 },

  // ── Hero card ──────────────────────────────────────────────────────────────
  heroCard: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.xl,
    borderWidth: 1, borderColor: COLORS.border,
    marginBottom: 12, overflow: 'hidden',
  },
  // Imagen hero (full-width)
  heroImgBg: {
    width: '100%', height: 190,
  },
  heroImgPlaceholder: {
    backgroundColor: COLORS.card2,
    alignItems: 'center', justifyContent: 'center',
    borderTopLeftRadius: RADIUS.xl, borderTopRightRadius: RADIUS.xl,
  },
  heroImgInitial: {
    fontFamily: FONTS.title, fontSize: 80, color: COLORS.green, opacity: 0.15,
  },
  heroCameraBtn: {
    width: 30, height: 30, borderRadius: 15,
    backgroundColor: 'rgba(0,0,0,0.55)',
    alignItems: 'center', justifyContent: 'center',
    borderWidth: 1, borderColor: 'rgba(255,255,255,0.25)',
  },
  heroFloatBtn: {
    width: 30, height: 30, borderRadius: 15,
    backgroundColor: 'rgba(0,230,118,0.25)',
    alignItems: 'center', justifyContent: 'center',
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.5)',
  },
  heroImgInfo: { position: 'absolute', bottom: 12, left: SPACING.lg, right: SPACING.lg },
  heroNameLarge: { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: '#fff', flex: 1, letterSpacing: 0.5 },
  heroVerifiedBadge: {
    flexDirection: 'row', alignItems: 'center', gap: 4,
    backgroundColor: COLORS.blue, borderRadius: RADIUS.full,
    paddingHorizontal: 8, paddingVertical: 3,
  },
  heroVerifiedText: { fontFamily: FONTS.bodySemiBold, fontSize: 10, color: '#fff' },
  heroPendingBadge: {
    flexDirection: 'row', alignItems: 'center', gap: 4,
    backgroundColor: 'rgba(255,152,0,0.2)', borderRadius: RADIUS.full,
    borderWidth: 1, borderColor: 'rgba(255,152,0,0.6)',
    paddingHorizontal: 8, paddingVertical: 3,
  },
  heroPendingText: { fontFamily: FONTS.bodySemiBold, fontSize: 10, color: COLORS.orange },
  heroChip: {
    flexDirection: 'row', alignItems: 'center', gap: 4,
    backgroundColor: 'rgba(255,255,255,0.12)', borderRadius: RADIUS.full,
    borderWidth: 1, borderColor: 'rgba(255,255,255,0.2)',
    paddingHorizontal: 7, paddingVertical: 3,
  },
  heroChipText: { fontFamily: FONTS.bodyMedium, fontSize: 10, color: 'rgba(255,255,255,0.85)' },

  // Stats overlay (sobre la foto)
  statsOverlay: {
    position: 'absolute', top: 0, left: 0, right: 0,
    flexDirection: 'row', alignItems: 'center',
    backgroundColor: 'rgba(0,0,0,0.55)',
    paddingVertical: 11,
    borderBottomWidth: 1, borderBottomColor: 'rgba(255,255,255,0.08)',
  },
  statOverlayItem:    { flex: 1, alignItems: 'center', gap: 2 },
  statOverlayDivider: { width: 1, height: 30, backgroundColor: 'rgba(255,255,255,0.15)' },
  statOverlayVal:     { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: '#fff' },
  statOverlayLabel:   { fontFamily: FONTS.body, fontSize: 9, color: 'rgba(255,255,255,0.55)', textTransform: 'uppercase' as const, letterSpacing: 0.3 },

  availDot:      { width: 8, height: 8, borderRadius: 4 },
  availDotGreen: { backgroundColor: COLORS.green },
  availDotRed:   { backgroundColor: '#EF5350' },

  bioText: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2, lineHeight: 20, paddingHorizontal: SPACING.lg, paddingVertical: 12 },

  // Edit form
  editForm: { marginTop: 0, gap: 2, borderTopWidth: 1, borderTopColor: COLORS.border, paddingTop: 14, paddingHorizontal: SPACING.lg, paddingBottom: 14 },
  editRow:  { marginBottom: 10 },
  editLabel: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.muted2, marginBottom: 6 },
  editInput: {
    backgroundColor: COLORS.bg, borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: COLORS.border,
    padding: 12, fontFamily: FONTS.body, fontSize: 14, color: COLORS.text,
  },
  saveBtn: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 8,
    backgroundColor: COLORS.green, borderRadius: RADIUS.md, paddingVertical: 13, marginTop: 6,
  },
  saveBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.bg },

  // Video section
  videoSection: {
    marginHorizontal: SPACING.lg, marginBottom: 16, marginTop: 4,
    backgroundColor: COLORS.card2, borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: COLORS.border, overflow: 'hidden',
    padding: 14,
  },
  videoSectionLabel: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted2, marginBottom: 10 },
  videoPlayer: { width: '100%', aspectRatio: 16 / 9, borderRadius: RADIUS.sm, backgroundColor: '#000' },
  videoBtnsRow: { flexDirection: 'row', gap: 8, marginTop: 10 },
  videoBtnReplace: {
    flex: 1, alignItems: 'center', paddingVertical: 10, borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: COLORS.green,
  },
  videoBtnReplaceText: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.green },
  videoBtnDelete: {
    width: 44, alignItems: 'center', justifyContent: 'center', paddingVertical: 10,
    borderRadius: RADIUS.md, borderWidth: 1, borderColor: '#EF535060',
    backgroundColor: 'rgba(239,83,80,0.08)',
  },
  videoUploadBtn: {
    alignItems: 'center', paddingVertical: 18, borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: COLORS.border, borderStyle: 'dashed',
    flexDirection: 'row', justifyContent: 'center', gap: 8,
  },
  videoUploadText: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted2 },

  // Toggles
  togglesRow: { flexDirection: 'row', gap: 10, marginBottom: 24 },
  togglePill: {
    flex: 1, flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 7,
    backgroundColor: COLORS.card, borderRadius: RADIUS.full,
    borderWidth: 1, borderColor: COLORS.border, paddingVertical: 10,
  },
  togglePillActive:    { borderColor: COLORS.green, backgroundColor: COLORS.greenMuted },
  togglePillText:      { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted },
  togglePillTextActive: { color: COLORS.green },

  // Section header
  sectionHeader: { flexDirection: 'row', alignItems: 'center', gap: 8, marginBottom: 12 },
  sectionTitle:  { fontFamily: FONTS.title, fontSize: 17, color: COLORS.text, flex: 1 },
  sectionBadge:  { backgroundColor: COLORS.green, borderRadius: RADIUS.full, paddingHorizontal: 8, paddingVertical: 2 },
  sectionBadgeText: { fontFamily: FONTS.bodySemiBold, fontSize: 11, color: COLORS.bg },

  // My group card
  groupCard: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.xl,
    borderWidth: 1, borderColor: COLORS.border,
    padding: SPACING.lg, marginBottom: 20,
  },
  groupCardTop: { flexDirection: 'row', alignItems: 'center', gap: 14, marginBottom: 14 },
  groupCardPhoto: { width: 60, height: 60, borderRadius: 16 },
  groupCardPhotoPlaceholder: {
    width: 60, height: 60, borderRadius: 16,
    backgroundColor: COLORS.greenMuted, borderWidth: 1.5, borderColor: COLORS.green,
    alignItems: 'center', justifyContent: 'center',
  },
  groupCardInitial: { fontFamily: FONTS.title, fontSize: 24, color: COLORS.green },
  groupCardName:    { fontFamily: FONTS.title, fontSize: 16, color: COLORS.text, marginBottom: 2 },
  groupCardGenre:   { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, marginBottom: 6 },
  memberBadge: {
    flexDirection: 'row', alignItems: 'center', gap: 4, alignSelf: 'flex-start',
    backgroundColor: COLORS.greenMuted, borderRadius: RADIUS.full,
    borderWidth: 1, borderColor: COLORS.green,
    paddingHorizontal: 8, paddingVertical: 3,
  },
  memberBadgeText: { fontFamily: FONTS.bodyMedium, fontSize: 11, color: COLORS.green },
  groupCardStats: {
    flexDirection: 'row', alignItems: 'center',
    backgroundColor: COLORS.bg, borderRadius: RADIUS.lg, borderWidth: 1, borderColor: COLORS.border,
    paddingVertical: 12,
  },
  groupStat:      { flex: 1, alignItems: 'center', gap: 3 },
  groupStatValue: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.text },
  groupStatLabel: { fontFamily: FONTS.body, fontSize: 10, color: COLORS.muted },
  groupStatDivider: { width: 1, height: 28, backgroundColor: COLORS.border },

  // Invitations header
  invHeader: { marginBottom: 0 },
  filterTabs: { flexDirection: 'row', gap: 8, marginBottom: 14 },
  filterTab: {
    paddingHorizontal: 14, paddingVertical: 7, borderRadius: RADIUS.full,
    backgroundColor: COLORS.card, borderWidth: 1, borderColor: COLORS.border,
  },
  filterTabActive:    { backgroundColor: COLORS.greenMuted, borderColor: COLORS.green },
  filterTabText:      { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.muted },
  filterTabTextActive: { color: COLORS.green },

  // Empty state
  emptyBox:  { alignItems: 'center', paddingVertical: 40 },
  emptyTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.muted2, marginBottom: 6 },
  emptyHint:  { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted, textAlign: 'center' },

  // Group reservation cards
  resCard: {
    flexDirection: 'row', alignItems: 'center',
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border,
    marginBottom: 10, overflow: 'hidden',
  },
  resAccent: { width: 4, alignSelf: 'stretch' },
  resContent: { flex: 1, padding: SPACING.md, gap: 5 },
  resTopRow: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', marginBottom: 4 },
  resPkgName: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.text, flex: 1, marginRight: 8 },
  resStatusChip: {
    paddingHorizontal: 8, paddingVertical: 3, borderRadius: RADIUS.full, borderWidth: 1,
  },
  resStatusText: { fontFamily: FONTS.bodyMedium, fontSize: 11 },
  resInfoRow: { flexDirection: 'row', alignItems: 'center', gap: 6 },
  resInfoText: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, flex: 1 },

  // Quote cards
  quoteCard: {
    flexDirection: 'row', alignItems: 'center',
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border,
    padding: SPACING.md, marginBottom: 8, gap: 10,
  },
  quoteCardEmoji: { fontSize: 22, width: 28, textAlign: 'center' as const },
  quoteCardClient: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.text, marginBottom: 2 },
  quoteCardDate:   { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2 },
  quoteCardChip: {
    paddingHorizontal: 8, paddingVertical: 3,
    borderRadius: RADIUS.full, borderWidth: 1,
  },
  quoteCardChipText: { fontFamily: FONTS.bodyMedium, fontSize: 11 },
});

const ic = StyleSheet.create({
  card: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.xl,
    borderWidth: 1, borderColor: COLORS.border,
    padding: SPACING.lg, marginBottom: 12,
  },
  cardPending: { borderColor: COLORS.green },

  topRow:   { flexDirection: 'row', alignItems: 'center', gap: 12, marginBottom: 10 },
  groupPhoto: { width: 48, height: 48, borderRadius: 14 },
  groupPhotoPlaceholder: {
    width: 48, height: 48, borderRadius: 14,
    backgroundColor: COLORS.greenMuted, borderWidth: 1.5, borderColor: COLORS.green,
    alignItems: 'center', justifyContent: 'center',
  },
  groupPhotoInitial: { fontFamily: FONTS.title, fontSize: 18, color: COLORS.green },
  groupName:    { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.text },
  groupGenre:   { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2 },
  verifiedBadge: {
    flexDirection: 'row', alignItems: 'center', gap: 3,
    backgroundColor: 'rgba(66,133,244,0.15)', borderRadius: RADIUS.full,
    borderWidth: 1, borderColor: 'rgba(66,133,244,0.35)',
    paddingHorizontal: 6, paddingVertical: 2,
  },
  verifiedBadgeText: { fontFamily: FONTS.bodyMedium, fontSize: 10, color: '#90CAF9' },
  trustText: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted2 },

  statusChip: {
    paddingHorizontal: 9, paddingVertical: 3,
    borderRadius: RADIUS.full, borderWidth: 1,
  },
  statusText: { fontFamily: FONTS.bodyMedium, fontSize: 11 },

  infoRow:   { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', marginBottom: 8 },
  typeBadge: { paddingHorizontal: 10, paddingVertical: 4, borderRadius: RADIUS.full },
  typeBadgeTocada: { backgroundColor: COLORS.greenMuted },
  typeBadgeMember: { backgroundColor: 'rgba(99,102,241,0.12)' },
  typeText:    { fontFamily: FONTS.bodyMedium, fontSize: 12 },
  typeTextTocada: { color: COLORS.green },
  typeTextMember: { color: '#6366F1' },
  dateText: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted },

  eventBox:  { backgroundColor: 'rgba(255,255,255,0.03)', borderRadius: 8, padding: 8, marginBottom: 8, gap: 4 },
  eventRow:  { flexDirection: 'row', alignItems: 'center', gap: 6 },
  eventText: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2 },

  payBlock: { marginBottom: 6 },
  payRow:   { flexDirection: 'row', alignItems: 'center', gap: 5, marginBottom: 2 },
  payText:  { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.green },
  payNote:  { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted2, marginLeft: 18 },

  messageText: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted, fontStyle: 'italic', marginBottom: 8 },

  actions: { flexDirection: 'row', gap: 10, marginTop: 12 },
  rejectBtn: {
    flex: 1, flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 7,
    backgroundColor: 'rgba(239,83,80,0.1)', borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: 'rgba(239,83,80,0.4)', paddingVertical: 12,
  },
  rejectText: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: '#EF5350' },
  acceptBtn: {
    flex: 1, flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 7,
    backgroundColor: COLORS.green, borderRadius: RADIUS.md, paddingVertical: 12,
  },
  acceptText: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.bg },
});
