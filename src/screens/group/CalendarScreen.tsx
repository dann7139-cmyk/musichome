import { ArrowLeft, ChevronLeft, ChevronRight } from 'lucide-react-native';
import React, { useEffect, useRef, useState } from 'react';
import {
  Alert,
  Modal,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { supabase } from '../../config/supabase';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';
import Particles from '../../components/ui/Particles';
import Badge from '../../components/ui/Badge';

const DAYS = ['Dom', 'Lun', 'Mar', 'Mié', 'Jue', 'Vie', 'Sáb'];
const MONTHS = [
  'Enero','Febrero','Marzo','Abril','Mayo','Junio',
  'Julio','Agosto','Septiembre','Octubre','Noviembre','Diciembre'
];

const STATUS_MAP: Record<string, { label: string; variant: any }> = {
  pending:     { label: 'Pendiente',  variant: 'orange' },
  confirmed:   { label: 'Confirmada', variant: 'green' },
  in_progress: { label: 'En curso',   variant: 'blue' },
  completed:   { label: 'Completada', variant: 'muted' },
  cancelled:   { label: 'Cancelada',  variant: 'red' },
};

function toDateStr(year: number, month: number, day: number) {
  return `${year}-${String(month + 1).padStart(2, '0')}-${String(day).padStart(2, '0')}`;
}

export default function GroupCalendarScreen({ navigation }: any) {
  const today = new Date();
  const [year, setYear] = useState(today.getFullYear());
  const [month, setMonth] = useState(today.getMonth());
  const [blockedDates, setBlockedDates] = useState<Set<string>>(new Set());
  const [reservedMap, setReservedMap] = useState<Record<string, any>>({});
  const [saving, setSaving] = useState(false);
  const [selectedRes, setSelectedRes] = useState<any>(null);
  const groupIdRef = useRef<string | null>(null);

  useEffect(() => { fetchData(); }, []);

  const fetchData = async () => {
    const { data: sessionData } = await supabase.auth.getSession();
    if (!sessionData.session) return;

    const { data: grp } = await supabase
      .from('groups')
      .select('id')
      .eq('owner_id', sessionData.session.user.id)
      .single();

    if (!grp) return;
    groupIdRef.current = grp.id;

    // Fechas bloqueadas manualmente
    const { data: unavData } = await supabase
      .from('group_unavailability')
      .select('blocked_date')
      .eq('group_id', grp.id);
    if (unavData) setBlockedDates(new Set(unavData.map((d: any) => d.blocked_date)));

    // Reservaciones activas
    const { data: resData } = await supabase
      .from('reservations')
      .select('event_date, status, group_earnings, event_time, address, client_id, package:packages(name, duration_hours)')
      .eq('group_id', grp.id)
      .in('status', ['pending', 'confirmed', 'in_progress']);

    if (resData) {
      // Fetch client names separately
      const clientIds = [...new Set(resData.map((r: any) => r.client_id).filter(Boolean))];
      let clientMap: Record<string, { full_name: string }> = {};
      if (clientIds.length > 0) {
        const { data: clients } = await supabase
          .from('profiles').select('id, full_name').in('id', clientIds);
        if (clients) clients.forEach((c: any) => { clientMap[c.id] = { full_name: c.full_name }; });
      }

      const map: Record<string, any> = {};
      resData.forEach((r: any) => {
        if (r.event_date) map[r.event_date] = { ...r, client: clientMap[r.client_id] ?? null };
      });
      setReservedMap(map);
    }
  };

  const prevMonth = () => {
    if (month === 0) { setMonth(11); setYear(y => y - 1); }
    else setMonth(m => m - 1);
  };

  const nextMonth = () => {
    if (month === 11) { setMonth(0); setYear(y => y + 1); }
    else setMonth(m => m + 1);
  };

  const handleDayPress = async (day: number, isPast: boolean) => {
    const dateStr = toDateStr(year, month, day);

    // Si hay reserva ese día → mostrar info
    if (reservedMap[dateStr]) { setSelectedRes(reservedMap[dateStr]); return; }

    if (isPast) return;

    const gid = groupIdRef.current;
    if (!gid) { Alert.alert('Error', 'No se encontró tu grupo. Sal y vuelve a entrar.'); return; }

    // Actualización optimista
    const newSet = new Set(blockedDates);
    const wasBlocked = newSet.has(dateStr);
    if (wasBlocked) { newSet.delete(dateStr); } else { newSet.add(dateStr); }
    setBlockedDates(newSet);

    setSaving(true);
    const { error: dbError } = wasBlocked
      ? await supabase.from('group_unavailability').delete().eq('group_id', gid).eq('date', dateStr)
      : await supabase.from('group_unavailability').insert([{ group_id: gid, date: dateStr }]);
    setSaving(false);

    if (dbError) {
      setBlockedDates(new Set(blockedDates)); // revert
      Alert.alert('Error al guardar', dbError.message ?? 'No se pudo guardar.');
    }
  };

  const firstDay = new Date(year, month, 1).getDay();
  const daysInMonth = new Date(year, month + 1, 0).getDate();
  const todayStr = toDateStr(today.getFullYear(), today.getMonth(), today.getDate());

  const cells: (number | null)[] = [];
  for (let i = 0; i < firstDay; i++) cells.push(null);
  for (let d = 1; d <= daysInMonth; d++) cells.push(d);

  const blockedThisMonth = Array.from(blockedDates)
    .filter(d => d.startsWith(`${year}-${String(month + 1).padStart(2, '0')}-`)).sort();

  const reservedThisMonth = Object.keys(reservedMap)
    .filter(d => d.startsWith(`${year}-${String(month + 1).padStart(2, '0')}-`)).sort();

  return (
    <View style={styles.container}>
      <Particles />
      <SafeAreaView style={{ flex: 1 }}>
        <View style={styles.header}>
          <Pressable style={styles.backBtn} onPress={() => navigation.goBack()}>
            <ArrowLeft size={20} color={COLORS.text} />
          </Pressable>
          <Text style={styles.headerTitle}>Mi Disponibilidad</Text>
          <View style={{ width: 40 }} />
        </View>

        <ScrollView showsVerticalScrollIndicator={false}>
          {/* LEYENDA */}
          <View style={styles.legend}>
            <View style={styles.legendItem}><View style={[styles.legendDot, { backgroundColor: COLORS.green }]} /><Text style={styles.legendText}>Libre</Text></View>
            <View style={styles.legendItem}><View style={[styles.legendDot, { backgroundColor: COLORS.gold }]} /><Text style={styles.legendText}>Reservado</Text></View>
            <View style={styles.legendItem}><View style={[styles.legendDot, { backgroundColor: COLORS.red }]} /><Text style={styles.legendText}>No disponible</Text></View>
            <View style={styles.legendItem}><View style={[styles.legendDot, { backgroundColor: COLORS.muted }]} /><Text style={styles.legendText}>Pasado</Text></View>
          </View>

          <Text style={styles.hint}>Toca un día libre para bloquearlo · Toca un reservado para ver detalles</Text>

          {/* NAVEGACIÓN MES */}
          <View style={styles.monthNav}>
            <Pressable style={styles.navBtn} onPress={prevMonth}><ChevronLeft size={20} color={COLORS.text} /></Pressable>
            <Text style={styles.monthTitle}>{MONTHS[month]} {year}</Text>
            <Pressable style={styles.navBtn} onPress={nextMonth}><ChevronRight size={20} color={COLORS.text} /></Pressable>
          </View>

          {/* DÍAS */}
          <View style={styles.weekRow}>
            {DAYS.map(d => <Text key={d} style={styles.weekDay}>{d}</Text>)}
          </View>

          {/* GRID */}
          <View style={styles.grid}>
            {cells.map((day, i) => {
              if (!day) return <View key={`e-${i}`} style={styles.cell} />;
              const dateStr = toDateStr(year, month, day);
              const isPast = dateStr < todayStr;
              const isToday = dateStr === todayStr;
              const isBlocked = blockedDates.has(dateStr);
              const isReserved = !!reservedMap[dateStr];
              return (
                <Pressable
                  key={dateStr}
                  style={[
                    styles.cell,
                    isReserved && styles.cellReserved,
                    isBlocked && !isReserved && styles.cellBlocked,
                    isToday && !isBlocked && !isReserved && styles.cellToday,
                    isPast && !isReserved && styles.cellPast,
                  ]}
                  onPress={() => handleDayPress(day, isPast && !isReserved)}
                >
                  <Text style={[
                    styles.cellText,
                    isReserved && styles.cellTextReserved,
                    isBlocked && !isReserved && styles.cellTextBlocked,
                    isToday && !isBlocked && !isReserved && styles.cellTextToday,
                    isPast && !isReserved && styles.cellTextPast,
                  ]}>
                    {day}
                  </Text>
                  {isReserved && <View style={styles.reservedDot} />}
                </Pressable>
              );
            })}
          </View>

          {/* RESERVAS DEL MES */}
          {reservedThisMonth.length > 0 && (
            <View style={styles.section}>
              <Text style={styles.listTitle}>Eventos en {MONTHS[month]}</Text>
              {reservedThisMonth.map(d => {
                const r = reservedMap[d];
                const s = STATUS_MAP[r.status] ?? STATUS_MAP.pending;
                const dayNum = parseInt(d.split('-')[2]);
                const dow = new Date(d + 'T12:00:00').getDay();
                return (
                  <Pressable key={d} style={styles.resRow} onPress={() => setSelectedRes(r)}>
                    <View style={styles.resDateBox}>
                      <Text style={styles.resDay}>{dayNum}</Text>
                      <Text style={styles.resDow}>{DAYS[dow]}</Text>
                    </View>
                    <View style={styles.resInfo}>
                      <Text style={styles.resClient}>{r.client?.full_name ?? 'Cliente'}</Text>
                      <Text style={styles.resPkg}>{r.package?.name ?? '—'}</Text>
                      {r.event_time && <Text style={styles.resMeta}>{r.event_time}</Text>}
                    </View>
                    <Badge label={s.label} variant={s.variant} />
                  </Pressable>
                );
              })}
            </View>
          )}

          {/* DÍAS BLOQUEADOS */}
          {blockedThisMonth.length > 0 && (
            <View style={styles.section}>
              <Text style={styles.listTitle}>Días no disponibles en {MONTHS[month]}</Text>
              <View style={styles.blockedChips}>
                {blockedThisMonth.map(d => {
                  const day = parseInt(d.split('-')[2]);
                  const dow = new Date(d + 'T12:00:00').getDay();
                  return (
                    <Pressable key={d} style={styles.blockedChip} onPress={() => handleDayPress(day, false)}>
                      <Text style={styles.blockedChipText}>{DAYS[dow]} {day}</Text>
                      <Text style={styles.blockedChipX}>✕</Text>
                    </Pressable>
                  );
                })}
              </View>
            </View>
          )}

          {saving && <Text style={styles.savingText}>Guardando...</Text>}
        </ScrollView>
      </SafeAreaView>

      {/* MODAL detalle reserva */}
      <Modal visible={!!selectedRes} transparent animationType="slide" onRequestClose={() => setSelectedRes(null)}>
        <Pressable style={styles.overlay} onPress={() => setSelectedRes(null)}>
          <Pressable style={styles.sheet} onPress={e => e.stopPropagation()}>
            {selectedRes && (() => {
              const r = selectedRes;
              const s = STATUS_MAP[r.status] ?? STATUS_MAP.pending;
              return (
                <>
                  <View style={styles.handle} />
                  <View style={styles.sheetHeaderRow}>
                    <Text style={styles.sheetTitle}>Detalle de reserva</Text>
                    <Badge label={s.label} variant={s.variant} dot />
                  </View>
                  <DetailRow label="Cliente" value={r.client?.full_name ?? '—'} />
                  <DetailRow label="Paquete" value={`${r.package?.name ?? '—'}${r.package?.duration_hours ? ` · ${r.package.duration_hours}h` : ''}`} />
                  <DetailRow label="Fecha" value={r.event_date ?? '—'} />
                  {r.event_time && <DetailRow label="Hora" value={r.event_time} />}
                  {r.address && <DetailRow label="Lugar" value={r.address} />}
                  <View style={styles.earningsRow}>
                    <Text style={styles.detailLabel}>Tu ganancia</Text>
                    <Text style={styles.earningsValue}>${r.group_earnings?.toLocaleString() ?? '—'}</Text>
                  </View>
                  <Pressable style={styles.closeBtn} onPress={() => setSelectedRes(null)}>
                    <Text style={styles.closeBtnText}>Cerrar</Text>
                  </Pressable>
                </>
              );
            })()}
          </Pressable>
        </Pressable>
      </Modal>
    </View>
  );
}

function DetailRow({ label, value }: { label: string; value: string }) {
  return (
    <View style={styles.detailRow}>
      <Text style={styles.detailLabel}>{label}</Text>
      <Text style={styles.detailValue}>{value}</Text>
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
  legend: { flexDirection: 'row', justifyContent: 'center', gap: 12, paddingVertical: 12, flexWrap: 'wrap' },
  legendItem: { flexDirection: 'row', alignItems: 'center', gap: 5 },
  legendDot: { width: 9, height: 9, borderRadius: 5 },
  legendText: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted2 },
  hint: { textAlign: 'center', fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted, marginBottom: 6, paddingHorizontal: SPACING.xl },
  monthNav: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between',
    paddingHorizontal: SPACING.xl, paddingVertical: 12,
  },
  navBtn: {
    width: 36, height: 36, borderRadius: 10,
    backgroundColor: COLORS.card, borderWidth: 1, borderColor: COLORS.border,
    alignItems: 'center', justifyContent: 'center',
  },
  monthTitle: { fontFamily: FONTS.title, fontSize: 18, color: COLORS.text },
  weekRow: { flexDirection: 'row', paddingHorizontal: SPACING.xl, marginBottom: 4 },
  weekDay: { flex: 1, textAlign: 'center', fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.muted2 },
  grid: { flexDirection: 'row', flexWrap: 'wrap', paddingHorizontal: SPACING.xl },
  cell: {
    width: `${100 / 7}%`, aspectRatio: 1,
    alignItems: 'center', justifyContent: 'center',
    borderRadius: 10, marginVertical: 2,
  },
  cellBlocked: { backgroundColor: 'rgba(239,83,80,0.15)', borderWidth: 1, borderColor: COLORS.red },
  cellReserved: { backgroundColor: 'rgba(255,179,0,0.15)', borderWidth: 1.5, borderColor: COLORS.gold },
  cellToday: { backgroundColor: COLORS.greenMuted, borderWidth: 1.5, borderColor: COLORS.green },
  cellPast: { opacity: 0.3 },
  cellText: { fontFamily: FONTS.bodyMedium, fontSize: 14, color: COLORS.text },
  cellTextBlocked: { color: COLORS.red },
  cellTextReserved: { color: COLORS.gold, fontFamily: FONTS.bodySemiBold },
  cellTextToday: { color: COLORS.green },
  cellTextPast: { color: COLORS.muted },
  reservedDot: {
    width: 4, height: 4, borderRadius: 2,
    backgroundColor: COLORS.gold, position: 'absolute', bottom: 4,
  },
  section: { marginHorizontal: SPACING.xl, marginTop: 16, marginBottom: 8 },
  listTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.muted2, marginBottom: 10 },
  resRow: {
    flexDirection: 'row', alignItems: 'center', gap: 12,
    backgroundColor: COLORS.card, borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: 'rgba(255,179,0,0.3)',
    padding: 12, marginBottom: 8,
  },
  resDateBox: {
    width: 40, alignItems: 'center',
    backgroundColor: 'rgba(255,179,0,0.12)',
    borderRadius: 8, paddingVertical: 6,
  },
  resDay: { fontFamily: FONTS.title, fontSize: 18, color: COLORS.gold },
  resDow: { fontFamily: FONTS.body, fontSize: 10, color: COLORS.gold },
  resInfo: { flex: 1 },
  resClient: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.text, marginBottom: 2 },
  resPkg: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2 },
  resMeta: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted, marginTop: 2 },
  blockedChips: { flexDirection: 'row', flexWrap: 'wrap', gap: 8 },
  blockedChip: {
    flexDirection: 'row', alignItems: 'center', gap: 6,
    backgroundColor: 'rgba(239,83,80,0.1)', borderRadius: RADIUS.full,
    borderWidth: 1, borderColor: COLORS.red, paddingHorizontal: 12, paddingVertical: 6,
  },
  blockedChipText: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.red },
  blockedChipX: { fontSize: 11, color: COLORS.red },
  savingText: { textAlign: 'center', fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, padding: 8 },
  // Modal
  overlay: { flex: 1, backgroundColor: 'rgba(0,0,0,0.55)', justifyContent: 'flex-end' },
  sheet: {
    backgroundColor: COLORS.card, borderTopLeftRadius: 24, borderTopRightRadius: 24,
    padding: SPACING.xl, paddingBottom: 40,
  },
  handle: {
    width: 36, height: 4, borderRadius: 2,
    backgroundColor: COLORS.border, alignSelf: 'center', marginBottom: 20,
  },
  sheetHeaderRow: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center', marginBottom: 20 },
  sheetTitle: { fontFamily: FONTS.title, fontSize: 20, color: COLORS.text },
  detailRow: {
    flexDirection: 'row', justifyContent: 'space-between',
    paddingVertical: 11, borderBottomWidth: 1, borderBottomColor: COLORS.border,
  },
  detailLabel: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2 },
  detailValue: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.text, flex: 1, textAlign: 'right', marginLeft: 12 },
  earningsRow: {
    flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center',
    paddingVertical: 14,
  },
  earningsValue: { fontFamily: FONTS.title, fontSize: 22, color: COLORS.green },
  closeBtn: {
    backgroundColor: COLORS.card2, borderRadius: RADIUS.lg,
    paddingVertical: 14, alignItems: 'center',
    borderWidth: 1, borderColor: COLORS.border,
  },
  closeBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.text },
});
