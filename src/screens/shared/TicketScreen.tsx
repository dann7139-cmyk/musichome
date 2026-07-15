/**
 * TicketScreen — Ticket premium con código de inicio y modo regalo.
 */
import React, { useEffect, useRef, useState } from 'react';
import {
  ActivityIndicator, Alert, Animated, Image, Pressable,
  ScrollView, Share, StyleSheet, Switch, Text, TextInput, View,
} from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { LinearGradient } from 'expo-linear-gradient';
import { captureRef } from 'react-native-view-shot';
import * as MediaLibrary from 'expo-media-library';
import { ArrowLeft, Calendar, Clock, CreditCard, Download, Gift, Music2, Share2 } from 'lucide-react-native';
import { FONTS } from '../../config/theme';

// ── Tokens de diseño ──────────────────────────────────────────────────────────
const OUTER_BG    = '#050A13';
const CARD_BG     = '#080F1C';   // para outer/botones
// 🌈 HOLOGRÁFICO verde/azul (pedido 2026-07-15) — reemplaza al dorado.
// El marco y los acentos van en degradado verde → cian → azul, como los
// tickets iridiscentes de imprenta.
const GOLD        = '#00B8D9';   // acento principal (cian) — mismo nombre para no tocar 40 refs
const GOLD_LIGHT  = '#00D26A';
const GOLD_DIM    = 'rgba(0,184,217,0.10)';
const GOLD_BORDER = 'rgba(0,184,217,0.30)';
// Tornasol premium (brief 2026): verde → turquesa → azul, sin exagerar
const HOLO_FRAME  = ['#00D26A', '#00D9FF', '#2563FF'] as const;
const HOLO_STOPS  = ['#00A651', '#00B8A9', '#0891B2', '#2563EB'];   // texto holo (legible en blanco)
// ✨ FOIL PLATEADO (hot stamping holográfico): plata con destellos
// pastel de todos los colores — vista previa de cómo lo dejará la imprenta
const FOIL_FRAME  = ['#C3CBD6', '#E9D9EF', '#D3E9DD', '#F2F5F9', '#D8E5F6', '#AEB9C8'] as const;
const FOIL_STOPS  = ['#8A94A6', '#9B8FB0', '#7FA391', '#7E93B8'];   // texto foil (legible en blanco)
const FOIL_BRIGHT = ['#E6EBF2', '#EFD9F5', '#D6F0E0', '#DCE9FB'];   // dígitos sobre oscuro
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
    <View style={{ flexDirection: 'row', alignItems: 'center', marginVertical: 10 }}>
      <DashedLine />
    </View>
  );
}

// ✂️ Silueta de boleto REAL — recorta el marco holográfico completo:
// muesca grande arriba y abajo al centro + mordidas de estampilla en los
// lados izquierdo y derecho (el overflow:hidden del marco las convierte
// en medios círculos que dejan ver el fondo oscuro).
function TicketCutout() {
  const dots = Array.from({ length: 22 }, (_, i) => <View key={i} style={s.cutDot} />);
  return (
    <>
      <View pointerEvents="none" style={s.cutNotchTop} />
      <View pointerEvents="none" style={s.cutNotchBottom} />
      <View pointerEvents="none" style={[s.cutSide, { left: -7 }]}>{dots}</View>
      <View pointerEvents="none" style={[s.cutSide, { right: -7 }]}>{dots}</View>
    </>
  );
}

// 🌈 Texto "holográfico": cada carácter interpola verde → cian → azul.
// (Sin masked-view: el degradado por carácter da el efecto iridiscente
// y sobrevive perfecto a la captura de imagen y a la imprenta.)
function HoloText({ text, style, stops = HOLO_STOPS }: { text: string; style?: any; stops?: string[] }) {
  const chars = String(text).split('');
  const n = Math.max(1, chars.length - 1);
  return (
    <View style={{ flexDirection: 'row', justifyContent: 'center' }}>
      {chars.map((c, i) => (
        <Text
          key={i}
          style={[style, { color: stops[Math.min(stops.length - 1, Math.round((i / n) * (stops.length - 1)))] }]}
        >
          {c}
        </Text>
      ))}
    </View>
  );
}

// Sobre fondo oscuro los tonos van BRILLANTES (verde → cian → azul)
const HOLO_BRIGHT = ['#00E676', '#00D9FF', '#22A7FF', '#5B8CFF'];

