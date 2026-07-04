import { ArrowLeft, CalendarOff, Plus, Trash2, X } from 'lucide-react-native';
import React, { useCallback, useEffect, useState } from 'react';
import {
  ActivityIndicator,
  Alert,
  Modal,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  View,
} from 'react-native';
import { Calendar } from 'react-native-calendars';
import { SafeAreaView } from 'react-native-safe-area-context';
import { supabase } from '../../config/supabase';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';
import Particles from '../../components/ui/Particles';

interface BlockedDate {
  id: string;
  date: string;          // columna real de group_unavailability
  reason: string | null; // agregada en sql/430
}

export default function GroupAvailabilityScreen({ navigation }: any) {
  const [groupId, setGroupId] = useState<string | null>(null);
  const [blockedDates, setBlockedDates] = useState<BlockedDate[]>([]);
  const [markedDates, setMarkedDates] = useState<any>({});
  const [loading, setLoading] = useState(true);
  const [modalVisible, setModalVisible] = useState(false);
  const [selectedDate, setSelectedDate] = useState('');
  const [reason, setReason] = useState('');
  const [saving, setSaving] = useState(false);

  useEffect(() => { fetchGroup(); }, []);

  useEffect(() => {
    const unsubscribe = navigation.addListener('focus', () => {
      if (groupId) {
        fetchBlockedDates(groupId);
      } else {
        fetchGroup();
      }
    });
    return unsubscribe;
  }, [navigation, groupId]);

  const fetchGroup = async () => {
    const { data: sessionData } = await supabase.auth.getSession();
    if (!sessionData.session) return;

    const { data: grp } = await supabase
      .from('groups')
      .select('id')
      .eq('owner_id', sessionData.session.user.id)
      .limit(1)
      .maybeSingle();  // .single() truena si el owner tiene >1 grupo

    if (grp) {
      setGroupId(grp.id);
      await fetchBlockedDates(grp.id);
    }
    setLoading(false);
  };

  const fetchBlockedDates = async (gid: string) => {
    const { data, error } = await supabase
      .from('group_unavailability')
      .select('*')
      .eq('group_id', gid)
      .order('date', { ascending: true });

    if (error) {
      // Visible: si esto falla en silencio, el calendario pinta TODO libre y miente
      console.log('Error fetching blocked dates:', error.message);
      Alert.alert('Error al cargar bloqueos', 'No se pudieron cargar tus fechas bloqueadas. Vuelve a entrar a la pantalla.');
      return;
    }

    setBlockedDates((data ?? []) as BlockedDate[]);
    const marked: any = {};
    (data ?? []).forEach((bd: BlockedDate) => {
      marked[bd.date] = {
        selected: true,
        selectedColor: COLORS.red,
        selectedTextColor: '#fff',
      };
    });
    setMarkedDates(marked);
  };

  const openBlockModal = (dateStr: string) => {
    // Si ya está bloqueada, preguntar si quiere desbloquear
    const existing = blockedDates.find(b => b.date === dateStr);
    if (existing) {
      Alert.alert(
        'Fecha bloqueada',
        `Esta fecha ya está bloqueada.\n\n${existing.reason || 'Sin motivo especificado'}`,
        [
          { text: 'Cancelar', style: 'cancel' },
          { text: 'Desbloquear', style: 'destructive', onPress: () => removeBlock(existing.id) },
        ]
      );
      return;
    }

    setSelectedDate(dateStr);
    setReason('');
    setModalVisible(true);
  };

  const handleBlock = async () => {
    if (!groupId || !selectedDate) return;

    setSaving(true);
    const { error } = await supabase
      .from('group_unavailability')
      .insert([{
        group_id: groupId,
        date: selectedDate,
        reason: reason.trim() || null,
      }]);

    setSaving(false);

    if (error) {
      if ((error as any)?.code === '23505') {
        // Ya estaba bloqueada (p.ej. creada desde CalendarScreen o estado
        // desincronizado) — sincronizar el calendario y ofrecer el toggle
        setModalVisible(false);
        await fetchBlockedDates(groupId);
        Alert.alert(
          'Fecha ya bloqueada',
          `${selectedDate} ya estaba bloqueada. ¿Quieres desbloquearla?`,
          [
            { text: 'Dejarla bloqueada', style: 'cancel' },
            {
              text: 'Desbloquear',
              style: 'destructive',
              onPress: async () => {
                const { data: row } = await supabase
                  .from('group_unavailability')
                  .select('id')
                  .eq('group_id', groupId)
                  .eq('date', selectedDate)
                  .maybeSingle();
                if (row?.id) await removeBlock(row.id);
              },
            },
          ]
        );
      } else {
        Alert.alert('Error', error.message);
      }
    } else {
      setModalVisible(false);
      await fetchBlockedDates(groupId);
      Alert.alert('✓ Bloqueada', `La fecha ${selectedDate} fue bloqueada correctamente.`);
    }
  };

  const removeBlock = async (blockId: string) => {
    if (!groupId) return;

    const { error } = await supabase
      .from('group_unavailability')
      .delete()
      .eq('id', blockId);

    if (error) {
      Alert.alert('Error', error.message);
    } else {
      await fetchBlockedDates(groupId);
    }
  };

  if (loading) {
    return (
      <View style={s.container}>
        <Particles />
        <View style={s.center}>
          <ActivityIndicator size="large" color={COLORS.green} />
        </View>
      </View>
    );
  }

  return (
    <View style={s.container}>
      <Particles />
      <SafeAreaView style={{ flex: 1 }}>
        <View style={s.header}>
          <Pressable style={s.backBtn} onPress={() => navigation.goBack()}>
            <ArrowLeft size={20} color={COLORS.text} />
          </Pressable>
          <Text style={s.headerTitle}>Disponibilidad</Text>
          <View style={{ width: 40 }} />
        </View>

        <ScrollView showsVerticalScrollIndicator={false}>
          <View style={s.section}>
            <Text style={s.sectionTitle}>Calendario de disponibilidad</Text>
            <Text style={s.hint}>
              Toca una fecha para bloquearla. Las fechas bloqueadas aparecerán en rojo y no estarán disponibles para reservas.
            </Text>

            <View style={s.calendarWrapper}>
              <Calendar
                onDayPress={(day) => openBlockModal(day.dateString)}
                markedDates={markedDates}
                theme={{
                  calendarBackground: COLORS.card,
                  textSectionTitleColor: COLORS.muted,
                  selectedDayBackgroundColor: COLORS.green,
                  selectedDayTextColor: '#fff',
                  todayTextColor: COLORS.green,
                  dayTextColor: COLORS.text,
                  textDisabledColor: COLORS.muted,
                  monthTextColor: COLORS.text,
                  textMonthFontFamily: FONTS.bodySemiBold,
                  textDayFontFamily: FONTS.body,
                  textDayHeaderFontFamily: FONTS.bodyMedium,
                  textDayFontSize: 14,
                  textMonthFontSize: 16,
                  textDayHeaderFontSize: 12,
                  'stylesheet.calendar.header': {
                    week: {
                      marginTop: 10,
                      marginBottom: 7,
                      flexDirection: 'row',
                      justifyContent: 'space-around',
                    },
                  },
                } as any}
                style={s.calendar}
              />
            </View>
          </View>

          {/* Lista de fechas bloqueadas */}
          {blockedDates.length > 0 && (
            <View style={s.section}>
              <Text style={s.sectionTitle}>Fechas bloqueadas ({blockedDates.length})</Text>
              {blockedDates.map((bd) => (
                <View key={bd.id} style={s.blockedRow}>
                  <View style={{ flex: 1 }}>
                    <Text style={s.blockedDate}>{bd.date}</Text>
                    {bd.reason && <Text style={s.blockedReason}>{bd.reason}</Text>}
                  </View>
                  <Pressable
                    style={s.removeBtn}
                    onPress={() => {
                      Alert.alert(
                        'Desbloquear fecha',
                        `¿Desbloquear ${bd.date}?`,
                        [
                          { text: 'Cancelar', style: 'cancel' },
                          { text: 'Desbloquear', style: 'destructive', onPress: () => removeBlock(bd.id) },
                        ]
                      );
                    }}
                  >
                    <Trash2 size={16} color={COLORS.red} />
                  </Pressable>
                </View>
              ))}
            </View>
          )}
        </ScrollView>
      </SafeAreaView>

      {/* Modal para bloquear fecha */}
      <Modal visible={modalVisible} transparent animationType="slide">
        <View style={s.overlay}>
          <View style={s.sheet}>
            <View style={s.sheetHeader}>
              <Text style={s.sheetTitle}>Bloquear fecha</Text>
              <Pressable onPress={() => setModalVisible(false)}>
                <X size={20} color={COLORS.muted2} />
              </Pressable>
            </View>

            <Text style={s.modalDate}>{selectedDate}</Text>

            <Text style={s.label}>Motivo (opcional)</Text>
            <TextInput
              style={s.input}
              value={reason}
              onChangeText={setReason}
              placeholder="Ej: Día festivo, vacaciones..."
              placeholderTextColor={COLORS.muted}
              multiline
              numberOfLines={3}
              textAlignVertical="top"
              maxLength={200}
            />

            <Pressable
              style={[s.saveBtn, saving && { opacity: 0.5 }]}
              onPress={handleBlock}
              disabled={saving}
            >
              {saving
                ? <ActivityIndicator size="small" color={COLORS.bg} />
                : <><CalendarOff size={16} color={COLORS.bg} /><Text style={s.saveBtnText}>Bloquear fecha</Text></>}
            </Pressable>
          </View>
        </View>
      </Modal>
    </View>
  );
}

