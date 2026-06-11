/**
 * TimePickerModal — Modal con drum-roll para elegir hora y minutos.
 * Props:
 *   visible    – controla si está abierto
 *   value      – string "HH:MM" inicial (o '' para 00:00)
 *   onConfirm  – callback con string "HH:MM"
 *   onClose    – callback al cerrar sin confirmar
 *   title      – texto del encabezado (opcional)
 */
import React, { useEffect, useState } from 'react';
import { Modal, Pressable, StyleSheet, Text, View } from 'react-native';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';
import ScrollPicker from './ScrollPicker';

// ── Listas de opciones ────────────────────────────────────────────────────────

const HOURS    = Array.from({ length: 12 }, (_, i) => String(i + 1).padStart(2, '0')); // 01–12
const MINUTES  = ['00', '05', '10', '15', '20', '25', '30', '35', '40', '45', '50', '55'];
const MERIDIEM = ['AM', 'PM'];

// ── Parse / build ─────────────────────────────────────────────────────────────

const parseValue = (val: string): { hIdx: number; mIdx: number; merIdx: number } => {
  const [hStr, mStr] = (val || '08:00').split(':');
  const h24    = parseInt(hStr) || 8;
  const m      = parseInt(mStr) || 0;
  const merIdx = h24 >= 12 ? 1 : 0;           // 0 = AM, 1 = PM
  let h12 = h24 % 12;
  if (h12 === 0) h12 = 12;                    // 0h → 12 AM, 12h → 12 PM
  const hIdx = h12 - 1;                       // 01-12 → index 0-11
  const mIdx = Math.max(0, Math.min(Math.round(m / 5), MINUTES.length - 1));
  return { hIdx, mIdx, merIdx };
};

// ── Component ─────────────────────────────────────────────────────────────────

interface Props {
  visible:   boolean;
  value?:    string;
  title?:    string;
  onConfirm: (time: string) => void;
  onClose:   () => void;
}

export default function TimePickerModal({ visible, value = '00:00', title = 'Seleccionar hora', onConfirm, onClose }: Props) {
  const [hIdx, setHIdx] = useState(7);     // default: 08 AM
  const [mIdx, setMIdx] = useState(0);
  const [merIdx, setMerIdx] = useState(0); // 0 = AM, 1 = PM

  // Inicializar cuando se abre el modal
  useEffect(() => {
    if (visible) {
      const parsed = parseValue(value);
      setHIdx(parsed.hIdx);
      setMIdx(parsed.mIdx);
      setMerIdx(parsed.merIdx);
    }
  }, [visible, value]);

  const confirm = () => {
    const h12 = parseInt(HOURS[hIdx]);
    const mer = MERIDIEM[merIdx];
    let h24: number;
    if (mer === 'AM') {
      h24 = h12 === 12 ? 0 : h12;
    } else {
      h24 = h12 === 12 ? 12 : h12 + 12;
    }
    onConfirm(`${String(h24).padStart(2, '0')}:${MINUTES[mIdx]}`);
  };

  return (
    <Modal visible={visible} transparent animationType="slide" onRequestClose={onClose}>
      <View style={s.overlay}>
        {/* Backdrop: solo el área vacía cierra el modal */}
        <Pressable style={{ flex: 1 }} onPress={onClose} />
        <View style={s.sheet}>
          {/* Handle */}
          <View style={s.handle} />

          {/* Título */}
          <Text style={s.title}>{title}</Text>

          {/* Pickers row */}
          <View style={s.pickersRow}>
            {/* Horas */}
            <View style={s.pickerCol}>
              <Text style={s.colLabel}>Hora</Text>
              <ScrollPicker
                items={HOURS}
                selectedIndex={hIdx}
                onSelect={setHIdx}
                width={80}
              />
            </View>

            {/* Separador */}
            <Text style={s.colon}>:</Text>

            {/* Minutos */}
            <View style={s.pickerCol}>
              <Text style={s.colLabel}>Min</Text>
              <ScrollPicker
                items={MINUTES}
                selectedIndex={mIdx}
                onSelect={setMIdx}
                width={80}
              />
            </View>

            {/* AM / PM */}
            <View style={[s.pickerCol, { marginLeft: 12 }]}>
              <Text style={s.colLabel}>AM/PM</Text>
              <ScrollPicker
                items={MERIDIEM}
                selectedIndex={merIdx}
                onSelect={setMerIdx}
                width={70}
              />
            </View>
          </View>

          {/* Preview */}
          <View style={s.preview}>
            <Text style={s.previewTime}>{HOURS[hIdx]}:{MINUTES[mIdx]}</Text>
            <Text style={s.previewLabel}>{MERIDIEM[merIdx]}</Text>
          </View>

          {/* Botones */}
          <View style={s.btnRow}>
            <Pressable style={s.cancelBtn} onPress={onClose}>
              <Text style={s.cancelText}>Cancelar</Text>
            </Pressable>
            <Pressable style={s.confirmBtn} onPress={confirm}>
              <Text style={s.confirmText}>Confirmar</Text>
            </Pressable>
          </View>
        </View>
      </View>
    </Modal>
  );
}

