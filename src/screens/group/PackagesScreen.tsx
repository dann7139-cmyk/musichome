import { ArrowLeft, Clock, DollarSign, Edit2, Plus, Trash2, Users } from 'lucide-react-native';
import React, { useEffect, useMemo, useState } from 'react';
import {
  ActivityIndicator,
  Alert,
  Image,
  Keyboard,
  KeyboardAvoidingView,
  Modal,
  Platform,
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
import { PLATFORM_FEE_RATE } from '../../utils/calculations';
import Button from '../../components/ui/Button';
import Input from '../../components/ui/Input';
import Particles from '../../components/ui/Particles';

interface DistMember {
  user_id: string;
  full_name: string;
  isOwner: boolean;
  avatar_url?: string;
  role?: string;
}

export default function GroupPackagesScreen({ navigation }: any) {
  const [packages, setPackages] = useState<any[]>([]);
  const [groupId, setGroupId] = useState<string | null>(null);
  const [showModal, setShowModal] = useState(false);
  const [editPkg, setEditPkg] = useState<any>(null);
  const [form, setForm] = useState({ name: '', description: '', price: '', duration_hours: '3', extra_hour_price: '' });
  const [loading, setLoading] = useState(false);
  const [refreshing, setRefreshing] = useState(false);

  // Distribution modal
  const [showDistModal, setShowDistModal]   = useState(false);
  const [distPkg, setDistPkg]               = useState<any>(null);
  const [distMembers, setDistMembers]       = useState<DistMember[]>([]);
  const [distAmounts, setDistAmounts]       = useState<Record<string, string>>({});
  const [distLoading, setDistLoading]       = useState(false);

  // Budget restante mientras el usuario escribe
  // Nuevo modelo: $200 fijos por hora contratada
  const commissionAmount = (distPkg?.duration_hours ?? 0) * 200;
  const totalAllocated = useMemo(
    () => distMembers.reduce((sum, m) => sum + (parseFloat(distAmounts[m.user_id] || '0') || 0), 0),
    [distMembers, distAmounts]
  );
  const netForMembers = (distPkg?.price ?? 0) - commissionAmount;
  const budgetRemaining = netForMembers - totalAllocated;

  useEffect(() => { fetchPackages(); }, []);

  const openDist = async (pkg: any) => {
    setDistPkg(pkg);
    setDistLoading(true);
    setShowDistModal(true);

    const { data: sd } = await supabase.auth.getSession();
    const uid = sd.session?.user.id;

    const [ownerRes, jobBoardRes, membersRes, existingRes] = await Promise.all([
      supabase.from('profiles').select('id, full_name, avatar_url').eq('id', uid!).maybeSingle(),
      supabase.from('job_board_profiles').select('instrument_or_role').eq('user_id', uid!).maybeSingle(),
      supabase
        .from('job_invitations')
        .select('invited_user_id, profile:profiles!job_invitations_invited_user_id_fkey(full_name, avatar_url)')
        .eq('group_id', groupId!)
        .eq('status', 'accepted')
        .is('event_id', null),
      supabase
        .from('package_member_distribution')
        .select('user_id, amount')
        .eq('package_id', pkg.id),
    ]);

    const members: DistMember[] = [
      {
        user_id: uid!,
        full_name: ownerRes.data?.full_name ?? 'Dueño',
        isOwner: true,
        avatar_url: ownerRes.data?.avatar_url ?? undefined,
        role: jobBoardRes.data?.instrument_or_role ?? undefined,
      },
      ...((membersRes.data ?? []) as any[]).map((inv: any) => ({
        user_id: inv.invited_user_id,
        full_name: inv.profile?.full_name ?? 'Integrante',
        isOwner: false,
        avatar_url: inv.profile?.avatar_url ?? undefined,
      })),
    ];
    setDistMembers(members);

    const amounts: Record<string, string> = {};
    (existingRes.data ?? []).forEach((d: any) => { amounts[d.user_id] = String(d.amount); });
    setDistAmounts(amounts);

    setDistLoading(false);
  };

  const handleSaveDist = async () => {
    if (budgetRemaining < 0) {
      Alert.alert('Error', `La distribución excede la ganancia neta del grupo ($${netForMembers.toLocaleString()})`);
      return;
    }
    setDistLoading(true);

    const rows = distMembers
      .filter(m => parseFloat(distAmounts[m.user_id] || '0') > 0)
      .map(m => ({ user_id: m.user_id, amount: parseFloat(distAmounts[m.user_id] || '0') }));

    const { data, error } = await supabase.rpc('upsert_package_distribution', {
      p_package_id: distPkg.id,
      p_rows: rows,
    });

    setDistLoading(false);

    if (error || (data as any)?.error) {
      Alert.alert('Error', (data as any)?.error ?? error?.message);
      return;
    }

    setShowDistModal(false);
    Alert.alert('✓ Listo', 'Distribución guardada correctamente.');
  };

  const onRefresh = async () => { setRefreshing(true); await fetchPackages(); setRefreshing(false); };

  const fetchPackages = async () => {
    try {
      const { data: grpRaw } = await supabase.rpc('get_my_group').maybeSingle();
      if (!grpRaw) return;
      const grp = grpRaw as { id: string };
      setGroupId(grp.id);
      const { data } = await supabase
        .from('packages')
        .select('*')
        .eq('group_id', grp.id);
      if (data) setPackages(data);
    } catch (e) {
      console.error('Error fetching packages:', e);
    }
  };

  const openCreate = () => {
    setEditPkg(null);
    setForm({ name: '', description: '', price: '', duration_hours: '3', extra_hour_price: '' });
    setShowModal(true);
  };

  const openEdit = (pkg: any) => {
    setEditPkg(pkg);
    setForm({
      name: pkg.name ?? '',
      description: pkg.description ?? '',
      price: String(pkg.price ?? ''),
      duration_hours: String(pkg.duration_hours ?? 3),
      extra_hour_price: pkg.extra_hour_price != null ? String(pkg.extra_hour_price) : '',
    });
    setShowModal(true);
  };

  const handleSave = async () => {
    if (!form.name || !form.price) {
      Alert.alert('Error', 'Nombre y precio son requeridos');
      return;
    }
    const hours = parseFloat(form.duration_hours);
    if (hours < 3) {
      Alert.alert('Error', 'Los paquetes deben tener mínimo 3 horas');
      return;
    }
    setLoading(true);
    const payload = {
      group_id: groupId,
      name: form.name,
      description: form.description,
      price: parseFloat(form.price),
      duration_hours: hours,
      extra_hour_price: form.extra_hour_price ? parseFloat(form.extra_hour_price) : null,
      is_active: true,
    };

    if (editPkg) {
      await supabase.from('packages').update(payload).eq('id', editPkg.id);
    } else {
      await supabase.from('packages').insert([payload]);
    }
    setLoading(false);
    setShowModal(false);
    fetchPackages();
  };

  const handleDelete = (pkg: any) => {
    Alert.alert('Eliminar paquete', `¿Eliminar "${pkg.name}"?`, [
      { text: 'Cancelar', style: 'cancel' },
      {
        text: 'Eliminar',
        style: 'destructive',
        onPress: async () => {
          await supabase.from('packages').update({ is_active: false }).eq('id', pkg.id);
          fetchPackages();
        },
      },
    ]);
  };

  return (
    <View style={styles.container}>
      <Particles />
      <SafeAreaView style={{ flex: 1 }}>
        <View style={styles.header}>
          <Pressable style={styles.backBtn} onPress={() => navigation.goBack()}>
            <ArrowLeft size={20} color={COLORS.text} />
          </Pressable>
          <Text style={styles.headerTitle}>Mis Paquetes</Text>
          <Pressable style={styles.addBtn} onPress={openCreate}>
            <Plus size={20} color={COLORS.green} />
          </Pressable>
        </View>

        <ScrollView showsVerticalScrollIndicator={false} contentContainerStyle={styles.list} refreshControl={<RefreshControl refreshing={refreshing} onRefresh={onRefresh} tintColor={COLORS.green} />}>
          {packages.length === 0 ? (
            <View style={styles.empty}>
              <Text style={styles.emptyIcon}>📦</Text>
              <Text style={styles.emptyTitle}>Sin paquetes</Text>
              <Text style={styles.emptyText}>Crea tu primer paquete para que los clientes puedan contratarte</Text>
              <View style={{ marginTop: 16, width: '100%' }}>
                <Button label="+ Crear paquete" onPress={openCreate} />
              </View>
            </View>
          ) : (
            packages.map(pkg => (
              <View key={pkg.id} style={styles.pkgCard}>
                <View style={styles.pkgHeader}>
                  <View style={styles.pkgInfo}>
                    <Text style={styles.pkgName}>{pkg.name}</Text>
                    <View style={styles.pkgMeta}>
                      <Clock size={13} color={COLORS.muted2} />
                      <Text style={styles.pkgMetaText}>{pkg.duration_hours}h</Text>
                      {pkg.members_count && (
                        <>
                          <Users size={13} color={COLORS.muted2} />
                          <Text style={styles.pkgMetaText}>{pkg.members_count} int.</Text>
                        </>
                      )}
                    </View>
                  </View>
                  <View style={{ alignItems: 'flex-end' }}>
                    <Text style={styles.pkgPrice}>${pkg.price?.toLocaleString()}</Text>
                    <Text style={styles.pkgClientPrice}>
                      Cliente paga ~${Math.round((pkg.price ?? 0) * (1 + PLATFORM_FEE_RATE)).toLocaleString()}
                    </Text>
                  </View>
                </View>
                {pkg.description && <Text style={styles.pkgDesc}>{pkg.description}</Text>}
                {pkg.extra_hour_price != null && (
                  <View style={{ flexDirection: 'row', alignItems: 'center', gap: 6, marginBottom: 8 }}>
                    <Clock size={12} color={COLORS.gold} />
                    <Text style={{ fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.gold }}>
                      Hora extra: ${pkg.extra_hour_price.toLocaleString()}/hr
                    </Text>
                  </View>
                )}
                <View style={styles.pkgActions}>
                  <Pressable style={styles.editBtn} onPress={() => openEdit(pkg)}>
                    <Edit2 size={14} color={COLORS.green} />
                    <Text style={styles.editText}>Editar</Text>
                  </Pressable>
                  <Pressable style={styles.distBtn} onPress={() => openDist(pkg)}>
                    <DollarSign size={14} color={COLORS.gold} />
                    <Text style={styles.distBtnText}>Distribución</Text>
                  </Pressable>
                  <Pressable style={styles.deleteBtn} onPress={() => handleDelete(pkg)}>
                    <Trash2 size={14} color={COLORS.red} />
                    <Text style={styles.deleteText}>Eliminar</Text>
                  </Pressable>
                </View>
              </View>
            ))
          )}
        </ScrollView>

        {/* ── MODAL: DISTRIBUCIÓN ── */}
        <Modal visible={showDistModal} transparent animationType="slide">
          <KeyboardAvoidingView
            behavior={Platform.OS === 'ios' ? 'padding' : 'height'}
            style={{ flex: 1 }}
          >
            <Pressable style={styles.modalOverlay} onPress={Keyboard.dismiss}>
            <Pressable style={styles.modal} onPress={e => e.stopPropagation()}>
              <Text style={styles.modalTitle}>Distribución: {distPkg?.name}</Text>

              {/* Comisión Daricefy */}
              <View style={styles.commissionRow}>
                <View>
                  <Text style={styles.commissionLabel}>Comisión Daricefy</Text>
                  <Text style={styles.commissionSub}>{distPkg?.duration_hours}h × $200/h</Text>
                </View>
                <Text style={styles.commissionAmount}>−${commissionAmount.toLocaleString()}</Text>
              </View>

              {/* Budget tracker */}
              <View style={styles.budgetRow}>
                <Text style={styles.budgetLabel}>
                  Para distribuir: ${netForMembers.toLocaleString()}
                </Text>
                <Text style={[
                  styles.budgetRemaining,
                  { color: budgetRemaining < 0 ? COLORS.red : COLORS.green },
                ]}>
                  Restante: ${budgetRemaining.toLocaleString()}
                </Text>
              </View>

              {distLoading ? (
                <ActivityIndicator color={COLORS.green} style={{ marginVertical: 30 }} />
              ) : (
                <ScrollView showsVerticalScrollIndicator={false}>
                  {distMembers.map(m => (
                    <View key={m.user_id} style={styles.distRow}>
                      {m.avatar_url ? (
                        <Image source={{ uri: m.avatar_url }} style={styles.distAvatarImg} />
                      ) : (
                        <View style={styles.distAvatar}>
                          <Text style={styles.distAvatarText}>
                            {m.full_name?.charAt(0)?.toUpperCase() ?? '?'}
                          </Text>
                        </View>
                      )}
                      <View style={{ flex: 1 }}>
                        <Text style={styles.distName} numberOfLines={1}>{m.full_name}</Text>
                        <Text style={styles.distRole}>
                          {m.isOwner
                            ? (m.role ? `👑 ${m.role}` : '👑 Admin del grupo')
                            : '🎸 Integrante'}
                        </Text>
                      </View>
                      <View style={styles.distInputWrap}>
                        <Text style={styles.distCurrency}>$</Text>
                        <TextInput
                          style={styles.distInput}
                          value={distAmounts[m.user_id] ?? ''}
                          onChangeText={v => setDistAmounts(prev => ({ ...prev, [m.user_id]: v }))}
                          keyboardType="numeric"
                          returnKeyType="done"
                          onSubmitEditing={Keyboard.dismiss}
                          placeholder="0"
                          placeholderTextColor={COLORS.muted}
                        />
                      </View>
                    </View>
                  ))}

                  {distMembers.length === 0 && (
                    <Text style={styles.distEmpty}>
                      No hay integrantes en el grupo aún.
                    </Text>
                  )}

                  <View style={{ gap: 10, marginTop: 20 }}>
                    <Button
                      label="Guardar distribución"
                      onPress={handleSaveDist}
                      loading={distLoading}
                    />
                    <Button
                      label="Cancelar"
                      onPress={() => setShowDistModal(false)}
                      variant="ghost"
                    />
                  </View>
                </ScrollView>
              )}
            </Pressable>
            </Pressable>
          </KeyboardAvoidingView>
        </Modal>

        {/* MODAL */}
        <Modal visible={showModal} transparent animationType="slide">
          <View style={styles.modalOverlay}>
            <View style={styles.modal}>
              <Text style={styles.modalTitle}>{editPkg ? 'Editar paquete' : 'Nuevo paquete'}</Text>
              <ScrollView showsVerticalScrollIndicator={false}>
                <Input label="Nombre del paquete" placeholder="Paquete Premium" value={form.name} onChangeText={v => setForm(f => ({ ...f, name: v }))} />
                <Input label="Descripción" placeholder="Qué incluye el paquete..." value={form.description} onChangeText={v => setForm(f => ({ ...f, description: v }))} multiline numberOfLines={3} />
                <Input label="Precio ($)" placeholder="5000" value={form.price} onChangeText={v => setForm(f => ({ ...f, price: v }))} keyboardType="numeric" />
                <Input label="Duración (horas, mín. 3)" placeholder="4" value={form.duration_hours} onChangeText={v => setForm(f => ({ ...f, duration_hours: v }))} keyboardType="numeric" />
                <Input label="Precio hora extra ($)" placeholder="800 (opcional)" value={form.extra_hour_price} onChangeText={v => setForm(f => ({ ...f, extra_hour_price: v }))} keyboardType="numeric" />

                <View style={{ gap: 10 }}>
                  <Button label="Guardar paquete" onPress={handleSave} loading={loading} />
                  <Button label="Cancelar" onPress={() => setShowModal(false)} variant="ghost" />
                </View>
              </ScrollView>
            </View>
          </View>
        </Modal>
      </SafeAreaView>
    </View>
  );
}

const styles = StyleSheet.create({
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
  addBtn: {
    width: 40, height: 40, borderRadius: 12,
    backgroundColor: COLORS.greenMuted, borderWidth: 1, borderColor: COLORS.green,
    alignItems: 'center', justifyContent: 'center',
  },
  list: { padding: SPACING.xl, gap: 14 },
  pkgCard: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border, padding: SPACING.lg,
  },
  pkgHeader: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'flex-start', marginBottom: 8 },
  pkgInfo: { flex: 1 },
  pkgName: { fontFamily: FONTS.bodySemiBold, fontSize: 17, color: COLORS.text, marginBottom: 5 },
  pkgMeta: { flexDirection: 'row', alignItems: 'center', gap: 6 },
  pkgMetaText: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2 },
  pkgPrice:       { fontFamily: FONTS.title, fontSize: 22, color: COLORS.green },
  pkgClientPrice: { fontFamily: FONTS.body, fontSize: 10, color: COLORS.muted, marginTop: 1 },
  pkgDesc: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2, marginBottom: 12, lineHeight: 20 },
  pkgActions: { flexDirection: 'row', gap: 12, paddingTop: 12, borderTopWidth: 1, borderTopColor: COLORS.border },
  editBtn: { flexDirection: 'row', alignItems: 'center', gap: 5, padding: 6 },
  editText: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.green },
  deleteBtn: { flexDirection: 'row', alignItems: 'center', gap: 5, padding: 6 },
  deleteText: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.red },
  empty: { alignItems: 'center', paddingTop: 60 },
  emptyIcon: { fontSize: 48, marginBottom: 16 },
  emptyTitle: { fontFamily: FONTS.title, fontSize: 20, color: COLORS.text, marginBottom: 8 },
  emptyText: { fontFamily: FONTS.body, fontSize: 14, color: COLORS.muted2, textAlign: 'center' },
  modalOverlay: { flex: 1, backgroundColor: COLORS.overlay, justifyContent: 'flex-end' },
  modal: {
    backgroundColor: COLORS.card2, borderTopLeftRadius: 24, borderTopRightRadius: 24,
    padding: SPACING.xl, maxHeight: '90%',
  },
  modalTitle: { fontFamily: FONTS.title, fontSize: 20, color: COLORS.text, marginBottom: 20 },
  // ── Distribution modal ────────────────────────────────────────────────────
  distBtn:     { flexDirection: 'row', alignItems: 'center', gap: 5, padding: 6 },
  distBtnText: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.gold },

  commissionRow: {
    flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center',
    backgroundColor: '#1a1200', borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: '#3d2e00',
    paddingHorizontal: 14, paddingVertical: 10, marginBottom: 10,
  },
  commissionLabel: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.gold },
  commissionSub:   { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted2, marginTop: 2 },
  commissionAmount: { fontFamily: FONTS.title, fontSize: 15, color: COLORS.gold },

  budgetRow: {
    flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center',
    backgroundColor: COLORS.bg, borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: COLORS.border,
    paddingHorizontal: 14, paddingVertical: 10, marginBottom: 16,
  },
  budgetLabel:     { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted2 },
  budgetRemaining: { fontFamily: FONTS.title, fontSize: 15 },

  distRow: {
    flexDirection: 'row', alignItems: 'center', gap: 12,
    paddingVertical: 12, borderBottomWidth: 1, borderBottomColor: COLORS.border,
  },
  distAvatar: {
    width: 40, height: 40, borderRadius: 20,
    backgroundColor: COLORS.greenMuted, borderWidth: 1, borderColor: COLORS.green,
    alignItems: 'center', justifyContent: 'center',
  },
  distAvatarImg: {
    width: 40, height: 40, borderRadius: 20,
    borderWidth: 1, borderColor: COLORS.border,
  },
  distAvatarText: { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.green },
  distName:       { fontFamily: FONTS.bodyMedium, fontSize: 14, color: COLORS.text },
  distRole:       { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted2, marginTop: 2 },
  distInputWrap: {
    flexDirection: 'row', alignItems: 'center',
    backgroundColor: COLORS.bg, borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: COLORS.border,
    paddingHorizontal: 10, paddingVertical: 8, minWidth: 90,
  },
  distCurrency: { fontFamily: FONTS.bodyMedium, fontSize: 14, color: COLORS.muted2, marginRight: 4 },
  distInput: {
    fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.text,
    minWidth: 60, textAlign: 'right',
  },
  distEmpty: {
    fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted,
    textAlign: 'center', paddingVertical: 24,
  },
});
