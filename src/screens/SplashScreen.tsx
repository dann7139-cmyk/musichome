import { LinearGradient } from 'expo-linear-gradient';
import React, { useEffect, useRef } from 'react';
import { Animated, Easing, Image, StyleSheet, Text, View } from 'react-native';
import { useTranslation } from 'react-i18next';
import { COLORS, FONTS } from '../config/theme';

export default function SplashScreen() {
  const { t } = useTranslation();
  const logoOpacity  = useRef(new Animated.Value(0)).current;
  const logoScale    = useRef(new Animated.Value(0.82)).current;
  const glowOpacity  = useRef(new Animated.Value(0)).current;
  const taglineOp    = useRef(new Animated.Value(0)).current;
  const taglineY     = useRef(new Animated.Value(12)).current;
  const dotPulse     = useRef(new Animated.Value(1)).current;

  useEffect(() => {
    // Logo fade + scale in
    Animated.parallel([
      Animated.timing(logoOpacity, {
        toValue: 1, duration: 700, easing: Easing.out(Easing.cubic),
        useNativeDriver: true,
      }),
      Animated.timing(logoScale, {
        toValue: 1, duration: 700, easing: Easing.out(Easing.back(1.4)),
        useNativeDriver: true,
      }),
      Animated.timing(glowOpacity, {
        toValue: 1, duration: 900, delay: 200, easing: Easing.out(Easing.ease),
        useNativeDriver: true,
      }),
    ]).start(() => {
      // Tagline slide up
      Animated.parallel([
        Animated.timing(taglineOp, {
          toValue: 1, duration: 400, easing: Easing.out(Easing.ease),
          useNativeDriver: true,
        }),
        Animated.timing(taglineY, {
          toValue: 0, duration: 400, easing: Easing.out(Easing.ease),
          useNativeDriver: true,
        }),
      ]).start();

      // Dot pulse loop
      Animated.loop(
        Animated.sequence([
          Animated.timing(dotPulse, { toValue: 1.6, duration: 700, useNativeDriver: true }),
          Animated.timing(dotPulse, { toValue: 1,   duration: 700, useNativeDriver: true }),
        ])
      ).start();
    });
  }, []);

  return (
    <View style={s.container}>
      {/* Background radial glow */}
      <Animated.View style={[s.glow, { opacity: glowOpacity }]} />

      {/* Logo block */}
      <Animated.View style={{ alignItems: 'center', opacity: logoOpacity, transform: [{ scale: logoScale }] }}>
        {/* Marca (2026-09-04) — el logo real, arriba del wordmark */}
        <Image source={require('../../assets/images/icon.png')} style={s.mark} resizeMode="contain" />

        {/* Live dot */}
        <Animated.View style={[s.liveDot, { transform: [{ scale: dotPulse }] }]} />

        <Text style={s.logo}>
          Darice<Text style={s.logoAccent}>fy</Text>
        </Text>

        {/* Underline gradient */}
        <LinearGradient
          colors={[COLORS.green, 'rgba(0,230,118,0)']}
          start={{ x: 0, y: 0 }} end={{ x: 1, y: 0 }}
          style={s.underline}
        />
      </Animated.View>

      {/* Tagline */}
      <Animated.Text
        style={[s.tagline, { opacity: taglineOp, transform: [{ translateY: taglineY }] }]}
      >
        {t('splashScreen.tagline')}
      </Animated.Text>
    </View>
  );
}

const s = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: COLORS.bg ?? '#040404',
    alignItems: 'center',
    justifyContent: 'center',
    gap: 20,
  },
  glow: {
    position: 'absolute',
    width: 280,
    height: 280,
    borderRadius: 140,
    backgroundColor: 'rgba(0,230,118,0.07)',
    top: '50%',
    left: '50%',
    marginTop: -140,
    marginLeft: -140,
  },
  mark: {
    width: 88,
    height: 88,
    marginBottom: 14,
  },
  liveDot: {
    width: 8,
    height: 8,
    borderRadius: 4,
    backgroundColor: COLORS.green ?? '#00E676',
    marginBottom: 10,
    shadowColor: COLORS.green ?? '#00E676',
    shadowOpacity: 0.8,
    shadowRadius: 8,
    shadowOffset: { width: 0, height: 0 },
    elevation: 6,
  },
  logo: {
    fontFamily: FONTS.title ?? 'System',
    fontSize: 36,
    color: '#fff',
    letterSpacing: -0.5,
  },
  logoAccent: {
    color: COLORS.green ?? '#00E676',
  },
  underline: {
    height: 2,
    width: 120,
    borderRadius: 1,
    marginTop: 8,
  },
  tagline: {
    fontFamily: FONTS.body ?? 'System',
    fontSize: 13,
    color: 'rgba(255,255,255,0.35)',
    letterSpacing: 0.3,
    textAlign: 'center',
  },
});
