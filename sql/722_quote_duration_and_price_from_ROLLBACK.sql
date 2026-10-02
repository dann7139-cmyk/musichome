-- ═══════════════════════════════════════════════════════════════════════════
-- ROLLBACK de sql/722 — duración de la quote + price_from editable
-- ═══════════════════════════════════════════════════════════════════════════
-- NO SE EJECUTA salvo emergencia deliberada.
--
-- Devuelve las cuatro funciones a sus bytes EXACTOS anteriores (se comprueba con
-- md5 al final: si alguna no quedó idéntica, la transacción aborta) y quita lo
-- que 722 agregó.
--
-- ⚠ OJO: el paso 1 vuelve a DEJAR EL DEFECTO DE DURACIÓN. Una reserva creada
-- desde una cotización volvería a apartar solo 3 h en el calendario aunque la
-- quote diga 10. Solo tiene sentido si el arreglo rompió algo peor.
-- Las reservas que ya se crearon CON la duración correcta no se tocan: su
-- `hours_count` y su `busy_range` se quedan como están (correctos).
--
-- ⚠ El paso 4 BORRA los `price_from` capturados con el editor nuevo. Si solo se
-- quiere dejar de capturarlos, corre hasta el paso 3 y detente.
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

-- ── 1. client_accept_quote: quitar hours_count ──────────────────────────────
DO $rb1$
DECLARE
  v_def TEXT;
  v_nl  TEXT;
BEGIN
  SELECT pg_get_functiondef(oid) INTO v_def FROM pg_proc
  WHERE oid = to_regprocedure('public.client_accept_quote(uuid,uuid,integer)');
  v_nl := CASE WHEN v_def LIKE '%' || chr(13) || '%' THEN chr(13) || chr(10) ELSE chr(10) END;

  v_def := replace(v_def, ',' || v_nl || '      hours_count', '');
  v_def := replace(v_def, ',' || v_nl || '      v_quote.duration_hours', '');

  EXECUTE v_def;
END
$rb1$;

-- ── 2. Catálogo: volver a la versión de 5 campos (sin price_from) ───────────
DO $rb2$
DECLARE
  v_def TEXT;
  v_nl  TEXT;
BEGIN
  SELECT pg_get_functiondef(oid) INTO v_def FROM pg_proc
  WHERE proname = 'set_group_commercial_catalog' AND pronamespace = 'public'::regnamespace;
  v_nl := CASE WHEN v_def LIKE '%' || chr(13) || '%' THEN chr(13) || chr(10) ELSE chr(10) END;

  v_def := replace(v_def,
    '  p_capacity_max     INTEGER DEFAULT NULL,' || v_nl || '  p_price_from       NUMERIC DEFAULT NULL)',
    '  p_capacity_max     INTEGER DEFAULT NULL)');
  v_def := replace(v_def,
    '  -- price_from es un precio "desde", no una cotizacion: 0 no tiene sentido como' || v_nl ||
    '  -- gancho comercial pero tampoco hay razon para prohibirlo; solo se acota.' || v_nl ||
    '  IF p_price_from IS NOT NULL AND (p_price_from < 0 OR p_price_from > 10000000) THEN' || v_nl ||
    '    RETURN jsonb_build_object(''ok'', false, ''error'', ''invalid_price_from'');' || v_nl ||
    '  END IF;' || v_nl || v_nl, v_nl);
  v_def := replace(v_def,
    '      capacity_max     = p_capacity_max,' || v_nl || '      price_from       = p_price_from',
    '      capacity_max     = p_capacity_max');
  v_def := replace(v_def,
    '  -- Un "desde" sin decir cuantas horas incluye es lo que hace que el cliente' || v_nl ||
    '  -- crea que ese precio le alcanza para todo su evento.' || v_nl ||
    '  IF p_price_from IS NOT NULL AND p_included_hours IS NULL THEN' || v_nl ||
    '    v_avisos := array_append(v_avisos, ''price_without_included_hours'');' || v_nl ||
    '  END IF;' || v_nl, '');
  v_def := replace(v_def,
    '    ''capacity_max'',     p_capacity_max,' || v_nl || '    ''price_from'',       p_price_from,',
    '    ''capacity_max'',     p_capacity_max,');
  -- Reemplazo completo: el comentario del cuerpo vuelve a decir "4 campos".
  v_def := replace(v_def,
    '  -- Reemplazo completo de los 5 campos', '  -- Reemplazo completo de los 4 campos');

  EXECUTE v_def;

  DROP FUNCTION public.set_group_commercial_catalog(uuid,numeric,numeric,numeric,integer,numeric);
END
$rb2$;