const s = StyleSheet.create({
  container: { flex: 1, backgroundColor: COLORS.bg },
  center: { flex: 1, alignItems: 'center', justifyContent: 'center' },
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
  section: { padding: SPACING.xl },
  sectionTitle: { fontFamily: FONTS.title, fontSize: 18, color: COLORS.text, marginBottom: 8 },
  hint: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted, lineHeight: 20, marginBottom: 20 },
  calendarWrapper: {
    borderRadius: RADIUS.lg, overflow: 'hidden',
    borderWidth: 1, borderColor: COLORS.border,
  },
  calendar: {
    backgroundColor: COLORS.card,
    paddingBottom: 10,
  },
  blockedRow: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between',
    backgroundColor: COLORS.card, borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: COLORS.border, padding: 14, marginBottom: 10,
  },
  blockedDate: { fontFamily: FONTS.bodyMedium, fontSize: 15, color: COLORS.text, marginBottom: 3 },
  blockedReason: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2 },
  removeBtn: {
    width: 36, height: 36, borderRadius: 8,
    backgroundColor: 'rgba(239,83,80,0.1)', alignItems: 'center', justifyContent: 'center',
  },
  // Modal
  overlay: { flex: 1, backgroundColor: 'rgba(0,0,0,0.7)', justifyContent: 'flex-end' },
  sheet: {
    backgroundColor: COLORS.card, borderTopLeftRadius: 24, borderTopRightRadius: 24,
    padding: SPACING.xl, paddingBottom: 40,
    borderTopWidth: 1, borderColor: COLORS.border,
  },
  sheetHeader: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center', marginBottom: 20 },
  sheetTitle: { fontFamily: FONTS.title, fontSize: 20, color: COLORS.text },
  modalDate: { fontFamily: FONTS.bodySemiBold, fontSize: 16, color: COLORS.green, marginBottom: 16, textAlign: 'center' },
  label: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted2, marginBottom: 8 },
  input: {
    backgroundColor: COLORS.bg, borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: COLORS.border,
    paddingHorizontal: 14, paddingVertical: 12,
    fontFamily: FONTS.body, fontSize: 15, color: COLORS.text,
    height: 80, marginBottom: 20,
  },
  saveBtn: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 10,
    backgroundColor: COLORS.red, borderRadius: RADIUS.lg, paddingVertical: 15,
  },
  saveBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.bg },
});
