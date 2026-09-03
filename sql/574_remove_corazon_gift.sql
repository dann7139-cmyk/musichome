-- ============================================================
-- sql/574_remove_corazon_gift.sql — quitar "Corazón" ($10/$1) del catálogo
--
-- Soft-delete (active=false), no DELETE — group_gifts históricos siguen
-- apuntando a este gift_id y deben poder seguir mostrándose/auditándose.
-- El picker (GiftPickerModal) ya filtra .eq('active', true), así que
-- desaparece solo de la app sin más cambios.
-- ============================================================

UPDATE public.gift_catalog SET active = false WHERE id = 'cae0d21b-c49e-4ef6-855f-c4f4c8291240'; -- "Corazón" ❤️ ($10 MXN / $1 USD)

SELECT '574_remove_corazon_gift.sql ejecutado ✅' AS status;
