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

    // 1. Solicitudes activas del cliente con propuestas recibidas
    const { data: reqs } = await supabase
      .from('event_requests')
      .select('id, event_type, genre, event_date, hours, guest_count, location_city, location_municipio, location_estado, latitude, longitude, event_lat, event_lng, status')
      .eq('client_id', clientId)
      .in('status', ['en_negociacion', 'negotiating'])
      .order('created_at', { ascending: false });

    if (!reqs || reqs.length === 0) {
      activeReqIds.current = new Set();
      prevCountRef.current = 0;
      setProposals([]);
      return;
    }

    const reqIds = reqs.map((r: any) => r.id);
    activeReqIds.current = new Set(reqIds);
    const reqMap: Record<string, any> = Object.fromEntries(reqs.map((r: any) => [r.id, r]));

    // 2. Propuestas de grupos para esas solicitudes
    const { data: props } = await supabase
      .from('event_request_proposals')
      .select('id, request_id, group_id, group_owner_id, proposal_data, created_at')
      .in('request_id', reqIds)
      .order('created_at', { ascending: true });

    if (!props || props.length === 0) {
      prevCountRef.current = 0;
      setProposals([]);
      return;
    }

    // 3. Info de grupo (incluyendo lat/lng para el mapa)
    const ownerIds = [...new Set((props as any[]).map((p: any) => p.group_owner_id))];
    const { data: groups } = await supabase
      .from('groups')
      .select('id, owner_id, name, genre, profile_image, city, state')
      .in('owner_id', ownerIds);

    const groupByOwner: Record<string, any> = Object.fromEntries(
      (groups ?? []).map((g: any) => [g.owner_id, g])
    );

    const all: ClientProposal[] = (props as any[]).map(p => ({
      id:             p.id,
      request_id:     p.request_id,
      group_id:       p.group_id,
      group_owner_id: p.group_owner_id,
      proposal_data:  p.proposal_data ?? {},
      created_at:     p.created_at,
      group:          groupByOwner[p.group_owner_id] ?? null,
      request:        reqMap[p.request_id] ?? null,
    }));

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
