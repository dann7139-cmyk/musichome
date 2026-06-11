-- ════════════════════════════════════════════════════════════════════
-- 172_reconcile_wallet_transactions.sql
-- Reconcilia ingresos perdidos: inserta wallet_transactions faltantes
-- para recommendation_orders y bid_orders que ya están como 'paid'
-- pero no tienen su registro en wallet_transactions.
--
-- Usa WHERE NOT EXISTS en lugar de ON CONFLICT (no hay UNIQUE en reference_id)
-- Seguro e idempotente: si se ejecuta dos veces no duplica nada.
-- ════════════════════════════════════════════════════════════════════

DO $$
DECLARE
  v_order RECORD;
  v_admin RECORD;
  v_ref   TEXT;
  v_cnt_rec  INT := 0;
  v_cnt_bid  INT := 0;
BEGIN

  -- ── 1. recommendation_orders pagadas sin wallet ────────────────────
  FOR v_order IN
    SELECT ro.id, ro.group_id, ro.amount, ro.duration_days,
           ro.stripe_payment_id,
           g.name  AS group_name,
           g.city  AS group_city
    FROM   public.recommendation_orders ro
    LEFT JOIN public.groups g ON g.id = ro.group_id
    WHERE  ro.status = 'paid'
      AND  NOT EXISTS (
        SELECT 1 FROM public.wallet_transactions wt
        WHERE wt.type = 'recommendation_income'
          AND (wt.reference_id = 'rec_' || ro.id::TEXT
               OR (ro.stripe_payment_id IS NOT NULL
                   AND wt.reference_id = ro.stripe_payment_id))
      )
  LOOP
    v_ref := COALESCE(NULLIF(v_order.stripe_payment_id, ''), 'rec_' || v_order.id::TEXT);
    v_cnt_rec := v_cnt_rec + 1;

    FOR v_admin IN SELECT id FROM public.profiles WHERE role = 'admin' LOOP
      -- Asegurar wallet del admin
      INSERT INTO public.wallets (user_id)
      VALUES (v_admin.id)
      ON CONFLICT (user_id) DO NOTHING;

      -- Solo insertar si no existe ya (deduplicación con WHERE NOT EXISTS)
      INSERT INTO public.wallet_transactions
        (user_id, amount, type, status, reference_id, description)
      SELECT
        v_admin.id,
        v_order.amount,
        'recommendation_income',
        'completed',
        v_ref,
        'Recomendación (reconciliado): '
          || COALESCE(v_order.group_name, v_order.group_id::TEXT)
          || ' · ' || v_order.duration_days || 'd'
          || CASE WHEN v_order.group_city IS NOT NULL
                  THEN ' (' || v_order.group_city || ')' ELSE '' END
      WHERE NOT EXISTS (
        SELECT 1 FROM public.wallet_transactions
        WHERE reference_id = v_ref
          AND user_id      = v_admin.id
      );

      -- Actualizar saldo solo si se insertó la transacción
      UPDATE public.wallets
      SET available_balance = available_balance + v_order.amount,
          total_earned      = total_earned      + v_order.amount,
          updated_at        = NOW()
      WHERE user_id = v_admin.id
        AND NOT EXISTS (
          SELECT 1 FROM public.wallet_transactions
          WHERE reference_id = v_ref
            AND user_id      = v_admin.id
            AND created_at   < NOW() - INTERVAL '1 second'
        );
    END LOOP;
  END LOOP;

  -- ── 2. bid_orders pagadas sin wallet ──────────────────────────────
  FOR v_order IN
    SELECT bo.id, bo.group_id, bo.amount,
           g.name AS group_name
    FROM   public.bid_orders bo
    LEFT JOIN public.groups g ON g.id = bo.group_id
    WHERE  bo.status = 'paid'
      AND  NOT EXISTS (
        SELECT 1 FROM public.wallet_transactions wt
        WHERE wt.type        = 'bid_income'
          AND wt.reference_id = 'bid_' || bo.id::TEXT
      )
  LOOP
    v_cnt_bid := v_cnt_bid + 1;

    FOR v_admin IN SELECT id FROM public.profiles WHERE role = 'admin' LOOP
      INSERT INTO public.wallets (user_id)
      VALUES (v_admin.id)
      ON CONFLICT (user_id) DO NOTHING;

      INSERT INTO public.wallet_transactions
        (user_id, amount, type, status, reference_id, description)
      SELECT
        v_admin.id,
        v_order.amount,
        'bid_income',
        'completed',
        'bid_' || v_order.id::TEXT,
        'Posicionamiento (reconciliado): '
          || COALESCE(v_order.group_name, v_order.group_id::TEXT)
      WHERE NOT EXISTS (
        SELECT 1 FROM public.wallet_transactions
        WHERE reference_id = 'bid_' || v_order.id::TEXT
          AND user_id      = v_admin.id
      );

      UPDATE public.wallets
      SET available_balance = available_balance + v_order.amount,
          total_earned      = total_earned      + v_order.amount,
          updated_at        = NOW()
      WHERE user_id = v_admin.id
        AND NOT EXISTS (
          SELECT 1 FROM public.wallet_transactions
          WHERE reference_id = 'bid_' || v_order.id::TEXT
            AND user_id      = v_admin.id
            AND created_at   < NOW() - INTERVAL '1 second'
        );
    END LOOP;
  END LOOP;

  RAISE NOTICE '172 reconciliación: % rec_orders + % bid_orders sin wallet → procesados',
    v_cnt_rec, v_cnt_bid;
END $$;

-- ── Verificar resultado ───────────────────────────────────────────────────────
SELECT
  type,
  COUNT(*)    AS transacciones,
  SUM(amount) AS total
FROM public.wallet_transactions
WHERE type IN ('recommendation_income', 'bid_income', 'ad_income')
  AND status = 'completed'
GROUP BY type
ORDER BY type;

SELECT '172_reconcile_wallet_transactions.sql ejecutado ✅' AS status;
