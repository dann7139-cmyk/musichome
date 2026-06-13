/**
 * TalentStatsScreen — Estadísticas del talento individual.
 * 4 tabs: Actividad · Rendimiento · Reputación · Especialización
 */
import React, { useEffect, useState } from 'react';
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
import { ArrowLeft, Activity, TrendingUp, Star, Music2 } from 'lucide-react-native';
import { supabase } from '../../config/supabase';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';

// ─── Helpers ─────────────────────────────────────────────────────────────────

function fmt(n: number) {
  return n.toLocaleString('es-MX', { minimumFractionDigits: 0, maximumFractionDigits: 0 });
}
function pct(n: number) { return `${Math.round(n)}%`; }

// ─── Sub-components ───────────────────────────────────────────────────────────

function StatCard({ label, value, sub, color = COLORS.green }: any) {
  return (
    <View style={c.statCard}>
      <Text style={[c.statVal, { color }]}>{value}</Text>
      <Text style={c.statLabel}>{label}</Text>
      {sub ? <Text style={c.statSub}>{sub}</Text> : null}
    </View>
  );
}

function Row2({ label, value, color }: { label: string; value: string; color?: string }) {
  return (
    <View style={c.row2}>
      <Text style={c.row2Label}>{label}</Text>
      <Text style={[c.row2Val, color ? { color } : null]}>{value}</Text>
    </View>
  );
}

function SectionTitle({ title }: { title: string }) {
  return <Text style={c.sectionTitle}>{title}</Text>;
}

function ProgressBar({ value, max, color = COLORS.green }: { value: number; max: number; color?: string }) {
  const p = max > 0 ? Math.min(100, (value / max) * 100) : 0;
  return (
    <View style={c.progressBg}>
      <View style={[c.progressFill, { width: `${p}%` as any, backgroundColor: color }]} />
    </View>
  );
}

// ─── TABS ─────────────────────────────────────────────────────────────────────

const TABS = [
  { label: 'Actividad',       icon: Activity },
  { label: 'Rendimiento',     icon: TrendingUp },
  { label: 'Reputación',      icon: Star },
  { label: 'Especialización', icon: Music2 },
];

// ─── Screen ───────────────────────────────────────────────────────────────────

