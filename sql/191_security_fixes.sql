-- ════════════════════════════════════════════════════════════════════
-- 191_security_fixes.sql
--
-- OBJETIVO: Aplicar los fixes de seguridad del audit.
--
-- 1. REVOKE mark_ad_payment de authenticated → solo service_role
-- 2. CHECK CONSTRAINT en target_states (solo valores normalizados)
-- 3. CHECK CONSTRAINT en advertisements.status (máquina de estados)
--
-- Requiere: 190_profile_ads_rotation.sql
-- ════════════════════════════════════════════════════════════════════


-- ── 1. REVOKE mark_ad_payment de usuarios normales ───────────────────────────
-- Solo el webhook (service_role) puede confirmar pagos.
-- Antes cualquier usuario autenticado podía llamarla directamente.

REVOKE EXECUTE ON FUNCTION public.mark_ad_payment(UUID, TEXT) FROM authenticated;
GRANT  EXECUTE ON FUNCTION public.mark_ad_payment(UUID, TEXT) TO service_role;

-- Nota: el webhook stripe-webhook usa SERVICE_ROLE_KEY → tiene acceso.
-- El frontend nunca debe llamar esta función directamente.


-- ── 2. CHECK CONSTRAINT: target_states solo valores normalizados ─────────────
-- Evita que inserciones manuales rompan el filtro de segmentación.

ALTER TABLE public.advertisements
  DROP CONSTRAINT IF EXISTS chk_target_states_normalized;

ALTER TABLE public.advertisements
  ADD CONSTRAINT chk_target_states_normalized CHECK (
    target_states IS NULL
    OR NOT EXISTS (
      SELECT 1
      FROM   unnest(target_states) AS s
      WHERE  s IS DISTINCT FROM normalize_state_name(s)
    )
  );


-- ── 3. CHECK CONSTRAINT: máquina de estados válidos ──────────────────────────
-- Evita valores de status inventados o typos.

ALTER TABLE public.advertisements
  DROP CONSTRAINT IF EXISTS chk_advertisement_status;

ALTER TABLE public.advertisements
  ADD CONSTRAINT chk_advertisement_status CHECK (
    status IN (
      'pending_payment',
      'pending_review',
      'active',
      'paused',
      'rejected',
      'expired'
    )
  );


-- ── Verificación ──────────────────────────────────────────────────────────────

-- Confirmar que mark_ad_payment ya NO está disponible para authenticated:
-- (debe devolver 0 filas para 'authenticated')
SELECT grantee, privilege_type
FROM   information_schema.routine_privileges
WHERE  routine_name = 'mark_ad_payment'
  AND  routine_schema = 'public';

-- Confirmar constraints en advertisements:
SELECT conname, pg_get_constraintdef(oid)
FROM   pg_constraint
WHERE  conrelid = 'public.advertisements'::REGCLASS
  AND  conname IN ('chk_target_states_normalized', 'chk_advertisement_status');

SELECT '191_security_fixes.sql ejecutado ✅' AS status;
