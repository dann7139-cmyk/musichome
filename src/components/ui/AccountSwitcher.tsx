/**
 * AccountSwitcher — cambiar rápido entre varias cuentas ya conocidas (ej.
 * tu admin + la cuenta de un cliente que manejas por él) sin cerrar
 * sesión y volver a escribir contraseña cada vez. Mismo mecanismo que ya
 * existe en el flujo de deep link de recuperación de contraseña
 * (AuthContext.tsx: supabase.auth.setSession con access_token/
 * refresh_token) — aquí solo se guardan esos tokens por cuenta.
 *
 * Petición real (2026-09-18): "quiero un botón para irme rápido a la
 * cuenta del cliente de Lala... cotizo desde mi admin, me vuelvo a meter
 * a la de Lala para el pago, y regresar a mi cuenta de admin" — ya
 * existía en la web, aquí es el mismo concepto para la app.
 *
 * ⚠️ Los tokens quedan guardados en este celular (AsyncStorage) — mismo
 * criterio que guardar contraseñas, solo para un equipo de confianza.
 */
import { Repeat, X, Check, Trash2 } from 'lucide-react-native';
import React, { useEffect, useState } from 'react';
import { ActivityIndicator, Alert, Modal, Pressable, StyleSheet, Text, TextInput, View } from 'react-native';
import AsyncStorage from '@react-native-async-storage/async-storage';
import { supabase } from '../../config/supabase';
import { useAuth } from '../../context/AuthContext';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';

const STORAGE_KEY = 'daricefy_account_switcher';

interface SavedAccount {
  label: string;
  email: string;
  access_token: string;
  refresh_token: string;
}

async function loadAccounts(): Promise<SavedAccount[]> {
  try {
    const raw = await AsyncStorage.getItem(STORAGE_KEY);
    return raw ? JSON.parse(raw) : [];
  } catch {
    return [];
  }
}
async function saveAccounts(list: SavedAccount[]) {
  try { await AsyncStorage.setItem(STORAGE_KEY, JSON.stringify(list)); } catch {}
}

export default function AccountSwitcher() {
  const { session, profile, signOut } = useAuth();
  const [open, setOpen] = useState(false);
  const [adding, setAdding] = useState(false);
  const [labelInput, setLabelInput] = useState('');
  const [accounts, setAccounts] = useState<SavedAccount[]>([]);
  const [switching, setSwitching] = useState<string | null>(null);
  const [pendingLeave, setPendingLeave] = useState(false);

  useEffect(() => { if (open) loadAccounts().then(setAccounts); }, [open]);

  if (!session) return null;

  const currentEmail = session.user.email ?? '';
  const others = accounts.filter(a => a.email.toLowerCase() !== currentEmail.toLowerCase());
  const isCurrentSaved = accounts.some(a => a.email.toLowerCase() === currentEmail.toLowerCase());

  const openAdd = () => {
    setLabelInput((profile as any)?.name ?? (profile as any)?.full_name ?? currentEmail);
    setAdding(true);
  };

  const confirmAdd = async () => {
    if (!labelInput.trim() || !session) return;
    const next = [
      ...accounts.filter(a => a.email.toLowerCase() !== currentEmail.toLowerCase()),
      { label: labelInput.trim(), email: currentEmail, access_token: session.access_token, refresh_token: session.refresh_token },
    ];
    setAccounts(next);
    await saveAccounts(next);
    setAdding(false);
    if (pendingLeave) {
      setPendingLeave(false);
      setOpen(false);
      await signOut();
    }
  };

  // 2026-09-18 — petición real: "no me deja agregar la otra cuenta, que
  // me mande donde inicio sesión si quiero agregar otra cuenta, ahí tengo
  // la cuenta guardada y que se guarde después". Para una cuenta nueva
  // (nunca usada en este teléfono) hace falta cerrar sesión, iniciar
  // sesión ahí, y guardarla — este botón guarda primero la cuenta actual
  // (si aún no está guardada) para no perderla, y cierra sesión para caer
  // en Login (AppNavigator ya cambia de stack solo cuando session===null).
  const addAnother = () => {
    if (isCurrentSaved) {
      setOpen(false);
      signOut();
      return;
    }
    Alert.alert(
      'Antes de salir',
      'Para no perder el acceso a esta cuenta, guárdala primero.',
      [
        { text: 'Cancelar', style: 'cancel' },
        { text: 'Salir sin guardar', style: 'destructive', onPress: () => { setOpen(false); signOut(); } },
        { text: 'Guardar y continuar', onPress: () => { setPendingLeave(true); openAdd(); } },
      ]
    );
  };

  const switchTo = async (acc: SavedAccount) => {
    setSwitching(acc.email);
    const { error } = await supabase.auth.setSession({
      access_token: acc.access_token, refresh_token: acc.refresh_token,
    });
    setSwitching(null);
    if (error) {
      Alert.alert(
        'No se pudo cambiar',
        `La sesión de "${acc.label}" ya expiró — inicia sesión ahí de nuevo una vez y vuelve a guardarla.`
      );
      return;
    }
    setOpen(false);
    // onAuthStateChange en AuthContext recoge el cambio y AppNavigator
    // cambia de stack solo según el nuevo rol — sin más que hacer aquí.
  };

  const forget = async (email: string) => {
    const next = accounts.filter(a => a.email.toLowerCase() !== email.toLowerCase());
    setAccounts(next);
    await saveAccounts(next);
  };

  return (
    <>
      <Pressable style={s.iconBtn} onPress={() => setOpen(true)}>
        <Repeat size={16} color={COLORS.muted2} />
        {others.length > 0 && (
          <View style={s.badge}><Text style={s.badgeText}>{others.length}</Text></View>
        )}
      </Pressable>

      <Modal visible={open} transparent animationType="slide" onRequestClose={() => setOpen(false)}>
        <Pressable style={s.backdrop} onPress={() => setOpen(false)} />
        <View style={s.sheet}>
          {adding ? (
            <>
              <Text style={s.title}>Guardar esta cuenta</Text>
              <Text style={s.hint}>¿Cómo le quieres llamar? (ej. &quot;Lala&quot;, &quot;Mi admin&quot;)</Text>
              <TextInput
                style={s.input}
                value={labelInput}
                onChangeText={setLabelInput}
                placeholder="Nombre para esta cuenta"
                placeholderTextColor={COLORS.muted}
                autoFocus
              />
              <View style={s.row}>
                <Pressable style={[s.btn, s.btnGhost]} onPress={() => setAdding(false)}>
                  <Text style={s.btnGhostText}>Cancelar</Text>
                </Pressable>
                <Pressable style={[s.btn, s.btnGreen]} onPress={confirmAdd}>
                  <Check size={16} color={COLORS.bg} />
                  <Text style={s.btnGreenText}>Guardar</Text>
                </Pressable>
              </View>
            </>
          ) : (
            <>
              <View style={s.header}>
                <Text style={s.title}>Cuentas</Text>
                <Pressable onPress={() => setOpen(false)} hitSlop={8}>
                  <X size={18} color={COLORS.muted} />
                </Pressable>
              </View>

              <Text style={s.sectionLabel}>Ahora eres</Text>
              <Text style={s.currentName}>{(profile as any)?.name ?? (profile as any)?.full_name ?? currentEmail}</Text>

              {others.length > 0 && (
                <>
                  <Text style={[s.sectionLabel, { marginTop: 14 }]}>Cambiar a</Text>
                  {others.map(a => (
                    <View key={a.email} style={s.accRow}>
                      <Pressable
                        style={s.accBtn}
                        onPress={() => switchTo(a)}
                        disabled={switching === a.email}
                      >
                        {switching === a.email
                          ? <ActivityIndicator size="small" color={COLORS.green} />
                          : <Text style={s.accBtnText}>{a.label}</Text>}
                      </Pressable>
                      <Pressable style={s.forgetBtn} onPress={() => forget(a.email)} hitSlop={8}>
                        <Trash2 size={14} color={COLORS.muted} />
                      </Pressable>
                    </View>
                  ))}
                </>
              )}

              <Pressable style={s.addBtn} onPress={openAdd}>
                <Text style={s.addBtnText}>+ Guardar esta cuenta</Text>
              </Pressable>
              <Pressable style={s.addBtn} onPress={addAnother}>
                <Text style={s.addBtnMutedText}>+ Agregar otra cuenta (ir a iniciar sesión)</Text>
              </Pressable>
            </>
          )}
        </View>
      </Modal>
    </>
  );
}

