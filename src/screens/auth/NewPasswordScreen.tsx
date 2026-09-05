/**
 * NewPasswordScreen — se muestra SOLO cuando AuthContext detecta una
 * sesión de recuperación (link de "¿Olvidaste tu contraseña?" tocado
 * desde el correo, 2026-09-05). No es una pantalla a la que se navegue
 * normalmente — AppNavigator la fuerza mientras `passwordRecovery` esté
 * activo, antes que cualquier otra pantalla.
 */
import { LinearGradient } from 'expo-linear-gradient';
import { Lock } from 'lucide-react-native';
import React, { useState } from 'react';
import {
  Alert,
  KeyboardAvoidingView,
  Platform,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { supabase } from '../../config/supabase';
import { useAuth } from '../../context/AuthContext';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';
import Button from '../../components/ui/Button';
import Input from '../../components/ui/Input';
import Particles from '../../components/ui/Particles';

export default function NewPasswordScreen() {
  const { clearPasswordRecovery } = useAuth();
  const [password, setPassword] = useState('');
  const [confirmPassword, setConfirmPassword] = useState('');
  const [loading, setLoading] = useState(false);

  const handleSave = async () => {
    if (password.length < 6) {
      Alert.alert('Error', 'La contraseña debe tener al menos 6 caracteres.');
      return;
    }
    if (password !== confirmPassword) {
      Alert.alert('Error', 'Las contraseñas no coinciden.');
      return;
    }
    setLoading(true);
    const { error } = await supabase.auth.updateUser({ password });
    setLoading(false);
    if (error) {
      Alert.alert('Error', error.message);
      return;
    }
    Alert.alert(
      '✓ Contraseña actualizada',
      'Inicia sesión con tu contraseña nueva.',
      [{ text: 'Entendido', onPress: () => clearPasswordRecovery() }],
    );
  };

  return (
    <View style={styles.container}>
      <Particles />

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
            <View style={styles.hero}>
              <View style={styles.logoIconWrap}>
                <Lock size={26} color={COLORS.green} />
              </View>
              <Text style={styles.logoText}>Nueva contraseña</Text>
              <Text style={styles.heroSub}>
                Escribe tu nueva contraseña para volver a entrar a tu cuenta.
              </Text>
            </View>

            <View style={styles.card}>
              <LinearGradient
                colors={[COLORS.green, 'rgba(0,230,118,0)']}
                start={{ x: 0, y: 0 }} end={{ x: 1, y: 0 }}
                style={styles.cardAccent}
              />

              <Input
                label="Contraseña nueva"
                placeholder="Mínimo 6 caracteres"
                value={password}
                onChangeText={setPassword}
                secureTextEntry
                autoCapitalize="none"
                autoCorrect={false}
                textContentType="newPassword"
                icon={<Lock size={18} color={COLORS.muted} />}
              />

              <Input
                label="Confirmar contraseña"
                placeholder="Repite la contraseña"
                value={confirmPassword}
                onChangeText={setConfirmPassword}
                secureTextEntry
                autoCapitalize="none"
                autoCorrect={false}
                textContentType="newPassword"
                icon={<Lock size={18} color={COLORS.muted} />}
              />

              <View style={{ height: 4 }} />
              <Button label="Guardar contraseña" onPress={handleSave} loading={loading} size="lg" />
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
  hero: { alignItems: 'center', marginBottom: 36 },
  logoIconWrap: {
    width: 56, height: 56, borderRadius: 28,
    backgroundColor: 'rgba(0,230,118,0.12)', borderWidth: 1,
    borderColor: 'rgba(0,230,118,0.3)', alignItems: 'center',
    justifyContent: 'center', marginBottom: 12,
  },
  logoText: {
    fontFamily: FONTS.title, fontSize: 22,
    color: COLORS.text, textAlign: 'center',
  },
  heroSub: {
    fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2,
    textAlign: 'center', marginTop: 8, paddingHorizontal: 12, lineHeight: 19,
  },
  card: {
    backgroundColor: COLORS.card,
    borderRadius: RADIUS.xl ?? 20,
    borderWidth: 1, borderColor: COLORS.border,
    padding: SPACING.xl,
    paddingTop: 0,
    overflow: 'hidden',
  },
  cardAccent: { height: 2, marginBottom: 24, borderRadius: 1 },
});
