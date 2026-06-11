/**
 * uploadAdMedia.ts
 * Validation and upload helpers for advertisement media.
 *
 * Limits:
 *   Image — JPG / PNG / WebP — max 5 MB
 *   Video — MP4             — max 20 MB, max 30 s
 */
import * as ImagePicker from 'expo-image-picker';
import { supabase } from '../config/supabase';

export const AD_IMAGE_MAX_BYTES = 5  * 1024 * 1024;   // 5 MB
export const AD_VIDEO_MAX_BYTES = 20 * 1024 * 1024;   // 20 MB
export const AD_VIDEO_MAX_MS    = 30_000;              // 30 s

const ALLOWED_IMAGE_MIMES = new Set([
  'image/jpeg', 'image/jpg', 'image/png', 'image/webp',
]);

/**
 * Open the native image picker with validation.
 * Returns the asset, or null if the user cancelled.
 * Throws a user-friendly Error if validation fails.
 */
export async function pickAdImage(): Promise<ImagePicker.ImagePickerAsset | null> {
  const result = await ImagePicker.launchImageLibraryAsync({
    mediaTypes:    'images',
    allowsEditing: true,
    aspect:        [16, 9],
    quality:       0.65,  // compress at pick time
  });
  if (result.canceled) return null;

  const asset = result.assets[0];
  const mime  = (asset.mimeType ?? 'image/jpeg').toLowerCase();

  if (!ALLOWED_IMAGE_MIMES.has(mime)) {
    throw new Error('Formato no válido. Solo se aceptan imágenes JPG, PNG o WebP.');
  }
  if (asset.fileSize && asset.fileSize > AD_IMAGE_MAX_BYTES) {
    const mb = (asset.fileSize / 1024 / 1024).toFixed(1);
    throw new Error(`La imagen pesa ${mb} MB. El máximo es 5 MB.`);
  }
  return asset;
}

/**
 * Open the native video picker with validation.
 * Returns the asset, or null if the user cancelled.
 * Throws a user-friendly Error if validation fails.
 */
export async function pickAdVideo(): Promise<ImagePicker.ImagePickerAsset | null> {
  const result = await ImagePicker.launchImageLibraryAsync({
    mediaTypes:    'videos',
    allowsEditing: false,
    quality:       1,
  });
  if (result.canceled) return null;

  const asset = result.assets[0];
  const mime  = (asset.mimeType ?? 'video/mp4').toLowerCase();

  if (!mime.includes('mp4')) {
    throw new Error('Solo se aceptan videos en formato MP4.');
  }
  if (asset.fileSize && asset.fileSize > AD_VIDEO_MAX_BYTES) {
    const mb = (asset.fileSize / 1024 / 1024).toFixed(1);
    throw new Error(`El video pesa ${mb} MB. El máximo es 20 MB.`);
  }
  if (asset.duration && asset.duration > AD_VIDEO_MAX_MS) {
    const s = Math.ceil(asset.duration / 1000);
    throw new Error(`El video dura ${s}s. El máximo es 30 segundos.`);
  }
  return asset;
}

/**
 * Upload a validated asset to the `advertisements` storage bucket.
 * Returns the public URL and duration in seconds (for video).
 */
export async function uploadAdMedia(
  asset:     ImagePicker.ImagePickerAsset,
  mediaType: 'image' | 'video',
  userId:    string,
): Promise<{ publicUrl: string; durationSeconds: number | null }> {
  const mime = asset.mimeType ?? (mediaType === 'image' ? 'image/jpeg' : 'video/mp4');
  const ext  = mediaType === 'video'
    ? 'mp4'
    : mime.includes('png')  ? 'png'
    : mime.includes('webp') ? 'webp'
    : 'jpg';

  const path = `${userId}/ad_${Date.now()}.${ext}`;
  const buf  = await fetch(asset.uri).then(r => r.arrayBuffer());

  const { error } = await supabase.storage
    .from('advertisements')
    .upload(path, buf, { contentType: mime, upsert: false });

  if (error) throw error;

  const { data } = supabase.storage.from('advertisements').getPublicUrl(path);
  const durationSeconds = asset.duration ? Math.ceil(asset.duration / 1000) : null;

  return { publicUrl: data.publicUrl, durationSeconds };
}
