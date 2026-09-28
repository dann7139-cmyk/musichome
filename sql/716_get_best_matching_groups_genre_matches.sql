-- ═══════════════════════════════════════════════════════════════════════════
-- 716 — `get_best_matching_groups` usa la regla canónica de género
-- ═══════════════════════════════════════════════════════════════════════════
-- Última pieza de la misma alineación. `get_best_matching_groups` es el filtro de
-- destinatarios del **smart matching**, el segundo sistema de avisos que corre sobre
-- la MISMA solicitud: la llama `_notify_matching_wave`, que a su vez la disparan
-- `start_smart_matching()` (trigger AFTER INSERT `trg_start_smart_matching`) y el
-- cron `smart-matching-queue` (`process_matching_queue`, cada minuto). O sea: es
-- una ruta **vigente**, no legacy.
--
-- ── CAMBIO: UNA condición del WHERE, nada más ──────────────────────────────
--   antes:  WHERE g.genre     = v_req.genre
--   ahora:  WHERE public.genre_matches(g.genre, v_req.genre)
--
-- ── POR QUÉ NO TOCA EL RANKING ────────────────────────────────────────────
-- El orden lo pone `calculate_matching_score(g.id, p_request_id)`, y esa función
-- **no menciona el género en ninguna línea** (verificado: 0 líneas con 'genre').
-- Así que cambiar el filtro no altera el score ni el orden; solo deja pasar a los
-- grupos compuestos compatibles, que es lo que ya hace `dispatch_express_request`.
-- Tampoco se toca `LIMIT p_limit` / `OFFSET p_offset` (los lotes de
-- `_notify_matching_wave`: 3 en la ola 1 y 5 en las siguientes), ni
-- `p_exclude_ids`, ni `is_active`, ni `availability`, ni la distancia.
-- No cambian firma, DEFAULT, ACL, SECURITY DEFINER, search_path, RLS ni ownership.
--
-- ── CÓMO (a prueba de transcripción) ──────────────────────────────────────
-- Se regenera desde su propio `pg_get_functiondef()` sustituyendo solo esa
-- condición, con guard por md5 (3f2514010a3e98d0345249015ddc953c) y comprobación de
-- que la ocurrencia es 1.
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

DO $mig$
DECLARE
  v_oid    OID;
  v_def    TEXT;
  v_new    TEXT;
  v_patron TEXT := 'g\.genre\s*=\s*v_req\.genre';
  v_ocurr  INT;
BEGIN
  v_oid := to_regprocedure('public.get_best_matching_groups(uuid, integer, integer, uuid[])');
  IF v_oid IS NULL THEN
    RAISE EXCEPTION 'No existe get_best_matching_groups(uuid,int,int,uuid[]). Abortando.';
  END IF;
  IF (SELECT COUNT(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
      WHERE n.nspname='public' AND p.proname='get_best_matching_groups') <> 1 THEN
    RAISE EXCEPTION 'Hay mas de una firma de get_best_matching_groups. Reauditar.';
  END IF;
  IF (SELECT md5(prosrc) FROM pg_proc WHERE oid=v_oid) <> '3f2514010a3e98d0345249015ddc953c' THEN
    RAISE EXCEPTION 'El cuerpo de get_best_matching_groups no es el auditado (md5 %). Abortando.',
      (SELECT md5(prosrc) FROM pg_proc WHERE oid=v_oid);
  END IF;
  IF to_regprocedure('public.genre_matches(text, text)') IS NULL THEN
    RAISE EXCEPTION 'No existe genre_matches(text,text). Abortando.';
  END IF;
  -- el score no debe depender del genero (si algun dia dependiera, esto se para)
  IF (SELECT prosrc FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
      WHERE n.nspname='public' AND p.proname='calculate_matching_score') ~* 'genre' THEN
    RAISE EXCEPTION 'calculate_matching_score ahora usa el genero: reauditar antes de tocar el filtro.';
  END IF;

  v_def := pg_get_functiondef(v_oid);
  SELECT COUNT(*) INTO v_ocurr FROM regexp_matches(v_def, v_patron, 'g');
  IF v_ocurr <> 1 THEN
    RAISE EXCEPTION 'Se esperaba 1 ocurrencia del filtro de genero y hay %. Abortando.', v_ocurr;
  END IF;

  v_new := regexp_replace(v_def, v_patron, 'public.genre_matches(g.genre, v_req.genre)');
  EXECUTE v_new;
END
$mig$;

COMMENT ON FUNCTION public.get_best_matching_groups(uuid, integer, integer, uuid[]) IS
  'sql/716 — el filtro de destinatarios del smart matching usa public.genre_matches(), la misma regla canonica de dispatch_express_request, propose_event_request (sql/713) y _send_wave (sql/715). Antes exigia igualdad exacta y dejaba fuera a los grupos de genero compuesto. Unico cambio: esa condicion del WHERE. El orden lo sigue poniendo calculate_matching_score, que no mira el genero; LIMIT/OFFSET y p_exclude_ids sin tocar.';

DO $verify$
DECLARE v_src TEXT;
BEGIN
  SELECT prosrc INTO v_src FROM pg_proc
  WHERE oid = to_regprocedure('public.get_best_matching_groups(uuid, integer, integer, uuid[])');
  IF v_src ~ 'g\.genre\s*=\s*v_req\.genre' THEN
    RAISE EXCEPTION 'La igualdad exacta sigue ahi. Abortando.';
  END IF;
  IF v_src NOT LIKE '%genre_matches(g.genre, v_req.genre)%' THEN
    RAISE EXCEPTION 'No quedo la llamada a genre_matches. Abortando.';
  END IF;
  IF v_src NOT LIKE '%calculate_matching_score%'
     OR v_src NOT LIKE '%LIMIT  p_limit%'
     OR v_src NOT LIKE '%OFFSET p_offset%'
     OR v_src NOT LIKE '%p_exclude_ids%'
     OR v_src NOT LIKE '%haversine_km%' THEN
    RAISE EXCEPTION 'El cuerpo perdio partes que debian quedar intactas. Abortando.';
  END IF;
  IF NOT has_function_privilege('authenticated',
       'public.get_best_matching_groups(uuid, integer, integer, uuid[])','EXECUTE') THEN
    RAISE EXCEPTION 'Cambio la ACL. Abortando.';
  END IF;
END
$verify$;

COMMIT;
