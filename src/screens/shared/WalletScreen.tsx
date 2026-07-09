import {
  ArrowLeft,
  ArrowUpRight,
  CheckCircle,
  Clock,
  CreditCard,
  ExternalLink,
  TrendingUp,
  Wallet,
} from 'lucide-react-native';
import React, { useCallback, useEffect, useRef, useState } from 'react';
import {
  ActivityIndicator,
  Alert,
  AppState,
  Linking,
  Pressable,
  RefreshControl,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { useTranslation } from 'react-i18next';
import { supabase } from '../../config/supabase';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';
import Particles from '../../components/ui/Particles';
import Button from '../../components/ui/Button';

function formatCurrency(n: number) {
  return '$' + Number(n ?? 0).toLocaleString('es-MX', { minimumFractionDigits: 0, maximumFractionDigits: 2 });
}

const TYPE_LABELS: Record<string, { label: string; color: string; sign: string; icon?: string }> = {
  // Tipos nuevos (group_wallets / 184a)
  credit_pending:         { label: 'Pago retenido',             color: COLORS.orange, sign: '+' },
  credit_available:       { label: 'Ganancias liberadas',        color: COLORS.green,  sign: '+' },
  debit_payout:           { label: 'Retiro',                     color: COLORS.red,    sign: '-' },
  debit_refund:           { label: 'Reembolso',                  color: COLORS.blue,   sign: '-' },
  // Tipos legacy (wallets / 59)
  event_earning:          { label: 'Ganancia de evento',        color: COLORS.green,  sign: '+' },
  extra_hour:             { label: 'Hora extra',                 color: COLORS.green,  sign: '+' },
  withdrawal:             { label: 'Retiro',                     color: COLORS.red,    sign: '-' },
  commission:             { label: 'Comisión',                   color: COLORS.orange, sign: '-' },
  adjustment:             { label: 'Ajuste',                     color: COLORS.muted2, sign: '±' },
  refund:                 { label: 'Reembolso',                  color: COLORS.blue,   sign: '+' },
  platform_income:        { label: 'Comisión de plataforma',     color: COLORS.green,  sign: '+' },
  commission_correction:  { label: 'Ajuste Stripe',              color: COLORS.muted2, sign: '-' },
  // Ingresos publicitarios (admin)
  ad_income:              { label: 'Publicidad',                 color: '#C9A84C',     sign: '+', icon: '📢' },
  bid_income:             { label: 'Posicionamiento (bid)',       color: '#A78BFA',     sign: '+', icon: '🔥' },
  recommendation_income:  { label: 'Recomendación destacada',    color: '#FCD34D',     sign: '+', icon: '⭐' },
};

interface StripeStatus {
  stripe_account_id: string | null;
  stripe_onboarding_completed: boolean;
  role: string | null;
  group_id: string | null;
}

export default function WalletScreen({ navigation }: any) {
  const { t } = useTranslation();
  const [wallet, setWallet]             = useState<any>(null);
  const [transactions, setTransactions] = useState<any[]>([]);
  const [loading, setLoading]           = useState(true);
  const [refreshing, setRefreshing]     = useState(false);
  const [stripeLoading, setStripeLoading] = useState(false);
  const [stripeStatus, setStripeStatus] = useState<StripeStatus>({
    stripe_account_id: null,
    stripe_onboarding_completed: false,
    role: null,
    group_id: null,
  });

  const appStateRef = useRef(AppState.currentState);

  const load = useCallback(async () => {
    const { data: { user } } = await supabase.auth.getUser();
    if (!user) { setLoading(false); setRefreshing(false); return; }

    // Stripe status (solo necesita profiles + groups para grupos)
    const { data: prof } = await supabase
      .from('profiles')
      .select('role, stripe_account_id, stripe_onboarding_completed')
      .eq('id', user.id)
      .maybeSingle();

    const role = prof?.role ?? null;

    if (role === 'group') {
      const { data: grp } = await supabase
        .from('groups')
        .select('id, stripe_account_id, stripe_onboarding_completed')
        .eq('owner_id', user.id)
        .maybeSingle();
      setStripeStatus({
        stripe_account_id:          grp?.stripe_account_id ?? null,
        stripe_onboarding_completed: grp?.stripe_onboarding_completed ?? false,
        role,
        group_id: grp?.id ?? null,
      });
    } else {
      setStripeStatus({
        stripe_account_id:          prof?.stripe_account_id ?? null,
        stripe_onboarding_completed: prof?.stripe_onboarding_completed ?? false,
        role,
        group_id: null,
      });
    }

    // RPC centralizado: bypasa RLS del cliente, devuelve wallet + transacciones
    const { data: rpcData, error: rpcErr } = await supabase.rpc('get_my_wallet');
    if (rpcErr) console.warn('[Wallet] get_my_wallet error:', rpcErr.message);

    if (rpcData?.ok) {
      const w = rpcData.wallet ?? {};
      setWallet({
        available_balance: w.available_balance ?? 0,
        pending_balance:   w.pending_balance   ?? 0,
        total_earned:      w.total_earned       ?? 0,
        ...w,
      });
      setTransactions(rpcData.transactions ?? []);
    } else {
      setWallet({ available_balance: 0, pending_balance: 0, total_earned: 0 });
      setTransactions([]);
    }

    setLoading(false);
    setRefreshing(false);
  }, []);

  useEffect(() => { load(); }, []);

  // Verificar estado de Stripe cuando el usuario vuelve del navegador de onboarding
  useEffect(() => {
    const sub = AppState.addEventListener('change', async (nextState) => {
      if (appStateRef.current.match(/inactive|background/) && nextState === 'active') {
        const { data: sd } = await supabase.auth.getSession();
        const token = sd.session?.access_token;
        if (token) {
          await supabase.functions.invoke('verify-stripe-account', {
            body:    stripeStatus.group_id ? { group_id: stripeStatus.group_id } : undefined,
            headers: { Authorization: `Bearer ${token}` },
          });
        }
        load();
      }
      appStateRef.current = nextState;
    });
    return () => sub.remove();
  }, [stripeStatus.group_id]);

  // Realtime: actualizar wallet y transacciones
  useEffect(() => {
    const sub = supabase
      .channel('wallet-realtime')
      .on('postgres_changes', { event: 'UPDATE', schema: 'public', table: 'group_wallets' },
        () => load())
      .on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'wallet_transactions' },
        () => load())
      .subscribe();
    return () => { supabase.removeChannel(sub); };
  }, [load]);

  const onRefresh = () => { setRefreshing(true); load(); };

  // ── Stripe Connect ─────────────────────────────────────────────────────────
  const handleConnectStripe = async () => {
    setStripeLoading(true);
    try {
      const { data: sd } = await supabase.auth.getSession();
      const token = sd.session?.access_token;
      if (!token) { Alert.alert('Error', 'Sesión no encontrada. Vuelve a iniciar sesión.'); return; }

      const isGroup = stripeStatus.role === 'group';

      // Verificar estado real si ya tiene cuenta
      if (stripeStatus.stripe_account_id) {
        const { data: verifyData } = await supabase.functions.invoke('verify-stripe-account', {
          body:    isGroup && stripeStatus.group_id ? { group_id: stripeStatus.group_id } : undefined,
          headers: { Authorization: `Bearer ${token}` },
        });
        if (verifyData?.verified) {
          setStripeStatus(prev => ({ ...prev, stripe_onboarding_completed: true }));
          await load();
        }
      }

      if (isGroup) {
        // Grupos: crear cuenta si no existe, luego onboarding
        if (!stripeStatus.stripe_account_id) {
          const { data: createData, error: createErr } = await supabase.functions.invoke(
            'stripe-connect-create',
            { body: { group_id: stripeStatus.group_id }, headers: { Authorization: `Bearer ${token}` } },
          );
          if (createErr || createData?.error) throw new Error(createErr?.message ?? createData?.error ?? 'Error creando cuenta Stripe');
          setStripeStatus(prev => ({ ...prev, stripe_account_id: createData.stripe_account_id }));
        }

        const { data, error } = await supabase.functions.invoke(
          'stripe-connect-onboard',
          { body: { group_id: stripeStatus.group_id }, headers: { Authorization: `Bearer ${token}` } },
        );
        if (error || data?.error) throw new Error(error?.message ?? data?.error ?? 'Error de red');

        if (data?.already_completed) {
          setStripeStatus(prev => ({ ...prev, stripe_onboarding_completed: true }));
          if (data?.login_url) {
            Alert.alert('✅ Cuenta activa',
              '¿Deseas gestionar tu cuenta bancaria en Stripe?',
              [
                { text: 'Gestionar', onPress: () => Linking.openURL(data.login_url) },
                { text: 'Cerrar', style: 'cancel' },
              ],
            );
          } else {
            Alert.alert('✅ Cuenta activa', 'Tu cuenta bancaria ya está verificada.');
          }
          return;
        }
        if (!data?.url) throw new Error('No se recibió URL de Stripe');
        await Linking.openURL(data.url);

      } else {
        // Talent / admin / client: usar stripe-connect-profile
        const { data, error } = await supabase.functions.invoke(
          'stripe-connect-profile',
          { headers: { Authorization: `Bearer ${token}` } },
        );
        if (error || data?.error) throw new Error(error?.message ?? data?.error ?? 'Error de red');

        if (data?.already_completed) {
          setStripeStatus(prev => ({ ...prev, stripe_onboarding_completed: true }));
          if (data?.login_url) {
            Alert.alert('✅ Cuenta activa',
              '¿Deseas gestionar tu cuenta bancaria en Stripe?',
              [
                { text: 'Gestionar', onPress: () => Linking.openURL(data.login_url) },
                { text: 'Cerrar', style: 'cancel' },
              ],
            );
          } else {
            Alert.alert('✅ Cuenta activa', 'Tu cuenta ya está verificada.');
          }
          return;
        }
        if (!data?.url) throw new Error('No se recibió URL de Stripe');
        await Linking.openURL(data.url);
      }
    } catch (e: any) {
      Alert.alert('Error', e.message ?? 'Intenta de nuevo más tarde');
    } finally {
      setStripeLoading(false);
    }
  };

  if (loading) {
    return (
      <View style={{ flex: 1, backgroundColor: COLORS.bg, alignItems: 'center', justifyContent: 'center' }}>
        <ActivityIndicator color={COLORS.green} />
      </View>
    );
  }

  const available  = wallet?.available_balance ?? 0;
  const pending    = wallet?.pending_balance   ?? 0;
  const total      = wallet?.total_earned      ?? 0;
  const availUsd   = wallet?.available_balance_usd ?? 0;
  const pendingUsd = wallet?.pending_balance_usd   ?? 0;
  const totalUsd   = wallet?.total_earned_usd      ?? 0;
  const hasUsd     = availUsd > 0 || pendingUsd > 0 || totalUsd > 0;
  const stripeOk   = stripeStatus.stripe_onboarding_completed;
  const stripeLinked = !!stripeStatus.stripe_account_id;

  return (
    <View style={st.container}>
      <Particles />
      <SafeAreaView style={{ flex: 1 }}>
        {/* Header */}
        <View style={st.header}>
          <Pressable style={st.backBtn} onPress={() => navigation.goBack()}>
            <ArrowLeft size={20} color={COLORS.text} />
          </Pressable>
          <Text style={st.headerTitle}>{t('wallet.title')}</Text>
          <View style={{ width: 40 }} />
        </View>

        <ScrollView
          showsVerticalScrollIndicator={false}
          contentContainerStyle={st.scroll}
          refreshControl={<RefreshControl refreshing={refreshing} onRefresh={onRefresh} tintColor={COLORS.green} />}
        >
          {/* Saldo disponible — hero */}
          <View style={st.heroCard}>
            <Wallet size={22} color={COLORS.green} style={{ marginBottom: 8 }} />
            <Text style={st.heroLabel}>{t('wallet.available')}</Text>
            <Text style={st.heroAmount}>{formatCurrency(available)}</Text>
            <View style={st.heroRow}>
              <View style={st.heroStat}>
                <Clock size={14} color={COLORS.muted2} />
                <Text style={st.heroStatLabel}>{t('wallet.pending')}</Text>
                <Text style={st.heroStatValue}>{formatCurrency(pending)}</Text>
              </View>
              <View style={st.heroDivider} />
              <View style={st.heroStat}>
                <TrendingUp size={14} color={COLORS.muted2} />
                <Text style={st.heroStatLabel}>{t('wallet.total_earned')}</Text>
                <Text style={st.heroStatValue}>{formatCurrency(total)}</Text>
              </View>
            </View>
          </View>

          {/* Saldo USD (solo si el grupo tiene eventos en USA) */}
          {hasUsd && (
            <View style={[st.heroCard, { marginTop: 12 }]}>
              <Text style={[st.heroLabel, { marginBottom: 4 }]}>{t('wallet.usd_balance')}</Text>
              <Text style={st.heroAmount}>
                US${availUsd.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}
              </Text>
              <View style={st.heroRow}>
                <View style={st.heroStat}>
                  <Clock size={14} color={COLORS.muted2} />
                  <Text style={st.heroStatLabel}>{t('wallet.pending')}</Text>
                  <Text style={st.heroStatValue}>
                    US${pendingUsd.toLocaleString('en-US', { minimumFractionDigits: 2 })}
                  </Text>
                </View>
                <View style={st.heroDivider} />
                <View style={st.heroStat}>
                  <TrendingUp size={14} color={COLORS.muted2} />
                  <Text style={st.heroStatLabel}>{t('wallet.total_earned')}</Text>
                  <Text style={st.heroStatValue}>
                    US${totalUsd.toLocaleString('en-US', { minimumFractionDigits: 2 })}
                  </Text>
                </View>
              </View>
            </View>
          )}

          {/* Botón retirar */}
          <View style={{ marginBottom: 16 }}>
            <Button
              label={t('wallet.withdraw')}
              onPress={() => navigation.navigate('Withdraw', { available })}
              size="lg"
              disabled={available <= 0}
            />
            {available <= 0 ? (
              <Text style={st.noBalanceHint}>{t('wallet.withdraw_hint_no_balance')}</Text>
            ) : null}
          </View>

          {/* Stripe Connect */}
          <Pressable
            style={[st.stripeCard, stripeOk && st.stripeCardActive]}
            onPress={handleConnectStripe}
            disabled={stripeLoading}
          >
            {stripeLoading ? (
              <ActivityIndicator size="small" color={COLORS.green} style={{ marginRight: 12 }} />
            ) : stripeOk ? (
              <CheckCircle size={20} color={COLORS.green} />
            ) : (
              <CreditCard size={20} color={COLORS.orange} />
            )}
            <View style={{ flex: 1, marginLeft: 12 }}>
              {stripeOk ? (
                <>
                  <Text style={st.stripeTitle}>{t('wallet.stripe_verified')}</Text>
                  <Text style={st.stripeSub}>{t('wallet.stripe_verified_sub')}</Text>
                </>
              ) : stripeLinked ? (
                <>
                  <Text style={st.stripeTitleWarn}>{t('wallet.stripe_pending')}</Text>
                  <Text style={st.stripeSub}>{t('wallet.stripe_connect_sub')}</Text>
                </>
              ) : (
                <>
                  <Text style={st.stripeTitleWarn}>{t('wallet.stripe_connect')}</Text>
                  <Text style={st.stripeSub}>{t('wallet.stripe_connect_sub')}</Text>
                </>
              )}
            </View>
            <ExternalLink size={16} color={stripeOk ? COLORS.green : COLORS.orange} />
          </Pressable>

          {/* Info */}
          <View style={st.feeCard}>
            <Text style={st.feeTitle}>{t('wallet.how_title')}</Text>
            <View style={st.feeRow}>
              <Text style={st.feeLabel}>{t('wallet.how_events')}</Text>
              <Text style={st.feeValue}>{t('wallet.how_events_val')}</Text>
            </View>
            <View style={st.feeRow}>
              <Text style={st.feeLabel}>{t('wallet.how_processing')}</Text>
              <Text style={st.feeValue}>{t('wallet.how_processing_val')}</Text>
            </View>
            <View style={st.feeRow}>
              <Text style={st.feeLabel}>{t('wallet.how_fee')}</Text>
              <Text style={st.feeValue}>{t('wallet.how_fee_val')}</Text>
            </View>
          </View>

          {/* Historial */}
          <View style={st.historialHeader}>
            <Text style={st.sectionTitle}>{t('wallet.history')}</Text>
            {transactions.length > 0 && (
              <View style={st.txCountBadge}>
                <Text style={st.txCountText}>{transactions.length}</Text>
              </View>
            )}
          </View>

          {transactions.length === 0 ? (
            <View style={st.emptyBox}>
              <Text style={st.emptyIcon}>💸</Text>
              <Text style={st.emptyText}>{t('wallet.empty')}</Text>
              <Text style={st.emptySubText}>{t('wallet.empty_sub')}</Text>
            </View>
          ) : (() => {
            // Agrupar por fecha relativa
            const today    = new Date(); today.setHours(0,0,0,0);
            const yesterday = new Date(today); yesterday.setDate(today.getDate() - 1);
            const weekAgo   = new Date(today); weekAgo.setDate(today.getDate() - 7);
            const monthAgo  = new Date(today); monthAgo.setDate(today.getDate() - 30);

            const dateLabel = (iso: string): string => {
              const d = new Date(iso); d.setHours(0,0,0,0);
              if (d >= today)     return t('wallet.tx_today');
              if (d >= yesterday) return t('wallet.tx_yesterday');
              if (d >= weekAgo)   return t('wallet.tx_this_week');
              if (d >= monthAgo)  return t('wallet.tx_this_month');
              return d.toLocaleDateString('es-MX', { month: 'long', year: 'numeric' });
            };

            // Construir lista con separadores de grupo
            const items: Array<{ type: 'header'; label: string } | { type: 'tx'; tx: any }> = [];
            let lastLabel = '';
            for (const tx of transactions) {
              const lbl = dateLabel(tx.created_at);
              if (lbl !== lastLabel) {
                items.push({ type: 'header', label: lbl });
                lastLabel = lbl;
              }
              items.push({ type: 'tx', tx });
            }

            return (
              <>
                {items.map((item, idx) => {
                  if (item.type === 'header') {
                    return (
                      <View key={`h-${idx}`} style={st.txGroupHeader}>
                        <Text style={st.txGroupLabel}>{item.label}</Text>
                        <View style={st.txGroupLine} />
                      </View>
                    );
                  }
                  const { tx } = item;
                  const meta = TYPE_LABELS[tx.type] ?? { label: tx.type, color: COLORS.muted2, sign: '+', icon: undefined };
                  const timeStr = new Date(tx.created_at).toLocaleTimeString('es-MX', { hour: '2-digit', minute: '2-digit' });
                  const isDebit  = meta.sign === '-';
                  const isPending = tx.status === 'pending';

                  return (
                    <View key={tx.id} style={st.txRow}>
                      {/* Ícono / punto */}
                      <View style={[st.txDot, { backgroundColor: meta.color + '18', borderColor: meta.color + '55' }]}>
                        {meta.icon
                          ? <Text style={{ fontSize: 15 }}>{meta.icon}</Text>
                          : isDebit
                            ? <ArrowUpRight size={15} color={meta.color} style={{ transform: [{ rotate: '180deg' }] }} />
                            : <ArrowUpRight size={15} color={meta.color} />
                        }
                      </View>

                      {/* Descripción + estado */}
                      <View style={{ flex: 1, marginLeft: 12 }}>
                        <Text style={st.txLabel} numberOfLines={1}>
                          {tx.description ?? meta.label}
                        </Text>
                        <View style={st.txMetaRow}>
                          <Text style={st.txDate}>{timeStr}</Text>
                          {isPending && (
                            <View style={st.txPendingBadge}>
                              <Text style={st.txPendingText}>Pendiente</Text>
                            </View>
                          )}
                          {tx.status === 'failed' && (
                            <View style={[st.txPendingBadge, { backgroundColor: 'rgba(239,68,68,0.15)', borderColor: '#EF4444' }]}>
                              <Text style={[st.txPendingText, { color: '#EF4444' }]}>Fallido</Text>
                            </View>
                          )}
                        </View>
                      </View>

                      {/* Monto + tipo */}
                      <View style={{ alignItems: 'flex-end' }}>
                        <Text style={[st.txAmount, { color: isDebit ? COLORS.red : meta.color, opacity: isPending ? 0.6 : 1 }]}>
                          {meta.sign}{tx.currency_code === 'USD'
                            ? `US$${Number(tx.amount ?? 0).toLocaleString('en-US', { minimumFractionDigits: 2 })}`
                            : formatCurrency(tx.amount)}
                        </Text>
                        <Text style={[st.txTypeBadge, { color: meta.color }]}>{meta.label}</Text>
                      </View>
                    </View>
                  );
                })}
              </>
            );
          })()}
          <View style={{ height: 32 }} />
        </ScrollView>
      </SafeAreaView>
    </View>
  );
}

