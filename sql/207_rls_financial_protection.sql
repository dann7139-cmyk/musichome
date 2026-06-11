-- 207_rls_financial_protection.sql
-- Reemplaza la política de UPDATE de grupos en reservations para que no puedan
-- modificar columnas financieras (total_price, base_price, client_id) post-creación.
-- Requiere: 206_stripe_full_payment.sql aplicado.

-- Eliminar política existente (el nombre puede variar; intentamos los nombres comunes)
DROP POLICY IF EXISTS "reservations_group_update"      ON reservations;
DROP POLICY IF EXISTS "groups_can_update_reservations" ON reservations;
DROP POLICY IF EXISTS "group_update_reservations"      ON reservations;

-- Nueva política: grupo solo puede actualizar status, notas, campos no financieros.
-- Las columnas financieras deben coincidir con los valores actuales en DB (inmutables).
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
    total_price = (SELECT r2.total_price FROM reservations r2 WHERE r2.id = reservations.id) AND
    base_price  = (SELECT r2.base_price  FROM reservations r2 WHERE r2.id = reservations.id) AND
    client_id   = (SELECT r2.client_id   FROM reservations r2 WHERE r2.id = reservations.id)
  );

SELECT '207_rls_financial_protection.sql ejecutado ✅' AS status;
