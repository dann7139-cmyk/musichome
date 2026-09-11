-- sql/641_admin_ops_media_and_stuck_events.sql
--
-- Petición del usuario (2026-09-11): que la cuenta de EE.UU. (admin_ops)
-- pueda también forzar el inicio/cierre de eventos y aprobar fotos —
-- pero SOLO de grupos de su país (US). Verificado antes de tocar nada:
-- ninguna de las dos cosas era accesible para admin_ops hoy.
--
--  1. approve_group_photo / reject_group_photo / approve_group_video /
--     reject_group_video — eran 100% exclusivas de role='admin'. Se
--     agrega la misma rama de país que ya usa admin_force_start_event.
--  2. RLS gep_posts_admin_update (group_event_posts) y gv_admin_update
--     (group_videos) — mismo caso, se agrega la rama de país.
--  3. admin_get_pending_media(limit) — NUEVA. Reemplaza las 3 queries
--     directas sin filtro que hacía MediaReviewScreen.tsx (grupos con
--     foto/video pendiente, publicaciones pendientes, videos de
--     carrusel pendientes) — ahora separadas por país para admin_ops,
--     admin completo sigue viendo todo.
--  4. admin_get_stuck_service_events(limit) — NUEVA. Hermana de
--     admin_get_stuck_events (que ya cubre "nunca inició"): esta cubre
--     el caso nuevo de sql/639 — "inició pero nunca cerró" (p.ej. el
--     cliente nunca dio el código de servicio terminado). Umbral: más
--     de 24 horas desde que inició, para no marcar como "atorado" un
--     evento de recolección al día siguiente que sigue su curso normal.
--     Trae teléfonos de cliente y proveedor, listos para llamar.
--
-- El admin completo NO pierde nada: en las 4 funciones y en ambas RPCs
-- nuevas, la rama `v_role = 'admin'` sigue viendo/actuando sobre TODO
-- sin importar país — igual que siempre.
-- ============================================================

BEGIN;

-- ── 1. Fotos y videos de perfil de grupo ──────────────────────────────
CREATE OR REPLACE FUNCTION public.approve_group_photo(p_group_id uuid)
RETURNS json LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_role TEXT;
BEGIN
  SELECT role INTO v_role FROM profiles WHERE id = auth.uid();
  IF v_role NOT IN ('admin', 'admin_ops') THEN
    RETURN json_build_object('ok', false, 'error', 'No autorizado');
  END IF;
  IF v_role = 'admin_ops' AND NOT EXISTS (
    SELECT 1 FROM groups g WHERE g.id = p_group_id AND country_code_of(g.country) = admin_ops_country()
  ) THEN
    RETURN json_build_object('ok', false, 'error', 'No autorizado');
  END IF;

  UPDATE groups SET photo_status = 'approved', photo_reject_reason = NULL WHERE id = p_group_id;
  IF NOT FOUND THEN RETURN json_build_object('ok', false, 'error', 'Grupo no encontrado'); END IF;
  RETURN json_build_object('ok', true);
END;
$$;

CREATE OR REPLACE FUNCTION public.reject_group_photo(p_group_id uuid, p_reason text)
RETURNS json LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_role TEXT;
BEGIN
  SELECT role INTO v_role FROM profiles WHERE id = auth.uid();
  IF v_role NOT IN ('admin', 'admin_ops') THEN
    RETURN json_build_object('ok', false, 'error', 'No autorizado');
  END IF;
  IF v_role = 'admin_ops' AND NOT EXISTS (
    SELECT 1 FROM groups g WHERE g.id = p_group_id AND country_code_of(g.country) = admin_ops_country()
  ) THEN
    RETURN json_build_object('ok', false, 'error', 'No autorizado');
  END IF;

  UPDATE groups SET photo_status = 'rejected', photo_reject_reason = p_reason WHERE id = p_group_id;
  IF NOT FOUND THEN RETURN json_build_object('ok', false, 'error', 'Grupo no encontrado'); END IF;
  RETURN json_build_object('ok', true);
END;
$$;

