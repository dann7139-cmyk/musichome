/**
 * ClientVerificationScreen
 *
 * Rol cliente  → formulario de datos personales + envío de solicitud.
 * Rol talento  → flujo KYC completo: checklist + documento + selfie + envío,
 *                equivalente al GroupVerificationScreen.
 *
 * Columnas de profiles usadas:
 *   id_document_url  — path del documento en verification-docs
 *   selfie_url       — path de la selfie en verification-docs
 *   verification_status, verification_submitted_at, verification_admin_notes
 */
import {
  ArrowLeft,
  Award,
  Camera,
  CheckCircle,
  Clock,
  FileText,
  IdCard,
  MapPin,
  Phone,
  Shield,
  ShieldCheck,
  Upload,
  User,
  XCircle,
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

// ─── Pasos del flujo talento ──────────────────────────────────────────────────

const TALENT_STEPS = [
  { key: 'profile',  icon: User,       label: 'Perfil' },
  { key: 'document', icon: Upload,     label: 'Documento' },
  { key: 'selfie',   icon: Camera,     label: 'Foto' },
  { key: 'review',   icon: Award,      label: 'Revisión' },
  { key: 'approved', icon: ShieldCheck, label: 'Aprobado' },
];

// ─── Pantalla principal ────────────────────────────────────────────────────────

export default function ClientVerificationScreen({ navigation }: any) {
  const [profile,     setProfile]     = useState<any>(null);
  const [loading,     setLoading]     = useState(false);
  const [submitting,  setSubmitting]  = useState(false);

  // Formulario (clientes y talentos)
  const [fullName, setFullName] = useState('');
  const [phone,    setPhone]    = useState('');
  const [city,     setCity]     = useState('');
  const [stateTxt, setStateTxt] = useState('');

  // KYC talento
  const [activeKycStep,   setActiveKycStep]   = useState<'document' | 'selfie' | null>(null);
  const [docUri,          setDocUri]          = useState<string | null>(null);
  const [docUploading,    setDocUploading]    = useState(false);
  const [docUploaded,     setDocUploaded]     = useState(false);
  const [selfieUri,       setSelfieUri]       = useState<string | null>(null);
  const [selfieUploading, setSelfieUploading] = useState(false);
  const [selfieComplete,  setSelfieComplete]  = useState(false);

  // Animations
  const pulseAnim  = useRef(new Animated.Value(1)).current;
  const glowAnim   = useRef(new Animated.Value(0.3)).current;
  const rotateAnim = useRef(new Animated.Value(0)).current;

  useEffect(() => { fetchProfile(); }, []);

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
    if (profile?.verification_status === 'approved') {
      Animated.loop(
        Animated.timing(rotateAnim, { toValue: 1, duration: 8000, easing: Easing.linear, useNativeDriver: true })
      ).start();
    }
  }, [profile?.verification_status]);

  const spin = rotateAnim.interpolate({ inputRange: [0, 1], outputRange: ['0deg', '360deg'] });

  const fetchProfile = async () => {
    setLoading(true);
    const { data: sessionData } = await supabase.auth.getSession();
    if (!sessionData.session) { setLoading(false); return; }
    const { data: prof } = await supabase
      .from('profiles').select('*').eq('id', sessionData.session.user.id).single();
    if (prof) {
      setProfile(prof);
      setFullName(prof.full_name ?? '');
      setPhone(prof.phone ?? '');
      setCity(prof.city ?? '');
      setStateTxt(prof.state ?? '');
      // Pre-cargar estado KYC solo si el status actual NO es rejected
      // (si fue rechazado, se permite re-subir desde cero)
      if (prof.verification_status !== 'rejected') {
        if (prof.id_document_url) setDocUploaded(true);
        if (prof.selfie_url)      setSelfieComplete(true);
      }
    }
    setLoading(false);
  };

  const isTalent   = profile?.role === 'talent';
  const currentStatus = profile?.verification_status ?? 'none';
  const isApproved = currentStatus === 'approved';
  const isPending  = currentStatus === 'pending';
  const isRejected = currentStatus === 'rejected';
  const heroColor  = isApproved ? COLORS.blue : isPending ? COLORS.orange : isRejected ? COLORS.red : COLORS.green;

  // ─── Progreso de pasos (talento) ─────────────────────────────────────────────

  const getTalentCompletionStep = () => {
    if (!fullName.trim() || !city.trim()) return 0;
    if (!docUploaded) return 1;
    if (!selfieComplete) return 2;
    if (currentStatus === 'none' || currentStatus === 'rejected') return 3;
    if (currentStatus === 'pending') return 4;
    return 5;
  };
  const talentCompletionStep = getTalentCompletionStep();

  // ─── Guardar datos básicos del perfil ────────────────────────────────────────

  const handleSaveInfo = async () => {
    if (!fullName.trim() || !city.trim() || !stateTxt.trim()) {
      Alert.alert('Campos requeridos', 'Completa nombre, ciudad y estado.');
      return;
    }
    setSubmitting(true);
    const { data: sessionData } = await supabase.auth.getSession();
    if (!sessionData.session) { setSubmitting(false); return; }
    const { error } = await supabase.from('profiles').update({
      full_name: fullName.trim(),
      phone: phone.trim() || null,
      city: city.trim(),
      state: stateTxt.trim(),
    }).eq('id', sessionData.session.user.id);
    setSubmitting(false);
    if (error) {
      Alert.alert('Error', error.message);
    } else {
      setProfile((prev: any) => ({ ...prev, full_name: fullName.trim(), phone: phone.trim() || null, city: city.trim(), state: stateTxt.trim() }));
      Alert.alert('✓ Guardado', 'Información actualizada.');
    }
  };

  // ─── KYC Talento: documento ──────────────────────────────────────────────────

  const handlePickDocument = () => {
    Alert.alert('Subir documento', 'Elige cómo agregar tu identificación oficial.', [
      {
        text: 'Tomar foto',
        onPress: async () => {
          const { status } = await ImagePicker.requestCameraPermissionsAsync();
          if (status !== 'granted') {
            Alert.alert('Permiso denegado', 'Necesitamos acceso a la cámara.');
            return;
          }
          const result = await ImagePicker.launchCameraAsync({ mediaTypes: ['images'], allowsEditing: true, quality: 0.85 });
          if (!result.canceled && result.assets?.length) setDocUri(result.assets[0].uri);
        },
      },
      {
        text: 'Elegir de galería',
        onPress: async () => {
          const { status } = await ImagePicker.requestMediaLibraryPermissionsAsync();
          if (status !== 'granted') {
            Alert.alert('Permiso denegado', 'Necesitamos acceso a la galería.');
            return;
          }
          const result = await ImagePicker.launchImageLibraryAsync({ mediaTypes: ['images'], allowsEditing: true, quality: 0.85 });
          if (!result.canceled && result.assets?.length) setDocUri(result.assets[0].uri);
        },
      },
      { text: 'Cancelar', style: 'cancel' },
    ]);
  };

  const handleUploadDocument = async () => {
    if (!docUri || !profile) return;
    setDocUploading(true);
    try {
      const { data: sessionData } = await supabase.auth.getSession();
      if (!sessionData.session) return;
      const ext         = docUri.split('.').pop()?.toLowerCase() ?? 'jpg';
      const storagePath = `kyc_talent_${profile.id}_${Date.now()}.${ext}`;
      const response    = await fetch(docUri);
      const blob        = await response.blob();
      const { error: upErr } = await supabase.storage
        .from('verification-docs')
        .upload(storagePath, blob, { contentType: `image/${ext}`, upsert: true });
      if (upErr) throw upErr;
      const { error: dbErr } = await supabase.from('profiles')
        .update({ id_document_url: storagePath })
        .eq('id', sessionData.session.user.id);
      if (dbErr) throw dbErr;
      setDocUploaded(true);
      setActiveKycStep(null);
      Alert.alert('✅ Documento subido', 'Ahora toma tu foto de verificación.');
    } catch (e: any) {
      Alert.alert('Error', e.message ?? 'No se pudo subir el documento.');
    } finally {
      setDocUploading(false);
    }
  };

  // ─── KYC Talento: selfie ─────────────────────────────────────────────────────

  const handleTakeSelfie = async () => {
    const { status } = await ImagePicker.requestCameraPermissionsAsync();
    if (status !== 'granted') {
      Alert.alert('Permiso denegado', 'Necesitamos acceso a la cámara frontal.');
      return;
    }
    const result = await ImagePicker.launchCameraAsync({
      mediaTypes: ['images'],
      cameraType: ImagePicker.CameraType.front,
      allowsEditing: true,
      aspect: [1, 1],
      quality: 0.85,
    });
    if (!result.canceled && result.assets?.length) setSelfieUri(result.assets[0].uri);
  };

  const handleConfirmSelfie = async () => {
    if (!selfieUri || !profile) return;
    setSelfieUploading(true);
    try {
      const { data: sessionData } = await supabase.auth.getSession();
      if (!sessionData.session) return;
      const ext         = selfieUri.split('.').pop()?.toLowerCase() ?? 'jpg';
      const storagePath = `selfie_talent_${profile.id}_${Date.now()}.${ext}`;
      const response    = await fetch(selfieUri);
      const blob        = await response.blob();
      const { error: upErr } = await supabase.storage
        .from('verification-docs')
        .upload(storagePath, blob, { contentType: `image/${ext}`, upsert: true });
      if (upErr) throw upErr;
      const { error: dbErr } = await supabase.from('profiles')
        .update({ selfie_url: storagePath })
        .eq('id', sessionData.session.user.id);
      if (dbErr) throw dbErr;
      setSelfieComplete(true);
      setActiveKycStep(null);
      Alert.alert('✅ Foto enviada', '¡Perfecto! Ahora puedes enviar tu solicitud.');
    } catch (e: any) {
      Alert.alert('Error', e.message ?? 'No se pudo subir la foto.');
    } finally {
      setSelfieUploading(false);
    }
  };

  // ─── Enviar solicitud ────────────────────────────────────────────────────────

  const handleSubmitVerification = async () => {
    if (!fullName.trim() || !phone.trim() || !city.trim() || !stateTxt.trim()) {
      Alert.alert('Completa tu información', 'Necesitas nombre, teléfono, ciudad y estado para solicitar verificación.');
      return;
    }
    if (isTalent && !docUploaded) {
      Alert.alert('Documento requerido', 'Sube tu INE o pasaporte antes de continuar.');
      setActiveKycStep('document');
      return;
    }
    if (isTalent && !selfieComplete) {
      Alert.alert('Foto requerida', 'Toma tu foto de verificación antes de enviar.');
      setActiveKycStep('selfie');
      return;
    }

    Alert.alert(
      'Solicitar verificación',
      'Se enviará tu solicitud al equipo de Daricefy. Revisaremos tu perfil en 1-3 días hábiles.',
      [
        { text: 'Cancelar', style: 'cancel' },
        {
          text: 'Enviar solicitud',
          onPress: async () => {
            setSubmitting(true);
            const { data: sessionData } = await supabase.auth.getSession();
            if (!sessionData.session) { setSubmitting(false); return; }
            const { error } = await supabase.from('profiles').update({
              full_name: fullName.trim(),
              phone: phone.trim(),
              city: city.trim(),
              state: stateTxt.trim(),
              verification_status: 'pending',
              verification_submitted_at: new Date().toISOString(),
            }).eq('id', sessionData.session.user.id);

            // Notificar a admins
            const { data: admins } = await supabase
              .from('profiles').select('id').eq('role', 'admin');
            if (admins?.length) {
              const roleLabel = isTalent ? 'talento' : 'cliente';
              await supabase.from('notifications').insert(
                admins.map((a: any) => ({
                  user_id: a.id,
                  type: 'verification',
                  title: `📋 Nueva verificación de ${roleLabel}`,
                  message: `${fullName.trim()} de ${city.trim()}, ${stateTxt.trim()} solicita verificación.`,
                }))
              );
            }

            setSubmitting(false);
            if (error) {
              Alert.alert('Error', error.message);
            } else {
              setProfile((prev: any) => ({ ...prev, verification_status: 'pending' }));
              Alert.alert('¡Solicitud enviada! 🎉', 'Te notificaremos cuando tu verificación sea revisada.');
            }
          },
        },
      ]
    );
  };

  // ════════════════════════════════════════════════════════════════════════════
  // RENDER TALENTO — Sub-pantalla: documento
  // ════════════════════════════════════════════════════════════════════════════

  if (isTalent && activeKycStep === 'document') {
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
                {['Foto nítida, sin reflejos', 'Todos los datos visibles', 'Documento vigente', 'JPG o PNG (máx. 5 MB)'].map((tip, i) => (
                  <View key={i} style={styles.docTipRow}>
                    <CheckCircle size={14} color={COLORS.green} />
                    <Text style={styles.docTipText}>{tip}</Text>
                  </View>
                ))}
              </View>
            </View>
            <View style={{ marginTop: 16, marginBottom: 32 }}>
              <Button label="Subir documento" onPress={handleUploadDocument} loading={docUploading} disabled={!docUri} size="lg" />
            </View>
          </ScrollView>
        </SafeAreaView>
      </View>
    );
  }

  // ════════════════════════════════════════════════════════════════════════════
  // RENDER TALENTO — Sub-pantalla: selfie
  // ════════════════════════════════════════════════════════════════════════════

  if (isTalent && activeKycStep === 'selfie') {
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
              <Text style={styles.selfieInfoDesc}>Asegúrate de estar en un lugar bien iluminado. Tu rostro debe estar centrado y visible.</Text>
            </View>
            {selfieUri ? (
              <View style={styles.selfiePreviewWrap}>
                <Image source={{ uri: selfieUri }} style={styles.selfiePreview} resizeMode="cover" />
                <Pressable style={styles.selfieRetakeBtn} onPress={() => setSelfieUri(null)}>
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
              ].map((s, i) => (
                <View key={i} style={styles.selfieStep}>
                  <Text style={styles.selfieStepEmoji}>{s.icon}</Text>
                  <Text style={styles.selfieStepText}>{s.text}</Text>
                </View>
              ))}
            </View>
            <View style={{ width: '100%', gap: 12, marginTop: 16, marginBottom: 32 }}>
              {!selfieUri && <Button label="📷 Abrir cámara frontal" onPress={handleTakeSelfie} size="lg" />}
              {selfieUri  && <Button label="✅ Confirmar foto" onPress={handleConfirmSelfie} loading={selfieUploading} size="lg" />}
              <Text style={styles.selfieNote}>Esta foto se usa solo para verificar tu identidad y no se comparte con terceros.</Text>
            </View>
          </ScrollView>
        </SafeAreaView>
      </View>
    );
  }

  // ════════════════════════════════════════════════════════════════════════════
  // RENDER PRINCIPAL
  // ════════════════════════════════════════════════════════════════════════════

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

          {/* ── HERO STATUS ────────────────────────────────────────────────── */}
          <View style={styles.heroCard}>
            <View style={styles.heroIconContainer}>
              <Animated.View style={[styles.heroGlowRing, { opacity: glowAnim, transform: [{ scale: pulseAnim }], borderColor: heroColor, shadowColor: heroColor }]} />
              <Animated.View style={[styles.heroGlowRing2, { opacity: Animated.multiply(glowAnim, 0.5), transform: [{ scale: Animated.multiply(pulseAnim, 1.15) }], borderColor: heroColor }]} />
              <Animated.View style={[
                styles.heroIconRing,
                isApproved && styles.heroIconApproved,
                isPending  && styles.heroIconPending,
                isRejected && styles.heroIconRejected,
                isApproved && { transform: [{ rotate: spin }] },
              ]}>
                {isApproved ? <ShieldCheck size={38} color={COLORS.blue} />
                  : isPending  ? <Clock size={38} color={COLORS.orange} />
                  : isRejected ? <XCircle size={38} color={COLORS.red} />
                  : <Shield size={38} color={COLORS.green} />}
              </Animated.View>
            </View>
            <Text style={styles.heroTitle}>
              {isApproved ? '¡Estás verificado!'
                : isPending  ? 'En revisión'
                : isRejected ? 'Solicitud rechazada'
                : isTalent   ? 'Obtén la verificación'
                : 'Verifica tu identidad'}
            </Text>
            <Text style={styles.heroSubtitle}>
              {isApproved
                ? (isTalent ? 'Tu perfil tiene la insignia verificada. Los grupos confían más en ti.' : 'Los grupos pueden ver que eres un cliente confiable.')
                : isPending  ? 'Tu solicitud está siendo revisada. Te notificaremos pronto.'
                : isRejected ? 'Tu solicitud fue rechazada. Revisa el motivo y vuelve a intentarlo.'
                : isTalent   ? 'Completa los pasos para obtener el badge de verificado.'
                : 'Completa tu perfil para que los grupos confíen en ti.'}
            </Text>

            {/* Progress steps — solo talentos */}
            {isTalent && (
              <View style={styles.stepsRow}>
                {TALENT_STEPS.map((step, i) => {
                  const done   = i < talentCompletionStep;
                  const active = i === talentCompletionStep;
                  const IconComp = step.icon;
                  return (
                    <View key={step.key} style={styles.stepItem}>
                      <View style={[styles.stepCircle, done && styles.stepDone, active && styles.stepActive]}>
                        {done ? <CheckCircle size={14} color={COLORS.bg} /> : <IconComp size={13} color={active ? COLORS.green : COLORS.muted} />}
                      </View>
                      <Text style={[styles.stepLabel, done && styles.stepLabelDone, active && styles.stepLabelActive]}>{step.label}</Text>
                      {i < TALENT_STEPS.length - 1 && <View style={[styles.stepLine, done && styles.stepLineDone]} />}
                    </View>
                  );
                })}
              </View>
            )}
          </View>

          {/* ── RECHAZADO ─────────────────────────────────────────────────── */}
          {isRejected && (
            <View style={styles.rejectedCard}>
              <View style={styles.rejectedHeader}>
                <XCircle size={18} color={COLORS.red} />
                <Text style={styles.rejectedTitle}>Solicitud rechazada</Text>
              </View>
              <Text style={styles.rejectedNotes}>
                {profile?.verification_admin_notes ?? 'El equipo revisó tu solicitud y no fue aprobada en esta ocasión.'}
              </Text>
              <Text style={styles.rejectedHint}>Corrige la información y vuelve a intentarlo.</Text>
            </View>
          )}

          {/* ── APROBADO ──────────────────────────────────────────────────── */}
          {isApproved && (
            <View style={styles.approvedCard}>
              <ShieldCheck size={22} color={COLORS.blue} />
              <View style={{ flex: 1 }}>
                <Text style={styles.approvedTitle}>Identidad verificada</Text>
                <Text style={styles.approvedDesc}>
                  {isTalent
                    ? 'Tu perfil muestra la insignia de verificación. Los grupos pueden contratarte con confianza.'
                    : 'Tu perfil muestra la insignia de verificación. Los grupos pueden ver tu información con confianza.'}
                </Text>
              </View>
            </View>
          )}

          {/* ── FORMULARIO DE DATOS ───────────────────────────────────────── */}
          {!isApproved && (
            <View style={styles.formCard}>
              <View style={styles.formCardHeader}>
                <User size={16} color={COLORS.green} />
                <Text style={styles.formCardTitle}>Datos personales</Text>
              </View>

              <Text style={styles.inputLabel}>Nombre completo</Text>
              <TextInput style={styles.input} value={fullName} onChangeText={setFullName}
                placeholder="Tu nombre completo" placeholderTextColor={COLORS.muted}
                autoCapitalize="words" editable={!isPending} />

              <Text style={styles.inputLabel}>Teléfono</Text>
              <TextInput style={styles.input} value={phone} onChangeText={setPhone}
                placeholder="Ej: 3312345678" placeholderTextColor={COLORS.muted}
                keyboardType="phone-pad" editable={!isPending} />

              <View style={styles.twoCol}>
                <View style={{ flex: 1 }}>
                  <Text style={styles.inputLabel}>Ciudad</Text>
                  <TextInput style={styles.input} value={city} onChangeText={setCity}
                    placeholder="Ej: Guadalajara" placeholderTextColor={COLORS.muted}
                    autoCapitalize="words" editable={!isPending} />
                </View>
                <View style={{ flex: 1 }}>
                  <Text style={styles.inputLabel}>Estado</Text>
                  <TextInput style={styles.input} value={stateTxt} onChangeText={setStateTxt}
                    placeholder="Ej: Jalisco" placeholderTextColor={COLORS.muted}
                    autoCapitalize="words" editable={!isPending} />
                </View>
              </View>

              {!isPending && (
                <Pressable style={styles.saveInfoBtn} onPress={handleSaveInfo} disabled={submitting}>
                  <Text style={styles.saveInfoText}>{submitting ? 'Guardando...' : 'Guardar información'}</Text>
                </Pressable>
              )}
            </View>
          )}

          {/* ── PASOS KYC (solo talento) ──────────────────────────────────── */}
          {isTalent && !isApproved && (
            <View style={styles.kycCard}>
              <Text style={styles.kycCardTitle}>Verificación de identidad</Text>
              <Text style={styles.kycDesc}>
                Solicitamos una identificación oficial y una fotografía facial para proteger a todos en la plataforma.
                Esta información se usa exclusivamente para verificar identidades, prevenir fraudes y suplantaciones,
                y proporcionar respaldo en caso de disputas o incidentes. Tus documentos se almacenan cifrados
                y nunca se comparten con terceros.
              </Text>

              {/* Documento */}
              <Pressable
                style={[styles.kycStep, docUploaded && styles.kycStepDone]}
                onPress={() => !docUploaded && setActiveKycStep('document')}
                disabled={isPending}
              >
                <View style={[styles.kycStepIcon, docUploaded && styles.kycStepIconDone]}>
                  {docUploaded ? <CheckCircle size={20} color={COLORS.bg} /> : <FileText size={20} color={COLORS.green} />}
                </View>
                <View style={{ flex: 1 }}>
                  <Text style={styles.kycStepTitle}>{docUploaded ? '✅ Documento subido' : 'Subir INE / Pasaporte'}</Text>
                  <Text style={styles.kycStepDesc}>{docUploaded ? 'Tu documento fue cargado.' : 'Toma foto o elige de galería.'}</Text>
                </View>
                {!docUploaded && !isPending && <Text style={styles.kycChevron}>→</Text>}
              </Pressable>

              {/* Selfie */}
              <Pressable
                style={[styles.kycStep, selfieComplete && styles.kycStepDone]}
                onPress={() => !selfieComplete && setActiveKycStep('selfie')}
                disabled={isPending}
              >
                <View style={[styles.kycStepIcon, selfieComplete && styles.kycStepIconDone, !selfieComplete && { backgroundColor: 'rgba(66,133,244,0.1)', borderColor: 'rgba(66,133,244,0.3)' }]}>
                  {selfieComplete ? <CheckCircle size={20} color={COLORS.bg} /> : <Camera size={20} color={COLORS.blue} />}
                </View>
                <View style={{ flex: 1 }}>
                  <Text style={styles.kycStepTitle}>{selfieComplete ? '✅ Foto enviada' : 'Foto de verificación'}</Text>
                  <Text style={styles.kycStepDesc}>{selfieComplete ? 'Tu foto de identidad fue registrada.' : 'Selfie con cámara frontal.'}</Text>
                </View>
                {!selfieComplete && !isPending && <Text style={styles.kycChevron}>→</Text>}
              </Pressable>

              <View style={styles.kycSecurityNote}>
                <Text style={styles.kycSecurityText}>🔐 Tu información está protegida con encriptación. Nunca compartimos tus documentos.</Text>
              </View>
            </View>
          )}

          {/* ── BENEFICIOS (cliente simple) ───────────────────────────────── */}
          {!isTalent && (
            <View style={styles.benefitsCard}>
              <Text style={styles.benefitsTitle}>¿Por qué verificarte?</Text>
              {[
                { icon: '🛡️', title: 'Confianza',          desc: 'Los grupos aceptarán tus reservas más rápido' },
                { icon: '⭐', title: 'Prioridad',           desc: 'Aparecerás como cliente verificado' },
                { icon: '🔒', title: 'Seguridad',           desc: 'Protege tu cuenta con información real' },
                { icon: '🎵', title: 'Mejor experiencia',   desc: 'Accede a funciones exclusivas' },
              ].map((b, i) => (
                <View key={i} style={styles.benefitRow}>
                  <View style={styles.benefitIcon}><Text style={{ fontSize: 18 }}>{b.icon}</Text></View>
                  <View style={{ flex: 1 }}>
                    <Text style={styles.benefitTitle}>{b.title}</Text>
                    <Text style={styles.benefitDesc}>{b.desc}</Text>
                  </View>
                </View>
              ))}
            </View>
          )}

          {/* ── ACCIÓN ────────────────────────────────────────────────────── */}
          {(currentStatus === 'none' || currentStatus === 'rejected') && (
            <View style={styles.submitSection}>
              <Button label="🛡️ Solicitar verificación" onPress={handleSubmitVerification} loading={submitting} size="lg" />
              <Text style={styles.submitHint}>Revisaremos tu solicitud en 1-3 días hábiles</Text>
            </View>
          )}

          {isPending && (
            <View style={styles.pendingBanner}>
              <Clock size={20} color={COLORS.orange} />
              <View style={{ flex: 1 }}>
                <Text style={styles.pendingTitle}>Solicitud en proceso</Text>
                <Text style={styles.pendingDesc}>Nuestro equipo está revisando tu información. Te notificaremos cuando esté listo.</Text>
              </View>
            </View>
          )}

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
  heroCard: { backgroundColor: COLORS.card, borderRadius: RADIUS.xl, borderWidth: 1, borderColor: COLORS.border, padding: SPACING.xl, alignItems: 'center' },
  heroIconContainer: { width: 120, height: 120, alignItems: 'center', justifyContent: 'center', marginBottom: 16 },
  heroGlowRing:  { position: 'absolute', width: 110, height: 110, borderRadius: 55, borderWidth: 1.5, backgroundColor: 'transparent', shadowOffset: { width: 0, height: 0 }, shadowOpacity: 0.6, shadowRadius: 20 },
  heroGlowRing2: { position: 'absolute', width: 120, height: 120, borderRadius: 60, borderWidth: 1, backgroundColor: 'transparent' },
  heroIconRing:  { width: 84, height: 84, borderRadius: 42, backgroundColor: 'rgba(0,230,118,0.1)', borderWidth: 2, borderColor: 'rgba(0,230,118,0.35)', alignItems: 'center', justifyContent: 'center' },
  heroIconApproved: { backgroundColor: 'rgba(66,133,244,0.1)', borderColor: 'rgba(66,133,244,0.35)' },
  heroIconPending:  { backgroundColor: 'rgba(255,152,0,0.1)',  borderColor: 'rgba(255,152,0,0.35)'  },
  heroIconRejected: { backgroundColor: 'rgba(239,83,80,0.1)',  borderColor: 'rgba(239,83,80,0.35)'  },
  heroTitle:    { fontFamily: FONTS.title, fontSize: 22, color: COLORS.text, marginBottom: 8, textAlign: 'center' },
  heroSubtitle: { fontFamily: FONTS.body, fontSize: 14, color: COLORS.muted2, textAlign: 'center', lineHeight: 22, marginBottom: 16 },

  // Progress steps
  stepsRow:  { flexDirection: 'row', alignItems: 'flex-start', justifyContent: 'center', width: '100%', marginTop: 8 },
  stepItem:  { alignItems: 'center', flex: 1, position: 'relative' },
  stepCircle:{ width: 30, height: 30, borderRadius: 15, backgroundColor: COLORS.card2, borderWidth: 1.5, borderColor: COLORS.border, alignItems: 'center', justifyContent: 'center', marginBottom: 6 },
  stepDone:  { backgroundColor: COLORS.green, borderColor: COLORS.green },
  stepActive:{ borderColor: COLORS.green, backgroundColor: 'rgba(0,230,118,0.12)' },
  stepLabel:      { fontFamily: FONTS.body, fontSize: 9, color: COLORS.muted, textAlign: 'center' },
  stepLabelDone:  { color: COLORS.green },
  stepLabelActive:{ color: COLORS.text, fontFamily: FONTS.bodyMedium },
  stepLine:    { position: 'absolute', top: 15, left: '60%', right: '-40%', height: 1.5, backgroundColor: COLORS.border },
  stepLineDone:{ backgroundColor: COLORS.green },

  // Rejected / Approved
  rejectedCard:  { backgroundColor: 'rgba(239,83,80,0.06)', borderRadius: RADIUS.lg, borderWidth: 1, borderColor: 'rgba(239,83,80,0.3)', padding: SPACING.lg },
  rejectedHeader:{ flexDirection: 'row', alignItems: 'center', gap: 8, marginBottom: 8 },
  rejectedTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.red },
  rejectedNotes: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.text, marginBottom: 6, lineHeight: 20 },
  rejectedHint:  { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2 },
  approvedCard:  { flexDirection: 'row', alignItems: 'center', gap: 14, backgroundColor: 'rgba(66,133,244,0.06)', borderRadius: RADIUS.lg, borderWidth: 1, borderColor: 'rgba(66,133,244,0.3)', padding: SPACING.lg },
  approvedTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.blue, marginBottom: 4 },
  approvedDesc:  { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2, lineHeight: 20 },

  // Form
  formCard:      { backgroundColor: COLORS.card, borderRadius: RADIUS.lg, borderWidth: 1, borderColor: COLORS.border, padding: SPACING.lg },
  formCardHeader:{ flexDirection: 'row', alignItems: 'center', gap: 8, marginBottom: 16 },
  formCardTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.text },
  inputLabel:    { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.muted2, marginBottom: 6, marginTop: 4 },
  input: {
    backgroundColor: COLORS.bg, borderRadius: RADIUS.md, borderWidth: 1, borderColor: COLORS.border,
    paddingHorizontal: 14, paddingVertical: 12, fontFamily: FONTS.body, fontSize: 14, color: COLORS.text, marginBottom: 4,
  },
  twoCol:       { flexDirection: 'row', gap: 12 },
  saveInfoBtn:  { backgroundColor: COLORS.card2, borderRadius: RADIUS.md, borderWidth: 1, borderColor: COLORS.border, paddingVertical: 12, alignItems: 'center', marginTop: 12 },
  saveInfoText: { fontFamily: FONTS.bodyMedium, fontSize: 14, color: COLORS.text },

  // KYC Talento
  kycCard:         { backgroundColor: COLORS.card, borderRadius: RADIUS.lg, borderWidth: 1, borderColor: COLORS.border, padding: SPACING.lg },
  kycCardTitle:    { fontFamily: FONTS.title, fontSize: 16, color: COLORS.text, marginBottom: 10 },
  kycDesc:         { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2, lineHeight: 20, marginBottom: 16 },
  kycStep:         { flexDirection: 'row', alignItems: 'center', gap: 14, backgroundColor: COLORS.card2, borderRadius: RADIUS.md, borderWidth: 1, borderColor: COLORS.border, padding: SPACING.lg, marginBottom: 12 },
  kycStepDone:     { borderColor: COLORS.green, backgroundColor: 'rgba(0,230,118,0.06)' },
  kycStepIcon:     { width: 44, height: 44, borderRadius: 12, backgroundColor: 'rgba(0,230,118,0.1)', borderWidth: 1, borderColor: 'rgba(0,230,118,0.3)', alignItems: 'center', justifyContent: 'center' },
  kycStepIconDone: { backgroundColor: COLORS.green, borderColor: COLORS.green },
  kycStepTitle:    { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.text, marginBottom: 3 },
  kycStepDesc:     { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2 },
  kycChevron:      { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.muted2 },
  kycSecurityNote: { backgroundColor: 'rgba(0,230,118,0.04)', borderRadius: RADIUS.md, borderWidth: 1, borderColor: 'rgba(0,230,118,0.15)', padding: 12, marginTop: 4 },
  kycSecurityText: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, lineHeight: 18 },

  // Document step
  docCard:     { backgroundColor: COLORS.card, borderRadius: RADIUS.xl, borderWidth: 1, borderColor: COLORS.border, padding: SPACING.xl, alignItems: 'center' },
  docIconBox:  { width: 72, height: 72, borderRadius: 20, backgroundColor: 'rgba(0,230,118,0.1)', borderWidth: 1.5, borderColor: 'rgba(0,230,118,0.3)', alignItems: 'center', justifyContent: 'center', marginBottom: 16 },
  docTitle:    { fontFamily: FONTS.title, fontSize: 20, color: COLORS.text, marginBottom: 10, textAlign: 'center' },
  docDesc:     { fontFamily: FONTS.body, fontSize: 14, color: COLORS.muted2, textAlign: 'center', lineHeight: 22, marginBottom: 20 },
  docPickBtn:  { flexDirection: 'row', alignItems: 'center', gap: 12, backgroundColor: COLORS.greenMuted, borderRadius: RADIUS.lg, borderWidth: 1.5, borderColor: COLORS.green, paddingHorizontal: 24, paddingVertical: 16, marginBottom: 20, width: '100%', justifyContent: 'center' },
  docPickBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.green },
  docPreviewWrap: { width: '100%', marginBottom: 20, alignItems: 'center' },
  docPreview:     { width: '100%', height: 180, borderRadius: RADIUS.lg, marginBottom: 10 },
  docChangeBtn:   { paddingHorizontal: 16, paddingVertical: 8 },
  docChangeBtnText: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted2 },
  docTips:    { gap: 10, width: '100%' },
  docTipRow:  { flexDirection: 'row', alignItems: 'center', gap: 10 },
  docTipText: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2, flex: 1 },

  // Selfie step
  selfieInfoBox:        { width: '100%', backgroundColor: 'rgba(66,133,244,0.06)', borderRadius: RADIUS.lg, borderWidth: 1, borderColor: 'rgba(66,133,244,0.25)', padding: SPACING.lg, alignItems: 'center', gap: 10 },
  selfieInfoTitle:      { fontFamily: FONTS.bodySemiBold, fontSize: 16, color: COLORS.text },
  selfieInfoDesc:       { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2, textAlign: 'center', lineHeight: 20 },
  selfiePlaceholder:    { width: 200, height: 200, borderRadius: 100, backgroundColor: COLORS.card2, borderWidth: 2, borderColor: COLORS.border, alignItems: 'center', justifyContent: 'center', gap: 12, marginVertical: 24 },
  selfiePlaceholderText:{ fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted, textAlign: 'center', paddingHorizontal: 20 },
  selfiePreviewWrap:    { alignItems: 'center', marginVertical: 24, gap: 12 },
  selfiePreview:        { width: 200, height: 200, borderRadius: 100, borderWidth: 3, borderColor: COLORS.green },
  selfieRetakeBtn:      { flexDirection: 'row', alignItems: 'center', gap: 8, backgroundColor: COLORS.card2, borderRadius: RADIUS.md, borderWidth: 1, borderColor: COLORS.border, paddingHorizontal: 16, paddingVertical: 10 },
  selfieRetakeBtnText:  { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.text },
  selfieInstructions:   { width: '100%', backgroundColor: COLORS.card, borderRadius: RADIUS.lg, borderWidth: 1, borderColor: COLORS.border, padding: SPACING.lg, gap: 12 },
  selfieStep:           { flexDirection: 'row', alignItems: 'center', gap: 14 },
  selfieStepEmoji:      { fontSize: 20, width: 32, textAlign: 'center' },
  selfieStepText:       { fontFamily: FONTS.body, fontSize: 14, color: COLORS.muted2, flex: 1 },
  selfieNote:           { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted, textAlign: 'center', lineHeight: 16 },

  // Benefits (cliente)
  benefitsCard:  { backgroundColor: COLORS.card, borderRadius: RADIUS.lg, borderWidth: 1, borderColor: COLORS.border, padding: SPACING.lg },
  benefitsTitle: { fontFamily: FONTS.title, fontSize: 16, color: COLORS.text, marginBottom: 16 },
  benefitRow:    { flexDirection: 'row', alignItems: 'center', gap: 14, marginBottom: 16 },
  benefitIcon:   { width: 42, height: 42, borderRadius: 12, backgroundColor: COLORS.card2, borderWidth: 1, borderColor: COLORS.border, alignItems: 'center', justifyContent: 'center' },
  benefitTitle:  { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.text, marginBottom: 2 },
  benefitDesc:   { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2 },

  // Submit / Pending
  submitSection: { marginTop: 4, gap: 10 },
  submitHint:    { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted, textAlign: 'center' },
  pendingBanner: { flexDirection: 'row', alignItems: 'center', gap: 14, backgroundColor: 'rgba(255,152,0,0.06)', borderRadius: RADIUS.lg, borderWidth: 1, borderColor: 'rgba(255,152,0,0.3)', padding: SPACING.lg },
  pendingTitle:  { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.orange, marginBottom: 4 },
  pendingDesc:   { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2, lineHeight: 20 },
});
