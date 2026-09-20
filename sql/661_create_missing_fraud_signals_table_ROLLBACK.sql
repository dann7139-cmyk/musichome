-- ROLLBACK de sql/661_create_missing_fraud_signals_table.sql
-- ADVERTENCIA: si se corre esto, guard_quote_spam() vuelve a tronar con un
-- error crudo en vez del mensaje amable cuando un cliente llegue a 15
-- cotizaciones en 24h. Solo usar en una emergencia deliberada.
DROP TABLE IF EXISTS public.fraud_signals;
