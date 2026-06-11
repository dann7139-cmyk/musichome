-- ============================================================
-- sql/255b_fase3.sql — FASE 3 (hardening de permisos)
--
-- ⚠️  EJECUTAR SOLO DESPUÉS DE:
--   1. 255a_fase1.sql aplicado correctamente
--   2. App desplegada con el frontend migrado (VerificationScreen + VerificationsScreen)
--   3. Flujo KYC probado end-to-end: grupo sube doc → selfie → envía → admin aprueba → badge ✅
--
-- ANTES DE EJECUTAR — verificar columnas del GRANT:
--   SELECT column_name FROM information_schema.columns
--   WHERE table_schema = 'public' AND table_name = 'groups'
--   ORDER BY ordinal_position;
--
-- Confirmar que ninguna columna que el owner edite legítimamente
-- en la app esté ausente de la lista del GRANT de abajo.
--
-- ROLLBACK: sql/255_rollback.sql (sección ROLLBACK FASE 3)
-- ============================================================


-- ─────────────────────────────────────────────────────────────────────────────
-- § F3-1  DROP TRIGGER + FUNCTION sync_group_verification
--
-- El trigger es SECURITY INVOKER: tras el REVOKE (F3-2), los callers
-- authenticated ya no podrán escribir is_verified/verification_status en groups,
-- por lo que el trigger fallaría en cada cambio de status. Se elimina primero.
-- ─────────────────────────────────────────────────────────────────────────────

DROP TRIGGER IF EXISTS sync_verification_status
  ON public.verification_requests;

DROP FUNCTION IF EXISTS public.sync_group_verification();


-- ─────────────────────────────────────────────────────────────────────────────
-- § F3-2  REVOKE + GRANT column-level en groups
--
-- Columnas EXCLUIDAS (solo RPCs SECURITY DEFINER pueden escribirlas):
--   is_verified, admin_verified, verification_status
--   strike_count, last_strike_at, suspended_at, suspended_by
-- ─────────────────────────────────────────────────────────────────────────────

REVOKE UPDATE ON public.groups FROM authenticated;

GRANT UPDATE (
  name,
  genre,
  description,
  city,
  state,
  profile_image,
  promo_video,
  is_active,
  price_from,
  bid_amount,
  service_cities
) ON public.groups TO authenticated;


-- ─────────────────────────────────────────────────────────────────────────────
-- § F3-3  Verificación
-- ─────────────────────────────────────────────────────────────────────────────

DO $$
DECLARE
  v_trigger_count INT;
BEGIN
  SELECT COUNT(*) INTO v_trigger_count
  FROM   information_schema.triggers
  WHERE  trigger_schema      = 'public'
    AND  event_object_table  = 'verification_requests'
    AND  trigger_name        = 'sync_verification_status';

  IF v_trigger_count > 0 THEN
    RAISE EXCEPTION '[255b] Trigger sync_verification_status todavía existe ❌';
  END IF;

  IF EXISTS (
    SELECT 1 FROM pg_proc p
    JOIN pg_namespace ns ON ns.oid = p.pronamespace
    WHERE ns.nspname = 'public' AND proname = 'sync_group_verification'
  ) THEN
    RAISE EXCEPTION '[255b] Función sync_group_verification todavía existe ❌';
  END IF;

  IF EXISTS (
    SELECT 1 FROM information_schema.column_privileges
    WHERE grantee        = 'authenticated'
      AND table_schema   = 'public'
      AND table_name     = 'groups'
      AND column_name    IN ('is_verified', 'admin_verified', 'verification_status')
      AND privilege_type = 'UPDATE'
  ) THEN
    RAISE EXCEPTION '[255b] authenticated todavía tiene UPDATE en columnas de verificación ❌';
  END IF;

  RAISE NOTICE '[255b] ✅ Trigger eliminado';
  RAISE NOTICE '[255b] ✅ Función sync_group_verification eliminada';
  RAISE NOTICE '[255b] ✅ REVOKE aplicado — is_verified/admin_verified/verification_status protegidos';
  RAISE NOTICE '[255b] FASE 3 COMPLETADA — vulnerabilidad groups_owner_all CERRADA';
END;
$$;


SELECT '255b_fase3.sql aplicado correctamente ✅' AS status;
