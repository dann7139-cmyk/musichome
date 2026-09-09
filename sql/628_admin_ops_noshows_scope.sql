-- sql/628_admin_ops_noshows_scope.sql
--
-- Fase 1 (cola 1/3: No-shows) del admin con alcance por país (sql/627).
-- Cada una de las 9 funciones de esta cola ahora también acepta llamadas
-- de role='admin_ops', pero:
--   - Las 4 de CONSULTA (get_no_shows, get_no_shows_history,
--     get_stuck_events, get_unverified_payouts) filtran las filas a solo
--     el país de alcance de quien llama (country_code_of(g.country) =
--     admin_ops_country()) — un admin_ops nunca ve filas de otro país.
--   - Las 5 de ACCIÓN (resolve_no_show, mark_no_show, force_start_event,
--     verify_arrival_and_release, block_unverified_payout) re-verifican
--     el país de LA RESERVA ESPECÍFICA contra el alcance de quien llama
--     antes de tocar nada — así un admin_ops no puede actuar sobre una
--     reserva de otro país aunque conozca su id y llame al RPC directo.
-- Para role='admin' (cuenta completa) el comportamiento es IDÉNTICO al
-- de antes — cero filtro, cero cambio de resultado.
BEGIN;

-- ── 1/9: admin_get_no_shows ────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_get_no_shows(p_limit integer DEFAULT 50)
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
    RETURN jsonb_build_object('ok', false, 'error', 'Acceso restringido a administradores');
  END IF;

  SELECT jsonb_build_object(
    'ok',    true,
    'items', COALESCE(
      jsonb_agg(
        jsonb_build_object(
          'id',            r.id,
          'folio',         r.folio,
          'event_date',    r.event_date,
          'event_time',    r.event_time,
          'total_price',   r.total_price,
          'payout_status', r.payout_status,
          'cancelled_at',  r.cancelled_at,
          'group_name',    g.name,
          'group_id',      r.group_id,
          'group_phone',   po.phone,
          'client_name',   p.full_name,
          'client_phone',  p.phone,
          'country_code',  country_code_of(g.country),          -- [470]
          'country',       COALESCE(g.country, 'México'),        -- [470]
          'state',         g.state,                              -- [470]
          'city',          g.city,                               -- [470]
          'currency',      COALESCE(r.currency_code, 'MXN'),     -- [470]
          'has_strike',    EXISTS (
            SELECT 1 FROM group_strikes gs
            WHERE gs.group_id      = r.group_id
              AND gs.strike_type   = 'no_show'
              AND gs.reservation_id = r.id
          ),
          'event_lat',            COALESCE(r.event_lat, q.latitude, er.latitude, er.event_lat),
          'event_lng',            COALESCE(r.event_lng, q.longitude, er.longitude, er.event_lng),
          'group_en_route_at',    r.group_en_route_at,
          'transit_lat',          r.transit_lat,
          'transit_lng',          r.transit_lng,
          'transit_updated_at',   r.transit_updated_at,
          'event_started_at',     r.event_started_at,
          'group_arrived_at',     r.group_arrived_at,
          'arrival_gps_verified', r.arrival_gps_verified
        )
        ORDER BY r.cancelled_at DESC
      ),
      '[]'::jsonb
    )
  )
  INTO v_result
  FROM reservations r
  LEFT JOIN groups         g  ON g.id  = r.group_id
  LEFT JOIN profiles       po ON po.id = g.owner_id
  LEFT JOIN profiles       p  ON p.id  = r.client_id
  LEFT JOIN quotes         q  ON q.id  = r.quote_id
  LEFT JOIN event_requests er ON er.id = r.event_request_id
  WHERE r.cancellation_type          = 'system_auto'
    AND r.cancel_reason              = 'no_show_grupo'
    AND r.admin_no_show_resolution   IS NULL
    AND (v_caller_role = 'admin' OR country_code_of(g.country) = admin_ops_country())  -- [628]
  LIMIT p_limit;

  RETURN v_result;
