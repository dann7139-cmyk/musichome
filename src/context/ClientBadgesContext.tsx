import React, { createContext, useContext, useEffect, useState } from 'react';
import { supabase } from '../config/supabase';

type ClientBadgesCtx = {
  pendingQuotesCount: number;
};

const ClientBadgesContext = createContext<ClientBadgesCtx>({ pendingQuotesCount: 0 });

export const ClientBadgesProvider = ({ children }: { children: React.ReactNode }) => {
  const [pendingQuotesCount, setPendingQuotesCount] = useState(0);

  const fetchCount = async () => {
    const { data: { session } } = await supabase.auth.getSession();
    if (!session) return;
    const { count } = await supabase
      .from('quotes')
      .select('*', { count: 'exact', head: true })
      .eq('client_id', session.user.id)
      .eq('status', 'quoted');
    setPendingQuotesCount(count ?? 0);
  };

  useEffect(() => {
    fetchCount();

    // Actualizar en tiempo real cuando cambia el estado de una cotización
    let uid: string | null = null;
    supabase.auth.getUser().then(({ data }) => { uid = data.user?.id ?? null; });

    const sub = supabase
      .channel('client-quote-badges')
      .on('postgres_changes', {
        event: '*', schema: 'public', table: 'quotes',
      }, () => { fetchCount(); })
      .subscribe();

    return () => { supabase.removeChannel(sub); };
  }, []);

  return (
    <ClientBadgesContext.Provider value={{ pendingQuotesCount }}>
      {children}
    </ClientBadgesContext.Provider>
  );
};

export const useClientBadges = () => useContext(ClientBadgesContext);
