import * as ImagePicker from 'expo-image-picker';
import { supabase } from '../config/supabase';

/**
 * Abre el selector de imágenes, sube la foto al bucket `group-images`
 * (ruta avatars/{userId}.jpg) y actualiza profiles.avatar_url.
 *
 * @returns URL pública de la imagen, o null si el usuario canceló.
 * @throws Si el upload falla.
 */
export async function pickAndUploadProfileImage(userId: string): Promise<string | null> {
  const result = await ImagePicker.launchImageLibraryAsync({
    mediaTypes: 'images',
    allowsEditing: true,
    aspect: [1, 1],
    quality: 0.7,
  });

  if (result.canceled) return null;

  const uri = result.assets[0].uri;
  const arrayBuffer = await fetch(uri).then(r => r.arrayBuffer());
  const path = `avatars/${userId}.jpg`;

  const { error } = await supabase.storage
    .from('group-images')
    .upload(path, arrayBuffer, { contentType: 'image/jpeg', upsert: true });

  if (error) throw error;

  const { data } = supabase.storage.from('group-images').getPublicUrl(path);
  // Añadir timestamp para romper el cache de imagen (la URL cambia en cada subida)
  const freshUrl = `${data.publicUrl}?t=${Date.now()}`;
  await supabase.from('profiles').update({ avatar_url: freshUrl }).eq('id', userId);

  return freshUrl;
}
