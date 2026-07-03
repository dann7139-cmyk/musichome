import { useEffect, useRef, useState } from 'react';
import { supabase } from '../config/supabase';
import { useAuth } from '../context/AuthContext';

/**
 * Detecta si el usuario tiene un evento en vivo (status='in_progress' AND event_started_at NOT NULL).
 * Hace fetch inicial + suscripción Realtime a la tabla reservations.
 * Debe llamarse UNA sola vez, a nivel del tab navigator, no por pantalla.
 */
export function useLiveEvent(): { hasLiveEvent: boolean } {
  const { user, role } = useAuth();
  const [hasLiveEvent, setHasLiveEvent] = useState(false);

  useEffect(() => {
    if (!user?.id || !role || role === 'admin') {
      setHasLiveEvent(false);
      return;
    }

    let active = true;
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    let channel: any = null;
    let resolvedGroupId: string | null = null;

    const check = async () => {
      if (!active) return;

      if (role === 'client') {
        const { data } = await supabase
          .from('reservations')
          .select('id')
          .eq('client_id', user.id)
          .eq('status', 'in_progress')
          .not('event_started_at', 'is', null)
          .limit(1)
          .maybeSingle();
        if (active) setHasLiveEvent(!!data);

      } else if (role === 'group') {
        if (!resolvedGroupId) return;
        const { data } = await supabase
          .from('reservations')
          .select('id')
          .eq('group_id', resolvedGroupId)
          .eq('status', 'in_progress')
          .not('event_started_at', 'is', null)
          .limit(1)
          .maybeSingle();
        if (active) setHasLiveEvent(!!data);

      } else if (role === 'talent') {
        const { data } = await supabase
          .from('job_invitations')
          .select('reservation:reservations!reservation_id(id, status, event_started_at)')
          .eq('invited_user_id', user.id)
          .eq('status', 'accepted')
          .limit(20);
        if (active) {
          setHasLiveEvent(
            (data ?? []).some((inv: any) =>
              inv.reservation?.status === 'in_progress' &&
              inv.reservation?.event_started_at != null
            )
          );
        }
      }
    };

    const setupChannel = (groupId?: string) => {
      const filter =
        role === 'client'
          ? `client_id=eq.${user.id}`
          : role === 'group' && groupId
            ? `group_id=eq.${groupId}`
            : undefined;

      channel = supabase.channel(`live_tab_${role}_${user.id}`);

      // Talento: también escucha job_invitations
      if (role === 'talent') {
        channel.on(
          'postgres_changes',
          {
            event: 'UPDATE',
            schema: 'public',
            table: 'job_invitations',
            filter: `invited_user_id=eq.${user.id}`,
          },
          () => check()
        );
      }

      channel
        .on(
          'postgres_changes',
          {
            event: 'UPDATE',
            schema: 'public',
            table: 'reservations',
            ...(filter ? { filter } : {}),
          },
          () => check()
        )
        .subscribe();
    };

    const init = async () => {
      if (role === 'group') {
        const { data: grp } = await supabase
          .from('groups')
          .select('id')
          .eq('owner_id', user.id)
          .maybeSingle();
        if (!active) return;
        resolvedGroupId = grp?.id ?? null;
      }

      await check();
      if (!active) return;
      setupChannel(resolvedGroupId ?? undefined);
    };

    init();

    return () => {
      active = false;
      if (channel) supabase.removeChannel(channel);
    };
  }, [user?.id, role]);

  return { hasLiveEvent };
}
