import React, { useCallback, useEffect, useRef, useState } from 'react';
import {
  Animated,
  Dimensions,
  Image,
  Platform,
  Pressable,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import MapView, { Circle, Polyline, Marker } from 'react-native-maps';
import * as Haptics from 'expo-haptics';
import { Clock, MapPin, Users, Zap } from 'lucide-react-native';
import { COLORS, FONTS, RADIUS } from '../../config/theme';
import { EARTH_STYLE } from '../../constants/mapStyle';
import type { ExpressDispatch } from '../../context/ExpressContext';
import { playCriticalTick } from '../../utils/expressSound';

// ── Public layout constants ───────────────────────────────────────────────────
const { width: W } = Dimensions.get('window');
export const CARD_WIDTH   = Math.round(W * 0.86);
export const LIST_PADDING = Math.round((W - CARD_WIDTH) / 2);
export const CARD_GAP     = 12;

const MAP_H = 170;

// ── City coords lookup ────────────────────────────────────────────────────────
const CITY_COORDS: Record<string, { lat: number; lng: number }> = {
  // CDMX
  'ciudad de mexico': { lat: 19.4326, lng: -99.1332 },
  'cdmx':            { lat: 19.4326, lng: -99.1332 },
  'iztapalapa':      { lat: 19.3579, lng: -99.0591 },
  'ecatepec':        { lat: 19.6012, lng: -99.0329 },
  'naucalpan':       { lat: 19.4794, lng: -99.2389 },
  'tlalnepantla':    { lat: 19.5432, lng: -99.1965 },
  'nezahualcoyotl':  { lat: 19.4022, lng: -99.0153 },
  'coyoacan':        { lat: 19.3467, lng: -99.1619 },
  // GDL metro — CRÍTICO
  'guadalajara':     { lat: 20.6597, lng: -103.3496 },
  'zapopan':         { lat: 20.7214, lng: -103.3865 },
  'tlaquepaque':     { lat: 20.6305, lng: -103.2971 },
  'san pedro tlaquepaque': { lat: 20.6305, lng: -103.2971 },
  'tonala':          { lat: 20.6228, lng: -103.2292 },
  'tlajomulco':      { lat: 20.4890, lng: -103.4321 },
  'tlajomulco de zuniga': { lat: 20.4890, lng: -103.4321 },
  'el salto':        { lat: 20.5356, lng: -103.2096 },
  'puerto vallarta': { lat: 20.6534, lng: -105.2253 },
  // Norte
  'monterrey':       { lat: 25.6866, lng: -100.3161 },
  'saltillo':        { lat: 25.4232, lng: -100.9963 },
  'torreon':         { lat: 25.5428, lng: -103.4068 },
  'chihuahua':       { lat: 28.6330, lng: -106.0691 },
  'ciudad juarez':   { lat: 31.6904, lng: -106.4245 },
  'tijuana':         { lat: 32.5149, lng: -117.0382 },
  'mexicali':        { lat: 32.6245, lng: -115.4523 },
  'hermosillo':      { lat: 29.0729, lng: -110.9559 },
  'culiacan':        { lat: 24.8090, lng: -107.3940 },
  'mazatlan':        { lat: 23.2494, lng: -106.4111 },
  'los mochis':      { lat: 25.7903, lng: -108.9865 },
  'reynosa':         { lat: 26.0924, lng: -98.2777 },
  'matamoros':       { lat: 25.8694, lng: -97.5025 },
  'victoria':        { lat: 23.7369, lng: -99.1411 },
  'durango':         { lat: 24.0277, lng: -104.6532 },
  'la paz':          { lat: 24.1426, lng: -110.3128 },
  // Centro
  'puebla':          { lat: 19.0414, lng: -98.2063 },
  'toluca':          { lat: 19.2826, lng: -99.6557 },
  'queretaro':       { lat: 20.5888, lng: -100.3899 },
  'san luis potosi': { lat: 22.1565, lng: -100.9855 },
  'aguascalientes':  { lat: 21.8818, lng: -102.2916 },
  'leon':            { lat: 21.1236, lng: -101.6858 },
  'celaya':          { lat: 20.5234, lng: -100.8155 },
  'irapuato':        { lat: 20.6766, lng: -101.3552 },
  'morelia':         { lat: 19.7060, lng: -101.1950 },
  'colima':          { lat: 19.2452, lng: -103.7241 },
  'tepic':           { lat: 21.5040, lng: -104.8955 },
  'zacatecas':       { lat: 22.7709, lng: -102.5832 },
  'pachuca':         { lat: 20.1011, lng: -98.7591 },
  'cuernavaca':      { lat: 18.9261, lng: -99.2306 },
  // Sur / Sureste
  'acapulco':        { lat: 16.8531, lng: -99.8237 },
  'veracruz':        { lat: 19.1739, lng: -96.1342 },
  'xalapa':          { lat: 19.5438, lng: -96.9102 },
  'merida':          { lat: 20.9674, lng: -89.5926 },
  'cancun':          { lat: 21.1619, lng: -86.8515 },
  'playa del carmen': { lat: 20.6296, lng: -87.0739 },
  'villahermosa':    { lat: 17.9892, lng: -92.9473 },
  'tuxtla gutierrez': { lat: 16.7521, lng: -93.1153 },
  'oaxaca':          { lat: 17.0732, lng: -96.7266 },
  'chetumal':        { lat: 18.5001, lng: -88.2963 },
  'tapachula':       { lat: 14.9060, lng: -92.2634 },
  'campeche':        { lat: 19.8301, lng: -90.5349 },
  // Fallbacks por estado (location_estado)
  'jalisco':         { lat: 20.6597, lng: -103.3496 },
  'nuevo leon':      { lat: 25.6866, lng: -100.3161 },
  'estado de mexico': { lat: 19.2826, lng: -99.6557 },
  'baja california': { lat: 32.5149, lng: -117.0382 },
  'sonora':          { lat: 29.0729, lng: -110.9559 },
  'sinaloa':         { lat: 24.8090, lng: -107.3940 },
  'tamaulipas':      { lat: 25.8694, lng: -97.5025 },
  'guerrero':        { lat: 16.8531, lng: -99.8237 },
  'chiapas':         { lat: 16.7521, lng: -93.1153 },
  'yucatan':         { lat: 20.9674, lng: -89.5926 },
  'quintana roo':    { lat: 21.1619, lng: -86.8515 },
  'tabasco':         { lat: 17.9892, lng: -92.9473 },
  'veracruz state':  { lat: 19.1739, lng: -96.1342 },
  'default':         { lat: 19.4326, lng: -99.1332 },
};

function normalize(s: string) {
  return s.toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '');
}

