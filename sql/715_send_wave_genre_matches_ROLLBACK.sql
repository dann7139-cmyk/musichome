-- ═══════════════════════════════════════════════════════════════════════════
-- ROLLBACK de 715 — `_send_wave` vuelve a la igualdad exacta de género
-- ═══════════════════════════════════════════════════════════════════════════
-- ⚠️  Correrlo reintroduce el hueco: un grupo de género compuesto
-- ("Norteño/Sierreño") volverá a ser despachado y a poder cotizar, pero dejará de
-- entrar en las olas 1/2/3 de una solicitud "Norteño".
--
-- Misma técnica que 715 (sustituir una condición sobre el propio
-- `pg_get_functiondef` de producción), así que el cuerpo vuelve byte a byte:
-- md5 esperado al terminar = 300f26c99383aa1e339dcf5ade5fce96.
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

DO $rb$
DECLARE
  v_oid   OID;
  v_def   TEXT;
  v_new   TEXT;
  v_viejo TEXT := 'public.genre_matches(g.genre, p_req.genre)';
  v_ocurr INT;
BEGIN
  v_oid := to_regprocedure('public._send_wave(record, integer, integer, boolean)');
  IF v_oid IS NULL THEN
    RAISE EXCEPTION 'No existe _send_wave. Abortando.';
  END IF;

  v_def := pg_get_functiondef(v_oid);
  v_ocurr := (length(v_def) - length(replace(v_def, v_viejo, ''))) / length(v_viejo);
  IF v_ocurr <> 1 THEN
    RAISE EXCEPTION 'Se esperaba 1 ocurrencia de genre_matches y hay %. Abortando.', v_ocurr;
  END IF;

  v_new := replace(v_def, v_viejo, 'g.genre     = p_req.genre');
  EXECUTE v_new;

  IF (SELECT md5(prosrc) FROM pg_proc WHERE oid=v_oid) <> '300f26c99383aa1e339dcf5ade5fce96' THEN
    RAISE EXCEPTION 'El cuerpo restaurado no coincide con el md5 previo a sql/715 (revisar el espaciado). Abortando.';
  END IF;
END
$rb$;

COMMENT ON FUNCTION public._send_wave(record, integer, integer, boolean) IS
  'ROLLBACK de sql/715: el filtro de genero de las olas vuelve a la igualdad exacta.';

COMMIT;
