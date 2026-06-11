-- ============================================================
-- 217_dispatch_express_request.sql
-- Conecta el backend Express: cuando un cliente crea una request,
-- se buscan los grupos elegibles y se insertan en express_dispatches
-- con una ventana de exclusividad de 3 minutos.
--
-- Ejecutar después de 215_express_dispatch_system.sql y
-- 216_pg_cron_express_locks.sql
-- ============================================================

-- ── 1. Columna de ventana de exclusividad en event_requests ─────────────────
ALTER TABLE public.event_requests
  ADD COLUMN IF NOT EXISTS express_window_until timestamptz DEFAULT NULL;

COMMENT ON COLUMN public.event_requests.express_window_until IS
  'Mientras NOW() < express_window_until la request es exclusiva del canal Express '
  'y NO debe aparecer en el explorador de grupos.';

CREATE INDEX IF NOT EXISTS idx_event_requests_express_window
  ON public.event_requests (express_window_until)
  WHERE express_window_until IS NOT NULL;

-- ── 2. Función principal: dispatch_express_request ──────────────────────────
CREATE OR REPLACE FUNCTION public.dispatch_express_request(
  p_request_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_request          public.event_requests%ROWTYPE;
  v_group_row        RECORD;
  v_dispatched       int  := 0;
  v_window_minutes   int  := 3;   -- ventana de exclusividad Express
  v_max_groups       int  := 10;  -- máximo de dispatches por request
BEGIN

  -- Cargar la request
  SELECT * INTO v_request
  FROM public.event_requests
  WHERE id = p_request_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'request_not_found');
  END IF;

  -- Solo requests abiertas
  IF v_request.status <> 'open' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'request_not_open', 'status', v_request.status);
  END IF;

  -- Buscar grupos elegibles:
  --   - Mismo género
  --   - Misma ciudad O mismo estado (fallback amplio)
  --   - Activos y verificados (is_active = true)
  --   - Sin strikes que los suspendan
  --   - Sin dispatch previo para esta request (idempotente)
  FOR v_group_row IN
    SELECT g.id AS group_id
    FROM public.groups g
    WHERE
      -- Coincidencia de género
      g.genre = v_request.genre

      -- Coincidencia geográfica: ciudad exacta > estado
      AND (
        lower(trim(g.city))  = lower(trim(v_request.location_city))
        OR lower(trim(g.state)) = lower(trim(v_request.location_estado))
      )

      -- Grupo activo
      AND g.is_active = true

      -- No suspendido por strikes
      AND (g.suspended_at IS NULL)

      -- No ha recibido ya un dispatch para esta request
      AND NOT EXISTS (
        SELECT 1 FROM public.express_dispatches ed
        WHERE ed.request_id = p_request_id
          AND ed.group_id   = g.id
      )

    -- Priorizar ciudad exacta, luego rating y verificación
    ORDER BY
      (lower(trim(g.city)) = lower(trim(v_request.location_city))) DESC,
      g.is_verified DESC,
      g.rating DESC NULLS LAST

    LIMIT v_max_groups
  LOOP

    INSERT INTO public.express_dispatches (
      request_id,
      group_id,
      status,
      expires_at
    )
    VALUES (
      p_request_id,
      v_group_row.group_id,
      'pending_broadcast',
      NOW() + (v_window_minutes || ' minutes')::interval
    )
    ON CONFLICT DO NOTHING;

    v_dispatched := v_dispatched + 1;

  END LOOP;

  -- Marcar la ventana de exclusividad en la request
  IF v_dispatched > 0 THEN
    UPDATE public.event_requests
    SET express_window_until = NOW() + (v_window_minutes || ' minutes')::interval
    WHERE id = p_request_id;
  END IF;

  RETURN jsonb_build_object(
    'ok',          true,
    'dispatched',  v_dispatched,
    'request_id',  p_request_id,
    'window_min',  v_window_minutes
  );

END;
$$;

GRANT EXECUTE ON FUNCTION public.dispatch_express_request(uuid) TO authenticated;

-- ── 3. Actualizar get_open_requests_for_group: respetar ventana express ──────
-- Un grupo NO debe ver en el explorador una request que está en su
-- ventana express (tiene express_window_until en el futuro).
CREATE OR REPLACE FUNCTION public.get_open_requests_for_group()
RETURNS SETOF public.event_requests
LANGUAGE sql
SECURITY DEFINER
AS $$
  SELECT er.*
  FROM public.event_requests er
  JOIN public.groups g ON g.genre = er.genre
  WHERE
    g.owner_id      = auth.uid()
    AND er.status   = 'open'
    AND er.expires_at > NOW()
    -- Ocultar si está en ventana de exclusividad Express
    AND (
      er.express_window_until IS NULL
      OR er.express_window_until < NOW()
    )
  ORDER BY er.created_at DESC;
$$;

-- ── 4. Política RLS para grupos: misma exclusividad ──────────────────────────
-- Los grupos solo ven en SELECT las requests que ya salieron de la ventana,
-- excepto las que tienen un dispatch activo para ELLOS.
-- (Las request con dispatch activo ya llegan por ExpressContext → Realtime,
--  no por consulta directa de la tabla.)

-- Primero dropeamos la política anterior si existe
DROP POLICY IF EXISTS "groups_see_open_requests" ON public.event_requests;

CREATE POLICY "groups_see_open_requests"
  ON public.event_requests
  FOR SELECT
  TO authenticated
  USING (
    status = 'open'
    AND expires_at > NOW()
    AND (
      -- Fuera de la ventana express → visible a todos
      express_window_until IS NULL
      OR express_window_until < NOW()
      -- O bien: el grupo que consulta tiene un dispatch activo para esta request
      OR EXISTS (
        SELECT 1
        FROM public.express_dispatches ed
        JOIN public.groups g ON g.id = ed.group_id
        WHERE ed.request_id = event_requests.id
          AND g.owner_id    = auth.uid()
          AND ed.status     NOT IN ('ignored', 'expired', 'taken')
      )
    )
  );

-- ── 5. Verificación ─────────────────────────────────────────────────────────
SELECT
  column_name,
  data_type,
  column_default
FROM information_schema.columns
WHERE table_name = 'event_requests'
  AND column_name = 'express_window_until';

SELECT '217_dispatch_express_request.sql ejecutado ✅' AS status;
