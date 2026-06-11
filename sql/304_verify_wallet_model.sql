-- ════════════════════════════════════════════════════════════════════
-- 304_verify_wallet_model.sql
--
-- Auditoría post-migración. Ejecutar DESPUÉS de 300-303.
-- No modifica nada. Solo verifica el estado del sistema.
--
-- NOTAS DE SCHEMA:
--   wallet_transactions (184a): group_wallet_id, group_id, type, amount,
--     reservation_id, description, balance_after. SIN user_id, status, reference_event_id.
--   wallets (59): user_id, available_balance, pending_balance. Para admin/owner individual.
--
-- Ejecutar en Supabase SQL Editor y revisar los resultados.
-- ════════════════════════════════════════════════════════════════════

-- ── 1. Verificar columna is_informational en event_payouts ────────────────────
SELECT
  '1. is_informational en event_payouts' AS check_name,
  role,
  is_informational,
  COUNT(*) AS total
FROM public.event_payouts
GROUP BY role, is_informational
ORDER BY role, is_informational;

-- ── 2. Verificar que ningún member/invited tiene is_informational=FALSE ────────
SELECT
  '2. members/invited con payout REAL (DEBE SER 0)' AS check_name,
  COUNT(*) AS total_incorrecto
FROM public.event_payouts
WHERE role IN ('member', 'invited')
  AND is_informational = FALSE;

-- ── 3. Verificar wallets individuales con saldo (admin y owners legacy) ────────
SELECT
  '3. Wallets individuales con saldo (admin=ok, otros=revisar)' AS check_name,
  p.role,
  COUNT(*) AS wallets_con_saldo,
  SUM(w.available_balance) AS total_disponible,
  SUM(w.pending_balance)   AS total_pendiente
FROM public.wallets w
JOIN public.profiles p ON p.id = w.user_id
WHERE w.available_balance > 0 OR w.pending_balance > 0
GROUP BY p.role
ORDER BY wallets_con_saldo DESC;

-- ── 4. Verificar group_wallets activos ────────────────────────────────────────
SELECT
  '4. Group wallets activos' AS check_name,
  COUNT(*)                   AS total_grupos,
  SUM(gw.available_balance)  AS total_disponible,
  SUM(gw.pending_balance)    AS total_pendiente
FROM public.group_wallets gw;

-- ── 5. Verificar wallet_transactions del grupo (schema 184a) ──────────────────
-- Muestra distribución de tipos. credit_available y credit_pending son los importantes.
SELECT
  '5. wallet_transactions por tipo (group-based, 184a)' AS check_name,
  wt.type,
  COUNT(*)        AS total,
  SUM(wt.amount)  AS total_monto
FROM public.wallet_transactions wt
GROUP BY wt.type
ORDER BY total DESC;

-- ── 6. Verificar que credit_extra_hour_earnings solo va al owner ──────────────
-- extra_hour va a wallets individual (tabla de 59), no a wallet_transactions (184a)
SELECT
  '6. Wallets individuales con ganancia extra_hour (solo owner/admin esperado)' AS check_name,
  p.role,
  p.full_name,
  w.available_balance,
  w.total_earned
FROM public.wallets w
JOIN public.profiles p ON p.id = w.user_id
WHERE w.total_earned > 0
ORDER BY w.total_earned DESC
LIMIT 20;

-- ── 7. Verificar que NO hay wallet_transactions de tipo event_earning ──────────
-- La tabla vieja (59) tenía type='event_earning'. La nueva (184a) no lo tiene.
-- Si aparece event_earning, hay datos de esquema mezclados.
SELECT
  '7. Tipos legacy en wallet_transactions (debe ser 0)' AS check_name,
  COUNT(*) AS total_legacy
FROM public.wallet_transactions
WHERE type NOT IN (
  'credit_pending', 'credit_available',
  'release_to_available', 'debit_payout',
  'refund_dispute', 'adjustment'
);

-- ── 8. Verificar trigger activo ───────────────────────────────────────────────
SELECT
  '8. Trigger generate_event_payouts (debe existir y estar activo)' AS check_name,
  tgname    AS trigger_name,
  tgenabled AS enabled
FROM pg_trigger
WHERE tgname = 'trigger_generate_event_payouts';

-- ── 9. Verificar que backfill fue eliminado ───────────────────────────────────
SELECT
  '9. backfill_missing_member_payouts eliminado (DEBE SER 0)' AS check_name,
  COUNT(*) AS existe
FROM pg_proc
WHERE proname = 'backfill_missing_member_payouts';

-- ── 10. Verificar reservas en held > 12h (pending de liberar) ────────────────
SELECT
  '10. Reservas en held > 12h esperando release' AS check_name,
  COUNT(*) AS total_pendientes
FROM public.reservations r
WHERE r.payment_status IN ('paid','fully_paid','deposit_paid')
  AND r.payout_status = 'held'
  AND r.event_date IS NOT NULL
  AND (r.event_date::TEXT || ' ' || COALESCE(r.event_time::TEXT, '23:59:59'))::TIMESTAMP
      AT TIME ZONE 'America/Mexico_City' + INTERVAL '12 hours' < NOW()
  AND NOT EXISTS (
    SELECT 1 FROM public.disputes d
    WHERE d.reservation_id = r.id AND d.status IN ('open','under_review')
  );

-- ── 11. Verificar constraint de tipos en wallet_transactions ─────────────────
SELECT
  '11. Constraint chk_wt_type actual' AS check_name,
  pg_get_constraintdef(c.oid) AS constraint_def
FROM pg_constraint c
JOIN pg_class t ON t.oid = c.conrelid
WHERE c.conname = 'chk_wt_type'
  AND t.relname = 'wallet_transactions';

-- ── 12. Verificar que mp_credit_pending_earnings acredita solo grupos ──────────
SELECT
  '12. credit_pending por reserva (debe ser 1 o 0 por reserva, nunca múltiples)' AS check_name,
  reservation_id,
  COUNT(*) AS total_por_reserva
FROM public.wallet_transactions
WHERE type = 'credit_pending'
  AND group_id IS NOT NULL
GROUP BY reservation_id
HAVING COUNT(*) > 1
LIMIT 10;

SELECT '304_verify_wallet_model: auditoría completa ejecutada ✅' AS status;
