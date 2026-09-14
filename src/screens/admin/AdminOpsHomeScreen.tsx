import React, { useCallback, useEffect, useState } from 'react';
import {
  ActivityIndicator,
  Alert,
  Image,
  Linking,
  Modal,
  Pressable,
  RefreshControl,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  View,
} from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import * as ImagePicker from 'expo-image-picker';
import * as ImageManipulator from 'expo-image-manipulator';
import * as WebBrowser from 'expo-web-browser';
import { LogOut, Phone } from 'lucide-react-native';
import { supabase } from '../../config/supabase';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';
import { useAuth } from '../../context/AuthContext';

// Abre un comprobante guardado en el bucket 'refund-receipts' (mismo
// patrón que NotificationsScreen usa para el comprobante del cliente).
const openReceipt = async (receiptPath: string | null | undefined) => {
  if (!receiptPath) { Alert.alert('Sin comprobante', 'Este movimiento no tiene un comprobante guardado.'); return; }
  const { data, error } = await supabase.storage.from('refund-receipts').createSignedUrl(receiptPath, 3600);
  if (error || !data?.signedUrl) { Alert.alert('Error', 'No se pudo abrir el comprobante.'); return; }
  await WebBrowser.openBrowserAsync(data.signedUrl);
};

// sql/627-631 (2026-09-08) — panel reducido para cuentas role='admin_ops'.
// Cada RPC que llama esta pantalla YA filtra sus filas por
// profiles.admin_country_scope del lado del servidor (nunca confiamos
// solo en esta UI) — ver esos archivos para el detalle de seguridad.
// A propósito NO reutiliza DashboardScreen/FinancialScreen/
// VerificationsScreen (esas muestran secciones/datos globales — finanzas
// agregadas, disputas, anuncios — que un admin_ops nunca debe ver).
//
// Alcance de esta primera versión: las 3 colas pedidas (no-shows, pagos/
// transferencias, verificación). Disputas y "eventos a coordinar" quedan
// fuera por ahora (esas 2 tablas todavía no guardan país — ver nota en
// sql/630).

type Tab = 'resumen' | 'noshows' | 'pagos' | 'verificacion' | 'eventos' | 'historial';

const money = (n: number | null | undefined, currency = 'MXN') =>
  `$${Number(n ?? 0).toLocaleString('es-MX', { minimumFractionDigits: 2 })} ${currency}`;

export default function AdminOpsHomeScreen({ navigation }: any) {
  const { profile, signOut } = useAuth();
  const [tab, setTab] = useState<Tab>('resumen');

  return (
    <View style={{ flex: 1, backgroundColor: COLORS.bg }}>
      <SafeAreaView edges={['top']} style={s.header}>
        <View>
          <Text style={s.headerTitle}>Panel — {profile?.admin_country_scope === 'US' ? 'Estados Unidos' : profile?.admin_country_scope}</Text>
          <Text style={s.headerSub}>Solo ves lo que corresponde a tu país</Text>
        </View>
        <Pressable onPress={() => signOut()} hitSlop={10}>
          <LogOut size={20} color={COLORS.muted2} />
        </Pressable>
      </SafeAreaView>

      <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={s.tabs}>
        {([
          ['resumen', '📊 Resumen'],
          ['noshows', '🚨 No-shows'],
          ['pagos', '💵 Pagos'],
          ['verificacion', '🪪 Verificación'],
          ['eventos', '🔒 Eventos'],
          ['historial', '🧾 Historial'],
        ] as [Tab, string][]).map(([key, label]) => (
          <Pressable key={key} style={[s.tabBtn, tab === key && s.tabBtnActive]} onPress={() => setTab(key)}>
            <Text style={[s.tabBtnText, tab === key && s.tabBtnTextActive]}>{label}</Text>
          </Pressable>
        ))}
        {/* 📸 Fotos vive en su propia pantalla (se comparte con el admin
            completo — sql/641 ya la acota a EE.UU. del lado del servidor). */}
        <Pressable style={s.tabBtn} onPress={() => navigation.navigate('AdminMediaReview')}>
          <Text style={s.tabBtnText}>📸 Fotos</Text>
        </Pressable>
        {/* 📞 Cotizaciones que manejo — grupos en modo conserjería de tu
            país (sql/648 ya acota admin_get_concierge_quotes del lado del
            servidor). */}
        <Pressable style={s.tabBtn} onPress={() => navigation.navigate('AdminManagedQuotes')}>
          <Text style={s.tabBtnText}>📞 Cotizaciones</Text>
        </Pressable>
        {/* 📝 Solicitudes de proveedores — sql/649, ya acotado por país. */}
        <Pressable style={s.tabBtn} onPress={() => navigation.navigate('AdminProviderApplications')}>
          <Text style={s.tabBtnText}>📝 Solicitudes</Text>
        </Pressable>
      </ScrollView>

      {tab === 'resumen' && <ResumenTab navigation={navigation} />}
      {tab === 'noshows' && <NoShowsTab />}
      {tab === 'pagos' && <PagosTab />}
      {tab === 'verificacion' && <VerificacionTab />}
      {tab === 'eventos' && <EventosTab />}
      {tab === 'historial' && <HistorialTab />}
    </View>
  );
}

