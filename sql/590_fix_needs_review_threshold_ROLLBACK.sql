-- Rollback de sql/590 — restaura admin_get_event_detail() exactamente
-- como estaba antes del parche (hash confirmado
-- e8e3339a85533c2404b17b9120e219a7, 2026-09-01), con el umbral viejo
-- (cualquier declaración distinta de "no" activa needs_review).

BEGIN;

CREATE OR REPLACE FUNCTION public.admin_get_event_detail(p_event_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_result jsonb; v_sound jsonb;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;

  SELECT jsonb_build_object(
    'needs_review', COALESCE(bool_or(
      COALESCE(q.needs_sound NOT IN ('no','no_group_brings','ya_tengo'), false) OR
      COALESCE(q.needs_lighting NOT IN ('no'), false) OR
      COALESCE(q.needs_stage NOT IN ('no'), false) OR
      COALESCE(q.needs_led NOT IN ('no'), false)
    ), false),
    'max_needs_sound', (array_agg(q.needs_sound ORDER BY
      CASE q.needs_sound WHEN 'si_200' THEN 4 WHEN 'si_100' THEN 3 WHEN 'si_50' THEN 2 WHEN 'si' THEN 1 ELSE 0 END DESC NULLS LAST
    ) FILTER (WHERE q.needs_sound IS NOT NULL))[1],
    'requested_by', COALESCE(jsonb_agg(DISTINCT g.name) FILTER (
      WHERE q.needs_sound NOT IN ('no','no_group_brings','ya_tengo')
         OR q.needs_lighting NOT IN ('no') OR q.needs_stage NOT IN ('no') OR q.needs_led NOT IN ('no')
    ), '[]'::jsonb)
  ) INTO v_sound
  FROM public.quotes q
  JOIN public.groups g ON g.id = q.group_id
  WHERE q.event_id = p_event_id;

  SELECT jsonb_build_object(
    'ok', true,
    'event', jsonb_build_object('id', e.id, 'event_date', e.event_date, 'address', e.address, 'client_id', e.client_id),
    'sound_summary', COALESCE(v_sound, jsonb_build_object('needs_review', false)),
    'providers', (SELECT COALESCE(jsonb_agg(x3.item ORDER BY x3.created_at), '[]'::jsonb) FROM (
        SELECT r.created_at, jsonb_build_object(
          'reservation_id', r.id, 'group_id', r.group_id, 'group_name', g.name, 'genre', g.genre,
          'status', r.status, 'total_price', r.total_price, 'currency', COALESCE(r.currency_code, 'MXN'),
          'has_own_sound', g.has_sound,
          'quote', (SELECT jsonb_build_object(
              'id', q2.id, 'status', q2.status,
              'needs_sound', q2.needs_sound, 'needs_lighting', q2.needs_lighting,
              'needs_stage', q2.needs_stage, 'needs_led', q2.needs_led
            ) FROM public.quotes q2
            WHERE q2.group_id = r.group_id AND q2.event_id = e.id
            ORDER BY q2.created_at DESC LIMIT 1)
        ) AS item
        FROM public.reservations r JOIN public.groups g ON g.id = r.group_id WHERE r.event_id = e.id
        UNION ALL
        SELECT q3.created_at, jsonb_build_object(
          'reservation_id', 'quote-' || q3.id, 'group_id', q3.group_id, 'group_name', g3.name, 'genre', g3.genre,
          'status', q3.status, 'total_price', q3.total_amount,
          'currency', COALESCE((SELECT c.currency_code FROM public.countries c WHERE c.id = g3.country_id), 'MXN'),
          'has_own_sound', g3.has_sound,
          'quote', jsonb_build_object(
            'id', q3.id, 'status', q3.status,
            'needs_sound', q3.needs_sound, 'needs_lighting', q3.needs_lighting,
            'needs_stage', q3.needs_stage, 'needs_led', q3.needs_led
          )
        ) AS item
        FROM public.quotes q3 JOIN public.groups g3 ON g3.id = q3.group_id
        WHERE q3.event_id = e.id AND q3.status IN ('pending', 'quoted')
      ) x3)
  ) INTO v_result FROM public.events e WHERE e.id = p_event_id;

  IF v_result IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'not_found'); END IF;
  RETURN v_result;
END;
$function$;

COMMIT;

SELECT '590_fix_needs_review_threshold_ROLLBACK ✅' AS status;
