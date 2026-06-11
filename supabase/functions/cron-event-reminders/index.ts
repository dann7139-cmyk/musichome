/**
 * cron-event-reminders
 *
 * Supabase Edge Function — scheduled to run every hour.
 * Calls send_event_reminders() which sends 24h-before-event
 * notifications to both the client and the group owner.
 * Duplicate-safe: the DB function checks if reminder was already sent.
 *
 * Schedule via Supabase Dashboard → Edge Functions → cron:
 *   Schedule: "every hour"  →  0 * * * *
 *
 * OR via pg_cron:
 *   SELECT cron.schedule(
 *     'event-reminders',
 *     '0 * * * *',
 *     $$SELECT send_event_reminders()$$
 *   );
 *
 * Required env vars:
 *   SUPABASE_URL
 *   SUPABASE_SERVICE_ROLE_KEY
 */

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const supabase = createClient(
  Deno.env.get('SUPABASE_URL')!,
  Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
);

Deno.serve(async (_req) => {
  try {
    const { data: reminded, error } = await supabase
      .rpc('send_event_reminders');

    if (error) throw error;

    console.log(`[cron-event-reminders] Sent reminders for ${reminded} events`);

    return new Response(
      JSON.stringify({ reminded: reminded ?? 0 }),
      { headers: { 'Content-Type': 'application/json' } },
    );
  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : 'Internal error';
    console.error('[cron-event-reminders]', message);
    return new Response(
      JSON.stringify({ error: message }),
      { status: 500, headers: { 'Content-Type': 'application/json' } },
    );
  }
});
