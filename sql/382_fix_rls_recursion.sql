-- ═══════════════════════════════════════════════════════════════
-- 382 — Fix infinite recursion en policies de reservations
-- Causa: WITH CHECK en 207/207b/208 hace subqueries a la misma tabla.
-- Fix: reemplazar con ownership-check simple (sin subqueries a reservations).
-- La protección financiera real la hacen los RPCs con SECURITY DEFINER.
-- Ejecutar en Supabase SQL Editor
-- ═══════════════════════════════════════════════════════════════

BEGIN;

-- ─── DROP de las 3 policies recursivas ────────────────────────────────────────

-- Policy del grupo (creada en 207/207b/208 — puede existir una o varias versiones)
DROP POLICY IF EXISTS "reservations_group_update_safe" ON reservations;

-- Policy del cliente (creada en 208)
DROP POLICY IF EXISTS "reservations_client_reschedule" ON reservations;

-- Versión anterior del 03_rls_policies.sql si aún existe
DROP POLICY IF EXISTS "reservations_group_update" ON reservations;

-- ─── CREATE policies simples sin subqueries a reservations ───────────────────

-- Grupo (dueño): puede actualizar sus reservas.
-- Protección financiera real → RPCs SECURITY DEFINER + triggers.
CREATE POLICY "reservations_group_update_safe"
  ON reservations FOR UPDATE
  USING (
    EXISTS (
      SELECT 1 FROM groups
      WHERE groups.id   = group_id
        AND groups.owner_id = auth.uid()
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM groups
      WHERE groups.id   = group_id
        AND groups.owner_id = auth.uid()
    )
  );

-- Cliente: puede actualizar sus propias reservas (status, notas, etc.).
-- Protección financiera real → RPCs SECURITY DEFINER + triggers.
CREATE POLICY "reservations_client_reschedule"
  ON reservations FOR UPDATE
  USING  (client_id = auth.uid())
  WITH CHECK (client_id = auth.uid());

COMMIT;

-- ═══════════════════════════════════════════════════════════════
-- VERIFICACIONES (ejecutar separado después del COMMIT)
-- ═══════════════════════════════════════════════════════════════

-- V1: no deben quedar policies con subqueries a reservations en WITH CHECK
SELECT policyname, cmd, with_check
FROM pg_policies
WHERE tablename = 'reservations'
  AND with_check ILIKE '%FROM reservations%';
-- Esperado: 0 filas

-- V2: las dos nuevas policies existen con cmd=UPDATE
SELECT policyname, cmd, qual IS NOT NULL AS has_using, with_check IS NOT NULL AS has_check
FROM pg_policies
WHERE tablename = 'reservations'
  AND policyname IN ('reservations_group_update_safe', 'reservations_client_reschedule');
-- Esperado: 2 filas, ambas con has_using=true, has_check=true

-- V3: total de policies activas en reservations (referencia)
SELECT policyname, cmd
FROM pg_policies
WHERE tablename = 'reservations'
ORDER BY policyname;
-- Revisar que no quede ninguna policy huérfana o duplicada

-- V4: prueba funcional — debe ejecutar sin error de recursión
-- (reemplaza el UUID con una reserva real tuya)
-- UPDATE reservations SET status = status WHERE id = 'UUID-REAL'::uuid;
-- Esperado: UPDATE 1 (sin error de infinite recursion)
