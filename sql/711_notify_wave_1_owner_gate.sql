-- ═══════════════════════════════════════════════════════════════════════════
-- 711 — `notify_wave_1` solo puede lanzar la ola de TU PROPIA solicitud
-- ═══════════════════════════════════════════════════════════════════════════
-- Complemento de sql/708 (que le quitó el acceso anónimo). El revoke no bastaba:
-- la función **no validaba `auth.uid()` en ningún punto**, así que cualquier
-- `authenticated` podía lanzar la ola de una solicitud ajena — escribir
-- `event_lat/event_lng/radius_km/use_radius_expansion/current_wave=1/
-- wave1_sent_at/notified_count` en ella y disparar avisos reales a 3 grupos
-- alrededor de coordenadas que él elegía. Además dejaba la solicitud en
-- `wave_already_started`, así que el cliente legítimo ya no podía lanzarla.
--
-- ── LO QUE **NO** CAMBIA ───────────────────────────────────────────────────
-- · La **firma** es idéntica: 5 argumentos, mismos nombres y tipos y **los
--   mismos 4 DEFAULT** que ya tenía en producción (verificado con
--   `pg_get_function_arguments`: `p_event_lat DEFAULT NULL`,
--   `p_event_lng DEFAULT NULL`, `p_radius_km DEFAULT 50`,
--   `p_use_radius_expansion DEFAULT false`; `pronargdefaults = 4`). Reproducirlos
--   es obligatorio: quitar uno hace fallar el CREATE OR REPLACE con 42P13
--   ("cannot remove parameter defaults from existing function") y además podría
--   alterar cómo PostgREST resuelve la llamada. La app instalada y la candidata
--   siguen llamando igual, con sus 4 claves.
-- · El **top 3** sigue siendo top 3: `_send_wave(v_req, 0, 3, v_urgent)` queda
--   letra por letra igual.
-- · El **algoritmo de matching** no se toca: `_send_wave` no se modifica.
-- · El radio, la urgencia (< 6 h), la expansión de radio, el `notified_count` y
--   el JSON de respuesta quedan idénticos.
-- · Los códigos de error existentes se conservan: `request_not_found` y
--   `wave_already_started`.
--
-- ── LO ÚNICO QUE CAMBIA ───────────────────────────────────────────────────
-- La búsqueda inicial de la solicitud pasa de
--     SELECT * FROM event_requests WHERE id = p_request_id;
-- a una búsqueda **acotada al dueño** cuando hay sesión:
--     WHERE id = p_request_id AND client_id = auth.uid()
-- Consecuencias buscadas:
--   · A lanza la suya ................................ igual que hoy
--   · B intenta lanzar la de A ....................... `request_not_found`
--   · id inventado ................................... `request_not_found`
--   → **el mismo texto en los dos casos**, así que no sirve como oráculo de
--     existencia: no hay enumeración útil.
--
-- ── BACKEND Y CRON ────────────────────────────────────────────────────────
-- Cuando NO hay sesión se distingue por el claim del JWT:
--   · `auth.role() = 'service_role'` (Edge Functions / backend) → sin filtro de
--     dueño, como hoy.
--   · sin JWT (`auth.role()` NULL → '') → llamada directa de `postgres`, psql o
--     `pg_cron` → sin filtro de dueño, como hoy.
--   · cualquier otro rol sin uid (p. ej. `anon`) → `unauthorized`. Defensa en
--     profundidad: desde sql/708 `anon` ya no tiene EXECUTE.
-- Hoy esto es teórico y está verificado: **0 funciones, 0 triggers, 0 crons, 0
-- Edge Functions y 0 llamadas de web/ invocan `notify_wave_1`**. El cron 7
-- (`process-express-waves`) llama `process_notification_waves()`, que es otra
-- función y escala las olas 2/3 por su cuenta sin pasar por aquí.
--
-- ── LOS 2 LLAMADORES REALES SIGUEN FUNCIONANDO ────────────────────────────
-- `GuidedRequestScreen:290` y `OpenRequestScreen:544` llaman inmediatamente
-- después de INSERTAR la solicitud con `client_id = user.id` (el mismo
-- `auth.uid()` de la sesión), así que la solicitud **siempre es propia**.
-- `GuidedRequestScreen` usa `rpcResult?.notified ?? 0` para su alerta: el JSON de
-- la ruta feliz no cambia.
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

DO $guard$
DECLARE v_n INT;
BEGIN
  SELECT COUNT(*) INTO v_n FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND p.proname='notify_wave_1';
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'Se esperaba 1 firma de notify_wave_1 y hay %. Reauditar (sql/704).', v_n;
  END IF;
  IF (SELECT md5(prosrc) FROM pg_proc
      WHERE oid = to_regprocedure('public.notify_wave_1(uuid, double precision, double precision, double precision, boolean)'))
     <> 'cff1e818611c0d77fde4f4a8efe16837' THEN
    RAISE EXCEPTION 'El cuerpo de notify_wave_1 no es el auditado. Abortando.';
  END IF;
  IF to_regprocedure('public._send_wave(record, integer, integer, boolean)') IS NULL THEN
    RAISE EXCEPTION 'No existe _send_wave(record,int,int,boolean). Abortando.';
  END IF;
