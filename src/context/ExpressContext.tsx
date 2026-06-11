import React, { createContext, useCallback, useContext, useEffect, useRef, useState } from 'react';
import { AppState } from 'react-native';
import * as Haptics from 'expo-haptics';
import { supabase } from '../config/supabase';
import {
  loadExpressSounds,
  unloadExpressSounds,
  playDispatchSound,
  playQueueBadge,
} from '../utils/expressSound';

export interface ExpressDispatch {
  id: string;
  request_id: string;
  group_id: string;
  status: string;
  created_at: string;
  expires_at?: string;
  request?: {
    id: string;
    event_type: string;
    genre: string;
    event_date: string;
    event_time: string | null;
    hours: number;
    guest_count: number | null;
    location_city: string;
    location_municipio: string | null;
    location_estado: string;
    comments: string | null;
  };
}

interface ExpressCtx {
  dispatches: ExpressDispatch[];
  dismiss: (id: string) => void;
}

const ExpressContext = createContext<ExpressCtx>({
  dispatches: [],
  dismiss: () => {},
});

export function ExpressProvider({
  children,
  groupId,
}: {
  children: React.ReactNode;
  groupId: string | null;
}) {
  const [dispatches, setDispatches] = useState<ExpressDispatch[]>([]);

  useEffect(() => {
    loadExpressSounds();
    return () => { unloadExpressSounds(); };
  }, []);

  const channelRef      = useRef<ReturnType<typeof supabase.channel> | null>(null);
  const dispatchesRef   = useRef<ExpressDispatch[]>([]);
  const dismissedIdsRef = useRef(new Set<string>());
  const removingRef     = useRef(new Set<string>());
  dispatchesRef.current = dispatches;

  const remove = useCallback((id: string) => {
    setDispatches(prev => prev.filter(d => d.id !== id));
  }, []);

  const add = useCallback((dispatch: ExpressDispatch, silent = false) => {
    if (dismissedIdsRef.current.has(dispatch.id)) return;
    if (dispatchesRef.current.some(d => d.id === dispatch.id)) return;
    if (dispatchesRef.current.length >= 5) return;

    const isFirst = dispatchesRef.current.length === 0;

    setDispatches(prev => {
      if (prev.some(d => d.id === dispatch.id)) return prev;
      if (prev.length >= 5) return prev;
      return [...prev, dispatch];
    });

    if (!silent) {
      if (isFirst) {
        playDispatchSound();
        Haptics.notificationAsync(Haptics.NotificationFeedbackType.Warning).catch(() => {});
      } else {
        playQueueBadge();
        Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light).catch(() => {});
      }
    }
  }, []);

  const loadPending = useCallback(async (gid: string, silent = false) => {
    const { data: rows } = await supabase
      .from('express_dispatches')
      .select('*, request:event_requests(id,event_type,genre,event_date,event_time,hours,guest_count,location_city,location_municipio,location_estado,comments)')
      .eq('group_id', gid)
      .in('status', ['pending_broadcast', 'quoting'])
      .order('created_at', { ascending: true });

    rows?.forEach(d => add({ ...d, request: (d as any).request ?? undefined }, silent));
  }, [add]);

  useEffect(() => {
    if (!groupId) return;
    loadPending(groupId);

    const sub = AppState.addEventListener('change', state => {
      if (state === 'active' && groupId) loadPending(groupId, true);
    });
    return () => sub.remove();
  }, [groupId, loadPending]);

  useEffect(() => {
    if (!groupId) return;

    const channel = supabase
      .channel(`express_dispatch:${groupId}`)
      .on(
        'postgres_changes' as any,
        { event: 'INSERT', schema: 'public', table: 'express_dispatches', filter: `group_id=eq.${groupId}` },
        async (payload: any) => {
          const dispatch = payload.new as ExpressDispatch;
          if (dispatch.status !== 'pending_broadcast') return;

          const { data: req } = await supabase
            .from('event_requests')
            .select('id,event_type,genre,event_date,event_time,hours,guest_count,location_city,location_municipio,location_estado,comments')
            .eq('id', dispatch.request_id)
            .single();

          add({ ...dispatch, request: req ?? undefined });
        }
      )
      .on(
        'postgres_changes' as any,
        { event: 'UPDATE', schema: 'public', table: 'express_dispatches', filter: `group_id=eq.${groupId}` },
        (payload: any) => {
          const updated = payload.new as ExpressDispatch;

          if (updated.status === 'taken') {
            if (!removingRef.current.has(updated.id)) {
              removingRef.current.add(updated.id);
              setDispatches(prev =>
                prev.map(d => d.id === updated.id ? { ...d, status: 'taken' } : d)
              );
              setTimeout(() => {
                remove(updated.id);
                removingRef.current.delete(updated.id);
              }, 1_400);
            }
          } else if (
            updated.status === 'ignored' ||
            updated.status === 'expired' ||
            updated.status === 'quoted'
          ) {
            remove(updated.id);
          }
        }
      )
      .subscribe();

    channelRef.current = channel;
    return () => { supabase.removeChannel(channel); };
  }, [groupId, add, remove]);

  const dismiss = useCallback((id: string) => {
    dismissedIdsRef.current.add(id);
    remove(id);
    void supabase.rpc('ignore_express_dispatch', { p_dispatch_id: id });
  }, [remove]);

  return (
    <ExpressContext.Provider value={{ dispatches, dismiss }}>
      {children}
    </ExpressContext.Provider>
  );
}

export const useExpress = () => useContext(ExpressContext);
