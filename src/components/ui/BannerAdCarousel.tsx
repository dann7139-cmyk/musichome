import { LinearGradient } from 'expo-linear-gradient';
import * as WebBrowser from 'expo-web-browser';
import { Volume2, VolumeX } from 'lucide-react-native';
import React, { useEffect, useRef, useState } from 'react';
import { Animated, Image, Pressable, StyleSheet, Text, View } from 'react-native';
import { useIsFocused } from '@react-navigation/native';
import { supabase } from '../../config/supabase';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';
import VideoPlayer from './VideoPlayer';

// Petición real (2026-09-03): "quiero que el banner home también aparezca
// en Inicio donde siguen a los grupos... igual aparecerá en Inicio donde
// salen las publicaciones". El tipo de anuncio 'banner_home' YA prometía
// esto en su propia descripción ("Lo ven todos los usuarios al abrir la
// app") pero solo se renderizaba en HomeScreen (tab Explorar) — nunca en
// FeedScreen (tab Inicio, la primera pantalla al abrir la app). Extraído
// aquí como componente reutilizable (mismo look, misma RPC
// get_active_banner_ads) para que ambas pantallas muestren EXACTAMENTE
// los mismos anuncios activos, sin duplicar la lógica de animación/video.
//
// Auto-contenido: hace su propio fetch (no depende de que el padre ya
// haya cargado `bannerAds`) — así cualquier pantalla nueva puede montarlo
// con solo pasarle navigation + city/state/country.

interface Props {
  navigation: any;
  city?: string | null;
  state?: string | null;
  country?: string | null;
  style?: any;
}

export default function BannerAdCarousel({ navigation, city = null, state = null, country = null, style }: Props) {
  const [ads, setAds] = useState<any[]>([]);
  const [currentAdIndex, setCurrentAdIndex] = useState(0);
  const [bannerImgError, setBannerImgError] = useState(false);
  const [adMuted, setAdMuted] = useState(false);
  const adFade = useRef(new Animated.Value(1)).current;
  const isFocused = useIsFocused();

  useEffect(() => {
    let cancelled = false;
    (async () => {
      const params: Record<string, any> = {};
      if (city)    params.p_city    = city;
      if (state)   params.p_state   = state;
      if (country) params.p_country = country.toLowerCase();
      const { data } = await supabase.rpc('get_active_banner_ads', params);
      if (!cancelled) { setAds((data as any[]) ?? []); setCurrentAdIndex(0); }
    })();
    return () => { cancelled = true; };
  }, [city, state, country]);

  // Registrar impresión cada vez que cambia el anuncio visible
  useEffect(() => {
    if (ads.length === 0) return;
    const ad = ads[currentAdIndex];
    if (ad?.id) supabase.rpc('track_ad_impression', { p_ad_id: ad.id }).then(() => {});
  }, [currentAdIndex, ads.length]);

  // Carousel automático — mismo patrón que HomeScreen (video avanza solo
  // por su propio onEnd, imagen avanza por temporizador)
  useEffect(() => {
    const total = ads.length;
    if (total <= 1) return;
    const current = ads[currentAdIndex % total];
    if (current?.media_type === 'video') return;
    const secs = current?.duration_seconds ?? 5;
    const timer = setTimeout(() => {
      Animated.timing(adFade, { toValue: 0, duration: 280, useNativeDriver: true }).start(() => {
        setCurrentAdIndex(prev => (prev + 1) % total);
        setBannerImgError(false);
        Animated.timing(adFade, { toValue: 1, duration: 280, useNativeDriver: true }).start();
      });
    }, secs * 1000);
    return () => clearTimeout(timer);
  }, [ads.length, currentAdIndex]);

  const openAdDestination = (ad: any) => {
    if (ad.link_type === 'group' && ad.link_id) {
      supabase.from('groups').select('*').eq('id', ad.link_id).single()
        .then(({ data }) => { if (data) navigation.navigate('GroupDetail', { group: data }); });
      return;
    }
    if (ad.link_type === 'video' && ad.youtube_url) {
      WebBrowser.openBrowserAsync(ad.youtube_url, {
        dismissButtonStyle: 'close',
        presentationStyle: WebBrowser.WebBrowserPresentationStyle.PAGE_SHEET,
      });
      return;
    }
    if (ad.link_type === 'url' && ad.link_url) {
      WebBrowser.openBrowserAsync(ad.link_url, {
        dismissButtonStyle: 'close',
        presentationStyle: WebBrowser.WebBrowserPresentationStyle.PAGE_SHEET,
      });
      return;
    }
    // Sin link específico: llevar a paquetes de publicidad
    navigation.navigate('AdvertisingPackages');
  };

  const handleAdPress = (ad: any) => {
    if (ad?.id) supabase.rpc('track_ad_click', { p_ad_id: ad.id }).then(() => {});
    openAdDestination(ad);
  };

  if (ads.length === 0) return null;
  const total = ads.length;
  const safeIndex = currentAdIndex % total;
  const item = ads[safeIndex];

  return (
    <View style={[{ marginBottom: 20 }, style]}>
      <Animated.View style={{ opacity: adFade }}>
        <Pressable style={s.promoBanner} onPress={() => handleAdPress(item)}>
          <View style={s.promoBannerInner}>
            {item.media_type === 'video' && item.media_url ? (
              <VideoPlayer
                uri={item.media_url}
                style={s.promoBannerBg}
                contentFit="cover"
                startTime={item.video_start_seconds ?? 0}
                autoPlay
                muted={adMuted || !isFocused}
                loop={total <= 1}
                onEnd={total > 1 ? () => {
                  Animated.timing(adFade, { toValue: 0, duration: 280, useNativeDriver: true }).start(() => {
                    setCurrentAdIndex(prev => (prev + 1) % total);
                    setBannerImgError(false);
                    Animated.timing(adFade, { toValue: 1, duration: 280, useNativeDriver: true }).start();
                  });
                } : undefined}
              />
            ) : item.media_url && !bannerImgError ? (
              <Image
                source={{ uri: item.media_url }}
                style={s.promoBannerBg}
                resizeMode="cover"
                onError={() => setBannerImgError(true)}
              />
            ) : (
              <LinearGradient colors={['#0d1f0d', '#030a03']} style={s.promoBannerBg} />
            )}
            <LinearGradient
              colors={['transparent', 'rgba(0,0,0,0.48)', 'rgba(0,0,0,0.78)']}
              locations={[0.48, 0.76, 1]}
              style={s.promoBannerGrad}
            />
            <View style={s.promoBannerTagChip}>
              <Text style={s.promoBannerTagText}>ANUNCIO</Text>
            </View>
            {item.media_type === 'video' && item.media_url && (
              <Pressable style={s.promoBannerMute} onPress={() => setAdMuted(m => !m)} hitSlop={8}>
                {adMuted ? <VolumeX size={15} color="#fff" /> : <Volume2 size={15} color="#fff" />}
              </Pressable>
            )}
            <View style={s.promoBannerOverlay}>
              <View style={{ flex: 1 }}>
                <Text style={s.promoBannerTitle} numberOfLines={1}>{item.title}</Text>
                {item.subtitle ? <Text style={s.promoBannerSub} numberOfLines={1}>{item.subtitle}</Text> : null}
              </View>
              {!!item.button_text && (
                <Pressable style={s.promoBannerBtn} onPress={() => handleAdPress(item)}>
                  <Text style={s.promoBannerBtnText}>{item.button_text} →</Text>
                </Pressable>
              )}
            </View>
          </View>
        </Pressable>
      </Animated.View>
      {total > 1 && (
        <View style={s.carouselDots}>
          {ads.map((_: any, i: number) => (
            <Pressable
              key={i}
              onPress={() => {
                Animated.timing(adFade, { toValue: 0, duration: 200, useNativeDriver: true }).start(() => {
                  setCurrentAdIndex(i);
                  Animated.timing(adFade, { toValue: 1, duration: 200, useNativeDriver: true }).start();
                });
              }}
            >
              <View style={[s.carouselDot, i === safeIndex && s.carouselDotActive]} />
            </Pressable>
          ))}
        </View>
      )}
    </View>
  );
}