CREATE OR REPLACE FUNCTION public.approve_group_video(p_group_id uuid)
RETURNS json LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_role TEXT;
BEGIN
  SELECT role INTO v_role FROM profiles WHERE id = auth.uid();
  IF v_role NOT IN ('admin', 'admin_ops') THEN
    RETURN json_build_object('ok', false, 'error', 'No autorizado');
  END IF;
  IF v_role = 'admin_ops' AND NOT EXISTS (
    SELECT 1 FROM groups g WHERE g.id = p_group_id AND country_code_of(g.country) = admin_ops_country()
  ) THEN
    RETURN json_build_object('ok', false, 'error', 'No autorizado');
  END IF;

  UPDATE groups SET video_status = 'approved', video_reject_reason = NULL WHERE id = p_group_id;
  IF NOT FOUND THEN RETURN json_build_object('ok', false, 'error', 'Grupo no encontrado'); END IF;
  RETURN json_build_object('ok', true);
END;
$$;

CREATE OR REPLACE FUNCTION public.reject_group_video(p_group_id uuid, p_reason text)
RETURNS json LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_role TEXT;
BEGIN
  SELECT role INTO v_role FROM profiles WHERE id = auth.uid();
  IF v_role NOT IN ('admin', 'admin_ops') THEN
    RETURN json_build_object('ok', false, 'error', 'No autorizado');
  END IF;
  IF v_role = 'admin_ops' AND NOT EXISTS (
    SELECT 1 FROM groups g WHERE g.id = p_group_id AND country_code_of(g.country) = admin_ops_country()
  ) THEN
    RETURN json_build_object('ok', false, 'error', 'No autorizado');
  END IF;

  UPDATE groups SET video_status = 'rejected', video_reject_reason = p_reason WHERE id = p_group_id;
  IF NOT FOUND THEN RETURN json_build_object('ok', false, 'error', 'Grupo no encontrado'); END IF;
  RETURN json_build_object('ok', true);
END;
$$;

-- ── 2. RLS: publicaciones y videos de carrusel ─────────────────────────
DROP POLICY IF EXISTS gep_posts_admin_update ON public.group_event_posts;
CREATE POLICY gep_posts_admin_update ON public.group_event_posts
  FOR UPDATE TO public
  USING (
    EXISTS (SELECT 1 FROM profiles p WHERE p.id = auth.uid() AND p.role = 'admin')
    OR (admin_ops_country() IS NOT NULL AND EXISTS (
      SELECT 1 FROM groups g WHERE g.id = group_event_posts.group_id
        AND country_code_of(g.country) = admin_ops_country()
    ))
  );

DROP POLICY IF EXISTS gv_admin_update ON public.group_videos;
CREATE POLICY gv_admin_update ON public.group_videos
  FOR UPDATE TO public
  USING (
    EXISTS (SELECT 1 FROM profiles p WHERE p.id = auth.uid() AND p.role = 'admin')
    OR (admin_ops_country() IS NOT NULL AND EXISTS (
      SELECT 1 FROM groups g WHERE g.id = group_videos.group_id
        AND country_code_of(g.country) = admin_ops_country()
    ))
  );

-- ── 3. Cola de fotos/videos/publicaciones pendientes, por país ────────
CREATE OR REPLACE FUNCTION public.admin_get_pending_media(p_limit integer DEFAULT 50)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_role   TEXT;
  v_groups jsonb;
  v_posts  jsonb;
  v_videos jsonb;