const s = StyleSheet.create({
  iconBtn: {
    width: 36, height: 36, borderRadius: 10,
    backgroundColor: COLORS.card, borderWidth: 1, borderColor: COLORS.border,
    alignItems: 'center', justifyContent: 'center', position: 'relative',
  },
  badge: {
    position: 'absolute', top: -3, right: -3,
    backgroundColor: COLORS.green, borderRadius: 8,
    minWidth: 16, height: 16, alignItems: 'center', justifyContent: 'center', paddingHorizontal: 3,
  },
  badgeText: { fontFamily: FONTS.bodySemiBold, fontSize: 9, color: COLORS.bg },

  backdrop: { flex: 1, backgroundColor: 'rgba(0,0,0,0.6)' },
  sheet: {
    backgroundColor: COLORS.card, borderTopLeftRadius: 24, borderTopRightRadius: 24,
    padding: SPACING.xl, borderWidth: 1, borderColor: COLORS.border, gap: 4,
  },
  header: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', marginBottom: 6 },
  title: { fontFamily: FONTS.title, fontSize: 17, color: COLORS.text },
  hint: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, marginBottom: 10 },
  sectionLabel: { fontFamily: FONTS.bodyMedium, fontSize: 11, color: COLORS.muted, textTransform: 'uppercase', letterSpacing: 0.6 },
  currentName: { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.text, marginTop: 2 },

  accRow: { flexDirection: 'row', alignItems: 'center', gap: 6, marginTop: 6 },
  accBtn: {
    flex: 1, paddingVertical: 12, paddingHorizontal: 12, borderRadius: RADIUS.md,
    backgroundColor: COLORS.card2, borderWidth: 1, borderColor: COLORS.border,
  },
  accBtnText: { fontFamily: FONTS.bodyMedium, fontSize: 14, color: COLORS.text },
  forgetBtn: {
    width: 40, height: 40, borderRadius: RADIUS.md, alignItems: 'center', justifyContent: 'center',
    backgroundColor: COLORS.card2, borderWidth: 1, borderColor: COLORS.border,
  },

  addBtn: { marginTop: 16, paddingVertical: 13, alignItems: 'center' },
  addBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.green },
  addBtnMutedText: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted2 },

  input: {
    backgroundColor: COLORS.bg, borderRadius: RADIUS.md, borderWidth: 1, borderColor: COLORS.border,
    paddingHorizontal: 14, paddingVertical: 12, fontFamily: FONTS.body, fontSize: 14, color: COLORS.text, marginBottom: 16,
  },
  row: { flexDirection: 'row', gap: 10 },
  btn: {
    flex: 1, flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 6,
    paddingVertical: 13, borderRadius: RADIUS.md,
  },
  btnGhost: { backgroundColor: COLORS.card2, borderWidth: 1, borderColor: COLORS.border },
  btnGhostText: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.muted2 },
  btnGreen: { backgroundColor: COLORS.green },
  btnGreenText: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.bg },
});
