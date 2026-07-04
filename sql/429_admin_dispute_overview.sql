-- ============================================================
-- sql/429_admin_dispute_overview.sql
-- HOTFIX: admin_dispute_overview no existía en prod (sql/186 nunca
-- se corrió) → la pantalla de Disputas del admin (Lote A) fallaba con
-- "Could not find the function ... in the schema cache".
--
-- Definición idéntica a sql/186:184 (firma que DisputesScreen ya
-- llama por nombre: p_status, p_limit, p_offset).
--
-- ⚠️ DIAGNÓSTICO ADICIONAL: sql/186 define MÁS funciones que quizá
-- tampoco existan. Corre esto y pégale el resultado a Fable:
--
--   SELECT unnest(ARRAY['admin_gmv_summary','admin_payout_queue',
--                       'admin_dispute_overview','get_groups_ranked_by_demand',
--                       'update_demand_scores']) AS esperada
--   EXCEPT
--   SELECT proname FROM pg_proc
--   WHERE pronamespace = 'public'::regnamespace;
--   -- Cada fila que salga = función de sql/186 que FALTA en tu DB.
-- ============================================================

CREATE OR REPLACE FUNCTION admin_dispute_overview(
  p_status TEXT DEFAULT 'open',
  p_limit  INT  DEFAULT 50,
  p_offset INT  DEFAULT 0
)
RETURNS TABLE (
  dispute_id     UUID,
  reservation_id UUID,
  event_date     DATE,
  total_price    NUMERIC,
  status         TEXT,
  reason         TEXT,
  opened_by      UUID,
  opener_email   TEXT,
  group_name     TEXT,
  created_at     TIMESTAMPTZ,
  updated_at     TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin') THEN
    RAISE EXCEPTION 'unauthorized: solo admins';
  END IF;

  RETURN QUERY
    SELECT
      d.id,
      d.reservation_id,
      r.event_date,
      r.total_price,
      d.status::TEXT,
      d.reason::TEXT,
      d.opened_by,
      u.email::TEXT,   -- auth.users.email es varchar(255): sin cast,
      g.name::TEXT,    -- RETURN QUERY truena con 42804 (bug latente de sql/186)
      d.created_at,
      d.updated_at
    FROM disputes d
    JOIN reservations r ON r.id = d.reservation_id
    JOIN groups g ON g.id = r.group_id
    JOIN auth.users u ON u.id = d.opened_by
    WHERE (p_status = 'all' OR d.status = p_status)
    ORDER BY d.created_at DESC
    LIMIT p_limit OFFSET p_offset;
END;
$$;

GRANT EXECUTE ON FUNCTION admin_dispute_overview(TEXT, INT, INT) TO authenticated;

-- ── Verificaciones ────────────────────────────────────────────────────────────
-- V1: existe con la firma correcta
SELECT proname, pg_get_function_arguments(oid) AS firma
FROM   pg_proc
WHERE  proname = 'admin_dispute_overview'
  AND  pronamespace = 'public'::regnamespace;
-- Esperado: 1 fila → p_status text DEFAULT 'open', p_limit integer DEFAULT 50,
--                    p_offset integer DEFAULT 0

-- V2 (funcional, disfrazado de admin):
-- BEGIN;
-- SELECT set_config('request.jwt.claims', json_build_object(
--   'sub', (SELECT id::text FROM profiles WHERE role='admin' LIMIT 1),
--   'role','authenticated')::text, true);
-- SELECT * FROM admin_dispute_overview('all', 10, 0);
-- ROLLBACK;

SELECT '429_admin_dispute_overview.sql ejecutado ✅' AS status;