// ─────────────────────────────────────────────────────────────────────────
// TAB — RESUMEN (solo lectura, solo su país — "cuánto ha ganado Daricefy
// en Estados Unidos", el equivalente a lo que el admin completo ve para
// México en su panel de finanzas. Nunca muestra el dinero de otro país.)
// ─────────────────────────────────────────────────────────────────────────
function ResumenTab({ navigation }: any) {
  const [loading, setLoading] = useState(true);
  const [refreshing, setRefreshing] = useState(false);
  const [data, setData] = useState<any>(null);
  // Modo conserjería + solicitudes de proveedores (sql/648+649, 2026-09-13) —
  // visibles aquí y no solo en la campana de notificaciones.
  const [pendingConcierge, setPendingConcierge] = useState(0);
  const [pendingApps, setPendingApps] = useState(0);

  const load = useCallback(async () => {
    const { data: res, error } = await supabase.rpc('admin_ops_country_summary');
    if (!error && (res as any)?.ok) setData(res);

    const conciergeRes = await supabase.rpc('admin_get_concierge_quotes', { p_limit: 500 });
    setPendingConcierge((conciergeRes.data as any)?.items?.length ?? 0);

    const appsRes = await supabase.rpc('admin_get_provider_applications', { p_status: 'pending' });
    setPendingApps((appsRes.data as any)?.items?.length ?? 0);

    setLoading(false);
    setRefreshing(false);
  }, []);

  useEffect(() => { load(); }, [load]);

  if (loading) return <Centered><ActivityIndicator color={COLORS.green} /></Centered>;

  const currency = data?.country === 'US' ? 'USD' : 'MXN';

  return (
    <ScrollView
      contentContainerStyle={s.list}
      refreshControl={<RefreshControl refreshing={refreshing} onRefresh={() => { setRefreshing(true); load(); }} tintColor={COLORS.green} />}
    >
      {(pendingConcierge > 0 || pendingApps > 0) && (
        <View style={s.pendingRow}>
          {pendingConcierge > 0 && (
            <Pressable style={s.pendingCard} onPress={() => navigation.navigate('AdminManagedQuotes')}>
              <Text style={s.pendingCardNum}>{pendingConcierge}</Text>
              <Text style={s.pendingCardLbl}>📞 Por llamar</Text>
            </Pressable>
          )}
          {pendingApps > 0 && (
            <Pressable style={s.pendingCard} onPress={() => navigation.navigate('AdminProviderApplications')}>
              <Text style={s.pendingCardNum}>{pendingApps}</Text>
              <Text style={s.pendingCardLbl}>📝 Solicitudes</Text>
            </Pressable>
          )}
        </View>
      )}

      <Text style={s.sectionLabel}>Ingresos de {data?.country === 'US' ? 'Estados Unidos' : data?.country} (histórico)</Text>
      <View style={s.card}>
        <View style={s.summaryRow}>
          <Text style={s.summaryLabel}>Total cobrado a clientes</Text>
          <Text style={s.summaryValue}>{money(data?.total_cobrado, currency)}</Text>
        </View>
        <View style={s.summaryRow}>
          <Text style={s.summaryLabel}>Pagado/por pagar a proveedores</Text>
          <Text style={s.summaryValue}>{money(data?.dinero_grupos, currency)}</Text>
        </View>
        <View style={[s.summaryRow, { borderTopWidth: 1, borderTopColor: COLORS.border, paddingTop: 10, marginTop: 4 }]}>
          <Text style={[s.summaryLabel, { color: COLORS.green, fontFamily: FONTS.bodySemiBold }]}>Comisión de Daricefy</Text>
          <Text style={[s.summaryValue, { color: COLORS.green }]}>{money(data?.comision_daricefy, currency)}</Text>
        </View>
        <Text style={s.summaryFoot}>{data?.eventos_cobrados ?? 0} eventos cobrados en total</Text>
      </View>
    </ScrollView>
  );
}

// ─────────────────────────────────────────────────────────────────────────
// TAB — HISTORIAL (pagos ya realizados con su comprobante, separados por
// tipo — evento / propina / retiro / reembolso — para no mezclarlos)
// ─────────────────────────────────────────────────────────────────────────
const HISTORIAL_LABELS: Record<string, { icon: string; label: string }> = {
  evento:    { icon: '🎤', label: 'Pago de evento' },
  propina:   { icon: '🎁', label: 'Propinas pagadas' },
  retiro:    { icon: '🏦', label: 'Retiro' },
  reembolso: { icon: '↩️', label: 'Reembolso' },
};

