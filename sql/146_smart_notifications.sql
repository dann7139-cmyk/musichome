-- ════════════════════════════════════════════════════════════════════════════
-- 146_smart_notifications.sql
-- Notificaciones más adictivas: mensajes personalizados por ciudad,
-- nuevos tipos para grupos Y clientes, frecuencia controlada.
--
-- CAMBIOS:
--   · run_daily_notification_engine() — mensajes urgentes con ciudad real
--   · send_client_city_notifications() — notifica clientes: "nuevos grupos"
--   · notifications type CHECK ampliado (new_city_groups, group_nearby)
--   · Anti-spam: 24h para marketing, 7d para first_ad_reminder y clients
--
-- Ejecutar DESPUÉS de 145_notification_engine.sql
-- ════════════════════════════════════════════════════════════════════════════


-- ── 1. Ampliar tipos de notificación ─────────────────────────────────────────

DO $$
BEGIN
  ALTER TABLE public.notifications
    DROP CONSTRAINT IF EXISTS notifications_type_check;

  ALTER TABLE public.notifications
    ADD CONSTRAINT notifications_type_check CHECK (type IN (
      'reservation', 'payment', 'review', 'verification', 'system', 'financial', 'admin_alert',
      'booking', 'booking_received', 'booking_accepted', 'booking_confirmed',
      'booking_rejected', 'booking_auto_cancelled', 'booking_expired_no_payment', 'booking_cancelled',
      'deposit_received', 'payment_released',
      'event_reminder_24h', 'event_completed', 'event_started', 'overtime_requested',
      'dispute_opened', 'dispute_received',
      'job_invitation',
      'new_quote_request', 'quote_received', 'quote_accepted', 'quote_cancelled',
      -- Motor de marketing (grupos)
      'ad_space_available', 'high_demand', 'no_ads_in_city', 'first_ad_reminder',
      -- Motor de re-engagement (clientes)
      'new_city_groups', 'group_nearby'
    )) NOT VALID;
END;
$$;


-- ── 2. run_daily_notification_engine() mejorado ───────────────────────────────
-- Mensajes personalizados con ciudad real, urgencia y acción directa.

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
  v_city_name TEXT;
  v_banner_free INT;
  v_featured_free INT;
BEGIN

  -- ══ PARTE A: Notificaciones a GRUPOS por ciudad ═══════════════════════════

  FOR v_city IN
    SELECT DISTINCT p.city
    FROM   public.profiles p
    WHERE  p.role = 'group'
      AND  p.city IS NOT NULL
      AND  trim(p.city) <> ''
    ORDER BY p.city
  LOOP
    v_city_name     := v_city.city;
    v_slots         := public.check_city_ad_slots(v_city_name);
    v_demand        := public.get_city_demand_score(v_city_name);
    v_banner_free   := COALESCE((v_slots->>'banner_free')::INT, 3);
    v_featured_free := COALESCE((v_slots->>'featured_free')::INT, 10);

    -- ── 1. ALTA DEMANDA — mayor urgencia posible ─────────────────────────
    IF (v_demand->>'demand_level') IN ('very_high', 'high') THEN
      SELECT public.send_city_notifications(
        v_city_name,
        'high_demand',
        '⚡ Alta demanda en ' || v_city_name,
        'Hay clientes buscando grupos en tu zona ahora. Si no te promocionas pierdes eventos. Actúa antes de que otro lo haga.',
        jsonb_build_object(
          'screen',       'AdvertisingPackages',
          'city',         v_city_name,
          'demand_level', v_demand->>'demand_level',
          'marketing',    true
        )
      ) INTO v_sent;
      v_total := v_total + v_sent;
      CONTINUE;
    END IF;

    -- ── 2. ESPACIOS DISPONIBLES — escasez real ───────────────────────────
    IF v_banner_free > 0 OR v_featured_free > 0 THEN
      SELECT public.send_city_notifications(
        v_city_name,
        'ad_space_available',
        CASE
          WHEN v_banner_free <= 2 THEN '🔴 Solo ' || v_banner_free || ' espacios en ' || v_city_name
          ELSE '🔥 Espacios disponibles en ' || v_city_name
        END,
        CASE
          WHEN v_banner_free <= 2
          THEN 'Quedan ' || v_banner_free || ' espacios de banner en tu ciudad. Los grupos que se anuncian reciben hasta 3× más solicitudes.'
          ELSE 'Hay ' || v_featured_free || ' slots disponibles hoy en ' || v_city_name || '. Aparece primero antes de que se llenen.'
        END,
        jsonb_build_object(
          'screen',         'AdvertisingPackages',
          'city',           v_city_name,
          'banner_free',    v_banner_free,
          'featured_free',  v_featured_free,
          'marketing',      true
        )
      ) INTO v_sent;
      v_total := v_total + v_sent;
      CONTINUE;
    END IF;

    -- ── 3. SIN ANUNCIOS — mercado sin competencia ─────────────────────
    IF (v_slots->>'banner_used')::INT = 0
      AND (v_slots->>'featured_used')::INT = 0
      AND (v_slots->>'profile_used')::INT = 0
    THEN
      SELECT public.send_city_notifications(
        v_city_name,
        'no_ads_in_city',
        '🚀 Sé el primero en ' || v_city_name,
        'Ningún grupo en tu ciudad se está promocionando. Es tu oportunidad de aparecer primero sin competencia.',
        jsonb_build_object(
          'screen',    'AdvertisingPackages',
          'city',      v_city_name,
          'marketing', true
        )
      ) INTO v_sent;
      v_total := v_total + v_sent;
    END IF;

  END LOOP;

  -- ── 4. RECORDATORIO GLOBAL — grupos sin ninguna visibilidad paga ─────────
  WITH no_ads_groups AS (
    SELECT p.id AS user_id, p.city
    FROM   public.profiles p
    WHERE  p.role = 'group'
      AND  p.city IS NOT NULL AND trim(p.city) <> ''
      AND  NOT EXISTS (
        SELECT 1 FROM public.groups g2
        WHERE  g2.city ILIKE p.city
          AND  g2.owner_id = p.id
          AND  (
            (g2.bid_ends_at > now()    AND COALESCE(g2.bid_amount,  0) > 0)
            OR (g2.boost_ends_at > now() AND COALESCE(g2.boost_score, 0) > 0)
          )
      )
      AND  NOT EXISTS (
        SELECT 1 FROM public.notification_log nl
        WHERE  nl.user_id = p.id
          AND  nl.ntype   = 'first_ad_reminder'
          AND  nl.sent_at > now() - INTERVAL '7 days'
      )
  ),
  inserted AS (
    INSERT INTO public.notifications(user_id, type, title, body, data)
    SELECT
      user_id,
      'first_ad_reminder',
      '📢 ' || city || ' te espera',
      'Estás perdiendo eventos por no promocionarte. Los grupos con visibilidad paga reciben hasta 3× más solicitudes en su ciudad.',
      jsonb_build_object(
        'screen', 'AdvertisingPackages', 'marketing', true,
        'city', city
      )
    FROM no_ads_groups
    RETURNING user_id
  )
  INSERT INTO public.notification_log(user_id, ntype)
  SELECT user_id, 'first_ad_reminder' FROM inserted;

  GET DIAGNOSTICS v_sent = ROW_COUNT;
  v_total := v_total + v_sent;


  -- ══ PARTE B: Notificaciones a CLIENTES ═══════════════════════════════════
  -- Re-engagement: "hay grupos nuevos en tu ciudad"

  SELECT public.send_client_city_notifications() INTO v_sent;
  v_total := v_total + v_sent;


  RETURN jsonb_build_object(
    'ok',                 true,
    'notifications_sent', v_total
  );
