-- ============================================================
-- sql/426_admin_dispute_evidence.sql
-- LOTE B · Evidencia GPS para disputas (admin)
--
-- admin_dispute_evidence(p_reservation_id) → JSONB con todo lo que el
-- mapa de evidencia necesita en UN viaje:
--   · Coords del EVENTO resueltas con la MISMA cascada del candado
--     sql/424 (quotes → event_requests, COALESCE(latitude, event_lat))
--     — una sola verdad sobre "dónde era el evento".
--   · arrival_lat/lng/distance_m/gps_verified + group_arrived_at
--     (auditoría escrita por release_half_on_arrival).
--   · Teléfono del owner del grupo (groups.owner_id → profiles.phone).
--
-- SECURITY DEFINER + gate de rol admin adentro (patrón admin_*).
-- Razón de ser RPC y no joins: las políticas RLS de quotes /
-- event_requests son de cliente/grupo — al admin le devolverían NULL
-- en silencio.
--
-- NO toca notificaciones ni el constraint (nada que pre-checar).
-- NO toca release_half_on_arrival ni resolve_dispute.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.admin_dispute_evidence(p_reservation_id UUID)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_res       RECORD;
  v_ev_lat    FLOAT8;
  v_ev_lng    FLOAT8;
  v_phone     TEXT;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin') THEN
    RAISE EXCEPTION 'unauthorized: solo admins';
  END IF;

  SELECT r.id, r.quote_id, r.event_request_id, r.group_id,
         r.arrival_lat, r.arrival_lng, r.arrival_distance_m,
         r.arrival_gps_verified, r.group_arrived_at,
         r.event_date, r.event_time, r.address,
         g.name AS group_name, g.owner_id
  INTO   v_res
  FROM   reservations r
  JOIN   groups g ON g.id = r.group_id
  WHERE  r.id = p_reservation_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_found');
  END IF;

  -- Cascada de coords del evento — idéntica a release_half_on_arrival (sql/424)
  v_ev_lat := NULL; v_ev_lng := NULL;
  IF v_res.quote_id IS NOT NULL THEN
    SELECT q.latitude, q.longitude INTO v_ev_lat, v_ev_lng
    FROM quotes q WHERE q.id = v_res.quote_id;
  END IF;
  IF (v_ev_lat IS NULL OR v_ev_lng IS NULL)
     AND v_res.event_request_id IS NOT NULL THEN
    SELECT COALESCE(er.latitude, er.event_lat), COALESCE(er.longitude, er.event_lng)
    INTO   v_ev_lat, v_ev_lng
    FROM   event_requests er WHERE er.id = v_res.event_request_id;
  END IF;

  SELECT p.phone INTO v_phone FROM profiles p WHERE p.id = v_res.owner_id;

  RETURN jsonb_build_object(
    'ok',                   true,
    'event_lat',            v_ev_lat,
    'event_lng',            v_ev_lng,
    'arrival_lat',          v_res.arrival_lat,
    'arrival_lng',          v_res.arrival_lng,
    'arrival_distance_m',   v_res.arrival_distance_m,
    'arrival_gps_verified', v_res.arrival_gps_verified,
    'group_arrived_at',     v_res.group_arrived_at,
    'group_name',           v_res.group_name,
    'owner_phone',          v_phone,
    'event_date',           v_res.event_date,
    'address',              v_res.address
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_dispute_evidence(UUID) TO authenticated;

COMMIT;

-- ── Verificaciones ────────────────────────────────────────────────────────────
-- V1: existe con SECURITY DEFINER
SELECT proname, prosecdef AS security_definer
FROM   pg_proc
WHERE  proname = 'admin_dispute_evidence'
  AND  pronamespace = 'public'::regnamespace;
-- Esperado: 1 fila, security_definer = true

-- V2: usa la cascada del candado (misma verdad que sql/424)
SELECT
  routine_definition LIKE '%COALESCE(er.latitude, er.event_lat)%' AS cascada_ok,
  routine_definition LIKE '%owner_phone%'                          AS telefono_ok
FROM information_schema.routines
WHERE routine_schema = 'public' AND routine_name = 'admin_dispute_evidence';
-- Esperado: true | true

-- V3 (funcional, corre como admin): evidencia de la reserva DRC
-- SELECT admin_dispute_evidence('ea478bd1-5286-4e77-9cb3-76b6b8b43827');
-- Esperado: ok:true con event_lat/lng (tiene event_request con coords),
--           arrival_* según el último estado, owner_phone del grupo.

SELECT '426_admin_dispute_evidence.sql ejecutado ✅' AS status;
