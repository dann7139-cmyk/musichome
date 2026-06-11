/**
 * GroupVerificationScreen — Verificación de identidad KYC para grupos.
 *
 * Pasos:
 *   1. Perfil completo (nombre, género, foto, descripción)
 *   2. Documento de identidad (INE / Pasaporte) — cámara o galería
 *   3. Foto de verificación — selfie con cámara frontal
 *   4. Solicitud enviada → revisión admin (1-3 días)
 */
import {
  ArrowLeft,
  Award,
  Camera,
  CheckCircle,
  Clock,
  Crown,
  FileText,
  Music2,
  Phone,
  Shield,
  ShieldCheck,
  Star,
  TrendingUp,
  Upload,
  XCircle,
  Zap,
} from 'lucide-react-native';
import React, { useEffect, useRef, useState } from 'react';
import {
  Alert,
  Animated,
  Easing,
  Image,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  View,
} from 'react-native';
import * as ImagePicker from 'expo-image-picker';
import { SafeAreaView } from 'react-native-safe-area-context';
import { supabase } from '../../config/supabase';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';
import Button from '../../components/ui/Button';
import Particles from '../../components/ui/Particles';

// ─── Pasos del flujo ──────────────────────────────────────────────────────────

const STEPS = [
  { key: 'profile',  icon: Music2,      label: 'Perfil' },
  { key: 'document', icon: Upload,      label: 'Documento' },
  { key: 'selfie',   icon: Camera,      label: 'Foto' },
  { key: 'review',   icon: Award,       label: 'Revisión' },
  { key: 'approved', icon: ShieldCheck, label: 'Aprobado' },
];

// ─── Pantalla principal ────────────────────────────────────────────────────────

