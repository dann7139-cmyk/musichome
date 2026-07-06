-- ============================================================
-- sql/447_add_phones_to_no_shows.sql
-- Agrega teléfonos (grupo + cliente) a admin_get_no_shows para que el
-- ADMIN pueda marcarles antes de resolver (reembolsar / strike / cerrar).
--
-- Fuentes (mismo patrón que 426/446):
--   · Cliente: profiles.phone  (client_id → profiles)
--   · Grupo:   profiles.phone del OWNER (groups.owner_id → profiles)
--
-- Basado en el pg_get_functiondef VIVO de prod (lección 429): la versión
-- real trae `has_strike` y el filtro `admin_no_show_resolution IS NULL`
-- que NO están en el repo (sql/386). Se conservan TAL CUAL; solo se añade
-- el JOIN al owner y los 2 campos de teléfono.
--
-- SOLO admin (gate + SECURITY DEFINER). Read-only. NO toca payout/wallet,
-- NO toca el candado GPS ni el release del 50%. Los teléfonos NO se
-- exponen a otros usuarios.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.admin_get_no_shows(p_limit integer DEFAULT 50)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
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
          'group_phone',   po.phone,       -- [447] teléfono del owner del grupo
          'client_name',   p.full_name,
          'client_phone',  p.phone,        -- [447] teléfono del cliente
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
  LEFT JOIN groups   g  ON g.id  = r.group_id
  LEFT JOIN profiles po ON po.id = g.owner_id   -- [447] owner del grupo (para su teléfono)
  LEFT JOIN profiles p  ON p.id  = r.client_id
  WHERE r.cancellation_type          = 'system_auto'
    AND r.cancel_reason              = 'no_show_grupo'
    AND r.admin_no_show_resolution   IS NULL
  LIMIT p_limit;

  RETURN v_result;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_get_no_shows(integer) TO authenticated;

COMMIT;

-- ── VERIFICACIONES (correr por separado después del COMMIT) ─────────────────────
-- V1: trae teléfonos, conserva has_strike y el filtro de resolución, read-only
SELECT
  prosecdef                                       AS is_security_definer,
  prosrc LIKE '%group_phone%'                      AS trae_tel_grupo,          -- true
  prosrc LIKE '%client_phone%'                     AS trae_tel_cliente,        -- true
  prosrc LIKE '%g.owner_id%'                        AS join_owner,             -- true
  prosrc LIKE '%has_strike%'                        AS conserva_has_strike,    -- true
  prosrc LIKE '%admin_no_show_resolution%IS NULL%'  AS conserva_filtro_resol,  -- true
  prosrc NOT LIKE '%UPDATE %'                        AS solo_lectura           -- true
FROM pg_proc
WHERE proname = 'admin_get_no_shows';
-- Esperado: true | true | true | true | true | true | true

-- V2: preview — cola con teléfonos
-- SELECT admin_get_no_shows();
-- Esperado: items[] con group_phone y client_phone (o null si el perfil no tiene).

SELECT '447_add_phones_to_no_shows.sql ejecutado ✅' AS status;
