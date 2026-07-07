import React, { useCallback, useEffect, useRef, useState } from 'react';
import {
  Animated,
  Dimensions,
  Image,
  Pressable,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import * as Haptics from 'expo-haptics';
import { Clock, MapPin, Users, Zap } from 'lucide-react-native';
import { supabase } from '../../config/supabase';
import { COLORS, FONTS, RADIUS } from '../../config/theme';
import type { ExpressDispatch } from '../../context/ExpressContext';
import { estimateEtaMin, formatDist, formatEta, haversineKm, privacyOffsetZone } from '../../utils/mapUtils';
import RequestZoneMap, { EVENT_LABELS, fmtDate, MAP_H } from '../requests/RequestZoneMap';
import ClientProfileModal from '../requests/ClientProfileModal';
import RequestDetailsModal from '../requests/RequestDetailsModal';
import { playCriticalTick } from '../../utils/expressSound';

// ── Public layout constants ───────────────────────────────────────────────────
const { width: W } = Dimensions.get('window');
export const CARD_WIDTH   = Math.round(W * 0.86);
export const LIST_PADDING = Math.round((W - CARD_WIDTH) / 2);
export const CARD_GAP     = 12;

// ── CountdownDisplay — isolated re-render island, ticks every second ──────────
function CountdownDisplay({ expiresAt, onExpire }: { expiresAt?: string; onExpire?: () => void }) {
  const [ms, setMs] = useState(() =>
    expiresAt ? Math.max(0, new Date(expiresAt).getTime() - Date.now()) : 180_000
  );
  const criticalFiredRef = useRef(false);
  const expiredFiredRef  = useRef(false);

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
    // Al llegar a 0: la tarjeta se quita sola (no espera al cron de 5 min)
    if (secs <= 0 && expiresAt && !expiredFiredRef.current) {
      expiredFiredRef.current = true;
      onExpire?.();
    }
  }, [secs, expiresAt, onExpire]);

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
  onExpire?:      (id: string) => void;
  isBlocked?:     boolean;
  isFocused?:     boolean;
  userLocation?:  { latitude: number; longitude: number } | null;
  groupPhotoUrl?: string | null;
}

const ExpressCard = React.memo(function ExpressCard({
  dispatch, onCotizar, onDismiss, onExpire, isBlocked = false, userLocation, groupPhotoUrl,
}: Props) {
  const { id, request, status, expires_at } = dispatch;
  const isTaken = status === 'taken';

  // Perfil público del cliente (RPC 435 — sin teléfono/email por construcción)
  const clientId = request?.client_id ?? null;
  const [clientProfile, setClientProfile] = useState<{ full_name: string | null; avatar_url: string | null; city: string | null } | null>(null);
  const [profileOpen,   setProfileOpen]   = useState(false);
  const [detailsOpen,   setDetailsOpen]   = useState(false);
  useEffect(() => {
    if (!clientId) { setClientProfile(null); return; }
    let cancelled = false;
    supabase.rpc('get_client_public_profile', { p_client_id: clientId }).then(({ data }) => {
      if (!cancelled && data?.ok) setClientProfile(data);
    });
    return () => { cancelled = true; };
  }, [clientId]);

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
  const center = privacyOffsetZone(
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

        <RequestZoneMap
          mapId={id} center={center}
          userLocation={userLocation} groupPhotoUrl={groupPhotoUrl}
          typeLabel="⚡ Express"
        />

        <View style={s.cdPosition} pointerEvents="none">
          <CountdownDisplay expiresAt={expires_at} onExpire={() => onExpire?.(id)} />
        </View>

        <View style={s.body}>
          {/* Cliente que solicita — espejo de la tarjeta que ve el cliente */}
          {clientProfile && (
            <View style={s.clientRow}>
              {clientProfile.avatar_url
                ? <Image source={{ uri: clientProfile.avatar_url }} style={s.clientAvatar} />
                : (
                  <View style={s.clientAvatarPlaceholder}>
                    <Text style={s.clientAvatarInitial}>
                      {(clientProfile.full_name ?? '?').charAt(0).toUpperCase()}
                    </Text>
                  </View>
                )
              }
              <View style={{ flex: 1 }}>
                <Text style={s.clientName} numberOfLines={1}>{clientProfile.full_name ?? 'Cliente'}</Text>
                {clientProfile.city ? <Text style={s.clientCity} numberOfLines={1}>{clientProfile.city}</Text> : null}
              </View>
              <Pressable
                onPress={() => setProfileOpen(true)}
                hitSlop={8}
                style={({ pressed }) => [s.viewProfileBtn, pressed && { opacity: 0.6 }]}
              >
                <Text style={s.viewProfileTx}>Ver perfil ›</Text>
              </Pressable>
            </View>
          )}

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
                <View style={s.statDiv} />
                <View style={s.stat}>
                  <View style={{ flexDirection: 'row', alignItems: 'center', gap: 3 }}>
                    <Clock size={10} color={COLORS.muted2} />
                    <Text style={s.statVal}>{formatEta(estimateEtaMin(distKm))}</Text>
                  </View>
                  <Text style={s.statLbl}>llegada</Text>
                </View>
              </>
            )}
          </View>

          <View style={s.actions}>
            <Pressable onPress={handleDismiss} hitSlop={12}
              style={({ pressed }) => [s.btnGhost, pressed && { opacity: 0.5 }]}>
              <Text style={s.btnGhostTx}>Ignorar</Text>
            </Pressable>
            <Pressable onPress={() => setDetailsOpen(true)} hitSlop={8}
              style={({ pressed }) => [s.btnOutline, pressed && { opacity: 0.6 }]}>
              <Text style={s.btnOutlineTx}>Detalles</Text>
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

      <ClientProfileModal
        clientId={profileOpen ? clientId : null}
        onClose={() => setProfileOpen(false)}
      />
      <RequestDetailsModal
        request={detailsOpen ? (request ?? null) : null}
        onClose={() => setDetailsOpen(false)}
        onCotizar={isBlocked ? undefined : () => { setDetailsOpen(false); handleCotizar(); }}
      />
    </Animated.View>
  );
});

