-- ════════════════════════════════════════════════════════════════════════════
-- 100_reservation_improvements.sql
-- 8 mejoras al sistema de reservas programadas
-- NO modifica el flujo actual de pagos — solo agrega protecciones y mejoras
-- Ejecutar DESPUÉS de 95_wave_notifications.sql
-- ════════════════════════════════════════════════════════════════════════════

-- ────────────────────────────────────────────────────────────────────────────
-- MEJORA 1: PROTECCIÓN CONTRA DOUBLE-BOOKING
-- Trigger que impide que un grupo tenga 2 reservas activas el mismo día.
-- Estados que NO bloquean una nueva reserva: cancelled, rejected, expired.
-- ────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.prevent_double_booking()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_conflict_count INT;
BEGIN
  SELECT COUNT(*)
  INTO   v_conflict_count
  FROM   public.reservations
  WHERE  group_id   = NEW.group_id
    AND  event_date = NEW.event_date
    AND  id        != COALESCE(NEW.id, '00000000-0000-0000-0000-000000000000'::UUID)
    AND  status NOT IN ('cancelled', 'rejected', 'expired');

  IF v_conflict_count > 0 THEN
    RAISE EXCEPTION
      'El grupo ya tiene una reserva activa para la fecha %. Por favor elige otra fecha.',
      NEW.event_date;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trigger_prevent_double_booking ON public.reservations;
CREATE TRIGGER trigger_prevent_double_booking
  BEFORE INSERT OR UPDATE OF group_id, event_date ON public.reservations
  FOR EACH ROW EXECUTE FUNCTION public.prevent_double_booking();

-- Índice de soporte para la consulta del trigger (lectura rápida)
CREATE INDEX IF NOT EXISTS idx_reservations_group_date_active
  ON public.reservations(group_id, event_date)
  WHERE status NOT IN ('cancelled', 'rejected', 'expired');

-- ────────────────────────────────────────────────────────────────────────────
-- MEJORA 2: ACTIVAR pg_cron
-- auto_cancel cada 5 min (era cada 15 min en el comentario de 11_push_booking_flow).
-- send_event_reminders cada hora.
-- NOTA: requiere pg_cron habilitado en Supabase → Database → Extensions.
-- Ejecutar manualmente si pg_cron no está disponible aún.
-- ────────────────────────────────────────────────────────────────────────────

DO $$
BEGIN
  -- Desregistrar si ya existían con otro schedule
  BEGIN
    PERFORM cron.unschedule('auto-cancel-bookings');
  EXCEPTION WHEN OTHERS THEN NULL; END;

  BEGIN
    PERFORM cron.unschedule('event-reminders');
  EXCEPTION WHEN OTHERS THEN NULL; END;

  -- Registrar con nuevos schedules
  PERFORM cron.schedule(
    'auto-cancel-bookings',
    '*/5 * * * *',
    'SELECT public.auto_cancel_expired_bookings()'
  );

  PERFORM cron.schedule(
    'event-reminders',
    '0 * * * *',
    'SELECT public.send_event_reminders()'
  );

EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'pg_cron no disponible aún. Activar en Dashboard → Extensions → pg_cron, luego re-ejecutar este bloque.';
END;
$$;

-- ────────────────────────────────────────────────────────────────────────────
-- MEJORA 3: TABLA refund_requests + TRIGGER AUTO-COLA
-- Cuando se registra una cancelación con reembolso, se encola automáticamente
-- en refund_requests para ser procesado por la Edge Function process-refund.
-- ────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.refund_requests (
  id               UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  reservation_id   UUID        REFERENCES public.reservations(id) ON DELETE SET NULL,
  client_id        UUID        REFERENCES public.profiles(id) ON DELETE SET NULL,
  amount           NUMERIC(12,2) NOT NULL CHECK (amount > 0),
  refund_policy    TEXT        NOT NULL,
  reason           TEXT,
  status           TEXT        NOT NULL DEFAULT 'pending'
                               CHECK (status IN ('pending', 'processing', 'completed', 'failed')),
  stripe_refund_id TEXT,
  failure_message  TEXT,
  created_at       TIMESTAMPTZ DEFAULT NOW(),
  processed_at     TIMESTAMPTZ
);