export default function GroupVerificationScreen({ navigation }: any) {
  const [group,      setGroup]      = useState<any>(null);
  const [request,    setRequest]    = useState<any>(null);
  const [attemptId,  setAttemptId]  = useState<string | null>(null);
  const [ownerPhone, setOwnerPhone] = useState('');
  const [loading,    setLoading]    = useState(false);

  // KYC state
  const [activeKycStep,  setActiveKycStep]  = useState<'document' | 'selfie' | null>(null);
  const [docUri,         setDocUri]         = useState<string | null>(null);
  const [docUploading,   setDocUploading]   = useState(false);
  const [docUploaded,    setDocUploaded]    = useState(false);
  const [selfieUri,      setSelfieUri]      = useState<string | null>(null);
  const [selfieUploading, setSelfieUploading] = useState(false);
  const [selfieComplete, setSelfieComplete] = useState(false);

  // Animations
  const pulseAnim  = useRef(new Animated.Value(1)).current;
  const glowAnim   = useRef(new Animated.Value(0.3)).current;
  const rotateAnim = useRef(new Animated.Value(0)).current;

  useEffect(() => { fetchData(); }, []);

  useEffect(() => {
    Animated.loop(
      Animated.sequence([
        Animated.parallel([
          Animated.timing(pulseAnim, { toValue: 1.12, duration: 1200, easing: Easing.inOut(Easing.ease), useNativeDriver: true }),
          Animated.timing(glowAnim,  { toValue: 0.7,  duration: 1200, easing: Easing.inOut(Easing.ease), useNativeDriver: true }),
        ]),
        Animated.parallel([
          Animated.timing(pulseAnim, { toValue: 1,   duration: 1200, easing: Easing.inOut(Easing.ease), useNativeDriver: true }),
          Animated.timing(glowAnim,  { toValue: 0.3, duration: 1200, easing: Easing.inOut(Easing.ease), useNativeDriver: true }),
        ]),
      ])
    ).start();
  }, []);

  useEffect(() => {
    if (group?.verification_status === 'approved') {
      Animated.loop(
        Animated.timing(rotateAnim, { toValue: 1, duration: 8000, easing: Easing.linear, useNativeDriver: true })
      ).start();
    }
  }, [group?.verification_status]);

  const spin = rotateAnim.interpolate({ inputRange: [0, 1], outputRange: ['0deg', '360deg'] });

  const fetchData = async () => {
    const { data: sessionData } = await supabase.auth.getSession();
    if (!sessionData.session) return;

    const { data: grp } = await supabase
      .from('groups').select('*')
      .eq('owner_id', sessionData.session.user.id).single();
    setGroup(grp);

    if (grp) {
      // Obtener último request (cualquier status)
      const { data: req } = await supabase
        .from('verification_requests').select('*')
        .eq('group_id', grp.id)
        .order('submitted_at', { ascending: false })
        .limit(1).maybeSingle();
      setRequest(req);

      // Solo pre-cargar estado KYC si el request es un draft activo.
      // Si está rejected, resetear a false para permitir nuevo intento.
      if (req?.status === 'draft') {
        setAttemptId(req.id);
        if (req?.document_url) setDocUploaded(true);
        if (req?.liveness_verified) setSelfieComplete(true);
      }

      // Obtener teléfono del owner
      const { data: ownerProf } = await supabase
        .from('profiles').select('phone').eq('id', grp.owner_id).single();
      setOwnerPhone(ownerProf?.phone ?? '');
    }
  };

  // ── Helper: obtener o crear el draft attempt ───────────────────────────────

  const ensureAttemptId = async (): Promise<string | null> => {
    if (attemptId) return attemptId;
    if (!group) return null;
    const { data, error } = await supabase.rpc('start_group_verification', {
      p_group_id: group.id,
    });
    if (error || !data?.ok) {
      Alert.alert('Error', data?.error ?? error?.message ?? 'No se pudo iniciar la verificación.');
      return null;
    }
    setAttemptId(data.attempt_id);
    return data.attempt_id;
  };

  // ── Documento: cámara o galería ───────────────────────────────────────────

  const handlePickDocument = () => {
    Alert.alert(
      'Subir documento',
      'Elige cómo quieres agregar tu identificación oficial.',
      [
        {
          text: 'Tomar foto',
          onPress: async () => {
            const { status } = await ImagePicker.requestCameraPermissionsAsync();
            if (status !== 'granted') {
              Alert.alert('Permiso denegado', 'Necesitamos acceso a la cámara para tomar la foto del documento.');
              return;
            }
            const result = await ImagePicker.launchCameraAsync({
              mediaTypes: ['images'],
              allowsEditing: true,
              quality: 0.85,
            });
            if (!result.canceled && result.assets?.length) setDocUri(result.assets[0].uri);
          },
        },
        {
          text: 'Elegir de galería',
          onPress: async () => {
            const { status } = await ImagePicker.requestMediaLibraryPermissionsAsync();
            if (status !== 'granted') {
              Alert.alert('Permiso denegado', 'Necesitamos acceso a la galería para seleccionar el documento.');
              return;
            }
            const result = await ImagePicker.launchImageLibraryAsync({
              mediaTypes: ['images'],
              allowsEditing: true,
              quality: 0.85,
            });
            if (!result.canceled && result.assets?.length) setDocUri(result.assets[0].uri);
          },
        },
        { text: 'Cancelar', style: 'cancel' },
      ]
    );
  };

  const handleUploadDocument = async () => {
    if (!docUri || !group) return;
    setDocUploading(true);
    try {
      const ext         = docUri.split('.').pop()?.toLowerCase() ?? 'jpg';
      // Path privado: el admin genera signed URL para revisar.
      const storagePath = `kyc_${group.id}_${Date.now()}.${ext}`;
      const response    = await fetch(docUri);
      const blob        = await response.blob();
      const { error: uploadError } = await supabase.storage
        .from('verification-docs')
        .upload(storagePath, blob, { contentType: `image/${ext}`, upsert: true });
      if (uploadError) throw uploadError;

      const aid = await ensureAttemptId();
      if (!aid) return;

      const { data, error } = await supabase.rpc('update_verification_document', {
        p_attempt_id:    aid,
        p_document_path: storagePath,
      });
      if (error || !data?.ok) throw new Error(data?.error ?? error?.message);

      setDocUploaded(true);
      setActiveKycStep(null);
      Alert.alert('✅ Documento subido', 'Tu documento fue cargado correctamente. Ahora toma tu foto de verificación.');
    } catch (e: any) {
      Alert.alert('Error', e.message ?? 'No se pudo subir el documento.');
    } finally {
      setDocUploading(false);
    }
  };

  // ── Selfie: cámara frontal ─────────────────────────────────────────────────
  // Selfie simple con cámara frontal. liveness_verified=TRUE indica que
  // se tomó y subió la foto. No implica detección biométrica de vida.

  const handleTakeSelfie = async () => {
    const { status } = await ImagePicker.requestCameraPermissionsAsync();
    if (status !== 'granted') {
      Alert.alert('Permiso denegado', 'Necesitamos acceso a la cámara frontal para tu foto de verificación.');
      return;
    }
    const result = await ImagePicker.launchCameraAsync({
      mediaTypes: ['images'],
      cameraType: ImagePicker.CameraType.front,
      allowsEditing: true,
      aspect: [1, 1],
      quality: 0.85,
    });
    if (!result.canceled && result.assets?.length) {
      setSelfieUri(result.assets[0].uri);
    }
  };

  const handleConfirmSelfie = async () => {
    if (!selfieUri || !group) return;
    setSelfieUploading(true);
    try {
      const ext         = selfieUri.split('.').pop()?.toLowerCase() ?? 'jpg';
      const storagePath = `selfie_${group.id}_${Date.now()}.${ext}`;
      const response    = await fetch(selfieUri);
      const blob        = await response.blob();
      const { error: uploadError } = await supabase.storage
        .from('verification-docs')
        .upload(storagePath, blob, { contentType: `image/${ext}`, upsert: true });
      if (uploadError) throw uploadError;

      const aid = await ensureAttemptId();
      if (!aid) return;

      const { data, error } = await supabase.rpc('complete_verification_liveness', {
        p_attempt_id:  aid,
        p_selfie_path: storagePath,
      });
      if (error || !data?.ok) throw new Error(data?.error ?? error?.message);

      setSelfieComplete(true);
      setActiveKycStep(null);
      Alert.alert('✅ Foto enviada', '¡Perfecto! Ahora puedes enviar tu solicitud de verificación.');
    } catch (e: any) {
      Alert.alert('Error', e.message ?? 'No se pudo subir la foto.');
    } finally {
      setSelfieUploading(false);
    }
  };

  // ── Guardar teléfono ───────────────────────────────────────────────────────

  const handleSavePhone = async (phone: string) => {
    if (!group || !phone.trim()) return;
    await supabase.from('profiles')
      .update({ phone: phone.trim() })
      .eq('id', group.owner_id);
  };

  // ── Enviar solicitud final ─────────────────────────────────────────────────

  const handleRequestVerification = async () => {
    if (!group) return;
    const perfilIncompleto = !group.name || !group.genre || !group.profile_image || !group.description;
    if (perfilIncompleto) {
      Alert.alert('Perfil incompleto', 'Revisa la lista de requisitos en esta pantalla y completa todo lo marcado antes de continuar.');
      return;
    }
    if (!docUploaded) {
      Alert.alert('Documento requerido', 'Por favor sube tu INE o pasaporte antes de continuar.');
      setActiveKycStep('document');
      return;
    }
    if (!selfieComplete) {
      Alert.alert('Foto requerida', 'Toma tu foto de verificación antes de enviar.');
      setActiveKycStep('selfie');
      return;
    }

    const doSubmit = async () => {
      setLoading(true);
      const aid = await ensureAttemptId();
      if (!aid) { setLoading(false); return; }
      const { data, error } = await supabase.rpc('submit_verification_request', {
        p_attempt_id: aid,
      });
      setLoading(false);
      if (error || !data?.ok) {
        if (data?.error === 'profile_incomplete' && data?.missing?.length) {
          const labels: Record<string, string> = {
            name: 'Nombre del grupo', genre: 'Género musical',
            profile_image: 'Foto de perfil', description: 'Descripción',
          };
          const list = (data.missing as string[])
            .map((k: string) => `• ${labels[k] ?? k}`)
            .join('\n');
          Alert.alert('Perfil incompleto', `Completa los siguientes requisitos antes de continuar:\n\n${list}`);
        } else {
          Alert.alert('Error', data?.error ?? error?.message ?? 'No se pudo enviar la solicitud.');
        }
      } else {
        setAttemptId(null);
        setGroup((prev: any) => ({ ...prev, verification_status: 'pending' }));
        Alert.alert('¡Solicitud enviada! 🎉', 'Revisaremos tu identidad y te notificaremos el resultado.');
        fetchData();
      }
    };

    // Advertencia no bloqueante si falta teléfono
    if (!ownerPhone.trim()) {
      Alert.alert(
        'Sin teléfono de contacto',
        'Agregar un número de teléfono ayuda al equipo a contactarte durante la revisión.',
        [
          { text: 'Agregar teléfono', style: 'cancel' },
          { text: 'Continuar de todas formas', onPress: doSubmit },
        ]
      );
    } else {
      Alert.alert(
        'Enviar verificación',
        'Se enviará tu solicitud con tu documento y foto de identidad. El equipo la revisará en 1-3 días hábiles.',
        [
          { text: 'Cancelar', style: 'cancel' },
          { text: 'Enviar solicitud', onPress: doSubmit },
        ]
      );
    }
  };

  const currentStatus = group?.verification_status ?? 'none';
  const isApproved    = currentStatus === 'approved';
  const isPending     = currentStatus === 'pending';
  const isRejected    = currentStatus === 'rejected';
  const heroColor     = isApproved ? COLORS.blue : isPending ? COLORS.orange : isRejected ? COLORS.red : COLORS.green;

  // 0=Perfil 1=Documento 2=Foto 3=Revisión 4=Aprobado
  const getCompletionStep = () => {
    if (!group?.name || !group?.genre || !group?.profile_image || !group?.description) return 0;
    if (!docUploaded) return 1;
    if (!selfieComplete) return 2;
    if (currentStatus === 'none' || currentStatus === 'rejected') return 3;
    if (currentStatus === 'pending') return 4;
    return 5;
  };
  const completionStep = getCompletionStep();

  // ─── RENDER: Paso de documento ───────────────────────────────────────────
  if (activeKycStep === 'document') {
    return (
      <View style={styles.container}>
        <Particles />
        <SafeAreaView style={{ flex: 1 }}>
          <View style={styles.header}>
            <Pressable style={styles.backBtn} onPress={() => { setActiveKycStep(null); setDocUri(null); }}>
              <ArrowLeft size={20} color={COLORS.text} />
            </Pressable>
            <Text style={styles.headerTitle}>Documento de identidad</Text>
            <View style={{ width: 40 }} />
          </View>
          <ScrollView contentContainerStyle={styles.scroll}>
            <View style={styles.docCard}>
              <View style={styles.docIconBox}>
                <FileText size={36} color={COLORS.green} />
              </View>
              <Text style={styles.docTitle}>Sube tu INE o Pasaporte</Text>
              <Text style={styles.docDesc}>
                Solo aceptamos INE, pasaporte o cédula profesional vigente. La información está encriptada y protegida.
              </Text>

              {docUri ? (
                <View style={styles.docPreviewWrap}>
                  <Image source={{ uri: docUri }} style={styles.docPreview} resizeMode="cover" />
                  <Pressable style={styles.docChangeBtn} onPress={handlePickDocument}>
                    <Text style={styles.docChangeBtnText}>Cambiar documento</Text>
                  </Pressable>
                </View>
              ) : (
                <Pressable style={styles.docPickBtn} onPress={handlePickDocument}>
                  <Upload size={22} color={COLORS.green} />
                  <Text style={styles.docPickBtnText}>Tomar foto o elegir de galería</Text>
                </Pressable>
              )}

              <View style={styles.docTips}>
                {[
                  'Foto nítida, sin reflejos ni sombras',
                  'Todos los datos visibles y legibles',
                  'Documento vigente (no expirado)',
                  'Archivo: JPG, PNG (máx. 5 MB)',
                ].map((tip, i) => (
                  <View key={i} style={styles.docTipRow}>
                    <CheckCircle size={14} color={COLORS.green} />
                    <Text style={styles.docTipText}>{tip}</Text>
                  </View>
                ))}
              </View>
            </View>

            <View style={{ marginTop: 16, marginBottom: 32 }}>
              <Button
                label="Subir documento"
                onPress={handleUploadDocument}
                loading={docUploading}
                disabled={!docUri}
                size="lg"
              />
            </View>
          </ScrollView>
        </SafeAreaView>
      </View>
    );
  }

  // ─── RENDER: Paso de selfie ────────────────────────────────────────────────
  if (activeKycStep === 'selfie') {
    return (
      <View style={styles.container}>
        <Particles />
        <SafeAreaView style={{ flex: 1 }}>
          <View style={styles.header}>
            <Pressable style={styles.backBtn} onPress={() => { setActiveKycStep(null); setSelfieUri(null); }}>
              <ArrowLeft size={20} color={COLORS.text} />
            </Pressable>
            <Text style={styles.headerTitle}>Foto de verificación</Text>
            <View style={{ width: 40 }} />
          </View>
          <ScrollView contentContainerStyle={[styles.scroll, { alignItems: 'center' }]}>

            <View style={styles.selfieInfoBox}>
              <Camera size={28} color={COLORS.blue} />
              <Text style={styles.selfieInfoTitle}>Foto con cámara frontal</Text>
              <Text style={styles.selfieInfoDesc}>
                Asegúrate de estar en un lugar bien iluminado. Tu rostro debe estar centrado y visible.
              </Text>
            </View>

            {selfieUri ? (
              <View style={styles.selfiePreviewWrap}>
                <Image source={{ uri: selfieUri }} style={styles.selfiePreview} resizeMode="cover" />
                <Pressable style={styles.selfieRetakeBtn} onPress={() => { setSelfieUri(null); }}>
                  <Camera size={16} color={COLORS.text} />
                  <Text style={styles.selfieRetakeBtnText}>Tomar otra foto</Text>
                </Pressable>
              </View>
            ) : (
              <View style={styles.selfiePlaceholder}>
                <Camera size={48} color={COLORS.muted} />
                <Text style={styles.selfiePlaceholderText}>Toca el botón para abrir la cámara frontal</Text>
              </View>
            )}

            <View style={styles.selfieInstructions}>
              {[
                { icon: '☀️', text: 'Buena iluminación, evita contraluz' },
                { icon: '👤', text: 'Rostro completo, sin gafas ni gorras' },
                { icon: '📱', text: 'Mantén el dispositivo estable' },
              ].map((step, i) => (
                <View key={i} style={styles.selfieStep}>
                  <Text style={styles.selfieStepEmoji}>{step.icon}</Text>
                  <Text style={styles.selfieStepText}>{step.text}</Text>
                </View>
              ))}
            </View>

            <View style={{ width: '100%', gap: 12, marginTop: 16, marginBottom: 32 }}>
              {!selfieUri && (
                <Button label="📷 Abrir cámara frontal" onPress={handleTakeSelfie} size="lg" />
              )}
              {selfieUri && (
                <Button
                  label="✅ Confirmar foto"
                  onPress={handleConfirmSelfie}
                  loading={selfieUploading}
                  size="lg"
                />
              )}
              <Text style={styles.selfieNote}>
                Esta foto se usa solo para verificar tu identidad y no se comparte con terceros.
              </Text>
            </View>
          </ScrollView>
        </SafeAreaView>
      </View>
    );
  }

  // ─── RENDER PRINCIPAL ─────────────────────────────────────────────────────
  return (
    <View style={styles.container}>
      <Particles />
      <SafeAreaView style={{ flex: 1 }}>
        <View style={styles.header}>
          <Pressable style={styles.backBtn} onPress={() => navigation.goBack()}>
            <ArrowLeft size={20} color={COLORS.text} />
          </Pressable>
          <Text style={styles.headerTitle}>Verificación</Text>
          <View style={{ width: 40 }} />
        </View>

        <ScrollView showsVerticalScrollIndicator={false} contentContainerStyle={styles.scroll}>

          {/* HERO STATUS */}
          <View style={styles.heroCard}>
            <View style={styles.heroIconContainer}>
              <Animated.View style={[styles.heroGlowRing, { opacity: glowAnim, transform: [{ scale: pulseAnim }], borderColor: heroColor, shadowColor: heroColor }]} />
              <Animated.View style={[styles.heroGlowRing2, { opacity: Animated.multiply(glowAnim, 0.5), transform: [{ scale: Animated.multiply(pulseAnim, 1.15) }], borderColor: heroColor }]} />
              <Animated.View style={[styles.heroIconRing, isApproved && styles.heroIconApproved, isPending && styles.heroIconPending, isRejected && styles.heroIconRejected, isApproved && { transform: [{ rotate: spin }] }]}>
                {isApproved ? <ShieldCheck size={38} color={COLORS.blue} /> : isPending ? <Clock size={38} color={COLORS.orange} /> : isRejected ? <XCircle size={38} color={COLORS.red} /> : <Shield size={38} color={COLORS.green} />}
              </Animated.View>
            </View>
            <Text style={styles.heroTitle}>
              {isApproved ? '¡Grupo verificado!' : isPending ? 'En revisión' : isRejected ? 'Solicitud rechazada' : 'Obtén la verificación'}
            </Text>
            <Text style={styles.heroSubtitle}>
              {isApproved
                ? 'Tu grupo tiene la insignia verificada por DARICEFY. Los clientes confían más en ti.'
                : isPending
                ? 'Tu solicitud está siendo revisada. Te notificaremos en 1-3 días hábiles.'
                : isRejected
                ? 'Tu solicitud fue rechazada. Revisa el motivo y vuelve a intentarlo.'
                : 'Completa los pasos para obtener el badge de verificado.'}
            </Text>

            {/* PROGRESS STEPS */}
            <View style={styles.stepsRow}>
              {STEPS.map((step, i) => {
                const done   = i < completionStep;
                const active = i === completionStep;
                const IconComp = step.icon;
                return (
                  <View key={step.key} style={styles.stepItem}>
                    <View style={[styles.stepCircle, done && styles.stepDone, active && styles.stepActive]}>
                      {done ? <CheckCircle size={14} color={COLORS.bg} /> : <IconComp size={13} color={done ? COLORS.bg : active ? COLORS.green : COLORS.muted} />}
                    </View>
                    <Text style={[styles.stepLabel, done && styles.stepLabelDone, active && styles.stepLabelActive]}>
                      {step.label}
                    </Text>
                    {i < STEPS.length - 1 && (
                      <View style={[styles.stepLine, done && styles.stepLineDone]} />
                    )}
                  </View>
                );
              })}
            </View>
          </View>

          {/* RECHAZADO */}
          {isRejected && (
            <View style={styles.rejectedCard}>
              <View style={styles.rejectedHeader}>
                <XCircle size={18} color={COLORS.red} />
                <Text style={styles.rejectedTitle}>Solicitud rechazada</Text>
              </View>
              {request?.admin_notes
                ? <Text style={styles.rejectedNotes}>{request.admin_notes}</Text>
                : <Text style={styles.rejectedNotes}>El equipo revisó tu solicitud y no fue aprobada en esta ocasión.</Text>
              }
              <Text style={styles.rejectedHint}>Corrige los puntos necesarios y vuelve a enviar tu solicitud.</Text>
            </View>
          )}

          {/* APROBADO */}
          {isApproved && (
            <View style={styles.approvedCard}>
              <ShieldCheck size={22} color={COLORS.blue} />
              <View style={{ flex: 1 }}>
                <Text style={styles.approvedTitle}>✅ Verificado por DARICEFY</Text>
                <Text style={styles.approvedDesc}>
                  Tu grupo aparece con prioridad en búsquedas y tiene el badge azul de confianza.
                </Text>
              </View>
            </View>
          )}

          {/* CHECKLIST DE REQUISITOS */}
          {!isApproved && (
            <View style={styles.checklistCard}>
              <Text style={styles.checklistTitle}>Requisitos del perfil</Text>
              {[
                { text: 'Nombre del grupo',            done: !!group?.name },
                { text: 'Género musical',              done: !!group?.genre },
                { text: 'Foto de perfil',              done: !!group?.profile_image },
                { text: 'Descripción',                 done: !!group?.description },
                { text: 'Video promocional (opcional)', done: !!group?.promo_video },
              ].map((req, i) => (
                <View key={i} style={styles.checkRow}>
                  <View style={[styles.checkCircle, req.done && styles.checkCircleDone]}>
                    {req.done ? <CheckCircle size={13} color={COLORS.bg} /> : <View style={styles.checkEmpty} />}
                  </View>
                  <Text style={[styles.checkText, req.done && styles.checkTextDone]}>{req.text}</Text>
                </View>
              ))}

              {/* Teléfono de contacto */}
              <View style={[styles.checkRow, { marginTop: 8, flexDirection: 'column', alignItems: 'flex-start', gap: 8 }]}>
                <View style={{ flexDirection: 'row', alignItems: 'center', gap: 8 }}>
                  <Phone size={14} color={ownerPhone.trim() ? COLORS.green : COLORS.muted} />
                  <Text style={[styles.checkText, ownerPhone.trim() && styles.checkTextDone]}>
                    Teléfono de contacto{!ownerPhone.trim() ? ' (recomendado)' : ''}
                  </Text>
                </View>
                <TextInput
                  style={[styles.phoneInput, isPending && { opacity: 0.5 }]}
                  value={ownerPhone}
                  onChangeText={setOwnerPhone}
                  onBlur={() => handleSavePhone(ownerPhone)}
                  placeholder="Ej: 3312345678"
                  placeholderTextColor={COLORS.muted}
                  keyboardType="phone-pad"
                  editable={!isPending && !isApproved}
                />
              </View>
            </View>
          )}

          {/* PASOS KYC */}
          {!isApproved && (
            <View style={styles.kycCard}>
              <Text style={styles.checklistTitle}>Verificación de identidad</Text>
              <Text style={styles.kycDesc}>
                Solicitamos una identificación oficial y una fotografía facial para proteger a todos en la plataforma.
                Esta información se usa exclusivamente para verificar identidades, prevenir fraudes y suplantaciones,
                y proporcionar respaldo en caso de disputas o incidentes. Tus documentos se almacenan cifrados
                y nunca se comparten con terceros.
              </Text>

              {/* Paso: Documento */}
              <Pressable
                style={[styles.kycStep, docUploaded && styles.kycStepDone]}
                onPress={() => !docUploaded && setActiveKycStep('document')}
                disabled={isPending}
              >
                <View style={[styles.kycStepIcon, docUploaded && styles.kycStepIconDone]}>
                  {docUploaded ? <CheckCircle size={20} color={COLORS.bg} /> : <FileText size={20} color={COLORS.green} />}
                </View>
                <View style={{ flex: 1 }}>
                  <Text style={styles.kycStepTitle}>
                    {docUploaded ? '✅ Documento subido' : 'Subir INE / Pasaporte'}
                  </Text>
                  <Text style={styles.kycStepDesc}>
                    {docUploaded ? 'Tu documento fue cargado correctamente.' : 'Toma foto o elige de galería.'}
                  </Text>
                </View>
                {!docUploaded && !isPending && (
                  <View style={styles.kycStepChevron}>
                    <Text style={styles.kycStepChevronText}>→</Text>
                  </View>
                )}
              </Pressable>

              {/* Paso: Foto de verificación */}
              <Pressable
                style={[styles.kycStep, selfieComplete && styles.kycStepDone]}
                onPress={() => !selfieComplete && setActiveKycStep('selfie')}
                disabled={isPending}
              >
                <View style={[styles.kycStepIcon, selfieComplete && styles.kycStepIconDone, !selfieComplete && { backgroundColor: 'rgba(66,133,244,0.1)', borderColor: 'rgba(66,133,244,0.3)' }]}>
                  {selfieComplete ? <CheckCircle size={20} color={COLORS.bg} /> : <Camera size={20} color={COLORS.blue} />}
                </View>
                <View style={{ flex: 1 }}>
                  <Text style={styles.kycStepTitle}>
                    {selfieComplete ? '✅ Foto enviada' : 'Foto de verificación'}
                  </Text>
                  <Text style={styles.kycStepDesc}>
                    {selfieComplete ? 'Tu foto de identidad fue registrada.' : 'Selfie con cámara frontal.'}
                  </Text>
                </View>
                {!selfieComplete && !isPending && (
                  <View style={styles.kycStepChevron}>
                    <Text style={styles.kycStepChevronText}>→</Text>
                  </View>
                )}
              </Pressable>

              <View style={styles.kycSecurityNote}>
                <Text style={styles.kycSecurityText}>
                  🔐 Tu información está protegida con encriptación AES-256. Nunca compartimos tus documentos.
                </Text>
              </View>
            </View>
          )}

          {/* BENEFICIOS */}
          <View style={styles.benefitsCard}>
            <Text style={styles.benefitsTitle}>Beneficios al verificarte</Text>
            {[
              { icon: Crown,      color: COLORS.blue,   title: 'Badge verificado',  desc: '✅ DARICEFY junto a tu nombre' },
              { icon: TrendingUp, color: COLORS.green,  title: 'Más visibilidad',   desc: 'Prioridad en búsquedas y recomendaciones' },
              { icon: Star,       color: COLORS.gold,   title: 'Mayor confianza',   desc: 'Los clientes prefieren grupos verificados' },
              { icon: Zap,        color: COLORS.orange, title: 'Más reservas',      desc: 'Aumenta tus ingresos con más solicitudes' },
            ].map((b, i) => {
              const IconComp = b.icon;
              return (
                <View key={i} style={styles.benefitRow}>
                  <View style={[styles.benefitIcon, { borderColor: `${b.color}30`, backgroundColor: `${b.color}10` }]}>
                    <IconComp size={18} color={b.color} />
                  </View>
                  <View style={{ flex: 1 }}>
                    <Text style={styles.benefitTitle}>{b.title}</Text>
                    <Text style={styles.benefitDesc}>{b.desc}</Text>
                  </View>
                </View>
              );
            })}
          </View>

          {/* ACCIÓN */}
          <View style={styles.actionSection}>
            {(currentStatus === 'none' || currentStatus === 'rejected') && (
              <>
                <Button
                  label="🛡️ Enviar solicitud de verificación"
                  onPress={handleRequestVerification}
                  loading={loading}
                  size="lg"
                />
                <Text style={styles.actionHint}>
                  {docUploaded && selfieComplete
                    ? 'Revisaremos tu solicitud en 1-3 días hábiles'
                    : 'Completa el documento y la foto para continuar'}
                </Text>
              </>
            )}
            {isPending && (
              <View style={styles.pendingBanner}>
                <Clock size={20} color={COLORS.orange} />
                <View style={{ flex: 1 }}>
                  <Text style={styles.pendingTitle}>Solicitud en proceso</Text>
                  <Text style={styles.pendingDesc}>
                    Nuestro equipo está revisando tu identidad y documentos. Te notificaremos cuando esté listo.
                  </Text>
                </View>
              </View>
            )}
          </View>

          <View style={{ height: 32 }} />
        </ScrollView>
      </SafeAreaView>
    </View>
  );
}

