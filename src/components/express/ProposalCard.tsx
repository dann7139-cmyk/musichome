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
import MapView, { Circle, Marker, Polyline } from 'react-native-maps';
import { ChevronRight, MapPin, Users, Zap } from 'lucide-react-native';
import { COLORS, FONTS, RADIUS } from '../../config/theme';
import { EARTH_STYLE } from '../../constants/mapStyle';
import {
  cameraForPoints,
  formatDist,
  haversineKm,
  idHash,
  mapRegionForPoints,
  privacyOffset,
  resolveCoords,
} from '../../utils/mapUtils';
import type { ClientProposal } from '../../context/ClientProposalContext';

// ── Layout constants ───────────────────────────────────────────────────────────
const { width: W } = Dimensions.get('window');
export const PROPOSAL_CARD_WIDTH   = Math.round(W * 0.86);
export const PROPOSAL_LIST_PADDING = Math.round((W - PROPOSAL_CARD_WIDTH) / 2);
export const PROPOSAL_CARD_GAP     = 12;

const MAP_H = 155;

// ── Genre emojis ──────────────────────────────────────────────────────────────
const GENRE_EMOJI: Record<string, string> = {
  Norteño: '🪗', Banda: '🎺', Mariachi: '🎻', Grupero: '🎸',
  Cumbia: '🥁', Salsa: '💃', Jazz: '🎷', Rock: '🤘', Pop: '🎤',
  'Regional Mexicano': '🇲🇽', Tropical: '🌴', Ranchero: '🤠',
  Electrónica: '🎧', Otro: '🎵',
};

// ── MapSection ────────────────────────────────────────────────────────────────
// Vista del CLIENTE — misma semántica que el mapa del grupo (2026-07-11):
//   - Círculo verde   → LA TOCADA (el evento, coords exactas del cliente)
//   - Foto del cliente → dentro del círculo (su evento)
//   - Foto del grupo   → su zona aproximada (ciudad; el GPS real del grupo
//                        no se comparte hasta el día del evento)
//   - Instrumentos     → viajan del grupo hacia el evento
interface MapSectionProps {
  proposalId:     string;
  eventCenter:    { latitude: number; longitude: number };
  genre:          string;
  groupLocation:  { latitude: number; longitude: number };  // always resolved
  clientPhotoUrl: string | null;
  groupPhotoUrl:  string | null;
}

