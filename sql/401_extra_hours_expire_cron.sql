-- ════════════════════════════════════════════════════════════════════
-- sql/401 — Auto-expire extra_hours estancadas + pg_cron
--
-- Problema: BUG B2 — El texto "20 min para pagar" en el banner
--   no se cumple técnicamente porque nada expira pending_payment.
--
-- Solución:
--   A. RPC expire_pending_extra_hours()
--      Expira awaiting_group_confirmation > 10 min → 'expired'
--      Notifica cliente (extra_hour_expired) y grupo (extra_hour_expired).
--   B. RPC expire_pending_payment_extras()
--      Expira pending_payment > 30 min desde creación → 'expired'
--      (30 min = 10 min grupo + 20 min cliente, bound conservador)
--      Notifica cliente (extra_hour_expired) y grupo (extra_hour_payment_expired).
--   C. pg_cron: ambas RPCs cada minuto.
--
-- Idempotencia:
--   - FOR UPDATE SKIP LOCKED: nunca procesa la misma fila dos veces.
--   - AND status = 'X' en el UPDATE: guardia anti-race condition.
--   - cron.schedule con mismo nombre: actualiza el job existente.
--
-- NOTA: updated_at en extra_hours no es confiable para medir cuándo
--   el grupo aceptó (sql/400 no la actualiza explícitamente). Por eso
--   se usa created_at + 30 min como bound conservador para pending_payment,
--   garantizando ≥20 min de ventana al cliente independientemente de cuán
--   rápido respondió el grupo.
-- ════════════════════════════════════════════════════════════════════

BEGIN;

-- ── A. expire_pending_extra_hours ─────────────────────────────────────────────
-- Expira solicitudes que el grupo ignoró más de 10 minutos.

DROP FUNCTION IF EXISTS public.expire_pending_extra_hours();

CREATE OR REPLACE FUNCTION public.expire_pending_extra_hours()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_row       RECORD;
  v_client_id UUID;
  v_owner_id  UUID;
  v_count     INTEGER := 0;
BEGIN
  FOR v_row IN
    SELECT e.id, e.reservation_id, e.hours_added, e.total_extra_cost
    FROM   public.extra_hours e
    WHERE  e.status = 'awaiting_group_confirmation'
      AND  e.created_at < NOW() - INTERVAL '10 minutes'
    FOR UPDATE SKIP LOCKED
  LOOP
    -- Marcar expirada (AND en WHERE como guardia anti-race)
    UPDATE public.extra_hours
    SET    status = 'expired'
    WHERE  id     = v_row.id
      AND  status = 'awaiting_group_confirmation';

    IF NOT FOUND THEN CONTINUE; END IF;

    -- Obtener client_id y owner del grupo
    SELECT r.client_id, g.owner_id
    INTO   v_client_id, v_owner_id
    FROM   public.reservations r
    JOIN   public.groups g ON g.id = r.group_id
    WHERE  r.id = v_row.reservation_id;

    -- Notificar al cliente
    IF v_client_id IS NOT NULL THEN
      INSERT INTO public.notifications (user_id, type, title, body, data)
      VALUES (
        v_client_id,
        'extra_hour_expired',
        '⏰ Solicitud expirada',
        'El grupo no respondió a tiempo. Tu solicitud de ' ||
          v_row.hours_added || 'h extra fue cancelada automáticamente.',
        jsonb_build_object(
          'reservation_id', v_row.reservation_id,
          'extra_hour_id',  v_row.id,
          'screen',         'EventTimer'
        )
      );
    END IF;

    -- Notificar al dueño del grupo
    IF v_owner_id IS NOT NULL THEN
      INSERT INTO public.notifications (user_id, type, title, body, data)
      VALUES (
        v_owner_id,
        'extra_hour_expired',
        '⏰ Solicitud de hora extra expiró',
        'No respondiste a tiempo. La solicitud de ' ||
          v_row.hours_added || 'h extra ($' ||
          ROUND(v_row.total_extra_cost)::TEXT ||
          ') fue cancelada automáticamente.',
        jsonb_build_object(
          'reservation_id', v_row.reservation_id,
          'extra_hour_id',  v_row.id,
          'screen',         'EventTimer'
        )
      );
    END IF;

    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;

EXCEPTION WHEN OTHERS THEN
  RAISE WARNING '[401] expire_pending_extra_hours error: %', SQLERRM;
  RETURN -1;
END;
$$;

GRANT EXECUTE ON FUNCTION public.expire_pending_extra_hours()
  TO authenticated, service_role;

-- ── B. expire_pending_payment_extras ─────────────────────────────────────────
-- Expira solicitudes que el cliente no pagó en 30 min desde creación.

DROP FUNCTION IF EXISTS public.expire_pending_payment_extras();

CREATE OR REPLACE FUNCTION public.expire_pending_payment_extras()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_row       RECORD;
  v_client_id UUID;
  v_owner_id  UUID;
  v_count     INTEGER := 0;
