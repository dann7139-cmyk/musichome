-- ============================================================
-- sql/444_admin_get_stuck_events.sql
-- Cola "Eventos atorados" para el admin.
--
-- PROBLEMA: admin_get_no_shows (386) solo lista reservas YA CANCELADAS
-- por abandono (cancellation_type='system_auto'). Los eventos que solo
-- dispararon la ALERTA de no-show (auto_start_due_events CASO 2) siguen
-- en status='confirmed' y NO aparecen en ninguna cola → el admin no
-- tiene dónde forzar su inicio (caso DRC-2026-0017).
--
-- ESTA función (NUEVA, read-only) lista exactamente esos eventos:
--   · status = 'confirmed' (no iniciado, no cancelado)
--   · pagado (mismo filtro de payment que mark_abandoned_reservations)
--   · SIN llegada GPS (group_arrived_at IS NULL)
--   · hora del evento ya pasada (+10 min de gracia, igual que el auto-inicio)
--   · dentro de las últimas 48 h (para que la cola sea accionable y no
--     acumule eventos viejos indefinidamente).
--
-- Solo lee. NO cancela, NO toca payout/wallet, NO toca el candado GPS ni
-- el release del 50%. El force-start real lo hace admin_force_start_event
-- (sql/443), que exige status IN ('confirmed','accepted').
--
-- México = UTC-6 fijo (sin horario de verano desde 2022).
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.admin_get_stuck_events(p_limit INT DEFAULT 50)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_role TEXT;
  v_result      JSONB;
BEGIN
  -- Gate admin
  SELECT role INTO v_caller_role FROM profiles WHERE id = auth.uid();
  IF v_caller_role <> 'admin' THEN
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
        'client_name',    p.full_name,
        'minutes_late',   GREATEST(0, (EXTRACT(EPOCH FROM (
                            NOW() - ((r.event_date + COALESCE(r.event_time, '23:59:00'::TIME))
                                     AT TIME ZONE 'America/Mexico_City')
                          )) / 60)::INT)
      ) AS item
    FROM reservations r
    LEFT JOIN groups   g ON g.id = r.group_id
    LEFT JOIN profiles p ON p.id = r.client_id
    WHERE r.status           = 'confirmed'
      AND r.event_started_at IS NULL
      AND r.group_arrived_at IS NULL
      AND r.payment_status   IN ('paid', 'deposit_paid', 'fully_paid')
      -- hora del evento ya pasada + 10 min de gracia (igual que el auto-inicio)
      AND ((r.event_date + COALESCE(r.event_time, '23:59:00'::TIME))
             AT TIME ZONE 'America/Mexico_City') < NOW() - INTERVAL '10 minutes'
      -- ventana de 48 h para que la cola sea accionable
      AND ((r.event_date + COALESCE(r.event_time, '23:59:00'::TIME))
             AT TIME ZONE 'America/Mexico_City') > NOW() - INTERVAL '48 hours'
    ORDER BY event_ts DESC
    LIMIT p_limit
  ) x;

  RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_get_stuck_events(INT) TO authenticated;

COMMIT;

-- ── VERIFICACIONES (correr por separado después del COMMIT) ─────────────────────
-- V1: función existe, SECURITY DEFINER, y NO toca dinero/GPS
SELECT
  prosecdef                                               AS is_security_definer,
  prosrc NOT LIKE '%release_half_on_arrival%'             AS no_toca_gps,
  prosrc NOT LIKE '%group_wallets%'                       AS no_toca_wallet,
  prosrc NOT LIKE '%UPDATE %'                             AS solo_lectura
FROM pg_proc
WHERE proname = 'admin_get_stuck_events';
-- Esperado: true | true | true | true

-- V2: vista previa de la cola actual (debería incluir DRC-2026-0017 si sigue atorado)
-- SELECT admin_get_stuck_events();
-- Esperado: {"ok": true, "items": [ { "folio": "DRC-2026-0017", ... "minutes_late": N } ]}

SELECT '444_admin_get_stuck_events.sql ejecutado ✅' AS status;
