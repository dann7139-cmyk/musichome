-- 205b_cancel_strikes.sql
-- Cancelaciones completas + sistema de strikes + suspensión de grupos.
-- Requiere: 205a aplicado.

-- ── 1. Columnas de cancelación en reservations ────────────────────────────────

ALTER TABLE reservations
  ADD COLUMN IF NOT EXISTS cancelled_at      TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS cancelled_by      UUID  REFERENCES profiles(id),
  ADD COLUMN IF NOT EXISTS cancel_reason     TEXT,
  ADD COLUMN IF NOT EXISTS cancellation_type TEXT;

DO $$ BEGIN
  ALTER TABLE reservations ADD CONSTRAINT chk_cancellation_type
    CHECK (cancellation_type IN (
      'client_initiated','group_initiated','admin_initiated','system_auto'
    ));
EXCEPTION WHEN duplicate_object THEN NULL;
END; $$;

-- ── 2. Tabla group_strikes ────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS group_strikes (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  group_id        UUID        NOT NULL REFERENCES groups(id)        ON DELETE CASCADE,
  reservation_id  UUID                 REFERENCES reservations(id)  ON DELETE SET NULL,
  strike_type     TEXT        NOT NULL,
  issued_by       UUID        NOT NULL REFERENCES profiles(id),
  note            TEXT,
  auto_suspended  BOOLEAN     DEFAULT FALSE,
  created_at      TIMESTAMPTZ DEFAULT NOW()
);

DO $$ BEGIN
  ALTER TABLE group_strikes ADD CONSTRAINT chk_strike_type
    CHECK (strike_type IN ('late_cancel','no_show','fraud','fake_profile','quality'));
EXCEPTION WHEN duplicate_object THEN NULL;
END; $$;

CREATE INDEX IF NOT EXISTS idx_strikes_group ON group_strikes(group_id);
CREATE INDEX IF NOT EXISTS idx_strikes_type  ON group_strikes(strike_type);

ALTER TABLE group_strikes ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "admin_manage_strikes" ON group_strikes;
CREATE POLICY "admin_manage_strikes"
  ON group_strikes FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin'));

-- ── 3. Columnas de strike tracking en groups ──────────────────────────────────

ALTER TABLE groups
  ADD COLUMN IF NOT EXISTS strike_count   INT         DEFAULT 0,
  ADD COLUMN IF NOT EXISTS last_strike_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS suspended_at   TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS suspended_by   UUID REFERENCES profiles(id);

-- ── 4. Helper interno: aplica strike y auto-suspende si llega a 3 ─────────────

