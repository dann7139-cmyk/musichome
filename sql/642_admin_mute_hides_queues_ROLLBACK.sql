-- sql/642_admin_mute_hides_queues_ROLLBACK.sql
--
-- Revierte sql/642: quita el helper admin_is_country_muted() y restaura
-- las 12 funciones a su versión inmediatamente anterior (sql/628, 629,
-- 630, 641, 617 según cada una). Después de este rollback, el "mute" de
-- un país vuelve a afectar SOLO las 3 notificaciones puntuales de
-- sql/631 — las colas del Dashboard/AdminOpsHome vuelven a mostrar TODOS
-- los países sin excepción, igual que antes de sql/642.
--
-- EXCEPCIÓN DELIBERADA: admin_withdrawals_queue y admin_manual_refund_queue
-- NO se revierten a su forma literal de sql/629 — esa forma tenía
-- `WHERE id = auth.uid()`, que sql/642 corrigió a `WHERE profiles.id =
-- auth.uid()` porque `id` es ambiguo contra la columna de salida de la
-- función (RETURNS TABLE(id uuid, ...)) y SIEMPRE lanzaba
-- "column reference id is ambiguous" en producción — un bug real,
-- confirmado en vivo, no relacionado con el mute. Revertir ese arreglo
-- solo para deshacer el mute rompería de nuevo estas 2 colas. Por eso
-- aquí se restauran SOLO quitando el filtro de mute, conservando el
-- `profiles.id`.
--
-- ÚSESE SOLO EN CASO DE EMERGENCIA DELIBERADA. NO EJECUTAR salvo que se
-- decida explícitamente deshacer este cambio.
BEGIN;

CREATE OR REPLACE FUNCTION public.admin_get_no_shows(p_limit integer DEFAULT 50)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
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
          'country_code',  country_code_of(g.country),
          'country',       COALESCE(g.country, 'México'),
          'state',         g.state,
          'city',          g.city,
          'currency',      COALESCE(r.currency_code, 'MXN'),
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
    AND (v_caller_role = 'admin' OR country_code_of(g.country) = admin_ops_country())
  LIMIT p_limit;

  RETURN v_result;
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_get_no_shows_history(p_limit integer DEFAULT 50)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
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
          'country_code',              country_code_of(g.country),
          'country',                   COALESCE(g.country, 'México'),
          'state',                     g.state,
          'city',                      g.city,
          'currency',                  COALESCE(r.currency_code, 'MXN'),
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
    AND (v_caller_role = 'admin' OR country_code_of(g.country) = admin_ops_country())
  LIMIT p_limit;

  RETURN v_result;
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_get_unverified_payouts(p_limit integer DEFAULT 50)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
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
        'country_code',   country_code_of(g.country),
        'country',        COALESCE(g.country, 'México'),
        'state',          g.state,
        'city',           g.city,
        'currency',       COALESCE(r.currency_code, 'MXN')
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
      AND (v_caller_role = 'admin' OR country_code_of(g.country) = admin_ops_country())
    ORDER BY r.event_date DESC NULLS LAST
    LIMIT p_limit
  ) x;

  RETURN v_result;
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_get_pending_media(p_limit integer DEFAULT 50)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
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
$function$;

CREATE OR REPLACE FUNCTION public.admin_get_stuck_service_events(p_limit integer DEFAULT 50)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
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
$function$;

CREATE OR REPLACE FUNCTION public.admin_get_pending_group_payments(p_limit integer DEFAULT 50)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE
  v_caller_role TEXT;
  v_result jsonb;
