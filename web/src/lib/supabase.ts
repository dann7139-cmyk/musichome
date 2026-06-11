import { createClient } from "@supabase/supabase-js";

const supabaseUrl     = process.env.NEXT_PUBLIC_SUPABASE_URL!;
const supabaseAnonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!;

export const supabase = createClient(supabaseUrl, supabaseAnonKey);

// ── Types ────────────────────────────────────────────────────────────────────

export interface Group {
  id:             string;
  name:           string;
  description:    string | null;
  city:           string | null;
  genre:          string | null;
  category:       string | null;
  base_price:     number | null;
  rating:         number | null;
  review_count:   number | null;
  profile_image:  string | null;
  cover_image:    string | null;
  badges:         string[] | null;
  bid_amount:     number | null;
  bid_ends_at:    string | null;
  boost_score:    number | null;
  is_verified:    boolean | null;
  owner_id:       string;
}

export interface Profile {
  id:         string;
  name:       string;
  email:      string;
  role:       "client" | "group" | "talent" | "admin";
  city:       string | null;
  phone:      string | null;
  avatar_url: string | null;
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