function resolveCoords(city: string, estado?: string | null) {
  const c = normalize(city);
  if (CITY_COORDS[c]) return CITY_COORDS[c];
  if (estado) {
    const e = normalize(estado);
    if (CITY_COORDS[e]) return CITY_COORDS[e];
  }
  return CITY_COORDS['default'];
}

function idHash(id: string): number {
  let h = 0;
  for (let i = 0; i < id.length; i++) h = (h * 31 + id.charCodeAt(i)) & 0x7fffffff;
  return h;
}

function privacyOffset(
  id:        string,
  city:      string,
  estado?:   string | null,
  lat?:      number | null,   // event_requests.latitude  (map picker)
  lng?:      number | null,   // event_requests.longitude (map picker)
  eventLat?: number | null,   // event_requests.event_lat (client GPS)
  eventLng?: number | null,   // event_requests.event_lng (client GPS)
) {
  const h    = idHash(id);
  const dlat = ((h % 800) - 400) / 200_000;
  const dlng = (((h * 31) % 800) - 400) / 200_000;

  // 1. Coordenadas del pin del mapa (más exactas)
  if (lat != null && lng != null) {
    return { latitude: lat + dlat, longitude: lng + dlng };
  }
  // 2. GPS del cliente al crear la solicitud
  if (eventLat != null && eventLng != null) {
    return { latitude: eventLat + dlat, longitude: eventLng + dlng };
  }
  // 3. Lookup por nombre de ciudad (último recurso)
  const base = resolveCoords(city, estado);
  return { latitude: base.lat + dlat, longitude: base.lng + dlng };
}

