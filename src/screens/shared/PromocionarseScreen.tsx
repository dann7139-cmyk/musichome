// ═══════════════════════════════════════════════════════════════════
// PromocionarseScreen — Catálogo visual de promociones
//
// Grupos  → Bidding, Recomendado, Destacado, Banner Home, Perfil
// Clientes → Banner Home, Perfil
// ═══════════════════════════════════════════════════════════════════

import { LinearGradient } from 'expo-linear-gradient';
import {
  ArrowRight,
  Megaphone,
  Rocket,
  Star,
  TrendingUp,
  User,
  Zap,
} from 'lucide-react-native';
import React from 'react';
import {
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { useAuth } from '../../context/AuthContext';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';

// ── Definición de cada tipo de promoción ─────────────────────────────────────

type PromoCard = {
  key:         string;
  label:       string;
  icon:        React.ReactNode;
  gradient:    [string, string];
  accent:      string;
  description: string;
  price:       string;
  badge?:      string;
  screen:      string;         // nombre de la ruta a navegar
  screenParams?: Record<string, any>;
  roles:       ('group' | 'client' | 'talent')[];
};

const PROMO_CARDS: PromoCard[] = [
  {
    key:         'bidding',
    label:       'Bidding',
    icon:        <TrendingUp size={28} color="#A78BFA" />,
    gradient:    ['#1A1035', '#2D1B69'],
    accent:      '#A78BFA',
    description: 'Sube en el ranking de tu ciudad pagando más que la competencia. El más alto gana la primera posición.',
    price:       'Precio libre · tú decides',
    badge:       '🔥 Más competitivo',
    screen:      'Bidding',
    roles:       ['group'],
  },
  {
    key:         'recommendation',
    label:       'Recomendado',
    icon:        <Zap size={28} color="#FF6D00" />,
    gradient:    ['#1F1008', '#3D1F00'],
    accent:      '#FF6D00',
    description: 'Aparece como grupo recomendado en los resultados de búsqueda de tu ciudad durante el tiempo que elijas.',
    price:       'Desde $199 · 3 días',
    badge:       '⚡ Alta conversión',
    screen:      'Recommendation',
    roles:       ['group'],
  },
  {
    key:         'sponsored',
    label:       'Destacado',
    icon:        <Star size={28} color="#C9A84C" />,
    gradient:    ['#1A1500', '#2E2200'],
    accent:      '#C9A84C',
    description: 'Tu grupo aparece en la sección "Destacados" del inicio — la columna dorada, primera a la vista. Visibilidad máxima en tu zona.',
    price:       '$349 · mensual',
    badge:       '⭐ Premium',
    screen:      'Destacado',
    roles:       ['group'],
  },
  {
    key:         'banner_home',
    label:       'Banner Home',
    icon:        <Megaphone size={28} color="#00E676" />,
    gradient:    ['#001A0D', '#003319'],
    accent:      '#00E676',
    description: 'Un banner de imagen o video que aparece en Explorador Y en Inicio — lo ven TODOS los usuarios de la app.',
    price:       'Desde $229 · 3 días',
    badge:       '📢 Mayor alcance',
    screen:      'AdvertisingPackages',
    screenParams: { initialType: 'banner_home' },
    // Petición real (2026-09-04): "mejor que el cliente no pague
    // anuncios porque van a querer poner números y brincarme" — cliente
    // quitado, reforzado también en el servidor (sql/608).
    roles:       ['group', 'talent'],
  },
  {
    key:         'profile_ad',
    label:       'Anuncio en Perfil',
    icon:        <User size={28} color="#4285F4" />,
    gradient:    ['#050D1F', '#0A1A3D'],
    accent:      '#4285F4',
    description: 'Tu anuncio aparece en la parte inferior del perfil de proveedores de OTRA categoría (nunca en la tuya, cero competencia directa). Impacta a usuarios que ya están listos para contratar.',
    price:       'Desde $129 · 3 días',
    screen:      'AdvertisingPackages',
    screenParams: { initialType: 'profile_ad' },
    roles:       ['group', 'talent'],
  },
];

// ── Miniaturas "así se ve en la app" ─────────────────────────────────────────
// Petición real (2026-09-19): "quiero que dentro de cómo funciona tenga
// pantallas de la app realmente que se parezcan, para que entiendan [dónde
// va a aparecer su anuncio]". Cada miniatura es una versión chica y fiel del
// lugar real donde ese anuncio se muestra (mismo layout que HomeScreen.tsx/
// GroupDetailScreen.tsx), no un dibujo genérico.

function MiniDeckPreview({ highlight }: { highlight: 'reco' | 'dest' }) {
  const cols: { key: 'reco' | 'dest' | 'pop'; label: string; color: string }[] = [
    { key: 'reco', label: 'Recomendados', color: COLORS.green },
    { key: 'dest', label: 'Destacados',   color: '#E6C25A' },
    { key: 'pop',  label: 'Populares',    color: '#fff' },
  ];
  return (
    <View style={pv.deckRow}>
      {cols.map(c => {
        const isHi = c.key === highlight;
        return (
          <View key={c.key} style={pv.deckCol}>
            <Text style={[pv.deckColLabel, { color: c.color, opacity: isHi ? 1 : 0.4 }]} numberOfLines={1}>
              {c.label}
            </Text>
            <View style={[pv.deckCard, isHi ? { borderColor: c.color, borderWidth: 1.5 } : { opacity: 0.4 }]}>
              {isHi && <Text style={pv.deckCardTag}>Tú</Text>}
            </View>
          </View>
        );
      })}
    </View>
  );
}

function MiniBannerPreview() {
  return (
    <View style={pv.bannerBox}>
      <View style={pv.bannerScrim} />
      <View style={pv.bannerTag}><Text style={pv.bannerTagTx}>ANUNCIO</Text></View>
      <View style={pv.bannerBottomRow}>
        <Text style={pv.bannerTitle} numberOfLines={1}>Tu anuncio aquí</Text>
        <View style={pv.bannerBtn}><Text style={pv.bannerBtnTx}>Ver más →</Text></View>
      </View>
    </View>
  );
}

function MiniProfileAdPreview() {
  return (
    <View style={pv.profWrap}>
      <View style={pv.profRow}>
        <View style={pv.profAvatar} />
        <View style={{ flex: 1, gap: 4 }}>
          <View style={pv.profLine} />
          <View style={[pv.profLine, { width: '55%' }]} />
        </View>
      </View>
      <View style={pv.profAdCard}>
        <View style={pv.profAdImg}>
          <View style={pv.profAdTag}><Text style={pv.profAdTagTx}>Anuncio</Text></View>
        </View>
        <Text style={pv.profAdCaption} numberOfLines={1}>Tu anuncio aquí ↑</Text>
      </View>
    </View>
  );
}

function MiniRankPreview() {
  return (
    <View style={pv.rankWrap}>
      {[1, 2, 3].map(n => (
        <View key={n} style={[pv.rankRow, n === 1 && pv.rankRowHi]}>
          <Text style={[pv.rankNum, n === 1 && { color: '#A78BFA' }]}>{n}</Text>
          <View style={[pv.rankBar, n === 1 && { backgroundColor: 'rgba(167,139,250,0.35)' }]} />
          {n === 1 && <Text style={pv.rankFlame}>🔥 Tú</Text>}
        </View>
      ))}
    </View>
  );
}

function PromoPreview({ cardKey }: { cardKey: string }) {
  switch (cardKey) {
    case 'bidding':        return <MiniRankPreview />;
    case 'recommendation': return <MiniDeckPreview highlight="reco" />;
    case 'sponsored':      return <MiniDeckPreview highlight="dest" />;
    case 'banner_home':    return <MiniBannerPreview />;
    case 'profile_ad':     return <MiniProfileAdPreview />;
    default:               return null;
  }
}

// ── Componente principal ──────────────────────────────────────────────────────

export default function PromocionarseScreen({ navigation }: any) {
  const { role } = useAuth();

  // Petición real (2026-09-03, corregida sql/607): CUALQUIERA puede
  // comprar "Anuncio de perfil" — la restricción ya no es de quién
  // compra, es de DÓNDE se muestra (get_profile_ads solo lo enseña en
  // perfiles de categoría distinta a la del anunciante, así un músico
  // nunca sale en el perfil de otro músico, pero sí en el de Comida/
  // Payasos/Renta/Fotógrafos, y viceversa). Nada que filtrar aquí.
  const visibleCards = PROMO_CARDS.filter(c =>
    c.roles.includes((role ?? 'client') as any)
  );

  const isGroup  = role === 'group';
  const subtitle = isGroup
    ? 'Elige cómo quieres que te encuentren más clientes'
    : 'Llega a más personas con tu anuncio';

  return (
    <SafeAreaView edges={['top']} style={s.container}>
      {/* Header — petición real (2026-09-03): el tab de abajo ya dice
          "Publicidad"/"Promocionarse", repetirlo arriba era redundante.
          Se deja el subtítulo porque sí aporta algo (explica qué hace la
          pantalla, no solo repite dónde estás). */}
      <View style={s.header}>
        <View>
          <Text style={s.subtitle}>{isGroup ? '🚀' : '📢'} {subtitle}</Text>
        </View>
      </View>

      <ScrollView
        contentContainerStyle={s.scroll}
        showsVerticalScrollIndicator={false}
      >
        {/* 📊 Mi publicidad — estado, vigencia y gasto de lo comprado */}
        <Pressable
          style={({ pressed }) => [s.myAdsBtn, pressed && { opacity: 0.85 }]}
          onPress={() => navigation.navigate('MyAds')}
        >
          <Text style={s.myAdsBtnTx}>📊 Mi publicidad</Text>
          <Text style={s.myAdsBtnSub}>Qué tienes activo, cuándo vence y cuánto has invertido →</Text>
        </Pressable>

        {visibleCards.map(card => (
          <Pressable
            key={card.key}
            style={({ pressed }) => [s.card, pressed && { opacity: 0.88 }]}
            onPress={() => navigation.navigate(card.screen, card.screenParams ?? {})}
          >
            <LinearGradient
              colors={card.gradient}
              start={{ x: 0, y: 0 }}
              end={{ x: 1, y: 1 }}
              style={s.cardGradient}
            >
              {/* Accent glow top-right */}
              <View style={[s.glowDot, { backgroundColor: card.accent + '30' }]} />

              {/* Badge */}
              {card.badge && (
                <View style={[s.badge, { borderColor: card.accent + '55', backgroundColor: card.accent + '18' }]}>
                  <Text style={[s.badgeText, { color: card.accent }]}>{card.badge}</Text>
                </View>
              )}

              {/* Icon + Title */}
              <View style={s.cardTopRow}>
                <View style={[s.iconWrap, { backgroundColor: card.accent + '18', borderColor: card.accent + '44' }]}>
                  {card.icon}
                </View>
                <View style={s.cardTitleWrap}>
                  <Text style={s.cardLabel}>{card.label}</Text>
                  <Text style={[s.cardPrice, { color: card.accent }]}>{card.price}</Text>
                </View>
                <View style={[s.arrowWrap, { backgroundColor: card.accent + '22' }]}>
                  <ArrowRight size={18} color={card.accent} />
                </View>
              </View>

              {/* Description */}
              <Text style={s.cardDesc}>{card.description}</Text>

              {/* Así se ve en la app — miniatura real del lugar exacto */}
              <Text style={s.previewLabel}>ASÍ SE VE EN LA APP</Text>
              <PromoPreview cardKey={card.key} />

              {/* Bottom accent line */}
              <View style={[s.accentLine, { backgroundColor: card.accent, marginTop: 14 }]} />
            </LinearGradient>
          </Pressable>
        ))}

        {/* Nota de ayuda */}
        <View style={s.helpNote}>
          <Text style={s.helpNoteText}>
            💡 Todos los anuncios son revisados antes de publicarse.{'\n'}
            El pago se procesa de forma segura vía Stripe.
          </Text>
        </View>

        {/* Políticas — una sola para todos los productos */}
        <Pressable
          style={s.policyLink}
          hitSlop={8}
          onPress={() => navigation.navigate('PromotionPolicy', { role: isGroup ? 'group' : 'client' })}
        >
          <Text style={s.policyLinkText}>📋 Políticas de publicidad</Text>
        </Pressable>
      </ScrollView>
    </SafeAreaView>
  );
}

// ── Estilos ───────────────────────────────────────────────────────────────────

const s = StyleSheet.create({
  container: { flex: 1, backgroundColor: COLORS.bg },

  header: {
    paddingHorizontal: SPACING.xl,
    paddingTop: 12,
    paddingBottom: 16,
    borderBottomWidth: 1,
    borderBottomColor: COLORS.border,
  },
  title:    { fontFamily: FONTS.title, fontSize: 24, color: COLORS.text },
  subtitle: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2, marginTop: 4 },

  scroll: {
    padding: SPACING.xl,
    paddingBottom: 40,
    gap: 14,
  },

  // 📊 Mi publicidad
  myAdsBtn: {
    backgroundColor: COLORS.card,
    borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.35)',
    padding: SPACING.md, gap: 3,
  },
  myAdsBtnTx:  { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.green },
  myAdsBtnSub: { fontFamily: FONTS.body, fontSize: 11.5, color: COLORS.muted2 },

  // ── Cards ──────────────────────────────────────────────────────────────────
  card: {
    borderRadius: RADIUS.xl,
    overflow: 'hidden',
    borderWidth: 1,
    borderColor: 'rgba(255,255,255,0.06)',
  },
  cardGradient: {
    padding: 20,
    position: 'relative',
    overflow: 'hidden',
  },
  glowDot: {
    position: 'absolute',
    top: -40,
    right: -40,
    width: 160,
    height: 160,
    borderRadius: 80,
  },
  badge: {
    alignSelf: 'flex-start',
    borderRadius: RADIUS.full,
    borderWidth: 1,
    paddingHorizontal: 10,
    paddingVertical: 4,
    marginBottom: 14,
  },
  badgeText: { fontFamily: FONTS.bodySemiBold, fontSize: 11 },

  cardTopRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 14,
    marginBottom: 14,
  },
  iconWrap: {
    width: 56,
    height: 56,
    borderRadius: RADIUS.lg,
    alignItems: 'center',
    justifyContent: 'center',
    borderWidth: 1,
    flexShrink: 0,
  },
  cardTitleWrap: { flex: 1 },
  cardLabel:     { fontFamily: FONTS.title, fontSize: 19, color: COLORS.text },
  cardPrice:     { fontFamily: FONTS.bodyMedium, fontSize: 12, marginTop: 3 },
  arrowWrap: {
    width: 36,
    height: 36,
    borderRadius: 18,
    alignItems: 'center',
    justifyContent: 'center',
    flexShrink: 0,
  },

  cardDesc: {
    fontFamily: FONTS.body,
    fontSize: 13,
    color: 'rgba(255,255,255,0.65)',
    lineHeight: 20,
    marginBottom: 16,
  },

  previewLabel: {
    fontFamily: FONTS.bodySemiBold,
    fontSize: 9,
    color: 'rgba(255,255,255,0.35)',
    letterSpacing: 0.8,
    marginBottom: 8,
  },

  accentLine: {
    height: 2,
    width: 40,
    borderRadius: 1,
    opacity: 0.7,
  },

  // ── Help note ──────────────────────────────────────────────────────────────
  helpNote: {
    backgroundColor: COLORS.card,
    borderRadius: RADIUS.lg,
    padding: 14,
    borderWidth: 1,
    borderColor: COLORS.border,
    marginTop: 4,
  },
  helpNoteText: {
    fontFamily: FONTS.body,
    fontSize: 12,
    color: COLORS.muted2,
    lineHeight: 18,
    textAlign: 'center',
  },
  policyLink:     { alignSelf: 'center', marginTop: 4, marginBottom: 10, paddingVertical: 6, paddingHorizontal: 14 },
  policyLinkText: { fontFamily: FONTS.body, fontSize: 11.5, color: COLORS.muted, textDecorationLine: 'underline' },
});

