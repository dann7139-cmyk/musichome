import { Check, ShieldCheck } from 'lucide-react-native';
import React from 'react';
import { View, ViewStyle } from 'react-native';

export type BadgeTier = 'free' | 'plus';

export default function VerifiedBadge({
  size  = 18,
  style,
  tier  = 'free',
}: {
  size?:  number;
  style?: ViewStyle;
  tier?:  BadgeTier;
}) {
  // Plus activo — círculo verde premium (mismo tamaño que free, sin layout shift)
  if (tier === 'plus') {
    const inner = Math.round(size * 0.62);
    return (
      <View style={[{
        width: size, height: size, borderRadius: size / 2,
        backgroundColor: '#00E676',
        alignItems: 'center', justifyContent: 'center',
      }, style]}>
        <ShieldCheck size={inner} color="#040404" strokeWidth={2.8} />
      </View>
    );
  }

  // Badge gratuito: idéntico al original
  return (
    <View
      style={[{
        width:           size,
        height:          size,
        borderRadius:    size / 2,
        backgroundColor: '#1A77F2',
        alignItems:      'center',
        justifyContent:  'center',
      }, style]}
    >
      <Check size={Math.round(size * 0.58)} color="#fff" strokeWidth={3.5} />
    </View>
  );
}
