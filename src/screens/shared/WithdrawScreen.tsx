import { ArrowLeft, Building2, CreditCard, User } from 'lucide-react-native';
import React, { useState } from 'react';
import {
  Alert,
  KeyboardAvoidingView,
  Platform,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  View,
} from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { supabase } from '../../config/supabase';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';
import Button from '../../components/ui/Button';
import Particles from '../../components/ui/Particles';
import { validateClabe, bankFromClabe } from '../../utils/clabe';

function formatCurrency(n: number) {
  return '$' + Number(n ?? 0).toLocaleString('es-MX', { minimumFractionDigits: 0 });
}

export default function WithdrawScreen({ route, navigation }: any) {
  const available: number = route.params?.available ?? 0;

  const [amount, setAmount]           = useState('');
  const [clabe, setClabe]             = useState(route.params?.savedClabe ?? '');
  const [bankName, setBankName]       = useState(route.params?.savedBankName ?? '');
  const [accountHolder, setAccountHolder] = useState(route.params?.savedAccountHolder ?? '');
  const [loading, setLoading]         = useState(false);

  // Load saved bank data from DB if not passed via params
  React.useEffect(() => {
    if (clabe) return; // already pre-filled
    supabase.auth.getSession().then(({ data: sd }) => {
      if (!sd.session) return;
      supabase
        .from('wallets')
        .select('bank_clabe, bank_name, account_holder')
        .eq('user_id', sd.session.user.id)
        .maybeSingle()
        .then(({ data }) => {
          if (!data) return;
          if (data.bank_clabe)     setClabe(data.bank_clabe);
          if (data.bank_name)      setBankName(data.bank_name);
          if (data.account_holder) setAccountHolder(data.account_holder);
        });
    });
  }, []);

  const handleWithdraw = async () => {
    const numAmount = parseFloat(amount);
    if (!amount || isNaN(numAmount) || numAmount <= 0) {
      Alert.alert('Error', 'Ingresa un monto válido.'); return;
    }
    if (numAmount > available) {
      Alert.alert('Error', `El monto supera tu saldo disponible (${formatCurrency(available)}).`); return;
    }
    const clabeCheck = validateClabe(clabe);
    if (!clabeCheck.valid) {
      Alert.alert('CLABE inválida', clabeCheck.error); return;
    }
    const detectedBank = bankFromClabe(clabe);
    const finalBank = detectedBank ?? bankName.trim();
    if (!finalBank) {
      Alert.alert('Error', 'Ingresa el nombre del banco.'); return;
    }
    if (detectedBank && detectedBank !== bankName.trim()) setBankName(detectedBank);
    if (!accountHolder.trim()) {
      Alert.alert('Error', 'Ingresa el nombre del titular.'); return;
    }

    Alert.alert(
      'Confirmar retiro',
      `¿Retirar ${formatCurrency(numAmount)} a tu cuenta?\n\n${finalBank} · terminación ${clabe.slice(-4)}\nTitular: ${accountHolder.trim()}`,
      [
        { text: 'Cancelar', style: 'cancel' },
        {
          text: 'Confirmar',
          onPress: async () => {
            setLoading(true);
            const { data, error } = await supabase.rpc('request_withdrawal', {
              p_amount:         numAmount,
              p_bank_clabe:     clabe,
              p_bank_name:      finalBank,
              p_account_holder: accountHolder.trim(),
            });
            setLoading(false);

            if (error || !data?.ok) {
              const msg = data?.error === 'insufficient_balance'
                ? `Saldo insuficiente. Disponible: ${formatCurrency(data?.available ?? 0)}`
                : error?.message ?? data?.error ?? 'No se pudo procesar el retiro.';
              Alert.alert('Error', msg);
              return;
            }

            Alert.alert(
              '✅ Retiro solicitado',
              `Tu retiro de ${formatCurrency(numAmount)} está siendo procesado. Recibirás el dinero vía SPEI en las próximas horas.`,
              [{ text: 'OK', onPress: () => navigation.goBack() }]
            );
          },
        },
      ]
    );
  };

  return (
    <View style={st.container}>
      <Particles />
      <SafeAreaView style={{ flex: 1 }}>
        {/* Header */}
        <View style={st.header}>
          <Pressable style={st.backBtn} onPress={() => navigation.goBack()}>
            <ArrowLeft size={20} color={COLORS.text} />
          </Pressable>
          <Text style={st.headerTitle}>Retirar dinero</Text>
          <View style={{ width: 40 }} />
        </View>

        <KeyboardAvoidingView
          style={{ flex: 1 }}
          behavior={Platform.OS === 'ios' ? 'padding' : undefined}
        >
          <ScrollView
            showsVerticalScrollIndicator={false}
            contentContainerStyle={st.scroll}
            keyboardShouldPersistTaps="handled"
          >
            {/* Saldo disponible */}
            <View style={st.balanceCard}>
              <Text style={st.balanceLabel}>Saldo disponible</Text>
              <Text style={st.balanceAmount}>{formatCurrency(available)}</Text>
            </View>

            {/* Monto */}
            <Text style={st.sectionTitle}>Monto a retirar</Text>
            <View style={st.inputWrap}>
              <Text style={st.inputPrefix}>$</Text>
              <TextInput
                style={st.input}
                placeholder="0.00"
                placeholderTextColor={COLORS.muted}
                keyboardType="decimal-pad"
                value={amount}
                onChangeText={setAmount}
              />
            </View>

            {/* Botones rápidos */}
            <View style={st.quickRow}>
              {[100, 500, 1000, available].map((v, i) => (
                <Pressable
                  key={i}
                  style={st.quickBtn}
                  onPress={() => setAmount(String(v))}
                >
                  <Text style={st.quickBtnText}>
                    {i === 3 ? 'Todo' : formatCurrency(v)}
                  </Text>
                </Pressable>
              ))}
            </View>

            {/* Datos bancarios */}
            <Text style={[st.sectionTitle, { marginTop: 24 }]}>Datos bancarios (SPEI)</Text>

            <View style={st.fieldWrap}>
              <CreditCard size={16} color={COLORS.muted2} style={st.fieldIcon} />
              <TextInput
                style={st.field}
                placeholder="CLABE (18 dígitos)"
                placeholderTextColor={COLORS.muted}
                keyboardType="number-pad"
                maxLength={18}
                value={clabe}
                onChangeText={setClabe}
              />
            </View>

            <View style={st.fieldWrap}>
              <Building2 size={16} color={COLORS.muted2} style={st.fieldIcon} />
              <TextInput
                style={st.field}
                placeholder="Banco (ej. BBVA, Banorte, HSBC)"
                placeholderTextColor={COLORS.muted}
                value={bankName}
                onChangeText={setBankName}
              />
            </View>

            <View style={st.fieldWrap}>
              <User size={16} color={COLORS.muted2} style={st.fieldIcon} />
              <TextInput
                style={st.field}
                placeholder="Nombre del titular de la cuenta"
                placeholderTextColor={COLORS.muted}
                value={accountHolder}
                onChangeText={setAccountHolder}
              />
            </View>

            {/* Info SPEI */}
            <View style={st.infoCard}>
              <Text style={st.infoText}>
                💡 Los retiros vía SPEI se procesan el mismo día (días hábiles 9am – 5pm).
                Una vez solicitado, el monto se descuenta inmediatamente de tu saldo.
              </Text>
            </View>

            <View style={{ marginTop: 24, marginBottom: 32 }}>
              <Button
                label={`Retirar ${amount ? formatCurrency(parseFloat(amount) || 0) : ''}`}
                onPress={handleWithdraw}
                loading={loading}
                size="lg"
                disabled={!amount || parseFloat(amount) <= 0}
              />
              <View style={{ height: 10 }} />
              <Button
                label="Cancelar"
                onPress={() => navigation.goBack()}
                variant="ghost"
                size="lg"
              />
            </View>
          </ScrollView>
        </KeyboardAvoidingView>
      </SafeAreaView>
    </View>
  );
}

