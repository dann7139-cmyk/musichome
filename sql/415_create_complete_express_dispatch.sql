-- ════════════════════════════════════════════════════════════════════
-- sql/415_create_complete_express_dispatch.sql
--
-- PROBLEMA:
--   ProposeRequestScreen llama complete_express_dispatch después de
--   que el grupo envía su cotización. Esta función nunca existió en
--   la DB → la llamada fallaba silenciosamente → el dispatch se
--   quedaba en status='pending_broadcast' → el carousel Uber no
--   cerraba la tarjeta → el grupo la veía aunque ya hubiera cotizado.
--
-- FIX:
--   1. Crear complete_express_dispatch → status='quoted'
--   2. El realtime subscription de ExpressContext recibe el UPDATE
--      y llama remove(id) → la tarjeta desaparece del carousel.
-- ════════════════════════════════════════════════════════════════════

DROP FUNCTION IF EXISTS public.complete_express_dispatch(UUID);

CREATE OR REPLACE FUNCTION public.complete_express_dispatch(
  p_dispatch_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_dispatch express_dispatches%ROWTYPE;
BEGIN
  -- Obtener el dispatch actual
  SELECT * INTO v_dispatch
  FROM public.express_dispatches
  WHERE id = p_dispatch_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'dispatch_not_found');
  END IF;

  -- Solo actualizar si está en un estado activo
  -- (puede que ya se haya actualizado por otro camino)
  IF v_dispatch.status NOT IN ('pending_broadcast', 'quoting') THEN
    RETURN jsonb_build_object('ok', true, 'status', v_dispatch.status, 'skipped', true);
  END IF;

  -- Marcar como cotizado → dispara realtime UPDATE → ExpressContext lo elimina del carousel
  UPDATE public.express_dispatches
  SET
    status    = 'quoted',
    quoted_at = NOW()
  WHERE id = p_dispatch_id;

  RETURN jsonb_build_object('ok', true, 'status', 'quoted');

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

-- Verificación: si hay algún dispatch en 'quoting' de los últimos 7 días
-- que ya tenga propuesta asociada, actualizarlos retroactivamente.
UPDATE public.express_dispatches ed
SET status = 'quoted', quoted_at = NOW()
WHERE ed.status = 'quoting'
  AND ed.created_at > NOW() - INTERVAL '7 days'
  AND EXISTS (
    SELECT 1
    FROM public.event_request_proposals erp
    WHERE erp.request_id = ed.request_id
      AND erp.group_id   = ed.group_id
  );

SELECT '415_create_complete_express_dispatch ✅' AS status;
