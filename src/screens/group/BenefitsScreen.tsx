import { LinearGradient } from 'expo-linear-gradient';
import React from 'react';
import {
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { ArrowLeft } from 'lucide-react-native';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';

const BENEFITS = [
  {
    emoji: '📅',
    title: 'Trabajo constante',
    desc: 'Recibe solicitudes de reserva de forma continua. Tu agenda siempre activa, sin depender de contactos externos.',
    accent: '#00E676',
  },
  {
    emoji: '🔒',
    title: 'Pago garantizado',
    desc: 'El pago completo se cobra antes del evento. Nunca más toques un escenario sin haber cobrado por adelantado.',
    accent: '#00E676',
  },
  {
    emoji: '💳',
    title: 'Pagos seguros',
    desc: 'Sistema de pagos integrado con Stripe o Mercado Pago. Sin efectivo, sin riesgos, con historial claro.',
    accent: '#448AFF',
  },
  {
    emoji: '🎸',
    title: 'Bolsa de trabajo',
    desc: 'Encuentra músicos calificados para completar tu lineup. Conecta con talento verificado cuando lo necesites.',
    accent: '#FF6E40',
  },
  {
    emoji: '🗓️',
    title: 'Calendario organizado',
    desc: 'Gestiona tu disponibilidad con un calendario propio. Bloquea fechas, acepta o rechaza con un toque.',
    accent: '#FFD740',
  },
  {
    emoji: '🔍',
    title: 'Publicidad en el explorador',
    desc: 'Tu perfil visible para miles de clientes que buscan música en vivo. Sin costo adicional de publicidad.',
    accent: '#00E676',
  },
  {
    emoji: '✅',
    title: 'Perfil verificado',
    desc: 'La insignia de verificación genera más confianza y aumenta hasta 3× las solicitudes de reserva.',
    accent: '#448AFF',
  },
  {
    emoji: '🛡️',
    title: 'Protección de contacto',
    desc: 'Tus datos personales solo se comparten después de confirmar la reserva. Cero contacto frío de desconocidos.',
    accent: '#FF6E40',
  },
  {
    emoji: '⏱️',
    title: 'Timer en vivo del evento',
    desc: 'Cronómetro automático durante el evento. Registro exacto del tiempo tocado para cualquier cobro de horas extra.',
    accent: '#FFD740',
  },
  {
    emoji: '⚡',
    title: 'Pago liberado automáticamente',
    desc: 'Tu pago se transfiere a tu billetera al finalizar el evento. Sin perseguir al cliente, sin esperas.',
    accent: '#00E676',
  },
] as const;

export default function BenefitsScreen({ navigation }: any) {
  return (
    <View style={styles.root}>
      <SafeAreaView style={styles.header} edges={['top']}>
        <Pressable style={styles.backBtn} onPress={() => navigation.goBack()}>
          <ArrowLeft size={20} color={COLORS.text} />
        </Pressable>
        <Text style={styles.headerTitle}>Por qué Daricefy</Text>
        <View style={{ width: 40 }} />
      </SafeAreaView>

      <ScrollView
        contentContainerStyle={styles.scroll}
        showsVerticalScrollIndicator={false}
      >
        {/* Hero */}
        <LinearGradient
          colors={['rgba(0,230,118,0.12)', 'transparent']}
          style={styles.hero}
          start={{ x: 0, y: 0 }}
          end={{ x: 1, y: 1 }}
        >
          <Text style={styles.heroEmoji}>🤝</Text>
          <Text style={styles.heroTitle}>Tu alianza estratégica</Text>
          <Text style={styles.heroSub}>
            Daricefy no es solo una plataforma.{'\n'}
            Es la estructura que te permite crecer como grupo profesional.
          </Text>
        </LinearGradient>

        {/* Benefit cards */}
        <View style={styles.cardsContainer}>
          {BENEFITS.map((b, i) => (
            <BenefitCard key={i} {...b} />
          ))}
        </View>

        {/* Footer note */}
        <View style={styles.footer}>
          <View style={styles.footerDivider} />
          <Text style={styles.footerLabel}>MODELO DE NEGOCIO</Text>
          <Text style={styles.footerText}>
            Por el acceso a todo esto, Daricefy cobra únicamente el{' '}
            <Text style={styles.footerHighlight}>10% de comisión</Text>
            {' '}sobre cada evento completado. Sin mensualidades, sin costo de registro.
          </Text>
          <Text style={styles.footerSub}>
            Solo pagas cuando ganas.
          </Text>
        </View>
      </ScrollView>
    </View>
  );
}

function BenefitCard({
  emoji,
  title,
  desc,
  accent,
}: {
  emoji: string;
  title: string;
  desc: string;
  accent: string;
}) {
  return (
    <View style={styles.card}>
      <View style={[styles.cardAccent, { backgroundColor: accent + '22', borderColor: accent + '44' }]}>
        <Text style={styles.cardEmoji}>{emoji}</Text>
      </View>
      <View style={styles.cardBody}>
        <Text style={styles.cardTitle}>{title}</Text>
        <Text style={styles.cardDesc}>{desc}</Text>
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  root: {
    flex: 1,
    backgroundColor: COLORS.bg,
  },

  // ── Header ──────────────────────────────────────────────────────────────────
  header: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    paddingHorizontal: SPACING.xl,
    paddingVertical: 14,
    borderBottomWidth: 1,
    borderBottomColor: COLORS.border,
  },
  backBtn: {
    width: 40,
    height: 40,
    borderRadius: 12,
    backgroundColor: COLORS.card,
    borderWidth: 1,
    borderColor: COLORS.border,
    alignItems: 'center',
    justifyContent: 'center',
  },
  headerTitle: {
    fontFamily: FONTS.bodySemiBold,
    fontSize: 16,
    color: COLORS.text,
  },

  // ── Scroll ───────────────────────────────────────────────────────────────────
  scroll: {
    paddingBottom: 48,
  },

  // ── Hero ─────────────────────────────────────────────────────────────────────
  hero: {
    marginHorizontal: SPACING.xl,
    marginTop: SPACING.xl,
    marginBottom: 8,
    borderRadius: RADIUS.xl,
    borderWidth: 1,
    borderColor: 'rgba(0,230,118,0.2)',
    padding: 24,
    alignItems: 'center',
  },
  heroEmoji: {
    fontSize: 40,
    marginBottom: 12,
  },
  heroTitle: {
    fontFamily: FONTS.title,
    fontSize: 22,
    color: COLORS.text,
    marginBottom: 10,
    textAlign: 'center',
  },
  heroSub: {
    fontFamily: FONTS.body,
    fontSize: 14,
    color: COLORS.muted2,
    textAlign: 'center',
    lineHeight: 21,
  },

  // ── Cards ────────────────────────────────────────────────────────────────────
  cardsContainer: {
    paddingHorizontal: SPACING.xl,
    paddingTop: 20,
    gap: 12,
  },
  card: {
    flexDirection: 'row',
    alignItems: 'flex-start',
    gap: 14,
    backgroundColor: COLORS.card,
    borderRadius: RADIUS.lg,
    borderWidth: 1,
    borderColor: COLORS.border,
    padding: 16,
  },
  cardAccent: {
    width: 48,
    height: 48,
    borderRadius: RADIUS.md,
    borderWidth: 1,
    alignItems: 'center',
    justifyContent: 'center',
    flexShrink: 0,
  },
  cardEmoji: {
    fontSize: 22,
  },
  cardBody: {
    flex: 1,
  },
  cardTitle: {
    fontFamily: FONTS.bodySemiBold,
    fontSize: 15,
    color: COLORS.text,
    marginBottom: 4,
  },
  cardDesc: {
    fontFamily: FONTS.body,
    fontSize: 13,
    color: COLORS.muted2,
    lineHeight: 19,
  },

  // ── Footer ───────────────────────────────────────────────────────────────────
  footer: {
    marginHorizontal: SPACING.xl,
    marginTop: 28,
    alignItems: 'center',
  },
  footerDivider: {
    width: 40,
    height: 1,
    backgroundColor: COLORS.border,
    marginBottom: 20,
  },
  footerLabel: {
    fontFamily: FONTS.bodySemiBold,
    fontSize: 11,
    color: COLORS.muted,
    letterSpacing: 1.5,
    marginBottom: 12,
  },
  footerText: {
    fontFamily: FONTS.body,
    fontSize: 14,
    color: COLORS.muted2,
    textAlign: 'center',
    lineHeight: 22,
  },
  footerHighlight: {
    fontFamily: FONTS.bodySemiBold,
    color: COLORS.green,
  },
  footerSub: {
    fontFamily: FONTS.bodySemiBold,
    fontSize: 15,
    color: COLORS.text,
    marginTop: 12,
  },
});
