/**
 * TicketScreen — Ticket premium con código de inicio y modo regalo.
 */
import React, { useRef, useState } from 'react';
import {
  ActivityIndicator, Alert, Image, Pressable,
  ScrollView, Share, StyleSheet, Switch, Text, TextInput, View,
} from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { LinearGradient } from 'expo-linear-gradient';
import { captureRef } from 'react-native-view-shot';
import * as MediaLibrary from 'expo-media-library';
import { ArrowLeft, Download, Gift, Share2 } from 'lucide-react-native';
import { FONTS } from '../../config/theme';

// ── Tokens de diseño ──────────────────────────────────────────────────────────
const OUTER_BG    = '#050A13';
const CARD_BG     = '#080F1C';   // para outer/botones
// 🌈 HOLOGRÁFICO verde/azul (pedido 2026-07-15) — reemplaza al dorado.
// El marco y los acentos van en degradado verde → cian → azul, como los
// tickets iridiscentes de imprenta.
const GOLD        = '#00B8D9';   // acento principal (cian) — mismo nombre para no tocar 40 refs
const GOLD_LIGHT  = '#00E676';
const GOLD_DIM    = 'rgba(0,184,217,0.10)';
const GOLD_BORDER = 'rgba(0,184,217,0.30)';
const HOLO_FRAME  = ['#00E676', '#4ADE80', '#22D3EE', '#3B82F6', '#22D3EE', '#00E676'] as const;
const HOLO_STOPS  = ['#00A651', '#00B8A9', '#0891B2', '#2563EB'];   // texto holo (legible en blanco)
const TEXT_MAIN   = '#E8EDF5';   // texto fuera del ticket
const TEXT_MUTED  = '#5A6A8A';
const TEXT_MUTED2 = '#8096B8';

// Ticket blanco — paleta interna
const T_BG      = '#FFFFFF';
const T_BG2     = '#F6F7F9';
const T_TEXT    = '#111827';
const T_MUTED   = '#6B7280';
const T_MUTED2  = '#374151';
const T_BORDER  = '#E5E7EB';
const T_GREEN   = '#00A651';     // verde más oscuro para legibilidad en blanco
const T_GREEN2  = 'rgba(0,166,81,0.10)';
const T_NAVY    = '#1E3A8A';     // código de barras

// ── Helpers ───────────────────────────────────────────────────────────────────
function fmtDate(d: string) {
  const dt = new Date(d + 'T12:00:00');
  const s = dt.toLocaleDateString('es-MX', {
    weekday: 'long', day: 'numeric', month: 'long', year: 'numeric',
  });
  return s.charAt(0).toUpperCase() + s.slice(1);
}

function fmtTime(t: string) {
  const [h, m] = t.substring(0, 5).split(':').map(Number);
  return `${h % 12 || 12}:${String(m).padStart(2, '0')} ${h >= 12 ? 'PM' : 'AM'}`;
}

function fmtDuration(r: any) {
  const h = r.quote?.duration_hours ?? r.hours_count;
  if (!h) return null;
  return `${h === 5 ? '+4' : h} hora${h !== 1 ? 's' : ''}`;
}

const GENRE_MAP: Record<string, string> = {
  mariachi:    '🎺 Mariachi',    banda:       '🥁 Banda',
  norteño:     '🎵 Norteño',     norterio:    '🎵 Norteño',
  jazz:        '🎷 Jazz',        tropical:    '🌴 Tropical',
  pop:         '🎤 Pop',         rock:        '🎸 Rock',
  clasica:     '🎻 Clásica',     clasico:     '🎻 Clásica',
  folclorico:  '🪗 Folclórico',  electronica: '🎛️ Electrónica',
};

// ── Sub-componentes ───────────────────────────────────────────────────────────

function DashedLine() {
  return (
    <View style={{ flex: 1, flexDirection: 'row', overflow: 'hidden', alignItems: 'center' }}>
      {Array.from({ length: 60 }, (_, i) => (
        <View key={i} style={{ width: 4, height: 1, backgroundColor: T_BORDER, marginRight: 4 }} />
      ))}
    </View>
  );
}

function Perforation() {
  return (
    <View style={{ flexDirection: 'row', alignItems: 'center', marginHorizontal: 0, marginVertical: 8 }}>
      <DashedLine />
    </View>
  );
}

