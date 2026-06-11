-- ════════════════════════════════════════════════════════════════════════════
-- 153_notification_validation.sql
-- Validación y robustecimiento del sistema de notificaciones push.
--
-- PROBLEMAS CORREGIDOS:
--   1. CHECK constraint no incluye bid_displaced / bid_expiring_soon / chat
--      → las inserciones de 152 fallan silenciosamente con error 23514
--   2. Sin límite global diario: un usuario puede recibir docenas de pushes
--   3. notify_visibility_fading() nunca se ejecuta (sin cron)
--   4. send-push-notification no skipea notificaciones con body vacío
--      (se corrige en la Edge Function — ver sección 4)
--
-- AÑADE:
--   · Constraint ampliado con todos los tipos existentes
--   · check_daily_push_limit(p_user_id) — devuelve TRUE si puede recibir más
--   · notify_bid_competition() actualizada con límite global
--   · notify_visibility_fading() actualizada con límite global
--   · cron.schedule para notify_visibility_fading (cada 6h vía pg_cron)
--
-- Ejecutar DESPUÉS de 152_bid_competition_triggers.sql
-- ════════════════════════════════════════════════════════════════════════════


-- ── 1. Ampliar CHECK constraint ───────────────────────────────────────────────
-- CRÍTICO: sin esto los INSERT de bid_displaced/bid_expiring_soon fallan.
-- NOT VALID = aplica solo a filas nuevas; no re-valida historial.

DO $$
BEGIN
  ALTER TABLE public.notifications
    DROP CONSTRAINT IF EXISTS notifications_type_check;

  ALTER TABLE public.notifications
    ADD CONSTRAINT notifications_type_check CHECK (type IN (
      -- Legacy
      'reservation', 'payment', 'review', 'verification', 'system',
      'financial', 'admin_alert',
      -- Reservas
      'booking', 'booking_received', 'booking_accepted', 'booking_confirmed',
      'booking_rejected', 'booking_auto_cancelled', 'booking_expired_no_payment',
      'booking_cancelled',
      -- Pagos
      'deposit_received', 'payment_released',
      -- Eventos
      'event_reminder_24h', 'event_completed', 'event_started', 'overtime_requested',
      -- Disputas
      'dispute_opened', 'dispute_received',
      -- Job board
      'job_invitation',
      -- Cotizaciones
      'new_quote_request', 'quote_received', 'quote_accepted', 'quote_cancelled',
      -- Chat
      'chat',
      -- Marketing / visibilidad (grupos)
      'ad_space_available', 'high_demand', 'no_ads_in_city', 'first_ad_reminder',
      -- Re-engagement (clientes)
      'new_city_groups', 'group_nearby',
      -- Competencia de bids (NUEVO en 152)
      'bid_displaced', 'bid_expiring_soon'
    )) NOT VALID;
END;
$$;


-- ── 2. check_daily_push_limit(p_user_id) ─────────────────────────────────────
-- Devuelve TRUE si el usuario puede recibir más notificaciones de marketing hoy.
-- Límite: máx 3 notificaciones de marketing/competencia en las últimas 24h.
-- Tipos incluidos: marketing + bid_displaced + bid_expiring_soon.