function HistorialTab() {
  const [loading, setLoading] = useState(true);
  const [refreshing, setRefreshing] = useState(false);
  const [items, setItems] = useState<any[]>([]);
  const [filter, setFilter] = useState<'todos' | 'evento' | 'propina' | 'retiro' | 'reembolso'>('todos');

  const load = useCallback(async () => {
    const { data, error } = await supabase.rpc('admin_get_payment_history', { p_limit: 100 });
    if (!error && (data as any)?.ok) setItems((data as any).items ?? []);
    setLoading(false);
    setRefreshing(false);
  }, []);

  useEffect(() => { load(); }, [load]);

  const filtered = filter === 'todos' ? items : items.filter(it => it.kind === filter);

  if (loading) return <Centered><ActivityIndicator color={COLORS.green} /></Centered>;

  return (
    <ScrollView
      contentContainerStyle={s.list}
      refreshControl={<RefreshControl refreshing={refreshing} onRefresh={() => { setRefreshing(true); load(); }} tintColor={COLORS.green} />}
    >
      <View style={s.filterRow}>
        {(['todos', 'evento', 'propina', 'retiro', 'reembolso'] as const).map(k => (
          <Pressable key={k} style={[s.filterChip, filter === k && s.filterChipActive]} onPress={() => setFilter(k)}>
            <Text style={[s.filterChipText, filter === k && s.filterChipTextActive]}>
              {k === 'todos' ? 'Todos' : HISTORIAL_LABELS[k].label}
            </Text>
          </Pressable>
        ))}
      </View>

      {filtered.length === 0 && <EmptyBox icon="🧾" text="Sin movimientos todavía" />}
      {filtered.map((it) => {
        const meta = HISTORIAL_LABELS[it.kind] ?? { icon: '💳', label: it.kind };
        return (
          <View key={it.id} style={s.card}>
            <View style={s.cardRow}>
              <Text style={s.cardTitle} numberOfLines={1}>{meta.icon} {it.group_name ?? '—'}</Text>
              <Text style={s.cardAmount}>{money(it.amount)}</Text>
            </View>
            <Text style={s.cardMeta}>
              {meta.label} · {new Date(it.created_at).toLocaleDateString('es-MX', { day: 'numeric', month: 'short', year: 'numeric' })}
              {it.transfer_ref ? ` · ref ${it.transfer_ref}` : ''}
            </Text>
            <ActionBtn label="Ver comprobante" color={COLORS.green} onPress={() => openReceipt(it.receipt_path)} />
          </View>
        );
      })}
    </ScrollView>
  );
}

// ─────────────────────────────────────────────────────────────────────────
// TAB 1 — NO-SHOWS
// ─────────────────────────────────────────────────────────────────────────
function NoShowsTab() {
  const [loading, setLoading] = useState(true);
  const [refreshing, setRefreshing] = useState(false);
  const [items, setItems] = useState<any[]>([]);
  const [busyId, setBusyId] = useState<string | null>(null);

  const load = useCallback(async () => {
    const { data, error } = await supabase.rpc('admin_get_no_shows', { p_limit: 50 });
    if (!error && (data as any)?.ok) setItems((data as any).items ?? []);
    setLoading(false);
    setRefreshing(false);
  }, []);

  useEffect(() => { load(); }, [load]);

  const resolve = async (id: string, resolution: 'refunded_100' | 'no_refund' | 'reviewed') => {
    setBusyId(id);
    const { data, error } = await supabase.rpc('admin_resolve_no_show', {
      p_reservation_id: id, p_resolution: resolution,
    });
    setBusyId(null);
    if (error || (data as any)?.ok === false) {
      Alert.alert('Error', (data as any)?.error ?? error?.message ?? 'No se pudo resolver');
      return;
    }
    load();
  };

  if (loading) return <Centered><ActivityIndicator color={COLORS.green} /></Centered>;

  return (
    <ScrollView
      contentContainerStyle={s.list}
      refreshControl={<RefreshControl refreshing={refreshing} onRefresh={() => { setRefreshing(true); load(); }} tintColor={COLORS.green} />}
    >
      {items.length === 0 && <EmptyBox icon="✅" text="Sin no-shows pendientes" />}
      {items.map((it) => (
        <View key={it.id} style={s.card}>
          <View style={s.cardRow}>
            <Text style={s.cardTitle} numberOfLines={1}>{it.group_name ?? 'Grupo'}</Text>
            <Text style={s.cardAmount}>{money(it.total_price, it.currency)}</Text>
          </View>
          <Text style={s.cardMeta}>{it.event_date} {it.event_time ?? ''} · {it.city ?? it.state ?? it.country}</Text>
          {!!it.client_name && <Text style={s.cardMeta}>Cliente: {it.client_name}</Text>}
          {it.has_strike && <Text style={s.strikeBadge}>⚠️ Ya tiene strike por no-show</Text>}
          <View style={s.phoneRow}>
            {!!it.group_phone && <CallPill phone={it.group_phone} label="Grupo" />}
            {!!it.client_phone && <CallPill phone={it.client_phone} label="Cliente" />}
          </View>
          <View style={s.actionsRow}>
            <ActionBtn label="Reembolsar 100%" color={COLORS.green} busy={busyId === it.id} onPress={() => resolve(it.id, 'refunded_100')} />
            <ActionBtn label="Sin reembolso" color={COLORS.orange} busy={busyId === it.id} onPress={() => resolve(it.id, 'no_refund')} />
            <ActionBtn label="Solo revisar" color={COLORS.muted2} busy={busyId === it.id} onPress={() => resolve(it.id, 'reviewed')} />
          </View>
        </View>
      ))}
    </ScrollView>
  );
}

// ─────────────────────────────────────────────────────────────────────────
// TAB 2 — PAGOS (eventos, propinas, retiros)
// ─────────────────────────────────────────────────────────────────────────
type PayKind = 'advance' | 'final_settlement' | 'gift' | 'withdrawal';
interface PayModal {
  kind: PayKind;
  id: string;          // reservation_id | group_id | withdrawal_id
  groupId?: string;
  title: string;
  suggestedAmount: number;
  currency: string;
}

