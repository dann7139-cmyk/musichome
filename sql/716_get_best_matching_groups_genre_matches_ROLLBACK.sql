-- ═══════════════════════════════════════════════════════════════════════════
-- ROLLBACK de 716 — `get_best_matching_groups` vuelve a la igualdad exacta
-- ═══════════════════════════════════════════════════════════════════════════
-- ⚠️  Correrlo hace que el smart matching vuelva a dejar fuera a los grupos de
-- género compuesto.
-- md5 esperado al terminar = 3f2514010a3e98d0345249015ddc953c.
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

DO $rb$
DECLARE
  v_oid   OID;
  v_def   TEXT;
  v_new   TEXT;
  v_viejo TEXT := 'public.genre_matches(g.genre, v_req.genre)';
  v_ocurr INT;
BEGIN
  v_oid := to_regprocedure('public.get_best_matching_groups(uuid, integer, integer, uuid[])');
  IF v_oid IS NULL THEN
    RAISE EXCEPTION 'No existe get_best_matching_groups. Abortando.';
  END IF;

  v_def := pg_get_functiondef(v_oid);
  v_ocurr := (length(v_def) - length(replace(v_def, v_viejo, ''))) / length(v_viejo);
  IF v_ocurr <> 1 THEN
    RAISE EXCEPTION 'Se esperaba 1 ocurrencia de genre_matches y hay %. Abortando.', v_ocurr;
  END IF;

  v_new := replace(v_def, v_viejo, 'g.genre     = v_req.genre');
  EXECUTE v_new;

  IF (SELECT md5(prosrc) FROM pg_proc WHERE oid=v_oid) <> '3f2514010a3e98d0345249015ddc953c' THEN
    RAISE EXCEPTION 'El cuerpo restaurado no coincide con el md5 previo a sql/716 (revisar el espaciado). Abortando.';
  END IF;
END
$rb$;

COMMENT ON FUNCTION public.get_best_matching_groups(uuid, integer, integer, uuid[]) IS
  'ROLLBACK de sql/716: el filtro de genero del smart matching vuelve a la igualdad exacta.';

COMMIT;
