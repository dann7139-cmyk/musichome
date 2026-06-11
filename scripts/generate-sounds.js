#!/usr/bin/env node
/**
 * generate-sounds.js — Genera los 5 archivos de audio de Daricefy Express.
 *
 * Sin dependencias externas — solo Node.js puro.
 * Formato: WAV 16-bit mono 22050 Hz (compatible con expo-av en iOS y Android).
 *
 * Uso:
 *   node scripts/generate-sounds.js
 *
 * Resultado: assets/sounds/*.wav  (reemplaza los placeholders actuales)
 */

'use strict';

const fs   = require('fs');
const path = require('path');

const SAMPLE_RATE   = 22050;
const BIT_DEPTH     = 16;
const BYTES_PER_S   = BIT_DEPTH / 8;
const BYTE_RATE     = SAMPLE_RATE * BYTES_PER_S;
const BLOCK_ALIGN   = BYTES_PER_S;

// ── WAV encoder ───────────────────────────────────────────────────────────────
function encodeWav(samples) {
  const dataSize = samples.length * BYTES_PER_S;
  const buf      = Buffer.alloc(44 + dataSize);

  buf.write('RIFF', 0, 'ascii');
  buf.writeUInt32LE(36 + dataSize, 4);
  buf.write('WAVE', 8, 'ascii');

  buf.write('fmt ', 12, 'ascii');
  buf.writeUInt32LE(16, 16);
  buf.writeUInt16LE(1,  20);               // PCM
  buf.writeUInt16LE(1,  22);               // mono
  buf.writeUInt32LE(SAMPLE_RATE, 24);
  buf.writeUInt32LE(BYTE_RATE,   28);
  buf.writeUInt16LE(BLOCK_ALIGN, 32);
  buf.writeUInt16LE(BIT_DEPTH,   34);

  buf.write('data', 36, 'ascii');
  buf.writeUInt32LE(dataSize, 40);

  for (let i = 0; i < samples.length; i++) {
    const v = Math.max(-32768, Math.min(32767, Math.round(samples[i])));
    buf.writeInt16LE(v, 44 + i * 2);
  }
  return buf;
}

// ── Helpers ───────────────────────────────────────────────────────────────────
function sine(freq, t) {
  return Math.sin(2 * Math.PI * freq * t);
}

// Amplitude envelope: fade-in / sustain / fade-out
function env(t, dur, fadeIn = 0.008, fadeOut = 0.04) {
  if (t < fadeIn)           return t / fadeIn;
  if (t > dur - fadeOut)    return (dur - t) / fadeOut;
  return 1;
}

function generate(durationSec, fn) {
  const n       = Math.ceil(SAMPLE_RATE * durationSec);
  const samples = new Float32Array(n);
  for (let i = 0; i < n; i++) {
    samples[i] = fn(i / SAMPLE_RATE, durationSec) * 32767;
  }
  return samples;
}

const out = path.join(__dirname, '..', 'assets', 'sounds');
fs.mkdirSync(out, { recursive: true });

function write(filename, samples) {
  fs.writeFileSync(path.join(out, filename), encodeWav(samples));
  console.log('✓', filename);
}

// ── 1. express_dispatch.wav ───────────────────────────────────────────────────
// Sub-bass thump (60Hz, 0–80ms) + metallic spark (2500Hz, 80–230ms)
// + ascending sweep (800→2400Hz, 200–480ms).
write('express_dispatch.wav', generate(0.48, (t) => {
  let s = 0;

  // Layer 1: sub-bass thump
  if (t < 0.08)
    s += sine(60, t) * Math.exp(-t * 22) * 0.65;

  // Layer 2: metallic spark
  if (t >= 0.08 && t < 0.23)
    s += sine(2500, t) * Math.exp(-(t - 0.08) * 20) * 0.38;

  // Layer 3: sweep (quadratic frequency rise)
  if (t >= 0.20) {
    const p    = (t - 0.20) / 0.28;
    const freq = 800 + (2400 - 800) * p * p;
    s += sine(freq, t) * env(t - 0.20, 0.28, 0.01, 0.09) * 0.52;
  }

  return s * 0.85;
}));

// ── 2. taken.wav ─────────────────────────────────────────────────────────────
// Descending sine 440→220 Hz, 300ms — "se cerró una puerta".
write('taken.wav', generate(0.30, (t, dur) =>
  sine(440 - (440 - 220) * (t / dur), t)
  * env(t, dur, 0.004, 0.07) * 0.62
));

// ── 3. quoted.wav ────────────────────────────────────────────────────────────
// Acorde mayor ascendente C5–E5–G5, notas solapadas, 600ms.
// Cada nota entra 150ms después de la anterior.
write('quoted.wav', generate(0.60, (t) => {
  const notes = [
    { freq: 523.25, start: 0.00, end: 0.32 },  // C5
    { freq: 659.25, start: 0.15, end: 0.45 },  // E5
    { freq: 783.99, start: 0.30, end: 0.60 },  // G5
  ];
  let s = 0;
  for (const { freq, start, end } of notes) {
    if (t >= start && t <= end) {
      const lt = t - start;
      const ld = end - start;
      s += (sine(freq, t) * 0.55 + sine(freq * 2, t) * 0.12) * env(lt, ld, 0.01, 0.07);
    }
  }
  return s * 0.72;
}));

// ── 4. countdown_critical.wav ────────────────────────────────────────────────
// Click seco, 800 Hz, 40ms — sin reverb, máxima limpieza.
write('countdown_critical.wav', generate(0.04, (t, dur) =>
  sine(800, t) * env(t, dur, 0.002, 0.012) * 0.55
));

// ── 5. queue_badge.wav ───────────────────────────────────────────────────────
// Click muy suave, 200 Hz, 80ms — apenas perceptible.
write('queue_badge.wav', generate(0.08, (t, dur) =>
  sine(200, t) * env(t, dur, 0.005, 0.025) * 0.28
));

console.log(`\nArchivos escritos en ${out}`);
console.log('Ejecuta la app para probar el audio.');
