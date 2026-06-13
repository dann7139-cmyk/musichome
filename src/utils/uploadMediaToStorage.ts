/**
 * Subida de media a Supabase Storage en STREAMING (expo-file-system).
 *
 * El patrón viejo — fetch(uri).arrayBuffer() + supabase.storage.upload() —
 * carga el archivo COMPLETO a memoria JS antes de mandarlo. Con videos de
 * decenas de MB eso tarda y truena (OOM / timeout). uploadAsync sube
 * directo desde disco en chunks nativos: rápido y estable.
 *
 * Límite de Supabase Storage: 50 MB por archivo (default del proyecto).
 * Validar tamaño ANTES de subir para dar un error claro al usuario.
 */
import * as FileSystem from 'expo-file-system/legacy';
import { supabase, supabaseAnonKey, supabaseUrl } from '../config/supabase';

export const MAX_VIDEO_MB = 50;
export const MAX_IMAGE_MB = 10;

/** Valida el tamaño del asset (bytes). Retorna mensaje de error o null si pasa. */
export function checkMediaSize(fileSize: number | undefined, isVideo: boolean): string | null {
  if (!fileSize) return null; // sin dato → dejar pasar, el server valida
  const mb    = fileSize / (1024 * 1024);
  const maxMb = isVideo ? MAX_VIDEO_MB : MAX_IMAGE_MB;
  if (mb > maxMb) {
    return isVideo
      ? `El video pesa ${mb.toFixed(0)} MB y el máximo es ${maxMb} MB. Usa un video más corto o de menor calidad.`
      : `La imagen pesa ${mb.toFixed(0)} MB y el máximo es ${maxMb} MB.`;
  }
  return null;
}

/**
 * Sube un archivo local a Storage en streaming con progreso real.
 * Retorna la URL pública.
 */
export async function uploadMediaToStorage(opts: {
  bucket: string;
  path: string;
  uri: string;
  contentType: string;
  /** Callback 0-100 — para mostrar "Subiendo… 43%" */
  onProgress?: (pct: number) => void;
}): Promise<string> {
  const { data: sd } = await supabase.auth.getSession();
  const token = sd.session?.access_token;
  if (!token) throw new Error('Sin sesión activa.');

  const task = FileSystem.createUploadTask(
    `${supabaseUrl}/storage/v1/object/${opts.bucket}/${opts.path}`,
    opts.uri,
    {
      httpMethod: 'POST',
      headers: {
        Authorization: `Bearer ${token}`,
        apikey: supabaseAnonKey,
        'Content-Type': opts.contentType,
        'x-upsert': 'true',
      },
      uploadType: FileSystem.FileSystemUploadType.BINARY_CONTENT,
    },
    (p) => {
      if (p.totalBytesExpectedToSend > 0) {
        opts.onProgress?.(
          Math.min(100, Math.round((p.totalBytesSent / p.totalBytesExpectedToSend) * 100)),
        );
      }
    },
  );

  const res = await task.uploadAsync();
  if (!res) throw new Error('Subida cancelada.');

  if (res.status < 200 || res.status >= 300) {
    // Mensajes comunes: 413 = excede límite del bucket; 403 = policy
    const hint = res.status === 413
      ? 'El archivo excede el límite del servidor.'
      : res.status === 403
        ? 'Sin permiso para subir a este bucket.'
        : (res.body ?? '').slice(0, 160);
    throw new Error(`No se pudo subir (${res.status}). ${hint}`);
  }

  const { data } = supabase.storage.from(opts.bucket).getPublicUrl(opts.path);
  return data.publicUrl;
}
