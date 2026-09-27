-- ═══════════════════════════════════════════════════════════════════════════
-- ROLLBACK de 705 — recrea la firma de 3 argumentos de `open_dispute`
-- ═══════════════════════════════════════════════════════════════════════════
-- ⚠️  Correrlo REINTRODUCE la ambigüedad 42725 y el cliente volvería a no poder
-- abrir disputas. Solo tiene sentido si se descubre un consumidor real de la
-- variante que escribe en `event_disputes`.
--
-- Cuerpo restaurado byte por byte como estaba en producción (oid 51572), con su
-- ACL original: EXECUTE para PUBLIC + anon + authenticated + service_role.
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

CREATE OR REPLACE FUNCTION public.open_dispute(
  p_reservation_id UUID,
  p_reason         TEXT,
  p_evidence_urls  TEXT[] DEFAULT '{}'::text[]
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_res        RECORD;
  v_caller_role TEXT;
  v_dispute_id  UUID;
  v_admin_id    UUID;
BEGIN
  SELECT r.*, g.owner_id AS g_owner_id
  INTO   v_res
  FROM   public.reservations r
  JOIN   public.groups g ON g.id = r.group_id
  WHERE  r.id = p_reservation_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'reservation_not_found');
  END IF;

  -- Determinar rol del caller
  IF auth.uid() = v_res.client_id THEN
    v_caller_role := 'client';
  ELSIF auth.uid() = v_res.g_owner_id THEN
    v_caller_role := 'group';
  ELSE
    RETURN jsonb_build_object('ok', false, 'error', 'unauthorized');
  END IF;

  -- Solo se puede disputar reservas en estados relevantes
  IF v_res.status NOT IN ('confirmed', 'completed', 'in_progress') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'dispute_not_allowed_for_status',
      'status', v_res.status);
  END IF;

  -- Verificar que no haya disputa abierta para la misma reserva
  IF EXISTS (
    SELECT 1 FROM public.event_disputes
    WHERE reservation_id = p_reservation_id
      AND status IN ('open', 'under_review')
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'dispute_already_open');
  END IF;

  -- Crear la disputa
  INSERT INTO public.event_disputes
    (reservation_id, opened_by, opened_by_role, reason, evidence_urls)
  VALUES
    (p_reservation_id, auth.uid(), v_caller_role, p_reason,
     COALESCE(p_evidence_urls, '{}'))
  RETURNING id INTO v_dispute_id;

  -- Notificar al admin
  v_admin_id := public.get_platform_admin_id();
  IF v_admin_id IS NOT NULL THEN
    PERFORM public.queue_push_notification(
      v_admin_id,
      'dispute_opened',
      '⚠️ Nueva disputa abierta',
      'Un ' || v_caller_role || ' abrió una disputa para la reserva del ' ||
        TO_CHAR(v_res.event_date::DATE, 'DD/MM/YYYY') || '.',
      jsonb_build_object(
        'dispute_id',     v_dispute_id,
        'reservation_id', p_reservation_id
      )
    );
  END IF;

  -- Notificar a la otra parte
  PERFORM public.queue_push_notification(
    CASE v_caller_role WHEN 'client' THEN v_res.g_owner_id ELSE v_res.client_id END,
    'dispute_received',
    'Se abrió una disputa en tu reserva',
    'Se ha abierto una disputa relacionada con el evento del ' ||
      TO_CHAR(v_res.event_date::DATE, 'DD/MM/YYYY') || '. El equipo la revisará.',
    jsonb_build_object(
      'dispute_id',     v_dispute_id,
      'reservation_id', p_reservation_id
    )
  );

  RETURN jsonb_build_object(
    'ok',         true,
    'dispute_id', v_dispute_id
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.open_dispute(UUID, TEXT, TEXT[])
  TO PUBLIC, anon, authenticated, service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
