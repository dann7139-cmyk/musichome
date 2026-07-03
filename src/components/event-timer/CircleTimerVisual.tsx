import React, { useEffect } from 'react';
import { View, Text, StyleSheet } from 'react-native';
import Animated, {
  useSharedValue,
  useAnimatedStyle,
  useAnimatedProps,
  withRepeat,
  withTiming,
  withSequence,
  withDelay,
  Easing,
} from 'react-native-reanimated';
import Svg, {
  Circle,
  Path,
  Defs,
  RadialGradient as SvgRadialGradient,
  Stop,
} from 'react-native-svg';

const AnimatedCircle = Animated.createAnimatedComponent(Circle);

// ─────────────────────────────────────────────────────────────────────────────
// TYPES & CONSTANTS
// ─────────────────────────────────────────────────────────────────────────────

export type TimerState =
  | 'pre_event'
  | 'live'
  | 'break'
  | 'extra_hours'
  | 'completed';

export interface CircleTimerVisualProps {
  state: TimerState;
  currentTime: string;      // "01:23:45"
  label?: string;           // opcional, default por estado
  subtitle?: string;        // "Restan 2h 36m"
  progress?: number;        // 0..1
  size?: number;            // px, default 320
  extraAmount?: string;     // Para extra_hours: "+$3,600 MXN"
}

const PALETTES = {
  pre_event:   { accent: '#94A3B8', rgb: '148, 163, 184' },
  live:        { accent: '#00E676', rgb: '0, 230, 118' },
  break:       { accent: '#60A5FA', rgb: '96, 165, 250' },
  extra_hours: { accent: '#FBBF24', rgb: '251, 191, 36' },
  completed:   { accent: '#00E676', rgb: '0, 230, 118' },
};

const DEFAULT_SIZE = 320;
const RING_VIEWBOX = 200;
const RING_RADIUS = 86;
const RING_STROKE = 9;
const RING_CIRCUMFERENCE = 2 * Math.PI * RING_RADIUS; // ~540

// ─────────────────────────────────────────────────────────────────────────────
// HELPER: PulsatingWave
// ─────────────────────────────────────────────────────────────────────────────

interface WaveProps {
  size: number;
  color: string;
  borderWidth?: number;
  duration?: number;
  delay?: number;
  startOpacity?: number;
  endScale?: number;
}