BEGIN
  FOR v_row IN
    SELECT e.id, e.reservation_id, e.hours_added, e.total_extra_cost, e.msi_months
    FROM   public.extra_hours e
    WHERE  e.status = 'pending_payment'
      AND  e.created_at < NOW() - INTERVAL '30 minutes'
    FOR UPDATE SKIP LOCKED
  LOOP
    UPDATE public.extra_hours
    SET    status = 'expired'
    WHERE  id     = v_row.id
      AND  status = 'pending_payment';

    IF NOT FOUND THEN CONTINUE; END IF;

    SELECT r.client_id, g.owner_id
    INTO   v_client_id, v_owner_id
    FROM   public.reservations r
    JOIN   public.groups g ON g.id = r.group_id
    WHERE  r.id = v_row.reservation_id;

    -- Notificar al cliente: expiró el tiempo de pago
    IF v_client_id IS NOT NULL THEN
      INSERT INTO public.notifications (user_id, type, title, body, data)
      VALUES (
        v_client_id,
        'extra_hour_expired',
        '⏰ Tiempo de pago expirado',
        'No completaste el pago de ' ||
          v_row.hours_added || 'h extra a tiempo. La solicitud fue cancelada.',
        jsonb_build_object(
          'reservation_id', v_row.reservation_id,
          'extra_hour_id',  v_row.id,
          'screen',         'EventTimer'
        )
      );
    END IF;

    -- Notificar al dueño del grupo: cliente no pagó
    IF v_owner_id IS NOT NULL THEN
      INSERT INTO public.notifications (user_id, type, title, body, data)
      VALUES (
        v_owner_id,
        'extra_hour_payment_expired',
        '⏰ El cliente no completó el pago',
        'El tiempo para pagar ' ||
          v_row.hours_added || 'h extra ($' ||
          ROUND(v_row.total_extra_cost)::TEXT ||
          ') venció. La solicitud fue cancelada automáticamente.',
        jsonb_build_object(
          'reservation_id', v_row.reservation_id,
          'extra_hour_id',  v_row.id,
          'screen',         'EventTimer'
        )
      );
    END IF;

    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;

EXCEPTION WHEN OTHERS THEN
  RAISE WARNING '[401] expire_pending_payment_extras error: %', SQLERRM;
  RETURN -1;
END;
$$;

GRANT EXECUTE ON FUNCTION public.expire_pending_payment_extras()
  TO authenticated, service_role;

COMMIT;

-- ════════════════════════════════════════════════════════════════════
-- C. Extensión + Cron jobs (FUERA de la transacción)
--
-- En Supabase, pg_cron ya está habilitado. Ejecutar estas sentencias
-- individualmente en el SQL Editor después del COMMIT anterior.
-- cron.schedule con el mismo nombre actualiza el job existente (idempotente).
-- ════════════════════════════════════════════════════════════════════

CREATE EXTENSION IF NOT EXISTS pg_cron;

-- Limpiar jobs anteriores si existen (0 filas = no existían, sin error)
SELECT cron.unschedule(jobid)
FROM   cron.job
WHERE  jobname IN ('expire-extra-hours-awaiting', 'expire-extra-hours-payment');

-- Job 1: Expirar awaiting_group_confirmation > 10 min
SELECT cron.schedule(
  'expire-extra-hours-awaiting',
  '* * * * *',
  'SELECT public.expire_pending_extra_hours()'
);

-- Job 2: Expirar pending_payment > 30 min desde creación
SELECT cron.schedule(
  'expire-extra-hours-payment',
  '* * * * *',
  'SELECT public.expire_pending_payment_extras()'
);

-- ════════════════════════════════════════════════════════════════════
-- VERIFICACIONES (ejecutar separado después del COMMIT + cron)
-- ════════════════════════════════════════════════════════════════════

-- V1: expire_pending_extra_hours existe y es SECURITY DEFINER
SELECT
  COUNT(*) = 1       AS funcion_a_existe,
  BOOL_OR(prosecdef) AS es_security_definer
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname = 'expire_pending_extra_hours';
-- Esperado: true | true

-- V2: expire_pending_payment_extras existe y es SECURITY DEFINER
SELECT
  COUNT(*) = 1       AS funcion_b_existe,
  BOOL_OR(prosecdef) AS es_security_definer
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname = 'expire_pending_payment_extras';
-- Esperado: true | true

-- V3: Cron jobs registrados y activos
SELECT jobname, schedule, command, active
FROM   cron.job
WHERE  jobname IN ('expire-extra-hours-awaiting', 'expire-extra-hours-payment')
ORDER  BY jobname;
-- Esperado: 2 filas, schedule='* * * * *', active=true

-- V4: GRANTs correctos para service_role
SELECT
  COUNT(*) FILTER (WHERE routine_name = 'expire_pending_extra_hours'   AND grantee = 'service_role') > 0 AS grant_a,
  COUNT(*) FILTER (WHERE routine_name = 'expire_pending_payment_extras' AND grantee = 'service_role') > 0 AS grant_b
FROM information_schema.role_routine_grants
WHERE routine_schema = 'public';
-- Esperado: true | true
