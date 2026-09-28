-- ═══════════════════════════════════════════════════════════════════════════
-- ROLLBACK de 713 — vuelve a la comparación exacta de género
-- ═══════════════════════════════════════════════════════════════════════════
-- ⚠️  Correrlo reintroduce el bug: un grupo de género compuesto
-- ("Norteño/Sierreño") seguirá siendo despachado y viendo la solicitud "Norteño",
-- pero al cotizar recibirá `genre_mismatch`.
--
-- Usa la misma técnica que 713 (sustituir una línea sobre el propio
-- `pg_get_functiondef` de producción), así que el cuerpo vuelve byte a byte al
-- estado anterior: md5 esperado al terminar = 7229b76cf16edd1beca00df2cc7de991.
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

DO $rb$
DECLARE
  v_oid   OID;
  v_def   TEXT;
  v_new   TEXT;
  v_viejo TEXT := 'IF NOT public.genre_matches(v_group.genre, v_req.genre) THEN';
  v_nuevo TEXT := 'IF v_group.genre <> v_req.genre THEN';
  v_ocurr INT;
BEGIN
  v_oid := to_regprocedure('public.propose_event_request(uuid,numeric,numeric,numeric,numeric,numeric,text,jsonb,text,text,uuid)');
  IF v_oid IS NULL THEN
    RAISE EXCEPTION 'No existe propose_event_request con la firma esperada. Abortando.';
  END IF;

  v_def := pg_get_functiondef(v_oid);
  v_ocurr := (length(v_def) - length(replace(v_def, v_viejo, ''))) / length(v_viejo);
  IF v_ocurr <> 1 THEN
    RAISE EXCEPTION 'Se esperaba 1 ocurrencia de genre_matches y hay %. Abortando.', v_ocurr;
  END IF;

  v_new := replace(v_def, v_viejo, v_nuevo);
  EXECUTE v_new;

  IF (SELECT md5(prosrc) FROM pg_proc WHERE oid = v_oid) <> '7229b76cf16edd1beca00df2cc7de991' THEN
    RAISE EXCEPTION 'El cuerpo restaurado no coincide con el md5 previo a sql/713. Abortando.';
  END IF;
END
$rb$;

COMMENT ON FUNCTION public.propose_event_request(uuid,numeric,numeric,numeric,numeric,numeric,text,jsonb,text,text,uuid) IS
  'ROLLBACK de sql/713: la validacion de genero vuelve a exigir igualdad exacta.';

NOTIFY pgrst, 'reload schema';

COMMIT;
