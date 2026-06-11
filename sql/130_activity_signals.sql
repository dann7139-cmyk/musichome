-- ════════════════════════════════════════════════════════════════════════════
-- 130_activity_signals.sql
-- Sistema de señales de urgencia y actividad basado en datos reales.
--
-- Tablas:
--   group_views       — log de vistas de perfil (ventana de 2 horas)
--
-- Columnas añadidas a groups:
--   is_high_demand    BOOLEAN  — >= 2 reservas activas próximas 30 días
--   last_booked_at    TIMESTAMPTZ — última reserva creada
--
-- Funciones:
--   track_group_view(p_group_id)          — registra vista (fire-and-forget)
--   get_group_activity_snapshot(p_group_id) — badges para GroupDetailScreen
--   update_group_demand_signal()          — trigger en reservations
--
-- Ejecutar DESPUÉS de 129_real_demand.sql
-- ════════════════════════════════════════════════════════════════════════════

-- ── 1. Tabla de vistas recientes ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.group_views (
  id         UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  group_id   UUID        NOT NULL REFERENCES public.groups(id) ON DELETE CASCADE,
  viewed_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_group_views_lookup
  ON public.group_views(group_id, viewed_at DESC);

ALTER TABLE public.group_views ENABLE ROW LEVEL SECURITY;

-- Cualquier usuario autenticado o anónimo puede insertar (fire-and-forget desde el cliente)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'group_views' AND policyname = 'gv_insert_any'
  ) THEN
    CREATE POLICY "gv_insert_any" ON public.group_views
      FOR INSERT TO authenticated, anon WITH CHECK (true);
  END IF;
END $$;

-- ── 2. Columnas de señales precalculadas en groups ───────────────────────────
ALTER TABLE public.groups
  ADD COLUMN IF NOT EXISTS is_high_demand  BOOLEAN     DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS last_booked_at  TIMESTAMPTZ DEFAULT NULL;

