-- ============================================================
-- sql/457_express_respect_toggle.sql
-- BUG: el toggle de disponibilidad exprés del grupo (groups.availability, el
-- switch del dashboard) NO se respeta en prod → un grupo offline/busy sigue
-- recibiendo solicitudes exprés. Prod quedó en la versión 432 (sin ese
-- candado); el sql/432b que lo agregaba nunca se corrió.
--
-- FIX: agrega UNA condición al matching:
--   COALESCE(g.availability, 'available') = 'available'
--     · 'offline' → excluido (lo que promete el switch)
--     · 'busy'    → excluido (un grupo ocupado no debe recibir exprés)
--     · NULL      → sigue recibiendo (grupos que nunca tocaron el switch)
--
-- Se construye sobre la versión vigente (sql/456, ventana 180) → conserva la
-- ventana de 3 h. Todo lo demás byte-idéntico a prod.
-- Guard: aborta si prod no tiene la forma esperada (lección 429).
-- ============================================================

-- ── PRE-CHECK ─────────────────────────────────────────────────────────────────
DO $pre$
BEGIN
  IF (SELECT prosrc FROM pg_proc WHERE proname = 'dispatch_express_request') NOT LIKE '%group_unavailability%'
     OR (SELECT prosrc FROM pg_proc WHERE proname = 'dispatch_express_request') NOT LIKE '%express_window_until%'
  THEN
    RAISE EXCEPTION 'ABORT: dispatch_express_request en prod no tiene la forma esperada — manda su pg_get_functiondef.';
  END IF;
END
$pre$;

BEGIN;

CREATE OR REPLACE FUNCTION public.dispatch_express_request(p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_request         public.event_requests%ROWTYPE;
  v_group_row       RECORD;
  v_dispatched      int := 0;
  v_window_minutes  int := 180;   -- 3 h (sql/456)
  v_max_groups      int := 10;
BEGIN
  SELECT * INTO v_request
  FROM public.event_requests
  WHERE id = p_request_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'request_not_found');
  END IF;

  IF v_request.status <> 'open' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'request_not_open', 'status', v_request.status);
  END IF;

  FOR v_group_row IN
    SELECT g.id AS group_id
    FROM public.groups g
    WHERE
      g.genre = v_request.genre
      AND (
        lower(trim(g.city))  = lower(trim(v_request.location_city))
        OR lower(trim(g.state)) = lower(trim(v_request.location_estado))
      )
      AND g.is_active = true
      AND g.suspended_at IS NULL
      -- [457] Toggle exprés del grupo: offline Y busy excluyen; NULL sigue recibiendo
      AND COALESCE(g.availability, 'available') = 'available'
      AND NOT EXISTS (
        SELECT 1 FROM public.express_dispatches ed
        WHERE ed.request_id = p_request_id
          AND ed.group_id   = g.id
      )
      -- [432] (i) El grupo bloqueó HOY (fecha local CDMX)
      AND NOT EXISTS (
        SELECT 1 FROM public.group_unavailability gu
        WHERE gu.group_id = g.id
          AND gu.date = (NOW() AT TIME ZONE 'America/Mexico_City')::date
      )
      -- [432] (ii) El grupo está tocando en este momento
      AND NOT EXISTS (
        SELECT 1 FROM public.reservations r
        WHERE r.group_id = g.id
          AND r.status = 'in_progress'
      )
    ORDER BY
      (lower(trim(g.city)) = lower(trim(v_request.location_city))) DESC,
      g.is_verified DESC,
      g.rating DESC NULLS LAST
    LIMIT v_max_groups
  LOOP
    INSERT INTO public.express_dispatches (
      request_id, group_id, status, expires_at
    )
    VALUES (
      p_request_id,
      v_group_row.group_id,
      'pending_broadcast',
      NOW() + (v_window_minutes || ' minutes')::interval
    )
    ON CONFLICT DO NOTHING;

    v_dispatched := v_dispatched + 1;
  END LOOP;

  IF v_dispatched > 0 THEN
    UPDATE public.event_requests
    SET express_window_until = NOW() + (v_window_minutes || ' minutes')::interval
    WHERE id = p_request_id;
  END IF;

  RETURN jsonb_build_object(
    'ok',         true,
    'dispatched', v_dispatched,
    'request_id', p_request_id,
    'window_min', v_window_minutes
  );
END;
$function$;

COMMIT;

-- ── VERIFICACIONES ──────────────────────────────────────────────────────────────
-- V1: toggle agregado + ventana 3h + matching intacto
SELECT
  prosrc LIKE '%COALESCE(g.availability%'        AS respeta_toggle,    -- true
  prosrc LIKE '%v_window_minutes  int := 180%'  AS ventana_180,        -- true
  prosrc LIKE '%group_unavailability%'          AS conserva_bloqueo,   -- true
  prosrc LIKE '%express_window_until%'          AS conserva_window     -- true
FROM pg_proc WHERE proname = 'dispatch_express_request';
-- Esperado: true | true | true | true

SELECT '457_express_respect_toggle.sql ejecutado ✅' AS status;
