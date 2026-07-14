/**
 * send-push-notification
 *
 * Supabase Edge Function — called by cron every minute.
 * Picks up all notifications where push_sent_at IS NULL,
 * fetches the user's push tokens, dispatches via Expo Push API,
 * then marks each notification as sent.
 *
 * Supported providers:
 *   PUSH_PROVIDER=expo  (default) → Expo Push API (iOS + Android)
 *   PUSH_PROVIDER=fcm              → Firebase Cloud Messaging
 *
 * Required env vars:
 *   SUPABASE_URL
 *   SUPABASE_SERVICE_ROLE_KEY
 *   PUSH_PROVIDER          (optional, default: 'expo')
 *   FCM_SERVER_KEY         (only needed if PUSH_PROVIDER=fcm)
 */

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const supabase = createClient(
  Deno.env.get('SUPABASE_URL')!,
  Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
);

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

const PUSH_PROVIDER  = Deno.env.get('PUSH_PROVIDER') ?? 'expo';
const EXPO_PUSH_URL  = 'https://exp.host/--/api/v2/push/send';
const FCM_SERVER_KEY = Deno.env.get('FCM_SERVER_KEY');

// ── Types ─────────────────────────────────────────────────────────────────────

interface PendingNotification {
  id:      string;
  user_id: string;
  title:   string;
  body:    string | null;
  message: string | null;   // legacy column — some old triggers still write here
  data:    Record<string, unknown>;
  type:    string;
}

interface PushToken {
  user_id:  string;
  token:    string;
  platform: string;
}

interface ExpoMessage {
  to:    string;
  title: string;
  body:  string;
  data?: Record<string, unknown>;
  sound: 'default';
  badge?: number;
  priority?:  'default' | 'normal' | 'high';
  channelId?: string;
}

// ── Push providers ────────────────────────────────────────────────────────────

async function sendExpoMessages(messages: ExpoMessage[]): Promise<void> {
  if (messages.length === 0) return;

  const response = await fetch(EXPO_PUSH_URL, {
    method:  'POST',
    headers: {
      'Content-Type':    'application/json',
      'Accept':          'application/json',
      'Accept-Encoding': 'gzip, deflate',
    },
    body: JSON.stringify(messages),
  });

  if (!response.ok) {
    const text = await response.text();
    console.error('[expo] push error:', text);
  }
}

async function sendFcmMessage(token: string, notification: PendingNotification): Promise<void> {
  if (!FCM_SERVER_KEY) {
    console.warn('[fcm] FCM_SERVER_KEY not set — skipping');
    return;
  }

  const response = await fetch('https://fcm.googleapis.com/fcm/send', {
    method:  'POST',
    headers: {
      Authorization:  `key=${FCM_SERVER_KEY}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      to:           token,
      notification: { title: notification.title, body: notification.body ?? notification.message ?? '' },
      data:         { ...(notification.data ?? {}), type: notification.type },
    }),
  });

  if (!response.ok) {
    const text = await response.text();
    console.error('[fcm] push error:', text);
  }
}

// ── Main handler ──────────────────────────────────────────────────────────────

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    // 1. Fetch unsent notifications (batch of 100)
    const { data: pending, error: fetchErr } = await supabase
      .from('notifications')
      .select('id, user_id, title, body, message, data, type')
      .is('push_sent_at', null)
      .order('created_at', { ascending: true })
      .limit(100);

    if (fetchErr) throw fetchErr;
    if (!pending?.length) {
      console.log('[send-push] no pending notifications');
      return new Response(
        JSON.stringify({ sent: 0, message: 'No pending notifications' }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
      );
    }

    const notifications = pending as PendingNotification[];
    console.log(`[send-push] batch: ${notifications.length} notifications pending`);

    // 2. Get unique user IDs and fetch their tokens
    const userIds = [...new Set(notifications.map((n) => n.user_id))];

    const { data: tokenRows, error: tokenErr } = await supabase
      .from('push_tokens')
      .select('user_id, token, platform')
      .in('user_id', userIds);

    if (tokenErr) throw tokenErr;

    // 3. Build userId → tokens[] map
    const tokenMap = new Map<string, PushToken[]>();
    for (const t of (tokenRows ?? []) as PushToken[]) {
      if (!tokenMap.has(t.user_id)) tokenMap.set(t.user_id, []);
      tokenMap.get(t.user_id)!.push(t);
    }

    // 4. Build Expo batch + handle FCM individually
    const expoMessages: ExpoMessage[] = [];
    const processedIds: string[]      = [];

    let skippedEmpty = 0;

    for (const notif of notifications) {
      const resolvedBody = notif.body ?? notif.message ?? '';

      // Skip notifications with no body — would deliver a blank push
      if (!resolvedBody.trim()) {
        console.warn(`[send-push] SKIP id=${notif.id} type=${notif.type} user=${notif.user_id} — empty body`);
        processedIds.push(notif.id); // mark as sent so it doesn't loop forever
        skippedEmpty++;
        continue;
      }

      const tokens = tokenMap.get(notif.user_id) ?? [];

      if (tokens.length === 0) {
        console.log(`[send-push] no tokens for user=${notif.user_id} — notif id=${notif.id} type=${notif.type}`);
      }

      for (const { token, platform } of tokens) {
        console.log(`[send-push] SEND id=${notif.id} type=${notif.type} user=${notif.user_id} platform=${platform} body_len=${resolvedBody.length}`);
        if (PUSH_PROVIDER === 'expo' || platform !== 'web') {
          expoMessages.push({
            to:    token,
            title: notif.title,
            body:  resolvedBody,
            data:  { ...(notif.data ?? {}), type: notif.type },
            sound: 'default',
            // Entrega inmediata con la app CERRADA: APNs/FCM despiertan el
            // dispositivo + canal Android 'default' (importance MAX en el hook)
            priority:  'high',
            channelId: 'default',
          });
        } else {
          await sendFcmMessage(token, notif);
        }
      }

      processedIds.push(notif.id);
    }

    // 5. Dispatch Expo batch
    console.log(`[send-push] dispatching ${expoMessages.length} expo messages (${skippedEmpty} skipped empty)`);
    await sendExpoMessages(expoMessages);

    // 6. Mark all as push_sent
    if (processedIds.length > 0) {
      await supabase
        .from('notifications')
        .update({ push_sent_at: new Date().toISOString() })
        .in('id', processedIds);
    }

    console.log(`[send-push] done: sent=${expoMessages.length} skipped_empty=${skippedEmpty} marked=${processedIds.length}`);
    return new Response(
      JSON.stringify({ sent: processedIds.length, skipped_empty: skippedEmpty }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
    );
  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : 'Internal error';
    console.error('[send-push-notification]', message);
    return new Response(
      JSON.stringify({ error: message }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
    );
  }
});
