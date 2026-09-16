-- ============================================================================
-- ROLLBACK sql/658_concierge_quote_detail_visa_client.sql
-- Regresa admin_get_concierge_quotes a su set reducido de campos, y quita
-- admin_get_cross_border_detail. ⚠️ NO correr salvo emergencia deliberada.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.admin_get_concierge_quotes(p_limit integer DEFAULT 50)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_role TEXT;
  v_result      JSONB;
BEGIN
  SELECT role INTO v_caller_role FROM profiles WHERE id = auth.uid();
  IF v_caller_role NOT IN ('admin', 'admin_ops') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;

  SELECT jsonb_build_object(
    'ok', true,
    'items', COALESCE(jsonb_agg(x.item ORDER BY x.created_at ASC), '[]'::jsonb)
  )
  INTO v_result
  FROM (
    SELECT
      q.created_at,
      jsonb_build_object(
        'quote_id',        q.id,
        'group_id',        g.id,
        'group_name',      g.name,
        'group_phone',     po.phone,
        'group_genre',     g.genre,
        'country',         COALESCE(g.country, 'México'),
        'client_name',     p.full_name,
        'client_phone',    p.phone,
        'event_date',      q.event_date,
        'event_time',      q.event_time,
        'duration_hours',  q.duration_hours,
        'event_address',   q.event_address,
        'event_municipio', q.event_municipio,
        'event_estado',    q.event_estado,
        'comments',        q.comments,
        'created_at',      q.created_at
      ) AS item
    FROM quotes q
    JOIN groups g ON g.id = q.group_id
    LEFT JOIN profiles po ON po.id = g.owner_id
    LEFT JOIN profiles p  ON p.id  = q.client_id
    WHERE q.status = 'pending'
      AND g.concierge_mode = true
      AND (v_caller_role = 'admin' OR country_code_of(g.country) = admin_ops_country())
    ORDER BY q.created_at ASC
    LIMIT p_limit
  ) x;

  RETURN v_result;
END;
$function$;

DROP FUNCTION IF EXISTS public.admin_get_cross_border_detail(uuid, text, integer);
