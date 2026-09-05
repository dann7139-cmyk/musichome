-- ============================================================
-- sql/605_category_interest_leads.sql
-- APLICADO 2026-09-03.
--
-- PETICIÓN REAL DEL USUARIO: cuando el cliente busca una categoría sin
-- proveedores todavía (hoy: Payasos/Comediante/Comida/Renta/Fotógrafos —
-- cero registrados en producción), mostrarle un botón "avísame" — y que
-- "le aparezca al admin el número de cliente, así yo consigo uno de lo
-- que está buscando... mientras por si no hay [proveedores]". O sea: NO
-- es un matching automático — es una lista de leads manual para que el
-- admin reclute un proveedor y contacte al cliente él mismo.
--
-- Diseño mínimo: una tabla + 2 RPCs. Nada de triggers automáticos todavía
-- (no se pidió) — el admin ve el teléfono/nombre del cliente vía join a
-- profiles (ya legible por cualquier authenticated: profiles_authenticated_read).
--
-- - category_interest_requests: 1 fila por (cliente, categoría) mientras
--   esté pendiente. Único índice parcial en (client_id, category_label)
--   WHERE contacted_at IS NULL → si el cliente ya pidió y sigue sin
--   contactar, tocar "avísame" otra vez es idempotente (no duplica). Una
--   vez que el admin marca contacted_at, el cliente puede volver a pedir
--   (nuevo ciclo, ej. si el admin no encontró nada la primera vez).
-- - request_category_interest(): la llama el cliente (SECURITY DEFINER,
--   usa auth.uid() — no hay política de INSERT directa en la tabla, solo
--   se puede insertar vía esta función).
-- - mark_category_interest_contacted(): la llama el admin desde su panel
--   para tachar el lead una vez que ya contactó al cliente.
--
-- Probado en BEGIN...ROLLBACK antes de aplicar (idempotencia, admin sí
-- puede marcar contactado, cliente normal NO puede). Ver rollback en el
-- archivo _ROLLBACK.
-- ============================================================

BEGIN;

CREATE TABLE public.category_interest_requests (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id      UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  category_label TEXT NOT NULL,
  genres         TEXT[] NOT NULL,
  city           TEXT,
  state          TEXT,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  contacted_at   TIMESTAMPTZ,
  contacted_by   UUID REFERENCES public.profiles(id)
);

CREATE UNIQUE INDEX category_interest_pending_uniq
  ON public.category_interest_requests (client_id, category_label)
  WHERE contacted_at IS NULL;

ALTER TABLE public.category_interest_requests ENABLE ROW LEVEL SECURITY;

CREATE POLICY category_interest_admin_select ON public.category_interest_requests
  FOR SELECT USING (public.is_admin());

CREATE POLICY category_interest_admin_update ON public.category_interest_requests
  FOR UPDATE USING (public.is_admin()) WITH CHECK (public.is_admin());

CREATE OR REPLACE FUNCTION public.request_category_interest(
  p_category_label TEXT, p_genres TEXT[], p_city TEXT DEFAULT NULL, p_state TEXT DEFAULT NULL
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE
  v_client UUID := auth.uid();
BEGIN
  IF v_client IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_authenticated');
  END IF;
  INSERT INTO public.category_interest_requests (client_id, category_label, genres, city, state)
  VALUES (v_client, p_category_label, p_genres, p_city, p_state)
  ON CONFLICT (client_id, category_label) WHERE contacted_at IS NULL DO NOTHING;
  RETURN jsonb_build_object('ok', true);
END;
$function$;
REVOKE EXECUTE ON FUNCTION public.request_category_interest(TEXT, TEXT[], TEXT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.request_category_interest(TEXT, TEXT[], TEXT, TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION public.mark_category_interest_contacted(p_id UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
BEGIN
  IF NOT public.is_admin() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;
  UPDATE public.category_interest_requests
  SET contacted_at = now(), contacted_by = auth.uid()
  WHERE id = p_id AND contacted_at IS NULL;
  RETURN jsonb_build_object('ok', true);
END;
$function$;
REVOKE EXECUTE ON FUNCTION public.mark_category_interest_contacted(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.mark_category_interest_contacted(UUID) TO authenticated;

COMMIT;