const MAP_STYLE = EARTH_STYLE;

// ── Distance / geo helpers ────────────────────────────────────────────────────
function haversineKm(lat1: number, lon1: number, lat2: number, lon2: number): number {
  const R = 6371;
  const dLat = (lat2 - lat1) * Math.PI / 180;
  const dLon = (lon2 - lon1) * Math.PI / 180;
  const a = Math.sin(dLat / 2) ** 2 +
            Math.cos(lat1 * Math.PI / 180) * Math.cos(lat2 * Math.PI / 180) *
            Math.sin(dLon / 2) ** 2;
  return R * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

function formatDist(km: number): string {
  if (km < 1) return `${Math.round(km * 1000)} m`;
  if (km < 10) return `${km.toFixed(1)} km`;
  return `${Math.round(km)} km`;
}

function mapRegionForPoints(
  p1: { latitude: number; longitude: number },
  p2: { latitude: number; longitude: number },
) {
  const spanLat = Math.abs(p1.latitude  - p2.latitude);
  const spanLng = Math.abs(p1.longitude - p2.longitude);
  const span    = Math.max(spanLat, spanLng);
  const pad     = Math.max(span * 0.35, 0.04); // 35% margen proporcional, mín ~4 km
  const minLat  = Math.min(p1.latitude,  p2.latitude)  - pad;
  const maxLat  = Math.max(p1.latitude,  p2.latitude)  + pad;
  const minLng  = Math.min(p1.longitude, p2.longitude) - pad;
  const maxLng  = Math.max(p1.longitude, p2.longitude) + pad;
  return {
    latitude:       (minLat + maxLat) / 2,
    longitude:      (minLng + maxLng) / 2,
    latitudeDelta:  maxLat - minLat,
    longitudeDelta: maxLng - minLng,
  };
}

function cameraForPoints(
  p1: { latitude: number; longitude: number },
  p2: { latitude: number; longitude: number },
) {
  const region   = mapRegionForPoints(p1, p2);
  // No incluir zoom — en iOS el altitude ya controla el nivel. zoom:n sobreescribe altitude.
  const altitude = Math.max((region.latitudeDelta / 0.072) * 6500 * 1.8, 5000);
  return { center: { latitude: region.latitude, longitude: region.longitude }, pitch: 0, heading: 0, altitude };
}


const EVENT_LABELS: Record<string, string> = {
  fiesta_privada: 'Fiesta privada',
  boda:           'Boda',
  cumpleanos:     'Cumpleaños',
  graduacion:     'Graduación',
  empresarial:    'Empresarial',
  otro:           'Evento',
};

function fmtDate(d: string) {
  try { return new Date(d).toLocaleDateString('es-MX', { weekday: 'short', day: 'numeric', month: 'short' }); }
  catch { return d; }
}

// ── MapSection — real map with privacy-offset zone circle + route + animation ──
interface MapSectionProps {
  dispatchId:     string;
  center:         { latitude: number; longitude: number };
  genre:          string;
  userLocation?:  { latitude: number; longitude: number } | null;
  groupPhotoUrl?: string | null;
}

const MapSection = React.memo(function MapSection({
  dispatchId, center, genre, userLocation, groupPhotoUrl,
}: MapSectionProps) {
  const showRoute = !!userLocation;

  // ── Instrument animation: 80ms tick (≈12fps) — smooth movement, no jank ──
  // Markers inside MapView → coordinates pixel-perfect on the green line.
  // 3 instruments evenly spaced: guitar @ t, trumpet @ t+0.33, accordion @ t+0.67
  const [instrT, setInstrT] = useState(0);
  useEffect(() => {
    if (!showRoute) { setInstrT(0); return; }
    const id = setInterval(() => setInstrT(prev => (prev + 0.022) % 1.0), 80);
    return () => clearInterval(id);
  }, [showRoute]);

  // 5 instruments evenly spaced 0.2 apart along the route
  const instrCoords = showRoute && userLocation ? (() => {
    const fLat = userLocation.latitude,  fLng = userLocation.longitude;
    const tLat = center.latitude,        tLng = center.longitude;
    const pos = (off: number) => {
      const t = (instrT + off) % 1.0;
      return { latitude: fLat + t * (tLat - fLat), longitude: fLng + t * (tLng - fLng) };
    };
    return {
      guitar:    pos(0.0),
      trumpet:   pos(0.2),
      accordion: pos(0.4),
      drum:      pos(0.6),
      violin:    pos(0.8),
    };
  })() : null;

  // ── Map config ─────────────────────────────────────────────────────────────
  const region = showRoute && userLocation ? mapRegionForPoints(userLocation, center) : null;
  let mapProps: object;
  if (Platform.OS === 'ios') {
    mapProps = { camera: showRoute && userLocation
      ? cameraForPoints(userLocation, center)
      : { center: { latitude: center.latitude, longitude: center.longitude }, pitch: 0, heading: 0, altitude: 9000 } };
  } else if (showRoute && region) {
    mapProps = { initialRegion: region };
  } else {
    mapProps = {
      initialRegion: { latitude: center.latitude, longitude: center.longitude, latitudeDelta: 0.072, longitudeDelta: 0.072 },
      liteMode: true as true,
    };
  }

  return (
    <View style={s.mapWrap}>
      <MapView
        key={showRoute ? `r-${dispatchId}` : `z-${dispatchId}`}
        style={StyleSheet.absoluteFill}
        customMapStyle={MAP_STYLE}
        scrollEnabled={false}
        zoomEnabled={false}
        rotateEnabled={false}
        pitchEnabled={false}
        pointerEvents="none"
        {...mapProps}
      >
        <Circle center={center} radius={310} strokeColor="rgba(0,230,118,0.65)" fillColor="rgba(0,230,118,0.13)" strokeWidth={2} />
        {showRoute && userLocation && (
          <>
            <Polyline coordinates={[userLocation, center]} strokeColor={COLORS.green} strokeWidth={1} />
            <Marker coordinate={userLocation} anchor={{ x: 0.5, y: 0.5 }} tracksViewChanges={false}>
              <View style={s.groupMarker}>
                {groupPhotoUrl
                  ? <Image source={{ uri: groupPhotoUrl }} style={s.groupMarkerImg} />
                  : <View style={s.groupMarkerFallback} />}
              </View>
            </Marker>
            {instrCoords && (
              <>
                <Marker coordinate={instrCoords.guitar}    anchor={{ x: 0.5, y: 0.5 }} tracksViewChanges={false}><Text style={s.instrEmoji}>🎸</Text></Marker>
                <Marker coordinate={instrCoords.trumpet}   anchor={{ x: 0.5, y: 0.5 }} tracksViewChanges={false}><Text style={s.instrEmoji}>🎺</Text></Marker>
                <Marker coordinate={instrCoords.accordion} anchor={{ x: 0.5, y: 0.5 }} tracksViewChanges={false}><Text style={s.instrEmoji}>🪗</Text></Marker>
                <Marker coordinate={instrCoords.drum}      anchor={{ x: 0.5, y: 0.5 }} tracksViewChanges={false}><Text style={s.instrEmoji}>🥁</Text></Marker>
                <Marker coordinate={instrCoords.violin}    anchor={{ x: 0.5, y: 0.5 }} tracksViewChanges={false}><Text style={s.instrEmoji}>🎻</Text></Marker>
              </>
            )}
          </>
        )}
      </MapView>

      <View style={s.zoneLabel} pointerEvents="none">
        <Text style={s.zoneLabelTx}>Zona aproximada</Text>
      </View>
      <View style={s.genreChip} pointerEvents="none">
        <Zap size={9} color={COLORS.green} />
        <Text style={s.genreTx}>{genre}</Text>
      </View>
    </View>
  );
}, (prev, next) =>
  prev.dispatchId    === next.dispatchId    &&
  prev.genre         === next.genre         &&
  prev.groupPhotoUrl === next.groupPhotoUrl &&
  prev.userLocation?.latitude  === next.userLocation?.latitude  &&
  prev.userLocation?.longitude === next.userLocation?.longitude
);

// ── CountdownDisplay — isolated re-render island, ticks every second ──────────
function CountdownDisplay({ expiresAt }: { expiresAt?: string }) {
  const [ms, setMs] = useState(() =>
    expiresAt ? Math.max(0, new Date(expiresAt).getTime() - Date.now()) : 180_000
  );
  const criticalFiredRef = useRef(false);

  useEffect(() => {
    if (!expiresAt) return;
    const id = setInterval(() => setMs(Math.max(0, new Date(expiresAt).getTime() - Date.now())), 1_000);
    return () => clearInterval(id);
  }, [expiresAt]);

  const secs  = Math.ceil(ms / 1_000);

  useEffect(() => {
    if (secs <= 20 && secs > 0 && !criticalFiredRef.current) {
      criticalFiredRef.current = true;
      playCriticalTick();
      Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Heavy).catch(() => {});
    }
  }, [secs]);

  const mins   = Math.floor(secs / 60);
  const sec    = secs % 60;
  const urgent = secs <= 20;
  const color  = secs > 60 ? COLORS.green : secs > 20 ? '#FFA726' : COLORS.red;
  return (
    <View style={[s.cdChip, urgent && s.cdChipUrgent]}>
      <Clock size={9} color={color} />
      <Text style={[s.cdText, { color }]}>{`${mins}:${String(sec).padStart(2, '0')}`}</Text>
    </View>
  );
}