function PagosTab() {
  const [loading, setLoading] = useState(true);
  const [refreshing, setRefreshing] = useState(false);
  const [groupPayments, setGroupPayments] = useState<any[]>([]);
  const [giftPayouts, setGiftPayouts] = useState<any[]>([]);
  const [withdrawals, setWithdrawals] = useState<any[]>([]);
  const [modal, setModal] = useState<PayModal | null>(null);
  const [reference, setReference] = useState('');
  const [receiptUri, setReceiptUri] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);

  const load = useCallback(async () => {
    const [gp, gg, wd] = await Promise.all([
      supabase.rpc('admin_get_pending_group_payments', { p_limit: 50 }),
      supabase.rpc('admin_get_pending_gift_payouts'),
      supabase.rpc('admin_withdrawals_queue', { p_limit: 60 }),
    ]);
    if ((gp.data as any)?.ok) setGroupPayments((gp.data as any).items ?? []);
    if ((gg.data as any)?.ok) setGiftPayouts((gg.data as any).items ?? []);
    if (!wd.error && Array.isArray(wd.data)) {
      setWithdrawals((wd.data as any[]).filter(w => w.status === 'pending' || w.status === 'processing'));
    }
    setLoading(false);
    setRefreshing(false);
  }, []);

  useEffect(() => { load(); }, [load]);

  const pickReceipt = async () => {
    const res = await ImagePicker.launchImageLibraryAsync({ mediaTypes: ['images'], quality: 0.8, allowsEditing: false });
    if (res.canceled || !res.assets?.[0]?.uri) return;
    try {
      const small = await ImageManipulator.manipulateAsync(
        res.assets[0].uri, [{ resize: { width: 1200 } }],
        { compress: 0.7, format: ImageManipulator.SaveFormat.JPEG },
      );
      setReceiptUri(small.uri);
    } catch {
      setReceiptUri(res.assets[0].uri);
    }
  };

  const closeModal = () => { setModal(null); setReference(''); setReceiptUri(null); };

  const confirmPayment = async () => {
    if (!modal) return;
    if (!receiptUri) { Alert.alert('Falta el comprobante', 'Sube una foto de la transferencia'); return; }
    if (!reference.trim() && modal.kind !== 'advance') {
      Alert.alert('Falta la referencia', 'Escribe la referencia de la transferencia'); return;
    }
    setSaving(true);
    try {
      const folder = modal.groupId ?? modal.id;
      const receiptPath = `${folder}/${modal.kind}_${modal.id}_${Date.now()}.jpg`;
      const buf = await fetch(receiptUri).then(r => r.arrayBuffer());
      const { error: upErr } = await supabase.storage
        .from('refund-receipts')
        .upload(receiptPath, buf, { contentType: 'image/jpeg', upsert: true });
      if (upErr) throw new Error('No se pudo subir el comprobante: ' + upErr.message);

      let res: any;
      const nowIso = new Date().toISOString();
      if (modal.kind === 'advance' || modal.kind === 'final_settlement') {
        res = await supabase.rpc('admin_register_group_payment', {
          p_reservation_id: modal.id, p_amount: modal.suggestedAmount, p_kind: modal.kind,
          p_receipt_path: receiptPath, p_note: null,
          p_transfer_reference: reference.trim() || null, p_transferred_at: nowIso,
        });
      } else if (modal.kind === 'gift') {
        res = await supabase.rpc('admin_register_gift_payout', {
          p_group_id: modal.id, p_amount: modal.suggestedAmount, p_currency_code: modal.currency,
          p_receipt_path: receiptPath, p_transfer_reference: reference.trim(), p_transferred_at: nowIso,
        });
      } else {
        res = await supabase.rpc('admin_complete_payout', {
          p_payout_id: modal.id, p_transfer_reference: reference.trim(), p_receipt_path: receiptPath,
        });
      }
      if (res.error || res.data?.ok === false) {
        throw new Error(res.data?.error ?? res.error?.message ?? 'No se pudo registrar el pago');
      }
      Alert.alert('Listo', 'Pago registrado y notificado al grupo');
      closeModal();
      load();
    } catch (e: any) {
      Alert.alert('Error', e?.message ?? 'No se pudo registrar el pago');
    } finally {
      setSaving(false);
    }
  };

  if (loading) return <Centered><ActivityIndicator color={COLORS.green} /></Centered>;

  return (
    <>
      <ScrollView
        contentContainerStyle={s.list}
        refreshControl={<RefreshControl refreshing={refreshing} onRefresh={() => { setRefreshing(true); load(); }} tintColor={COLORS.green} />}
      >
        <SectionLabel text="Pagos de eventos" count={groupPayments.length} />
        {groupPayments.length === 0 && <EmptyBox icon="💵" text="Sin pagos pendientes" small />}
        {groupPayments.map((it) => (
          <View key={it.reservation_id} style={s.card}>
            <View style={s.cardRow}>
              <Text style={s.cardTitle} numberOfLines={1}>{it.group_name}</Text>
              <Text style={s.cardAmount}>{money(it.saldo_pendiente, it.currency_code)}</Text>
            </View>
            <Text style={s.cardMeta}>{it.event_date} · {it.client_name ?? '—'}</Text>
            {!it.bank_clabe && <Text style={s.warnText}>⚠️ Sin datos bancarios registrados</Text>}
            <ActionBtn
              label="Registrar pago"
              color={COLORS.green}
              disabled={!it.bank_clabe}
              onPress={() => setModal({
                kind: 'final_settlement', id: it.reservation_id, groupId: it.group_id,
                title: `Pago a ${it.group_name}`, suggestedAmount: it.saldo_pendiente, currency: it.currency_code,
              })}
            />
          </View>
        ))}

        <SectionLabel text="Propinas/regalos acumulados" count={giftPayouts.length} />
        {giftPayouts.length === 0 && <EmptyBox icon="🎁" text="Sin solicitudes pendientes" small />}
        {giftPayouts.map((it) => (
          <View key={it.request_id} style={s.card}>
            <View style={s.cardRow}>
              <Text style={s.cardTitle} numberOfLines={1}>{it.group_name}</Text>
              <Text style={s.cardAmount}>{money(it.amount, it.currency)}</Text>
            </View>
            {!it.bank_clabe && <Text style={s.warnText}>⚠️ Sin datos bancarios registrados</Text>}
            <ActionBtn
              label="Registrar pago"
              color={COLORS.green}
              disabled={!it.bank_clabe}
              onPress={() => setModal({
                kind: 'gift', id: it.group_id, title: `Propinas a ${it.group_name}`,
                suggestedAmount: it.amount, currency: it.currency,
              })}
            />
          </View>
        ))}

        <SectionLabel text="Retiros" count={withdrawals.length} />
        {withdrawals.length === 0 && <EmptyBox icon="🏦" text="Sin retiros pendientes" small />}
        {withdrawals.map((it) => (
          <View key={it.id} style={s.card}>
            <View style={s.cardRow}>
              <Text style={s.cardTitle} numberOfLines={1}>{it.owner_name ?? it.group_name ?? 'Usuario'}</Text>
              <Text style={s.cardAmount}>{money(it.amount, it.currency)}</Text>
            </View>
            <Text style={s.cardMeta}>{it.expected_method === 'stripe_ach' ? 'ACH (Stripe)' : 'SPEI'} · {it.status}</Text>
            <ActionBtn
              label="Marcar transferido"
              color={COLORS.green}
              onPress={() => setModal({
                kind: 'withdrawal', id: it.id, title: `Retiro de ${it.owner_name ?? ''}`,
                suggestedAmount: it.amount, currency: it.currency,
              })}
            />
          </View>
        ))}
      </ScrollView>

      <Modal visible={!!modal} transparent animationType="fade" onRequestClose={closeModal}>
        <View style={s.modalOverlay}>
          <View style={s.modalCard}>
            <Text style={s.modalTitle}>{modal?.title}</Text>
            <Text style={s.modalAmount}>{money(modal?.suggestedAmount, modal?.currency)}</Text>

            <Pressable style={s.pickBtn} onPress={pickReceipt}>
              {receiptUri ? (
                <Image source={{ uri: receiptUri }} style={s.receiptPreview} />
              ) : (
                <Text style={s.pickBtnText}>📷 Subir comprobante de transferencia</Text>
              )}
            </Pressable>

            <TextInput
              style={s.input}
              placeholder="Referencia de la transferencia"
              placeholderTextColor={COLORS.muted}
              value={reference}
              onChangeText={setReference}
            />

            <View style={s.modalActions}>
              <Pressable style={s.modalCancelBtn} onPress={closeModal}>
                <Text style={s.modalCancelText}>Cancelar</Text>
              </Pressable>
              <Pressable style={s.modalConfirmBtn} onPress={confirmPayment} disabled={saving}>
                {saving ? <ActivityIndicator color={COLORS.bg} /> : <Text style={s.modalConfirmText}>Confirmar pago</Text>}
              </Pressable>
            </View>
          </View>
        </View>
      </Modal>
    </>
  );
}

