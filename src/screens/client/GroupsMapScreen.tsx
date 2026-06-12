/**
 * GroupsMapScreen — Mapa de grupos disponibles
 * Accessible by both client and group roles.
 */
import { LinearGradient } from 'expo-linear-gradient';
import * as Location from 'expo-location';
import { ArrowLeft, MapPin, Music2, Navigation, Search, X } from 'lucide-react-native';
import React, { useEffect, useRef, useState } from 'react';
import {
  ActivityIndicator,
  Alert,
  Animated,
  Dimensions,
  Image,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  View,
} from 'react-native';
import MapView, { Marker, PROVIDER_GOOGLE } from 'react-native-maps';
import { SafeAreaView } from 'react-native-safe-area-context';
import { supabase } from '../../config/supabase';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';
import { EARTH_STYLE } from '../../constants/mapStyle';

const { height: SH, width: SW } = Dimensions.get('window');

// ─── Coordenadas de ciudades ──────────────────────────────────────────────────
const CITY_COORDS: Record<string, { lat: number; lng: number }> = {
  'zapopan':            { lat: 20.7167, lng: -103.3833 },
  'guadalajara':        { lat: 20.6597, lng: -103.3496 },
  'tlaquepaque':        { lat: 20.6419, lng: -103.3117 },
  'tonalá':             { lat: 20.6236, lng: -103.2347 },
  'tonala':             { lat: 20.6236, lng: -103.2347 },
  'puerto vallarta':    { lat: 20.6534, lng: -105.2253 },
  'ciudad de méxico':   { lat: 19.4326, lng: -99.1332 },
  'cdmx':               { lat: 19.4326, lng: -99.1332 },
  'monterrey':          { lat: 25.6866, lng: -100.3161 },
  'puebla':             { lat: 19.0414, lng: -98.2063 },
  'tijuana':            { lat: 32.5149, lng: -117.0382 },
  'león':               { lat: 21.1221, lng: -101.6826 },
  'leon':               { lat: 21.1221, lng: -101.6826 },
  'chihuahua':          { lat: 28.6330, lng: -106.0691 },
  'aguascalientes':     { lat: 21.8818, lng: -102.2916 },
  'mérida':             { lat: 20.9674, lng: -89.5926 },
  'merida':             { lat: 20.9674, lng: -89.5926 },
  'cancún':             { lat: 21.1619, lng: -86.8515 },
  'cancun':             { lat: 21.1619, lng: -86.8515 },
  'veracruz':           { lat: 19.1738, lng: -96.1342 },
  'querétaro':          { lat: 20.5888, lng: -100.3899 },
  'queretaro':          { lat: 20.5888, lng: -100.3899 },
  'hermosillo':         { lat: 29.0729, lng: -110.9559 },
  'morelia':            { lat: 19.7060, lng: -101.1950 },
  'oaxaca':             { lat: 17.0732, lng: -96.7266 },
  'mazatlán':           { lat: 23.2494, lng: -106.4111 },
  'mazatlan':           { lat: 23.2494, lng: -106.4111 },
  'saltillo':           { lat: 25.4270, lng: -101.0034 },
  'durango':            { lat: 24.0277, lng: -104.6532 },
  'culiacán':           { lat: 24.8091, lng: -107.3940 },
  'culiacan':           { lat: 24.8091, lng: -107.3940 },
  'torreón':            { lat: 25.5428, lng: -103.4068 },
  'torreon':            { lat: 25.5428, lng: -103.4068 },
  'tepic':              { lat: 21.5051, lng: -104.8954 },
  'san luis potosí':    { lat: 22.1565, lng: -100.9855 },
  'san luis potosi':    { lat: 22.1565, lng: -100.9855 },
  'zacatecas':          { lat: 22.7709, lng: -102.5832 },
  'toluca':             { lat: 19.2826, lng: -99.6557 },
  'cuernavaca':         { lat: 18.9261, lng: -99.2305 },
  'acapulco':           { lat: 16.8531, lng: -99.8237 },
  'irapuato':           { lat: 20.6735, lng: -101.3548 },
  'celaya':             { lat: 20.5234, lng: -100.8119 },
};

