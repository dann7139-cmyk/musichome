import React, { useEffect, useState } from 'react';
import {
  ActivityIndicator,
  Linking,
  Platform,
  Pressable,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import MapView, { Circle, Marker, Polyline } from 'react-native-maps';
import { MapPin, Phone } from 'lucide-react-native';
import { supabase } from '../../config/supabase';
import { COLORS, FONTS, RADIUS } from '../../config/theme';
import { EARTH_STYLE } from '../../constants/mapStyle';
import { formatDist } from '../../utils/mapUtils';

// Evidencia GPS de una disputa (admin). Se monta SOLO al expandir la
// tarjeta — carga admin_dispute_evidence (sql/426) en ese momento.
// Patrón de mapa adaptado del MapSection de ExpressCard (estático,
// EARTH_STYLE, liteMode en Android, sin gestos).

interface Evidence {
  ok: boolean;
  event_lat: number | null;
  event_lng: number | null;
  arrival_lat: number | null;
  arrival_lng: number | null;
  arrival_distance_m: number | null;
  arrival_gps_verified: boolean | null;
  group_arrived_at: string | null;
  group_name: string | null;
  owner_phone: string | null;
}

interface Props {
  reservationId: string;
}

const MAP_H = 170;
// Umbral del candado server-side (release_half_on_arrival, sql/424)
const SERVER_RADIUS_M = 250;

type LatLng = { latitude: number; longitude: number };

// Encuadre de 2 puntos — mismo cálculo que mapRegionForPoints de ExpressCard
function regionForPoints(p1: LatLng, p2: LatLng) {
  const span = Math.max(Math.abs(p1.latitude - p2.latitude), Math.abs(p1.longitude - p2.longitude));
  const pad = Math.max(span * 0.5, 0.005); // mín ~550 m para que el círculo de 250 m quepa
  const minLat = Math.min(p1.latitude, p2.latitude) - pad;
  const maxLat = Math.max(p1.latitude, p2.latitude) + pad;
  const minLng = Math.min(p1.longitude, p2.longitude) - pad;
  const maxLng = Math.max(p1.longitude, p2.longitude) + pad;
  return {
    latitude: (minLat + maxLat) / 2,
    longitude: (minLng + maxLng) / 2,
    latitudeDelta: maxLat - minLat,
    longitudeDelta: maxLng - minLng,
  };
}

// group_arrived_at es un instante absoluto (timestamptz) → se formatea
// directo en zona America/Mexico_City (parseEventDateMX es para el par
// event_date+event_time, no aplica aquí)
function horaLlegadaMX(iso: string): string {
  return new Date(iso).toLocaleTimeString('es-MX', {
    hour: '2-digit', minute: '2-digit', timeZone: 'America/Mexico_City',
  });
}

const DisputeEvidenceMap = React.memo(function DisputeEvidenceMap({ reservationId }: Props) {
  const [ev, setEv] = useState<Evidence | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    let alive = true;
    supabase
      .rpc('admin_dispute_evidence', { p_reservation_id: reservationId })
      .then(({ data, error }) => {
        if (!alive) return;
        setEv(error ? null : (data as Evidence));
        setLoading(false);
      });
    return () => { alive = false; };
  }, [reservationId]);

  if (loading) {
    return (
      <View style={s.loadingBox}>
        <ActivityIndicator size="small" color={COLORS.green} />
      </View>
    );
  }
  if (!ev?.ok) {
    return <Text style={s.errorTx}>No se pudo cargar la evidencia GPS.</Text>;
  }

  const hasEventCoords   = ev.event_lat != null && ev.event_lng != null;
  const hasArrival       = ev.group_arrived_at != null;
  const hasArrivalCoords = ev.arrival_lat != null && ev.arrival_lng != null;
  const eventPoint: LatLng | null = hasEventCoords
    ? { latitude: ev.event_lat!, longitude: ev.event_lng! }
    : null;
  const arrivalPoint: LatLng | null = hasArrivalCoords
    ? { latitude: ev.arrival_lat!, longitude: ev.arrival_lng! }
    : null;

  const phoneRow = ev.owner_phone ? (
    <Pressable style={s.phoneRow} onPress={() => Linking.openURL(`tel:${ev.owner_phone}`)}>
      <Phone size={14} color={COLORS.green} />
      <Text style={s.phoneTx}>{ev.owner_phone}</Text>
      <Text style={s.phoneHint}>· llamar al grupo</Text>
    </Pressable>
  ) : (
    <Text style={s.phoneMissing}>📞 Grupo sin teléfono registrado</Text>
  );

  // ── Estado 1: llegada VERIFICADA → mapa completo ──────────────────────────
  if (hasArrival && ev.arrival_gps_verified === true && eventPoint && arrivalPoint) {
    const dentro = (ev.arrival_distance_m ?? 0) <= SERVER_RADIUS_M;
    return (
      <View style={s.wrap}>
        <View style={s.mapBox}>
          <MapView
            style={StyleSheet.absoluteFill}
            customMapStyle={EARTH_STYLE}
            initialRegion={regionForPoints(eventPoint, arrivalPoint)}
            scrollEnabled={false}
            zoomEnabled={false}
            rotateEnabled={false}
            pitchEnabled={false}
            pointerEvents="none"
            {...(Platform.OS === 'android' ? { liteMode: true as true } : {})}
          >
            <Circle
              center={eventPoint}
              radius={SERVER_RADIUS_M}
              strokeColor="rgba(0,230,118,0.65)"
              fillColor="rgba(0,230,118,0.10)"
              strokeWidth={2}
            />
            <Marker coordinate={eventPoint} anchor={{ x: 0.5, y: 0.5 }} tracksViewChanges={false}>
              <View style={s.eventPin} />
            </Marker>
            <Marker coordinate={arrivalPoint} anchor={{ x: 0.5, y: 0.5 }} tracksViewChanges={false}>
              <View style={s.arrivalPin} />
            </Marker>
            <Polyline
              coordinates={[eventPoint, arrivalPoint]}
              strokeColor={COLORS.green}
              strokeWidth={1.5}
            />
          </MapView>
          <View style={s.distChip} pointerEvents="none">
            <MapPin size={10} color={dentro ? COLORS.green : COLORS.orange} />
            <Text style={[s.distChipTx, { color: dentro ? COLORS.green : COLORS.orange }]}>
              {formatDist((ev.arrival_distance_m ?? 0) / 1000)} del evento
            </Text>
          </View>
        </View>
        <Text style={s.evidenceLine}>
          ✅ Llegada verificada · a {ev.arrival_distance_m ?? 0} m
          {ev.group_arrived_at ? ` · llegó ${horaLlegadaMX(ev.group_arrived_at)}` : ''}
        </Text>
        {phoneRow}
      </View>
    );
  }

  // ── Estado 2: llegada SIN verificación GPS (reserva sin coords) ───────────
  if (hasArrival && ev.arrival_gps_verified === false) {
    return (
      <View style={s.wrap}>
        <View style={[s.band, s.bandOrange]}>
          <Text style={s.bandOrangeTx}>
            📍 Llegada sin verificación GPS
            {ev.group_arrived_at ? ` · llegó ${horaLlegadaMX(ev.group_arrived_at)}` : ''}
          </Text>
          <Text style={s.bandSub}>La reserva no tiene coordenadas del evento.</Text>
        </View>
        {phoneRow}
      </View>
    );
  }

  // ── Estado 3: SIN llegada registrada (posible no-show) ────────────────────
  if (!hasArrival) {
    return (
      <View style={s.wrap}>
        {eventPoint && (
          <View style={s.mapBox}>
            <MapView
              style={StyleSheet.absoluteFill}
              customMapStyle={EARTH_STYLE}
              initialRegion={{
                latitude: eventPoint.latitude, longitude: eventPoint.longitude,
                latitudeDelta: 0.012, longitudeDelta: 0.012,
              }}
              scrollEnabled={false}
              zoomEnabled={false}
              rotateEnabled={false}
              pitchEnabled={false}
              pointerEvents="none"
              {...(Platform.OS === 'android' ? { liteMode: true as true } : {})}
            >
              <Circle
                center={eventPoint}
                radius={SERVER_RADIUS_M}
                strokeColor="rgba(239,83,80,0.55)"
                fillColor="rgba(239,83,80,0.08)"
                strokeWidth={2}
              />
              <Marker coordinate={eventPoint} anchor={{ x: 0.5, y: 0.5 }} tracksViewChanges={false}>
                <View style={s.eventPin} />
              </Marker>
            </MapView>
          </View>
        )}
        <View style={[s.band, s.bandRed]}>
          <Text style={s.bandRedTx}>🚫 Sin llegada registrada</Text>
          <Text style={s.bandSub}>El grupo nunca marcó llegada en esta reserva.</Text>
        </View>
        {phoneRow}
      </View>
    );
  }

  // ── Estado 4: LEGACY — llegada anterior a la verificación GPS ─────────────
  return (
    <View style={s.wrap}>
      <View style={[s.band, s.bandGray]}>
        <Text style={s.bandGrayTx}>
          Llegada registrada sin datos GPS
          {ev.group_arrived_at ? ` · llegó ${horaLlegadaMX(ev.group_arrived_at)}` : ''}
        </Text>
        <Text style={s.bandSub}>
          Anterior a la verificación por GPS — no implica irregularidad.
        </Text>
      </View>
      {phoneRow}
    </View>
  );
});

