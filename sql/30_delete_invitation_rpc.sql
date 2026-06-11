-- ══════════════════════════════════════════════════════════════════════════════
-- 30_delete_invitation_rpc.sql
-- RPC segura para que el dueño del grupo pueda eliminar invitaciones/miembros.
-- Usa SECURITY DEFINER para evitar bloqueos de RLS en grupos.
-- Ejecutar en Supabase SQL Editor.
-- ══════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.delete_group_invitation(p_invitation_id UUID)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_group_id UUID;
BEGIN
  -- Obtener el group_id de la invitación
  SELECT group_id INTO v_group_id
  FROM public.job_invitations
  WHERE id = p_invitation_id;

  IF NOT FOUND THEN
    RETURN json_build_object('error', 'Invitación no encontrada');
  END IF;

  -- Verificar que quien llama es el dueño del grupo
  IF NOT EXISTS (
    SELECT 1 FROM public.groups
    WHERE id = v_group_id AND owner_id = auth.uid()
  ) THEN
    RETURN json_build_object('error', 'Sin permiso');
  END IF;

  -- Eliminar
  DELETE FROM public.job_invitations WHERE id = p_invitation_id;

  RETURN json_build_object('success', true);
END;
$$;

GRANT EXECUTE ON FUNCTION public.delete_group_invitation(UUID) TO authenticated;

SELECT 'RPC delete_group_invitation creada ✅' AS status;
