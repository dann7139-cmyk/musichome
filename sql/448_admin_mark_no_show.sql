-- ============================================================
-- sql/448_admin_mark_no_show.sql
-- Permite al admin marcar como NO-SHOW un evento ATORADO (status='confirmed')
-- cuando confirma por teléfono que el grupo NO se presentará.
--
-- PROBLEMA: la cola de "Eventos atorados" (admin_get_stuck_events) solo
-- ofrecía "Forzar inicio". Si el admin llama y el grupo dice que no irá,
-- no había botón para cancelar+reembolsar desde ahí. Reembolsar un evento
-- 'confirmed' directo dejaría estado sucio (confirmed + refunded).
--
-- ESTA función lleva el evento atorado al MISMO estado canónico que produce
-- mark_abandoned_reservations (status='cancelled', cancellation_type=
-- 'system_auto', cancel_reason='no_show_grupo', payout_status='blocked'),
-- para que caiga en la cola de No-Shows y el admin lo resuelva con el
-- flujo EXISTENTE (process-refund Stripe + admin_apply_strike +
-- admin_resolve_no_show). El frontend encadena marcar → resolver en un tap.
--
-- NO reembolsa, NO aplica strike, NO toca wallet — eso lo hace el flujo de
-- resolución que ya existe. NO toca el candado GPS ni el release del 50%.
-- Guarda cancelled_by = admin (auditoría), a diferencia del cron (NULL).
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.admin_mark_no_show(p_reservation_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_id UUID := auth.uid();
  v_res      RECORD;
BEGIN
  -- Gate admin
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = v_admin_id AND role = 'admin') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Acceso restringido a administradores');
  END IF;

  SELECT * INTO v_res FROM reservations WHERE id = p_reservation_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Reserva no encontrada');
  END IF;

  -- Solo eventos aún confirmados y no iniciados
  IF v_res.status <> 'confirmed' OR v_res.event_started_at IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_stuck', 'status', v_res.status);
  END IF;

  -- No tocar si el pago ya se liberó o ya se reembolsó
  IF v_res.payout_status IN ('released', 'refunded') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'payout_no_reversible', 'payout_status', v_res.payout_status);
  END IF;

  UPDATE reservations SET
    status            = 'cancelled',
    cancelled_at      = NOW(),
    cancelled_by      = v_admin_id,        -- auditoría: admin lo marcó (cron usa NULL)
    cancel_reason     = 'no_show_grupo',
    cancellation_type = 'system_auto',     -- mismo tipo que mark_abandoned → cae en cola No-Shows
    payout_status     = 'blocked',
    updated_at        = NOW()
  WHERE id = p_reservation_id;

  RETURN jsonb_build_object('ok', true, 'status', 'cancelled', 'folio', v_res.folio);
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_mark_no_show(UUID) TO authenticated;

COMMIT;

-- ── VERIFICACIONES (correr por separado después del COMMIT) ─────────────────────
-- V1: función existe, SECURITY DEFINER, y NO toca dinero/GPS (solo cancela)
SELECT
  prosecdef                                   AS is_security_definer,
  prosrc LIKE '%no_show_grupo%'                AS marca_no_show,        -- true
  prosrc LIKE '%system_auto%'                  AS tipo_system_auto,     -- true
  prosrc NOT LIKE '%release_half_on_arrival%'  AS no_toca_gps,          -- true
  prosrc NOT LIKE '%group_wallets%'            AS no_toca_wallet,       -- true
  prosrc NOT LIKE '%admin_apply_strike%'       AS no_aplica_strike_aqui -- true (lo hace el flujo de resolución)
FROM pg_proc
WHERE proname = 'admin_mark_no_show';
-- Esperado: true | true | true | true | true | true

-- V2 (manual): tras marcar un atorado, debe aparecer en la cola de No-Shows
-- SELECT admin_mark_no_show('UUID-REAL'::UUID);
-- SELECT admin_get_no_shows();  -- la reserva ahora aparece ahí (resolution NULL)

SELECT '448_admin_mark_no_show.sql ejecutado ✅' AS status;
