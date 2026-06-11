import { Audio } from 'expo-av';

// ── Sound singletons ─────────────────────────────────────────────────────────
let dispatchSnd:  Audio.Sound | null = null;
let takenSnd:     Audio.Sound | null = null;
let quotedSnd:    Audio.Sound | null = null;
let criticalSnd:  Audio.Sound | null = null;
let queueSnd:     Audio.Sound | null = null;

// Anti-fatigue: dispatch sound silenced if played within last 90 s
let lastDispatchAt = 0;
const DISPATCH_COOLDOWN = 90_000;

async function createSnd(source: number): Promise<Audio.Sound | null> {
  try {
    const { sound } = await Audio.Sound.createAsync(source, {
      shouldPlay: false,
      volume: 0.85,
    });
    return sound;
  } catch {
    return null;
  }
}

// ── Lifecycle ─────────────────────────────────────────────────────────────────

export async function loadExpressSounds(): Promise<void> {
  try {
    await Audio.setAudioModeAsync({
      playsInSilentModeIOS: false,   // respects iOS silent switch
      staysActiveInBackground: false,
    });
  } catch {}

  [dispatchSnd, takenSnd, quotedSnd, criticalSnd, queueSnd] = await Promise.all([
    createSnd(require('../../assets/sounds/express_dispatch.wav')),
    createSnd(require('../../assets/sounds/taken.wav')),
    createSnd(require('../../assets/sounds/quoted.wav')),
    createSnd(require('../../assets/sounds/countdown_critical.wav')),
    createSnd(require('../../assets/sounds/queue_badge.wav')),
  ]);
}

export async function unloadExpressSounds(): Promise<void> {
  await Promise.allSettled([
    dispatchSnd?.unloadAsync(),
    takenSnd?.unloadAsync(),
    quotedSnd?.unloadAsync(),
    criticalSnd?.unloadAsync(),
    queueSnd?.unloadAsync(),
  ]);
  dispatchSnd = takenSnd = quotedSnd = criticalSnd = queueSnd = null;
}

// ── Play helpers (all fire-and-forget, never throw) ───────────────────────────

export function playDispatchSound(): void {
  const now = Date.now();
  if (now - lastDispatchAt < DISPATCH_COOLDOWN) return;
  lastDispatchAt = now;
  dispatchSnd?.replayAsync().catch(() => {});
}

export function playTakenSound():   void { takenSnd?.replayAsync().catch(() => {}); }
export function playQuotedSound():  void { quotedSnd?.replayAsync().catch(() => {}); }
export function playCriticalTick(): void { criticalSnd?.replayAsync().catch(() => {}); }
export function playQueueBadge():   void { queueSnd?.replayAsync().catch(() => {}); }
