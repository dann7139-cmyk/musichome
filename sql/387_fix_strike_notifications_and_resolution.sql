-- ═══════════════════════════════════════════════════════════════
-- 387 — Fix notificaciones de strike + sistema de resolución no-shows
--
-- Cambios:
--   1. Agrega columna admin_no_show_resolution a reservations
--   2. admin_apply_strike_internal → notifica al dueño del grupo
--   3. admin_get_no_shows → excluye ya-resueltos + retorna has_strike
--   4. admin_resolve_no_show → nuevo RPC que marca resolución + notifica cliente
-- ═══════════════════════════════════════════════════════════════

BEGIN;

-- ─── 1. Campo de resolución en reservations ───────────────────────────────────

ALTER TABLE reservations
  ADD COLUMN IF NOT EXISTS admin_no_show_resolution TEXT;

DO $$ BEGIN
  ALTER TABLE reservations ADD CONSTRAINT chk_admin_no_show_resolution
    CHECK (admin_no_show_resolution IN ('refunded_100', 'no_refund', 'reviewed'));
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- ─── 2. admin_apply_strike_internal — agrega notificación al grupo ────────────

CREATE OR REPLACE FUNCTION public.admin_apply_strike_internal(
  p_group_id       UUID,
  p_reservation_id UUID,
  p_strike_type    TEXT,
  p_issued_by      UUID,
  p_note           TEXT DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_new_count    INT;
  v_auto_suspend BOOLEAN := FALSE;
  v_folio        TEXT;
BEGIN
  INSERT INTO group_strikes (group_id, reservation_id, strike_type, issued_by, note)
  VALUES (p_group_id, p_reservation_id, p_strike_type, p_issued_by, p_note);

  UPDATE groups
  SET strike_count   = COALESCE(strike_count, 0) + 1,
      last_strike_at = NOW(),
      updated_at     = NOW()
  WHERE id = p_group_id
  RETURNING strike_count INTO v_new_count;

  -- Obtener folio de la reserva para el mensaje
  IF p_reservation_id IS NOT NULL THEN
    SELECT folio INTO v_folio FROM reservations WHERE id = p_reservation_id;
  END IF;

  -- Notificar al dueño del grupo sobre el strike recibido
  INSERT INTO notifications (user_id, type, title, body, data)
  SELECT
    g.owner_id,
    'admin',
    '⚠️ Has recibido un strike',
    format(
      'Recibiste un strike de tipo "%s"%s. Comunícate con soporte si crees que es un error.',
      p_strike_type,
      CASE WHEN v_folio IS NOT NULL THEN ' (reserva ' || v_folio || ')' ELSE '' END
    ),
    jsonb_build_object(
      'reservation_id', p_reservation_id,
      'strike_type',    p_strike_type
    )
  FROM groups g
  WHERE g.id = p_group_id;

  -- Auto-suspensión al llegar a 3 strikes
  IF v_new_count >= 3 THEN
    UPDATE groups
    SET suspended_at = NOW(),
        suspended_by = p_issued_by,
        updated_at   = NOW()
    WHERE id = p_group_id AND suspended_at IS NULL;

    v_auto_suspend := TRUE;

    UPDATE group_strikes
    SET auto_suspended = TRUE
    WHERE id = (
      SELECT id FROM group_strikes
      WHERE group_id = p_group_id
      ORDER BY created_at DESC
      LIMIT 1
    );

    -- Notificar a los admins sobre la suspensión
    INSERT INTO notifications (user_id, type, title, body, data)
    SELECT
      id, 'admin',
      '🚨 Grupo suspendido automáticamente',
      format('El grupo alcanzó %s strikes y fue suspendido automáticamente.', v_new_count),
      jsonb_build_object('screen', 'Verifications', 'group_id', p_group_id)
    FROM profiles WHERE role = 'admin';
  END IF;

  INSERT INTO financial_audit_logs (
    entity_type, entity_id, action, actor_id, actor_role, notes
  ) VALUES (
    'group', p_group_id, 'strike',
    p_issued_by, 'admin',
    format('Strike "%s" applied. Count now: %s. Auto-suspended: %s',
      p_strike_type, v_new_count, v_auto_suspend)
  );
END;
$$;

-- ─── 3. admin_get_no_shows — excluye resueltos + retorna has_strike ───────────

CREATE OR REPLACE FUNCTION admin_get_no_shows(
  p_limit INT DEFAULT 50
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
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
          'client_name',   p.full_name,
          'has_strike',    EXISTS (
            SELECT 1 FROM group_strikes gs
            WHERE gs.group_id      = r.group_id
              AND gs.strike_type   = 'no_show'
              AND gs.reservation_id = r.id
          )
        )
        ORDER BY r.cancelled_at DESC
      ),
      '[]'::jsonb
    )
  )
  INTO v_result
  FROM reservations r
  LEFT JOIN groups   g ON g.id = r.group_id
  LEFT JOIN profiles p ON p.id = r.client_id
  WHERE r.cancellation_type          = 'system_auto'
    AND r.cancel_reason              = 'no_show_grupo'
    AND r.admin_no_show_resolution   IS NULL
  LIMIT p_limit;

  RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION admin_get_no_shows(INT) TO authenticated;

