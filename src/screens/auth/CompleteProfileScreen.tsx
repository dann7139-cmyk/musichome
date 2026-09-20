/**
 * CompleteProfileScreen — último paso para cuentas nuevas dadas de alta con
 * Google (2026-09-19). Supabase ya creó el usuario en auth.users al volver
 * de Google, pero nadie eligió su rol ni llenó el resto del perfil (eso
 * antes solo pasaba en RegisterScreen, vía correo/contraseña). AppNavigator
 * manda aquí cuando `needsOnboarding` está prendido (AuthContext).
 *
 * Mismos roles y mismos campos que RegisterScreen — nunca escribe email ni
 * password (ya vienen de la sesión de Google).
 */
import React, { useState } from 'react';
import {
  Alert,
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
import { Music, User } from 'lucide-react-native';
import { supabase } from '../../config/supabase';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';
import Button from '../../components/ui/Button';
import Input from '../../components/ui/Input';
import Particles from '../../components/ui/Particles';
import { useAuth } from '../../context/AuthContext';

type RoleKey = 'client' | 'talent';
interface RoleDef { key: RoleKey; label: string; emoji: string; desc: string }

const ROLES: RoleDef[] = [
  { key: 'client', label: 'Soy Cliente', emoji: '🎉', desc: 'Contrata artistas para tu evento' },
  { key: 'talent', label: 'Soy Talento', emoji: '🎤', desc: 'Bolsa de trabajo musical' },
];

export default function CompleteProfileScreen() {
  const { t } = useTranslation();
  const { user, refetchProfile, signOut } = useAuth();

  const googleName = (user?.user_metadata as any)?.full_name
    ?? (user?.user_metadata as any)?.name
    ?? '';

  const [fullName, setFullName] = useState(googleName);
  const [role, setRole] = useState<RoleKey>('client');
  const [instrument, setInstrument] = useState('');
  const [expYears, setExpYears] = useState('');
  const [bio, setBio] = useState('');
  const [phone, setPhone] = useState('');
  const [termsAccepted, setTermsAccepted] = useState(false);
  const [loading, setLoading] = useState(false);

  const handleSubmit = async () => {
    if (!user) return;
    if (!fullName.trim()) {
      Alert.alert(t('common.error'), t('common.required'));
      return;
    }
    if (role === 'talent' && !instrument.trim()) {
      Alert.alert(t('common.error'), t('common.required'));
      return;
    }
    if (!termsAccepted) {
      Alert.alert(t('registerScreen.alertTermsTitle'), t('registerScreen.alertTermsMessage'));
      return;
    }

    setLoading(true);
    const { error } = await supabase.from('profiles').upsert(
      {
        id: user.id,
        email: user.email,
        full_name: fullName.trim(),
        role,
        phone: role === 'talent' && phone.trim() ? phone.trim() : null,
        phone_verified: false,
        id_verified: false,
        terms_accepted_at: new Date().toISOString(),
      },
      { onConflict: 'id' }
    );

    if (error) {
      setLoading(false);
      Alert.alert(t('registerScreen.alertErrorTitle'), error.message);
      return;
    }

    if (role === 'talent') {
      await supabase.from('job_board_profiles').upsert(
        {
          user_id: user.id,
          instrument_or_role: instrument.trim(),
          experience_years: parseInt(expYears) || 0,
          bio: bio.trim() || null,
          is_visible: true,
          availability_status: 'available',
        },
        { onConflict: 'user_id' }
      );
    }

    await refetchProfile();
    setLoading(false);
  };

  return (
    <View style={s.container}>
      <Particles />
      <SafeAreaView style={{ flex: 1 }}>
        <KeyboardAvoidingView style={{ flex: 1 }} behavior={Platform.OS === 'ios' ? 'padding' : undefined}>
          <ScrollView contentContainerStyle={s.scroll} keyboardShouldPersistTaps="handled" showsVerticalScrollIndicator={false}>
            <View style={s.logoRow}>
              <Text style={s.logoWhite}>Darice<Text style={s.logoGreen}>fy</Text></Text>
            </View>

            <Text style={s.title}>¡Ya casi! Completa tu perfil</Text>
            <Text style={s.subtitle}>
              Entraste con {user?.email} — solo falta esto para terminar.
            </Text>

            <Text style={s.label}>¿Qué quieres hacer en Daricefy?</Text>
            <View style={s.roleGrid}>
              {ROLES.map((r) => (
                <Pressable
                  key={r.key}
                  style={[s.roleCard, role === r.key && s.roleCardActive]}
                  onPress={() => setRole(r.key)}
                >
                  <Text style={s.roleEmoji}>{r.emoji}</Text>
                  <Text style={[s.roleLabel, role === r.key && s.roleLabelActive]}>{r.label}</Text>
                  <Text style={s.roleDesc}>{r.desc}</Text>
                </Pressable>
              ))}
            </View>

            <Input
              label="Nombre completo"
              placeholder="Ej. Ana Torres"
              value={fullName}
              onChangeText={setFullName}
              icon={<User size={18} color={COLORS.muted} />}
            />

            {role === 'talent' && (
              <View style={s.extraSection}>
                <View style={s.sectionHeader}>
                  <Music size={16} color={COLORS.green} />
                  <Text style={s.sectionHeaderText}>{t('registerScreen.talentSectionTitle')}</Text>
                </View>
                <Input
                  label={t('registerScreen.instrumentLabel')}
                  placeholder={t('registerScreen.instrumentPlaceholder')}
                  value={instrument}
                  onChangeText={setInstrument}
                  icon={<Music size={18} color={COLORS.muted} />}
                />
                <Input
                  label={t('registerScreen.experienceLabel')}
                  placeholder={t('registerScreen.experiencePlaceholder')}
                  value={expYears}
                  onChangeText={setExpYears}
                  keyboardType="numeric"
                />
                <Input
                  label={t('registerScreen.bioLabel')}
                  placeholder={t('registerScreen.bioPlaceholder')}
                  value={bio}
                  onChangeText={setBio}
                  multiline
                  numberOfLines={3}
                />
                <Input
                  label={t('registerScreen.phoneLabel')}
                  placeholder={t('registerScreen.phonePlaceholder')}
                  value={phone}
                  onChangeText={setPhone}
                  keyboardType="phone-pad"
                />
              </View>
            )}

            <Pressable style={s.legalRow} onPress={() => setTermsAccepted((v) => !v)} hitSlop={6}>
              <View style={[s.legalCheck, termsAccepted && s.legalCheckOn]}>
                {termsAccepted && <Text style={s.legalCheckMark}>✓</Text>}
              </View>
              <Text style={s.legalNote}>
                {t('registerScreen.legalAccept')}
                <Text style={s.legalLink}>{t('registerScreen.legalTerms')}</Text>
                {t('registerScreen.legalAnd')}
                <Text style={s.legalLink}>{t('registerScreen.legalPrivacy')}</Text>.
              </Text>
            </Pressable>

            <View style={{ marginTop: 8 }}>
              <Button label="Terminar" onPress={handleSubmit} loading={loading} size="lg" />
            </View>

            <Pressable style={s.signOutBtn} onPress={signOut} disabled={loading}>
              <Text style={s.signOutText}>Cancelar y salir</Text>
            </Pressable>
          </ScrollView>
        </KeyboardAvoidingView>
      </SafeAreaView>
    </View>
  );
}

const s = StyleSheet.create({
  container: { flex: 1, backgroundColor: COLORS.bg },
  scroll: { flexGrow: 1, padding: SPACING.xl, paddingTop: 40 },
  logoRow: { flexDirection: 'row', gap: 4, marginBottom: 32 },
  logoWhite: { fontFamily: FONTS.title, fontSize: 18, color: COLORS.text, letterSpacing: -0.5 },
  logoGreen: { fontFamily: FONTS.title, fontSize: 18, color: COLORS.green, letterSpacing: -0.5 },
  title: { fontFamily: FONTS.title, fontSize: 26, color: COLORS.text, marginBottom: 6 },
  subtitle: { fontFamily: FONTS.body, fontSize: 14, color: COLORS.muted2, marginBottom: 24 },
  label: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted2, marginBottom: 12 },

  roleGrid: { flexDirection: 'row', flexWrap: 'wrap', gap: 10, marginBottom: 20 },
  roleCard: {
    width: '47%', paddingVertical: 16, paddingHorizontal: 10, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border, backgroundColor: COLORS.card,
    alignItems: 'center', gap: 4,
  },
  roleCardActive: { borderColor: COLORS.green, backgroundColor: COLORS.greenMuted },
  roleEmoji: { fontSize: 24, marginBottom: 2 },
  roleLabel: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.muted2, textAlign: 'center' },
  roleLabelActive: { color: COLORS.green },
  roleDesc: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted, textAlign: 'center', marginTop: 2 },

  extraSection: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg, borderWidth: 1,
    borderColor: COLORS.green, padding: SPACING.lg, marginBottom: 8, gap: 2,
  },
  sectionHeader: { flexDirection: 'row', alignItems: 'center', gap: 8, marginBottom: 12 },
  sectionHeaderText: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.green },

  legalRow: { flexDirection: 'row', alignItems: 'flex-start', gap: 10, marginTop: 14, paddingHorizontal: 4 },
  legalCheck: {
    width: 22, height: 22, borderRadius: 6, marginTop: 1,
    borderWidth: 1.5, borderColor: COLORS.muted2, alignItems: 'center', justifyContent: 'center',
  },
  legalCheckOn: { borderColor: COLORS.green, backgroundColor: 'rgba(0,230,118,0.15)' },
  legalCheckMark: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.green },
  legalNote: { flex: 1, fontFamily: FONTS.body, fontSize: 11.5, color: COLORS.muted2, lineHeight: 17 },
  legalLink: { fontFamily: FONTS.bodySemiBold, fontSize: 11.5, color: COLORS.green, textDecorationLine: 'underline' },

  signOutBtn: { alignSelf: 'center', marginTop: 18, padding: 8 },
  signOutText: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted, textDecorationLine: 'underline' },
});