BEGIN
  SELECT role INTO v_caller_role FROM profiles WHERE id = auth.uid();
  IF v_caller_role NOT IN ('admin', 'admin_ops') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
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
        'reservation_id',   r.id,
        'folio',            r.folio,
        'event_date',       r.event_date,
        'event_time',       r.event_time,
        'group_id',         r.group_id,
        'group_name',       g.name,
        'owner_id',         g.owner_id,
        'client_name',      p.full_name,
        'currency_code',    r.currency_code,
        'group_earnings',   r.group_earnings,
        'total_anticipado', COALESCE(gp.total_anticipado, 0),
        'saldo_pendiente',  r.group_earnings - COALESCE(gp.total_anticipado, 0),
        'bank_clabe',       w.bank_clabe,
        'bank_name',        w.bank_name,
        'account_holder',   w.account_holder,
        'bank_linked_at',   w.bank_linked_at,
        'payment_requested', (pr.id IS NOT NULL),
        'refund_claim_status', rc.status,
        'country_code',     country_code_of(g.country),
        'country',          COALESCE(g.country, 'México')
      ) AS item
    FROM reservations r
    JOIN      groups   g ON g.id = r.group_id
    LEFT JOIN profiles p ON p.id = r.client_id
    LEFT JOIN wallets   w ON w.user_id = g.owner_id
    LEFT JOIN LATERAL (
      SELECT SUM(amount) AS total_anticipado
      FROM group_reservation_payments
      WHERE reservation_id = r.id
    ) gp ON true
    LEFT JOIN group_payment_requests pr ON pr.reservation_id = r.id AND pr.status = 'pending'
    LEFT JOIN LATERAL (
      SELECT status FROM provider_refund_claims
      WHERE reservation_id = r.id AND status IN ('processing','provider_succeeded')
      ORDER BY created_at DESC LIMIT 1
    ) rc ON true
    WHERE r.payout_status  = 'released'
      AND r.status         = 'completed'
      AND r.payment_status IN ('paid','fully_paid','deposit_paid')
      AND COALESCE(r.group_earnings, 0) > 0
      AND (r.group_earnings - COALESCE(gp.total_anticipado, 0)) > 0
      AND NOT EXISTS (
        SELECT 1 FROM disputes d WHERE d.reservation_id = r.id AND d.status IN ('open','under_review')
      )
      AND (v_caller_role = 'admin' OR country_code_of(g.country) = admin_ops_country())
    ORDER BY r.event_date DESC NULLS LAST
    LIMIT p_limit
  ) x;

  RETURN v_result;
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_get_pending_gift_payouts()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE
  v_caller_role TEXT;
  v_result jsonb;
BEGIN
  SELECT role INTO v_caller_role FROM profiles WHERE id = auth.uid();
  IF v_caller_role NOT IN ('admin', 'admin_ops') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;

  SELECT jsonb_build_object('ok', true, 'items', COALESCE(jsonb_agg(x.item ORDER BY x.requested_at DESC), '[]'::jsonb))
  INTO v_result
  FROM (
    SELECT
      r.requested_at,
      jsonb_build_object(
        'request_id',      r.id,
        'group_id',        r.group_id,
        'group_name',      g.name,
        'amount',          r.amount,
        'currency',        r.currency_code,
        'requested_at',    r.requested_at,
        'bank_clabe',      w.bank_clabe,
        'bank_name',       w.bank_name,
        'account_holder',  w.account_holder,
        'country_code',    country_code_of(g.country),
        'country',         COALESCE(g.country, 'México')
      ) AS item
    FROM public.group_gift_payout_requests r
    JOIN groups g ON g.id = r.group_id
    LEFT JOIN wallets w ON w.user_id = g.owner_id
    WHERE r.status = 'pending'
      AND (v_caller_role = 'admin' OR country_code_of(g.country) = admin_ops_country())
    ORDER BY r.requested_at DESC
  ) x;

  RETURN v_result;
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_get_pending_group_verifications(p_limit integer DEFAULT 50)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
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
    'items', COALESCE(jsonb_agg(x.item ORDER BY x.submitted_at ASC), '[]'::jsonb)
  )
  INTO v_result
  FROM (
    SELECT
      vr.submitted_at,
      jsonb_build_object(
        'id',                vr.id,
        'group_id',          vr.group_id,
        'group_name',        g.name,
        'document_url',      vr.document_url,
        'selfie_url',        vr.selfie_url,
        'liveness_verified', vr.liveness_verified,
        'submitted_at',      vr.submitted_at,
        'country_code',      country_code_of(g.country),
        'country',           COALESCE(g.country, 'México'),
        'state',             g.state,
        'city',              g.city
      ) AS item
    FROM verification_requests vr
    JOIN groups g ON g.id = vr.group_id
    WHERE vr.status = 'pending'
      AND (v_caller_role = 'admin' OR country_code_of(g.country) = admin_ops_country())
    LIMIT p_limit
  ) x;

  RETURN v_result;
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_get_pending_profile_verifications(p_role text DEFAULT NULL::text, p_limit integer DEFAULT 50)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE
  v_caller_role TEXT;
  v_result      JSONB;