// ─────────────────────────────────────────────────────────────────────────
// TAB 3 — VERIFICACIÓN / KYC
// ─────────────────────────────────────────────────────────────────────────
function VerificacionTab() {
  const [loading, setLoading] = useState(true);
  const [refreshing, setRefreshing] = useState(false);
  const [groups, setGroups] = useState<any[]>([]);
  const [profiles, setProfiles] = useState<any[]>([]);
  const [busyId, setBusyId] = useState<string | null>(null);

  const load = useCallback(async () => {
    const [g, p] = await Promise.all([
      supabase.rpc('admin_get_pending_group_verifications', { p_limit: 50 }),
      supabase.rpc('admin_get_pending_profile_verifications', { p_limit: 50 }),
    ]);
    if ((g.data as any)?.ok) setGroups((g.data as any).items ?? []);
    if ((p.data as any)?.ok) setProfiles((p.data as any).items ?? []);
    setLoading(false);
    setRefreshing(false);
  }, []);

  useEffect(() => { load(); }, [load]);

  const reviewGroup = async (id: string, approved: boolean) => {
    setBusyId(id);
    const { data, error } = await supabase.rpc('admin_review_group_verification', { p_attempt_id: id, p_approved: approved });
    setBusyId(null);
    if (error || (data as any)?.ok === false) { Alert.alert('Error', (data as any)?.error ?? error?.message); return; }
    load();
  };

  const reviewProfile = async (id: string, approved: boolean) => {
    setBusyId(id);
    const { data, error } = await supabase.rpc('admin_set_profile_verified', { p_user_id: id, p_verified: approved });
    setBusyId(null);
    if (error || (data as any)?.ok === false) { Alert.alert('Error', (data as any)?.error ?? error?.message); return; }
    load();
  };

  if (loading) return <Centered><ActivityIndicator color={COLORS.green} /></Centered>;

  return (
    <ScrollView
      contentContainerStyle={s.list}
      refreshControl={<RefreshControl refreshing={refreshing} onRefresh={() => { setRefreshing(true); load(); }} tintColor={COLORS.green} />}
    >
      <SectionLabel text="Grupos/proveedores" count={groups.length} />
      {groups.length === 0 && <EmptyBox icon="🪪" text="Sin solicitudes pendientes" small />}
      {groups.map((it) => (
        <View key={it.id} style={s.card}>
          <Text style={s.cardTitle}>{it.group_name}</Text>
          <Text style={s.cardMeta}>{it.city ?? it.state ?? it.country}</Text>
          <View style={s.photoRow}>
            {!!it.document_url && <Image source={{ uri: it.document_url }} style={s.photoThumb} />}
            {!!it.selfie_url && <Image source={{ uri: it.selfie_url }} style={s.photoThumb} />}
          </View>
          <View style={s.actionsRow}>
            <ActionBtn label="Aprobar" color={COLORS.green} busy={busyId === it.id} onPress={() => reviewGroup(it.id, true)} />
            <ActionBtn label="Rechazar" color={COLORS.red} busy={busyId === it.id} onPress={() => reviewGroup(it.id, false)} />
          </View>
        </View>
      ))}

      <SectionLabel text="Clientes y talentos" count={profiles.length} />
      {profiles.length === 0 && <EmptyBox icon="👤" text="Sin solicitudes pendientes" small />}
      {profiles.map((it) => (
        <View key={it.id} style={s.card}>
          <Text style={s.cardTitle}>{it.full_name}</Text>
          <Text style={s.cardMeta}>{it.role === 'talent' ? 'Talento' : 'Cliente'} · {it.city ?? it.state ?? it.country}</Text>
          <View style={s.actionsRow}>
            <ActionBtn label="Aprobar" color={COLORS.green} busy={busyId === it.id} onPress={() => reviewProfile(it.id, true)} />
            <ActionBtn label="Rechazar" color={COLORS.red} busy={busyId === it.id} onPress={() => reviewProfile(it.id, false)} />
          </View>
        </View>
      ))}
    </ScrollView>
  );
}