const st = StyleSheet.create({
  container:  { flex: 1, backgroundColor: COLORS.bg },
  header: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between',
    paddingHorizontal: SPACING.xl, paddingVertical: 14,
    borderBottomWidth: 1, borderBottomColor: COLORS.border,
  },
  backBtn: {
    width: 40, height: 40, borderRadius: 12,
    backgroundColor: COLORS.card, borderWidth: 1, borderColor: COLORS.border,
    alignItems: 'center', justifyContent: 'center',
  },
  headerTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 16, color: COLORS.text },
  scroll:      { padding: SPACING.xl, paddingBottom: 48 },

  // Hero
  heroCard: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.xl,
    borderWidth: 1, borderColor: COLORS.green + '40',
    padding: SPACING.xl, alignItems: 'center', marginBottom: 16,
  },
  heroLabel:     { fontFamily: FONTS.bodyMedium, fontSize: 11, color: COLORS.muted2, marginBottom: 2 },
  heroAmount:    { fontFamily: FONTS.title, fontSize: 28, color: COLORS.green, marginBottom: 10 },
  heroRow:       { flexDirection: 'row', alignItems: 'center', width: '100%' },
  heroStat:      { flex: 1, alignItems: 'center', gap: 2 },
  heroStatLabel: { fontFamily: FONTS.body, fontSize: 10, color: COLORS.muted },
  heroStatValue: { fontFamily: FONTS.bodyMedium, fontSize: 11, color: COLORS.text },
  heroDivider:   { width: 1, height: 36, backgroundColor: COLORS.border },

  noBalanceHint: {
    fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted,
    textAlign: 'center', marginTop: 10, lineHeight: 18,
  },

  // Stripe Connect card
  stripeCard: {
    flexDirection: 'row', alignItems: 'center',
    backgroundColor: 'rgba(255,152,0,0.08)',
    borderRadius: RADIUS.lg, borderWidth: 1, borderColor: COLORS.orange + '50',
    padding: SPACING.lg, marginBottom: 12,
  },
  stripeCardActive: {
    backgroundColor: COLORS.greenMuted,
    borderColor: COLORS.green + '50',
  },
  stripeTitle:     { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.text },
  stripeTitleWarn: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.text },
  stripeSub:       { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, marginTop: 2 },

  // Info
  feeCard: {
    backgroundColor: COLORS.card2, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border,
    padding: SPACING.lg, marginBottom: 24,
  },
  feeTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.muted2, marginBottom: 10 },
  feeRow:   { flexDirection: 'row', justifyContent: 'space-between', marginBottom: 6 },
  feeLabel: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted },
  feeValue: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.text },

  // Historial header
  historialHeader: { flexDirection: 'row', alignItems: 'center', gap: 10, marginBottom: 14 },
  sectionTitle:    { fontFamily: FONTS.title, fontSize: 18, color: COLORS.text },
  txCountBadge: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.full,
    borderWidth: 1, borderColor: COLORS.border,
    paddingHorizontal: 10, paddingVertical: 2,
  },
  txCountText: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.muted2 },

  // Empty state
  emptyBox:    { alignItems: 'center', paddingVertical: 36 },
  emptyIcon:   { fontSize: 40, marginBottom: 10 },
  emptyText:   { fontFamily: FONTS.bodyMedium, fontSize: 14, color: COLORS.muted2 },
  emptySubText:{ fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted, marginTop: 4 },

  // Grupo / fecha header
  txGroupHeader: { flexDirection: 'row', alignItems: 'center', gap: 10, marginTop: 8, marginBottom: 8 },
  txGroupLabel: { fontFamily: FONTS.bodyMedium, fontSize: 11, color: COLORS.muted, textTransform: 'uppercase', letterSpacing: 0.8 },
  txGroupLine:  { flex: 1, height: 1, backgroundColor: COLORS.border },

  // Fila de transacción
  txRow: {
    flexDirection: 'row', alignItems: 'center',
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border,
    padding: SPACING.lg, marginBottom: 8,
  },
  txDot: {
    width: 40, height: 40, borderRadius: 12,
    borderWidth: 1, alignItems: 'center', justifyContent: 'center',
    flexShrink: 0,
  },
  txLabel:    { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.text },
  txMetaRow:  { flexDirection: 'row', alignItems: 'center', gap: 6, marginTop: 3 },
  txDate:     { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted },
  txAmount:   { fontFamily: FONTS.bodySemiBold, fontSize: 15 },
  txTypeBadge:{ fontFamily: FONTS.body, fontSize: 10, color: COLORS.muted, marginTop: 2 },

  // Badge "Pendiente"
  txPendingBadge: {
    backgroundColor: 'rgba(245,158,11,0.15)',
    borderWidth: 1, borderColor: 'rgba(245,158,11,0.5)',
    borderRadius: RADIUS.full, paddingHorizontal: 7, paddingVertical: 1,
  },
  txPendingText: { fontFamily: FONTS.bodyMedium, fontSize: 9, color: '#F59E0B' },
});
