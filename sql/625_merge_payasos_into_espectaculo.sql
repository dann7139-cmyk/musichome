-- sql/625_merge_payasos_into_espectaculo.sql
-- Fusiona "Payasos" dentro de la categoría "Shows" (antes "Espectáculo").
--
-- PETICIÓN REAL (2026-09-05): "tipo de show" (payaso, mago, personajes,
-- animación) no debería ser exclusivo de Payasos — son tipos de actuación
-- que deben vivir dentro de una categoría más amplia de shows, junto con
-- Espectáculo. Confirmado con el usuario: Payasos deja de estar forzado a
-- "sin descansos" (ahora elige libremente, igual que Espectáculo); la
-- categoría se llama "Shows".
--
-- No hay NINGÚN grupo real (fuera de datos de prueba) con genre='Payasos'
-- o 'Espectáculo' en producción hoy — cero riesgo de migración de datos.
--
-- HALLAZGO REAL (no pedido, pero misma función): group_category_key()
-- (sql/610) nunca se actualizó cuando se agregaron Espectáculo/Maestro de
-- Ceremonias (sql/622) — hoy devuelve NULL para esos 2 géneros (confirmado
-- con consulta directa). Se corrige aquí de una vez.

-- 1. group_category_key — agrega Espectáculo (ahora incluye Payasos/Mago/
--    Personajes/Animación) y Maestro de Ceremonias, quita Payasos suelto.
CREATE OR REPLACE FUNCTION public.group_category_key(p_group_id uuid)
 RETURNS text
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  SELECT CASE
    WHEN g.genre = ANY(ARRAY[
      'Bachata','Balada','Banda','Blues','Bolero','Corridos','Corridos Tumbados',
      'Country','Cuartetos','Cumbia','Danzón','Electrónica','Folklore','Gospel',
      'Grupero','Grupos musicales','Hip Hop','Huapango','Jazz','Mariachi','Marimba',
      'Merengue','Norteño','Pop','R&B','Ranchero','Reggaeton','Rock','Salsa',
      'Sextetos','Son Jarocho','Tango','Tríos','Tropical','Trova','Vallenato','Versátil'
    ]) THEN 'grupo'
    WHEN g.genre = 'Solistas' THEN 'solista'
    WHEN g.genre = 'DJ' THEN 'dj'
    WHEN g.genre = 'Comediante' THEN 'comediante'
    WHEN g.genre = 'Maestro de Ceremonias' THEN 'mc'
    WHEN g.genre = ANY(ARRAY['Espectáculo','Payasos','Mago','Personajes','Animación']) THEN 'espectaculo'
    WHEN g.genre = ANY(ARRAY[
      'Sonido / Iluminación','Sonido','Iluminación','Cabinas DJ',
      'Iluminación profesional','Micrófonos','Pantallas LED','Proyectores','Sonido profesional'
    ]) THEN 'luzSonido'
    WHEN g.genre = 'Comida' THEN 'comida'
    WHEN g.genre = ANY(ARRAY[
      'Escenarios','Generadores eléctricos','Inflables acuáticos','Plantas de luz',
      'Renta de brincolines','Renta de mesas','Renta de sillas','Renta de toldos','Tarimas'
    ]) THEN 'renta'
    WHEN g.genre = ANY(ARRAY['Fotografía','Drones','Cabina 360','Cabina fotográfica']) THEN 'fotografos'
    ELSE NULL
  END
  FROM public.groups g WHERE g.id = p_group_id;
$function$;

-- 2. group_default_break_type — Payasos ya NO se fuerza a 'D' (sin
--    descansos); ahora elige libremente igual que Espectáculo (NULL).
CREATE OR REPLACE FUNCTION public.group_default_break_type(p_group_id uuid)
 RETURNS text
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  SELECT CASE
    WHEN g.genre = ANY(ARRAY[
      'Comediante', 'Comida', 'Maestro de Ceremonias',
      'Renta de brincolines', 'Inflables acuáticos',
      'Renta de mesas', 'Renta de sillas',
      'Fotografía', 'Drones', 'Cabina 360', 'Cabina fotográfica'
    ]) THEN 'D'
    ELSE NULL
  END
  FROM public.groups g WHERE g.id = p_group_id;
$function$;
