/**
 * videoCodecCheck.ts — detecta HEVC/H.265 en un video local ANTES de subirlo.
 *
 * Motivo real (2026-09-02): un anuncio activo ("síguenos") tenía un video
 * .mov de iPhone grabado en HEVC — muchos Android no lo pueden decodificar
 * con expo-video/ExoPlayer, así que a los clientes les aparecía en rojo
 * "No se pudo cargar el video" en vez del anuncio. El aviso que ya existía
 * (por extensión .mov) no habría atrapado este caso si el mismo video
 * hubiera venido en un .mp4 — HEVC puede venir en cualquiera de los dos
 * contenedores. Esto revisa el CÓDEC real, no la extensión.
 *
 * Cómo: los contenedores MP4/MOV guardan el códec de video como un FourCC
 * de 4 letras ASCII dentro de la caja `stsd` ('hvc1'/'hev1' = HEVC,
 * 'avc1'/'avc3' = H.264). En vez de parsear el árbol completo de cajas
 * (frágil — un contenedor atípico podría tronar el parser y bloquear
 * subidas válidas), se busca ese FourCC como substring de bytes en los
 * primeros ~6MB y últimos ~2MB del archivo (la caja `moov` que lo contiene
 * puede quedar al inicio o al final según cómo se grabó/editó el video).
 *
 * SIEMPRE devuelve `false` si algo falla (archivo no legible, formato
 * raro, etc.) — es un aviso extra, JAMÁS debe impedir una subida válida.
 */
import * as FileSystem from 'expo-file-system/legacy';

const HEVC_MARKERS = ['hvc1', 'hev1'];
const HEAD_BYTES = 6 * 1024 * 1024;
const TAIL_BYTES = 2 * 1024 * 1024;

/** Decodificador base64 → bytes, sin dependencias (no asume `atob` global). */
function base64ToBytes(b64: string): Uint8Array {
  const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  const lookup = new Int16Array(128).fill(-1);
  for (let i = 0; i < chars.length; i++) lookup[chars.charCodeAt(i)] = i;

  const clean = b64.replace(/[^A-Za-z0-9+/]/g, '');
  const byteLength = Math.floor((clean.length * 3) / 4);
  const bytes = new Uint8Array(byteLength);
  let p = 0;
  for (let i = 0; i < clean.length; i += 4) {
    const c0 = lookup[clean.charCodeAt(i)] ?? 0;
    const c1 = lookup[clean.charCodeAt(i + 1)] ?? 0;
    const c2 = i + 2 < clean.length ? lookup[clean.charCodeAt(i + 2)] : -1;
    const c3 = i + 3 < clean.length ? lookup[clean.charCodeAt(i + 3)] : -1;
    if (p < byteLength) bytes[p++] = (c0 << 2) | (c1 >> 4);
    if (c2 >= 0 && p < byteLength) bytes[p++] = ((c1 & 0xf) << 4) | (c2 >> 2);
    if (c3 >= 0 && p < byteLength) bytes[p++] = ((c2 & 0x3) << 6) | c3;
  }
  return bytes;
}

function containsAsciiMarker(bytes: Uint8Array, marker: string): boolean {
  const m = marker.split('').map(c => c.charCodeAt(0));
  outer: for (let i = 0; i <= bytes.length - m.length; i++) {
    for (let j = 0; j < m.length; j++) {
      if (bytes[i + j] !== m[j]) continue outer;
    }
    return true;
  }
  return false;
}

/**
 * Revisa un video local en busca de HEVC. `fileSizeBytes` es opcional —
 * si no se conoce, solo revisa el inicio del archivo.
 */
export async function looksLikeHevc(uri: string, fileSizeBytes?: number): Promise<boolean> {
  try {
    const head = await FileSystem.readAsStringAsync(uri, {
      encoding: FileSystem.EncodingType.Base64,
      position: 0,
      length: HEAD_BYTES,
    } as any);
    const headBytes = base64ToBytes(head);
    if (HEVC_MARKERS.some(m => containsAsciiMarker(headBytes, m))) return true;

    if (fileSizeBytes && fileSizeBytes > HEAD_BYTES) {
      const tailLen = Math.min(TAIL_BYTES, fileSizeBytes);
      const tail = await FileSystem.readAsStringAsync(uri, {
        encoding: FileSystem.EncodingType.Base64,
        position: fileSizeBytes - tailLen,
        length: tailLen,
      } as any);
      const tailBytes = base64ToBytes(tail);
      if (HEVC_MARKERS.some(m => containsAsciiMarker(tailBytes, m))) return true;
    }
    return false;
  } catch {
    // Nunca bloquea por un fallo de lectura — solo se pierde el aviso extra.
    return false;
  }
}
