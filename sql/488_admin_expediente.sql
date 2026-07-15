-- ============================================================
-- sql/488_admin_expediente.sql
-- 📂 EXPEDIENTE DEL ADMIN — búsqueda inteligente + caso completo.
--
--  1. admin_search_expediente(q) — UNA caja de búsqueda:
--     folio parcial ("0001"), nombre de cliente, nombre de grupo o
--     teléfono (de cualquiera de los dos). Regresa filas compactas.
--  2. admin_expediente_detail(reservation_id) — el caso completo:
--     teléfonos, mini-perfiles con historial (eventos/cancelados/
--     strikes), dirección + coordenadas (COALESCE quote/express como
--     sql/487), evidencia GPS, pago, y los últimos eventos de ese
--     cliente y de ese grupo para saltar entre expedientes.
--
-- Solo lectura, solo admin. No toca dinero ni flujos.
-- ============================================================

BEGIN;

-- ────────────────────────────────────────────────────────────
-- 1) Búsqueda inteligente → filas compactas
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_search_expediente(
  p_query TEXT,
  p_limit INT DEFAULT 30
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_q      TEXT := TRIM(COALESCE(p_query, ''));
  v_result JSONB;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Acceso restringido a administradores');
  END IF;
  IF LENGTH(v_q) < 3 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Escribe al menos 3 caracteres');
  END IF;

  SELECT jsonb_build_object(
    'ok', true,
    'items', COALESCE(jsonb_agg(row ORDER BY row->>'event_date' DESC), '[]'::jsonb)
  ) INTO v_result
  FROM (
    SELECT jsonb_build_object(
      'id',             r.id,
      'folio',          r.folio,
      'event_date',     r.event_date,
      'event_time',     r.event_time,
      'group_name',     g.name,
      'client_name',    p.full_name,
      'total_price',    r.total_price,
      'currency',       COALESCE(r.currency_code, 'MXN'),
      'status',         r.status,
      'payment_status', r.payment_status
    ) AS row
    FROM reservations r
    LEFT JOIN groups   g  ON g.id  = r.group_id
    LEFT JOIN profiles p  ON p.id  = r.client_id
    LEFT JOIN profiles po ON po.id = g.owner_id
    WHERE r.folio       ILIKE '%' || v_q || '%'
       OR g.name        ILIKE '%' || v_q || '%'
       OR p.full_name   ILIKE '%' || v_q || '%'
       OR p.phone       ILIKE '%' || v_q || '%'
       OR po.phone      ILIKE '%' || v_q || '%'
    ORDER BY r.event_date DESC, r.created_at DESC
    LIMIT GREATEST(1, LEAST(p_limit, 100))
  ) sub;

  RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_search_expediente(TEXT, INT) TO authenticated;

-- ────────────────────────────────────────────────────────────
-- 2) Expediente completo de una reserva
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_expediente_detail(
  p_reservation_id UUID
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_r      RECORD;
  v_result JSONB;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Acceso restringido a administradores');
  END IF;

  SELECT r.*,
         COALESCE(r.event_lat, q.latitude,  er.latitude,  er.event_lat) AS ev_lat,
         COALESCE(r.event_lng, q.longitude, er.longitude, er.event_lng) AS ev_lng,
         q.event_type      AS quote_event_type,
         g.name            AS group_name,
         g.profile_image   AS group_image,
         g.is_verified     AS group_verified,
         g.strike_count    AS group_strikes,
         g.owner_id        AS owner_id,
         po.full_name      AS owner_name,
         po.phone          AS group_phone,
         p.full_name       AS client_name,
         p.phone           AS client_phone,
         p.avatar_url      AS client_avatar,
         (p.verification_status = 'approved' OR COALESCE(p.admin_verified, false)) AS client_verified
  INTO v_r
  FROM reservations r
  LEFT JOIN groups         g  ON g.id  = r.group_id
  LEFT JOIN profiles       po ON po.id = g.owner_id
  LEFT JOIN profiles       p  ON p.id  = r.client_id
  LEFT JOIN quotes         q  ON q.id  = r.quote_id
  LEFT JOIN event_requests er ON er.id = r.event_request_id
  WHERE r.id = p_reservation_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Reserva no encontrada');
  END IF;

  v_result := jsonb_build_object(
    'ok', true,
    'reservation', jsonb_build_object(
      'id',                  v_r.id,
      'folio',               v_r.folio,
      'event_date',          v_r.event_date,
      'event_time',          v_r.event_time,
      'event_type',          v_r.quote_event_type,
      'address',             v_r.address,
      'hours_count',         v_r.hours_count,
      'total_price',         v_r.total_price,
      'currency',            COALESCE(v_r.currency_code, 'MXN'),
      'status',              v_r.status,
      'payment_status',      v_r.payment_status,
      'payout_status',       v_r.payout_status,
      'payment_provider',    v_r.payment_provider,
      'payment_method_type', v_r.payment_method_type,
      'cancelled_by',        v_r.cancelled_by,
      'cancel_reason',       v_r.cancel_reason,
      'event_lat',           v_r.ev_lat,
      'event_lng',           v_r.ev_lng,
      -- Evidencia GPS (misma semántica que sql/487)
      'group_en_route_at',    v_r.group_en_route_at,
      'transit_lat',          v_r.transit_lat,
      'transit_lng',          v_r.transit_lng,
      'transit_updated_at',   v_r.transit_updated_at,
      'event_started_at',     v_r.event_started_at,
      'event_ended_at',       v_r.event_ended_at,
      'group_arrived_at',     v_r.group_arrived_at,
      'arrival_gps_verified', v_r.arrival_gps_verified
    ),
    'client', jsonb_build_object(
      'id',        v_r.client_id,
      'name',      v_r.client_name,
      'phone',     v_r.client_phone,
      'avatar',    v_r.client_avatar,
      'verified',  COALESCE(v_r.client_verified, false),
      'events_total',     (SELECT COUNT(*) FROM reservations x WHERE x.client_id = v_r.client_id),
      'events_completed', (SELECT COUNT(*) FROM reservations x WHERE x.client_id = v_r.client_id AND x.status = 'completed'),
      'events_cancelled', (SELECT COUNT(*) FROM reservations x WHERE x.client_id = v_r.client_id AND x.status = 'cancelled' AND x.cancelled_by = 'client'),
      'open_disputes',    (SELECT COUNT(*) FROM disputes d JOIN reservations x ON x.id = d.reservation_id
                           WHERE d.opened_by = v_r.client_id AND d.status IN ('open','under_review'))
    ),
    'group', jsonb_build_object(
      'id',        v_r.group_id,
      'name',      v_r.group_name,
      'image',     v_r.group_image,
      'owner_name', v_r.owner_name,
      'phone',     v_r.group_phone,
      'verified',  COALESCE(v_r.group_verified, false),
      'strikes',   COALESCE(v_r.group_strikes, 0),
      'events_total',     (SELECT COUNT(*) FROM reservations x WHERE x.group_id = v_r.group_id),
      'events_completed', (SELECT COUNT(*) FROM reservations x WHERE x.group_id = v_r.group_id AND x.status = 'completed'),
      'events_cancelled', (SELECT COUNT(*) FROM reservations x WHERE x.group_id = v_r.group_id AND x.status = 'cancelled' AND x.cancelled_by = 'group')
    ),
    'client_history', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'id', x.id, 'folio', x.folio, 'event_date', x.event_date,
        'status', x.status, 'total_price', x.total_price,
        'counterpart', xg.name
      ) ORDER BY x.event_date DESC)
      FROM (
        SELECT * FROM reservations
        WHERE client_id = v_r.client_id AND id <> v_r.id
        ORDER BY event_date DESC LIMIT 10
      ) x
      LEFT JOIN groups xg ON xg.id = x.group_id
    ), '[]'::jsonb),
    'group_history', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'id', x.id, 'folio', x.folio, 'event_date', x.event_date,
        'status', x.status, 'total_price', x.total_price,
        'counterpart', xp.full_name
      ) ORDER BY x.event_date DESC)
      FROM (
        SELECT * FROM reservations
        WHERE group_id = v_r.group_id AND id <> v_r.id
        ORDER BY event_date DESC LIMIT 10
      ) x
      LEFT JOIN profiles xp ON xp.id = x.client_id
    ), '[]'::jsonb)
  );

  RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_expediente_detail(UUID) TO authenticated;

COMMIT;

-- ── VERIFICACIÓN ──────────────────────────────────────────────────────────────
SELECT proname FROM pg_proc
WHERE proname IN ('admin_search_expediente', 'admin_expediente_detail');
-- Esperado: 2 filas

SELECT '488_admin_expediente.sql ejecutado ✅' AS status;
