import * as ImagePicker from 'expo-image-picker';
import { supabase } from '../config/supabase';

export async function pickAndUploadGroupImage(groupId: string): Promise<string | null> {
  const result = await ImagePicker.launchImageLibraryAsync({
    mediaTypes: 'images',
    allowsEditing: true,
    aspect: [1, 1],
    quality: 0.7,
  });

  if (result.canceled) return null;

  const uri = result.assets[0].uri;
  const arrayBuffer = await fetch(uri).then(r => r.arrayBuffer());
  const path = `${groupId}/profile.jpg`;

  const { error } = await supabase.storage
    .from('group-images')
    .upload(path, arrayBuffer, { contentType: 'image/jpeg', upsert: true });

  if (error) throw error;

  const { data } = supabase.storage.from('group-images').getPublicUrl(path);
  const freshUrl = `${data.publicUrl}?t=${Date.now()}`;

  // Usar RPC SECURITY DEFINER para evitar bloqueos de RLS en groups
  const { data: rpcData, error: rpcError } = await supabase
    .rpc('update_group_photo', { p_group_id: groupId, p_photo_url: freshUrl });

  if (rpcError) throw rpcError;
  if (rpcData?.ok === false) throw new Error(rpcData.error ?? 'Error al guardar foto');

  return freshUrl;
}