// 🌈 Texto "holográfico": cada carácter interpola verde → cian → azul.
// (Sin masked-view: el degradado por carácter da el efecto iridiscente
// y sobrevive perfecto a la captura de imagen y a la imprenta.)
function HoloText({ text, style }: { text: string; style?: any }) {
  const chars = String(text).split('');
  const n = Math.max(1, chars.length - 1);
  return (
    <View style={{ flexDirection: 'row', justifyContent: 'center' }}>
      {chars.map((c, i) => (
        <Text
          key={i}
          style={[style, { color: HOLO_STOPS[Math.min(HOLO_STOPS.length - 1, Math.round((i / n) * (HOLO_STOPS.length - 1)))] }]}
        >
          {c}
        </Text>
      ))}
    </View>
  );
}

// Código de barras decorativo determinístico a partir del folio
function Barcode({ seed }: { seed: string }) {
  const chars = (seed && seed !== '—' ? seed : 'DARICEFY').split('');
  const bars: number[] = [];
  chars.forEach(c => {
    const v = c.charCodeAt(0);
    bars.push((v % 3) + 1, ((v >> 2) % 2) + 1, ((v >> 4) % 3) + 1);
  });
  return (
    <View style={{ flexDirection: 'row', alignItems: 'flex-end', height: 34, gap: 1.5, justifyContent: 'center' }}>
      {bars.map((w, i) => (
        <View key={i} style={{ width: w, height: i % 7 === 0 ? 34 : 28, backgroundColor: T_NAVY }} />
      ))}
    </View>
  );
}

function DigitBox({ digit, index }: { digit: string; index?: number }) {
  const holo = HOLO_STOPS[Math.min(HOLO_STOPS.length - 1, (index ?? 0))];
  return (
    <View style={[s.digitBox, { borderColor: holo }]}>
      <Text style={[s.digitText, { color: holo }]}>{digit}</Text>
    </View>
  );
}

function InfoRow({ icon, value, gold }: { icon: string; value: string; gold?: boolean }) {
  return (
    <View style={s.infoRow}>
      <Text style={s.infoIcon}>{icon}</Text>
      <Text style={gold ? s.infoValueGold : s.infoValue}>{value}</Text>
    </View>
  );
}

