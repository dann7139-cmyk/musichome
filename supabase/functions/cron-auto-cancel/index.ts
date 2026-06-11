// cron-auto-cancel
//
// Supabase Edge Function — scheduled to run every 15 minutes.
// Calls auto_cancel_expired_bookings() which cancels any
// pending_group_confirmation booking whose 24h window has elapsed.
//
// Schedule via Supabase Dashboard → Edge Functions → cron:
//   Schedule: "every 15 minutes"  →  */15 * * * *
//
// OR via pg_cron (requires extension enabled):
//   SELECT cron.schedule(
//     'auto-cancel-bookings',
//     '*/15 * * * *',
//     $$SELECT auto_cancel_expired_bookings()$$
//   );
//
// Required env vars:
//   SUPABASE_URL
//   SUPABASE_SERVICE_ROLE_KEY

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const supabase = createClient(
  Deno.env.get('SUPABASE_URL')!,
  Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
);

Deno.serve(async (_req) => {
  try {
    const { data: cancelled, error } = await supabase
      .rpc('auto_cancel_expired_bookings');

    if (error) throw error;

    console.log(`[cron-auto-cancel] Cancelled ${cancelled} expired bookings`);

    return new Response(
      JSON.stringify({ cancelled: cancelled ?? 0 }),
      { headers: { 'Content-Type': 'application/json' } },
    );
  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : 'Internal error';
    console.error('[cron-auto-cancel]', message);
    return new Response(
      JSON.stringify({ error: message }),
      { status: 500, headers: { 'Content-Type': 'application/json' } },
    );
  }
});