function PulsatingWave({
  size,
  color,
  borderWidth = 2,
  duration = 4200,
  delay = 0,
  startOpacity = 0.8,
  endScale = 1.24,
}: WaveProps) {
  const scale = useSharedValue(0.78);
  const opacity = useSharedValue(0);

  useEffect(() => {
    scale.value = withDelay(
      delay,
      withRepeat(
        withTiming(endScale, { duration, easing: Easing.bezier(0.15, 0.5, 0.3, 1) }),
        -1,
        false
      )
    );
    opacity.value = withDelay(
      delay,
      withRepeat(
        withSequence(
          withTiming(startOpacity, { duration: 0 }),
          withTiming(0, { duration, easing: Easing.out(Easing.quad) })
        ),
        -1,
        false
      )
    );
  }, [delay, duration, endScale, startOpacity, opacity, scale]);

  const animStyle = useAnimatedStyle(() => ({
    transform: [{ scale: scale.value }],
    opacity: opacity.value,
  }));

  return (
    <Animated.View
      pointerEvents="none"
      style={[
        styles.waveAbsolute,
        {
          width: size,
          height: size,
          borderRadius: size / 2,
          borderWidth,
          borderColor: color,
          shadowColor: color,
          shadowOpacity: 0.4,
          shadowRadius: 14,
          shadowOffset: { width: 0, height: 0 },
          elevation: 0,
        },
        animStyle,
      ]}
    />
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// HELPER: BreathingOrb
// ─────────────────────────────────────────────────────────────────────────────

interface OrbProps {
  size: number;
  rgb: string;
  duration?: number;
  centerOpacity?: number;
  scaleMin?: number;
  scaleMax?: number;
}

function BreathingOrb({
  size,
  rgb,
  duration = 3500,
  centerOpacity = 0.22,
  scaleMin = 0.95,
  scaleMax = 1.1,
}: OrbProps) {
  const scale = useSharedValue(scaleMin);
  const opacity = useSharedValue(0.85);

  useEffect(() => {
    scale.value = withRepeat(
      withSequence(
        withTiming(scaleMax, { duration: duration / 2, easing: Easing.inOut(Easing.quad) }),
        withTiming(scaleMin, { duration: duration / 2, easing: Easing.inOut(Easing.quad) })
      ),
      -1,
      false
    );
    opacity.value = withRepeat(
      withSequence(
        withTiming(1, { duration: duration / 2 }),
        withTiming(0.85, { duration: duration / 2 })
      ),
      -1,
      false
    );
  }, [duration, scaleMin, scaleMax, scale, opacity]);

  const animStyle = useAnimatedStyle(() => ({
    transform: [{ scale: scale.value }],
    opacity: opacity.value,
  }));

  const orbId = `orbGrad-${rgb.replace(/[, ]/g, '')}`;

  return (
    <Animated.View
      pointerEvents="none"
      style={[
        {
          position: 'absolute',
          width: size,
          height: size,
        },
        animStyle,
      ]}
    >
      <Svg width="100%" height="100%" viewBox={`0 0 ${size} ${size}`}>
        <Defs>
          <SvgRadialGradient id={orbId} cx="50%" cy="50%" r="50%">
            <Stop offset="0%" stopColor={`rgb(${rgb})`} stopOpacity={centerOpacity} />
            <Stop offset="40%" stopColor={`rgb(${rgb})`} stopOpacity={centerOpacity * 0.36} />
            <Stop offset="70%" stopColor={`rgb(${rgb})`} stopOpacity={0} />
          </SvgRadialGradient>
        </Defs>
        <Circle cx={size / 2} cy={size / 2} r={size / 2} fill={`url(#${orbId})`} />
      </Svg>
    </Animated.View>
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// HELPER: RingProgress
// ─────────────────────────────────────────────────────────────────────────────

interface RingProps {
  size: number;
  accent: string;
  progress: number;
  dashed?: boolean;
}

function RingProgress({ size, accent, progress, dashed = false }: RingProps) {
  const dashOffset = useSharedValue(
    RING_CIRCUMFERENCE - progress * RING_CIRCUMFERENCE
  );

  const rotation = useSharedValue(0);
  useEffect(() => {
    if (dashed) {
      rotation.value = withRepeat(
        withTiming(-RING_CIRCUMFERENCE, { duration: 30000, easing: Easing.linear }),
        -1,
        false
      );
    }
  }, [dashed, rotation]);

  useEffect(() => {
    dashOffset.value = withTiming(
      RING_CIRCUMFERENCE - progress * RING_CIRCUMFERENCE,
      { duration: 800, easing: Easing.out(Easing.cubic) }
    );
  }, [progress, dashOffset]);

  const animatedProps = useAnimatedProps(() => ({
    strokeDashoffset: dashed ? rotation.value : dashOffset.value,
  }));

  return (
    <Svg
      width={size}
      height={size}
      viewBox={`0 0 ${RING_VIEWBOX} ${RING_VIEWBOX}`}
      style={{ transform: [{ rotate: '-90deg' }] }}
    >
      <Circle
        cx={RING_VIEWBOX / 2}
        cy={RING_VIEWBOX / 2}
        r={RING_RADIUS}
        stroke="rgba(255,255,255,0.06)"
        fill="none"
        strokeWidth={RING_STROKE}
      />
      <AnimatedCircle
        cx={RING_VIEWBOX / 2}
        cy={RING_VIEWBOX / 2}
        r={RING_RADIUS}
        stroke={accent}
        fill="none"
        strokeWidth={RING_STROKE}
        strokeLinecap="round"
        strokeDasharray={dashed ? '4 8' : `${RING_CIRCUMFERENCE} ${RING_CIRCUMFERENCE}`}
        animatedProps={animatedProps}
      />
    </Svg>
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// HELPER: FlyingParticle
// ─────────────────────────────────────────────────────────────────────────────

interface FlyingParticleProps {
  symbol: string;
  color: string;
  fontSize?: number;
  startX: number;
  startY: number;
  containerSize: number;
  endTx: number;
  endTy: number;
  endRotation?: number;
  duration?: number;
  delay?: number;
  fontWeight?: '400' | '500' | '600' | '700' | '900';
  glow?: boolean;
}

function FlyingParticle({
  symbol,
  color,
  fontSize = 14,
  startX,
  startY,
  containerSize,
  endTx,
  endTy,
  endRotation = 0,
  duration = 5000,
  delay = 0,
  fontWeight = '500',
  glow = true,
}: FlyingParticleProps) {
  const tx = useSharedValue(0);
  const ty = useSharedValue(0);
  const scale = useSharedValue(0.3);
  const opacity = useSharedValue(0);
  const rot = useSharedValue(0);

  useEffect(() => {
    const animate = () => {
      tx.value = 0;
      ty.value = 0;
      scale.value = 0.3;
      opacity.value = 0;
      rot.value = 0;

      tx.value = withDelay(delay, withTiming(endTx, { duration, easing: Easing.out(Easing.quad) }));
      ty.value = withDelay(delay, withTiming(endTy, { duration, easing: Easing.out(Easing.quad) }));
      scale.value = withDelay(delay, withTiming(1.2, { duration, easing: Easing.out(Easing.quad) }));
      rot.value = withDelay(delay, withTiming(endRotation, { duration, easing: Easing.out(Easing.quad) }));
      opacity.value = withDelay(
        delay,
        withSequence(
          withTiming(1, { duration: duration * 0.15 }),
          withTiming(0.6, { duration: duration * 0.55 }),
          withTiming(0, { duration: duration * 0.3 })
        )
      );
    };

    animate();
    const interval = setInterval(animate, duration);
    return () => clearInterval(interval);
  }, [delay, duration, endTx, endTy, endRotation, tx, ty, scale, opacity, rot]);

  const animStyle = useAnimatedStyle(() => ({
    transform: [
      { translateX: tx.value },
      { translateY: ty.value },
      { scale: scale.value },
      { rotate: `${rot.value}deg` },
    ],
    opacity: opacity.value,
  }));

  return (
    <Animated.Text
      style={[
        {
          position: 'absolute',
          left: (startX / 100) * containerSize - fontSize / 2,
          top: (startY / 100) * containerSize - fontSize / 2,
          color,
          fontSize,
          fontWeight,
          textShadowColor: glow ? color : 'transparent',
          textShadowOffset: { width: 0, height: 0 },
          textShadowRadius: glow ? 8 : 0,
        },
        animStyle,
      ]}
    >
      {symbol}
    </Animated.Text>
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// HELPER: SteamParticle
// ─────────────────────────────────────────────────────────────────────────────

interface SteamProps {
  startX: number;
  startY: number;
  endTx: number;
  endTy: number;
  delay: number;
  rgb: string;
}

function SteamParticle({ startX, startY, endTx, endTy, delay, rgb }: SteamProps) {
  const tx = useSharedValue(0);
  const ty = useSharedValue(0);
  const scale = useSharedValue(0.5);
  const opacity = useSharedValue(0);

  useEffect(() => {
    const animate = () => {
      tx.value = 0;
      ty.value = 0;
      scale.value = 0.5;
      opacity.value = 0;

      const d = 6000;
      tx.value = withDelay(delay, withTiming(endTx, { duration: d, easing: Easing.out(Easing.quad) }));
      ty.value = withDelay(delay, withTiming(endTy, { duration: d, easing: Easing.out(Easing.quad) }));
      scale.value = withDelay(delay, withTiming(2.8, { duration: d, easing: Easing.out(Easing.quad) }));
      opacity.value = withDelay(
        delay,
        withSequence(
          withTiming(0.8, { duration: d * 0.15 }),
          withTiming(0, { duration: d * 0.85 })
        )
      );
    };

    animate();
    const interval = setInterval(animate, 6000);
    return () => clearInterval(interval);
  }, [delay, endTx, endTy, tx, ty, scale, opacity]);

  const animStyle = useAnimatedStyle(() => ({
    transform: [
      { translateX: tx.value },
      { translateY: ty.value },
      { scale: scale.value },
    ],
    opacity: opacity.value,
  }));

  return (
    <Animated.View
      style={[
        {
          position: 'absolute',
          left: startX,
          top: startY,
          width: 4,
          height: 4,
          borderRadius: 2,
          backgroundColor: `rgba(${rgb}, 0.6)`,
        },
        animStyle,
      ]}
    />
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// HELPER: ConfettiPiece
// ─────────────────────────────────────────────────────────────────────────────

interface ConfettiProps {
  shape: 'dot' | 'streamer' | 'star';
  color: string;
  endTx: number;
  endTy: number;
  endRotation: number;
  delay: number;
  containerSize: number;
}

function ConfettiPiece({ shape, color, endTx, endTy, endRotation, delay, containerSize }: ConfettiProps) {
  const tx = useSharedValue(0);
  const ty = useSharedValue(0);
  const scale = useSharedValue(0.3);
  const rot = useSharedValue(0);
  const opacity = useSharedValue(0);

  useEffect(() => {
    const animate = () => {
      tx.value = 0;
      ty.value = 0;
      scale.value = 0.3;
      rot.value = 0;
      opacity.value = 0;

      const d = 3500;
      tx.value = withDelay(delay, withTiming(endTx, { duration: d, easing: Easing.out(Easing.cubic) }));
      ty.value = withDelay(delay, withTiming(endTy, { duration: d, easing: Easing.out(Easing.cubic) }));
      scale.value = withDelay(delay, withTiming(1, { duration: d, easing: Easing.out(Easing.cubic) }));
      rot.value = withDelay(delay, withTiming(endRotation, { duration: d, easing: Easing.out(Easing.cubic) }));
      opacity.value = withDelay(
        delay,
        withSequence(
          withTiming(1, { duration: d * 0.1 }),
          withTiming(0.7, { duration: d * 0.7 }),
          withTiming(0, { duration: d * 0.2 })
        )
      );
    };

    animate();
    const interval = setInterval(animate, 3500);
    return () => clearInterval(interval);
  }, [delay, endTx, endTy, endRotation, tx, ty, scale, rot, opacity]);

  const animStyle = useAnimatedStyle(() => ({
    transform: [
      { translateX: tx.value },
      { translateY: ty.value },
      { scale: scale.value },
      { rotate: `${rot.value}deg` },
    ],
    opacity: opacity.value,
  }));

  const center = containerSize / 2;

  if (shape === 'star') {
    return (
      <Animated.Text
        style={[
          {
            position: 'absolute',
            left: center - 8,
            top: center - 8,
            color,
            fontSize: 14,
            fontWeight: '900',
            textShadowColor: color,
            textShadowOffset: { width: 0, height: 0 },
            textShadowRadius: 8,
          },
          animStyle,
        ]}
      >
        ★
      </Animated.Text>
    );
  }

  if (shape === 'streamer') {
    return (
      <Animated.View
        style={[
          {
            position: 'absolute',
            left: center - 1.5,
            top: center - 6,
            width: 3,
            height: 12,
            borderRadius: 2,
            backgroundColor: color,
          },
          animStyle,
        ]}
      />
    );
  }

  return (
    <Animated.View
      style={[
        {
          position: 'absolute',
          left: center - 3.5,
          top: center - 3.5,
          width: 7,
          height: 7,
          borderRadius: 3.5,
          backgroundColor: color,
          shadowColor: color,
          shadowOpacity: 0.8,
          shadowRadius: 6,
          shadowOffset: { width: 0, height: 0 },
        },
        animStyle,
      ]}
    />
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// HELPER: InnerSpark
// ─────────────────────────────────────────────────────────────────────────────

interface SparkProps {
  x: number;
  y: number;
  color: string;
  symbol?: string;
  fontSize?: number;
  delay?: number;
  containerSize: number;
}

function InnerSpark({ x, y, color, symbol = '✦', fontSize = 12, delay = 0, containerSize }: SparkProps) {
  const scale = useSharedValue(0);
  const opacity = useSharedValue(0);

  useEffect(() => {
    const animate = () => {
      scale.value = 0;
      opacity.value = 0;
      const d = 2500;
      scale.value = withDelay(
        delay,
        withSequence(
          withTiming(1.2, { duration: d * 0.25, easing: Easing.out(Easing.quad) }),
          withTiming(0.4, { duration: d * 0.75, easing: Easing.in(Easing.quad) })
        )
      );
      opacity.value = withDelay(
        delay,
        withSequence(
          withTiming(1, { duration: d * 0.25 }),
          withTiming(0.5, { duration: d * 0.35 }),
          withTiming(0, { duration: d * 0.4 })
        )
      );
    };

    animate();
    const interval = setInterval(animate, 2500);
    return () => clearInterval(interval);
  }, [delay, scale, opacity]);

  const animStyle = useAnimatedStyle(() => ({
    transform: [{ scale: scale.value }],
    opacity: opacity.value,
  }));

  return (
    <Animated.Text
      style={[
        {
          position: 'absolute',
          left: (x / 100) * containerSize - fontSize / 2,
          top: (y / 100) * containerSize - fontSize / 2,
          color,
          fontSize,
          fontWeight: '900',
          textShadowColor: color,
          textShadowOffset: { width: 0, height: 0 },
          textShadowRadius: 8,
        },
        animStyle,
      ]}
    >
      {symbol}
    </Animated.Text>
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// HELPER: CoffeeCupSvg
// ─────────────────────────────────────────────────────────────────────────────

function CoffeeCupSvg({ size, color }: { size: number; color: string }) {
  return (
    <Svg width={size} height={size} viewBox="0 0 24 24">
      <Path
        d="M17 8h1a4 4 0 1 1 0 8h-1"
        stroke={color}
        strokeWidth={1.5}
        fill="none"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
      <Path
        d="M3 8h14v9a4 4 0 0 1-4 4H7a4 4 0 0 1-4-4Z"
        stroke={color}
        strokeWidth={1.5}
        fill={color.replace('0.85', '0.18')}
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </Svg>
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// HELPER: PinPulse
// ─────────────────────────────────────────────────────────────────────────────

function PinPulse({ size, rgb }: { size: number; rgb: string }) {
  const scale = useSharedValue(0.85);
  const opacity = useSharedValue(0.6);

  useEffect(() => {
    scale.value = withRepeat(
      withSequence(
        withTiming(1.15, { duration: 1750, easing: Easing.inOut(Easing.quad) }),
        withTiming(0.85, { duration: 1750, easing: Easing.inOut(Easing.quad) })
      ),
      -1,
      false
    );
    opacity.value = withRepeat(
      withSequence(
        withTiming(1, { duration: 1750 }),
        withTiming(0.6, { duration: 1750 })
      ),
      -1,
      false
    );
  }, [scale, opacity]);

  const animStyle = useAnimatedStyle(() => ({
    transform: [{ scale: scale.value }],
    opacity: opacity.value,
  }));

  const orbSize = size * 0.5;

  return (
    <Animated.View
      style={[
        {
          position: 'absolute',
          width: orbSize,
          height: orbSize,
          top: (size - orbSize) / 2,
          left: (size - orbSize) / 2,
        },
        animStyle,
      ]}
    >
      <Svg width="100%" height="100%" viewBox={`0 0 ${orbSize} ${orbSize}`}>
        <Defs>
          <SvgRadialGradient id="pinGrad" cx="50%" cy="50%" r="50%">
            <Stop offset="0%" stopColor={`rgb(${rgb})`} stopOpacity={0.2} />
            <Stop offset="70%" stopColor={`rgb(${rgb})`} stopOpacity={0} />
          </SvgRadialGradient>
        </Defs>
        <Circle cx={orbSize / 2} cy={orbSize / 2} r={orbSize / 2} fill="url(#pinGrad)" />
      </Svg>
    </Animated.View>
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// MAIN COMPONENT
// ─────────────────────────────────────────────────────────────────────────────

export function CircleTimerVisual({
  state,
  currentTime,
  label,
  subtitle,
  progress,
  size = DEFAULT_SIZE,
  extraAmount,
}: CircleTimerVisualProps) {
  const palette = PALETTES[state];

  const defaultLabel: Record<TimerState, string> = {
    pre_event: 'Llegada en',
    live: 'Tocando',
    break: 'Descanso',
    extra_hours: 'Hora Extra',
    completed: '¡Completado!',
  };

  const finalLabel = label || defaultLabel[state];
  const finalProgress =
    progress !== undefined
      ? progress
      : state === 'completed'
        ? 1
        : state === 'pre_event'
          ? 0
          : 0.5;

  return (
    <View pointerEvents="box-none" style={[styles.container, { width: size, height: size }]}>
      {renderStateEffects(state, palette, size)}

      <View style={styles.ringWrapper}>
        <RingProgress
          size={size}
          accent={palette.accent}
          progress={finalProgress}
          dashed={state === 'pre_event'}
        />
      </View>

      {state === 'break' && (
        <View
          style={{
            position: 'absolute',
            top: '68%',
            left: 0,
            right: 0,
            alignItems: 'center',
            zIndex: 5,
          }}
          pointerEvents="none"
        >
          <CoffeeCupSvg size={Math.min(size * 0.10, 30)} color={`rgba(${palette.rgb}, 0.85)`} />
        </View>
      )}

      {state === 'break' && renderSteam(size, palette.rgb, size * 0.68)}
      {state === 'completed' && renderConfetti(size)}
      {state === 'completed' && renderInnerSparks(size)}
      {state === 'live' && renderLiveNotes(size, palette.accent)}
      {state === 'extra_hours' && renderCoins(size, palette.accent)}

      <View
        style={styles.centerText}
        pointerEvents="none"
      >
        <Text
          style={[
            styles.label,
            { color: state === 'pre_event' ? `rgba(${palette.rgb}, 0.75)` : 'rgba(255,255,255,0.6)' },
          ]}
        >
          {finalLabel.toUpperCase()}
        </Text>
        {state !== 'pre_event' && (
          <Text
            numberOfLines={1}
            adjustsFontSizeToFit
            minimumFontScale={0.7}
            style={[
              styles.time,
              state === 'extra_hours' && { color: palette.accent },
              state === 'completed' && { color: '#fff' },
            ]}
          >
            {currentTime}
          </Text>
        )}
        {subtitle && (
          <Text
            style={[
              styles.subtitle,
              state === 'extra_hours' && extraAmount ? { color: palette.accent, fontWeight: '600' } : undefined,
            ]}
          >
            {state === 'extra_hours' && extraAmount ? extraAmount : subtitle}
          </Text>
        )}
      </View>
    </View>
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// RENDER HELPERS POR ESTADO
// ─────────────────────────────────────────────────────────────────────────────

function renderStateEffects(
  state: TimerState,
  palette: { accent: string; rgb: string },
  size: number
) {
  switch (state) {
    case 'pre_event':
      return <PinPulse size={size} rgb={palette.rgb} />;

    case 'live':
      return (
        <>
          <PulsatingWave size={size} color={`rgba(${palette.rgb}, 0.85)`} delay={0} duration={4200} startOpacity={0.8} />
          <PulsatingWave size={size} color={`rgba(${palette.rgb}, 0.85)`} delay={1400} duration={4200} startOpacity={0.8} />
          <PulsatingWave size={size} color={`rgba(${palette.rgb}, 0.85)`} delay={2800} duration={4200} startOpacity={0.8} />
          <View style={styles.absoluteCenter} pointerEvents="none">
            <BreathingOrb size={size * 0.56} rgb={palette.rgb} duration={3500} centerOpacity={0.22} />
          </View>
        </>
      );

    case 'break':
      return (
        <>
          <PulsatingWave size={size} color={`rgba(${palette.rgb}, 0.7)`} borderWidth={1.5} delay={0} duration={6000} startOpacity={0.6} endScale={1.18} />
          <PulsatingWave size={size} color={`rgba(${palette.rgb}, 0.7)`} borderWidth={1.5} delay={3000} duration={6000} startOpacity={0.6} endScale={1.18} />
          <View style={styles.absoluteCenter} pointerEvents="none">
            <BreathingOrb size={size * 0.56} rgb={palette.rgb} duration={5000} centerOpacity={0.22} scaleMax={1.06} />
          </View>
        </>
      );

    case 'extra_hours':
      return (
        <>
          <PulsatingWave size={size} color={`rgba(${palette.rgb}, 0.85)`} delay={0} duration={3500} startOpacity={0.85} endScale={1.28} />
          <PulsatingWave size={size} color={`rgba(${palette.rgb}, 0.85)`} delay={1200} duration={3500} startOpacity={0.85} endScale={1.28} />
          <PulsatingWave size={size} color={`rgba(${palette.rgb}, 0.85)`} delay={2400} duration={3500} startOpacity={0.85} endScale={1.28} />
          <View style={styles.absoluteCenter} pointerEvents="none">
            <BreathingOrb size={size * 0.56} rgb={palette.rgb} duration={2500} centerOpacity={0.3} scaleMax={1.12} />
          </View>
        </>
      );

    case 'completed':
      return (
        <View style={styles.absoluteCenter} pointerEvents="none">
          <BreathingOrb size={size * 0.625} rgb={palette.rgb} duration={1800} centerOpacity={0.35} scaleMin={0.95} scaleMax={1.15} />
        </View>
      );
  }
}

function renderLiveNotes(size: number, color: string) {
  const notes: { sym: string; x: number; y: number; fs: number; tx: number; ty: number; rot: number; delay: number }[] = [
    { sym: '♪', x: 50, y: 8,  fs: 14, tx: 0,   ty: -50, rot: -15, delay: 0 },
    { sym: '♫', x: 78, y: 18, fs: 13, tx: 38,  ty: -38, rot: 20,  delay: 500 },
    { sym: '♬', x: 92, y: 50, fs: 12, tx: 48,  ty: 0,   rot: -8,  delay: 1000 },
    { sym: '♪', x: 78, y: 82, fs: 13, tx: 38,  ty: 42,  rot: 25,  delay: 1500 },
    { sym: '♩', x: 50, y: 90, fs: 12, tx: 0,   ty: 50,  rot: -20, delay: 2000 },
    { sym: '♬', x: 22, y: 82, fs: 13, tx: -38, ty: 42,  rot: -25, delay: 2500 },
    { sym: '♪', x: 8,  y: 50, fs: 12, tx: -48, ty: 0,   rot: 18,  delay: 3000 },
    { sym: '♫', x: 22, y: 18, fs: 14, tx: -38, ty: -38, rot: 22,  delay: 3500 },
  ];

  return (
    <>
      {notes.map((n, i) => (
        <FlyingParticle
          key={`note-${i}`}
          symbol={n.sym}
          color={color}
          fontSize={n.fs}
          startX={n.x}
          startY={n.y}
          containerSize={size}
          endTx={n.tx}
          endTy={n.ty}
          endRotation={n.rot}
          delay={n.delay}
          duration={5000}
        />
      ))}
    </>
  );
}

function renderCoins(size: number, color: string) {
  const coins: { x: number; y: number; tx: number; ty: number; delay: number }[] = [
    { x: 32, y: 22, tx: -22, ty: -38, delay: 0 },
    { x: 62, y: 25, tx: 26,  ty: -42, delay: 600 },
    { x: 80, y: 55, tx: 38,  ty: -8,  delay: 1200 },
    { x: 66, y: 75, tx: 28,  ty: 32,  delay: 1800 },
    { x: 38, y: 78, tx: -25, ty: 38,  delay: 2400 },
    { x: 18, y: 55, tx: -38, ty: -8,  delay: 3000 },
  ];

  return (
    <>
      {coins.map((c, i) => (
        <FlyingParticle
          key={`coin-${i}`}
          symbol="$"
          color={color}
          fontSize={16}
          startX={c.x}
          startY={c.y}
          containerSize={size}
          endTx={c.tx}
          endTy={c.ty}
          endRotation={360}
          delay={c.delay}
          duration={4000}
          fontWeight="700"
        />
      ))}
    </>
  );
}

function renderSteam(size: number, rgb: string, cupTopY?: number) {
  const center = size / 2;
  const baseY = cupTopY ?? (center - 5);
  const steams: { sx: number; sy: number; tx: number; ty: number; delay: number }[] = [
    { sx: center - 12, sy: baseY, tx: -8, ty: -75, delay: 0 },
    { sx: center,      sy: baseY, tx: 4,  ty: -85, delay: 1500 },
    { sx: center + 12, sy: baseY, tx: 10, ty: -70, delay: 3000 },
    { sx: center - 6,  sy: baseY, tx: -3, ty: -80, delay: 4500 },
  ];

  return (
    <>
      {steams.map((s, i) => (
        <SteamParticle
          key={`steam-${i}`}
          startX={s.sx}
          startY={s.sy}
          endTx={s.tx}
          endTy={s.ty}
          delay={s.delay}
          rgb={rgb}
        />
      ))}
    </>
  );
}

function renderConfetti(size: number) {
  const confettis: {
    shape: 'dot' | 'streamer' | 'star';
    color: string;
    tx: number;
    ty: number;
    rot: number;
    delay: number;
  }[] = [
    { shape: 'dot',      color: '#00E676', tx: -65, ty: -72, rot: 540,  delay: 0 },
    { shape: 'streamer', color: '#FFFFFF', tx: 70,  ty: -68, rot: -480, delay: 180 },
    { shape: 'star',     color: '#FBBF24', tx: 78,  ty: 36,  rot: 420,  delay: 360 },
    { shape: 'dot',      color: '#60A5FA', tx: -62, ty: 60,  rot: -540, delay: 540 },
    { shape: 'streamer', color: '#00E676', tx: 4,   ty: -80, rot: 360,  delay: 720 },
    { shape: 'dot',      color: '#FFFFFF', tx: 46,  ty: -72, rot: -360, delay: 900 },
    { shape: 'star',     color: '#FBBF24', tx: -72, ty: -38, rot: 480,  delay: 1080 },
    { shape: 'streamer', color: '#60A5FA', tx: 58,  ty: 72,  rot: -420, delay: 1260 },
    { shape: 'dot',      color: '#00E676', tx: -56, ty: 78,  rot: 540,  delay: 1440 },
    { shape: 'star',     color: '#FFFFFF', tx: 80,  ty: -8,  rot: 360,  delay: 1620 },
    { shape: 'streamer', color: '#FBBF24', tx: -78, ty: 14,  rot: -480, delay: 1800 },
    { shape: 'dot',      color: '#60A5FA', tx: 22,  ty: 80,  rot: 420,  delay: 1980 },
  ];

  return (
    <>
      {confettis.map((c, i) => (
        <ConfettiPiece
          key={`confetti-${i}`}
          shape={c.shape}
          color={c.color}
          endTx={c.tx}
          endTy={c.ty}
          endRotation={c.rot}
          delay={c.delay}
          containerSize={size}
        />
      ))}
    </>
  );
}

function renderInnerSparks(size: number) {
  const sparks: { x: number; y: number; color: string; delay: number; fs?: number }[] = [
    { x: 38, y: 32, color: '#FBBF24', delay: 0 },
    { x: 60, y: 30, color: '#FFFFFF', delay: 500 },
    { x: 35, y: 65, color: '#00E676', delay: 1000 },
    { x: 64, y: 68, color: '#FBBF24', delay: 1500 },
    { x: 50, y: 50, color: '#FFFFFF', delay: 2000, fs: 10 },
  ];

  return (
    <>
      {sparks.map((s, i) => (
        <InnerSpark
          key={`spark-${i}`}
          x={s.x}
          y={s.y}
          color={s.color}
          delay={s.delay}
          fontSize={s.fs}
          containerSize={size}
        />
      ))}
    </>
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// STYLES
// ─────────────────────────────────────────────────────────────────────────────

const styles = StyleSheet.create({
  container: {
    position: 'relative',
    alignSelf: 'center',
    alignItems: 'center',
    justifyContent: 'center',
  },
  ringWrapper: {
    position: 'absolute',
    top: 0, left: 0,
    width: '100%', height: '100%',
    zIndex: 3,
  },
  waveAbsolute: {
    position: 'absolute',
    top: 0, left: 0,
  },
  absoluteCenter: {
    position: 'absolute',
    top: '50%',
    left: '50%',
    transform: [{ translateX: -1 }, { translateY: -1 }],
    alignItems: 'center',
    justifyContent: 'center',
    zIndex: 2,
  },
  centerText: {
    position: 'absolute',
    top: '50%',
    left: '50%',
    transform: [{ translateX: -100 }, { translateY: -60 }],
    width: 200,
    alignItems: 'center',
    justifyContent: 'center',
    zIndex: 6,
  },
  label: {
    fontSize: 10,
    letterSpacing: 4,
    textTransform: 'uppercase',
    marginBottom: 12,
    fontWeight: '500',
    textShadowColor: 'rgba(0,0,0,0.7)',
    textShadowOffset: { width: 0, height: 0 },
    textShadowRadius: 12,
    textAlign: 'center',
  },
  time: {
    fontFamily: 'Syne_800ExtraBold',
    fontSize: 46,
    fontWeight: '700',
    letterSpacing: -2,
    color: '#fff',
    lineHeight: 46,
    textShadowColor: 'rgba(0,0,0,1)',
    textShadowOffset: { width: 0, height: 2 },
    textShadowRadius: 18,
    textAlign: 'center',
    includeFontPadding: false,
  },
  subtitle: {
    fontSize: 12,
    color: 'rgba(255,255,255,0.65)',
    marginTop: 14,
    letterSpacing: 0.3,
    fontWeight: '400',
    textShadowColor: 'rgba(0,0,0,0.7)',
    textShadowOffset: { width: 0, height: 0 },
    textShadowRadius: 12,
    textAlign: 'center',
  },
});

export default CircleTimerVisual;
