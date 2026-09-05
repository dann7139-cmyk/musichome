-- ============================================================
-- sql/604_photography_no_break_timer.sql
-- APLICADO 2026-09-03.
--
-- PETICIÓN REAL DEL USUARIO: "el que dice multimedia que diga
-- fotógrafos... ese no se como se registre y obvio tampoco lleva
-- temporizador solo por contrato y el cliente pone la hora de inicio
-- para que vea el fotografo como sera el evento."
--
-- Dos cambios, ambos de bajo riesgo porque HOY NO HAY NINGÚN GRUPO
-- registrado bajo ninguno de estos genres (confirmado por consulta
-- directa antes de aplicar):
--
-- 1) Renombrar la categoría raíz "Multimedia" (id 88709623-ae3e-400c-
--    857c-24f89ea0b879) a "Fotógrafos" — es lo que el cliente ve como
--    chip en el Explorador. Sus hijos (Drones, Cabina 360, Cabina
--    fotográfica) no cambian de nombre, solo el chip raíz.
--
-- 2) Igual que Comediante/Payasos/Comida/Renta (sql/603): estos genres
--    también reciben break_type='D' automático al aceptar cotización —
--    MISMO mecanismo ya confirmado con el usuario (pasan por la
--    pantalla de llegada/GPS, cuentan las horas contratadas seguidas,
--    nunca ven horario de descansos). Se incluye tanto "Fotografía"
--    (el fotógrafo como persona, categoría separada anidada bajo
--    "Servicios de evento") como los 3 hijos de "Fotógrafos"
--    (Drones/Cabina 360/Cabina fotográfica) — ninguno es una
--    actuación en vivo con tandas, todos son por contrato.
--
-- Probado en BEGIN...ROLLBACK antes de aplicar (Fotografía->D,
-- Banda->NULL sigue intacto). Ver rollback en el archivo _ROLLBACK.
-- ============================================================

BEGIN;

UPDATE public.categories
SET name = 'Fotógrafos'
WHERE id = '88709623-ae3e-400c-857c-24f89ea0b879' AND name = 'Multimedia';

CREATE OR REPLACE FUNCTION public.group_default_break_type(p_group_id UUID)
RETURNS TEXT LANGUAGE sql STABLE SET search_path TO 'public' AS $function$
  SELECT CASE
    WHEN g.genre = ANY(ARRAY[
      'Comediante', 'Payasos', 'Comida',
      'Renta de brincolines', 'Inflables acuáticos',
      'Renta de mesas', 'Renta de sillas',
      'Fotografía', 'Drones', 'Cabina 360', 'Cabina fotográfica'
    ]) THEN 'D'
    ELSE NULL
  END
  FROM public.groups g WHERE g.id = p_group_id;
$function$;

COMMIT;
