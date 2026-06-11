import React from 'react';
import { ActivityIndicator, Pressable, StyleSheet, Text } from 'react-native';
import { COLORS, FONTS, RADIUS } from '../../config/theme';

interface Props {
  label: string;
  onPress: () => void;
  variant?: 'primary' | 'outline' | 'ghost' | 'danger';
  loading?: boolean;
  disabled?: boolean;
  size?: 'sm' | 'md' | 'lg';
  fullWidth?: boolean;
}

export default function Button({
  label,
  onPress,
  variant = 'primary',
  loading = false,
  disabled = false,
  size = 'md',
  fullWidth = true,
}: Props) {
  const isDisabled = disabled || loading;

  return (
    <Pressable
      onPress={onPress}
      disabled={isDisabled}
      style={({ pressed }) => [
        styles.base,
        styles[variant],
        styles[size],
        fullWidth && styles.fullWidth,
        isDisabled && styles.disabled,
        pressed && !isDisabled && styles.pressed,
      ]}
    >
      {loading ? (
        <ActivityIndicator color={variant === 'primary' ? COLORS.black : COLORS.green} size="small" />
      ) : (
        <Text style={[styles.label, styles[`label_${variant}`], styles[`label_${size}`]]}>
          {label}
        </Text>
      )}
    </Pressable>
  );
}

const styles = StyleSheet.create({
  base: {
    alignItems: 'center',
    justifyContent: 'center',
    borderRadius: RADIUS.md,
  },
  fullWidth: { width: '100%' },
  // variants
  primary: {
    backgroundColor: COLORS.green,
  },
  outline: {
    backgroundColor: 'transparent',
    borderWidth: 1,
    borderColor: COLORS.green,
  },
  ghost: {
    backgroundColor: COLORS.greenMuted,
  },
  danger: {
    backgroundColor: COLORS.red,
  },
  // sizes
  sm: { paddingVertical: 10, paddingHorizontal: 16 },
  md: { paddingVertical: 14, paddingHorizontal: 20 },
  lg: { paddingVertical: 18, paddingHorizontal: 24 },
  // states
  disabled: { opacity: 0.45 },
  pressed: { opacity: 0.8 },
  // labels
  label: { fontFamily: FONTS.bodySemiBold, letterSpacing: 0.3 },
  label_primary: { color: COLORS.black, fontSize: 15 },
  label_outline: { color: COLORS.green, fontSize: 15 },
  label_ghost: { color: COLORS.green, fontSize: 15 },
  label_danger: { color: COLORS.white, fontSize: 15 },
  label_sm: { fontSize: 13 },
  label_md: { fontSize: 15 },
  label_lg: { fontSize: 16 },
});
