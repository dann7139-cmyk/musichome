-- ════════════════════════════════════════════════════════════════════════════
-- 193_ad_stats_and_notifications.sql
--
-- OBJETIVO: Completar el ciclo de métricas y notificaciones de anuncios.
--
-- 1. track_ad_impression(p_ad_id) — incrementa impressions en advertisements
-- 2. track_ad_click(p_ad_id)      — incrementa clicks en advertisements
-- 3. Nuevos tipos de notificación para el flujo de anuncios:
--      · ad_payment_confirmed  — pago recibido, en revisión
--      · ad_approved           — anuncio activo en la app
--      · ad_expiring_soon      — quedan 24 h de visibilidad
--      · ad_expired            — anuncio vencido, invita a renovar
-- 4. Trigger trg_notify_ad_status — dispara notificaciones en cambios de status
-- 5. notify_expiring_ads()        — cron 1×/hora para avisos de 24 h
-- 6. Trigger trg_notify_ad_expired — dispara notif cuando expire_advertisements
--    marca status = 'expired'
--
-- Requiere: 192_performance_and_flow_fixes.sql
-- ════════════════════════════════════════════════════════════════════════════


-- ════════════════════════════════════════════════════════════════════════════
-- 1. track_ad_impression — incrementa counter de impresiones
-- ════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.track_ad_impression(p_ad_id UUID)
RETURNS VOID
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  UPDATE public.advertisements
  SET    impressions = impressions + 1
  WHERE  id     = p_ad_id
    AND  status = 'active';
$$;

-- Cualquier usuario autenticado o anónimo puede registrar una impresión
GRANT EXECUTE ON FUNCTION public.track_ad_impression(UUID) TO anon, authenticated;


-- ════════════════════════════════════════════════════════════════════════════
-- 2. track_ad_click — incrementa counter de clics
-- ════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.track_ad_click(p_ad_id UUID)
RETURNS VOID
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  UPDATE public.advertisements
  SET    clicks = clicks + 1
  WHERE  id     = p_ad_id
    AND  status = 'active';
$$;

GRANT EXECUTE ON FUNCTION public.track_ad_click(UUID) TO anon, authenticated;


-- ════════════════════════════════════════════════════════════════════════════
-- 3. Ampliar notifications_type_check con tipos de anuncios
-- ════════════════════════════════════════════════════════════════════════════

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
      -- Competencia de bids (152-153)
      'bid_displaced', 'bid_expiring_soon',
      -- Recordatorio renovación (141)
      'bid_expiry_reminder',
      -- ── NUEVOS: flujo de anuncios (193) ──
      'ad_payment_confirmed',   -- pago confirmado, esperando revisión
      'ad_approved',            -- admin aprobó, ya está en vivo
      'ad_expiring_soon',       -- quedan 24 h
      'ad_expired'              -- venció, invita a renovar
    )) NOT VALID;
END;
$$;


-- ════════════════════════════════════════════════════════════════════════════
-- 4. Trigger: notificar al anunciante en cambios de status del anuncio
-- ════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.fn_notify_ad_status()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_title TEXT;
  v_body  TEXT;
  v_type  TEXT;
BEGIN
  -- Solo reaccionar cuando realmente cambia el status
  IF OLD.status = NEW.status THEN RETURN NEW; END IF;

  -- pending_payment → pending_review: pago confirmado por webhook
  IF OLD.status = 'pending_payment' AND NEW.status = 'pending_review' THEN
    v_type  := 'ad_payment_confirmed';
    v_title := '✅ ¡Pago recibido!';
    v_body  := 'Tu anuncio "' || NEW.title || '" está en revisión. El equipo lo aprobará en breve.';

  -- pending_review → active: admin aprobó
  ELSIF OLD.status IN ('pending_review', 'paused') AND NEW.status = 'active' THEN
    v_type  := 'ad_approved';
    v_title := '🚀 ¡Tu anuncio está en vivo!';
    v_body  := '"' || NEW.title || '" ya aparece en la app. ¡Buena suerte con tu campaña!';

  -- → expired: venció (puede ser de 'active' o 'approved')
  ELSIF NEW.status = 'expired' AND OLD.status <> 'expired' THEN
    v_type  := 'ad_expired';
    v_title := '⏰ Tu anuncio ha vencido';
    v_body  := '"' || NEW.title || '" ya no está visible. ¿Quieres renovarlo para seguir apareciendo?';

  ELSE
    RETURN NEW; -- otros cambios de status → sin notificación
  END IF;

  -- Insertar notificación (solo si el anunciante existe)
  INSERT INTO public.notifications (user_id, type, title, body, data)
  SELECT
    NEW.advertiser_id,
    v_type,
    v_title,
    v_body,
    jsonb_build_object(
      'ad_id',   NEW.id,
      'ad_type', NEW.type,
      'screen',  'MyAds'
    )
  WHERE NEW.advertiser_id IS NOT NULL;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_notify_ad_status ON public.advertisements;
