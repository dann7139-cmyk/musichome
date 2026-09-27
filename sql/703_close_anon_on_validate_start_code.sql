-- ═══════════════════════════════════════════════════════════════════════════
-- 703 — cierra el acceso ANÓNIMO a `validate_start_code`
-- ═══════════════════════════════════════════════════════════════════════════
-- PUENTE DE MIGRACIÓN, compatible con la app instalada. Retira PUBLIC y anon y
-- **conserva temporalmente `authenticated`**, que es lo que la versión instalada
-- necesita. No cambia el cuerpo de ninguna función, ni tablas, ni datos, ni
-- policies, ni RLS, ni nada económico. Solo quita permisos.
--
-- ── POR QUÉ SE PUEDE APLICAR ANTES DEL BUILD ───────────────────────────────
-- Demostrado que la app instalada llama esta RPC SIEMPRE como `authenticated`,
-- nunca como `anon`:
--   1. `navigation/AppNavigator.tsx:963` → `if (!session) return <pantallas de
--      auth>`: sin sesión solo se montan Intro/Login/Register. El stack del
--      grupo no existe.
--   2. `EventTimer` está registrado únicamente dentro de `{role === 'group' &&
--      …}` (línea 1115), y `role` viene de `useAuth()`, que se deriva del perfil
--      del usuario con sesión.
--   3. El cliente Supabase se crea con `persistSession: true`
--      (`src/config/supabase.ts`), así que en cuanto hay sesión manda
--      `Authorization: Bearer <access_token>` y PostgREST resuelve el rol del
--      claim → `authenticated`.
--   4. Refuerzo independiente: para tener el objeto `reservation` que la
--      pantalla usa, alguien tuvo que LEERLO bajo RLS, y todas las policies de
--      SELECT de `reservations` exigen `auth.uid()`. Con `anon`, `auth.uid()` es
--      NULL → 0 filas → el modal del código no puede ni abrirse.
--
-- ── POR QUÉ NO BASTA `REVOKE ... FROM anon` ────────────────────────────────
-- Esta función tenía `=X/postgres` en su ACL, es decir EXECUTE para **PUBLIC**.
-- `anon` lo hereda. Quitarle solo el grant nominal de `anon` habría dejado el
-- acceso intacto por la vía de PUBLIC. Por eso se revoca a los dos, y las
-- pruebas lo comprueban con `has_function_privilege`, que mide el permiso
-- EFECTIVO y no la ACL literal.
--
-- ── QUÉ RIESGO CIERRA ──────────────────────────────────────────────────────
-- `validate_start_code` no escribe nada, pero es un ORÁCULO: compara el
-- `arrival_code` de CUALQUIER reserva y responde si acertaste, sin comprobar
-- identidad y sin límite de intentos. El código es de 4 dígitos (1000-9999). Con
-- PUBLIC/anon, cualquiera con la llave pública de la app podía enumerarlo sin
-- tener cuenta. Tras esto hace falta al menos una sesión válida.
--
-- NO cierra todavía el acceso de un `authenticated` cualquiera: eso es `sql/700`,
-- que necesita que la app publicada use `group_validate_start_code`. Este archivo
-- es deliberadamente el subconjunto que NO rompe a nadie.
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

REVOKE EXECUTE ON FUNCTION public.validate_start_code(UUID, TEXT) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.validate_start_code(UUID, TEXT) TO postgres, service_role, authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
