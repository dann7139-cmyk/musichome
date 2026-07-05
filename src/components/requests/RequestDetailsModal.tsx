/**
 * RequestDetailsModal — detalle completo de cómo pidió el cliente el
 * evento (tipo, fecha/hora, duración, invitados, lugar, techado, tamaño,
 * sonido, comentarios). El grupo puede cerrar para volver a la tarjeta
 * o cotizar directo desde adentro.
 *
 * La dirección exacta NUNCA se muestra aquí (solo ciudad/municipio) —
 * se revela al confirmar el pago, como en el resto del flujo.
 */
import React from 'react';
import {
  Modal,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import { X, Zap } from 'lucide-react-native';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';
import { EVENT_LABELS } from './RequestZoneMap';

export interface RequestDetailsData {
  event_type?: string | null;
  genre?: string | null;
  event_date?: string | null;
  event_time?: string | null;
  hours?: number | null;
  guest_count?: number | null;
  location_city?: string | null;
  location_municipio?: string | null;
  location_estado?: string | null;
  venue_covered?: string | null;
  venue_size?: string | null;
  needs_sound?: string | null;
  comments?: string | null;
}

interface Props {
  request:    RequestDetailsData | null;   // null = cerrado
  onClose:    () => void;
  onCotizar?: () => void;                  // omitir para ocultar el botón (p.ej. bloqueado)
}

const VENUE_COVERED_LABELS: Record<string, string> = {
  si:    'Techado',
  no:    'Al aire libre',
  no_se: 'Por confirmar',
};

const VENUE_SIZE_LABELS: Record<string, string> = {
  patio_pequeno: 'Patio pequeño',
  salon_mediano: 'Salón mediano',
  salon_grande:  'Salón grande',
  jardin:        'Jardín / terreno',
  otro:          'Otro',
};

const NEEDS_SOUND_LABELS: Record<string, string> = {
  si:       'Necesita sonido del grupo',
  no:       'No necesita sonido',
  ya_tengo: 'El cliente ya tiene sonido',
};

function fmtLongDate(d: string): string {
  return new Date(d + 'T12:00:00').toLocaleDateString('es-MX', {
    weekday: 'long', day: 'numeric', month: 'long', year: 'numeric',
  });
}

function fmtTime12h(t: string): string {
  const [hStr, mStr] = t.split(':');
  const h = parseInt(hStr, 10);
  return `${h % 12 || 12}:${mStr} ${h >= 12 ? 'PM' : 'AM'}`;
}

function Row({ label, value }: { label: string; value: string }) {
  return (
    <View style={s.row}>
      <Text style={s.rowLabel}>{label}</Text>
      <Text style={s.rowValue}>{value}</Text>
    </View>
  );
}

export default function RequestDetailsModal({ request: req, onClose, onCotizar }: Props) {
  if (!req) return null;

  return (
    <Modal visible={!!req} transparent animationType="slide" onRequestClose={onClose}>
      <View style={s.overlay}>
        <View style={s.sheet}>
          <View style={s.header}>
            <View style={{ flex: 1 }}>
              <Text style={s.title}>
                {EVENT_LABELS[req.event_type ?? ''] ?? 'Evento'}
              </Text>
              <Text style={s.sub}>Así lo pidió el cliente</Text>
            </View>
            <Pressable style={s.closeBtn} onPress={onClose}>
              <X size={18} color={COLORS.text} />
            </Pressable>
          </View>

          <ScrollView style={{ maxHeight: 420 }} contentContainerStyle={s.bodyWrap}>
            {req.genre ? <Row label="Género" value={req.genre} /> : null}
            {req.event_date ? <Row label="Fecha" value={fmtLongDate(req.event_date)} /> : null}
            <Row label="Hora" value={req.event_time ? fmtTime12h(req.event_time) : 'A confirmar'} />
            {req.hours != null ? <Row label="Duración" value={`${req.hours} horas de servicio`} /> : null}
            {req.guest_count != null ? <Row label="Invitados" value={`~${req.guest_count} personas`} /> : null}
            <Row
              label="Zona"
              value={[req.location_city, req.location_municipio, req.location_estado].filter(Boolean).join(', ')}
            />
            {req.venue_covered ? <Row label="Lugar" value={VENUE_COVERED_LABELS[req.venue_covered] ?? req.venue_covered} /> : null}
            {req.venue_size ? <Row label="Tamaño" value={VENUE_SIZE_LABELS[req.venue_size] ?? req.venue_size} /> : null}
            {req.needs_sound ? <Row label="Sonido" value={NEEDS_SOUND_LABELS[req.needs_sound] ?? req.needs_sound} /> : null}

            {req.comments ? (
              <View style={s.commentsBox}>
                <Text style={s.commentsLabel}>💬 Comentarios del cliente</Text>
                <Text style={s.commentsTx}>{req.comments}</Text>
              </View>
            ) : null}

            <Text style={s.addressNote}>🔒 Dirección exacta visible al confirmar pago</Text>
          </ScrollView>

          <View style={s.footer}>
            <Pressable style={s.backBtn} onPress={onClose}>
              <Text style={s.backBtnTx}>Volver</Text>
            </Pressable>
            {onCotizar && (
              <Pressable
                style={({ pressed }) => [s.cotizarBtn, pressed && { opacity: 0.82 }]}
                onPress={onCotizar}
              >
                <Zap size={14} color={COLORS.bg} />
                <Text style={s.cotizarBtnTx}>Cotizar</Text>
              </Pressable>
            )}
          </View>
        </View>
      </View>
    </Modal>
  );
}

const s = StyleSheet.create({
  overlay: { flex: 1, backgroundColor: 'rgba(0,0,0,0.75)', justifyContent: 'flex-end' },
  sheet: {
    backgroundColor: COLORS.card,
    borderTopLeftRadius: 24, borderTopRightRadius: 24,
    borderTopWidth: 1, borderTopColor: COLORS.border,
    paddingBottom: 28,
  },

  header: {
    flexDirection: 'row', alignItems: 'center', gap: 12,
    paddingHorizontal: SPACING.xl, paddingVertical: 16,
    borderBottomWidth: 1, borderBottomColor: COLORS.border,
  },
  title: { fontFamily: FONTS.title, fontSize: 18, color: COLORS.text },
  sub:   { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, marginTop: 2 },
  closeBtn: {
    width: 36, height: 36, borderRadius: 10,
    backgroundColor: COLORS.bg, borderWidth: 1, borderColor: COLORS.border,
    alignItems: 'center', justifyContent: 'center',
  },

  bodyWrap: { paddingHorizontal: SPACING.xl, paddingVertical: 14, gap: 2 },
  row: {
    flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center', gap: 12,
    paddingVertical: 9,
    borderBottomWidth: 1, borderBottomColor: 'rgba(255,255,255,0.05)',
  },
  rowLabel: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted },
  rowValue: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.text, flex: 1, textAlign: 'right' },

  commentsBox: {
    marginTop: 12,
    backgroundColor: COLORS.bg, borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: COLORS.border,
    padding: 12, gap: 6,
  },
  commentsLabel: { fontFamily: FONTS.bodySemiBold, fontSize: 12, color: COLORS.muted2 },
  commentsTx:    { fontFamily: FONTS.body, fontSize: 13, color: COLORS.text, lineHeight: 20 },

  addressNote: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted, textAlign: 'center', marginTop: 14 },

  footer: {
    flexDirection: 'row', gap: 10,
    paddingHorizontal: SPACING.xl, paddingTop: 12,
    borderTopWidth: 1, borderTopColor: COLORS.border,
  },
  backBtn: {
    flex: 0.42, alignItems: 'center', justifyContent: 'center',
    backgroundColor: COLORS.bg, borderWidth: 1, borderColor: COLORS.border,
    borderRadius: RADIUS.lg, paddingVertical: 13,
  },
  backBtnTx: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.muted2 },
  cotizarBtn: {
    flex: 1, flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 6,
    backgroundColor: COLORS.green, borderRadius: RADIUS.lg, paddingVertical: 13,
  },
  cotizarBtnTx: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.bg },
});
