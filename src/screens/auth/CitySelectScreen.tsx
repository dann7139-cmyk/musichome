/**
 * CitySelectScreen
 *
 * Flujo con detección automática por GPS:
 *  1. Fase "autoDetecting": intenta detectar ubicación con expo-location
 *     - Si éxito y la ciudad está en la DB → guarda y abre la app directo
 *     - Si éxito pero ciudad no en DB      → abre selector con búsqueda pre-llenada
 *     - Si permiso denegado o GPS falla    → abre selector vacío (igual que antes)
 *  2. Fase "manual": selector manual (fallback)
 *
 * La ciudad NO bloquea el contenido; es preferencia de mercado local.
 */

import * as Location from 'expo-location';
import { MapPin, Search, CheckCircle, TrendingUp, X, RefreshCw, Navigation } from 'lucide-react-native';
import React, { useEffect, useRef, useState } from 'react';
import {
  ActivityIndicator,
  Animated,
  Easing,
  FlatList,
  Pressable,
  StyleSheet,
  Text,
  TextInput,
  View,
} from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { supabase } from '../../config/supabase';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';
import { useAuth } from '../../context/AuthContext';

interface CityOption {
  id: string;
  name: string;
  state_name: string;
  country_name: string;
  group_count: number;
  demand_level: 'high' | 'normal' | 'new';
}

const DEMAND_LABEL: Record<string, { label: string; color: string }> = {
  high:   { label: 'Alta demanda', color: '#FF6B35' },
  normal: { label: 'Activa',        color: COLORS.green },
  new:    { label: 'Nueva',         color: COLORS.muted },
};

// Timeout en ms para el intento de GPS (no bloquear más de esto)
const GPS_TIMEOUT_MS = 6000;

