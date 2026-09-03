-- ============================================================
-- 552_fix_confirm_cash_extra_payment.sql
--
-- PROPÓSITO
--   confirm_cash_extra_payment tiene dos problemas confirmados en la
--   auditoría de solo lectura previa:
--
--   1. BUG CRÍTICO ACTIVO: su INSERT INTO financial_audit_logs usa
--      columnas (reservation_id, extra_hour_id) que NO existen en el
--      esquema actual de esa tabla, y omite las columnas NOT NULL
--      (entity_type, entity_id). Esa sentencia SIEMPRE falla con un
--      error de Postgres. Como la función no tiene EXCEPTION WHEN
--      OTHERS, el error revierte TODA la transacción — incluido el
--      UPDATE extra_hours que la precede. Confirmado con evidencia
--      directa: 0 filas en toda la historia de extra_hours tienen
--      cash_confirmed_at IS NOT NULL, 0 entradas en financial_audit_logs
--      con action='cash_extra_confirmed' — la función nunca se ha
--      completado exitosamente ni una sola vez.
--
--   2. Misma laguna que ya se corrigió en approve_extra_hour_payment_atomic
--      (sql/550) y group_confirm_extra_hours (sql/551): el UPDATE deja
--      status='paid' sin fijar payout_status, que quedaría en el
--      default de tabla 'held' — el mismo filtro que usan
--      release_extra_hours_partial/_final. Hoy esto no se manifiesta
--      porque el bug #1 impide que la función llegue a completarse,
--      pero en cuanto se corrija el INSERT, sin este segundo cambio la
--      función caería en el mismo crédito indebido ya visto dos veces
--      (dinero en efectivo que la plataforma nunca procesó, acreditado
--      igual a group_wallets.available_balance por las funciones de
--      liberación).
--
-- AUDITORÍA DE FILAS AFECTADAS (solo lectura, ejecutada antes de este
-- archivo)
--   SELECT COUNT(*) FROM extra_hours
--   WHERE status='paid' AND payout_status='held' AND stripe_payment_id IS NULL;
--   → 0. Sin backfill necesario — el fix es puramente hacia adelante.
--
-- CAMBIOS (2, alcance autorizado explícitamente — nada más)
--   1. Reescribir el INSERT INTO financial_audit_logs para usar las
--      columnas reales de la tabla: entity_type, entity_id, action,
--      actor_id, actor_role, before_state, after_state, amount, notes.
--      No se agrega ninguna consulta nueva para capturar el monto —
--      `amount` queda NULL en este log (la función nunca leyó
--      total_extra_cost/group_extra_earnings antes; agregar esa lectura
--      sería un tercer cambio fuera del alcance autorizado). Puede
--      ampliarse en una ronda futura si se necesita.
--   2. Agregar `payout_status = 'released'` al mismo UPDATE extra_hours
--      que ya pone status='paid' — esta función nunca acredita ningún
--      wallet (el 100% del efectivo es del grupo directo, sin pasar
--      por la plataforma), así que no hay nada que "liberar" después.
--
-- EXPLÍCITAMENTE FUERA DE ALCANCE
--   - No se toca wallets, group_wallets ni wallet_transactions — esta
--     función nunca los tocó y sigue sin tocarlos.
--   - No se toca confirm_extra_hour_stripe_payment, approve_extra_hour_payment_atomic,
--     group_confirm_extra_hours, release_extra_hours_partial, release_extra_hours_final.
--   - Sin backfill: 0 filas afectadas hoy (ver auditoría arriba).
--
-- SEGURIDAD: PRE-CHECK DE VERSIÓN
--   Igual que sql/550 y sql/551: se verifica el md5() del código fuente
--   desplegado contra el auditado antes de reemplazar. Si no coincide,
--   aborta completo sin tocar nada.
--
-- NO EJECUTAR hasta autorización explícita. Este archivo se entrega
-- primero para revisión.
-- ============================================================

BEGIN;

-- ── Pre-check: la versión desplegada debe ser EXACTAMENTE la auditada ──
DO $$
DECLARE
  v_current_hash  TEXT;
  v_expected_hash CONSTANT TEXT := '163d20cdaf7ed18410dbf57a3f336773';
BEGIN
  SELECT md5(prosrc) INTO v_current_hash
  FROM   pg_proc p
  JOIN   pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public' AND p.proname = 'confirm_cash_extra_payment';

  IF v_current_hash IS NULL THEN
    RAISE EXCEPTION 'ABORT: confirm_cash_extra_payment no existe en esta base — no se puede aplicar este fix';
  END IF;

  IF v_current_hash <> v_expected_hash THEN
    RAISE EXCEPTION 'ABORT: la definición actual de confirm_cash_extra_payment (md5=%) no coincide con la versión auditada (md5=%). Alguien la modificó desde que se preparó este fix — revisar manualmente antes de reemplazarla.',
      v_current_hash, v_expected_hash;
  END IF;

  RAISE NOTICE 'Pre-check OK: versión desplegada coincide con la auditada (md5=%)', v_current_hash;
END $$;

