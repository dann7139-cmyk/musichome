-- ROLLBACK de sql/662_advertisements_advertiser_profiles_fk.sql
-- Solo quita la FK nueva a profiles — la FK original a auth.users no se toca.
ALTER TABLE public.advertisements DROP CONSTRAINT IF EXISTS advertisements_advertiser_id_profiles_fkey;