CREATE OR REPLACE FUNCTION public.check_daily_push_limit(p_user_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COUNT(*) < 3
  FROM   public.notifications
  WHERE  user_id = p_user_id
    AND  type    IN (
           'ad_space_available', 'high_demand', 'no_ads_in_city', 'first_ad_reminder',
           'bid_displaced', 'bid_expiring_soon'
         )
    AND  created_at > now() - INTERVAL '24 hours';
$$;

GRANT EXECUTE ON FUNCTION public.check_daily_push_limit(UUID)
  TO authenticated;


-- ── 3. notify_bid_competition() — con límite global diario ────────────────────
-- Reemplaza la versión de 152 añadiendo check_daily_push_limit.

CREATE OR REPLACE FUNCTION public.notify_bid_competition()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF TG_OP <> 'UPDATE'
    OR COALESCE(NEW.bid_amount, 0) <= COALESCE(OLD.bid_amount, 0)
    OR NEW.bid_ends_at IS NULL
    OR NEW.bid_ends_at <= now()
    OR NEW.is_active <> true
  THEN
    RETURN NEW;
  END IF;

  INSERT INTO public.notifications (user_id, type, title, body, data)
  SELECT
    g.owner_id,
    'bid_displaced',
    '📉 Perdiste una posición',
    'Otro grupo superó tu posicionamiento en ' || NEW.city ||
      '. Actúa ahora para recuperar tu lugar.',
    jsonb_build_object('screen', 'Bidding', 'city', NEW.city)
  FROM public.groups g
  WHERE normalize_city_name(g.city) = normalize_city_name(NEW.city)
    AND g.id        <> NEW.id
    AND g.is_active  = true
    AND g.bid_ends_at > now()
    AND COALESCE(g.bid_amount, 0) > 0
    AND COALESCE(g.bid_amount, 0) <  COALESCE(NEW.bid_amount, 0)
    AND COALESCE(g.bid_amount, 0) >= COALESCE(OLD.bid_amount, 0)
    -- Anti-spam por tipo: máx 1 bid_displaced cada 30 min
    AND NOT EXISTS (
      SELECT 1 FROM public.notifications n
      WHERE n.user_id = g.owner_id
        AND n.type    = 'bid_displaced'
        AND n.created_at > now() - INTERVAL '30 minutes'
    )
    -- Límite global: máx 3 marketing/competencia en 24h
    AND public.check_daily_push_limit(g.owner_id);

  RETURN NEW;
END;
$$;

-- Re-crear trigger (por si acaso no existía ya)
DROP TRIGGER IF EXISTS trg_notify_bid_competition ON public.groups;
CREATE TRIGGER trg_notify_bid_competition
  AFTER UPDATE OF bid_amount ON public.groups
  FOR EACH ROW EXECUTE FUNCTION public.notify_bid_competition();


-- ── 4. notify_visibility_fading() — con límite global diario ─────────────────

CREATE OR REPLACE FUNCTION public.notify_visibility_fading()
RETURNS INT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_count INT := 0;
BEGIN
  INSERT INTO public.notifications (user_id, type, title, body, data)
  SELECT
    g.owner_id,
    'bid_expiring_soon',
    '⚠️ Estás perdiendo visibilidad',
    'Tu posicionamiento en ' || g.city ||
      ' vence pronto. Renuévalo para no perder tu lugar.',
    jsonb_build_object('screen', 'Bidding', 'city', g.city)
  FROM public.groups g
  WHERE g.is_active  = true
    AND g.bid_ends_at BETWEEN now() AND now() + INTERVAL '48 hours'
    AND COALESCE(g.bid_amount, 0) > 0
    -- Anti-spam por tipo: máx 1 bid_expiring_soon cada 12h
    AND NOT EXISTS (
      SELECT 1 FROM public.notifications n
      WHERE n.user_id = g.owner_id
        AND n.type    = 'bid_expiring_soon'
        AND n.created_at > now() - INTERVAL '12 hours'
    )
    -- Límite global: máx 3 marketing/competencia en 24h
    AND public.check_daily_push_limit(g.owner_id);

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

REVOKE ALL ON FUNCTION public.notify_visibility_fading() FROM anon;
GRANT  EXECUTE ON FUNCTION public.notify_visibility_fading() TO authenticated;


-- ── 5. Cron: notify_visibility_fading cada 6 horas ───────────────────────────
-- Requiere pg_cron habilitado en Supabase (Project Settings → Extensions).
-- Si no está disponible, llamar manualmente o vía Edge Function cron.

DO $$
BEGIN
  PERFORM cron.unschedule('bid-visibility-fading');
EXCEPTION WHEN OTHERS THEN NULL;
END;
$$;

DO $$
BEGIN
  PERFORM cron.schedule(
    'bid-visibility-fading',
    '0 */6 * * *',   -- cada 6 horas
    $cron$SELECT public.notify_visibility_fading();$cron$
  );
  RAISE NOTICE '153: cron bid-visibility-fading registrado (cada 6h)';
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE '153: pg_cron no disponible — registrar manualmente notify_visibility_fading()';
END;
$$;


-- ── 6. Verificación de estado del sistema ────────────────────────────────────
-- Ejecutar después para confirmar que todo está bien.

SELECT
  'notifications_type_check' AS constraint_name,
  conname,
  pg_get_constraintdef(oid)  AS definition
FROM   pg_constraint
WHERE  conname = 'notifications_type_check'
  AND  conrelid = 'public.notifications'::regclass;

-- Cuántas notificaciones pendientes de push
SELECT COUNT(*) AS pending_push
FROM   public.notifications
WHERE  push_sent_at IS NULL;

-- Cuántas sin body (causarían push vacío)
SELECT COUNT(*) AS missing_body
FROM   public.notifications
WHERE  push_sent_at IS NULL
  AND  (body IS NULL OR body = '')
  AND  (message IS NULL OR message = '');

-- Estado del trigger trg_sync_notification_body
SELECT tgname, tgenabled
FROM   pg_trigger
WHERE  tgname = 'trg_sync_notification_body'
  AND  tgrelid = 'public.notifications'::regclass;

-- Estado del trigger trg_notify_bid_competition
SELECT tgname, tgenabled
FROM   pg_trigger
WHERE  tgname = 'trg_notify_bid_competition'
  AND  tgrelid = 'public.groups'::regclass;


SELECT '153_notification_validation.sql ejecutado ✅' AS status;
SELECT 'CRÍTICO CORREGIDO: bid_displaced y bid_expiring_soon en constraint' AS info;
SELECT 'check_daily_push_limit(): máx 3 marketing/competencia en 24h por usuario' AS info;
SELECT 'notify_bid_competition() y notify_visibility_fading() con límite global' AS info;
SELECT 'Cron bid-visibility-fading: cada 6h (si pg_cron disponible)' AS info;
