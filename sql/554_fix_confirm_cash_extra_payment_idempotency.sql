-- ============================================================
-- 554_fix_confirm_cash_extra_payment_idempotency.sql
--
-- PROPÓSITO
--   Cierra el hallazgo confirmado en el QA en vivo de sql/552
--   (2026-08-18): confirm_cash_extra_payment no tiene guard de
--   idempotencia. Una segunda llamada sobre la misma hora extra ya
--   confirmada vuelve a ejecutarse sin error — sobreescribe
--   cash_confirmed_at con un timestamp nuevo y crea una fila
--   DUPLICADA en financial_audit_logs (mismo action, mismo
--   entity_id, amount=NULL igual). No afecta wallets — la función
--   nunca los toca — pero sí ensucia el log de auditoría y pisa el
--   timestamp de confirmación real.
--
-- AUDITORÍA DE LA DEFINICIÓN ACTUAL (solo lectura, ejecutada antes
-- de este archivo)
--   md5(prosrc) = 2ddb5640bc4b04f5f8ce5761d91eb7f0, length = 2377
--   — exactamente la que quedó desplegada por sql/552, sin cambios.
--
-- CAMBIO (1, alcance mínimo — nada más)
--   Mover la comprobación de "la hora extra existe" de DESPUÉS del
--   UPDATE (vía `IF NOT FOUND`) a ANTES (vía `SELECT ... FOR UPDATE`),
--   y usar esa misma lectura para decidir si la fila YA está
--   confirmada (status='paid' AND payout_status='released' AND
--   is_cash_payment=true). Si ya lo está, `RETURN` inmediato — no-op
--   silencioso, sin tocar cash_confirmed_at ni insertar otra fila de
--   auditoría. Si no lo está (primera llamada real), el UPDATE y el
--   INSERT se ejecutan exactamente igual que hoy, sin ningún cambio
--   de comportamiento.
--
--   El `FOR UPDATE` en el SELECT es nuevo pero no cambia el
--   comportamiento observable en el caso normal (sin concurrencia) —
--   solo evita que dos llamadas simultáneas pasen ambas el check de
--   "no confirmada todavía" antes de que cualquiera de las dos
--   escriba (mismo patrón ya usado en approve_extra_hour_payment_atomic
--   y group_confirm_extra_hours).
--
-- COMPORTAMIENTO ESPERADO
--   1a llamada (hora extra en cualquier estado distinto de
--   "ya confirmada en efectivo"): IDÉNTICO al validado en el QA de
--   sql/552 — UPDATE fija status='paid', payout_status='released',
--   is_cash_payment=true, cash_confirmed_at=NOW(); INSERT en
--   financial_audit_logs con action='cash_extra_confirmed',
--   amount=NULL. Sin cambios de wallets (como siempre).
--
--   2a llamada (o cualquier llamada posterior) sobre la MISMA hora
--   extra ya confirmada: no-op. La función retorna normalmente (void,
--   sin RAISE EXCEPTION — no es un error para quien la llama,
--   igual que hoy no lo es), pero no ejecuta el UPDATE ni el INSERT.
--   cash_confirmed_at conserva el valor de la 1a llamada.
--   financial_audit_logs no recibe ninguna fila nueva.
--   Nota: el frontend (ExtraHoursScreen.tsx `handleConfirmCashReceived`)
--   no inspecciona ningún valor de retorno — solo verifica ausencia de
--   excepción — así que este no-op es indistinguible de un éxito
--   normal desde la UI, que es el comportamiento correcto.
--
-- EXPLÍCITAMENTE FUERA DE ALCANCE
--   - No se toca wallets, group_wallets ni wallet_transactions — esta
--     función nunca los tocó y sigue sin tocarlos.
--   - No se toca Stripe ni ninguna función hermana (approve_extra_hour_
--     payment_atomic, group_confirm_extra_hours, confirm_extra_hour_
--     stripe_payment, release_extra_hours_partial, release_extra_hours_final).
--   - No se cambia la firma ni el tipo de retorno (sigue siendo void)
--     — evita tocar el caller en ExtraHoursScreen.tsx.
--   - No se agrega ningún jsonb de resultado tipo {ok, skipped} — eso
--     sería un cambio de contrato, fuera del "guard mínimo" pedido.
--   - Sin backfill de datos históricos: extra_hours está vacía (0 filas
--     en toda la tabla, confirmado en la limpieza de QA de sql/553).
--
-- SEGURIDAD: PRE-CHECK DE VERSIÓN
--   Igual que sql/550-552: se verifica el md5() del código fuente
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
  v_expected_hash CONSTANT TEXT := '2ddb5640bc4b04f5f8ce5761d91eb7f0';
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
  v_extra     RECORD;
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

  -- CAMBIO (sql/554): la comprobación de existencia se mueve de DESPUÉS
  -- del UPDATE (IF NOT FOUND) a ANTES, vía SELECT ... FOR UPDATE — la
  -- misma lectura sirve para decidir abajo si la fila ya fue confirmada.
  SELECT *
  INTO   v_extra
  FROM   extra_hours
  WHERE  id = p_extra_hour_id
    AND  reservation_id = p_reservation_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Hora extra no encontrada para esta reserva';
  END IF;

  -- Idempotencia (CAMBIO sql/554): si esta hora extra ya fue confirmada
  -- en efectivo, no-op silencioso. Sin este guard, una segunda llamada
  -- (doble tap, reintento de red, etc.) sobreescribía cash_confirmed_at
  -- y creaba una fila duplicada en financial_audit_logs — confirmado en
  -- el QA en vivo de sql/552 (2026-08-18). No afecta wallets, que esta
  -- función nunca toca.
  IF v_extra.status = 'paid' AND v_extra.payout_status = 'released' AND v_extra.is_cash_payment THEN
    RETURN;
  END IF;

  -- payout_status='released': esta función nunca acredita ningún
  -- wallet — el 100% del efectivo es del grupo directo, sin pasar
  -- por la plataforma. Dejar payout_status en el default 'held' haría
  -- que release_extra_hours_partial/_final recogieran esta fila más
  -- tarde y acreditaran a group_wallets.available_balance dinero que
  -- la plataforma nunca procesó (crédito indebido, fix de sql/552).
  UPDATE extra_hours
  SET
    is_cash_payment   = TRUE,
    cash_confirmed_at = NOW(),
    status            = 'paid',
    payout_status     = 'released'
  WHERE
    id             = p_extra_hour_id
    AND reservation_id = p_reservation_id;

  -- Auditoría: columnas reales de financial_audit_logs (fix de sql/552).
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

