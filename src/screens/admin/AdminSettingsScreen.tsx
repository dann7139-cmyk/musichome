import React, { useState } from 'react';
import { ActivityIndicator, Alert, Pressable, StyleSheet, Switch, Text, View } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { supabase } from '../../config/supabase';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';
import { useAuth } from '../../context/AuthContext';

// sql/632 (2026-09-08) — interruptor para que la cuenta admin completa
// deje de recibir alertas de un país, una vez que haya un admin_ops
// contratado ahí (no-shows, pagos, verificación — las 3 colas de
// sql/628-631). Vacío por defecto = comportamiento actual sin cambio.
// Pantalla nueva y separada a propósito: no toca ProfileScreen.tsx
// (compartida con client/group/talent) ni DashboardScreen.tsx.
export default function AdminSettingsScreen() {
  const { profile, refetchProfile } = useAuth();
  const [saving, setSaving] = useState<'US' | 'CA' | null>(null);
  const muted = profile?.admin_muted_countries ?? [];

  const toggle = async (country: 'US' | 'CA') => {
    const next = muted.includes(country) ? muted.filter(c => c !== country) : [...muted, country];
    setSaving(country);
    const { data, error } = await supabase.rpc('admin_set_muted_countries', { p_countries: next });
    setSaving(null);
    if (error || (data as any)?.ok === false) {
      Alert.alert('Error', (data as any)?.error ?? error?.message ?? 'No se pudo guardar');
      return;
    }
    await refetchProfile();
  };

  return (
    <View style={{ flex: 1, backgroundColor: COLORS.bg }}>
      <SafeAreaView edges={['top']} style={s.header}>
        <Text style={s.headerTitle}>⚙️ Ajustes</Text>
      </SafeAreaView>

      <View style={s.body}>
        <Text style={s.sectionTitle}>Alertas por país</Text>
        <Text style={s.sectionHint}>
          Apaga un país cuando ya tengas a alguien contratado ahí (cuenta de admin con alcance) — dejarás
          de recibir sus alertas de no-shows, pagos y verificación. Tu acceso completo a la app no cambia.
        </Text>

        <View style={s.row}>
          <View style={{ flex: 1 }}>
            <Text style={s.rowTitle}>🇺🇸 Estados Unidos</Text>
            <Text style={s.rowSub}>{muted.includes('US') ? 'Apagado — no te llegan sus alertas' : 'Activo — te llegan sus alertas'}</Text>
          </View>
          {saving === 'US' ? (
            <ActivityIndicator color={COLORS.green} />
          ) : (
            <Switch
              value={!muted.includes('US')}
              onValueChange={() => toggle('US')}
              trackColor={{ false: COLORS.border, true: COLORS.greenMuted }}
              thumbColor={!muted.includes('US') ? COLORS.green : COLORS.muted2}
            />
          )}
        </View>

        <View style={s.row}>
          <View style={{ flex: 1 }}>
            <Text style={s.rowTitle}>🇨🇦 Canadá</Text>
            <Text style={s.rowSub}>{muted.includes('CA') ? 'Apagado — no te llegan sus alertas' : 'Activo — te llegan sus alertas'}</Text>
          </View>
          {saving === 'CA' ? (
            <ActivityIndicator color={COLORS.green} />
          ) : (
            <Switch
              value={!muted.includes('CA')}
              onValueChange={() => toggle('CA')}
              trackColor={{ false: COLORS.border, true: COLORS.greenMuted }}
              thumbColor={!muted.includes('CA') ? COLORS.green : COLORS.muted2}
            />
          )}
        </View>
      </View>
    </View>
  );
}

const s = StyleSheet.create({
  header: { paddingHorizontal: SPACING.xl, paddingBottom: 12 },
  headerTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 18, color: COLORS.text },
  body: { padding: SPACING.xl, gap: 16 },
  sectionTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.text },
  sectionHint: { fontFamily: FONTS.body, fontSize: 12.5, color: COLORS.muted2, lineHeight: 18, marginTop: -8 },
  row: {
    flexDirection: 'row', alignItems: 'center', gap: 12,
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg, borderWidth: 1, borderColor: COLORS.border,
    padding: 14,
  },
  rowTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.text },
  rowSub: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, marginTop: 2 },
});