END
$guard$;

CREATE OR REPLACE FUNCTION public.notify_wave_1(
  p_request_id           UUID,
  p_event_lat            DOUBLE PRECISION DEFAULT NULL::double precision,
  p_event_lng            DOUBLE PRECISION DEFAULT NULL::double precision,
  p_radius_km            DOUBLE PRECISION DEFAULT 50,
  p_use_radius_expansion BOOLEAN          DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_req            RECORD;
  v_sent           INT;
  v_urgent         BOOLEAN;
  v_initial_radius DOUBLE PRECISION;
  v_uid            UUID;
  v_role           TEXT;
BEGIN
  -- sql/711 — frontera de autorizacion. Un id inventado y uno ajeno devuelven
  -- EXACTAMENTE el mismo error, asi que esto no sirve para enumerar.
  v_uid  := auth.uid();
  v_role := COALESCE(auth.role(), '');

  IF v_uid IS NOT NULL THEN
    -- usuario con sesion: solo su propia solicitud
    SELECT * INTO v_req FROM public.event_requests
    WHERE id = p_request_id AND client_id = v_uid;
  ELSIF v_role = 'service_role' OR v_role = '' THEN
    -- backend (service_role) o llamada directa sin JWT (postgres / pg_cron)
    SELECT * INTO v_req FROM public.event_requests WHERE id = p_request_id;
  ELSE
    RETURN jsonb_build_object('ok', false, 'error', 'unauthorized');
  END IF;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'request_not_found');
  END IF;

  IF v_req.current_wave > 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'wave_already_started');
  END IF;

  v_initial_radius := CASE WHEN p_use_radius_expansion THEN 5.0 ELSE p_radius_km END;

  v_urgent := (
    v_req.event_date::TIMESTAMP +
    COALESCE((v_req.event_time)::INTERVAL, INTERVAL '0') - NOW()
  ) < INTERVAL '6 hours';

  UPDATE public.event_requests
  SET event_lat            = p_event_lat,
      event_lng            = p_event_lng,
      radius_km            = v_initial_radius,
      use_radius_expansion = p_use_radius_expansion,
      current_wave         = 1,
      wave1_sent_at        = NOW()
  WHERE id = p_request_id;

  SELECT * INTO v_req FROM public.event_requests WHERE id = p_request_id;

  -- Top 3 (quick matching) — suficiente para primera respuesta rápida
  v_sent := _send_wave(v_req, 0, 3, v_urgent);

  UPDATE public.event_requests
  SET notified_count = notified_count + v_sent
  WHERE id = p_request_id;

  RETURN jsonb_build_object(
    'ok',                   true,
    'wave',                 1,
    'notified',             v_sent,
    'urgent',               v_urgent,
    'initial_radius_km',    v_initial_radius,
    'use_radius_expansion', p_use_radius_expansion
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$function$;

-- ACL: exactamente la que dejó sql/708 (sin PUBLIC, sin anon).
REVOKE EXECUTE ON FUNCTION
  public.notify_wave_1(UUID, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION, BOOLEAN) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION
  public.notify_wave_1(UUID, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION, BOOLEAN) FROM anon;
GRANT EXECUTE ON FUNCTION
  public.notify_wave_1(UUID, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION, BOOLEAN)
  TO authenticated, service_role;

COMMENT ON FUNCTION public.notify_wave_1(UUID, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION, BOOLEAN) IS
  'sql/704 dejo esta unica firma (top 3). sql/708 le quito el acceso anonimo. sql/711 agrego la frontera de autorizacion: con sesion solo se puede lanzar la ola de una solicitud propia (client_id = auth.uid()); un id ajeno y un id inventado devuelven el mismo request_not_found, asi que no hay enumeracion. service_role y las llamadas sin JWT (postgres/pg_cron) siguen sin filtro de dueno. Firma, top 3 y algoritmo de matching sin cambios.';

DO $verify$
DECLARE v_src TEXT;
BEGIN
  SELECT prosrc INTO v_src FROM pg_proc
  WHERE oid = to_regprocedure('public.notify_wave_1(uuid, double precision, double precision, double precision, boolean)');
  IF v_src NOT LIKE '%_send_wave(v_req, 0, 3, v_urgent)%' THEN
    RAISE EXCEPTION 'Se perdio la llamada al top 3. Abortando.';
  END IF;
  IF v_src NOT LIKE '%client_id = v_uid%' THEN
    RAISE EXCEPTION 'No quedo la frontera de autorizacion. Abortando.';
  END IF;
  IF has_function_privilege('anon',
       'public.notify_wave_1(uuid, double precision, double precision, double precision, boolean)', 'EXECUTE') THEN
    RAISE EXCEPTION 'anon recupero EXECUTE. Abortando.';
  END IF;
  IF NOT has_function_privilege('authenticated',
       'public.notify_wave_1(uuid, double precision, double precision, double precision, boolean)', 'EXECUTE') THEN
    RAISE EXCEPTION 'authenticated perdio EXECUTE. Abortando.';
  END IF;
END
$verify$;

NOTIFY pgrst, 'reload schema';

COMMIT;
