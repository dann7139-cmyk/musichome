import { supabase } from '../config/supabase';
import { Category, CategoryType } from '../types/models';

/**
 * Fetches all active categories.
 * Pass a `type` to get only root-level categories of that type.
 * Leave `type` undefined to get everything.
 */
export async function fetchCategories(type?: CategoryType): Promise<Category[]> {
  let query = supabase
    .from('categories')
    .select('*')
    .eq('active', true)
    .order('name');

  if (type) {
    query = (query as any).eq('type', type);
  }

  const { data } = await query;
  return (data as Category[]) ?? [];
}

/**
 * Fetches only the root categories (those with no parent_id).
 * Useful for displaying the top-level type selector.
 */
export async function fetchRootCategories(): Promise<Category[]> {
  const { data } = await supabase
    .from('categories')
    .select('*')
    .eq('active', true)
    .is('parent_id', null)
    .order('name');

  return (data as Category[]) ?? [];
}

/**
 * Fetches direct children of a given parent category.
 */
export async function fetchChildCategories(parentId: string): Promise<Category[]> {
  const { data } = await supabase
    .from('categories')
    .select('*')
    .eq('active', true)
    .eq('parent_id', parentId)
    .order('name');

  return (data as Category[]) ?? [];
}

/**
 * Returns the group IDs that belong to `categoryId` or any of its descendants.
 * Delegates to the recursive DB function `get_groups_by_category`.
 */
export async function getGroupIdsByCategory(categoryId: string): Promise<string[]> {
  const { data, error } = await supabase.rpc('get_groups_by_category', {
    p_category_id: categoryId,
  });

  if (error || !data) return [];
  return (data as { group_id: string }[]).map(row => row.group_id);
}

/**
 * Fetches full group rows filtered by category (including subcategories).
 * Returns an empty array when no groups match.
 */
export async function fetchGroupsByCategory(categoryId: string) {
  const ids = await getGroupIdsByCategory(categoryId);
  if (ids.length === 0) return [];

  const { data } = await supabase
    .from('groups')
    .select('*')
    .eq('is_active', true)
    .in('id', ids)
    .order('created_at', { ascending: false });

  return data ?? [];
}

/**
 * Fetches the categories assigned to a specific provider (group),
 * with the full category object joined.
 */
export async function fetchProviderCategories(groupId: string) {
  const { data } = await supabase
    .from('provider_categories')
    .select('*, category:categories(*)')
    .eq('group_id', groupId);

  return data ?? [];
}

/**
 * Assigns a category to a provider.
 * Silently ignores duplicate assignments (UNIQUE constraint on DB).
 */
export async function addProviderCategory(
  groupId: string,
  categoryId: string
): Promise<{ error: string | null }> {
  const { error } = await supabase
    .from('provider_categories')
    .insert({ group_id: groupId, category_id: categoryId });

  if (error && error.code !== '23505') {
    // 23505 = unique_violation (already assigned — not an error)
    return { error: error.message };
  }
  return { error: null };
}

/**
 * Removes a category from a provider.
 * Will fail if this is the last category (DB trigger enforces minimum 1).
 */
export async function removeProviderCategory(
  groupId: string,
  categoryId: string
): Promise<{ error: string | null }> {
  const { error } = await supabase
    .from('provider_categories')
    .delete()
    .eq('group_id', groupId)
    .eq('category_id', categoryId);

  return { error: error?.message ?? null };
}
