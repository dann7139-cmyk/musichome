-- ═══════════════════════════════════════════════════════════════════════════
-- 699 — ETAPA 2.5 (a): frontera de autorización del proveedor sobre llegada y
--       liberación de pago
-- ═══════════════════════════════════════════════════════════════════════════
-- ADITIVA. Solo crea 3 funciones nuevas que envuelven primitivas existentes.
-- NO modifica ninguna función existente, no revoca permisos, no toca policies,
-- RLS ni tablas.
--
-- ⚠️  NO CAMBIA NINGUNA REGLA ECONÓMICA. No toca porcentajes, cantidades, el
-- momento contractual del payout, wallets, comisiones, Stripe/Conekta, las
-- reglas de llegada, la regla GPS ni los estados financieros. Todas esas guardas
-- siguen viviendo, sin un solo cambio, dentro de las primitivas
-- (`release_group_earnings_atomic`, `release_half_on_arrival`,
-- `validate_start_code`). Lo único que se añade es: **quién puede pedirlo**.
--
-- ── EL AGUJERO QUE CIERRA ──────────────────────────────────────────────────
-- Las tres primitivas no comprueban NADA sobre el llamante:
--   · `validate_start_code(reservation, code)` — sin identidad, ejecutable por
--     `anon`, y no escribe: es un ORÁCULO. Permite adivinar por fuerza bruta el
--     código de 4 dígitos (1000-9999) de CUALQUIER reserva, sin límite de
--     intentos.
--   · `release_half_on_arrival(reservation, lat, lng)` — sin identidad. Marca
--     `group_arrived_at`. Su "candado GPS" compara contra coordenadas que envía
--     el propio llamante, así que es autoatestiguado.
--   · `release_group_earnings_atomic(reservation, released_by)` — sin identidad,
--     y sus guardas son solo de ESTADO, una de ellas `group_arrived_at`.
-- Cadena abusiva: un proveedor marca llegada sin estar ahí y libera su propio
-- pago. Con un `reservation_id` ajeno, opera sobre la reserva de otro grupo.
--
-- ── LA FUENTE CANÓNICA DE AUTORIZACIÓN (no se inventa ninguna) ─────────────
-- El patrón que YA usa el proyecto para "este auth.uid() manda en esta
-- reserva" es, textualmente, `JOIN groups g ON g.id = r.group_id` y
-- `g.owner_id = auth.uid()`. Lo usan `start_event`, `complete_event`,
-- `group_update_transit`, `group_confirm_booking`, `group_reject_booking` y las
-- RPCs de sql/696. Existe además el helper `is_group_owner(p_group_id)`
-- (SECURITY DEFINER, `search_path=public`) que encapsula exactamente eso; se usa
-- aquí para no duplicar la condición.
-- `is_group_member()` existe también (membresía permanente vía
-- `job_invitations`), pero NO se usa: `start_event` —el paso inmediatamente
-- posterior al código de inicio— ya exige **dueño**, así que exigir dueño aquí
-- no quita nada que hoy funcione de extremo a extremo.
--
-- ── NADA SENSIBLE SE DERIVA DE PARÁMETROS DEL CLIENTE ──────────────────────
-- Del llamante llega SOLO el `reservation_id` (y el código / las coordenadas,
-- que ya eran suyos). Todo lo demás —group_id, dueño, estado, pago, payout,
-- llegada, moneda— se lee del servidor a partir de la reserva. Un
-- `reservation_id` de otro grupo falla en la primera comprobación.
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

-- ═══════════════════════════════════════════════════════════════════════════
-- Helper interno: ¿el que llama manda en esta reserva?
-- ═══════════════════════════════════════════════════════════════════════════
-- Devuelve el group_id solo si auth.uid() es el dueño del grupo de esa reserva;
-- NULL en cualquier otro caso (no existe, no es suya, sin sesión). Así las tres
-- envolturas comparten una única condición y no se puede divergir entre ellas.
CREATE OR REPLACE FUNCTION public.reservation_group_if_owner(p_reservation_id UUID)
RETURNS UUID
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT r.group_id
  FROM public.reservations r
  JOIN public.groups g ON g.id = r.group_id
  WHERE r.id = p_reservation_id
    AND auth.uid() IS NOT NULL
    AND g.owner_id = auth.uid();
$function$;

REVOKE EXECUTE ON FUNCTION public.reservation_group_if_owner(UUID) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.reservation_group_if_owner(UUID) TO authenticated, service_role;
COMMENT ON FUNCTION public.reservation_group_if_owner(UUID) IS
  'sql/699 — devuelve el group_id de la reserva SOLO si auth.uid() es el dueño de ese grupo; NULL si no. Unica condicion de autorizacion compartida por las envolturas de la Etapa 2.5. Usa el mismo criterio que start_event/complete_event/group_update_transit.';

