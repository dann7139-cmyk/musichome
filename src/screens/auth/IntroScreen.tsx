import { LinearGradient } from 'expo-linear-gradient';
import { Lock, Mail } from 'lucide-react-native';
import * as WebBrowser from 'expo-web-browser';
import Constants from 'expo-constants';
import React, { useEffect, useRef, useState } from 'react';
import {
  Alert,
  Animated,
  Easing,
  Image,
  KeyboardAvoidingView,
  Platform,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { useTranslation } from 'react-i18next';
import { supabase } from '../../config/supabase';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';
import Button from '../../components/ui/Button';
import Input from '../../components/ui/Input';

export default function IntroScreen({ navigation }: any) {
  const { t } = useTranslation();
  const [email,    setEmail]    = useState('');
  const [password, setPassword] = useState('');
  const [loading,  setLoading]  = useState(false);
  const [googleLoading, setGoogleLoading] = useState(false);

  // ── Animated refs ────────────────────────────────────────────────────────────
  const bgOpacity   = useRef(new Animated.Value(0)).current;
  const logoOpacity = useRef(new Animated.Value(0)).current;
  const logoScale   = useRef(new Animated.Value(1.35)).current;
  const taglinesOp  = useRef(new Animated.Value(0)).current;
  const taglinesY   = useRef(new Animated.Value(14)).current;
  const formOp      = useRef(new Animated.Value(0)).current;
  const formY       = useRef(new Animated.Value(32)).current;
  const rotateAnim  = useRef(new Animated.Value(0)).current;
  const pulseAnim   = useRef(new Animated.Value(1)).current;
  const xFlashAnim  = useRef(new Animated.Value(0)).current;
  const lineAnim    = useRef(new Animated.Value(0)).current;

  useEffect(() => {
    // Anillos de fondo aparecen
    Animated.timing(bgOpacity, { toValue: 1, duration: 700, easing: Easing.out(Easing.ease), useNativeDriver: true }).start();

    // Logo zoom-in dramático
    Animated.sequence([
      Animated.delay(200),
      Animated.parallel([
        Animated.timing(logoOpacity, { toValue: 1, duration: 650, easing: Easing.out(Easing.ease), useNativeDriver: true }),
        Animated.spring(logoScale,   { toValue: 1, tension: 48, friction: 5, useNativeDriver: true }),
      ]),
    ]).start();

    // Triple flash de la X
    Animated.sequence([
      Animated.delay(800),
      Animated.sequence([
        Animated.timing(xFlashAnim, { toValue: 1,   duration: 200, useNativeDriver: true }),
        Animated.timing(xFlashAnim, { toValue: 0.2, duration: 160, useNativeDriver: true }),
        Animated.timing(xFlashAnim, { toValue: 1,   duration: 200, useNativeDriver: true }),
        Animated.timing(xFlashAnim, { toValue: 0.3, duration: 150, useNativeDriver: true }),
        Animated.timing(xFlashAnim, { toValue: 1,   duration: 180, useNativeDriver: true }),
        Animated.timing(xFlashAnim, { toValue: 0,   duration: 500, easing: Easing.out(Easing.ease), useNativeDriver: true }),
      ]),
    ]).start();

    // Línea verde que se revela bajo el logo
    Animated.sequence([
      Animated.delay(860),
      Animated.timing(lineAnim, { toValue: 1, duration: 500, easing: Easing.out(Easing.ease), useNativeDriver: false }),
    ]).start();

    // Taglines slide up
    Animated.sequence([
      Animated.delay(960),
      Animated.parallel([
        Animated.timing(taglinesOp, { toValue: 1, duration: 550, easing: Easing.out(Easing.ease), useNativeDriver: true }),
        Animated.timing(taglinesY,  { toValue: 0, duration: 550, easing: Easing.out(Easing.ease), useNativeDriver: true }),
      ]),
    ]).start();

    // Formulario slide up
    Animated.sequence([
      Animated.delay(1100),
      Animated.parallel([
        Animated.timing(formOp, { toValue: 1, duration: 600, easing: Easing.out(Easing.ease), useNativeDriver: true }),
        Animated.timing(formY,  { toValue: 0, duration: 600, easing: Easing.out(Easing.ease), useNativeDriver: true }),
      ]),
    ]).start();

    // Rotación continua del anillo exterior
    Animated.loop(
      Animated.timing(rotateAnim, { toValue: 1, duration: 12000, easing: Easing.linear, useNativeDriver: true })
    ).start();

    // Pulso continuo del anillo medio
    Animated.loop(
      Animated.sequence([
        Animated.timing(pulseAnim, { toValue: 1.07, duration: 1600, easing: Easing.inOut(Easing.ease), useNativeDriver: true }),
        Animated.timing(pulseAnim, { toValue: 1,    duration: 1600, easing: Easing.inOut(Easing.ease), useNativeDriver: true }),
      ])
    ).start();
  }, []);

  const spin      = rotateAnim.interpolate({ inputRange: [0, 1], outputRange: ['0deg', '360deg'] });
  const lineWidth = lineAnim.interpolate({ inputRange: [0, 1], outputRange: ['0%', '82%'] });

  // ── Acciones ─────────────────────────────────────────────────────────────────
  const handleLogin = async () => {
    if (!email || !password) {
      Alert.alert(t('introScreen.alertEmptyFieldsTitle'), t('introScreen.alertEmptyFieldsMessage'));
      return;
    }
    setLoading(true);
    const { error } = await supabase.auth.signInWithPassword({ email, password });
    setLoading(false);
    if (error) Alert.alert(t('introScreen.alertLoginErrorTitle'), error.message);
  };

  const handleForgot = async () => {
    if (!email) {
      Alert.alert(t('introScreen.alertForgotEmailRequiredTitle'), t('introScreen.alertForgotEmailRequiredMessage'));
      return;
    }
    const { error } = await supabase.auth.resetPasswordForEmail(email, {
      redirectTo: 'daricefy://reset-password',
    });
    if (error) Alert.alert(t('introScreen.alertErrorTitle'), error.message);
    else Alert.alert(t('introScreen.alertEmailSentTitle'), t('introScreen.alertEmailSentMessage'));
  };

  // Entrar con Google (2026-09-19) — esta es la pantalla REAL de entrada
  // (Intro, no Login) — hallazgo real: "cuando me meto no aparece el botón
  // de Google" porque el botón se había agregado solo en LoginScreen.tsx,
  // una pantalla duplicada a la que casi nadie llega directo (solo desde
  // el link "Iniciar sesión" de Register). Mismo mecanismo aquí.
  const GOOGLE_REDIRECT_URL = 'daricefy://auth-callback';
  const handleGoogleSignIn = async () => {
    if (Constants.appOwnership === 'expo') {
      Alert.alert(
        'No disponible en Expo Go',
        'Entrar con Google necesita un build real de la app (no funciona dentro de Expo Go). Por ahora usa tu correo y contraseña para probar — Google ya está listo para cuando instales un build.',
      );
      return;
    }
    setGoogleLoading(true);
    try {
      const { data, error } = await supabase.auth.signInWithOAuth({
        provider: 'google',
        options: { redirectTo: GOOGLE_REDIRECT_URL, skipBrowserRedirect: true },
      });
      if (error || !data?.url) throw error ?? new Error('No se pudo iniciar con Google.');

      const res = await WebBrowser.openAuthSessionAsync(data.url, GOOGLE_REDIRECT_URL);
      if (res.type === 'success' && res.url) {
        const { error: exErr } = await supabase.auth.exchangeCodeForSession(res.url);
        if (exErr) throw exErr;
      }
    } catch (e: any) {
      Alert.alert(t('introScreen.alertErrorTitle'), e?.message ?? 'No se pudo iniciar sesión con Google.');
    } finally {
      setGoogleLoading(false);
    }
  };

  // ── Render ───────────────────────────────────────────────────────────────────
  return (
    <View style={s.container}>

      {/* ── FONDO: vórtice de energía (permanente) ── */}
      <Animated.View
        style={[StyleSheet.absoluteFill, { alignItems: 'center', justifyContent: 'center' }, { opacity: bgOpacity }]}
        pointerEvents="none"
      >
        <View style={s.glowBlob} />
        <Animated.View style={[s.ring, { width: 390, height: 390, borderRadius: 195, opacity: 0.09, transform: [{ rotate: spin }] }]} />
        <View           style={[s.ring, { width: 295, height: 295, borderRadius: 148, opacity: 0.14 }]} />
        <Animated.View style={[s.ring, { width: 215, height: 215, borderRadius: 108, opacity: 0.20, transform: [{ scale: pulseAnim }] }]} />
        <View           style={[s.ring, { width: 145, height: 145, borderRadius: 73,  opacity: 0.28 }]} />
        <View           style={[s.ring, { width: 82,  height: 82,  borderRadius: 41,  opacity: 0.16, borderColor: 'rgba(255,215,0,0.5)' }]} />
        {/* Rayos radiales */}
        {[15, 55, 95, 135, -15, -55, -95, -135].map((angle, i) => (
          <View key={i} style={[s.beam, { transform: [{ rotate: `${angle}deg` }] }]} />
        ))}
        {/* Puntos dorado/verde */}
        <View style={[s.dot, { marginTop: -148, backgroundColor: 'rgba(255,215,0,0.9)'  }]} />
        <View style={[s.dot, { marginTop:  148, backgroundColor: 'rgba(0,230,118,0.9)'  }]} />
        <View style={[s.dot, { marginLeft: -148, backgroundColor: 'rgba(255,215,0,0.65)' }]} />
        <View style={[s.dot, { marginLeft:  148, backgroundColor: 'rgba(0,230,118,0.65)' }]} />
      </Animated.View>

      {/* ── FLASH de la X ── */}
      <Animated.View
        style={[StyleSheet.absoluteFill, { alignItems: 'center', justifyContent: 'center' }, { opacity: xFlashAnim }]}
        pointerEvents="none"
      >
        <View style={s.xFlash} />
      </Animated.View>

      {/* ── CONTENIDO ── */}
      <SafeAreaView style={{ flex: 1 }}>
        <KeyboardAvoidingView style={{ flex: 1 }} behavior={Platform.OS === 'ios' ? 'padding' : undefined}>
          <ScrollView
            contentContainerStyle={s.scroll}
            keyboardShouldPersistTaps="handled"
            showsVerticalScrollIndicator={false}
          >

            {/* Logo + taglines */}
            <View style={s.hero}>
              <Animated.View style={{ alignItems: 'center', opacity: logoOpacity, transform: [{ scale: logoScale }] }}>
                {/* Marca (2026-09-05) — el logo real, igual que en Splash/Login */}
                <Image source={require('../../../assets/images/icon.png')} style={s.logoMark} resizeMode="contain" />
                <Text style={s.logoText} adjustsFontSizeToFit numberOfLines={1}>
                  Darice<Text style={s.logoX}>fy</Text>
                </Text>
                <View style={s.lineContainer}>
                  <Animated.View style={[s.line, { width: lineWidth }]} />
                </View>
              </Animated.View>

              <Animated.View style={{ alignItems: 'center', opacity: taglinesOp, transform: [{ translateY: taglinesY }], marginTop: 12 }}>
                <Text style={s.tagline}>{t('introScreen.tagline')}</Text>
                <Text style={s.subtitle}>{t('introScreen.subtitle')}</Text>
              </Animated.View>
            </View>

            {/* ── FORMULARIO DE LOGIN ── */}
            <Animated.View style={[s.card, { opacity: formOp, transform: [{ translateY: formY }] }]}>
              {/* Acento superior */}
              <LinearGradient
                colors={[COLORS.green, 'rgba(0,230,118,0)']}
                start={{ x: 0, y: 0 }} end={{ x: 1, y: 0 }}
                style={s.cardAccent}
              />

              <Text style={s.formTitle}>{t('introScreen.formTitle')}</Text>

              <Input
                label={t('introScreen.emailLabel')}
                placeholder={t('introScreen.emailPlaceholder')}
                value={email}
                onChangeText={setEmail}
                keyboardType="email-address"
                autoCapitalize="none"
                icon={<Mail size={18} color={COLORS.muted} />}
              />

              <Input
                label={t('introScreen.passwordLabel')}
                placeholder={t('introScreen.passwordPlaceholder')}
                value={password}
                onChangeText={setPassword}
                secureTextEntry
                icon={<Lock size={18} color={COLORS.muted} />}
              />

              <View style={{ height: 6 }} />
              <Button label={t('introScreen.submit')} onPress={handleLogin} loading={loading} size="lg" />

              <Pressable style={s.forgotRow} onPress={handleForgot}>
                <Text style={s.forgotText}>{t('introScreen.forgotPassword')}</Text>
              </Pressable>

              <View style={s.dividerRow}>
                <View style={s.dividerLine} />
                <Text style={s.dividerText}>o</Text>
                <View style={s.dividerLine} />
              </View>

              <Pressable
                style={[s.googleBtn, googleLoading && { opacity: 0.6 }]}
                onPress={handleGoogleSignIn}
                disabled={googleLoading}
              >
                <View style={s.googleGBadge}>
                  <Text style={s.googleGText}>G</Text>
                </View>
                <Text style={s.googleBtnText}>
                  {googleLoading ? 'Conectando…' : 'Continuar con Google'}
                </Text>
              </Pressable>
            </Animated.View>

            {/* ── FOOTER: registrarse ── */}
            <Animated.View style={[s.footer, { opacity: formOp }]}>
              <Text style={s.footerText}>{t('introScreen.noAccount')}</Text>
              <Pressable onPress={() => navigation?.navigate?.('Register')}>
                <Text style={s.footerLink}>{t('introScreen.registerLink')}</Text>
              </Pressable>
            </Animated.View>

          </ScrollView>
        </KeyboardAvoidingView>
      </SafeAreaView>
    </View>
  );
}

const s = StyleSheet.create({
  container: { flex: 1, backgroundColor: COLORS.bg },

  // ── Fondo ─────────────────────────────────────────────────────
  glowBlob: {
    position: 'absolute',
    width: 460, height: 460, borderRadius: 230,
    backgroundColor: 'rgba(0,230,118,0.035)',
  },
  ring: { position: 'absolute', borderWidth: 1.5, borderColor: COLORS.green },
  beam: { position: 'absolute', width: 1, height: 660, backgroundColor: 'rgba(0,230,118,0.055)' },
  dot:  { position: 'absolute', width: 8, height: 8, borderRadius: 4 },
  xFlash: { width: 130, height: 130, borderRadius: 65, backgroundColor: 'rgba(0,230,118,0.25)' },

  // ── Scroll ────────────────────────────────────────────────────
  scroll: {
    flexGrow: 1,
    paddingHorizontal: SPACING.xl,
    paddingTop: 20,
    paddingBottom: 32,
    justifyContent: 'center',
  },

  // ── Hero / logo ───────────────────────────────────────────────
  hero: { alignItems: 'center', marginBottom: 32 },
  logoMark: { width: 64, height: 64, marginBottom: 10 },
  logoText: {
    fontFamily: FONTS.title, fontSize: 34,
    color: COLORS.text, letterSpacing: -0.5, textAlign: 'center',
  },
  logoX: {
    color: COLORS.green,
  },
  lineContainer: { width: '75%', height: 2, overflow: 'hidden', marginTop: 10, alignSelf: 'center' },
  line: { height: 2, backgroundColor: COLORS.green, borderRadius: 1, opacity: 0.7 },

  tagline: {
    fontFamily: FONTS.bodyMedium, fontSize: 13,
    color: COLORS.muted2, letterSpacing: 0.6, textAlign: 'center',
  },
  subtitle: {
    fontFamily: FONTS.body, fontSize: 11,
    color: COLORS.muted, marginTop: 5, letterSpacing: 0.3,
    textAlign: 'center', fontStyle: 'italic',
  },

  // ── Card / formulario ─────────────────────────────────────────
  card: {
    backgroundColor: 'rgba(14,14,14,0.45)',
    borderRadius: RADIUS.xl ?? 20,
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.18)',
    padding: SPACING.xl,
    paddingTop: 0,
    marginBottom: 20,
    overflow: 'hidden',
  },
  cardAccent: { height: 2, marginBottom: 22, borderRadius: 1 },
  formTitle: {
    fontFamily: FONTS.title, fontSize: 20,
    color: COLORS.text, marginBottom: 18,
  },
  forgotRow: { alignItems: 'center', marginTop: 16, paddingVertical: 4 },
  forgotText: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2 },

  dividerRow: { flexDirection: 'row', alignItems: 'center', gap: 10, marginTop: 14, marginBottom: 6 },
  dividerLine: { flex: 1, height: 1, backgroundColor: 'rgba(255,255,255,0.1)' },
  dividerText: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted },

  googleBtn: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 10,
    backgroundColor: 'rgba(255,255,255,0.05)', borderWidth: 1, borderColor: 'rgba(255,255,255,0.12)',
    borderRadius: RADIUS.lg, paddingVertical: 13, marginTop: 10,
  },
  googleGBadge: {
    width: 20, height: 20, borderRadius: 10, backgroundColor: '#fff',
    alignItems: 'center', justifyContent: 'center',
  },
  googleGText: { fontFamily: FONTS.bodySemiBold, fontSize: 12, color: '#4285F4' },
  googleBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.text },

  // ── Footer ────────────────────────────────────────────────────
  footer: { flexDirection: 'row', justifyContent: 'center', alignItems: 'center' },
  footerText: { fontFamily: FONTS.body, fontSize: 14, color: COLORS.muted2 },
  footerLink: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.green },
});
