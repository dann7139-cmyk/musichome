/**
 * AdminVerificationsScreen — Panel de verificación KYC para administradores.
 *
 * Tabs:
 *   0 · Grupos   — verification_requests con evidencia KYC (doc + selfie)
 *   1 · Clientes — profiles role='client' pending/aprobados/rechazados
 *   2 · Talentos — profiles role='talent' pending/aprobados/rechazados
 *
 * Funcionalidades:
 *   · Búsqueda por nombre en cada tab
 *   · Filtro por país y estado (pills horizontales)
 *   · Ver documento y foto con signed URL
 *   · Teléfono del responsable visible
 *   · Ver info para TODOS los estados (pending, approved, rejected)
 */
import { ArrowLeft, CheckCircle, FileText, Globe, MapPin, Phone, Search, Shield, ShieldCheck, User, X, XCircle } from 'lucide-react-native';
import React, { useEffect, useMemo, useState } from 'react';
import {
  Alert,
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
import Badge from '../../components/ui/Badge';
import Particles from '../../components/ui/Particles';

// ─── Geo Filter Component ─────────────────────────────────────────────────────

function GeoFilter({
  data,
  countryKey,
  stateKey,
  activeCountry,
  activeState,
  onSelect,
}: {
  data: any[];
  countryKey: string;
  stateKey: string;
  activeCountry: string | null;
  activeState: string | null;
  onSelect: (country: string | null, state: string | null) => void;
}) {
  const { t } = useTranslation();
  const countries = useMemo(() => {
    const s = new Set<string>();
    data.forEach(d => { if (d[countryKey]) s.add(d[countryKey]); });
    return Array.from(s).sort();
  }, [data, countryKey]);

  const states = useMemo(() => {
    if (!activeCountry) return [];
    const s = new Set<string>();
    data.forEach(d => {
      if (d[countryKey] === activeCountry && d[stateKey]) s.add(d[stateKey]);
    });
    return Array.from(s).sort();
  }, [data, countryKey, stateKey, activeCountry]);

  if (countries.length === 0) return null;

  const pickCountry = (c: string) => {
    const next = activeCountry === c ? null : c;
    onSelect(next, null);
  };
  const pickState = (s: string) => {
    const next = activeState === s ? null : s;
    onSelect(activeCountry, next);
  };

  return (
    <View style={geoSt.wrap}>
      {/* Countries */}
      <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={geoSt.row}>
        <Pressable style={[geoSt.pill, !activeCountry && geoSt.pillActive]} onPress={() => onSelect(null, null)}>
          <Globe size={11} color={!activeCountry ? COLORS.bg : COLORS.muted2} />
          <Text style={[geoSt.pillTxt, !activeCountry && geoSt.pillTxtActive]}>{t('adminVerificationsScreen.geoFilter.all')}</Text>
        </Pressable>
        {countries.map(c => (
          <Pressable key={c} style={[geoSt.pill, activeCountry === c && geoSt.pillActive]} onPress={() => pickCountry(c)}>
            <Text style={[geoSt.pillTxt, activeCountry === c && geoSt.pillTxtActive]}>{c}</Text>
          </Pressable>
        ))}
      </ScrollView>

      {/* States — solo cuando hay país seleccionado */}
      {activeCountry && states.length > 0 && (
        <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={geoSt.row}>
          <Pressable style={[geoSt.pill, geoSt.pillSm, !activeState && geoSt.pillStatActive]} onPress={() => onSelect(activeCountry, null)}>
            <Text style={[geoSt.pillTxt, geoSt.pillTxtSm, !activeState && geoSt.pillTxtActive]}>{t('adminVerificationsScreen.geoFilter.allStates')}</Text>
          </Pressable>
          {states.map(st => (
            <Pressable key={st} style={[geoSt.pill, geoSt.pillSm, activeState === st && geoSt.pillStatActive]} onPress={() => pickState(st)}>
              <MapPin size={10} color={activeState === st ? COLORS.bg : COLORS.muted2} />
              <Text style={[geoSt.pillTxt, geoSt.pillTxtSm, activeState === st && geoSt.pillTxtActive]}>{st}</Text>
            </Pressable>
          ))}
        </ScrollView>
      )}
    </View>
  );
}

const geoSt = StyleSheet.create({
  wrap: { paddingBottom: 4 },
  row:  { gap: 6, paddingHorizontal: SPACING.xl, paddingVertical: 6 },
  pill: {
    flexDirection: 'row', alignItems: 'center', gap: 5,
    backgroundColor: COLORS.card2, borderRadius: RADIUS.full,
    borderWidth: 1, borderColor: COLORS.border,
    paddingHorizontal: 12, paddingVertical: 6,
  },
  pillSm: { paddingHorizontal: 10, paddingVertical: 4 },
  pillActive:    { backgroundColor: COLORS.green, borderColor: COLORS.green },
  pillStatActive:{ backgroundColor: 'rgba(66,133,244,0.15)', borderColor: 'rgba(66,133,244,0.5)' },
  pillTxt:    { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.muted2 },
  pillTxtSm:  { fontSize: 11 },
  pillTxtActive: { color: COLORS.bg },
});

// ─── Screen ───────────────────────────────────────────────────────────────────

export default function AdminVerificationsScreen({ navigation }: any) {
  const { t } = useTranslation();
  const [activeTab,   setActiveTab]   = useState(0);
  const [refreshing,  setRefreshing]  = useState(false);

  // Tab 0 — Grupos
  const [groupRequests, setGroupRequests] = useState<any[]>([]);
  const [selectedReq,   setSelectedReq]   = useState<any>(null);
  const [groupNotes,    setGroupNotes]     = useState('');
  const [groupLoading,  setGroupLoading]   = useState(false);

  // Tab 1 — Clientes
  const [clients,       setClients]       = useState<any[]>([]);
  const [selectedClient, setSelectedClient] = useState<any>(null);
  const [clientNotes,   setClientNotes]   = useState('');
  const [clientLoading, setClientLoading] = useState(false);

  // Tab 2 — Talentos
  const [talents,       setTalents]       = useState<any[]>([]);
  const [selectedTalent, setSelectedTalent] = useState<any>(null);
  const [talentNotes,   setTalentNotes]   = useState('');
  const [talentLoading, setTalentLoading] = useState(false);

  // Búsqueda
  const [searchGroups,   setSearchGroups]   = useState('');
  const [searchClients,  setSearchClients]  = useState('');
  const [searchTalents,  setSearchTalents]  = useState('');

  // Filtro geográfico
  const [gCountry, setGCountry] = useState<string | null>(null);
  const [gState,   setGState]   = useState<string | null>(null);
  const [cCountry, setCCountry] = useState<string | null>(null);
  const [cState,   setCState]   = useState<string | null>(null);
  const [tCountry, setTCountry] = useState<string | null>(null);
  const [tState,   setTState]   = useState<string | null>(null);

  useEffect(() => { fetchAll(); }, []);

  useEffect(() => {
    setSelectedReq(null); setGroupNotes('');
    setSelectedClient(null); setClientNotes('');
    setSelectedTalent(null); setTalentNotes('');
  }, [activeTab]);

  // ── Fetch ──────────────────────────────────────────────────────────────────

  const fetchAll = async () => {
    await Promise.all([fetchGroups(), fetchClients(), fetchTalents()]);
  };

  const fetchGroups = async () => {
    const { data } = await supabase
      .from('verification_requests')
      .select('*, group:groups(name, genre, city, state, country, owner_id, profile_image, owner:profiles!groups_owner_id_fkey(phone))')
      .neq('status', 'draft')
      .order('submitted_at', { ascending: false });
    if (data) setGroupRequests(data);
  };

  const fetchClients = async () => {
    const { data } = await supabase
      .from('profiles')
      .select('id, full_name, avatar_url, city, state, country, phone, verification_status, admin_verified, verification_submitted_at, created_at, verification_admin_notes')
      .eq('role', 'client')
      .not('verification_status', 'eq', 'none')
      .order('verification_submitted_at', { ascending: false });
    if (data) setClients(data);
  };

  const fetchTalents = async () => {
    const { data } = await supabase
      .from('profiles')
      .select('id, full_name, avatar_url, city, state, country, phone, verification_status, admin_verified, verification_submitted_at, created_at, verification_admin_notes, id_document_url, selfie_url')
      .eq('role', 'talent')
      // Sin filtro de status: el admin ve todos los talentos registrados.
      // Los que tienen solicitud pendiente aparecen primero por el orden.
      .order('verification_submitted_at', { ascending: false, nullsFirst: false })
      .order('created_at', { ascending: false });
    if (data) setTalents(data);
  };

  const onRefresh = async () => {
    setRefreshing(true);
    await fetchAll();
    setRefreshing(false);
  };

  // ── Datos filtrados ────────────────────────────────────────────────────────

  const filteredGroups = useMemo(() => {
    let list = groupRequests;
    if (searchGroups.trim()) {
      const q = searchGroups.toLowerCase();
      list = list.filter(r => r.group?.name?.toLowerCase().includes(q) || r.group?.city?.toLowerCase().includes(q));
    }
    if (gCountry) list = list.filter(r => r.group?.country === gCountry);
    if (gState)   list = list.filter(r => r.group?.state   === gState);
    return list;
  }, [groupRequests, searchGroups, gCountry, gState]);

  const filteredClients = useMemo(() => {
    let list = clients;
    if (searchClients.trim()) {
      const q = searchClients.toLowerCase();
      list = list.filter(p => p.full_name?.toLowerCase().includes(q) || p.city?.toLowerCase().includes(q));
    }
    if (cCountry) list = list.filter(p => p.country === cCountry);
    if (cState)   list = list.filter(p => p.state   === cState);
    return list;
  }, [clients, searchClients, cCountry, cState]);

  const filteredTalents = useMemo(() => {
    let list = talents;
    if (searchTalents.trim()) {
      const q = searchTalents.toLowerCase();
      list = list.filter(p => p.full_name?.toLowerCase().includes(q) || p.city?.toLowerCase().includes(q));
    }
    if (tCountry) list = list.filter(p => p.country === tCountry);
    if (tState)   list = list.filter(p => p.state   === tState);
    return list;
  }, [talents, searchTalents, tCountry, tState]);

  // ── Ver documento o selfie ─────────────────────────────────────────────────

  const handleViewFile = async (path: string, label: string) => {
    const { data, error } = await supabase.storage
      .from('verification-docs')
      .createSignedUrl(path, 3600);
    if (error || !data?.signedUrl) {
      Alert.alert(t('adminVerificationsScreen.alerts.error'), t('adminVerificationsScreen.alerts.fileLinkError', { label }));
      return;
    }
    Linking.openURL(data.signedUrl);
  };

  // ── Aprobar / rechazar grupos ──────────────────────────────────────────────

  const handleGroupDecision = async (request: any, decision: 'approved' | 'rejected') => {
    Alert.alert(
      decision === 'approved' ? t('adminVerificationsScreen.alerts.group.approveTitle') : t('adminVerificationsScreen.alerts.group.rejectTitle'),
      decision === 'approved'
        ? t('adminVerificationsScreen.alerts.group.approveMessage', { name: request.group?.name })
        : t('adminVerificationsScreen.alerts.group.rejectMessage', { name: request.group?.name }),
      [
        { text: t('adminVerificationsScreen.alerts.cancel'), style: 'cancel' },
        {
          text: decision === 'approved' ? t('adminVerificationsScreen.buttons.approve') : t('adminVerificationsScreen.buttons.reject'),
          style: decision === 'rejected' ? 'destructive' : 'default',
          onPress: async () => {
            setGroupLoading(true);
            const { data, error } = await supabase.rpc('admin_review_group_verification', {
              p_attempt_id: request.id,
              p_approved:   decision === 'approved',
              p_notes:      groupNotes || null,
            });
            setGroupLoading(false);
            if (error || !data?.ok) {
              Alert.alert(t('adminVerificationsScreen.alerts.error'), data?.error ?? error?.message ?? t('adminVerificationsScreen.alerts.group.genericError'));
              return;
            }
            setSelectedReq(null);
            setGroupNotes('');
            fetchGroups();
            Alert.alert(
              t('adminVerificationsScreen.alerts.done'),
              decision === 'approved' ? t('adminVerificationsScreen.alerts.group.approveSuccess') : t('adminVerificationsScreen.alerts.group.rejectSuccess'),
            );
          },
        },
      ]
    );
  };

  // ── Aprobar / rechazar clientes y talentos ─────────────────────────────────

  const handleProfileDecision = async (
    profile: any,
    verified: boolean,
    notes: string,
    setLoading: (v: boolean) => void,
    refetch: () => void,
    clearSelected: () => void,
  ) => {
    const label = profile.role === 'talent' ? t('adminVerificationsScreen.alerts.profile.roleTalent') : t('adminVerificationsScreen.alerts.profile.roleClient');
    Alert.alert(
      verified ? t('adminVerificationsScreen.alerts.profile.verifyTitle', { role: label }) : t('adminVerificationsScreen.alerts.profile.rejectTitle', { role: label }),
      verified
        ? t('adminVerificationsScreen.alerts.profile.verifyMessage', { name: profile.full_name })
        : t('adminVerificationsScreen.alerts.profile.rejectMessage', { name: profile.full_name }),
      [
        { text: t('adminVerificationsScreen.alerts.cancel'), style: 'cancel' },
        {
          text: verified ? t('adminVerificationsScreen.buttons.verify') : t('adminVerificationsScreen.buttons.reject'),
          style: verified ? 'default' : 'destructive',
          onPress: async () => {
            setLoading(true);
            const { data, error } = await supabase.rpc('admin_set_profile_verified', {
              p_user_id: profile.id,
              p_verified: verified,
              p_note:    notes.trim() || null,
            });
            setLoading(false);
            if (error || !data?.ok) {
              Alert.alert(t('adminVerificationsScreen.alerts.error'), error?.message ?? data?.error ?? t('adminVerificationsScreen.alerts.profile.genericError'));
              return;
            }
            clearSelected();
            refetch();
            Alert.alert(
              t('adminVerificationsScreen.alerts.done'),
              verified ? t('adminVerificationsScreen.alerts.profile.verifySuccess', { name: profile.full_name }) : t('adminVerificationsScreen.alerts.profile.rejectSuccess'),
            );
          },
        },
      ]
    );
  };

  // ── Config ─────────────────────────────────────────────────────────────────

  const STATUS_CONFIG: Record<string, { label: string; variant: any }> = {
    pending:  { label: 'Pendiente', variant: 'orange' },
    approved: { label: 'Aprobada',  variant: 'blue'   },
    rejected: { label: 'Rechazada', variant: 'red'    },
  };

  const pendingGroupsCount  = groupRequests.filter(r => r.status === 'pending').length;
  const pendingClientsCount = clients.filter(p => p.verification_status === 'pending').length;
  const pendingTalentsCount = talents.filter(p => p.verification_status === 'pending').length;

  const tabs = [
    { label: 'Grupos',   count: pendingGroupsCount  },
    { label: 'Clientes', count: pendingClientsCount },
    { label: 'Talentos', count: pendingTalentsCount },
  ];

  // ── RENDER ─────────────────────────────────────────────────────────────────

  return (
    <View style={styles.container}>
      <Particles />
      <SafeAreaView style={{ flex: 1 }}>

        {/* Header */}
        <View style={styles.header}>
          <Pressable style={styles.backBtn} onPress={() => navigation.goBack()}>
            <ArrowLeft size={20} color={COLORS.text} />
          </Pressable>
          <Text style={styles.headerTitle}>Verificaciones</Text>
          <View style={{ width: 40 }} />
        </View>

        {/* Tab bar */}
        <View style={styles.tabBar}>
          {tabs.map((tab, i) => (
            <Pressable
              key={i}
              style={[styles.tab, activeTab === i && styles.tabActive]}
              onPress={() => setActiveTab(i)}
            >
              <Text style={[styles.tabText, activeTab === i && styles.tabTextActive]}>
                {tab.label}
              </Text>
              {tab.count > 0 && (
                <View style={[styles.tabBadge, activeTab === i && styles.tabBadgeActive]}>
                  <Text style={[styles.tabBadgeText, activeTab === i && styles.tabBadgeTextActive]}>
                    {tab.count}
                  </Text>
                </View>
              )}
            </Pressable>
          ))}
        </View>

        {/* Buscador */}
        <View style={styles.searchWrap}>
          <Search size={14} color={COLORS.muted} />
          <TextInput
            style={styles.searchInput}
            placeholder={
              activeTab === 0 ? 'Buscar grupo por nombre o ciudad...'
              : activeTab === 1 ? 'Buscar cliente por nombre...'
              : 'Buscar talento por nombre...'
            }
            placeholderTextColor={COLORS.muted}
            value={activeTab === 0 ? searchGroups : activeTab === 1 ? searchClients : searchTalents}
            onChangeText={activeTab === 0 ? setSearchGroups : activeTab === 1 ? setSearchClients : setSearchTalents}
          />
          {(activeTab === 0 ? searchGroups : activeTab === 1 ? searchClients : searchTalents).length > 0 && (
            <Pressable onPress={() => activeTab === 0 ? setSearchGroups('') : activeTab === 1 ? setSearchClients('') : setSearchTalents('')}>
              <X size={14} color={COLORS.muted} />
            </Pressable>
          )}
        </View>

        {/* Filtro geográfico */}
        {activeTab === 0 && (
          <GeoFilter
            data={groupRequests.map(r => ({ country: r.group?.country, state: r.group?.state }))}
            countryKey="country" stateKey="state"
            activeCountry={gCountry} activeState={gState}
            onSelect={(c, s) => { setGCountry(c); setGState(s); }}
          />
        )}
        {activeTab === 1 && (
          <GeoFilter
            data={clients}
            countryKey="country" stateKey="state"
            activeCountry={cCountry} activeState={cState}
            onSelect={(c, s) => { setCCountry(c); setCState(s); }}
          />
        )}
        {activeTab === 2 && (
          <GeoFilter
            data={talents}
            countryKey="country" stateKey="state"
            activeCountry={tCountry} activeState={tState}
            onSelect={(c, s) => { setTCountry(c); setTState(s); }}
          />
        )}

        {/* Contador de resultados */}
        {(activeTab === 0 && (searchGroups || gCountry)) ||
         (activeTab === 1 && (searchClients || cCountry)) ||
         (activeTab === 2 && (searchTalents || tCountry)) ? (
          <Text style={styles.resultCount}>
            {activeTab === 0
              ? `${filteredGroups.length} de ${groupRequests.length} solicitudes`
              : activeTab === 1
              ? `${filteredClients.length} de ${clients.length} clientes`
              : `${filteredTalents.length} de ${talents.length} talentos`}
          </Text>
        ) : null}

        <ScrollView
          showsVerticalScrollIndicator={false}
          contentContainerStyle={styles.list}
          refreshControl={<RefreshControl refreshing={refreshing} onRefresh={onRefresh} tintColor={COLORS.green} />}
        >

          {/* ── TAB 0: GRUPOS ── */}
          {activeTab === 0 && (
            filteredGroups.length === 0 ? (
              <EmptyState label={searchGroups || gCountry ? 'Sin coincidencias' : 'Sin solicitudes de grupos'} />
            ) : (
              filteredGroups.map(req => {
                const conf       = STATUS_CONFIG[req.status] ?? STATUS_CONFIG.pending;
                const isSelected = selectedReq?.id === req.id;
                const isPending  = req.status === 'pending';

                return (
                  <View key={req.id} style={styles.card}>
                    <Pressable
                      style={styles.cardHeader}
                      onPress={() => setSelectedReq(isSelected ? null : req)}
                    >
                      <View style={styles.cardLeft}>
                        <View style={styles.shieldIcon}>
                          <Shield size={16} color={COLORS.blue} />
                        </View>
                        <View style={{ flex: 1 }}>
                          <Text style={styles.entityName}>{req.group?.name ?? 'Grupo'}</Text>
                          <Text style={styles.entityMeta}>
                            {[req.group?.genre, req.group?.city, req.group?.state, req.group?.country].filter(Boolean).join('  ·  ')}
                          </Text>
                          <Text style={styles.entityDate}>
                            {new Date(req.submitted_at).toLocaleDateString('es-MX')}
                          </Text>
                        </View>
                      </View>
                      <Badge label={conf.label} variant={conf.variant} />
                    </Pressable>

                    {/* Panel de info — visible para TODOS los estados */}
                    {isSelected && (
                      <View style={styles.actionPanel}>
                        {/* Teléfono */}
                        <View style={styles.ownerPhoneRow}>
                          <Phone size={13} color={req.group?.owner?.phone ? COLORS.green : COLORS.muted} />
                          <Text style={styles.ownerPhoneText}>
                            {req.group?.owner?.phone ?? 'Sin teléfono registrado'}
                          </Text>
                        </View>

                        {/* Chips KYC */}
                        <View style={styles.kycEvidenceRow}>
                          <View style={[styles.kycChip, req.liveness_verified ? styles.kycChipOk : styles.kycChipMissing]}>
                            <Text style={[styles.kycChipText, req.liveness_verified ? styles.kycChipTextOk : styles.kycChipTextMissing]}>
                              {req.liveness_verified ? '✅ Foto enviada' : '❌ Sin foto'}
                            </Text>
                          </View>
                          <View style={[styles.kycChip, req.document_url ? styles.kycChipOk : styles.kycChipMissing]}>
                            <Text style={[styles.kycChipText, req.document_url ? styles.kycChipTextOk : styles.kycChipTextMissing]}>
                              {req.document_url ? '✅ Documento subido' : '❌ Sin documento'}
                            </Text>
                          </View>
                        </View>

                        {/* Ver archivos */}
                        <View style={styles.viewFilesRow}>
                          {req.document_url && (
                            <Pressable style={styles.viewFileBtn} onPress={() => handleViewFile(req.document_url, 'documento')}>
                              <FileText size={14} color={COLORS.blue} />
                              <Text style={styles.viewFileBtnText}>Ver documento</Text>
                            </Pressable>
                          )}
                          {req.selfie_url && (
                            <Pressable style={styles.viewFileBtn} onPress={() => handleViewFile(req.selfie_url, 'foto')}>
                              <User size={14} color={COLORS.blue} />
                              <Text style={styles.viewFileBtnText}>Ver foto</Text>
                            </Pressable>
                          )}
                        </View>

                        {/* Notas admin (solo para pending) */}
                        {isPending && (
                          <>
                            <TextInput
                              style={styles.notesInput}
                              placeholder="Notas para el grupo (opcional)..."
                              placeholderTextColor={COLORS.muted}
                              value={groupNotes}
                              onChangeText={setGroupNotes}
                              multiline
                              numberOfLines={3}
                              textAlignVertical="top"
                            />
                            <View style={styles.actionBtns}>
                              <Pressable
                                style={[styles.decisionBtn, styles.approveBtn, groupLoading && { opacity: 0.6 }]}
                                onPress={() => handleGroupDecision(req, 'approved')}
                                disabled={groupLoading}
                              >
                                <CheckCircle size={16} color={COLORS.bg} />
                                <Text style={styles.approveBtnText}>Aprobar</Text>
                              </Pressable>
                              <Pressable
                                style={[styles.decisionBtn, styles.rejectBtn, groupLoading && { opacity: 0.6 }]}
                                onPress={() => handleGroupDecision(req, 'rejected')}
                                disabled={groupLoading}
                              >
                                <XCircle size={16} color={COLORS.white} />
                                <Text style={styles.rejectBtnText}>Rechazar</Text>
                              </Pressable>
                            </View>
                          </>
                        )}

                        {/* Notas del admin (lectura — para approved/rejected) */}
                        {!isPending && req.admin_notes && (
                          <View style={styles.notesBox}>
                            <Text style={styles.notesLabel}>Notas del admin:</Text>
                            <Text style={styles.notesText}>{req.admin_notes}</Text>
                          </View>
                        )}
                      </View>
                    )}
                  </View>
                );
              })
            )
          )}

          {/* ── TAB 1: CLIENTES ── */}
          {activeTab === 1 && (
            filteredClients.length === 0 ? (
              <EmptyState label={searchClients || cCountry ? 'Sin coincidencias' : 'Sin solicitudes de clientes'} />
            ) : (
              filteredClients.map(profile => {
                const isSelected = selectedClient?.id === profile.id;
                const conf = STATUS_CONFIG[profile.verification_status] ?? STATUS_CONFIG.pending;
                return (
                  <View key={profile.id} style={styles.card}>
                    <Pressable
                      style={styles.cardHeader}
                      onPress={() => { setSelectedClient(isSelected ? null : profile); setClientNotes(''); }}
                    >
                      <View style={styles.cardLeft}>
                        <ProfileAvatar profile={profile} />
                        <View style={{ flex: 1 }}>
                          <Text style={styles.entityName}>{profile.full_name ?? '—'}</Text>
                          <Text style={styles.entityMeta}>
                            {[profile.city, profile.state, profile.country].filter(Boolean).join(', ') || '—'}
                          </Text>
                          {profile.verification_submitted_at && (
                            <Text style={styles.entityDate}>
                              {new Date(profile.verification_submitted_at).toLocaleDateString('es-MX')}
                            </Text>
                          )}
                        </View>
                      </View>
                      <Badge label={conf.label} variant={conf.variant} />
                    </Pressable>

                    {isSelected && (
                      <View style={styles.actionPanel}>
                        {/* Teléfono */}
                        {profile.phone && (
                          <View style={styles.ownerPhoneRow}>
                            <Phone size={13} color={COLORS.green} />
                            <Text style={styles.ownerPhoneText}>{profile.phone}</Text>
                          </View>
                        )}

                        {/* Notas (solo pending) */}
                        {profile.verification_status === 'pending' && (
                          <>
                            <TextInput
                              style={styles.notesInput}
                              placeholder="Notas internas (opcional)..."
                              placeholderTextColor={COLORS.muted}
                              value={clientNotes}
                              onChangeText={setClientNotes}
                              multiline numberOfLines={3} textAlignVertical="top"
                            />
                            <View style={styles.actionBtns}>
                              <Pressable
                                style={[styles.decisionBtn, styles.approveBtn, clientLoading && { opacity: 0.6 }]}
                                onPress={() => handleProfileDecision({ ...profile, role: 'client' }, true, clientNotes, setClientLoading, fetchClients, () => setSelectedClient(null))}
                                disabled={clientLoading}
                              >
                                <CheckCircle size={16} color={COLORS.bg} />
                                <Text style={styles.approveBtnText}>Verificar</Text>
                              </Pressable>
                              <Pressable
                                style={[styles.decisionBtn, styles.rejectBtn, clientLoading && { opacity: 0.6 }]}
                                onPress={() => handleProfileDecision({ ...profile, role: 'client' }, false, clientNotes, setClientLoading, fetchClients, () => setSelectedClient(null))}
                                disabled={clientLoading}
                              >
                                <XCircle size={16} color={COLORS.white} />
                                <Text style={styles.rejectBtnText}>Rechazar</Text>
                              </Pressable>
                            </View>
                          </>
                        )}

                        {profile.verification_status !== 'pending' && profile.verification_admin_notes && (
                          <View style={styles.notesBox}>
                            <Text style={styles.notesLabel}>Notas del admin:</Text>
                            <Text style={styles.notesText}>{profile.verification_admin_notes}</Text>
                          </View>
                        )}
                      </View>
                    )}
                  </View>
                );
              })
            )
          )}

          {/* ── TAB 2: TALENTOS ── */}
          {activeTab === 2 && (
            filteredTalents.length === 0 ? (
              <EmptyState label={searchTalents || tCountry ? 'Sin coincidencias' : 'Sin talentos registrados'} />
            ) : (
              filteredTalents.map(profile => {
                const isSelected = selectedTalent?.id === profile.id;
                const conf = STATUS_CONFIG[profile.verification_status] ?? STATUS_CONFIG.pending;
                return (
                  <View key={profile.id} style={styles.card}>
                    <Pressable
                      style={styles.cardHeader}
                      onPress={() => { setSelectedTalent(isSelected ? null : profile); setTalentNotes(''); }}
                    >
                      <View style={styles.cardLeft}>
                        <ProfileAvatar profile={profile} />
                        <View style={{ flex: 1 }}>
                          <Text style={styles.entityName}>{profile.full_name ?? '—'}</Text>
                          <Text style={styles.entityMeta}>
                            {[profile.city, profile.state, profile.country].filter(Boolean).join(', ') || '—'}
                          </Text>
                          {profile.verification_submitted_at && (
                            <Text style={styles.entityDate}>
                              {new Date(profile.verification_submitted_at).toLocaleDateString('es-MX')}
                            </Text>
                          )}
                        </View>
                      </View>
                      <Badge label={conf.label} variant={conf.variant} />
                    </Pressable>

                    {isSelected && (
                      <View style={styles.actionPanel}>

                        {/* Teléfono */}
                        <View style={styles.ownerPhoneRow}>
                          <Phone size={13} color={profile.phone ? COLORS.green : COLORS.muted} />
                          <Text style={styles.ownerPhoneText}>
                            {profile.phone ?? 'Sin teléfono registrado'}
                          </Text>
                        </View>

                        {/* Chips evidencia KYC */}
                        <View style={styles.kycEvidenceRow}>
                          <View style={[styles.kycChip, profile.id_document_url ? styles.kycChipOk : styles.kycChipMissing]}>
                            <Text style={[styles.kycChipText, profile.id_document_url ? styles.kycChipTextOk : styles.kycChipTextMissing]}>
                              {profile.id_document_url ? '✅ Documento subido' : '❌ Sin documento'}
                            </Text>
                          </View>
                          <View style={[styles.kycChip, profile.selfie_url ? styles.kycChipOk : styles.kycChipMissing]}>
                            <Text style={[styles.kycChipText, profile.selfie_url ? styles.kycChipTextOk : styles.kycChipTextMissing]}>
                              {profile.selfie_url ? '✅ Foto enviada' : '❌ Sin foto'}
                            </Text>
                          </View>
                        </View>

                        {/* Botones ver archivos */}
                        {(profile.id_document_url || profile.selfie_url) && (
                          <View style={styles.viewFilesRow}>
                            {profile.id_document_url && (
                              <Pressable style={styles.viewFileBtn} onPress={() => handleViewFile(profile.id_document_url, 'documento')}>
                                <FileText size={14} color={COLORS.blue} />
                                <Text style={styles.viewFileBtnText}>Ver documento</Text>
                              </Pressable>
                            )}
                            {profile.selfie_url && (
                              <Pressable style={styles.viewFileBtn} onPress={() => handleViewFile(profile.selfie_url, 'foto')}>
                                <User size={14} color={COLORS.blue} />
                                <Text style={styles.viewFileBtnText}>Ver foto</Text>
                              </Pressable>
                            )}
                          </View>
                        )}

                        {/* Notas admin previas */}
                        {profile.verification_admin_notes && (
                          <View style={styles.notesBox}>
                            <Text style={styles.notesLabel}>Notas anteriores:</Text>
                            <Text style={styles.notesText}>{profile.verification_admin_notes}</Text>
                          </View>
                        )}

                        {/* Acción: disponible para cualquier talento no aprobado */}
                        {profile.verification_status !== 'approved' && (
                          <>
                            <TextInput
                              style={styles.notesInput}
                              placeholder="Notas para el talento (opcional)..."
                              placeholderTextColor={COLORS.muted}
                              value={talentNotes}
                              onChangeText={setTalentNotes}
                              multiline numberOfLines={3} textAlignVertical="top"
                            />
                            <View style={styles.actionBtns}>
                              <Pressable
                                style={[styles.decisionBtn, styles.approveBtn, talentLoading && { opacity: 0.6 }]}
                                onPress={() => handleProfileDecision({ ...profile, role: 'talent' }, true, talentNotes, setTalentLoading, fetchTalents, () => setSelectedTalent(null))}
                                disabled={talentLoading}
                              >
                                <CheckCircle size={16} color={COLORS.bg} />
                                <Text style={styles.approveBtnText}>Verificar</Text>
                              </Pressable>
                              <Pressable
                                style={[styles.decisionBtn, styles.rejectBtn, talentLoading && { opacity: 0.6 }]}
                                onPress={() => handleProfileDecision({ ...profile, role: 'talent' }, false, talentNotes, setTalentLoading, fetchTalents, () => setSelectedTalent(null))}
                                disabled={talentLoading}
                              >
                                <XCircle size={16} color={COLORS.white} />
                                <Text style={styles.rejectBtnText}>Rechazar</Text>
                              </Pressable>
                            </View>
                          </>
                        )}

                        {/* Talento aprobado — solo lectura */}
                        {profile.verification_status === 'approved' && (
                          <View style={[styles.kycChip, styles.kycChipOk, { alignSelf: 'flex-start', marginTop: 4 }]}>
                            <Text style={[styles.kycChipText, styles.kycChipTextOk]}>✅ Talento verificado</Text>
                          </View>
                        )}
                      </View>
                    )}
                  </View>
                );
              })
            )
          )}

        </ScrollView>
      </SafeAreaView>
    </View>
  );
}

// ─── Sub-components ───────────────────────────────────────────────────────────

function EmptyState({ label }: { label: string }) {
  return (
    <View style={styles.empty}>
      <ShieldCheck size={48} color={COLORS.muted} />
      <Text style={styles.emptyText}>{label}</Text>
    </View>
  );
}

function ProfileAvatar({ profile }: { profile: any }) {
  if (profile.avatar_url) {
    return <Image source={{ uri: profile.avatar_url }} style={styles.profileAvatar} />;
  }
  return (
    <View style={[styles.profileAvatar, styles.profileAvatarEmpty]}>
      <User size={16} color={COLORS.muted2} />
    </View>
  );
}

// ─── Styles ───────────────────────────────────────────────────────────────────

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

  tabBar: {
    flexDirection: 'row',
    borderBottomWidth: 1, borderBottomColor: COLORS.border,
  },
  tab: {
    flex: 1, flexDirection: 'row', alignItems: 'center', justifyContent: 'center',
    gap: 6, paddingVertical: 13,
    borderBottomWidth: 2, borderBottomColor: 'transparent',
  },
  tabActive:     { borderBottomColor: COLORS.green },
  tabText:       { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted2 },
  tabTextActive: { color: COLORS.green, fontFamily: FONTS.bodySemiBold },
  tabBadge: {
    minWidth: 18, height: 18, borderRadius: 9,
    backgroundColor: COLORS.card2, borderWidth: 1, borderColor: COLORS.border,
    alignItems: 'center', justifyContent: 'center', paddingHorizontal: 5,
  },
  tabBadgeActive:     { backgroundColor: COLORS.green, borderColor: COLORS.green },
  tabBadgeText:       { fontFamily: FONTS.bodySemiBold, fontSize: 10, color: COLORS.muted2 },
  tabBadgeTextActive: { color: COLORS.bg },

  // Search
  searchWrap: {
    flexDirection: 'row', alignItems: 'center', gap: 8,
    marginHorizontal: SPACING.xl, marginTop: 12,
    backgroundColor: COLORS.card, borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: COLORS.border,
    paddingHorizontal: 14, paddingVertical: 10,
  },
  searchInput: { flex: 1, fontFamily: FONTS.body, fontSize: 14, color: COLORS.text },

  resultCount: {
    fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted,
    marginHorizontal: SPACING.xl, marginTop: 4, marginBottom: 2,
  },

  list: { padding: SPACING.xl, gap: 12, paddingBottom: 40 },

  card: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border, overflow: 'hidden',
  },
  cardHeader: {
    flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center',
    padding: SPACING.lg,
  },
  cardLeft: { flexDirection: 'row', alignItems: 'center', gap: 12, flex: 1 },

  shieldIcon: {
    width: 36, height: 36, borderRadius: 10,
    backgroundColor: 'rgba(66,133,244,0.1)',
    alignItems: 'center', justifyContent: 'center',
  },
  profileAvatar: { width: 36, height: 36, borderRadius: 18 },
  profileAvatarEmpty: {
    backgroundColor: COLORS.card2, borderWidth: 1, borderColor: COLORS.border,
    alignItems: 'center', justifyContent: 'center',
  },

  entityName: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.text, marginBottom: 2 },
  entityMeta: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2 },
  entityDate: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted, marginTop: 2 },

  actionPanel: {
    borderTopWidth: 1, borderTopColor: COLORS.border,
    padding: SPACING.lg, gap: 10,
  },
  notesInput: {
    backgroundColor: COLORS.card2, borderRadius: RADIUS.sm,
    borderWidth: 1, borderColor: COLORS.border,
    padding: 12, fontFamily: FONTS.body, fontSize: 14, color: COLORS.text,
    textAlignVertical: 'top',
  },
  actionBtns: { flexDirection: 'row', gap: 10 },
  decisionBtn: {
    flex: 1, flexDirection: 'row', alignItems: 'center', justifyContent: 'center',
    gap: 8, paddingVertical: 12, borderRadius: RADIUS.md,
  },
  approveBtn:     { backgroundColor: COLORS.green },
  approveBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.bg },
  rejectBtn:      { backgroundColor: COLORS.red },
  rejectBtnText:  { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.white },

  ownerPhoneRow: { flexDirection: 'row', alignItems: 'center', gap: 8 },
  ownerPhoneText: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.text },

  kycEvidenceRow: { flexDirection: 'row', gap: 8, flexWrap: 'wrap' },
  kycChip:        { paddingHorizontal: 10, paddingVertical: 5, borderRadius: 8, borderWidth: 1 },
  kycChipOk:      { backgroundColor: 'rgba(0,230,118,0.08)', borderColor: 'rgba(0,230,118,0.35)' },
  kycChipMissing: { backgroundColor: 'rgba(239,83,80,0.08)', borderColor: 'rgba(239,83,80,0.35)' },
  kycChipText:    { fontFamily: FONTS.bodyMedium, fontSize: 12 },
  kycChipTextOk:      { color: COLORS.green },
  kycChipTextMissing: { color: COLORS.red },

  viewFilesRow: { flexDirection: 'row', gap: 8, flexWrap: 'wrap' },
  viewFileBtn: {
    flexDirection: 'row', alignItems: 'center', gap: 6,
    backgroundColor: 'rgba(66,133,244,0.08)', borderRadius: 8,
    borderWidth: 1, borderColor: 'rgba(66,133,244,0.3)',
    paddingHorizontal: 12, paddingVertical: 7,
  },
  viewFileBtnText: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.blue },

  notesBox: {
    borderTopWidth: 1, borderTopColor: COLORS.border,
    paddingTop: 10,
  },
  notesLabel: { fontFamily: FONTS.bodyMedium, fontSize: 11, color: COLORS.muted, marginBottom: 3 },
  notesText:  { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2 },

  empty:     { alignItems: 'center', paddingTop: 60, gap: 12 },
  emptyText: { fontFamily: FONTS.body, color: COLORS.muted, fontSize: 14, textAlign: 'center' },
});
