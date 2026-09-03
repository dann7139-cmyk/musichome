-- ============================================================
-- sql/588_admin_expediente_event_id.sql
-- ✅ APLICADO A PRODUCCIÓN 2026-09-01 (verificado de nuevo 2026-09-02:
-- admin_expediente_detail() ya trae 'event_id' en el jsonb en vivo). El
-- texto de este encabezado no se había actualizado tras aplicarlo — solo
-- un hueco de documentación, la función sí quedó desplegada correctamente.
--
-- Agrega 'event_id' al jsonb de `admin_expediente_detail` para que
-- AdminTicketSearchScreen.tsx pueda mostrar el botón real "Ver evento
-- completo" (navega a AdminEventDetail / admin_get_event_detail de sql/585).
--
-- Confirmado por hash antes de tocarlo: admin_expediente_detail actual en
-- producción = md5(prosrc) 'ba2aa3aa2cae3c85a7ffc38f38a5c2e0' (verificado
-- 2026-08-30). Esta es la ÚNICA función que toca este archivo. No modifica
-- admin_search_expediente ni ninguna otra función. No toca sql/556.
--
-- Cambio real, línea por línea contra sql/488: se agrega una sola clave
-- ('event_id', v_r.event_id) dentro del jsonb 'reservation' — todo lo
-- demás es byte-idéntico a la versión vigente en producción.
--
-- Depende de sql/585 solo para tener sentido de punta a punta (el botón de
-- UI navega a AdminEventDetail, que usa admin_get_event_detail de sql/585).
-- Este archivo por sí solo es inofensivo incluso si sql/585 nunca se aplica:
-- solo agrega un campo más al jsonb existente, reservations.event_id ya es
-- una columna real hoy.
-- ============================================================

BEGIN;

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
      'event_id',            v_r.event_id,
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
SELECT proname FROM pg_proc WHERE proname = 'admin_expediente_detail';
-- Esperado: 1 fila

SELECT '588_admin_expediente_event_id.sql ejecutado ✅' AS status;