export default DisputeEvidenceMap;

const s = StyleSheet.create({
  wrap: { gap: 8 },
  loadingBox: { height: 60, alignItems: 'center', justifyContent: 'center' },
  errorTx: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted, paddingVertical: 8 },
  mapBox: {
    height: MAP_H, borderRadius: RADIUS.md, overflow: 'hidden',
    borderWidth: 1, borderColor: COLORS.border,
  },
  eventPin: {
    width: 14, height: 14, borderRadius: 7,
    backgroundColor: COLORS.green, borderWidth: 2.5, borderColor: '#fff',
  },
  arrivalPin: {
    width: 14, height: 14, borderRadius: 7,
    backgroundColor: '#fff', borderWidth: 2.5, borderColor: COLORS.green,
  },
  distChip: {
    position: 'absolute', top: 8, right: 8,
    flexDirection: 'row', alignItems: 'center', gap: 4,
    backgroundColor: 'rgba(0,0,0,0.72)', borderRadius: 20,
    paddingHorizontal: 8, paddingVertical: 4,
    borderWidth: 1, borderColor: 'rgba(255,255,255,0.10)',
  },
  distChipTx: { fontFamily: FONTS.bodySemiBold, fontSize: 10, letterSpacing: 0.3 },
  evidenceLine: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.text },
  band: { borderRadius: RADIUS.md, padding: 12, gap: 3, borderWidth: 1 },
  bandOrange: { backgroundColor: 'rgba(255,152,0,0.08)', borderColor: 'rgba(255,152,0,0.35)' },
  bandOrangeTx: { fontFamily: FONTS.bodySemiBold, fontSize: 12, color: COLORS.orange },
  bandRed: { backgroundColor: 'rgba(239,83,80,0.08)', borderColor: 'rgba(239,83,80,0.35)' },
  bandRedTx: { fontFamily: FONTS.bodySemiBold, fontSize: 12, color: COLORS.red },
  bandGray: { backgroundColor: 'rgba(136,136,136,0.08)', borderColor: 'rgba(136,136,136,0.30)' },
  bandGrayTx: { fontFamily: FONTS.bodySemiBold, fontSize: 12, color: COLORS.muted2 },
  bandSub: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted2 },
  phoneRow: { flexDirection: 'row', alignItems: 'center', gap: 6, paddingVertical: 2 },
  phoneTx: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.green },
  phoneHint: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted },
  phoneMissing: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted },
});