// ── ExpressCard ───────────────────────────────────────────────────────────────
interface Props {
  dispatch:       ExpressDispatch;
  onCotizar:      (id: string) => void;
  onDismiss:      (id: string) => void;
  isBlocked?:     boolean;
  isFocused?:     boolean;
  userLocation?:  { latitude: number; longitude: number } | null;
  groupPhotoUrl?: string | null;
}

const ExpressCard = React.memo(function ExpressCard({
  dispatch, onCotizar, onDismiss, isBlocked = false, userLocation, groupPhotoUrl,
}: Props) {
  const { id, request, status, expires_at } = dispatch;
  const isTaken = status === 'taken';

  const entryX  = useRef(new Animated.Value(54)).current;
  const entryOp = useRef(new Animated.Value(0)).current;
  useEffect(() => {
    Animated.parallel([
      Animated.spring(entryX,  { toValue: 0, tension: 80, friction: 10, useNativeDriver: true }),
      Animated.timing(entryOp, { toValue: 1, duration: 220, useNativeDriver: true }),
    ]).start();
  }, []);

  const takenOp = useRef(new Animated.Value(0)).current;
  useEffect(() => {
    if (isTaken) Animated.timing(takenOp, { toValue: 1, duration: 250, useNativeDriver: true }).start();
  }, [isTaken]);

  const city   = request?.location_city ?? '';
  const estado = request?.location_estado ?? null;
  const genre  = request?.genre ?? 'Express';
  const center = privacyOffset(
    id, city, estado,
    request?.latitude, request?.longitude,
    request?.event_lat, request?.event_lng,
  );
  const distKm = userLocation
    ? haversineKm(userLocation.latitude, userLocation.longitude, center.latitude, center.longitude)
    : null;

  const handleCotizar = useCallback(() => onCotizar(id), [id, onCotizar]);
  const handleDismiss = useCallback(() => onDismiss(id), [id, onDismiss]);

  return (
    <Animated.View style={{ transform: [{ translateX: entryX }], opacity: entryOp }}>
      <View style={s.card}>

        <MapSection dispatchId={id} center={center} genre={genre} userLocation={userLocation} groupPhotoUrl={groupPhotoUrl} />

        <View style={s.cdPosition} pointerEvents="none">
          <CountdownDisplay expiresAt={expires_at} />
        </View>

        <View style={s.body}>
          <Text style={s.eventType} numberOfLines={1}>
            {EVENT_LABELS[request?.event_type ?? ''] ?? 'Evento express'}
          </Text>
          <Text style={s.cityTx} numberOfLines={1}>
            {city}{request?.location_municipio ? `, ${request.location_municipio}` : ''}
          </Text>

          <View style={s.statsRow}>
            <View style={s.stat}>
              <Text style={s.statVal}>{request?.hours ?? '—'}</Text>
              <Text style={s.statLbl}>hrs</Text>
            </View>
            <View style={s.statDiv} />
            <View style={s.stat}>
              <Text style={s.statVal} numberOfLines={1}>
                {request?.event_date ? fmtDate(request.event_date) : '—'}
              </Text>
              <Text style={s.statLbl}>fecha</Text>
            </View>
            {request?.guest_count ? (
              <>
                <View style={s.statDiv} />
                <View style={s.stat}>
                  <View style={{ flexDirection: 'row', alignItems: 'center', gap: 3 }}>
                    <Users size={10} color={COLORS.muted2} />
                    <Text style={s.statVal}>{request.guest_count}</Text>
                  </View>
                  <Text style={s.statLbl}>personas</Text>
                </View>
              </>
            ) : null}
            {distKm != null && (
              <>
                <View style={s.statDiv} />
                <View style={s.stat}>
                  <View style={{ flexDirection: 'row', alignItems: 'center', gap: 3 }}>
                    <MapPin size={10} color={COLORS.muted2} />
                    <Text style={s.statVal}>{formatDist(distKm)}</Text>
                  </View>
                  <Text style={s.statLbl}>de ti</Text>
                </View>
              </>
            )}
          </View>

          <View style={s.actions}>
            <Pressable onPress={handleDismiss} hitSlop={12}
              style={({ pressed }) => [s.btnGhost, pressed && { opacity: 0.5 }]}>
              <Text style={s.btnGhostTx}>Ignorar</Text>
            </Pressable>
            <Pressable
              onPress={isBlocked ? undefined : handleCotizar}
              style={({ pressed }) => [
                s.btnPrimary,
                isBlocked && s.btnBlocked,
                !isBlocked && pressed && { opacity: 0.82 },
              ]}
            >
              <Zap size={12} color={isBlocked ? COLORS.muted : COLORS.bg} />
              <Text style={[s.btnPrimaryTx, isBlocked && { color: COLORS.muted }]}>
                {isBlocked ? 'En curso' : 'Cotizar'}
              </Text>
            </Pressable>
          </View>
        </View>

        {isBlocked && (
          <View style={s.blockedOverlay} pointerEvents="none">
            <Text style={s.blockedTx}>Cotización en progreso</Text>
            <Text style={s.blockedSub}>Termina la actual primero</Text>
          </View>
        )}

        {isTaken && (
          <Animated.View style={[StyleSheet.absoluteFill, s.takenOverlay, { opacity: takenOp }]} pointerEvents="none">
            <Text style={s.takenIcon}>⚡</Text>
            <Text style={s.takenTitle}>Otro grupo la tomó</Text>
            <Text style={s.takenSub}>Seguirán llegando más solicitudes</Text>
          </Animated.View>
        )}

      </View>
    </Animated.View>
  );
});

