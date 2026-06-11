-- ══════════════════════════════════════════════════════════════════════════════
-- 43_fix_mark_deposit_pending_confirmed.sql
-- Actualiza client_mark_deposit_pending para aceptar status = 'confirmed'.
-- El RPC confirm_member_attendance salta 'accepted' y va directo a 'confirmed',
-- por lo que la función anterior (solo 'accepted') nunca se disparaba.
-- Ejecutar en Supabase SQL Editor.
-- ══════════════════════════════════════════════════════════════════════════════

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
    AND status     IN ('accepted', 'confirmed')          -- antes solo 'accepted'
    AND (payment_status IS NULL
         OR payment_status NOT IN ('deposit_paid', 'fully_paid', 'deposit_pending'));
END;
$$;

GRANT EXECUTE ON FUNCTION public.client_mark_deposit_pending(uuid) TO authenticated;

SELECT 'client_mark_deposit_pending actualizado: acepta accepted + confirmed ✅' AS status;
