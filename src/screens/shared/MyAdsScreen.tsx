/**
 * MyAdsScreen — "Mi publicidad": todo lo que el anunciante (grupo o
 * cliente) ha comprado, con estado, vigencia y total gastado.
 *
 * Fuente: RPC get_my_promo_summary (sql/498) — cada quien ve lo suyo.
 * Sin datos de la plataforma: solo SUS compras.
 */

import { LinearGradient } from 'expo-linear-gradient';
import { ArrowLeft, Megaphone, Star, TrendingUp, Zap } from 'lucide-react-native';
import React, { useCallback, useEffect, useState } from 'react';
import {
  ActivityIndicator,
  Pressable,
  RefreshControl,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { supabase } from '../../config/supabase';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';

// ── Tipos ─────────────────────────────────────────────────────────────────────

interface PromoItem {
  id:         string;
  kind:       'ad' | 'bid' | 'rec';
  type?:      string;       // banner_home | sponsored_group | profile_ad (solo ads)
  title?:     string;
  status:     string;
  amount:     number | null;
  paid:       boolean;
  is_free?:   boolean;
  days?:      number;
  starts_at:  string | null;
  ends_at:    string | null;
  created_at: string;
}

interface Summary {
  ads:  PromoItem[];
  bids: PromoItem[];
  recs: PromoItem[];
  total_spent:  number;
  active_count: number;
}

// ── Helpers ───────────────────────────────────────────────────────────────────

function fmtMoney(n: number | null | undefined): string {
  if (n == null) return '—';
  return `$${Number(n).toLocaleString('es-MX', { maximumFractionDigits: 0 })}`;
}

function fmtDate(iso: string | null): string {
  if (!iso) return '—';
  return new Date(iso).toLocaleDateString('es-MX', { day: 'numeric', month: 'short' });
}

function daysLeft(iso: string | null): number {
  if (!iso) return 0;
  const d = new Date(iso).getTime() - Date.now();
  return d > 0 ? Math.ceil(d / 86_400_000) : 0;
}

// Estado visible + color (unificado entre los 3 tipos)
function statusInfo(item: PromoItem): { label: string; color: string } {
  const vivo = item.ends_at && new Date(item.ends_at) > new Date();
  switch (item.status) {
    case 'active':
      return vivo
        ? { label: `🟢 Activo · ${daysLeft(item.ends_at)} día(s)`, color: COLORS.green }
        : { label: '🟢 Activo', color: COLORS.green };
    case 'paid':
      return vivo
        ? { label: `🟢 Activo · ${daysLeft(item.ends_at)} día(s)`, color: COLORS.green }
        : { label: '⚪ Terminado', color: COLORS.muted };
    case 'pending_review':  return { label: '⏳ En revisión',        color: '#FFC107' };
    case 'pending_payment': return { label: '💳 Pendiente de pago',  color: '#FF6D00' };
    case 'expired':         return { label: '⚪ Terminado',          color: COLORS.muted };
    case 'rejected':        return { label: '❌ Rechazado',          color: '#EF5350' };
    case 'paused':          return { label: '⏸ Pausado',            color: COLORS.muted2 };
    case 'cancelled':       return { label: '❌ Cancelado',          color: COLORS.muted };
    default:                return { label: item.status,             color: COLORS.muted2 };
  }
}

function kindInfo(item: PromoItem): { label: string; icon: React.ReactNode } {
  if (item.kind === 'bid') return { label: 'Posicionamiento', icon: <TrendingUp size={15} color="#A78BFA" /> };
  if (item.kind === 'rec') return { label: 'Recomendado',     icon: <Zap size={15} color="#FF6D00" /> };
  switch (item.type) {
    case 'sponsored_group': return { label: 'Destacado',         icon: <Star size={15} color="#C9A84C" /> };
    case 'banner_home':     return { label: 'Banner Home',       icon: <Megaphone size={15} color={COLORS.green} /> };
    case 'profile_ad':      return { label: 'Anuncio en Perfil', icon: <Megaphone size={15} color="#4285F4" /> };
    default:                return { label: 'Anuncio',           icon: <Megaphone size={15} color={COLORS.green} /> };
  }
}

// ── Screen ────────────────────────────────────────────────────────────────────

export default function MyAdsScreen({ navigation }: any) {
  const [summary,    setSummary]    = useState<Summary | null>(null);
  const [loading,    setLoading]    = useState(true);
  const [refreshing, setRefreshing] = useState(false);

  const load = useCallback(async () => {
    try {
      const { data, error } = await supabase.rpc('get_my_promo_summary');
      if (error) throw error;
      if (data?.ok) {
        setSummary({
          ads:  data.ads ?? [],
          bids: data.bids ?? [],
          recs: data.recs ?? [],
          total_spent:  Number(data.total_spent ?? 0),
          active_count: Number(data.active_count ?? 0),
        });
      }
    } catch (e: any) {
      console.error('[MyAdsScreen]', e?.message);
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => { load(); }, [load]);

  const onRefresh = async () => {
    setRefreshing(true);
    await load();
    setRefreshing(false);
  };

  const allItems: PromoItem[] = summary
    ? [...summary.ads, ...summary.bids, ...summary.recs]
        .sort((a, b) => new Date(b.created_at).getTime() - new Date(a.created_at).getTime())
    : [];

  return (
    <View style={s.root}>
      <SafeAreaView edges={['top']} style={s.header}>
        <Pressable style={s.backBtn} onPress={() => navigation.goBack()}>
          <ArrowLeft size={20} color={COLORS.text} />
        </Pressable>
        <Text style={s.headerTitle}>📊 Mi publicidad</Text>
        <View style={{ width: 40 }} />
      </SafeAreaView>

      {loading ? (
        <View style={s.center}><ActivityIndicator size="large" color={COLORS.green} /></View>
      ) : (
        <ScrollView
          contentContainerStyle={s.scroll}
          showsVerticalScrollIndicator={false}
          refreshControl={<RefreshControl refreshing={refreshing} onRefresh={onRefresh} tintColor={COLORS.green} />}
        >
          {/* ── Resumen ── */}
          <LinearGradient
            colors={['rgba(0,230,118,0.10)', 'rgba(0,230,118,0.02)']}
            style={s.summaryCard}
          >
            <View style={s.summaryCol}>
              <Text style={s.summaryValue}>{fmtMoney(summary?.total_spent ?? 0)}</Text>
              <Text style={s.summaryLabel}>Invertido en total</Text>
            </View>
            <View style={s.summaryDivider} />
            <View style={s.summaryCol}>
              <Text style={[s.summaryValue, { color: COLORS.green }]}>{summary?.active_count ?? 0}</Text>
              <Text style={s.summaryLabel}>Activas ahora</Text>
            </View>
          </LinearGradient>

          {/* ── Lista ── */}
          {allItems.length === 0 ? (
            <View style={s.emptyBox}>
              <Text style={s.emptyTitle}>Aún no tienes publicidad</Text>
              <Text style={s.emptyText}>Cuando compres un anuncio, aquí verás su estado y vigencia.</Text>
            </View>
          ) : (
            allItems.map(item => {
              const st = statusInfo(item);
              const k  = kindInfo(item);
              return (
                <View key={`${item.kind}-${item.id}`} style={s.itemCard}>
                  <View style={s.itemTop}>
                    <View style={s.itemKind}>
                      {k.icon}
                      <Text style={s.itemKindTx}>{k.label}</Text>
                    </View>
                    <Text style={s.itemAmount}>
                      {item.is_free ? 'Gratis' : fmtMoney(item.amount)}
                    </Text>
                  </View>
                  {!!item.title && item.kind === 'ad' && (
                    <Text style={s.itemTitle} numberOfLines={1}>{item.title}</Text>
                  )}
                  <View style={s.itemBottom}>
                    <Text style={[s.itemStatus, { color: st.color }]}>{st.label}</Text>
                    <Text style={s.itemDates}>
                      {item.starts_at
                        ? `${fmtDate(item.starts_at)} → ${fmtDate(item.ends_at)}`
                        : `Creado ${fmtDate(item.created_at)}`}
                    </Text>
                  </View>
                </View>
              );
            })
          )}

          <Text style={s.footNote}>
            Los montos son lo que pagaste por cada compra. Las campañas activas
            terminan solas en su fecha de vencimiento.
          </Text>

          <View style={{ height: 40 }} />
        </ScrollView>
      )}
    </View>
  );
}

// ── Estilos ───────────────────────────────────────────────────────────────────

const s = StyleSheet.create({
  root: { flex: 1, backgroundColor: COLORS.bg },
  header: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between',
    paddingHorizontal: SPACING.md, paddingBottom: SPACING.sm,
    borderBottomWidth: 1, borderBottomColor: COLORS.border,
  },
  headerTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 16, color: COLORS.text },
  backBtn: { width: 40, height: 40, alignItems: 'center', justifyContent: 'center' },
  center: { flex: 1, alignItems: 'center', justifyContent: 'center' },
  scroll: { paddingHorizontal: SPACING.md, paddingTop: SPACING.lg },

  // Resumen
  summaryCard: {
    flexDirection: 'row', alignItems: 'center',
    borderRadius: RADIUS.xl, borderWidth: 1, borderColor: 'rgba(0,230,118,0.25)',
    padding: SPACING.lg, marginBottom: SPACING.lg,
  },
  summaryCol:   { flex: 1, alignItems: 'center', gap: 4 },
  summaryDivider: { width: 1, height: 36, backgroundColor: COLORS.border },
  summaryValue: {
    fontFamily: FONTS.title, fontSize: 22, lineHeight: 28, color: COLORS.text,
    fontVariant: ['tabular-nums'], includeFontPadding: false,
  },
  summaryLabel: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted2 },

  // Item
  itemCard: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border,
    padding: SPACING.md, marginBottom: 10, gap: 6,
  },
  itemTop:    { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' },
  itemKind:   { flexDirection: 'row', alignItems: 'center', gap: 6 },
  itemKindTx: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.text },
  itemAmount: {
    fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.text,
    fontVariant: ['tabular-nums'],
  },
  itemTitle:  { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2 },
  itemBottom: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' },
  itemStatus: { fontFamily: FONTS.bodyMedium, fontSize: 12 },
  itemDates:  { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted, fontVariant: ['tabular-nums'] },

  // Vacío
  emptyBox: {
    alignItems: 'center', paddingVertical: 40, gap: 6,
    backgroundColor: COLORS.card, borderRadius: RADIUS.xl,
    borderWidth: 1, borderColor: COLORS.border,
  },
  emptyTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.text },
  emptyText:  { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, textAlign: 'center', paddingHorizontal: 30 },

  footNote: {
    fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted,
    textAlign: 'center', lineHeight: 16, marginTop: 8,
  },
});
