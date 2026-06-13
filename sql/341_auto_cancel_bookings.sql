-- ============================================================
-- sql/341_auto_cancel_bookings.sql
--
-- PROBLEMA: El SQL 100 (reservation_improvements) hace un
--   cron.unschedule('auto-cancel-bookings') pero NUNCA lo schedula.
--   Las reservas 'confirmed' sin pago se quedan activas para siempre.
--
-- FIX:
--   Crear auto_cancel_unpaid_bookings() + cron cada hora.
--
-- LÓGICA:
--   Cancelar reservas que llevan más de 24 h en estado 'confirmed'
--   o 'accepted' sin pago confirmado.
--   No cancela reservas con evento mañana o antes (urgentes — admin decide).
--   Genera notificación al grupo y al cliente.
-- ============================================================

CREATE OR REPLACE FUNCTION public.auto_cancel_unpaid_bookings()
RETURNS INT
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_res   RECORD;
  v_count INT := 0;
BEGIN
  -- Advisory lock: solo 1 proceso a la vez
  IF NOT pg_try_advisory_xact_lock(8765432109) THEN
    RETURN 0;
  END IF;

  FOR v_res IN
    SELECT r.id, r.client_id, r.group_id, r.event_date, g.owner_id, g.name AS group_name
    FROM   public.reservations r
    JOIN   public.groups       g ON g.id = r.group_id
    WHERE  r.status IN ('confirmed', 'accepted')
      AND  r.payment_status NOT IN ('paid', 'deposit_paid', 'fully_paid')
      -- Más de 24 h sin pago desde la última actualización
      AND  r.updated_at < NOW() - INTERVAL '24 hours'
      -- No cancelar si el evento es en las próximas 48 h (admin gestiona manualmente)
      AND  r.event_date > CURRENT_DATE + 1
      AND  r.event_started_at IS NULL
      AND  r.cancelled_at IS NULL
  LOOP

    -- Cancelar la reserva
    UPDATE public.reservations
    SET
      status            = 'cancelled',
      cancelled_at      = NOW(),
      cancelled_by      = 'system',
      cancel_reason     = 'pago_no_recibido_24h',
      cancellation_type = 'auto'
    WHERE id = v_res.id;

    -- Notificar al cliente
    IF v_res.client_id IS NOT NULL THEN
      INSERT INTO public.notifications (user_id, type, title, body, data)
      VALUES (
        v_res.client_id,
        'booking_auto_cancelled',
        '❌ Reserva cancelada por falta de pago',
        'Tu reserva con ' || v_res.group_name || ' fue cancelada porque el pago no se recibió en 24 h. Puedes volver a contratar.',
        jsonb_build_object('reservation_id', v_res.id, 'screen', 'ClientReservations')
      );
    END IF;

    -- Notificar al grupo
    IF v_res.owner_id IS NOT NULL THEN
      INSERT INTO public.notifications (user_id, type, title, body, data)
      VALUES (
        v_res.owner_id,
        'booking_auto_cancelled',
        '❌ Reserva cancelada — pago no recibido',
        'Una reserva para el ' || v_res.event_date || ' fue cancelada automáticamente por falta de pago del cliente.',
        jsonb_build_object('reservation_id', v_res.id, 'screen', 'GroupReservations')
      );
    END IF;

    v_count := v_count + 1;
  END LOOP;

  IF v_count > 0 THEN
    RAISE NOTICE '[auto-cancel-bookings] % reserva(s) cancelada(s) por falta de pago', v_count;
  END IF;

  RETURN v_count;
END;
$$;

GRANT EXECUTE ON FUNCTION public.auto_cancel_unpaid_bookings() TO service_role;


-- ── Cron: cada hora en punto ──────────────────────────────────────────────────
DO $$ BEGIN
  PERFORM cron.unschedule('auto-cancel-bookings');
EXCEPTION WHEN OTHERS THEN NULL;
END; $$;

SELECT cron.schedule(
  'auto-cancel-bookings',
  '0 * * * *',   -- cada hora en punto
  $$SELECT public.auto_cancel_unpaid_bookings();$$
);


-- ── Verificación ──────────────────────────────────────────────────────────────
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'auto-cancel-bookings') THEN
    RAISE NOTICE '[341] Cron auto-cancel-bookings registrado (cada 1 h) ✅';
  ELSE
    RAISE WARNING '[341] ALERTA: cron auto-cancel-bookings NO encontrado';
  END IF;
END;
$$;

-- Vista previa: reservas que serían canceladas si corriera ahora
SELECT
  r.id,
  r.status,
  r.payment_status,
  r.event_date,
  r.updated_at,
  NOW() - r.updated_at AS tiempo_sin_pago,
  g.name AS grupo
FROM   public.reservations r
JOIN   public.groups g ON g.id = r.group_id
WHERE  r.status IN ('confirmed', 'accepted')
  AND  r.payment_status NOT IN ('paid', 'deposit_paid', 'fully_paid')
  AND  r.updated_at < NOW() - INTERVAL '24 hours'
  AND  r.event_date > CURRENT_DATE + 1
  AND  r.event_started_at IS NULL
  AND  r.cancelled_at IS NULL
ORDER  BY r.updated_at ASC;

SELECT '341_auto_cancel_bookings.sql ejecutado ✅' AS status;
