-- ════════════════════════════════════════════════════════════════════════════
-- 148_dynamic_pricing.sql
-- Precios dinámicos sugeridos para cotizaciones.
-- Diferencia entre contratación PROGRAMADA y EXPRESS (tipo Uber).
--
-- FUNCIÓN: get_dynamic_price_suggestion(group_id, city, is_express, event_date, event_time)
--
-- Retorna:
--   · suggested_price_per_hour  — precio sugerido final
--   · base_ref_price            — precio_from del grupo (referencia)
--   · city_avg_price_per_hour   — promedio de cotizaciones aceptadas en la ciudad (90 días)
--   · multiplier                — multiplicador total aplicado
--   · demand_level              — nivel de demanda de la ciudad
--   · is_weekend                — si el evento es viernes/sábado/domingo
--   · is_night                  — si el evento es después de las 20:00
--   · is_express                — tipo de contratación
--   · reasons                   — array de mensajes explicativos
--
-- No modifica ningún precio. Solo sugiere.
-- Ejecutar DESPUÉS de 147_fix_notification_body.sql
-- ════════════════════════════════════════════════════════════════════════════


DROP FUNCTION IF EXISTS public.get_dynamic_price_suggestion(UUID, TEXT, BOOLEAN, DATE, TEXT);

CREATE OR REPLACE FUNCTION public.get_dynamic_price_suggestion(
  p_group_id   UUID,
  p_city       TEXT,
  p_is_express BOOLEAN DEFAULT FALSE,
  p_event_date DATE    DEFAULT NULL,
  p_event_time TEXT    DEFAULT NULL   -- formato 'HH:MM'
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_base_price     NUMERIC(10,2);
  v_city_avg       NUMERIC(10,2);
  v_demand         JSONB;
  v_demand_level   TEXT;
  v_multiplier     NUMERIC(6,4) := 1.0;
  v_is_weekend     BOOLEAN      := FALSE;
  v_is_night       BOOLEAN      := FALSE;
  v_is_urgent      BOOLEAN      := FALSE;
  v_dow            INT;
  v_hour           INT;
  v_suggested      NUMERIC(10,2);
  v_reasons        TEXT[]       := '{}';
BEGIN

  -- ── 1. Precio de referencia del grupo ────────────────────────────────────
  SELECT COALESCE(g.price_from, 0)
  INTO   v_base_price
  FROM   public.groups g
  WHERE  g.id = p_group_id;

  IF v_base_price IS NULL OR v_base_price = 0 THEN
    -- Sin precio de referencia, usar promedio de la ciudad o 1500 como fallback
    v_base_price := 1500;
  END IF;

  -- ── 2. Promedio de cotizaciones aceptadas en la ciudad (últimos 90 días) ─
  SELECT ROUND(AVG(q.price_per_hour), 2)
  INTO   v_city_avg
  FROM   public.quotes q
  JOIN   public.groups g ON g.id = q.group_id
  WHERE  g.city      ILIKE p_city
    AND  q.status    IN ('quoted', 'accepted')
    AND  q.price_per_hour > 0
    AND  q.created_at > now() - INTERVAL '90 days';

  -- Si no hay datos de ciudad, usar el precio base como referencia
  v_city_avg := COALESCE(v_city_avg, v_base_price);

  -- ── 3. Demanda de la ciudad ───────────────────────────────────────────────
  BEGIN
    v_demand       := public.get_city_demand_score(p_city);
    v_demand_level := COALESCE(v_demand->>'demand_level', 'low');
  EXCEPTION WHEN OTHERS THEN
    v_demand_level := 'low';
  END;

  -- ── 4. Multiplicador base según tipo de contratación y demanda ───────────

  IF p_is_express THEN
    -- Express (solicitud inmediata / tipo Uber)
    CASE v_demand_level
      WHEN 'very_high' THEN v_multiplier := 1.60;
      WHEN 'high'      THEN v_multiplier := 1.60;
      WHEN 'normal'    THEN v_multiplier := 1.40;
      ELSE                  v_multiplier := 1.25;  -- low / sin datos
    END CASE;
    v_reasons := array_append(v_reasons, '⚡ Servicio inmediato — puedes cobrar más');
  ELSE
    -- Programada (con anticipación)
    CASE v_demand_level
      WHEN 'very_high' THEN v_multiplier := 1.30;
      WHEN 'high'      THEN v_multiplier := 1.30;
      WHEN 'normal'    THEN v_multiplier := 1.15;
      ELSE                  v_multiplier := 1.00;
    END CASE;
  END IF;

  -- Mensaje de demanda
  IF v_demand_level IN ('very_high', 'high') THEN
    v_reasons := array_append(v_reasons, '🔥 Alta demanda en ' || p_city);
  ELSIF v_demand_level = 'normal' THEN
    v_reasons := array_append(v_reasons, '📈 Demanda media — buen momento');
  END IF;

  -- ── 5. Ajuste de fin de semana (+10%) ─────────────────────────────────────
  IF p_event_date IS NOT NULL THEN
    v_dow := EXTRACT(ISODOW FROM p_event_date)::INT;
    -- 5=viernes, 6=sábado, 7=domingo
    IF v_dow IN (5, 6, 7) THEN
      v_is_weekend := TRUE;
      v_multiplier := v_multiplier * 1.10;
      v_reasons    := array_append(v_reasons, '📅 Fin de semana — mayor valor');
    END IF;

    -- Urgencia express: evento hoy o mañana (+20%)
    IF p_is_express AND p_event_date <= CURRENT_DATE + INTERVAL '1 day' THEN
      v_is_urgent  := TRUE;
      v_multiplier := v_multiplier * 1.20;
      v_reasons    := array_append(v_reasons, '🚨 Último momento — tarifa urgente');
    END IF;
  END IF;

  -- ── 6. Ajuste horario nocturno (+10%) ─────────────────────────────────────
  -- Noche = después de 20:00 o antes de 06:00
  IF p_event_time IS NOT NULL AND p_event_time ~ '^\d{2}:\d{2}$' THEN
    v_hour := SPLIT_PART(p_event_time, ':', 1)::INT;
    IF v_hour >= 20 OR v_hour < 6 THEN
      v_is_night   := TRUE;
      v_multiplier := v_multiplier * 1.10;
      v_reasons    := array_append(v_reasons, '🌙 Horario nocturno — tarifa especial');
    END IF;
  END IF;

  -- ── 7. Ajuste por poca disponibilidad en express (+15%) ──────────────────
  IF p_is_express THEN
    DECLARE v_active_bids INT;
    BEGIN
      SELECT COUNT(*) INTO v_active_bids
      FROM   public.groups g2
      WHERE  g2.city ILIKE p_city
        AND  g2.is_active = TRUE
        AND  (g2.bid_ends_at > now() AND COALESCE(g2.bid_amount, 0) > 0);

      -- Más de 3 grupos con bid activo = competencia, sin ajuste
      -- Menos de 3 = poca oferta = +15%
      IF v_active_bids < 3 THEN
        v_multiplier := v_multiplier * 1.15;
        v_reasons    := array_append(v_reasons, '📉 Poca oferta disponible — alta oportunidad');
      END IF;
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
  END IF;

  -- ── 8. Calcular precio sugerido ───────────────────────────────────────────
  -- Se basa en el precio de referencia del grupo, no en el promedio
  -- para que sea personalizado. El promedio es solo informativo.
  v_suggested := ROUND(v_base_price * v_multiplier, -2);  -- redondear a centenas

  -- Mínimo: no sugerir menos que el promedio si es express
  IF p_is_express AND v_suggested < v_city_avg THEN
    v_suggested := ROUND(v_city_avg * 1.10, -2);
    v_reasons   := array_append(v_reasons, '💡 Ajustado al promedio de tu ciudad');
  END IF;

  -- ── 9. Construir resultado ────────────────────────────────────────────────
  RETURN jsonb_build_object(
    'ok',                       true,
    'suggested_price_per_hour', v_suggested,
    'base_ref_price',           v_base_price,
    'city_avg_price_per_hour',  v_city_avg,
    'multiplier',               ROUND(v_multiplier, 4),
    'demand_level',             v_demand_level,
    'is_weekend',               v_is_weekend,
    'is_night',                 v_is_night,
    'is_express',               p_is_express,
    'is_urgent',                v_is_urgent,
    'reasons',                  to_jsonb(v_reasons)
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object(
    'ok',    false,
    'error', SQLERRM
  );
END;
$$;

-- Grupos y admins autenticados pueden llamar esto
GRANT EXECUTE ON FUNCTION public.get_dynamic_price_suggestion(UUID, TEXT, BOOLEAN, DATE, TEXT)
  TO authenticated, service_role;


SELECT '148_dynamic_pricing.sql ejecutado ✅' AS status;
SELECT 'RPC: get_dynamic_price_suggestion(group_id, city, is_express, event_date, event_time)' AS info;
SELECT 'Multiplicadores: programada x1.0–1.3 | express x1.25–1.6 | fin de semana +10% | noche +10%' AS info;
