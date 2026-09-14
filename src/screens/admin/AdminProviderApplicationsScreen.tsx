/**
 * AdminProviderApplicationsScreen — solicitudes de proveedores nuevos (sql/649).
 *
 * Antes cualquiera se registraba directo como grupo. Ahora todo proveedor
 * nuevo manda esta solicitud (ProviderApplyScreen, sin sesión) y aparece
 * aquí. El admin lo contacta por WhatsApp para pedirle foto + hasta 3
 * videos, y si aprueba, esta pantalla crea la cuenta real con un clic —
 * el grupo nace en modo conserjería (sql/648), Daniel maneja sus primeras
 * cotizaciones hasta que el grupo gane confianza.
 *
 * Compartida entre role='admin' y role='admin_ops' — el RPC ya filtra por país.
 */
import { ArrowLeft, Briefcase, Calendar, Clock, MapPin, Phone } from 'lucide-react-native';
import React, { useCallback, useEffect, useState } from 'react';
import {
  ActivityIndicator,
  Alert,
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
import { supabase } from '../../config/supabase';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';

const call = (phone?: string | null) => { if (phone) Linking.openURL(`tel:${phone}`); };
const fecha = (d?: string | null) =>
  d ? new Date(d).toLocaleDateString('es-MX', { day: '2-digit', month: 'short', year: '2-digit' }) : '—';

const CATEGORY_LABELS: Record<string, string> = {
  grupo: 'Grupo musical', solista: 'Solista', dj: 'DJ', comediante: 'Comediante',
  espectaculo: 'Show', mc: 'Maestro de Ceremonias', luzSonido: 'Luz y sonido',
  comida: 'Comida', renta: 'Renta de mobiliario', fotografos: 'Fotografía/Video',
};

type TabKey = 'pending' | 'approved' | 'rejected' | 'all';

interface AppItem {
  id: string;
  full_name: string;
  phone: string;
  category: string;
  years_experience: number | null;
  min_hours: number | null;
  country: string | null;
  state: string | null;
  city: string | null;
  notes: string | null;
  status: 'pending' | 'contacted' | 'approved' | 'rejected';
  admin_notes: string | null;
  linked_group_id: string | null;
  created_at: string;
}

export default function AdminProviderApplicationsScreen({ navigation }: any) {
  const [tab, setTab] = useState<TabKey>('pending');
  const [items, setItems] = useState<AppItem[]>([]);
  const [loading, setLoading] = useState(true);
  const [refreshing, setRefreshing] = useState(false);

  const [approveTarget, setApproveTarget] = useState<AppItem | null>(null);
  const [email, setEmail] = useState('');
  const [genre, setGenre] = useState('');
  const [tempPassword, setTempPassword] = useState('');
  const [approving, setApproving] = useState(false);

  const [rejectTarget, setRejectTarget] = useState<AppItem | null>(null);
  const [rejectReason, setRejectReason] = useState('');
  const [rejecting, setRejecting] = useState(false);

  const load = useCallback(async (t: TabKey) => {
    const p_status = t === 'all' ? null : t;
    const { data, error } = await supabase.rpc('admin_get_provider_applications', { p_status });
    if (!error && data?.ok) setItems(data.items ?? []);
    setLoading(false);
    setRefreshing(false);
  }, []);

  useEffect(() => { setLoading(true); load(tab); }, [tab, load]);

  const onRefresh = () => { setRefreshing(true); load(tab); };

  const openApprove = (item: AppItem) => {
    setApproveTarget(item);
    setEmail('');
    setGenre('');
    setTempPassword('');
  };

  const sendApprove = async () => {
    if (!approveTarget) return;
    if (!email.trim() || !genre.trim()) {
      Alert.alert('Faltan datos', 'Escribe el correo y el género exacto del grupo.');
      return;
    }
    setApproving(true);
    const { data, error } = await supabase.rpc('admin_approve_provider_application', {
      p_application_id: approveTarget.id,
      p_email: email.trim(),
      p_genre: genre.trim(),
      p_temp_password: tempPassword.trim() || null,
    });
    setApproving(false);
    if (error || !data?.ok) {
      Alert.alert('Error', error?.message ?? data?.error ?? 'No se pudo aprobar.');
      return;
    }
    setApproveTarget(null);
    setItems(prev => prev.filter(i => i.id !== approveTarget.id));
    Alert.alert(
      '✅ Cuenta creada',
      `Correo: ${data.email}\nContraseña: ${data.temp_password}\n\nPásaselos al proveedor por WhatsApp.`,
    );
  };

  const openReject = (item: AppItem) => {
    setRejectTarget(item);
    setRejectReason('');
  };

  const sendReject = async () => {
    if (!rejectTarget) return;
    setRejecting(true);
    const { data, error } = await supabase.rpc('admin_reject_provider_application', {
      p_application_id: rejectTarget.id,
      p_reason: rejectReason.trim() || null,
    });
    setRejecting(false);
    if (error || !data?.ok) {
      Alert.alert('Error', error?.message ?? data?.error ?? 'No se pudo rechazar.');
      return;
    }
    setRejectTarget(null);
    setItems(prev => prev.filter(i => i.id !== rejectTarget.id));
  };

  return (
    <View style={s.container}>
      <SafeAreaView style={{ flex: 1 }}>
        <View style={s.header}>
          <Pressable style={s.backBtn} onPress={() => navigation.goBack()}>
            <ArrowLeft size={20} color={COLORS.text} />
          </Pressable>
          <Text style={s.headerTitle}>📝 Solicitudes de proveedores</Text>
          <View style={{ width: 40 }} />
        </View>

        <View style={s.tabs}>
          {([
            ['pending', 'Pendientes'],
            ['approved', 'Aprobadas'],
            ['rejected', 'Rechazadas'],
            ['all', 'Todas'],
          ] as [TabKey, string][]).map(([key, label]) => (
            <Pressable key={key} style={[s.tabBtn, tab === key && s.tabBtnActive]} onPress={() => setTab(key)}>
              <Text style={[s.tabBtnText, tab === key && s.tabBtnTextActive]}>{label}</Text>
            </Pressable>
          ))}
        </View>

        {loading ? (
          <View style={s.center}><ActivityIndicator size="large" color={COLORS.green} /></View>
        ) : items.length === 0 ? (
          <View style={s.center}>
            <Text style={{ fontSize: 40 }}>📝</Text>
            <Text style={s.emptyTitle}>Nada aquí</Text>
          </View>
        ) : (
          <ScrollView
            contentContainerStyle={{ padding: SPACING.xl, gap: 12 }}
            refreshControl={<RefreshControl refreshing={refreshing} onRefresh={onRefresh} tintColor={COLORS.green} />}
          >
            {items.map(item => (
              <View key={item.id} style={s.card}>
                <View style={s.cardHeader}>
                  <Text style={s.name} numberOfLines={1}>{item.full_name}</Text>
                  <View style={[s.statusPill, statusStyle(item.status)]}>
                    <Text style={s.statusPillText}>{statusLabel(item.status)}</Text>
                  </View>
                </View>
                <Text style={s.category}>{CATEGORY_LABELS[item.category] ?? item.category}</Text>

                <Pressable style={s.callRow} onPress={() => call(item.phone)}>
                  <Phone size={13} color={COLORS.green} />
                  <Text style={s.callText}>{item.phone}</Text>
                </Pressable>

                <View style={s.infoRow}>
                  <Briefcase size={13} color={COLORS.muted2} />
                  <Text style={s.infoText}>
                    {item.years_experience != null ? `${item.years_experience} años de trayectoria` : 'Años de trayectoria: —'}
                  </Text>
                </View>
                {item.min_hours != null && (
                  <View style={s.infoRow}>
                    <Clock size={13} color={COLORS.muted2} />
                    <Text style={s.infoText}>Mínimo {item.min_hours}h de contratación</Text>
                  </View>
                )}
                {(item.city || item.state || item.country) && (
                  <View style={s.infoRow}>
                    <MapPin size={13} color={COLORS.muted2} />
                    <Text style={s.infoText}>{[item.city, item.state, item.country].filter(Boolean).join(', ')}</Text>
                  </View>
                )}
                <View style={s.infoRow}>
                  <Calendar size={13} color={COLORS.muted2} />
                  <Text style={s.infoText}>{fecha(item.created_at)}</Text>
                </View>
                {item.notes ? <Text style={s.notes} numberOfLines={3}>"{item.notes}"</Text> : null}
                {item.status === 'rejected' && item.admin_notes ? (
                  <Text style={s.rejectReason}>Motivo: {item.admin_notes}</Text>
                ) : null}

                {item.status === 'pending' && (
                  <View style={s.actionsRow}>
                    <Pressable style={[s.actionBtn, s.rejectBtn]} onPress={() => openReject(item)}>
                      <Text style={s.rejectBtnText}>Rechazar</Text>
                    </Pressable>
                    <Pressable style={[s.actionBtn, s.approveBtn]} onPress={() => openApprove(item)}>
                      <Text style={s.approveBtnText}>Aprobar y crear cuenta</Text>
                    </Pressable>
                  </View>
                )}
              </View>
            ))}
          </ScrollView>
        )}
      </SafeAreaView>

      {/* Modal aprobar */}
      <Modal visible={!!approveTarget} transparent animationType="slide" onRequestClose={() => setApproveTarget(null)}>
        <View style={s.overlay}>
          <View style={s.sheet}>
            <Text style={s.sheetTitle}>{approveTarget?.full_name}</Text>
            <Text style={s.sheetHint}>Ya lo contactaste y viste sus fotos/videos por WhatsApp. Crea su cuenta real.</Text>

            <Text style={s.label}>Correo del proveedor</Text>
            <TextInput
              style={s.input}
              value={email}
              onChangeText={setEmail}
              placeholder="correo@ejemplo.com"
              placeholderTextColor={COLORS.muted}
              keyboardType="email-address"
              autoCapitalize="none"
            />

            <Text style={s.label}>Género exacto (ej. Banda, Mariachi, DJ)</Text>
            <TextInput
              style={s.input}
              value={genre}
              onChangeText={setGenre}
              placeholder="Ej. Banda"
              placeholderTextColor={COLORS.muted}
            />

            <Text style={s.label}>Contraseña temporal (opcional, se genera una si la dejas vacía)</Text>
            <TextInput
              style={s.input}
              value={tempPassword}
              onChangeText={setTempPassword}
              placeholder="Se genera automática si la dejas vacía"
              placeholderTextColor={COLORS.muted}
            />

            <View style={{ flexDirection: 'row', gap: 10, marginTop: 8 }}>
              <Pressable style={[s.modalBtn, s.modalBtnCancel]} onPress={() => setApproveTarget(null)}>
                <Text style={s.modalBtnCancelText}>Cancelar</Text>
              </Pressable>
              <Pressable style={[s.modalBtn, s.modalBtnSend, approving && { opacity: 0.6 }]} onPress={sendApprove} disabled={approving}>
                {approving ? <ActivityIndicator size="small" color={COLORS.bg} /> : <Text style={s.modalBtnSendText}>Crear cuenta</Text>}
              </Pressable>
            </View>
          </View>
        </View>
      </Modal>

      {/* Modal rechazar */}
      <Modal visible={!!rejectTarget} transparent animationType="slide" onRequestClose={() => setRejectTarget(null)}>
        <View style={s.overlay}>
          <View style={s.sheet}>
            <Text style={s.sheetTitle}>Rechazar a {rejectTarget?.full_name}</Text>
            <Text style={s.label}>Motivo (opcional)</Text>
            <TextInput
              style={[s.input, { height: 70, textAlignVertical: 'top' }]}
              value={rejectReason}
              onChangeText={setRejectReason}
              placeholder="Ej. no cumple calidad, no contestó..."
              placeholderTextColor={COLORS.muted}
              multiline
            />
            <View style={{ flexDirection: 'row', gap: 10, marginTop: 8 }}>
              <Pressable style={[s.modalBtn, s.modalBtnCancel]} onPress={() => setRejectTarget(null)}>
                <Text style={s.modalBtnCancelText}>Cancelar</Text>
              </Pressable>
              <Pressable style={[s.modalBtn, { backgroundColor: COLORS.red }, rejecting && { opacity: 0.6 }]} onPress={sendReject} disabled={rejecting}>
                {rejecting ? <ActivityIndicator size="small" color={COLORS.white} /> : <Text style={[s.modalBtnSendText, { color: COLORS.white }]}>Rechazar</Text>}
              </Pressable>
            </View>
          </View>
        </View>
      </Modal>
    </View>
  );
}

function statusLabel(status: string): string {
  return { pending: 'Pendiente', contacted: 'Contactado', approved: 'Aprobado', rejected: 'Rechazado' }[status] ?? status;
}
function statusStyle(status: string) {
  switch (status) {
    case 'approved': return { backgroundColor: COLORS.greenMuted };
    case 'rejected': return { backgroundColor: 'rgba(239,83,80,0.15)' };
    default: return { backgroundColor: 'rgba(255,179,0,0.15)' };
  }
}

const s = StyleSheet.create({
  container: { flex: 1, backgroundColor: COLORS.bg },
  center: { flex: 1, alignItems: 'center', justifyContent: 'center', gap: 8, padding: SPACING.xl },
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
  headerTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.text },

  tabs: { flexDirection: 'row', paddingHorizontal: SPACING.xl, paddingVertical: 10, gap: 8 },
  tabBtn: {
    flex: 1, paddingVertical: 9, borderRadius: RADIUS.md, alignItems: 'center',
    backgroundColor: COLORS.card, borderWidth: 1, borderColor: COLORS.border,
  },
  tabBtnActive: { backgroundColor: COLORS.greenMuted, borderColor: COLORS.green },
  tabBtnText: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.muted2 },
  tabBtnTextActive: { color: COLORS.green },

  emptyTitle: { fontFamily: FONTS.title, fontSize: 18, color: COLORS.text, marginTop: 4 },

  card: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border, padding: 14, gap: 6,
  },
  cardHeader: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', marginBottom: 2 },
  name: { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.text, flex: 1 },
  statusPill: { paddingHorizontal: 10, paddingVertical: 4, borderRadius: RADIUS.full },
  statusPillText: { fontFamily: FONTS.bodyMedium, fontSize: 10, color: COLORS.text },
  category: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, marginBottom: 2 },

  callRow: { flexDirection: 'row', alignItems: 'center', gap: 6 },
  callText: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.text },

  infoRow: { flexDirection: 'row', alignItems: 'flex-start', gap: 6, marginTop: 2 },
  infoText: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, flex: 1 },
  notes: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted, fontStyle: 'italic', marginTop: 2 },
  rejectReason: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.red, marginTop: 2 },

  actionsRow: { flexDirection: 'row', gap: 8, marginTop: 8 },
  actionBtn: { flex: 1, alignItems: 'center', justifyContent: 'center', paddingVertical: 11, borderRadius: RADIUS.md },
  approveBtn: { backgroundColor: COLORS.green },
  approveBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.bg },
  rejectBtn: { backgroundColor: COLORS.card2, borderWidth: 1, borderColor: COLORS.border },
  rejectBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.red },

  overlay: { flex: 1, backgroundColor: 'rgba(0,0,0,0.5)', justifyContent: 'flex-end' },
  sheet: {
    backgroundColor: COLORS.card, borderTopLeftRadius: 24, borderTopRightRadius: 24,
    padding: SPACING.xl, paddingBottom: 40,
  },
  sheetTitle: { fontFamily: FONTS.title, fontSize: 18, color: COLORS.text, marginBottom: 6 },
  sheetHint: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, marginBottom: 16, lineHeight: 17 },
  label: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted2, marginBottom: 6 },
  input: {
    backgroundColor: COLORS.bg, borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: COLORS.border,
    paddingHorizontal: 14, paddingVertical: 12,
    fontFamily: FONTS.body, fontSize: 15, color: COLORS.text, marginBottom: 14,
  },
  modalBtn: { flex: 1, alignItems: 'center', justifyContent: 'center', paddingVertical: 13, borderRadius: RADIUS.md },
  modalBtnCancel: { backgroundColor: COLORS.card2, borderWidth: 1, borderColor: COLORS.border },
  modalBtnCancelText: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.muted2 },
  modalBtnSend: { backgroundColor: COLORS.green },
  modalBtnSendText: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.bg },
});
