-- ============================================================================
-- ROLLBACK sql/657_cross_border_visa.sql
-- Quita el candado de "visa de trabajo" — cualquier grupo vuelve a poder
-- recibir cotizaciones de cualquier país sin restricción. ⚠️ NO correr salvo
-- emergencia deliberada.
-- ============================================================================

DROP TRIGGER IF EXISTS trg_guard_cross_border_quote ON public.quotes;
DROP FUNCTION IF EXISTS public.guard_cross_border_quote();
DROP FUNCTION IF EXISTS public.admin_get_cross_border_report(integer);

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

ALTER TABLE public.quotes DROP CONSTRAINT IF EXISTS quotes_status_check;
ALTER TABLE public.quotes ADD CONSTRAINT quotes_status_check
  CHECK (status = ANY (ARRAY['pending', 'quoted', 'accepted', 'rejected', 'expired']));

-- La columna has_work_visa y las filas 'blocked_no_visa' que ya existan se
-- dejan tal cual (no se borran datos) — este rollback solo apaga el candado.