const s = StyleSheet.create({
  promoBanner: {
    borderRadius: RADIUS.xl, overflow: 'hidden',
    borderWidth: 1, borderColor: COLORS.greenGlow,
  },
  promoBannerInner: { height: 132, position: 'relative' },
  promoBannerMute: {
    position: 'absolute', top: 8, right: 8,
    width: 30, height: 30, borderRadius: 15,
    alignItems: 'center', justifyContent: 'center',
    backgroundColor: 'rgba(0,0,0,0.5)',
    borderWidth: 1, borderColor: 'rgba(255,255,255,0.15)',
  },
  promoBannerBg: {
    position: 'absolute', top: 0, left: 0, right: 0, bottom: 0,
    width: '100%', height: '100%',
  },
  promoBannerGrad: {
    position: 'absolute', top: 0, left: 0, right: 0, bottom: 0,
  },
  promoBannerTagChip: {
    position: 'absolute', top: 8, left: 8,
    backgroundColor: 'rgba(0,0,0,0.45)',
    borderRadius: RADIUS.full, paddingHorizontal: 7, paddingVertical: 3,
    borderWidth: 1, borderColor: 'rgba(255,255,255,0.12)',
  },
  promoBannerTagText: {
    fontFamily: FONTS.bodyMedium, fontSize: 7,
    color: 'rgba(255,255,255,0.70)', letterSpacing: 1.0,
  },
  promoBannerOverlay: {
    position: 'absolute', bottom: 0, left: 0, right: 0,
    flexDirection: 'row', alignItems: 'flex-end', gap: 8,
    paddingHorizontal: SPACING.md, paddingBottom: 11,
  },
  promoBannerTitle: {
    fontFamily: FONTS.bodySemiBold, fontSize: 12.5, color: '#fff', marginBottom: 2,
    textShadowColor: 'rgba(0,0,0,0.6)', textShadowOffset: { width: 0, height: 1 }, textShadowRadius: 4,
  },
  promoBannerSub: {
    fontFamily: FONTS.body, fontSize: 10.5, color: 'rgba(255,255,255,0.78)',
    textShadowColor: 'rgba(0,0,0,0.5)', textShadowOffset: { width: 0, height: 1 }, textShadowRadius: 3,
  },
  promoBannerBtn: {
    paddingHorizontal: 8, paddingVertical: 4,
    borderRadius: RADIUS.sm, backgroundColor: COLORS.green, flexShrink: 0,
  },
  promoBannerBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 9.5, color: '#000' },
  carouselDots: {
    flexDirection: 'row', justifyContent: 'center', alignItems: 'center',
    gap: 6, marginTop: 10,
  },
  carouselDot: { width: 6, height: 6, borderRadius: 3, backgroundColor: COLORS.border },
  carouselDotActive: { width: 18, backgroundColor: COLORS.green },
});