// ─────────────────────────────────────────────────────────────────────────
// TAB — EVENTOS (sql/640+641, 2026-09-11) — forzar inicio de eventos que
// nunca arrancaron y forzar cierre de eventos que iniciaron pero nunca
// cerraron (p.ej. el cliente nunca dio el código de "servicio terminado").
// Ambas RPCs ya vienen acotadas a EE.UU. del lado del servidor.
// ─────────────────────────────────────────────────────────────────────────
function EventosTab() {
  const [loading, setLoading] = useState(true);
  const [refreshing, setRefreshing] = useState(false);
  const [notStarted, setNotStarted] = useState<any[]>([]);
  const [notEnded, setNotEnded] = useState<any[]>([]);
  const [busyId, setBusyId] = useState<string | null>(null);

  const load = useCallback(async () => {
    const [a, b] = await Promise.all([
      supabase.rpc('admin_get_stuck_events', { p_limit: 50 }),
      supabase.rpc('admin_get_stuck_service_events', { p_limit: 50 }),
    ]);
    if (!a.error && (a.data as any)?.ok) setNotStarted((a.data as any).items ?? []);
    if (!b.error && (b.data as any)?.ok) setNotEnded((b.data as any).items ?? []);
    setLoading(false);
    setRefreshing(false);
  }, []);

  useEffect(() => { load(); }, [load]);

  const forceStart = async (id: string) => {
    setBusyId(id);
    const { data, error } = await supabase.rpc('admin_force_start_event', { p_reservation_id: id });
    setBusyId(null);
    if (error || (data as any)?.ok === false) {
      Alert.alert('Error', (data as any)?.error ?? error?.message ?? 'No se pudo forzar el inicio.');
      return;
    }
    load();
  };

  const forceComplete = (id: string) => {
    Alert.alert(
      'Forzar cierre del evento',
      'Esto marca el evento como terminado AHORA MISMO y libera el pago pendiente del grupo. Confírmalo primero con ambos por teléfono.',
      [
        { text: 'Cancelar', style: 'cancel' },
        {
          text: 'Sí, forzar cierre', style: 'destructive',
          onPress: async () => {
            setBusyId(id);
            const { data, error } = await supabase.rpc('admin_force_complete_event', {
              p_reservation_id: id,
              p_reason: 'Confirmado por soporte vía AdminOpsHomeScreen (EE.UU.)',
            });
            setBusyId(null);
            if (error || (data as any)?.ok === false) {
              Alert.alert('Error', (data as any)?.error ?? error?.message ?? 'No se pudo forzar el cierre.');
              return;
            }
            load();
          },
        },
      ],
    );
  };

  if (loading) return <Centered><ActivityIndicator color={COLORS.green} /></Centered>;

  return (
    <ScrollView
      contentContainerStyle={s.list}
      refreshControl={<RefreshControl refreshing={refreshing} onRefresh={() => { setRefreshing(true); load(); }} tintColor={COLORS.green} />}
    >
      <SectionLabel text="Nunca iniciaron (ya pasó su hora)" count={notStarted.length} />
      {notStarted.length === 0 && <EmptyBox icon="✅" text="Nada atorado sin iniciar" small />}
      {notStarted.map((it) => (
        <View key={it.id} style={s.card}>
          <View style={s.cardRow}>
            <Text style={s.cardTitle} numberOfLines={1}>{it.group_name ?? 'Grupo'}</Text>
            <Text style={s.cardAmount}>{money(it.total_price, it.currency)}</Text>
          </View>
          <Text style={s.cardMeta}>{it.event_date} {it.event_time ?? ''} · lleva {Math.round((it.minutes_late ?? 0) / 60)}h de retraso</Text>
          {!!it.client_name && <Text style={s.cardMeta}>Cliente: {it.client_name}</Text>}
          <View style={s.phoneRow}>
            {!!it.group_phone && <CallPill phone={it.group_phone} label="Grupo" />}
            {!!it.client_phone && <CallPill phone={it.client_phone} label="Cliente" />}
          </View>
          <View style={s.actionsRow}>
            <ActionBtn label="Forzar inicio" color={COLORS.green} busy={busyId === it.id} onPress={() => forceStart(it.id)} />
          </View>
        </View>
      ))}

      <SectionLabel text="Iniciaron pero nunca cerraron" count={notEnded.length} />
      {notEnded.length === 0 && <EmptyBox icon="✅" text="Nada atorado sin cerrar" small />}
      {notEnded.map((it) => (
        <View key={it.id} style={s.card}>
          <View style={s.cardRow}>
            <Text style={s.cardTitle} numberOfLines={1}>{it.group_name ?? 'Grupo'} {it.group_genre ? `· ${it.group_genre}` : ''}</Text>
            <Text style={s.cardAmount}>{money(it.total_price, it.currency)}</Text>
          </View>
          <Text style={s.cardMeta}>{it.event_date} {it.event_time ?? ''} · lleva {it.hours_stuck}h sin cerrarse</Text>
          {!!it.client_name && <Text style={s.cardMeta}>Cliente: {it.client_name}</Text>}
          <View style={s.phoneRow}>
            {!!it.group_phone && <CallPill phone={it.group_phone} label="Grupo" />}
            {!!it.client_phone && <CallPill phone={it.client_phone} label="Cliente" />}
          </View>
          <View style={s.actionsRow}>
            <ActionBtn label="Forzar cierre" color={'#EF5350'} busy={busyId === it.id} onPress={() => forceComplete(it.id)} />
          </View>
        </View>
      ))}
    </ScrollView>
  );
}

