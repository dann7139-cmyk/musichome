-- ═══════════════════════════════════════════════════════════════════════════
-- ROLLBACK de sql/688 — SOLO en caso de reversión deliberada
-- ═══════════════════════════════════════════════════════════════════════════
--
-- Restaura genre_category_key() EXACTAMENTE a la versión que estaba viva en
-- producción antes de sql/688 (capturada con pg_get_functiondef contra
-- sqgzyipqpewzbnfrtdqk el 2026-09-26, antes de aplicar el parche) y elimina el
-- helper nuevo.
--
-- CONSECUENCIA DE CORRERLO: los géneros compuestos vuelven a clasificar como
-- NULL. Hoy eso afecta a un proveedor real (Grupo AS, 'Norteño/Sierreño'), que
-- volvería a quedar sin categoría del lado servidor. `group_category_key()`
-- (por id de grupo) seguiría devolviendo 'grupo' porque ya parte por "/" desde
-- sql/672 — la pérdida es solo en la clasificación por cadena de género.
--
-- No toca datos, ni el género de ningún proveedor, ni pagos, ni índices
-- (ninguno depende de esta función — verificado en pg_depend antes de sql/688).
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

CREATE OR REPLACE FUNCTION public.genre_category_key(p_genre text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public'
AS $function$
  SELECT CASE
    WHEN p_genre = ANY(ARRAY[
      'Norteño','Sierreño','Norteño-Banda','Versátil','Banda','Mariachi','Rock',
      'Bachata','Balada','Blues','Bolero','Conjunto','Country','Cuartetos','Cumbia',
      'Danzón','Electrónica','Folklore','Gospel','Hip Hop','Jazz','Marimba','Merengue',
      'Pop','R&B','Reggaeton','Salsa','Sextetos','Son Jarocho','Tango','Tríos',
      'Tropical','Trova','Vallenato',
      'Americana','Appalachian','Bluegrass','Cajun','Classical','Dance','Disco','Folk',
      'Funk','Indie','Klezmer','Metal','Motown','Punk','Soul','Southern Rock','Swing','Zydeco'
    ]) THEN 'grupo'
    WHEN p_genre = 'Solistas' THEN 'solista'
    WHEN p_genre = 'DJ' THEN 'dj'
    WHEN p_genre = 'Comediante' THEN 'comediante'
    WHEN p_genre = 'Maestro de Ceremonias' THEN 'mc'
    WHEN p_genre = ANY(ARRAY['Espectáculo','Payasos','Mago','Personajes','Animación']) THEN 'espectaculo'
    WHEN p_genre = 'Sonido / Iluminación' THEN 'luzSonido'
    WHEN p_genre = ANY(ARRAY['Comida','Barra de mixología','Snacks y botanas','Café y postres']) THEN 'comida'
    WHEN p_genre = ANY(ARRAY[
      'Escenarios','Generadores eléctricos','Inflables acuáticos','Plantas de luz',
      'Renta de brincolines','Renta de mesas','Renta de sillas','Renta de toldos','Tarimas'
    ]) THEN 'renta'
    WHEN p_genre = ANY(ARRAY['Fotografía','Drones','Cabina 360','Cabina fotográfica']) THEN 'fotografos'
    WHEN p_genre = 'Terraza' THEN 'terraza'
    ELSE NULL
  END;
$function$;

-- Se borra al final, cuando genre_category_key ya no la referencia.
DROP FUNCTION IF EXISTS public.genre_category_key_exact(text);

COMMIT;