export default function TalentStatsScreen({ navigation }: any) {
  const [activeTab, setActiveTab] = useState(0);
  const [loading,   setLoading]   = useState(true);
  const [refreshing, setRefreshing] = useState(false);

  // ── Data ─────────────────────────────────────────────────────────────────
  const [invitations,     setInvitations]     = useState<any[]>([]);
  const [groupReservations, setGroupReservations] = useState<any[]>([]);
  const [profile,         setProfile]         = useState<any>(null);
  const [artistProfile,   setArtistProfile]   = useState<any>(null);
  const [groups,          setGroups]          = useState<any[]>([]);

  useEffect(() => { loadAll(); }, []);

  const onRefresh = async () => { setRefreshing(true); await loadAll(); setRefreshing(false); };

  const loadAll = async () => {
    setLoading(true);
    const { data: { user } } = await supabase.auth.getUser();
    if (!user) { setLoading(false); return; }

    const [profileRes, artistRes, invRes] = await Promise.all([
      supabase.from('profiles')
        .select('full_name, rating, reputation_level, reputation_points, city, state, created_at')
        .eq('id', user.id)
        .single(),
      supabase.from('job_board_profiles')
        .select('instrument_or_role, availability_status, experience_years')
        .eq('user_id', user.id)
        .maybeSingle(),
      supabase.from('job_invitations')
        .select('id, status, group_id, created_at, groups(name, city, genre)')
        .eq('invited_user_id', user.id),
    ]);

    setProfile(profileRes.data);
    setArtistProfile(artistRes.data);

    const allInvitations = invRes.data ?? [];
    setInvitations(allInvitations);

    // Get accepted group IDs to fetch their reservations
    const acceptedInvs = allInvitations.filter((i: any) => i.status === 'accepted');
    const groupIds = [...new Set(acceptedInvs.map((i: any) => i.group_id))];
    setGroups(acceptedInvs.map((i: any) => i.groups).filter(Boolean));

    if (groupIds.length > 0) {
      const { data: resData } = await supabase.from('reservations')
        .select('status, event_date, event_time, package_id, created_at')
        .in('group_id', groupIds);
      setGroupReservations(resData ?? []);
    }

    setLoading(false);
  };

  // ── Calculations ─────────────────────────────────────────────────────────
  const accepted  = invitations.filter(i => i.status === 'accepted');
  const declined  = invitations.filter(i => i.status === 'declined');
  const pending   = invitations.filter(i => i.status === 'pending');
  const acceptRate = invitations.length > 0 ? (accepted.length / invitations.length) * 100 : 0;

  const completedEvents = groupReservations.filter(r => r.status === 'completed');
  const now             = new Date();
  const monthStart      = new Date(now.getFullYear(), now.getMonth(), 1);
  const eventsThisMonth = completedEvents.filter(r => new Date(r.event_date) >= monthStart);

  // Groups worked with (unique)
  const uniqueGroups = groups.reduce((acc: any[], g: any) => {
    if (g && !acc.find((a: any) => a.name === g.name)) acc.push(g);
    return acc;
  }, []);

  // Most frequent event (by group city)
  const cityCounts: Record<string, number> = {};
  uniqueGroups.forEach((g: any) => {
    if (g.city) cityCounts[g.city] = (cityCounts[g.city] ?? 0) + 1;
  });
  const topCity = Object.entries(cityCounts).sort((a, b) => b[1] - a[1])[0]?.[0] ?? 'Sin datos';

  // Genres (from groups)
  const genres: string[] = [];
  uniqueGroups.forEach((g: any) => { if (g.genre && !genres.includes(g.genre)) genres.push(g.genre); });

  // Months since registration
  const memberSince = profile?.created_at
    ? new Date(profile.created_at).toLocaleDateString('es-MX', { month: 'long', year: 'numeric' })
    : 'Desconocido';

  // ── Render ───────────────────────────────────────────────────────────────
  return (
    <View style={c.root}>
      <SafeAreaView edges={['top']} style={c.header}>
        {navigation.canGoBack() ? (
          <Pressable style={c.backBtn} onPress={() => navigation.goBack()}>
            <ArrowLeft size={20} color={COLORS.text} />
          </Pressable>
        ) : (
          <View style={{ width: 40 }} />
        )}
        <Text style={c.headerTitle}>Mi Panel</Text>
        <View style={{ width: 40 }} />
      </SafeAreaView>

      {/* Tab bar */}
      <ScrollView
        horizontal
        showsHorizontalScrollIndicator={false}
        style={c.tabBar}
        contentContainerStyle={c.tabBarContent}
      >
        {TABS.map((tab, i) => {
          const Icon = tab.icon;
          const active = activeTab === i;
          return (
            <Pressable key={i} style={[c.tab, active && c.tabActive]} onPress={() => setActiveTab(i)}>
              <Icon size={13} color={active ? COLORS.green : COLORS.muted2} />
              <Text style={[c.tabText, active && c.tabTextActive]}>{tab.label}</Text>
            </Pressable>
          );
        })}
      </ScrollView>

      {loading ? (
        <View style={c.center}>
          <ActivityIndicator size="large" color={COLORS.green} />
        </View>
      ) : (
        <ScrollView contentContainerStyle={c.scroll} showsVerticalScrollIndicator={false} refreshControl={<RefreshControl refreshing={refreshing} onRefresh={onRefresh} tintColor={COLORS.green} />}>

          {/* ══ TAB 0: ACTIVIDAD ══ */}
          {activeTab === 0 && (
            <View>
              {/* Tarjeta de perfil */}
              <View style={c.profileCard}>
                <View style={{ flex: 1 }}>
                  <Text style={c.profileName}>{profile?.full_name ?? '—'}</Text>
                  {artistProfile?.instrument_or_role && (
                    <Text style={c.profileInstrument}>{artistProfile.instrument_or_role}</Text>
                  )}
                  {profile?.city || profile?.state ? (
                    <Text style={c.profileCity}>
                      📍 {[profile?.city, profile?.state].filter(Boolean).join(', ')}
                    </Text>
                  ) : (
                    <Text style={c.profileCityEmpty}>Sin ubicación — configura tu ciudad en Perfil</Text>
                  )}
                </View>
                <View style={[c.statusDot,
                  artistProfile?.availability_status === 'available' ? { backgroundColor: COLORS.green } :
                  artistProfile?.availability_status === 'busy'      ? { backgroundColor: COLORS.orange } :
                  { backgroundColor: COLORS.muted }
                ]} />
              </View>

              <View style={c.statsGrid}>
                <StatCard label="Grupos activos"   value={uniqueGroups.length}      sub="Trabajando con" color={COLORS.blue} />
                <StatCard label="Eventos del grupo" value={completedEvents.length}  sub="Completados" />
                <StatCard label="Este mes"          value={eventsThisMonth.length}   sub="Eventos" color={COLORS.orange} />
                <StatCard label="Invitaciones"      value={invitations.length}       sub="Totales" color={COLORS.muted2} />
              </View>

              <View style={c.card}>
                <SectionTitle title="Actividad general" />
                <Row2 label="Grupos con los que trabajas" value={String(uniqueGroups.length)} color={COLORS.green} />
                <Row2 label="Invitaciones recibidas"      value={String(invitations.length)} />
                <Row2 label="Aceptadas"                   value={String(accepted.length)} color={COLORS.green} />
                <Row2 label="Declinadas"                  value={String(declined.length)} color={COLORS.red} />
                <Row2 label="Pendientes"                  value={String(pending.length)} color={COLORS.orange} />
                <Row2 label="Miembro desde"               value={memberSince} />
              </View>

              {uniqueGroups.length > 0 && (
                <View style={c.card}>
                  <SectionTitle title="Grupos con los que trabajas" />
                  {uniqueGroups.slice(0, 5).map((g: any, i: number) => (
                    <Row2 key={i} label={g.name ?? 'Grupo'} value={g.city ?? ''} />
                  ))}
                </View>
              )}
            </View>
          )}

          {/* ══ TAB 1: RENDIMIENTO ══ */}
          {activeTab === 1 && (
            <View>
              {/* Eventos participados */}
              <View style={[c.card, { gap: 0 }]}>
                <SectionTitle title="Participación en eventos" />
                <View style={c.earningsHero}>
                  <Text style={c.earningsAmount}>{completedEvents.length}</Text>
                  <Text style={c.earningsLabel}>Eventos completados</Text>
                </View>
                <Row2 label="Este mes" value={String(eventsThisMonth.length)} color={COLORS.green} />
                <Row2 label="Invitaciones aceptadas" value={String(accepted.length)} color={COLORS.green} />
                <View style={{ paddingHorizontal: 4, paddingTop: 10, paddingBottom: 4 }}>
                  <Text style={{ fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted2, lineHeight: 16 }}>
                    💡 Los pagos los gestiona el dueño del grupo fuera de la plataforma.
                  </Text>
                </View>
              </View>

              <View style={c.card}>
                <SectionTitle title="Tasa de aceptación de invitaciones" />
                <ProgressBar value={acceptRate} max={100} color={acceptRate >= 70 ? COLORS.green : COLORS.orange} />
                <View style={[c.row2, { marginTop: 8 }]}>
                  <Text style={c.row2Label}>Aceptadas / Total</Text>
                  <Text style={[c.row2Val, { color: COLORS.green }]}>{accepted.length} / {invitations.length}</Text>
                </View>
                <View style={c.row2}>
                  <Text style={c.row2Label}>% Aceptación</Text>
                  <Text style={[c.row2Val, { color: acceptRate >= 70 ? COLORS.green : COLORS.orange }]}>
                    {pct(acceptRate)}
                  </Text>
                </View>
              </View>

              <View style={c.statsGrid}>
                <StatCard label="Grupos activos"    value={uniqueGroups.length}      color={COLORS.blue} />
                <StatCard label="% Aceptación"      value={pct(acceptRate)}           color={acceptRate >= 70 ? COLORS.green : COLORS.orange} />
              </View>

              {uniqueGroups.length > 0 && (
                <View style={c.card}>
                  <SectionTitle title="Grupos con los que más trabajas" />
                  {uniqueGroups.slice(0, 5).map((g: any, i: number) => (
                    <View key={i} style={c.rankRow}>
                      <Text style={c.rankNum}>{i + 1}</Text>
                      <View style={{ flex: 1 }}>
                        <Text style={c.rankLabel}>{g.name ?? 'Grupo'}</Text>
                        {g.genre ? <Text style={c.rankSub}>{g.genre}</Text> : null}
                      </View>
                      <Text style={c.rankVal}>{g.city ?? ''}</Text>
                    </View>
                  ))}
                </View>
              )}
            </View>
          )}

          {/* ══ TAB 2: REPUTACIÓN ══ */}
          {activeTab === 2 && (
            <View>
              <View style={[c.card, c.ratingHero]}>
                <Text style={c.ratingBig}>
                  {profile?.rating != null ? Number(profile.rating).toFixed(1) : '—'}
                </Text>
                <Text style={c.ratingStars}>
                  {profile?.rating != null
                    ? '★'.repeat(Math.round(profile.rating)) + '☆'.repeat(5 - Math.round(profile.rating))
                    : '☆☆☆☆☆'}
                </Text>
                <Text style={c.ratingLabel}>Calificación individual</Text>
              </View>

              <View style={c.card}>
                <SectionTitle title="Nivel personal" />
                <Row2 label="Nivel"               value={profile?.reputation_level ?? 'Bronce'} color={COLORS.gold} />
                <Row2 label="Puntos"              value={fmt(profile?.reputation_points ?? 0)} color={COLORS.green} />
                <Row2 label="Ciudad base"         value={profile?.city ?? 'No registrada'} />
                <Row2 label="Eventos del grupo"   value={String(completedEvents.length)} color={COLORS.green} />
              </View>
            </View>
          )}

          {/* ══ TAB 3: ESPECIALIZACIÓN ══ */}
          {activeTab === 3 && (
            <View>
              <View style={c.card}>
                <SectionTitle title="Perfil artístico" />
                <Row2 label="Instrumento / Rol"   value={artistProfile?.instrument_or_role ?? 'No registrado'} color={COLORS.green} />
                <Row2 label="Disponibilidad"       value={
                  artistProfile?.availability_status === 'available' ? 'Disponible' :
                  artistProfile?.availability_status === 'busy' ? 'Ocupado' : 'Sin perfil'
                } color={artistProfile?.availability_status === 'available' ? COLORS.green : COLORS.orange} />
                {artistProfile?.experience_years && (
                  <Row2 label="Años de experiencia" value={`${artistProfile.experience_years} años`} />
                )}
              </View>

              {genres.length > 0 && (
                <View style={c.card}>
                  <SectionTitle title="Géneros que tocas" />
                  <View style={c.tagsWrap}>
                    {genres.map((g, i) => (
                      <View key={i} style={c.tag}>
                        <Text style={c.tagText}>{g}</Text>
                      </View>
                    ))}
                  </View>
                </View>
              )}

              <View style={c.card}>
                <SectionTitle title="Zona de trabajo" />
                <Row2 label="Ciudad más frecuente" value={topCity} color={COLORS.green} />
                <Row2 label="Grupos en diferentes ciudades" value={String(Object.keys(cityCounts).length)} />
              </View>

              <View style={c.card}>
                <SectionTitle title="Resumen de participación" />
                <Row2 label="Grupos activos"         value={String(uniqueGroups.length)} color={COLORS.blue} />
                <Row2 label="Eventos del grupo"      value={String(completedEvents.length)} />
                <Row2 label="Invitaciones totales"   value={String(invitations.length)} />
              </View>
            </View>
          )}

          <View style={{ height: 40 }} />
        </ScrollView>
      )}
    </View>
  );
}

