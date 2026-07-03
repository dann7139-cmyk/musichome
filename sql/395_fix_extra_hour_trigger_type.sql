-- ════════════════════════════════════════════════════════════════════
-- sql/395 — Fix trigger notify_extra_hour_proposed: tipo 'reservation' → 'extra_hour_requested'
--
-- Problema:
--   El trigger trg_notify_extra_hour_proposed (sql/353) inserta una
--   notificación con type='reservation' cuando el cliente solicita
--   hora extra (status='awaiting_group_confirmation'). Esto genera
--   una notificación duplicada porque:
--     1. El trigger inserta con type='reservation' → grupo navega a Reservas
--     2. El frontend (handleBuyExtra) también insertaba con type='extra_hour_requested'
--   El grupo abría la primera (type='reservation') y terminaba en la pantalla
--   incorrecta.
--
-- Fix:
--   A. Recrear notify_extra_hour_proposed con type='extra_hour_requested'
--      en el branch awaiting_group_confirmation.
--   B. El frontend ya NO inserta notificación manual (eliminado en esta misma
--      sesión): el trigger es la única fuente y envía type correcto + extra_hour_id.
--
-- NotificationsScreen ya tiene case 'extra_hour_requested' que navega
-- correctamente a EventTimer con reserva cargada.
-- ════════════════════════════════════════════════════════════════════

BEGIN;

CREATE OR REPLACE FUNCTION public.notify_extra_hour_proposed()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_client_id      UUID;
  v_group_owner_id UUID;
BEGIN
  -- Obtener client_id y group owner en un solo query
  SELECT r.client_id, g.owner_id
  INTO   v_client_id, v_group_owner_id
  FROM   public.reservations r
  JOIN   public.groups g ON g.id = r.group_id
  WHERE  r.id = NEW.reservation_id;

  IF NOT FOUND THEN
    RETURN NEW;  -- reserva no encontrada: no bloquear el INSERT
  END IF;

  IF NEW.status = 'pending' THEN
    -- Grupo propuso al cliente
    IF v_client_id IS NOT NULL THEN
      INSERT INTO public.notifications (user_id, type, title, body, data)
      VALUES (
        v_client_id,
        'extra_hour_proposed',
        '⏰ Hora extra propuesta',
        'El grupo propuso ' || NEW.hours_added || 'h extra por $' ||
          NEW.total_extra_cost::TEXT || ' MXN. Revisa y aprueba.',
        jsonb_build_object(
          'screen',         'ClientExtraHours',
          'reservation_id', NEW.reservation_id,
          'extra_hour_id',  NEW.id
        )
      );
    END IF;

  ELSIF NEW.status = 'awaiting_group_confirmation' THEN
    -- Cliente solicitó al grupo
    -- FIX: type corregido de 'reservation' → 'extra_hour_requested'
    -- NotificationsScreen.case 'extra_hour_requested' navega a EventTimer
    IF v_group_owner_id IS NOT NULL THEN
      INSERT INTO public.notifications (user_id, type, title, body, data)
      VALUES (
        v_group_owner_id,
        'extra_hour_requested',
        '⏰ El cliente quiere ' || NEW.hours_added || 'h extra',
        'El cliente solicita ' || NEW.hours_added || 'h extra por $' ||
          NEW.total_extra_cost::TEXT || ' MXN. Confirma para extender el evento.',
        jsonb_build_object(
          'screen',         'EventTimer',
          'reservation_id', NEW.reservation_id,
          'extra_hour_id',  NEW.id
        )
      );
    END IF;
  END IF;

  RETURN NEW;

EXCEPTION WHEN OTHERS THEN
  -- El trigger no debe bloquear el INSERT original
  RAISE WARNING '[395] notify_extra_hour_proposed falló: %', SQLERRM;
  RETURN NEW;
END;
$$;

-- Recrear trigger (idempotente)
DROP TRIGGER IF EXISTS trg_notify_extra_hour_proposed ON public.extra_hours;

CREATE TRIGGER trg_notify_extra_hour_proposed
  AFTER INSERT ON public.extra_hours
  FOR EACH ROW
  WHEN (NEW.status IN ('pending', 'awaiting_group_confirmation'))
  EXECUTE FUNCTION public.notify_extra_hour_proposed();

COMMIT;

-- ════════════════════════════════════════════════════════════════════
-- VERIFICACIONES (ejecutar separado después del COMMIT)
-- ════════════════════════════════════════════════════════════════════

-- V1: Función usa 'extra_hour_requested' (no 'reservation') en awaiting_group_confirmation
SELECT
  routine_definition LIKE '%extra_hour_requested%' AS tipo_correcto,
  routine_definition NOT LIKE '%''reservation''%'  AS sin_tipo_viejo
FROM information_schema.routines
WHERE routine_schema = 'public'
  AND routine_name   = 'notify_extra_hour_proposed';
-- Esperado: true | true

-- V2: Trigger existe y está activo
SELECT trigger_name, event_manipulation, action_timing, action_condition
FROM information_schema.triggers
WHERE trigger_schema = 'public'
  AND event_object_table = 'extra_hours'
  AND trigger_name = 'trg_notify_extra_hour_proposed';
-- Esperado: 1 fila, event_manipulation=INSERT, action_timing=AFTER

-- V3: Función tiene SECURITY DEFINER
SELECT proname, prosecdef AS is_security_definer
FROM pg_proc
WHERE proname = 'notify_extra_hour_proposed'
  AND pronamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public');
-- Esperado: is_security_definer = true

-- V4: Función mantiene el branch 'pending' intacto
SELECT routine_definition LIKE '%extra_hour_proposed%' AS mantiene_pending_notif
FROM information_schema.routines
WHERE routine_schema = 'public'
  AND routine_name   = 'notify_extra_hour_proposed';
-- Esperado: true
