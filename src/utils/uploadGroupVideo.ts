import * as ImagePicker from 'expo-image-picker';
import { Alert } from 'react-native';
import { supabase } from '../config/supabase';

const MAX_BYTES = 50 * 1024 * 1024; // 50 MB

const ALLOWED_TYPES: Record<string, string> = {
  'video/mp4':  'mp4',
  'video/webm': 'webm',
};

/**
 * 🎬 Multi-video (sql/492): sube a una ruta ÚNICA y lo registra en
 * group_videos (status pending → revisión del admin). El límite 3/5
 * (Plus) lo valida el trigger del servidor — si se excede, lanza el
 * mensaje del trigger tal cual (incluye el upsell de Plus).
 */
export async function pickAndUploadGroupVideoMulti(groupId: string): Promise<boolean> {
  const result = await ImagePicker.launchImageLibraryAsync({
    mediaTypes: 'videos',
    allowsEditing: false,
    quality: 1,
  });
  if (result.canceled) return false;

  const asset = result.assets[0];
  if (asset.fileSize && asset.fileSize > MAX_BYTES) {
    throw new Error(`El video pesa ${(asset.fileSize / 1024 / 1024).toFixed(1)} MB. El límite es 50 MB.`);
  }
  const mimeType = asset.mimeType ?? 'video/mp4';
  if (mimeType === 'video/quicktime') {
    Alert.alert(
      '❌ Formato no compatible',
      'Tu video está en formato .mov (iPhone). Súbelo en MP4 (Configuración → Cámara → Formatos → "Más compatible").',
    );
    return false;
  }
  const ext = ALLOWED_TYPES[mimeType];
  if (!ext) throw new Error('Formato no válido. Solo se aceptan MP4 y WebM.');

  const path = `${groupId}/video-${Date.now()}.${ext}`;
  const arrayBuffer = await fetch(asset.uri).then(r => r.arrayBuffer());
  const { error: uploadError } = await supabase.storage
    .from('group-videos')
    .upload(path, arrayBuffer, { contentType: mimeType, upsert: false });
  if (uploadError) throw uploadError;

  const { data } = supabase.storage.from('group-videos').getPublicUrl(path);
  const { error: insErr } = await supabase.from('group_videos').insert({
    group_id: groupId,
    url: data.publicUrl,
    status: 'pending',
  });
  if (insErr) throw new Error(insErr.message);
  return true;
}

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

  if (mimeType === 'video/quicktime') {
    Alert.alert(
      '❌ Formato no compatible',
      'Tu video está en formato .mov (iPhone).\n\nPara que TODOS puedan verlo (iPhone, Android, Web), súbelo en formato MP4.\n\n📱 PARA TU iPHONE — Cambia el formato de grabación:\n1. Configuración\n2. Cámara\n3. Formatos\n4. Selecciona "Más compatible"\n\nDespués graba un video nuevo y súbelo.\n\n🌐 PARA CONVERTIR uno que ya tienes:\n- cloudconvert.com (gratis)\n- O usa cualquier conversor online',
    );
    return null;
  }

  const ext = ALLOWED_TYPES[mimeType];
  if (!ext) {
    throw new Error('Formato no válido. Solo se aceptan MP4 y WebM.');
  }

  const path = `${groupId}/promo-video.${ext}`;
  const arrayBuffer = await fetch(asset.uri).then(r => r.arrayBuffer());

  const { error: uploadError } = await supabase.storage
    .from('group-videos')
    .upload(path, arrayBuffer, { contentType: mimeType, upsert: true });

  if (uploadError) throw uploadError;

  const { data } = supabase.storage.from('group-videos').getPublicUrl(path);
  const publicUrl = data.publicUrl;

  // Guardar URL via RPC (SECURITY DEFINER omite RLS — update directo falla en producción)
  const { data: rpcData, error: dbError } = await supabase
    .rpc('update_group_video', { p_group_id: groupId, p_video_url: publicUrl });

  const rpcFailed = dbError || (rpcData && rpcData.ok === false);
  if (rpcFailed) {
    throw new Error('Video subido pero no se pudo guardar en el perfil: ' + (dbError?.message ?? rpcData?.error ?? 'error desconocido'));
  }

  return publicUrl;
}
