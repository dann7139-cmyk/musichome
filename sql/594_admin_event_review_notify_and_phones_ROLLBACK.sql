-- Rollback de sql/594 — quita el trigger/función de notificación al
-- admin y los teléfonos de la lista, restaura
-- admin_get_events_needing_review() exactamente como estaba (hash
-- confirmado 'd10c213d4d3cd8123c944ea93a0babd6', 2026-09-01).

BEGIN;

DROP TRIGGER IF EXISTS trg_notify_admin_event_review ON public.quotes;
DROP FUNCTION IF EXISTS public.notify_admin_event_review();
DROP FUNCTION IF EXISTS public.event_needs_admin_review(UUID, UUID);

CREATE OR REPLACE FUNCTION public.admin_get_events_needing_review()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE v_result jsonb;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;
  SELECT jsonb_build_object('ok', true, 'items', COALESCE(jsonb_agg(x.item ORDER BY x.event_date ASC), '[]'::jsonb))
  INTO v_result
  FROM (
    SELECT e.event_date, jsonb_build_object(
      'event_id', e.id, 'event_date', e.event_date, 'address', e.address, 'client_name', p.full_name,
      'provider_count', (SELECT COUNT(DISTINCT gid) FROM (
          SELECT r.group_id AS gid FROM public.reservations r WHERE r.event_id = e.id AND r.status = ANY (public.estados_que_ocupan())
          UNION
          SELECT q.group_id AS gid FROM public.quotes q WHERE q.event_id = e.id AND q.status IN ('pending','quoted')
        ) x),
      'max_needs_sound', (SELECT (array_agg(q3.needs_sound ORDER BY
          CASE q3.needs_sound WHEN 'si_200' THEN 4 WHEN 'si_100' THEN 3 WHEN 'si_50' THEN 2 WHEN 'si' THEN 1 ELSE 0 END DESC NULLS LAST
        ) FILTER (WHERE q3.needs_sound IS NOT NULL))[1] FROM public.quotes q3 WHERE q3.event_id = e.id),
      'requested_by', (SELECT COALESCE(jsonb_agg(DISTINCT g4.name) FILTER (
          WHERE q4.needs_sound IN ('si_200', 'si') OR q4.needs_lighting = 'premium' OR q4.needs_stage = 'wedding' OR q4.needs_led = 'xl'
        ), '[]'::jsonb) FROM public.quotes q4 JOIN public.groups g4 ON g4.id = q4.group_id WHERE q4.event_id = e.id)
    ) AS item
    FROM public.events e
    LEFT JOIN public.profiles p ON p.id = e.client_id
    WHERE e.event_date >= (NOW() AT TIME ZONE 'America/Mexico_City')::date
      AND (SELECT COUNT(DISTINCT gid) FROM (
            SELECT r.group_id AS gid FROM public.reservations r WHERE r.event_id = e.id AND r.status = ANY (public.estados_que_ocupan())
            UNION
            SELECT q.group_id AS gid FROM public.quotes q WHERE q.event_id = e.id AND q.status IN ('pending','quoted')
          ) x2) >= 2
      AND EXISTS (
        SELECT 1 FROM public.quotes q5 WHERE q5.event_id = e.id AND (
          q5.needs_sound IN ('si_200', 'si') OR
          q5.needs_lighting = 'premium' OR
          q5.needs_stage = 'wedding' OR
          q5.needs_led = 'xl'
        )
      )
      AND EXISTS (SELECT 1 FROM public.quotes q6 WHERE q6.event_id = e.id AND q6.status = 'pending')
  ) x;
  RETURN v_result;
END;
$function$;

COMMIT;

SELECT '594_admin_event_review_notify_and_phones_ROLLBACK ✅' AS status;