export default ExpressCard;

// ── Styles ────────────────────────────────────────────────────────────────────
const s = StyleSheet.create({
  card:    { width: CARD_WIDTH, backgroundColor: '#060c06', borderRadius: RADIUS.xl, overflow: 'hidden', borderWidth: 1, borderColor: 'rgba(0,230,118,0.14)' },
  mapWrap: { height: MAP_H, overflow: 'hidden', borderBottomWidth: 1, borderBottomColor: 'rgba(0,230,118,0.10)' },

  genreChip: { position: 'absolute', top: 10, left: 10, flexDirection: 'row', alignItems: 'center', gap: 4, backgroundColor: 'rgba(0,0,0,0.72)', borderRadius: 20, paddingHorizontal: 8, paddingVertical: 4, borderWidth: 1, borderColor: 'rgba(0,230,118,0.28)' },
  genreTx:   { fontFamily: FONTS.bodySemiBold, fontSize: 10, color: COLORS.green, letterSpacing: 0.3, textTransform: 'capitalize' },
  zoneLabel:   { position: 'absolute', top: 10, right: 10, backgroundColor: 'rgba(0,0,0,0.60)', borderRadius: 20, paddingHorizontal: 8, paddingVertical: 4, borderWidth: 1, borderColor: 'rgba(255,255,255,0.10)' },
  zoneLabelTx: { fontFamily: FONTS.body, fontSize: 9, color: 'rgba(255,255,255,0.55)', letterSpacing: 0.3 },

  cdPosition:   { position: 'absolute', top: MAP_H - 34, right: 10 },
  cdChip:       { flexDirection: 'row', alignItems: 'center', gap: 4, backgroundColor: 'rgba(0,0,0,0.72)', borderRadius: 20, paddingHorizontal: 8, paddingVertical: 4, borderWidth: 1, borderColor: 'rgba(255,255,255,0.1)' },
  cdChipUrgent: { borderColor: 'rgba(239,83,80,0.5)', backgroundColor: 'rgba(239,83,80,0.1)' },
  cdText:       { fontFamily: FONTS.bodySemiBold, fontSize: 11, letterSpacing: 0.5 },

  body:      { paddingHorizontal: 16, paddingTop: 13, paddingBottom: 15, gap: 9 },
  eventType: { fontFamily: FONTS.bodySemiBold, fontSize: 16, color: COLORS.text, letterSpacing: 0.1 },
  cityTx:    { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2, marginTop: -5 },

  statsRow: { flexDirection: 'row', alignItems: 'center', gap: 12 },
  stat:     { alignItems: 'flex-start', gap: 2 },
  statVal:  { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.text },
  statLbl:  { fontFamily: FONTS.body, fontSize: 10, color: COLORS.muted },
  statDiv:  { width: 1, height: 26, backgroundColor: 'rgba(255,255,255,0.07)' },

  actions:      { flexDirection: 'row', gap: 8, marginTop: 2 },
  btnGhost:     { paddingHorizontal: 12, paddingVertical: 10, borderRadius: RADIUS.lg, alignItems: 'center', justifyContent: 'center' },
  btnGhostTx:   { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted },
  btnPrimary:   { flex: 1, flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 5, paddingVertical: 10, borderRadius: RADIUS.lg, backgroundColor: COLORS.green },
  btnBlocked:   { backgroundColor: 'rgba(255,255,255,0.06)', borderWidth: 1, borderColor: 'rgba(255,255,255,0.08)' },
  btnPrimaryTx: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.bg },

  blockedOverlay: { position: 'absolute', bottom: 0, left: 0, right: 0, height: 56, backgroundColor: 'rgba(6,12,6,0.78)', alignItems: 'center', justifyContent: 'center', gap: 3 },
  blockedTx:      { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.muted2 },
  blockedSub:     { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted },

  groupMarker:        { width: 34, height: 34, borderRadius: 17, overflow: 'hidden', borderWidth: 2.5, borderColor: COLORS.green },
  groupMarkerImg:     { width: '100%', height: '100%' },
  groupMarkerFallback:{ width: '100%', height: '100%', backgroundColor: COLORS.green },
  instrEmoji:         { fontSize: 15 },

  takenOverlay: { backgroundColor: 'rgba(6,12,6,0.90)', alignItems: 'center', justifyContent: 'center', gap: 8, borderRadius: RADIUS.xl },
  takenIcon:    { fontSize: 32 },
  takenTitle:   { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.text },
  takenSub:     { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, textAlign: 'center', paddingHorizontal: 24 },
});
