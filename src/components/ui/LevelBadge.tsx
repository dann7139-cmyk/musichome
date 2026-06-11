import React from 'react';
import { StyleSheet, Text, View } from 'react-native';
import { FONTS, RADIUS } from '../../config/theme';
import type { GroupLevel } from '../../types/models';

const LEVEL_CONFIG: Record<GroupLevel, {
  emoji: string;
  label: string;
  color: string;
  bg: string;
  border: string;
}> = {
  bronce: { emoji: '🥉', label: 'Bronce', color: '#CD7F32', bg: 'rgba(205,127,50,0.12)', border: 'rgba(205,127,50,0.4)' },
  plata:  { emoji: '🥈', label: 'Plata',  color: '#B0BEC5', bg: 'rgba(176,190,197,0.12)', border: 'rgba(176,190,197,0.4)' },
  oro:    { emoji: '🥇', label: 'Oro',    color: '#FFD700', bg: 'rgba(255,215,0,0.12)',  border: 'rgba(255,215,0,0.4)' },
  elite:  { emoji: '💎', label: 'Elite',  color: '#00E5FF', bg: 'rgba(0,229,255,0.12)', border: 'rgba(0,229,255,0.4)' },
};

interface Props {
  nivel?: GroupLevel | null;
  size?: 'sm' | 'md';
}

export default function LevelBadge({ nivel, size = 'md' }: Props) {
  if (!nivel) return null;
  const cfg = LEVEL_CONFIG[nivel];
  const sm = size === 'sm';

  return (
    <View style={[
      styles.badge,
      { backgroundColor: cfg.bg, borderColor: cfg.border },
      sm && styles.badgeSm,
    ]}>
      <Text style={sm ? styles.emojiSm : styles.emoji}>{cfg.emoji}</Text>
      <Text style={[styles.label, { color: cfg.color }, sm && styles.labelSm]}>
        {cfg.label}
      </Text>
    </View>
  );
}

const styles = StyleSheet.create({
  badge: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 5,
    paddingHorizontal: 10,
    paddingVertical: 5,
    borderRadius: RADIUS.full,
    borderWidth: 1,
    alignSelf: 'flex-start',
  },
  badgeSm: {
    paddingHorizontal: 7,
    paddingVertical: 3,
    gap: 3,
  },
  emoji: {
    fontSize: 14,
  },
  emojiSm: {
    fontSize: 11,
  },
  label: {
    fontFamily: FONTS.bodySemiBold,
    fontSize: 13,
  },
  labelSm: {
    fontSize: 11,
  },
});