ALTER TABLE public.refund_requests ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "rr_admin_all"  ON public.refund_requests;
DROP POLICY IF EXISTS "rr_client_own" ON public.refund_requests;

CREATE POLICY "rr_admin_all" ON public.refund_requests FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin'));

CREATE POLICY "rr_client_own" ON public.refund_requests FOR SELECT TO authenticated
  USING (auth.uid() = client_id);

CREATE INDEX IF NOT EXISTS idx_refund_requests_status
  ON public.refund_requests(status, created_at)
  WHERE status = 'pending';

CREATE INDEX IF NOT EXISTS idx_refund_requests_reservation
  ON public.refund_requests(reservation_id);

-- Trigger: al insertar en cancellation_records con refund_amount > 0 →
-- encolar un refund_request automáticamente.
CREATE OR REPLACE FUNCTION public.auto_queue_refund()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_client_id UUID;
BEGIN
  -- Solo encolar si hay monto a reembolsar
  IF NEW.refund_amount IS NULL OR NEW.refund_amount <= 0 THEN
    RETURN NEW;
  END IF;

  -- Obtener client_id de la reserva
  SELECT client_id INTO v_client_id
  FROM   public.reservations
  WHERE  id = NEW.reservation_id;

  IF v_client_id IS NULL THEN
    RETURN NEW;
  END IF;

  INSERT INTO public.refund_requests
    (reservation_id, client_id, amount, refund_policy, reason, status)
  VALUES
    (NEW.reservation_id, v_client_id, NEW.refund_amount,
     COALESCE(NEW.refund_policy, 'full'),
     COALESCE(NEW.reason, 'Cancelación de reserva'),
     'pending');

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trigger_auto_queue_refund ON public.cancellation_records;
CREATE TRIGGER trigger_auto_queue_refund
  AFTER INSERT ON public.cancellation_records
  FOR EACH ROW EXECUTE FUNCTION public.auto_queue_refund();

-- También encolar reembolso cuando el grupo rechaza o auto-cancela una reserva ya pagada
CREATE OR REPLACE FUNCTION public.auto_queue_refund_on_rejection()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_deposit_paid NUMERIC(12,2);
BEGIN
  -- Solo actuar cuando cambia a rejected o cancelled desde pending_group_confirmation
  IF NOT (
    TG_OP = 'UPDATE'
    AND OLD.status = 'pending_group_confirmation'
    AND NEW.status IN ('rejected', 'cancelled')
  ) THEN
    RETURN NEW;
  END IF;

  -- Calcular lo pagado (depósito 50%)
  IF NEW.payment_status IN ('deposit_paid', 'deposit_pending') THEN
    v_deposit_paid := ROUND(COALESCE(NEW.total_price, 0) * 0.5, 2);
  ELSIF NEW.payment_status = 'fully_paid' THEN
    v_deposit_paid := COALESCE(NEW.total_price, 0);
  ELSE
    v_deposit_paid := 0;
  END IF;

  IF v_deposit_paid > 0 THEN
    -- Evitar duplicados
    IF NOT EXISTS (
      SELECT 1 FROM public.refund_requests
      WHERE reservation_id = NEW.id AND status IN ('pending', 'processing', 'completed')
    ) THEN
      INSERT INTO public.refund_requests
        (reservation_id, client_id, amount, refund_policy, reason, status)
      VALUES
        (NEW.id, NEW.client_id, v_deposit_paid, 'full',
         CASE NEW.status
           WHEN 'rejected'   THEN 'El grupo rechazó la solicitud'
           WHEN 'cancelled'  THEN 'Reserva cancelada automáticamente por falta de respuesta'
         END,
         'pending');
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trigger_auto_queue_refund_on_rejection ON public.reservations;
CREATE TRIGGER trigger_auto_queue_refund_on_rejection
  AFTER UPDATE ON public.reservations
  FOR EACH ROW EXECUTE FUNCTION public.auto_queue_refund_on_rejection();