// ── Pantalla principal ────────────────────────────────────────────────────────
export default function TicketScreen({ navigation, route }: any) {
  // senderName (opcional): nombre del comprador para "De:" (lo pasa QuotePayment).
  const { reservation: r, senderName } = route.params as { reservation: any; senderName?: string };

  const ticketRef = useRef<View>(null);
  // Caja de regalo: si la reserva ES regalo, el ticket entra en modo regalo
  // automáticamente con el destinatario y el mensaje reales.
  const [giftMode, setGiftMode] = useState(!!r.is_gift);
  const [giftFrom, setGiftFrom] = useState(senderName ?? '');
  const [giftTo,   setGiftTo]   = useState(r.gift_recipient_name ?? '');
  const [saving,   setSaving]   = useState(false);

  const giftMsg  = r.gift_message ?? '';
  const location = r.event_city ?? r.city ?? r.event_municipio ?? r.address ?? null;

  const groupName  = r.group?.name ?? 'Grupo musical';
  const genre      = r.group?.genre ?? null;
  const photoUri   = r.group?.profile_image ?? null;
  const folio      = r.folio ?? '—';
  const code       = r.arrival_code ?? null;
  const digits     = code ? code.split('') : ['?', '?', '?', '?'];
  const date       = r.event_date ? fmtDate(r.event_date) : '—';
  const time       = r.event_time ? fmtTime(r.event_time) : '—';
  const duration   = fmtDuration(r);
  // 🇲🇽/🇺🇸 El ticket se marca solo según la moneda del evento — así el
  // admin distingue las descargas de México y de Estados Unidos.
  const isUS       = (r.currency_code ?? 'MXN') === 'USD';
  const price      = r.total_price != null
    ? (isUS
        ? `US$${Number(r.total_price).toLocaleString('en-US')} USD`
        : `$${Number(r.total_price).toLocaleString('es-MX')} MXN`)
    : null;

  // ── Descargar imagen ────────────────────────────────────────────────────────
  const handleDownload = async () => {
    setSaving(true);
    try {
      const { status } = await MediaLibrary.requestPermissionsAsync();
      if (status !== 'granted') {
        Alert.alert('Permiso requerido', 'Necesitamos acceso a tu galería para guardar el ticket.');
        setSaving(false);
        return;
      }
      const uri = await captureRef(ticketRef, { format: 'jpg', quality: 0.97 });
      await MediaLibrary.saveToLibraryAsync(uri);
      Alert.alert('✅ Guardado', 'Tu ticket se guardó en la galería.');
    } catch {
      Alert.alert('Error', 'No se pudo guardar el ticket. Intenta de nuevo.');
    } finally {
      setSaving(false);
    }
  };

  // ── Compartir ────────────────────────────────────────────────────────────────
  const handleShare = async () => {
    try {
      const uri = await captureRef(ticketRef, { format: 'jpg', quality: 0.9 });
      await Share.share({
        url:     uri,
        message: `🎵 Mi ticket Daricefy | ${groupName} | ${r.event_date ?? ''} | Folio: ${folio}`,
      });
    } catch {
      await Share.share({ message: `🎵 Ticket Daricefy\nFolio: ${folio}\n${groupName} — ${date}` });
    }
  };

  return (
    <LinearGradient colors={[OUTER_BG, '#060C18', '#080F1C', OUTER_BG]} style={{ flex: 1 }}>
      <SafeAreaView style={{ flex: 1 }} edges={['top']}>

        {/* Barra superior */}
        <View style={s.header}>
          <Pressable onPress={() => navigation.goBack()} style={s.headerBtn}>
            <ArrowLeft size={20} color={TEXT_MAIN} />
          </Pressable>
          <Text style={s.headerTitle}>Tu ticket</Text>
          <Pressable onPress={handleShare} style={s.headerBtn}>
            <Share2 size={20} color={GOLD} />
          </Pressable>
        </View>

        <ScrollView contentContainerStyle={s.scroll} showsVerticalScrollIndicator={false}>

          {/* Toggle modo regalo */}
          <View style={s.giftToggle}>
            <Gift size={16} color={giftMode ? GOLD : TEXT_MUTED} />
            <Text style={[s.giftToggleLabel, giftMode && { color: GOLD }]}>Modo regalo</Text>
            <Switch
              value={giftMode}
              onValueChange={setGiftMode}
              trackColor={{ false: '#1E2A3A', true: 'rgba(0,230,118,0.4)' }}
              thumbColor={giftMode ? GOLD_LIGHT : '#3A4A5A'}
            />
          </View>

          {/* Campos De / Para (solo en modo regalo) */}
          {giftMode && (
            <View style={s.giftFields}>
              <View style={s.giftFieldRow}>
                <Text style={s.giftFieldKey}>De</Text>
                <TextInput
                  style={s.giftFieldInput}
                  value={giftFrom}
                  onChangeText={setGiftFrom}
                  placeholder="Tu nombre"
                  placeholderTextColor={TEXT_MUTED}
                />
              </View>
              <View style={s.giftFieldRow}>
                <Text style={s.giftFieldKey}>Para</Text>
                <TextInput
                  style={s.giftFieldInput}
                  value={giftTo}
                  onChangeText={setGiftTo}
                  placeholder="Nombre del festejado"
                  placeholderTextColor={TEXT_MUTED}
                />
              </View>
            </View>
          )}

          {/* ════════ TICKET (captureable, con marco holográfico) ════════ */}
          <LinearGradient
            ref={ticketRef as any}
            colors={HOLO_FRAME as any}
            start={{ x: 0, y: 0 }} end={{ x: 1, y: 1 }}
            style={s.holoFrame}
            collapsable={false}
          >
          <LinearGradient
            colors={[T_BG, T_BG, T_BG2]}
            style={s.ticket}
            collapsable={false}
          >
            {/* Esquinas doradas */}
            <View style={[s.corner, { top: 12, left: 12, borderRightWidth: 0, borderBottomWidth: 0, borderTopLeftRadius: 4 }]} />
            <View style={[s.corner, { top: 12, right: 12, borderLeftWidth: 0, borderBottomWidth: 0, borderTopRightRadius: 4 }]} />
            <View style={[s.corner, { bottom: 12, left: 12, borderRightWidth: 0, borderTopWidth: 0, borderBottomLeftRadius: 4 }]} />
            <View style={[s.corner, { bottom: 12, right: 12, borderLeftWidth: 0, borderTopWidth: 0, borderBottomRightRadius: 4 }]} />

            {/* Cabecera */}
            <View style={s.ticketHead}>
              <Text style={s.appLogo}>DARICEFY</Text>
              <Text style={s.appSub}>
                {giftMode ? 'UN REGALO MUSICAL PARA TI' : 'TU CONTRATACIÓN MUSICAL'}
              </Text>
              <View style={s.countryChip}>
                <Text style={s.countryChipTx}>{isUS ? '🇺🇸 USA · USD' : '🇲🇽 MÉXICO · MXN'}</Text>
              </View>
              {giftMode && (giftFrom || giftTo) && (
                <View style={s.giftNames}>
                  {!!giftFrom && (
                    <Text style={s.giftNamesText}>
                      De: <Text style={{ color: T_GREEN }}>{giftFrom}</Text>
                    </Text>
                  )}
                  {!!giftTo && (
                    <Text style={s.giftNamesText}>
                      Para: <Text style={{ color: T_GREEN }}>{giftTo}</Text>
                    </Text>
                  )}
                </View>
              )}
            </View>

            {/* Línea dorada */}
            <View style={s.goldRule} />

            {/* Foto del grupo */}
            <View style={s.photoWrap}>
              {photoUri ? (
                <View style={s.photoRing}>
                  <Image source={{ uri: photoUri }} style={s.photo} />
                </View>
              ) : (
                <View style={[s.photoRing, s.photoPlaceholder]}>
                  <Text style={{ fontSize: 40 }}>🎵</Text>
                </View>
              )}
            </View>

            {/* Nombre y género */}
            <Text style={s.groupName}>{groupName}</Text>
            {!!genre && (
              <View style={s.genrePill}>
                <Text style={s.genreText}>
                  {GENRE_MAP[genre.toLowerCase()] ?? genre}
                </Text>
              </View>
            )}

            {/* Mensaje personalizado del regalo */}
            {giftMode && !!giftMsg && (
              <View style={s.giftMsgBox}>
                <Text style={s.giftMsgText}>“{giftMsg}”</Text>
              </View>
            )}

            {/* Detalles del evento */}
            <View style={s.infoCard}>
              <InfoRow icon="📅" value={date} />
              <InfoRow icon="🕐" value={time} />
              {giftMode && !!location && <InfoRow icon="📍" value={location} />}
              {!!duration && <InfoRow icon="⏱️" value={duration} />}
              {!giftMode && !!price && <InfoRow icon="💳" value={price} gold />}
            </View>

            {/* Perforación */}
            <Perforation />

            {/* Folio con efecto holo */}
            <View style={s.folioBlock}>
              <Text style={s.folioLabel}>FOLIO DE RESERVACIÓN</Text>
              <HoloText text={folio} style={s.folioValue} />
            </View>

            {/* Código de inicio */}
            <View style={s.codeSection}>
              <Text style={s.codeLabel}>CÓDIGO DE INICIO</Text>
              <View style={s.digitsRow}>
                {digits.map((d: string, i: number) => <DigitBox key={i} digit={d} index={i} />)}
              </View>
              <Text style={s.codeHint}>Muéstralo al grupo al llegar al evento</Text>
            </View>

            {/* Perforación */}
            <Perforation />

            {/* Código de barras decorativo + footer */}
            <Barcode seed={folio} />
            <View style={s.ticketFoot}>
              <Text style={s.footerMain}>Daricefy — La música está en tus manos</Text>
              <Text style={s.footerSub}>daricefy.com  ·  ✅ Reservación confirmada</Text>
            </View>
          </LinearGradient>
          </LinearGradient>
          {/* ════════ fin ticket ════════ */}

          {/* Botón descargar */}
          <Pressable
            style={[s.dlBtn, saving && { opacity: 0.7 }]}
            onPress={handleDownload}
            disabled={saving}
          >
            <LinearGradient
              colors={['#00E676', '#22D3EE', '#3B82F6']}
              start={{ x: 0, y: 0 }} end={{ x: 1, y: 0 }}
              style={s.dlGrad}
            >
              {saving
                ? <ActivityIndicator color={CARD_BG} size="small" />
                : (
                  <>
                    <Download size={18} color={CARD_BG} />
                    <Text style={s.dlText}>Descargar como imagen</Text>
                  </>
                )
              }
            </LinearGradient>
          </Pressable>

          {/* Botón compartir */}
          <Pressable style={s.shareBtn} onPress={handleShare}>
            <Share2 size={18} color={GOLD} />
            <Text style={s.shareText}>Compartir ticket</Text>
          </Pressable>

        </ScrollView>
      </SafeAreaView>
    </LinearGradient>
  );
}

