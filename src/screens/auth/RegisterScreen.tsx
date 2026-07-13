import React, { useState } from 'react';
import {
  Alert,
  KeyboardAvoidingView,
  Linking,
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
import { Gift, Lock, Mail, Music, User } from 'lucide-react-native';
import Particles from '../../components/ui/Particles';

type RoleKey = 'client' | 'talent' | 'group';
type DbRole  = 'client' | 'talent' | 'group';

interface RoleDef {
  key:      RoleKey;
  dbRole:   DbRole;
  label:    string;
  subtitle: string;
  emoji:    string;
  desc:     string;
}

const ROLES: RoleDef[] = [
  { key: 'client', dbRole: 'client', label: 'Soy Cliente',   subtitle: '',                        emoji: '🎉', desc: 'Contrata artistas para tu evento' },
  { key: 'talent', dbRole: 'talent', label: 'Soy Talento',   subtitle: 'Músico',                  emoji: '🎤', desc: 'Bolsa de trabajo musical' },
  { key: 'group',  dbRole: 'group',  label: 'Soy Prestador', subtitle: 'Grupo · DJ · Show · Foto', emoji: '🎸', desc: 'Recibe cotizaciones y gestiona eventos' },
];

interface CategoryDef {
  key:   string;
  label: string;
  emoji: string;
  desc:  string;
}

/** Todas las categorías de servicio para prestadores */
const GRUPO_CATEGORIES: CategoryDef[] = [
  { key: 'grupo',              label: 'Grupo / Solista',    emoji: '🎸', desc: 'Banda, conjunto musical o artista solista' },
  { key: 'dj',                 label: 'DJ',                 emoji: '🎧', desc: 'Música electrónica y mezclas' },
  { key: 'payaso',             label: 'Payaso / Animación', emoji: '🤡', desc: 'Entretenimiento infantil' },
  { key: 'fotografia',         label: 'Foto / Video',       emoji: '📸', desc: 'Fotografía y videografía de eventos' },
  { key: 'show',               label: 'Espectáculo',        emoji: '🎪', desc: 'Shows, magia, performance' },
  { key: 'maestro_ceremonias', label: 'Maestro de Ceremonias', emoji: '🎙️', desc: 'MC y conducción de eventos' },
  { key: 'animacion',          label: 'Animación / Brincolines', emoji: '🎠', desc: 'Entretenimiento general' },
];

/** Categoría por defecto según rol */
const DEFAULT_CATEGORY: Record<RoleKey, string> = {
  client: 'client',
  talent: 'music',
  group:  'grupo',
};

export default function RegisterScreen({ navigation, route }: any) {
  const { t } = useTranslation();
  const [fullName, setFullName]              = useState('');
  const [email, setEmail]                    = useState('');
  const [password, setPassword]              = useState('');
  const [role, setRole]                      = useState<RoleKey>('client');
  const [category, setCategory]              = useState<string>('client');

  // Talent-specific
  const [instrument, setInstrument]          = useState('');
  const [expYears, setExpYears]              = useState('');
  const [bio, setBio]                        = useState('');
  const [phone, setPhone]                    = useState('');

  // Pre-relleno si viene de un deep link daricefy://g/:code
  const [referralCode, setReferralCode]      = useState<string>(
    (route?.params?.referralCode as string | undefined) ?? ''
  );

  const [loading, setLoading]                = useState(false);
  const [registered, setRegistered]          = useState(false);
  const [stripeConnectLoading, setStripeConnectLoading] = useState(false);

  const selectedRole = ROLES.find(r => r.key === role)!;

  const handleSelectRole = (r: RoleKey) => {
    setRole(r);
    setCategory(DEFAULT_CATEGORY[r]);
  };

  const handleRegister = async () => {
    if (!fullName.trim() || !email.trim() || !password) {
      Alert.alert(t('common.error'), t('common.required'));
      return;
    }
    if (role === 'talent' && !instrument.trim()) {
      Alert.alert(t('common.error'), t('common.required'));
      return;
    }

    setLoading(true);

    const dbRole = selectedRole.dbRole;

    const { data, error } = await supabase.auth.signUp({
      email: email.trim(),
      password,
      options: { data: { full_name: fullName.trim(), role: dbRole } },
    });

    if (error) {
      setLoading(false);
      Alert.alert('Error', error.message);
      return;
    }

    const userId  = data.user?.id;
    const session = data.session;

    if (userId && session) {
      await supabase.from('profiles').upsert(
        {
          id: userId,
          email: email.trim(),
          full_name: fullName.trim(),
          role: dbRole,
          phone: (role === 'talent' || role === 'group') && phone.trim() ? phone.trim() : null,
          phone_verified: false,
          id_verified: false,
        },
        { onConflict: 'id' }
      );

      if (role === 'talent') {
        await supabase.from('job_board_profiles').upsert(
          {
            user_id:             userId,
            instrument_or_role:  instrument.trim(),
            experience_years:    parseInt(expYears) || 0,
            bio:                 bio.trim() || null,
            is_visible:          true,
            availability_status: 'available',
          },
          { onConflict: 'user_id' }
        );
      } else if (role === 'group') {
        // Guardar tipo de grupo/show para clasificación
        await supabase.from('job_board_profiles').upsert(
          {
            user_id:             userId,
            instrument_or_role:  category,
            is_visible:          false,
            availability_status: 'available',
          },
          { onConflict: 'user_id' }
        );
      }
    }

    // Registrar código de referido si es cliente y tiene uno
    let referralOk = false;
    let referralErr = '';
    if (role === 'client' && referralCode.trim() && userId && session) {
      const { data: refData, error: refErr } = await supabase.rpc('register_referral', {
        p_referral_code: referralCode.trim().toUpperCase(),
      });
      if (!refErr && (refData?.ok !== false)) {
        referralOk = true;
      } else {
        referralErr = refData?.error ?? refErr?.message ?? 'Código inválido';
      }
    }

    setLoading(false);

    if (selectedRole.dbRole === 'talent' || selectedRole.dbRole === 'group') {
      setRegistered(true);
    } else {
      const referralMsg = referralCode.trim()
        ? referralOk
          ? '\n\n✅ Código aplicado correctamente. Recibirás un beneficio en tu primera reserva.'
          : `\n\n⚠️ Código de referido no válido: ${referralErr}`
        : '';
      Alert.alert(
        '¡Listo!',
        `Cuenta creada. Revisa tu correo para verificar tu cuenta.${referralMsg}`,
        [{ text: 'OK', onPress: () => navigation?.navigate?.('Login') }]
      );
    }
  };

  const handleConnectAfterRegister = async () => {
    setStripeConnectLoading(true);
    try {
      const { data: sd } = await supabase.auth.getSession();
      const token = sd.session?.access_token;
      if (token) {
        const { data } = await supabase.functions.invoke('stripe-connect-profile', {
          headers: { Authorization: `Bearer ${token}` },
        });
        if (data?.url) {
          await Linking.openURL(data.url);
        }
      }
    } catch {
      // Conectar más tarde desde el perfil
    } finally {
      setStripeConnectLoading(false);
    }
    navigation?.replace?.('Login');
  };

  // ── Pantalla de éxito post-registro ─────────────────────────────────────
  if (registered) {
    if (role === 'talent') {
      return (
        <View style={styles.container}>
          <Particles />
          <SafeAreaView style={{ flex: 1, justifyContent: 'center' }}>
            <View style={styles.successContainer}>
              <Text style={styles.successEmoji}>🎵</Text>
              <Text style={styles.successTitle}>¡Bienvenido a Daricefy!</Text>
              <Text style={styles.successSub}>
                Tu perfil ya está visible en la bolsa de trabajo. Los grupos
                podrán invitarte a tocadas o a formar parte de su banda.
              </Text>
              <Button
                label="Entrar a la app →"
                onPress={() => navigation?.replace?.('Login')}
                size="lg"
              />
              <Text style={styles.successHint}>
                Recibirás notificaciones cuando un grupo te invite.
              </Text>
            </View>
          </SafeAreaView>
        </View>
      );
    }

    return (
      <View style={styles.container}>
        <Particles />
        <SafeAreaView style={{ flex: 1, justifyContent: 'center' }}>
          <View style={styles.successContainer}>
            <Text style={styles.successEmoji}>🎉</Text>
            <Text style={styles.successTitle}>¡Cuenta creada!</Text>
            <Text style={styles.successSub}>
              Conecta tu cuenta bancaria para recibir pagos automáticamente cuando completes eventos.
            </Text>
            <Button
              label={stripeConnectLoading ? 'Abriendo...' : '💳 Conectar cuenta ahora'}
              onPress={handleConnectAfterRegister}
              loading={stripeConnectLoading}
              size="lg"
            />
            <Pressable
              style={styles.skipBtn}
              onPress={() => navigation?.replace?.('Login')}
              disabled={stripeConnectLoading}
            >
              <Text style={styles.skipText}>Después →</Text>
            </Pressable>
          </View>
        </SafeAreaView>
      </View>
    );
  }

  return (
    <View style={styles.container}>
      <Particles />
      <SafeAreaView style={{ flex: 1 }}>
        <KeyboardAvoidingView
          style={{ flex: 1 }}
          behavior={Platform.OS === 'ios' ? 'padding' : undefined}
        >
          <ScrollView
            contentContainerStyle={styles.scroll}
            keyboardShouldPersistTaps="handled"
            showsVerticalScrollIndicator={false}
          >
            {/* HEADER */}
            <View style={styles.header}>
              <Pressable onPress={() => navigation?.goBack?.()} style={styles.backBtn}>
                <Text style={styles.backText}>← Volver</Text>
              </Pressable>
              <View style={styles.logoRow}>
                <Text style={styles.logoWhite}>Darice<Text style={styles.logoGreen}>fy</Text></Text>
              </View>
            </View>

            <Text style={styles.title}>{t('auth.register.title')}</Text>
            <Text style={styles.subtitle}>Únete al ecosistema de entretenimiento</Text>

            {/* ROLE SELECTOR — 2×2 grid */}
            <Text style={styles.label}>¿Cómo quieres usar Daricefy?</Text>
            <View style={styles.roleGrid}>
              {ROLES.map((r) => {
                const roleLabel = r.key === 'client'
                  ? t('auth.register.role_client')
                  : r.key === 'talent'
                  ? t('auth.register.role_talent')
                  : t('auth.register.role_provider');
                const roleDesc = r.key === 'client'
                  ? t('auth.register.role_client_desc')
                  : r.key === 'talent'
                  ? t('auth.register.role_talent_desc')
                  : t('auth.register.role_provider_desc');
                return (
                  <Pressable
                    key={r.key}
                    style={[styles.roleCard, role === r.key && styles.roleCardActive]}
                    onPress={() => handleSelectRole(r.key)}
                  >
                    <Text style={styles.roleEmoji}>{r.emoji}</Text>
                    <Text style={[styles.roleLabel, role === r.key && styles.roleLabelActive]}>
                      {roleLabel}
                    </Text>
                    {r.subtitle ? (
                      <View style={[styles.roleSubtitlePill, role === r.key && styles.roleSubtitlePillActive]}>
                        <Text style={[styles.roleSubtitle, role === r.key && styles.roleSubtitleActive]}>
                          {r.subtitle}
                        </Text>
                      </View>
                    ) : null}
                    <Text style={styles.roleDesc}>{roleDesc}</Text>
                  </Pressable>
                );
              })}
            </View>

            {/* CAMPOS BASE */}
            <Input
              label={t('auth.register.full_name_label')}
              placeholder={t('auth.register.full_name_placeholder')}
              value={fullName}
              onChangeText={setFullName}
              icon={<User size={18} color={COLORS.muted} />}
            />

            <Input
              label={t('auth.register.email_label')}
              placeholder={t('auth.register.email_placeholder')}
              value={email}
              onChangeText={setEmail}
              keyboardType="email-address"
              autoCapitalize="none"
              icon={<Mail size={18} color={COLORS.muted} />}
            />

            <Input
              label={t('auth.register.password_label')}
              placeholder={t('auth.register.password_placeholder')}
              value={password}
              onChangeText={setPassword}
              secureTextEntry
              icon={<Lock size={18} color={COLORS.muted} />}
            />

            {/* ── SOY TALENTO — siempre Música ──────────────────────────── */}
            {role === 'talent' && (
              <View style={styles.extraSection}>
                <View style={styles.sectionHeader}>
                  <Music size={16} color={COLORS.green} />
                  <Text style={styles.sectionHeaderText}>Perfil de Talento · 🎵 Música</Text>
                </View>

                <Input
                  label="Instrumento o rol *"
                  placeholder="Ej: Guitarrista, Vocalista, Baterista..."
                  value={instrument}
                  onChangeText={setInstrument}
                  icon={<Music size={18} color={COLORS.muted} />}
                />

                <Input
                  label="Años de experiencia"
                  placeholder="Ej: 5"
                  value={expYears}
                  onChangeText={setExpYears}
                  keyboardType="numeric"
                />

                <Input
                  label="Bio (opcional)"
                  placeholder="Cuéntanos sobre ti, tu estilo, lo que ofreces..."
                  value={bio}
                  onChangeText={setBio}
                  multiline
                  numberOfLines={3}
                />

                <Input
                  label="Teléfono de contacto"
                  placeholder="Ej: 5512345678"
                  value={phone}
                  onChangeText={setPhone}
                  keyboardType="phone-pad"
                />
              </View>
            )}

            {/* ── SOY PRESTADOR — Todas las categorías ─────────────────── */}
            {role === 'group' && (
              <View style={styles.extraSection}>
                <View style={styles.sectionHeader}>
                  <Text style={styles.sectionEmoji}>🎪</Text>
                  <Text style={styles.sectionHeaderText}>¿Qué tipo de servicio ofreces?</Text>
                </View>
                <View style={styles.categoryGrid}>
                  {GRUPO_CATEGORIES.map((cat) => (
                    <Pressable
                      key={cat.key}
                      style={[styles.categoryCard, category === cat.key && styles.categoryCardActive]}
                      onPress={() => setCategory(cat.key)}
                    >
                      <Text style={styles.categoryEmoji}>{cat.emoji}</Text>
                      <Text style={[styles.categoryLabel, category === cat.key && styles.categoryLabelActive]}>
                        {cat.label}
                      </Text>
                      <Text style={styles.categoryDesc}>{cat.desc}</Text>
                    </Pressable>
                  ))}
                </View>

                <Input
                  label="Teléfono de contacto"
                  placeholder="Ej: 5512345678"
                  value={phone}
                  onChangeText={setPhone}
                  keyboardType="phone-pad"
                />
              </View>
            )}

            {/* Código de referido — solo para clientes */}
            {role === 'client' && (
              <View style={styles.referralSection}>
                <View style={styles.referralHeader}>
                  <Gift size={14} color={COLORS.green} />
                  <Text style={styles.referralLabel}>¿Tienes un código de referido?</Text>
                </View>
                <Input
                  label=""
                  placeholder="Ej: TROVADORES10  (opcional)"
                  value={referralCode}
                  onChangeText={(t: string) => setReferralCode(t.toUpperCase())}
                  autoCapitalize="characters"
                  icon={<Gift size={18} color={COLORS.muted} />}
                />
                <Text style={styles.referralHint}>
                  Ingresa el código que te compartió el grupo · Recibirás un beneficio en tu primera reserva
                </Text>
              </View>
            )}

            <View style={{ marginTop: 8 }}>
              <Button label={t('auth.register.submit')} onPress={handleRegister} loading={loading} size="lg" />
            </View>

            {/* Aceptación legal — al crear la cuenta aceptas términos y privacidad */}
            <Text style={styles.legalNote}>
              Al crear tu cuenta aceptas los{' '}
              <Text style={styles.legalLink} onPress={() => navigation?.navigate?.('Legal', { doc: 'terms' })}>
                Términos y condiciones
              </Text>{' '}
              y el{' '}
              <Text style={styles.legalLink} onPress={() => navigation?.navigate?.('Legal', { doc: 'privacy' })}>
                Aviso de privacidad
              </Text>.
            </Text>

            <View style={styles.footer}>
              <Text style={styles.footerText}>{t('auth.register.already_account')}</Text>
              <Pressable onPress={() => navigation?.navigate?.('Login')}>
                <Text style={styles.footerLink}>{t('auth.register.login_link')}</Text>
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
  scroll:    { flexGrow: 1, padding: SPACING.xl, paddingTop: 20 },
  header:    { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', marginBottom: 32 },
  backBtn:   { padding: 4 },
  backText:  { fontFamily: FONTS.bodyMedium, color: COLORS.muted2, fontSize: 14 },
  logoRow:   { flexDirection: 'row', gap: 4 },
  logoWhite: { fontFamily: FONTS.title, fontSize: 18, color: COLORS.text, letterSpacing: -0.5 },
  logoGreen: { fontFamily: FONTS.title, fontSize: 18, color: COLORS.green, letterSpacing: -0.5 },
  title:     { fontFamily: FONTS.title, fontSize: 28, color: COLORS.text, marginBottom: 6 },
  subtitle:  { fontFamily: FONTS.body, fontSize: 14, color: COLORS.muted2, marginBottom: 24 },
  label:     { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted2, marginBottom: 12 },

  // 3-column role grid
  roleGrid: { flexDirection: 'row', flexWrap: 'wrap', gap: 10, marginBottom: 24 },
  roleCard: {
    width: '30%',
    paddingVertical: 14,
    paddingHorizontal: 8,
    borderRadius: RADIUS.lg,
    borderWidth: 1,
    borderColor: COLORS.border,
    backgroundColor: COLORS.card,
    alignItems: 'center',
    gap: 4,
  },
  roleCardActive:         { borderColor: COLORS.green, backgroundColor: COLORS.greenMuted },
  roleEmoji:              { fontSize: 22, marginBottom: 2 },
  roleLabel:              { fontFamily: FONTS.bodySemiBold, fontSize: 12, color: COLORS.muted2, textAlign: 'center' },
  roleLabelActive:        { color: COLORS.green },
  roleSubtitlePill:       { backgroundColor: 'rgba(255,255,255,0.06)', borderRadius: 20, paddingHorizontal: 7, paddingVertical: 2, marginTop: 2 },
  roleSubtitlePillActive: { backgroundColor: 'rgba(0,230,118,0.15)' },
  roleSubtitle:           { fontFamily: FONTS.bodySemiBold, fontSize: 9, color: COLORS.muted, textAlign: 'center' },
  roleSubtitleActive:     { color: COLORS.green },
  roleDesc:               { fontFamily: FONTS.body, fontSize: 10, color: COLORS.muted, textAlign: 'center', marginTop: 3 },

  // Extra section (talent / group / show)
  extraSection: {
    backgroundColor: COLORS.card,
    borderRadius: RADIUS.lg,
    borderWidth: 1,
    borderColor: COLORS.green,
    padding: SPACING.lg,
    marginBottom: 8,
    gap: 2,
  },
  sectionHeader: { flexDirection: 'row', alignItems: 'center', gap: 8, marginBottom: 12 },
  sectionEmoji:  { fontSize: 16 },
  sectionHeaderText: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.green },

  // Category chips (legacy, unused but kept for safety)
  categoryRow: { flexDirection: 'row', flexWrap: 'wrap', gap: 8, marginBottom: 4 },
  categoryChip: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 5,
    paddingHorizontal: 14,
    paddingVertical: 9,
    borderRadius: RADIUS.full,
    borderWidth: 1,
    borderColor: COLORS.border,
    backgroundColor: COLORS.card2,
  },
  categoryChipActive:  { borderColor: COLORS.green, backgroundColor: COLORS.greenMuted },
  categoryEmoji:       { fontSize: 15 },
  categoryLabel:       { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted2 },
  categoryLabelActive: { color: COLORS.green },

  // Category grid (prestadores)
  categoryGrid: { flexDirection: 'row', flexWrap: 'wrap', gap: 8, marginBottom: 4 },
  categoryCard: {
    width: '47%',
    alignItems: 'center',
    paddingVertical: 12,
    paddingHorizontal: 8,
    borderRadius: RADIUS.lg,
    borderWidth: 1,
    borderColor: COLORS.border,
    backgroundColor: COLORS.card2,
    gap: 3,
  },
  categoryCardActive: { borderColor: COLORS.green, backgroundColor: COLORS.greenMuted },
  categoryDesc: { fontFamily: FONTS.body, fontSize: 10, color: COLORS.muted, textAlign: 'center' },

  // Referral section
  referralSection: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.3)',
    padding: SPACING.lg, marginBottom: 8, gap: 4,
  },
  referralHeader: { flexDirection: 'row', alignItems: 'center', gap: 7, marginBottom: 4 },
  referralLabel:  { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.green },
  referralHint:   { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted, marginTop: -4 },

  footer:     { flexDirection: 'row', justifyContent: 'center', marginTop: 24 },
  footerText: { fontFamily: FONTS.body, fontSize: 14, color: COLORS.muted2 },
  footerLink: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.green },
  legalNote: {
    fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted2,
    textAlign: 'center', lineHeight: 16, marginTop: 12, paddingHorizontal: 10,
  },
  legalLink: { fontFamily: FONTS.bodySemiBold, fontSize: 11, color: COLORS.green, textDecorationLine: 'underline' },

  // Success screen
  successContainer: { padding: SPACING.xl, alignItems: 'center', gap: 12 },
  successEmoji:     { fontSize: 64, marginBottom: 8 },
  successTitle:     { fontFamily: FONTS.title, fontSize: 28, color: COLORS.text, textAlign: 'center' },
  successSub:       { fontFamily: FONTS.body, fontSize: 15, color: COLORS.muted2, textAlign: 'center', lineHeight: 22, marginBottom: 12 },
  successHint:      { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted, textAlign: 'center', marginTop: 12 },
  skipBtn:          { paddingVertical: 14, paddingHorizontal: 24 },
  skipText:         { fontFamily: FONTS.bodyMedium, fontSize: 14, color: COLORS.muted2 },
});
