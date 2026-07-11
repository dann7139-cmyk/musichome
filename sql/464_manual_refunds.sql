-- ============================================================
-- sql/464_manual_refunds.sql
-- Cola de REEMBOLSOS MANUALES (SPEI / efectivo) — decisión 2026-07-10.
--
-- Conekta solo reembolsa por API los pagos con TARJETA. Para SPEI y
-- efectivo, la devolución es por transferencia bancaria manual:
--   · La cancelación y la reversión de wallet se completan SIEMPRE
--     (settle_cancellation / process_refund_reversal — sin cambios).
--   · Se crea una fila en manual_refunds (cola gemela de payout_requests).
--   · Cliente: promesa de 5 días hábiles + notificación al enviarse.
--   · Admin: cola en el panel financiero; al transferir sube comprobante
--     y referencia → status 'sent' → notifica al cliente.
--
-- NO toca settle_cancellation, wallets, GPS ni liberaciones.
-- ============================================================

BEGIN;

-- ── 0. Método de pago real en la reserva (lo escribe conekta-webhook) ────────
ALTER TABLE reservations ADD COLUMN IF NOT EXISTS payment_method_type TEXT;

-- ── 1. Helper: sumar días hábiles (L-V, sin festivos) ────────────────────────
CREATE OR REPLACE FUNCTION public.add_business_days(p_from DATE, p_days INT)
RETURNS DATE LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  v_date DATE := p_from;
  v_left INT  := p_days;
BEGIN
  WHILE v_left > 0 LOOP
    v_date := v_date + 1;
    IF EXTRACT(ISODOW FROM v_date) < 6 THEN v_left := v_left - 1; END IF;
  END LOOP;
  RETURN v_date;
END;
$$;

-- ── 2. Tabla ──────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS manual_refunds (
  id                 UUID          DEFAULT gen_random_uuid() PRIMARY KEY,
  reservation_id     UUID          NOT NULL REFERENCES reservations(id) ON DELETE CASCADE,
  client_id          UUID          NOT NULL REFERENCES profiles(id),
  group_id           UUID          REFERENCES groups(id),
  folio              TEXT,
  payment_method     TEXT          NOT NULL DEFAULT 'unknown'
    CONSTRAINT chk_mr_method CHECK (payment_method IN ('spei','cash','unknown')),
  amount             NUMERIC(14,2) NOT NULL CHECK (amount > 0),
  clabe              TEXT,               -- 18 dígitos (puede llegar después si fue fallback)
  account_holder     TEXT,
  bank_name          TEXT,
  due_date           DATE          NOT NULL,  -- promesa: 5 días hábiles
  status             TEXT          NOT NULL DEFAULT 'pending'
    CONSTRAINT chk_mr_status CHECK (status IN ('pending','processing','sent')),
  transfer_reference TEXT,               -- clave de rastreo / folio de la transferencia
  receipt_path       TEXT,               -- path en storage del comprobante
  api_error          TEXT,               -- error original de Conekta si vino de fallback
  processed_by       UUID,
  processed_at       TIMESTAMPTZ,
  created_at         TIMESTAMPTZ   DEFAULT NOW(),
  updated_at         TIMESTAMPTZ   DEFAULT NOW()
);

-- Idempotencia: máximo UNA devolución manual por reserva
CREATE UNIQUE INDEX IF NOT EXISTS uq_mr_reservation ON manual_refunds(reservation_id);
CREATE INDEX IF NOT EXISTS idx_mr_status ON manual_refunds(status);

ALTER TABLE manual_refunds ENABLE ROW LEVEL SECURITY;

-- Cliente: puede VER su propio reembolso (estado + comprobante). Sin escrituras
-- directas — todo pasa por RPC/service_role.
DROP POLICY IF EXISTS mr_client_select ON manual_refunds;
CREATE POLICY mr_client_select ON manual_refunds
  FOR SELECT USING (client_id = auth.uid());

