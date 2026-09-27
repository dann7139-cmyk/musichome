-- ═══════════════════════════════════════════════════════════════════════════
-- 704 — desambigua `notify_wave_1`: retira la firma de 4 argumentos
-- ═══════════════════════════════════════════════════════════════════════════
-- CORRECCIÓN PRE-RELEASE. No cambia lógica de oleadas, ni precios, ni pagos, ni
-- nada financiero. Solo elimina una de dos firmas duplicadas para que la llamada
-- que ya hace la app resuelva de forma inequívoca.
--
-- ── EL PROBLEMA (medido, no deducido) ──────────────────────────────────────
-- La app llama con exactamente 4 claves:
--   p_request_id, p_event_lat, p_event_lng, p_radius_km
-- y en producción hay DOS funciones que aceptan justo ese conjunto:
--   · oid 51474 → (uuid, float8 DEFAULT, float8 DEFAULT, float8 DEFAULT 50)
--   · oid 51640 → (uuid, float8 DEFAULT, float8 DEFAULT, float8 DEFAULT 50,
--                  boolean DEFAULT false)
-- La segunda encaja también porque su parámetro extra tiene DEFAULT. Resultado:
-- Postgres no puede elegir candidato y responde **42725 "function is not
-- unique"**. Verificado llamando con las claves exactas de la app dentro de una
-- transacción revertida. Consecuencia real hoy: **la oleada 1 de avisos a
-- proveedores nunca se dispara** desde GuidedRequestScreen ni OpenRequestScreen.
--
-- ── CUÁL SOBREVIVE Y POR QUÉ (no se elige "la que parece vieja") ───────────
-- Sobrevive la de **5 argumentos** (oid 51640). Evidencia:
--   1. Tiene el OID más alto → se creó después.
--   2. Es la única que escribe `event_requests.use_radius_expansion`, columna que
--      SÍ existe en producción (boolean, default false). La de 4 argumentos ni la
--      menciona, así que dejarla sería dejar viva una versión que ignora una
--      columna del esquema actual.
--   3. Su cuerpo trae el comentario "Top 3 (quick matching)", o sea es la
--      evolución deliberada del diseño.
--
-- ── SE DEMUESTRA QUE NADIE DEPENDE DE LA QUE SE RETIRA ────────────────────
-- Callers verificados uno por uno:
--   · funciones SQL que la invocan .......... NINGUNA
--   · triggers .............................. NINGUNO
--   · crons (`cron.job`) .................... NINGUNO
--   · Edge Functions ........................ NINGUNA
--   · web/src ............................... NINGUNA
--   · app ................................... 2 sitios
--       - src/screens/client/GuidedRequestScreen.tsx:290
--       - src/screens/client/OpenRequestScreen.tsx:544
--     ambos con las MISMAS 4 claves, y **ninguno manda
--     `p_use_radius_expansion`**.
-- Como los dos callers mandan 4 claves y la firma que sobrevive las acepta todas
-- (la quinta es opcional), ninguno se rompe: pasan de fallar con 42725 a
-- funcionar.
--
-- ── LA ÚNICA CONSECUENCIA DE COMPORTAMIENTO, DICHA EN VOZ ALTA ─────────────
-- Las dos versiones difieren en cuántos proveedores notifica la oleada 1:
-- la retirada usaba `_send_wave(v_req, 0, 5, ...)` (top 5) y la que sobrevive usa
-- `_send_wave(v_req, 0, 3, ...)` (top 3). Hoy **ninguna de las dos corre** (la
-- llamada falla), así que no hay comportamiento vigente que preservar; a partir de
-- esta migración la oleada 1 avisará al top 3, que es lo que dice la versión más
-- reciente. Si se prefiere el top 5, el ROLLBACK de este archivo restaura la firma
-- de 4 argumentos y habría que retirar la de 5 en su lugar — pero eso sí sería una
-- decisión de producto y NO se toma aquí.
-- La lógica de la firma que sobrevive **no se modifica ni una línea**.
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

-- Guarda: no seguir si el estado no es el auditado (2 firmas exactas).
DO $guard$
DECLARE v_n INT;
BEGIN
  SELECT COUNT(*) INTO v_n FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND p.proname='notify_wave_1';
  IF v_n <> 2 THEN
    RAISE EXCEPTION 'Se esperaban 2 firmas de notify_wave_1 y hay %. Reauditar antes de continuar.', v_n;
  END IF;
  IF to_regprocedure('public.notify_wave_1(uuid, double precision, double precision, double precision, boolean)') IS NULL THEN
    RAISE EXCEPTION 'No existe la firma de 5 argumentos que debe sobrevivir. Abortando.';
  END IF;
END
$guard$;

DROP FUNCTION public.notify_wave_1(UUID, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION);

NOTIFY pgrst, 'reload schema';

COMMIT;
