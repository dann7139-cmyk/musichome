import React, { useState } from 'react';
import {
  Pressable,
  StyleSheet,
  Text,
  TextInput,
  View,
} from 'react-native';
import { supabase } from '../config/supabase';
import { COLORS } from '../config/theme';

export default function LoginScreen({ navigation }: any) {
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');

  const handleLogin = async () => {
    const { error } = await supabase.auth.signInWithPassword({
      email,
      password,
    });

    if (error) {
      alert(error.message);
    } else {
      navigation.replace('Home');
    }
  };

  return (
    <View style={styles.container}>
      <View style={styles.logoContainer}>
        <Text style={styles.welcomeSmall}>Bienvenido a</Text>

        <View style={styles.logoRow}>
          <Text style={styles.logoLight}>DARICE</Text>
          <Text style={styles.logoBold}>FY</Text>
        </View>

        <View style={styles.logoUnderline} />
      </View>

      <Text style={styles.subtitle}>Iniciar Sesión</Text>

      <TextInput
        placeholder="Correo"
        placeholderTextColor={COLORS.textMuted}
        value={email}
        onChangeText={setEmail}
        style={styles.input}
      />

      <TextInput
        placeholder="Contraseña"
        placeholderTextColor={COLORS.textMuted}
        secureTextEntry
        value={password}
        onChangeText={setPassword}
        style={styles.input}
      />

      <Pressable style={styles.button} onPress={handleLogin}>
        <Text style={styles.buttonText}>Entrar</Text>
      </Pressable>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: COLORS.background,
    justifyContent: 'center',
    paddingHorizontal: 24,
  },

  logoContainer: {
    alignItems: 'center',
    marginBottom: 40,
  },

  welcomeSmall: {
    fontSize: 14,
    color: COLORS.textSecondary,
    marginBottom: 8,
  },

  logoRow: {
    flexDirection: 'row',
  },

  logoLight: {
    fontSize: 34,
    fontWeight: '300',
    color: COLORS.text,
    letterSpacing: 2,
  },

  logoBold: {
    fontSize: 34,
    fontWeight: '700',
    color: COLORS.primary,
    letterSpacing: 2,
  },

  logoUnderline: {
    width: 60,
    height: 3,
    backgroundColor: COLORS.primary,
    marginTop: 10,
    borderRadius: 2,
  },

  subtitle: {
    fontSize: 18,
    color: COLORS.textSecondary,
    marginBottom: 20,
    textAlign: 'center',
  },

  input: {
    backgroundColor: COLORS.surface,
    padding: 14,
    borderRadius: 12,
    marginBottom: 15,
    color: COLORS.text,
  },

  button: {
    backgroundColor: COLORS.primary,
    padding: 16,
    borderRadius: 12,
    alignItems: 'center',
    marginTop: 10,
  },

  buttonText: {
    color: COLORS.black,
    fontWeight: 'bold',
    fontSize: 16,
  },
});
