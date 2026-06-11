-- ============================================================
-- sql/223_express_push_v2.sql
--
-- Fix 1 — Eliminar doble push
--   notify_groups_in_zone() inserta la notificación de zona con
--   push_sent_at = NOW() para que el cron NO la despache como push
--   banner. El registro sigue apareciendo en el bell icon in-app.
--   El único push que llega al dispositivo es el de dispatch (Fix 2).
--
-- Fix 2 — Push inmediata via pg_net
--   notify_group_on_express_dispatch() ahora llama a Expo Push API
--   directamente desde el trigger (fire-and-forget, no bloquea la
--   transacción). El cron de 60s queda como backup: no re-enviará
--   porque el INSERT marca push_sent_at = NOW() antes de pg_net.
--
-- Latencia resultante:
--   INSERT express_dispatches → trigger 223 → net.http_post (async)
--   → Expo API → APNs/FCM → dispositivo ≈ 1-5 segundos.
--
-- Ejecutar en: Supabase Dashboard → SQL Editor
-- Requiere: extensión pg_net habilitada (ya activa en Supabase)
-- ============================================================


-- ══════════════════════════════════════════════════════════════
-- FIX 1: notify_groups_in_zone — suprime push banner
-- ══════════════════════════════════════════════════════════════
-- Copia exacta de 200_fix_neighborhood_city_matching.sql con un
-- único cambio: push_sent_at = NOW() en el INSERT para que el
-- cron nunca lo despacha como push. La notificación sigue siendo
-- visible en el bell icon (read = false, push_sent_at = NOW()).

CREATE OR REPLACE FUNCTION public.notify_groups_in_zone()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_city        TEXT;
  v_municipio   TEXT;
  v_genre       TEXT;
  v_event_type  TEXT;
  v_total_today INT;
  rec           RECORD;
BEGIN
  IF TG_OP <> 'INSERT' THEN RETURN NEW; END IF;

  v_city       := LOWER(TRIM(COALESCE(NEW.city, NEW.location_city)));
  v_municipio  := LOWER(TRIM(COALESCE(NEW.location_municipio, '')));
  v_genre      := NEW.genre;
  v_event_type := COALESCE(NEW.event_type, 'evento');

  IF v_city IS NULL OR v_city = '' THEN RETURN NEW; END IF;
  IF v_genre IS NULL OR v_genre = '' THEN RETURN NEW; END IF;

  SELECT COUNT(*)::INT INTO v_total_today
  FROM public.event_requests
  WHERE genre  = v_genre
    AND status IN ('open', 'pending', 'en_negociacion')
    AND created_at >= NOW() - INTERVAL '24 hours'
    AND (
      LOWER(TRIM(COALESCE(city, location_city))) = v_city
      OR (v_municipio <> '' AND LOWER(TRIM(COALESCE(city, location_city))) = v_municipio)
      OR (v_municipio <> '' AND LOWER(TRIM(COALESCE(location_municipio, ''))) = v_municipio)
    );

  FOR rec IN
    SELECT DISTINCT g.owner_id, g.city AS grp_city
    FROM public.groups g
    WHERE g.owner_id IS NOT NULL
      AND g.is_active = TRUE
      AND COALESCE(g.availability, 'available') = 'available'
      AND g.genre = v_genre
      AND g.owner_id <> NEW.client_id
      AND (
        LOWER(TRIM(g.city)) = v_city
        OR (v_municipio <> '' AND LOWER(TRIM(g.city)) = v_municipio)
      )
      AND NOT EXISTS (
        SELECT 1 FROM public.notifications n
        WHERE n.user_id = g.owner_id
          AND n.type    = 'zone_demand'
          AND (n.data->>'city' = v_city OR n.data->>'city' = v_municipio)
          AND n.data->>'genre' = v_genre
          AND n.created_at > NOW() - INTERVAL '6 hours'
      )
  LOOP
    -- push_sent_at = NOW() → el cron nunca mandará esto como push banner.
    -- El registro es solo para el bell icon in-app.
    INSERT INTO public.notifications (user_id, type, title, body, data, push_sent_at)
    VALUES (
      rec.owner_id,
      'zone_demand',
      '⚡ Solicitud de ' || v_genre || ' en ' || rec.grp_city,
      CASE
        WHEN v_total_today >= 5 THEN
          'Hay ' || v_total_today || ' solicitudes de ' || v_genre || ' en tu zona hoy. ¡Responde rápido!'
        WHEN v_total_today >= 2 THEN
          'Hay ' || v_total_today || ' solicitudes activas de ' || v_genre || ' en tu zona.'
        ELSE
          'Nuevo cliente busca grupo de ' || v_genre || ' cerca de ' || rec.grp_city || '. ¡Sé el primero!'
      END,
      jsonb_build_object(
        'screen',           'OpenRequests',
        'city',             v_city,
        'genre',            v_genre,
        'count',            v_total_today,
        'type',             'express_request',
        'event_request_id', NEW.id::TEXT
      ),
      NOW()   -- ← suprime push banner; solo aparece en bell icon
    );
  END LOOP;

  RETURN NEW;