export default ExpressCard;

// ── Styles ────────────────────────────────────────────────────────────────────
const s = StyleSheet.create({
  card:    { width: CARD_WIDTH, backgroundColor: '#060c06', borderRadius: RADIUS.xl, overflow: 'hidden', borderWidth: 1, borderColor: 'rgba(0,230,118,0.55)' },

  cdPosition:   { position: 'absolute', top: MAP_H - 34, right: 10 },
  cdChip:       { flexDirection: 'row', alignItems: 'center', gap: 4, backgroundColor: 'rgba(0,0,0,0.72)', borderRadius: 20, paddingHorizontal: 8, paddingVertical: 4, borderWidth: 1, borderColor: 'rgba(255,255,255,0.1)' },
  cdChipUrgent: { borderColor: 'rgba(239,83,80,0.5)', backgroundColor: 'rgba(239,83,80,0.1)' },
  cdText:       { fontFamily: FONTS.bodySemiBold, fontSize: 11, letterSpacing: 0.5 },

  body:      { paddingHorizontal: 16, paddingTop: 13, paddingBottom: 15, gap: 9 },
  eventType: { fontFamily: FONTS.bodySemiBold, fontSize: 16, color: COLORS.text, letterSpacing: 0.1 },
  cityTx:    { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2, marginTop: -5 },

  clientRow:               { flexDirection: 'row', alignItems: 'center', gap: 10 },
  clientAvatar:            { width: 40, height: 40, borderRadius: 20 },
  clientAvatarPlaceholder: { width: 40, height: 40, borderRadius: 20, backgroundColor: 'rgba(0,230,118,0.12)', alignItems: 'center', justifyContent: 'center' },
  clientAvatarInitial:     { fontFamily: FONTS.bodySemiBold, fontSize: 17, color: COLORS.green },
  clientName:              { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.text },
  clientCity:              { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted2, marginTop: 1 },
  viewProfileBtn: {
    backgroundColor: 'rgba(0,230,118,0.10)', borderRadius: 20,
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.35)',
    paddingHorizontal: 10, paddingVertical: 5,
  },
  viewProfileTx: { fontFamily: FONTS.bodySemiBold, fontSize: 11, color: COLORS.green },

  statsRow: { flexDirection: 'row', flexWrap: 'wrap', alignItems: 'center', gap: 12, rowGap: 8 },
  stat:     { alignItems: 'flex-start', gap: 2 },
  statVal:  { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.text },
  statLbl:  { fontFamily: FONTS.body, fontSize: 10, color: COLORS.muted },
  statDiv:  { width: 1, height: 26, backgroundColor: 'rgba(255,255,255,0.07)' },

  actions:      { flexDirection: 'row', gap: 8, marginTop: 2 },
  btnGhost:     { paddingHorizontal: 12, paddingVertical: 10, borderRadius: RADIUS.lg, alignItems: 'center', justifyContent: 'center' },
  btnGhostTx:   { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted },
  btnOutline:   { paddingHorizontal: 14, paddingVertical: 10, borderRadius: RADIUS.lg, alignItems: 'center', justifyContent: 'center', borderWidth: 1, borderColor: 'rgba(0,230,118,0.35)', backgroundColor: 'rgba(0,230,118,0.08)' },
  btnOutlineTx: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.green },
  btnPrimary:   { flex: 1, flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 5, paddingVertical: 10, borderRadius: RADIUS.lg, backgroundColor: COLORS.green },
  btnBlocked:   { backgroundColor: 'rgba(255,255,255,0.06)', borderWidth: 1, borderColor: 'rgba(255,255,255,0.08)' },
  btnPrimaryTx: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.bg },

  blockedOverlay: { position: 'absolute', bottom: 0, left: 0, right: 0, height: 56, backgroundColor: 'rgba(6,12,6,0.78)', alignItems: 'center', justifyContent: 'center', gap: 3 },
  blockedTx:      { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.muted2 },
  blockedSub:     { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted },

  takenOverlay: { backgroundColor: 'rgba(6,12,6,0.90)', alignItems: 'center', justifyContent: 'center', gap: 8, borderRadius: RADIUS.xl },
  takenIcon:    { fontSize: 32 },
  takenTitle:   { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.text },
  takenSub:     { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, textAlign: 'center', paddingHorizontal: 24 },
});
