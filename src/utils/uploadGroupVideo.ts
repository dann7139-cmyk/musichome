import * as ImagePicker from 'expo-image-picker';
import { supabase } from '../config/supabase';

const MAX_BYTES = 50 * 1024 * 1024; // 50 MB

const ALLOWED_TYPES: Record<string, string> = {
  'video/mp4':       'mp4',
  'video/quicktime': 'mov',
  'video/webm':      'webm',
};

export async function pickAndUploadGroupVideo(groupId: string): Promise<string | null> {
  const result = await ImagePicker.launchImageLibraryAsync({
    mediaTypes: 'videos',
    allowsEditing: false,
    quality: 1,
  });

  if (result.canceled) return null;

  const asset = result.assets[0];

  if (asset.fileSize && asset.fileSize > MAX_BYTES) {
    throw new Error(
      `El video pesa ${(asset.fileSize / 1024 / 1024).toFixed(1)} MB. El límite es 50 MB.`,
    );
  }

  const mimeType = asset.mimeType ?? 'video/mp4';
  const ext = ALLOWED_TYPES[mimeType];
  if (!ext) {
    throw new Error('Formato no válido. Solo se aceptan MP4, MOV y WebM.');
  }

  const path = `${groupId}/promo-video.${ext}`;
  const arrayBuffer = await fetch(asset.uri).then(r => r.arrayBuffer());

  const { error: uploadError } = await supabase.storage
    .from('group-videos')
    .upload(path, arrayBuffer, { contentType: mimeType, upsert: true });

  if (uploadError) throw uploadError;

  const { data } = supabase.storage.from('group-videos').getPublicUrl(path);
  const publicUrl = data.publicUrl;

  // Usar RPC SECURITY DEFINER para evitar bloqueos de RLS en groups
  const { data: rpcData, error: rpcError } = await supabase
    .rpc('update_group_video', { p_group_id: groupId, p_video_url: publicUrl });

  if (rpcError) throw rpcError;
  if (rpcData?.ok === false) throw new Error(rpcData.error ?? 'Error al guardar video');

  return publicUrl;
}
