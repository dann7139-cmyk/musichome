-- ═══════════════════════════════════════════════════════════════════════════
-- ROLLBACK de sql/724 — cierre de SECURITY DEFINER
-- ═══════════════════════════════════════════════════════════════════════════
-- ⚠⚠ LEE ESTO ANTES DE CORRER NADA ⚠⚠
--
-- Este archivo REABRE un agujero con dinero real. Probado antes del parche: con
-- la anon key, sin ninguna sesión, se podía marcar pagado un regalo de $500 que
-- nadie pagó y dejar $300 de saldo RETIRABLE en la wallet del grupo. También:
-- activar Plus gratis, marcar bids pagados, suspender a un proveedor con 3
-- strikes y forjar `financial_audit_logs` como si fuera un admin.
--
-- NO corras este archivo completo "por si acaso". Está dividido en 4 pasos de
-- menor a mayor daño. Corre el MÍNIMO que resuelva el problema que tengas y
-- detente ahí.
--
--   PASO 1 — repone service_role. Úsalo si un webhook empezó a fallar con 42501.
--            (No debería: 725 probó que los 8 funcionan desde service_role.)
--   PASO 2 — quita el guard interno, dejando el REVOKE. Úsalo si en producción
--            `auth.role()` no vale 'service_role' en las llamadas reales del
--            webhook y por eso los pagos dejaron de confirmarse. ESTE es el
--            rollback probable y el menos dañino de los que tocan el guard.
--   PASO 3 — devuelve EXECUTE a PUBLIC/anon/authenticated. REABRE EL AGUJERO.
--   PASO 4 — devuelve los defaults del esquema. Hace que CADA función y tabla
--            nueva vuelva a nacer abierta a anon.
--
-- Si lo que falla es una pantalla de la app, el PASO 3 casi seguro NO es la
-- solución: se verificó que ninguna de las 120 funciones cerradas se llama desde
-- `src/` ni `web/` (209 nombres de `.rpc()` extraídos y comparados). Primero
-- averigua QUÉ función y repón solo esa.
-- ═══════════════════════════════════════════════════════════════════════════

-- ───────────────────────────────────────────────────────────────────────────
-- PASO 1 — reponer service_role en las 8 de webhook (inocuo)
-- ───────────────────────────────────────────────────────────────────────────
BEGIN;
DO $p1$
DECLARE v_fn RECORD;
BEGIN
  FOR v_fn IN
    SELECT p.oid::regprocedure::text AS firma
    FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.proname IN
      ('confirm_gift_payment','confirm_bid_payment','confirm_recommendation_payment',
       'mark_ad_payment','renew_recommendation_subscription','renew_sponsored_subscription',
       'activate_plus','deactivate_plus')
  LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role', v_fn.firma);
  END LOOP;
END
$p1$;
COMMIT;

-- ───────────────────────────────────────────────────────────────────────────
-- PASO 2 — quitar SOLO el guard interno, conservando el REVOKE
-- Deja a las 8 accesibles únicamente por service_role vía permisos, que sigue
-- siendo mucho mejor que el estado anterior a 724.
-- ───────────────────────────────────────────────────────────────────────────
/*  Descomenta este bloque para ejecutarlo.
BEGIN;
DO $p2$
DECLARE
  v_fn RECORD; v_def TEXT; v_nl TEXT; v_ini INT; v_fin INT;
BEGIN
  FOR v_fn IN
    SELECT p.oid, p.oid::regprocedure::text AS firma
    FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.proname IN
      ('confirm_gift_payment','confirm_bid_payment','confirm_recommendation_payment',
       'mark_ad_payment','renew_recommendation_subscription','renew_sponsored_subscription',
       'activate_plus','deactivate_plus')
  LOOP
    v_def := pg_get_functiondef(v_fn.oid);
    v_nl  := CASE WHEN v_def LIKE '%' || chr(13) || '%' THEN chr(13) || chr(10) ELSE chr(10) END;
    -- El guard va desde su primer comentario hasta el END IF; y la linea en blanco.
    v_ini := position('  -- sql/724 — defensa en profundidad.' in v_def);
    IF v_ini = 0 THEN
      RAISE NOTICE '% ya no tiene el guard, se omite', v_fn.firma;
      CONTINUE;
    END IF;
    v_fin := position('  END IF;' || v_nl || v_nl in substr(v_def, v_ini));
    IF v_fin = 0 THEN
      RAISE EXCEPTION 'No pude delimitar el guard en %. Quitalo a mano.', v_fn.firma;
    END IF;
    v_def := left(v_def, v_ini - 1)
          || substr(v_def, v_ini + v_fin + length('  END IF;' || v_nl || v_nl) - 1);
    EXECUTE v_def;
  END LOOP;
END
$p2$;
DO $v2$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.prosrc LIKE '%solo el backend puede ejecutar%'
      AND p.proname IN ('confirm_gift_payment','confirm_bid_payment','confirm_recommendation_payment',
        'mark_ad_payment','renew_recommendation_subscription','renew_sponsored_subscription',
        'activate_plus','deactivate_plus')
  ) THEN
    RAISE EXCEPTION 'Alguna conservo el guard. Revisar a mano.';
  END IF;
END
$v2$;
COMMIT;
*/

-- ───────────────────────────────────────────────────────────────────────────
-- PASO 3 — ⚠ REABRE EL AGUJERO: devuelve EXECUTE a PUBLIC/anon/authenticated
-- Solo si quedó demostrado que el REVOKE rompió algo que no se puede arreglar
-- reponiendo una función concreta.
-- ───────────────────────────────────────────────────────────────────────────
/*  Descomenta este bloque para ejecutarlo. SABIENDO QUE REABRE EL AGUJERO.
BEGIN;
DO $p3$
DECLARE v_fn RECORD; v_n INT := 0;
BEGIN
  -- Las mismas familias de 724, en el mismo orden.
  FOR v_fn IN
    SELECT p.oid::regprocedure::text AS firma
    FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.prosecdef
      AND NOT has_function_privilege('anon', p.oid, 'EXECUTE')
      AND p.proname NOT IN (
        -- estas YA estaban cerradas antes de 724 (sql/694 y etapas previas):
        -- no se tocan, para no deshacer endurecimientos anteriores.
        SELECT unnest(ARRAY['notify_wave_1','set_group_commercial_catalog','notify_pending_quotes'])
      )
  LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO PUBLIC, anon, authenticated', v_fn.firma);
    v_n := v_n + 1;
  END LOOP;
  RAISE NOTICE 'REABIERTAS % funciones', v_n;
END
$p3$;
COMMIT;
*/

-- ───────────────────────────────────────────────────────────────────────────
-- PASO 4 — ⚠⚠ devuelve los defaults: todo lo NUEVO vuelve a nacer abierto
-- ───────────────────────────────────────────────────────────────────────────
/*  Descomenta este bloque para ejecutarlo.
BEGIN;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  GRANT EXECUTE ON FUNCTIONS TO PUBLIC, anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  GRANT INSERT, UPDATE, DELETE, TRUNCATE ON TABLES TO anon;
COMMIT;
*/

NOTIFY pgrst, 'reload schema';
