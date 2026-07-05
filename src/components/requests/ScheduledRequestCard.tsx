/**
 * ScheduledRequestCard — tarjeta premium para solicitudes PROGRAMADAS
 * (abiertas) del grupo, con la misma experiencia visual que ExpressCard:
 * mapa de zona aproximada inline (offset de privacidad ±220 m — la
 * dirección exacta solo se revela tras el pago), badge de género sobre
 * el mapa, tipo de evento y fila de stats (hrs/fecha/hora/personas/de ti).
 *
 * Conserva lo propio de las abiertas que la exprés no tiene: quién
 * contrata, 🆕 NUEVO, ⏱ expiración 48h, 🔥 evento urgente, 👀 competencia,
 * ✨ tarifa protegida y el estado de propuesta enviada. Sin countdown
 * sonoro (la urgencia de segundos es solo exprés).
 *
 * Tocar el mapa abre el modal de zona completa (onPressMap).
 */
import React, { useState } from 'react';
import { Image, Pressable, StyleSheet, Text, View } from 'react-native';
import { Clock, MapPin, Users, Zap } from 'lucide-react-native';
import { COLORS, FONTS, RADIUS } from '../../config/theme';
import { parseEventDateMX } from '../../utils/calculations';
import { formatDist, haversineKm, privacyOffsetZone } from '../../utils/mapUtils';
import RequestZoneMap, { EVENT_LABELS, fmtDate, MAP_H } from './RequestZoneMap';
import RequestDetailsModal from './RequestDetailsModal';

export interface ScheduledRequestData {
  id: string;
  genre: string;
  event_type: string;
  event_date: string;
  event_time: string | null;
  hours: number;
  guest_count: number | null;
  location_city: string;
  location_municipio: string | null;
  location_estado: string;
  venue_covered: string | null;
  venue_size?: string | null;
  needs_sound?: string | null;
  comments: string | null;
  created_at: string;
  expires_at: string;
  notified_count: number | null;
  latitude?: number | null;
  longitude?: number | null;
  event_lat?: number | null;
  event_lng?: number | null;
  demand_multiplier?: number | null;
  requester?: { full_name: string | null; avatar_url: string | null; role: string | null } | null;
}

interface Props {
  request:         ScheduledRequestData;
  alreadyProposed: boolean;
  highlighted:     boolean;
  userLocation?:   { latitude: number; longitude: number } | null;
  groupPhotoUrl?:  string | null;
  onPropose:       () => void;
  onPressMap:      () => void;
  onViewProfile?:  () => void;   // abre el perfil público del cliente (RPC 435)
}

const VENUE_COVERED_LABELS: Record<string, string> = {
  si:    '✅ Techado',
  no:    '☀️ Al aire libre',
  no_se: '❓ Techado por confirmar',
};

function timeUntilExpiry(expiresAt: string): string {
  const diff = new Date(expiresAt).getTime() - Date.now();
  if (diff <= 0) return 'Expirada';
  const hours = Math.floor(diff / 3_600_000);
  const mins  = Math.floor((diff % 3_600_000) / 60_000);
  const secs  = Math.floor((diff % 60_000) / 1_000);
  if (hours > 0) return `${hours}h ${mins}min restantes`;
  if (mins > 0)  return `${mins}m ${String(secs).padStart(2, '0')}s`;
  return `${secs}s`;
}

function formatTime12h(t: string): string {
  const [hStr, mStr] = t.split(':');
  const h = parseInt(hStr, 10);
  return `${h % 12 || 12}:${mStr} ${h >= 12 ? 'PM' : 'AM'}`;
}

