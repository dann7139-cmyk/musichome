-- ═══════════════════════════════════════════════════════════════════════════
-- 715 — `_send_wave` usa la regla canónica de género (olas 1/2/3)
-- ═══════════════════════════════════════════════════════════════════════════
-- Cierra la última mezcla de semánticas del flujo exprés: `dispatch_express_request`
-- selecciona con `genre_matches()` y `propose_event_request` ya valida con
-- `genre_matches()` (sql/713), pero el filtro de destinatarios de las olas seguía
-- con **igualdad exacta**, así que un grupo "Norteño/Sierreño" era despachado y
-- podía cotizar, pero **nunca entraba en las olas** de una solicitud "Norteño".
--
-- ── CAMBIO: UNA condición del WHERE, nada más ──────────────────────────────
--   antes:  WHERE g.genre     = p_req.genre
--   ahora:  WHERE public.genre_matches(g.genre, p_req.genre)
--
-- NO se toca: el `ORDER BY` (disponible-ahora primero, 50 % ranking + 50 %
-- proximidad), el `OFFSET p_offset`/`LIMIT p_limit` (top 3 en la ola 1, 12 en la 2,
-- 1000 en la 3), el radio, `haversine_km`, el filtro de `is_active`/`availability`,
-- el `NOT EXISTS` anti-duplicados, el título/cuerpo de la notificación, ni el
-- contador que devuelve. Tampoco firma, DEFAULT, ACL, SECURITY DEFINER,
-- search_path, RLS ni ownership.
--
-- ── EVIDENCIA (transacción revertida, datos sintéticos) ────────────────────
-- Solicitud "Norteño" + grupo "Norteño/Sierreño" (activo, available, sin
-- `group_locations` → la distancia no puede excluirlo):
--   (a) dispatch_express_request -> {"ok":true,"dispatched":1}   · dispatch del compuesto: 1
--   (b) notify_wave_1 -> notified: 3  · notificaciones de la ola para el compuesto: 0
--   (c) la MISMA consulta de `_send_wave`, con todas las demás condiciones
--       idénticas, devuelve para ese grupo:
--          con igualdad exacta ....... 0 filas
--          con genre_matches() ....... 1 fila
--   (d) is_active + availability OK, 0 filas en group_locations (así que
--       `gl.lat IS NULL` lo incluye sin importar la distancia), ranking_score 1.3
-- O sea: **la única razón de la exclusión era la comparación de género.**
--
-- ── CONSECUENCIA QUE SÍ HAY QUE TENER PRESENTE ────────────────────────────
-- El límite de la ola 1 sigue siendo 3, pero ahora los grupos compuestos
-- compatibles **compiten por esos 3 lugares** con el mismo criterio de ranking y
-- proximidad que los demás. Eso es exactamente lo que ya hace el despacho exprés.
-- No se amplía qué géneros son compatibles: se reutiliza la función que define esa
-- regla.
--
-- ── CÓMO (a prueba de transcripción) ──────────────────────────────────────
-- Se regenera la función desde su propio `pg_get_functiondef()` de producción
-- sustituyendo solo esa condición, con guard por md5 del cuerpo
-- (300f26c99383aa1e339dcf5ade5fce96) y comprobación de que la ocurrencia es 1.
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

DO $mig$
DECLARE
  v_oid    OID;
  v_def    TEXT;
  v_new    TEXT;
  v_patron TEXT := 'g\.genre\s*=\s*p_req\.genre';
  v_ocurr  INT;
BEGIN
  v_oid := to_regprocedure('public._send_wave(record, integer, integer, boolean)');
  IF v_oid IS NULL THEN
    RAISE EXCEPTION 'No existe _send_wave(record,int,int,boolean). Abortando.';
  END IF;
  IF (SELECT COUNT(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
      WHERE n.nspname='public' AND p.proname='_send_wave') <> 1 THEN
    RAISE EXCEPTION 'Hay mas de una firma de _send_wave. Reauditar.';
  END IF;
  IF (SELECT md5(prosrc) FROM pg_proc WHERE oid=v_oid) <> '300f26c99383aa1e339dcf5ade5fce96' THEN
    RAISE EXCEPTION 'El cuerpo de _send_wave no es el auditado (md5 %). Abortando.',
      (SELECT md5(prosrc) FROM pg_proc WHERE oid=v_oid);
  END IF;
  IF to_regprocedure('public.genre_matches(text, text)') IS NULL THEN
    RAISE EXCEPTION 'No existe genre_matches(text,text). Abortando.';
  END IF;

  v_def := pg_get_functiondef(v_oid);
  SELECT COUNT(*) INTO v_ocurr FROM regexp_matches(v_def, v_patron, 'g');
  IF v_ocurr <> 1 THEN
    RAISE EXCEPTION 'Se esperaba 1 ocurrencia del filtro de genero y hay %. Abortando.', v_ocurr;
  END IF;

  v_new := regexp_replace(v_def, v_patron, 'public.genre_matches(g.genre, p_req.genre)');
  EXECUTE v_new;
END
$mig$;

COMMENT ON FUNCTION public._send_wave(record, integer, integer, boolean) IS
  'sql/715 — el filtro de destinatarios usa public.genre_matches(), la misma regla canonica de dispatch_express_request y propose_event_request (sql/713), para que un grupo de genero compuesto ("Norteno/Sierreno") tambien entre en las olas de una solicitud "Norteno". Antes exigia igualdad exacta. Unico cambio: esa condicion del WHERE. Ranking, proximidad, OFFSET/LIMIT (top 3 / 12 / 1000), radio, anti-duplicados y textos, sin tocar.';

DO $verify$
DECLARE v_src TEXT;
BEGIN
  SELECT prosrc INTO v_src FROM pg_proc WHERE oid = to_regprocedure('public._send_wave(record, integer, integer, boolean)');
  IF v_src ~ 'g\.genre\s*=\s*p_req\.genre' THEN
    RAISE EXCEPTION 'La igualdad exacta sigue ahi. Abortando.';
  END IF;
  IF v_src NOT LIKE '%genre_matches(g.genre, p_req.genre)%' THEN
    RAISE EXCEPTION 'No quedo la llamada a genre_matches. Abortando.';
  END IF;
  -- lo que NO debia cambiar sigue en su lugar
  IF v_src NOT LIKE '%OFFSET p_offset LIMIT p_limit%'
     OR v_src NOT LIKE '%haversine_km%'
     OR v_src NOT LIKE '%available_now%'
     OR v_src NOT LIKE '%followup_level%'
     OR v_src NOT LIKE '%ranking_score%' THEN
    RAISE EXCEPTION 'El cuerpo perdio partes que debian quedar intactas. Abortando.';
  END IF;
  IF NOT has_function_privilege('authenticated',
       'public._send_wave(record, integer, integer, boolean)','EXECUTE') THEN
    RAISE EXCEPTION 'Cambio la ACL. Abortando.';
  END IF;
END
$verify$;

COMMIT;
