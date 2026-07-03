import React from 'react';
import { StyleSheet, Text, View } from 'react-native';
import { FONTS, RADIUS } from '../../config/theme';

type BadgeVariant = 'green' | 'orange' | 'blue' | 'red' | 'muted';

interface Props {
  label: string;
  variant?: BadgeVariant;
  dot?: boolean;
  small?: boolean;
}

const variantColors: Record<BadgeVariant, { bg: string; text: string; dot: string }> = {
  green:  { bg: 'rgba(0,230,118,0.12)',  text: '#00E676', dot: '#00E676' },
  orange: { bg: 'rgba(255,152,0,0.12)',  text: '#FF9800', dot: '#FF9800' },
  blue:   { bg: 'rgba(96,165,250,0.12)', text: '#60A5FA', dot: '#60A5FA' },
  red:    { bg: 'rgba(239,83,80,0.12)',  text: '#EF5350', dot: '#EF5350' },
  muted:  { bg: 'rgba(85,85,85,0.2)',    text: '#888888', dot: '#555555' },
};

export default function Badge({ label, variant = 'muted', dot = false, small = false }: Props) {
  const c = variantColors[variant];
  return (
    <View style={[styles.badge, small && styles.badgeSmall, { backgroundColor: c.bg }]}>
      {dot && <View style={[styles.dot, small && styles.dotSmall, { backgroundColor: c.dot }]} />}
      <Text style={[styles.label, small && styles.labelSmall, { color: c.text }]}>{label}</Text>
    </View>
  );
}

const styles = StyleSheet.create({
  badge: {
    flexDirection: 'row',
    alignItems: 'center',
    paddingHorizontal: 10,
    paddingVertical: 4,
    borderRadius: RADIUS.full,
    gap: 5,
    alignSelf: 'flex-start',
  },
  badgeSmall: {
    paddingHorizontal: 7,
    paddingVertical: 2,
    gap: 3,
  },
  dot: {
    width: 6,
    height: 6,
    borderRadius: 3,
  },
  dotSmall: {
    width: 5,
    height: 5,
    borderRadius: 2,
  },
  label: {
    fontFamily: FONTS.bodyMedium,
    fontSize: 12,
  },
  labelSmall: {
    fontSize: 10,
  },
});
