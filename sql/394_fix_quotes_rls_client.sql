-- ════════════════════════════════════════════════════════════════════
-- sql/394 — RLS SELECT para clientes en tabla quotes
--
-- Problema:
--   EventTimerScreen carga overtime prices vía:
--     supabase.from('quotes').select(...).eq('id', reservation.quote_id)
--   Este query corre con el JWT del cliente. Si no existe policy SELECT
--   que permita al cliente leer su propia cotización, el query devuelve
--   null → liveQuote queda null → opts.length = 0 → tarjeta oculta.
--
--   quotes.client_id existe y es el FK al usuario cliente
--   (verificado: ReservationsScreen usa .eq('client_id', uid) exitosamente).
--
-- Fix:
--   Crear policy SELECT en quotes para que el cliente pueda leer
--   las cotizaciones donde él es el client_id.
--
-- Complementa Fix A+B (HomeScreen + ReservationsScreen) que ahora
-- incluyen quote JOIN directamente en la navegación, haciendo liveQuote
-- un fallback en lugar de la fuente primaria.
-- ════════════════════════════════════════════════════════════════════

BEGIN;

-- ── Crear policy si no existe ────────────────────────────────────────
-- Nombre único para poder detectar duplicados en V1.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename  = 'quotes'
      AND policyname = 'client can read own quote'
  ) THEN
    EXECUTE $policy$
      CREATE POLICY "client can read own quote"
        ON public.quotes
        FOR SELECT
        TO authenticated
        USING (auth.uid() = client_id)
    $policy$;
  END IF;
END;
$$;

COMMIT;

-- ════════════════════════════════════════════════════════════════════
-- VERIFICACIONES (ejecutar separado después del COMMIT)
-- ════════════════════════════════════════════════════════════════════

-- V1: Policy existe en quotes
SELECT policyname, cmd, qual
FROM pg_policies
WHERE schemaname = 'public'
  AND tablename  = 'quotes'
  AND policyname = 'client can read own quote';
-- Esperado: 1 fila con cmd='SELECT', qual contiene 'client_id'

-- V2: client_id existe en quotes y es de tipo uuid
SELECT column_name, data_type, is_nullable
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name   = 'quotes'
  AND column_name  = 'client_id';
-- Esperado: 1 fila, data_type='uuid'

-- V3: RLS está habilitado en quotes
SELECT relname, relrowsecurity
FROM pg_class
WHERE relname = 'quotes'
  AND relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public');
-- Esperado: relrowsecurity = true

-- V4: Listar todas las policies activas en quotes (contexto completo)
SELECT policyname, cmd, roles, qual
FROM pg_policies
WHERE schemaname = 'public'
  AND tablename  = 'quotes'
ORDER BY policyname;
-- Esperado: incluye 'client can read own quote' con roles={authenticated}
