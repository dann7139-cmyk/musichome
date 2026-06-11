/**
 * pushNotifications.ts
 * Client-side push token management.
 *
 * Usage:
 *   1. On app launch (after auth), call registerPushToken().
 *   2. On logout, call unregisterPushToken() with the stored token.
 *
 * Getting an Expo push token in React Native:
 *   import * as Notifications from 'expo-notifications';
 *   const { data: token } = await Notifications.getExpoPushTokenAsync();
 */

import { supabase } from '../config/supabase';
import type { PushPlatform, PushToken } from '../types/models';

/**
 * Register or update a push token for the current user.
 * Safe to call on every app launch — uses UPSERT internally.
 * If the same device switches accounts the token is reassigned.
 */
export async function registerPushToken(
  token: string,
  platform: PushPlatform,
): Promise<void> {
  const { error } = await supabase.rpc('register_push_token', {
    p_token:    token,
    p_platform: platform,
  });

  if (error) throw error;
}

/**
 * Remove a push token from the DB.
 * Call this on logout so the user stops receiving push
 * notifications on a device they've signed out of.
 */
export async function unregisterPushToken(token: string): Promise<void> {
  const { error } = await supabase
    .from('push_tokens')
    .delete()
    .eq('token', token);

  if (error) throw error;
}

/**
 * Fetch all push tokens registered to the current user.
 * Useful for debugging or showing "active devices".
 */
export async function fetchMyPushTokens(): Promise<PushToken[]> {
  const { data, error } = await supabase
    .from('push_tokens')
    .select('*')
    .order('created_at', { ascending: false });

  if (error) throw error;
  return (data ?? []) as PushToken[];
}

/**
 * Remove ALL push tokens for the current user.
 * Call this on full account sign-out or "sign out of all devices".
 */
export async function unregisterAllTokens(): Promise<void> {
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return;

  const { error } = await supabase
    .from('push_tokens')
    .delete()
    .eq('user_id', user.id);

  if (error) throw error;
}
