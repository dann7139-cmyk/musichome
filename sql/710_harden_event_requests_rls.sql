-- ═══════════════════════════════════════════════════════════════════════════
-- 710 — cierra el agujero de RLS de `event_requests`
-- ═══════════════════════════════════════════════════════════════════════════
-- NO toca columnas, ni constraints, ni triggers, ni índices, ni funciones, ni
-- pagos, ni el matching. Solo policies y grants de tabla.
--
-- ── LA CAUSA RAÍZ ──────────────────────────────────────────────────────────
-- `sql/65_event_requests.sql:100-104` creó:
--     -- Service role sin restricción (para Edge Functions)
--     CREATE POLICY "er_service_all" ON public.event_requests FOR ALL
--       USING (true) WITH CHECK (true);
-- El comentario dice **"service role"**, pero a la policy le faltó
-- `TO service_role`. Sin cláusula TO, Postgres la aplica a **PUBLIC**, o sea a
-- todos los roles. Verificado en `pg_policy`: `polroles = {0}` = PUBLIC.
-- Como es PERMISSIVE y su USING es `true`, se sumaba con OR a todas las demás y
-- las volvía decorativas.
--
-- ── LO QUE SE DEMOSTRÓ (transacción revertida, usuarios sintéticos) ────────
--   [anon SELECT] ....................... 1 fila visible (todas)
--   [anon UPDATE] ....................... 1 fila modificada
--   [anon INSERT] ....................... LOGRADO, a nombre de otro cliente
--   [anon DELETE] ....................... 1 fila borrada
--   [authenticated B SELECT la de A] .... 1 fila
--   [authenticated B UPDATE la de A] .... 1 fila, genre quedó en 'B_LA_TOCO'
--   [authenticated B DELETE la de A] .... 1 fila borrada
-- Con la publishable key (pública, va dentro del binario) eso era alcanzable
-- sin sesión.
--
-- ── POR QUÉ NO PUEDE ROMPER NADA DEL BACKEND ──────────────────────────────
-- Las **47** funciones que tocan `event_requests` son **todas** SECURITY DEFINER
-- y **todas** son de `postgres`, que es dueño de la tabla y tiene
-- `rolbypassrls = true` (verificado). `relforcerowsecurity = false`. Por lo
-- tanto RPCs, triggers y crons **no pasan por RLS** y este cambio no los altera:
-- ni `notify_wave_1`, ni `process_notification_waves` (cron 7, olas 2/3), ni
-- `dispatch_express_request`, ni `accept_event_request`, ni `expire_stale_requests`.
--
-- ── FLUJOS DIRECTOS REALES QUE SÍ DEPENDEN DE RLS (auditados uno por uno) ──
-- CLIENTE (todos con `client_id = auth.uid()`):
--   OpenRequestScreen:168  SELECT propias            → er_client_select
--   OpenRequestScreen:494  INSERT propia             → er_client_insert
--   OpenRequestScreen:238  UPDATE cancelar propia    → er_client_update
--   OpenRequestScreen:268  UPDATE elegir propuesta   → er_client_update
--   GuidedRequestScreen    INSERT propia             → er_client_insert
--   ProposalCarousel:190   UPDATE propia (por id)    → er_client_update
--   ClientProposalContext:131, HomeScreen:551, ReservationsScreen:211 → er_client_select
-- PROVEEDOR (solo lectura):
--   OpenRequestsScreen:583      open/en_negociacion + género + vigente
--   ScheduledQuotesCarousel:333 idéntica
--   group/DashboardScreen:788   conteo de 'open' del género
--   OpenRequestsScreen:595      status='accepted' + accepted_by_group_id propio
--   IncomingExpressScreen:534   una solicitud por id, vía su express_dispatch
--   ExpressContext:189          idéntica
--   EventTimerScreen:1389       lat/lng de la solicitud de SU reserva
-- ADMIN: admin/DashboardScreen y web AdminHomeReport:101 → er_admin_all
-- ANON: **ninguno**. No hay una sola lectura de event_requests antes de sesión.
--
-- ── COMPATIBILIDAD CON EL BINARIO INSTALADO ───────────────────────────────
-- Las consultas del proveedor cambiaron el 2026-09-26 (commit 9037eec) de
-- `.eq('genre', grp.genre)` a `.in('genre', splitGenres(grp.genre))`. La versión
-- vieja (la del binario instalado) es **más estrecha**, así que ya la cubría
-- `er_group_select` con su igualdad exacta. Para que la versión nueva (y
-- cualquier grupo con género compuesto, p. ej. el real "Norteño/Sierreño") siga
-- viendo lo mismo que hoy, se añade `er_group_genre_split_select`, que replica
-- **exactamente** `splitGenres()` de `src/constants/providerCategories.ts:162`
-- (partir por '/', trim, comparación sin distinguir mayúsculas). No es una regla
-- nueva de producto: es la que ya aplica la app.
--
-- ── QUÉ QUEDA (diseño final) ──────────────────────────────────────────────
--   cliente        → SELECT/INSERT/UPDATE **solo de sus solicitudes**
--   proveedor      → SOLO SELECT, y solo: (a) abiertas/en negociación vigentes
--                    de su género, (b) las que aceptó, (c) las que le fueron
--                    despachadas por express, (d) la de su propia reserva
--   cliente ajeno  → NADA de otro cliente (se cierra también la fuga de
--                    `groups_see_open_requests`, que dejaba a cualquier
--                    authenticated leer todas las solicitudes abiertas)
--   admin          → lo de siempre (er_admin_all)
--   service_role   → sin restricción (la intención original de sql/65)
--   postgres       → bypassa RLS por ser dueño (sin cambios)
--   anon           → NADA: sin policy que le aplique y además sin grants
--   DELETE         → solo admin y service_role (ningún flujo de app borra)
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

