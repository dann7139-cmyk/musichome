-- ═══════════════════════════════════════════════════════════════════════════
-- 708 — cierra el acceso ANONIMO a `notify_wave_1`
-- ═══════════════════════════════════════════════════════════════════════════
-- Migración mínima de ACL. NO toca el cuerpo de la función, ni el top 3, ni
-- policies, ni tablas, ni nada financiero. Solo quita EXECUTE a PUBLIC y anon.
--
-- ── ESTADO ANTES (medido, no deducido) ─────────────────────────────────────
-- Una sola firma (la de 5 argumentos que dejó sql/704), oid 51640:
--   acl = {=X/postgres, postgres=X/postgres, anon=X/postgres,
--          authenticated=X/postgres, service_role=X/postgres}
-- El `=X/postgres` inicial es **PUBLIC con EXECUTE**, así que no basta con
-- revocar a `anon`: hay que revocar a PUBLIC también, o anon lo hereda.
--   has_function_privilege('anon', ..., 'EXECUTE') = true
--
-- ── POR QUÉ ES SEGURO: la app SIEMPRE llama como `authenticated` ───────────
-- 1. Solo hay 2 llamadores en todo el repositorio:
--      src/screens/client/GuidedRequestScreen.tsx:290
--      src/screens/client/OpenRequestScreen.tsx:544
--    (los de `para_asesor/code/` son copias de documentación, no se compilan).
-- 2. Ambas pantallas exigen sesión ANTES de llegar a la llamada:
--      GuidedRequestScreen:241  const { data:{user} } = await supabase.auth.getUser();
--      GuidedRequestScreen:242  if (!user) { Alert(...sessionNotFound); return; }
--      OpenRequestScreen:488    idéntico, y usa `user.id` como client_id del insert
--    Es decir: sin sesión no se inserta la solicitud y nunca se llega a la RPC.
-- 3. Ambas pantallas están registradas SOLO detrás del gate de sesión:
--    `navigation/AppNavigator.tsx:963  if (!session) { ...solo Intro/Login/Register... }`
--    Los registros de `GuidedRequest` / `OpenRequest` (1173, 1177, 1214, 1215,
--    1248, 1249) están todos después de ese return, y el de la línea 527 vive en
--    `ExploreStack()`, que solo se monta dentro de los tabs por rol.
-- 4. La llamada necesita `inserted.id` de un INSERT en `event_requests` hecho con
--    `client_id = user.id`; sin usuario no existe ese id.
-- Esto aplica igual a la app INSTALADA y a la nueva: el cambio es de ACL, no de
-- firma ni de contrato, así que un binario viejo autenticado sigue funcionando.
--
-- ── NINGUNA DEPENDENCIA LEGÍTIMA DE anon ──────────────────────────────────
--   · funciones SQL que la invocan ......... NINGUNA (0 en pg_proc.prosrc)
--   · triggers ............................ NINGUNO
--   · crons ............................... NINGUNO  (el cron 7,
--       `process-express-waves`, llama `process_notification_waves()`, que corre
--       como `postgres` y escala las olas 2/3 por su cuenta — no pasa por aquí)
--   · Edge Functions ...................... NINGUNA
--   · web/ ................................ NINGUNA
--   · app ................................. 2 sitios, ambos autenticados
-- Y `service_role` conserva EXECUTE, así que cualquier llamada de servidor futura
-- sigue teniendo camino.
--
-- ── QUÉ PODÍA HACER UN ANÓNIMO HOY (por qué vale cerrarlo) ────────────────
-- La función NO valida `auth.uid()` en ningún punto: con solo el `p_request_id`
-- escribe `event_lat/event_lng/radius_km/use_radius_expansion/current_wave=1/
-- wave1_sent_at/notified_count` en esa solicitud y dispara notificaciones reales a
-- los 3 grupos mejor rankeados alrededor de las coordenadas que mande el llamante.
-- Con la anon key (que es pública por diseño, va dentro del binario) un tercero
-- podía: quemar la ola 1 de una solicitud ajena (queda `wave_already_started` y el
-- cliente real ya no puede lanzarla), avisar a grupos de coordenadas inventadas, y
-- usar las 3 respuestas distintas (`request_not_found` / `wave_already_started` /
-- `ok`) como oráculo de existencia. Esta migración le quita esa vía sin sesión.
--
-- ── LO QUE ESTA MIGRACIÓN **NO** ARREGLA (reportado, fuera de alcance) ────
-- `authenticated` sigue pudiendo llamarla para una solicitud que no es suya, y la
-- policy `er_service_all` de `event_requests` es `FOR ALL TO PUBLIC USING (true)
-- WITH CHECK (true)`, con `anon` teniendo SELECT/INSERT/UPDATE de tabla. Eso es un
-- agujero MAYOR y **separado**, que no se toca aquí porque no está autorizado.
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

DO $guard$
DECLARE
  v_oid OID;
  v_n   INT;
BEGIN
  SELECT COUNT(*) INTO v_n
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'notify_wave_1';
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'Se esperaba 1 firma de notify_wave_1 y hay %. Reauditar (sql/704).', v_n;
  END IF;

  v_oid := to_regprocedure('public.notify_wave_1(uuid, double precision, double precision, double precision, boolean)');
  IF v_oid IS NULL THEN
    RAISE EXCEPTION 'No existe la firma de 5 argumentos. Abortando.';
  END IF;

  -- El cuerpo no se toca: se verifica que sigue siendo el que auditamos.
  IF (SELECT md5(prosrc) FROM pg_proc WHERE oid = v_oid) <> 'cff1e818611c0d77fde4f4a8efe16837' THEN
    RAISE EXCEPTION 'El cuerpo de notify_wave_1 cambio desde la auditoria. Reauditar antes de tocar su ACL.';
  END IF;
END
$guard$;

REVOKE EXECUTE ON FUNCTION
  public.notify_wave_1(UUID, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION, BOOLEAN)
  FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION
  public.notify_wave_1(UUID, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION, BOOLEAN)
  FROM anon;

-- Los que sí hacen falta (explícitos, para que el ACL quede legible).
GRANT EXECUTE ON FUNCTION
  public.notify_wave_1(UUID, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION, BOOLEAN)
  TO authenticated, service_role;

COMMENT ON FUNCTION public.notify_wave_1(UUID, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION, BOOLEAN) IS
  'sql/704 dejo esta unica firma (top 3). sql/708 cerro el acceso anonimo: EXECUTE solo para authenticated, service_role y postgres. Los 2 llamadores de la app exigen sesion antes de llamarla. OJO: no valida auth.uid() -> un authenticated todavia puede lanzar la ola de una solicitud ajena; eso sigue abierto y esta reportado.';

DO $verify$
BEGIN
  IF has_function_privilege('anon',
       'public.notify_wave_1(uuid, double precision, double precision, double precision, boolean)',
       'EXECUTE') THEN
    RAISE EXCEPTION 'anon SIGUE con EXECUTE efectivo. Abortando.';
  END IF;
  IF NOT has_function_privilege('authenticated',
       'public.notify_wave_1(uuid, double precision, double precision, double precision, boolean)',
       'EXECUTE') THEN
    RAISE EXCEPTION 'authenticated PERDIO EXECUTE. Abortando.';
  END IF;
  IF NOT has_function_privilege('service_role',
       'public.notify_wave_1(uuid, double precision, double precision, double precision, boolean)',
       'EXECUTE') THEN
    RAISE EXCEPTION 'service_role PERDIO EXECUTE. Abortando.';
  END IF;
END
$verify$;

NOTIFY pgrst, 'reload schema';

COMMIT;