-- ── 3. create_manual_refund (service_role — la llama process-refund) ─────────
CREATE OR REPLACE FUNCTION public.create_manual_refund(
  p_reservation_id UUID,
  p_amount         NUMERIC,
  p_method         TEXT    DEFAULT 'unknown',
  p_clabe          TEXT    DEFAULT NULL,
  p_account_holder TEXT    DEFAULT NULL,
  p_bank_name      TEXT    DEFAULT NULL,
  p_api_error      TEXT    DEFAULT NULL
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_res      RECORD;
  v_due      DATE;
  v_id       UUID;
  v_admin_id UUID;
  v_client   TEXT;
BEGIN
  SELECT r.*, p.full_name AS client_name INTO v_res
  FROM reservations r JOIN profiles p ON p.id = r.client_id
  WHERE r.id = p_reservation_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'not_found'); END IF;

  v_due := public.add_business_days((NOW() AT TIME ZONE 'America/Mexico_City')::date, 5);

  INSERT INTO manual_refunds
    (reservation_id, client_id, group_id, folio, payment_method, amount,
     clabe, account_holder, bank_name, due_date, api_error)
  VALUES
    (p_reservation_id, v_res.client_id, v_res.group_id, v_res.folio,
     COALESCE(NULLIF(p_method, ''), 'unknown'), p_amount,
     p_clabe, p_account_holder, p_bank_name, v_due, p_api_error)
  ON CONFLICT (reservation_id) DO UPDATE SET
    -- Reintento: completa datos bancarios si faltaban, nunca duplica
    clabe          = COALESCE(manual_refunds.clabe,          EXCLUDED.clabe),
    account_holder = COALESCE(manual_refunds.account_holder, EXCLUDED.account_holder),
    bank_name      = COALESCE(manual_refunds.bank_name,      EXCLUDED.bank_name),
    updated_at     = NOW()
  RETURNING id INTO v_id;

  -- Notificar al ADMIN (además de la cola — la cola es la fuente de verdad)
  SELECT id INTO v_admin_id FROM profiles WHERE role = 'admin' ORDER BY created_at LIMIT 1;
  IF v_admin_id IS NOT NULL THEN
    INSERT INTO notifications (user_id, type, title, body, data)
    VALUES (v_admin_id, 'admin', '💸 Reembolso manual pendiente',
      format('%s — $%s MXN por transferencia (%s). Folio %s. Fecha límite: %s.',
        v_res.client_name, to_char(p_amount, 'FM999,999,990.00'),
        COALESCE(p_method, 'desconocido'), COALESCE(v_res.folio, 's/f'),
        to_char(v_due, 'DD Mon YYYY')),
      jsonb_build_object('screen', 'AdminFinancial', 'manual_refund_id', v_id,
                         'reservation_id', p_reservation_id));
  END IF;

  RETURN jsonb_build_object('ok', true, 'id', v_id, 'due_date', v_due);
END;
$$;

REVOKE ALL ON FUNCTION public.create_manual_refund(UUID, NUMERIC, TEXT, TEXT, TEXT, TEXT, TEXT) FROM PUBLIC, authenticated;
GRANT EXECUTE ON FUNCTION public.create_manual_refund(UUID, NUMERIC, TEXT, TEXT, TEXT, TEXT, TEXT) TO service_role;

-- ── 4. admin_manual_refund_queue (cola para el panel financiero) ─────────────
CREATE OR REPLACE FUNCTION public.admin_manual_refund_queue(p_status TEXT DEFAULT NULL)
RETURNS TABLE (
  id                 UUID,
  reservation_id     UUID,
  client_id          UUID,
  folio              TEXT,
  client_name        TEXT,
  client_phone       TEXT,
  payment_method     TEXT,
  amount             NUMERIC,
  clabe              TEXT,
  account_holder     TEXT,
  bank_name          TEXT,
  due_date           DATE,
  status             TEXT,
  transfer_reference TEXT,
  receipt_path       TEXT,
  api_error          TEXT,
  created_at         TIMESTAMPTZ,
  processed_at       TIMESTAMPTZ
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE profiles.id = auth.uid() AND role = 'admin') THEN
    RAISE EXCEPTION 'Solo administradores';
  END IF;
  RETURN QUERY
  SELECT mr.id, mr.reservation_id, mr.client_id, mr.folio,
         p.full_name, p.phone,
         mr.payment_method, mr.amount, mr.clabe, mr.account_holder, mr.bank_name,
         mr.due_date, mr.status, mr.transfer_reference, mr.receipt_path, mr.api_error,
         mr.created_at, mr.processed_at
  FROM manual_refunds mr
  JOIN profiles p ON p.id = mr.client_id
  WHERE (p_status IS NULL OR mr.status = p_status)
  ORDER BY (mr.status = 'sent'), mr.due_date, mr.created_at;
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_manual_refund_queue(TEXT) TO authenticated;