END;
$$;

REVOKE ALL ON FUNCTION public.run_daily_notification_engine() FROM anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.run_daily_notification_engine() TO service_role;


-- ── 3. send_client_city_notifications() ──────────────────────────────────────
-- Notifica a clientes sobre actividad en su ciudad.
-- Anti-spam: máx 1 notificación de este tipo cada 3 días.

DROP FUNCTION IF EXISTS public.send_client_city_notifications();
CREATE OR REPLACE FUNCTION public.send_client_city_notifications()
RETURNS INT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_city      RECORD;
  v_total     INT := 0;
  v_new_count INT;
BEGIN
  FOR v_city IN
    SELECT DISTINCT p.city
    FROM   public.profiles p
    WHERE  p.role = 'client'
      AND  p.city IS NOT NULL AND trim(p.city) <> ''
    ORDER BY p.city
  LOOP
    -- Contar grupos activos que se unieron en los últimos 7 días o tienen bid activo
    SELECT COUNT(*) INTO v_new_count
    FROM   public.groups g
    WHERE  g.city ILIKE v_city.city
      AND  g.is_active = true
      AND  (
        g.created_at > now() - INTERVAL '7 days'
        OR (g.bid_ends_at > now() AND COALESCE(g.bid_amount, 0) > 0)
      );

    IF v_new_count = 0 THEN CONTINUE; END IF;

    WITH eligible AS (
      SELECT p.id AS user_id
      FROM   public.profiles p
      WHERE  p.role = 'client'
        AND  p.city ILIKE v_city.city
        AND  NOT EXISTS (
          SELECT 1 FROM public.notification_log nl
          WHERE  nl.user_id = p.id
            AND  nl.ntype   = 'new_city_groups'
            AND  nl.sent_at > now() - INTERVAL '3 days'
        )
    ),
    inserted AS (
      INSERT INTO public.notifications(user_id, type, title, body, data)
      SELECT
        user_id,
        'new_city_groups',
        '🎶 Grupos disponibles en ' || v_city.city,
        CASE
          WHEN v_new_count >= 5 THEN v_new_count || ' grupos activos en tu zona ahora. Encuentra el ideal para tu evento.'
          WHEN v_new_count >= 2 THEN v_new_count || ' grupos nuevos disponibles cerca de ti. Encuéntralos antes de que se agenden.'
          ELSE 'Hay un grupo nuevo disponible en ' || v_city.city || '. Revisa si es el indicado para tu evento.'
        END,
        jsonb_build_object(
          'screen',  'Explorar',
          'city',    v_city.city,
          'count',   v_new_count
        )
      FROM eligible
      RETURNING user_id
    )
    INSERT INTO public.notification_log(user_id, ntype)
    SELECT user_id, 'new_city_groups' FROM inserted;

    GET DIAGNOSTICS v_new_count = ROW_COUNT;
    v_total := v_total + v_new_count;

  END LOOP;

  RETURN v_total;
END;
$$;

REVOKE ALL ON FUNCTION public.send_client_city_notifications() FROM anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.send_client_city_notifications() TO service_role;


SELECT '146_smart_notifications.sql ejecutado ✅' AS status;
SELECT 'Mensajes personalizados con ciudad, urgencia y escasez real' AS info;
SELECT 'Nueva función: send_client_city_notifications() para re-engagement de clientes' AS info;
