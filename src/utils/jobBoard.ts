/**
 * jobBoard.ts
 * Service functions for the Job Board feature.
 *
 * Sections:
 *   A. Talent profiles  (job_board_profiles)
 *   B. Invitations      (job_invitations)
 *   C. Notifications    (notifications)
 */

import { supabase } from '../config/supabase';
import type {
  JobBoardProfile,
  TalentResult,
  JobInvitation,
  Notification,
  AvailabilityStatus,
  InvitationStatus,
} from '../types/models';

// ─────────────────────────────────────────────────────────────────────────────
// A. TALENT PROFILES
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Search visible talent profiles.
 * Calls the search_talents RPC which joins profiles for name/avatar.
 *
 * @param role         - Optional partial match on instrument_or_role (e.g. "DJ", "vocalist")
 * @param availability - Optional filter: 'available' | 'busy' | undefined for all
 */
export async function searchTalents(
  role?: string,
  availability?: AvailabilityStatus
): Promise<TalentResult[]> {
  const { data, error } = await supabase.rpc('search_talents', {
    p_role:         role         ?? null,
    p_availability: availability ?? null,
  });

  if (error) throw error;
  return (data ?? []) as TalentResult[];
}

/**
 * Get the current user's own job board profile.
 * Returns null if the user has not created one yet.
 */
export async function fetchMyJobProfile(): Promise<JobBoardProfile | null> {
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) throw new Error('Not authenticated');

  const { data, error } = await supabase
    .from('job_board_profiles')
    .select('*')
    .eq('user_id', user.id)
    .maybeSingle();

  if (error) throw error;
  return data as JobBoardProfile | null;
}

export interface UpsertJobProfileData {
  instrument_or_role: string;
  bio?: string;
  experience_years?: number;
  availability_status?: AvailabilityStatus;
  is_visible?: boolean;
}

/**
 * Create or update the current user's job board profile.
 * Uses upsert on user_id so it's safe to call repeatedly.
 */
export async function upsertJobProfile(
  profileData: UpsertJobProfileData
): Promise<JobBoardProfile> {
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) throw new Error('Not authenticated');

  const { data, error } = await supabase
    .from('job_board_profiles')
    .upsert(
      { user_id: user.id, ...profileData },
      { onConflict: 'user_id' }
    )
    .select()
    .single();

  if (error) throw error;
  return data as JobBoardProfile;
}

/**
 * Toggle the current user's visibility on the job board.
 */
export async function setJobProfileVisibility(
  isVisible: boolean
): Promise<void> {
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) throw new Error('Not authenticated');

  const { error } = await supabase
    .from('job_board_profiles')
    .update({ is_visible: isVisible })
    .eq('user_id', user.id);

  if (error) throw error;
}

/**
 * Update the current user's availability status.
 */
export async function setAvailabilityStatus(
  status: AvailabilityStatus
): Promise<void> {
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) throw new Error('Not authenticated');

  const { error } = await supabase
    .from('job_board_profiles')
    .update({ availability_status: status })
    .eq('user_id', user.id);

  if (error) throw error;
}

// ─────────────────────────────────────────────────────────────────────────────
// B. INVITATIONS
// ─────────────────────────────────────────────────────────────────────────────

export interface SendInvitationData {
  group_id:                string;
  invited_user_id:         string;
  event_id?:               string;
  proposed_payment_amount?: number;
  message?:                string;
}

/**
 * Group owner sends an invitation to a talent.
 * A notification is automatically created by the DB trigger.
 */
export async function sendJobInvitation(
  invitationData: SendInvitationData
): Promise<JobInvitation> {
  const { data, error } = await supabase
    .from('job_invitations')
    .insert(invitationData)
    .select()
    .single();

  if (error) throw error;
  return data as JobInvitation;
}

/**
 * Invited user: fetch all invitations sent to them,
 * including group name and event details.
 */
export async function fetchMyInvitations(): Promise<JobInvitation[]> {
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) throw new Error('Not authenticated');

  const { data, error } = await supabase
    .from('job_invitations')
    .select(`
      *,
      group:groups ( id, name, profile_image, city ),
      event:events ( id, event_date, address )
    `)
    .eq('invited_user_id', user.id)
    .order('created_at', { ascending: false });

  if (error) throw error;
  return (data ?? []) as JobInvitation[];
}

/**
 * Group owner: fetch all invitations sent by a specific group.
 * Includes invited user's name and availability status.
 */
export async function fetchGroupInvitations(
  groupId: string
): Promise<JobInvitation[]> {
  const { data, error } = await supabase
    .from('job_invitations')
    .select(`
      *,
      invited_user:profiles ( id, full_name, avatar_url ),
      event:events ( id, event_date, address )
    `)
    .eq('group_id', groupId)
    .order('created_at', { ascending: false });

  if (error) throw error;
  return (data ?? []) as JobInvitation[];
}

/**
 * Invited user: accept or reject an invitation.
 * RLS enforces that only the invited_user_id can call this.
 */
export async function respondToInvitation(
  invitationId: string,
  status: Extract<InvitationStatus, 'accepted' | 'rejected'>
): Promise<void> {
  const { error } = await supabase
    .from('job_invitations')
    .update({ status })
    .eq('id', invitationId);

  if (error) throw error;
}

/**
 * Group owner: retract (delete) a pending invitation.
 * Only works while status is still 'pending'.
 */
export async function retractInvitation(invitationId: string): Promise<void> {
  const { error } = await supabase
    .from('job_invitations')
    .delete()
    .eq('id', invitationId)
    .eq('status', 'pending'); // safety guard — don't delete accepted/rejected

  if (error) throw error;
}

// ─────────────────────────────────────────────────────────────────────────────
// C. NOTIFICATIONS
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Fetch all notifications for the current user, newest first.
 */
export async function fetchNotifications(): Promise<Notification[]> {
  const { data, error } = await supabase
    .from('notifications')
    .select('*')
    .order('created_at', { ascending: false });

  if (error) throw error;
  return (data ?? []) as Notification[];
}

/**
 * Fetch only unread notifications for the current user.
 */
export async function fetchUnreadNotifications(): Promise<Notification[]> {
  const { data, error } = await supabase
    .from('notifications')
    .select('*')
    .eq('is_read', false)
    .order('created_at', { ascending: false });

  if (error) throw error;
  return (data ?? []) as Notification[];
}

/**
 * Count unread notifications (useful for badge counts).
 */
export async function countUnreadNotifications(): Promise<number> {
  const { count, error } = await supabase
    .from('notifications')
    .select('*', { count: 'exact', head: true })
    .eq('is_read', false);

  if (error) throw error;
  return count ?? 0;
}

/**
 * Mark a single notification as read.
 */
export async function markNotificationRead(
  notificationId: string
): Promise<void> {
  const { error } = await supabase
    .from('notifications')
    .update({ is_read: true })
    .eq('id', notificationId);

  if (error) throw error;
}

/**
 * Mark all notifications as read for the current user.
 */
export async function markAllNotificationsRead(): Promise<void> {
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) throw new Error('Not authenticated');

  const { error } = await supabase
    .from('notifications')
    .update({ is_read: true })
    .eq('user_id', user.id)
    .eq('is_read', false);

  if (error) throw error;
}