-- ────────────────────────────────────────────────────────────────────────────
-- MEJORA 4: NOTIFICAR A TODOS LOS INTEGRANTES DEL GRUPO AL RECIBIR RESERVA
-- Reemplaza notify_booking_events para incluir a los miembros aceptados.
-- ────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.notify_booking_events()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_group_owner_id UUID;
  v_client_name    TEXT;
  v_group_name     TEXT;
  v_member         RECORD;
BEGIN
  -- Resolver dueño del grupo y nombre
  SELECT g.owner_id, g.name
  INTO   v_group_owner_id, v_group_name
  FROM   public.groups g
  WHERE  g.id = NEW.group_id;

  SELECT p.full_name
  INTO   v_client_name
  FROM   public.profiles p
  WHERE  p.id = NEW.client_id;

  -- ── INSERT: nueva reserva recibida ─────────────────────────────────────
  IF TG_OP = 'INSERT' THEN

    -- Notificar al dueño del grupo
    PERFORM public.queue_push_notification(
      v_group_owner_id,
      'booking_received',
      'Nueva solicitud de reserva',
      COALESCE(v_client_name, 'Un cliente') || ' quiere reservar a ' ||
        COALESCE(v_group_name, 'tu grupo'),
      jsonb_build_object(
        'reservation_id', NEW.id,
        'client_id',      NEW.client_id,
        'event_date',     NEW.event_date
      )
    );

    -- Notificar a todos los integrantes aceptados del grupo (excepto el dueño, ya notificado)
    FOR v_member IN
      SELECT ji.invited_user_id
      FROM   public.job_invitations ji
      WHERE  ji.group_id  = NEW.group_id
        AND  ji.status    = 'accepted'
        AND  ji.invited_user_id IS DISTINCT FROM v_group_owner_id
    LOOP
      PERFORM public.queue_push_notification(
        v_member.invited_user_id,
        'booking_received',
        'Nueva reserva para el grupo',
        COALESCE(v_client_name, 'Un cliente') || ' reservó al grupo para el ' ||
          TO_CHAR(NEW.event_date::DATE, 'DD/MM/YYYY'),
        jsonb_build_object(
          'reservation_id', NEW.id,
          'event_date',     NEW.event_date
        )
      );
    END LOOP;

    RETURN NEW;
  END IF;

  -- ── UPDATE: cambio de estado ────────────────────────────────────────────
  IF TG_OP = 'UPDATE' AND (OLD.status IS DISTINCT FROM NEW.status
                          OR OLD.client_confirmed_complete IS DISTINCT FROM NEW.client_confirmed_complete)
  THEN

    -- Grupo confirmó → notificar al cliente
    IF NEW.status = 'confirmed' AND OLD.status != 'confirmed' THEN
      PERFORM public.queue_push_notification(
        NEW.client_id,
        'booking_confirmed',
        '¡Reserva confirmada!',
        COALESCE(v_group_name, 'El grupo') || ' confirmó tu reserva para el ' ||
          TO_CHAR(NEW.event_date::DATE, 'DD/MM/YYYY'),
        jsonb_build_object('reservation_id', NEW.id)
      );

    -- Grupo rechazó → notificar al cliente
    ELSIF NEW.status = 'rejected' AND OLD.status != 'rejected' THEN
      PERFORM public.queue_push_notification(
        NEW.client_id,
        'booking_rejected',
        'Reserva no aceptada',
        COALESCE(v_group_name, 'El grupo') ||
          ' no pudo aceptar tu solicitud. Tu depósito será reembolsado.',
        jsonb_build_object('reservation_id', NEW.id)
      );

    -- Auto-cancelada (grupo no respondió en 24h) → notificar al cliente
    ELSIF NEW.status = 'cancelled' AND OLD.status = 'pending_group_confirmation' THEN
      PERFORM public.queue_push_notification(
        NEW.client_id,
        'booking_auto_cancelled',
        'Reserva cancelada automáticamente',
        'El grupo no respondió dentro de las 24 horas. Tu depósito será reembolsado.',
        jsonb_build_object('reservation_id', NEW.id)
      );

    -- Cliente confirmó evento completado → notificar al grupo y cliente
    ELSIF NEW.status = 'completed' AND NEW.client_confirmed_complete = TRUE
      AND OLD.client_confirmed_complete = FALSE
    THEN
      PERFORM public.queue_push_notification(
        v_group_owner_id,
        'event_completed',
        'Evento completado',
        'El cliente confirmó el evento. El pago restante ha sido liberado.',
        jsonb_build_object('reservation_id', NEW.id)
      );
      PERFORM public.queue_push_notification(
        NEW.client_id,
        'payment_released',
        'Pago liberado',
        '¡Gracias! El pago restante fue liberado a ' ||
          COALESCE(v_group_name, 'el grupo') || '.',
        jsonb_build_object('reservation_id', NEW.id)
      );

    END IF;
  END IF;

  RETURN NEW;
