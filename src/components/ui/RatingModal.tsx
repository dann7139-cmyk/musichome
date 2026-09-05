/**
 * RatingModal — Modal de calificación post-evento.
 * Usado por cliente (califica grupo), grupo (califica cliente o talento).
 */
import React, { useState } from 'react';
import {
  ActivityIndicator,
  Alert,
  KeyboardAvoidingView,
  Modal,
  Platform,
  Pressable,
  StyleSheet,
  Text,
  TextInput,
  View,
} from 'react-native';
import { Gift as GiftIcon } from 'lucide-react-native';
import { useTranslation } from 'react-i18next';
import { supabase } from '../../config/supabase';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';
import { containsProfanity, PROFANITY_WARNING } from '../../utils/profanityFilter';
import GiftPickerModal from '../gifts/GiftPickerModal';

export type RatingSubject =
  | { type: 'group';   targetId: string; targetName: string; reservationId: string; groupCountry?: string | null }
  | { type: 'client';  targetId: string; targetName: string; reservationId: string }
  | { type: 'talent';  targetId: string; targetName: string; reservationId: string };

export interface ReviewSubmitted {
  stars: number;
  comment: string;
}

interface Props {
  visible: boolean;
  subject: RatingSubject | null;
  onDone: (submitted: ReviewSubmitted | null) => void;
}

const STARS = [1, 2, 3, 4, 5];

const STAR_LABELS: Record<number, string> = {
  1: 'Muy malo',
  2: 'Regular',
  3: 'Bueno',
  4: 'Muy bueno',
  5: 'Excelente',
};

export default function RatingModal({ visible, subject, onDone }: Props) {
  const { t } = useTranslation();
  const [stars,   setStars]   = useState(5);
  const [comment, setComment] = useState('');
  const [loading, setLoading] = useState(false);
  // 🎁 "Dar propina" — solo aplica cuando el cliente califica al grupo.
  const [tipVisible, setTipVisible] = useState(false);

  if (!subject) return null;

  const title = subject.type === 'group'
    ? `¿Cómo estuvo el grupo?`
    : subject.type === 'client'
    ? `¿Cómo fue el cliente?`
    : `¿Cómo se desempeñó el talento?`;

  const subtitle = `Califica a ${subject.targetName}`;

  const handleSubmit = async () => {
    if (containsProfanity(comment)) {
      Alert.alert('Lenguaje no permitido', PROFANITY_WARNING);
      return;
    }

    setLoading(true);
    try {
      let rpcName = '';
      let rpcArgs: Record<string, any> = {
        p_reservation_id: subject.reservationId,
        p_rating: stars,
        p_comment: comment.trim() || null,
      };

      if (subject.type === 'group') {
        rpcName = 'submit_group_review';
      } else if (subject.type === 'client') {
        rpcName = 'submit_client_review';
      } else {
        rpcName = 'submit_talent_review';
        rpcArgs.p_talent_id = subject.targetId;
      }

      const { data, error } = await supabase.rpc(rpcName, rpcArgs);
      if (error) throw error;
      if (data?.ok === false) {
        if (data.error === 'profanity_detected') {
          Alert.alert('Lenguaje no permitido', PROFANITY_WARNING);
          return;
        }
        if (data.error === 'already_reviewed') {
          onDone(null);
          return;
        }
        throw new Error(data.error);
      }
      onDone({ stars, comment: comment.trim() });
    } catch (e: any) {
      Alert.alert('Error', e.message ?? 'No se pudo enviar la calificación.');
    } finally {
      setLoading(false);
    }
  };

  return (
    <Modal visible={visible} transparent animationType="slide">
      <KeyboardAvoidingView
        style={s.backdrop}
        behavior={Platform.OS === 'ios' ? 'padding' : undefined}
      >
        <View style={s.sheet}>
          {/* Header */}
          <Text style={s.title}>{title}</Text>
          <Text style={s.subtitle}>{subtitle}</Text>

          {/* Stars */}
          <View style={s.starsRow}>
            {STARS.map(n => (
              <Pressable key={n} onPress={() => setStars(n)} style={s.starBtn}>
                <Text style={[s.star, n <= stars && s.starActive]}>★</Text>
              </Pressable>
            ))}
          </View>
          <Text style={s.starLabel}>{STAR_LABELS[stars]}</Text>

          {/* Comment */}
          <TextInput
            style={s.input}
            placeholder="Comentario opcional... (sin groserías)"
            placeholderTextColor={COLORS.muted}
            value={comment}
            onChangeText={text => {
              setComment(text);
            }}
            onBlur={() => {
              if (containsProfanity(comment)) {
                Alert.alert('Lenguaje no permitido', PROFANITY_WARNING);
                setComment('');
              }
            }}
            multiline
            numberOfLines={3}
            textAlignVertical="top"
            maxLength={300}
          />

          {/* 🎁 Dar propina — solo al calificar al grupo. Mismo azul que el
              resto de los botones de regalo en la app. */}
          {subject.type === 'group' && (
            <Pressable style={s.btnTip} onPress={() => setTipVisible(true)}>
              <GiftIcon size={16} color="#fff" />
              <Text style={s.btnTipText}>{t('gifts.tipButton')}</Text>
            </Pressable>
          )}

          {/* Buttons */}
          <Pressable
            style={[s.btnSubmit, loading && { opacity: 0.6 }]}
            onPress={handleSubmit}
            disabled={loading}
          >
            {loading
              ? <ActivityIndicator color={COLORS.bg} size="small" />
              : <Text style={s.btnSubmitText}>Enviar calificación ⭐</Text>}
          </Pressable>

          <Pressable style={s.btnSkip} onPress={() => onDone(null)}>
            <Text style={s.btnSkipText}>Omitir</Text>
          </Pressable>
        </View>
      </KeyboardAvoidingView>

      {/* GiftPickerModal NO usa <Modal> nativo propio a propósito (por eso
          se puede montar aquí, dentro de este <Modal>, sin romperse en
          Android). */}
      {subject.type === 'group' && (
        <GiftPickerModal
          visible={tipVisible}
          onClose={() => setTipVisible(false)}
          groupId={subject.targetId}
          groupName={subject.targetName}
          groupCountry={subject.groupCountry ?? null}
          reservationId={subject.reservationId}
        />
      )}
    </Modal>
  );
}

