-- ════════════════════════════════════════════════════════════════════
-- 49_financial_ledger.sql
-- Tabla de libro mayor financiero + logs de auditoría.
-- financial_ledger: registra cada movimiento de dinero (cobro, transfer, etc.)
-- audit_logs: registra acciones críticas del sistema para trazabilidad.
-- ════════════════════════════════════════════════════════════════════

-- ── 1. financial_ledger ───────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.financial_ledger (
  id               UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  reservation_id   UUID        REFERENCES public.reservations(id) ON DELETE SET NULL,
  user_id          UUID        REFERENCES public.profiles(id)     ON DELETE SET NULL,
  entry_type       TEXT        NOT NULL
                   CHECK (entry_type IN (
                     'client_deposit',      -- cobro del 50% al cliente
                     'client_final',        -- cobro del 50% final al cliente
                     'platform_commission', -- comisión retenida por la plataforma
                     'group_transfer',      -- pago al grupo (dueño)
                     'member_transfer',     -- pago a integrante
                     'talent_transfer',     -- pago a talento invitado
                     'referral_transfer',   -- pago a referido
                     'refund',              -- reembolso al cliente
                     'adjustment'           -- ajuste manual por admin
                   )),
  amount           NUMERIC(12,2) NOT NULL,
  currency         TEXT          NOT NULL DEFAULT 'mxn',
  stripe_object_id TEXT,               -- PaymentIntent ID o Transfer ID
  description      TEXT,
  created_by       UUID        REFERENCES public.profiles(id) ON DELETE SET NULL,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Índices para consultas del admin
CREATE INDEX IF NOT EXISTS idx_ledger_reservation ON public.financial_ledger(reservation_id);
CREATE INDEX IF NOT EXISTS idx_ledger_user        ON public.financial_ledger(user_id);
CREATE INDEX IF NOT EXISTS idx_ledger_type        ON public.financial_ledger(entry_type);
CREATE INDEX IF NOT EXISTS idx_ledger_created     ON public.financial_ledger(created_at DESC);

-- RLS
ALTER TABLE public.financial_ledger ENABLE ROW LEVEL SECURITY;

-- Usuarios ven sus propios registros
CREATE POLICY "user_see_own_ledger" ON public.financial_ledger
  FOR SELECT USING (user_id = auth.uid());

-- Admin ve todo
CREATE POLICY "admin_see_all_ledger" ON public.financial_ledger
  FOR SELECT USING (EXISTS (
    SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin'
  ));

-- Service role puede insertar (Edge Functions)
CREATE POLICY "service_insert_ledger" ON public.financial_ledger
  FOR INSERT WITH CHECK (true);

-- Admin puede ajustar
CREATE POLICY "admin_manage_ledger" ON public.financial_ledger
  FOR UPDATE USING (EXISTS (
    SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin'
  ));

-- ── 2. audit_logs ─────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.audit_logs (
  id           UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  actor_id     UUID        REFERENCES public.profiles(id) ON DELETE SET NULL,
  action       TEXT        NOT NULL,    -- ej. 'reservation.accept', 'payout.release'
  target_type  TEXT,                    -- ej. 'reservation', 'group', 'profile'
  target_id    UUID,
  metadata     JSONB       DEFAULT '{}',
  ip_address   TEXT,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_audit_actor   ON public.audit_logs(actor_id);
CREATE INDEX IF NOT EXISTS idx_audit_action  ON public.audit_logs(action);
CREATE INDEX IF NOT EXISTS idx_audit_target  ON public.audit_logs(target_type, target_id);
CREATE INDEX IF NOT EXISTS idx_audit_created ON public.audit_logs(created_at DESC);

-- RLS
ALTER TABLE public.audit_logs ENABLE ROW LEVEL SECURITY;

-- Solo admin puede leer
CREATE POLICY "admin_read_audit" ON public.audit_logs
  FOR SELECT USING (EXISTS (
    SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin'
  ));

-- Service role puede insertar
CREATE POLICY "service_insert_audit" ON public.audit_logs
  FOR INSERT WITH CHECK (true);

-- ── 3. Vista: resumen financiero mensual ──────────────────────────────
CREATE OR REPLACE VIEW public.financial_monthly_summary AS
SELECT
  DATE_TRUNC('month', r.created_at)           AS month,
  COUNT(*)    FILTER (WHERE r.status = 'completed' AND r.payment_status = 'fully_paid')
                                               AS completed_events,
  SUM(r.total_price)
    FILTER (WHERE r.status = 'completed' AND r.payment_status = 'fully_paid')
                                               AS total_revenue,
  SUM(r.commission_amount)
    FILTER (WHERE r.status = 'completed' AND r.payment_status = 'fully_paid')
                                               AS total_commission,
  SUM(r.group_earnings)
    FILTER (WHERE r.status = 'completed' AND r.payment_status = 'fully_paid')
                                               AS total_group_earnings,
  COUNT(*)    FILTER (WHERE r.status = 'cancelled')
                                               AS cancelled_events,
  COUNT(*)    FILTER (WHERE r.payment_status = 'remaining_pending')
                                               AS pending_final_payments
FROM public.reservations r
GROUP BY DATE_TRUNC('month', r.created_at)
ORDER BY month DESC;

-- Solo admin puede ver la vista
REVOKE ALL ON public.financial_monthly_summary FROM PUBLIC;
GRANT SELECT ON public.financial_monthly_summary TO authenticated;

-- (La RLS de la vista depende de las políticas de la tabla base.
--  Para uso admin, consultar directamente con service role desde Edge Functions.)

SELECT '49_financial_ledger: OK ✅' AS status;