const st = StyleSheet.create({
  container: { flex: 1, backgroundColor: COLORS.bg },
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
  scroll: { padding: SPACING.xl },

  balanceCard: {
    backgroundColor: COLORS.greenMuted, borderRadius: RADIUS.xl,
    borderWidth: 1, borderColor: COLORS.green + '40',
    padding: SPACING.xl, alignItems: 'center', marginBottom: 24,
  },
  balanceLabel:  { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted2, marginBottom: 4 },
  balanceAmount: { fontFamily: FONTS.title, fontSize: 34, color: COLORS.green },

  sectionTitle: { fontFamily: FONTS.title, fontSize: 17, color: COLORS.text, marginBottom: 12 },

  inputWrap: {
    flexDirection: 'row', alignItems: 'center',
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border,
    paddingHorizontal: SPACING.lg, marginBottom: 12,
  },
  inputPrefix: { fontFamily: FONTS.title, fontSize: 24, color: COLORS.green, marginRight: 8 },
  input: {
    flex: 1, fontFamily: FONTS.title, fontSize: 28, color: COLORS.text,
    paddingVertical: 16,
  },

  quickRow:    { flexDirection: 'row', gap: 8, marginBottom: 4 },
  quickBtn: {
    flex: 1, backgroundColor: COLORS.card2, borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: COLORS.border,
    paddingVertical: 10, alignItems: 'center',
  },
  quickBtnText: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.muted2 },

  fieldWrap: {
    flexDirection: 'row', alignItems: 'center',
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border,
    paddingHorizontal: SPACING.lg, marginBottom: 10,
  },
  fieldIcon: { marginRight: 10 },
  field: {
    flex: 1, fontFamily: FONTS.body, fontSize: 15, color: COLORS.text,
    paddingVertical: 14,
  },

  infoCard: {
    backgroundColor: 'rgba(255,152,0,0.08)', borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.orange + '50',
    padding: SPACING.lg, marginTop: 8,
  },
  infoText: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.orange, lineHeight: 20 },
});