-- ── 5. admin_process_manual_refund (procesando / enviado + notifica) ─────────
CREATE OR REPLACE FUNCTION public.admin_process_manual_refund(
  p_refund_id          UUID,
  p_action             TEXT,                 -- 'processing' | 'sent'
  p_transfer_reference TEXT DEFAULT NULL,
  p_receipt_path       TEXT DEFAULT NULL
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_mr RECORD;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Solo administradores');
  END IF;
  IF p_action NOT IN ('processing', 'sent') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Acción inválida');
  END IF;

  SELECT * INTO v_mr FROM manual_refunds WHERE id = p_refund_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'not_found'); END IF;
  IF v_mr.status = 'sent' THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'already_sent');
  END IF;

  IF p_action = 'sent' AND COALESCE(TRIM(p_transfer_reference), '') = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'La referencia de la transferencia es obligatoria');
  END IF;

  UPDATE manual_refunds SET
    status             = p_action,
    transfer_reference = COALESCE(p_transfer_reference, transfer_reference),
    receipt_path       = COALESCE(p_receipt_path, receipt_path),
    processed_by       = auth.uid(),
    processed_at       = CASE WHEN p_action = 'sent' THEN NOW() ELSE processed_at END,
    updated_at         = NOW()
  WHERE id = p_refund_id;

  -- Auditoría financiera
  INSERT INTO financial_audit_logs (entity_type, entity_id, action, actor_id, actor_role, amount, notes)
  VALUES ('manual_refund', p_refund_id,
          CASE WHEN p_action = 'sent' THEN 'manual_refund_completed' ELSE 'manual_refund_processing' END,
          auth.uid(), 'admin', v_mr.amount,
          format('ref=%s receipt=%s', COALESCE(p_transfer_reference, 'n/a'), COALESCE(p_receipt_path, 'n/a')));

  -- Notificar al cliente cuando el dinero YA fue enviado
  IF p_action = 'sent' THEN
    INSERT INTO notifications (user_id, type, title, body, data)
    VALUES (v_mr.client_id, 'payment', '✅ Tu reembolso fue enviado',
      format('Enviamos tu reembolso de $%s MXN por transferencia%s. Puedes ver el comprobante en tu reserva cancelada.',
        to_char(v_mr.amount, 'FM999,999,990.00'),
        CASE WHEN v_mr.clabe IS NOT NULL
             THEN format(' a tu cuenta terminación %s', RIGHT(v_mr.clabe, 4)) ELSE '' END),
      jsonb_build_object('screen', 'Reservations', 'reservation_id', v_mr.reservation_id,
                         'manual_refund_id', p_refund_id));
  END IF;

  RETURN jsonb_build_object('ok', true, 'status', p_action);
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_process_manual_refund(UUID, TEXT, TEXT, TEXT) TO authenticated;

-- ── 6. Storage: bucket privado para comprobantes ──────────────────────────────
INSERT INTO storage.buckets (id, name, public)
VALUES ('refund-receipts', 'refund-receipts', false)
ON CONFLICT (id) DO NOTHING;

-- Admin sube/lee; el cliente lee SOLO su carpeta ({client_id}/...)
DROP POLICY IF EXISTS rr_admin_all    ON storage.objects;
CREATE POLICY rr_admin_all ON storage.objects
  FOR ALL USING (
    bucket_id = 'refund-receipts'
    AND EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
  ) WITH CHECK (
    bucket_id = 'refund-receipts'
    AND EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
  );

DROP POLICY IF EXISTS rr_client_read ON storage.objects;
CREATE POLICY rr_client_read ON storage.objects
  FOR SELECT USING (
    bucket_id = 'refund-receipts'
    AND (storage.foldername(name))[1] = auth.uid()::text
  );

COMMIT;

-- ── VERIFICACIONES ────────────────────────────────────────────────────────────
-- V1: tabla + unique por reserva
SELECT indexname FROM pg_indexes WHERE tablename = 'manual_refunds';
-- Esperado: incluye uq_mr_reservation

-- V2: funciones con grants
SELECT proname FROM pg_proc
WHERE proname IN ('create_manual_refund','admin_manual_refund_queue','admin_process_manual_refund','add_business_days')
ORDER BY proname;
-- Esperado: las 4

-- V3: días hábiles (vie 10 jul 2026 + 5 hábiles = vie 17 jul 2026)
SELECT add_business_days('2026-07-10'::date, 5) AS debe_ser_2026_07_17;

-- V4: bucket
SELECT id, public FROM storage.buckets WHERE id = 'refund-receipts';
-- Esperado: refund-receipts | false

SELECT '464_manual_refunds.sql ejecutado ✅' AS status;