// ─── Styles ───────────────────────────────────────────────────────────────────

const c = StyleSheet.create({
  root:   { flex: 1, backgroundColor: COLORS.bg },
  header: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between',
    paddingHorizontal: SPACING.xl, paddingVertical: 12,
    borderBottomWidth: 1, borderBottomColor: COLORS.border,
  },
  backBtn: {
    width: 40, height: 40, borderRadius: 12,
    backgroundColor: COLORS.card, borderWidth: 1, borderColor: COLORS.border,
    alignItems: 'center', justifyContent: 'center',
  },
  headerTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 17, color: COLORS.text },
  center:      { flex: 1, alignItems: 'center', justifyContent: 'center' },
  scroll:      { padding: SPACING.xl, gap: 16 },

  tabBar:        { borderBottomWidth: 1, borderBottomColor: COLORS.border, maxHeight: 48 },
  tabBarContent: { paddingHorizontal: SPACING.xl, gap: 4, alignItems: 'center' },
  tab: {
    flexDirection: 'row', alignItems: 'center', gap: 5,
    paddingHorizontal: 14, paddingVertical: 12,
  },
  tabActive:     { borderBottomWidth: 2, borderBottomColor: COLORS.green },
  tabText:       { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.muted2 },
  tabTextActive: { color: COLORS.green },

  card: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.xl,
    borderWidth: 1, borderColor: COLORS.border, padding: SPACING.lg,
  },
  profileCard: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.xl,
    borderWidth: 1, borderColor: COLORS.border,
    padding: SPACING.lg, flexDirection: 'row', alignItems: 'center', gap: 12,
  },
  profileName:       { fontFamily: FONTS.bodySemiBold, fontSize: 16, color: COLORS.text, marginBottom: 2 },
  profileInstrument: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.green, marginBottom: 4 },
  profileCity:       { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2 },
  profileCityEmpty:  { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted, fontStyle: 'italic' },
  statusDot:         { width: 10, height: 10, borderRadius: 5 },
  statsGrid: { flexDirection: 'row', gap: 12, flexWrap: 'wrap' },
  statCard: {
    flex: 1, minWidth: '45%', backgroundColor: COLORS.card, borderRadius: RADIUS.xl,
    borderWidth: 1, borderColor: COLORS.border, padding: SPACING.lg,
    alignItems: 'center',
  },
  statVal:   { fontFamily: FONTS.title, fontSize: 22, color: COLORS.green, marginBottom: 4 },
  statLabel: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.muted2, textAlign: 'center' },
  statSub:   { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted, marginTop: 2 },

  sectionTitle: {
    fontFamily: FONTS.bodySemiBold, fontSize: 11, color: COLORS.muted2,
    textTransform: 'uppercase', letterSpacing: 1, marginBottom: 14,
  },
  row2:      { flexDirection: 'row', justifyContent: 'space-between', paddingVertical: 7, borderBottomWidth: 1, borderBottomColor: COLORS.border },
  row2Label: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2 },
  row2Val:   { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.text },

  progressBg:   { height: 6, backgroundColor: COLORS.border, borderRadius: 3, overflow: 'hidden', marginVertical: 6 },
  progressFill: { height: '100%', borderRadius: 3 },

  rankRow:   { flexDirection: 'row', alignItems: 'center', gap: 12, paddingVertical: 8, borderBottomWidth: 1, borderBottomColor: COLORS.border },
  rankNum:   { fontFamily: FONTS.title, fontSize: 18, color: COLORS.muted, width: 24, textAlign: 'center' },
  rankLabel: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.text },
  rankSub:   { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted2 },
  rankVal:   { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.muted2 },

  ratingHero:  { alignItems: 'center', paddingVertical: 24 },
  ratingBig:   { fontFamily: FONTS.title, fontSize: 72, color: COLORS.gold },
  ratingStars: { fontSize: 24, color: COLORS.gold, marginBottom: 8 },
  ratingLabel: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2 },

  tagsWrap: { flexDirection: 'row', flexWrap: 'wrap', gap: 8 },
  tag:      { backgroundColor: COLORS.greenMuted, borderRadius: RADIUS.full, paddingHorizontal: 12, paddingVertical: 5, borderWidth: 1, borderColor: COLORS.green },
  tagText:  { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.green },

  earningsHero:   { alignItems: 'center', paddingVertical: 20 },
  earningsAmount: { fontFamily: FONTS.title, fontSize: 48, color: COLORS.green },
  earningsLabel:  { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2, marginTop: 4 },
});
