-- ═══════════════════════════════════════════════════════════════════════════
-- ROLLBACK de 697 — devuelve el UPDATE general sobre `reservations`
-- ═══════════════════════════════════════════════════════════════════════════
-- ⚠️  Esto REABRE la vulnerabilidad: vuelve a permitir que un cliente o un
-- proveedor cambien `total_price`, `payment_status`, `payout_status`,
-- `commission_amount` y la moneda de las filas que RLS les deja ver. Correrlo
-- solo si el cierre rompió un flujo legítimo que no se detectó y hace falta
-- restaurar el estado anterior mientras se investiga.
--
-- Restaura el estado previo: grants de tabla `arwdDxtm` (ALL) para anon y
-- authenticated, que es el default de Supabase que tenía la tabla.
-- El GRANT por columna de `break_type` se vuelve redundante al volver el UPDATE
-- completo; se revoca para no dejar un permiso suelto que confunda después.
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

REVOKE UPDATE (break_type) ON TABLE public.reservations FROM authenticated;

GRANT ALL ON TABLE public.reservations TO anon, authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
