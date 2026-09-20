import { createClient } from "@supabase/supabase-js";

const supabaseUrl     = process.env.NEXT_PUBLIC_SUPABASE_URL!;
const supabaseAnonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!;

export const supabase = createClient(supabaseUrl, supabaseAnonKey);

// ── Types ────────────────────────────────────────────────────────────────────

// groups no tiene category/base_price/cover_image/review_count — son
// genre/price_from/(solo profile_image)/total_reviews (hallazgo real,
// esta interfaz llevaba tiempo desalineada del esquema real).
export interface Group {
  id:             string;
  name:           string;
  description:    string | null;
  city:           string | null;
  state:          string | null;
  genre:          string | null;
  price_from:     number | null;
  rating:         number | null;
  total_reviews:  number | null;
  profile_image:  string | null;
  badges:         string[] | null;
  bid_amount:     number | null;
  bid_ends_at:    string | null;
  boost_score:    number | null;
  is_verified:    boolean | null;
  owner_id:       string;
  total_eventos_completados?: number | null;
}

export interface Profile {
  id:         string;
  name:       string;
  email:      string;
  role:       "client" | "group" | "talent" | "admin" | "admin_ops";
  city:       string | null;
  phone:      string | null;
  avatar_url: string | null;
  // sql/627+660 (app móvil) — alcance por país y candado de dinero para
  // admin_ops. NULL/undefined en cualquier otro rol, y en el admin
  // completo (nunca se le exige, ver AdminOpsPanel).
  admin_country_scope?:      "MX" | "US" | "CA" | null;
  admin_can_manage_payouts?: boolean;
}

export interface Reservation {
  id:              string;
  group_id:        string;
  client_id:       string;
  event_date:      string;
  event_time:      string | null;
  status:          string;
  payment_status:  string;
  total_price:     number;
  deposit_amount:  number | null;
  created_at:      string;
  groups?:         { name: string; profile_image: string | null };
  profiles?:       { name: string };
}