DO $guard$
DECLARE v_n INT;
BEGIN
  IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid='public.event_requests'::regclass) THEN
    RAISE EXCEPTION 'RLS no esta habilitada en event_requests. Abortando.';
  END IF;
  IF pg_get_userbyid((SELECT relowner FROM pg_class WHERE oid='public.event_requests'::regclass)) <> 'postgres' THEN
    RAISE EXCEPTION 'El dueno de event_requests ya no es postgres: reauditar el bypass de RLS del backend.';
  END IF;
  SELECT COUNT(*) INTO v_n FROM pg_policy WHERE polrelid='public.event_requests'::regclass;
  IF v_n <> 8 THEN
    RAISE EXCEPTION 'Se esperaban 8 policies en event_requests y hay %. Reauditar.', v_n;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_policy
    WHERE polrelid='public.event_requests'::regclass AND polname='er_service_all' AND polroles='{0}'
  ) THEN
    RAISE EXCEPTION 'er_service_all no esta como se audito (FOR ALL a PUBLIC). Abortando.';
  END IF;
  -- Ninguna funcion que toque la tabla debe depender de RLS: todas SECDEF de postgres.
  SELECT COUNT(*) INTO v_n FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND p.prosrc ILIKE '%event_requests%'
    AND (NOT p.prosecdef OR pg_get_userbyid(p.proowner) <> 'postgres');
  IF v_n <> 0 THEN
    RAISE EXCEPTION '% funciones que tocan event_requests NO son SECURITY DEFINER de postgres. Reauditar antes de tocar RLS.', v_n;
  END IF;
END
$guard$;

-- ── 1. La policy culpable: vuelve a su intención original ──────────────────
DROP POLICY "er_service_all" ON public.event_requests;

CREATE POLICY "er_service_all"
  ON public.event_requests
  FOR ALL
  TO service_role
  USING (true)
  WITH CHECK (true);

-- ── 2. Proveedor: género compuesto, igual que splitGenres() de la app ──────
CREATE POLICY "er_group_genre_split_select"
  ON public.event_requests
  FOR SELECT
  TO authenticated
  USING (
    status = ANY (ARRAY['open'::text, 'en_negociacion'::text])
    AND expires_at > now()
    AND EXISTS (
      SELECT 1
      FROM public.groups g
      WHERE g.owner_id = auth.uid()
        AND lower(btrim(event_requests.genre)) = ANY (
              SELECT lower(btrim(x)) FROM unnest(string_to_array(g.genre, '/')) AS x
            )
    )
  );

-- ── 3. Proveedor: la solicitud que le despacharon por express ─────────────
CREATE POLICY "er_group_dispatched_select"
  ON public.event_requests
  FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM public.express_dispatches ed
      JOIN public.groups g ON g.id = ed.group_id
      WHERE ed.request_id = event_requests.id
        AND g.owner_id = auth.uid()
    )
  );

