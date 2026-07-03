/**
 * @deprecated bookingFlow.ts — LEGACY 50% DEPOSIT FLOW — DO NOT USE
 *
 * Este archivo describe el flujo antiguo de anticipo del 50% que ya NO existe.
 * El flujo actual es PAGO COMPLETO desde el inicio, procesado por Stripe.
 *
 * Flujo actual (desde 2025):
 *   CLIENT:   BookingScreen / QuotePaymentScreen / OpenRequestScreen
 *             → crea reserva → llama create-payment-intent (Edge Function)
 *             → Stripe PaymentSheet → webhook → confirm_full_payment_and_credit_wallet
 *             → payout_status='held' → cron 12h post-evento → released
 *
 * Ninguna pantalla activa llama a las funciones de este archivo.
 * Las RPCs set_booking_expiration, group_confirm_booking, client_confirm_event_complete
 * pueden no existir en Supabase — no las uses.
 *
 * Puedes eliminar este archivo cuando confirmes que no hay referencias externas.
 */

import { supabase } from '../config/supabase';
import type { Reservation, ReservationStatus } from '../types/models';

// ─────────────────────────────────────────────────────────────────────────────
// CLIENT SIDE
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Call this AFTER Stripe confirms the 50% deposit was paid.
 * Sets the booking into pending_group_confirmation and starts
 * the 24h group-response window.
 *
 * @param reservationId - The reservation that was just paid for
 * @param depositAmount - The actual amount paid (in your currency, not cents)
 */
export async function confirmDepositPaid(
  reservationId: string,
  depositAmount: number,
): Promise<void> {
  const { error } = await supabase.rpc('set_booking_expiration', {
    p_reservation_id: reservationId,
    p_deposit_amount: depositAmount,
  });

  if (error) throw error;
}

/**
 * Client confirms the event happened and is complete.
 * This is the trigger that releases the remaining 50% to the group.
 * Only callable by the client who owns the reservation.
 */
export async function clientConfirmEventComplete(
  reservationId: string,
): Promise<void> {
  const { error } = await supabase.rpc('client_confirm_event_complete', {
    p_reservation_id: reservationId,
  });

  if (error) throw error;
}

/**
 * Fetch all reservations for the current client.
 * Includes group details.
 */
export async function fetchClientReservations(): Promise<Reservation[]> {
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) throw new Error('Not authenticated');

  const { data, error } = await supabase
    .from('reservations')
    .select(`
      *,
      group:groups ( id, name, profile_image, city )
    `)
    .eq('client_id', user.id)
    .order('event_date', { ascending: false });

  if (error) throw error;
  return (data ?? []) as Reservation[];
}

/**
 * Fetch a single reservation by ID.
 * Works for both client and group owner — RLS enforces access.
 */
export async function fetchReservationById(
  reservationId: string,
): Promise<Reservation | null> {
  const { data, error } = await supabase
    .from('reservations')
    .select(`
      *,
      group:groups ( id, name, profile_image, city ),
      client:profiles ( id, full_name, avatar_url, phone )
    `)
    .eq('id', reservationId)
    .maybeSingle();

  if (error) throw error;
  return data as Reservation | null;
}

// ─────────────────────────────────────────────────────────────────────────────
// GROUP SIDE
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Group owner accepts the booking.
 * Only works while status = 'pending_group_confirmation' and within 24h window.
 */
export async function groupConfirmBooking(
  reservationId: string,
): Promise<void> {
  const { error } = await supabase.rpc('group_confirm_booking', {
    p_reservation_id: reservationId,
  });

  if (error) throw error;
}

/**
 * Group owner rejects the booking.
 * Triggers refund notification to the client.
 * The actual Stripe refund must be executed separately (Edge Function or webhook).
 */
export async function groupRejectBooking(
  reservationId: string,
): Promise<void> {
  const { error } = await supabase.rpc('group_reject_booking', {
    p_reservation_id: reservationId,
  });

  if (error) throw error;
}

/**
 * Fetch all pending bookings for a group that need a response.
 * Sorted by expiration time (most urgent first).
 */
export async function fetchPendingGroupBookings(
  groupId: string,
): Promise<Reservation[]> {
  const { data, error } = await supabase
    .from('reservations')
    .select(`
      *,
      client:profiles ( id, full_name, avatar_url, phone )
    `)
    .eq('group_id', groupId)
    .eq('status', 'pending_group_confirmation')
    .order('booking_expiration_at', { ascending: true });

  if (error) throw error;
  return (data ?? []) as Reservation[];
}

/**
 * Fetch all reservations for a group, optionally filtered by status.
 */
export async function fetchGroupReservations(
  groupId: string,
  status?: ReservationStatus,
): Promise<Reservation[]> {
  let query = supabase
    .from('reservations')
    .select(`
      *,
      client:profiles ( id, full_name, avatar_url, phone )
    `)
    .eq('group_id', groupId)
    .order('event_date', { ascending: false });

  if (status) {
    query = query.eq('status', status);
  }

  const { data, error } = await query;
  if (error) throw error;
  return (data ?? []) as Reservation[];
}

// ─────────────────────────────────────────────────────────────────────────────
// HELPERS
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Returns true if the booking's 24h group-response window is still open.
 */
export function isBookingConfirmationWindowOpen(reservation: Reservation): boolean {
  if (!reservation.booking_expiration_at) return false;
  return new Date(reservation.booking_expiration_at) > new Date();
}

/**
 * Returns remaining minutes in the confirmation window.
 * Returns 0 if already expired.
 */
export function bookingConfirmationMinutesLeft(reservation: Reservation): number {
  if (!reservation.booking_expiration_at) return 0;
  const diff = new Date(reservation.booking_expiration_at).getTime() - Date.now();
  return Math.max(0, Math.floor(diff / 60_000));
}