const MapSection = React.memo(function MapSection({
  proposalId, eventCenter, genre, groupLocation, clientPhotoUrl, groupPhotoUrl,
}: MapSectionProps) {
  // Instrumentos animados — 80 ms tick igual que ExpressCard
  const [instrT, setInstrT] = useState(0);
  useEffect(() => {
    const id = setInterval(() => setInstrT(prev => (prev + 0.022) % 1.0), 80);
    return () => clearInterval(id);
  }, []);

  const fLat = groupLocation.latitude;
  const fLng = groupLocation.longitude;
  const tLat = eventCenter.latitude;
  const tLng = eventCenter.longitude;
  const pos = (off: number) => {
    const t = (instrT + off) % 1.0;
    return { latitude: fLat + t * (tLat - fLat), longitude: fLng + t * (tLng - fLng) };
  };
  const instrCoords = {
    guitar:    pos(0.0),
    trumpet:   pos(0.2),
    accordion: pos(0.4),
    drum:      pos(0.6),
    violin:    pos(0.8),
  };

  const region = mapRegionForPoints(groupLocation, eventCenter);
  let mapProps: object;
  if (Platform.OS === 'ios') {
    mapProps = { camera: cameraForPoints(groupLocation, eventCenter) };
  } else {
    mapProps = { initialRegion: region };
  }

  return (
    <View style={s.mapWrap}>
      <MapView
        key={`r-${proposalId}`}
        style={StyleSheet.absoluteFill}
        customMapStyle={EARTH_STYLE}
        scrollEnabled={false}
        zoomEnabled={false}
        rotateEnabled={false}
        pitchEnabled={false}
        pointerEvents="none"
        {...mapProps}
      >
        {/* Círculo verde = LA TOCADA (misma semántica que el mapa del grupo:
            verde siempre es el evento; las fotos son personas) */}
        <Circle
          center={eventCenter}
          radius={500}
          strokeColor="rgba(0,230,118,0.65)"
          fillColor="rgba(0,230,118,0.13)"
          strokeWidth={2}
        />

        {/* Foto del cliente EN su evento (dentro del círculo) */}
        <Marker coordinate={eventCenter} anchor={{ x: 0.5, y: 0.5 }} tracksViewChanges={false}>
          <View style={s.clientMarker}>
            {clientPhotoUrl
              ? <Image source={{ uri: clientPhotoUrl }} style={s.clientMarkerImg} />
              : <View style={s.clientMarkerFallback}>
                  <Text style={{ fontSize: 14 }}>🎵</Text>
                </View>
            }
          </View>
        </Marker>

        {/* Foto del GRUPO en su zona aproximada (su ciudad — el GPS real del
            grupo no se comparte hasta el día del evento) */}
        <Marker coordinate={groupLocation} anchor={{ x: 0.5, y: 0.5 }} tracksViewChanges={false}>
          <View style={s.clientMarker}>
            {groupPhotoUrl
              ? <Image source={{ uri: groupPhotoUrl }} style={s.clientMarkerImg} />
              : <View style={s.clientMarkerFallback}>
                  <Text style={{ fontSize: 14 }}>🎤</Text>
                </View>
            }
          </View>
        </Marker>

        {/* Línea del grupo hacia el evento */}
        <Polyline
          coordinates={[groupLocation, eventCenter]}
          strokeColor={COLORS.green}
          strokeWidth={1.5}
        />

        {/* Instrumentos viajando hacia la foto del cliente */}
        <Marker coordinate={instrCoords.guitar}    anchor={{ x: 0.5, y: 0.5 }} tracksViewChanges={false}><Text style={s.instrEmoji}>🎸</Text></Marker>
        <Marker coordinate={instrCoords.trumpet}   anchor={{ x: 0.5, y: 0.5 }} tracksViewChanges={false}><Text style={s.instrEmoji}>🎺</Text></Marker>
        <Marker coordinate={instrCoords.accordion} anchor={{ x: 0.5, y: 0.5 }} tracksViewChanges={false}><Text style={s.instrEmoji}>🪗</Text></Marker>
        <Marker coordinate={instrCoords.drum}      anchor={{ x: 0.5, y: 0.5 }} tracksViewChanges={false}><Text style={s.instrEmoji}>🥁</Text></Marker>
        <Marker coordinate={instrCoords.violin}    anchor={{ x: 0.5, y: 0.5 }} tracksViewChanges={false}><Text style={s.instrEmoji}>🎻</Text></Marker>
      </MapView>

      {/* Chip de género */}
      <View style={s.genreChip} pointerEvents="none">
        <Zap size={9} color={COLORS.green} />
        <Text style={s.genreTx}>{genre}</Text>
      </View>

      {/* Etiqueta del evento */}
      <View style={s.zoneLabel} pointerEvents="none">
        <Text style={s.zoneLabelTx}>Tu evento</Text>
      </View>
    </View>
  );
}, (prev, next) =>
  prev.proposalId     === next.proposalId     &&
  prev.genre          === next.genre          &&
  prev.clientPhotoUrl === next.clientPhotoUrl &&
  prev.groupLocation?.latitude  === next.groupLocation?.latitude  &&
  prev.groupLocation?.longitude === next.groupLocation?.longitude
);

// ── ProposalCard ──────────────────────────────────────────────────────────────

interface Props {
  proposal:       ClientProposal;
  clientPhotoUrl: string | null;
  onHire:         (proposal: ClientProposal) => void;
  onDismiss:      (id: string) => void;
  onViewProfile?: () => void;
  isHiring?:      boolean;
  isBlocked?:     boolean;
}

