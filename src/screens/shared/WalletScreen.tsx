import {
  ArrowLeft,
  ArrowUpRight,
  Building2,
  CheckCircle,
  Clock,
  CreditCard,
  ExternalLink,
  TrendingUp,
  User,
  Wallet,
} from 'lucide-react-native';
import React, { useCallback, useEffect, useRef, useState } from 'react';
import {
  ActivityIndicator,
  Alert,
  AppState,
  Image,
  Linking,
  Pressable,
  RefreshControl,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  View,
} from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { useTranslation } from 'react-i18next';
import { supabase } from '../../config/supabase';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';
import Particles from '../../components/ui/Particles';
import Button from '../../components/ui/Button';
import { validateClabe, bankFromClabe } from '../../utils/clabe';

function formatCurrency(n: number) {
  return '$' + Number(n ?? 0).toLocaleString('es-MX', { minimumFractionDigits: 0, maximumFractionDigits: 2 });
}

const TYPE_LABELS: Record<string, { label: string; color: string; sign: string; icon?: string }> = {
  // Tipos nuevos (group_wallets / 184a)
  credit_pending:         { label: 'Pago retenido',             color: COLORS.orange, sign: '+' },
  credit_available:       { label: 'Ganancias liberadas',        color: COLORS.green,  sign: '+' },
  final_settlement:       { label: 'Pago final',                 color: COLORS.green,  sign: '+', icon: '✅' },
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
  // 🎁 Regalos/donaciones (sql/566-568)
  gift_income:            { label: 'Regalo recibido',            color: COLORS.gold,   sign: '+', icon: '🎁' },
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
  const [downloadingReport, setDownloadingReport] = useState(false);
  const [stripeLoading, setStripeLoading] = useState(false);
  const [stripeStatus, setStripeStatus] = useState<StripeStatus>({
    stripe_account_id: null,
    stripe_onboarding_completed: false,
    role: null,
    group_id: null,
  });

  // ── Datos bancarios permanentes (Fase P1A) ──────────────────────────────────
  const [bankClabe, setBankClabe]             = useState('');
  const [bankName, setBankName]               = useState('');
  const [accountHolder, setAccountHolder]     = useState('');
  const [savingBank, setSavingBank]           = useState(false);

  // ── "Solicitar pago" por reserva (Fase P1D) — el grupo ya no retira ────────
  const [payableReservations, setPayableReservations] = useState<any[]>([]);
  const [requestingPayment, setRequestingPayment]      = useState<string | null>(null);

  // ── Cobro de propinas/regalos acumulados (sql/584) ──────────────────────
  const [giftPayoutStatus, setGiftPayoutStatus] = useState<any>(null);
  const [requestingGiftPayout, setRequestingGiftPayout] = useState(false);

  // 🎁 Quién ha donado (solo grupo, sql/566-568)
  const [giftDonors, setGiftDonors] = useState<any[]>([]);
  const hasBankData = !!(bankClabe && bankClabe.length === 18 && bankName.trim() && accountHolder.trim());

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

      // 🎁 Quién le ha donado a este grupo — RLS ya lo permite (dueño del
      // grupo puede leer sus propios group_gifts, sql/566).
      if (grp?.id) {
        // group_amount (60% del grupo) — NUNCA amount (precio completo del
        // regalo): la comisión de Daricefy es invisible para el grupo, aquí
        // solo debe ver lo que a ÉL le tocó, igual que en wallet_transactions.
        const { data: giftsData } = await supabase
          .from('group_gifts')
          .select('id, group_amount, currency_code, created_at, sender:profiles!sender_id(full_name, avatar_url), gift:gift_catalog(emoji, name)')
          .eq('group_id', grp.id)
          .eq('status', 'paid')
          .order('created_at', { ascending: false })
          .limit(20);
        setGiftDonors(giftsData ?? []);
      }

      // Datos bancarios ya guardados (tabla `wallets`, no `group_wallets` —
      // get_my_wallet() no los incluye para rol group). Mismo patrón de
      // lectura ya usado en WithdrawScreen.tsx.
      const { data: bankData } = await supabase
        .from('wallets')
        .select('bank_clabe, bank_name, account_holder')
        .eq('user_id', user.id)
        .maybeSingle();
      if (bankData) {
        setBankClabe(bankData.bank_clabe ?? '');
        setBankName(bankData.bank_name ?? '');
        setAccountHolder(bankData.account_holder ?? '');
      }

      // Fase P1D — reservas ya liberadas con saldo pendiente, propias del grupo
      const { data: payableData } = await supabase.rpc('group_get_payable_reservations');
      if ((payableData as any)?.ok) setPayableReservations((payableData as any).items ?? []);

      // sql/584 — saldo de propinas/regalos acumulados sin cobrar
      const { data: giftPayoutData } = await supabase.rpc('group_get_gift_payout_status');
      if ((giftPayoutData as any)?.ok) setGiftPayoutStatus(giftPayoutData);
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

  // ── Datos bancarios permanentes (Fase P1A) ──────────────────────────────────
  // Solo guarda/valida — nunca toca group_wallets, wallet_transactions ni withdrawals.
  const handleSaveBank = async () => {
    const clabeCheck = validateClabe(bankClabe);
    if (!clabeCheck.valid) {
      Alert.alert('CLABE inválida', clabeCheck.error);
      return;
    }
    const detectedBank = bankFromClabe(bankClabe);
    const finalBank = detectedBank ?? bankName.trim();
    if (!finalBank) {
      Alert.alert('Error', 'Ingresa el nombre del banco.');
      return;
    }
    if (!accountHolder.trim()) {
      Alert.alert('Error', 'Ingresa el nombre del titular.');
      return;
    }

    setSavingBank(true);
    try {
      const { data, error } = await supabase.rpc('save_bank_account', {
        p_clabe:          bankClabe,
        p_bank_name:       finalBank,
        p_account_holder:  accountHolder.trim(),
      });
      if (error || !data?.ok) {
        Alert.alert('Error', data?.error === 'invalid_clabe'
          ? 'CLABE inválida.'
          : (error?.message ?? data?.error ?? 'No se pudo guardar.'));
        return;
      }
      setBankName(finalBank);
      Alert.alert('✅ Datos guardados', 'Tus datos bancarios quedaron guardados.');
    } catch (e: any) {
      Alert.alert('Error', e.message ?? 'Intenta de nuevo.');
    } finally {
      setSavingBank(false);
    }
  };

  // Fase P1D — "Solicitar pago": aviso administrativo, nunca mueve dinero.
  const handleRequestPayment = async (reservationId: string) => {
    setRequestingPayment(reservationId);
    try {
      const { data, error } = await supabase.rpc('group_request_payment', { p_reservation_id: reservationId });
      if (error || !(data as any)?.ok) {
        const err = (data as any)?.error ?? error?.message;
        const msg = err === 'missing_bank_data' ? 'Completa tus datos bancarios antes de solicitar el pago.'
          : err === 'no_balance_due' ? 'Esta reserva ya no tiene saldo pendiente.'
          : err ?? 'No se pudo enviar la solicitud.';
        Alert.alert('Error', msg);
        return;
      }
      Alert.alert('✅ Solicitud enviada', 'Le avisamos a Daricefy que quieres que te paguen este evento.');
      setPayableReservations(prev => prev.map(r =>
        r.reservation_id === reservationId ? { ...r, payment_requested: true } : r
      ));
    } catch (e: any) {
      Alert.alert('Error', e.message ?? 'Intenta de nuevo.');
    } finally {
      setRequestingPayment(null);
    }
  };

  // sql/584 — pedir el pago de propinas/regalos acumulados (aviso administrativo, no mueve dinero).
  const handleRequestGiftPayout = async () => {
    setRequestingGiftPayout(true);
    try {
      const { data, error } = await supabase.rpc('group_request_gift_payout');
      if (error || !(data as any)?.ok) {
        const err = (data as any)?.error ?? error?.message;
        const msg = err === 'missing_bank_data' ? 'Completa tus datos bancarios antes de solicitar el pago.'
          : err === 'below_minimum' ? 'Todavía no llegas al mínimo para solicitar el pago.'
          : err ?? 'No se pudo enviar la solicitud.';
        Alert.alert('Error', msg);
        return;
      }
      Alert.alert('✅ Solicitud enviada', 'Le avisamos a Daricefy que quieres cobrar tus propinas acumuladas.');
      setGiftPayoutStatus((prev: any) => ({
        ...prev,
        has_pending_request: true,
        pending_amount: (data as any).amount,
        pending_currency: (data as any).currency,
      }));
    } catch (e: any) {
      Alert.alert('Error', e.message ?? 'Intenta de nuevo.');
    } finally {
      setRequestingGiftPayout(false);
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
  // 🎁 Total de regalos — grupo (total_gift_income) o admin (total_gift_commission).
  // Mismo saldo de siempre, solo un desglose aparte para que no se confunda
  // con las ganancias de eventos (pedido explícito del usuario).
  const giftTotal    = wallet?.total_gift_income    ?? wallet?.total_gift_commission    ?? 0;
  const giftTotalUsd = wallet?.total_gift_income_usd ?? wallet?.total_gift_commission_usd ?? 0;
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
            <Text style={st.heroAmount} numberOfLines={1} adjustsFontSizeToFit minimumFontScale={0.6}>{formatCurrency(available)}</Text>
            <View style={st.heroRow}>
              <View style={st.heroStat}>
                <Clock size={14} color={COLORS.muted2} />
                <Text style={st.heroStatLabel}>{t('wallet.pending')}</Text>
                <Text style={st.heroStatValue} numberOfLines={1} adjustsFontSizeToFit minimumFontScale={0.6}>{formatCurrency(pending)}</Text>
              </View>
              <View style={st.heroDivider} />
              <View style={st.heroStat}>
                <TrendingUp size={14} color={COLORS.muted2} />
                <Text style={st.heroStatLabel}>{t('wallet.total_earned')}</Text>
                <Text style={st.heroStatValue} numberOfLines={1} adjustsFontSizeToFit minimumFontScale={0.6}>{formatCurrency(total)}</Text>
              </View>
            </View>
          </View>

          {/* Saldo USD (solo si el grupo tiene eventos en USA) */}
          {hasUsd && (
            <View style={[st.heroCard, { marginTop: 12 }]}>
              <Text style={[st.heroLabel, { marginBottom: 4 }]}>{t('wallet.usd_balance')}</Text>
              <Text style={st.heroAmount} numberOfLines={1} adjustsFontSizeToFit minimumFontScale={0.6}>
                US${availUsd.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}
              </Text>
              <View style={st.heroRow}>
                <View style={st.heroStat}>
                  <Clock size={14} color={COLORS.muted2} />
                  <Text style={st.heroStatLabel}>{t('wallet.pending')}</Text>
                  <Text style={st.heroStatValue} numberOfLines={1} adjustsFontSizeToFit minimumFontScale={0.6}>
                    US${pendingUsd.toLocaleString('en-US', { minimumFractionDigits: 2 })}
                  </Text>
                </View>
                <View style={st.heroDivider} />
                <View style={st.heroStat}>
                  <TrendingUp size={14} color={COLORS.muted2} />
                  <Text style={st.heroStatLabel}>{t('wallet.total_earned')}</Text>
                  <Text style={st.heroStatValue} numberOfLines={1} adjustsFontSizeToFit minimumFontScale={0.6}>
                    US${totalUsd.toLocaleString('en-US', { minimumFractionDigits: 2 })}
                  </Text>
                </View>
              </View>
            </View>
          )}

          {/* 🎁 Desglose de regalos — mismo saldo de arriba, aparte para que
              no se confunda con las ganancias de eventos. */}
          {(giftTotal > 0 || giftTotalUsd > 0) && (
            <View style={st.giftCard}>
              <Text style={st.giftCardTitle}>
                🎁 {stripeStatus.role === 'group' ? 'Total recibido en regalos' : 'Comisión total por regalos'}
              </Text>
              {giftTotal > 0 && (
                <Text style={st.giftCardAmount}>{formatCurrency(giftTotal)} MXN</Text>
              )}
              {giftTotalUsd > 0 && (
                <Text style={st.giftCardAmount}>
                  US${giftTotalUsd.toLocaleString('en-US', { minimumFractionDigits: 2 })} USD
                </Text>
              )}
            </View>
          )}

          {stripeStatus.role === 'group' && giftDonors.length > 0 && (
            <View style={st.giftCard}>
              <Text style={st.giftCardTitle}>🎁 Quién te ha apoyado</Text>
              {giftDonors.map(g => (
                <View key={g.id} style={st.donorRow}>
                  {g.sender?.avatar_url ? (
                    <Image source={{ uri: g.sender.avatar_url }} style={st.donorAvatar} />
                  ) : (
                    <View style={[st.donorAvatar, st.donorAvatarPh]}>
                      <User size={13} color={COLORS.muted} />
                    </View>
                  )}
                  <Text style={st.donorText} numberOfLines={1}>
                    <Text style={st.donorName}>{g.sender?.full_name ?? 'Alguien'}</Text>
                    {' te regaló '}{g.gift?.emoji} {g.gift?.name}
                  </Text>
                  <Text style={st.donorAmount}>
                    {g.currency_code === 'USD' ? 'US$' : '$'}{g.group_amount}
                  </Text>
                </View>
              ))}
            </View>
          )}

          {/* Fase P1D — el grupo ya NO retira dinero: solo puede avisar que
              quiere que le paguen una reserva específica. La transferencia
              real siempre la hace el admin. Roles distintos de "group"
              (admin/talent/client, wallet personal en `wallets`) conservan
              el botón "Retirar" tal cual — ese flujo no cambia aquí. */}
          {stripeStatus.role === 'group' ? (
            <View style={{ marginBottom: 16 }}>
              <Text style={st.sectionTitle}>Eventos disponibles para pago</Text>
              {payableReservations.length === 0 && (
                <View style={st.noBalanceHintCard}>
                  <Text style={st.noBalanceHint}>
                    Aquí aparecerán tus eventos en cuanto Daricefy libere su pago.
                  </Text>
                </View>
              )}
              {payableReservations.map((r: any) => (
                <View key={r.reservation_id} style={st.payableCard}>
                  <Text style={st.payableTitle} numberOfLines={1}>
                    {r.folio ? `Folio ${r.folio}` : 'Evento'}
                  </Text>
                  <Text style={st.payableSub}>
                    {r.event_date ? new Date(r.event_date).toLocaleDateString('es-MX', { day: '2-digit', month: 'short', year: 'numeric' }) : '—'}
                  </Text>
                  <View style={{ flexDirection: 'row', justifyContent: 'space-between', marginTop: 6 }}>
                    <Text style={st.payableRowLabel}>Ganancia del grupo</Text>
                    <Text style={st.payableRowValue}>{formatCurrency(Number(r.group_earnings ?? 0))}</Text>
                  </View>
                  <View style={{ flexDirection: 'row', justifyContent: 'space-between' }}>
                    <Text style={st.payableRowLabel}>Anticipos recibidos</Text>
                    <Text style={st.payableRowValue}>{formatCurrency(Number(r.total_anticipado ?? 0))}</Text>
                  </View>
                  <View style={{ flexDirection: 'row', justifyContent: 'space-between' }}>
                    <Text style={[st.payableRowLabel, { color: COLORS.green }]}>Saldo pendiente</Text>
                    <Text style={[st.payableRowValue, { color: COLORS.green }]}>{formatCurrency(Number(r.saldo_pendiente ?? 0))}</Text>
                  </View>
                  {!hasBankData ? (
                    <Pressable style={[st.payableBtn, { backgroundColor: COLORS.orange + '20', borderColor: COLORS.orange }]}
                      onPress={() => Alert.alert(
                        'Faltan tus datos bancarios',
                        'Completa CLABE, banco y titular en la sección "Datos bancarios" de esta misma pantalla para poder solicitar el pago.',
                      )}>
                      <Text style={[st.payableBtnTx, { color: COLORS.orange }]}>Completa tus datos bancarios para solicitar el pago</Text>
                    </Pressable>
                  ) : r.payment_requested ? (
                    <View style={[st.payableBtn, { backgroundColor: COLORS.card2, borderColor: COLORS.border }]}>
                      <Text style={[st.payableBtnTx, { color: COLORS.muted2 }]}>✓ Pago solicitado</Text>
                    </View>
                  ) : (
                    <Pressable
                      style={[st.payableBtn, requestingPayment === r.reservation_id && { opacity: 0.6 }]}
                      disabled={requestingPayment === r.reservation_id}
                      onPress={() => handleRequestPayment(r.reservation_id)}
                    >
                      <Text style={st.payableBtnTx}>
                        {requestingPayment === r.reservation_id ? 'Enviando…' : 'Solicitar pago'}
                      </Text>
                    </Pressable>
                  )}
                </View>
              ))}
            </View>
          ) : (
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
          )}

          {/* sql/584 — cobro de propinas/regalos acumulados, independiente de
              cualquier reserva. Solo aparece cuando pasa el mínimo o ya hay
              una solicitud pendiente (para que el grupo vea su estatus). */}
          {stripeStatus.role === 'group' && giftPayoutStatus && (
            giftPayoutStatus.has_pending_request ||
            giftPayoutStatus.unpaid_mxn >= giftPayoutStatus.threshold_mxn ||
            giftPayoutStatus.unpaid_usd >= giftPayoutStatus.threshold_usd
          ) && (
            <View style={st.payableCard}>
              <Text style={st.payableTitle}>🎁 Propinas y regalos acumulados</Text>
              <Text style={st.payableSub}>
                Este saldo ya está aparte de tus eventos — puedes cobrarlo cuando quieras arriba del mínimo.
              </Text>
              {giftPayoutStatus.has_pending_request ? (
                <>
                  <View style={{ flexDirection: 'row', justifyContent: 'space-between', marginTop: 6 }}>
                    <Text style={[st.payableRowLabel, { color: COLORS.green }]}>Solicitado</Text>
                    <Text style={[st.payableRowValue, { color: COLORS.green }]}>
                      {giftPayoutStatus.pending_currency === 'USD' ? 'US$' : '$'}{giftPayoutStatus.pending_amount} {giftPayoutStatus.pending_currency}
                    </Text>
                  </View>
                  <View style={[st.payableBtn, { backgroundColor: COLORS.card2, borderColor: COLORS.border }]}>
                    <Text style={[st.payableBtnTx, { color: COLORS.muted2 }]}>✓ Pago solicitado</Text>
                  </View>
                </>
              ) : (
                <>
                  {giftPayoutStatus.unpaid_mxn > 0 && (
                    <View style={{ flexDirection: 'row', justifyContent: 'space-between', marginTop: 6 }}>
                      <Text style={st.payableRowLabel}>Sin cobrar (MXN)</Text>
                      <Text style={st.payableRowValue}>{formatCurrency(Number(giftPayoutStatus.unpaid_mxn))}</Text>
                    </View>
                  )}
                  {giftPayoutStatus.unpaid_usd > 0 && (
                    <View style={{ flexDirection: 'row', justifyContent: 'space-between' }}>
                      <Text style={st.payableRowLabel}>Sin cobrar (USD)</Text>
                      <Text style={st.payableRowValue}>US${Number(giftPayoutStatus.unpaid_usd).toFixed(2)}</Text>
                    </View>
                  )}
                  {!hasBankData ? (
                    <Pressable style={[st.payableBtn, { backgroundColor: COLORS.orange + '20', borderColor: COLORS.orange }]}
                      onPress={() => Alert.alert(
                        'Faltan tus datos bancarios',
                        'Completa CLABE, banco y titular en la sección "Datos bancarios" de esta misma pantalla para poder solicitar el pago.',
                      )}>
                      <Text style={[st.payableBtnTx, { color: COLORS.orange }]}>Completa tus datos bancarios para solicitar el pago</Text>
                    </Pressable>
                  ) : (
                    <Pressable
                      style={[st.payableBtn, requestingGiftPayout && { opacity: 0.6 }]}
                      disabled={requestingGiftPayout}
                      onPress={handleRequestGiftPayout}
                    >
                      <Text style={st.payableBtnTx}>
                        {requestingGiftPayout ? 'Enviando…' : 'Solicitar pago de propinas'}
                      </Text>
                    </Pressable>
                  )}
                </>
              )}
            </View>
          )}

          {/* Retiros: transferencia SPEI procesada por Daricefy con comprobante.
              (El onboarding de Stripe Connect quedó fuera del modelo v2 —
              la CLABE se captura en el formulario de retiro.) */}

          {/* Datos bancarios permanentes (Fase P1A) — solo guarda/edita datos
              de contacto para que el admin pueda usarlos al pagar; no mueve
              dinero, no crea ninguna solicitud. */}
          {stripeStatus.role === 'group' && (
            <View style={st.bankCard}>
              <Text style={st.sectionTitle}>Datos bancarios</Text>

              <View style={st.bankFieldWrap}>
                <CreditCard size={16} color={COLORS.muted2} style={st.bankFieldIcon} />
                <TextInput
                  style={st.bankField}
                  placeholder="CLABE (18 dígitos)"
                  placeholderTextColor={COLORS.muted}
                  keyboardType="number-pad"
                  maxLength={18}
                  value={bankClabe}
                  onChangeText={setBankClabe}
                />
              </View>

              <View style={st.bankFieldWrap}>
                <Building2 size={16} color={COLORS.muted2} style={st.bankFieldIcon} />
                <TextInput
                  style={st.bankField}
                  placeholder="Banco (ej. BBVA, Banorte, HSBC)"
                  placeholderTextColor={COLORS.muted}
                  value={bankName}
                  onChangeText={setBankName}
                />
              </View>

              <View style={st.bankFieldWrap}>
                <User size={16} color={COLORS.muted2} style={st.bankFieldIcon} />
                <TextInput
                  style={st.bankField}
                  placeholder="Nombre del titular de la cuenta"
                  placeholderTextColor={COLORS.muted}
                  value={accountHolder}
                  onChangeText={setAccountHolder}
                />
              </View>

              <Button
                label="Guardar datos bancarios"
                onPress={handleSaveBank}
                loading={savingBank}
                size="md"
              />
            </View>
          )}

          {/* 📈 "Mi desempeño" vive en el DASHBOARD del grupo (movido
              2026-07-18 a petición) — aquí solo queda la descarga */}

          {/* 📊 Reporte propio del grupo (Excel) — siempre visible, no depende
              de notificaciones. Seguridad en el SERVIDOR: la EF deriva el
              group_id del token; solo datos propios, solo "Tu ganancia". */}
          {stripeStatus.role === 'group' && (
            <Pressable
              style={[st.reportBtn, downloadingReport && { opacity: 0.6 }]}
              disabled={downloadingReport}
              onPress={() => {
                const download = async (format: 'xlsx' | 'pdf', days: number | null) => {
                  setDownloadingReport(true);
                  try {
                    const from = days != null
                      ? new Date(Date.now() - days * 86400000).toISOString().substring(0, 10)
                      : null;
                    const { data, error } = await supabase.functions.invoke('generate-report', {
                      body: { mode: 'group', format, from },
                    });
                    if (error || !(data as any)?.ok) {
                      Alert.alert('No se pudo generar', (data as any)?.error ?? error?.message ?? 'Intenta de nuevo.');
                      return;
                    }
                    await Linking.openURL((data as any).url);
                  } catch {
                    Alert.alert('Error', 'No se pudo descargar el reporte. Intenta de nuevo.');
                  } finally {
                    setDownloadingReport(false);
                  }
                };
                const pickRange = (format: 'xlsx' | 'pdf') => {
                  Alert.alert('📅 Periodo', '¿Qué periodo quieres?', [
                    { text: 'Últimos 30 días',  onPress: () => download(format, 30) },
                    { text: 'Últimos 90 días',  onPress: () => download(format, 90) },
                    { text: 'Este año',         onPress: () => download(format, 365) },
                    { text: 'Todo',             onPress: () => download(format, null) },
                    { text: 'Cancelar', style: 'cancel' },
                  ]);
                };
                Alert.alert('⬇ Descargar mi reporte', '¿En qué formato?', [
                  { text: '📄 PDF (resumen bonito)', onPress: () => pickRange('pdf') },
                  { text: '📊 Excel (detallado)',    onPress: () => pickRange('xlsx') },
                  { text: 'Cancelar', style: 'cancel' },
                ]);
              }}
            >
              <Text style={st.reportBtnTx}>
                {downloadingReport ? 'Generando tu reporte…' : '⬇ Descargar mi reporte (PDF o Excel)'}
              </Text>
            </Pressable>
          )}

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
                  let meta = TYPE_LABELS[tx.type] ?? { label: tx.type, color: COLORS.muted2, sign: '+', icon: undefined };
                  // 🔒 Fuera del rol admin, los tipos de plataforma se muestran
                  // con etiqueta neutra (no deben revelar comisiones al grupo)
                  if (stripeStatus.role !== 'admin' && (tx.type === 'platform_income' || tx.type === 'commission' || tx.type === 'commission_correction')) {
                    meta = { ...meta, label: tx.type === 'platform_income' ? 'Ingreso' : 'Ajuste' };
                  }
                  // 💰 Para el admin, 'commission' es SU ganancia llegando a su
                  // wallet (ej. comisión por regalo) — no un descuento. El signo
                  // "-" tenía sentido pensando en a quién se le cobra, pero en
                  // esta lista siempre es la vista del dueño de la wallet.
                  if (stripeStatus.role === 'admin' && tx.type === 'commission') {
                    meta = { ...meta, sign: '+', color: COLORS.green };
                  }
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

  // 🎁 Regalos/donaciones (sql/566-569)
  giftCard: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.xl,
    borderWidth: 1, borderColor: COLORS.border,
    padding: SPACING.lg, marginTop: 12, gap: 6,
  },
  giftCardTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.text },
  giftCardAmount: { fontFamily: FONTS.title, fontSize: 20, color: COLORS.gold },
  donorRow: {
    flexDirection: 'row', alignItems: 'center', gap: 8,
    paddingVertical: 6, borderTopWidth: 1, borderTopColor: COLORS.border,
  },
  donorAvatar: { width: 26, height: 26, borderRadius: 13, backgroundColor: COLORS.card2 },
  donorAvatarPh: { alignItems: 'center', justifyContent: 'center' },
  donorText: { flex: 1, fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2 },
  donorName: { fontFamily: FONTS.bodyMedium, color: COLORS.text },
  donorAmount: { fontFamily: FONTS.bodySemiBold, fontSize: 12, color: COLORS.gold },

  noBalanceHint: {
    fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted,
    textAlign: 'center', marginTop: 10, lineHeight: 18,
  },
  noBalanceHintCard: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border, padding: SPACING.lg,
  },

  // "Solicitar pago" por reserva (Fase P1D)
  payableCard: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border,
    padding: SPACING.lg, marginTop: 10,
  },
  payableTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.text },
  payableSub:   { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted, marginTop: 2 },
  payableRowLabel: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2 },
  payableRowValue: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.text },
  payableBtn: {
    marginTop: 10, borderRadius: RADIUS.md, borderWidth: 1, borderColor: COLORS.green,
    backgroundColor: COLORS.greenMuted, paddingVertical: 10, alignItems: 'center',
  },
  payableBtnTx: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.green },

  // Datos bancarios (Fase P1A)
  bankCard: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.xl,
    borderWidth: 1, borderColor: COLORS.border,
    padding: SPACING.lg, marginBottom: 16,
  },
  bankFieldWrap: {
    flexDirection: 'row', alignItems: 'center',
    backgroundColor: COLORS.card2, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border,
    paddingHorizontal: SPACING.lg, marginBottom: 10,
  },
  bankFieldIcon: { marginRight: 10 },
  bankField: {
    flex: 1, fontFamily: FONTS.body, fontSize: 15, color: COLORS.text,
    paddingVertical: 14,
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

  // 📊 Botón de reporte del grupo
  reportBtn: {
    marginBottom: 16, paddingVertical: 13, alignItems: 'center',
    backgroundColor: 'rgba(0,230,118,0.08)', borderRadius: RADIUS.full,
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.4)',
  },
  reportBtnTx: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.green },

  // 📈 Panel de desempeño
  performanceBtn: {
    marginBottom: 12, padding: 14,
    backgroundColor: COLORS.card, borderRadius: RADIUS.xl,
    borderWidth: 1.5, borderColor: 'rgba(0,230,118,0.45)', gap: 3,
  },
  performanceBtnTx: { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.green },
  performanceBtnSub: { fontFamily: FONTS.body, fontSize: 11.5, color: COLORS.muted2 },

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