END;
$function$;

-- ── 2/9: admin_get_no_shows_history ────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_get_no_shows_history(p_limit integer DEFAULT 50)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_role TEXT;
  v_result JSONB;
BEGIN
  SELECT role INTO v_caller_role FROM profiles WHERE id = auth.uid();
  IF v_caller_role NOT IN ('admin', 'admin_ops') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Acceso restringido a administradores');
  END IF;

  SELECT jsonb_build_object(
    'ok',    true,
    'items', COALESCE(
      jsonb_agg(
        jsonb_build_object(
          'id',                        r.id,
          'folio',                     r.folio,
          'event_date',                r.event_date,
          'total_price',               r.total_price,
          'group_name',                g.name,
          'group_id',                  r.group_id,
          'client_name',               p.full_name,
          'country_code',              country_code_of(g.country),      -- [470]
          'country',                   COALESCE(g.country, 'México'),    -- [470]
          'state',                     g.state,                          -- [470]
          'city',                      g.city,                           -- [470]
          'currency',                  COALESCE(r.currency_code, 'MXN'), -- [470]
          'admin_no_show_resolution',  r.admin_no_show_resolution,
          'admin_no_show_resolved_at', r.admin_no_show_resolved_at,
          'admin_no_show_notes',       r.admin_no_show_notes,
          'resolver_name',             resolver.full_name,
          'has_strike',                EXISTS (
            SELECT 1 FROM group_strikes gs
            WHERE gs.group_id       = r.group_id
              AND gs.strike_type    = 'no_show'
              AND gs.reservation_id = r.id
          )
        )
        ORDER BY r.admin_no_show_resolved_at DESC
      ),
      '[]'::jsonb
    )
  )
  INTO v_result
  FROM reservations r
  LEFT JOIN groups   g        ON g.id = r.group_id
  LEFT JOIN profiles p        ON p.id = r.client_id
  LEFT JOIN profiles resolver ON resolver.id = r.admin_no_show_resolved_by
  WHERE r.cancellation_type        = 'system_auto'
    AND r.cancel_reason            = 'no_show_grupo'
    AND r.admin_no_show_resolution IS NOT NULL
    AND (v_caller_role = 'admin' OR country_code_of(g.country) = admin_ops_country())  -- [628]
  LIMIT p_limit;

  RETURN v_result;
END;
$function$;

-- ── 3/9: admin_get_stuck_events ────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_get_stuck_events(p_limit integer DEFAULT 50)
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
    RETURN jsonb_build_object('ok', false, 'error', 'Acceso restringido a administradores');
  END IF;

  SELECT jsonb_build_object(
    'ok',    true,
    'items', COALESCE(jsonb_agg(x.item ORDER BY x.event_ts DESC), '[]'::jsonb)
  )
  INTO v_result
  FROM (
    SELECT
      (
        (r.event_date + COALESCE(r.event_time, '23:59:00'::TIME))
          AT TIME ZONE 'America/Mexico_City'
      ) AS event_ts,
      jsonb_build_object(
        'id',             r.id,
        'folio',          r.folio,
        'event_date',     r.event_date,
        'event_time',     r.event_time,
        'total_price',    r.total_price,
        'payout_status',  r.payout_status,
        'payment_status', r.payment_status,
        'group_name',     g.name,
        'group_id',       r.group_id,
        'group_phone',    po.phone,
        'client_name',    p.full_name,
        'client_phone',   p.phone,
        'country_code',   country_code_of(g.country),           -- [628]
        'country',        COALESCE(g.country, 'México'),         -- [628]
        'state',          g.state,                               -- [628]
        'city',           g.city,                                -- [628]
        'currency',       COALESCE(r.currency_code, 'MXN'),      -- [628]
        'minutes_late',   GREATEST(0, (EXTRACT(EPOCH FROM (
                            NOW() - ((r.event_date + COALESCE(r.event_time, '23:59:00'::TIME))
                                     AT TIME ZONE 'America/Mexico_City')
                          )) / 60)::INT)
      ) AS item
    FROM reservations r
    LEFT JOIN groups   g  ON g.id  = r.group_id
    LEFT JOIN profiles po ON po.id = g.owner_id
    LEFT JOIN profiles p  ON p.id  = r.client_id
    WHERE r.status           = 'confirmed'
      AND r.event_started_at IS NULL
      AND r.group_arrived_at IS NULL
      AND r.payment_status   IN ('paid', 'deposit_paid', 'fully_paid')
      AND ((r.event_date + COALESCE(r.event_time, '23:59:00'::TIME))
             AT TIME ZONE 'America/Mexico_City') < NOW() - INTERVAL '10 minutes'
      AND ((r.event_date + COALESCE(r.event_time, '23:59:00'::TIME))
             AT TIME ZONE 'America/Mexico_City') > NOW() - INTERVAL '48 hours'
      AND (v_caller_role = 'admin' OR country_code_of(g.country) = admin_ops_country())  -- [628]
    ORDER BY event_ts DESC
    LIMIT p_limit
  ) x;

  RETURN v_result;