const ProposalCard = React.memo(function ProposalCard({
  proposal, clientPhotoUrl, onHire, onDismiss, onViewProfile,
  isHiring = false, isBlocked = false,
}: Props) {
  const { id, group, request, proposal_data: pd } = proposal;

  // Animación de entrada
  const entryX  = useRef(new Animated.Value(54)).current;
  const entryOp = useRef(new Animated.Value(0)).current;
  useEffect(() => {
    Animated.parallel([
      Animated.spring(entryX,  { toValue: 0, tension: 80, friction: 10, useNativeDriver: true }),
      Animated.timing(entryOp, { toValue: 1, duration: 220, useNativeDriver: true }),
    ]).start();
  }, []);

  // Coordenadas del evento: este mapa lo ve el PROPIO cliente, así que se
  // pintan EXACTAS (el jitter de privacidad es para ocultarle la dirección
  // a los grupos, no al dueño del evento — con jitter "su casa" salía ~1 km
  // corrida y se veía mal). Fallback a ciudad solo si no hay coords.
  const eventCenter = (() => {
    const la = request?.latitude ?? request?.event_lat ?? null;
    const ln = request?.longitude ?? request?.event_lng ?? null;
    if (la != null && ln != null) return { latitude: la, longitude: ln };
    return privacyOffset(id, request?.location_city ?? '', request?.location_estado, null, null);
  })();

  // Coordenadas del grupo: ciudad/estado → fallback hash del group_id
  // Siempre devuelve un punto para que el mapa muestre el círculo y la línea.
  const groupLocation = (() => {
    if (group?.city || group?.state) {
      const c = resolveCoords(group?.city ?? '', group?.state ?? null);
      return { latitude: c.lat, longitude: c.lng };
    }
    // Si el grupo no tiene ciudad, derivar offset pseudoaleatorio ~8-15 km del evento
    const h     = idHash(proposal.group_id);
    const dist  = 0.06 + (h % 80) / 1000;
    const angle = ((h * 37) % 628) / 100;
    return {
      latitude:  eventCenter.latitude  + dist * Math.cos(angle),
      longitude: eventCenter.longitude + dist * Math.sin(angle),
    };
  })();

  // Distancia grupo → evento (siempre calculable)
  const distKm = haversineKm(
    groupLocation.latitude, groupLocation.longitude,
    eventCenter.latitude,   eventCenter.longitude,
  );

  const handleHire    = useCallback(() => onHire(proposal),  [onHire, proposal]);
  const handleDismiss = useCallback(() => onDismiss(id), [onDismiss, id]);

  const genre     = group?.genre ?? request?.genre ?? 'Express';
  const groupCity = [group?.city, group?.state].filter(Boolean).join(', ');

  return (
    <Animated.View style={{ transform: [{ translateX: entryX }], opacity: entryOp }}>
      <View style={s.card}>

        {/* ── Mapa ── */}
        <MapSection
          proposalId={id}
          eventCenter={eventCenter}
          genre={genre}
          groupLocation={groupLocation}
          clientPhotoUrl={clientPhotoUrl}
          groupPhotoUrl={group?.profile_image ?? null}
        />

        {/* ── Body ── */}
        <View style={s.body}>

          {/* Info del grupo + botón ver perfil */}
          <View style={s.groupRow}>
            <View style={s.avatarWrap}>
              {group?.profile_image
                ? <Image source={{ uri: group.profile_image }} style={s.avatar} />
                : <View style={s.avatarFallback}>
                    <Text style={s.avatarEmoji}>{GENRE_EMOJI[genre] ?? '🎵'}</Text>
                  </View>
              }
            </View>
            <View style={{ flex: 1, gap: 2 }}>
              <Text style={s.groupName} numberOfLines={1}>{group?.name ?? 'Grupo'}</Text>
              {!!groupCity && <Text style={s.groupCity} numberOfLines={1}>{groupCity}</Text>}
            </View>
            {!!onViewProfile && (
              <Pressable
                onPress={onViewProfile}
                hitSlop={10}
                style={({ pressed }) => [s.profileBtn, pressed && { opacity: 0.6 }]}
              >
                <Text style={s.profileBtnTx}>Ver perfil</Text>
                <ChevronRight size={11} color={COLORS.green} />
              </Pressable>
            )}
          </View>

          {/* Stats: duración | personas | km al evento */}
          <View style={s.statsRow}>
            <View style={s.stat}>
              <Text style={s.statVal}>{request?.hours ?? '—'} hrs</Text>
              <Text style={s.statLbl}>duración</Text>
            </View>
            {!!request?.guest_count && (
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
            )}
            <>
              <View style={s.statDiv} />
              <View style={s.stat}>
                <View style={{ flexDirection: 'row', alignItems: 'center', gap: 3 }}>
                  <MapPin size={10} color={COLORS.muted2} />
                  <Text style={s.statVal}>{formatDist(distKm)}</Text>
                </View>
                <Text style={s.statLbl}>del evento</Text>
              </View>
            </>
          </View>

          {/* Precio: solo traslado (si aplica) + total */}
          <View style={s.priceBox}>
            {pd?.travel_cost != null && Number(pd.travel_cost) > 0 && (
              <View style={s.priceRow}>
                <Text style={s.priceLabel}>Traslado</Text>
                <Text style={s.priceValSub}>+${Number(pd.travel_cost).toLocaleString()} MXN</Text>
              </View>
            )}
            {pd?.total_amount != null && (
              <View style={[s.priceRow, pd?.travel_cost && Number(pd.travel_cost) > 0 ? s.totalRow : {}]}>
                <Text style={s.totalLabel}>Total a pagar</Text>
                <Text style={s.totalVal}>${Number(pd.total_amount).toLocaleString()} MXN</Text>
              </View>
            )}
          </View>

          {/* Horario */}
          {(pd?.arrival_time || pd?.start_time) && (
            <View style={s.timesRow}>
              {!!pd.arrival_time && (
                <View style={s.timeChip}>
                  <Text style={s.timeChipLabel}>🕐 Llegada</Text>
                  <Text style={s.timeChipVal}>{pd.arrival_time}</Text>
                </View>
              )}
              {!!pd.start_time && (
                <View style={s.timeChip}>
                  <Text style={s.timeChipLabel}>🎵 Inicio</Text>
                  <Text style={s.timeChipVal}>{pd.start_time}</Text>
                </View>
              )}
            </View>
          )}

          {/* Notas del grupo */}
          {!!pd?.notes && (
            <Text style={s.notes} numberOfLines={2}>💬 {pd.notes}</Text>
          )}

          {/* Botones */}
          <View style={s.actions}>
            <Pressable
              onPress={handleDismiss}
              hitSlop={12}
              style={({ pressed }) => [s.btnGhost, pressed && { opacity: 0.5 }]}
            >
              <Text style={s.btnGhostTx}>Rechazar</Text>
            </Pressable>
            <Pressable
              onPress={isBlocked ? undefined : handleHire}
              style={({ pressed }) => [
                s.btnPrimary,
                isBlocked && s.btnBlocked,
                isHiring  && s.btnBlocked,
                !isBlocked && !isHiring && pressed && { opacity: 0.82 },
              ]}
            >
              <Zap size={12} color={isBlocked || isHiring ? COLORS.muted : COLORS.bg} />
              <Text style={[s.btnPrimaryTx, (isBlocked || isHiring) && { color: COLORS.muted }]}>
                {isHiring ? 'Procesando...' : isBlocked ? 'En curso' : 'Contratar y pagar'}
              </Text>
            </Pressable>
          </View>

        </View>

        {/* Overlay bloqueado */}
        {isBlocked && !isHiring && (
          <View style={s.blockedOverlay} pointerEvents="none">
            <Text style={s.blockedTx}>Procesando otra selección</Text>
          </View>
        )}

      </View>
    </Animated.View>
  );
});