const s = StyleSheet.create({
  backdrop: {
    flex: 1,
    backgroundColor: 'rgba(0,0,0,0.7)',
    justifyContent: 'flex-end',
  },
  sheet: {
    backgroundColor: COLORS.card,
    borderTopLeftRadius: 24,
    borderTopRightRadius: 24,
    padding: SPACING.xl,
    paddingBottom: 44,
    borderTopWidth: 1,
    borderColor: COLORS.border,
  },
  title:    { fontFamily: FONTS.title, fontSize: 22, color: COLORS.text, textAlign: 'center', marginBottom: 4 },
  subtitle: { fontFamily: FONTS.body, fontSize: 14, color: COLORS.muted2, textAlign: 'center', marginBottom: 24 },

  starsRow:   { flexDirection: 'row', justifyContent: 'center', gap: 8, marginBottom: 8 },
  starBtn:    { padding: 4 },
  star:       { fontSize: 40, color: COLORS.border },
  starActive: { color: '#FFD700' },
  starLabel:  { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted2, textAlign: 'center', marginBottom: 20 },

  input: {
    backgroundColor: COLORS.bg,
    borderRadius: RADIUS.md,
    borderWidth: 1,
    borderColor: COLORS.border,
    paddingHorizontal: 14,
    paddingVertical: 12,
    fontFamily: FONTS.body,
    fontSize: 14,
    color: COLORS.text,
    height: 80,
    marginBottom: 20,
  },

  btnTip: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 8,
    backgroundColor: '#3B82F6', borderWidth: 1.5, borderColor: '#60A5FA',
    borderRadius: RADIUS.lg, paddingVertical: 13, marginBottom: 12,
  },
  btnTipText: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: '#fff' },

  btnSubmit: {
    backgroundColor: COLORS.green,
    borderRadius: RADIUS.lg,
    paddingVertical: 15,
    alignItems: 'center',
    marginBottom: 12,
  },
  btnSubmitText: { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.bg },

  btnSkip: { alignItems: 'center', paddingVertical: 8 },
  btnSkipText: { fontFamily: FONTS.body, fontSize: 14, color: COLORS.muted },
});