END;
$$;

-- El trigger ya existe desde 11_push_booking_flow.sql — reemplazar
DROP TRIGGER IF EXISTS trigger_notify_booking_events ON public.reservations;
CREATE TRIGGER trigger_notify_booking_events
  AFTER INSERT OR UPDATE ON public.reservations
  FOR EACH ROW EXECUTE FUNCTION public.notify_booking_events();

-- ────────────────────────────────────────────────────────────────────────────
-- MEJORA 5: COBRO AUTOMÁTICO DE HORAS EXTRA
-- RPC que registra la solicitud de cobro extra. La Edge Function process-overtime
-- ejecuta el cargo real en Stripe off-session.
-- ────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.overtime_requests (
  id               UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  reservation_id   UUID        NOT NULL REFERENCES public.reservations(id) ON DELETE CASCADE,
  requested_by     UUID        NOT NULL REFERENCES public.profiles(id),
  extra_hours      NUMERIC(4,2) NOT NULL CHECK (extra_hours > 0),
  amount_per_hour  NUMERIC(12,2) NOT NULL CHECK (amount_per_hour > 0),
  total_amount     NUMERIC(12,2) GENERATED ALWAYS AS (extra_hours * amount_per_hour) STORED,
  status           TEXT        NOT NULL DEFAULT 'pending'
                               CHECK (status IN ('pending', 'approved', 'charged', 'failed', 'waived')),
  stripe_payment_intent_id TEXT,
  failure_message  TEXT,
  created_at       TIMESTAMPTZ DEFAULT NOW(),
  processed_at     TIMESTAMPTZ
);

ALTER TABLE public.overtime_requests ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "ot_admin_all"     ON public.overtime_requests;
DROP POLICY IF EXISTS "ot_group_owner"   ON public.overtime_requests;
DROP POLICY IF EXISTS "ot_client_select" ON public.overtime_requests;

CREATE POLICY "ot_admin_all" ON public.overtime_requests FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin'));

CREATE POLICY "ot_group_owner" ON public.overtime_requests FOR ALL TO authenticated
  USING (
    auth.uid() = requested_by
    OR auth.uid() = (
      SELECT g.owner_id FROM public.reservations r
      JOIN public.groups g ON g.id = r.group_id
      WHERE r.id = reservation_id
    )
  );

CREATE POLICY "ot_client_select" ON public.overtime_requests FOR SELECT TO authenticated
  USING (
    auth.uid() = (
      SELECT client_id FROM public.reservations WHERE id = reservation_id
    )
  );