-- ═══════════════════════════════════════════════════════════════════════════
-- 1. group_validate_start_code — cierra el oráculo de fuerza bruta
-- ═══════════════════════════════════════════════════════════════════════════
-- Mismo comportamiento que `validate_start_code` para el llamante legítimo (el
-- dueño del grupo, que es quien teclea el código en EventTimerScreen), pero
-- inalcanzable para todos los demás.
--
-- POR QUÉ NO SE AÑADE UN LÍMITE DE INTENTOS NI SE ALARGA EL CÓDIGO:
-- el usuario pidió no inventar 6 dígitos ni CAPTCHA, y pidió evaluar si hace
-- falta un rate limit persistente. La respuesta honesta, con los datos: **no
-- añade seguridad real**, porque el dueño del grupo **ya puede LEER
-- `arrival_code` directamente** (4 policies de SELECT le dan la fila y no hay
-- ninguna restricción por columna: `has_column_privilege('authenticated',
-- 'reservations','arrival_code','SELECT')` = true). Para el proveedor el código
-- nunca fue un secreto, así que limitarle los intentos no cambia nada. Para
-- cualquier OTRO usuario, la comprobación de dueño ya elimina el acceso por
-- completo, y con ello la enumeración. Un límite de intentos sería una columna
-- nueva que no protege de nadie. Lo que sí queda REPORTADO —y no se toca aquí
-- porque cambiaría las reglas de llegada— es que el código, por construcción, no
-- puede servir como prueba de llegada frente a un proveedor malicioso.
CREATE OR REPLACE FUNCTION public.group_validate_start_code(
  p_reservation_id UUID,
  p_code           TEXT
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_group UUID;
BEGIN
  v_group := public.reservation_group_if_owner(p_reservation_id);
  IF v_group IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_group_owner');
  END IF;
  -- La comparación del código se delega tal cual: no se cambia el criterio.
  RETURN public.validate_start_code(p_reservation_id, p_code);
END;
$function$;

-- ═══════════════════════════════════════════════════════════════════════════
-- 2. group_confirm_arrival — marcar llegada, solo el proveedor de esa reserva
-- ═══════════════════════════════════════════════════════════════════════════
-- La regla GPS y el umbral de 250 m NO se tocan: siguen dentro de
-- `release_half_on_arrival`. Las coordenadas siguen siendo las que manda el
-- llamante — eso es una debilidad REPORTADA, no resuelta aquí, porque cambiarla
-- sería cambiar la regla de llegada.
CREATE OR REPLACE FUNCTION public.group_confirm_arrival(
  p_reservation_id UUID,
  p_lat            DOUBLE PRECISION DEFAULT NULL,
  p_lng            DOUBLE PRECISION DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_group UUID;
BEGIN
  v_group := public.reservation_group_if_owner(p_reservation_id);
  IF v_group IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_group_owner');
  END IF;
  RETURN public.release_half_on_arrival(p_reservation_id, p_lat, p_lng);
END;
$function$;

-- ═══════════════════════════════════════════════════════════════════════════
-- 3. group_release_earnings — la acción del proveedor, separada de la primitiva
-- ═══════════════════════════════════════════════════════════════════════════
-- Esta es la separación que pidió el usuario (opción B): la ACCIÓN PERMITIDA AL
-- PROVEEDOR queda aquí, y la PRIMITIVA FINANCIERA sigue intacta en
-- `release_group_earnings_atomic`. Ni una de sus guardas se duplica ni se
-- relaja: payout_status, payment_status, disputa abierta, llegada verificada,
-- moneda, idempotencia (`already_released`) y el reparto siguen exactamente
-- donde estaban.
--
-- `p_released_by` se rellena con `auth.uid()` siguiendo la convención que ya
-- usan los llamadores existentes: los admin pasan el id del admin
-- (`admin_release_reservation`, `admin_force_complete_event`,
-- `admin_verify_arrival_and_release`) y los automáticos pasan NULL
-- (`release_all_eligible_payments`, `release_event_payment`). Solo alimenta el
-- registro de auditoría; no interviene en ningún cálculo.
CREATE OR REPLACE FUNCTION public.group_release_earnings(p_reservation_id UUID)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_group UUID;
BEGIN
  v_group := public.reservation_group_if_owner(p_reservation_id);
  IF v_group IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_group_owner');
  END IF;
  RETURN public.release_group_earnings_atomic(p_reservation_id, auth.uid());
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.group_validate_start_code(UUID, TEXT)                        FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.group_confirm_arrival(UUID, DOUBLE PRECISION, DOUBLE PRECISION) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.group_release_earnings(UUID)                                 FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.group_validate_start_code(UUID, TEXT)                        TO authenticated, service_role;
GRANT  EXECUTE ON FUNCTION public.group_confirm_arrival(UUID, DOUBLE PRECISION, DOUBLE PRECISION) TO authenticated, service_role;
GRANT  EXECUTE ON FUNCTION public.group_release_earnings(UUID)                                 TO authenticated, service_role;

COMMENT ON FUNCTION public.group_validate_start_code(UUID, TEXT) IS
  'sql/699 (Etapa 2.5) — valida el codigo de inicio SOLO para el dueño del grupo de esa reserva. Cierra el oraculo de fuerza bruta de validate_start_code, que era ejecutable por anon y sin identidad. No cambia el criterio del codigo.';
COMMENT ON FUNCTION public.group_confirm_arrival(UUID, DOUBLE PRECISION, DOUBLE PRECISION) IS
  'sql/699 (Etapa 2.5) — marca llegada SOLO para el dueño del grupo de esa reserva. Delega en release_half_on_arrival sin tocar la regla GPS ni el umbral de 250 m. Las coordenadas siguen siendo del llamante: debilidad reportada, no resuelta aqui.';
COMMENT ON FUNCTION public.group_release_earnings(UUID) IS
  'sql/699 (Etapa 2.5) — accion del PROVEEDOR para liberar su pago, separada de la primitiva financiera. Verifica dueño del grupo y delega en release_group_earnings_atomic sin cambiar ni duplicar ninguna de sus guardas economicas. p_released_by = auth.uid(), siguiendo la convencion de los llamadores admin.';

NOTIFY pgrst, 'reload schema';

COMMIT;
