-- ============================================================
-- sql/513_f1_audit.sql — F1 PASO 1: AUDITORÍA (SOLO LECTURA)
--
-- Diseño v2 aprobado 2026-07-19. Este archivo NO modifica nada.
-- Calcula los rangos de ocupación que TENDRÍA cada reserva con el
-- modelo nuevo (montaje 30' + duración + extras×75' + desmontaje 30'
-- + margen 15') y reporta todo lo incompatible ANTES de crear
-- cualquier objeto.
--
-- Ejecuta el archivo completo y pásame los 5 resultados.
-- ============================================================

-- Rangos candidatos de las reservas OCUPANTES (estados del diseño v2)
WITH ocupantes AS (
  SELECT
    r.id, r.folio, r.group_id, g.name AS grupo, r.status,
    r.event_date, r.event_time, r.hours_count,
    g.state AS grupo_estado, g.country AS grupo_pais,
    -- Zona horaria estimada (misma lógica que usará tz_for_event)
    CASE
      WHEN g.country = 'Estados Unidos' THEN 'America/Chicago'
      WHEN g.country = 'Canadá'         THEN 'America/Toronto'
      WHEN g.state IN ('Baja California')                    THEN 'America/Tijuana'
      WHEN g.state IN ('Sonora')                              THEN 'America/Hermosillo'
      WHEN g.state IN ('Quintana Roo')                        THEN 'America/Cancun'
      WHEN g.state IN ('Baja California Sur','Sinaloa','Nayarit') THEN 'America/Mazatlan'
      WHEN g.state IN ('Chihuahua')                           THEN 'America/Chihuahua'
      ELSE 'America/Mexico_City'
    END AS tz,
    COALESCE((SELECT COUNT(*) FROM extra_hours eh
              WHERE eh.reservation_id = r.id
                AND eh.status IN ('accepted','paid')), 0) AS extras
  FROM reservations r
  LEFT JOIN groups g ON g.id = r.group_id
  WHERE r.status IN ('pending','pending_payment','pending_group_confirmation',
                     'accepted','confirmed','in_progress','live')
),
rangos AS (
  SELECT o.*,
    tstzrange(
      ((o.event_date + COALESCE(o.event_time, TIME '17:00'))
         AT TIME ZONE o.tz) - INTERVAL '30 minutes',
      ((o.event_date + COALESCE(o.event_time, TIME '17:00'))
         AT TIME ZONE o.tz)
        + (GREATEST(COALESCE(o.hours_count,3),1) * INTERVAL '1 hour')
        + (o.extras * INTERVAL '75 minutes')
        + INTERVAL '45 minutes',
      '[)'
    ) AS busy_range
  FROM ocupantes o
)

-- ── RESULTADO 1: TRASLAPES reales entre ocupantes del mismo grupo ──
SELECT '1_TRASLAPES' AS reporte,
  a.grupo, a.folio AS folio_a, a.status AS status_a,
  a.event_date AS fecha_a, a.event_time AS hora_a,
  b.folio AS folio_b, b.status AS status_b,
  b.event_date AS fecha_b, b.event_time AS hora_b
FROM rangos a
JOIN rangos b ON b.group_id = a.group_id AND b.id > a.id
             AND a.busy_range && b.busy_range;

-- ── RESULTADO 2: días con MÁS de 2 ocupantes (violarían el límite) ──
WITH ocupantes AS (
  SELECT r.id, r.group_id, g.name AS grupo, r.event_date, r.status
  FROM reservations r LEFT JOIN groups g ON g.id = r.group_id
  WHERE r.status IN ('pending','pending_payment','pending_group_confirmation',
                     'accepted','confirmed','in_progress','live','completed')
)
SELECT '2_MAS_DE_2_POR_DIA' AS reporte,
  grupo, event_date, COUNT(*) AS eventos,
  STRING_AGG(status, ', ') AS estados
FROM ocupantes
GROUP BY group_id, grupo, event_date
HAVING COUNT(*) > 2
ORDER BY eventos DESC;

-- ── RESULTADO 3: ocupantes con DATOS INCOMPLETOS para el rango ──
SELECT '3_DATOS_INCOMPLETOS' AS reporte,
  g.name AS grupo, r.folio, r.status, r.event_date,
  CASE WHEN r.event_time IS NULL THEN 'SIN HORA (se asumiría 17:00)' END AS falta_hora,
  CASE WHEN r.hours_count IS NULL THEN 'SIN DURACIÓN (se asumiría 3h)' END AS falta_duracion,
  CASE WHEN g.state IS NULL THEN 'GRUPO SIN ESTADO (tz por país)' END AS falta_estado
FROM reservations r
LEFT JOIN groups g ON g.id = r.group_id
WHERE r.status IN ('pending','pending_payment','pending_group_confirmation',
                   'accepted','confirmed','in_progress','live')
  AND (r.event_time IS NULL OR r.hours_count IS NULL OR g.state IS NULL);

-- ── RESULTADO 4: ocupantes ZOMBIS (fecha ya pasó y siguen "vivos") ──
SELECT '4_ZOMBIS' AS reporte,
  g.name AS grupo, r.folio, r.status, r.event_date, r.payment_status
FROM reservations r
LEFT JOIN groups g ON g.id = r.group_id
WHERE r.status IN ('pending','pending_payment','pending_group_confirmation','accepted','confirmed')
  AND r.event_date < (NOW() AT TIME ZONE 'America/Mexico_City')::date - 1
ORDER BY r.event_date;

-- ── RESULTADO 5: RESUMEN ──
SELECT '5_RESUMEN' AS reporte,
  (SELECT COUNT(*) FROM reservations WHERE status IN
    ('pending','pending_payment','pending_group_confirmation',
     'accepted','confirmed','in_progress','live'))                 AS ocupantes_vivos,
  (SELECT COUNT(*) FROM reservations WHERE status = 'completed')   AS completadas,
  (SELECT COUNT(*) FROM extra_hours WHERE status IN ('accepted','paid')) AS extras_confirmadas,
  (SELECT COUNT(*) FROM group_unavailability)                      AS bloqueos_manuales,
  (SELECT COUNT(*) FROM pg_extension WHERE extname = 'btree_gist') AS btree_gist_instalada;
-- btree_gist_instalada: 0 = habrá que crearla en el paso del constraint (normal)
