-- ============================================================
-- sql/487_noshow_gps_evidence.sql
-- 🗺️ EVIDENCIA GPS en la cola de no-shows del admin.
--
-- Antes la tarjeta solo traía teléfonos y datos del evento — el admin
-- no podía ver si el grupo presionó "Voy en camino", hasta dónde llegó
-- su rastro GPS, ni si el evento inició con el PIN del cliente.
--
-- admin_get_no_shows v3 agrega por reserva:
--   event_lat/lng        → dónde ERA el evento
--   group_en_route_at    → ¿presionó "Voy en camino"? ¿a qué hora?
--   transit_lat/lng      → ÚLTIMO punto GPS del trayecto del grupo
--   transit_updated_at   → hora de ese último punto
--   event_started_at     → ¿el evento inició con el PIN del cliente?
--   group_arrived_at + arrival_gps_verified → llegada (normalmente NULL
--     aquí — por eso es no-show — pero cubre el caso admin_mark_no_show)
--
-- Regla del juez: sin llegada + sin rastro + sin PIN = reembolso 100%.
-- Cualquier evidencia presente = el grupo sí fue (o al menos salió).
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.admin_get_no_shows(p_limit integer DEFAULT 50)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_role TEXT;
  v_result      JSONB;
BEGIN
  SELECT role INTO v_caller_role FROM profiles WHERE id = auth.uid();
  IF v_caller_role <> 'admin' THEN
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
          -- [487] 🗺️ Evidencia GPS del trayecto y arranque.
          -- Coordenadas del evento: reservations.event_lat casi siempre va
          -- NULL — las reales viven en la cotización (programadas) o en la
          -- solicitud (express). COALESCE cubre los tres orígenes.
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
  LEFT JOIN quotes         q  ON q.id  = r.quote_id            -- [487] coords programadas
  LEFT JOIN event_requests er ON er.id = r.event_request_id    -- [487] coords express
  WHERE r.cancellation_type          = 'system_auto'
    AND r.cancel_reason              = 'no_show_grupo'
    AND r.admin_no_show_resolution   IS NULL
  LIMIT p_limit;

  RETURN v_result;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_get_no_shows(integer) TO authenticated;

COMMIT;

-- ── VERIFICACIÓN ──────────────────────────────────────────────────────────────
SELECT prosrc LIKE '%transit_lat%' AS con_evidencia_gps
FROM pg_proc WHERE proname = 'admin_get_no_shows';
-- Esperado: true

SELECT '487_noshow_gps_evidence.sql ejecutado ✅' AS status;