// ── Styles ────────────────────────────────────────────────────────────────────

const s = StyleSheet.create({
  overlay: {
    flex: 1,
    backgroundColor: 'rgba(0,0,0,0.65)',
    flexDirection: 'column',
  },
  sheet: {
    backgroundColor: '#111',
    borderTopLeftRadius: 28,
    borderTopRightRadius: 28,
    paddingHorizontal: SPACING.xl,
    paddingBottom: 40,
    paddingTop: 16,
    borderTopWidth: 1,
    borderColor: 'rgba(0,230,118,0.15)',
  },
  handle: {
    width: 44, height: 4, borderRadius: 2,
    backgroundColor: 'rgba(255,255,255,0.15)',
    alignSelf: 'center', marginBottom: 20,
  },
  title: {
    fontFamily: FONTS.title,
    fontSize: 20,
    color: COLORS.text,
    textAlign: 'center',
    marginBottom: 24,
  },

  // Pickers
  pickersRow: {
    flexDirection: 'row',
    justifyContent: 'center',
    alignItems: 'center',
    gap: 0,
  },
  pickerCol: { alignItems: 'center', gap: 8 },
  colLabel: {
    fontFamily: FONTS.bodyMedium,
    fontSize: 11,
    color: COLORS.muted,
    letterSpacing: 1.5,
    textTransform: 'uppercase',
  },
  colon: {
    fontFamily: FONTS.title,
    fontSize: 36,
    color: COLORS.green,
    marginHorizontal: 8,
    marginTop: 26,
    opacity: 0.7,
  },

  // Preview de la hora seleccionada
  preview: {
    flexDirection: 'row',
    justifyContent: 'center',
    alignItems: 'baseline',
    gap: 6,
    marginTop: 20,
    marginBottom: 24,
  },
  previewTime: {
    fontFamily: FONTS.title,
    fontSize: 48,
    color: COLORS.green,
    letterSpacing: 2,
  },
  previewLabel: {
    fontFamily: FONTS.bodyMedium,
    fontSize: 16,
    color: COLORS.muted2,
  },

  // Botones
  btnRow: { flexDirection: 'row', gap: 12 },
  cancelBtn: {
    flex: 1, paddingVertical: 15, borderRadius: RADIUS.md,
    backgroundColor: 'rgba(255,255,255,0.06)',
    borderWidth: 1, borderColor: COLORS.border,
    alignItems: 'center',
  },
  cancelText: { fontFamily: FONTS.bodyMedium, fontSize: 15, color: COLORS.muted2 },
  confirmBtn: {
    flex: 2, paddingVertical: 15, borderRadius: RADIUS.md,
    backgroundColor: COLORS.green,
    alignItems: 'center',
  },
  confirmText: { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: '#000' },
});
