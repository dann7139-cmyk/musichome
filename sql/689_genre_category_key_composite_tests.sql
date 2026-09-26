-- ═══════════════════════════════════════════════════════════════════════════
-- sql/689 — SUITE DE PRUEBAS de sql/688 (géneros compuestos)
-- ═══════════════════════════════════════════════════════════════════════════
--
-- NO APLICA NADA. Solo prueba. 100% seguro de correr en cualquier momento: todo
-- va dentro de BEGIN...ROLLBACK y termina en RAISE EXCEPTION, así que ni una
-- fila ni una definición queda tocada.
--
-- Requiere sql/688 YA aplicado. Correr también cada vez que se toque
-- genre_category_key(), genre_category_key_exact(), genre_matches(),
-- genre_in_list() o group_category_key().
--
-- CUBRE:
--   [1]  Los 11 caminos de categoría con géneros SIMPLES siguen igual.
--   [2]  'Sonido / Iluminación' — género simple QUE CONTIENE "/" (la trampa:
--        si se partiera primero, dejaría de clasificar).
--   [3]  'Norteño/Sierreño' → 'grupo'.
--   [4]  genre_matches con 'Norteño' y con 'Sierreño' sigue en true.
--   [5]  Compuestos generales (no solo el caso real): espacios alrededor,
--        parte desconocida al inicio, 3 partes, orden izquierda-a-derecha.
--   [6]  Entradas inválidas: NULL, '', '/', '///', solo desconocidos → NULL.
--   [7]  Categorías NO musicales siguen clasificando igual (comida, renta,
--        fotografos, terraza, luzSonido, dj, solista, mc, comediante,
--        espectaculo).
--   [8]  REGRESIÓN DURA: todos los géneros realmente presentes en
--        public.groups clasifican igual o mejor que antes (nunca peor).
--   [9]  group_category_key() de cada grupo real no cambió.
--   [10] El predicado real de dispatch_express_request (IS DISTINCT FROM
--        'comida'/'terraza') da el mismo veredicto que antes para cada grupo.
--   [11] Sin overloads: una sola genre_category_key y una sola _exact.
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

-- Foto del comportamiento ANTERIOR para los géneros reales, calculada con el
-- helper exacto (que replica lo que la función hacía antes de sql/688).
CREATE TEMP TABLE _antes_689 AS
SELECT g.id,
       g.genre,
       public.genre_category_key_exact(g.genre) AS cat_antes,
       public.group_category_key(g.id)          AS grupo_cat_antes
FROM public.groups g;

DO $suite$
DECLARE
  v_n INT;
  v_r RECORD;
