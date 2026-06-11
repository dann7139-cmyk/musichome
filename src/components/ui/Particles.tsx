import React, { useEffect, useRef } from 'react';
import { Animated, Dimensions, Easing, View } from 'react-native';
import { COLORS } from '../../config/theme';

const { width, height } = Dimensions.get('window');

function Particle({
  x, size, duration, delay, startY, maxOpacity, driftRange,
}: {
  x: number; size: number; duration: number; delay: number;
  startY: number; maxOpacity: number; driftRange: number;
}) {
  const translateY = useRef(new Animated.Value(startY)).current;
  const translateX = useRef(new Animated.Value(0)).current;
  const opacity = useRef(new Animated.Value(0)).current;

  useEffect(() => {
    Animated.loop(
      Animated.sequence([
        Animated.timing(translateX, {
          toValue: driftRange,
          duration: duration * 0.6,
          easing: Easing.inOut(Easing.sin),
          useNativeDriver: true,
        }),
        Animated.timing(translateX, {
          toValue: -driftRange,
          duration: duration * 0.6,
          easing: Easing.inOut(Easing.sin),
          useNativeDriver: true,
        }),
      ])
    ).start();

    const rise = () => {
      translateY.setValue(startY);
      opacity.setValue(0);
      Animated.sequence([
        Animated.delay(delay),
        Animated.parallel([
          Animated.timing(translateY, { toValue: -30, duration, easing: Easing.linear, useNativeDriver: true }),
          Animated.sequence([
            Animated.timing(opacity, { toValue: maxOpacity, duration: 700, useNativeDriver: true }),
            Animated.timing(opacity, { toValue: 0, duration: duration - 700, useNativeDriver: true }),
          ]),
        ]),
      ]).start(() => rise());
    };
    rise();
  }, []);

  const glowSize = size * 3;

  return (
    <Animated.View
      style={{
        position: 'absolute',
        left: x - glowSize / 2,
        width: glowSize,
        height: glowSize,
        alignItems: 'center',
        justifyContent: 'center',
        opacity,
        transform: [{ translateY }, { translateX }],
      }}
    >
      <View
        style={{
          position: 'absolute',
          width: glowSize,
          height: glowSize,
          borderRadius: glowSize / 2,
          backgroundColor: 'rgba(0,230,118,0.12)',
        }}
      />
      <View
        style={{
          width: size,
          height: size,
          borderRadius: size / 2,
          backgroundColor: COLORS.green,
          shadowColor: COLORS.green,
          shadowOffset: { width: 0, height: 0 },
          shadowOpacity: 1,
          shadowRadius: size * 2,
          elevation: 0,
        }}
      />
    </Animated.View>
  );
}

const PARTICLES = [
  { x: width * 0.04, size: 3, duration: 6000, delay: 0,    startY: height,       maxOpacity: 0.9, driftRange: 8  },
  { x: width * 0.13, size: 2, duration: 7200, delay: 900,  startY: height * 0.6, maxOpacity: 0.6, driftRange: 12 },
  { x: width * 0.22, size: 4, duration: 5500, delay: 300,  startY: height * 0.8, maxOpacity: 0.8, driftRange: 6  },
  { x: width * 0.31, size: 2, duration: 6800, delay: 1800, startY: height,       maxOpacity: 0.5, driftRange: 15 },
  { x: width * 0.42, size: 3, duration: 5000, delay: 700,  startY: height * 0.5, maxOpacity: 0.7, driftRange: 10 },
  { x: width * 0.51, size: 2, duration: 7000, delay: 200,  startY: height * 0.7, maxOpacity: 0.6, driftRange: 8  },
  { x: width * 0.6,  size: 5, duration: 5800, delay: 1200, startY: height,       maxOpacity: 0.9, driftRange: 5  },
  { x: width * 0.7,  size: 2, duration: 6500, delay: 500,  startY: height * 0.4, maxOpacity: 0.5, driftRange: 14 },
  { x: width * 0.79, size: 3, duration: 5200, delay: 2000, startY: height * 0.9, maxOpacity: 0.8, driftRange: 9  },
  { x: width * 0.87, size: 2, duration: 7500, delay: 400,  startY: height * 0.6, maxOpacity: 0.6, driftRange: 11 },
  { x: width * 0.95, size: 4, duration: 5600, delay: 800,  startY: height,       maxOpacity: 0.7, driftRange: 7  },
];

export default function Particles() {
  return (
    <>
      {PARTICLES.map((p, i) => (
        <Particle key={i} {...p} />
      ))}
    </>
  );
}