CREATE OR REPLACE FUNCTION public.admin_apply_strike_internal(
  p_group_id       UUID,
  p_reservation_id UUID,
  p_strike_type    TEXT,
  p_issued_by      UUID,
  p_note           TEXT DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_new_count    INT;
  v_auto_suspend BOOLEAN := FALSE;
BEGIN
  INSERT INTO group_strikes (group_id, reservation_id, strike_type, issued_by, note)
  VALUES (p_group_id, p_reservation_id, p_strike_type, p_issued_by, p_note);

  UPDATE groups
  SET strike_count   = COALESCE(strike_count, 0) + 1,
      last_strike_at = NOW(),
      updated_at     = NOW()
  WHERE id = p_group_id
  RETURNING strike_count INTO v_new_count;

  IF v_new_count >= 3 THEN
    UPDATE groups
    SET suspended_at = NOW(),
        suspended_by = p_issued_by,
        updated_at   = NOW()
    WHERE id = p_group_id AND suspended_at IS NULL;

    v_auto_suspend := TRUE;

    UPDATE group_strikes SET auto_suspended = TRUE
    WHERE id = (
      SELECT id FROM group_strikes
      WHERE group_id = p_group_id ORDER BY created_at DESC LIMIT 1
    );

    INSERT INTO notifications (user_id, type, title, body, data)
    SELECT id, 'admin',
      '🚨 Grupo suspendido automáticamente',
      format('El grupo alcanzó %s strikes y fue suspendido automáticamente.', v_new_count),
      jsonb_build_object('screen','Verifications','group_id',p_group_id)
    FROM profiles WHERE role = 'admin';
  END IF;

  INSERT INTO financial_audit_logs (
    entity_type, entity_id, action, actor_id, actor_role, notes
  ) VALUES (
    'group', p_group_id, 'strike',
    p_issued_by, 'admin',
    format('Strike "%s" applied. Count now: %s. Auto-suspended: %s',
      p_strike_type, v_new_count, v_auto_suspend)
  );

  RAISE NOTICE '[STRIKE_APPLIED] group=% type=% count=% auto_suspend=%',
    p_group_id, p_strike_type, v_new_count, v_auto_suspend;
END;
$$;

-- ── 5. RPC cancel_reservation ─────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.cancel_reservation(
  p_reservation_id UUID,
  p_reason         TEXT DEFAULT NULL,
  p_actor_override UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_caller_id       UUID := auth.uid();
  v_actor           UUID;
  v_actor_role      TEXT;
  v_reservation     RECORD;
  v_cancel_type     TEXT;
  v_refund_eligible BOOLEAN;
BEGIN
  v_actor := COALESCE(p_actor_override, v_caller_id);
  IF v_actor IS NULL THEN RAISE EXCEPTION 'unauthorized: sesión requerida'; END IF;

  SELECT * INTO v_reservation FROM reservations WHERE id = p_reservation_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Reserva no encontrada'; END IF;

  SELECT COALESCE(role,'client') INTO v_actor_role FROM profiles WHERE id = v_actor;

  -- Permission check (no admin)
  IF v_actor_role != 'admin' THEN
    IF v_reservation.client_id != v_actor THEN
      IF NOT EXISTS (
        SELECT 1 FROM groups WHERE id = v_reservation.group_id AND owner_id = v_actor
      ) THEN
        RAISE EXCEPTION 'unauthorized: no puedes cancelar esta reserva';
      END IF;
    END IF;
  END IF;

  IF v_reservation.status IN ('cancelled','completed') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'ya_cancelada_o_completada');
  END IF;

  -- Determine cancellation type
  IF v_actor_role = 'admin' THEN
    v_cancel_type := 'admin_initiated';
  ELSIF v_reservation.client_id = v_actor THEN
    v_cancel_type := 'client_initiated';
  ELSE
    v_cancel_type := 'group_initiated';
  END IF;

  v_refund_eligible :=
    v_reservation.payment_status IN ('paid','fully_paid','deposit_paid')
    AND v_reservation.event_date > CURRENT_DATE;

  UPDATE reservations SET
    status            = 'cancelled',
    payout_status     = 'blocked',
    cancelled_at      = NOW(),
    cancelled_by      = v_actor,
    cancel_reason     = p_reason,
    cancellation_type = v_cancel_type,
    updated_at        = NOW()
  WHERE id = p_reservation_id;

  INSERT INTO financial_audit_logs (
    entity_type, entity_id, action,
    actor_id, actor_role,
    before_state, after_state, notes
  ) VALUES (
    'reservation', p_reservation_id, 'cancel',
    v_actor, v_actor_role,
    jsonb_build_object('status', v_reservation.status, 'payout_status', v_reservation.payout_status),
    jsonb_build_object('status','cancelled','payout_status','blocked','type', v_cancel_type),
    p_reason
  );

  -- Si el grupo cancela → strike automático
  IF v_cancel_type = 'group_initiated' THEN
    PERFORM admin_apply_strike_internal(
      v_reservation.group_id, p_reservation_id, 'late_cancel', v_actor,
      format('Grupo canceló reserva %s — strike automático', p_reservation_id)
    );
  END IF;

  -- Notificar al cliente
  INSERT INTO notifications (user_id, type, title, body, data)
  VALUES (
    v_reservation.client_id, 'reservation',
    '❌ Reserva cancelada',
    format('Tu reserva del %s fue cancelada.%s', v_reservation.event_date,
      CASE WHEN v_refund_eligible THEN ' Contacta soporte para el reembolso.' ELSE '' END),
    jsonb_build_object('screen','Reservations','reservation_id',p_reservation_id)
  );

  RETURN jsonb_build_object(
    'ok',              true,
    'cancelled',       true,
    'cancel_type',     v_cancel_type,
    'refund_eligible', v_refund_eligible,
    'reservation_id',  p_reservation_id
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.cancel_reservation TO authenticated;

-- ── 6. RPC admin_apply_strike (llamado externamente por admin) ────────────────

CREATE OR REPLACE FUNCTION public.admin_apply_strike(
  p_group_id       UUID,
  p_strike_type    TEXT,
  p_reservation_id UUID DEFAULT NULL,
  p_note           TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_caller_id UUID := auth.uid();
BEGIN
  IF v_caller_id IS NULL THEN RAISE EXCEPTION 'unauthorized'; END IF;
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = v_caller_id AND role = 'admin') THEN
    RAISE EXCEPTION 'unauthorized: solo admins';
  END IF;

  PERFORM admin_apply_strike_internal(
    p_group_id, p_reservation_id, p_strike_type, v_caller_id, p_note
  );

  RETURN jsonb_build_object('ok', true, 'group_id', p_group_id, 'strike_type', p_strike_type);
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_apply_strike TO authenticated;

-- ── 7. RPC admin_unsuspend_group ──────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.admin_unsuspend_group(
  p_group_id UUID,
  p_note     TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_caller_id UUID := auth.uid();
BEGIN
  IF v_caller_id IS NULL THEN RAISE EXCEPTION 'unauthorized'; END IF;
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = v_caller_id AND role = 'admin') THEN
    RAISE EXCEPTION 'unauthorized: solo admins';
  END IF;

  UPDATE groups
  SET suspended_at = NULL, suspended_by = NULL, updated_at = NOW()
  WHERE id = p_group_id;

  UPDATE groups SET strike_count = 0 WHERE id = p_group_id;

  INSERT INTO financial_audit_logs (
    entity_type, entity_id, action, actor_id, actor_role, notes
  ) VALUES (
    'group', p_group_id, 'unsuspend', v_caller_id, 'admin', p_note
  );

  RETURN jsonb_build_object('ok', true, 'group_id', p_group_id, 'unsuspended', true);
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_unsuspend_group TO authenticated;

SELECT '205b_cancel_strikes.sql ejecutado ✅' AS status;