export default function CitySelectScreen() {
  const { refetchProfile } = useAuth();

  // Fases: 'detecting' → GPS en curso | 'manual' → mostrar selector
  const [phase, setPhase]           = useState<'detecting' | 'manual'>('detecting');
  const [detectedCity, setDetectedCity] = useState<string | null>(null);

  const [cities,    setCities]    = useState<CityOption[]>([]);
  const [filtered,  setFiltered]  = useState<CityOption[]>([]);
  const [search,    setSearch]    = useState('');
  const [selected,  setSelected]  = useState<CityOption | null>(null);
  const [loading,   setLoading]   = useState(true);
  const [saving,    setSaving]    = useState(false);
  const [error,     setError]     = useState<string | null>(null);

  // Animación del punto pulsante del loader GPS
  const pulseAnim = useRef(new Animated.Value(0.6)).current;
  useEffect(() => {
    Animated.loop(
      Animated.sequence([
        Animated.timing(pulseAnim, { toValue: 1, duration: 700, easing: Easing.inOut(Easing.ease), useNativeDriver: true }),
        Animated.timing(pulseAnim, { toValue: 0.6, duration: 700, easing: Easing.inOut(Easing.ease), useNativeDriver: true }),
      ])
    ).start();
  }, []);

  // ── Fase 1: intentar GPS ──────────────────────────────────────────────────
  useEffect(() => {
    attemptGpsDetection();
  }, []);

  const attemptGpsDetection = async () => {
    try {
      // Pedir permiso (no muestra diálogo si ya fue respondido)
      const { status } = await Location.requestForegroundPermissionsAsync();
      console.log('[CitySelect] permiso de ubicación:', status);
      if (status !== 'granted') {
        console.log('[CitySelect] permiso denegado → selector manual');
        fallbackToManual(null);
        return;
      }

      // GPS con timeout
      const locPromise = Location.getCurrentPositionAsync({
        accuracy: Location.Accuracy.Balanced,
      });
      const timeoutPromise = new Promise<null>((_, reject) =>
        setTimeout(() => reject(new Error('timeout')), GPS_TIMEOUT_MS)
      );

      let loc: Location.LocationObject;
      try {
        loc = await Promise.race([locPromise, timeoutPromise]) as Location.LocationObject;
        console.log('[CitySelect] GPS obtenido:', loc.coords.latitude, loc.coords.longitude);
      } catch (gpsErr) {
        console.log('[CitySelect] GPS timeout o error → selector manual', gpsErr);
        fallbackToManual(null);
        return;
      }

      // Reverse geocoding — con su propio timeout de 3s para no quedarse colgado
      let place: Location.LocationGeocodedAddress | undefined;
      try {
        const geocodeResult = await Promise.race([
          Location.reverseGeocodeAsync({
            latitude:  loc.coords.latitude,
            longitude: loc.coords.longitude,
          }),
          new Promise<never>((_, reject) =>
            setTimeout(() => reject(new Error('geocode timeout')), 3000)
          ),
        ]);
        place = (geocodeResult as Location.LocationGeocodedAddress[])[0];
      } catch (geoErr) {
        console.log('[CitySelect] geocoding timeout o error → selector manual', geoErr);
        fallbackToManual(null);
        return;
      }

      const cityName = place?.city ?? place?.subregion ?? place?.region ?? null;
      console.log('[CitySelect] ciudad detectada por GPS:', cityName);
      if (!cityName) {
        fallbackToManual(null);
        return;
      }

      // Cargar ciudades de la DB para buscar coincidencia
      const { data: cityData, error: citiesErr } = await supabase.rpc('get_active_cities');
      if (citiesErr) {
        console.log('[CitySelect] error cargando ciudades DB → selector manual', citiesErr);
        fallbackToManual(cityName);
        return;
      }
      const allCities = (cityData as CityOption[]) ?? [];
      setCities(allCities);
      setFiltered(allCities);

      // Buscar coincidencia (case-insensitive, incluye variantes)
      const match = allCities.find(c =>
        c.name.toLowerCase() === cityName.toLowerCase() ||
        c.name.toLowerCase().includes(cityName.toLowerCase()) ||
        cityName.toLowerCase().includes(c.name.toLowerCase())
      );

      if (match) {
        // Coincidencia encontrada → guardar automáticamente
        console.log('[CitySelect] match encontrado en DB:', match.name, '→ guardando...');
        setDetectedCity(match.name);
        // Asegurar que loading=false por si saveCity falla y queda en manual
        setLoading(false);
        await saveCity(match.name);
        // saveCity llama refetchProfile que desbloquea la app
        return;
      } else {
        // Sin coincidencia → abrir selector con búsqueda pre-llenada
        console.log('[CitySelect] sin match en DB para', cityName, '→ selector manual');
        fallbackToManual(cityName, allCities);
      }

    } catch (err) {
      console.log('[CitySelect] error inesperado → selector manual', err);
      fallbackToManual(null);
    }
  };

  const fallbackToManual = (detectedName: string | null, preloadedCities?: CityOption[]) => {
    if (detectedName) {
      setSearch(detectedName);
      setDetectedCity(detectedName);
    }
    if (preloadedCities) {
      setCities(preloadedCities);
      setFiltered(
        detectedName
          ? preloadedCities.filter(c => c.name.toLowerCase().includes(detectedName.toLowerCase()))
          : preloadedCities
      );
      setLoading(false);
    } else {
      loadCities(detectedName ?? undefined);
    }
    setPhase('manual');
  };

  useEffect(() => {
    if (!search.trim()) {
      setFiltered(cities);
    } else {
      const q = search.toLowerCase();
      setFiltered(cities.filter(c =>
        c.name.toLowerCase().includes(q) ||
        c.state_name.toLowerCase().includes(q)
      ));
    }
  }, [search, cities]);

  const loadCities = async (prefillSearch?: string) => {
    setLoading(true);
    const { data, error: err } = await supabase.rpc('get_active_cities');
    if (err) {
      setError('No se pudieron cargar las ciudades. Intenta de nuevo.');
    } else {
      const list = (data as CityOption[]) ?? [];
      setCities(list);
      setFiltered(
        prefillSearch
          ? list.filter(c => c.name.toLowerCase().includes(prefillSearch.toLowerCase()))
          : list
      );
    }
    setLoading(false);
  };

  const saveCity = async (cityName: string) => {
    setSaving(true);
    const { data, error: err } = await supabase.rpc('update_my_city', { p_city: cityName });
    if (err || (data as any)?.ok === false) {
      console.log('[CitySelect] error guardando ciudad:', cityName, err ?? (data as any));
      setError('No se pudo guardar tu ciudad. Intenta de nuevo.');
      setSaving(false);
      setLoading(false);
      setPhase('manual');
      return;
    }
    console.log('[CitySelect] ciudad guardada:', cityName, '→ refetchProfile');
    await refetchProfile();
    setSaving(false);
  };

  const handleConfirm = async () => {
    if (!selected) return;
    await saveCity(selected.name);
  };

  const renderCity = ({ item }: { item: CityOption }) => {
    const isSelected = selected?.id === item.id;
    const demand = DEMAND_LABEL[item.demand_level] ?? DEMAND_LABEL.normal;

    return (
      <Pressable
        style={[styles.cityRow, isSelected && styles.cityRowSelected]}
        onPress={() => setSelected(item)}
      >
        <View style={[styles.cityIcon, isSelected && { backgroundColor: COLORS.green + '22' }]}>
          <MapPin size={18} color={isSelected ? COLORS.green : COLORS.muted} />
        </View>

        <View style={styles.cityInfo}>
          <Text style={[styles.cityName, isSelected && { color: COLORS.green }]}>
            {item.name}
          </Text>
          <Text style={styles.cityState}>
            {item.state_name}{item.country_name ? ` · ${item.country_name}` : ''}
          </Text>
        </View>

        <View style={styles.cityMeta}>
          {(item.demand_level === 'high' || item.demand_level === 'normal') && (
            <View style={[styles.demandBadge, { backgroundColor: demand.color + '18' }]}>
              <TrendingUp size={10} color={demand.color} />
              <Text style={[styles.demandText, { color: demand.color }]}>
                {demand.label}
              </Text>
            </View>
          )}
          {item.group_count > 0 && (
            <Text style={styles.groupCount}>
              {item.group_count} grupo{item.group_count !== 1 ? 's' : ''}
            </Text>
          )}
          {isSelected && (
            <CheckCircle size={18} color={COLORS.green} style={{ marginLeft: 6 }} />
          )}
        </View>
      </Pressable>
    );
  };

  // ── FASE DETECCIÓN: loader animado ────────────────────────────────────────
  if (phase === 'detecting') {
    return (
      <View style={styles.detectContainer}>
        <Animated.View style={{ opacity: pulseAnim, transform: [{ scale: pulseAnim }] }}>
          <Navigation size={48} color={COLORS.green} />
        </Animated.View>
        <Text style={styles.detectTitle}>Detectando tu ubicación…</Text>
        <Text style={styles.detectSub}>
          Esto solo toma un momento. Usamos tu ubicación para mostrar grupos y precios locales.
        </Text>
        <ActivityIndicator color={COLORS.green} style={{ marginTop: 24 }} />
      </View>
    );
  }

  // ── FASE MANUAL: selector de ciudad ──────────────────────────────────────
  return (
    <SafeAreaView style={styles.container}>

      {/* Header */}
      <View style={styles.header}>
        <MapPin size={32} color={COLORS.green} />
        <Text style={styles.title}>
          {detectedCity
            ? `"${detectedCity}" no está disponible aún`
            : '¿En qué ciudad estás?'}
        </Text>
        <Text style={styles.subtitle}>
          {detectedCity
            ? 'Selecciona la ciudad más cercana. Esto personaliza tu experiencia.'
            : 'Esto personaliza los grupos, precios y anuncios que ves.'}
        </Text>
      </View>

      {/* Búsqueda */}
      <View style={styles.searchRow}>
        <Search size={16} color={COLORS.muted} style={{ marginRight: 8 }} />
        <TextInput
          style={styles.searchInput}
          placeholder="Buscar ciudad…"
          placeholderTextColor={COLORS.muted}
          value={search}
          onChangeText={setSearch}
          autoCapitalize="none"
          autoFocus={!!detectedCity}
        />
        {search.length > 0 && (
          <Pressable onPress={() => setSearch('')} hitSlop={8}>
            <X size={16} color={COLORS.muted} />
          </Pressable>
        )}
      </View>

      {/* Lista de ciudades */}
      {loading ? (
        <View style={styles.center}>
          <ActivityIndicator color={COLORS.green} />
        </View>
      ) : error ? (
        <View style={styles.center}>
          <Text style={styles.errorText}>{error}</Text>
          <Pressable style={styles.retryBtn} onPress={() => loadCities()}>
            <RefreshCw size={14} color={COLORS.green} />
            <Text style={styles.retryText}>Reintentar</Text>
          </Pressable>
        </View>
      ) : (
        <FlatList
          data={filtered}
          keyExtractor={item => item.id}
          renderItem={renderCity}
          contentContainerStyle={{ paddingBottom: 120 }}
          showsVerticalScrollIndicator={false}
          keyboardShouldPersistTaps="handled"
          ListEmptyComponent={
            <Text style={styles.emptyText}>
              {search.trim()
                ? `Sin resultados para "${search}"`
                : 'No hay ciudades disponibles.'}
            </Text>
          }
        />
      )}

      {/* Botón confirmar */}
      <View style={styles.footer}>
        <Pressable
          style={[styles.btn, (!selected || saving) && styles.btnDisabled]}
          onPress={handleConfirm}
          disabled={!selected || saving}
        >
          {saving ? (
            <ActivityIndicator color={COLORS.bg} size="small" />
          ) : (
            <Text style={styles.btnText}>
              {selected ? `Confirmar — ${selected.name}` : 'Selecciona una ciudad'}
            </Text>
          )}
        </Pressable>
      </View>

    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  // ── Fase detecting ──────────────────────────────────────────────────────
  detectContainer: {
    flex: 1,
    backgroundColor: COLORS.bg,
    alignItems: 'center',
    justifyContent: 'center',
    paddingHorizontal: 40,
    gap: 16,
  },
  detectTitle: {
    fontFamily: FONTS.title,
    fontSize: 22,
    color: COLORS.text,
    textAlign: 'center',
    marginTop: 8,
  },
  detectSub: {
    fontFamily: FONTS.body,
    fontSize: 14,
    color: COLORS.muted2,
    textAlign: 'center',
    lineHeight: 21,
  },

  // ── Fase manual ─────────────────────────────────────────────────────────
  container: {
    flex: 1,
    backgroundColor: COLORS.bg,
  },
  header: {
    alignItems: 'center',
    paddingTop: SPACING.xl,
    paddingHorizontal: SPACING.xl,
    paddingBottom: SPACING.lg,
    gap: 8,
  },
  title: {
    fontFamily: FONTS.title,
    fontSize: 24,
    color: COLORS.text,
    textAlign: 'center',
    marginTop: 8,
  },
  subtitle: {
    fontFamily: FONTS.body,
    fontSize: 14,
    color: COLORS.muted2,
    textAlign: 'center',
    lineHeight: 20,
  },
  searchRow: {
    flexDirection: 'row',
    alignItems: 'center',
    backgroundColor: COLORS.card,
    borderRadius: RADIUS.md,
    marginHorizontal: SPACING.lg,
    marginBottom: SPACING.sm,
    paddingHorizontal: SPACING.md,
    height: 44,
    borderWidth: 1,
    borderColor: COLORS.border,
  },
  searchInput: {
    flex: 1,
    fontFamily: FONTS.body,
    fontSize: 15,
    color: COLORS.text,
  },
  cityRow: {
    flexDirection: 'row',
    alignItems: 'center',
    marginHorizontal: SPACING.lg,
    marginVertical: 3,
    padding: SPACING.md,
    borderRadius: RADIUS.md,
    backgroundColor: COLORS.card,
    borderWidth: 1,
    borderColor: COLORS.border,
  },
  cityRowSelected: {
    borderColor: COLORS.green,
    backgroundColor: COLORS.green + '0D',
  },
  cityIcon: {
    width: 36,
    height: 36,
    borderRadius: 18,
    backgroundColor: COLORS.card2,
    alignItems: 'center',
    justifyContent: 'center',
    marginRight: 12,
  },
  cityInfo: {
    flex: 1,
  },
  cityName: {
    fontFamily: FONTS.bodySemiBold,
    fontSize: 15,
    color: COLORS.text,
  },
  cityState: {
    fontFamily: FONTS.body,
    fontSize: 12,
    color: COLORS.muted,
    marginTop: 1,
  },
  cityMeta: {
    alignItems: 'flex-end',
    gap: 4,
  },
  demandBadge: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 3,
    paddingHorizontal: 6,
    paddingVertical: 2,
    borderRadius: 6,
  },
  demandText: {
    fontFamily: FONTS.bodyMedium,
    fontSize: 10,
  },
  groupCount: {
    fontFamily: FONTS.body,
    fontSize: 11,
    color: COLORS.muted,
  },
  center: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
  },
  emptyText: {
    fontFamily: FONTS.body,
    fontSize: 14,
    color: COLORS.muted,
    textAlign: 'center',
    marginTop: 40,
  },
  errorText: {
    fontFamily: FONTS.body,
    fontSize: 13,
    color: '#FF4D4F',
    textAlign: 'center',
    marginHorizontal: SPACING.xl,
    marginBottom: 8,
  },
  retryBtn: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 6,
    marginTop: 12,
    paddingHorizontal: 16,
    paddingVertical: 8,
    borderRadius: RADIUS.md,
    borderWidth: 1,
    borderColor: COLORS.green,
  },
  retryText: {
    fontFamily: FONTS.bodyMedium,
    fontSize: 14,
    color: COLORS.green,
  },
  footer: {
    position: 'absolute',
    bottom: 0,
    left: 0,
    right: 0,
    padding: SPACING.lg,
    backgroundColor: COLORS.bg,
    borderTopWidth: 1,
    borderTopColor: COLORS.border,
  },
  btn: {
    backgroundColor: COLORS.green,
    borderRadius: RADIUS.md,
    height: 50,
    alignItems: 'center',
    justifyContent: 'center',
  },
  btnDisabled: {
    opacity: 0.4,
  },
  btnText: {
    fontFamily: FONTS.bodySemiBold,
    fontSize: 16,
    color: COLORS.bg,
  },
});
