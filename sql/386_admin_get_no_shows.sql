-- ═══════════════════════════════════════════════════════════════
-- 386 — admin_get_no_shows RPC
-- Lista reservas canceladas automáticamente por no presentarse el grupo.
-- Filtro: cancellation_type='system_auto' AND cancel_reason='no_show_grupo'
-- Solo admin puede ejecutar (verificado por role en profiles).
-- SECURITY DEFINER: bypasses RLS en reservations.
-- ═══════════════════════════════════════════════════════════════

BEGIN;

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
          'client_name',   p.full_name
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
  WHERE r.cancellation_type = 'system_auto'
    AND r.cancel_reason     = 'no_show_grupo'
  LIMIT p_limit;

  RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION admin_get_no_shows(INT) TO authenticated;

COMMIT;

-- ═══════════════════════════════════════════════════════════════
-- VERIFICACIONES (ejecutar separado después del COMMIT)
-- ═══════════════════════════════════════════════════════════════

-- V1: función existe con SECURITY DEFINER
SELECT proname, pronargs, prosecdef AS is_security_definer
FROM   pg_proc
WHERE  proname = 'admin_get_no_shows';
-- Esperado: 1 fila, is_security_definer = true

-- V2: GRANT aplicado a authenticated
SELECT grantee, privilege_type
FROM   information_schema.routine_privileges
WHERE  routine_name = 'admin_get_no_shows'
  AND  grantee = 'authenticated';
-- Esperado: 1 fila con privilege_type = 'EXECUTE'

-- V3: llamar como admin y verificar que retorna los no-shows actuales
-- SELECT admin_get_no_shows();
-- Esperado: {"ok": true, "items": [...]} con las reservas de DRC-2026-0003 y similares

-- V4: verificar que un usuario NO admin no puede ejecutar
-- (Cambiar a sesión de cliente y ejecutar)
-- SELECT admin_get_no_shows();
-- Esperado: {"ok": false, "error": "Acceso restringido a administradores"}
