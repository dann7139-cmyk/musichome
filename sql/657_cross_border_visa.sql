-- ============================================================================
-- sql/657_cross_border_visa.sql
-- "¿El grupo tiene visa de trabajo?" — si un cliente pide una cotización
-- para un evento en OTRO país (comparado contra el país del EVENTO, no el
-- país del cliente — lo que importa para un trámite de visa es a dónde
-- viajaría el grupo a trabajar, no de dónde es quien pide) y el grupo NO
-- tiene visa activada, la cotización se crea igual pero marcada
-- 'blocked_no_visa' — nunca le llega al grupo ni al cliente le sale como
-- enviada, pero queda registrada como prueba de demanda real (memoria:
-- "por si me piden un documento, les doy la prueba").
--
-- Nota de diseño: se decidió NO abortar el INSERT (RAISE EXCEPTION) porque
-- eso también habría descartado el propio registro dentro de la misma
-- transacción — no hay forma limpia en Postgres de "loguear y aún así
-- rechazar" sin una transacción autónoma. Dejar que la fila exista con un
-- status dedicado resuelve ambas cosas con la infraestructura que ya existe
-- (ninguna tabla nueva).
--
-- País del evento: se infiere de quotes.event_estado contra la tabla real
-- states/countries (32 estados MX + 51 US ya cargados).
-- ============================================================================

-- 1) Interruptor en el propio grupo (lo prende el dueño desde su perfil).
ALTER TABLE public.groups
  ADD COLUMN IF NOT EXISTS has_work_visa boolean NOT NULL DEFAULT false;

-- 2) Nuevo status posible en quotes.
ALTER TABLE public.quotes DROP CONSTRAINT IF EXISTS quotes_status_check;
ALTER TABLE public.quotes ADD CONSTRAINT quotes_status_check
  CHECK (status = ANY (ARRAY['pending', 'quoted', 'accepted', 'rejected', 'expired', 'blocked_no_visa']));

-- 3) El candado real, en el INSERT de quotes.
CREATE OR REPLACE FUNCTION public.guard_cross_border_quote()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_group         RECORD;
  v_event_country TEXT;
BEGIN
  SELECT country, has_work_visa INTO v_group
  FROM public.groups WHERE id = NEW.group_id;

  -- Sin país de grupo conocido, o sin estado de evento: no se puede
  -- comparar, se deja pasar tal cual.
  IF v_group.country IS NULL OR NEW.event_estado IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT c.name INTO v_event_country
  FROM public.states s
  JOIN public.countries c ON c.id = s.country_id
  WHERE LOWER(TRIM(s.name)) = LOWER(TRIM(NEW.event_estado))
  LIMIT 1;

  -- Estado no reconocido (typo, u otro país sin catálogo aún): se deja
  -- pasar sin tocar nada — dato demasiado ambiguo para bloquear con él.
  IF v_event_country IS NULL OR v_event_country = v_group.country THEN
    RETURN NEW;
  END IF;

  -- Cross-border confirmado. Sin visa: la fila se crea igual (sirve de
  -- registro de demanda) pero marcada para que nadie la vea como una
  -- cotización real en curso.
  IF NOT v_group.has_work_visa THEN
    NEW.status := 'blocked_no_visa';
  END IF;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_guard_cross_border_quote ON public.quotes;
CREATE TRIGGER trg_guard_cross_border_quote
  BEFORE INSERT ON public.quotes
  FOR EACH ROW EXECUTE FUNCTION public.guard_cross_border_quote();

