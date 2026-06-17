-- ════════════════════════════════════════════════════════════════════
-- sql/362_expire_stale_quotes.sql
--
-- Bug: cotizaciones con status='pending' o 'quoted' cuya event_date
-- ya pasó se quedan en "Pendientes" indefinidamente.
-- No existe ningún mecanismo de auto-expiración para la tabla quotes.
--
-- Ejemplo reportado: cotización para evento del 14-jun-2026 sigue
-- apareciendo en "Pendientes" el 17-jun-2026 (3 días después).
--
-- Solución en 4 bloques (todos dentro de un BEGIN/COMMIT):
--   BLOQUE 1 — Añadir 'quote_expired' a notifications_type_check.
--              Patrón idéntico a 349 y 353 — misma lista de tipos
--              + el tipo nuevo. NOT VALID para no revalidar legacy.
--   BLOQUE 2 — RPC expire_stale_quotes(): expira, notifica, retorna JSON.
--   BLOQUE 3 — Cron pg_cron horario: 0 * * * *
--              (no cada 5 min como event_requests — baja urgencia).
--   BLOQUE 4 — Ejecución inmediata para limpiar backlog existente.
--
-- Backward compatible: CREATE OR REPLACE, constraint NOT VALID.
-- Requiere: sql/353 ejecutado (última versión del constraint).
-- ════════════════════════════════════════════════════════════════════

BEGIN;

-- ════════════════════════════════════════════════════════════════════
-- BLOQUE 1: Añadir 'quote_expired' a la constraint de notificaciones
--
-- Lista completa = todos los tipos de sql/353 + quote_expired.
-- NOT VALID: solo valida nuevos INSERTs, no revalida filas legacy.
-- ════════════════════════════════════════════════════════════════════

DO $$
BEGIN
  ALTER TABLE public.notifications
    DROP CONSTRAINT IF EXISTS notifications_type_check;

  ALTER TABLE public.notifications
    ADD CONSTRAINT notifications_type_check CHECK (type IN (
      -- Legacy / genéricos
      'reservation', 'payment', 'review', 'verification', 'system',
      'financial', 'admin_alert', 'admin', 'general',
      -- Reservas (booking flow)
      'booking', 'booking_received', 'booking_accepted', 'booking_confirmed',
      'booking_rejected', 'booking_auto_cancelled', 'booking_expired_no_payment',
      'booking_cancelled',
      -- Pagos y wallet
      'deposit_received', 'payment_released', 'payment_received',
      'payment_mismatch', 'payout', 'wallet',
      -- Recordatorios de evento
      'event_reminder_24h', 'event_upcoming_24h',
      'event_reminder_morning', 'event_reminder_1h',
      'event_reminder_3h',    'event_reminder_2h',
      -- Ciclo de vida del evento
      'event_completed', 'event_started', 'overtime_requested',
      'event_auto_started', 'event_no_show_alert',
      -- Disputas
      'dispute_opened', 'dispute_received', 'dispute',
      -- Bolsa de trabajo
      'job_invitation',
      -- Cotizaciones
      'new_quote_request', 'quote_received',
      'quote_accepted',    'quote_cancelled', 'quote_sent_to_client',
      'quote_expired',                              -- nuevo en 362
      -- Chat
      'chat',
      -- Marketing / visibilidad (grupos)
      'ad_space_available', 'high_demand', 'no_ads_in_city', 'first_ad_reminder',
      -- Anuncios (publicados por grupo)
      'ad_payment_confirmed', 'ad_approved', 'ad_rejected',
      'ad_expiring_soon',     'ad_expired',
      -- Re-engagement (clientes)
      'new_city_groups', 'group_nearby',
      -- Competencia de bids
      'bid_displaced', 'bid_expiring_soon', 'bid_expiry_reminder',
      -- Zona / demanda express
      'zone_demand', 'express_dispatch',
      -- Admin / KYC / anti-fraude
      'fraud_alert', 'referral_reward',
      -- Proximidad al evento (349)
      'request_expired_proximity', 'quote_expired_proximity',
      -- Horas extra (353)
      'extra_hour_proposed', 'extra_hour_approved_by_client', 'extra_hour_payment_confirmed'
    )) NOT VALID;

  RAISE NOTICE '[362] notifications_type_check actualizado con quote_expired ✅';
END;
$$;


-- ════════════════════════════════════════════════════════════════════
-- BLOQUE 2: expire_stale_quotes()
--
-- Criterio de expiración: status IN ('pending','quoted')
--                         AND event_date < CURRENT_DATE
-- Por cada cotización:
--   · UPDATE status = 'expired'
--   · Notifica al cliente (siempre)
--   · Notifica al grupo SOLO si status era 'quoted' (había respondido)
--
-- Advisory lock 5566778899: evita que dos crons se pisen.
-- Bloques EXCEPTION en notificaciones: la expiración nunca falla por
-- un INSERT a notificaciones — guard extra de robustez.
-- ════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.expire_stale_quotes()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_expired_count    INT := 0;
  v_notified_clients INT := 0;
  v_notified_groups  INT := 0;
  v_q                RECORD;
  v_event_label      TEXT;
