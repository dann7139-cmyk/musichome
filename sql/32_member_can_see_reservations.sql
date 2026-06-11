-- ══════════════════════════════════════════════════════════════════════════════
-- 32_member_can_see_reservations.sql
-- Permite que integrantes aceptados del grupo puedan ver las reservas.
-- Solo SELECT — UPDATE/INSERT sigue siendo solo del owner.
-- Ejecutar en Supabase SQL Editor.
-- ══════════════════════════════════════════════════════════════════════════════

-- ── 1. Función SECURITY DEFINER: verifica membresía del grupo ─────────────────
-- Evita recursión de RLS al consultar job_invitations desde policies de reservations.
CREATE OR REPLACE FUNCTION public.is_group_member(p_group_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.job_invitations
    WHERE group_id    = p_group_id
      AND invited_user_id = auth.uid()
      AND status      = 'accepted'
      AND event_id    IS NULL   -- membresía permanente, no tocadas
  );
$$;

GRANT EXECUTE ON FUNCTION public.is_group_member(UUID) TO authenticated;

-- ── 2. Actualizar RLS de reservations para incluir miembros ───────────────────
-- Primero, verificar que la tabla tiene RLS activo
ALTER TABLE public.reservations ENABLE ROW LEVEL SECURITY;

-- Política de lectura para miembros del grupo
-- (El owner ya tiene su política existente; esta es adicional)
DROP POLICY IF EXISTS "reservations_member_select" ON public.reservations;
CREATE POLICY "reservations_member_select"
  ON public.reservations FOR SELECT
  USING (
    -- Owner del grupo
    public.is_group_owner(group_id)
    OR
    -- Integrante con membresía aceptada
    public.is_group_member(group_id)
    OR
    -- Cliente (el que hizo la reserva)
    client_id = auth.uid()
  );

-- ── 3. Verificación ───────────────────────────────────────────────────────────
SELECT
  polname AS policy,
  polcmd  AS command
FROM pg_policy
WHERE polrelid = 'public.reservations'::regclass
ORDER BY polname;

SELECT 'Miembros pueden ver reservas ✅' AS status;