BEGIN
  SELECT role INTO v_caller_role FROM profiles WHERE id = auth.uid();
  IF v_caller_role NOT IN ('admin', 'admin_ops') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;
  IF p_role IS NOT NULL AND p_role NOT IN ('client', 'talent') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_role');
  END IF;

  SELECT jsonb_build_object(
    'ok', true,
    'items', COALESCE(jsonb_agg(x.item ORDER BY x.submitted_at ASC), '[]'::jsonb)
  )
  INTO v_result
  FROM (
    SELECT
      p.verification_submitted_at AS submitted_at,
      jsonb_build_object(
        'id',                p.id,
        'full_name',         p.full_name,
        'role',              p.role,
        'submitted_at',      p.verification_submitted_at,
        'country_code',      country_code_of(p.country),
        'country',           COALESCE(p.country, 'México'),
        'state',             p.state,
        'city',              p.city
      ) AS item
    FROM profiles p
    WHERE p.role IN ('client', 'talent')
      AND p.verification_status = 'pending'
      AND (p_role IS NULL OR p.role = p_role)
      AND (v_caller_role = 'admin' OR country_code_of(p.country) = admin_ops_country())
    LIMIT p_limit
  ) x;

  RETURN v_result;
END;
$function$;

-- admin_withdrawals_queue / admin_manual_refund_queue: se restaura SOLO
-- el filtro de mute (quitado), NO el `WHERE id = auth.uid()` original —
-- ver nota al inicio del archivo.
CREATE OR REPLACE FUNCTION public.admin_withdrawals_queue(p_limit integer DEFAULT 60)
RETURNS TABLE(id uuid, user_id uuid, owner_name text, owner_phone text, group_name text, country_code text, country text, state text, city text, currency text, expected_method text, amount numeric, status text, bank_clabe text, bank_name text, account_holder text, transfer_reference text, receipt_path text, created_at timestamp with time zone, processed_at timestamp with time zone)
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE
  v_caller_role TEXT;
BEGIN
  SELECT role INTO v_caller_role FROM profiles WHERE profiles.id = auth.uid();
  IF v_caller_role NOT IN ('admin', 'admin_ops') THEN
    RAISE EXCEPTION 'Solo administradores';
  END IF;
  RETURN QUERY
  SELECT
    w.id, w.user_id,
    p.full_name, p.phone,
    g.name,
    country_code_of(COALESCE(g.country, p.country)),
    COALESCE(g.country, p.country, 'México'),
    COALESCE(g.state,  p.state),
    COALESCE(g.city,   p.city),
    CASE WHEN country_code_of(COALESCE(g.country, p.country)) = 'US' THEN 'USD' ELSE 'MXN' END,
    CASE WHEN country_code_of(COALESCE(g.country, p.country)) = 'US' THEN 'stripe_ach' ELSE 'spei' END,
    w.amount, w.status,
    w.bank_clabe, w.bank_name, w.account_holder,
    w.transfer_reference, w.receipt_path,
    w.created_at, w.processed_at
  FROM withdrawals w
  JOIN profiles p ON p.id = w.user_id
  LEFT JOIN groups g ON g.owner_id = w.user_id
  WHERE (v_caller_role = 'admin' OR country_code_of(COALESCE(g.country, p.country)) = admin_ops_country())
  ORDER BY (w.status IN ('pending','processing')) DESC, w.created_at DESC
  LIMIT p_limit;
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_manual_refund_queue(p_status text DEFAULT NULL::text)
RETURNS TABLE(id uuid, reservation_id uuid, client_id uuid, folio text, client_name text, client_phone text, country_code text, country text, state text, city text, currency text, payment_method text, amount numeric, clabe text, account_holder text, bank_name text, due_date date, status text, transfer_reference text, receipt_path text, api_error text, created_at timestamp with time zone, processed_at timestamp with time zone)
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE
  v_caller_role TEXT;