REVOKE ALL ON FUNCTION public.set_group_commercial_catalog(uuid,numeric,numeric,numeric,integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.set_group_commercial_catalog(uuid,numeric,numeric,numeric,integer) FROM anon;
GRANT EXECUTE ON FUNCTION public.set_group_commercial_catalog(uuid,numeric,numeric,numeric,integer)
  TO authenticated, service_role;

-- ── 3. Registro / aprobación / cola de Admin: quitar price_from ─────────────
DO $rb3$
DECLARE
  v_def TEXT;
BEGIN
  SELECT pg_get_functiondef(oid) INTO v_def FROM pg_proc
  WHERE proname = 'submit_provider_application' AND pronamespace = 'public'::regnamespace;
  v_def := replace(v_def,
    'p_capacity_max integer DEFAULT NULL::integer, p_price_from numeric DEFAULT NULL::numeric)',
    'p_capacity_max integer DEFAULT NULL::integer)');
  v_def := replace(v_def,
    'notes, included_hours, extra_hour_price, capacity_max, price_from)',
    'notes, included_hours, extra_hour_price, capacity_max)');
  v_def := replace(v_def,
    'p_included_hours, p_extra_hour_price, p_capacity_max, p_price_from)',
    'p_included_hours, p_extra_hour_price, p_capacity_max)');
  EXECUTE v_def;
  DROP FUNCTION public.submit_provider_application(
    text, text, text, integer, numeric, text, text, text, text, numeric, numeric, integer, numeric);

  SELECT pg_get_functiondef(oid) INTO v_def FROM pg_proc
  WHERE oid = to_regprocedure('public.admin_approve_provider_application(uuid,text,text,text)');
  v_def := replace(v_def,
    '    min_hours, included_hours, extra_hour_price, capacity_max, price_from',
    '    min_hours, included_hours, extra_hour_price, capacity_max');
  v_def := replace(v_def,
    '    v_app.min_hours, v_app.included_hours, v_app.extra_hour_price, v_app.capacity_max, v_app.price_from',
    '    v_app.min_hours, v_app.included_hours, v_app.extra_hour_price, v_app.capacity_max');
  EXECUTE v_def;

  SELECT pg_get_functiondef(oid) INTO v_def FROM pg_proc
  WHERE oid = to_regprocedure('public.admin_get_provider_applications(text)');
  v_def := replace(v_def, ' ''price_from'', a.price_from,', '');
  EXECUTE v_def;
END
$rb3$;

GRANT EXECUTE ON FUNCTION public.submit_provider_application(
  text, text, text, integer, numeric, text, text, text, text, numeric, numeric, integer)
  TO anon, authenticated, service_role;

-- ── 4. Columnas y CHECK (BORRA price_from capturado — ver la nota) ──────────
ALTER TABLE public.groups
  DROP CONSTRAINT IF EXISTS chk_groups_price_from;

ALTER TABLE public.provider_applications
  DROP CONSTRAINT IF EXISTS chk_papps_price_from;

ALTER TABLE public.provider_applications
  DROP COLUMN IF EXISTS price_from;

-- `groups.price_from` NO se borra: existía desde antes de 722 y la web la lee.
COMMENT ON COLUMN public.groups.price_from IS NULL;

-- ── 5. Prueba de identidad: los bytes deben ser los de antes de 722 ─────────
DO $verify$
BEGIN
  IF (SELECT md5(prosrc) FROM pg_proc WHERE oid = to_regprocedure('public.client_accept_quote(uuid,uuid,integer)'))
     <> '59d981aa1793176834b22c09b0f9c21e' THEN
    RAISE EXCEPTION 'client_accept_quote NO volvio a sus bytes originales. Abortando el rollback.';
  END IF;
  IF (SELECT md5(prosrc) FROM pg_proc
      WHERE oid = to_regprocedure('public.set_group_commercial_catalog(uuid,numeric,numeric,numeric,integer)'))
     <> '8c9436c531b039a43b0a35f5f6db2772' THEN
    RAISE EXCEPTION 'set_group_commercial_catalog NO volvio a sus bytes de sql/720. Abortando el rollback.';
  END IF;
  IF (SELECT md5(prosrc) FROM pg_proc
      WHERE oid = to_regprocedure('public.submit_provider_application(text,text,text,integer,numeric,text,text,text,text,numeric,numeric,integer)'))
     <> '8e9e8529822004fbe10345504d42b067' THEN
    RAISE EXCEPTION 'submit_provider_application NO volvio a sus bytes de sql/720. Abortando el rollback.';
  END IF;
  IF (SELECT md5(prosrc) FROM pg_proc WHERE oid = to_regprocedure('public.admin_approve_provider_application(uuid,text,text,text)'))
     <> '1e6f02b8de3dc3a64f5f6c981f3e9e26' THEN
    RAISE EXCEPTION 'admin_approve_provider_application NO volvio a sus bytes de sql/720. Abortando.';
  END IF;
  IF (SELECT md5(prosrc) FROM pg_proc WHERE oid = to_regprocedure('public.admin_get_provider_applications(text)'))
     <> '36c689b14e4d87ed0890f00c922c51c5' THEN
    RAISE EXCEPTION 'admin_get_provider_applications NO volvio a sus bytes de sql/720. Abortando.';
  END IF;
END
$verify$;

NOTIFY pgrst, 'reload schema';

COMMIT;