BEGIN
  -- Advisory lock: solo 1 instancia del cron a la vez
  IF NOT pg_try_advisory_xact_lock(5566778899) THEN
    RETURN jsonb_build_object(
      'ok', true, 'skipped', true, 'reason', 'lock_busy'
    );
  END IF;

  FOR v_q IN
    SELECT q.id,
           q.client_id,
           q.group_id,
           q.status,
           q.event_date,
           q.event_type
    FROM   public.quotes q
    WHERE  q.status    IN ('pending', 'quoted')
      AND  q.event_date < CURRENT_DATE
    ORDER  BY q.event_date ASC   -- más viejas primero
  LOOP
    -- 1. Marcar como expirada
    UPDATE public.quotes
    SET    status     = 'expired',
           updated_at = NOW()
    WHERE  id = v_q.id;

    -- Label legible del tipo de evento para las notificaciones
    v_event_label := CASE v_q.event_type
      WHEN 'fiesta_privada' THEN 'fiesta privada'
      WHEN 'boda'           THEN 'boda'
      WHEN 'cumpleanos'     THEN 'cumpleaños'
      WHEN 'graduacion'     THEN 'graduación'
      WHEN 'empresarial'    THEN 'evento empresarial'
      ELSE COALESCE(v_q.event_type, 'evento')
    END;

    -- 2. Notificar al cliente (siempre — él envió la solicitud)
    IF v_q.client_id IS NOT NULL THEN
      BEGIN
        INSERT INTO public.notifications (user_id, type, title, body, data)
        VALUES (
          v_q.client_id,
          'quote_expired',
          'Solicitud cerrada',
          'Tu solicitud de ' || v_event_label
            || ' del ' || TO_CHAR(v_q.event_date, 'DD/MM/YYYY')
            || ' fue cerrada automáticamente porque la fecha ya pasó.',
          jsonb_build_object(
            'quote_id', v_q.id,
            'screen',   'Reservations'
          )
        );
        v_notified_clients := v_notified_clients + 1;
      EXCEPTION WHEN OTHERS THEN
        NULL; -- no interrumpir el loop si la notificación falla
      END;
    END IF;

    -- 3. Notificar al grupo solo si había enviado cotización (status='quoted')
    IF v_q.status = 'quoted' AND v_q.group_id IS NOT NULL THEN
      BEGIN
        INSERT INTO public.notifications (user_id, type, title, body, data)
        SELECT
          g.owner_id,
          'quote_expired',
          'Cotización sin respuesta',
          'La cotización que enviaste para ' || v_event_label
            || ' del ' || TO_CHAR(v_q.event_date, 'DD/MM/YYYY')
            || ' expiró. El cliente no respondió antes del evento.',
          jsonb_build_object(
            'quote_id', v_q.id,
            'screen',   'GroupQuotes'
          )
        FROM public.groups g
        WHERE g.id = v_q.group_id;
        v_notified_groups := v_notified_groups + 1;
      EXCEPTION WHEN OTHERS THEN
        NULL;
      END;
    END IF;

    v_expired_count := v_expired_count + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'ok',               true,
    'expired',          v_expired_count,
    'notified_clients', v_notified_clients,
    'notified_groups',  v_notified_groups,
    'ran_at',           NOW()
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

-- Solo el cron (service_role) la necesita
GRANT EXECUTE ON FUNCTION public.expire_stale_quotes() TO service_role;
REVOKE EXECUTE ON FUNCTION public.expire_stale_quotes() FROM authenticated;


COMMIT;


-- ════════════════════════════════════════════════════════════════════
-- BLOQUE 3: Cron pg_cron — horario, minuto 0
--
-- Fuera del BEGIN/COMMIT: cron.schedule() es una función que
-- registra el job y no necesita estar en la misma transacción.
-- ════════════════════════════════════════════════════════════════════

DO $$ BEGIN
  PERFORM cron.unschedule('expire-stale-quotes');
EXCEPTION WHEN OTHERS THEN NULL;
END; $$;

SELECT cron.schedule(
  'expire-stale-quotes',
  '0 * * * *',
  'SELECT public.expire_stale_quotes()'
);


-- ════════════════════════════════════════════════════════════════════
-- BLOQUE 4: Ejecución inmediata — limpia backlog existente
--
-- Cotizaciones zombie acumuladas antes de este SQL (como la del
-- 14-jun-2026) se limpian ahora sin esperar el próximo cron.
-- ════════════════════════════════════════════════════════════════════

SELECT public.expire_stale_quotes() AS resultado_inmediato;


-- ════════════════════════════════════════════════════════════════════
-- VERIFICACIONES (ejecutar después del bloque anterior)
-- ════════════════════════════════════════════════════════════════════

-- V1. 'quote_expired' está en el constraint
--     Esperado: 1 fila
SELECT COUNT(*) AS tiene_quote_expired
FROM   pg_constraint c
WHERE  c.conname  = 'notifications_type_check'
  AND  c.conrelid = 'public.notifications'::regclass
  AND  pg_get_constraintdef(c.oid) LIKE '%quote_expired%';


-- V2. Cron registrado correctamente
--     Esperado: 1 fila con schedule = '0 * * * *'
SELECT jobname, schedule, command
FROM   cron.job
WHERE  jobname = 'expire-stale-quotes';


-- V3. Cotizaciones zombie restantes — debe ser 0
SELECT COUNT(*) AS zombies_pendientes
FROM   public.quotes
WHERE  status    IN ('pending', 'quoted')
  AND  event_date < CURRENT_DATE;


-- V4. Distribución actual de la tabla quotes por status
SELECT status, COUNT(*) AS total
FROM   public.quotes
GROUP  BY status
ORDER  BY total DESC;


SELECT 'sql/362_expire_stale_quotes.sql ejecutado ✅' AS status;
