-- ============================================================
-- sql/452_unverified_payouts_queue.sql
-- Cola admin "Verificar llegada" (Opción A): eventos cuyo pago quedó 'held'
-- porque el grupo nunca probó presencia (sin group_arrived_at ni
-- arrival_verified). El admin llama por teléfono, confirma y LIBERA, o BLOQUEA.
--
-- 3 RPCs (todos SECURITY DEFINER + gate admin):
--   · admin_get_unverified_payouts  — lista (con teléfonos grupo+cliente)
--   · admin_verify_arrival_and_release — marca arrival_verified=true y libera
--   · admin_block_unverified_payout — bloquea el payout (no se paga al grupo)
--
-- NO toca el candado GPS ni el 50% anticipado. La liberación reusa el punto
-- único release_group_earnings_atomic (que ahora respeta el guard de llegada).
-- ============================================================

BEGIN;

-- ─── 1. Lista de pagos retenidos por falta de verificación ────────────────────
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
      AND NOT EXISTS (SELECT 1 FROM disputes d
                      WHERE d.reservation_id = r.id AND d.status IN ('open','under_review'))
    ORDER BY r.event_date DESC NULLS LAST
    LIMIT p_limit
  ) x;

  RETURN v_result;
END;
$$;

-- ─── 2. Verificar llegada (admin confirmó) y liberar ──────────────────────────
CREATE OR REPLACE FUNCTION public.admin_verify_arrival_and_release(p_reservation_id UUID)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_admin_id UUID := auth.uid();
  v_release  JSONB;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = v_admin_id AND role = 'admin') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;

  -- Marca presencia verificada por el admin (auditable)
  UPDATE reservations SET arrival_verified = true, updated_at = NOW()
  WHERE id = p_reservation_id;

  INSERT INTO financial_audit_logs
    (entity_type, entity_id, action, actor_id, actor_role, amount, notes)
  VALUES ('reservation', p_reservation_id, 'arrival_verified_by_admin', v_admin_id, 'admin', 0,
    'Admin confirmó presencia del grupo tras revisión — libera pago retenido');

  -- Libera por el punto único (ya pasa el guard porque arrival_verified=true)
  v_release := release_group_earnings_atomic(p_reservation_id, v_admin_id);

  RETURN jsonb_build_object('ok', true, 'release', v_release);
END;
$$;

-- ─── 3. Bloquear el payout (grupo NO probó presencia / no se presentó) ─────────
CREATE OR REPLACE FUNCTION public.admin_block_unverified_payout(p_reservation_id UUID)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_admin_id UUID := auth.uid();
  v_res      RECORD;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = v_admin_id AND role = 'admin') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;

  SELECT payout_status INTO v_res FROM reservations WHERE id = p_reservation_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'not_found'); END IF;
  IF v_res.payout_status = 'released' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'ya_liberado');
  END IF;

  UPDATE reservations SET payout_status = 'blocked', updated_at = NOW()
  WHERE id = p_reservation_id;

  INSERT INTO financial_audit_logs
    (entity_type, entity_id, action, actor_id, actor_role, amount, notes)
  VALUES ('reservation', p_reservation_id, 'payout_blocked_no_arrival', v_admin_id, 'admin', 0,
    'Admin bloqueó el pago: el grupo no probó presencia (sin llegada verificada)');

  RETURN jsonb_build_object('ok', true, 'payout_status', 'blocked');
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_get_unverified_payouts(INT)     TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_verify_arrival_and_release(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_block_unverified_payout(UUID)    TO authenticated;

COMMIT;

-- ── VERIFICACIONES ──────────────────────────────────────────────────────────────
-- V1: las 3 funciones existen, SECURITY DEFINER, gate admin
SELECT proname, prosecdef AS is_security_definer,
       prosrc LIKE '%role = ''admin''%' OR prosrc LIKE '%<> ''admin''%' AS tiene_gate_admin
FROM pg_proc
WHERE proname IN ('admin_get_unverified_payouts','admin_verify_arrival_and_release','admin_block_unverified_payout')
ORDER BY proname;
-- Esperado: 3 filas, is_security_definer=true

-- V2 (read-only): la cola actual — eventos held sin verificar
-- SELECT admin_get_unverified_payouts();

SELECT '452_unverified_payouts_queue.sql ejecutado ✅' AS status;
