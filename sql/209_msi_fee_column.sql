-- 209_msi_fee_column.sql
-- Agrega columnas para tracking de MSI en reservas.
--
-- msi_months     — número de meses seleccionados (NULL = pago único)
-- msi_fee_amount — cargo adicional MSI (no reduce group_earnings)
--
-- IMPORTANTE: estas columnas son de solo lectura para clientes/grupos.
-- Solo el service_role (create-payment-intent) las escribe.

ALTER TABLE reservations
  ADD COLUMN IF NOT EXISTS msi_months     int     NULL,
  ADD COLUMN IF NOT EXISTS msi_fee_amount numeric NULL DEFAULT 0;

-- Índice para reportes de MSI y GMV desagregado
CREATE INDEX IF NOT EXISTS idx_reservations_msi_months
  ON reservations(msi_months)
  WHERE msi_months IS NOT NULL;

-- Proteger msi_fee_amount en RLS de cliente (no puede modificar)
-- La política reservations_client_reschedule de 208 ya bloquea columnas no listadas
-- en WITH CHECK. Las columnas nuevas tampoco son listadas allí, por lo que
-- no hay camino para que el cliente las modifique. ✅

SELECT '209_msi_fee_column.sql ejecutado ✅' AS status;
