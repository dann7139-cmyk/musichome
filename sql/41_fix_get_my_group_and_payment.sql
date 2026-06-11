-- ══════════════════════════════════════════════════════════════════════════════
-- 41_fix_get_my_group_and_payment.sql
-- 1. Redefine get_my_group() para que también retorne el grupo cuando el
--    usuario es integrante aceptado (no solo dueño).
-- 2. Crea RPC client_mark_deposit_pending para que el cliente pueda marcar
--    su reserva como "pago en proceso" inmediatamente tras pagar.
-- Ejecutar en Supabase SQL Editor.
-- ══════════════════════════════════════════════════════════════════════════════

-- ── 0. DROP primero (necesario para cambiar tipo de retorno) ──────────────────
DROP FUNCTION IF EXISTS public.get_my_group();

-- ── 1. get_my_group — ahora incluye integrantes ───────────────────────────────
CREATE OR REPLACE FUNCTION public.get_my_group()
RETURNS SETOF public.groups
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
DECLARE
  v_group public.groups%ROWTYPE;
BEGIN
  -- Primero: ¿es el dueño de un grupo?
  SELECT * INTO v_group
  FROM public.groups
  WHERE owner_id = auth.uid()
  LIMIT 1;

  IF FOUND THEN
    RETURN NEXT v_group;
    RETURN;
  END IF;

  -- Si no es dueño, ¿es integrante aceptado permanente de algún grupo?
  SELECT g.* INTO v_group
  FROM public.groups g
  JOIN public.job_invitations ji ON ji.group_id = g.id
  WHERE ji.invited_user_id = auth.uid()
    AND ji.status   = 'accepted'
    AND ji.event_id IS NULL     -- membresía permanente (no tocada puntual)
  LIMIT 1;

  IF FOUND THEN
    RETURN NEXT v_group;
  END IF;

  RETURN;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_my_group() TO authenticated;

-- ── 2. client_mark_deposit_pending ───────────────────────────────────────────
-- Marca la reserva como "depósito en proceso" inmediatamente después de que
-- el cliente completa el PaymentSheet. El webhook de Stripe lo confirmará
-- poco después (cambiará a deposit_paid / confirmed).
-- Solo funciona si el cliente es dueño de la reserva y aún no pagó.
CREATE OR REPLACE FUNCTION public.client_mark_deposit_pending(p_reservation_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE public.reservations
  SET payment_status = 'deposit_pending'
  WHERE id         = p_reservation_id
    AND client_id  = auth.uid()
    AND status     = 'accepted'
    AND (payment_status IS NULL
         OR payment_status NOT IN ('deposit_paid', 'fully_paid', 'deposit_pending'));
END;
$$;

GRANT EXECUTE ON FUNCTION public.client_mark_deposit_pending(uuid) TO authenticated;

SELECT 'get_my_group actualizado para dueños + integrantes ✅' AS status;
SELECT 'client_mark_deposit_pending creado ✅' AS status;
