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
    price:       'Desde $169 · 3 días',
    badge:       '⭐ Premium',
    screen:      'AdvertisingPackages',
    screenParams: { initialType: 'sponsored_group' },
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

              {/* Bottom accent line */}
              <View style={[s.accentLine, { backgroundColor: card.accent }]} />
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