CREATE TRIGGER trg_notify_ad_status
  AFTER UPDATE OF status ON public.advertisements
  FOR EACH ROW EXECUTE FUNCTION public.fn_notify_ad_status();


-- ════════════════════════════════════════════════════════════════════════════
-- 5. notify_expiring_ads() — cron 1×/hora
--    Avisa 24 h antes de que venza un anuncio activo.
-- ════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.notify_expiring_ads()
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
    a.advertiser_id,
    'ad_expiring_soon',
    '⏳ Tu anuncio vence en 24 horas',
    '"' || a.title || '" dejará de mostrarse mañana. Renuévalo para mantener tu visibilidad.',
    jsonb_build_object(
      'ad_id',   a.id,
      'ad_type', a.type,
      'ends_at', a.ends_at,
      'screen',  'MyAds'
    )
  FROM public.advertisements a
  WHERE a.status        = 'active'
    AND a.ends_at IS NOT NULL
    AND a.ends_at BETWEEN now() AND now() + INTERVAL '25 hours'
    -- Anti-spam: no repetir si ya se envió hoy
    AND NOT EXISTS (
      SELECT 1 FROM public.notifications n
      WHERE n.user_id = a.advertiser_id
        AND n.type    = 'ad_expiring_soon'
        AND n.data->>'ad_id' = a.id::TEXT
        AND n.created_at > now() - INTERVAL '20 hours'
    )
    AND a.advertiser_id IS NOT NULL;

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

GRANT EXECUTE ON FUNCTION public.notify_expiring_ads() TO service_role;

-- Cron: cada hora (descomentar si tienes pg_cron)
DO $$
BEGIN
  PERFORM cron.unschedule('notify-expiring-ads');
EXCEPTION WHEN OTHERS THEN NULL;
END;
$$;

DO $$
BEGIN
  PERFORM cron.schedule(
    'notify-expiring-ads',
    '30 * * * *',   -- a los :30 de cada hora (distinto de expire_advertisements a los :00/:05)
    $cron$SELECT public.notify_expiring_ads();$cron$
  );
  RAISE NOTICE '193: cron notify-expiring-ads registrado (cada hora a :30)';
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE '193: pg_cron no disponible — registrar manualmente notify_expiring_ads()';
END;
$$;


-- ════════════════════════════════════════════════════════════════════════════
-- Verificación
-- ════════════════════════════════════════════════════════════════════════════

-- Confirmar funciones creadas
SELECT routine_name, routine_type
FROM   information_schema.routines
WHERE  routine_schema = 'public'
  AND  routine_name IN ('track_ad_impression', 'track_ad_click', 'notify_expiring_ads')
ORDER  BY routine_name;

-- Confirmar trigger
SELECT tgname, tgenabled
FROM   pg_trigger
WHERE  tgname    = 'trg_notify_ad_status'
  AND  tgrelid   = 'public.advertisements'::REGCLASS;

-- Anuncios activos próximos a vencer (próximas 48 h)
SELECT id, title, type, ends_at,
       ROUND(EXTRACT(EPOCH FROM (ends_at - now())) / 3600) AS hours_left
FROM   public.advertisements
WHERE  status  = 'active'
  AND  ends_at IS NOT NULL
  AND  ends_at < now() + INTERVAL '48 hours'
ORDER  BY ends_at;

SELECT '193_ad_stats_and_notifications.sql ejecutado ✅' AS status;