function DigitBox({ digit, index, bright = HOLO_BRIGHT }: { digit: string; index?: number; bright?: string[] }) {
  const holo = bright[Math.min(bright.length - 1, (index ?? 0))];
  return (
    <View style={[s.digitBox, { borderColor: `${holo}55` }]}>
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
  // Caja de regalo: si la reserva ES regalo (el cliente lo marcó al comprar),
  // el ticket sale ARMADO — De/Para/mensaje reales, sin nada que editar
  // (el admin solo lo descarga). El toggle manual queda solo para
  // reservas normales que el cliente quiera regalar después.
  const isRealGift = !!r.is_gift;
  const [giftMode, setGiftMode] = useState(isRealGift);
  const [giftFrom, setGiftFrom] = useState(senderName ?? r.client?.full_name ?? '');
  const [giftTo,   setGiftTo]   = useState(r.gift_recipient_name ?? '');
  const [saving,   setSaving]   = useState(false);

  const giftMsg  = r.gift_message ?? '';
  const location = r.event_city ?? r.city ?? r.event_municipio ?? r.address ?? null;

  // ✨ Vista previa del acabado: 🌈 color (digital) o foil plateado
  // (cómo lo dejará la imprenta con hot stamping holográfico)
  const [foilView, setFoilView] = useState(false);
  const frameColors = foilView ? FOIL_FRAME : HOLO_FRAME;
  const textStops   = foilView ? FOIL_STOPS : HOLO_STOPS;
  const digitStops  = foilView ? FOIL_BRIGHT : HOLO_BRIGHT;
  const cornerColor = foilView ? '#AEB9C8' : '#00D26A';

  // ✨ Entrada premium: fade in + slide up 350 ms (brief 2026)
  const appear = useRef(new Animated.Value(0)).current;
  useEffect(() => {
    Animated.timing(appear, { toValue: 1, duration: 350, useNativeDriver: true }).start();
  }, [appear]);

  const groupName  = r.group?.name ?? 'Grupo musical';
  const genre      = r.group?.genre ?? null;
  const photoUri   = r.group?.profile_image ?? null;
  const folio      = r.folio ?? '—';
  const code       = r.arrival_code ?? null;
  const digits     = code ? code.split('') : ['?', '?', '?', '?'];
  const date       = r.event_date ? fmtDate(r.event_date) : '—';
  // Fecha compacta para el grid del boleto: "Sáb 27 jul 2026"
  const dateShort  = r.event_date
    ? (() => {
        const sd = new Date(r.event_date + 'T12:00:00')
          .toLocaleDateString('es-MX', { weekday: 'short', day: 'numeric', month: 'short', year: 'numeric' });
        return sd.charAt(0).toUpperCase() + sd.slice(1);
      })()
    : '—';
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
      // PNG en alta resolución (~1170px de ancho ≈ 300 dpi en tamaño boleto)
      // — calidad de imprenta para el foil holográfico
      const uri = await captureRef(ticketRef, { format: 'png', quality: 1, width: 1170 } as any);
      await MediaLibrary.saveToLibraryAsync(uri);
      Alert.alert('✅ Guardado', 'Tu ticket se guardó en la galería en alta calidad (PNG, listo para imprenta).');
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
          <Animated.View
            style={{
              opacity: appear,
              transform: [{ translateY: appear.interpolate({ inputRange: [0, 1], outputRange: [24, 0] }) }],
            }}
          >

          {/* Toggle modo regalo — solo para reservas que NO son regalo de
              origen (las de regalo ya vienen armadas del cliente) */}
          {!isRealGift && (
          <>
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

          {/* Campos De / Para (solo en modo regalo manual) */}
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
          </>
          )}

          {/* ✨ Vista del acabado: color digital o foil plateado de imprenta */}
          <View style={s.finishToggle}>
            <Pressable
              style={[s.finishBtn, !foilView && s.finishBtnOn]}
              onPress={() => setFoilView(false)}
            >
              <Text style={[s.finishBtnTx, !foilView && s.finishBtnTxOn]}>🌈 Color</Text>
            </Pressable>
            <Pressable
              style={[s.finishBtn, foilView && s.finishBtnOn]}
              onPress={() => setFoilView(true)}
            >
              <Text style={[s.finishBtnTx, foilView && s.finishBtnTxOn]}>✨ Foil plateado</Text>
            </Pressable>
          </View>
          {foilView && (
            <Text style={s.finishHint}>
              Así se verá con hot stamping holográfico: plata que brilla de todos los colores según la luz.
            </Text>
          )}

          {/* ════════ TICKET (captureable, con marco holográfico) ════════ */}
          <LinearGradient
            ref={ticketRef as any}
            colors={frameColors as any}
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
            <View style={[s.corner, { borderColor: cornerColor, top: 12, left: 12, borderRightWidth: 0, borderBottomWidth: 0, borderTopLeftRadius: 4 }]} />
            <View style={[s.corner, { borderColor: cornerColor, top: 12, right: 12, borderLeftWidth: 0, borderBottomWidth: 0, borderTopRightRadius: 4 }]} />
            <View style={[s.corner, { borderColor: cornerColor, bottom: 12, left: 12, borderRightWidth: 0, borderTopWidth: 0, borderBottomLeftRadius: 4 }]} />
            <View style={[s.corner, { borderColor: cornerColor, bottom: 12, right: 12, borderLeftWidth: 0, borderTopWidth: 0, borderBottomRightRadius: 4 }]} />

            {/* Cabecera */}
            <View style={s.ticketHead}>
              <Text style={s.appLogo}>DARICEFY</Text>
              <Text style={s.appSub}>
                {giftMode ? 'UN REGALO MUSICAL PARA TI' : 'TU CONTRATACIÓN MUSICAL'}
              </Text>
              {/* País discreto — no roba espacio */}
              <Text style={s.countryMini}>{isUS ? '🇺🇸 USD' : '🇲🇽 MXN'}</Text>
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

            {/* Foto del grupo — aro con degradado verde-azul */}
            <View style={s.photoWrap}>
              <LinearGradient
                colors={frameColors as any}
                start={{ x: 0, y: 0 }} end={{ x: 1, y: 1 }}
                style={s.photoGradRing}
              >
                <View style={s.photoInner}>
                  {photoUri ? (
                    <Image source={{ uri: photoUri }} style={s.photo} />
                  ) : (
                    <View style={s.photoPlaceholder}>
                      <Text style={{ fontSize: 40 }}>🎵</Text>
                    </View>
                  )}
                </View>
              </LinearGradient>
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

            {/* (El mensaje personalizado del regalo NO va impreso en el ticket
                — va mejor en la tarjeta física de la caja. Pedido 2026-07-15.) */}

            {/* Detalles del evento — grid tipo boleto (sin lugar: el cliente
                ya sabe dónde es). FECHA | HORA arriba, TOCADA | TOTAL abajo. */}
            <Pressable style={({ pressed }) => [s.infoGrid, pressed && s.cardPressed]}>
              <View style={s.infoCell}>
                <View style={s.infoLabelRow}>
                  <Calendar size={11} color="#2563FF" strokeWidth={2.2} />
                  <Text style={s.infoLabel}>FECHA</Text>
                </View>
                <Text style={s.infoBig}>{dateShort}</Text>
              </View>
              <View style={s.infoDivV} />
              <View style={s.infoCell}>
                <View style={s.infoLabelRow}>
                  <Clock size={11} color="#00A651" strokeWidth={2.2} />
                  <Text style={s.infoLabel}>HORA DE INICIO</Text>
                </View>
                <Text style={s.infoBig}>{time}</Text>
              </View>
            </Pressable>
            {(!!duration || (!giftMode && !!price)) && (
              <Pressable style={({ pressed }) => [s.infoGrid, { marginTop: 10 }, pressed && s.cardPressed]}>
                {!!duration && (
                  <View style={s.infoCell}>
                    <View style={s.infoLabelRow}>
                      <Music2 size={11} color="#00A651" strokeWidth={2.2} />
                      <Text style={s.infoLabel}>HORAS DE TOCADA</Text>
                    </View>
                    <Text style={s.infoBig}>{duration}</Text>
                  </View>
                )}
                {!giftMode && !!price && (
                  <>
                    <View style={s.infoDivV} />
                    <View style={s.infoCell}>
                      <View style={s.infoLabelRow}>
                        <CreditCard size={11} color="#2563FF" strokeWidth={2.2} />
                        <Text style={s.infoLabel}>TOTAL</Text>
                      </View>
                      <HoloText text={price} style={s.infoBigHolo} stops={textStops} />
                    </View>
                  </>
                )}
              </Pressable>
            )}

            {/* Perforación */}
            <Perforation />

            {/* Folio con efecto holo */}
            <View style={s.folioBlock}>
              <Text style={s.folioLabel}>FOLIO DE RESERVACIÓN</Text>
              <HoloText text={folio} style={s.folioValue} stops={textStops} />
            </View>

            {/* Código de inicio */}
            <View style={s.codeSection}>
              <Text style={s.codeLabel}>CÓDIGO DE INICIO</Text>
              <View style={s.digitsRow}>
                {digits.map((d: string, i: number) => <DigitBox key={i} digit={d} index={i} bright={digitStops} />)}
              </View>
              <Text style={s.codeHint}>Muéstralo al grupo al llegar al evento</Text>
            </View>

            {/* Perforación */}
            <Perforation />

            <View style={s.ticketFoot}>
              <Text style={s.footerMain}>Daricefy — La música está en tus manos</Text>
              <Text style={s.footerSub}>daricefy.com  ·  ✅ Reservación confirmada</Text>
            </View>
          </LinearGradient>
          {/* ✂️ Recorte de la silueta (muescas + mordidas sobre el marco) */}
          <TicketCutout />
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

          </Animated.View>
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

  // 🌈 Marco holográfico (verde → cian → azul) — envuelve el ticket blanco.
  // Angosto y centrado, proporción de boleto real (no cuadrado).
  holoFrame: {
    borderRadius: 24, padding: 9, marginBottom: 16,
    alignSelf: 'center', width: '94%', maxWidth: 360,
    overflow: 'hidden',   // ✂️ recorta muescas y mordidas sobre el marco
    shadowColor: '#22D3EE', shadowOffset: { width: 0, height: 4 },
    shadowOpacity: 0.35, shadowRadius: 16, elevation: 10,
  },

  // Ticket card (fondo blanco)
  ticket: {
    borderRadius: 14, borderWidth: 1, borderColor: T_BORDER,
    paddingHorizontal: 16, paddingTop: 14, paddingBottom: 12, overflow: 'hidden',
  },

  // ✂️ Silueta de boleto sobre el MARCO holográfico completo
  cutNotchTop: {
    position: 'absolute', top: -18, left: '50%', marginLeft: -19,
    width: 38, height: 38, borderRadius: 19, backgroundColor: OUTER_BG, zIndex: 6,
  },
  cutNotchBottom: {
    position: 'absolute', bottom: -18, left: '50%', marginLeft: -19,
    width: 38, height: 38, borderRadius: 19, backgroundColor: OUTER_BG, zIndex: 6,
  },
  cutSide: {
    position: 'absolute', top: 10, bottom: 10, width: 14,
    justifyContent: 'space-between', alignItems: 'center', zIndex: 6,
  },
  cutDot: { width: 12, height: 12, borderRadius: 6, backgroundColor: OUTER_BG },

  // ✨ Toggle de acabado (color / foil plateado)
  finishToggle: {
    flexDirection: 'row', alignSelf: 'center', gap: 6, marginBottom: 10,
    backgroundColor: 'rgba(255,255,255,0.05)', borderRadius: 999, padding: 4,
    borderWidth: 1, borderColor: 'rgba(255,255,255,0.08)',
  },
  finishBtn:    { paddingHorizontal: 14, paddingVertical: 6, borderRadius: 999 },
  finishBtnOn:  { backgroundColor: 'rgba(255,255,255,0.12)' },
  finishBtnTx:  { fontFamily: FONTS.bodyMedium, fontSize: 12, color: TEXT_MUTED2 },
  finishBtnTxOn:{ color: TEXT_MAIN },
  finishHint: {
    fontFamily: FONTS.body, fontSize: 10.5, color: TEXT_MUTED2,
    textAlign: 'center', marginBottom: 10, paddingHorizontal: 20, lineHeight: 15,
  },

  // Esquinas minimalistas tipo escáner — muy delgadas, verdes
  corner: {
    position: 'absolute', width: 18, height: 18,
    borderColor: '#00D26A', borderWidth: 1.2,
  },

  // Ticket head — jerarquía premium
  ticketHead: { alignItems: 'center', paddingTop: 2, marginBottom: 8 },
  appLogo: {
    fontFamily: FONTS.title, fontSize: 19, color: T_TEXT,
    letterSpacing: 5, includeFontPadding: false,
  },
  appSub: {
    fontFamily: FONTS.bodyMedium, fontSize: 10.5, color: T_MUTED,
    letterSpacing: 2.5, marginTop: 4,
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

  // Photo — aro degradado verde-azul con sombra ligera
  photoWrap: { alignItems: 'center', marginBottom: 8 },
  photoGradRing: {
    width: 84, height: 84, borderRadius: 42, padding: 3,
    shadowColor: '#00D9FF', shadowOffset: { width: 0, height: 3 },
    shadowOpacity: 0.30, shadowRadius: 10, elevation: 6,
  },
  photoInner: {
    flex: 1, borderRadius: 39, overflow: 'hidden',
    borderWidth: 2.5, borderColor: T_BG, backgroundColor: T_BG2,
  },
  photo: { width: '100%', height: '100%' },
  photoPlaceholder: {
    flex: 1, backgroundColor: T_BG2, alignItems: 'center', justifyContent: 'center',
  },

  // Group name & genre — protagonista
  groupName: {
    fontFamily: FONTS.title, fontSize: 19.5, color: T_TEXT,
    textAlign: 'center', letterSpacing: 0.5, marginBottom: 5,
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

  // Info card (legacy — InfoRow aún lo usa en otros puntos)
  infoRow:   { flexDirection: 'row', alignItems: 'center', gap: 8 },
  infoIcon:  { fontSize: 13, width: 20 },
  infoValue: {
    fontFamily: FONTS.bodyMedium, fontSize: 12, color: T_TEXT, flex: 1,
  },
  infoValueGold: {
    fontFamily: FONTS.bodySemiBold, fontSize: 12, color: T_GREEN, flex: 1,
  },

  // 🎫 Tarjetas premium de detalles: FECHA | HORA · TOCADA | TOTAL
  infoGrid: {
    flexDirection: 'row', alignItems: 'stretch',
    backgroundColor: T_BG,
    borderRadius: 16, borderWidth: 1, borderColor: '#EEF2F7',
    paddingVertical: 10, paddingHorizontal: 6,
    shadowColor: '#1E3A8A', shadowOffset: { width: 0, height: 2 },
    shadowOpacity: 0.06, shadowRadius: 8, elevation: 2,
  },
  cardPressed: { transform: [{ scale: 0.98 }] },
  infoCell:  { flex: 1, alignItems: 'center', justifyContent: 'center', gap: 5 },
  infoDivV:  { width: 1, borderLeftWidth: 1, borderColor: T_BORDER, borderStyle: 'dashed', marginVertical: 2 },
  infoLabelRow: { flexDirection: 'row', alignItems: 'center', gap: 4 },
  infoLabel: {
    fontFamily: FONTS.bodySemiBold, fontSize: 8.5, color: T_MUTED,
    letterSpacing: 1.4,
  },
  infoBig: {
    fontFamily: FONTS.bodySemiBold, fontSize: 13.5, color: T_TEXT, textAlign: 'center',
  },
  infoBigHolo: {
    fontFamily: FONTS.bodySemiBold, fontSize: 13.5, textAlign: 'center',
  },
  countryMini: {
    fontFamily: FONTS.bodySemiBold, fontSize: 8.5, color: T_MUTED,
    letterSpacing: 1.5, marginTop: 5,
  },

  // Folio
  folioBlock: {
    alignItems: 'center', marginBottom: 6, gap: 2,
  },
  folioLabel: {
    fontFamily: FONTS.body, fontSize: 8, color: T_MUTED,
    letterSpacing: 3, textTransform: 'uppercase',
  },
  folioValue: {
    fontFamily: FONTS.bodySemiBold, fontSize: 14,
    letterSpacing: 2.5,
  },

  // Código de inicio
  codeSection: { alignItems: 'center', marginBottom: 6 },
  codeLabel: {
    fontFamily: FONTS.body, fontSize: 8, color: T_MUTED,
    letterSpacing: 4, textTransform: 'uppercase', marginBottom: 7,
  },
  digitsRow: { flexDirection: 'row', gap: 10, marginBottom: 6 },
  // Teclas premium del PIN: cuadros oscuros, dígito degradado con brillo
  digitBox: {
    width: 48, height: 48, borderRadius: 12,
    backgroundColor: '#111827', borderWidth: 1,
    alignItems: 'center', justifyContent: 'center',
    shadowColor: '#00D9FF', shadowOffset: { width: 0, height: 2 },
    shadowOpacity: 0.25, shadowRadius: 6, elevation: 4,
  },
  digitText: {
    fontFamily: FONTS.title, fontSize: 23,
    includeFontPadding: false, lineHeight: 33,
    textShadowColor: 'rgba(0,217,255,0.45)',
    textShadowOffset: { width: 0, height: 0 }, textShadowRadius: 7,
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