CREATE INDEX IF NOT EXISTS idx_overtime_requests_reservation
  ON public.overtime_requests(reservation_id);

-- RPC: dueño del grupo solicita cobro de horas extra durante el evento
CREATE OR REPLACE FUNCTION public.request_overtime(
  p_reservation_id UUID,
  p_extra_hours    NUMERIC,
  p_amount_per_hour NUMERIC DEFAULT NULL  -- NULL = usar precio del paquete
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_res          RECORD;
  v_owner_id     UUID;
  v_hour_price   NUMERIC(12,2);
  v_ot_id        UUID;
BEGIN
  -- Obtener reserva con info del paquete
  SELECT r.*, g.owner_id AS g_owner_id,
         pkg.extra_hour_price
  INTO   v_res
  FROM   public.reservations r
  JOIN   public.groups g ON g.id = r.group_id
  LEFT JOIN public.packages pkg ON pkg.id = r.package_id
  WHERE  r.id = p_reservation_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'reservation_not_found');
  END IF;

  v_owner_id := v_res.g_owner_id;

  -- Solo el dueño del grupo puede solicitar overtime
  IF v_owner_id IS DISTINCT FROM auth.uid() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unauthorized');
  END IF;

  -- La reserva debe estar confirmada o en progreso
  IF v_res.status NOT IN ('confirmed', 'in_progress') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'reservation_not_active',
      'status', v_res.status);
  END IF;

  -- Determinar precio por hora
  v_hour_price := COALESCE(
    p_amount_per_hour,
    v_res.extra_hour_price,
    ROUND(v_res.total_price / GREATEST(v_res.hours_count, 1), 2)
  );

  IF v_hour_price IS NULL OR v_hour_price <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'cannot_determine_hour_price');
  END IF;

  -- Insertar solicitud de overtime
  INSERT INTO public.overtime_requests
    (reservation_id, requested_by, extra_hours, amount_per_hour)
  VALUES
    (p_reservation_id, auth.uid(), p_extra_hours, v_hour_price)
  RETURNING id INTO v_ot_id;

  -- Notificar al cliente
  PERFORM public.queue_push_notification(
    v_res.client_id,
    'overtime_requested',
    '⏰ Solicitud de tiempo extra',
    'El grupo solicita ' || p_extra_hours || ' hora(s) extra por $' ||
      (p_extra_hours * v_hour_price)::TEXT || ' MXN.',
    jsonb_build_object(
      'overtime_id',    v_ot_id,
      'reservation_id', p_reservation_id,
      'extra_hours',    p_extra_hours,
      'amount',         p_extra_hours * v_hour_price
    )
  );

  RETURN jsonb_build_object(
    'ok',              true,
    'overtime_id',     v_ot_id,
    'extra_hours',     p_extra_hours,
    'amount_per_hour', v_hour_price,
    'total_amount',    p_extra_hours * v_hour_price
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.request_overtime(UUID, NUMERIC, NUMERIC) TO authenticated;

-- ────────────────────────────────────────────────────────────────────────────
-- MEJORA 6: TABLA event_disputes + RPC open_dispute
-- ────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.event_disputes (
  id             UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  reservation_id UUID        NOT NULL REFERENCES public.reservations(id) ON DELETE CASCADE,
  opened_by      UUID        NOT NULL REFERENCES public.profiles(id),
  opened_by_role TEXT        NOT NULL CHECK (opened_by_role IN ('client', 'group')),
  reason         TEXT        NOT NULL,
  evidence_urls  TEXT[]      DEFAULT '{}',
  status         TEXT        NOT NULL DEFAULT 'open'
                             CHECK (status IN ('open', 'under_review', 'resolved', 'closed')),
  admin_notes    TEXT,
  resolution     TEXT,
  resolution_type TEXT       CHECK (resolution_type IN ('refund_client', 'release_group', 'split', 'no_action', NULL)),
  created_at     TIMESTAMPTZ DEFAULT NOW(),
  resolved_at    TIMESTAMPTZ
);

ALTER TABLE public.event_disputes ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "disp_admin_all"    ON public.event_disputes;
DROP POLICY IF EXISTS "disp_involved_sel" ON public.event_disputes;
DROP POLICY IF EXISTS "disp_involved_ins" ON public.event_disputes;

CREATE POLICY "disp_admin_all" ON public.event_disputes FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin'));

-- Cliente o dueño del grupo puede ver disputas de sus reservas
CREATE POLICY "disp_involved_sel" ON public.event_disputes FOR SELECT TO authenticated
  USING (
    auth.uid() = opened_by
    OR auth.uid() = (
      SELECT r.client_id FROM public.reservations r WHERE r.id = reservation_id
    )
    OR auth.uid() = (
      SELECT g.owner_id FROM public.reservations r
      JOIN public.groups g ON g.id = r.group_id
      WHERE r.id = reservation_id
    )
  );

-- Solo involucrados pueden abrir una disputa
CREATE POLICY "disp_involved_ins" ON public.event_disputes FOR INSERT TO authenticated
  WITH CHECK (
    auth.uid() = (
      SELECT r.client_id FROM public.reservations r WHERE r.id = reservation_id
    )
    OR auth.uid() = (
      SELECT g.owner_id FROM public.reservations r
      JOIN public.groups g ON g.id = r.group_id
      WHERE r.id = reservation_id
    )
  );

CREATE INDEX IF NOT EXISTS idx_event_disputes_reservation
  ON public.event_disputes(reservation_id);

CREATE INDEX IF NOT EXISTS idx_event_disputes_status
  ON public.event_disputes(status)
  WHERE status = 'open';

-- RPC: abrir una disputa (cliente o grupo)
CREATE OR REPLACE FUNCTION public.open_dispute(
  p_reservation_id UUID,
  p_reason         TEXT,
  p_evidence_urls  TEXT[] DEFAULT '{}'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_res        RECORD;
  v_caller_role TEXT;
  v_dispute_id  UUID;
  v_admin_id    UUID;
BEGIN
  SELECT r.*, g.owner_id AS g_owner_id
  INTO   v_res
  FROM   public.reservations r
  JOIN   public.groups g ON g.id = r.group_id
  WHERE  r.id = p_reservation_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'reservation_not_found');
  END IF;

  -- Determinar rol del caller
  IF auth.uid() = v_res.client_id THEN
    v_caller_role := 'client';
  ELSIF auth.uid() = v_res.g_owner_id THEN
    v_caller_role := 'group';
  ELSE
    RETURN jsonb_build_object('ok', false, 'error', 'unauthorized');
  END IF;

  -- Solo se puede disputar reservas en estados relevantes
  IF v_res.status NOT IN ('confirmed', 'completed', 'in_progress') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'dispute_not_allowed_for_status',
      'status', v_res.status);
  END IF;

  -- Verificar que no haya disputa abierta para la misma reserva
  IF EXISTS (
    SELECT 1 FROM public.event_disputes
    WHERE reservation_id = p_reservation_id
      AND status IN ('open', 'under_review')
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'dispute_already_open');
  END IF;

  -- Crear la disputa
  INSERT INTO public.event_disputes
    (reservation_id, opened_by, opened_by_role, reason, evidence_urls)
  VALUES
    (p_reservation_id, auth.uid(), v_caller_role, p_reason,
     COALESCE(p_evidence_urls, '{}'))
  RETURNING id INTO v_dispute_id;

  -- Notificar al admin
  v_admin_id := public.get_platform_admin_id();
  IF v_admin_id IS NOT NULL THEN
    PERFORM public.queue_push_notification(
      v_admin_id,
      'dispute_opened',
      '⚠️ Nueva disputa abierta',
      'Un ' || v_caller_role || ' abrió una disputa para la reserva del ' ||
        TO_CHAR(v_res.event_date::DATE, 'DD/MM/YYYY') || '.',
      jsonb_build_object(
        'dispute_id',     v_dispute_id,
        'reservation_id', p_reservation_id
      )
    );
  END IF;

  -- Notificar a la otra parte
  PERFORM public.queue_push_notification(
    CASE v_caller_role WHEN 'client' THEN v_res.g_owner_id ELSE v_res.client_id END,
    'dispute_received',
    'Se abrió una disputa en tu reserva',
    'Se ha abierto una disputa relacionada con el evento del ' ||
      TO_CHAR(v_res.event_date::DATE, 'DD/MM/YYYY') || '. El equipo la revisará.',
    jsonb_build_object(
      'dispute_id',     v_dispute_id,
      'reservation_id', p_reservation_id
    )
  );

  RETURN jsonb_build_object(
    'ok',         true,
    'dispute_id', v_dispute_id
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.open_dispute(UUID, TEXT, TEXT[]) TO authenticated;

-- ────────────────────────────────────────────────────────────────────────────
-- MEJORA 7: commission_rate_applied EN reservations
-- Guarda la tasa de comisión vigente al momento de crear la reserva.
-- Esto asegura que cambios futuros de tasa no afecten reservas históricas.
-- ────────────────────────────────────────────────────────────────────────────

ALTER TABLE public.reservations
  ADD COLUMN IF NOT EXISTS commission_rate_applied NUMERIC(5,4);

-- Trigger: snapshot de la tasa al crear la reserva
CREATE OR REPLACE FUNCTION public.snapshot_commission_rate()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Solo en INSERT o cuando la columna aún es NULL
  IF TG_OP = 'INSERT' OR NEW.commission_rate_applied IS NULL THEN
    -- Tasa base: 8% para reservas normales, 3% para express
    NEW.commission_rate_applied :=
      CASE
        WHEN NEW.event_request_id IS NOT NULL THEN 0.03   -- express
        ELSE 0.08                                          -- programada
      END;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trigger_snapshot_commission_rate ON public.reservations;
CREATE TRIGGER trigger_snapshot_commission_rate
  BEFORE INSERT ON public.reservations
  FOR EACH ROW EXECUTE FUNCTION public.snapshot_commission_rate();

-- Backfill: llenar commission_rate_applied en reservas existentes donde sea NULL
UPDATE public.reservations
SET    commission_rate_applied =
         CASE
           WHEN event_request_id IS NOT NULL THEN 0.03
           ELSE 0.08
         END
WHERE  commission_rate_applied IS NULL;

-- ────────────────────────────────────────────────────────────────────────────
-- MEJORA 8: ÍNDICES DE PERFORMANCE EN reservations
-- ────────────────────────────────────────────────────────────────────────────

-- Consultas del cliente: "mis reservas por estado y fecha"
CREATE INDEX IF NOT EXISTS idx_reservations_client_status_date
  ON public.reservations(client_id, status, event_date DESC);

-- Consultas del grupo: "mis reservas por estado y fecha"
CREATE INDEX IF NOT EXISTS idx_reservations_group_status_date
  ON public.reservations(group_id, status, event_date DESC);

-- Consultas del dashboard: reservas activas (excluir terminadas)
CREATE INDEX IF NOT EXISTS idx_reservations_active
  ON public.reservations(group_id, event_date DESC)
  WHERE status NOT IN ('completed', 'cancelled', 'rejected', 'expired', 'paid');

-- Índice para la cola de reembolsos pendientes (Edge Function process-refund)
CREATE INDEX IF NOT EXISTS idx_refund_requests_pending_created
  ON public.refund_requests(created_at ASC)
  WHERE status = 'pending';

-- ────────────────────────────────────────────────────────────────────────────

SELECT '100_reservation_improvements: 8 mejoras al sistema de reservas ✅' AS status;
