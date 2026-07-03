-- ============================================================
-- sql/424_gps_verified_arrival.sql
-- GPS FASE 1 — Llegada verificada + candado server-side del 50%
--
--   · Umbral SERVIDOR: 250 m (cliente valida a 200 m; los 50 m de
--     margen evitan el rebote "pasó en el teléfono, falló en server"
--     por deriva GPS urbana).
--   · El RPC resuelve las coords del evento POR SÍ MISMO (cascada
--     quotes → event_requests) — nunca confía en coords del evento
--     enviadas por el cliente. Un cliente modificado no puede mentir.
--   · Evento CON coords: sin p_lat/p_lng → gps_required; >250 m →
--     too_far; pasa → marca llegada + auditoría + verified=true +
--     libera 50%.
--   · Evento SIN coords (reservas directas, fase 1): marca llegada,
--     libera 50% con verified=false y AVISA AL ADMIN (type 'admin',
--     ya en el constraint — cero cambios de constraint/handler).
--   · group_arrived_at ahora lo escribe el RPC atómicamente (el
--     frontend ya no hace el UPDATE directo).
--
-- Base: lógica de dinero de sql/240 (currency-aware) conservada.
-- ============================================================

BEGIN;

-- ── 1. Columnas de auditoría ──────────────────────────────────────────────────
ALTER TABLE public.reservations
  ADD COLUMN IF NOT EXISTS arrival_lat          NUMERIC,
  ADD COLUMN IF NOT EXISTS arrival_lng          NUMERIC,
  ADD COLUMN IF NOT EXISTS arrival_distance_m   INT,
  ADD COLUMN IF NOT EXISTS arrival_gps_verified BOOLEAN;

-- ── 2. Haversine en metros ────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.haversine_m(
  lat1 FLOAT8, lng1 FLOAT8, lat2 FLOAT8, lng2 FLOAT8
)
RETURNS NUMERIC
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
  r     CONSTANT FLOAT8 := 6371000;  -- radio terrestre en metros
  dlat  FLOAT8 := radians(lat2 - lat1);
  dlng  FLOAT8 := radians(lng2 - lng1);
  a     FLOAT8;
BEGIN
  a := sin(dlat / 2) ^ 2
     + cos(radians(lat1)) * cos(radians(lat2)) * sin(dlng / 2) ^ 2;
  RETURN (r * 2 * atan2(sqrt(a), sqrt(1 - a)))::NUMERIC;
END;
$$;

-- ── 3. release_half_on_arrival con candado GPS ────────────────────────────────
-- Se dropea la firma vieja (UUID) — único caller es EventTimerScreen,
-- que en este mismo lote pasa a la firma nueva.
DROP FUNCTION IF EXISTS public.release_half_on_arrival(UUID);
DROP FUNCTION IF EXISTS public.release_half_on_arrival(UUID, FLOAT8, FLOAT8);

