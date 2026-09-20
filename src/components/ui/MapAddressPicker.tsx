import * as Location from 'expo-location';
import { MapPin, Navigation, Search, X } from 'lucide-react-native';
import React, { useCallback, useEffect, useRef, useState } from 'react';
import {
  ActivityIndicator,
  FlatList,
  Keyboard,
  Modal,
  Pressable,
  StyleSheet,
  Text,
  TextInput,
  View,
} from 'react-native';
import MapView, { PROVIDER_GOOGLE, Region } from 'react-native-maps';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { COLORS, FONTS, RADIUS } from '../../config/theme';
import { EARTH_STYLE } from '../../constants/mapStyle';

export interface AddressResult {
  address: string;
  city: string;
  municipio: string;
  estado: string;
  latitude: number;
  longitude: number;
}

interface Props {
  visible: boolean;
  onConfirm: (result: AddressResult) => void;
  onClose: () => void;
  initialLatitude?: number;
  initialLongitude?: number;
}

// Default center: Mexico City
const DEFAULT_REGION: Region = {
  latitude: 19.432608,
  longitude: -99.133209,
  latitudeDelta: 0.015,
  longitudeDelta: 0.015,
};

export default function MapAddressPicker({
  visible,
  onConfirm,
  onClose,
  initialLatitude,
  initialLongitude,
}: Props) {
  const insets = useSafeAreaInsets();
  const mapRef = useRef<MapView>(null);

  // Center coords tracked from onRegionChangeComplete
  const centerRef = useRef({ lat: DEFAULT_REGION.latitude, lng: DEFAULT_REGION.longitude });

  const [detectedAddress,   setDetectedAddress]   = useState('');
  const [detectedCity,      setDetectedCity]      = useState('');
  const [detectedMunicipio, setDetectedMunicipio] = useState('');
  const [detectedEstado,    setDetectedEstado]    = useState('');
  const [isGeocoding,       setIsGeocoding]       = useState(false);

  const [searchText,    setSearchText]    = useState('');
  const [searchResults, setSearchResults] = useState<any[]>([]);
  const [isSearching,   setIsSearching]   = useState(false);
  const [showResults,   setShowResults]   = useState(false);

  const geocodeTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const searchTimer  = useRef<ReturnType<typeof setTimeout> | null>(null);

  // ── On open: move to initial coords or user GPS ──────────────────────────
  useEffect(() => {
    if (!visible) return;
    if (initialLatitude && initialLongitude) {
      centerRef.current = { lat: initialLatitude, lng: initialLongitude };
      const r: Region = { latitude: initialLatitude, longitude: initialLongitude, latitudeDelta: 0.01, longitudeDelta: 0.01 };
      setTimeout(() => mapRef.current?.animateToRegion(r, 400), 300);
      doReverseGeocode(initialLatitude, initialLongitude);
    } else {
      goToUserLocation();
    }
  }, [visible]);

  // ── GPS: move map to current user position ────────────────────────────────
  const goToUserLocation = useCallback(async () => {
    try {
      const { status } = await Location.requestForegroundPermissionsAsync();
      if (status !== 'granted') return;
      const pos = await Location.getCurrentPositionAsync({ accuracy: Location.Accuracy.Balanced });
      centerRef.current = { lat: pos.coords.latitude, lng: pos.coords.longitude };
      const r: Region = {
        latitude: pos.coords.latitude,
        longitude: pos.coords.longitude,
        latitudeDelta: 0.01,
        longitudeDelta: 0.01,
      };
      mapRef.current?.animateToRegion(r, 600);
      doReverseGeocode(pos.coords.latitude, pos.coords.longitude);
    } catch (_) {}
  }, []);

  // ── Reverse geocode center of map ─────────────────────────────────────────
  const doReverseGeocode = useCallback(async (lat: number, lng: number) => {
    setIsGeocoding(true);
    setDetectedAddress('');
    try {
      const [geo] = await Location.reverseGeocodeAsync({ latitude: lat, longitude: lng });
      if (geo) {
        const streetParts = [geo.street, geo.streetNumber].filter(Boolean);
        const street = streetParts.join(' ');
        const colony = (geo as any).sublocality ?? (geo as any).neighborhood ?? '';
        const full = [street, colony].filter(Boolean).join(', ');
        setDetectedAddress(full || geo.name || '');
        setDetectedCity(geo.city ?? geo.subregion ?? '');
        setDetectedMunicipio(geo.subregion ?? geo.district ?? geo.city ?? '');
        setDetectedEstado(geo.region ?? '');
      }
    } catch (_) {}
    setIsGeocoding(false);
  }, []);

  // ── Map drag ended ────────────────────────────────────────────────────────
  const onRegionChangeComplete = useCallback((r: Region) => {
    centerRef.current = { lat: r.latitude, lng: r.longitude };
    if (geocodeTimer.current) clearTimeout(geocodeTimer.current);
    geocodeTimer.current = setTimeout(() => {
      doReverseGeocode(r.latitude, r.longitude);
    }, 450);
  }, [doReverseGeocode]);

  // ── Nominatim search ──────────────────────────────────────────────────────
  const handleSearch = useCallback((text: string) => {
    setSearchText(text);
    setShowResults(false);
    if (searchTimer.current) clearTimeout(searchTimer.current);
    if (text.trim().length < 3) { setSearchResults([]); return; }
    searchTimer.current = setTimeout(async () => {
      setIsSearching(true);
      try {
        const url =
          `https://nominatim.openstreetmap.org/search?q=${encodeURIComponent(text)}` +
          `&format=json&limit=5&countrycodes=mx&addressdetails=1`;
        const res  = await fetch(url, {
          headers: { 'Accept-Language': 'es', 'User-Agent': 'MusicHomeApp/1.0' },
        });
        const data = await res.json();
        setSearchResults(data);
        setShowResults(true);
      } catch (_) {}
      setIsSearching(false);
    }, 650);
  }, []);

  const selectSearchResult = useCallback((item: any) => {
    const lat = parseFloat(item.lat);
    const lng = parseFloat(item.lon);
    centerRef.current = { lat, lng };
    const r: Region = { latitude: lat, longitude: lng, latitudeDelta: 0.01, longitudeDelta: 0.01 };
    mapRef.current?.animateToRegion(r, 600);
    setSearchText(item.display_name?.split(',')[0] ?? '');
    setShowResults(false);
    Keyboard.dismiss();
    doReverseGeocode(lat, lng);
  }, [doReverseGeocode]);

  // ── Confirm ───────────────────────────────────────────────────────────────
  const handleConfirm = () => {
    onConfirm({
      address:   detectedAddress,
      city:      detectedCity,
      municipio: detectedMunicipio,
      estado:    detectedEstado,
      latitude:  centerRef.current.lat,
      longitude: centerRef.current.lng,
    });
  };

  const canConfirm = !!detectedAddress && !isGeocoding;

  // ── Render ────────────────────────────────────────────────────────────────
  return (
    <Modal visible={visible} animationType="slide" statusBarTranslucent hardwareAccelerated>
      <View style={s.container}>

        {/* ── Map ── */}
        <MapView
          ref={mapRef}
          style={StyleSheet.absoluteFill}
          provider={PROVIDER_GOOGLE}
          customMapStyle={EARTH_STYLE}
          userInterfaceStyle="dark"
          initialRegion={DEFAULT_REGION}
          onRegionChangeComplete={onRegionChangeComplete}
          showsUserLocation
          showsMyLocationButton={false}
          showsCompass={false}
        />

        {/* ── Fixed center pin — contorno blanco para contrastar sobre el mapa oscuro ── */}
        <View style={s.pinWrapper} pointerEvents="none">
          <MapPin size={44} color="#ffffff" fill="#E53935" strokeWidth={1.5} />
          <View style={s.pinDot} />
        </View>

        {/* ── Top bar ── */}
        <View style={[s.topBar, { top: insets.top + 8 }]}>
          <Pressable style={s.closeBtn} onPress={onClose}>
            <X size={20} color={COLORS.text} />
          </Pressable>

          <View style={s.searchBox}>
            <Search size={15} color={COLORS.muted2} />
            <TextInput
              style={s.searchInput}
              placeholder="Buscar dirección..."
              placeholderTextColor={COLORS.muted}
              value={searchText}
              onChangeText={handleSearch}
              returnKeyType="search"
              onSubmitEditing={() => searchResults[0] && selectSearchResult(searchResults[0])}
            />
            {isSearching
              ? <ActivityIndicator size="small" color={COLORS.green} />
              : searchText.length > 0 && (
                <Pressable onPress={() => { setSearchText(''); setSearchResults([]); setShowResults(false); }}>
                  <X size={14} color={COLORS.muted} />
                </Pressable>
              )
            }
          </View>
        </View>

        {/* ── Search results ── */}
        {showResults && searchResults.length > 0 && (
          <View style={[s.resultsBox, { top: insets.top + 72 }]}>
            <FlatList
              data={searchResults}
              keyExtractor={(_, i) => String(i)}
              keyboardShouldPersistTaps="handled"
              renderItem={({ item }) => (
                <Pressable style={s.resultItem} onPress={() => selectSearchResult(item)}>
                  <MapPin size={13} color={COLORS.green} style={{ marginTop: 2 }} />
                  <Text style={s.resultText} numberOfLines={2}>{item.display_name}</Text>
                </Pressable>
              )}
            />
          </View>
        )}

        {/* ── My location button ── */}
        <Pressable style={[s.myLocBtn, { bottom: 196 }]} onPress={goToUserLocation}>
          <Navigation size={20} color={COLORS.green} />
        </Pressable>

        {/* ── Bottom card ── */}
        <View style={[s.bottomCard, { paddingBottom: insets.bottom + 12 }]}>
          <View style={s.cardHandle} />

          {isGeocoding ? (
            <View style={s.geocodingRow}>
              <ActivityIndicator size="small" color={COLORS.green} />
              <Text style={s.geocodingText}>Detectando dirección…</Text>
            </View>
          ) : (
            <View style={s.addressRow}>
              <MapPin size={18} color={COLORS.green} style={{ marginTop: 2, flexShrink: 0 }} />
              <View style={{ flex: 1 }}>
                <Text style={s.addressText} numberOfLines={2}>
                  {detectedAddress || 'Mueve el mapa para seleccionar un punto'}
                </Text>
                {(detectedMunicipio || detectedEstado) ? (
                  <Text style={s.addressSub}>
                    {[detectedMunicipio, detectedEstado].filter(Boolean).join(', ')}
                  </Text>
                ) : null}
              </View>
            </View>
          )}

          <Pressable
            style={[s.confirmBtn, !canConfirm && s.confirmBtnDisabled]}
            onPress={handleConfirm}
            disabled={!canConfirm}
          >
            <Text style={s.confirmBtnText}>✅ Confirmar esta dirección</Text>
          </Pressable>

          <Pressable style={s.manualBtn} onPress={onClose}>
            <Text style={s.manualBtnText}>Escribir dirección manualmente</Text>
          </Pressable>
        </View>

      </View>
    </Modal>
  );
}

