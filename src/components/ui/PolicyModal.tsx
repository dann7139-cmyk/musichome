/**
 * PolicyModal — Modal de aceptación de políticas de DARICEFY.
 * Se muestra una vez antes de que el cliente realice su primera contratación.
 * La aceptación se persiste en AsyncStorage para no mostrarse repetidamente.
 */
import AsyncStorage from '@react-native-async-storage/async-storage';
import { CheckCircle, FileText, Shield, X } from 'lucide-react-native';
import React, { useEffect, useState } from 'react';
import {
  Modal,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';
import Button from './Button';

const STORAGE_KEY = 'daricefy_client_policies_accepted_v1';

interface Props {
  visible: boolean;
  onAccept: () => void;
  onClose: () => void;
}

const POLICIES = [
  {
    num: '1',
    text: 'DARICEFY es una plataforma de intermediación. Te conectamos con grupos y talentos, pero NO somos responsables de la ejecución del evento.',
  },
  {
    num: '2',
    text: 'El contrato de servicio es directamente entre tú (cliente) y el grupo o talento contratado.',
  },
  {
    num: '3',
    text: 'DARICEFY cobra una Tarifa de servicio por el uso de la plataforma. Esta tarifa NO incluye seguro ni garantía del evento.',
  },
  {
    num: '4',
    text: 'Cualquier incumplimiento, daño o accidente durante el evento debe resolverse directamente entre las partes. DARICEFY puede mediar si es necesario, pero no asume responsabilidad legal.',
  },
  {
    num: '5',
    text: 'Al confirmar el pago aceptas estas condiciones y autorizas el cobro del servicio.',
  },
];

export default function PolicyModal({ visible, onAccept, onClose }: Props) {
  const [checked, setChecked] = useState(false);

  useEffect(() => {
    if (visible) setChecked(false);
  }, [visible]);

  const handleAccept = async () => {
    await AsyncStorage.setItem(STORAGE_KEY, 'true');
    onAccept();
  };

  return (
    <Modal
      visible={visible}
      transparent
      animationType="slide"
      statusBarTranslucent
      onRequestClose={onClose}
    >
      <View style={styles.overlay}>
        <View style={styles.sheet}>
          {/* Header */}
          <View style={styles.header}>
            <View style={styles.headerLeft}>
              <Shield size={20} color={COLORS.green} />
              <Text style={styles.headerTitle}>Antes de continuar</Text>
            </View>
            <Pressable style={styles.closeBtn} onPress={onClose} hitSlop={12}>
              <X size={18} color={COLORS.muted} />
            </Pressable>
          </View>

          <ScrollView
            showsVerticalScrollIndicator={false}
            contentContainerStyle={styles.scroll}
          >
            <Text style={styles.subtitle}>
              Lee y acepta las condiciones de uso de DARICEFY para continuar con tu contratación.
            </Text>

            <View style={styles.policiesCard}>
              {POLICIES.map((p) => (
                <View key={p.num} style={styles.policyRow}>
                  <View style={styles.numBadge}>
                    <Text style={styles.numText}>{p.num}</Text>
                  </View>
                  <Text style={styles.policyText}>{p.text}</Text>
                </View>
              ))}
            </View>

            {/* Ver políticas completas */}
            <Pressable style={styles.fullPolicyLink}>
              <FileText size={14} color={COLORS.muted2} />
              <Text style={styles.fullPolicyText}>Ver políticas completas</Text>
            </Pressable>

            {/* Checkbox de aceptación */}
            <Pressable
              style={styles.checkRow}
              onPress={() => setChecked(v => !v)}
            >
              <View style={[styles.checkbox, checked && styles.checkboxChecked]}>
                {checked && <CheckCircle size={16} color={COLORS.bg} />}
              </View>
              <Text style={styles.checkLabel}>
                He leído y acepto las políticas de DARICEFY
              </Text>
            </Pressable>
          </ScrollView>

          {/* Botón de acción */}
          <View style={styles.footer}>
            <Button
              label="Continuar con la contratación"
              onPress={handleAccept}
              disabled={!checked}
              size="lg"
            />
            <Text style={styles.footerNote}>
              Solo se muestra una vez. Puedes consultar las políticas en tu perfil.
            </Text>
          </View>
        </View>
      </View>
    </Modal>
  );
}

/**
 * Verifica si el usuario ya aceptó las políticas.
 * Úsalo en BookingScreen antes de mostrar el modal.
 */
export async function hasPoliciesAccepted(): Promise<boolean> {
  const val = await AsyncStorage.getItem(STORAGE_KEY);
  return val === 'true';
}

const styles = StyleSheet.create({
  overlay: {
    flex: 1,
    backgroundColor: 'rgba(0,0,0,0.75)',
    justifyContent: 'flex-end',
  },
  sheet: {
    backgroundColor: COLORS.card,
    borderTopLeftRadius: 24,
    borderTopRightRadius: 24,
    maxHeight: '88%',
    borderTopWidth: 1,
    borderColor: COLORS.border,
  },
  header: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    paddingHorizontal: SPACING.xl,
    paddingTop: SPACING.lg,
    paddingBottom: 14,
    borderBottomWidth: 1,
    borderBottomColor: COLORS.border,
  },
  headerLeft: { flexDirection: 'row', alignItems: 'center', gap: 10 },
  headerTitle: { fontFamily: FONTS.title, fontSize: 17, color: COLORS.text },
  closeBtn: {
    width: 34, height: 34, borderRadius: 10,
    backgroundColor: COLORS.card2, alignItems: 'center', justifyContent: 'center',
    borderWidth: 1, borderColor: COLORS.border,
  },
  scroll: { padding: SPACING.xl, paddingBottom: 8 },
  subtitle: {
    fontFamily: FONTS.body, fontSize: 14, color: COLORS.muted2,
    lineHeight: 22, marginBottom: 20,
  },
  policiesCard: {
    backgroundColor: COLORS.card2, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border,
    padding: SPACING.lg, gap: 16, marginBottom: 16,
  },
  policyRow: { flexDirection: 'row', alignItems: 'flex-start', gap: 12 },
  numBadge: {
    width: 24, height: 24, borderRadius: 12,
    backgroundColor: 'rgba(0,230,118,0.12)',
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.3)',
    alignItems: 'center', justifyContent: 'center',
    flexShrink: 0,
  },
  numText: { fontFamily: FONTS.bodySemiBold, fontSize: 11, color: COLORS.green },
  policyText: {
    fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2,
    lineHeight: 20, flex: 1,
  },
  fullPolicyLink: {
    flexDirection: 'row', alignItems: 'center', gap: 8,
    marginBottom: 20,
  },
  fullPolicyText: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2 },
  checkRow: {
    flexDirection: 'row', alignItems: 'center', gap: 14,
    backgroundColor: COLORS.card2, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border,
    padding: SPACING.lg, marginBottom: 8,
  },
  checkbox: {
    width: 24, height: 24, borderRadius: 6,
    borderWidth: 2, borderColor: COLORS.border,
    alignItems: 'center', justifyContent: 'center',
    flexShrink: 0,
  },
  checkboxChecked: {
    backgroundColor: COLORS.green, borderColor: COLORS.green,
  },
  checkLabel: { fontFamily: FONTS.bodyMedium, fontSize: 14, color: COLORS.text, flex: 1 },
  footer: {
    paddingHorizontal: SPACING.xl,
    paddingTop: 14,
    paddingBottom: 28,
    borderTopWidth: 1,
    borderTopColor: COLORS.border,
    gap: 10,
  },
  footerNote: {
    fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted,
    textAlign: 'center',
  },
});