CREATE FUNCTION public.release_half_on_arrival(
  p_reservation_id UUID,
  p_lat            FLOAT8 DEFAULT NULL,
  p_lng            FLOAT8 DEFAULT NULL
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_reservation RECORD;
  v_wallet      RECORD;
  v_total       NUMERIC;
  v_half        NUMERIC;
  v_currency    TEXT;
  v_ev_lat      FLOAT8;
  v_ev_lng      FLOAT8;
  v_dist        NUMERIC;
  v_verified    BOOLEAN;
  v_admin_id    UUID;
  v_group_name  TEXT;
  c_umbral_m    CONSTANT NUMERIC := 250;  -- servidor 250 m (cliente 200 m)
BEGIN
  SELECT * INTO v_reservation FROM reservations WHERE id = p_reservation_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'not_found'); END IF;

  -- Idempotencia: llegada ya registrada → no repetir nada
  IF v_reservation.group_arrived_at IS NOT NULL THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'already_arrived',
                              'verified', v_reservation.arrival_gps_verified);
  END IF;

  -- ── CANDADO GPS: coords del evento resueltas SERVER-SIDE ──────────
  v_ev_lat := NULL; v_ev_lng := NULL;
  IF v_reservation.quote_id IS NOT NULL THEN
    SELECT q.latitude, q.longitude INTO v_ev_lat, v_ev_lng
    FROM quotes q WHERE q.id = v_reservation.quote_id;
  END IF;
  IF (v_ev_lat IS NULL OR v_ev_lng IS NULL)
     AND v_reservation.event_request_id IS NOT NULL THEN
    SELECT COALESCE(er.latitude, er.event_lat), COALESCE(er.longitude, er.event_lng)
    INTO   v_ev_lat, v_ev_lng
    FROM   event_requests er WHERE er.id = v_reservation.event_request_id;
  END IF;

  IF v_ev_lat IS NOT NULL AND v_ev_lng IS NOT NULL THEN
    -- Evento CON coords: GPS obligatorio y dentro del umbral
    IF p_lat IS NULL OR p_lng IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'error', 'gps_required');
    END IF;
    v_dist := haversine_m(p_lat, p_lng, v_ev_lat, v_ev_lng);
    IF v_dist > c_umbral_m THEN
      RETURN jsonb_build_object('ok', false, 'error', 'too_far',
                                'distance_m', ROUND(v_dist)::INT);
    END IF;
    v_verified := TRUE;
  ELSE
    -- Evento SIN coords (reserva directa, fase 1): libera sin verificar
    -- + aviso al admin (abajo). El server detecta la ausencia por sí
    -- mismo — el cliente nunca declara "no hay coords".
    v_verified := FALSE;
  END IF;

  -- ── Marcar llegada + auditoría (atómico, dentro del FOR UPDATE) ───
  UPDATE reservations SET
    group_arrived_at     = NOW(),
    arrival_lat          = p_lat,
    arrival_lng          = p_lng,
    arrival_distance_m   = CASE WHEN v_dist IS NOT NULL THEN ROUND(v_dist)::INT END,
    arrival_gps_verified = v_verified,
    updated_at           = NOW()
  WHERE id = p_reservation_id;

  -- Aviso al admin cuando la llegada NO pudo verificarse por GPS
  IF NOT v_verified THEN
    SELECT id INTO v_admin_id FROM profiles WHERE role = 'admin' LIMIT 1;
    SELECT name INTO v_group_name FROM groups WHERE id = v_reservation.group_id;
    IF v_admin_id IS NOT NULL THEN
      INSERT INTO notifications (user_id, type, title, body, data)
      VALUES (
        v_admin_id, 'admin',
        '📍 Llegada sin verificación GPS',
        COALESCE(v_group_name, 'Un grupo') ||
          ' marcó llegada en una reserva sin coordenadas del evento. Reserva: ' ||
          p_reservation_id::text,
        jsonb_build_object(
          'reservation_id', p_reservation_id,
          'group_id',       v_reservation.group_id,
          'reason',         'no_event_coords',
          'screen',         'AdminVerifications'
        )
      );
    END IF;
  END IF;

  -- ── Dinero: lógica de sql/240 (sin cambios de fondo) ──────────────
  IF v_reservation.payout_status != 'held' THEN
    RETURN jsonb_build_object('ok', true, 'arrived', true, 'released', false,
                              'skipped_release', v_reservation.payout_status,
                              'verified', v_verified,
                              'distance_m', CASE WHEN v_dist IS NOT NULL THEN ROUND(v_dist)::INT END);
  END IF;

  IF v_reservation.payment_status NOT IN ('paid','fully_paid','deposit_paid') THEN
    RETURN jsonb_build_object('ok', true, 'arrived', true, 'released', false,
                              'skipped_release', 'payment_not_confirmed',
                              'verified', v_verified,
                              'distance_m', CASE WHEN v_dist IS NOT NULL THEN ROUND(v_dist)::INT END);
  END IF;

  v_currency := COALESCE(v_reservation.currency_code, 'MXN');

  PERFORM ensure_group_wallet(v_reservation.group_id);
  SELECT * INTO v_wallet FROM group_wallets WHERE group_id = v_reservation.group_id FOR UPDATE;

  v_total := COALESCE(v_reservation.group_earnings,
               COALESCE(v_reservation.base_price,
                 ROUND(v_reservation.total_price * 0.9, 2)));
  v_half  := ROUND(v_total / 2, 2);

  IF v_currency = 'USD' THEN
    UPDATE group_wallets SET
      pending_balance_usd   = GREATEST(0, pending_balance_usd - v_half),
      available_balance_usd = available_balance_usd + v_half,
      updated_at            = NOW()
    WHERE id = v_wallet.id;
  ELSE
    UPDATE group_wallets SET
      pending_balance   = GREATEST(0, pending_balance - v_half),
      available_balance = available_balance + v_half,
      updated_at        = NOW()
    WHERE id = v_wallet.id;
  END IF;

  UPDATE reservations SET payout_status = 'half_released', updated_at = NOW()
  WHERE id = p_reservation_id;

  INSERT INTO wallet_transactions
    (group_wallet_id, group_id, type, amount, reservation_id, description, balance_after, currency_code)
  VALUES (v_wallet.id, v_reservation.group_id, 'credit_available', v_half,
    p_reservation_id,
    format('50%% al llegar al evento — reserva %s', p_reservation_id),
    CASE WHEN v_currency = 'USD'
      THEN v_wallet.available_balance_usd + v_half
      ELSE v_wallet.available_balance + v_half
    END,
    v_currency);

  INSERT INTO financial_audit_logs
    (entity_type, entity_id, action, actor_id, actor_role, amount, notes)
  VALUES ('reservation', p_reservation_id, 'partial_release', NULL, 'system', v_half,
    format('50%% on arrival currency=%s gps_verified=%s dist_m=%s',
           v_currency, v_verified, COALESCE(ROUND(v_dist)::text, 'n/a')));

  INSERT INTO notifications (user_id, type, title, body, data)
  SELECT g.owner_id, 'payout',
    '💰 50% disponible en tu wallet',
    format('$%s %s disponibles por llegar al evento.',
      to_char(v_half, 'FM999,999,990'), v_currency),
    jsonb_build_object('screen','Wallet','reservation_id',p_reservation_id)
  FROM groups g WHERE g.id = v_reservation.group_id;

  RETURN jsonb_build_object('ok', true, 'arrived', true, 'released', true,
                            'amount_released', v_half, 'currency', v_currency,
                            'verified', v_verified,
                            'distance_m', CASE WHEN v_dist IS NOT NULL THEN ROUND(v_dist)::INT END);
