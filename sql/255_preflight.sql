-- ============================================================
-- sql/255_preflight.sql
--
-- SOLO LECTURA — cero modificaciones de datos.
-- Validación completa antes de ejecutar sql/255.
--
-- Ejecutar en Supabase SQL Editor como service_role o postgres.
-- Revisar CADA sección antes de autorizar sql/255.
--
-- Si aparece cualquier bloque marcado con ⚠️ REVISAR o ❌ BLOQUEANTE
-- en los resultados, NO proceder con sql/255 hasta resolver.
-- ============================================================


-- ══════════════════════════════════════════════════════════════
-- SECCIÓN 1 — Distribución general de estados
-- Esperado: solo valores dentro de ('draft','pending','approved','rejected')
-- ══════════════════════════════════════════════════════════════

SELECT
  '1 · Distribución de estados' AS seccion,
  status,
  COUNT(*)                       AS total_filas,
  CASE
    WHEN status IN ('draft','pending','approved','rejected')
    THEN '✅ valor válido'
    ELSE '❌ BLOQUEANTE: valor fuera del CHECK constraint'
  END AS validacion
FROM public.verification_requests
GROUP BY status
ORDER BY status;


-- ══════════════════════════════════════════════════════════════
-- SECCIÓN 2 — Referencias rotas a group_id
-- Esperado: 0 filas (todas las filas deben tener un grupo existente)
-- ══════════════════════════════════════════════════════════════

SELECT
  '2 · Referencias rotas' AS seccion,
  vr.id,
  vr.group_id,
  vr.status,
  vr.submitted_at,
  '❌ BLOQUEANTE: group_id no existe en groups' AS validacion
FROM public.verification_requests vr
LEFT JOIN public.groups g ON g.id = vr.group_id
WHERE g.id IS NULL;


-- ══════════════════════════════════════════════════════════════
-- SECCIÓN 3 — NULLs críticos que afectarían a las RPCs
-- Las RPCs de sql/255 dependen de: group_id, status, submitted_at
-- ══════════════════════════════════════════════════════════════

SELECT
  '3 · NULLs críticos' AS seccion,
  COUNT(*) FILTER (WHERE group_id    IS NULL) AS filas_sin_group_id,
  COUNT(*) FILTER (WHERE status      IS NULL) AS filas_sin_status,
  COUNT(*) FILTER (WHERE submitted_at IS NULL) AS filas_sin_submitted_at,
  COUNT(*)                                     AS total_filas,
  CASE
    WHEN COUNT(*) FILTER (WHERE group_id IS NULL) > 0
      OR COUNT(*) FILTER (WHERE status   IS NULL) > 0
    THEN '❌ BLOQUEANTE: existen NULLs en columnas requeridas por RPCs'
    ELSE '✅ sin NULLs críticos'
  END AS validacion
FROM public.verification_requests;


-- ══════════════════════════════════════════════════════════════
-- SECCIÓN 4 — Grupos con más de un pending
-- Esperado idealmente: 0 grupos.
-- Si hay resultados, la limpieza los reducirá a 1 por grupo.
-- ══════════════════════════════════════════════════════════════

SELECT
  '4 · Grupos con múltiples pending' AS seccion,
  group_id,
  COUNT(*) AS filas_pending,
  MIN(submitted_at) AS mas_antigua,
  MAX(submitted_at) AS mas_reciente,
  CASE
    WHEN COUNT(*) > 5
    THEN '⚠️ REVISAR: más de 5 filas pending — revisar historial'
    ELSE '⚠️ deduplicar'
  END AS nota
FROM public.verification_requests
WHERE status = 'pending'
GROUP BY group_id
HAVING COUNT(*) > 1
ORDER BY filas_pending DESC;


-- ══════════════════════════════════════════════════════════════
-- SECCIÓN 5 — Grupos con más de un draft
-- Esperado: 0 grupos (draft es nuevo desde sql/253)
-- ══════════════════════════════════════════════════════════════

SELECT
  '5 · Grupos con múltiples draft' AS seccion,
  group_id,
  COUNT(*) AS filas_draft,
  MIN(submitted_at) AS mas_antigua,
  MAX(submitted_at) AS mas_reciente,
  '⚠️ deduplicar' AS nota
FROM public.verification_requests
WHERE status = 'draft'
GROUP BY group_id
HAVING COUNT(*) > 1
ORDER BY filas_draft DESC;


