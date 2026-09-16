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
import { ArrowLeft, Briefcase, Calendar, Clock, MapPin, Phone, Plus, FileDown } from 'lucide-react-native';
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
import { useAuth } from '../../context/AuthContext';
import { PROVIDER_CATEGORIES } from '../../constants/providerCategories';
import { STATES_BY_COUNTRY } from '../../utils/locationUtils';
import { exportProviderAgreementPdf } from '../../utils/exportProviderAgreementPdf';

// admin_country_scope ('MX'/'US'/'CA') → nombre de país tal cual se guarda
// en groups/provider_applications. Solo para preseleccionar y limitar las
// opciones en pantalla — el RPC ya rechaza del lado del servidor cualquier
// intento de un admin_ops de dar de alta fuera de su país (sql/649/653).
const SCOPE_TO_COUNTRY: Record<string, string> = { MX: 'México', US: 'Estados Unidos', CA: 'Canadá' };

const call = (phone?: string | null) => { if (phone) Linking.openURL(`tel:${phone}`); };
const fecha = (d?: string | null) =>
  d ? new Date(d).toLocaleDateString('es-MX', { day: '2-digit', month: 'short', year: '2-digit' }) : '—';

const CATEGORY_LABELS: Record<string, string> = {
  grupo: 'Grupo musical', solista: 'Solista', dj: 'DJ', comediante: 'Comediante',
  espectaculo: 'Show', mc: 'Maestro de Ceremonias', luzSonido: 'Luz y sonido',
  comida: 'Comida', renta: 'Renta de mobiliario', fotografos: 'Fotografía/Video',
};