-- ── Reemplazo: función completa, sin abreviar ──────────────────────────
CREATE OR REPLACE FUNCTION public.confirm_cash_extra_payment(p_extra_hour_id uuid, p_reservation_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_id UUID := auth.uid();
BEGIN
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'unauthorized: sesión requerida';
  END IF;

  -- El caller debe ser dueño del grupo o miembro activo de él
  IF NOT EXISTS (
    SELECT 1
    FROM reservations r
    JOIN groups g ON g.id = r.group_id
    LEFT JOIN job_invitations ji
      ON  ji.group_id        = g.id
      AND ji.invited_user_id = v_caller_id
      AND ji.status          = 'accepted'
      AND ji.invitation_type IN ('membership', 'job')
    WHERE r.id = p_reservation_id
      AND (g.owner_id = v_caller_id OR ji.invited_user_id IS NOT NULL)
  ) THEN
    RAISE EXCEPTION 'unauthorized: no eres parte del grupo de esta reserva';
  END IF;

  -- payout_status='released' (CAMBIO #2): esta función nunca acredita
  -- ningún wallet — el efectivo es 100% del grupo, directo, sin pasar
  -- por la plataforma. Dejar payout_status en el default 'held' haría
  -- que release_extra_hours_partial/_final recogieran esta fila más
  -- tarde y acreditaran a group_wallets.available_balance dinero que
  -- la plataforma nunca procesó (crédito indebido).
  UPDATE extra_hours
  SET
    is_cash_payment   = TRUE,
    cash_confirmed_at = NOW(),
    status            = 'paid',
    payout_status     = 'released'
  WHERE
    id             = p_extra_hour_id
    AND reservation_id = p_reservation_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Hora extra no encontrada para esta reserva';
  END IF;

  -- Auditoría (CAMBIO #1): columnas corregidas al esquema real de
  -- financial_audit_logs. Antes: INSERT (actor_id, action,
  -- reservation_id, extra_hour_id) — reservation_id/extra_hour_id no
  -- existen en la tabla, entity_type/entity_id (NOT NULL) faltaban —
  -- esa sentencia siempre fallaba y revertía toda la función.
  INSERT INTO financial_audit_logs (
    entity_type, entity_id, action, actor_id, actor_role,
    before_state, after_state, amount, notes
  ) VALUES (
    'extra_hour', p_extra_hour_id, 'cash_extra_confirmed', v_caller_id, 'group',
    jsonb_build_object('reservation_id', p_reservation_id),
    jsonb_build_object(
      'status',           'paid',
      'payout_status',    'released',
      'is_cash_payment',  true,
      'reservation_id',   p_reservation_id
    ),
    NULL,
    format('Confirmación de pago en efectivo de hora extra · reserva %s', p_reservation_id::TEXT)
  );
END;
$function$;

COMMIT;

-- ============================================================
-- VERIFICACIÓN POST-FIX (ejecutar por separado después del COMMIT,
-- NO se auto-ejecuta — todo lo siguiente está comentado)
-- ============================================================

-- V1: la función existe y su código fuente ahora usa las columnas
-- correctas de financial_audit_logs y fija payout_status='released'
-- SELECT prosrc ILIKE '%entity_type%' AS usa_entity_type,
--        prosrc NOT ILIKE '%INSERT INTO financial_audit_logs (actor_id, action, reservation_id, extra_hour_id)%' AS insert_viejo_ausente,
--        (SELECT COUNT(*) FROM regexp_matches(prosrc, 'payout_status\s*=\s*''released''', 'g')) AS ocurrencias_released
-- FROM pg_proc WHERE proname = 'confirm_cash_extra_payment' AND pronamespace='public'::regnamespace;
-- Esperado: usa_entity_type=true, insert_viejo_ausente=true, ocurrencias_released=1 (o 2, contando el after_state)

-- V2: confirmar que approve_extra_hour_payment_atomic, group_confirm_extra_hours,
-- confirm_extra_hour_stripe_payment, release_extra_hours_partial,
-- release_extra_hours_final NO cambiaron (comparar contra hashes ya
-- capturados en auditorías previas)
-- SELECT proname, md5(prosrc) FROM pg_proc
-- WHERE proname IN ('approve_extra_hour_payment_atomic','group_confirm_extra_hours',
--                    'confirm_extra_hour_stripe_payment','release_extra_hours_partial',
--                    'release_extra_hours_final')
--   AND pronamespace='public'::regnamespace;

-- V3: la función ahora SÍ puede completarse — probar en una fila QA
-- (fuera de este archivo, requiere autorización aparte) y confirmar
-- que financial_audit_logs recibe una fila con action='cash_extra_confirmed'

-- V4: sin filas históricas afectadas (el fix es hacia adelante)
-- SELECT COUNT(*) AS at_risk_count
-- FROM extra_hours
-- WHERE status = 'paid' AND payout_status = 'held' AND stripe_payment_id IS NULL;
-- Esperado: 0 (igual que antes del fix)

SELECT '552_fix_confirm_cash_extra_payment preparado — NO EJECUTADO' AS status;
