import React, {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useRef,
  useState,
} from 'react';
import { AppState } from 'react-native';
import * as Haptics from 'expo-haptics';
import { supabase } from '../config/supabase';
import {
  loadExpressSounds,
  unloadExpressSounds,
  playDispatchSound,
} from '../utils/expressSound';

// ── Imperativo: AppNavigator puede revivir desde fuera del Provider ───────────
let _reviveAll: (() => Promise<void>) | null = null;
export async function reviveClientProposals(): Promise<void> {
  await _reviveAll?.();
}

// ── Tipos ─────────────────────────────────────────────────────────────────────

export interface ProposalData {
  price_per_hour?:    number;
  travel_cost?:       number;
  base_price?:        number;
  base_total?:        number;
  demand_multiplier?: number;
  group_price?:       number;
  express_fee?:       number;
  total_amount?:      number;
  group_earnings?:    number;
  overtime_1h_price?: number;
  overtime_2h_price?: number;
  overtime_3h_price?: number;
  notes?:             string | null;
  member_dist?:       any;
  arrival_time?:      string | null;
  start_time?:        string | null;
}

export interface ClientProposalGroup {
  id:             string;
  owner_id:       string;
  name:           string;
  genre:          string;
  profile_image?: string | null;
  city?:          string | null;
  state?:         string | null;
}

export interface ClientProposalRequest {
  id:                   string;
  event_type:           string;
  genre:                string;
  event_date:           string;
  hours:                number;
  guest_count?:         number | null;
  location_city:        string;
  location_municipio?:  string | null;
  location_estado:      string;
  latitude?:            number | null;
  longitude?:           number | null;
  event_lat?:           number | null;
  event_lng?:           number | null;
  status:               string;
}

export interface ClientProposal {
  id:             string;
  request_id:     string;
  group_id:       string;
  group_owner_id: string;
  proposal_data:  ProposalData;
  created_at:     string;
  group:          ClientProposalGroup | null;
  request:        ClientProposalRequest | null;
  // 'scheduled' = cotización PROGRAMADA respondida (misma experiencia Uber
  // que las propuestas express — decisión 2026-07-11). raw = quote completo
  // para navegar a QuotePayment al contratar.
  kind?:          'express' | 'scheduled';
  raw?:           any;
}

// ── Context ───────────────────────────────────────────────────────────────────

interface ClientProposalCtx {
  proposals:  ClientProposal[];
  dismiss:    (id: string) => void;
  dismissAll: () => void;
  reviveAll:  () => Promise<void>;
}

const ClientProposalContext = createContext<ClientProposalCtx>({
  proposals:  [],
  dismiss:    () => {},
  dismissAll: () => {},
  reviveAll:  async () => {},
});

// ── Provider ──────────────────────────────────────────────────────────────────

