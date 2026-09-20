// 'admin_ops' — cuenta admin con alcance limitado a un país (sql/627,
// 2026-09-08). Ve solo las colas de no-shows/pagos/verificación de su
// país (profiles.admin_country_scope); nunca finanzas globales.
export type UserRole = 'admin' | 'group' | 'client' | 'talent' | 'admin_ops';

/** Status values for the events table */
export type EventStatus = 'draft' | 'active' | 'completed' | 'cancelled';

/** Status values for the reservations table.
 *  Legacy statuses (pending, in_progress) are kept for backward compatibility
 *  with existing rows; new bookings use the values below. */
export type ReservationStatus =
  // Legacy
  | 'pending'
  | 'in_progress'
  | 'rejected'
  // Current
  | 'pending_payment'
  | 'pending_provider_confirmation'
  | 'pending_group_confirmation'    // waiting for group to accept
  | 'accepted'                      // group accepted — client has 24h to pay 50%
  | 'confirmed'                     // MP payment approved
  | 'completed'
  | 'cancelled'
  | 'expired';

export type BreakType = 'A' | 'B' | 'D';

export type VerificationStatus = 'none' | 'pending' | 'approved' | 'rejected';

export interface Profile {
  id: string;
  email: string;
  full_name: string;
  role: UserRole;
  phone?: string;
  phone_verified: boolean;
  id_verified: boolean;
  avatar_url?: string;
  city?: string;
  state?: string;
  country?: string;
  created_at: string;
  // sql/627 (2026-09-08) — admin con alcance por país. Solo se llenan
  // para role='admin_ops' (admin_country_scope) o role='admin'
  // (admin_muted_countries, el interruptor de opt-out por país).
  admin_country_scope?: 'MX' | 'US' | 'CA' | null;
  admin_muted_countries?: string[];
  // sql/660 (2026-09-16) — false = admin_ops "limitado" (sin acceso a
  // dinero: solo no-shows, fotos, cotizaciones de conserjería y
  // solicitudes de proveedores). true = puede registrar pagos/retiros.
  admin_can_manage_payouts?: boolean;
}

export interface Event {
  id: string;
  client_id: string;
  event_date: string;
  address: string;
  status: EventStatus;
  created_at: string;
  updated_at: string;
  // Relations
  client?: Profile;
  reservations?: Reservation[];
}

export interface Country {
  id: string;
  name: string;
  code: string;
  commission_rate: number;
  currency_code: string;
  currency_symbol: string;
  payment_provider: string;
}

export type GroupLevel = 'bronce' | 'plata' | 'oro' | 'elite';

export interface Group {
  id: string;
  owner_id: string;
  name: string;
  genre: string;
  description?: string;
  city: string;
  state?: string;
  country: string;
  country_id?: string;
  country_code?: string;
  profile_image?: string;
  promo_video?: string;
  price_from?: number;
  rating?: number;
  total_reviews?: number;
  is_verified: boolean;
  verification_status: VerificationStatus;
  is_active: boolean;
  created_at: string;
  // Reputación
  nivel?: GroupLevel;
  puntos_reputacion?: number;
  total_eventos_completados?: number;
  cancelaciones?: number;
}

export interface Package {
  id: string;
  group_id: string;
  name: string;
  description?: string;
  duration_hours: number;
  price: number;
  members_count?: number;
  includes?: string[];
  break_type?: BreakType;
  is_active: boolean;
}

export interface Reservation {
  id: string;
  event_id?: string;
  group_id: string;
  package_id: string;
  client_id: string;
  event_date: string;
  deposit_paid: boolean;
  deposit_amount?: number;           // actual 50% amount paid
  remaining_amount?: number;         // total_price - deposit_amount
  booking_expiration_at?: string;    // 24h deadline for group to confirm
  client_confirmed_complete: boolean; // client must explicitly confirm event done
  event_time?: string;
  address: string;
  total_price: number;
  platform_commission: number;
  group_earnings: number;
  status: ReservationStatus;
  break_type?: BreakType;
  group_arrived_at?: string;
  arrival_location_lat?: number;
  arrival_location_lng?: number;
  event_started_at?: string;
  event_ended_at?: string;
  actual_duration_minutes?: number;
  qr_code?: string;
  notes?: string;
  created_at: string;
  // Relations
  group?: Group;
  package?: Package;
  client?: Profile;
}

export interface ExtraHour {
  id: string;
  reservation_id: string;
  hours_added: number;
  price_per_hour: number;
  total_extra_cost: number;
  platform_commission: number;
  group_extra_earnings: number;
  status: 'pending' | 'paid' | 'rejected';
  created_at: string;
}

export interface EventBreak {
  id: string;
  reservation_id: string;
  break_type: BreakType;
  scheduled_at: string;
  started_at?: string;
  ended_at?: string;
}

export interface VerificationRequest {
  id: string;
  group_id: string;
  status: VerificationStatus;
  document_url?: string;
  admin_notes?: string;
  submitted_at: string;
  reviewed_at?: string;
}

export interface Review {
  id: string;
  reservation_id: string;
  client_id: string;
  group_id: string;
  rating: number;
  comment?: string;
  created_at: string;
}

export interface MotivationalMessage {
  id: string;
  week_number: number;
  message_es: string;
  category: string;
}

export type CategoryType = 'music' | 'entertainment' | 'service';

export interface Category {
  id: string;
  name: string;
  parent_id?: string;
  type: CategoryType;
  active: boolean;
  created_at: string;
  // Relations
  parent?: Category;
  children?: Category[];
}

export interface ProviderCategory {
  id: string;
  group_id: string;
  category_id: string;
  created_at: string;
  // Relations
  category?: Category;
  group?: Group;
}

// ─── Push Notifications ─────────────────────────────────────────────────────

export type PushPlatform = 'ios' | 'android' | 'web';

export interface PushToken {
  id: string;
  user_id: string;
  token: string;
  platform: PushPlatform;
  created_at: string;
}

// ─── Job Board ──────────────────────────────────────────────────────────────

export type AvailabilityStatus = 'available' | 'busy';
export type InvitationStatus   = 'pending' | 'accepted' | 'rejected';

export interface JobBoardProfile {
  id: string;
  user_id: string;
  instrument_or_role: string;
  bio?: string;
  experience_years: number;
  rating: number;
  total_jobs: number;
  availability_status: AvailabilityStatus;
  is_visible: boolean;
  created_at: string;
  updated_at: string;
  // Relations
  user?: Profile;
}

/** Shape returned by the search_talents RPC */
export interface TalentResult {
  id: string;
  user_id: string;
  full_name: string;
  avatar_url?: string;
  instrument_or_role: string;
  bio?: string;
  experience_years: number;
  rating: number;
  total_jobs: number;
  availability_status: AvailabilityStatus;
  distance_km?: number;
  created_at: string;
}

export interface JobInvitation {
  id: string;
  group_id: string;
  invited_user_id: string;
  event_id?: string;
  proposed_payment_amount?: number;
  message?: string;
  status: InvitationStatus;
  created_at: string;
  updated_at: string;
  // Relations
  group?: Group;
  invited_user?: Profile;
  event?: Event;
}

// ─── Notifications ───────────────────────────────────────────────────────────

export type NotificationType =
  | 'job_invitation'
  | 'invitation_accepted'
  | 'invitation_rejected'
  | string; // forward-compatible with future types

export interface Notification {
  id: string;
  user_id: string;
  type: NotificationType;
  title: string;
  body: string;
  data: Record<string, unknown>;
  is_read: boolean;
  created_at: string;
}