const GENRE_EMOJIS: Record<string, string> = {
  'Norteño':            '🪗',
  'Banda':              '🎺',
  'Mariachi':           '🎻',
  'Grupero':            '🎸',
  'Cumbia':             '🥁',
  'Salsa':              '💃',
  'Jazz':               '🎷',
  'Rock':               '🤘',
  'Pop':                '🎤',
  'Regional Mexicano':  '🇲🇽',
  'Tropical':           '🌴',
  'Ranchero':           '🤠',
  'Electrónica':        '🎧',
  'Otro':               '🎵',
};

const GENRE_COLORS: Record<string, string> = {
  'Norteño':            '#F59E0B',
  'Banda':              '#EF4444',
  'Mariachi':           '#10B981',
  'Grupero':            '#8B5CF6',
  'Cumbia':             '#F97316',
  'Salsa':              '#EC4899',
  'Jazz':               '#06B6D4',
  'Rock':               '#6366F1',
  'Pop':                '#A78BFA',
  'Regional Mexicano':  '#22C55E',
  'Tropical':           '#14B8A6',
  'Ranchero':           '#D97706',
  'Electrónica':        '#3B82F6',
  'Otro':               COLORS.green,
};

function seededRand(seed: string, idx: number): number {
  let h = 0xdeadbeef;
  const s = seed + '|' + idx;
  for (let i = 0; i < s.length; i++) h = Math.imul(h ^ s.charCodeAt(i), 0x9e3779b9);
  h ^= h >>> 16;
  return (h >>> 0) / 0xffffffff;
}

function approxCoord(id: string, city: string): { latitude: number; longitude: number } {
  const key = city.toLowerCase().trim();
  let base = CITY_COORDS[key];
  if (!base) {
    for (const [k, v] of Object.entries(CITY_COORDS)) {
      if (key.includes(k) || k.includes(key)) { base = v; break; }
    }
  }
  if (!base) {
    let h = 5381;
    for (let i = 0; i < id.length; i++) h = ((h << 5) + h + id.charCodeAt(i)) | 0;
    base = { lat: 20 + (Math.abs(h) % 8000) / 1000, lng: -104 + (Math.abs(h * 79) % 14000) / 1000 };
  }
  const angle   = seededRand(id, 1) * 2 * Math.PI;
  const distDeg = 0.005 + seededRand(id, 2) * 0.008;
  return {
    latitude:  base.lat + Math.sin(angle) * distDeg,
    longitude: base.lng + Math.cos(angle) * distDeg,
  };
}

// Estilo unificado en src/constants/mapStyle.ts
const DARK_MAP_STYLE = EARTH_STYLE;

interface GroupPin {
  id: string;
  name: string;
  genre: string;
  city: string;
  profile_image: string | null;
  price_from?: number | null;
  coord: { latitude: number; longitude: number };
}

// ─── Marker animado ───────────────────────────────────────────────────────────
function GroupMarker({ group, selected, onPress }: {
  group: GroupPin;
  selected: boolean;
  onPress: () => void;
}) {
  const scaleAnim  = useRef(new Animated.Value(0.8)).current;
  const glowAnim   = useRef(new Animated.Value(0)).current;
  const accentColor = GENRE_COLORS[group.genre] ?? COLORS.green;

  useEffect(() => {
    Animated.spring(scaleAnim, { toValue: 1, friction: 5, useNativeDriver: true }).start();
  }, []);

  useEffect(() => {
    if (selected) {
      Animated.loop(
        Animated.sequence([
          Animated.timing(glowAnim, { toValue: 1, duration: 700, useNativeDriver: true }),
          Animated.timing(glowAnim, { toValue: 0.4, duration: 700, useNativeDriver: true }),
        ])
      ).start();
      Animated.spring(scaleAnim, { toValue: 1.25, friction: 4, useNativeDriver: true }).start();
    } else {
      glowAnim.stopAnimation();
      Animated.spring(scaleAnim, { toValue: 1, friction: 5, useNativeDriver: true }).start();
      glowAnim.setValue(0);
    }
  }, [selected]);

  const emoji = GENRE_EMOJIS[group.genre] ?? '🎵';

  return (
    <Marker
      coordinate={group.coord}
      anchor={{ x: 0.5, y: 0.5 }}
      onPress={onPress}
      tracksViewChanges={false}
    >
      <Animated.View style={{ transform: [{ scale: scaleAnim }], alignItems: 'center' }}>
        {/* Glow ring when selected */}
        {selected && (
          <Animated.View style={[
            gms.pinGlow,
            { borderColor: accentColor, opacity: glowAnim },
          ]} />
        )}
        {/* Pin body */}
        <View style={[
          gms.pin,
          { borderColor: selected ? accentColor : `${accentColor}66` },
          selected && { backgroundColor: `${accentColor}22` },
        ]}>
          {group.profile_image ? (
            <Image source={{ uri: group.profile_image }} style={gms.pinPhoto} />
          ) : (
            <Text style={gms.pinEmoji}>{emoji}</Text>
          )}
        </View>
        {/* Genre dot */}
        <View style={[gms.pinDot, { backgroundColor: accentColor }]} />
      </Animated.View>
    </Marker>
  );
}

