"use client";

import { useCallback, useEffect, useState } from "react";
import { supabase } from "@/lib/supabase";

/**
 * "En trabajo" (sql/660, 2026-09-16) — evita que dos personas del equipo
 * atiendan el mismo caso dos veces (no-shows, fotos, cotizaciones de
 * conserjería, solicitudes de proveedores). Puerto directo de
 * src/hooks/useAdminClaims.ts (app móvil) — mismas 3 RPC, mismo shape.
 * Un claim vence a los 30 minutos del lado del servidor; aquí solo se
 * refleja lo que admin_get_claims devuelva.
 */

export interface AdminClaim {
  item_id: string;
  claimed_by: string;
  claimed_by_name: string | null;
  claimed_at: string;
  is_mine: boolean;
}

export function useAdminClaims(itemType: string, itemIds: string[]) {
  const [claims, setClaims] = useState<Record<string, AdminClaim>>({});
  const [busyId, setBusyId] = useState<string | null>(null);
  const key = itemIds.join(",");

  const refresh = useCallback(async () => {
    if (itemIds.length === 0) { setClaims({}); return; }
    const { data } = await supabase.rpc("admin_get_claims", { p_item_type: itemType, p_item_ids: itemIds });
    const items: AdminClaim[] = (data as any)?.items ?? [];
    const map: Record<string, AdminClaim> = {};
    items.forEach((c) => { map[c.item_id] = c; });
    setClaims(map);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [itemType, key]);

  useEffect(() => { refresh(); }, [refresh]);

  const claim = useCallback(async (itemId: string): Promise<boolean> => {
    setBusyId(itemId);
    const { data, error } = await supabase.rpc("admin_claim_item", { p_item_type: itemType, p_item_id: itemId });
    setBusyId(null);
    if (error || (data as any)?.ok === false) {
      const claimedByName = (data as any)?.claimed_by_name;
      if (typeof window !== "undefined") {
        window.alert(
          claimedByName
            ? `${claimedByName} ya está trabajando en esto ahora mismo.`
            : "No se pudo tomar este caso.",
        );
      }
      await refresh();
      return false;
    }
    await refresh();
    return true;
  }, [itemType, refresh]);

  const release = useCallback(async (itemId: string) => {
    setBusyId(itemId);
    await supabase.rpc("admin_release_claim", { p_item_type: itemType, p_item_id: itemId });
    setBusyId(null);
    await refresh();
  }, [itemType, refresh]);

  return { claims, claim, release, refresh, busyId };
}
