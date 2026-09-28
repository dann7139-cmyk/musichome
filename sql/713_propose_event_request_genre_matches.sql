-- ═══════════════════════════════════════════════════════════════════════════
-- 713 — `propose_event_request` usa la regla canónica de género
-- ═══════════════════════════════════════════════════════════════════════════
-- Corrige UNA inconsistencia: el despacho exprés selecciona grupos con
-- `genre_matches()` (entiende los géneros compuestos), pero la RPC con la que el
-- grupo cotiza exigía **igualdad exacta**. Resultado: un grupo "Norteño/Sierreño"
-- era despachado para una solicitud "Norteño", recibía el push, veía la solicitud
-- … y al cotizar recibía `genre_mismatch`.
--
-- NO cambia ranking, distancia, top 3, olas, la ventana de 3 h, los locks, RLS,
-- pagos, reservaciones, Stripe/Conekta, wallets ni comisiones. NO amplía qué
-- géneros son compatibles: reutiliza la función que ya define esa regla.
--
-- ── BUG REPRODUCIDO (transacción revertida, datos sintéticos) ───────────────
--   genre_matches('Norteño/Sierreño','Norteño') = true
--   comparación exacta (<>)                     = true  → genre_mismatch
--   dispatch_express_request                    -> {"ok":true,"dispatched":1}
--   dispatch creado para el grupo compuesto     = 1
--   el grupo compuesto VE la solicitud          = 1
--   propose_event_request                       -> {"ok":false,"error":"genre_mismatch"}
--   propuestas creadas                          = 0
--
-- ── FUENTE CANÓNICA: `public.genre_matches(a, b)` ──────────────────────────
-- Ya existe, es IMMUTABLE, no es SECURITY DEFINER y la puede ejecutar cualquiera:
--     SELECT a IS NOT NULL AND b IS NOT NULL AND EXISTS (
--       SELECT 1 FROM unnest(string_to_array(a,'/')) AS pa
--       CROSS JOIN unnest(string_to_array(b,'/')) AS pb
--       WHERE lower(trim(pa)) = lower(trim(pb)));
-- Es el espejo exacto de `genreMatches()` de la app
-- (`src/constants/providerCategories.ts:167`) y ya la usan `dispatch_express_request`
-- y `get_surge_factor`. No se crea una segunda lógica de parsing.
--
-- ── CÓMO SE HACE EL CAMBIO (a prueba de transcripción) ─────────────────────
-- No se reescribe la función a mano: se toma su propio `pg_get_functiondef()` de
-- producción y se sustituye **una sola línea**. Todo lo demás —firma, los 10
-- DEFAULT, SECURITY DEFINER, search_path, y las 5 078 letras del cuerpo— queda
-- byte a byte igual. Guard por md5 antes de tocar nada, y verificación de que la
-- sustitución ocurrió exactamente 1 vez.
--
--   ANTES:  IF v_group.genre <> v_req.genre THEN
--   AHORA:  IF NOT public.genre_matches(v_group.genre, v_req.genre) THEN
--
-- El resto de la validación no se toca: sigue devolviendo `genre_mismatch` cuando
-- de verdad no hay ningún estilo en común.
--
-- ── OTRAS COMPARACIONES EXACTAS ENCONTRADAS (reportadas, NO incluidas) ─────
-- `accept_event_request` e `instant_accept_request` tienen el mismo
-- `v_group.genre <> v_req.genre` → `genre_mismatch`. **No se tocan aquí**: la app
-- no las invoca (0 llamadas en todo `src/`), así que hoy el bug no es alcanzable
-- por esa vía, y ampliar el cambio no estaba autorizado.
-- `_send_wave`, `get_best_matching_groups`, `notify_express_groups` y
-- `get_open_requests_for_group` también comparan exacto, pero eso es
-- **selección/notificación/visibilidad** (olas, ranking, matching): tocarlo sería
-- cambiar a quién le llega la solicitud, que está explícitamente prohibido.
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

DO $mig$
DECLARE
  v_oid      OID;
  v_def      TEXT;
  v_new      TEXT;
  v_viejo    TEXT := 'IF v_group.genre <> v_req.genre THEN';
  v_nuevo    TEXT := 'IF NOT public.genre_matches(v_group.genre, v_req.genre) THEN';
  v_ocurr    INT;
