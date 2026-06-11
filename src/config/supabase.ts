import { createClient } from "@supabase/supabase-js";
import AsyncStorage from "@react-native-async-storage/async-storage";

export const supabaseUrl     = "https://sqgzyipqpewzbnfrtdqk.supabase.co";
export const supabaseAnonKey = "sb_publishable_hVxM5hR57omduY44QPKbZQ_q6mBgeIX";

export const supabase = createClient(supabaseUrl, supabaseAnonKey, {
  auth: {
    storage: AsyncStorage,
    autoRefreshToken: true,
    persistSession: true,
    detectSessionInUrl: false,
  },
});