// ─── Screen ───────────────────────────────────────────────────────────────────
export default function GroupsMapScreen({ navigation }: any) {
  const [groups,      setGroups]      = useState<GroupPin[]>([]);
  const [loading,     setLoading]     = useState(true);
  const [selected,    setSelected]    = useState<GroupPin | null>(null);
  const [genreFilter, setGenreFilter] = useState<string | null>(null);
  const [searchText,  setSearchText]  = useState('');
  const [locating,    setLocating]    = useState(false);
  const [showSearch,  setShowSearch]  = useState(false);

  const mapRef      = useRef<MapView>(null);
  const cardAnim    = useRef(new Animated.Value(0)).current;
  const headerAnim  = useRef(new Animated.Value(0)).current;

  useEffect(() => {
    Animated.timing(headerAnim, { toValue: 1, duration: 400, useNativeDriver: true }).start();
    (async () => {
      const { data } = await supabase
        .from('groups')
        .select('id, name, genre, city, profile_image, price_from')
        .eq('is_active', true);

      const pins: GroupPin[] = (data ?? []).map((g: any) => ({
        id:            g.id,
        name:          g.name,
        genre:         g.genre ?? 'Otro',
        city:          g.city ?? '',
        profile_image: g.profile_image ?? null,
        price_from:    g.price_from ?? null,
        coord:         approxCoord(g.id, g.city ?? ''),
      }));
      setGroups(pins);
      setLoading(false);
    })();
  }, []);

  // Animate info card when group selected
  useEffect(() => {
    if (selected) {
      Animated.spring(cardAnim, { toValue: 1, friction: 8, useNativeDriver: true }).start();
      // Center map on selected group
      mapRef.current?.animateToRegion({
        latitude:       selected.coord.latitude - 0.012,
        longitude:      selected.coord.longitude,
        latitudeDelta:  0.05,
        longitudeDelta: 0.05,
      }, 500);
    } else {
      Animated.timing(cardAnim, { toValue: 0, duration: 200, useNativeDriver: true }).start();
    }
  }, [selected]);

  const allGenres = [...new Set(groups.map(g => g.genre))].sort();

  const visible = groups.filter(g => {
    const matchGenre = !genreFilter || g.genre === genreFilter;
    const matchSearch = !searchText || g.name.toLowerCase().includes(searchText.toLowerCase()) ||
      g.city.toLowerCase().includes(searchText.toLowerCase());
    return matchGenre && matchSearch;
  });

  const handleNearMe = async () => {
    setLocating(true);
    try {
      const { status } = await Location.requestForegroundPermissionsAsync();
      if (status !== 'granted') {
        Alert.alert('Permiso necesario', 'Activa la ubicación para ver grupos cercanos a ti.');
        setLocating(false);
        return;
      }
      const pos = await Location.getCurrentPositionAsync({ accuracy: Location.Accuracy.Balanced });
      mapRef.current?.animateToRegion({
        latitude:       pos.coords.latitude,
        longitude:      pos.coords.longitude,
        latitudeDelta:  0.4,
        longitudeDelta: 0.4,
      }, 900);
    } catch {
      Alert.alert('Error', 'No se pudo obtener tu ubicación.');
    }
    setLocating(false);
  };

  const accentColor = selected ? (GENRE_COLORS[selected.genre] ?? COLORS.green) : COLORS.green;

  return (
    <View style={gms.root}>
      {/* ── Header ──────────────────────────────────────────────── */}
      <SafeAreaView edges={['top']} style={gms.headerWrap}>
        <Animated.View style={[gms.header, { opacity: headerAnim }]}>
          <Pressable style={gms.backBtn} onPress={() => navigation.goBack()}>
            <ArrowLeft size={20} color={COLORS.text} />
          </Pressable>

          {showSearch ? (
            <View style={gms.searchBox}>
              <Search size={15} color={COLORS.muted2} />
              <TextInput
                style={gms.searchInput}
                placeholder="Buscar grupo o ciudad..."
                placeholderTextColor={COLORS.muted}
                value={searchText}
                onChangeText={setSearchText}
                autoFocus
              />
              {searchText.length > 0 && (
                <Pressable onPress={() => setSearchText('')}>
                  <X size={15} color={COLORS.muted2} />
                </Pressable>
              )}
            </View>
          ) : (
            <View style={{ flex: 1 }}>
              <Text style={gms.headerTitle}>Explorar grupos</Text>
              <Text style={gms.headerSub}>
                {loading ? 'Buscando...' : `${visible.length} grupo${visible.length !== 1 ? 's' : ''} disponibles`}
              </Text>
            </View>
          )}

          <Pressable
            style={gms.searchBtn}
            onPress={() => { setShowSearch(v => !v); if (showSearch) setSearchText(''); }}
          >
            {showSearch ? <X size={18} color={COLORS.green} /> : <Search size={18} color={COLORS.green} />}
          </Pressable>
        </Animated.View>

        {/* Genre filters */}
        <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={gms.filterScroll}>
          <Pressable
            style={[gms.filterChip, !genreFilter && gms.filterChipActive]}
            onPress={() => setGenreFilter(null)}
          >
            <Text style={[gms.filterChipText, !genreFilter && gms.filterChipTextActive]}>
              🎵 Todos ({groups.length})
            </Text>
          </Pressable>
          {allGenres.map(g => {
            const count  = groups.filter(gr => gr.genre === g).length;
            const color  = GENRE_COLORS[g] ?? COLORS.green;
            const active = genreFilter === g;
            return (
              <Pressable
                key={g}
                style={[
                  gms.filterChip,
                  active && { borderColor: color, backgroundColor: `${color}18` },
                ]}
                onPress={() => setGenreFilter(prev => prev === g ? null : g)}
              >
                <Text style={[gms.filterChipText, active && { color }]}>
                  {GENRE_EMOJIS[g] ?? '🎵'} {g} {count > 0 ? `(${count})` : ''}
                </Text>
              </Pressable>
            );
          })}
        </ScrollView>
      </SafeAreaView>

      {loading ? (
        <View style={gms.center}>
          <ActivityIndicator color={COLORS.green} size="large" />
          <Text style={gms.loadingText}>Buscando grupos cerca de ti...</Text>
        </View>
      ) : (
        <View style={{ flex: 1 }}>
          <MapView
            ref={mapRef}
            provider={PROVIDER_GOOGLE}
            style={gms.map}
            initialRegion={{ latitude: 22.5, longitude: -102.5, latitudeDelta: 12, longitudeDelta: 12 }}
            customMapStyle={DARK_MAP_STYLE}
            showsUserLocation
            showsMyLocationButton={false}
            toolbarEnabled={false}
            onPress={() => setSelected(null)}
          >
            {visible.map(g => (
              <GroupMarker
                key={g.id}
                group={g}
                selected={selected?.id === g.id}
                onPress={() => setSelected(selected?.id === g.id ? null : g)}
              />
            ))}
          </MapView>

          {/* Stats overlay */}
          <View style={gms.statsOverlay} pointerEvents="none">
            <View style={gms.statsBubble}>
              <Music2 size={11} color={COLORS.green} />
              <Text style={gms.statsText}>{visible.length} grupo{visible.length !== 1 ? 's' : ''}</Text>
            </View>
            {genreFilter && (
              <View style={[gms.statsBubble, { borderColor: `${GENRE_COLORS[genreFilter]}55` }]}>
                <Text style={[gms.statsText, { color: GENRE_COLORS[genreFilter] ?? COLORS.green }]}>
                  {genreFilter}
                </Text>
              </View>
            )}
          </View>

          {/* Near me button */}
          <Pressable
            style={[gms.nearMeBtn, locating && { opacity: 0.6 }]}
            onPress={handleNearMe}
            disabled={locating}
          >
            <LinearGradient
              colors={['rgba(0,230,118,0.15)', 'rgba(0,200,83,0.15)']}
              style={StyleSheet.absoluteFillObject}
            />
            {locating
              ? <ActivityIndicator size="small" color={COLORS.green} />
              : <Navigation size={16} color={COLORS.green} />
            }
            <Text style={gms.nearMeText}>
              {locating ? 'Localizando...' : 'Cerca de mí'}
            </Text>
          </Pressable>

          {/* Selected group card */}
          {selected && (
            <Animated.View style={[gms.infoCard, {
              borderColor: `${accentColor}55`,
              transform: [
                { translateY: cardAnim.interpolate({ inputRange: [0, 1], outputRange: [200, 0] }) },
              ],
              opacity: cardAnim,
            }]}>
              <LinearGradient
                colors={[`${accentColor}12`, 'transparent']}
                start={{ x: 0, y: 0 }}
                end={{ x: 1, y: 1 }}
                style={StyleSheet.absoluteFillObject}
              />

              {/* Close */}
              <Pressable style={gms.infoClose} onPress={() => setSelected(null)}>
                <X size={14} color={COLORS.muted2} />
              </Pressable>

              {/* Top row */}
              <Pressable
                style={gms.infoCardTop}
                onPress={() => navigation.navigate('GroupDetail', { group: selected })}
              >
                <View style={[gms.infoAvatarWrap, { borderColor: `${accentColor}55` }]}>
                  {selected.profile_image ? (
                    <Image source={{ uri: selected.profile_image }} style={gms.infoPhoto} />
                  ) : (
                    <View style={[gms.infoAvatarFallback, { backgroundColor: `${accentColor}20` }]}>
                      <Text style={gms.infoEmoji}>{GENRE_EMOJIS[selected.genre] ?? '🎵'}</Text>
                    </View>
                  )}
                </View>
                <View style={{ flex: 1 }}>
                  <Text style={gms.infoName} numberOfLines={1}>{selected.name}</Text>
                  <View style={gms.infoMetaRow}>
                    <View style={[gms.genreTag, { backgroundColor: `${accentColor}20`, borderColor: `${accentColor}44` }]}>
                      <Text style={[gms.genreTagText, { color: accentColor }]}>
                        {GENRE_EMOJIS[selected.genre] ?? '🎵'} {selected.genre}
                      </Text>
                    </View>
                    <View style={gms.cityTag}>
                      <MapPin size={10} color={COLORS.muted2} />
                      <Text style={gms.cityTagText}>{selected.city}</Text>
                    </View>
                  </View>
                  {selected.price_from != null && (
                    <Text style={gms.priceTag}>
                      Desde <Text style={{ color: accentColor, fontFamily: FONTS.bodySemiBold }}>
                        ${selected.price_from.toLocaleString()}
                      </Text>
                    </Text>
                  )}
                </View>
              </Pressable>

              {/* Buttons */}
              <View style={gms.infoBtnRow}>
                <Pressable
                  style={gms.profileBtn}
                  onPress={() => navigation.navigate('GroupDetail', { group: selected })}
                >
                  <Text style={gms.profileBtnText}>Ver perfil</Text>
                </Pressable>
                <Pressable
                  style={[gms.quoteBtn, { backgroundColor: accentColor }]}
                  onPress={() => navigation.navigate('QuoteForm', { group: selected })}
                >
                  <Text style={gms.quoteBtnText}>Pedir cotización</Text>
                </Pressable>
              </View>
            </Animated.View>
          )}

          {/* Empty state for filter */}
          {!loading && visible.length === 0 && (
            <View style={gms.emptyOverlay} pointerEvents="none">
              <View style={gms.emptyCard}>
                <Text style={gms.emptyEmoji}>🎵</Text>
                <Text style={gms.emptyText}>
                  {genreFilter
                    ? `No hay grupos de ${genreFilter} disponibles`
                    : 'No hay grupos disponibles'}
                </Text>
              </View>
            </View>
          )}
        </View>
      )}
    </View>
  );
}

