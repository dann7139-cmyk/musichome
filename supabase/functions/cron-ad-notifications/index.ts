/**
 * cron-ad-notifications
 *
 * Supabase Edge Function — scheduled to run once per day.
 * Calls run_daily_notification_engine() which:
 *   · Checks ad slot availability per city
 *   · Checks demand level per city (get_city_demand_score)
 *   · Sends targeted in-app notifications to group owners only
 *   · Anti-spam: max 1 marketing notification per 20h per user
 *   · Priority: high_demand > ad_space_available > no_ads_in_city > first_ad_reminder
 *
 * The existing send-push-notification function picks up the inserted
 * notifications and dispatches Expo push notifications automatically.
 *
 * Schedule via Supabase Dashboard → Edge Functions → cron:
 *   "0 10 * * *"  → every day at 10:00 UTC
 *
 * OR via pg_cron:
 *   SELECT cron.schedule(
 *     'ad-notifications',
 *     '0 10 * * *',
 *     $$SELECT run_daily_notification_engine()$$
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
    const { data, error } = await supabase
      .rpc('run_daily_notification_engine');

    if (error) throw error;

    const sent = (data as any)?.notifications_sent ?? 0;
    console.log(`[cron-ad-notifications] Notifications sent: ${sent}`);

    return new Response(
      JSON.stringify({ ok: true, notifications_sent: sent }),
      { headers: { 'Content-Type': 'application/json' } },
    );
  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : 'Internal error';
    console.error('[cron-ad-notifications]', message);
    return new Response(
      JSON.stringify({ error: message }),
      { status: 500, headers: { 'Content-Type': 'application/json' } },
    );
  }
});