// ─── Styles ──────────────────────────────────────────────────────────────────

const s = StyleSheet.create({
  container: { flex: 1, backgroundColor: '#000' },

  // Pin centered on map
  pinWrapper: {
    position: 'absolute',
    top: '50%',
    left: '50%',
    marginTop: -52,   // pin height (44) + dot (6) + gap (2)
    marginLeft: -22,  // half of pin width (44)
    alignItems: 'center',
  },
  pinDot: {
    width: 8, height: 8, borderRadius: 4,
    backgroundColor: 'rgba(229,57,53,0.5)',
    marginTop: 2,
  },

  // Top bar
  topBar: {
    position: 'absolute',
    left: 12, right: 12,
    flexDirection: 'row',
    alignItems: 'center',
    gap: 10,
  },
  closeBtn: {
    width: 42, height: 42, borderRadius: 21,
    backgroundColor: COLORS.card,
    alignItems: 'center', justifyContent: 'center',
    borderWidth: 1, borderColor: COLORS.border,
  },
  searchBox: {
    flex: 1, flexDirection: 'row', alignItems: 'center', gap: 8,
    backgroundColor: COLORS.card,
    borderRadius: 24, borderWidth: 1, borderColor: COLORS.border,
    paddingHorizontal: 14, height: 42,
  },
  searchInput: {
    flex: 1,
    fontFamily: FONTS.body,
    fontSize: 14,
    color: COLORS.text,
  },

  // Search results
  resultsBox: {
    position: 'absolute',
    left: 64, right: 12,
    backgroundColor: COLORS.card,
    borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border,
    maxHeight: 220,
    overflow: 'hidden',
  },
  resultItem: {
    flexDirection: 'row', alignItems: 'flex-start', gap: 8,
    paddingHorizontal: 14, paddingVertical: 11,
    borderBottomWidth: 1, borderBottomColor: COLORS.border,
  },
  resultText: {
    flex: 1,
    fontFamily: FONTS.body, fontSize: 13, color: COLORS.text, lineHeight: 18,
  },

  // My location button — oscuro, consistente con el tema
  myLocBtn: {
    position: 'absolute',
    right: 16,
    width: 46, height: 46, borderRadius: 23,
    backgroundColor: COLORS.card,
    borderWidth: 1, borderColor: COLORS.border,
    alignItems: 'center', justifyContent: 'center',
    shadowColor: '#000', shadowOffset: { width: 0, height: 2 },
    shadowOpacity: 0.25, shadowRadius: 4,
    elevation: 5,
  },

  // Bottom card
  bottomCard: {
    position: 'absolute',
    bottom: 0, left: 0, right: 0,
    backgroundColor: COLORS.card,
    borderTopLeftRadius: 24, borderTopRightRadius: 24,
    borderTopWidth: 1, borderTopColor: COLORS.border,
    paddingTop: 8, paddingHorizontal: 20,
  },
  cardHandle: {
    width: 36, height: 4, borderRadius: 2,
    backgroundColor: COLORS.border,
    alignSelf: 'center', marginBottom: 16,
  },

  geocodingRow: {
    flexDirection: 'row', alignItems: 'center', gap: 10,
    paddingVertical: 10, marginBottom: 8,
  },
  geocodingText: { fontFamily: FONTS.body, fontSize: 14, color: COLORS.muted },

  addressRow: {
    flexDirection: 'row', alignItems: 'flex-start', gap: 10,
    marginBottom: 16,
  },
  addressText: {
    fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.text, lineHeight: 20,
  },
  addressSub: {
    fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, marginTop: 3,
  },

  confirmBtn: {
    backgroundColor: COLORS.green,
    borderRadius: RADIUS.lg,
    paddingVertical: 15,
    alignItems: 'center',
    marginBottom: 10,
  },
  confirmBtnDisabled: { backgroundColor: COLORS.border },
  confirmBtnText: {
    fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.bg,
  },

  manualBtn: { alignItems: 'center', paddingVertical: 8 },
  manualBtnText: {
    fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted2,
  },
});