-- ── 4. Proveedor: la solicitud de su propia reserva (lat/lng del timer) ────
CREATE POLICY "er_group_reservation_select"
  ON public.event_requests
  FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM public.reservations rr
      JOIN public.groups g ON g.id = rr.group_id
      WHERE rr.event_request_id = event_requests.id
        AND g.owner_id = auth.uid()
    )
  );

-- ── 5. Segunda policy con el mismo defecto: `groups_see_open_requests` ────
-- `sql/217_dispatch_express_request.sql:163-186` la creó bajo el título
-- "Política RLS para grupos", pero su USING **nunca comprueba que el llamante
-- tenga un grupo**: solo pide `status='open'`, vigente y fuera de la ventana
-- express. O sea que **cualquier `authenticated`, incluido un cliente
-- cualquiera, podía leer TODAS las solicitudes abiertas de TODOS los clientes**
-- (con su `client_id`, dirección y comentarios). Nadie lo notó porque
-- `er_service_all` ya lo permitía todo de todos modos.
-- Se recrea idéntica más la condición que le faltaba, la misma que ya usa su
-- RPC hermana `get_open_requests_for_group()` (`g.owner_id = auth.uid()`).
-- Para un proveedor no cambia nada; para un cliente ajeno cierra la fuga.
DROP POLICY "groups_see_open_requests" ON public.event_requests;

CREATE POLICY "groups_see_open_requests"
  ON public.event_requests
  FOR SELECT
  TO authenticated
  USING (
    status = 'open'
    AND expires_at > now()
    AND EXISTS (SELECT 1 FROM public.groups g2 WHERE g2.owner_id = auth.uid())
    AND (
      express_window_until IS NULL
      OR express_window_until < now()
      OR EXISTS (
        SELECT 1
        FROM public.express_dispatches ed
        JOIN public.groups g ON g.id = ed.group_id
        WHERE ed.request_id = event_requests.id
          AND g.owner_id    = auth.uid()
          AND ed.status     <> ALL (ARRAY['ignored'::text, 'expired'::text, 'taken'::text])
      )
    )
  );

-- ── 6. anon: se le retiran los grants de tabla (no hay flujo anónimo) ─────
REVOKE SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
  ON public.event_requests FROM anon;

COMMENT ON TABLE public.event_requests IS
  'sql/710 — RLS reparada. La policy er_service_all de sql/65 decia "service role" pero le faltaba TO service_role, asi que aplicaba a PUBLIC con USING(true): anon y cualquier authenticated podian leer, insertar, modificar y borrar solicitudes ajenas. Ahora: cliente solo las suyas; proveedor SOLO SELECT (su genero vigente, las que acepto, las que le despacharon, la de su reserva); admin igual que antes; service_role sin restriccion; anon sin grants. Las 47 funciones que la tocan son SECDEF de postgres y no pasan por RLS.';

DO $verify$
DECLARE v_n INT;
BEGIN
  SELECT COUNT(*) INTO v_n FROM pg_policy WHERE polrelid='public.event_requests'::regclass;
  IF v_n <> 11 THEN
    RAISE EXCEPTION 'Se esperaban 11 policies al terminar y hay %. Abortando.', v_n;
  END IF;
  IF EXISTS (
    SELECT 1 FROM pg_policy
    WHERE polrelid='public.event_requests'::regclass AND polname='er_service_all' AND polroles='{0}'
  ) THEN
    RAISE EXCEPTION 'er_service_all sigue aplicando a PUBLIC. Abortando.';
  END IF;
  IF has_table_privilege('anon','public.event_requests','SELECT')
     OR has_table_privilege('anon','public.event_requests','INSERT')
     OR has_table_privilege('anon','public.event_requests','UPDATE')
     OR has_table_privilege('anon','public.event_requests','DELETE') THEN
    RAISE EXCEPTION 'anon conserva grants sobre event_requests. Abortando.';
  END IF;
  IF NOT (has_table_privilege('authenticated','public.event_requests','SELECT')
      AND has_table_privilege('authenticated','public.event_requests','INSERT')
      AND has_table_privilege('authenticated','public.event_requests','UPDATE')) THEN
    RAISE EXCEPTION 'authenticated perdio grants necesarios. Abortando.';
  END IF;
  IF NOT has_table_privilege('service_role','public.event_requests','SELECT') THEN
    RAISE EXCEPTION 'service_role perdio acceso. Abortando.';
  END IF;
END
$verify$;

COMMIT;
