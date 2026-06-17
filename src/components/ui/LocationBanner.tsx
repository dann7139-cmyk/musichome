import React from 'react';
import { Pressable, StyleSheet, Text, View } from 'react-native';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';

interface Props {
  profileState:  string;
  detectedState: string;
  onUseHere:     () => void;
  onUseHome:     () => void;
}

export default function LocationBanner({
  profileState,
  detectedState,
  onUseHere,
  onUseHome,
}: Props) {
  return (
    <View style={styles.container}>
      <Text style={styles.text}>
        {'📍 Parece que estás en '}
        <Text style={styles.highlight}>{detectedState}</Text>
        {'  ·  ¿qué grupos quieres ver?'}
      </Text>
      <View style={styles.row}>
        <Pressable
          style={({ pressed }) => [styles.btn, styles.btnHere, pressed && styles.pressed]}
          onPress={onUseHere}
          hitSlop={8}
        >
          <Text style={styles.btnHereLabel}>Aquí</Text>
        </Pressable>
        <Pressable
          style={({ pressed }) => [styles.btn, styles.btnHome, pressed && styles.pressed]}
          onPress={onUseHome}
          hitSlop={8}
        >
          <Text style={styles.btnHomeLabel}>{profileState} (mi casa)</Text>
        </Pressable>
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    marginHorizontal: SPACING.xl,
    marginBottom: SPACING.md,
    backgroundColor: 'rgba(255, 179, 0, 0.10)',
    borderLeftWidth: 3,
    borderLeftColor: COLORS.gold,
    borderRadius: RADIUS.sm,
    paddingHorizontal: SPACING.md,
    paddingVertical: SPACING.sm,
  },
  text: {
    fontFamily: FONTS.body,
    fontSize: 13,
    color: COLORS.gold,
    lineHeight: 19,
    marginBottom: 4,
  },
  highlight: {
    fontFamily: FONTS.bodySemiBold,
    color: COLORS.gold,
  },
  row: {
    flexDirection: 'row',
    gap: SPACING.xs,
    marginTop: 4,
  },
  btn: {
    paddingHorizontal: 12,
    paddingVertical: 6,
    borderRadius: RADIUS.sm,
    borderWidth: 1,
  },
  pressed: { opacity: 0.7 },
  btnHere: {
    backgroundColor: COLORS.gold,
    borderColor: COLORS.gold,
  },
  btnHereLabel: {
    fontFamily: FONTS.bodySemiBold,
    fontSize: 12,
    color: COLORS.black,
  },
  btnHome: {
    backgroundColor: 'transparent',
    borderColor: COLORS.gold,
  },
  btnHomeLabel: {
    fontFamily: FONTS.bodySemiBold,
    fontSize: 12,
    color: COLORS.gold,
  },
});