// ── Estilos de las miniaturas "así se ve en la app" ─────────────────────────
const pv = StyleSheet.create({
  // Deck (Recomendado/Destacado) — mismo renglón de 3 columnas que HomeScreen
  deckRow: { flexDirection: 'row', gap: 6 },
  deckCol: { flex: 1, alignItems: 'center', gap: 4 },
  deckColLabel: { fontFamily: FONTS.bodySemiBold, fontSize: 8, textAlign: 'center' },
  deckCard: {
    width: '100%', aspectRatio: 1 / 1.15, borderRadius: 8,
    backgroundColor: 'rgba(255,255,255,0.06)', borderWidth: 1, borderColor: 'rgba(255,255,255,0.1)',
    alignItems: 'center', justifyContent: 'center',
  },
  deckCardTag: { fontFamily: FONTS.bodySemiBold, fontSize: 10, color: '#fff' },

  // Banner — imagen + gradiente + chip + título/botón
  bannerBox: {
    height: 62, borderRadius: 10, overflow: 'hidden', position: 'relative',
    backgroundColor: 'rgba(0,230,118,0.10)', borderWidth: 1, borderColor: 'rgba(0,230,118,0.3)',
  },
  bannerScrim: {
    position: 'absolute', left: 0, right: 0, bottom: 0, height: '70%',
    backgroundColor: 'rgba(0,0,0,0.55)',
  },
  bannerTag: {
    position: 'absolute', top: 5, left: 5, backgroundColor: 'rgba(0,0,0,0.5)',
    borderRadius: 999, paddingHorizontal: 5, paddingVertical: 1.5,
  },
  bannerTagTx: { fontFamily: FONTS.bodySemiBold, fontSize: 6.5, color: '#fff', letterSpacing: 0.4 },
  bannerBottomRow: {
    position: 'absolute', left: 6, right: 6, bottom: 5,
    flexDirection: 'row', alignItems: 'flex-end', justifyContent: 'space-between', gap: 6,
  },
  bannerTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 10, color: '#fff', flexShrink: 1 },
  bannerBtn: { backgroundColor: COLORS.green, borderRadius: 999, paddingHorizontal: 6, paddingVertical: 2 },
  bannerBtnTx: { fontFamily: FONTS.bodySemiBold, fontSize: 7, color: COLORS.bg },

  // Anuncio en Perfil — perfil de otro proveedor con la tarjeta al fondo
  profWrap: { gap: 6 },
  profRow: { flexDirection: 'row', alignItems: 'center', gap: 8 },
  profAvatar: { width: 26, height: 26, borderRadius: 8, backgroundColor: 'rgba(255,255,255,0.1)' },
  profLine: { height: 5, borderRadius: 3, backgroundColor: 'rgba(255,255,255,0.1)', width: '80%' },
  profAdCard: {
    borderRadius: 8, overflow: 'hidden', borderWidth: 1, borderColor: 'rgba(167,139,250,0.5)',
    backgroundColor: 'rgba(167,139,250,0.08)',
  },
  profAdImg: { height: 30, justifyContent: 'flex-start' },
  profAdTag: {
    alignSelf: 'flex-start', margin: 4, backgroundColor: 'rgba(0,0,0,0.5)',
    borderRadius: 999, paddingHorizontal: 5, paddingVertical: 1.5,
  },
  profAdTagTx: { fontFamily: FONTS.bodySemiBold, fontSize: 6.5, color: '#fff' },
  profAdCaption: { fontFamily: FONTS.bodyMedium, fontSize: 8.5, color: '#fff', paddingHorizontal: 6, paddingBottom: 5 },

  // Bidding — salto de posición en el ranking
  rankWrap: { gap: 5 },
  rankRow: { flexDirection: 'row', alignItems: 'center', gap: 8 },
  rankRowHi: {},
  rankNum: { fontFamily: FONTS.bodySemiBold, fontSize: 11, color: 'rgba(255,255,255,0.35)', width: 12 },
  rankBar: { flex: 1, height: 10, borderRadius: 5, backgroundColor: 'rgba(255,255,255,0.07)' },
  rankFlame: { fontFamily: FONTS.bodySemiBold, fontSize: 9, color: '#A78BFA' },
});