BEGIN
  -- ══ [1] Géneros simples: un representante por categoría ═══════════════════
  ASSERT public.genre_category_key('Norteño')               = 'grupo',       '[1] Norteño';
  ASSERT public.genre_category_key('Sierreño')              = 'grupo',       '[1] Sierreño';
  ASSERT public.genre_category_key('Cumbia')                = 'grupo',       '[1] Cumbia';
  ASSERT public.genre_category_key('Zydeco')                = 'grupo',       '[1] Zydeco (bloque US)';
  ASSERT public.genre_category_key('Solistas')              = 'solista',     '[1] Solistas';
  ASSERT public.genre_category_key('DJ')                    = 'dj',          '[1] DJ';
  ASSERT public.genre_category_key('Comediante')            = 'comediante',  '[1] Comediante';
  ASSERT public.genre_category_key('Maestro de Ceremonias') = 'mc',          '[1] MC';
  ASSERT public.genre_category_key('Payasos')               = 'espectaculo', '[1] Payasos dentro de Shows';
  ASSERT public.genre_category_key('Comida')                = 'comida',      '[1] Comida';
  ASSERT public.genre_category_key('Barra de mixología')    = 'comida',      '[1] Barra de mixología (sql/673)';
  ASSERT public.genre_category_key('Renta de brincolines')  = 'renta',       '[1] Renta';
  ASSERT public.genre_category_key('Fotografía')            = 'fotografos',  '[1] Fotografía';
  ASSERT public.genre_category_key('Terraza')               = 'terraza',     '[1] Terraza (sql/681)';

  -- ══ [2] LA TRAMPA: género simple que contiene "/" ═════════════════════════
  ASSERT public.genre_category_key('Sonido / Iluminación') = 'luzSonido',
    '[2] REGRESIÓN GRAVE: "Sonido / Iluminación" dejó de clasificar — se está partiendo por "/" ANTES de intentar la igualdad exacta';

  -- ══ [3] El caso real que motivó sql/688 ═══════════════════════════════════
  ASSERT public.genre_category_key('Norteño/Sierreño') = 'grupo',
    '[3] Norteño/Sierreño debería clasificar como grupo, llegó: ' || COALESCE(public.genre_category_key('Norteño/Sierreño'), 'NULL');

  -- ══ [4] genre_matches sigue igual (sql/672, no se tocó) ═══════════════════
  ASSERT public.genre_matches('Norteño/Sierreño', 'Norteño'),  '[4] no calza con Norteño';
  ASSERT public.genre_matches('Norteño/Sierreño', 'Sierreño'), '[4] no calza con Sierreño';
  ASSERT NOT public.genre_matches('Norteño/Sierreño', 'Cumbia'), '[4] no debería calzar con Cumbia';

  -- ══ [5] Compuestos generales, no solo el caso real ════════════════════════
  ASSERT public.genre_category_key(' Norteño / Sierreño ') = 'grupo',
    '[5] compuesto con espacios alrededor';
  ASSERT public.genre_category_key('GeneroInventado/Norteño') = 'grupo',
    '[5] primera parte desconocida, segunda válida';
  ASSERT public.genre_category_key('Norteño/GeneroInventado') = 'grupo',
    '[5] primera parte válida, segunda desconocida';
  ASSERT public.genre_category_key('Norteño/Sierreño/Banda') = 'grupo',
    '[5] tres partes';
  -- Orden determinista: gana la PRIMERA parte que clasifique, de izq. a der.
  ASSERT public.genre_category_key('DJ/Norteño') = 'dj',
    '[5] debería ganar la primera parte que clasifica (DJ), llegó: ' || COALESCE(public.genre_category_key('DJ/Norteño'), 'NULL');
  ASSERT public.genre_category_key('Norteño/DJ') = 'grupo',
    '[5] orden inverso debe dar grupo';
  ASSERT public.genre_category_key('Inventado/Comida') = 'comida',
    '[5] compuesto no musical';

  -- ══ [6] Entradas inválidas ════════════════════════════════════════════════
  ASSERT public.genre_category_key(NULL)              IS NULL, '[6] NULL debe dar NULL';
  ASSERT public.genre_category_key('')                IS NULL, '[6] cadena vacía';
  ASSERT public.genre_category_key('/')               IS NULL, '[6] solo separador';
  ASSERT public.genre_category_key('///')             IS NULL, '[6] separadores repetidos';
  ASSERT public.genre_category_key('   ')             IS NULL, '[6] solo espacios';
  ASSERT public.genre_category_key('NoExiste')        IS NULL, '[6] género desconocido';
  ASSERT public.genre_category_key('NoExiste/Tampoco') IS NULL, '[6] compuesto todo desconocido';
  ASSERT public.genre_category_key('norteño')         IS NULL,
    '[6] la clasificación SIEMPRE fue sensible a mayúsculas/acentos; sql/688 no debe volverla laxa';

  -- ══ [7] Categorías no musicales, una por una ══════════════════════════════
  ASSERT public.genre_category_key('Snacks y botanas')     = 'comida',     '[7] snacks';
  ASSERT public.genre_category_key('Café y postres')       = 'comida',     '[7] café';
  ASSERT public.genre_category_key('Renta de mesas')       = 'renta',      '[7] mesas';
  ASSERT public.genre_category_key('Inflables acuáticos')  = 'renta',      '[7] inflables';
  ASSERT public.genre_category_key('Cabina 360')           = 'fotografos', '[7] cabina 360';
  ASSERT public.genre_category_key('Drones')               = 'fotografos', '[7] drones';
  ASSERT public.genre_category_key('Mago')                 = 'espectaculo','[7] mago';

  -- ══ [8] REGRESIÓN DURA contra los géneros REALES de producción ════════════
  -- Ningún grupo real puede EMPEORAR: si antes tenía categoría, debe seguir
  -- siendo la misma; si antes era NULL, ahora puede tener una (mejora) o seguir
  -- NULL, pero nunca cambiar de una categoría a otra.
  FOR v_r IN
    SELECT a.genre, a.cat_antes, public.genre_category_key(a.genre) AS cat_ahora
    FROM _antes_689 a
  LOOP
    IF v_r.cat_antes IS NOT NULL THEN
      ASSERT v_r.cat_ahora = v_r.cat_antes,
        '[8] REGRESIÓN: el género real ' || quote_literal(v_r.genre) ||
        ' cambió de categoría: ' || v_r.cat_antes || ' -> ' || COALESCE(v_r.cat_ahora, 'NULL');
    END IF;
  END LOOP;

  SELECT count(*) INTO v_n FROM _antes_689
   WHERE cat_antes IS NULL AND public.genre_category_key(genre) IS NOT NULL;
  ASSERT v_n >= 1,
    '[8] se esperaba que al menos un grupo real pasara de sin-categoría a clasificado (Grupo AS, Norteño/Sierreño)';

  -- ══ [9] group_category_key() por id no cambió para nadie ══════════════════
  FOR v_r IN
    SELECT a.id, a.genre, a.grupo_cat_antes, public.group_category_key(a.id) AS ahora
    FROM _antes_689 a
  LOOP
    ASSERT v_r.ahora IS NOT DISTINCT FROM v_r.grupo_cat_antes,
      '[9] group_category_key cambió para ' || quote_literal(v_r.genre) || ': ' ||
      COALESCE(v_r.grupo_cat_antes, 'NULL') || ' -> ' || COALESCE(v_r.ahora, 'NULL');
  END LOOP;

  -- ══ [10] El predicado real de dispatch_express_request ════════════════════
  -- Excluye comida y terraza del despacho Express. Nadie que hoy entre puede
  -- quedar fuera por sql/688.
  FOR v_r IN
    SELECT a.genre,
           (a.cat_antes IS DISTINCT FROM 'comida' AND a.cat_antes IS DISTINCT FROM 'terraza') AS entraba,
           (public.genre_category_key(a.genre) IS DISTINCT FROM 'comida'
            AND public.genre_category_key(a.genre) IS DISTINCT FROM 'terraza')                AS entra
    FROM _antes_689 a
  LOOP
    ASSERT v_r.entra = v_r.entraba,
      '[10] cambió la elegibilidad para Express de ' || quote_literal(v_r.genre) ||
      ': entraba=' || v_r.entraba::text || ' ahora=' || v_r.entra::text;
  END LOOP;

  -- ══ [11] Sin overloads ════════════════════════════════════════════════════
  SELECT count(*) INTO v_n FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'genre_category_key';
  ASSERT v_n = 1, '[11] genre_category_key quedó duplicada (overload): ' || v_n::text;
  SELECT count(*) INTO v_n FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'genre_category_key_exact';
  ASSERT v_n = 1, '[11] genre_category_key_exact duplicada: ' || v_n::text;

  RAISE EXCEPTION 'TEST_REPORT sql/689: TODO PASÓ — géneros simples de las 11 categorías intactos; "Sonido / Iluminación" (simple CON "/") sigue clasificando; Norteño/Sierreño ahora es grupo; genre_matches sin cambio; compuestos generales con espacios, partes desconocidas, 3 partes y orden izquierda-a-derecha determinista; NULL/vacío/"/"/"///"/desconocidos siguen dando NULL y la clasificación sigue sensible a mayúsculas; categorías no musicales igual; CERO regresiones sobre los géneros reales de producción; group_category_key sin cambios; elegibilidad de Express idéntica para todos; sin overloads';
END
$suite$;

ROLLBACK;