-- ══════════════════════════════════════════════════════════════
-- SECCIÓN 6 — Grupos con draft Y pending simultáneamente
-- Si existen: el draft será eliminado, el pending conservado.
-- ══════════════════════════════════════════════════════════════

SELECT
  '6 · Draft + pending simultáneos' AS seccion,
  vr.group_id,
  g.name                            AS nombre_grupo,
  COUNT(*) FILTER (WHERE vr.status = 'draft')   AS filas_draft,
  COUNT(*) FILTER (WHERE vr.status = 'pending') AS filas_pending,
  MAX(vr.submitted_at) FILTER (WHERE vr.status = 'draft')   AS draft_mas_reciente,
  MAX(vr.submitted_at) FILTER (WHERE vr.status = 'pending') AS pending_mas_reciente,
  '⚠️ los drafts serán eliminados — el pending es la solicitud activa' AS accion
FROM public.verification_requests vr
JOIN public.groups g ON g.id = vr.group_id
WHERE vr.status IN ('draft','pending')
GROUP BY vr.group_id, g.name
HAVING
  COUNT(*) FILTER (WHERE vr.status = 'draft')   > 0
  AND COUNT(*) FILTER (WHERE vr.status = 'pending') > 0
ORDER BY vr.group_id;


-- ══════════════════════════════════════════════════════════════
-- SECCIÓN 7 — Vista previa: qué filas se CONSERVARÁN
-- Criterio: para cada (group_id, status) se conserva la fila
-- con submitted_at más reciente. En caso de empate, id DESC.
-- ══════════════════════════════════════════════════════════════

WITH ranked AS (
  SELECT
    vr.id,
    vr.group_id,
    g.name              AS nombre_grupo,
    vr.status,
    vr.submitted_at,
    vr.document_url,
    vr.liveness_verified,
    vr.admin_notes,
    ROW_NUMBER() OVER (
      PARTITION BY vr.group_id, vr.status
      ORDER BY vr.submitted_at DESC NULLS LAST, vr.id DESC
    ) AS rn
  FROM public.verification_requests vr
  JOIN public.groups g ON g.id = vr.group_id
  WHERE vr.status IN ('draft','pending')
)
SELECT
  '7 · Filas a CONSERVAR tras limpieza' AS seccion,
  group_id,
  nombre_grupo,
  status,
  id                   AS id_conservado,
  submitted_at,
  document_url IS NOT NULL AS tiene_document_url,
  liveness_verified,
  rn,
  CASE
    WHEN rn = 1 THEN '✅ se conserva'
    ELSE '🗑 se eliminaría'
  END AS decision
FROM ranked
ORDER BY group_id, status, rn;


-- ══════════════════════════════════════════════════════════════
-- SECCIÓN 8 — Resumen cuantitativo de la limpieza
-- ══════════════════════════════════════════════════════════════

WITH ranked_pending AS (
  SELECT
    id,
    group_id,
    ROW_NUMBER() OVER (
      PARTITION BY group_id
      ORDER BY submitted_at DESC NULLS LAST, id DESC
    ) AS rn
  FROM public.verification_requests
  WHERE status = 'pending'
),
drafts_con_pending AS (
  SELECT vr.id
  FROM public.verification_requests vr
  WHERE vr.status = 'draft'
    AND vr.group_id IN (
      SELECT group_id FROM public.verification_requests WHERE status = 'pending'
    )
),
ranked_draft AS (
  SELECT
    id,
    group_id,
    ROW_NUMBER() OVER (
      PARTITION BY group_id
      ORDER BY submitted_at DESC NULLS LAST, id DESC
    ) AS rn
  FROM public.verification_requests
  WHERE status = 'draft'
    AND id NOT IN (SELECT id FROM drafts_con_pending)
)
SELECT
  '8 · Resumen cuantitativo de limpieza' AS seccion,
  (SELECT COUNT(*) FROM drafts_con_pending)            AS drafts_eliminados_por_pending_activo,
  (SELECT COUNT(*) FROM ranked_pending  WHERE rn > 1)  AS pendings_duplicados_a_eliminar,
  (SELECT COUNT(*) FROM ranked_draft    WHERE rn > 1)  AS drafts_duplicados_a_eliminar,
  (SELECT COUNT(*) FROM drafts_con_pending)
    + (SELECT COUNT(*) FROM ranked_pending WHERE rn > 1)
    + (SELECT COUNT(*) FROM ranked_draft   WHERE rn > 1) AS total_filas_a_eliminar,
  (SELECT COUNT(*) FROM public.verification_requests
   WHERE status IN ('approved','rejected'))             AS filas_intactas_historial,
  CASE
    WHEN (SELECT COUNT(*) FROM drafts_con_pending)
       + (SELECT COUNT(*) FROM ranked_pending WHERE rn > 1)
       + (SELECT COUNT(*) FROM ranked_draft   WHERE rn > 1) > 1000
    THEN '⚠️ REVISAR: >1000 filas a eliminar — ejecutar DELETE en lotes'
    ELSE '✅ volumen manejable en un solo DELETE'
  END AS nota_volumen;


