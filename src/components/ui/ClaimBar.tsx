import React from 'react';
import { Pressable, StyleSheet, Text, View } from 'react-native';
import { COLORS, FONTS, RADIUS } from '../../config/theme';
import type { AdminClaim } from '../../hooks/useAdminClaims';

/** Franja de "en trabajo" para las 4 colas con sql/660 (ver useAdminClaims). */
export function ClaimBar({ claim, onClaim, onRelease, busy }: {
  claim?: AdminClaim;
  onClaim: () => void;
  onRelease: () => void;
  busy?: boolean;
}) {
  if (claim && !claim.is_mine) {
    return (
      <View style={s.lockedRow}>
        <Text style={s.lockedText}>🔒 En trabajo por {claim.claimed_by_name ?? 'otro admin'}</Text>
      </View>
    );
  }
  if (claim?.is_mine) {
    return (
      <Pressable style={s.mineRow} onPress={onRelease} disabled={busy}>
        <Text style={s.mineText}>👤 Lo estás atendiendo tú · toca para liberar</Text>
      </Pressable>
    );
  }
  return (
    <Pressable style={s.takeBtn} onPress={onClaim} disabled={busy}>
      <Text style={s.takeBtnText}>✋ Tomar este caso</Text>
    </Pressable>
  );
}

const s = StyleSheet.create({
  lockedRow: {
    paddingVertical: 6, paddingHorizontal: 10, borderRadius: RADIUS.md, alignSelf: 'flex-start',
    backgroundColor: 'rgba(239, 83, 80, 0.14)', borderWidth: 1, borderColor: COLORS.red,
  },
  lockedText: { fontFamily: FONTS.bodyMedium, fontSize: 11.5, color: COLORS.red },
  mineRow: {
    paddingVertical: 6, paddingHorizontal: 10, borderRadius: RADIUS.md, alignSelf: 'flex-start',
    backgroundColor: COLORS.greenMuted, borderWidth: 1, borderColor: COLORS.green,
  },
  mineText: { fontFamily: FONTS.bodyMedium, fontSize: 11.5, color: COLORS.green },
  takeBtn: {
    paddingVertical: 6, paddingHorizontal: 10, borderRadius: RADIUS.md, alignSelf: 'flex-start',
    backgroundColor: COLORS.card2, borderWidth: 1, borderColor: COLORS.border,
  },
  takeBtnText: { fontFamily: FONTS.bodyMedium, fontSize: 11.5, color: COLORS.muted2 },
});
