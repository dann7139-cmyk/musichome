import React, { createContext, useCallback, useContext, useEffect, useRef, useState } from 'react';
import { AppState } from 'react-native';
import * as Haptics from 'expo-haptics';
import { supabase } from '../config/supabase';

// ── Imperativo: AppNavigator puede revivir dispatches desde fuera del Provider ──
let _reviveDispatch: ((id: string) => Promise<void>) | null = null;
let _reviveAll:      (() => Promise<void>) | null = null;
let _removeDispatch: ((id: string) => void) | null = null;

export async function reviveExpressDispatch(id: string) {
  await _reviveDispatch?.(id);
}
export async function reviveAllExpressDispatches() {
  await _reviveAll?.();
}
// Tras enviar la cotización, ProposeRequestScreen quita la tarjeta al
// instante (sin esperar al RPC/realtime — robusto aunque sql/415 no exista)
export function markExpressDispatchQuoted(id: string) {
  _removeDispatch?.(id);
}
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
    client_id: string | null;
    event_type: string;
    genre: string;
    event_date: string;
    event_time: string | null;
    hours: number;
    guest_count: number | null;
    location_city: string;
    location_municipio: string | null;
    location_estado: string;
    latitude: number | null;
    longitude: number | null;
    event_lat: number | null;
    event_lng: number | null;
    venue_covered: string | null;
    venue_size: string | null;
    needs_sound: string | null;
    comments: string | null;
    status?: string | null;
  };
}

// Estados de solicitud en los que TODAVÍA se puede cotizar. Si la solicitud
// ya fue aceptada/pagada/cancelada, el dispatch no debe seguir en el carrusel
// aunque su propia fila siga en 'pending_broadcast' (nadie la cerró).
const OPEN_REQUEST_STATUSES = ['open', 'en_negociacion', 'negotiating'];

interface ExpressCtx {
  dispatches:   ExpressDispatch[];
  hasDismissed: boolean;
  dismiss:      (id: string) => void;
  reviveAll:    () => Promise<void>;
}

const ExpressContext = createContext<ExpressCtx>({
  dispatches:   [],
  hasDismissed: false,
  dismiss:      () => {},
  reviveAll:    async () => {},
});

export function ExpressProvider({
  children,
  groupId,
}: {
  children: React.ReactNode;
  groupId: string | null;
}) {
  const [dispatches,   setDispatches]   = useState<ExpressDispatch[]>([]);
  const [hasDismissed, setHasDismissed] = useState(false);

  useEffect(() => {
    loadExpressSounds();
    return () => { unloadExpressSounds(); };
  }, []);

  const channelRef      = useRef<ReturnType<typeof supabase.channel> | null>(null);
  const dispatchesRef   = useRef<ExpressDispatch[]>([]);
  const dismissedIdsRef = useRef(new Set<string>());
  const removingRef     = useRef(new Set<string>());
  const groupGenreRef   = useRef<string | null>(null);
  dispatchesRef.current = dispatches;

  // Fetch the group's genre once so we can filter dispatches by matching genre
  useEffect(() => {
    if (!groupId) return;
    supabase.from('groups').select('genre').eq('id', groupId).single()
      .then(({ data }) => { groupGenreRef.current = data?.genre ?? null; });
  }, [groupId]);

  const remove = useCallback((id: string) => {
    setDispatches(prev => prev.filter(d => d.id !== id));
  }, []);

  const add = useCallback((dispatch: ExpressDispatch, silent = false) => {
    if (dismissedIdsRef.current.has(dispatch.id)) return;
    if (dispatchesRef.current.some(d => d.id === dispatch.id)) return;
    if (dispatchesRef.current.length >= 5) return;
    // La solicitud ya no está abierta (aceptada/pagada/cancelada/expirada) →
    // no mostrar aunque el dispatch siga 'pending_broadcast'
    const reqStatus = dispatch.request?.status;
    if (reqStatus && !OPEN_REQUEST_STATUSES.includes(reqStatus)) return;
    // Only show dispatches whose genre matches this group's genre
    const grpGenre = groupGenreRef.current;
    if (grpGenre && dispatch.request?.genre) {
      if (dispatch.request.genre.toLowerCase().trim() !== grpGenre.toLowerCase().trim()) return;
    }

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
      .select('*, request:event_requests(id,client_id,event_type,genre,event_date,event_time,hours,guest_count,location_city,location_municipio,location_estado,latitude,longitude,event_lat,event_lng,venue_covered,venue_size,needs_sound,comments,status)')
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
            .select('id,client_id,event_type,genre,event_date,event_time,hours,guest_count,location_city,location_municipio,location_estado,latitude,longitude,event_lat,event_lng,venue_covered,venue_size,needs_sound,comments,status')
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
    setHasDismissed(true);
    remove(id);
    void supabase.rpc('ignore_express_dispatch', { p_dispatch_id: id });
  }, [remove]);

  const reviveAll = useCallback(async () => {
    if (!groupId) return;
    dismissedIdsRef.current.clear();
    // hasDismissed stays true while network request is in-flight so the banner
    // remains visible. We clear it only after dispatches are added, so the user
    // never sees a 1-2 s gap where both the banner and the carousel are gone.
    const { data: rows } = await supabase
      .from('express_dispatches')
      .select('*, request:event_requests(id,client_id,event_type,genre,event_date,event_time,hours,guest_count,location_city,location_municipio,location_estado,latitude,longitude,event_lat,event_lng,venue_covered,venue_size,needs_sound,comments,status)')
      .eq('group_id', groupId)
      .in('status', ['pending_broadcast', 'quoting', 'ignored'])
      .order('created_at', { ascending: true });
    rows?.forEach(d => add({ ...d, request: (d as any).request ?? undefined }, true));
    setHasDismissed(false);
  }, [groupId, add]);

  // Registro de handlers imperativos para AppNavigator (fuera del Provider)
  useEffect(() => {
    if (!groupId) return;
    _reviveDispatch = async (id: string) => {
      dismissedIdsRef.current.delete(id);
      const { data } = await supabase
        .from('express_dispatches')
        .select('*, request:event_requests(id,client_id,event_type,genre,event_date,event_time,hours,guest_count,location_city,location_municipio,location_estado,latitude,longitude,event_lat,event_lng,venue_covered,venue_size,needs_sound,comments,status)')
        .eq('id', id)
        .in('status', ['pending_broadcast', 'quoting', 'ignored'])
        .single();
      if (data) add({ ...data, request: (data as any).request ?? undefined }, true);
    };
    _reviveAll = reviveAll;
    _removeDispatch = (id: string) => {
      // Marcar como descartado local para que un loadPending posterior no lo
      // vuelva a traer si el status en DB aún no cambió a 'quoted'
      dismissedIdsRef.current.add(id);
      remove(id);
    };
    return () => { _reviveDispatch = null; _reviveAll = null; _removeDispatch = null; };
  }, [groupId, add, reviveAll, remove]);

  return (
    <ExpressContext.Provider value={{ dispatches, hasDismissed, dismiss, reviveAll }}>
      {children}
    </ExpressContext.Provider>
  );
}

export const useExpress = () => useContext(ExpressContext);
