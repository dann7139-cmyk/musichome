import { Headphones } from 'lucide-react-native';
import React from 'react';
import { StyleSheet, Text, View } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import Particles from '../../components/ui/Particles';
import { COLORS, FONTS } from '../../config/theme';

export default function PistasScreen() {
  return (
    <View style={styles.container}>
      <Particles />
      <SafeAreaView style={styles.safe}>
        <View style={styles.content}>
          <View style={styles.iconBox}>
            <Headphones size={48} color={COLORS.green} strokeWidth={1.5} />
          </View>
          <Text style={styles.title}>Pistas</Text>
          <Text style={styles.sub}>Próximamente podrás comprar{'\n'}pistas musicales exclusivas</Text>
          <View style={styles.badge}>
            <Text style={styles.badgeText}>EN DESARROLLO</Text>
          </View>
        </View>
      </SafeAreaView>
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: COLORS.bg },
  safe: { flex: 1 },
  content: { flex: 1, alignItems: 'center', justifyContent: 'center', paddingHorizontal: 32 },
  iconBox: {
    width: 100, height: 100, borderRadius: 28,
    backgroundColor: 'rgba(0,230,118,0.08)',
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.25)',
    alignItems: 'center', justifyContent: 'center',
    marginBottom: 24,
  },
  title: { fontFamily: FONTS.title, fontSize: 32, color: COLORS.text, marginBottom: 12 },
  sub: { fontFamily: FONTS.body, fontSize: 15, color: COLORS.muted2, textAlign: 'center', lineHeight: 22, marginBottom: 24 },
  badge: {
    paddingHorizontal: 16, paddingVertical: 7,
    borderRadius: 999, borderWidth: 1,
    borderColor: COLORS.green, backgroundColor: 'rgba(0,230,118,0.1)',
  },
  badgeText: { fontFamily: FONTS.bodySemiBold, fontSize: 11, color: COLORS.green, letterSpacing: 1.5 },
});
