-- ============================================================
-- sql/test_route_history.sql  (SOLO PRUEBAS — no producción)
--
-- Inserta 15 puntos falsos en group_location_history simulando
-- un recorrido realista por la ciudad en las últimas 2 horas,
-- para verificar que "Ver ruta" dibuja bien la polyline.
--
-- Elige automáticamente el grupo:
--   1º preferencia: grupo con GPS real Y reserva activa
--      (es el único caso donde aparece el botón "Ver ruta")
--   2º fallback:    cualquier grupo con GPS real en group_locations
--
-- El recorrido termina EXACTO en la posición actual del grupo,
-- así la cabeza de la ruta conecta con el marcador en vivo.
--
-- LIMPIEZA: ver bloque comentado al final del archivo.
-- ============================================================

DO $$
DECLARE
  v_group_id UUID;
  v_name     TEXT;
  v_lat      DOUBLE PRECISION;
  v_lng      DOUBLE PRECISION;
  v_has_conn BOOLEAN := FALSE;
  pts        INT := 15;
  i          INT;
  t_lat      DOUBLE PRECISION;
  t_lng      DOUBLE PRECISION;
  f          DOUBLE PRECISION;
BEGIN
  -- 1º: grupo con GPS real + reserva activa (donde sí aparece "Ver ruta")
  SELECT r.group_id INTO v_group_id
  FROM public.reservations r
  JOIN public.group_locations gl ON gl.group_id = r.group_id
  WHERE r.status IN ('accepted', 'confirmed', 'in_progress')
    AND r.event_ended_at IS NULL
    AND gl.lat IS NOT NULL
    AND NOT (gl.lat = 0 AND gl.lng = 0)
  ORDER BY gl.last_seen DESC
  LIMIT 1;

  IF v_group_id IS NOT NULL THEN
    v_has_conn := TRUE;
  ELSE
    -- 2º fallback: cualquier grupo con GPS real
    SELECT gl.group_id INTO v_group_id
    FROM public.group_locations gl
    WHERE gl.lat IS NOT NULL
      AND NOT (gl.lat = 0 AND gl.lng = 0)
    ORDER BY gl.last_seen DESC
    LIMIT 1;
  END IF;

  IF v_group_id IS NULL THEN
    RAISE EXCEPTION 'No hay ningún grupo con GPS real en group_locations — abre la app con un usuario de grupo compartiendo ubicación primero';
  END IF;

  SELECT g.name, gl.lat, gl.lng INTO v_name, v_lat, v_lng
  FROM public.groups g
  JOIN public.group_locations gl ON gl.group_id = g.id
  WHERE g.id = v_group_id;

  -- Recorrido sintético: desplazamiento neto ~3.5 km en diagonal con
  -- curvas (sin/cos) + jitter fino — parece calles, no una línea recta.
  -- i=0 → hace 2h (origen tenue), i=14 → ahora (posición actual sólida).
  FOR i IN 0 .. pts - 1 LOOP
    f := i::DOUBLE PRECISION / (pts - 1);                 -- progreso 0 → 1

    t_lat := v_lat
      - 0.020 * (1 - f)                                   -- viene del sur
      + 0.0040 * sin(i * 0.9)                             -- curvas amplias
      + 0.0008 * sin(i * 3.7);                            -- jitter de calle
    t_lng := v_lng
      - 0.028 * (1 - f)                                   -- viene del oeste
      + 0.0050 * cos(i * 0.7)
      + 0.0008 * cos(i * 4.3);

    -- Último punto = posición actual exacta del grupo
    IF i = pts - 1 THEN
      t_lat := v_lat;
      t_lng := v_lng;
    END IF;

    INSERT INTO public.group_location_history (group_id, lat, lng, recorded_at)
    VALUES (
      v_group_id, t_lat, t_lng,
      NOW() - ((pts - 1 - i) * INTERVAL '8.5 minutes')    -- ~2h repartidas
    );
  END LOOP;

  RAISE NOTICE '────────────────────────────────────────────';
  RAISE NOTICE 'Grupo elegido: % (id: %)', v_name, v_group_id;
  RAISE NOTICE 'Reserva activa: %', CASE WHEN v_has_conn THEN 'SÍ ✅' ELSE 'NO ⚠️  — el botón "Ver ruta" solo aparece en grupos con reserva activa' END;
  RAISE NOTICE '15 puntos insertados cubriendo las últimas 2 horas';
  RAISE NOTICE 'Para limpiar: ver bloque al final de este archivo';
  RAISE NOTICE '────────────────────────────────────────────';
END;
$$;

-- Ver lo insertado (copia el group_id del NOTICE de arriba):
-- SELECT id, lat, lng, recorded_at
-- FROM public.group_location_history
-- WHERE group_id = '<GROUP_ID>'
-- ORDER BY recorded_at;

-- ============================================================
-- LIMPIEZA — ejecutar cuando termines de probar:
--
-- DELETE FROM public.group_location_history
-- WHERE group_id = '<GROUP_ID>'
--   AND recorded_at > NOW() - INTERVAL '3 hours';
--
-- Nota: si en esa ventana de 3h hubo puntos REALES del grupo,
-- también se borran — es inofensivo, se regeneran con el próximo
-- update de GPS. Y en el peor caso el cron de retención purga
-- todo lo de más de 48h automáticamente.
-- ============================================================