BEGIN
  SELECT role INTO v_caller_role FROM profiles WHERE profiles.id = auth.uid();
  IF v_caller_role NOT IN ('admin', 'admin_ops') THEN
    RAISE EXCEPTION 'Solo administradores';
  END IF;
  RETURN QUERY
  SELECT mr.id, mr.reservation_id, mr.client_id, mr.folio,
         p.full_name, p.phone,
         country_code_of(p.country),
         COALESCE(p.country, 'México'),
         p.state, p.city,
         COALESCE(r.currency_code, 'MXN'),
         mr.payment_method, mr.amount, mr.clabe, mr.account_holder, mr.bank_name,
         mr.due_date, mr.status, mr.transfer_reference, mr.receipt_path, mr.api_error,
         mr.created_at, mr.processed_at
  FROM manual_refunds mr
  JOIN profiles p ON p.id = mr.client_id
  LEFT JOIN reservations r ON r.id = mr.reservation_id
  WHERE (p_status IS NULL OR mr.status = p_status)
    AND (v_caller_role = 'admin' OR country_code_of(p.country) = admin_ops_country())
  ORDER BY (mr.status = 'sent'), mr.due_date, mr.created_at;
END;
$function$;

CREATE OR REPLACE FUNCTION public.confirm_gift_payment(p_group_gift_id uuid, p_conekta_order_id text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_gift          RECORD;
  v_gw            RECORD;
  v_admin_id      UUID;
  v_gw_bal_after  NUMERIC(14,2);
  v_group_owner   UUID;
  v_group_name    TEXT;
  v_gift_catalog  RECORD;
  v_sender_name   TEXT;
  v_recipient     UUID;
  v_notif_title   TEXT;
  v_notif_body    TEXT;
  v_notif_screen  TEXT;
  v_catalog_price NUMERIC;
  v_is_custom     BOOLEAN;
  v_is_tip        BOOLEAN;
  v_currency_sym  TEXT;
  v_sender_title  TEXT;
  v_sender_body   TEXT;
  v_wt_desc       TEXT;
  v_gift_label    TEXT;
BEGIN
  SELECT * INTO v_gift FROM public.group_gifts WHERE id = p_group_gift_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'group_gift no encontrado: %', p_group_gift_id; END IF;
  IF v_gift.status = 'paid' THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'already_paid');
  END IF;
  IF v_gift.currency_code NOT IN ('MXN', 'USD') THEN
    RAISE EXCEPTION 'unsupported_currency: %', v_gift.currency_code;
  END IF;

  UPDATE public.group_gifts
  SET status = 'paid', paid_at = NOW(), payment_ref = p_conekta_order_id
  WHERE id = p_group_gift_id;

  SELECT owner_id INTO v_group_owner FROM public.groups WHERE id = v_gift.group_id;
  SELECT name INTO v_group_name FROM public.groups WHERE id = v_gift.group_id;
  SELECT full_name INTO v_sender_name FROM public.profiles WHERE id = v_gift.sender_id;
  SELECT * INTO v_gift_catalog FROM public.gift_catalog WHERE id = v_gift.gift_id;

  SELECT amount INTO v_catalog_price
  FROM public.gift_catalog_prices
  WHERE gift_id = v_gift.gift_id AND currency_code = v_gift.currency_code;
  v_is_custom := v_catalog_price IS NOT NULL AND v_gift.amount > v_catalog_price;
  v_is_tip    := v_gift.reservation_id IS NOT NULL;
  v_currency_sym := CASE v_gift.currency_code WHEN 'USD' THEN 'US$' ELSE '$' END;
  v_gift_label := CASE WHEN v_is_custom THEN 'Regalo sorpresa' ELSE COALESCE(v_gift_catalog.name, 'Regalo') END;

  v_wt_desc := (CASE WHEN v_is_tip THEN 'Propina de evento (' || v_gift_label || ')' ELSE v_gift_label END)
    || ' de ' || COALESCE(v_sender_name, 'un fan');

  PERFORM public.ensure_group_wallet(v_gift.group_id);
  SELECT * INTO v_gw FROM public.group_wallets WHERE group_id = v_gift.group_id FOR UPDATE;

  IF v_gift.currency_code = 'USD' THEN
    v_gw_bal_after := COALESCE(v_gw.available_balance_usd, 0) + v_gift.group_amount;
    UPDATE public.group_wallets
    SET available_balance_usd = v_gw_bal_after,
        total_earned_usd      = COALESCE(total_earned_usd, 0) + v_gift.group_amount,
        total_gift_income_usd = COALESCE(total_gift_income_usd, 0) + v_gift.group_amount,
        updated_at            = NOW()
    WHERE id = v_gw.id;
  ELSE
    v_gw_bal_after := COALESCE(v_gw.available_balance, 0) + v_gift.group_amount;
    UPDATE public.group_wallets
    SET available_balance = v_gw_bal_after,
        total_earned      = COALESCE(total_earned, 0) + v_gift.group_amount,
        total_gift_income = COALESCE(total_gift_income, 0) + v_gift.group_amount,
        updated_at        = NOW()
    WHERE id = v_gw.id;
  END IF;

  INSERT INTO public.wallet_transactions
    (group_wallet_id, group_id, type, amount, gift_id, description, balance_after, currency_code)
  VALUES
    (v_gw.id, v_gift.group_id, 'gift_income', v_gift.group_amount, v_gift.id,
     v_wt_desc, v_gw_bal_after, v_gift.currency_code);

  v_admin_id := public.get_platform_admin_id();
  IF v_admin_id IS NOT NULL THEN
    INSERT INTO public.wallets (user_id) VALUES (v_admin_id) ON CONFLICT (user_id) DO NOTHING;
    IF v_gift.currency_code = 'USD' THEN
      UPDATE public.wallets
      SET available_balance_usd    = COALESCE(available_balance_usd, 0) + v_gift.platform_amount,
          total_earned_usd         = COALESCE(total_earned_usd, 0) + v_gift.platform_amount,
          total_gift_commission_usd = COALESCE(total_gift_commission_usd, 0) + v_gift.platform_amount,
          updated_at               = NOW()
      WHERE user_id = v_admin_id;
    ELSE
      UPDATE public.wallets
      SET available_balance     = available_balance + v_gift.platform_amount,
          total_earned          = COALESCE(total_earned, 0) + v_gift.platform_amount,
          total_gift_commission = COALESCE(total_gift_commission, 0) + v_gift.platform_amount,
          updated_at            = NOW()
      WHERE user_id = v_admin_id;
    END IF;
    INSERT INTO public.wallet_transactions
      (user_id, type, amount, gift_id, description, currency_code)
    VALUES
      (v_admin_id, 'commission', v_gift.platform_amount, v_gift.id,
       'Comisión por regalo', v_gift.currency_code);
  END IF;

  IF v_is_custom THEN
    v_notif_title  := CASE WHEN v_is_tip THEN '🎁 ¡Recibiste una propina sorpresa!' ELSE '🎁 ¡Recibiste un regalo sorpresa!' END;
    v_notif_body   := COALESCE(v_sender_name, 'Alguien')
      || (CASE WHEN v_is_tip THEN ' te dio una propina sorpresa por el evento. ' ELSE ' te mandó un regalo sorpresa. ' END)
      || 'Tócalo para descubrir cuánto fue.';
    v_notif_screen := 'GiftReveal';
  ELSE
    v_notif_title  := CASE WHEN v_is_tip THEN '🎁 ¡Recibiste una propina!' ELSE '🎁 ¡Recibiste un regalo!' END;
    v_notif_body   := COALESCE(v_sender_name, 'Alguien') || ' ' ||
      (CASE WHEN v_is_tip THEN 'te dio propina por el evento: ' ELSE '' END) ||
      CASE v_gift_catalog.name
        WHEN 'Corazón'  THEN CASE WHEN v_is_tip THEN 'Corazón ❤️.' ELSE 'te mandó un Corazón ❤️.' END
        WHEN 'Fuego'    THEN CASE WHEN v_is_tip THEN 'Fuego 🔥.' ELSE 'te mandó un Fuego 🔥.' END
        WHEN 'Rayo'     THEN CASE WHEN v_is_tip THEN 'Rayo ⚡.' ELSE 'te mandó un Rayo ⚡.' END
        WHEN 'Diamante' THEN CASE WHEN v_is_tip THEN 'Diamante 💎.' ELSE 'te regaló un Diamante 💎.' END
        WHEN 'Corona'   THEN CASE WHEN v_is_tip THEN 'Corona 👑.' ELSE 'te coronó 👑.' END
        WHEN 'Trofeo'   THEN CASE WHEN v_is_tip THEN 'Trofeo 🏆.' ELSE 'te dio el Trofeo 🏆.' END
        ELSE (CASE WHEN v_is_tip THEN '' ELSE 'te regaló ' END) || v_gift_catalog.emoji || ' ' || v_gift_catalog.name || '.'
      END;
    v_notif_screen := 'GiftReveal';
  END IF;

  v_sender_title := COALESCE(v_group_name, 'El grupo') || ' te dice ¡Gracias! 💚';

  IF v_is_custom THEN
    v_sender_body := 'Queremos agradecerte de manera muy especial por tu generoso apoyo de '
      || v_currency_sym || v_gift.amount || ' ' || v_gift.currency_code
      || ' 🌟. Gracias por creer en nuestra música — significa muchísimo para nosotros.';
  ELSE
    v_sender_body := CASE v_gift_catalog.name
      WHEN 'Corazón'  THEN '¡Gracias por tu Corazón ❤️! Tu apoyo nos ayuda a seguir haciendo música en vivo.'
      WHEN 'Fuego'    THEN '¡Gracias por tu Fuego 🔥! Cada regalo como este nos motiva a seguir tocando.'
      WHEN 'Rayo'     THEN '¡Gracias por tu Rayo ⚡! Se siente muchísimo tu apoyo.'
      WHEN 'Diamante' THEN '¡Gracias por tu Diamante 💎! Tu generosidad significa mucho para nosotros.'
      WHEN 'Corona'   THEN '¡Nos coronaste 👑! Gracias de corazón por tu apoyo.'
      WHEN 'Trofeo'   THEN 'Queremos agradecerte de manera muy especial por tu Trofeo 🏆. Tu apoyo hace una diferencia real en nuestra música — ¡gracias por creer en nosotros!'
      ELSE '¡Gracias por tu ' || v_gift_catalog.emoji || ' ' || v_gift_catalog.name || '! Tu apoyo significa mucho para nosotros.'
    END;
  END IF;

  FOR v_recipient IN
    SELECT DISTINCT recipient FROM (
      SELECT v_group_owner AS recipient
      UNION
      SELECT ji.invited_user_id
      FROM public.job_invitations ji
      WHERE ji.group_id = v_gift.group_id
        AND ji.status = 'accepted'
        AND ji.invitation_type IN ('membership', 'job')
        AND ji.event_id IS NULL
    ) recipients
    WHERE recipient IS NOT NULL AND recipient != v_gift.sender_id
  LOOP
    INSERT INTO public.notifications (user_id, type, title, body, data)
    VALUES (v_recipient, 'system', v_notif_title, v_notif_body,
      jsonb_build_object('screen', v_notif_screen, 'gift_id', v_gift.id));
  END LOOP;

  INSERT INTO public.notifications (user_id, type, title, body, data)
  VALUES (v_gift.sender_id, 'system', v_sender_title, v_sender_body,
    jsonb_build_object('screen', 'GroupDetail', 'group_id', v_gift.group_id, 'gift_id', v_gift.id));

  IF v_gift_catalog.notify_admin AND v_admin_id IS NOT NULL THEN
    INSERT INTO public.notifications (user_id, type, title, body, data)
    VALUES (
      v_admin_id, 'system',
      '🎆 Regalo grande enviado',
      COALESCE(v_sender_name, 'Alguien') || ' mandó ' || v_gift_catalog.emoji || ' ' || v_gift_label
        || ' ($' || v_gift.amount || ' ' || v_gift.currency_code || ').',
      jsonb_build_object('screen', 'AdminFinancial', 'gift_id', v_gift.id)
    );
  END IF;

  RETURN jsonb_build_object('ok', true, 'group_amount', v_gift.group_amount,
    'platform_amount', v_gift.platform_amount, 'currency', v_gift.currency_code);
END;
$function$;

DROP FUNCTION IF EXISTS public.admin_is_country_muted(text, uuid);

COMMIT;

-- ── VERIFICACIÓN ────────────────────────────────────────────
SELECT proname FROM pg_proc WHERE proname = 'admin_is_country_muted';
-- Esperado: 0 filas (función eliminada)

SELECT '642_admin_mute_hides_queues_ROLLBACK.sql ejecutado ✅' AS status;
