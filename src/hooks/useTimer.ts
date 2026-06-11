import { useEffect, useRef, useState } from 'react';

interface TimerState {
  elapsed: number;       // segundos transcurridos
  remaining: number;     // segundos restantes
  progress: number;      // 0-100
  displayElapsed: string;
  displayRemaining: string;
  isRunning: boolean;
  isBreak: boolean;
}

export function useTimer(totalSeconds: number, startTime?: Date) {
  const intervalRef = useRef<ReturnType<typeof setInterval> | null>(null);
  const [state, setState] = useState<TimerState>({
    elapsed: 0,
    remaining: totalSeconds,
    progress: 0,
    displayElapsed: '0:00:00',
    displayRemaining: formatSeconds(totalSeconds),
    isRunning: false,
    isBreak: false,
  });

  const format = (secs: number) => formatSeconds(secs);

  useEffect(() => {
    if (!startTime) return;

    const tick = () => {
      const now = new Date();
      const elapsed = Math.floor((now.getTime() - startTime.getTime()) / 1000);
      const remaining = Math.max(0, totalSeconds - elapsed);
      const progress = Math.min(100, (elapsed / totalSeconds) * 100);

      setState({
        elapsed,
        remaining,
        progress,
        displayElapsed: format(elapsed),
        displayRemaining: format(remaining),
        isRunning: remaining > 0,
        isBreak: false,
      });

      if (remaining <= 0 && intervalRef.current) {
        clearInterval(intervalRef.current);
      }
    };

    tick();
    intervalRef.current = setInterval(tick, 1000);

    return () => {
      if (intervalRef.current) clearInterval(intervalRef.current);
    };
  }, [startTime, totalSeconds]);

  return state;
}

function formatSeconds(secs: number): string {
  const h = Math.floor(secs / 3600);
  const m = Math.floor((secs % 3600) / 60);
  const s = secs % 60;
  return `${h}:${String(m).padStart(2, '0')}:${String(s).padStart(2, '0')}`;
}
