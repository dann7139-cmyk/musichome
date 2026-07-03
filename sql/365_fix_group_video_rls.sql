-- 365_fix_group_video_rls.sql
-- Asegura que el dueño del grupo puede actualizar promo_video y video_status
-- en su propio registro. El update directo desde el cliente ya funciona si
-- la política RLS de UPDATE en groups cubre todas las columnas.
--
-- Si el update directo da error de permisos, ejecutar este SQL en Supabase.

-- Política UPDATE para groups: el owner puede actualizar su propio grupo
DROP POLICY IF EXISTS "group_owner_update" ON groups;
CREATE POLICY "group_owner_update"
  ON groups FOR UPDATE
  USING (owner_id = auth.uid())
  WITH CHECK (owner_id = auth.uid());

-- También recrear el RPC como respaldo (SECURITY DEFINER omite RLS)
DROP FUNCTION IF EXISTS update_group_video(uuid, text);
CREATE OR REPLACE FUNCTION update_group_video(p_group_id uuid, p_video_url text)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE groups
  SET promo_video   = p_video_url,
      video_status  = 'pending'
  WHERE id = p_group_id;

  IF NOT FOUND THEN
    RETURN json_build_object('ok', false, 'error', 'Grupo no encontrado');
  END IF;

  RETURN json_build_object('ok', true);
END;
$$;