-- ─── 4. admin_resolve_no_show — nuevo RPC ─────────────────────────────────────

CREATE OR REPLACE FUNCTION admin_resolve_no_show(
  p_reservation_id UUID,
  p_resolution     TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_role TEXT;
  v_client_id   UUID;
  v_folio       TEXT;
BEGIN
  SELECT role INTO v_caller_role FROM profiles WHERE id = auth.uid();

  IF v_caller_role <> 'admin' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Acceso restringido a administradores');
  END IF;

  IF p_resolution NOT IN ('refunded_100', 'no_refund', 'reviewed') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Resolución inválida');
  END IF;

  SELECT client_id, folio
  INTO   v_client_id, v_folio
  FROM   reservations
  WHERE  id = p_reservation_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Reserva no encontrada');
  END IF;

  UPDATE reservations
  SET admin_no_show_resolution = p_resolution
  WHERE id = p_reservation_id;

  -- Notificar al cliente (solo para resoluciones con impacto financiero)
  IF v_client_id IS NOT NULL AND p_resolution <> 'reviewed' THEN
    INSERT INTO notifications (user_id, type, title, body, data)
    VALUES (
      v_client_id,
      'reservation',
      CASE p_resolution
        WHEN 'refunded_100' THEN '💚 Tu dinero fue reembolsado'
        WHEN 'no_refund'    THEN '⚠️ Evento cancelado sin reembolso'
      END,
      CASE p_resolution
        WHEN 'refunded_100' THEN format(
          'El grupo no se presentó a tu evento%s. Hemos procesado el reembolso total. Disculpa los inconvenientes.',
          CASE WHEN v_folio IS NOT NULL THEN ' (' || v_folio || ')' ELSE '' END
        )
        WHEN 'no_refund' THEN format(
          'El grupo no se presentó a tu evento%s. Por política de la plataforma no aplica reembolso en este caso. Comunícate con soporte para más información.',
          CASE WHEN v_folio IS NOT NULL THEN ' (' || v_folio || ')' ELSE '' END
        )
      END,
      jsonb_build_object('reservation_id', p_reservation_id)
    );
  END IF;

  RETURN jsonb_build_object('ok', true, 'resolution', p_resolution);
END;
$$;

GRANT EXECUTE ON FUNCTION admin_resolve_no_show(UUID, TEXT) TO authenticated;

COMMIT;

-- ═══════════════════════════════════════════════════════════════
-- VERIFICACIONES (ejecutar separado después del COMMIT)
-- ═══════════════════════════════════════════════════════════════

-- V1: columna admin_no_show_resolution existe con constraint correcto
SELECT column_name, data_type, is_nullable
FROM information_schema.columns
WHERE table_name = 'reservations' AND column_name = 'admin_no_show_resolution';
-- Esperado: 1 fila, data_type = 'text', is_nullable = 'YES'

-- V2: las 3 funciones existen con SECURITY DEFINER
SELECT proname, prosecdef AS is_security_definer
FROM pg_proc
WHERE proname IN ('admin_apply_strike_internal', 'admin_get_no_shows', 'admin_resolve_no_show');
-- Esperado: 3 filas, todas con is_security_definer = true

-- V3: admin_get_no_shows retorna solo los sin resolución
-- SELECT admin_get_no_shows();
-- Esperado: items sin admin_no_show_resolution; has_strike correcto por reserva

-- V4: admin_resolve_no_show marca la resolución y la saca de admin_get_no_shows
-- SELECT admin_resolve_no_show('UUID-REAL'::UUID, 'reviewed');
-- Luego: SELECT admin_get_no_shows(); → la reserva ya NO debe aparecer
-- También: SELECT admin_no_show_resolution FROM reservations WHERE id = 'UUID-REAL';
-- Esperado: 'reviewed'
