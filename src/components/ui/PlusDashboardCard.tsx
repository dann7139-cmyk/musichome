import React, { useEffect, useState } from 'react';
import { ActivityIndicator, Pressable, StyleSheet, Text, View } from 'react-native';
import { AlertCircle, ChevronRight, ShieldCheck } from 'lucide-react-native';
import { LinearGradient } from 'expo-linear-gradient';
import { supabase } from '../../config/supabase';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';

interface PlusStatus {
  is_active: boolean;
  status: string;
  trial_ends_at: string | null;
  expires_at: string | null;
}

interface Props {
  navigation: any;
  groupId: string | null;
}

function daysUntil(dateStr: string | null): number {
  if (!dateStr) return 0;
  return Math.max(0, Math.ceil((new Date(dateStr).getTime() - Date.now()) / 86_400_000));
}

function fmtDate(dateStr: string | null): string {
  if (!dateStr) return '';
  return new Date(dateStr).toLocaleDateString('es-MX', { day: 'numeric', month: 'long', year: 'numeric' });
}

export default function PlusDashboardCard({ navigation, groupId }: Props) {
  const [plusStatus, setPlusStatus] = useState<PlusStatus | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    if (!groupId) { setLoading(false); return; }
    supabase
      .rpc('get_my_plus_status', { p_group_id: groupId })
      .then(({ data, error }) => {
        if (!error && data && data.length > 0) setPlusStatus(data[0]);
        setLoading(false);
      });
  }, [groupId]);

  const goToPlus = () => navigation.navigate('Plus', { groupId });

  if (loading) {
    return (
      <View style={s.loadingWrap}>
        <ActivityIndicator size="small" color={COLORS.green} />
      </View>
    );
  }

  const st = plusStatus?.status ?? 'inactive';

  // ── Activa o en prueba ────────────────────────────────────────────────────────
  if (st === 'active' || st === 'trialing') {
    const isTrialing = st === 'trialing';
    const days = isTrialing ? daysUntil(plusStatus?.trial_ends_at ?? null) : null;
    const renewLabel = isTrialing
      ? `${days} día${days !== 1 ? 's' : ''} restantes en prueba`
      : `Renueva el ${fmtDate(plusStatus?.expires_at ?? null)}`;

    return (
      <Pressable onPress={goToPlus} style={s.wrap}>
        <LinearGradient
          colors={['rgba(0,230,118,0.12)', 'rgba(0,200,83,0.05)']}
          start={{ x: 0, y: 0 }}
          end={{ x: 1, y: 1 }}
          style={s.card}
        >
          <View style={s.iconWrap}>
            <ShieldCheck size={22} color={COLORS.green} strokeWidth={2.5} />
          </View>
          <View style={s.body}>
            <Text style={s.title}>
              Plus {isTrialing ? '· Prueba gratuita' : '· Activa'}
            </Text>
            <Text style={s.sub}>{renewLabel}</Text>
          </View>
          <ChevronRight size={18} color={COLORS.green} />
        </LinearGradient>
      </Pressable>
    );
  }

  // ── Pago fallido ──────────────────────────────────────────────────────────────
  if (st === 'past_due' || st === 'unpaid') {
    return (
      <Pressable onPress={goToPlus} style={s.wrap}>
        <View style={[s.card, s.cardAlert]}>
          <View style={[s.iconWrap, s.iconAlert]}>
            <AlertCircle size={22} color={COLORS.red} strokeWidth={2.5} />
          </View>
          <View style={s.body}>
            <Text style={[s.title, s.titleAlert]}>Plus pausada</Text>
            <Text style={s.sub}>Actualiza tu tarjeta para reactivar</Text>
          </View>
          <ChevronRight size={18} color={COLORS.red} />
        </View>
      </Pressable>
    );
  }

  // ── Inactiva ──────────────────────────────────────────────────────────────────
  return (
    <Pressable onPress={goToPlus} style={s.wrap}>
      <LinearGradient
        colors={['rgba(0,230,118,0.07)', 'rgba(0,230,118,0.02)']}
        start={{ x: 0, y: 0 }}
        end={{ x: 1, y: 1 }}
        style={[s.card, s.cardInactive]}
      >
        <View style={[s.iconWrap, s.iconInactive]}>
          <ShieldCheck size={22} color={COLORS.green} strokeWidth={2} />
        </View>
        <View style={s.body}>
          <Text style={s.title}>Verificación Plus</Text>
          <Text style={s.sub}>Aparece primero · 7 días gratis</Text>
        </View>
        <View style={s.ctaBadge}>
          <Text style={s.ctaText}>Activar</Text>
        </View>
      </LinearGradient>
    </Pressable>
  );
}

const s = StyleSheet.create({
  loadingWrap: {
    marginHorizontal: SPACING.xl,
    marginTop: 16,
    height: 68,
    alignItems: 'center',
    justifyContent: 'center',
  },
  wrap: {
    marginHorizontal: SPACING.xl,
    marginTop: 16,
    borderRadius: RADIUS.lg,
    overflow: 'hidden',
  },
  card: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 12,
    padding: 14,
    borderRadius: RADIUS.lg,
    borderWidth: 1,
    borderColor: 'rgba(0,230,118,0.22)',
  },
  cardInactive: {
    borderColor: 'rgba(0,230,118,0.12)',
  },
  cardAlert: {
    backgroundColor: 'rgba(239,83,80,0.06)',
    borderColor: 'rgba(239,83,80,0.22)',
  },
  iconWrap: {
    width: 42,
    height: 42,
    borderRadius: 21,
    backgroundColor: 'rgba(0,230,118,0.12)',
    alignItems: 'center',
    justifyContent: 'center',
  },
  iconInactive: {
    backgroundColor: 'rgba(0,230,118,0.07)',
  },
  iconAlert: {
    backgroundColor: 'rgba(239,83,80,0.10)',
  },
  body: { flex: 1 },
  title: {
    fontFamily: FONTS.bodySemiBold,
    fontSize: 14,
    color: COLORS.text,
  },
  titleAlert: {
    color: COLORS.red,
  },
  sub: {
    fontFamily: FONTS.body,
    fontSize: 12,
    color: COLORS.muted2,
    marginTop: 2,
  },
  ctaBadge: {
    backgroundColor: COLORS.green,
    borderRadius: 20,
    paddingHorizontal: 14,
    paddingVertical: 6,
  },
  ctaText: {
    fontFamily: FONTS.bodySemiBold,
    fontSize: 12,
    color: '#000',
  },
});