-- ══════════════════════════════════════════════════════════════
-- SECCIÓN 9 — Simulación de índices parciales post-limpieza
-- Verifica que después de la limpieza no quedarían conflictos
-- que impidan crear UNIQUE INDEX WHERE status='pending'/'draft'
-- ══════════════════════════════════════════════════════════════

WITH post_cleanup_pending AS (
  SELECT group_id, COUNT(*) AS filas
  FROM public.verification_requests
  WHERE status = 'pending'
    AND id IN (
      SELECT DISTINCT ON (group_id) id
      FROM public.verification_requests
      WHERE status = 'pending'
      ORDER BY group_id, submitted_at DESC NULLS LAST, id DESC
    )
  GROUP BY group_id
),
post_cleanup_draft AS (
  SELECT group_id, COUNT(*) AS filas
  FROM public.verification_requests
  WHERE status = 'draft'
    AND group_id NOT IN (
      SELECT group_id FROM public.verification_requests WHERE status = 'pending'
    )
    AND id IN (
      SELECT DISTINCT ON (group_id) id
      FROM public.verification_requests
      WHERE status = 'draft'
        AND group_id NOT IN (
          SELECT group_id FROM public.verification_requests WHERE status = 'pending'
        )
      ORDER BY group_id, submitted_at DESC NULLS LAST, id DESC
    )
  GROUP BY group_id
)
SELECT
  '9 · Simulación post-limpieza — unicidad de índices' AS seccion,
  (SELECT COUNT(*) FROM post_cleanup_pending WHERE filas > 1) AS grupos_pending_con_conflicto,
  (SELECT COUNT(*) FROM post_cleanup_draft   WHERE filas > 1) AS grupos_draft_con_conflicto,
  CASE
    WHEN (SELECT COUNT(*) FROM post_cleanup_pending WHERE filas > 1) > 0
      OR (SELECT COUNT(*) FROM post_cleanup_draft   WHERE filas > 1) > 0
    THEN '❌ BLOQUEANTE: la limpieza no resuelve todos los conflictos — revisar sección 7'
    ELSE '✅ los índices parciales podrán crearse sin conflicto tras la limpieza'
  END AS validacion;


-- ══════════════════════════════════════════════════════════════
-- SECCIÓN 10 — Resumen ejecutivo de autorización
-- Lee este bloque ÚLTIMO. Si todos los campos dicen ✅, puedes
-- compartir los resultados para generar sql/255.
-- ══════════════════════════════════════════════════════════════

WITH checks AS (
  SELECT
    -- Estados inválidos
    COUNT(*) FILTER (
      WHERE status NOT IN ('draft','pending','approved','rejected')
    ) AS estados_invalidos,
    -- Referencias rotas
    (SELECT COUNT(*)
     FROM public.verification_requests vr
     LEFT JOIN public.groups g ON g.id = vr.group_id
     WHERE g.id IS NULL
    ) AS referencias_rotas,
    -- NULLs críticos
    COUNT(*) FILTER (WHERE group_id IS NULL OR status IS NULL) AS nulls_criticos
  FROM public.verification_requests
)
SELECT
  '10 · Resumen ejecutivo — autorización para sql/255' AS seccion,
  CASE WHEN estados_invalidos  = 0 THEN '✅' ELSE '❌ BLOQUEANTE' END AS estados,
  CASE WHEN referencias_rotas  = 0 THEN '✅' ELSE '❌ BLOQUEANTE' END AS referencias,
  CASE WHEN nulls_criticos      = 0 THEN '✅' ELSE '❌ BLOQUEANTE' END AS nulls,
  CASE
    WHEN estados_invalidos = 0
     AND referencias_rotas = 0
     AND nulls_criticos    = 0
    THEN '✅ datos listos — comparte los resultados para generar sql/255'
    ELSE '❌ NO proceder — resolver bloqueantes primero'
  END AS decision_final
FROM checks;