// ─── Estilos ──────────────────────────────────────────────────────────────────
const styles = StyleSheet.create({
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
  scroll: { padding: SPACING.xl, gap: 16 },

  // Hero
  heroCard: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.xl,
    borderWidth: 1, borderColor: COLORS.border, padding: SPACING.xl, alignItems: 'center',
  },
  heroIconContainer: { width: 120, height: 120, alignItems: 'center', justifyContent: 'center', marginBottom: 16 },
  heroGlowRing: {
    position: 'absolute', width: 110, height: 110, borderRadius: 55,
    borderWidth: 1.5, backgroundColor: 'transparent',
    shadowOffset: { width: 0, height: 0 }, shadowOpacity: 0.6, shadowRadius: 20,
  },
  heroGlowRing2: { position: 'absolute', width: 120, height: 120, borderRadius: 60, borderWidth: 1, backgroundColor: 'transparent' },
  heroIconRing: {
    width: 84, height: 84, borderRadius: 42,
    backgroundColor: 'rgba(0,230,118,0.1)', borderWidth: 2, borderColor: 'rgba(0,230,118,0.35)',
    alignItems: 'center', justifyContent: 'center',
  },
  heroIconApproved: { backgroundColor: 'rgba(66,133,244,0.1)', borderColor: 'rgba(66,133,244,0.35)' },
  heroIconPending:  { backgroundColor: 'rgba(255,152,0,0.1)',  borderColor: 'rgba(255,152,0,0.35)'  },
  heroIconRejected: { backgroundColor: 'rgba(239,83,80,0.1)',  borderColor: 'rgba(239,83,80,0.35)'  },
  heroTitle:    { fontFamily: FONTS.title, fontSize: 22, color: COLORS.text, marginBottom: 8, textAlign: 'center' },
  heroSubtitle: { fontFamily: FONTS.body, fontSize: 14, color: COLORS.muted2, textAlign: 'center', lineHeight: 22, marginBottom: 24 },

  // Steps
  stepsRow: { flexDirection: 'row', alignItems: 'flex-start', justifyContent: 'center', width: '100%' },
  stepItem: { alignItems: 'center', flex: 1, position: 'relative' },
  stepCircle: {
    width: 30, height: 30, borderRadius: 15,
    backgroundColor: COLORS.card2, borderWidth: 1.5, borderColor: COLORS.border,
    alignItems: 'center', justifyContent: 'center', marginBottom: 6,
  },
  stepDone:   { backgroundColor: COLORS.green, borderColor: COLORS.green },
  stepActive: { borderColor: COLORS.green, backgroundColor: 'rgba(0,230,118,0.12)' },
  stepLabel:       { fontFamily: FONTS.body, fontSize: 9, color: COLORS.muted, textAlign: 'center' },
  stepLabelDone:   { color: COLORS.green },
  stepLabelActive: { color: COLORS.text, fontFamily: FONTS.bodyMedium },
  stepLine: {
    position: 'absolute', top: 15, left: '60%', right: '-40%',
    height: 1.5, backgroundColor: COLORS.border,
  },
  stepLineDone: { backgroundColor: COLORS.green },

  // Rejected / Approved
  rejectedCard: {
    backgroundColor: 'rgba(239,83,80,0.06)', borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: 'rgba(239,83,80,0.3)', padding: SPACING.lg,
  },
  rejectedHeader: { flexDirection: 'row', alignItems: 'center', gap: 8, marginBottom: 8 },
  rejectedTitle:  { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.red },
  rejectedNotes:  { fontFamily: FONTS.body, fontSize: 13, color: COLORS.text, marginBottom: 6, lineHeight: 20 },
  rejectedHint:   { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2 },
  approvedCard: {
    flexDirection: 'row', alignItems: 'center', gap: 14,
    backgroundColor: 'rgba(66,133,244,0.06)', borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: 'rgba(66,133,244,0.3)', padding: SPACING.lg,
  },
  approvedTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.blue, marginBottom: 4 },
  approvedDesc:  { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2, lineHeight: 20 },

  // Checklist
  checklistCard: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border, padding: SPACING.lg,
  },
  checklistTitle: { fontFamily: FONTS.title, fontSize: 16, color: COLORS.text, marginBottom: 16 },
  checkRow: { flexDirection: 'row', alignItems: 'center', gap: 12, marginBottom: 14 },
  checkCircle: {
    width: 24, height: 24, borderRadius: 12,
    backgroundColor: COLORS.card2, borderWidth: 1.5, borderColor: COLORS.border,
    alignItems: 'center', justifyContent: 'center',
  },
  checkCircleDone: { backgroundColor: COLORS.green, borderColor: COLORS.green },
  checkEmpty: { width: 8, height: 8, borderRadius: 4, backgroundColor: COLORS.muted },
  checkText:     { fontFamily: FONTS.body, fontSize: 14, color: COLORS.muted2 },
  checkTextDone: { color: COLORS.text },
  phoneInput: {
    width: '100%', backgroundColor: COLORS.bg, borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: COLORS.border,
    paddingHorizontal: 14, paddingVertical: 10,
    fontFamily: FONTS.body, fontSize: 14, color: COLORS.text,
  },

  // KYC Steps
  kycCard: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border, padding: SPACING.lg,
  },
  kycDesc: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2, lineHeight: 20, marginBottom: 16 },
  kycStep: {
    flexDirection: 'row', alignItems: 'center', gap: 14,
    backgroundColor: COLORS.card2, borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: COLORS.border,
    padding: SPACING.lg, marginBottom: 12,
  },
  kycStepDone: { borderColor: COLORS.green, backgroundColor: 'rgba(0,230,118,0.06)' },
  kycStepIcon: {
    width: 44, height: 44, borderRadius: 12,
    backgroundColor: 'rgba(0,230,118,0.1)', borderWidth: 1, borderColor: 'rgba(0,230,118,0.3)',
    alignItems: 'center', justifyContent: 'center',
  },
  kycStepIconDone: { backgroundColor: COLORS.green, borderColor: COLORS.green },
  kycStepTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.text, marginBottom: 3 },
  kycStepDesc:  { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2 },
  kycStepChevron: { width: 28, height: 28, borderRadius: 8, backgroundColor: COLORS.card, borderWidth: 1, borderColor: COLORS.border, alignItems: 'center', justifyContent: 'center' },
  kycStepChevronText: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.muted2 },
  kycSecurityNote: {
    backgroundColor: 'rgba(0,230,118,0.04)', borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.15)', padding: 12, marginTop: 4,
  },
  kycSecurityText: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, lineHeight: 18 },

  // Document upload step
  docCard: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.xl,
    borderWidth: 1, borderColor: COLORS.border, padding: SPACING.xl, alignItems: 'center',
  },
  docIconBox: {
    width: 72, height: 72, borderRadius: 20,
    backgroundColor: 'rgba(0,230,118,0.1)', borderWidth: 1.5, borderColor: 'rgba(0,230,118,0.3)',
    alignItems: 'center', justifyContent: 'center', marginBottom: 16,
  },
  docTitle: { fontFamily: FONTS.title, fontSize: 20, color: COLORS.text, marginBottom: 10, textAlign: 'center' },
  docDesc:  { fontFamily: FONTS.body, fontSize: 14, color: COLORS.muted2, textAlign: 'center', lineHeight: 22, marginBottom: 20 },
  docPickBtn: {
    flexDirection: 'row', alignItems: 'center', gap: 12,
    backgroundColor: COLORS.greenMuted, borderRadius: RADIUS.lg,
    borderWidth: 1.5, borderColor: COLORS.green,
    paddingHorizontal: 24, paddingVertical: 16, marginBottom: 20, width: '100%', justifyContent: 'center',
  },
  docPickBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.green },
  docPreviewWrap: { width: '100%', marginBottom: 20, alignItems: 'center' },
  docPreview: { width: '100%', height: 180, borderRadius: RADIUS.lg, marginBottom: 10 },
  docChangeBtn: { paddingHorizontal: 16, paddingVertical: 8 },
  docChangeBtnText: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted2 },
  docTips: { gap: 10, width: '100%' },
  docTipRow: { flexDirection: 'row', alignItems: 'center', gap: 10 },
  docTipText: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2, flex: 1 },

  // Selfie step
  selfieInfoBox: {
    width: '100%', backgroundColor: 'rgba(66,133,244,0.06)',
    borderRadius: RADIUS.lg, borderWidth: 1, borderColor: 'rgba(66,133,244,0.25)',
    padding: SPACING.lg, alignItems: 'center', gap: 10,
  },
  selfieInfoTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 16, color: COLORS.text },
  selfieInfoDesc:  { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2, textAlign: 'center', lineHeight: 20 },
  selfiePlaceholder: {
    width: 200, height: 200, borderRadius: 100,
    backgroundColor: COLORS.card2, borderWidth: 2, borderColor: COLORS.border,
    alignItems: 'center', justifyContent: 'center', gap: 12, marginVertical: 24,
  },
  selfiePlaceholderText: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted, textAlign: 'center', paddingHorizontal: 20 },
  selfiePreviewWrap: { alignItems: 'center', marginVertical: 24, gap: 12 },
  selfiePreview: { width: 200, height: 200, borderRadius: 100, borderWidth: 3, borderColor: COLORS.green },
  selfieRetakeBtn: {
    flexDirection: 'row', alignItems: 'center', gap: 8,
    backgroundColor: COLORS.card2, borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: COLORS.border,
    paddingHorizontal: 16, paddingVertical: 10,
  },
  selfieRetakeBtnText: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.text },
  selfieInstructions: {
    width: '100%', backgroundColor: COLORS.card,
    borderRadius: RADIUS.lg, borderWidth: 1, borderColor: COLORS.border, padding: SPACING.lg, gap: 12,
  },
  selfieStep: { flexDirection: 'row', alignItems: 'center', gap: 14 },
  selfieStepEmoji: { fontSize: 20, width: 32, textAlign: 'center' },
  selfieStepText:  { fontFamily: FONTS.body, fontSize: 14, color: COLORS.muted2, flex: 1 },
  selfieNote: {
    fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted,
    textAlign: 'center', lineHeight: 16,
  },

  // Benefits
  benefitsCard: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border, padding: SPACING.lg,
  },
  benefitsTitle: { fontFamily: FONTS.title, fontSize: 16, color: COLORS.text, marginBottom: 16 },
  benefitRow: { flexDirection: 'row', alignItems: 'center', gap: 14, marginBottom: 16 },
  benefitIcon: { width: 42, height: 42, borderRadius: 12, borderWidth: 1, alignItems: 'center', justifyContent: 'center' },
  benefitTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.text, marginBottom: 2 },
  benefitDesc:  { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2 },

  // Actions
  actionSection: { marginTop: 4, gap: 10 },
  actionHint: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted, textAlign: 'center' },
  pendingBanner: {
    flexDirection: 'row', alignItems: 'center', gap: 14,
    backgroundColor: 'rgba(255,152,0,0.06)', borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: 'rgba(255,152,0,0.3)', padding: SPACING.lg,
  },
  pendingTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.orange, marginBottom: 4 },
  pendingDesc:  { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2, lineHeight: 20 },
});
