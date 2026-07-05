/**
 * RequestZoneMap — mapa de zona aproximada compartido entre las tarjetas
 * de solicitud del grupo (ExpressCard y ScheduledRequestCard).
 *
 * Extraído del MapSection de ExpressCard SIN cambios de comportamiento.
 * IMPORTANTE: no agregar provider={PROVIDER_GOOGLE} ni quitar liteMode —
 * se intentó (Lote M) y rompió el render del mapa en el dispositivo del
 * usuario; decisión de producto 2026-07-04: el mapa se queda con el
 * provider default de la plataforma aunque los colores difieran del
 * EARTH_STYLE de las pantallas de detalle. La animación vale más.
 *
 * Con userLocation muestra la ruta grupo→zona con instrumentos animados;
 * sin él, solo el círculo de zona. El offset de privacidad (~±220 m + radio
 * 310 m) lo calcula el caller con privacyOffsetZone de utils/mapUtils —
 * la dirección exacta NUNCA pasa por aquí.
 */
import React, { useEffect, useState } from 'react';
import { Image, Platform, StyleSheet, Text, View } from 'react-native';
import MapView, { Circle, Marker, Polyline } from 'react-native-maps';
import { Zap } from 'lucide-react-native';
import { COLORS, FONTS } from '../../config/theme';
import { EARTH_STYLE } from '../../constants/mapStyle';
import { cameraForPoints, mapRegionForPoints } from '../../utils/mapUtils';

export const MAP_H = 170;

export const EVENT_LABELS: Record<string, string> = {
  fiesta_privada: 'Fiesta privada',
  boda:           'Boda',
  cumpleanos:     'Cumpleaños',
  graduacion:     'Graduación',
  empresarial:    'Empresarial',
  otro:           'Evento',
};

export function fmtDate(d: string) {
  try { return new Date(d).toLocaleDateString('es-MX', { weekday: 'short', day: 'numeric', month: 'short' }); }
  catch { return d; }
}

interface RequestZoneMapProps {
  mapId:          string;
  center:         { latitude: number; longitude: number };
  userLocation?:  { latitude: number; longitude: number } | null;
  groupPhotoUrl?: string | null;
  zoneLabelRight?: number;   // corre el chip "Zona aproximada" cuando la tarjeta pone una X encima
  typeLabel?:      string;   // chip arriba-izquierda: "⚡ Express" / "📅 Programada".
                             // Sin chip de género: el grupo ya sabe su género — si la
                             // solicitud le llegó es porque el cliente pidió ese género.
}

const RequestZoneMap = React.memo(function RequestZoneMap({
  mapId, center, userLocation, groupPhotoUrl, zoneLabelRight = 10, typeLabel,
}: RequestZoneMapProps) {
  const showRoute = !!userLocation;

  // ── Instrument animation: 80ms tick (≈12fps) — smooth movement, no jank ──
  // Markers inside MapView → coordinates pixel-perfect on the green line.
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
        key={showRoute ? `r-${mapId}` : `z-${mapId}`}
        style={StyleSheet.absoluteFill}
        customMapStyle={EARTH_STYLE}
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

      <View style={[s.zoneLabel, { right: zoneLabelRight }]} pointerEvents="none">
        <Text style={s.zoneLabelTx}>Zona aproximada</Text>
      </View>
      {typeLabel ? (
        <View style={s.typeChip} pointerEvents="none">
          <Zap size={9} color={COLORS.green} />
          <Text style={s.typeTx}>{typeLabel}</Text>
        </View>
      ) : null}
    </View>
  );
}, (prev, next) =>
  prev.mapId         === next.mapId         &&
  prev.groupPhotoUrl === next.groupPhotoUrl &&
  prev.zoneLabelRight === next.zoneLabelRight &&
  prev.typeLabel     === next.typeLabel     &&
  prev.userLocation?.latitude  === next.userLocation?.latitude  &&
  prev.userLocation?.longitude === next.userLocation?.longitude
);

export default RequestZoneMap;

const s = StyleSheet.create({
  mapWrap: { height: MAP_H, overflow: 'hidden', borderBottomWidth: 1, borderBottomColor: 'rgba(0,230,118,0.10)' },

  zoneLabel:   { position: 'absolute', top: 10, right: 10, backgroundColor: 'rgba(0,0,0,0.60)', borderRadius: 20, paddingHorizontal: 8, paddingVertical: 4, borderWidth: 1, borderColor: 'rgba(255,255,255,0.10)' },
  zoneLabelTx: { fontFamily: FONTS.body, fontSize: 9, color: 'rgba(255,255,255,0.55)', letterSpacing: 0.3 },
  typeChip: { position: 'absolute', top: 10, left: 10, flexDirection: 'row', alignItems: 'center', gap: 4, backgroundColor: 'rgba(0,0,0,0.72)', borderRadius: 20, paddingHorizontal: 8, paddingVertical: 4, borderWidth: 1, borderColor: 'rgba(0,230,118,0.28)' },
  typeTx:   { fontFamily: FONTS.bodySemiBold, fontSize: 10, color: COLORS.green, letterSpacing: 0.4, textTransform: 'uppercase' },

  groupMarker:        { width: 34, height: 34, borderRadius: 17, overflow: 'hidden', borderWidth: 2.5, borderColor: COLORS.green },
  groupMarkerImg:     { width: '100%', height: '100%' },
  groupMarkerFallback:{ width: '100%', height: '100%', backgroundColor: COLORS.green },
  instrEmoji:         { fontSize: 15 },
});
