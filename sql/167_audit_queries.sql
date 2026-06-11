-- ════════════════════════════════════════════════════════════════════
-- 167_audit_queries.sql
-- Consultas de auditoría para detectar pérdida de dinero y duplicados.
-- NO modifica datos — solo SELECT / reportes.
--
-- EJECUTAR MANUALMENTE en el SQL editor de Supabase cuando necesites
-- validar la integridad del sistema financiero.
-- ════════════════════════════════════════════════════════════════════


-- ── A. Reservas completadas SIN comisión en wallet ──────────────────────────────
-- Eventos que generaron commission_amount > 0 pero no tienen
-- un wallet_transaction de tipo platform_income.
-- Estos representan DINERO PERDIDO que nunca llegó a la wallet.

SELECT
  r.id              AS reservation_id,
  r.status,
  r.commission_amount,
  r.event_date,
  r.group_id,
  g.name            AS group_name,
  g.city
FROM public.reservations r
LEFT JOIN public.groups g ON g.id = r.group_id
WHERE r.status = 'completed'
  AND COALESCE(r.commission_amount, 0) > 0
  AND NOT EXISTS (
    SELECT 1 FROM public.wallet_transactions wt
    WHERE wt.type = 'platform_income'
      AND wt.reference_id = r.id::TEXT
  )
ORDER BY r.event_date DESC;


-- ── B. Anuncios pagados SIN ad_income en wallet ─────────────────────────────────
-- Publicidad con mp_payment_id (pago confirmado) pero sin
-- wallet_transaction de tipo ad_income.

SELECT
  a.id              AS ad_id,
  a.title,
  a.type,
  a.status,
  a.mp_payment_id,
  a.updated_at,
  ap.price
FROM public.advertisements a
LEFT JOIN public.ad_packages ap ON ap.id = a.package_id
WHERE a.mp_payment_id IS NOT NULL
  AND a.mp_payment_id != ''
  AND COALESCE(ap.price, 0) > 0
  AND NOT EXISTS (
    SELECT 1 FROM public.wallet_transactions wt
    WHERE wt.reference_id = a.mp_payment_id
      AND wt.type = 'ad_income'
  )
ORDER BY a.updated_at DESC;


-- ── C. Bids pagados SIN bid_income en wallet ────────────────────────────────────
-- Órdenes de bidding con status = 'paid' sin wallet_transaction de tipo bid_income.

SELECT
  bo.id             AS order_id,
  bo.group_id,
  g.name            AS group_name,
  g.city,
  bo.amount,
  bo.mp_payment_id,
  bo.updated_at
FROM public.bid_orders bo
LEFT JOIN public.groups g ON g.id = bo.group_id
WHERE bo.status = 'paid'
  AND NOT EXISTS (
    SELECT 1 FROM public.wallet_transactions wt
    WHERE wt.type = 'bid_income'
      AND (
        wt.reference_id = bo.mp_payment_id
        OR wt.reference_id = 'bid_' || bo.id::TEXT
      )
  )
ORDER BY bo.updated_at DESC;


-- ── D. Recomendaciones pagadas SIN recommendation_income en wallet ──────────────

SELECT
  ro.id             AS order_id,
  ro.group_id,
  g.name            AS group_name,
  g.city,
  ro.amount,
  ro.mp_payment_id,
  ro.updated_at
FROM public.recommendation_orders ro
LEFT JOIN public.groups g ON g.id = ro.group_id
WHERE ro.status = 'paid'
  AND NOT EXISTS (
    SELECT 1 FROM public.wallet_transactions wt
    WHERE wt.type = 'recommendation_income'
      AND (
        wt.reference_id = ro.mp_payment_id
        OR wt.reference_id = 'rec_' || ro.id::TEXT
      )
  )
ORDER BY ro.updated_at DESC;


-- ── E. Transacciones duplicadas (mismo reference_id, tipo y usuario) ────────────
-- No debería devolver resultados si el UNIQUE INDEX funciona correctamente.

SELECT
  reference_id,
  type,
  user_id,
  COUNT(*)       AS duplicates,
  SUM(amount)    AS total_amount
FROM public.wallet_transactions
WHERE reference_id IS NOT NULL
GROUP BY reference_id, type, user_id
HAVING COUNT(*) > 1
ORDER BY duplicates DESC;


-- ── F. Balance de wallets vs SUM de wallet_transactions (consistencia) ──────────
-- Si la diferencia es > $1, el balance está desincronizado.

SELECT
  w.user_id,
  p.full_name,
  w.available_balance   AS wallet_balance,
  COALESCE(SUM(CASE WHEN wt.type != 'withdrawal' THEN wt.amount ELSE -wt.amount END), 0)
    AS calculated_balance,
  w.available_balance
    - COALESCE(SUM(CASE WHEN wt.type != 'withdrawal' THEN wt.amount ELSE -wt.amount END), 0)
    AS discrepancy
FROM public.wallets w
LEFT JOIN public.profiles p ON p.id = w.user_id
LEFT JOIN public.wallet_transactions wt ON wt.user_id = w.user_id AND wt.status = 'completed'
GROUP BY w.user_id, p.full_name, w.available_balance
HAVING ABS(
  w.available_balance
  - COALESCE(SUM(CASE WHEN wt.type != 'withdrawal' THEN wt.amount ELSE -wt.amount END), 0)
) > 1
ORDER BY ABS(w.available_balance
  - COALESCE(SUM(CASE WHEN wt.type != 'withdrawal' THEN wt.amount ELSE -wt.amount END), 0)
) DESC;


-- ── G. Resumen de ingresos por tipo (validación rápida) ─────────────────────────

SELECT
  type,
  COUNT(*)          AS transactions,
  SUM(amount)       AS total_amount,
  MIN(created_at)   AS first_at,
  MAX(created_at)   AS last_at
FROM public.wallet_transactions
WHERE status = 'completed'
GROUP BY type
ORDER BY total_amount DESC;


-- ── H. Top 10 reference_id con mayor monto ──────────────────────────────────────

SELECT
  reference_id,
  type,
  SUM(amount)  AS total,
  COUNT(*)     AS count
FROM public.wallet_transactions
WHERE reference_id IS NOT NULL
GROUP BY reference_id, type
ORDER BY total DESC
LIMIT 10;


SELECT '167_audit_queries.sql — Solo lectura. Sin cambios en datos.' AS nota;
