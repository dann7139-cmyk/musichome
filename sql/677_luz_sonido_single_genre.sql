-- ============================================================================
-- 677 — Luz y Sonido pasa a ser un solo género "sombrilla"
-- ============================================================================
-- Petición real (2026-09-22): "no quiero que salgan las opciones de abajo
-- como sonido profesional, proyectores... los clientes se meterán a ver
-- cada proveedor de esa categoría y ya eligen el que sea" — Luz y Sonido
-- deja de tener 9 subtipos (Sonido, Iluminación, Cabinas DJ, Iluminación
-- profesional, Micrófonos, Pantallas LED, Proyectores, Sonido profesional)
-- y queda con uno solo: 'Sonido / Iluminación'. Mismo cambio ya aplicado en
-- src/constants/providerCategories.ts y web/src/lib/genreCategories.ts.
-- Confirmado 0 grupos reales registrados con cualquiera de los 9 valores
-- (nada que migrar).
-- ============================================================================

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
    ELSE NULL
  END;
$function$;

COMMIT;
