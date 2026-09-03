-- ============================================================
-- sql/595_unique_group_names.sql
-- ✅ APLICADO A PRODUCCIÓN 2026-09-01. Probado antes: 0 grupos duplicados
-- en producción, e insertar un duplicado (con espacios/mismo case) se
-- rechaza correctamente con unique_violation.
--
-- PETICIÓN REAL DEL USUARIO (2026-09-01): que no puedan existir dos
-- grupos con el mismo nombre — cada uno debe ser único.
--
-- Verificado ANTES de escribir esto: CERO grupos duplicados hoy en
-- producción (SELECT LOWER(TRIM(name)), COUNT(*) ... HAVING COUNT(*)>1
-- → 0 filas) — seguro agregar la restricción sin tener que resolver
-- datos existentes primero.
--
-- Índice único sobre LOWER(TRIM(name)) — no distingue mayúsculas/
-- minúsculas ni espacios extra ("Daniel Rivera" y "daniel rivera " se
-- consideran el mismo nombre). No se encontró ninguna pantalla de la
-- app donde el grupo edite su propio nombre hoy — el registro parece
-- ser manual/administrativo — así que esta restricción protege
-- independientemente de por dónde se cree un grupo en el futuro.
-- ============================================================

BEGIN;

CREATE UNIQUE INDEX IF NOT EXISTS groups_name_unique_ci
  ON public.groups (LOWER(TRIM(name)));

COMMIT;

SELECT '595_unique_group_names — APLICADO A PRODUCCIÓN 2026-09-01' AS status;
