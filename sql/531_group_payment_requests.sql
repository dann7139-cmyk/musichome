-- ============================================================
-- sql/531_group_payment_requests.sql
-- Fase P1D — "Retirar" → "Solicitar pago" (aviso administrativo, cero dinero)
--
-- REGLAS DEFINITIVAS:
--   1. El grupo NO retira dinero — solo avisa "quiero que me pagues esta
--      reserva". La transferencia real la sigue haciendo el admin (P1E).
--   2. group_request_payment() NO toca group_wallets, wallet_transactions
--      ni withdrawals — verificado explícitamente en las pruebas.
--   3. group_id SIEMPRE derivado de reservations.group_id, jamás parámetro.
--   4. Solo una solicitud 'pending' activa por reservation_id (UNIQUE
--      parcial) — pero se conserva historial completo (completed/cancelled
--      no bloquean una nueva pending).
--   5. payment_requested (para UI de grupo y badge de admin) = existe una
--      solicitud con status='pending' — una solicitud histórica cerrada
--      NUNCA produce ese indicador.
--   6. Requiere los 3 datos bancarios completos (CLABE válida + banco +
--      titular), no solo CLABE no nula.
--
-- DEUDA TÉCNICA DOCUMENTADA (fuera de alcance de esta fase, no se toca):
--   src/screens/admin/DashboardScreen.tsx también navega a 'Withdraw' para
--   que el ADMIN retire su propia comisión (tabla wallets, no
--   group_wallets). request_withdrawal() solo resuelve
--   `groups WHERE owner_id = auth.uid()` — no tiene rama para el wallet
--   personal de un admin, así que ese botón probablemente ya falla hoy
--   con 'no_group' si el admin no posee un grupo. No se arregla aquí.
--
-- Rollback: sql/531_group_payment_requests_ROLLBACK.sql
-- ============================================================

BEGIN;

-- ── 1. Tabla ──────────────────────────────────────────────────────────────
CREATE TABLE public.group_payment_requests (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  reservation_id    UUID NOT NULL REFERENCES reservations(id) ON DELETE CASCADE,
  group_id          UUID NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
  requested_by      UUID NOT NULL REFERENCES profiles(id),
  status            TEXT NOT NULL DEFAULT 'pending',
  requested_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  seen_by_admin_at  TIMESTAMPTZ
);

ALTER TABLE public.group_payment_requests
  ADD CONSTRAINT chk_grp_pay_req_status CHECK (status IN ('pending','completed','cancelled'));
-- 'completed' NO se usa todavía en esta fase — lo activará P1E cuando
-- registre el pago final. Esquema preparado, sin lógica financiera aquí.

CREATE UNIQUE INDEX uq_grp_pay_req_active
  ON public.group_payment_requests(reservation_id)
  WHERE status = 'pending';

CREATE INDEX idx_grp_pay_req_group ON public.group_payment_requests(group_id);

-- ── 2. RLS — solo lectura desde cliente, cero escritura directa ───────────
ALTER TABLE public.group_payment_requests ENABLE ROW LEVEL SECURITY;

REVOKE INSERT, UPDATE, DELETE ON public.group_payment_requests FROM authenticated, anon;
GRANT SELECT ON public.group_payment_requests TO authenticated;

