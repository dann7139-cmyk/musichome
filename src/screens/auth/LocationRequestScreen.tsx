import React, { useEffect, useRef, useState } from 'react';
import {
  ActivityIndicator,
  Alert,
  FlatList,
  Modal,
  Platform,
  Pressable,
  SafeAreaView,
  StatusBar,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import * as Location from 'expo-location';
import { supabase } from '../../config/supabase';
import { useAuth } from '../../context/AuthContext';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';
import Button from '../../components/ui/Button';

// ─── Types ────────────────────────────────────────────────────────────────────

type Screen = 'initial' | 'detecting' | 'confirming' | 'manual';

interface CountryRow { id: string; name: string; code: string; }
interface StateRow   { id: string; name: string; code: string; }

// ─── Constants ────────────────────────────────────────────────────────────────

const ROLE_SUBTITLES: Record<string, string> = {
  client: 'Necesitamos tu ubicación para mostrarte grupos disponibles en tu zona.',
  group:  'Necesitamos tu ubicación para que los clientes de tu estado puedan encontrarte.',
  talent: 'Necesitamos tu ubicación para que los grupos de tu estado puedan invitarte.',
};

// ─── Util ─────────────────────────────────────────────────────────────────────

function withTimeout<T>(promise: Promise<T>, ms: number): Promise<T> {
  return Promise.race([
    promise,
    new Promise<never>((_, reject) =>
      setTimeout(() => reject(new Error('timeout')), ms)
    ),
  ]);
}

// ─── Component ────────────────────────────────────────────────────────────────

export default function LocationRequestScreen() {
  const { role, refetchProfile } = useAuth();

  const [screen,           setScreen          ] = useState<Screen>('initial');
  const [countries,        setCountries       ] = useState<CountryRow[]>([]);
  const [states,           setStates          ] = useState<StateRow[]>([]);
  const [selCountry,       setSelCountry      ] = useState<CountryRow | null>(null);
  const [selState,         setSelState        ] = useState<StateRow | null>(null);
  const [showCountryModal, setShowCountryModal] = useState(false);
  const [showStateModal,   setShowStateModal  ] = useState(false);
  const [saving,             setSaving            ] = useState(false);
  const [notFoundHint,       setNotFoundHint      ] = useState<string | null>(null);
  const [confirmedStateName,   setConfirmedStateName  ] = useState<string | null>(null);
  const [confirmedCountryName, setConfirmedCountryName] = useState<string | null>(null);

  const cancelledRef = useRef(false);

  // Load active countries on mount
  useEffect(() => {
    supabase
      .from('countries')
      .select('id, name, code')
      .eq('is_active', true)
      .order('name')
      .then(({ data }) => {
        if (data) setCountries(data);
      });
  }, []);

  // Load states whenever country changes
  useEffect(() => {
    if (!selCountry) {
      setStates([]);
      setSelState(null);
      return;
    }
    setSelState(null);
    supabase
      .from('states')
      .select('id, name, code')
      .eq('country_id', selCountry.id)
      .order('name')
      .then(({ data }) => {
        if (data) setStates(data);
      });
  }, [selCountry]);

  // ── GPS detection ─────────────────────────────────────────────────────────

  const handleDetect = async () => {
    cancelledRef.current = false;
    setScreen('detecting');

    try {
      // 1. OS permission
      const { status } = await Location.requestForegroundPermissionsAsync();
      if (cancelledRef.current) return;
      if (status !== 'granted') {
        setScreen('manual');
        return;
      }

      // 2. Position — 8s timeout
      const pos = await withTimeout(
        Location.getCurrentPositionAsync({ accuracy: Location.Accuracy.Balanced }),
        8_000
      );
      if (cancelledRef.current) return;

      // 3. Reverse geocode — 3s timeout
      const [place] = await withTimeout(
        Location.reverseGeocodeAsync({
          latitude:  pos.coords.latitude,
          longitude: pos.coords.longitude,
        }),
        3_000
      );
      if (cancelledRef.current) return;

      const detectedState   = place?.region         ?? null;
      const detectedCountry = place?.isoCountryCode ?? null;

      // 4. Country support check (skip if countries list not yet loaded)
      const matchedCountry = countries.length > 0
        ? countries.find(
            c => c.code.toUpperCase() === (detectedCountry ?? '').toUpperCase()
          )
        : undefined;

      if (countries.length > 0 && !matchedCountry) {
        const label = detectedState ?? detectedCountry ?? 'tu ubicación actual';
        Alert.alert(
          'Zona no disponible',
          `Daricefy todavía no opera en ${label}. ` +
          'Por favor selecciona tu país de origen manualmente.',
          [{ text: 'OK', onPress: () => setScreen('manual') }]
        );
        return;
      }

      // Countries not loaded yet → fall through to manual
      if (!matchedCountry) {
        setScreen('manual');
        return;
      }

      // 5. Load states for detected country
      const { data: stateData } = await supabase
        .from('states')
        .select('id, name, code')
        .eq('country_id', matchedCountry.id)
        .order('name');
      if (cancelledRef.current) return;

      // 6. Find matching state — tolerates full name ("Jalisco"), ISO code
      //    ("MX-JAL"), or abbreviation ("JAL" / "Jal.") which Android GPS
      //    returns in varying formats (sometimes with trailing punctuation).
      const cleanStr = (s: string) =>
        s.toLowerCase().trim().replace(/[^a-z0-9áéíóúüñ]/gi, '').toLowerCase();

      const normalizedDetected = cleanStr(detectedState ?? '');
      const matchedState = (stateData ?? []).find(s => {
        const cleanName      = cleanStr(s.name);
        const cleanCode      = cleanStr(s.code);
        const cleanCodeShort = cleanStr(s.code.split('-')[1] ?? '');
        return (
          cleanName === normalizedDetected
          || cleanCode === normalizedDetected
          || cleanCodeShort === normalizedDetected
        );
      });

      if (!matchedState) {
        // Country OK but state not in catalog → manual with country preselected + hint
        setSelCountry(matchedCountry);
        setStates(stateData ?? []);
        setNotFoundHint(
          detectedState
            ? `No reconocimos "${detectedState}". Selecciona tu estado de la lista.`
            : 'No reconocimos tu estado. Selecciónalo de la lista.'
        );
        setScreen('manual');
        return;
      }

      // 7. Both matched → ask user to confirm before writing to DB
      setConfirmedStateName(matchedState.name);
      setConfirmedCountryName(matchedCountry.name);
      setScreen('confirming');

    } catch (err) {
      if (cancelledRef.current) return;
      const isTimeout = (err as Error).message === 'timeout';
      Alert.alert(
        'Error de ubicación',
        isTimeout
          ? 'No pudimos detectar tu ubicación (tiempo agotado).'
          : 'Ocurrió un error al detectar tu ubicación.',
        [
          { text: 'Reintentar',             onPress: () => handleDetect() },
          { text: 'Seleccionar manualmente', onPress: () => setScreen('manual') },
        ]
      );
      setScreen('initial');
    }
  };

  const handleCancel = () => {
    cancelledRef.current = true;
    setScreen('initial');
  };

  // ── Save ──────────────────────────────────────────────────────────────────

  const saveLocation = async (stateName: string, countryName: string) => {
    setSaving(true);
    const { error } = await supabase.rpc('update_my_location', {
      p_state:   stateName,
      p_country: countryName,
    });
    if (error) {
      setSaving(false);
      Alert.alert('Error', 'No pudimos guardar tu ubicación. Intenta de nuevo.');
      return;
    }
    await refetchProfile();
    // AppNavigator re-renders: guard passes → exits this screen automatically
  };

  const handleSaveManual = () => {
    if (!selCountry || !selState || saving) return;
    saveLocation(selState.name, selCountry.name);
  };

  // ── Renders ───────────────────────────────────────────────────────────────

  const subtitle = ROLE_SUBTITLES[role ?? 'client'] ?? ROLE_SUBTITLES.client;

  const renderInitial = () => (
    <View style={styles.centerContent}>
      <Text style={styles.emoji}>📍</Text>
      <Text style={styles.title}>¿Dónde estás?</Text>
      <Text style={styles.subtitle}>{subtitle}</Text>

      <View style={styles.buttonGroup}>
        <Button
          label="Detectar automáticamente"
          onPress={handleDetect}
          size="lg"
        />
        <Button
          label="Seleccionar manualmente"
          onPress={() => setScreen('manual')}
          variant="outline"
          size="lg"
        />
      </View>
    </View>
  );

  const renderDetecting = () => (
    <View style={styles.centerContent}>
      <ActivityIndicator size="large" color={COLORS.green} style={styles.spinner} />
      <Text style={styles.detectingTitle}>Detectando tu ubicación...</Text>
      <Text style={styles.detectingHint}>
        Asegúrate de tener el GPS activo y buena señal.
      </Text>
      <Pressable onPress={handleCancel} style={styles.cancelLink}>
        <Text style={styles.cancelText}>Cancelar</Text>
      </Pressable>
    </View>
  );

  const renderConfirming = () => (
    <View style={styles.centerContent}>
      <Text style={styles.emoji}>✅</Text>
      <Text style={styles.confirmingTitle}>Te detectamos en:</Text>
      <View style={styles.confirmingCard}>
        <Text style={styles.confirmingLocation}>
          📍 {confirmedStateName}, {confirmedCountryName}
        </Text>
      </View>
      <Text style={styles.confirmingQuestion}>¿Es correcto?</Text>
      <View style={styles.buttonGroup}>
        <Button
          label="Sí, continuar"
          onPress={() => saveLocation(confirmedStateName!, confirmedCountryName!)}
          size="lg"
          loading={saving}
        />
        <Button
          label="No, seleccionar otro"
          onPress={() => setScreen('manual')}
          variant="outline"
          size="lg"
          disabled={saving}
        />
      </View>
    </View>
  );

  const renderManual = () => (
    <View style={styles.manualContent}>
      <Pressable onPress={() => setScreen('initial')} style={styles.backRow}>
        <Text style={styles.backText}>← Volver</Text>
      </Pressable>

      <Text style={styles.manualTitle}>Selecciona tu ubicación</Text>

      {notFoundHint && (
        <View style={styles.hintBox}>
          <Text style={styles.hintText}>{notFoundHint}</Text>
        </View>
      )}

      <Text style={styles.fieldLabel}>País</Text>
      <Pressable
        style={styles.selector}
        onPress={() => setShowCountryModal(true)}
      >
        <Text style={selCountry ? styles.selectorValue : styles.selectorPlaceholder}>
          {selCountry?.name ?? 'Selecciona un país'}
        </Text>
        <Text style={styles.selectorArrow}>▾</Text>
      </Pressable>

      <Text style={[styles.fieldLabel, !selCountry && styles.fieldLabelDisabled]}>
        Estado / Provincia
      </Text>
      <Pressable
        style={[styles.selector, !selCountry && styles.selectorDisabled]}
        onPress={() => selCountry && setShowStateModal(true)}
        disabled={!selCountry}
      >
        <Text style={selState ? styles.selectorValue : styles.selectorPlaceholder}>
          {selState?.name ?? (selCountry ? 'Selecciona un estado' : 'Primero selecciona un país')}
        </Text>
        <Text style={styles.selectorArrow}>▾</Text>
      </Pressable>

      <View style={styles.saveButtonWrap}>
        <Button
          label="Guardar ubicación"
          onPress={handleSaveManual}
          size="lg"
          loading={saving}
          disabled={!selCountry || !selState}
        />
      </View>
    </View>
  );

  // ── Modals ────────────────────────────────────────────────────────────────

  const renderCountryModal = () => (
    <Modal
      visible={showCountryModal}
      animationType="slide"
      transparent
      onRequestClose={() => setShowCountryModal(false)}
    >
      <Pressable style={styles.modalOverlay} onPress={() => setShowCountryModal(false)}>
        <View style={styles.modalSheet}>
          <View style={styles.modalHeader}>
            <Text style={styles.modalTitle}>País</Text>
            <Pressable onPress={() => setShowCountryModal(false)} hitSlop={12}>
              <Text style={styles.modalClose}>✕</Text>
            </Pressable>
          </View>
          <FlatList
            data={countries}
            keyExtractor={item => item.id}
            renderItem={({ item }) => (
              <Pressable
                style={[
                  styles.modalItem,
                  selCountry?.id === item.id && styles.modalItemActive,
                ]}
                onPress={() => {
                  setSelCountry(item);
                  setNotFoundHint(null);
                  setShowCountryModal(false);
                }}
              >
                <Text style={[
                  styles.modalItemText,
                  selCountry?.id === item.id && styles.modalItemTextActive,
                ]}>
                  {item.name}
                </Text>
                {selCountry?.id === item.id && (
                  <Text style={styles.modalItemCheck}>✓</Text>
                )}
              </Pressable>
            )}
            ItemSeparatorComponent={() => <View style={styles.modalSeparator} />}
          />
        </View>
      </Pressable>
    </Modal>
  );

  const renderStateModal = () => (
    <Modal
      visible={showStateModal}
      animationType="slide"
      transparent
      onRequestClose={() => setShowStateModal(false)}
    >
      <Pressable style={styles.modalOverlay} onPress={() => setShowStateModal(false)}>
        <View style={styles.modalSheet}>
          <View style={styles.modalHeader}>
            <Text style={styles.modalTitle}>Estado / Provincia</Text>
            <Pressable onPress={() => setShowStateModal(false)} hitSlop={12}>
              <Text style={styles.modalClose}>✕</Text>
            </Pressable>
          </View>
          <FlatList
            data={states}
            keyExtractor={item => item.id}
            renderItem={({ item }) => (
              <Pressable
                style={[
                  styles.modalItem,
                  selState?.id === item.id && styles.modalItemActive,
                ]}
                onPress={() => {
                  setSelState(item);
                  setShowStateModal(false);
                }}
              >
                <Text style={[
                  styles.modalItemText,
                  selState?.id === item.id && styles.modalItemTextActive,
                ]}>
                  {item.name}
                </Text>
                {selState?.id === item.id && (
                  <Text style={styles.modalItemCheck}>✓</Text>
                )}
              </Pressable>
            )}
            ItemSeparatorComponent={() => <View style={styles.modalSeparator} />}
          />
        </View>
      </Pressable>
    </Modal>
  );

  // ── Main render ───────────────────────────────────────────────────────────

  return (
    <SafeAreaView style={styles.root}>
      <StatusBar barStyle="light-content" backgroundColor={COLORS.bg} />
      {screen === 'initial'    && renderInitial()}
      {screen === 'detecting'  && renderDetecting()}
      {screen === 'confirming' && renderConfirming()}
      {screen === 'manual'     && renderManual()}
      {renderCountryModal()}
      {renderStateModal()}
    </SafeAreaView>
  );
}

// ─── Styles ───────────────────────────────────────────────────────────────────

const styles = StyleSheet.create({
  root: {
    flex: 1,
    backgroundColor: COLORS.bg,
  },

  // ── Initial & Detecting (centered layout) ─────────────────────────────────
  centerContent: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    paddingHorizontal: SPACING.xl,
  },
  emoji: {
    fontSize: 56,
    marginBottom: SPACING.lg,
  },
  title: {
    fontFamily: FONTS.title,
    fontSize: 28,
    color: COLORS.text,
    textAlign: 'center',
    marginBottom: SPACING.sm,
  },
  subtitle: {
    fontFamily: FONTS.body,
    fontSize: 15,
    color: COLORS.muted2,
    textAlign: 'center',
    lineHeight: 22,
    marginBottom: SPACING.xxl,
  },
  buttonGroup: {
    width: '100%',
    gap: SPACING.sm,
  },

  // ── Detecting ─────────────────────────────────────────────────────────────
  spinner: {
    marginBottom: SPACING.lg,
  },
  detectingTitle: {
    fontFamily: FONTS.bodySemiBold,
    fontSize: 17,
    color: COLORS.text,
    textAlign: 'center',
    marginBottom: SPACING.xs,
  },
  detectingHint: {
    fontFamily: FONTS.body,
    fontSize: 13,
    color: COLORS.muted2,
    textAlign: 'center',
    marginBottom: SPACING.xl,
  },
  cancelLink: {
    paddingVertical: SPACING.xs,
  },
  cancelText: {
    fontFamily: FONTS.bodyMedium,
    fontSize: 14,
    color: COLORS.muted2,
    textDecorationLine: 'underline',
  },

  // ── Confirming ────────────────────────────────────────────────────────────
  confirmingTitle: {
    fontFamily: FONTS.bodyMedium,
    fontSize: 17,
    color: COLORS.muted2,
    textAlign: 'center',
    marginBottom: SPACING.lg,
  },
  confirmingCard: {
    backgroundColor: COLORS.greenMuted,
    borderRadius: RADIUS.lg,
    paddingHorizontal: SPACING.xl,
    paddingVertical: SPACING.md,
    marginBottom: SPACING.lg,
  },
  confirmingLocation: {
    fontFamily: FONTS.title,
    fontSize: 22,
    color: COLORS.green,
    textAlign: 'center',
  },
  confirmingQuestion: {
    fontFamily: FONTS.body,
    fontSize: 16,
    color: COLORS.muted2,
    textAlign: 'center',
    marginBottom: SPACING.xxl,
  },

  // ── Manual ────────────────────────────────────────────────────────────────
  manualContent: {
    flex: 1,
    paddingHorizontal: SPACING.xl,
    paddingTop: SPACING.lg,
  },
  backRow: {
    marginBottom: SPACING.xl,
    alignSelf: 'flex-start',
  },
  backText: {
    fontFamily: FONTS.bodyMedium,
    fontSize: 15,
    color: COLORS.green,
  },
  manualTitle: {
    fontFamily: FONTS.title,
    fontSize: 22,
    color: COLORS.text,
    marginBottom: SPACING.lg,
  },
  hintBox: {
    backgroundColor: 'rgba(255, 183, 0, 0.10)',
    borderLeftWidth: 3,
    borderLeftColor: COLORS.gold,
    borderRadius: RADIUS.sm,
    paddingHorizontal: SPACING.sm,
    paddingVertical: SPACING.xs,
    marginBottom: SPACING.lg,
  },
  hintText: {
    fontFamily: FONTS.body,
    fontSize: 13,
    color: COLORS.gold,
    lineHeight: 19,
  },
  fieldLabel: {
    fontFamily: FONTS.bodyMedium,
    fontSize: 13,
    color: COLORS.muted2,
    marginBottom: 6,
    marginTop: SPACING.md,
  },
  fieldLabelDisabled: {
    opacity: 0.4,
  },
  selector: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    backgroundColor: COLORS.card,
    borderWidth: 1,
    borderColor: COLORS.border,
    borderRadius: RADIUS.md,
    paddingHorizontal: SPACING.md,
    paddingVertical: 14,
  },
  selectorDisabled: {
    opacity: 0.4,
  },
  selectorValue: {
    fontFamily: FONTS.body,
    fontSize: 15,
    color: COLORS.text,
    flex: 1,
  },
  selectorPlaceholder: {
    fontFamily: FONTS.body,
    fontSize: 15,
    color: COLORS.muted,
    flex: 1,
  },
  selectorArrow: {
    fontSize: 16,
    color: COLORS.muted2,
    marginLeft: SPACING.xs,
  },
  saveButtonWrap: {
    marginTop: SPACING.xxl,
  },

  // ── Modals ────────────────────────────────────────────────────────────────
  modalOverlay: {
    flex: 1,
    backgroundColor: COLORS.overlay,
    justifyContent: 'flex-end',
  },
  modalSheet: {
    backgroundColor: COLORS.card,
    borderTopLeftRadius: RADIUS.xl,
    borderTopRightRadius: RADIUS.xl,
    maxHeight: '65%',
    paddingBottom: Platform.OS === 'ios' ? SPACING.xl : SPACING.lg,
  },
  modalHeader: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    paddingHorizontal: SPACING.xl,
    paddingVertical: SPACING.md,
    borderBottomWidth: 1,
    borderBottomColor: COLORS.border,
  },
  modalTitle: {
    fontFamily: FONTS.bodySemiBold,
    fontSize: 16,
    color: COLORS.text,
  },
  modalClose: {
    fontFamily: FONTS.body,
    fontSize: 16,
    color: COLORS.muted2,
  },
  modalItem: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    paddingHorizontal: SPACING.xl,
    paddingVertical: 14,
  },
  modalItemActive: {
    backgroundColor: COLORS.greenMuted,
  },
  modalItemText: {
    fontFamily: FONTS.body,
    fontSize: 15,
    color: COLORS.text,
    flex: 1,
  },
  modalItemTextActive: {
    fontFamily: FONTS.bodyMedium,
    color: COLORS.green,
  },
  modalItemCheck: {
    fontFamily: FONTS.bodySemiBold,
    fontSize: 14,
    color: COLORS.green,
    marginLeft: SPACING.xs,
  },
  modalSeparator: {
    height: 1,
    backgroundColor: COLORS.border,
    marginHorizontal: SPACING.xl,
  },
});