// ── Estilos ───────────────────────────────────────────────────────────────────
const s = StyleSheet.create({
  // Header
  header: {
    flexDirection: 'row', alignItems: 'center',
    paddingHorizontal: 16, paddingVertical: 10,
  },
  headerBtn: {
    width: 38, height: 38, borderRadius: 10,
    backgroundColor: 'rgba(255,255,255,0.05)',
    borderWidth: 1, borderColor: 'rgba(255,255,255,0.08)',
    alignItems: 'center', justifyContent: 'center',
  },
  headerTitle: {
    flex: 1, textAlign: 'center',
    fontFamily: FONTS.bodyMedium, fontSize: 16, color: TEXT_MAIN,
  },

  scroll: { padding: 20, paddingBottom: 48 },

  // Gift toggle
  giftToggle: {
    flexDirection: 'row', alignItems: 'center', gap: 10,
    backgroundColor: 'rgba(255,255,255,0.04)',
    borderRadius: 12, borderWidth: 1, borderColor: 'rgba(255,255,255,0.07)',
    paddingHorizontal: 16, paddingVertical: 11, marginBottom: 14,
  },
  giftToggleLabel: {
    flex: 1, fontFamily: FONTS.bodyMedium, fontSize: 14, color: TEXT_MUTED2,
  },

  // Gift fields
  giftFields: { gap: 10, marginBottom: 16 },
  giftFieldRow: { flexDirection: 'row', alignItems: 'center', gap: 12 },
  giftFieldKey: {
    fontFamily: FONTS.bodySemiBold, fontSize: 14, color: GOLD, width: 44,
  },
  giftFieldInput: {
    flex: 1, fontFamily: FONTS.body, fontSize: 15, color: TEXT_MAIN,
    borderBottomWidth: 1, borderColor: GOLD_BORDER, paddingVertical: 6,
  },

  // 🌈 Marco holográfico (verde → cian → azul) — envuelve el ticket blanco
  holoFrame: {
    borderRadius: 24, padding: 7, marginBottom: 16,
    shadowColor: '#22D3EE', shadowOffset: { width: 0, height: 4 },
    shadowOpacity: 0.35, shadowRadius: 16, elevation: 10,
  },

  // Ticket card (fondo blanco)
  ticket: {
    borderRadius: 18, borderWidth: 1, borderColor: T_BORDER,
    paddingHorizontal: 20, paddingTop: 14, paddingBottom: 14, overflow: 'hidden',
  },

  // Corner accents
  corner: {
    position: 'absolute', width: 14, height: 14,
    borderColor: T_GREEN, borderWidth: 1.5,
  },

  // Ticket head
  ticketHead: { alignItems: 'center', paddingTop: 4, marginBottom: 8 },
  appLogo: {
    fontFamily: FONTS.title, fontSize: 16, color: T_TEXT,
    letterSpacing: 6, includeFontPadding: false,
  },
  appSub: {
    fontFamily: FONTS.body, fontSize: 9, color: T_MUTED,
    letterSpacing: 2.5, marginTop: 3,
  },
  countryChip: {
    marginTop: 7, paddingHorizontal: 10, paddingVertical: 3,
    borderRadius: 999, borderWidth: 1, borderColor: 'rgba(8,145,178,0.35)',
    backgroundColor: 'rgba(8,145,178,0.06)',
  },
  countryChipTx: { fontFamily: FONTS.bodySemiBold, fontSize: 9.5, color: '#0891B2', letterSpacing: 1.2 },
  giftNames: { marginTop: 8, alignItems: 'center', gap: 3 },
  giftNamesText: {
    fontFamily: FONTS.bodyMedium, fontSize: 13, color: T_MUTED2,
  },

  goldRule: {
    height: 1, backgroundColor: T_BORDER, marginBottom: 12,
  },

  // Photo
  photoWrap: { alignItems: 'center', marginBottom: 8 },
  photoRing: {
    width: 86, height: 86, borderRadius: 43,
    borderWidth: 2, borderColor: GOLD,
    overflow: 'hidden',
    shadowColor: GOLD, shadowOffset: { width: 0, height: 0 },
    shadowOpacity: 0.35, shadowRadius: 8, elevation: 5,
  },
  photo: { width: '100%', height: '100%' },
  photoPlaceholder: {
    backgroundColor: T_BG2, alignItems: 'center', justifyContent: 'center',
  },

  // Group name & genre
  groupName: {
    fontFamily: FONTS.title, fontSize: 19, color: T_TEXT,
    textAlign: 'center', letterSpacing: 0.5, marginBottom: 6,
  },
  genrePill: {
    alignSelf: 'center', marginBottom: 10,
    backgroundColor: T_GREEN2, borderWidth: 1, borderColor: 'rgba(0,166,81,0.25)',
    borderRadius: 20, paddingHorizontal: 12, paddingVertical: 3,
  },
  genreText: {
    fontFamily: FONTS.bodyMedium, fontSize: 12, color: T_GREEN,
  },

  // Mensaje del regalo
  giftMsgBox: {
    alignSelf: 'stretch', marginBottom: 10,
    backgroundColor: T_GREEN2, borderRadius: 10,
    borderWidth: 1, borderColor: 'rgba(0,166,81,0.20)',
    paddingHorizontal: 14, paddingVertical: 10,
  },
  giftMsgText: {
    fontFamily: FONTS.body, fontSize: 12.5, color: T_MUTED2,
    textAlign: 'center', lineHeight: 18, fontStyle: 'italic',
  },

  // Info card
  infoCard: {
    backgroundColor: T_BG2,
    borderRadius: 10, borderWidth: 1, borderColor: T_BORDER,
    padding: 10, gap: 7, marginBottom: 0,
  },
  infoRow:   { flexDirection: 'row', alignItems: 'center', gap: 8 },
  infoIcon:  { fontSize: 13, width: 20 },
  infoValue: {
    fontFamily: FONTS.bodyMedium, fontSize: 12, color: T_TEXT, flex: 1,
  },
  infoValueGold: {
    fontFamily: FONTS.bodySemiBold, fontSize: 12, color: T_GREEN, flex: 1,
  },

  // Folio
  folioBlock: {
    alignItems: 'center', marginBottom: 10, gap: 3,
  },
  folioLabel: {
    fontFamily: FONTS.body, fontSize: 8, color: T_MUTED,
    letterSpacing: 3, textTransform: 'uppercase',
  },
  folioValue: {
    fontFamily: FONTS.bodySemiBold, fontSize: 14, color: T_TEXT,
    letterSpacing: 2,
  },

  // Código de inicio
  codeSection: { alignItems: 'center', marginBottom: 6 },
  codeLabel: {
    fontFamily: FONTS.body, fontSize: 8, color: T_MUTED,
    letterSpacing: 4, textTransform: 'uppercase', marginBottom: 10,
  },
  digitsRow: { flexDirection: 'row', gap: 8, marginBottom: 8 },
  digitBox: {
    width: 46, height: 54, borderRadius: 8,
    backgroundColor: '#111827', borderWidth: 1, borderColor: '#1F2937',
    alignItems: 'center', justifyContent: 'center',
  },
  digitText: {
    fontFamily: FONTS.title, fontSize: 26, color: '#FFFFFF',
    includeFontPadding: false, lineHeight: 32,
  },
  codeHint: {
    fontFamily: FONTS.body, fontSize: 9, color: T_MUTED, textAlign: 'center',
  },

  // Footer del ticket
  ticketFoot:  { alignItems: 'center', gap: 3 },
  footerMain:  {
    fontFamily: FONTS.bodyMedium, fontSize: 10, color: T_MUTED2,
    textAlign: 'center', letterSpacing: 0.5,
  },
  footerSub: {
    fontFamily: FONTS.body, fontSize: 9, color: T_MUTED, textAlign: 'center',
  },

  // Botón descargar
  dlBtn:  { borderRadius: 16, overflow: 'hidden', marginBottom: 12 },
  dlGrad: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'center',
    gap: 10, paddingVertical: 16,
  },
  dlText: {
    fontFamily: FONTS.bodySemiBold, fontSize: 16, color: CARD_BG,
  },

  // Botón compartir
  shareBtn: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'center',
    gap: 10, borderWidth: 1, borderColor: GOLD_BORDER,
    borderRadius: 16, paddingVertical: 14,
    backgroundColor: GOLD_DIM,
  },
  shareText: {
    fontFamily: FONTS.bodyMedium, fontSize: 15, color: GOLD,
  },
});
