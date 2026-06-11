-- ============================================================
-- sql/221_get_my_invitations_rpc.sql
-- Crea get_my_job_invitations() — SECURITY DEFINER.
--
-- Por qué: la consulta directa a job_invitations puede devolver
-- filas vacías si alguna política RLS en la cadena de joins
-- (job_invitations → groups → events → reservations) tiene un
-- problema silencioso. Al usar SECURITY DEFINER, los joins
-- bypasean RLS pero el filtro WHERE usa auth.uid() explícitamente,
-- por lo que el talento solo puede ver SUS propias invitaciones.
--
-- Ejecutar en: Supabase Dashboard → SQL Editor
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
      'id',            g.id,
      'name',          g.name,
      'genre',         g.genre,
      'profile_image', g.profile_image,
      'rating',        g.rating,
      'total_reviews', g.total_reviews,
      'members_count', g.members_count
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

-- Verificación: debe devolver filas para el usuario logueado
-- SELECT * FROM get_my_job_invitations();

SELECT 'RPC get_my_job_invitations creado ✅' AS status;
