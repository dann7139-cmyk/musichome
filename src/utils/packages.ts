import { supabase } from '../config/supabase';

export async function getGroupPackages(groupId: string) {
  const { data, error } = await supabase
    .from('packages')
    .select('*')
    .eq('provider_id', groupId)
    .eq('is_active', true)
    .order('price');

  if (error) throw error;

  return data;
}

export async function getAllPackages() {
  const { data, error } = await supabase
    .from('packages')
    .select('*');

  if (error) throw error;

  return data;
}