END;
$function$;

-- ── 4/9: admin_get_unverified_payouts ──────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_get_unverified_payouts(p_limit integer DEFAULT 50)
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
    RETURN jsonb_build_object('ok', false, 'error', 'Acceso restringido a administradores');
  END IF;

  SELECT jsonb_build_object(
    'ok', true,
    'items', COALESCE(jsonb_agg(x.item ORDER BY x.event_date DESC NULLS LAST), '[]'::jsonb)
  )
  INTO v_result
  FROM (
    SELECT
      r.event_date,
      jsonb_build_object(
        'id',             r.id,
        'folio',          r.folio,
        'event_date',     r.event_date,
        'event_time',     r.event_time,
        'status',         r.status,
        'total_price',    r.total_price,
        'group_earnings', r.group_earnings,
        'payout_status',  r.payout_status,
        'group_name',     g.name,
        'group_id',       r.group_id,
        'group_phone',    po.phone,
        'client_name',    p.full_name,
        'client_phone',   p.phone,
        'country_code',   country_code_of(g.country),          -- [628]
        'country',        COALESCE(g.country, 'México'),        -- [628]
        'state',          g.state,                              -- [628]
        'city',           g.city,                               -- [628]
        'currency',       COALESCE(r.currency_code, 'MXN')      -- [628]
      ) AS item
    FROM reservations r
    LEFT JOIN groups   g  ON g.id  = r.group_id
    LEFT JOIN profiles po ON po.id = g.owner_id
    LEFT JOIN profiles p  ON p.id  = r.client_id
    WHERE r.payout_status     = 'held'
      AND r.group_arrived_at  IS NULL
      AND COALESCE(r.arrival_verified, false) = false
      AND r.payment_status    IN ('paid','fully_paid','deposit_paid')
      AND NOT (r.status = 'confirmed' AND r.event_started_at IS NULL)
      AND NOT EXISTS (SELECT 1 FROM disputes d
                      WHERE d.reservation_id = r.id AND d.status IN ('open','under_review'))
      AND (v_caller_role = 'admin' OR country_code_of(g.country) = admin_ops_country())  -- [628]
    ORDER BY r.event_date DESC NULLS LAST
    LIMIT p_limit
  ) x;

  RETURN v_result;
END;
$function$;

