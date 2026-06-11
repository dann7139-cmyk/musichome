-- ============================================================
-- sql/250_update_invitations_rpc.sql
--
-- Actualiza get_my_job_invitations() para incluir datos de
-- confianza del grupo en cada invitación:
--
--   • is_verified      — badge de verificación
--   • created_at       — antigüedad del grupo en plataforma
--   • completed_events — eventos reales completados (status='completed')
--
-- Backward compatible: todos los campos existentes se conservan.
-- Solo se agregan campos nuevos al objeto 'group'.
-- CREATE OR REPLACE — no rompe la firma existente.
--
-- Único consumidor: src/screens/talent/JobBoardScreen.tsx
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_my_job_invitations()
RETURNS SETOF json
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT json_build_object(
    'id',                      ji.id,
    'event_id',                ji.event_id,
    'proposed_payment_amount', ji.proposed_payment_amount,
    'message',                 ji.message,
    'status',                  ji.status,
    'created_at',              ji.created_at,

    'group', CASE WHEN g.id IS NOT NULL THEN json_build_object(
      -- Campos originales (sin cambios)
      'id',            g.id,
      'name',          g.name,
      'genre',         g.genre,
      'profile_image', g.profile_image,
      'rating',        g.rating,
      'total_reviews', g.total_reviews,
      'members_count', g.members_count,
      -- Campos nuevos para confianza entre usuarios
      'is_verified',      g.is_verified,
      'created_at',       g.created_at,
      'completed_events', COALESCE((
        SELECT COUNT(*)::int
        FROM public.reservations r
        WHERE r.group_id = g.id
          AND r.status = 'completed'
      ), 0)
    ) ELSE NULL END,

    'event', CASE WHEN ev.id IS NOT NULL THEN json_build_object(
      'event_date',  ev.event_date,
      'address',     ev.address,
      'reservations', COALESCE((
        SELECT json_agg(json_build_object(
          'event_time', res.event_time,
          'package', CASE WHEN pk.id IS NOT NULL THEN json_build_object(
            'name',           pk.name,
            'duration_hours', pk.duration_hours
          ) ELSE NULL END
        ))
        FROM public.reservations res
        LEFT JOIN public.packages pk ON pk.id = res.package_id
        WHERE res.event_id = ji.event_id
      ), '[]'::json)
    ) ELSE NULL END
  )
  FROM public.job_invitations ji
  LEFT JOIN public.groups  g  ON g.id  = ji.group_id
  LEFT JOIN public.events  ev ON ev.id = ji.event_id
  WHERE ji.invited_user_id = auth.uid()
  ORDER BY ji.created_at DESC;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_my_job_invitations() TO authenticated;

-- Verificación
SELECT 'RPC get_my_job_invitations actualizada con is_verified, created_at, completed_events ✅' AS status;
