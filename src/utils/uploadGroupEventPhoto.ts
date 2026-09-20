import * as ImagePicker from 'expo-image-picker';
import { supabase } from '../config/supabase';
import { validatePublicText } from './textValidation';

export interface GroupEventPost {
  id: string;
  group_id: string;
  caption: string | null;
  status: 'pending' | 'approved' | 'rejected';
  review_note: string | null;
  created_at: string;
  photos: { id: string; url: string; position: number }[];
}

// Elegir fotos SIN publicar todavía — el grupo ve una vista previa y decide
// cuándo tocar "Publicar" (hallazgo real 2026-09-05: antes un solo toque
// elegía la foto Y la publicaba de una vez, sin previsualizar ni poder
// arrepentirse).
export async function pickGroupEventPhotos(): Promise<ImagePicker.ImagePickerAsset[] | null> {
  const result = await ImagePicker.launchImageLibraryAsync({
    mediaTypes: 'images',
    allowsMultipleSelection: true,
    selectionLimit: 6,
    quality: 0.7,
  });

  if (result.canceled || result.assets.length === 0) return null;
  return result.assets;
}

// Publicación con varias fotos (carrusel) YA elegidas de antes con
// pickGroupEventPhotos(). Se crea 1 fila en group_event_posts (la
// publicación) y 1 fila hija en group_event_photos por cada foto.
export async function uploadGroupEventPost(
  groupId: string,
  caption: string | null,
  assets: ImagePicker.ImagePickerAsset[],
): Promise<GroupEventPost | null> {
  if (!assets || assets.length === 0) return null;

  // Sin teléfonos, correos, links ni redes sociales en la descripción —
  // mismo filtro que ya usa el resto de la app (textValidation.ts).
  const check = validatePublicText(caption);
  if (!check.valid) throw new Error(check.error);

  // El límite de 6 publicaciones activas por grupo lo aplica el trigger
  // enforce_max_event_posts (sql/561) — si se excede, este INSERT lanza
  // 'max_event_photos_reached' en error.message.
  const { data: post, error: postError } = await supabase
    .from('group_event_posts')
    .insert({ group_id: groupId, caption: caption?.trim() || null })
    .select()
    .single();

  if (postError) throw postError;

  const photos: { id: string; url: string; position: number }[] = [];
  for (let i = 0; i < assets.length; i++) {
    const uri = assets[i].uri;
    const arrayBuffer = await fetch(uri).then(r => r.arrayBuffer());
    const path = `${groupId}/event-photos/${post.id}-${i}-${Date.now()}.jpg`;

    const { error: uploadError } = await supabase.storage
      .from('group-images')
      .upload(path, arrayBuffer, { contentType: 'image/jpeg', upsert: false });
    if (uploadError) throw uploadError;

    const { data: urlData } = supabase.storage.from('group-images').getPublicUrl(path);

    const { data: photoRow, error: photoError } = await supabase
      .from('group_event_photos')
      .insert({ post_id: post.id, url: urlData.publicUrl, position: i })
      .select()
      .single();
    if (photoError) throw photoError;

    photos.push(photoRow as any);
  }

  return { ...(post as any), photos };
}