export default ProposalCard;

// ── Styles ────────────────────────────────────────────────────────────────────
const s = StyleSheet.create({
  card: {
    width: PROPOSAL_CARD_WIDTH,
    backgroundColor: '#060c06',
    borderRadius: RADIUS.xl,
    overflow: 'hidden',
    borderWidth: 1,
    borderColor: 'rgba(0,230,118,0.14)',
  },
  mapWrap: {
    height: MAP_H,
    overflow: 'hidden',
    borderBottomWidth: 1,
    borderBottomColor: 'rgba(0,230,118,0.10)',
  },

  genreChip: {
    position: 'absolute', top: 10, left: 10,
    flexDirection: 'row', alignItems: 'center', gap: 4,
    backgroundColor: 'rgba(0,0,0,0.72)',
    borderRadius: 20, paddingHorizontal: 8, paddingVertical: 4,
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.28)',
  },
  genreTx: {
    fontFamily: FONTS.bodySemiBold, fontSize: 10,
    color: COLORS.green, letterSpacing: 0.3, textTransform: 'capitalize',
  },
  zoneLabel: {
    position: 'absolute', top: 10, right: 10,
    backgroundColor: 'rgba(0,0,0,0.60)',
    borderRadius: 20, paddingHorizontal: 8, paddingVertical: 4,
    borderWidth: 1, borderColor: 'rgba(255,255,255,0.10)',
  },
  zoneLabelTx: {
    fontFamily: FONTS.body, fontSize: 9,
    color: 'rgba(255,255,255,0.55)', letterSpacing: 0.3,
  },

  // Marcadores del mapa
  clientMarker: {
    width: 36, height: 36, borderRadius: 18,
    overflow: 'hidden', borderWidth: 2.5, borderColor: '#fff',
    backgroundColor: COLORS.card,
    alignItems: 'center', justifyContent: 'center',
  },
  clientMarkerImg:      { width: '100%', height: '100%' },
  clientMarkerFallback: { width: '100%', height: '100%', alignItems: 'center', justifyContent: 'center' },
  instrEmoji:           { fontSize: 15 },

  body: { paddingHorizontal: 14, paddingTop: 12, paddingBottom: 14, gap: 10 },

  // Info del grupo
  groupRow:     { flexDirection: 'row', alignItems: 'center', gap: 10 },
  avatarWrap:   {},
  avatar:       { width: 56, height: 56, borderRadius: 28, borderWidth: 2, borderColor: 'rgba(0,230,118,0.40)' },
  avatarFallback: {
    width: 56, height: 56, borderRadius: 28,
    backgroundColor: 'rgba(0,230,118,0.12)',
    alignItems: 'center', justifyContent: 'center',
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.25)',
  },
  avatarEmoji: { fontSize: 24 },
  groupName:   { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.text },
  groupCity:   { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2 },

  profileBtn: {
    flexDirection: 'row', alignItems: 'center', gap: 3,
    paddingHorizontal: 8, paddingVertical: 5,
    borderRadius: RADIUS.md,
    backgroundColor: 'rgba(0,230,118,0.08)',
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.22)',
  },
  profileBtnTx: { fontFamily: FONTS.bodyMedium, fontSize: 11, color: COLORS.green },

  // Stats
  statsRow: { flexDirection: 'row', alignItems: 'center', gap: 12 },
  stat:     { alignItems: 'flex-start', gap: 2 },
  statVal:  { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.text },
  statLbl:  { fontFamily: FONTS.body, fontSize: 10, color: COLORS.muted },
  statDiv:  { width: 1, height: 26, backgroundColor: 'rgba(255,255,255,0.07)' },

  // Precio
  priceBox: {
    backgroundColor: 'rgba(0,0,0,0.30)',
    borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.12)',
    paddingHorizontal: 10, paddingVertical: 8, gap: 5,
  },
  priceRow:    { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center' },
  priceLabel:  { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2 },
  priceValSub: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.text },
  totalRow: {
    marginTop: 4, paddingTop: 6,
    borderTopWidth: 1, borderTopColor: 'rgba(0,230,118,0.2)',
  },
  totalLabel: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.text },
  totalVal:   { fontFamily: FONTS.title, fontSize: 17, color: COLORS.green },

  // Horario
  timesRow: { flexDirection: 'row', gap: 8 },
  timeChip: {
    flex: 1, backgroundColor: 'rgba(0,230,118,0.07)',
    borderRadius: RADIUS.md, borderWidth: 1, borderColor: 'rgba(0,230,118,0.18)',
    paddingHorizontal: 10, paddingVertical: 7, alignItems: 'center',
  },
  timeChipLabel: { fontFamily: FONTS.body, fontSize: 10, color: COLORS.muted2, marginBottom: 2 },
  timeChipVal:   { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.green },

  // Notas
  notes: {
    fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2,
    lineHeight: 17, marginTop: -2,
  },

  // Botones
  actions:     { flexDirection: 'row', gap: 8, marginTop: 2 },
  btnGhost:    {
    paddingHorizontal: 14, paddingVertical: 11,
    borderRadius: RADIUS.lg, alignItems: 'center', justifyContent: 'center',
  },
  btnGhostTx:  { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted },
  btnPrimary:  {
    flex: 1, flexDirection: 'row', alignItems: 'center', justifyContent: 'center',
    gap: 5, paddingVertical: 11, borderRadius: RADIUS.lg, backgroundColor: COLORS.green,
  },
  btnBlocked:   { backgroundColor: 'rgba(255,255,255,0.06)', borderWidth: 1, borderColor: 'rgba(255,255,255,0.08)' },
  btnPrimaryTx: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.bg },

  // Overlay bloqueado
  blockedOverlay: {
    position: 'absolute', bottom: 0, left: 0, right: 0, height: 50,
    backgroundColor: 'rgba(6,12,6,0.82)', alignItems: 'center', justifyContent: 'center',
  },
  blockedTx: { fontFamily: FONTS.bodySemiBold, fontSize: 12, color: COLORS.muted2 },
});
