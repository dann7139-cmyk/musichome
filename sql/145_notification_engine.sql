-- ════════════════════════════════════════════════════════════════════════════
-- 145_notification_engine.sql
-- Motor de notificaciones inteligentes por ciudad.
--
-- FUNCIONES:
--   · check_city_ad_slots(p_city)          — disponibilidad de espacios publicitarios
--   · send_city_notifications(...)          — inserta notificaciones in-app para grupos en una ciudad
--   · run_daily_notification_engine()       — orquestador (llamado por cron diario)
--
-- ANTI-SPAM:
--   · Tabla notification_log                — rastrea envíos para evitar repetición
--   · Máx 1 notificación de marketing por usuario cada 20 horas
--   · Prioridad: high_demand > ad_space_available > no_ads_in_city > first_ad_reminder
--
-- SEGMENTACIÓN:
--   · Solo grupos (role = 'group') reciben notificaciones de visibilidad
--   · Ciudad del grupo filtra todos los envíos
--
-- Ejecutar DESPUÉS de 144_city_scale_foundation.sql
-- ════════════════════════════════════════════════════════════════════════════


-- ── 1. Tabla notification_log (anti-spam) ─────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.notification_log (
  id       UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id  UUID        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  ntype    TEXT        NOT NULL,
  sent_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_notif_log_user_type
  ON public.notification_log(user_id, ntype, sent_at DESC);

ALTER TABLE public.notification_log ENABLE ROW LEVEL SECURITY;
-- Los usuarios no necesitan leer este log directamente
DROP POLICY IF EXISTS "service_only" ON public.notification_log;
CREATE POLICY "service_only" ON public.notification_log
  USING (false);


-- ── 2. Ampliar el CHECK de notification types ─────────────────────────────────

DO $$
BEGIN
  -- Eliminar el constraint anterior (cualquier versión)
  ALTER TABLE public.notifications
    DROP CONSTRAINT IF EXISTS notifications_type_check;

  -- NOT VALID: aplica solo a filas nuevas/actualizadas, no valida datos históricos.
  -- Esto evita el error 23514 cuando ya existen filas con tipos legacy.
  ALTER TABLE public.notifications
    ADD CONSTRAINT notifications_type_check CHECK (type IN (
      -- Tipos legacy
      'reservation', 'payment', 'review', 'verification', 'system', 'financial', 'admin_alert',
      -- Flujo de reservas
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
      -- Motor de notificaciones (nuevos)
      'ad_space_available', 'high_demand', 'no_ads_in_city', 'first_ad_reminder'
    )) NOT VALID;
END;
$$;


-- ── 3. check_city_ad_slots(p_city) ───────────────────────────────────────────
-- Devuelve disponibilidad de espacios publicitarios en una ciudad.
-- Límites: banner ≤ 3, destacado (bid) ≤ 10, perfil (sponsored) ≤ 20

DROP FUNCTION IF EXISTS public.check_city_ad_slots(TEXT);
CREATE OR REPLACE FUNCTION public.check_city_ad_slots(p_city TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER STABLE
SET search_path = public
AS $$
DECLARE
  v_banners  INT;
  v_featured INT;
  v_profiles INT;
BEGIN
  IF p_city IS NULL OR trim(p_city) = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'city_required');
  END IF;

  -- Banners activos segmentados por esta ciudad
  SELECT COUNT(*) INTO v_banners
  FROM   public.advertisements
  WHERE  status = 'active'
    AND  type   = 'banner_home'
    AND  ends_at > now()
    AND  target_locations IS NOT NULL
    AND  target_locations @> jsonb_build_array(p_city);

  -- Grupos con bid activo en esta ciudad (ocupan slots de "destacado")
  SELECT COUNT(*) INTO v_featured
  FROM   public.groups
  WHERE  city ILIKE p_city
    AND  bid_ends_at > now()
    AND  COALESCE(bid_amount, 0) > 0;

  -- Grupos patrocinados activos en esta ciudad (slots de "perfil")
  SELECT COUNT(*) INTO v_profiles
  FROM   public.sponsored_groups sg
  JOIN   public.groups g ON g.id = sg.group_id
  WHERE  sg.is_active = true
    AND  sg.ends_at   > now()
    AND  g.city ILIKE p_city;

  RETURN jsonb_build_object(
    'ok',               true,
    'banner_used',      v_banners,
    'featured_used',    v_featured,
    'profile_used',     v_profiles,
    'banner_free',      GREATEST(0, 3  - v_banners),
    'featured_free',    GREATEST(0, 10 - v_featured),
    'profile_free',     GREATEST(0, 20 - v_profiles)
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.check_city_ad_slots(TEXT) TO authenticated, service_role;


-- ── 4. send_city_notifications(p_city, p_ntype, p_title, p_body, p_data) ─────
-- Inserta notificaciones in-app para todos los grupos de una ciudad
-- que no hayan recibido ese tipo en las últimas 20 horas.
-- Devuelve el número de notificaciones insertadas.
--
-- Usa columna `body` (no `message`) para que send-push-notification
-- pueda leerla y despacharla al dispositivo.

DROP FUNCTION IF EXISTS public.send_city_notifications(TEXT, TEXT, TEXT, TEXT);
DROP FUNCTION IF EXISTS public.send_city_notifications(TEXT, TEXT, TEXT, TEXT, JSONB);
CREATE OR REPLACE FUNCTION public.send_city_notifications(
  p_city  TEXT,
  p_ntype TEXT,
  p_title TEXT,
  p_body  TEXT,
  p_data  JSONB DEFAULT '{}'::JSONB
)
RETURNS INT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_count INT;
BEGIN
  -- Insertar notificaciones para grupos elegibles
  WITH eligible AS (
    SELECT p.id AS user_id
    FROM   public.profiles p
    WHERE  p.role = 'group'
      AND  p.city ILIKE p_city
      AND  p.id IS NOT NULL
      -- Anti-spam: no notificado en las últimas 20 horas con este tipo
      AND  NOT EXISTS (
        SELECT 1
        FROM   public.notification_log nl
        WHERE  nl.user_id = p.id
          AND  nl.ntype   = p_ntype
          AND  nl.sent_at > now() - INTERVAL '20 hours'
      )
  ),
  inserted AS (
    -- `body` es la columna que lee send-push-notification
    -- `data` permite el deep-link / enrutamiento en la app
    INSERT INTO public.notifications(user_id, type, title, body, data)
    SELECT user_id,
           p_ntype,
           p_title,
           p_body,
           COALESCE(p_data, '{}'::JSONB) || jsonb_build_object('city', p_city, 'marketing', true)
    FROM   eligible
    RETURNING user_id
  )
  -- Registrar en el log para anti-spam
  INSERT INTO public.notification_log(user_id, ntype)
  SELECT user_id, p_ntype FROM inserted;

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

-- Solo service_role (Edge Functions) puede llamar esto
REVOKE ALL ON FUNCTION public.send_city_notifications(TEXT, TEXT, TEXT, TEXT, JSONB) FROM anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.send_city_notifications(TEXT, TEXT, TEXT, TEXT, JSONB) TO service_role;


-- ── 5. run_daily_notification_engine() ───────────────────────────────────────
-- Orquestador principal. Llamado por la Edge Function cron-ad-notifications.
--
-- Lógica por ciudad (en orden de prioridad):
--   1. Alta demanda        → ⚡ notifica y pasa a siguiente ciudad
--   2. Espacios libres     → 🔥 notifica
--   3. Sin anuncios        → 🚀 notifica (solo si no hay ningún anuncio activo)
-- Lógica global:
--   4. Primer recordatorio → 📢 para grupos que nunca han tenido visibilidad paga

DROP FUNCTION IF EXISTS public.run_daily_notification_engine();
CREATE OR REPLACE FUNCTION public.run_daily_notification_engine()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_city   RECORD;
  v_slots  JSONB;
  v_demand JSONB;
  v_total  INT := 0;
  v_sent   INT := 0;
BEGIN

  -- ── Por ciudad ─────────────────────────────────────────────────────────────
  FOR v_city IN
    SELECT DISTINCT p.city
    FROM   public.profiles p
    WHERE  p.role = 'group'
      AND  p.city IS NOT NULL
      AND  trim(p.city) <> ''
    ORDER BY p.city
  LOOP
    v_slots  := public.check_city_ad_slots(v_city.city);
    v_demand := public.get_city_demand_score(v_city.city);

    -- 1. ALTA DEMANDA (prioridad máxima — salta a siguiente ciudad después)
    IF (v_demand->>'demand_level') IN ('very_high', 'high') THEN
      SELECT public.send_city_notifications(
        v_city.city,
        'high_demand',
        '⚡ Alta demanda en tu ciudad',
        'Alta demanda, promociónate ahora y consigue más eventos.',
        jsonb_build_object('ntype', 'high_demand', 'demand_level', v_demand->>'demand_level',
                           'screen', 'AdvertisingPackages')
      ) INTO v_sent;
      v_total := v_total + v_sent;
      CONTINUE;  -- No enviar más notificaciones para esta ciudad
    END IF;

    -- 2. ESPACIOS DISPONIBLES
    IF (v_slots->>'banner_free')::INT > 0
      OR (v_slots->>'featured_free')::INT > 0
    THEN
      SELECT public.send_city_notifications(
        v_city.city,
        'ad_space_available',
        '🔥 Quedan espacios disponibles hoy',
        'Hay espacios libres en tu ciudad. Aparece primero y consigue más eventos.',
        jsonb_build_object('ntype', 'ad_space_available',
                           'banner_free',   (v_slots->>'banner_free')::INT,
                           'featured_free', (v_slots->>'featured_free')::INT,
                           'screen', 'AdvertisingPackages')
      ) INTO v_sent;
      v_total := v_total + v_sent;
      CONTINUE;
    END IF;

    -- 3. SIN ANUNCIOS ACTIVOS en la ciudad (mercado sin competencia paga)
    IF (v_slots->>'banner_used')::INT = 0
      AND (v_slots->>'featured_used')::INT = 0
      AND (v_slots->>'profile_used')::INT = 0
    THEN
      SELECT public.send_city_notifications(
        v_city.city,
        'no_ads_in_city',
        '🚀 Sé el primero en tu ciudad',
        'No hay grupos promocionados en tu zona. Aparece antes de que otro lo haga.',
        jsonb_build_object('ntype', 'no_ads_in_city', 'screen', 'AdvertisingPackages')
      ) INTO v_sent;
      v_total := v_total + v_sent;
    END IF;

  END LOOP;

  -- ── Global: recordatorio a grupos sin ninguna visibilidad paga ─────────────
  -- (grupos sin bid activo, sin boost, sin sponsored)
  WITH no_ads_groups AS (
    SELECT p.id AS user_id
    FROM   public.profiles p
    JOIN   public.groups   g ON g.city IS NOT NULL  -- tiene grupo vinculado
    WHERE  p.role = 'group'
      -- Sin visibilidad paga activa
      AND  NOT EXISTS (
        SELECT 1 FROM public.groups g2
        WHERE  g2.city ILIKE p.city
          AND  (
            (g2.bid_ends_at > now()   AND COALESCE(g2.bid_amount,   0) > 0)
            OR (g2.boost_ends_at > now() AND COALESCE(g2.boost_score, 0) > 0)
          )
          AND  g2.owner_id = p.id
      )
      -- Anti-spam: no notificado con este tipo en los últimos 7 días
      AND  NOT EXISTS (
        SELECT 1 FROM public.notification_log nl
        WHERE  nl.user_id = p.id
          AND  nl.ntype   = 'first_ad_reminder'
          AND  nl.sent_at > now() - INTERVAL '7 days'
      )
  ),
  inserted AS (
    INSERT INTO public.notifications(user_id, type, title, body, data)
    SELECT user_id,
           'first_ad_reminder',
           '📢 Aumenta tu visibilidad',
           'Los grupos que se anuncian reciben hasta 3× más solicitudes. Descubre los paquetes disponibles.',
           jsonb_build_object('ntype', 'first_ad_reminder', 'marketing', true,
                              'screen', 'AdvertisingPackages')
    FROM   no_ads_groups
    RETURNING user_id
  )
  INSERT INTO public.notification_log(user_id, ntype)
  SELECT user_id, 'first_ad_reminder' FROM inserted;

  GET DIAGNOSTICS v_sent = ROW_COUNT;
  v_total := v_total + v_sent;

  RETURN jsonb_build_object(
    'ok',                  true,
    'notifications_sent',  v_total
  );
END;
$$;

REVOKE ALL ON FUNCTION public.run_daily_notification_engine() FROM anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.run_daily_notification_engine() TO service_role;


-- ── 6. Registrar cron diario (10:00 UTC) ─────────────────────────────────────
-- Requiere: pg_net habilitado en Dashboard → Extensions → pg_net
-- Reemplazar YOUR_PROJECT_REF y YOUR_SERVICE_ROLE_KEY antes de ejecutar.
-- O configurar manualmente en Dashboard → Edge Functions → cron-ad-notifications

DO $$
BEGIN
  BEGIN
    PERFORM cron.unschedule('ad-notifications');
  EXCEPTION WHEN OTHERS THEN NULL; END;

  PERFORM cron.schedule(
    'ad-notifications',
    '0 10 * * *',    -- cada día a las 10:00 UTC
    $cmd$
    SELECT net.http_post(
      url     := 'https://sqgzyipqpewzbnfrtdqk.supabase.co/functions/v1/cron-ad-notifications',
      headers := '{"Authorization": "Bearer YOUR_SERVICE_ROLE_KEY", "Content-Type": "application/json"}'::jsonb,
      body    := '{}'::jsonb
    );
    $cmd$
  );

EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE
    E'⚠️  No se pudo registrar el cron de ad-notifications.\n'
    '   Opciones:\n'
    '   A) Dashboard → Edge Functions → cron-ad-notifications → Schedule → "0 10 * * *"\n'
    '   B) Habilitar pg_net en Extensions y re-ejecutar.';
END;
$$;


SELECT '145_notification_engine.sql ejecutado ✅' AS status;
SELECT 'Tabla: notification_log (anti-spam)' AS info;
SELECT 'RPCs: check_city_ad_slots, send_city_notifications (body+data), run_daily_notification_engine' AS info;
SELECT 'Cron: ad-notifications → 0 10 * * * → cron-ad-notifications edge function' AS info;
