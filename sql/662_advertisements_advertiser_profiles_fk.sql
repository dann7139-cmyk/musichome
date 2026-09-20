-- ============================================================================
-- sql/662_advertisements_advertiser_profiles_fk.sql
--
-- advertisements.advertiser_id ya tenía FK a auth.users, pero NINGUNA a
-- public.profiles — descubierto arreglando el panel admin web ("Anuncios"
-- siempre salía vacío). Cualquier consulta que pida el embed profiles(...)
-- sobre advertisements (PostgREST) fallaba por completo, porque no hay
-- forma de resolver esa relación sin una FK directa entre las 2 tablas
-- expuestas. Se agrega esta FK adicional — no reemplaza ni toca la que ya
-- existe a auth.users; profiles.id siempre es un auth.users.id válido en
-- este esquema, así que ambas conviven sin conflicto. 0 filas huérfanas
-- verificadas antes de aplicar (48 anuncios reales en producción).
-- ============================================================================

ALTER TABLE public.advertisements ADD CONSTRAINT advertisements_advertiser_id_profiles_fkey
  FOREIGN KEY (advertiser_id) REFERENCES public.profiles(id) ON DELETE SET NULL;