const APPLY_COUNTRIES = ['México', 'Estados Unidos', 'Canadá'];

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
  const { profile } = useAuth();
  // Un admin_ops (ej. cuenta de tu novia, alcance EE.UU.) solo puede dar de
  // alta proveedores de su propio país — aquí nomás se le oculta la opción
  // para que no se equivoque, el RPC ya lo bloquea de todos modos.
  const scopedCountry = profile?.role === 'admin_ops' ? SCOPE_TO_COUNTRY[profile.admin_country_scope ?? ''] : null;
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

  // Alta directa: tú ya llamaste al proveedor y tienes sus datos — esto
  // manda la misma solicitud que llenaría él en ProviderApplyScreen (aquí
  // no aparece en tu navegación porque es pantalla pública sin sesión), y
  // en cuanto se crea, abre de una vez el modal de "Aprobar" de arriba para
  // que en un solo flujo quede la cuenta+grupo listos.
  const [addModal, setAddModal] = useState(false);
  const [addName, setAddName] = useState('');
  const [addPhone, setAddPhone] = useState('');
  const [addCategory, setAddCategory] = useState<string | null>(null);
  const [addYears, setAddYears] = useState('');
  const [addMinHours, setAddMinHours] = useState('');
  const [addCountry, setAddCountry] = useState('México');
  const [addState, setAddState] = useState('');
  const [addCity, setAddCity] = useState('');
  const [addNotes, setAddNotes] = useState('');
  const [adding, setAdding] = useState(false);
  const [downloadingAgreement, setDownloadingAgreement] = useState(false);

  const handleDownloadAgreement = async () => {
    if (downloadingAgreement) return;
    setDownloadingAgreement(true);
    try {
      await exportProviderAgreementPdf();
    } catch (e: any) {
      Alert.alert('No se pudo generar', e?.message ?? 'Intenta de nuevo.');
    } finally {
      setDownloadingAgreement(false);
    }
  };

  const openAdd = () => {
    setAddModal(true);
    setAddName(''); setAddPhone(''); setAddCategory(null);
    setAddYears(''); setAddMinHours('');
    setAddCountry(scopedCountry ?? 'México'); setAddState(''); setAddCity(''); setAddNotes('');
  };

  const sendAdd = async () => {
    if (!addName.trim() || addPhone.trim().length < 7 || !addCategory) {
      Alert.alert('Faltan datos', 'Escribe el nombre, teléfono y elige la categoría.');
      return;
    }
    setAdding(true);
    const { data, error } = await supabase.rpc('submit_provider_application', {
      p_full_name: addName.trim(),
      p_phone: addPhone.trim(),
      p_category: addCategory,
      p_years_experience: addYears ? parseInt(addYears, 10) : null,
      p_min_hours: addMinHours ? parseFloat(addMinHours) : null,
      p_country: addCountry,
      p_state: addState.trim() || null,
      p_city: addCity.trim() || null,
      p_notes: addNotes.trim() || null,
    });
    setAdding(false);
    if (error || !data?.ok) {
      Alert.alert('Error', error?.message ?? data?.error ?? 'No se pudo crear la solicitud.');
      return;
    }
    setAddModal(false);
    // Encadena directo al modal de aprobar — no hace falta ir a buscarla
    // en la pestaña "Pendientes".
    openApprove({
      id: data.application_id,
      full_name: addName.trim(),
      phone: addPhone.trim(),
      category: addCategory,
      years_experience: addYears ? parseInt(addYears, 10) : null,
      min_hours: addMinHours ? parseFloat(addMinHours) : null,
      country: addCountry,
      state: addState.trim() || null,
      city: addCity.trim() || null,
      notes: addNotes.trim() || null,
      status: 'pending',
      admin_notes: null,
      linked_group_id: null,
      created_at: new Date().toISOString(),
    });
  };

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
    // Si su categoría solo tiene un género posible (DJ, Comida, MC,
    // Comediante), se preselecciona — si tiene varios (grupo musical,
    // show, luz y sonido, renta, fotógrafos), el admin elige de la lista
    // real de abajo, nunca escribe a mano (evita que un typo lo deje
    // invisible en esa categoría del Explorador).
    const opts = PROVIDER_CATEGORIES.find(c => c.key === item.category)?.genres ?? [];
    setGenre(opts.length === 1 ? opts[0] : '');
    setTempPassword('');
  };

  const sendApprove = async () => {
    if (!approveTarget) return;
    if (!email.trim() || !genre.trim()) {
      Alert.alert('Faltan datos', 'Escribe el correo y elige el género exacto del grupo.');
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
          <View style={{ flexDirection: 'row', gap: 8 }}>
            <Pressable style={s.backBtn} onPress={handleDownloadAgreement} disabled={downloadingAgreement}>
              {downloadingAgreement
                ? <ActivityIndicator size="small" color={COLORS.green} />
                : <FileDown size={20} color={COLORS.green} />}
            </Pressable>
            <Pressable style={s.backBtn} onPress={openAdd}>
              <Plus size={20} color={COLORS.green} />
            </Pressable>
          </View>
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

            <Text style={s.label}>Género exacto — de esto depende que aparezca en su categoría del Explorador</Text>
            <View style={s.genreGrid}>
              {(PROVIDER_CATEGORIES.find(c => c.key === approveTarget?.category)?.genres ?? []).map(g => (
                <Pressable key={g} style={[s.genreChip, genre === g && s.genreChipActive]} onPress={() => setGenre(g)}>
                  <Text style={[s.genreChipText, genre === g && s.genreChipTextActive]}>{g}</Text>
                </Pressable>
              ))}
            </View>

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

      {/* Modal agregar directo — tú ya hablaste con el proveedor por teléfono */}
      <Modal visible={addModal} transparent animationType="slide" onRequestClose={() => setAddModal(false)}>
        <View style={s.overlay}>
          <ScrollView style={[s.sheet, { maxHeight: '85%' }]} contentContainerStyle={{ paddingBottom: 40 }}>
            <Text style={s.sheetTitle}>Agregar proveedor</Text>
            <Text style={s.sheetHint}>Para uno que ya contactaste tú mismo por teléfono. Al enviar, sigue directo al paso de crear su cuenta.</Text>

            <Text style={s.label}>Nombre o nombre del grupo</Text>
            <TextInput style={s.input} value={addName} onChangeText={setAddName} placeholder="Ej. Banda Los Ejemplares" placeholderTextColor={COLORS.muted} />

            <Text style={s.label}>Teléfono (WhatsApp)</Text>
            <TextInput style={s.input} value={addPhone} onChangeText={setAddPhone} placeholder="Ej. 33 1234 5678" placeholderTextColor={COLORS.muted} keyboardType="phone-pad" />

            <Text style={s.label}>Categoría</Text>
            <View style={s.genreGrid}>
              {PROVIDER_CATEGORIES.map(cat => (
                <Pressable key={cat.key} style={[s.genreChip, addCategory === cat.key && s.genreChipActive]} onPress={() => setAddCategory(cat.key)}>
                  <Text style={[s.genreChipText, addCategory === cat.key && s.genreChipTextActive]}>
                    {cat.emoji} {CATEGORY_LABELS[cat.key] ?? cat.key}
                  </Text>
                </Pressable>
              ))}
            </View>

            <View style={{ flexDirection: 'row', gap: 12 }}>
              <View style={{ flex: 1 }}>
                <Text style={s.label}>Años de trayectoria</Text>
                <TextInput style={s.input} value={addYears} onChangeText={t => setAddYears(t.replace(/[^0-9]/g, ''))} placeholder="Ej. 5" placeholderTextColor={COLORS.muted} keyboardType="numeric" />
              </View>
              <View style={{ flex: 1 }}>
                <Text style={s.label}>Horas mínimas</Text>
                <TextInput style={s.input} value={addMinHours} onChangeText={t => setAddMinHours(t.replace(/[^0-9.]/g, ''))} placeholder="Ej. 3" placeholderTextColor={COLORS.muted} keyboardType="numeric" />
              </View>
            </View>

            <Text style={s.label}>País{scopedCountry ? ` — tu cuenta solo da de alta en ${scopedCountry}` : ''}</Text>
            <View style={s.genreGrid}>
              {(scopedCountry ? [scopedCountry] : APPLY_COUNTRIES).map(c => (
                <Pressable key={c} style={[s.genreChip, addCountry === c && s.genreChipActive]} onPress={() => { setAddCountry(c); setAddState(''); }}>
                  <Text style={[s.genreChipText, addCountry === c && s.genreChipTextActive]}>{c}</Text>
                </Pressable>
              ))}
            </View>

            {/* Estado por botones, no texto libre — un typo aquí rompe filtros
                que comparan el estado exacto (recomendados, patrocinados). */}
            <Text style={s.label}>Estado</Text>
            <View style={s.genreGrid}>
              {(STATES_BY_COUNTRY[addCountry] ?? []).map(st => (
                <Pressable key={st} style={[s.genreChip, addState === st && s.genreChipActive]} onPress={() => setAddState(st)}>
                  <Text style={[s.genreChipText, addState === st && s.genreChipTextActive]}>{st}</Text>
                </Pressable>
              ))}
            </View>

            <View style={{ flexDirection: 'row', gap: 12 }}>
              <View style={{ flex: 1 }}>
                <Text style={s.label}>Ciudad</Text>
                <TextInput style={s.input} value={addCity} onChangeText={setAddCity} placeholder="Ej. Zapopan" placeholderTextColor={COLORS.muted} />
              </View>
            </View>

            <Text style={s.label}>Notas (opcional)</Text>
            <TextInput
              style={[s.input, { height: 70, textAlignVertical: 'top' }]}
              value={addNotes}
              onChangeText={setAddNotes}
              placeholder="Ej. tocan en bodas, tienen equipo propio..."
              placeholderTextColor={COLORS.muted}
              multiline
            />

            <View style={{ flexDirection: 'row', gap: 10, marginTop: 8 }}>
              <Pressable style={[s.modalBtn, s.modalBtnCancel]} onPress={() => setAddModal(false)}>
                <Text style={s.modalBtnCancelText}>Cancelar</Text>
              </Pressable>
              <Pressable style={[s.modalBtn, s.modalBtnSend, adding && { opacity: 0.6 }]} onPress={sendAdd} disabled={adding}>
                {adding ? <ActivityIndicator size="small" color={COLORS.bg} /> : <Text style={s.modalBtnSendText}>Siguiente</Text>}
              </Pressable>
            </View>
          </ScrollView>
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
  genreGrid: { flexDirection: 'row', flexWrap: 'wrap', gap: 8, marginBottom: 14 },
  genreChip: {
    paddingHorizontal: 12, paddingVertical: 8, borderRadius: RADIUS.full,
    backgroundColor: COLORS.bg, borderWidth: 1, borderColor: COLORS.border,
  },
  genreChipActive: { backgroundColor: COLORS.green, borderColor: COLORS.green },
  genreChipText: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.muted2 },
  genreChipTextActive: { color: COLORS.bg },
  modalBtn: { flex: 1, alignItems: 'center', justifyContent: 'center', paddingVertical: 13, borderRadius: RADIUS.md },
  modalBtnCancel: { backgroundColor: COLORS.card2, borderWidth: 1, borderColor: COLORS.border },
  modalBtnCancelText: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.muted2 },
  modalBtnSend: { backgroundColor: COLORS.green },
  modalBtnSendText: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.bg },
});
