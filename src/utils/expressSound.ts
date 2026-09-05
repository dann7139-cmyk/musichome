import { createAudioPlayer, setAudioModeAsync, type AudioPlayer } from 'expo-audio';

// ── Sound singletons ─────────────────────────────────────────────────────────
let dispatchSnd:  AudioPlayer | null = null;
let takenSnd:     AudioPlayer | null = null;
let quotedSnd:    AudioPlayer | null = null;
let criticalSnd:  AudioPlayer | null = null;
let queueSnd:     AudioPlayer | null = null;

// Anti-fatigue: dispatch sound silenced if played within last 90 s
let lastDispatchAt = 0;
const DISPATCH_COOLDOWN = 90_000;

function createSnd(source: number): AudioPlayer | null {
  try {
    const player = createAudioPlayer(source);
    player.volume = 0.85;
    return player;
  } catch {
    return null;
  }
}

// ── Lifecycle ─────────────────────────────────────────────────────────────────

export async function loadExpressSounds(): Promise<void> {
  try {
    await setAudioModeAsync({
      playsInSilentMode: false,   // respects iOS silent switch
      shouldPlayInBackground: false,
    });
  } catch {}

  // sql/expo-audio (migración desde expo-av, SDK 57 — createAudioPlayer es
  // síncrono, ya no hace falta Promise.all con createAsync)
  dispatchSnd = createSnd(require('../../assets/sounds/express_dispatch.wav'));
  takenSnd    = createSnd(require('../../assets/sounds/taken.wav'));
  quotedSnd   = createSnd(require('../../assets/sounds/quoted.wav'));
  criticalSnd = createSnd(require('../../assets/sounds/countdown_critical.wav'));
  queueSnd    = createSnd(require('../../assets/sounds/queue_badge.wav'));
}

export async function unloadExpressSounds(): Promise<void> {
  [dispatchSnd, takenSnd, quotedSnd, criticalSnd, queueSnd].forEach(s => {
    try { s?.remove(); } catch {}
  });
  dispatchSnd = takenSnd = quotedSnd = criticalSnd = queueSnd = null;
}

// ── Play helpers (all fire-and-forget, never throw) ───────────────────────────

// expo-audio no tiene "replayAsync" — hay que rebobinar a 0 antes de play()
// para que un sonido corto que ya terminó vuelva a sonar desde el inicio.
function replay(player: AudioPlayer | null): void {
  if (!player) return;
  player.seekTo(0).then(() => player.play()).catch(() => {});
}

export function playDispatchSound(): void {
  const now = Date.now();
  if (now - lastDispatchAt < DISPATCH_COOLDOWN) return;
  lastDispatchAt = now;
  replay(dispatchSnd);
}

export function playTakenSound():   void { replay(takenSnd); }
export function playQuotedSound():  void { replay(quotedSnd); }
export function playCriticalTick(): void { replay(criticalSnd); }
export function playQueueBadge():   void { replay(queueSnd); }
