-- 622_add_espectaculo_mc_categories.sql
-- Pedido 2026-09-05: "Espectáculo" y "Maestro de Ceremonias" existían como
-- opción al REGISTRARSE (RegisterScreen.tsx, GRUPO_CATEGORIES local, nunca
-- sincronizada con providerCategories.ts) pero no existían como categoría
-- en Explorador ni en "Agregar otro proveedor" — alguien registrado así
-- prácticamente no se podía encontrar. Se agregan como categorías reales
-- (providerCategories.ts) y aquí se fija su comportamiento de descansos:
--
-- - "Maestro de Ceremonias" trabaja corrido todo el evento (como
--   Comediante) → sin temporizador de tandas, igual que las demás
--   categorías sin performance musical.
-- - "Espectáculo" (shows/magia/performance) SÍ es una actuación con
--   posibles tandas, igual que un solista → NO se agrega aquí, sigue
--   siendo NULL (el grupo elige su tipo de descanso, como banda/DJ/solista).

CREATE OR REPLACE FUNCTION public.group_default_break_type(p_group_id uuid)
 RETURNS text
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  SELECT CASE
    WHEN g.genre = ANY(ARRAY[
      'Comediante', 'Payasos', 'Comida', 'Maestro de Ceremonias',
      'Renta de brincolines', 'Inflables acuáticos',
      'Renta de mesas', 'Renta de sillas',
      'Fotografía', 'Drones', 'Cabina 360', 'Cabina fotográfica'
    ]) THEN 'D'
    ELSE NULL
  END
  FROM public.groups g WHERE g.id = p_group_id;
$function$;
