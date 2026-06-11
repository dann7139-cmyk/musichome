-- 207b_rls_financial_extended.sql
-- Extiende la protección financiera del 207 original.
-- Agrega: service_fee_amount, group_earnings, payout_status, client_available_balance.
-- Requiere: 207_rls_financial_protection.sql aplicado.

-- Reemplazar la política existente con una versión extendida.
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
    -- Columnas de precio: inmutables post-creación
    total_price              = (SELECT r2.total_price              FROM reservations r2 WHERE r2.id = reservations.id) AND
    base_price               = (SELECT r2.base_price               FROM reservations r2 WHERE r2.id = reservations.id) AND
    -- Columnas de fees y ganancias: solo backend/RPC puede tocar
    service_fee_amount       IS NOT DISTINCT FROM (SELECT r2.service_fee_amount       FROM reservations r2 WHERE r2.id = reservations.id) AND
    group_earnings           IS NOT DISTINCT FROM (SELECT r2.group_earnings           FROM reservations r2 WHERE r2.id = reservations.id) AND
    client_available_balance IS NOT DISTINCT FROM (SELECT r2.client_available_balance FROM reservations r2 WHERE r2.id = reservations.id) AND
    -- Columnas de identidad: nunca deben cambiar
    client_id                = (SELECT r2.client_id                FROM reservations r2 WHERE r2.id = reservations.id) AND
    -- payout_status: solo el sistema de wallets puede moverlo (held/released/refunded)
    payout_status            IS NOT DISTINCT FROM (SELECT r2.payout_status            FROM reservations r2 WHERE r2.id = reservations.id)
  );

-- Verificación: listar todas las políticas UPDATE activas en reservations
SELECT policyname, cmd, with_check IS NOT NULL AS tiene_with_check
FROM pg_policies
WHERE tablename = 'reservations'
  AND cmd = 'UPDATE'
ORDER BY policyname;

SELECT '207b_rls_financial_extended.sql ejecutado ✅' AS status;
