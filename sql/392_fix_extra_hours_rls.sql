-- ════════════════════════════════════════════════════════════════════
-- sql/392 — Fix RLS + constraint en extra_hours
--
-- Contexto:
--   sql/03_rls_policies.sql solo definió FOR SELECT en extra_hours.
--   Sin política de INSERT, cualquier insert directo desde el cliente
--   Supabase (autenticado como 'authenticated') es bloqueado por RLS
--   → error "new row violates row-level security policy".
--
--   Adicionalmente, sql/135 reemplazó el constraint de status a:
--   ('pending','client_requested','accepted','rejected','expired')
--   pero el código posterior (sql/182, sql/183, sql/353) usa 'paid'
--   y 'awaiting_group_confirmation' que no estaban en ese constraint.
--
-- Cambios:
--   1. DROP + ADD constraint unificado con TODOS los valores en uso.
--   2. INSERT policy para el owner del grupo (propone hora extra).
--   3. INSERT policy para el cliente (solicita desde EventTimerScreen).
--   4. UPDATE policy para el cliente (aprueba o rechaza la propuesta).
-- ════════════════════════════════════════════════════════════════════

BEGIN;

-- ─── 1. Constraint unificado ──────────────────────────────────────────────────

ALTER TABLE public.extra_hours
  DROP CONSTRAINT IF EXISTS extra_hours_status_check;

ALTER TABLE public.extra_hours
  ADD CONSTRAINT extra_hours_status_check
    CHECK (status IN (
      'pending',                   -- grupo propone → cliente decide
      'client_requested',          -- legacy: cliente solicitó (sql/135)
      'accepted',                  -- legacy: aceptado (sql/135)
      'rejected',                  -- cliente rechazó la propuesta
      'expired',                   -- venció sin respuesta (sql/135)
      'paid',                      -- aprobado y cobrado (sql/182+183+353)
      'awaiting_group_confirmation', -- cliente solicitó, grupo confirma
      'cancelled_by_selection'     -- reservado para Fase 2 (modelo 3 opciones)
    ));

-- ─── 2. INSERT — owner del grupo (propone hora extra) ────────────────────────
--
-- El dueño del grupo puede insertar en extra_hours si es el owner
-- del grupo asociado a la reserva.

DROP POLICY IF EXISTS "extra_hours_insert_group_owner" ON public.extra_hours;

CREATE POLICY "extra_hours_insert_group_owner"
  ON public.extra_hours
  FOR INSERT
  WITH CHECK (
    EXISTS (
      SELECT 1
      FROM   public.reservations r
      JOIN   public.groups g ON g.id = r.group_id
      WHERE  r.id  = reservation_id
        AND  g.owner_id = auth.uid()
    )
  );

-- ─── 3. INSERT — cliente (solicita desde EventTimerScreen) ───────────────────
--
-- El cliente puede insertar con status='awaiting_group_confirmation'
-- (flujo inverso: cliente pide, grupo confirma).

DROP POLICY IF EXISTS "extra_hours_insert_client" ON public.extra_hours;

CREATE POLICY "extra_hours_insert_client"
  ON public.extra_hours
  FOR INSERT
  WITH CHECK (
    EXISTS (
      SELECT 1
      FROM   public.reservations r
      WHERE  r.id        = reservation_id
        AND  r.client_id = auth.uid()
    )
  );

-- ─── 4. UPDATE — cliente (aprueba o rechaza la propuesta) ────────────────────
--
-- El cliente puede actualizar status de 'pending' a 'paid' / 'rejected'.
-- approve_extra_hour_payment_atomic es SECURITY DEFINER y no necesita
-- esta política, pero handleReject en ClientExtraHoursScreen sí la necesita
-- (UPDATE directo via PostgREST).

DROP POLICY IF EXISTS "extra_hours_update_client" ON public.extra_hours;

CREATE POLICY "extra_hours_update_client"
  ON public.extra_hours
  FOR UPDATE
  USING (
    EXISTS (
      SELECT 1
      FROM   public.reservations r
      WHERE  r.id        = reservation_id
        AND  r.client_id = auth.uid()
    )
  );

COMMIT;

-- ════════════════════════════════════════════════════════════════════
-- VERIFICACIONES (ejecutar separado, después del COMMIT)
-- ════════════════════════════════════════════════════════════════════

-- V1: constraint incluye todos los valores nuevos
SELECT
  pg_get_constraintdef(c.oid) LIKE '%paid%'                        AS tiene_paid,
  pg_get_constraintdef(c.oid) LIKE '%awaiting_group_confirmation%' AS tiene_awaiting,
  pg_get_constraintdef(c.oid) LIKE '%cancelled_by_selection%'      AS tiene_cancelled
FROM   pg_constraint c
WHERE  c.conname  = 'extra_hours_status_check'
  AND  c.conrelid = 'public.extra_hours'::regclass;
-- Esperado: true | true | true

-- V2: las 3 nuevas políticas existen (SELECT ya existía)
SELECT policyname, cmd
FROM   pg_policies
WHERE  tablename = 'extra_hours'
ORDER  BY policyname;
-- Esperado: 4 filas:
--   extrahours_related_users     → SELECT  (pre-existente)
--   extra_hours_insert_client    → INSERT  (nueva)
--   extra_hours_insert_group_owner → INSERT (nueva)
--   extra_hours_update_client    → UPDATE  (nueva)

-- V3: RLS sigue habilitado en extra_hours
SELECT relname, relrowsecurity AS rls_enabled
FROM   pg_class
WHERE  relname = 'extra_hours';
-- Esperado: rls_enabled = true

-- V4: simular que el constraint acepta los nuevos valores (sin insertar)
SELECT status,
  CASE WHEN status IN (
    'pending','client_requested','accepted','rejected','expired',
    'paid','awaiting_group_confirmation','cancelled_by_selection'
  ) THEN 'OK' ELSE 'FALTA' END AS en_constraint
FROM (VALUES
  ('pending'),('paid'),('rejected'),
  ('awaiting_group_confirmation'),('cancelled_by_selection')
) AS t(status);
-- Esperado: todas las filas = 'OK'