export default function ScheduledRequestCard({
  request: req, alreadyProposed, highlighted, userLocation, groupPhotoUrl, onPropose, onPressMap, onViewProfile,
}: Props) {
  const [detailsOpen, setDetailsOpen] = useState(false);
  const center = privacyOffsetZone(
    req.id, req.location_city, req.location_estado,
    req.latitude, req.longitude,
    req.event_lat, req.event_lng,
  );
  const distKm = userLocation
    ? haversineKm(userLocation.latitude, userLocation.longitude, center.latitude, center.longitude)
    : null;

  const diffMs    = new Date(req.expires_at).getTime() - Date.now();
  const isUrgent  = diffMs > 0 && diffMs < 5 * 60_000;
  const isWarning = diffMs >= 5 * 60_000 && diffMs < 10 * 60_000;
  const isNew     = Date.now() - new Date(req.created_at).getTime() < 10 * 60_000;
  const viewers   = req.notified_count ?? 0;

  const eventStart =
    parseEventDateMX(req.event_date, req.event_time ?? '20:00')?.getTime() ?? null;
  const isEventUrgent = eventStart !== null && eventStart - Date.now() < 6 * 3_600_000 && eventStart > Date.now();

  const requester = req.requester;
  const requesterLabel = requester?.role === 'group'
    ? '🎸 Grupo'
    : requester?.role === 'talent' ? '🎵 Músico independiente' : '👤 Cliente particular';

  return (
    <View style={[s.card, highlighted && s.cardHighlighted, isNew && !highlighted && s.cardNew]}>

      {/* Mapa de zona — tocar abre el modal de zona completa */}
      <Pressable onPress={onPressMap}>
        <RequestZoneMap mapId={req.id} center={center} userLocation={userLocation} groupPhotoUrl={groupPhotoUrl} typeLabel="📅 Programada" />
        <View style={s.expandChip} pointerEvents="none">
          <MapPin size={9} color={COLORS.green} />
          <Text style={s.expandChipTx}>Ampliar</Text>
        </View>
      </Pressable>

      {/* Expiración de la solicitud, anclada al mapa como el countdown exprés */}
      <View style={s.expiryPosition} pointerEvents="none">
        <View style={[s.expiryChip, isWarning && s.expiryChipWarning, isUrgent && s.expiryChipUrgent]}>
          <Clock size={9} color={isUrgent ? '#FF5252' : isWarning ? '#FFA726' : COLORS.green} />
          <Text style={[s.expiryTx, isWarning && { color: '#FFA726' }, isUrgent && { color: '#FF5252' }]}>
            ⏱ {timeUntilExpiry(req.expires_at)}
          </Text>
        </View>
      </View>

      <View style={s.body}>
        {highlighted && (
          <View style={s.highlightBanner}>
            <Text style={s.highlightBannerTx}>📩 Solicitud que te notificó — revisa los detalles</Text>
          </View>
        )}

        {/* Quién contrata — espejo de la tarjeta que ve el cliente */}
        {requester && (
          <View style={s.requesterRow}>
            {requester.avatar_url
              ? <Image source={{ uri: requester.avatar_url }} style={s.requesterAvatar} />
              : (
                <View style={s.requesterAvatarPlaceholder}>
                  <Text style={s.requesterAvatarInitial}>
                    {(requester.full_name ?? '?').charAt(0).toUpperCase()}
                  </Text>
                </View>
              )
            }
            <View style={{ flex: 1 }}>
              <Text style={s.requesterNameTx} numberOfLines={1}>{requester.full_name ?? 'Cliente'}</Text>
              <Text style={s.requesterTypeTx}>{requesterLabel}</Text>
            </View>
            {onViewProfile && (
              <Pressable
                onPress={onViewProfile}
                hitSlop={8}
                style={({ pressed }) => [s.viewProfileBtn, pressed && { opacity: 0.6 }]}
              >
                <Text style={s.viewProfileTx}>Ver perfil ›</Text>
              </Pressable>
            )}
          </View>
        )}

        <Text style={s.eventType} numberOfLines={1}>
          {EVENT_LABELS[req.event_type] ?? req.event_type}
        </Text>
        <Text style={s.cityTx} numberOfLines={1}>
          {req.location_city}{req.location_municipio ? `, ${req.location_municipio}` : ''} · 🔒 dirección oculta
        </Text>

        {/* Badges propios de programadas */}
        {(isNew || isEventUrgent || viewers > 1 || (req.demand_multiplier ?? 1) > 1 || alreadyProposed) && (
          <View style={s.badgeRow}>
            {isNew && (
              <View style={s.newBadge}><Text style={s.newBadgeTx}>🆕 NUEVO</Text></View>
            )}
            {isEventUrgent && (
              <View style={s.urgentBadge}><Text style={s.urgentBadgeTx}>🔥 Evento urgente</Text></View>
            )}
            {viewers > 1 && (
              <View style={s.competitionBadge}><Text style={s.competitionBadgeTx}>👀 {viewers} grupos lo ven</Text></View>
            )}
            {(req.demand_multiplier ?? 1) > 1 && (
              <View style={s.surgeBadge}><Text style={s.surgeBadgeTx}>✨ Tarifa protegida</Text></View>
            )}
            {alreadyProposed && (
              <View style={s.surgeBadge}><Text style={s.surgeBadgeTx}>📩 Tu propuesta enviada</Text></View>
            )}
          </View>
        )}

        {/* Stats — misma fila que ExpressCard */}
        <View style={s.statsRow}>
          <View style={s.stat}>
            <Text style={s.statVal}>{req.hours ?? '—'}</Text>
            <Text style={s.statLbl}>hrs</Text>
          </View>
          <View style={s.statDiv} />
          <View style={s.stat}>
            <Text style={s.statVal} numberOfLines={1}>{fmtDate(req.event_date)}</Text>
            <Text style={s.statLbl}>fecha</Text>
          </View>
          {req.event_time ? (
            <>
              <View style={s.statDiv} />
              <View style={s.stat}>
                <Text style={s.statVal}>{formatTime12h(req.event_time)}</Text>
                <Text style={s.statLbl}>hora</Text>
              </View>
            </>
          ) : null}
          {req.guest_count ? (
            <>
              <View style={s.statDiv} />
              <View style={s.stat}>
                <View style={{ flexDirection: 'row', alignItems: 'center', gap: 3 }}>
                  <Users size={10} color={COLORS.muted2} />
                  <Text style={s.statVal}>{req.guest_count}</Text>
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

        {req.venue_covered && (
          <Text style={s.venueTx}>{VENUE_COVERED_LABELS[req.venue_covered] ?? req.venue_covered}</Text>
        )}

        {req.comments ? (
          <View style={s.commentsBox}>
            <Text style={s.commentsTx} numberOfLines={3}>💬 {req.comments}</Text>
          </View>
        ) : null}

        {alreadyProposed && (
          <View style={s.awaitingBanner}>
            <Text style={s.awaitingTx}>⏳ Tu propuesta está en revisión. El cliente decidirá pronto.</Text>
          </View>
        )}

        <View style={s.actions}>
          <Pressable
            onPress={() => setDetailsOpen(true)}
            hitSlop={8}
            style={({ pressed }) => [s.btnOutline, pressed && { opacity: 0.6 }]}
          >
            <Text style={s.btnOutlineTx}>Detalles</Text>
          </Pressable>
          <Pressable
            onPress={onPropose}
            style={({ pressed }) => [s.btnPrimary, pressed && { opacity: 0.82 }]}
          >
            <Zap size={12} color={COLORS.bg} />
            <Text style={s.btnPrimaryTx}>
              {alreadyProposed ? 'Actualizar propuesta' : 'Cotizar'}
            </Text>
          </Pressable>
        </View>

        <Text style={s.addressNote}>🔒 Dirección exacta visible al confirmar pago</Text>
      </View>

      <RequestDetailsModal
        request={detailsOpen ? req : null}
        onClose={() => setDetailsOpen(false)}
        onCotizar={() => { setDetailsOpen(false); onPropose(); }}
      />
    </View>
  );
}

// ── Styles — paleta y proporciones de ExpressCard ─────────────────────────────
const s = StyleSheet.create({
  card:            { width: '100%', backgroundColor: '#060c06', borderRadius: RADIUS.xl, overflow: 'hidden', borderWidth: 1, borderColor: 'rgba(0,230,118,0.14)' },
  cardNew:         { borderColor: 'rgba(0,230,118,0.50)' },
  cardHighlighted: { borderColor: 'rgba(99,102,241,0.60)' },

  expandChip:   { position: 'absolute', bottom: 8, left: 10, flexDirection: 'row', alignItems: 'center', gap: 4, backgroundColor: 'rgba(0,0,0,0.72)', borderRadius: 20, paddingHorizontal: 8, paddingVertical: 4, borderWidth: 1, borderColor: 'rgba(0,230,118,0.28)' },
  expandChipTx: { fontFamily: FONTS.bodySemiBold, fontSize: 9, color: COLORS.green, letterSpacing: 0.3 },

  expiryPosition:    { position: 'absolute', top: MAP_H - 34, right: 10 },
  expiryChip:        { flexDirection: 'row', alignItems: 'center', gap: 4, backgroundColor: 'rgba(0,0,0,0.72)', borderRadius: 20, paddingHorizontal: 8, paddingVertical: 4, borderWidth: 1, borderColor: 'rgba(255,255,255,0.1)' },
  expiryChipWarning: { borderColor: 'rgba(255,167,38,0.5)', backgroundColor: 'rgba(255,167,38,0.10)' },
  expiryChipUrgent:  { borderColor: 'rgba(239,83,80,0.5)', backgroundColor: 'rgba(239,83,80,0.10)' },
  expiryTx:          { fontFamily: FONTS.bodySemiBold, fontSize: 10, color: COLORS.green, letterSpacing: 0.2 },

  body:      { paddingHorizontal: 16, paddingTop: 13, paddingBottom: 15, gap: 9 },
  eventType: { fontFamily: FONTS.bodySemiBold, fontSize: 16, color: COLORS.text, letterSpacing: 0.1 },
  cityTx:    { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2, marginTop: -5 },

  highlightBanner:   { backgroundColor: 'rgba(99,102,241,0.15)', borderRadius: RADIUS.sm, borderWidth: 1, borderColor: 'rgba(99,102,241,0.35)', paddingHorizontal: 10, paddingVertical: 6 },
  highlightBannerTx: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: '#818CF8' },

  requesterRow:               { flexDirection: 'row', alignItems: 'center', gap: 8 },
  requesterAvatar:            { width: 28, height: 28, borderRadius: 14 },
  requesterAvatarPlaceholder: { width: 28, height: 28, borderRadius: 14, backgroundColor: 'rgba(0,230,118,0.12)', alignItems: 'center', justifyContent: 'center' },
  requesterAvatarInitial:     { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.green },
  requesterNameTx:            { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.text },
  requesterTypeTx:            { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted2, marginTop: 1 },
  viewProfileBtn: {
    backgroundColor: 'rgba(0,230,118,0.10)', borderRadius: 20,
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.35)',
    paddingHorizontal: 10, paddingVertical: 5,
  },
  viewProfileTx: { fontFamily: FONTS.bodySemiBold, fontSize: 11, color: COLORS.green },

  badgeRow: { flexDirection: 'row', flexWrap: 'wrap', gap: 6 },
  newBadge:            { backgroundColor: 'rgba(0,230,118,0.15)', borderRadius: 20, borderWidth: 1, borderColor: 'rgba(0,230,118,0.40)', paddingHorizontal: 8, paddingVertical: 3 },
  newBadgeTx:          { fontFamily: FONTS.bodySemiBold, fontSize: 10, color: COLORS.green },
  urgentBadge:         { backgroundColor: 'rgba(255,60,0,0.15)', borderRadius: 20, borderWidth: 1, borderColor: 'rgba(255,60,0,0.50)', paddingHorizontal: 8, paddingVertical: 3 },
  urgentBadgeTx:       { fontFamily: FONTS.bodySemiBold, fontSize: 10, color: '#FF3C00' },
  competitionBadge:    { backgroundColor: 'rgba(66,133,244,0.12)', borderRadius: 20, borderWidth: 1, borderColor: 'rgba(66,133,244,0.35)', paddingHorizontal: 8, paddingVertical: 3 },
  competitionBadgeTx:  { fontFamily: FONTS.bodyMedium, fontSize: 10, color: COLORS.blue },
  surgeBadge:          { backgroundColor: 'rgba(0,230,118,0.10)', borderRadius: 20, borderWidth: 1, borderColor: 'rgba(0,230,118,0.35)', paddingHorizontal: 8, paddingVertical: 3 },
  surgeBadgeTx:        { fontFamily: FONTS.bodyMedium, fontSize: 10, color: COLORS.green },

  statsRow: { flexDirection: 'row', flexWrap: 'wrap', alignItems: 'center', gap: 12 },
  stat:     { alignItems: 'flex-start', gap: 2 },
  statVal:  { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.text },
  statLbl:  { fontFamily: FONTS.body, fontSize: 10, color: COLORS.muted },
  statDiv:  { width: 1, height: 26, backgroundColor: 'rgba(255,255,255,0.07)' },

  venueTx: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, marginTop: -3 },

  commentsBox: { backgroundColor: 'rgba(255,255,255,0.03)', borderRadius: RADIUS.md, borderWidth: 1, borderColor: 'rgba(255,255,255,0.06)', padding: 10 },
  commentsTx:  { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, lineHeight: 18 },

  awaitingBanner: { backgroundColor: 'rgba(0,230,118,0.08)', borderRadius: RADIUS.md, borderWidth: 1, borderColor: 'rgba(0,230,118,0.25)', padding: 10 },
  awaitingTx:     { fontFamily: FONTS.body, fontSize: 12, color: COLORS.green, lineHeight: 18 },

  actions:      { flexDirection: 'row', gap: 8, marginTop: 2 },
  btnOutline:   { paddingHorizontal: 14, paddingVertical: 10, borderRadius: RADIUS.lg, alignItems: 'center', justifyContent: 'center', borderWidth: 1, borderColor: 'rgba(0,230,118,0.35)', backgroundColor: 'rgba(0,230,118,0.08)' },
  btnOutlineTx: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.green },
  btnPrimary:   { flex: 1, flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 5, paddingVertical: 10, borderRadius: RADIUS.lg, backgroundColor: COLORS.green },
  btnPrimaryTx: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.bg },

  addressNote: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted, textAlign: 'center', marginTop: 2 },
});