BEGIN
  SELECT role INTO v_role FROM profiles WHERE id = auth.uid();
  IF v_role NOT IN ('admin', 'admin_ops') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;

  SELECT COALESCE(jsonb_agg(x), '[]'::jsonb) INTO v_groups FROM (
    SELECT jsonb_build_object(
      'id', g.id, 'name', g.name, 'profile_image', g.profile_image, 'promo_video', g.promo_video,
      'photo_status', g.photo_status, 'video_status', g.video_status,
      'photo_reject_reason', g.photo_reject_reason, 'video_reject_reason', g.video_reject_reason,
      'owner_id', g.owner_id
    ) AS x
    FROM groups g
    WHERE (g.photo_status = 'pending' OR g.video_status = 'pending')
      AND (v_role = 'admin' OR country_code_of(g.country) = admin_ops_country())
    LIMIT p_limit
  ) t;

  -- 'groups' anidado (no group_name/group_owner_id planos) para que
  -- MediaReviewScreen.tsx no tenga que cambiar ni un uso de post.groups?.x
  SELECT COALESCE(jsonb_agg(x), '[]'::jsonb) INTO v_posts FROM (
    SELECT jsonb_build_object(
      'id', p.id, 'group_id', p.group_id, 'caption', p.caption,
      'groups', jsonb_build_object('name', g.name, 'owner_id', g.owner_id),
      'photos', (
        SELECT COALESCE(jsonb_agg(jsonb_build_object('id', ph.id, 'url', ph.url, 'position', ph.position) ORDER BY ph.position), '[]'::jsonb)
        FROM group_event_photos ph WHERE ph.post_id = p.id
      )
    ) AS x
    FROM group_event_posts p
    JOIN groups g ON g.id = p.group_id
    WHERE p.status = 'pending'
      AND (v_role = 'admin' OR country_code_of(g.country) = admin_ops_country())
    LIMIT p_limit
  ) t;

  SELECT COALESCE(jsonb_agg(x), '[]'::jsonb) INTO v_videos FROM (
    SELECT jsonb_build_object('id', v.id, 'group_id', v.group_id, 'url', v.url,
      'groups', jsonb_build_object('name', g.name, 'owner_id', g.owner_id)) AS x
    FROM group_videos v
    JOIN groups g ON g.id = v.group_id
    WHERE v.status = 'pending'
      AND (v_role = 'admin' OR country_code_of(g.country) = admin_ops_country())
    LIMIT p_limit
  ) t;

  RETURN jsonb_build_object('ok', true, 'groups', v_groups, 'event_posts', v_posts, 'videos', v_videos);
END;
$$;

-- ── 4. Eventos "atorados sin cerrar" (sql/639, nunca dieron el código) ──
CREATE OR REPLACE FUNCTION public.admin_get_stuck_service_events(p_limit integer DEFAULT 50)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_role   TEXT;
  v_result jsonb;
BEGIN
  SELECT role INTO v_role FROM profiles WHERE id = auth.uid();
  IF v_role NOT IN ('admin', 'admin_ops') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;

  SELECT jsonb_build_object('ok', true, 'items', COALESCE(jsonb_agg(x.item ORDER BY x.started_at ASC), '[]'::jsonb))
  INTO v_result
  FROM (
    SELECT
      r.event_started_at AS started_at,
      jsonb_build_object(
        'id',               r.id,
        'folio',            r.folio,
        'event_date',       r.event_date,
        'event_time',       r.event_time,
        'total_price',      r.total_price,
        'currency',         COALESCE(r.currency_code, 'MXN'),
        'group_name',       g.name,
        'group_id',         r.group_id,
        'group_genre',      g.genre,
        'group_phone',      po.phone,
        'client_name',      p.full_name,
        'client_phone',     p.phone,
        'event_started_at', r.event_started_at,
        'hours_stuck',      GREATEST(0, (EXTRACT(EPOCH FROM (NOW() - r.event_started_at)) / 3600)::INT),
        'country',          COALESCE(g.country, 'México')
      ) AS item
    FROM reservations r
    JOIN groups   g  ON g.id  = r.group_id
    LEFT JOIN profiles po ON po.id = g.owner_id
    LEFT JOIN profiles p  ON p.id  = r.client_id
    WHERE r.event_started_at IS NOT NULL
      AND r.event_ended_at   IS NULL
      AND r.status <> 'completed'
      AND r.event_started_at < NOW() - INTERVAL '24 hours'
      AND (v_role = 'admin' OR country_code_of(g.country) = admin_ops_country())
    ORDER BY r.event_started_at ASC
    LIMIT p_limit
  ) x;

  RETURN v_result;
END;
$$;

COMMIT;

-- ── VERIFICACIÓN ────────────────────────────────────────────
SELECT proname FROM pg_proc WHERE proname IN ('admin_get_pending_media', 'admin_get_stuck_service_events');
-- Esperado: 2 filas

SELECT policyname FROM pg_policies WHERE policyname IN ('gep_posts_admin_update', 'gv_admin_update')
  AND (qual ILIKE '%admin_ops_country%');
-- Esperado: 2 filas

SELECT '641_admin_ops_media_and_stuck_events.sql ejecutado ✅' AS status;