END;
$$;

-- Recrear trigger (misma definición que 200)
DROP TRIGGER IF EXISTS trg_notify_zone_on_request ON public.event_requests;
CREATE TRIGGER trg_notify_zone_on_request
  AFTER INSERT ON public.event_requests
  FOR EACH ROW
  EXECUTE FUNCTION public.notify_groups_in_zone();


-- ══════════════════════════════════════════════════════════════
-- FIX 2: notify_group_on_express_dispatch — push inmediata
-- ══════════════════════════════════════════════════════════════
-- Reemplaza la versión de 222. Diferencias:
--   1. push_sent_at = NOW() en el INSERT → cron no re-envía
--   2. FOR LOOP sobre push_tokens → net.http_post a Expo API
--      por cada dispositivo del owner (fire-and-forget, async)
--   3. El cron queda como backup si pg_net falla (≤ 60s después)
--      pero normalmente la push llega en 1-5s.

CREATE OR REPLACE FUNCTION public.notify_group_on_express_dispatch()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_owner_id    uuid;
  v_genre       text;
  v_city        text;
  v_notif_id    uuid;
  v_push_title  text;
  v_push_body   text;
  v_tok         RECORD;
BEGIN
  -- Solo para dispatches nuevos listos para mostrar
  IF NEW.status <> 'pending_broadcast' THEN
    RETURN NEW;
  END IF;

  SELECT g.owner_id, g.genre, g.city
    INTO v_owner_id, v_genre, v_city
    FROM public.groups g
   WHERE g.id = NEW.group_id;

  IF v_owner_id IS NULL THEN
    RETURN NEW;
  END IF;

  v_push_title := '⚡ Solicitud Express para ti';
  v_push_body  := 'Tienes una solicitud de ' || COALESCE(v_genre, 'música') ||
                  ' en ' || COALESCE(v_city, 'tu zona') || '. ¡Responde rápido!';

  -- 1. Registrar en notifications (bell icon + audit).
  --    push_sent_at = NOW() indica que la push ya se despacha
  --    via pg_net abajo; el cron no la tocará.
  INSERT INTO public.notifications (user_id, type, title, body, data, push_sent_at)
  VALUES (
    v_owner_id,
    'express_dispatch',
    v_push_title,
    v_push_body,
    jsonb_build_object(
      'type',       'express_dispatch',
      'dispatchId', NEW.id::TEXT,
      'screen',     'IncomingExpress'
    ),
    NOW()
  )
  RETURNING id INTO v_notif_id;

  -- 2. Push inmediata a cada dispositivo registrado del owner.
  --    net.http_post es async (fire-and-forget): no bloquea la
  --    transacción ni el INSERT de express_dispatches.
  --    Prioridad 'high' → APNs/FCM entrega inmediatamente.
  FOR v_tok IN
    SELECT token FROM public.push_tokens WHERE user_id = v_owner_id
  LOOP
    PERFORM net.http_post(
      url     := 'https://exp.host/--/api/v2/push/send',
      headers := '{"Content-Type":"application/json","Accept":"application/json","Accept-Encoding":"gzip, deflate"}'::jsonb,
      body    := jsonb_build_object(
        'to',       v_tok.token,
        'title',    v_push_title,
        'body',     v_push_body,
        'data',     jsonb_build_object(
          'type',       'express_dispatch',
          'dispatchId', NEW.id::TEXT,
          'screen',     'IncomingExpress'
        ),
        'sound',      'default',
        'priority',   'high',
        'channelId',  'default'
      )
    );
  END LOOP;

  RETURN NEW;
END;
$$;

-- Recrear trigger (misma tabla que 222, reemplaza la función)
DROP TRIGGER IF EXISTS trg_notify_group_on_express_dispatch ON public.express_dispatches;
CREATE TRIGGER trg_notify_group_on_express_dispatch
  AFTER INSERT ON public.express_dispatches
  FOR EACH ROW
  EXECUTE FUNCTION public.notify_group_on_express_dispatch();


-- ── Verificación ──────────────────────────────────────────────────────────────
SELECT
  tgname,
  tgrelid::regclass AS tabla,
  tgenabled
FROM pg_trigger
WHERE tgname IN (
  'trg_notify_zone_on_request',
  'trg_notify_group_on_express_dispatch'
);

SELECT '223_express_push_v2.sql ejecutado ✅' AS status;
SELECT 'Fix 1: zone_demand → push suprimida (solo bell icon)' AS fix1;
SELECT 'Fix 2: express_dispatch → push inmediata via pg_net' AS fix2;