-- 4) notify_quote_request — nunca debe notificar a nadie una cotización
--    bloqueada (no es real todavía para el grupo ni el cliente).
CREATE OR REPLACE FUNCTION public.notify_quote_request(p_quote_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_quote        RECORD;
  v_group        RECORD;
  v_client_name  TEXT;
  v_country      TEXT;
  v_member_id    UUID;
BEGIN
  SELECT * INTO v_quote FROM public.quotes WHERE id = p_quote_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'quote_not_found'); END IF;
  IF v_quote.client_id <> auth.uid() THEN RETURN jsonb_build_object('ok', false, 'error', 'not_owner'); END IF;

  IF v_quote.status = 'blocked_no_visa' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'blocked_no_visa');
  END IF;

  SELECT g.id, g.owner_id, g.name, g.country, g.concierge_mode, po.phone AS owner_phone
  INTO v_group
  FROM public.groups g
  LEFT JOIN public.profiles po ON po.id = g.owner_id
  WHERE g.id = v_quote.group_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'group_not_found'); END IF;

  SELECT full_name INTO v_client_name FROM public.profiles WHERE id = v_quote.client_id;

  IF NOT v_group.concierge_mode THEN
    IF v_group.owner_id IS NOT NULL THEN
      INSERT INTO public.notifications (user_id, type, title, body, data)
      VALUES (
        v_group.owner_id, 'new_quote_request',
        '📋 Nueva solicitud de cotización',
        format('%s quiere contratarte para un evento de %s horas.', COALESCE(v_client_name,'Un cliente'), COALESCE(v_quote.duration_hours::text, '—')),
        jsonb_build_object('group_id', v_group.id, 'quote_id', p_quote_id)
      );

      FOR v_member_id IN
        SELECT ji.invited_user_id FROM public.job_invitations ji
        WHERE ji.group_id = v_group.id AND ji.invitation_type = 'membership' AND ji.status = 'accepted'
      LOOP
        INSERT INTO public.notifications (user_id, type, title, body, data)
        VALUES (v_member_id, 'new_quote_request', '📋 Nueva solicitud de cotización',
          'Su grupo tiene una nueva solicitud de cotización.',
          jsonb_build_object('group_id', v_group.id, 'quote_id', p_quote_id));
      END LOOP;

      FOR v_member_id IN
        SELECT ji.invited_user_id FROM public.job_invitations ji
        WHERE ji.group_id = v_group.id AND ji.invitation_type = 'event' AND ji.status = 'accepted'
      LOOP
        INSERT INTO public.notifications (user_id, type, title, body, data)
        VALUES (v_member_id, 'new_quote_request', '📋 Nueva solicitud de cotización',
          'Su grupo tiene una nueva solicitud de cotización.',
          jsonb_build_object('group_id', v_group.id, 'quote_id', p_quote_id));
      END LOOP;
    END IF;
  ELSE
    v_country := public.country_code_of(v_group.country);
    INSERT INTO public.notifications (user_id, type, title, body, data)
    SELECT p.id, 'new_quote_request',
      '📞 Cotización para llamar — ' || v_group.name,
      format('%s pidió cotización a %s (aún no maneja su cuenta). Llama al %s para darle el precio.',
        COALESCE(v_client_name, 'Un cliente'), v_group.name, COALESCE(v_group.owner_phone, 'sin teléfono')),
      jsonb_build_object('quote_id', p_quote_id, 'group_id', v_group.id, 'group_phone', v_group.owner_phone, 'screen', 'AdminManagedQuotes')
    FROM public.profiles p
    WHERE (p.role = 'admin' AND NOT public.admin_is_country_muted(v_group.country, p.id))
       OR (p.role = 'admin_ops' AND p.admin_country_scope = v_country);
  END IF;

  RETURN jsonb_build_object('ok', true);
END;
$function$;

-- 5) Reporte cross-border para admin/admin_ops (país acotado, patrón de siempre).
--    Se deriva directo de quotes — sin tabla nueva.
CREATE OR REPLACE FUNCTION public.admin_get_cross_border_report(p_limit integer DEFAULT 200)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_role TEXT;
  v_result      JSONB;
BEGIN
  SELECT role INTO v_caller_role FROM public.profiles WHERE id = auth.uid();
  IF v_caller_role NOT IN ('admin', 'admin_ops') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;

  SELECT jsonb_build_object(
    'ok', true,
    'items', COALESCE(jsonb_agg(x.item ORDER BY x.total_requests DESC), '[]'::jsonb)
  )
  INTO v_result
  FROM (
    SELECT
      count(*) AS total_requests,
      jsonb_build_object(
        'group_id',           g.id,
        'group_name',         g.name,
        'group_country',      g.country,
        'has_work_visa',      g.has_work_visa,
        'event_country',      c.name,
        'total_requests',     count(*),
        'blocked_requests',   count(*) FILTER (WHERE q.status = 'blocked_no_visa'),
        'fulfilled_requests', count(*) FILTER (WHERE q.status <> 'blocked_no_visa'),
        'last_request_at',    max(q.created_at)
      ) AS item
    FROM public.quotes q
    JOIN public.groups g  ON g.id = q.group_id
    JOIN public.states  s ON LOWER(TRIM(s.name)) = LOWER(TRIM(q.event_estado))
    JOIN public.countries c ON c.id = s.country_id
    WHERE g.country IS NOT NULL
      AND c.name <> g.country
      AND (v_caller_role = 'admin' OR public.country_code_of(g.country) = public.admin_ops_country())
    GROUP BY g.id, g.name, g.country, g.has_work_visa, c.name
    ORDER BY count(*) DESC
    LIMIT p_limit
  ) x;

  RETURN v_result;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_get_cross_border_report(integer) TO authenticated;