-- V1: el código fuente ahora incluye el guard de idempotencia y el
-- SELECT ... FOR UPDATE previo, y ya NO tiene el viejo "IF NOT FOUND"
-- inmediatamente después de un UPDATE sin SELECT previo.
-- SELECT prosrc ILIKE '%FOR UPDATE%' AS usa_select_for_update,
--        prosrc ILIKE '%v_extra.status = ''paid'' AND v_extra.payout_status = ''released'' AND v_extra.is_cash_payment%' AS tiene_guard_idempotencia,
--        (SELECT COUNT(*) FROM regexp_matches(prosrc, 'INSERT INTO financial_audit_logs', 'g')) AS inserts_de_auditoria
-- FROM pg_proc WHERE proname = 'confirm_cash_extra_payment' AND pronamespace='public'::regnamespace;
-- Esperado: usa_select_for_update=true, tiene_guard_idempotencia=true, inserts_de_auditoria=1 (sin duplicar el INSERT)

-- V2: confirmar que las 5 funciones hermanas NO cambiaron (comparar
-- contra los hashes ya capturados en auditorías previas)
-- SELECT proname, md5(prosrc) FROM pg_proc
-- WHERE proname IN ('approve_extra_hour_payment_atomic','group_confirm_extra_hours',
--                    'confirm_extra_hour_stripe_payment','release_extra_hours_partial',
--                    'release_extra_hours_final')
--   AND pronamespace='public'::regnamespace;
-- Esperado (sin cambios): 33628daffb34921cfe883a8205b97607, a7d390424f07f16c8581ad8b7178e022,
--                          fca14301fc3ae170a5f8024e709f4c39, (hashes de release_* sin capturar aún,
--                          pero deben coincidir con lo leído en la auditoría previa a este archivo)

-- V3: prueba funcional en vivo (fuera de este archivo, requiere
-- autorización aparte, mismo protocolo IDs QA sintéticos que sql/553):
-- llamar 2 veces sobre la misma hora extra y confirmar que la 2a
-- llamada NO cambia cash_confirmed_at ni agrega fila a financial_audit_logs
-- (a diferencia del comportamiento observado en el QA de sql/552).

-- V4: sin filas históricas afectadas — extra_hours global sigue vacía
-- SELECT COUNT(*) AS total_extra_hours FROM extra_hours;
-- Esperado: 0 (tabla vacía, confirmado en limpieza de sql/553)

SELECT '554_fix_confirm_cash_extra_payment_idempotency preparado — NO EJECUTADO' AS status;
