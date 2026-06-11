-- ══════════════════════════════════════════════════════════════════════════════
-- 37_client_cancel_and_mp_payment_id.sql
-- - Agrega mp_payment_id a reservations (para guardar el ID real de Mercado Pago)
-- - RPC segura para que el cliente cancele su propia reserva
-- Ejecutar en Supabase SQL Editor.
-- ══════════════════════════════════════════════════════════════════════════════

-- ── 1. Columna para guardar el ID de pago de Mercado Pago ─────────────────────
ALTER TABLE public.reservations
  ADD COLUMN IF NOT EXISTS mp_payment_id TEXT;

-- ── 2. RPC: el cliente cancela su reserva ─────────────────────────────────────
-- SECURITY DEFINER para actualizar la tabla sin política UPDATE del cliente.
-- Valida: que la reserva sea del cliente, que el estado sea cancelable,
-- y que no se haya confirmado un pago real.
CREATE OR REPLACE FUNCTION public.client_cancel_reservation(
  p_reservation_id UUID
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_res       RECORD;
  v_owner_id  UUID;
BEGIN
  -- Verificar que la reserva pertenece al cliente actual
  SELECT * INTO v_res
  FROM public.reservations
  WHERE id = p_reservation_id
    AND client_id = auth.uid();

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Reserva no encontrada o sin permiso';
  END IF;

  -- Solo cancelar si está en estado cancelable
  IF v_res.status NOT IN (
    'pending', 'pending_payment', 'pending_group_confirmation', 'confirmed'
  ) THEN
    RAISE EXCEPTION 'No se puede cancelar una reserva con estado: %', v_res.status;
  END IF;

  -- Si el anticipo ya fue confirmado por MP, no permitir cancelación directa
  IF v_res.payment_status IN ('deposit_paid', 'fully_paid') THEN
    RAISE EXCEPTION 'No se puede cancelar: el anticipo ya fue confirmado. Contacta soporte.';
  END IF;

  -- Cancelar la reserva
  UPDATE public.reservations
  SET status = 'cancelled'
  WHERE id = p_reservation_id;

  -- Notificar al dueño del grupo
  SELECT owner_id INTO v_owner_id
  FROM public.groups
  WHERE id = v_res.group_id;

  IF v_owner_id IS NOT NULL THEN
    INSERT INTO public.notifications (user_id, type, title, message, reference_id)
    VALUES (
      v_owner_id,
      'reservation',
      '❌ Reserva cancelada',
      'El cliente canceló la reserva del ' || v_res.event_date || '.',
      p_reservation_id
    );
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION public.client_cancel_reservation(UUID) TO authenticated;

SELECT 'client_cancel_reservation RPC creado ✅' AS status;