export function ClientProposalProvider({
  children,
  clientId,
}: {
  children: React.ReactNode;
  clientId: string | null;
}) {
  const [proposals, setProposals] = useState<ClientProposal[]>([]);

  const dismissedIdsRef  = useRef(new Set<string>());
  const activeReqIds     = useRef(new Set<string>());
  const prevCountRef     = useRef(0);

  useEffect(() => {
    loadExpressSounds();
    return () => { unloadExpressSounds(); };
  }, []);

  const loadProposals = useCallback(async (silent = false) => {
    if (!clientId) { setProposals([]); return; }

    // 1. En paralelo: solicitudes EXPRESS activas + cotizaciones PROGRAMADAS
    //    respondidas (misma experiencia Uber para ambas — 2026-07-11)
    const [{ data: reqs }, { data: schedQuotes }] = await Promise.all([
      supabase
        .from('event_requests')
        .select('id, event_type, genre, event_date, hours, guest_count, location_city, location_municipio, location_estado, latitude, longitude, event_lat, event_lng, status')
        .eq('client_id', clientId)
        .in('status', ['en_negociacion', 'negotiating'])
        .order('created_at', { ascending: false }),
      supabase
        .from('quotes')
        .select('*, group:groups(id, owner_id, name, genre, profile_image, city, state)')
        .eq('client_id', clientId)
        // El grupo responde con status 'quoted' (QuoteDetailScreen:174)
        .in('status', ['quoted', 'responded'])
        .order('created_at', { ascending: false }),
    ]);

    // ── Express (flujo original, intacto) ────────────────────────────
    let expressAll: ClientProposal[] = [];
    if (reqs && reqs.length > 0) {
      const reqIds = reqs.map((r: any) => r.id);
      activeReqIds.current = new Set(reqIds);
      const reqMap: Record<string, any> = Object.fromEntries(reqs.map((r: any) => [r.id, r]));

      const { data: props } = await supabase
        .from('event_request_proposals')
        .select('id, request_id, group_id, group_owner_id, proposal_data, created_at')
        .in('request_id', reqIds)
        .order('created_at', { ascending: true });

      if (props && props.length > 0) {
        const ownerIds = [...new Set((props as any[]).map((p: any) => p.group_owner_id))];
        const { data: groups } = await supabase
          .from('groups')
          .select('id, owner_id, name, genre, profile_image, city, state')
          .in('owner_id', ownerIds);
        const groupByOwner: Record<string, any> = Object.fromEntries(
          (groups ?? []).map((g: any) => [g.owner_id, g])
        );
        expressAll = (props as any[]).map(p => ({
          id:             p.id,
          request_id:     p.request_id,
          group_id:       p.group_id,
          group_owner_id: p.group_owner_id,
          proposal_data:  p.proposal_data ?? {},
          created_at:     p.created_at,
          group:          groupByOwner[p.group_owner_id] ?? null,
          request:        reqMap[p.request_id] ?? null,
          kind:           'express' as const,
        }));
      }
    } else {
      activeReqIds.current = new Set();
    }

    // ── Programadas respondidas → misma forma de tarjeta ─────────────
    const schedAll: ClientProposal[] = (schedQuotes ?? []).map((q: any) => ({
      id:             `q-${q.id}`,
      request_id:     q.id,
      group_id:       q.group?.id ?? q.group_id,
      group_owner_id: q.group?.owner_id ?? '',
      proposal_data: {
        total_amount: q.total_amount ?? null,
        start_time:   q.event_time ? String(q.event_time).slice(0, 5) : null,
        notes:        q.group_notes ?? null,
      } as any,
      created_at:     q.responded_at ?? q.created_at,
      group:          q.group ?? null,
      request: {
        id:               q.id,
        event_type:       q.event_type ?? 'otro',
        genre:            q.group?.genre ?? '',
        event_date:       q.event_date,
        hours:            q.duration_hours ?? null,
        guest_count:      q.num_persons ?? q.guest_count ?? null,
        location_city:    q.event_municipio ?? '',
        location_estado:  q.event_estado ?? '',
        latitude:         q.latitude ?? null,
        longitude:        q.longitude ?? null,
        status:           q.status,
      } as any,
      kind: 'scheduled' as const,
      raw:  q,
    }));

    const all: ClientProposal[] = [...expressAll, ...schedAll];
    if (all.length === 0) {
      prevCountRef.current = 0;
      setProposals([]);
      return;
    }

    const visible = all.filter(p => !dismissedIdsRef.current.has(p.id));

    // Sonido + háptico solo al aparecer nuevas propuestas (transición 0 → 1+)
    if (!silent && visible.length > 0 && prevCountRef.current === 0) {
      playDispatchSound();
      Haptics.notificationAsync(Haptics.NotificationFeedbackType.Warning).catch(() => {});
    }

    prevCountRef.current = visible.length;
    setProposals(visible);
  }, [clientId]);

  // Carga inicial + foreground
  useEffect(() => {
    if (!clientId) return;
    void loadProposals();
    const sub = AppState.addEventListener('change', state => {
      if (state === 'active') void loadProposals(true);
    });
    return () => sub.remove();
  }, [clientId, loadProposals]);

  // Realtime: INSERT en event_request_proposals para las solicitudes de este cliente
  useEffect(() => {
    if (!clientId) return;

    const channel = supabase
      .channel(`client_proposals:${clientId}`)
      .on(
        'postgres_changes' as any,
        { event: 'INSERT', schema: 'public', table: 'event_request_proposals' },
        (_payload: any) => {
          // Always reload — activeReqIds may be empty if request was still 'open'
          // when we last loaded (group's proposal transitions it to en_negociacion)
          void loadProposals();
        }
      )
      .on(
        'postgres_changes' as any,
        // Programadas: el grupo respondió una cotización → brota el carrusel
        { event: 'UPDATE', schema: 'public', table: 'quotes', filter: `client_id=eq.${clientId}` },
        (_payload: any) => { void loadProposals(); }
      )
      .subscribe();

    return () => { supabase.removeChannel(channel); };
  }, [clientId, loadProposals]);

  const dismiss = useCallback((id: string) => {
    dismissedIdsRef.current.add(id);
    setProposals(prev => {
      const next = prev.filter(p => p.id !== id);
      prevCountRef.current = next.length;
      return next;
    });
  }, []);

  const dismissAll = useCallback(() => {
    setProposals(prev => {
      prev.forEach(p => dismissedIdsRef.current.add(p.id));
      prevCountRef.current = 0;
      return [];
    });
  }, []);

  const reviveAll = useCallback(async () => {
    dismissedIdsRef.current.clear();
    prevCountRef.current = 0;
    await loadProposals();
  }, [loadProposals]);

  // Registro imperativo para AppNavigator (fuera del árbol React)
  useEffect(() => {
    _reviveAll = reviveAll;
    return () => { _reviveAll = null; };
  }, [reviveAll]);

  return (
    <ClientProposalContext.Provider value={{ proposals, dismiss, dismissAll, reviveAll }}>
      {children}
    </ClientProposalContext.Provider>
  );
}

export const useClientProposals = () => useContext(ClientProposalContext);
