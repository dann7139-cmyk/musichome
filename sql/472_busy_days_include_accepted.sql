-- ============================================================
-- sql/472_busy_days_include_accepted.sql
-- FIX: el calendario del cliente NO mostraba los días ocupados del grupo.
--
-- Causa (auditoría 2026-07-11): get_group_busy_days filtraba por status
-- 'confirmed', pero las reservas pagadas de la app viven en 'accepted'
-- (flujo real validado). Resultado: los eventos reales eran invisibles.
--
-- Cambio único: incluir 'accepted' (y 'live' por si acaso) en el filtro.
-- La función ya regresa event_time y hours_count — el frontend ahora los
-- usa para mostrar "el grupo tiene evento de X a Y; puedes contratarlo
-- en otro horario" (el grupo puede tocar 2 veces el mismo día).
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_group_busy_days(
  p_group_id UUID,
  p_from     DATE,
  p_to       DATE
)
RETURNS TABLE (
  event_date  DATE,
  event_time  TIME,
  hours_count NUMERIC
)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'unauthorized: sesión requerida';
  END IF;

  RETURN QUERY
    SELECT r.event_date, r.event_time, r.hours_count
    FROM   reservations r
    WHERE  r.group_id   = p_group_id
      AND  r.event_date BETWEEN p_from AND p_to
      AND  r.status IN ('pending','pending_payment','pending_group_confirmation',
                        'accepted','confirmed','in_progress','live')
    ORDER BY r.event_date, r.event_time;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_group_busy_days(UUID, DATE, DATE) TO authenticated;

-- ── VERIFICACIÓN ──────────────────────────────────────────────────────────────
SELECT prosrc LIKE '%''accepted''%' AS incluye_accepted
FROM pg_proc WHERE proname = 'get_group_busy_days';
-- Esperado: true

SELECT '472_busy_days_include_accepted.sql ejecutado ✅' AS status;
