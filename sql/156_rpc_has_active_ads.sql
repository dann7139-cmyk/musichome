-- ════════════════════════════════════════════════════════════════════════════
-- 156_rpc_has_active_ads.sql
-- RPC ligera: devuelve true si el usuario autenticado tiene al menos un
-- anuncio activo en public.advertisements.
-- Evita traer toda la lista de órdenes solo para chequear el estado.
-- ════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.has_active_ads()
RETURNS boolean
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM   public.advertisements
    WHERE  advertiser_id = auth.uid()
      AND  status        = 'active'
    LIMIT  1
  );
$$;

GRANT EXECUTE ON FUNCTION public.has_active_ads() TO authenticated;

SELECT 'has_active_ads RPC creada ✅' AS status;
