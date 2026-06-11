-- ════════════════════════════════════════════════════════════════════════════
-- 129_real_demand.sql
-- Demanda real por ciudad: solicitudes activas vs grupos disponibles.
--
-- get_city_demand(p_city)
--   Calcula demanda real consultando reservas y grupos en esa ciudad.
--   Usado en BookingScreen para mostrar "Alta demanda en tu zona" SOLO
--   cuando hay datos reales que lo justifiquen.
--
-- Ejecutar DESPUÉS de 128_referral_system.sql
-- ════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.get_city_demand(p_city TEXT DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_active_requests  INT := 0;
  v_available_groups INT := 0;
  v_ratio            NUMERIC;
  v_demand_level     TEXT;
  v_message          TEXT;
  v_surcharge_rate   NUMERIC := 0;
BEGIN
  IF p_city IS NULL OR TRIM(p_city) = '' THEN
    -- Sin ciudad → demanda nacional genérica (media, sin ajuste)
    RETURN jsonb_build_object(
      'demand_level',     'medium',
      'active_requests',  0,
      'available_groups', 0,
      'message',          'Disponibilidad normal',
      'surcharge_rate',   0
    );
  END IF;

  -- Reservas activas en los próximos 30 días en esa ciudad
  SELECT COUNT(*) INTO v_active_requests
  FROM public.reservations r
  JOIN public.groups g ON g.id = r.group_id
  WHERE (
      g.location ILIKE '%' || p_city || '%'
      OR g.city   ILIKE '%' || p_city || '%'
    )
    AND r.status IN ('pending', 'pending_payment', 'pending_group_confirmation', 'confirmed')
    AND r.event_date >= CURRENT_DATE
    AND r.event_date <= CURRENT_DATE + INTERVAL '30 days';

  -- Grupos activos en esa ciudad
  SELECT COUNT(*) INTO v_available_groups
  FROM public.groups g
  WHERE (
      g.location ILIKE '%' || p_city || '%'
      OR g.city   ILIKE '%' || p_city || '%'
    )
    AND g.is_active = true;

  -- Calcular ratio y clasificar
  IF v_available_groups = 0 THEN
    v_demand_level := 'medium';
    v_message      := 'Disponibilidad normal en tu zona';
    v_surcharge_rate := 0;
  ELSE
    v_ratio := v_active_requests::NUMERIC / v_available_groups;

    IF v_ratio >= 1.5 THEN
      v_demand_level   := 'high';
      v_message        := 'Alta demanda en tu zona · Los grupos se agendan rápido';
      v_surcharge_rate := 0;   -- La info es solo para mostrar al usuario, no ajustamos precio
    ELSIF v_ratio <= 0.3 THEN
      v_demand_level   := 'low';
      v_message        := 'Amplia disponibilidad en tu zona';
      v_surcharge_rate := 0;
    ELSE
      v_demand_level   := 'medium';
      v_message        := 'Disponibilidad normal en tu zona';
      v_surcharge_rate := 0;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'demand_level',     v_demand_level,
    'active_requests',  v_active_requests,
    'available_groups', v_available_groups,
    'message',          v_message,
    'surcharge_rate',   v_surcharge_rate
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object(
    'demand_level',     'medium',
    'active_requests',  0,
    'available_groups', 0,
    'message',          'Disponibilidad normal',
    'surcharge_rate',   0
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_city_demand(TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_city_demand(TEXT) TO anon;

SELECT '129_real_demand.sql ejecutado ✅' AS status;
SELECT 'Función: get_city_demand(p_city)' AS info;
