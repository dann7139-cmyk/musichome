-- ═══════════════════════════════════════════════════════════════════════════
-- sql/688 — genre_category_key() entiende géneros compuestos ("Norteño/Sierreño")
-- ═══════════════════════════════════════════════════════════════════════════
--
-- PROBLEMA REAL (verificado en producción, no supuesto).
-- `groups.genre` es texto libre y desde sql/672 la app permite guardar más de un
-- estilo separado por "/". Hoy existe un proveedor real así:
--
--   Grupo AS — genre = 'Norteño/Sierreño' — Jalisco — activo
--
-- `genre_category_key(p_genre)` compara la CADENA COMPLETA con
-- `= ANY(ARRAY[...])`. 'Norteño/Sierreño' no es miembro literal de ningún
-- arreglo, así que cae al `ELSE NULL`:
--
--   genre_category_key('Norteño/Sierreño')  →  NULL      ← el bug
--   genre_matches('Norteño/Sierreño','Norteño')  → true  (ya correcto, sql/672)
--   group_category_key(<id de Grupo AS>)    →  'grupo'   (ya correcto, sql/672)
--
-- Es decir: el proyecto YA tiene la solución para géneros compuestos, aplicada
-- en `group_category_key()` (parte por "/" y toma la primera parte que
-- clasifica) y en `genre_in_list()`/`genre_matches()` (mismo `string_to_array`).
-- El único punto que quedó comparando la cadena entera es
-- `genre_category_key()` cuando se le pasa el género crudo.
--
-- SOLUCIÓN — GENERAL, sin casos especiales.
-- No se menciona 'Norteño/Sierreño' en ninguna parte ni se toca el género
-- guardado de ningún proveedor. Se reutiliza EXACTAMENTE el patrón que ya
-- funciona en `group_category_key()`:
--   1. `genre_category_key_exact()` — helper nuevo con el CUERPO ACTUAL, copiado
--      textual de producción (pg_get_functiondef, 2026-09-26). Clasifica una
--      sola etiqueta por igualdad exacta.
--   2. `genre_category_key()` = COALESCE(exacto(cadena completa),
--                                        primera parte que clasifique).
--      La primera rama garantiza que TODO género simple se comporte byte por
--      byte igual que hoy. La segunda solo entra cuando la primera dio NULL.
--
-- POR QUÉ ES SEGURO (verificado antes de escribir esto):
--   · 0 índices y 0 constraints dependen de genre_category_key (pg_depend).
--     Es IMMUTABLE, así que había que comprobarlo — no lo es por suposición.
--   · Solo 2 funciones la llaman:
--       - `group_category_key()`: ya le pasa partes sueltas → sin cambio.
--       - `dispatch_express_request()`: la usa como
--         `genre_category_key(g.genre) IS DISTINCT FROM 'comida'` y
--         `... IS DISTINCT FROM 'terraza'`, o sea EXCLUYE comida y terrazas del
--         despacho Express. Para Grupo AS pasa de NULL a 'grupo':
--         `NULL IS DISTINCT FROM 'comida'` = true y
--         `'grupo' IS DISTINCT FROM 'comida'` = true → **sigue incluido**,
--         cero cambio de comportamiento. Y si algún día existiera un compuesto
--         que empiece por comida/terraza, hoy se colaría al Express por el NULL
--         y con este arreglo quedaría correctamente excluido — el cambio solo
--         puede mejorar la clasificación, nunca perderla.
--   · Firma idéntica (1 parámetro text, RETURNS text, IMMUTABLE, search_path),
--     así que CREATE OR REPLACE reemplaza de verdad y NO crea overload.
--     Los ACL se preservan con OR REPLACE.
--
-- ORDEN entre partes: gana la PRIMERA parte que clasifique, leyendo de
-- izquierda a derecha. Es la misma regla de `group_category_key()`, aquí hecha
-- explícita con WITH ORDINALITY para que el orden sea determinista y no dependa
-- del plan del motor.
--
-- QUÉ NO HACE: no toca datos, no cambia el género de ningún proveedor, no toca
-- pagos, Stripe, Conekta, MSI, wallets, payouts, retiros, comisiones,
-- reembolsos, reservas ni cotizaciones.
--
-- Orden: correr DESPUÉS de sql/687. Probar con sql/689 (autorevertible).
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

-- ── 1. Helper: clasificación por igualdad exacta de UNA etiqueta ────────────
-- Cuerpo copiado textual de la genre_category_key viva en producción
-- (incluye ya los cambios de sql/673 Amenidades, 677 Luz y Sonido, 681 Terraza).
CREATE OR REPLACE FUNCTION public.genre_category_key_exact(p_genre text)
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

COMMENT ON FUNCTION public.genre_category_key_exact(text) IS
  'sql/688 — clasifica UNA etiqueta de género por igualdad exacta. Es el cuerpo que genre_category_key() tenía hasta sql/687. Para clasificar un groups.genre (que puede ser compuesto, "Norteño/Sierreño") usar genre_category_key(), no esta.';

-- ── 2. genre_category_key(): exacto primero, luego por partes ───────────────
-- OJO: "Sonido / Iluminación" contiene una "/" y es un género SIMPLE legítimo.
-- Por eso la primera rama (igualdad exacta sobre la cadena completa) tiene que
-- ir ANTES de partir por "/": si se partiera primero, quedaría 'Sonido' +
-- 'Iluminación', ninguno clasifica, y Luz y Sonido dejaría de funcionar. Este
-- orden no es estético, es lo que evita esa regresión.
CREATE OR REPLACE FUNCTION public.genre_category_key(p_genre text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public'
AS $function$
  SELECT COALESCE(
    public.genre_category_key_exact(p_genre),
    (
      SELECT public.genre_category_key_exact(trim(parte.valor))
      FROM unnest(string_to_array(COALESCE(p_genre, ''), '/'))
             WITH ORDINALITY AS parte(valor, orden)
      WHERE public.genre_category_key_exact(trim(parte.valor)) IS NOT NULL
      ORDER BY parte.orden
      LIMIT 1
    )
  );
$function$;

COMMENT ON FUNCTION public.genre_category_key(text) IS
  'sql/688 — clasifica un groups.genre en su categoría. Acepta géneros simples y COMPUESTOS separados por "/" ("Norteño/Sierreño" -> grupo): primero intenta igualdad exacta de la cadena completa (para no romper "Sonido / Iluminación", que lleva "/" y es simple) y si no, gana la primera parte que clasifique, de izquierda a derecha. Mismo criterio que group_category_key().';

COMMIT;

-- ── Verificación manual sugerida después de aplicar ─────────────────────────
-- SELECT public.genre_category_key('Norteño/Sierreño');        -- → grupo
-- SELECT public.genre_category_key('Sonido / Iluminación');    -- → luzSonido
-- SELECT public.genre_category_key('Norteño');                 -- → grupo
-- SELECT public.genre_category_key(NULL);                      -- → NULL
-- SELECT g.name, g.genre, public.genre_category_key(g.genre)
--   FROM public.groups g ORDER BY g.name;