-- ── 5/9: admin_mark_no_show (acción) ───────────────────────────────────
-- HALLAZGO REAL (no relacionado a admin_ops, encontrado al probar en
-- sandbox): esta función SIEMPRE fallaba — asignaba el UUID del admin a
-- `cancelled_by`, pero esa columna es TEXT con
-- CHECK (cancelled_by = ANY('group','client','admin','system')). Nunca
-- pudo haberse ejecutado con éxito en producción. Corregido a 'admin'
-- (mismo patrón que sql/341 usa 'system' para el cron).
CREATE OR REPLACE FUNCTION public.admin_mark_no_show(p_reservation_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_admin_id    UUID := auth.uid();
  v_caller_role TEXT;
  v_res         RECORD;
BEGIN
  SELECT role INTO v_caller_role FROM profiles WHERE id = v_admin_id;
  IF v_caller_role NOT IN ('admin', 'admin_ops') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Acceso restringido a administradores');
  END IF;

  SELECT * INTO v_res FROM reservations WHERE id = p_reservation_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Reserva no encontrada');
  END IF;

  -- [628] admin_ops: la reserva debe ser de su país de alcance
  IF v_caller_role = 'admin_ops' AND NOT EXISTS (
    SELECT 1 FROM groups g WHERE g.id = v_res.group_id
      AND country_code_of(g.country) = admin_ops_country()
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Acceso restringido a administradores');
  END IF;

  IF v_res.status <> 'confirmed' OR v_res.event_started_at IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_stuck', 'status', v_res.status);
  END IF;

  IF v_res.payout_status IN ('released', 'refunded') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'payout_no_reversible', 'payout_status', v_res.payout_status);
  END IF;

  UPDATE reservations SET
    status            = 'cancelled',
    cancelled_at      = NOW(),
    cancelled_by      = 'admin',           -- [628] antes: v_admin_id (UUID) — violaba el CHECK, ver nota arriba
    cancel_reason     = 'no_show_grupo',
    cancellation_type = 'system_auto',
    payout_status     = 'blocked',
    updated_at        = NOW()
  WHERE id = p_reservation_id;

  RETURN jsonb_build_object('ok', true, 'status', 'cancelled', 'folio', v_res.folio);
END;
$function$;

-- ── 6/9: admin_resolve_no_show (acción) ────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_resolve_no_show(p_reservation_id uuid, p_resolution text, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_id   UUID    := auth.uid();
  v_caller_role TEXT;
  v_group_id    UUID;
  v_client_id   UUID;
  v_folio       TEXT;
  v_total_price NUMERIC;
BEGIN
  SELECT role INTO v_caller_role FROM profiles WHERE id = v_caller_id;
  IF v_caller_role NOT IN ('admin', 'admin_ops') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Acceso restringido a administradores');
  END IF;

  IF p_resolution NOT IN ('refunded_100', 'no_refund', 'reviewed') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Resolución inválida');
  END IF;

  SELECT client_id, folio, total_price, group_id
  INTO   v_client_id, v_folio, v_total_price, v_group_id
  FROM   reservations
  WHERE  id = p_reservation_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Reserva no encontrada');
  END IF;

  -- [628] admin_ops: la reserva debe ser de su país de alcance
  IF v_caller_role = 'admin_ops' AND NOT EXISTS (
    SELECT 1 FROM groups g WHERE g.id = v_group_id
      AND country_code_of(g.country) = admin_ops_country()
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Acceso restringido a administradores');
  END IF;

  UPDATE reservations
  SET admin_no_show_resolution  = p_resolution,
      admin_no_show_resolved_at = NOW(),
      admin_no_show_resolved_by = v_caller_id,
      admin_no_show_notes       = p_notes
  WHERE id = p_reservation_id;

  INSERT INTO financial_audit_logs (
    entity_type, entity_id, action,
    actor_id, actor_role,
    amount, notes
  ) VALUES (
    'reservation', p_reservation_id, 'no_show_resolved',
    v_caller_id, v_caller_role,
    v_total_price,
    format('resolution=%s%s',
      p_resolution,
      CASE WHEN p_notes IS NOT NULL THEN '. ' || p_notes ELSE '' END
    )
  );

  IF v_client_id IS NOT NULL AND p_resolution <> 'reviewed' THEN
    INSERT INTO notifications (user_id, type, title, body, data)
    VALUES (
      v_client_id,
      'reservation',
      CASE p_resolution
        WHEN 'refunded_100' THEN '💚 Tu dinero fue reembolsado'
        WHEN 'no_refund'    THEN '⚠️ Evento cancelado sin reembolso'
      END,
      CASE p_resolution
        WHEN 'refunded_100' THEN format(
          'El grupo no se presentó a tu evento%s. Hemos procesado el reembolso total. Disculpa los inconvenientes.',
          CASE WHEN v_folio IS NOT NULL THEN ' (' || v_folio || ')' ELSE '' END
        )
        WHEN 'no_refund' THEN format(
          'El grupo no se presentó a tu evento%s. Por política de la plataforma no aplica reembolso en este caso. Comunícate con soporte para más información.',
          CASE WHEN v_folio IS NOT NULL THEN ' (' || v_folio || ')' ELSE '' END
        )
      END,
      jsonb_build_object('reservation_id', p_reservation_id)
    );
  END IF;

  RETURN jsonb_build_object('ok', true, 'resolution', p_resolution);
END;
$function$;

-- ── 7/9: admin_force_start_event (acción) ──────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_force_start_event(p_reservation_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_admin_id   UUID := auth.uid();
  v_caller_role TEXT;
  v_res        RECORD;
  v_hours      NUMERIC;
  v_break      TEXT;
  v_break_min  INT;
  v_music_min  INT;
  v_group_name TEXT;
BEGIN
  SELECT role INTO v_caller_role FROM profiles WHERE id = v_admin_id;
  IF v_caller_role NOT IN ('admin', 'admin_ops') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;

  SELECT * INTO v_res FROM reservations WHERE id = p_reservation_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'not_found'); END IF;

  -- [628] admin_ops: la reserva debe ser de su país de alcance
  IF v_caller_role = 'admin_ops' AND NOT EXISTS (
    SELECT 1 FROM groups g WHERE g.id = v_res.group_id
      AND country_code_of(g.country) = admin_ops_country()
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;

  IF v_res.event_started_at IS NOT NULL OR v_res.status = 'completed' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'already_started',
      'status', v_res.status);
  END IF;
  IF v_res.status NOT IN ('confirmed', 'accepted') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_startable', 'status', v_res.status);
  END IF;

  v_hours := GREATEST(COALESCE(v_res.hours_count,
                        (SELECT duration_hours FROM quotes WHERE id = v_res.quote_id), 3), 1);
  v_break := COALESCE(v_res.break_type, 'B');
  v_break_min := CASE v_break
    WHEN 'A' THEN 15 * GREATEST(v_hours::INT - 1, 0)
    WHEN 'D' THEN 0
    ELSE 15
  END;
  v_music_min := (v_hours * 60)::INT - v_break_min;

  UPDATE reservations SET
    status           = 'in_progress',
    event_started_at = NOW(),
    break_type       = v_break,
    music_minutes    = v_music_min,
    arrival_verified = true,
    updated_at       = NOW()
  WHERE id = p_reservation_id;

  INSERT INTO financial_audit_logs
    (entity_type, entity_id, action, actor_id, actor_role, amount, notes)
  VALUES ('reservation', p_reservation_id, 'force_start', v_admin_id, v_caller_role, 0,
    format('Inicio forzado por admin (presencia verificada -> arrival_verified=true). break=%s music_min=%s',
           v_break, v_music_min));

  SELECT name INTO v_group_name FROM groups WHERE id = v_res.group_id;

  INSERT INTO notifications (user_id, type, title, body, data)
  SELECT g.owner_id, 'event_auto_started',
    '⏰ Un administrador inició tu evento',
    'El evento se marcó como iniciado. Abre la app para ver el timer.',
    jsonb_build_object('reservation_id', p_reservation_id, 'screen', 'EventTimer', 'forced', true)
  FROM groups g WHERE g.id = v_res.group_id;

  IF v_res.client_id IS NOT NULL THEN
    INSERT INTO notifications (user_id, type, title, body, data)
    VALUES (v_res.client_id, 'event_auto_started',
      '🎵 ¡Tu evento ha iniciado!',
      COALESCE(v_group_name, 'El grupo') || ' está por comenzar. ¡Disfrútalo!',
      jsonb_build_object('reservation_id', p_reservation_id, 'screen', 'LiveEvent'));
  END IF;

  RETURN jsonb_build_object('ok', true, 'status', 'in_progress',
    'break_type', v_break, 'music_minutes', v_music_min, 'arrival_verified', true);
END;
$function$;

-- ── 8/9: admin_verify_arrival_and_release (acción) ─────────────────────
CREATE OR REPLACE FUNCTION public.admin_verify_arrival_and_release(p_reservation_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_admin_id    UUID := auth.uid();
  v_caller_role TEXT;
  v_group_id    UUID;
  v_release     JSONB;
BEGIN
  SELECT role INTO v_caller_role FROM profiles WHERE id = v_admin_id;
  IF v_caller_role NOT IN ('admin', 'admin_ops') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;

  SELECT group_id INTO v_group_id FROM reservations WHERE id = p_reservation_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_found');
  END IF;

  -- [628] admin_ops: la reserva debe ser de su país de alcance
  IF v_caller_role = 'admin_ops' AND NOT EXISTS (
    SELECT 1 FROM groups g WHERE g.id = v_group_id
      AND country_code_of(g.country) = admin_ops_country()
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;

  UPDATE reservations SET arrival_verified = true, updated_at = NOW()
  WHERE id = p_reservation_id;

  INSERT INTO financial_audit_logs
    (entity_type, entity_id, action, actor_id, actor_role, amount, notes)
  VALUES ('reservation', p_reservation_id, 'arrival_verified_by_admin', v_admin_id, v_caller_role, 0,
    'Admin confirmó presencia del grupo tras revisión — libera pago retenido');

  v_release := release_group_earnings_atomic(p_reservation_id, v_admin_id);

  RETURN jsonb_build_object('ok', true, 'release', v_release);
END;
$function$;

-- ── 9/9: admin_block_unverified_payout (acción) ────────────────────────
CREATE OR REPLACE FUNCTION public.admin_block_unverified_payout(p_reservation_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_admin_id    UUID := auth.uid();
  v_caller_role TEXT;
  v_res         RECORD;
BEGIN
  SELECT role INTO v_caller_role FROM profiles WHERE id = v_admin_id;
  IF v_caller_role NOT IN ('admin', 'admin_ops') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;

  SELECT payout_status, group_id INTO v_res FROM reservations WHERE id = p_reservation_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'not_found'); END IF;

  -- [628] admin_ops: la reserva debe ser de su país de alcance
  IF v_caller_role = 'admin_ops' AND NOT EXISTS (
    SELECT 1 FROM groups g WHERE g.id = v_res.group_id
      AND country_code_of(g.country) = admin_ops_country()
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;

  IF v_res.payout_status = 'released' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'ya_liberado');
  END IF;

  UPDATE reservations SET payout_status = 'blocked', updated_at = NOW()
  WHERE id = p_reservation_id;

  INSERT INTO financial_audit_logs
    (entity_type, entity_id, action, actor_id, actor_role, amount, notes)
  VALUES ('reservation', p_reservation_id, 'payout_blocked_no_arrival', v_admin_id, v_caller_role, 0,
    'Admin bloqueó el pago: el grupo no probó presencia (sin llegada verificada)');

  RETURN jsonb_build_object('ok', true, 'payout_status', 'blocked');
END;
$function$;

COMMIT;
