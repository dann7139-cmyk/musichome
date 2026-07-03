-- ═══════════════════════════════════════════════════════════════
-- 388 — Historial de no-shows resueltos
--
-- Cambios:
--   1. 3 columnas de auditoría en reservations
--      (admin_no_show_resolved_at, admin_no_show_resolved_by, admin_no_show_notes)
--   2. admin_resolve_no_show reconstruido: guarda quién/cuándo + log financiero
--      (firma cambia a UUID, TEXT, TEXT DEFAULT NULL — se elimina la versión 2-param
--       del 387 para evitar ambigüedad en PostgREST)
--   3. admin_get_no_shows_history: RPC nuevo para listar los ya-resueltos
-- ═══════════════════════════════════════════════════════════════

BEGIN;

-- ─── 1. Columnas de auditoría en reservations ─────────────────────────────────

ALTER TABLE reservations
  ADD COLUMN IF NOT EXISTS admin_no_show_resolved_at  TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS admin_no_show_resolved_by  UUID REFERENCES profiles(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS admin_no_show_notes        TEXT;

-- ─── 2. admin_resolve_no_show — versión actualizada ───────────────────────────
-- Eliminar la versión 2-param (387) para evitar sobrecarga ambigua en PostgREST.

DROP FUNCTION IF EXISTS admin_resolve_no_show(UUID, TEXT);

CREATE OR REPLACE FUNCTION admin_resolve_no_show(
  p_reservation_id UUID,
  p_resolution     TEXT,
  p_notes          TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_id   UUID    := auth.uid();
  v_client_id   UUID;
  v_folio       TEXT;
  v_total_price NUMERIC;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM profiles WHERE id = v_caller_id AND role = 'admin'
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Acceso restringido a administradores');
  END IF;

  IF p_resolution NOT IN ('refunded_100', 'no_refund', 'reviewed') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Resolución inválida');
  END IF;

  SELECT client_id, folio, total_price
  INTO   v_client_id, v_folio, v_total_price
  FROM   reservations
  WHERE  id = p_reservation_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Reserva no encontrada');
  END IF;

  UPDATE reservations
  SET admin_no_show_resolution  = p_resolution,
      admin_no_show_resolved_at = NOW(),
      admin_no_show_resolved_by = v_caller_id,
      admin_no_show_notes       = p_notes
  WHERE id = p_reservation_id;

  -- Registro en audit log financiero
  INSERT INTO financial_audit_logs (
    entity_type, entity_id, action,
    actor_id, actor_role,
    amount, notes
  ) VALUES (
    'reservation', p_reservation_id, 'no_show_resolved',
    v_caller_id, 'admin',
    v_total_price,
    format('resolution=%s%s',
      p_resolution,
      CASE WHEN p_notes IS NOT NULL THEN '. ' || p_notes ELSE '' END
    )
  );

  -- Notificar al cliente solo cuando hay impacto financiero
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

GRANT EXECUTE ON FUNCTION admin_resolve_no_show(UUID, TEXT, TEXT) TO authenticated;

-- ─── 3. admin_get_no_shows_history — nuevo RPC ────────────────────────────────

CREATE OR REPLACE FUNCTION admin_get_no_shows_history(
  p_limit INT DEFAULT 50
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_result JSONB;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin'
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Acceso restringido a administradores');
  END IF;

  SELECT jsonb_build_object(
    'ok',    true,
    'items', COALESCE(
      jsonb_agg(
        jsonb_build_object(
          'id',                        r.id,
          'folio',                     r.folio,
          'event_date',                r.event_date,
          'total_price',               r.total_price,
          'group_name',                g.name,
          'group_id',                  r.group_id,
          'client_name',               p.full_name,
          'admin_no_show_resolution',  r.admin_no_show_resolution,
          'admin_no_show_resolved_at', r.admin_no_show_resolved_at,
          'admin_no_show_notes',       r.admin_no_show_notes,
          'resolver_name',             resolver.full_name,
          'has_strike',                EXISTS (
            SELECT 1 FROM group_strikes gs
            WHERE gs.group_id       = r.group_id
              AND gs.strike_type    = 'no_show'
              AND gs.reservation_id = r.id
          )
        )
        ORDER BY r.admin_no_show_resolved_at DESC
      ),
      '[]'::jsonb
    )
  )
  INTO v_result
  FROM reservations r
  LEFT JOIN groups   g        ON g.id = r.group_id
  LEFT JOIN profiles p        ON p.id = r.client_id
  LEFT JOIN profiles resolver ON resolver.id = r.admin_no_show_resolved_by
  WHERE r.cancellation_type        = 'system_auto'
    AND r.cancel_reason            = 'no_show_grupo'
    AND r.admin_no_show_resolution IS NOT NULL
  LIMIT p_limit;

  RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION admin_get_no_shows_history(INT) TO authenticated;

COMMIT;

-- ═══════════════════════════════════════════════════════════════
-- VERIFICACIONES (ejecutar separado después del COMMIT)
-- ═══════════════════════════════════════════════════════════════

-- V1: las 3 columnas existen en reservations
SELECT column_name, data_type, is_nullable
FROM information_schema.columns
WHERE table_name = 'reservations'
  AND column_name IN (
    'admin_no_show_resolved_at',
    'admin_no_show_resolved_by',
    'admin_no_show_notes'
  )
ORDER BY column_name;
-- Esperado: 3 filas

-- V2: admin_resolve_no_show existe con 3 params y SECURITY DEFINER
SELECT proname, pronargs, prosecdef AS is_security_definer
FROM pg_proc
WHERE proname = 'admin_resolve_no_show';
-- Esperado: 1 fila (solo la versión 3-param), is_security_definer = true

-- V3: admin_get_no_shows_history existe con SECURITY DEFINER y GRANT
SELECT proname, pronargs, prosecdef AS is_security_definer
FROM pg_proc
WHERE proname = 'admin_get_no_shows_history';
-- Esperado: 1 fila, is_security_definer = true
SELECT grantee, privilege_type
FROM information_schema.routine_privileges
WHERE routine_name = 'admin_get_no_shows_history'
  AND grantee = 'authenticated';
-- Esperado: 1 fila con EXECUTE

-- V4: historial solo retorna resueltos (admin_no_show_resolution IS NOT NULL)
-- SELECT admin_get_no_shows_history();
-- Esperado: {"ok": true, "items": [...]} donde cada item tiene admin_no_show_resolution NOT NULL
-- Si aún no hay resueltos → items = []
-- Resolver uno con: SELECT admin_resolve_no_show('UUID-REAL'::UUID, 'reviewed');
-- Luego verificar: ya no aparece en admin_get_no_shows() pero SÍ en admin_get_no_shows_history()
