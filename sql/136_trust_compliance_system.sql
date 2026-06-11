-- ════════════════════════════════════════════════════════════════════════════
-- 136_trust_compliance_system.sql
--
-- Sistema de protección anti-fuga:
--   · trust_score en grupos (ranking interno, nunca visible al grupo)
--   · event_feedback: cliente confirma si todo salió bien
--   · _check_event_compliance: detecta eventos fuera de contrato sin extensión
--   · submit_event_feedback: RPC para el cliente
--
-- Ejecutar DESPUÉS de 135_deposit_commission_and_extra_hours_confirm.sql
-- ════════════════════════════════════════════════════════════════════════════

-- ── 1. Columnas en groups ──────────────────────────────────────────────────

ALTER TABLE public.groups
  ADD COLUMN IF NOT EXISTS trust_score             INTEGER  DEFAULT 100,
  ADD COLUMN IF NOT EXISTS compliance_flags        TEXT[]   DEFAULT '{}',
  ADD COLUMN IF NOT EXISTS total_events_completed  INTEGER  DEFAULT 0,
  ADD COLUMN IF NOT EXISTS extra_hours_rate        NUMERIC(5,2) DEFAULT 0;

-- ── 2. Tabla event_feedback ───────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.event_feedback (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  reservation_id  UUID        NOT NULL REFERENCES public.reservations(id) ON DELETE CASCADE,
  client_id       UUID        NOT NULL REFERENCES public.profiles(id),
  group_id        UUID        NOT NULL REFERENCES public.groups(id),
  had_issue       BOOLEAN     NOT NULL DEFAULT FALSE,
  issue_text      TEXT,
  created_at      TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE (reservation_id, client_id)
);

ALTER TABLE public.event_feedback ENABLE ROW LEVEL SECURITY;

CREATE POLICY "client_insert_feedback" ON public.event_feedback
  FOR INSERT TO authenticated
  WITH CHECK (client_id = auth.uid());

CREATE POLICY "admin_view_feedback" ON public.event_feedback
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.profiles
      WHERE id = auth.uid() AND role = 'admin'
    )
  );

-- ── 3. RPC: submit_event_feedback ─────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.submit_event_feedback(
  p_reservation_id UUID,
  p_had_issue      BOOLEAN DEFAULT FALSE,
  p_issue_text     TEXT    DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid  UUID := auth.uid();
  v_res  RECORD;
BEGIN
  SELECT * INTO v_res FROM public.reservations WHERE id = p_reservation_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'reservation_not_found');
  END IF;

  INSERT INTO public.event_feedback (reservation_id, client_id, group_id, had_issue, issue_text)
  VALUES (p_reservation_id, v_uid, v_res.group_id, p_had_issue, p_issue_text)
  ON CONFLICT (reservation_id, client_id) DO NOTHING;

  -- Incrementar total de eventos completados del grupo y actualizar tasa de horas extra
  UPDATE public.groups
  SET total_events_completed = COALESCE(total_events_completed, 0) + 1,
      extra_hours_rate = (
        SELECT COALESCE(
          CAST(COUNT(*) AS NUMERIC) /
          NULLIF(COALESCE(total_events_completed, 0) + 1, 0),
          0
        )
        FROM public.extra_hours eh
        JOIN public.reservations r2 ON r2.id = eh.reservation_id
        WHERE r2.group_id = v_res.group_id AND eh.status = 'accepted'
      )
  WHERE id = v_res.group_id;

  -- Si reporta problema: bajar trust_score y registrar flag
  IF p_had_issue THEN
    UPDATE public.groups
    SET trust_score      = GREATEST(0, COALESCE(trust_score, 100) - 5),
        compliance_flags = array_append(
          COALESCE(compliance_flags, '{}'),
          'issue_reported:' || NOW()::DATE::TEXT
        )
    WHERE id = v_res.group_id;

    -- Notificar admin
    INSERT INTO public.notifications (user_id, type, title, body, data)
    SELECT p.id,
      'admin_alert',
      '⚠️ Problema reportado en evento',
      'El cliente reportó un problema en la reserva ' || p_reservation_id::TEXT,
      jsonb_build_object(
        'reservation_id', p_reservation_id,
        'group_id',       v_res.group_id,
        'issue_text',     p_issue_text,
        'screen',         'AdminDashboard'
      )
    FROM public.profiles p WHERE p.role = 'admin'
    LIMIT 1;
  END IF;

  RETURN jsonb_build_object('ok', true);

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.submit_event_feedback(UUID, BOOLEAN, TEXT) TO authenticated;

-- ── 4. Función interna: detectar actividad fuera de contrato ──────────────
-- Llamar cuando se complete un evento (desde trigger o RPC de cierre).
-- No se muestra al usuario — solo actualiza flags internos.

CREATE OR REPLACE FUNCTION public._check_event_compliance(p_reservation_id UUID)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_res          RECORD;
  v_contract_end TIMESTAMPTZ;
  v_overrun_mins INTEGER;
BEGIN
  SELECT * INTO v_res FROM public.reservations WHERE id = p_reservation_id;
  IF NOT FOUND THEN RETURN; END IF;
  IF v_res.event_started_at IS NULL OR v_res.event_ended_at IS NULL THEN RETURN; END IF;

  v_contract_end := v_res.event_started_at
    + (COALESCE(v_res.hours_count, 3)::TEXT || ' hours')::INTERVAL;

  v_overrun_mins := EXTRACT(EPOCH FROM (v_res.event_ended_at - v_contract_end)) / 60;

  -- Evento corrió >30 min extra sin horas extra registradas en la app
  IF v_overrun_mins > 30 AND COALESCE(v_res.extra_hours_added, 0) = 0 THEN
    UPDATE public.groups
    SET trust_score      = GREATEST(0, COALESCE(trust_score, 100) - 10),
        compliance_flags = array_append(
          COALESCE(compliance_flags, '{}'),
          'possible_off_app:' || v_res.event_date::TEXT
        )
    WHERE id = v_res.group_id;
  ELSIF v_overrun_mins > 0 AND COALESCE(v_res.extra_hours_added, 0) > 0 THEN
    -- Extensión registrada correctamente → premio leve
    UPDATE public.groups
    SET trust_score = LEAST(100, COALESCE(trust_score, 100) + 2)
    WHERE id = v_res.group_id;
  END IF;
END;
$$;

-- No necesita GRANT — es interna, llamada por service_role o SECURITY DEFINER fns

-- ── 5. Trigger: ejecutar _check_event_compliance al marcar completed ──────

CREATE OR REPLACE FUNCTION public._trg_reservation_completed()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.status = 'completed' AND (OLD.status IS DISTINCT FROM 'completed') THEN
    PERFORM public._check_event_compliance(NEW.id);
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_reservation_compliance ON public.reservations;

CREATE TRIGGER trg_reservation_compliance
  AFTER UPDATE ON public.reservations
  FOR EACH ROW
  EXECUTE FUNCTION public._trg_reservation_completed();

-- ── 6. Índice para búsqueda ordenada por trust_score ─────────────────────

CREATE INDEX IF NOT EXISTS idx_groups_trust_score ON public.groups (trust_score DESC);

SELECT '136_trust_compliance_system ✅' AS status;