CREATE POLICY grp_pay_req_admin_read ON public.group_payment_requests FOR SELECT
  USING (EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin'));

CREATE POLICY grp_pay_req_owner_read ON public.group_payment_requests FOR SELECT
  USING (EXISTS (SELECT 1 FROM groups g WHERE g.id = group_id AND g.owner_id = auth.uid()));

-- Deliberadamente NINGUNA policy de INSERT/UPDATE/DELETE.

-- ── 3. RPC de escritura — único punto de entrada, admin-free (lo usa el grupo) ──
CREATE OR REPLACE FUNCTION public.group_request_payment(p_reservation_id UUID)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE
  v_res      RECORD;
  v_saldo    NUMERIC;
  v_existing RECORD;
  v_new_id   UUID;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_authenticated');
  END IF;

  SELECT r.*, g.owner_id INTO v_res
  FROM reservations r JOIN groups g ON g.id = r.group_id
  WHERE r.id = p_reservation_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_found');
  END IF;

  IF v_res.owner_id <> auth.uid() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_owner');
  END IF;

  IF v_res.payout_status <> 'released' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_released');
  END IF;

  SELECT v_res.group_earnings - COALESCE(SUM(amount), 0) INTO v_saldo
  FROM group_reservation_payments WHERE reservation_id = p_reservation_id;
  IF v_saldo IS NULL OR v_saldo <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_balance_due');
  END IF;

  -- [P1D] Datos bancarios completos: CLABE válida (18 dígitos, mismo
  -- criterio que save_bank_account) + banco + titular no vacíos.
  IF NOT EXISTS (
    SELECT 1 FROM wallets w
    WHERE w.user_id = v_res.owner_id
      AND w.bank_clabe IS NOT NULL AND length(w.bank_clabe) = 18 AND w.bank_clabe ~ '^\d{18}$'
      AND w.bank_name IS NOT NULL AND length(trim(w.bank_name)) > 0
      AND w.account_holder IS NOT NULL AND length(trim(w.account_holder)) > 0
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'missing_bank_data');
  END IF;

  -- Idempotencia: solo una solicitud 'pending' activa por reserva
  SELECT * INTO v_existing FROM group_payment_requests
  WHERE reservation_id = p_reservation_id AND status = 'pending';
  IF FOUND THEN
    RETURN jsonb_build_object('ok', true, 'already_requested', true, 'request_id', v_existing.id);
  END IF;

  BEGIN
    INSERT INTO group_payment_requests (reservation_id, group_id, requested_by, status)
    VALUES (p_reservation_id, v_res.group_id, auth.uid(), 'pending')
    RETURNING id INTO v_new_id;
  EXCEPTION WHEN unique_violation THEN
    SELECT id INTO v_new_id FROM group_payment_requests
    WHERE reservation_id = p_reservation_id AND status = 'pending';
    RETURN jsonb_build_object('ok', true, 'already_requested', true, 'request_id', v_new_id);
  END;

  INSERT INTO notifications (user_id, type, title, body, data)
  SELECT p.id, 'payment', '📢 Grupo solicita su pago',
    format('%s solicita el pago de su evento del %s%s.',
      (SELECT name FROM groups WHERE id = v_res.group_id),
      v_res.event_date,
      CASE WHEN v_res.folio IS NOT NULL THEN format(' (folio %s)', v_res.folio) ELSE '' END),
    jsonb_build_object('reservation_id', p_reservation_id, 'screen', 'AdminFinancial')
  FROM profiles p WHERE p.role = 'admin';

  RETURN jsonb_build_object('ok', true, 'already_requested', false, 'request_id', v_new_id);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.group_request_payment(UUID) TO authenticated;

-- ── 4. RPC de lectura — lista del grupo ────────────────────────────────────
CREATE OR REPLACE FUNCTION public.group_get_payable_reservations()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE v_result jsonb;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_authenticated');
  END IF;

  SELECT jsonb_build_object('ok', true, 'items', COALESCE(jsonb_agg(x.item ORDER BY x.event_date DESC NULLS LAST), '[]'::jsonb))
  INTO v_result
  FROM (
    SELECT r.event_date, jsonb_build_object(
      'reservation_id',   r.id,
      'folio',            r.folio,
      'event_date',       r.event_date,
      'group_earnings',   r.group_earnings,
      'total_anticipado', COALESCE(gp.total_anticipado, 0),
      'saldo_pendiente',  r.group_earnings - COALESCE(gp.total_anticipado, 0),
      'payment_requested', (pr.id IS NOT NULL)
    ) AS item
    FROM reservations r
    JOIN groups g ON g.id = r.group_id
    LEFT JOIN LATERAL (
      SELECT SUM(amount) AS total_anticipado FROM group_reservation_payments WHERE reservation_id = r.id
    ) gp ON true
    -- [P1D corrección] SOLO status='pending' cuenta como solicitud activa
    LEFT JOIN group_payment_requests pr ON pr.reservation_id = r.id AND pr.status = 'pending'
    WHERE g.owner_id = auth.uid()
      AND r.payout_status = 'released'
      AND (r.group_earnings - COALESCE(gp.total_anticipado, 0)) > 0
    ORDER BY r.event_date DESC NULLS LAST
  ) x;

  RETURN v_result;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.group_get_payable_reservations() TO authenticated;

-- ── 5. Actualizar P1B/P1C para el badge de admin (solo status='pending') ──
CREATE OR REPLACE FUNCTION public.admin_get_pending_group_payments(p_limit integer DEFAULT 50)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_result jsonb;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;

  SELECT jsonb_build_object(
    'ok', true,
    'items', COALESCE(jsonb_agg(x.item ORDER BY x.event_date DESC NULLS LAST), '[]'::jsonb)
  )
  INTO v_result
  FROM (
    SELECT
      r.event_date,
      jsonb_build_object(
        'reservation_id',   r.id,
        'folio',            r.folio,
        'event_date',       r.event_date,
        'event_time',       r.event_time,
        'group_id',         r.group_id,
        'group_name',       g.name,
        'client_name',      p.full_name,
        'group_earnings',   r.group_earnings,
        'total_anticipado', COALESCE(gp.total_anticipado, 0),
        'saldo_pendiente',  r.group_earnings - COALESCE(gp.total_anticipado, 0),
        'bank_clabe',       w.bank_clabe,
        'bank_name',        w.bank_name,
        'account_holder',   w.account_holder,
        'bank_linked_at',   w.bank_linked_at,
        -- [P1D] badge — SOLO cuenta una solicitud activa (status='pending')
        'payment_requested', (pr.id IS NOT NULL)
      ) AS item
    FROM reservations r
    JOIN      groups   g ON g.id = r.group_id
    LEFT JOIN profiles p ON p.id = r.client_id
    LEFT JOIN wallets   w ON w.user_id = g.owner_id
    LEFT JOIN LATERAL (
      SELECT SUM(amount) AS total_anticipado
      FROM group_reservation_payments
      WHERE reservation_id = r.id
    ) gp ON true
    LEFT JOIN group_payment_requests pr ON pr.reservation_id = r.id AND pr.status = 'pending'
    WHERE r.payout_status  = 'released'
      AND r.payment_status IN ('paid','fully_paid','deposit_paid')
      AND COALESCE(r.group_earnings, 0) > 0
      AND (r.group_earnings - COALESCE(gp.total_anticipado, 0)) > 0
    ORDER BY r.event_date DESC NULLS LAST
    LIMIT p_limit
  ) x;

  RETURN v_result;
END;
$function$;

COMMIT;

-- ── Verificación ──────────────────────────────────────────────────
SELECT proname, prosecdef FROM pg_proc
WHERE pronamespace = 'public'::regnamespace
  AND proname IN ('group_request_payment','group_get_payable_reservations','admin_get_pending_group_payments');

SELECT '531_group_payment_requests ✅' AS status;