// ─── Styles ──────────────────────────────────────────────────────────────────
const gms = StyleSheet.create({
  root:        { flex: 1, backgroundColor: COLORS.bg },
  center:      { flex: 1, alignItems: 'center', justifyContent: 'center', gap: 14 },
  loadingText: { fontFamily: FONTS.body, fontSize: 14, color: COLORS.muted2 },

  headerWrap: {
    borderBottomWidth: 1, borderBottomColor: COLORS.border,
    backgroundColor: COLORS.bg,
  },
  header: {
    flexDirection: 'row', alignItems: 'center', gap: 12,
    paddingHorizontal: SPACING.lg, paddingTop: 6, paddingBottom: 10,
  },
  backBtn: {
    width: 38, height: 38, borderRadius: 11,
    backgroundColor: COLORS.card, borderWidth: 1, borderColor: COLORS.border,
    alignItems: 'center', justifyContent: 'center',
  },
  headerTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 17, color: COLORS.text },
  headerSub:   { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted2, marginTop: 1 },

  searchBtn: {
    width: 38, height: 38, borderRadius: 11,
    backgroundColor: 'rgba(0,230,118,0.08)', borderWidth: 1, borderColor: 'rgba(0,230,118,0.25)',
    alignItems: 'center', justifyContent: 'center',
  },
  searchBox: {
    flex: 1, flexDirection: 'row', alignItems: 'center', gap: 8,
    backgroundColor: COLORS.card, borderRadius: 10,
    borderWidth: 1, borderColor: COLORS.border,
    paddingHorizontal: 12, height: 38,
  },
  searchInput: {
    flex: 1, fontFamily: FONTS.body, fontSize: 14, color: COLORS.text,
  },

  filterScroll:       { paddingHorizontal: SPACING.lg, paddingVertical: 8, gap: 8 },
  filterChip: {
    paddingHorizontal: 12, paddingVertical: 7,
    borderRadius: RADIUS.full,
    backgroundColor: COLORS.card2, borderWidth: 1, borderColor: COLORS.border,
  },
  filterChipActive:     { borderColor: COLORS.green, backgroundColor: 'rgba(0,230,118,0.10)' },
  filterChipText:       { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.muted2 },
  filterChipTextActive: { color: COLORS.green },

  map: { flex: 1 },

  // Marker
  pin: {
    width: 44, height: 44, borderRadius: 22,
    alignItems: 'center', justifyContent: 'center',
    backgroundColor: 'rgba(10,10,10,0.92)',
    borderWidth: 2.5, borderColor: 'rgba(0,230,118,0.5)',
    shadowColor: '#000', shadowOpacity: 0.5, shadowOffset: { width: 0, height: 3 }, shadowRadius: 6,
    elevation: 6,
  },
  pinGlow: {
    position: 'absolute',
    width: 58, height: 58, borderRadius: 29,
    borderWidth: 2, borderColor: COLORS.green,
    top: -7, left: -7,
  },
  pinDot: {
    width: 7, height: 7, borderRadius: 3.5,
    marginTop: -3,
  },
  pinEmoji: { fontSize: 22 },
  pinPhoto: { width: 40, height: 40, borderRadius: 20 },

  // Stats overlay
  statsOverlay: {
    position: 'absolute', top: 12, left: 12,
    flexDirection: 'row', gap: 6, flexWrap: 'wrap',
  },
  statsBubble: {
    flexDirection: 'row', alignItems: 'center', gap: 5,
    backgroundColor: 'rgba(4,4,4,0.80)',
    borderRadius: RADIUS.full, borderWidth: 1, borderColor: 'rgba(0,230,118,0.30)',
    paddingHorizontal: 10, paddingVertical: 5,
  },
  statsText: { fontFamily: FONTS.bodyMedium, fontSize: 11, color: COLORS.green },

  // Near me
  nearMeBtn: {
    position: 'absolute', bottom: 28, right: 14,
    flexDirection: 'row', alignItems: 'center', gap: 7,
    backgroundColor: 'rgba(6,6,6,0.92)',
    borderRadius: RADIUS.full, borderWidth: 1.5, borderColor: 'rgba(0,230,118,0.40)',
    paddingHorizontal: 16, paddingVertical: 11,
    overflow: 'hidden',
    shadowColor: COLORS.green, shadowOpacity: 0.3,
    shadowOffset: { width: 0, height: 4 }, shadowRadius: 10,
    elevation: 8,
  },
  nearMeText: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.green },

  // Info card
  infoCard: {
    position: 'absolute', bottom: 20, left: 14, right: 14,
    backgroundColor: COLORS.card,
    borderRadius: RADIUS.xl, borderWidth: 1.5,
    padding: 16, gap: 14,
    overflow: 'hidden',
    shadowColor: '#000', shadowOpacity: 0.4,
    shadowOffset: { width: 0, height: 8 }, shadowRadius: 20,
    elevation: 12,
  },
  infoClose: {
    position: 'absolute', top: 10, right: 10,
    width: 26, height: 26, borderRadius: 13,
    backgroundColor: COLORS.card2, borderWidth: 1, borderColor: COLORS.border,
    alignItems: 'center', justifyContent: 'center',
    zIndex: 10,
  },
  infoCardTop: {
    flexDirection: 'row', alignItems: 'center', gap: 12,
  },
  infoAvatarWrap: {
    width: 54, height: 54, borderRadius: 27,
    borderWidth: 2, overflow: 'hidden',
  },
  infoAvatarFallback: {
    width: 54, height: 54, alignItems: 'center', justifyContent: 'center',
  },
  infoEmoji:    { fontSize: 26 },
  infoPhoto:    { width: 54, height: 54 },
  infoName:     { fontFamily: FONTS.bodySemiBold, fontSize: 16, color: COLORS.text, marginBottom: 5 },
  infoMetaRow:  { flexDirection: 'row', alignItems: 'center', gap: 6, flexWrap: 'wrap' },
  genreTag: {
    flexDirection: 'row', alignItems: 'center', gap: 3,
    borderRadius: RADIUS.full, borderWidth: 1,
    paddingHorizontal: 8, paddingVertical: 3,
  },
  genreTagText: { fontFamily: FONTS.bodyMedium, fontSize: 11 },
  cityTag: {
    flexDirection: 'row', alignItems: 'center', gap: 3,
  },
  cityTagText:  { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted2 },
  priceTag:     { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, marginTop: 3 },

  infoBtnRow:  { flexDirection: 'row', gap: 10 },
  profileBtn: {
    flex: 1, backgroundColor: COLORS.card2,
    borderRadius: RADIUS.lg, paddingHorizontal: 12, paddingVertical: 12,
    alignItems: 'center', borderWidth: 1, borderColor: COLORS.border,
  },
  profileBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.text },
  quoteBtn: {
    flex: 2, borderRadius: RADIUS.lg, paddingHorizontal: 12, paddingVertical: 12,
    alignItems: 'center',
  },
  quoteBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.bg },

  // Empty overlay
  emptyOverlay: {
    position: 'absolute', top: 0, left: 0, right: 0, bottom: 0,
    alignItems: 'center', justifyContent: 'center',
  },
  emptyCard: {
    backgroundColor: 'rgba(14,14,14,0.88)',
    borderRadius: RADIUS.xl, borderWidth: 1, borderColor: COLORS.border,
    paddingHorizontal: 28, paddingVertical: 20, alignItems: 'center', gap: 8,
  },
  emptyEmoji: { fontSize: 36 },
  emptyText:  { fontFamily: FONTS.bodyMedium, fontSize: 14, color: COLORS.muted2, textAlign: 'center' },
});