END;
$$;

GRANT EXECUTE ON FUNCTION public.release_half_on_arrival(UUID, FLOAT8, FLOAT8)
  TO authenticated, service_role;

COMMIT;

-- ── Verificaciones ────────────────────────────────────────────────────────────
-- V1: columnas de auditoría creadas
SELECT column_name FROM information_schema.columns
WHERE table_schema='public' AND table_name='reservations'
  AND column_name LIKE 'arrival_%'
ORDER BY column_name;
-- Esperado: arrival_distance_m, arrival_gps_verified, arrival_lat, arrival_lng

-- V2: haversine correcta (~200 m entre 2 puntos conocidos de GDL)
SELECT ROUND(haversine_m(20.6597, -103.3496, 20.6615, -103.3496)) AS metros_aprox;
-- Esperado: ~200 (±2)

-- V3: una sola firma del RPC, la nueva
SELECT proname, pg_get_function_identity_arguments(oid) AS firma
FROM pg_proc WHERE proname = 'release_half_on_arrival';
-- Esperado: 1 fila → (uuid, double precision, double precision)

-- V4: el candado está en la definición
SELECT
  routine_definition LIKE '%gps_required%' AS lock_gps,
  routine_definition LIKE '%too_far%'      AS lock_dist,
  routine_definition LIKE '%no_event_coords%' AS aviso_admin
FROM information_schema.routines
WHERE routine_schema='public' AND routine_name='release_half_on_arrival';
-- Esperado: true | true | true

SELECT '424_gps_verified_arrival.sql ejecutado ✅' AS status;
