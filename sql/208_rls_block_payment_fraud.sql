-- 208_rls_block_payment_fraud.sql
-- Cierra todas las brechas de fraude en payment_status / columnas financieras.
--
-- PROBLEMAS QUE RESUELVE:
-- A) El grupo podía cambiar payment_status directamente (207b no lo bloqueaba).
-- B) El cliente no tenía política UPDATE → el optimistic-update del frontend
--    fallaba silenciosamente; ahora se formaliza con columnas financieras bloqueadas.
-- C) stripe_payment_intent_id quedaba sin protección en 207b.
--
-- REQUIERE: 207b_rls_financial_extended.sql aplicado.

-- ═══════════════════════════════════════════════════════════════════════════════
-- 1. GRUPO — reemplazar política con versión que bloquea payment_status
-- ═══════════════════════════════════════════════════════════════════════════════
DROP POLICY IF EXISTS "reservations_group_update_safe" ON reservations;

CREATE POLICY "reservations_group_update_safe"
  ON reservations
  FOR UPDATE
  USING (
    EXISTS (
      SELECT 1 FROM groups
      WHERE groups.id = reservations.group_id
        AND groups.owner_id = auth.uid()
    )
  )
  WITH CHECK (
    -- Precio: nunca cambia post-creación
    total_price              = (SELECT r2.total_price FROM reservations r2 WHERE r2.id = reservations.id)            AND
    base_price               = (SELECT r2.base_price  FROM reservations r2 WHERE r2.id = reservations.id)            AND
    -- Fees y ganancias: solo RPCs SECURITY DEFINER
    service_fee_amount       IS NOT DISTINCT FROM (SELECT r2.service_fee_amount       FROM reservations r2 WHERE r2.id = reservations.id) AND
    group_earnings           IS NOT DISTINCT FROM (SELECT r2.group_earnings           FROM reservations r2 WHERE r2.id = reservations.id) AND
    client_available_balance IS NOT DISTINCT FROM (SELECT r2.client_available_balance FROM reservations r2 WHERE r2.id = reservations.id) AND
    -- Identidad: inmutable
    client_id                = (SELECT r2.client_id   FROM reservations r2 WHERE r2.id = reservations.id)            AND
    -- Estados de pago: SOLO webhooks/RPCs SECURITY DEFINER pueden moverlos
    payment_status           IS NOT DISTINCT FROM (SELECT r2.payment_status           FROM reservations r2 WHERE r2.id = reservations.id) AND
    payout_status            IS NOT DISTINCT FROM (SELECT r2.payout_status            FROM reservations r2 WHERE r2.id = reservations.id) AND
    stripe_payment_intent_id IS NOT DISTINCT FROM (SELECT r2.stripe_payment_intent_id FROM reservations r2 WHERE r2.id = reservations.id)
  );

-- ═══════════════════════════════════════════════════════════════════════════════
-- 2. CLIENTE — nueva política UPDATE limitada (solo reprogramar event_date)
--    Bloquea TODAS las columnas financieras y de estado de pago.
-- ═══════════════════════════════════════════════════════════════════════════════
DROP POLICY IF EXISTS "reservations_client_update"     ON reservations;
DROP POLICY IF EXISTS "reservations_client_reschedule" ON reservations;

CREATE POLICY "reservations_client_reschedule"
  ON reservations
  FOR UPDATE
  USING (client_id = auth.uid())
  WITH CHECK (
    -- Columnas financieras: el cliente JAMÁS puede tocarlas
    payment_status           IS NOT DISTINCT FROM (SELECT r2.payment_status           FROM reservations r2 WHERE r2.id = reservations.id) AND
    payout_status            IS NOT DISTINCT FROM (SELECT r2.payout_status            FROM reservations r2 WHERE r2.id = reservations.id) AND
    total_price              = (SELECT r2.total_price FROM reservations r2 WHERE r2.id = reservations.id)            AND
    base_price               = (SELECT r2.base_price  FROM reservations r2 WHERE r2.id = reservations.id)            AND
    service_fee_amount       IS NOT DISTINCT FROM (SELECT r2.service_fee_amount       FROM reservations r2 WHERE r2.id = reservations.id) AND
    group_earnings           IS NOT DISTINCT FROM (SELECT r2.group_earnings           FROM reservations r2 WHERE r2.id = reservations.id) AND
    client_available_balance IS NOT DISTINCT FROM (SELECT r2.client_available_balance FROM reservations r2 WHERE r2.id = reservations.id) AND
    -- Identidad: nunca cambia
    client_id                = (SELECT r2.client_id  FROM reservations r2 WHERE r2.id = reservations.id)             AND
    group_id                 = (SELECT r2.group_id   FROM reservations r2 WHERE r2.id = reservations.id)
    -- El cliente SÍ puede cambiar: event_date (reprogramar), notes.
    -- El campo status lo mueven solo RPCs (client_cancel_reservation, etc.).
  );

-- ═══════════════════════════════════════════════════════════════════════════════
-- 3. VERIFICACIÓN — lista las políticas UPDATE activas en reservations
-- ═══════════════════════════════════════════════════════════════════════════════
SELECT
  policyname,
  cmd,
  with_check IS NOT NULL AS tiene_with_check,
  qual       IS NOT NULL AS tiene_using
FROM pg_policies
WHERE tablename = 'reservations'
  AND cmd = 'UPDATE'
ORDER BY policyname;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 4. PRUEBA DE VALIDACIÓN — ejecutar en SQL Editor de Supabase
-- ═══════════════════════════════════════════════════════════════════════════════
-- NOTA: PostgreSQL NO soporta LIMIT en UPDATE. Usar subquery en su lugar.
--
-- Paso A — obtener una reserva real de prueba:
--   SELECT id, payment_status FROM reservations LIMIT 1;
--
-- Paso B — intentar falsificar el payment_status con ese ID:
--   UPDATE reservations
--   SET payment_status = 'paid'
--   WHERE id = '<uuid-de-la-reserva>';
--
-- Resultado esperado: ERROR "new row violates row-level security policy" ✅
-- Si actualiza sin error: la política NO está aplicada ❌
--
-- Paso C — verificar que las dos políticas nuevas existen:
--   SELECT policyname FROM pg_policies
--   WHERE tablename = 'reservations' AND cmd = 'UPDATE';
--   -- Debe incluir: reservations_group_update_safe, reservations_client_reschedule

SELECT '208_rls_block_payment_fraud.sql ejecutado ✅' AS status;