BEGIN
  v_oid := to_regprocedure('public.propose_event_request(uuid,numeric,numeric,numeric,numeric,numeric,text,jsonb,text,text,uuid)');
  IF v_oid IS NULL THEN
    RAISE EXCEPTION 'No existe propose_event_request con la firma esperada. Abortando.';
  END IF;

  IF (SELECT COUNT(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
      WHERE n.nspname='public' AND p.proname='propose_event_request') <> 1 THEN
    RAISE EXCEPTION 'Hay mas de una firma de propose_event_request. Reauditar.';
  END IF;

  SELECT prosrc INTO v_def FROM pg_proc WHERE oid = v_oid;
  IF md5(v_def) <> '7229b76cf16edd1beca00df2cc7de991' THEN
    RAISE EXCEPTION 'El cuerpo de propose_event_request no es el auditado (md5 %). Abortando.', md5(v_def);
  END IF;

  IF to_regprocedure('public.genre_matches(text, text)') IS NULL THEN
    RAISE EXCEPTION 'No existe genre_matches(text,text). Abortando.';
  END IF;

  -- Definicion COMPLETA generada por Postgres: firma + defaults + secdef +
  -- search_path + cuerpo. Solo se sustituye la linea de la comparacion.
  v_def := pg_get_functiondef(v_oid);

  v_ocurr := (length(v_def) - length(replace(v_def, v_viejo, ''))) / length(v_viejo);
  IF v_ocurr <> 1 THEN
    RAISE EXCEPTION 'Se esperaba 1 ocurrencia de la comparacion exacta y hay %. Abortando.', v_ocurr;
  END IF;

  v_new := replace(v_def, v_viejo, v_nuevo);
  EXECUTE v_new;
END
$mig$;

COMMENT ON FUNCTION public.propose_event_request(uuid,numeric,numeric,numeric,numeric,numeric,text,jsonb,text,text,uuid) IS
  'sql/713 — la validacion de genero usa public.genre_matches(), la misma regla canonica que ya usa dispatch_express_request, para que un grupo de genero compuesto ("Norteno/Sierreno") pueda cotizar la solicitud para la que fue despachado. Antes exigia igualdad exacta y devolvia genre_mismatch. Unico cambio respecto a la version anterior; el resto del cuerpo es byte-identico (se regenero desde pg_get_functiondef).';

DO $verify$
DECLARE v_src TEXT;
BEGIN
  SELECT prosrc INTO v_src FROM pg_proc
  WHERE oid = to_regprocedure('public.propose_event_request(uuid,numeric,numeric,numeric,numeric,numeric,text,jsonb,text,text,uuid)');

  IF v_src LIKE '%v_group.genre <> v_req.genre%' THEN
    RAISE EXCEPTION 'La comparacion exacta sigue ahi. Abortando.';
  END IF;
  IF v_src NOT LIKE '%genre_matches(v_group.genre, v_req.genre)%' THEN
    RAISE EXCEPTION 'No quedo la llamada a genre_matches. Abortando.';
  END IF;
  IF v_src NOT LIKE '%genre_mismatch%' THEN
    RAISE EXCEPTION 'Se perdio el codigo de error genre_mismatch. Abortando.';
  END IF;
  -- el resto del contrato sigue en su lugar
  IF v_src NOT LIKE '%event_request_proposals%'
     OR v_src NOT LIKE '%en_negociacion%'
     OR v_src NOT LIKE '%express_fee%' THEN
    RAISE EXCEPTION 'El cuerpo perdio partes que debian quedar intactas. Abortando.';
  END IF;
  IF NOT has_function_privilege('authenticated',
       'public.propose_event_request(uuid,numeric,numeric,numeric,numeric,numeric,text,jsonb,text,text,uuid)','EXECUTE') THEN
    RAISE EXCEPTION 'authenticated perdio EXECUTE. Abortando.';
  END IF;
END
$verify$;

NOTIFY pgrst, 'reload schema';

COMMIT;
