-- ============================================================================
-- sql/658_concierge_quote_detail_visa_client.sql
-- Dos cosas separadas que se juntan en esta migración:
--
-- 1) admin_get_concierge_quotes le faltaban casi todos los datos que el
--    cliente realmente llena (tipo de evento, num. personas, si el lugar es
--    cubierto/tamaño, sonido/luces/tarima/pantalla LED, detalles de
--    categoría, si es regalo sorpresa) — el admin que maneja la cotización
--    en nombre del grupo no podía verlos para negociar bien por teléfono.
--
-- 2) admin_get_cross_border_report (sql/657) solo daba conteos agregados —
--    para un trámite real ante consulado hace falta poder mostrar QUIÉN
--    pidió cada evento específico (nombre/teléfono del cliente, fecha,
--    dirección). Se agrega admin_get_cross_border_detail para eso.
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
        'quote_id',            q.id,
        'group_id',            g.id,
        'group_name',          g.name,
        'group_phone',         po.phone,
        'group_genre',         g.genre,
        'country',             COALESCE(g.country, 'México'),
        'client_name',         p.full_name,
        'client_phone',        p.phone,
        'event_type',          q.event_type,
        'event_date',          q.event_date,
        'event_time',          q.event_time,
        'duration_hours',      q.duration_hours,
        'num_personas',        q.num_personas,
        'event_address',       q.event_address,
        'event_municipio',     q.event_municipio,
        'event_estado',        q.event_estado,
        'venue_covered',       q.venue_covered,
        'venue_size',          q.venue_size,
        'needs_sound',         q.needs_sound,
        'needs_lighting',      q.needs_lighting,
        'needs_stage',         q.needs_stage,
        'needs_led',           q.needs_led,
        'category_details',    q.category_details,
        'is_gift',             q.is_gift,
        'gift_recipient_name', q.gift_recipient_name,
        'comments',            q.comments,
        'created_at',          q.created_at
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

-- Detalle por grupo+país destino: cada solicitud individual con quién la
-- pidió — la prueba documentada real para un trámite de visa.
CREATE OR REPLACE FUNCTION public.admin_get_cross_border_detail(p_group_id uuid, p_event_country text, p_limit integer DEFAULT 100)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_role TEXT;
  v_group       RECORD;
  v_result      JSONB;
BEGIN
  SELECT role INTO v_caller_role FROM public.profiles WHERE id = auth.uid();
  IF v_caller_role NOT IN ('admin', 'admin_ops') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;

  SELECT id, country INTO v_group FROM public.groups WHERE id = p_group_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'group_not_found');
  END IF;

  IF v_caller_role = 'admin_ops' AND public.country_code_of(v_group.country) <> public.admin_ops_country() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;

  SELECT jsonb_build_object(
    'ok', true,
    'items', COALESCE(jsonb_agg(x.item ORDER BY x.created_at DESC), '[]'::jsonb)
  )
  INTO v_result
  FROM (
    SELECT
      q.created_at,
      jsonb_build_object(
        'quote_id',        q.id,
        'was_blocked',     q.status = 'blocked_no_visa',
        'client_name',     p.full_name,
        'client_phone',    p.phone,
        'event_date',      q.event_date,
        'event_time',      q.event_time,
        'event_address',   q.event_address,
        'event_municipio', q.event_municipio,
        'event_estado',    q.event_estado,
        'created_at',      q.created_at
      ) AS item
    FROM public.quotes q
    LEFT JOIN public.profiles p ON p.id = q.client_id
    JOIN public.states  s ON LOWER(TRIM(s.name)) = LOWER(TRIM(q.event_estado))
    JOIN public.countries c ON c.id = s.country_id
    WHERE q.group_id = p_group_id
      AND c.name = p_event_country
    ORDER BY q.created_at DESC
    LIMIT p_limit
  ) x;

  RETURN v_result;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_get_cross_border_detail(uuid, text, integer) TO authenticated;
