-- ============================================================
-- sql/446_add_phones_to_stuck_events.sql
-- Agrega teléfonos (grupo + cliente) a admin_get_stuck_events (sql/444)
-- para que el ADMIN pueda marcarles y confirmar qué pasó antes de forzar
-- el inicio.
--
-- Fuentes de teléfono (mismo patrón que sql/426 admin_dispute_evidence):
--   · Cliente: profiles.phone  (client_id → profiles)
--   · Grupo:   profiles.phone del OWNER (groups.owner_id → profiles)
--
-- SOLO para admin (gate de rol intacto, SECURITY DEFINER). Los teléfonos
-- NO se exponen a otros usuarios — la regla anti-robo-de-contacto sigue
-- intacta a nivel de usuario; esta función solo la ejecuta el admin.
--
-- Read-only. NO cancela, NO toca payout/wallet, NO toca el candado GPS ni
-- el release del 50%. Solo añade 2 campos y un JOIN al owner.
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
        'group_phone',    po.phone,        -- [446] teléfono del owner del grupo
        'client_name',    p.full_name,
        'client_phone',   p.phone,         -- [446] teléfono del cliente
        'minutes_late',   GREATEST(0, (EXTRACT(EPOCH FROM (
                            NOW() - ((r.event_date + COALESCE(r.event_time, '23:59:00'::TIME))
                                     AT TIME ZONE 'America/Mexico_City')
                          )) / 60)::INT)
      ) AS item
    FROM reservations r
    LEFT JOIN groups   g  ON g.id  = r.group_id
    LEFT JOIN profiles po ON po.id = g.owner_id   -- [446] owner del grupo (para su teléfono)
    LEFT JOIN profiles p  ON p.id  = r.client_id
    WHERE r.status           = 'confirmed'
      AND r.event_started_at IS NULL
      AND r.group_arrived_at IS NULL
      AND r.payment_status   IN ('paid', 'deposit_paid', 'fully_paid')
      AND ((r.event_date + COALESCE(r.event_time, '23:59:00'::TIME))
             AT TIME ZONE 'America/Mexico_City') < NOW() - INTERVAL '10 minutes'
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
-- V1: función trae teléfonos, sigue siendo read-only y no toca dinero/GPS
SELECT
  prosecdef                                   AS is_security_definer,
  prosrc LIKE '%group_phone%'                 AS trae_tel_grupo,     -- true
  prosrc LIKE '%client_phone%'                AS trae_tel_cliente,   -- true
  prosrc LIKE '%g.owner_id%'                  AS join_owner,         -- true
  prosrc NOT LIKE '%release_half_on_arrival%' AS no_toca_gps,        -- true
  prosrc NOT LIKE '%group_wallets%'           AS no_toca_wallet,     -- true
  prosrc NOT LIKE '%UPDATE %'                 AS solo_lectura        -- true
FROM pg_proc
WHERE proname = 'admin_get_stuck_events';
-- Esperado: true | true | true | true | true | true | true

-- V2: preview — la cola con teléfonos
-- SELECT admin_get_stuck_events();
-- Esperado: items[] con group_phone y client_phone (o null si el perfil no tiene).

SELECT '446_add_phones_to_stuck_events.sql ejecutado ✅' AS status;
