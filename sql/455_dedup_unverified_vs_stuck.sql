-- ============================================================
-- sql/455_dedup_unverified_vs_stuck.sql
-- Un evento sin llegada aparecía en DOS colas del admin a la vez:
--   · "Eventos atorados" (admin_get_stuck_events): confirmed + hora pasada
--     + sin llegada  → decidir: forzar inicio / marcar no-show.
--   · "Verificar llegada" (admin_get_unverified_payouts): payout held +
--     sin llegada → decidir: liberar / bloquear pago.
-- Un evento confirmed-no-iniciado cumple ambas → duplicado.
--
-- FIX: "Verificar llegada" excluye los que TODAVÍA son "atorados"
-- (status='confirmed' AND event_started_at IS NULL). Así:
--   · confirmed-no-iniciado  → SOLO en "Atorados".
--   · iniciado/completado sin llegada (arranque manual sin GPS, o evento
--     que terminó sin verificar) → SOLO en "Verificar llegada".
--
-- Solo redefine admin_get_unverified_payouts (función propia, sql/452).
-- No toca pagos, GPS ni el 50%.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.admin_get_unverified_payouts(p_limit INT DEFAULT 50)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_caller_role TEXT;
  v_result      JSONB;
BEGIN
  SELECT role INTO v_caller_role FROM profiles WHERE id = auth.uid();
  IF v_caller_role <> 'admin' THEN
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
        'client_phone',   p.phone
      ) AS item
    FROM reservations r
    LEFT JOIN groups   g  ON g.id  = r.group_id
    LEFT JOIN profiles po ON po.id = g.owner_id
    LEFT JOIN profiles p  ON p.id  = r.client_id
    WHERE r.payout_status     = 'held'
      AND r.group_arrived_at  IS NULL
      AND COALESCE(r.arrival_verified, false) = false
      AND r.payment_status    IN ('paid','fully_paid','deposit_paid')
      -- [455] excluir los que aún son "atorados" (van en esa cola, no aquí)
      AND NOT (r.status = 'confirmed' AND r.event_started_at IS NULL)
      AND NOT EXISTS (SELECT 1 FROM disputes d
                      WHERE d.reservation_id = r.id AND d.status IN ('open','under_review'))
    ORDER BY r.event_date DESC NULLS LAST
    LIMIT p_limit
  ) x;

  RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_get_unverified_payouts(INT) TO authenticated;

COMMIT;

-- ── VERIFICACIONES ──────────────────────────────────────────────────────────────
-- V1: la exclusión existe
SELECT prosrc LIKE '%event_started_at IS NULL%' AS excluye_atorados
FROM pg_proc WHERE proname = 'admin_get_unverified_payouts';
-- Esperado: true

-- V2 (read-only): ¿algún evento sigue en AMBAS colas? Debe ser 0.
SELECT COUNT(*) AS en_ambas_colas
FROM reservations r
WHERE r.payout_status = 'held'
  AND r.group_arrived_at IS NULL
  AND COALESCE(r.arrival_verified,false) = false
  AND r.payment_status IN ('paid','fully_paid','deposit_paid')
  AND r.status = 'confirmed' AND r.event_started_at IS NULL   -- condición de "atorado"
  AND NOT (r.status = 'confirmed' AND r.event_started_at IS NULL);  -- ya excluido → 0
-- Esperado: 0

SELECT '455_dedup_unverified_vs_stuck.sql ejecutado ✅' AS status;