// ─────────────────────────────────────────────────────────────────────────
// Piezas compartidas
// ─────────────────────────────────────────────────────────────────────────
function Centered({ children }: { children: React.ReactNode }) {
  return <View style={{ flex: 1, backgroundColor: COLORS.bg, alignItems: 'center', justifyContent: 'center' }}>{children}</View>;
}

function EmptyBox({ icon, text, small }: { icon: string; text: string; small?: boolean }) {
  return (
    <View style={[s.emptyBox, small && { paddingVertical: 24 }]}>
      <Text style={s.emptyIcon}>{icon}</Text>
      <Text style={s.emptyTx}>{text}</Text>
    </View>
  );
}

function SectionLabel({ text, count }: { text: string; count: number }) {
  return (
    <Text style={s.sectionLabel}>{text}{count > 0 ? `  ·  ${count}` : ''}</Text>
  );
}

function CallPill({ phone, label }: { phone: string; label: string }) {
  return (
    <Pressable style={s.callPill} onPress={() => Linking.openURL(`tel:${phone}`)}>
      <Phone size={12} color={COLORS.green} />
      <Text style={s.callPillText}>{label}: {phone}</Text>
    </Pressable>
  );
}

function ActionBtn({ label, color, onPress, busy, disabled }: { label: string; color: string; onPress: () => void; busy?: boolean; disabled?: boolean }) {
  return (
    <Pressable
      style={[s.actionBtn, { borderColor: color }, disabled && s.actionBtnDisabled]}
      onPress={onPress}
      disabled={busy || disabled}
    >
      {busy ? <ActivityIndicator size="small" color={color} /> : <Text style={[s.actionBtnText, { color }]}>{label}</Text>}
    </Pressable>
  );
}

