import { LinearGradient } from 'expo-linear-gradient';
import { Lock, Mail } from 'lucide-react-native';
import React, { useEffect, useRef, useState } from 'react';
import {
  Alert,
  Animated,
  Easing,
  Image,
  Keyboard,
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
import Particles from '../../components/ui/Particles';

export default function LoginScreen({ navigation }: any) {
  const { t } = useTranslation();
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [loading, setLoading] = useState(false);

  // Animations
  const logoFade = useRef(new Animated.Value(0)).current;
  const logoY = useRef(new Animated.Value(-20)).current;
  const formFade = useRef(new Animated.Value(0)).current;
  const formY = useRef(new Animated.Value(30)).current;

  useEffect(() => {
    // Logo fade+slide in
    Animated.parallel([
      Animated.timing(logoFade, { toValue: 1, duration: 600, delay: 150, easing: Easing.out(Easing.ease), useNativeDriver: true }),
      Animated.timing(logoY, { toValue: 0, duration: 600, delay: 150, easing: Easing.out(Easing.ease), useNativeDriver: true }),
    ]).start();

    // Form slides up
    Animated.parallel([
      Animated.timing(formFade, { toValue: 1, duration: 500, delay: 400, easing: Easing.out(Easing.ease), useNativeDriver: true }),
      Animated.timing(formY, { toValue: 0, duration: 500, delay: 400, easing: Easing.out(Easing.ease), useNativeDriver: true }),
    ]).start();
  }, []);

  const handleLogin = async () => {
    if (!email || !password) {
      Alert.alert(t('common.error'), t('auth.login.error_empty'));
      return;
    }
    Keyboard.dismiss();
    setLoading(true);
    const { error } = await supabase.auth.signInWithPassword({ email, password });
    setLoading(false);
    if (error) Alert.alert(t('common.error'), error.message);
  };

  // "¿Olvidaste tu contraseña?" — hallazgo real (2026-09-05): el botón
  // existía en pantalla pero no tenía onPress, nunca hacía nada. Mismo
  // patrón ya probado y funcionando en IntroScreen.tsx.
  const handleForgot = async () => {
    if (!email.trim()) {
      Alert.alert(t('auth.login.forgot_email_required_title'), t('auth.login.forgot_email_required_message'));
      return;
    }
    const { error } = await supabase.auth.resetPasswordForEmail(email.trim(), {
      redirectTo: 'daricefy://reset-password',
    });
    if (error) Alert.alert(t('common.error'), error.message);
    else Alert.alert(t('auth.login.forgot_email_sent_title'), t('auth.login.forgot_email_sent_message'));
  };

  return (
    <View style={styles.container}>
      <Particles />

      {/* Gradiente superior */}
      <LinearGradient
        colors={['rgba(0,230,118,0.08)', 'transparent']}
        style={styles.topGradient}
        start={{ x: 0.5, y: 0 }}
        end={{ x: 0.5, y: 1 }}
        pointerEvents="none"
      />

      <SafeAreaView style={{ flex: 1 }}>
        <KeyboardAvoidingView style={{ flex: 1 }} behavior={Platform.OS === 'ios' ? 'padding' : undefined}>
          <ScrollView
            contentContainerStyle={styles.scroll}
            keyboardShouldPersistTaps="handled"
            showsVerticalScrollIndicator={false}
          >
            {/* ── HERO ── */}
            <View style={styles.hero}>
              <Animated.View style={{ opacity: logoFade, transform: [{ translateY: logoY }], alignItems: 'center' }}>
                {/* Marca (2026-09-05) — el logo real, igual que en SplashScreen.tsx */}
                <Image source={require('../../../assets/images/icon.png')} style={styles.logoMark} resizeMode="contain" />
                <Text style={styles.logoText} adjustsFontSizeToFit numberOfLines={1}>
                  Darice<Text style={styles.logoGreen}>fy</Text>
                </Text>
              </Animated.View>
            </View>

            {/* ── FORM CARD ── */}
            <Animated.View style={[styles.card, { opacity: formFade, transform: [{ translateY: formY }] }]}>
              {/* Accent line */}
              <LinearGradient
                colors={[COLORS.green, 'rgba(0,230,118,0)']}
                start={{ x: 0, y: 0 }} end={{ x: 1, y: 0 }}
                style={styles.cardAccent}
              />

              <Text style={styles.formTitle}>{t('auth.login.title')}</Text>

              <Input
                label={t('auth.login.email_label')}
                placeholder={t('auth.login.email_placeholder')}
                value={email}
                onChangeText={setEmail}
                keyboardType="email-address"
                autoCapitalize="none"
                autoCorrect={false}
                textContentType="emailAddress"
                icon={<Mail size={18} color={COLORS.muted} />}
              />

              <Input
                label={t('auth.login.password_label')}
                placeholder={t('auth.login.password_placeholder')}
                value={password}
                onChangeText={setPassword}
                secureTextEntry
                autoCorrect={false}
                textContentType="password"
                icon={<Lock size={18} color={COLORS.muted} />}
              />

              <View style={{ height: 4 }} />
              <Button label={t('auth.login.submit')} onPress={handleLogin} loading={loading} size="lg" />

              <Pressable style={styles.forgotRow} onPress={handleForgot} hitSlop={10}>
                <Text style={styles.forgotText}>{t('auth.login.forgot_password')}</Text>
              </Pressable>
            </Animated.View>

            {/* ── FOOTER ── */}
            <View style={styles.footer}>
              <Text style={styles.footerText}>{t('auth.login.no_account')}</Text>
              <Pressable onPress={() => navigation?.navigate?.('Register')}>
                <Text style={styles.footerLink}>{t('auth.login.register_link')}</Text>
              </Pressable>
            </View>
          </ScrollView>
        </KeyboardAvoidingView>
      </SafeAreaView>
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: COLORS.bg },
  topGradient: {
    position: 'absolute', top: 0, left: 0, right: 0, height: 320,
  },
  scroll: {
    flexGrow: 1,
    paddingHorizontal: SPACING.xl,
    paddingTop: 32,
    paddingBottom: 40,
    justifyContent: 'center',
  },

  // Hero
  hero: { alignItems: 'center', marginBottom: 36 },
  logoMark: { width: 56, height: 56, marginBottom: 12 },
  logoText: {
    fontFamily: FONTS.title, fontSize: 28,
    color: COLORS.text, letterSpacing: -0.5,
    textAlign: 'center', width: '100%',
  },
  logoGreen: { color: COLORS.green },

  // Form card
  card: {
    backgroundColor: COLORS.card,
    borderRadius: RADIUS.xl ?? 20,
    borderWidth: 1, borderColor: COLORS.border,
    padding: SPACING.xl,
    paddingTop: 0,
    marginBottom: 24,
    overflow: 'hidden',
  },
  cardAccent: { height: 2, marginBottom: 24, borderRadius: 1 },
  formTitle: {
    fontFamily: FONTS.title, fontSize: 20, color: COLORS.text,
    marginBottom: 20,
  },
  forgotRow: { alignItems: 'center', marginTop: 16 },
  forgotText: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2 },

  // Footer
  footer: { flexDirection: 'row', justifyContent: 'center', alignItems: 'center' },
  footerText: { fontFamily: FONTS.body, fontSize: 14, color: COLORS.muted2 },
  footerLink: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.green },
});
