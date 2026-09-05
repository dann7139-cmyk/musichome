import React, { useState } from 'react';
import { Pressable, StyleSheet, Text, TextInput, TextInputProps, View } from 'react-native';
import { Eye, EyeOff } from 'lucide-react-native';
import { COLORS, FONTS, RADIUS } from '../../config/theme';

interface Props extends TextInputProps {
  label?: string;
  error?: string;
  icon?: React.ReactNode;
}

// 🔒 Ojito para ver/ocultar la contraseña — petición real (2026-09-05):
// "que cuando estén poniendo la contraseña tenga el ojo para poder ver
// si está bien". Se agrega aquí (no en cada pantalla) para que aplique
// en Login/Registro/Intro de una sola vez. Mismo ícono Eye/EyeOff que ya
// usaba ProfileScreen.tsx en su propio modal de cambiar contraseña.
export default function Input({ label, error, icon, style, secureTextEntry, ...props }: Props) {
  const [focused, setFocused] = useState(false);
  const [visible, setVisible] = useState(false);
  const isPassword = !!secureTextEntry;

  return (
    <View style={styles.wrapper}>
      {label && <Text style={styles.label}>{label}</Text>}
      <View style={[styles.inputRow, focused && styles.inputFocused, error && styles.inputError]}>
        {icon && <View style={styles.icon}>{icon}</View>}
        <TextInput
          style={[styles.input, style]}
          placeholderTextColor={COLORS.muted}
          onFocus={() => setFocused(true)}
          onBlur={() => setFocused(false)}
          secureTextEntry={isPassword && !visible}
          {...props}
        />
        {isPassword && (
          <Pressable onPress={() => setVisible(v => !v)} hitSlop={10} style={styles.eyeBtn}>
            {visible
              ? <EyeOff size={18} color={COLORS.muted2} />
              : <Eye size={18} color={COLORS.muted2} />}
          </Pressable>
        )}
      </View>
      {error && <Text style={styles.error}>{error}</Text>}
    </View>
  );
}

const styles = StyleSheet.create({
  wrapper: { marginBottom: 16 },
  label: {
    fontFamily: FONTS.bodyMedium,
    fontSize: 13,
    color: COLORS.muted2,
    marginBottom: 8,
  },
  inputRow: {
    flexDirection: 'row',
    alignItems: 'center',
    backgroundColor: COLORS.card2,
    borderRadius: RADIUS.md,
    borderWidth: 1,
    borderColor: COLORS.border,
    paddingHorizontal: 16,
  },
  inputFocused: {
    borderColor: COLORS.green,
  },
  inputError: {
    borderColor: COLORS.red,
  },
  icon: { marginRight: 10 },
  eyeBtn: { marginLeft: 8, padding: 4 },
  input: {
    flex: 1,
    paddingVertical: 14,
    fontFamily: FONTS.body,
    fontSize: 15,
    color: COLORS.text,
  },
  error: {
    fontFamily: FONTS.body,
    fontSize: 12,
    color: COLORS.red,
    marginTop: 4,
  },
});
