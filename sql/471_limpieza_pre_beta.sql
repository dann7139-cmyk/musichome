-- ============================================================
-- sql/471_limpieza_pre_beta.sql
-- 🧹 BORRÓN Y CUENTA NUEVA antes de la beta cerrada (v0.9.0-beta).
--
-- BORRA todo lo transaccional generado en las pruebas:
--   reservas, cotizaciones, solicitudes express, eventos, reembolsos
--   manuales, retiros, movimientos de wallet, notificaciones, disputas,
--   strikes, logs de pago y auditoría financiera.
-- CONSERVA: usuarios/perfiles, grupos, anuncios/config, políticas, RPCs.
-- RESETEA: saldos de wallets (grupo y admin) a CERO.
--
-- ⚠️ IRREVERSIBLE. Correr SOLO cuando ya no necesites los datos de prueba.
-- ============================================================

BEGIN;

DO $$
DECLARE
  r RECORD;
  v_res INT; v_quo INT;
BEGIN
  SET LOCAL session_replication_role = replica;   -- sin triggers durante la limpieza

  SELECT COUNT(*) INTO v_res FROM reservations;
  SELECT COUNT(*) INTO v_quo FROM quotes;

  -- 1. Hijas de reservations (detectadas por FK, cubre tablas futuras)
  FOR r IN
    SELECT tc.table_name, kcu.column_name
    FROM information_schema.table_constraints tc
    JOIN information_schema.key_column_usage kcu
      ON kcu.constraint_name = tc.constraint_name AND kcu.table_schema = tc.table_schema
    JOIN information_schema.constraint_column_usage ccu
      ON ccu.constraint_name = tc.constraint_name AND ccu.table_schema = tc.table_schema
    WHERE tc.constraint_type = 'FOREIGN KEY'
      AND ccu.table_name = 'reservations' AND ccu.column_name = 'id'
      AND tc.table_schema = 'public'
  LOOP
    EXECUTE format('DELETE FROM public.%I WHERE %I IS NOT NULL', r.table_name, r.column_name);
  END LOOP;

  -- 2. Transaccional principal
  DELETE FROM reservations;
  DELETE FROM quotes;
  DELETE FROM event_requests;
  DELETE FROM events;

  -- 3. Colas y ledgers financieros de prueba
  DELETE FROM manual_refunds;
  DELETE FROM withdrawals;
  DELETE FROM wallet_transactions;
  DELETE FROM payment_event_logs;
  DELETE FROM financial_audit_logs;

  -- 4. Social/operativo de prueba
  DELETE FROM notifications;
  DELETE FROM disputes;
  DELETE FROM group_strikes;
  DELETE FROM reviews;

  RAISE NOTICE 'Eliminadas % reservas y % cotizaciones de prueba', v_res, v_quo;
EXCEPTION WHEN undefined_table THEN
  RAISE NOTICE 'Alguna tabla opcional no existe — continúa sin problema: %', SQLERRM;
END $$;

-- 5. Wallets en CERO (grupos y admin) — la beta arranca limpia
UPDATE group_wallets SET
  pending_balance = 0, available_balance = 0,
  pending_balance_usd = 0, available_balance_usd = 0,
  total_earned = 0, updated_at = NOW();

UPDATE wallets SET
  available_balance = 0, total_earned = 0, updated_at = NOW();

COMMIT;

-- ── VERIFICACIÓN FINAL — todo debe dar CERO ──────────────────────────────────
SELECT
  (SELECT COUNT(*) FROM reservations)        AS reservas,
  (SELECT COUNT(*) FROM quotes)              AS cotizaciones,
  (SELECT COUNT(*) FROM event_requests)      AS solicitudes,
  (SELECT COUNT(*) FROM manual_refunds)      AS reembolsos,
  (SELECT COUNT(*) FROM withdrawals)         AS retiros,
  (SELECT COUNT(*) FROM wallet_transactions) AS movimientos,
  (SELECT COUNT(*) FROM notifications)       AS notificaciones,
  (SELECT COALESCE(SUM(pending_balance + available_balance), 0) FROM group_wallets) AS saldos_grupos;

-- Lo que se CONSERVÓ (revisa que tus cuentas y grupos sigan)
SELECT (SELECT COUNT(*) FROM profiles) AS perfiles,
       (SELECT COUNT(*) FROM groups)   AS grupos;

SELECT '471_limpieza_pre_beta.sql ejecutado ✅ — base lista para la beta' AS status;