const s = StyleSheet.create({
  header: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between',
    paddingHorizontal: SPACING.xl, paddingBottom: 12,
  },
  headerTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 16, color: COLORS.text },
  headerSub: { fontFamily: FONTS.body, fontSize: 11.5, color: COLORS.muted2, marginTop: 2 },

  tabs: { flexDirection: 'row', paddingHorizontal: SPACING.lg, gap: 8, marginBottom: 8 },
  tabBtn: {
    flex: 1, paddingVertical: 9, borderRadius: RADIUS.md, alignItems: 'center',
    backgroundColor: COLORS.card, borderWidth: 1, borderColor: COLORS.border,
  },
  tabBtnActive: { backgroundColor: COLORS.greenMuted, borderColor: COLORS.green },
  tabBtnText: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.muted2 },
  tabBtnTextActive: { color: COLORS.green },

  list: { padding: SPACING.xl, paddingTop: 4, gap: 12 },

  pendingRow: { flexDirection: 'row', gap: 10, marginBottom: 4 },
  pendingCard: {
    flex: 1, alignItems: 'center', gap: 4, paddingVertical: 14,
    backgroundColor: COLORS.greenMuted, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.green,
  },
  pendingCardNum: { fontFamily: FONTS.title, fontSize: 22, color: COLORS.green },
  pendingCardLbl: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.text },

  sectionLabel: {
    fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.muted2,
    textTransform: 'uppercase', letterSpacing: 0.5, marginTop: 10, marginBottom: 2,
  },
  card: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg, borderWidth: 1,
    borderColor: COLORS.border, padding: 14, gap: 6,
  },
  cardRow: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', gap: 8 },
  cardTitle: { flex: 1, fontFamily: FONTS.bodySemiBold, fontSize: 14.5, color: COLORS.text },
  cardAmount: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.green },
  cardMeta: { fontFamily: FONTS.body, fontSize: 12.5, color: COLORS.muted2 },
  strikeBadge: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.orange },
  warnText: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.orange },

  phoneRow: { flexDirection: 'row', gap: 8, flexWrap: 'wrap' },
  callPill: {
    flexDirection: 'row', alignItems: 'center', gap: 4, paddingHorizontal: 8, paddingVertical: 4,
    borderRadius: RADIUS.md, backgroundColor: COLORS.greenMuted, borderWidth: 1, borderColor: COLORS.green,
  },
  callPillText: { fontFamily: FONTS.bodyMedium, fontSize: 11.5, color: COLORS.green },

  photoRow: { flexDirection: 'row', gap: 8 },
  photoThumb: { width: 72, height: 72, borderRadius: RADIUS.sm, backgroundColor: COLORS.card2 },

  actionsRow: { flexDirection: 'row', gap: 8, flexWrap: 'wrap', marginTop: 4 },
  actionBtn: {
    paddingHorizontal: 12, paddingVertical: 7, borderRadius: RADIUS.md, borderWidth: 1,
  },
  actionBtnDisabled: { opacity: 0.4 },
  actionBtnText: { fontFamily: FONTS.bodyMedium, fontSize: 12 },

  emptyBox: { alignItems: 'center', paddingVertical: 40, gap: 6 },
  emptyIcon: { fontSize: 32 },
  emptyTx: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2 },

  summaryRow: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', paddingVertical: 6 },
  summaryLabel: { fontFamily: FONTS.body, fontSize: 13.5, color: COLORS.muted2, flex: 1 },
  summaryValue: { fontFamily: FONTS.bodySemiBold, fontSize: 14.5, color: COLORS.text },
  summaryFoot: { fontFamily: FONTS.body, fontSize: 11.5, color: COLORS.muted, marginTop: 10 },

  filterRow: { flexDirection: 'row', flexWrap: 'wrap', gap: 8, marginBottom: 4 },
  filterChip: {
    paddingHorizontal: 12, paddingVertical: 6, borderRadius: RADIUS.full,
    backgroundColor: COLORS.card, borderWidth: 1, borderColor: COLORS.border,
  },
  filterChipActive: { backgroundColor: COLORS.greenMuted, borderColor: COLORS.green },
  filterChipText: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.muted2 },
  filterChipTextActive: { color: COLORS.green },

  modalOverlay: { flex: 1, backgroundColor: COLORS.overlay, alignItems: 'center', justifyContent: 'center', padding: SPACING.xl },
  modalCard: {
    width: '100%', backgroundColor: COLORS.card, borderRadius: RADIUS.xl, borderWidth: 1,
    borderColor: COLORS.border, padding: SPACING.lg, gap: 12,
  },
  modalTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.text },
  modalAmount: { fontFamily: FONTS.title, fontSize: 22, color: COLORS.green },
  pickBtn: {
    borderWidth: 1, borderColor: COLORS.border, borderStyle: 'dashed', borderRadius: RADIUS.md,
    alignItems: 'center', justifyContent: 'center', minHeight: 90, overflow: 'hidden',
  },
  pickBtnText: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted2, padding: 16, textAlign: 'center' },
  receiptPreview: { width: '100%', height: 140 },
  input: {
    borderWidth: 1, borderColor: COLORS.border, borderRadius: RADIUS.md, paddingHorizontal: 12,
    paddingVertical: 10, fontFamily: FONTS.body, fontSize: 13, color: COLORS.text, backgroundColor: COLORS.card2,
  },
  modalActions: { flexDirection: 'row', gap: 10, marginTop: 4 },
  modalCancelBtn: { flex: 1, alignItems: 'center', paddingVertical: 12, borderRadius: RADIUS.md, borderWidth: 1, borderColor: COLORS.border },
  modalCancelText: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted2 },
  modalConfirmBtn: { flex: 1, alignItems: 'center', paddingVertical: 12, borderRadius: RADIUS.md, backgroundColor: COLORS.green },
  modalConfirmText: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.bg },
});
