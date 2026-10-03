-- ═══════════════════════════════════════════════════════════════════════════
-- ROLLBACK de sql/726 — lockdown por columnas de groups
-- ═══════════════════════════════════════════════════════════════════════════
-- ⚠ Este archivo DEVUELVE a un proveedor la capacidad de auto-concederse Plus,
-- boost, bid, verificado, destacado, comisión 0 y de borrarse sus propios
-- strikes y su suspensión, editando su fila de `groups`. Probado antes del
-- parche: 1 fila afectada, sin error.
--
-- En 4 pasos, de menor a mayor daño. Corre el MÍNIMO que resuelva tu problema.
--
--   PASO 1 — devuelve UPDATE de tabla a `authenticated`, dejando el trigger.
--            Úsalo si una pantalla legítima empezó a fallar con 42501 por una
--            columna de perfil que no estaba en la lista concedida. ESTE es el
--            rollback probable y NO reabre el agujero (el trigger sigue).
--   PASO 2 — apaga el trigger, dejando los permisos por columna. Úsalo si el
--            trigger rechaza un flujo legítimo de Admin o del backend.
--   PASO 3 — ⚠ REABRE EL AGUJERO: quita el trigger y devuelve todo a authenticated.
--   PASO 4 — devuelve también el UPDATE a `anon` (no hay ningún flujo que lo pida;
--            es solo para volver al estado exacto previo).
--
-- `update_group_rating` NO se revierte a SECURITY INVOKER: devolverla crearía
-- otra vez un camino para que un cliente escriba `groups.rating`, y el cuerpo es
-- idéntico. Si de verdad hiciera falta, está al final, comentada.
-- ═══════════════════════════════════════════════════════════════════════════

-- ───────────────────────────────────────────────────────────────────────────
-- PASO 1 — devolver UPDATE de tabla a authenticated (el trigger sigue puesto)
-- ───────────────────────────────────────────────────────────────────────────
BEGIN;
GRANT UPDATE ON public.groups TO authenticated;
DO $v1$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid='public.groups'::regclass
                 AND tgname='trg_00_guard_platform_columns' AND tgenabled='O') THEN
    RAISE EXCEPTION 'El trigger de guarda NO esta activo: esto si reabriria el agujero. Abortando.';
  END IF;
END
$v1$;
COMMIT;

-- ───────────────────────────────────────────────────────────────────────────
-- PASO 2 — apagar SOLO el trigger (los permisos por columna siguen)
-- ───────────────────────────────────────────────────────────────────────────
/*  Descomenta para ejecutarlo.
BEGIN;
ALTER TABLE public.groups DISABLE TRIGGER trg_00_guard_platform_columns;
COMMIT;
*/

-- ───────────────────────────────────────────────────────────────────────────
-- PASO 3 — ⚠ REABRE EL AGUJERO: fuera el trigger y UPDATE completo de vuelta
-- ───────────────────────────────────────────────────────────────────────────
/*  Descomenta para ejecutarlo. SABIENDO QUE REABRE EL AGUJERO.
BEGIN;
DROP TRIGGER IF EXISTS trg_00_guard_platform_columns ON public.groups;
DROP FUNCTION IF EXISTS public.guard_group_platform_columns();
GRANT UPDATE ON public.groups TO authenticated;
COMMIT;
*/

-- ───────────────────────────────────────────────────────────────────────────
-- PASO 4 — devolver UPDATE a anon (estado exacto previo a 726)
-- ───────────────────────────────────────────────────────────────────────────
/*  Descomenta para ejecutarlo. Ningun flujo lo necesita.
BEGIN;
GRANT UPDATE ON public.groups TO anon;
COMMIT;
*/

-- ───────────────────────────────────────────────────────────────────────────
-- OPCIONAL — update_group_rating de vuelta a SECURITY INVOKER
-- No recomendado: volveria a exigir que el cliente tenga escritura sobre
-- groups.rating, que es como podia inflarse su propia calificacion.
-- ───────────────────────────────────────────────────────────────────────────
/*
BEGIN;
DO $rb$
DECLARE v_def TEXT;
BEGIN
  SELECT pg_get_functiondef(oid) INTO v_def FROM pg_proc
  WHERE oid = to_regprocedure('public.update_group_rating()');
  v_def := replace(v_def, chr(10) || ' SECURITY DEFINER', '');
  v_def := replace(v_def, chr(10) || ' SET search_path TO ''public''', '');
  EXECUTE v_def;
END
$rb$;
DO $v$
BEGIN
  IF (SELECT md5(prosrc) FROM pg_proc WHERE oid = to_regprocedure('public.update_group_rating()'))
     <> '80b63a72a83e76bbc696ac68412ecee5' THEN
    RAISE EXCEPTION 'update_group_rating NO volvio a sus bytes originales. Revisar a mano.';
  END IF;
END
$v$;
COMMIT;
*/

NOTIFY pgrst, 'reload schema';
