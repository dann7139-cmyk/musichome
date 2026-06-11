import { useEffect, useState } from 'react';
import { AccessibilityInfo } from 'react-native';

// expo-battery may not be installed; require gracefully so the hook
// still works without it, and enables low-power detection once installed.
let Battery: any = null;
try { Battery = require('expo-battery'); } catch {}

export interface MotionPrefs {
  isLowPower:     boolean; // battery saver / low-power mode
  isReduceMotion: boolean; // accessibility: prefers-reduced-motion
}

export function useMotionPrefs(): MotionPrefs {
  const [isLowPower,     setIsLowPower]     = useState(false);
  const [isReduceMotion, setIsReduceMotion] = useState(false);

  useEffect(() => {
    AccessibilityInfo.isReduceMotionEnabled().then(setIsReduceMotion);
    const sub = AccessibilityInfo.addEventListener('reduceMotionChanged', setIsReduceMotion);
    return () => sub.remove();
  }, []);

  useEffect(() => {
    if (!Battery) return;
    Battery.getPowerStateAsync?.()
      .then((s: any) => setIsLowPower(s?.lowPowerMode ?? false))
      .catch(() => {});
    const sub = Battery.addLowPowerModeListener?.((s: any) => {
      setIsLowPower(s?.lowPowerMode ?? false);
    });
    return () => sub?.remove?.();
  }, []);

  return { isLowPower, isReduceMotion };
}