-- ── 3. track_group_view: registrar una vista (llamado desde GroupDetailScreen) ──
CREATE OR REPLACE FUNCTION public.track_group_view(p_group_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Insertar vista
  INSERT INTO public.group_views(group_id) VALUES (p_group_id);

  -- Limpiar vistas antiguas de este grupo (> 2 horas) para mantener la tabla pequeña
  DELETE FROM public.group_views
  WHERE group_id = p_group_id
    AND viewed_at < NOW() - INTERVAL '2 hours';
END;
$$;

GRANT EXECUTE ON FUNCTION public.track_group_view(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.track_group_view(UUID) TO anon;

-- ── 4. update_group_demand_signal: trigger en reservations ──────────────────
CREATE OR REPLACE FUNCTION public.update_group_demand_signal()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_group_id      UUID;
  v_upcoming_cnt  INT;
BEGIN
  v_group_id := COALESCE(NEW.group_id, OLD.group_id);
  IF v_group_id IS NULL THEN RETURN NEW; END IF;

  -- Reservas activas de este grupo en los próximos 30 días
  SELECT COUNT(*) INTO v_upcoming_cnt
  FROM public.reservations
  WHERE group_id = v_group_id
    AND status IN (
      'pending', 'pending_payment',
      'pending_group_confirmation', 'confirmed'
    )
    AND event_date >= CURRENT_DATE
    AND event_date <= CURRENT_DATE + INTERVAL '30 days';

  UPDATE public.groups
  SET
    is_high_demand = (v_upcoming_cnt >= 2),
    last_booked_at = CASE
      WHEN TG_OP = 'INSERT' THEN NOW()
      ELSE last_booked_at          -- solo actualizar en nuevo insert, no en cambio de status
    END,
    updated_at     = NOW()
  WHERE id = v_group_id;

  RETURN NEW;

EXCEPTION WHEN OTHERS THEN
  RETURN NEW;  -- nunca bloquear la operación principal
END;
$$;

DROP TRIGGER IF EXISTS trg_update_demand_signal ON public.reservations;
CREATE TRIGGER trg_update_demand_signal
  AFTER INSERT OR UPDATE OF status ON public.reservations
  FOR EACH ROW
  EXECUTE FUNCTION public.update_group_demand_signal();

-- ── 5. get_group_activity_snapshot: señales detalladas para GroupDetailScreen ──
CREATE OR REPLACE FUNCTION public.get_group_activity_snapshot(p_group_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_recent_views   INT := 0;
  v_last_booked    TIMESTAMPTZ;
  v_upcoming_cnt   INT := 0;
  v_badges         JSONB := '[]'::JSONB;
  v_mins_ago       INT;
  v_hours_ago      INT;
BEGIN
  -- Vistas en los últimos 30 minutos (aproximación de "personas viendo ahora")
  SELECT COUNT(*) INTO v_recent_views
  FROM public.group_views
  WHERE group_id  = p_group_id
    AND viewed_at > NOW() - INTERVAL '30 minutes';

  -- Última reserva creada (cualquier estado excepto cancelado)
  SELECT MAX(created_at) INTO v_last_booked
  FROM public.reservations
  WHERE group_id = p_group_id
    AND status NOT IN ('cancelled', 'rejected');

  -- Reservas activas próximas 30 días
  SELECT COUNT(*) INTO v_upcoming_cnt
  FROM public.reservations
  WHERE group_id = p_group_id
    AND status IN (
      'pending', 'pending_payment',
      'pending_group_confirmation', 'confirmed'
    )
    AND event_date >= CURRENT_DATE
    AND event_date <= CURRENT_DATE + INTERVAL '30 days';

  -- Badge: personas viendo ahora (>= 2 para no mostrar "1 persona" = el propio usuario)
  IF v_recent_views >= 2 THEN
    v_badges := v_badges || jsonb_build_array(
      jsonb_build_object(
        'icon',    '👀',
        'message', v_recent_views::TEXT
                   || CASE WHEN v_recent_views = 1 THEN ' persona viendo este grupo'
                           ELSE ' personas viendo este grupo' END
      )
    );
  END IF;

  -- Badge: reservado recientemente (< 24 h)
  IF v_last_booked IS NOT NULL THEN
    v_mins_ago  := GREATEST(1, EXTRACT(EPOCH FROM (NOW() - v_last_booked))::INT / 60);
    v_hours_ago := v_mins_ago / 60;

    IF v_mins_ago < 60 THEN
      v_badges := v_badges || jsonb_build_array(
        jsonb_build_object(
          'icon',    '✅',
          'message', 'Reservado hace ' || v_mins_ago::TEXT || ' min'
        )
      );
    ELSIF v_hours_ago < 24 THEN
      v_badges := v_badges || jsonb_build_array(
        jsonb_build_object(
          'icon',    '✅',
          'message', 'Reservado hace ' || v_hours_ago::TEXT
                     || CASE WHEN v_hours_ago = 1 THEN ' hora' ELSE ' horas' END
        )
      );
    END IF;
  END IF;

  -- Badge: demanda alta / próximos eventos
  IF v_upcoming_cnt >= 3 THEN
    v_badges := v_badges || jsonb_build_array(
      jsonb_build_object(
        'icon',    '🔥',
        'message', 'Alta demanda · ' || v_upcoming_cnt::TEXT || ' eventos próximos'
      )
    );
  ELSIF v_upcoming_cnt >= 1 THEN
    v_badges := v_badges || jsonb_build_array(
      jsonb_build_object(
        'icon',    '📅',
        'message', v_upcoming_cnt::TEXT
                   || CASE WHEN v_upcoming_cnt = 1 THEN ' evento agendado' ELSE ' eventos agendados' END
                   || ' próximamente'
      )
    );
  END IF;

  RETURN jsonb_build_object(
    'badges',         v_badges,
    'recent_views',   v_recent_views,
    'upcoming_count', v_upcoming_cnt,
    'last_booked_at', v_last_booked
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('badges', '[]'::JSONB);
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_group_activity_snapshot(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_group_activity_snapshot(UUID) TO anon;

-- ── 6. Backfill: inicializar señales para grupos existentes ─────────────────
DO $$
DECLARE
  rec RECORD;
  v_cnt INT;
BEGIN
  FOR rec IN
    SELECT DISTINCT group_id FROM public.reservations
    WHERE status IN ('pending','pending_payment','pending_group_confirmation','confirmed')
      AND event_date >= CURRENT_DATE
  LOOP
    SELECT COUNT(*) INTO v_cnt
    FROM public.reservations
    WHERE group_id = rec.group_id
      AND status IN ('pending','pending_payment','pending_group_confirmation','confirmed')
      AND event_date >= CURRENT_DATE
      AND event_date <= CURRENT_DATE + INTERVAL '30 days';

    UPDATE public.groups
    SET
      is_high_demand = (v_cnt >= 2),
      last_booked_at = (
        SELECT MAX(created_at) FROM public.reservations
        WHERE group_id = rec.group_id
          AND status NOT IN ('cancelled','rejected')
      )
    WHERE id = rec.group_id;
  END LOOP;
END $$;

SELECT '130_activity_signals.sql ejecutado ✅' AS status;
SELECT 'Tabla: group_views' AS info
UNION ALL SELECT 'Columnas: groups.is_high_demand, groups.last_booked_at'
UNION ALL SELECT 'Funciones: track_group_view, get_group_activity_snapshot'
UNION ALL SELECT 'Trigger: trg_update_demand_signal en reservations';
