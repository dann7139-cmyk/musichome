-- ═══════════════════════════════════════════════════════════════════════════
-- 697 — ETAPA 2 (b): quita el UPDATE general de `reservations` a los roles
--       de la app y deja una sola columna inocua concedida
-- ═══════════════════════════════════════════════════════════════════════════
-- ⛔ NO APLICAR TODAVÍA. Ver "REQUISITOS" abajo: esta migración ROMPE cualquier
-- app instalada que todavía escriba `reservations` directamente, y el proyecto
-- NO tiene OTA (`expo-updates` no está instalado y `app.json` no tiene bloque
-- `updates`), así que un build ya distribuido conserva su bundle hasta que el
-- usuario instale uno nuevo desde la tienda.
--
-- ── QUÉ CIERRA ─────────────────────────────────────────────────────────────
-- Demostrado en transacción revertida antes de esta etapa: un cliente dueño de
-- su reserva podía cambiar por PostgREST `total_price` (10000 → 1),
-- `payment_status` → 'fully_paid', `payout_status` → 'released',
-- `commission_amount` → 0, la moneda, el `status`, la hora, la duración, y poner
-- `event_id`/`quote_id` en NULL. El dueño del grupo podía cambiar `total_price`
-- igual. La causa no son las policies (acotan bien la FILA) sino que
-- `reservations` tiene grants de tabla `arwdDxtm` para anon y authenticated —
-- el default de Supabase — y CERO permisos por columna.
--
-- ── POR QUÉ NO SE TOCAN LAS POLICIES ───────────────────────────────────────
-- Las 19 policies se quedan EXACTAMENTE como están (el usuario lo pidió: la
-- consolidación es la Etapa 3). RLS sigue siendo lo que limita la FILA; esta
-- migración limita las COLUMNAS. Las dos capas se complementan.
--
-- ── REQUISITOS ANTES DE APLICAR ────────────────────────────────────────────
--   1. `sql/696` aplicado (las 4 RPCs existen).
--   2. Una versión de la app que use esas RPCs publicada Y adoptada por los
--      usuarios instalados. Sin OTA esto significa build + submit + que la
--      gente actualice.
--   3. `sql/698` corrido y en verde.
-- Mientras (2) no se cumpla, aplicar esto deja a los usuarios instalados sin
-- poder guardar ubicación al reservar, sin reprogramar, y al proveedor sin
-- aceptar ni rechazar.
--
-- ── break_type: por qué SÍ se concede por columna ──────────────────────────
-- Verificado en producción antes de decidir:
--   · `CHECK (break_type = ANY (ARRAY['A','B','D']))` — dominio cerrado.
--   · tipo `text`, default NULL, sin índices.
--   · NINGÚN trigger de `reservations` lee `break_type` → cambiarlo no dispara
--     nada financiero (los 5 triggers financieros no lo miran).
--   · Lo leen 8 funciones y todas son de horario del evento en vivo
--     (`event_break_boundaries`, `notify_break_transitions`, `start_event`,
--     `auto_start_due_events`, `admin_force_start_event`) o de creación. Ninguna
--     de precio, payout ni comisión.
--   · No participa en `make_busy_range` → no altera `busy_range` ni la duración
--     facturable (eso es `hours_count`).
--   · Y sobre todo: `create_booking_with_event` ya recibe `p_break_type` DEL
--     CLIENTE al crear la reserva. Conceder la columna no otorga un privilegio
--     nuevo en especie, solo permite editar después lo que ya se eligió antes.
-- Nota honesta: con el grant por columna, tanto el proveedor (policy
-- `reservations_group_update_safe`) como el cliente dueño (policy
-- `client_update_own_reservations`) pueden cambiarlo en las filas que les
-- corresponden — igual que hoy. Un tercero sin relación no puede: lo frena RLS.
-- Si se quisiera "solo el proveedor", eso requiere una RPC y es un cambio de
-- producto, no de seguridad.
--
-- DELETE/TRUNCATE: hoy ya están bloqueados de hecho porque no existe ninguna
-- policy de DELETE, pero el grant sí está. Se revoca también por defensa en
-- profundidad; no cambia ningún comportamiento observable.
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

-- Guarda: no cerrar los permisos si las RPCs sustitutas no existen.
DO $guard$
BEGIN
  IF to_regprocedure('public.client_set_booking_location(uuid, text, text)')  IS NULL
  OR to_regprocedure('public.client_reschedule_reservation(uuid, date)')      IS NULL
  OR to_regprocedure('public.group_accept_booking(uuid)')                     IS NULL
  OR to_regprocedure('public.group_decline_booking(uuid)')                    IS NULL THEN
    RAISE EXCEPTION 'Falta alguna RPC de sql/696: aplica 696 antes de 697';
  END IF;
END
$guard$;

REVOKE UPDATE, DELETE, TRUNCATE ON TABLE public.reservations FROM anon, authenticated;

-- Única columna concedida, por los motivos justificados arriba.
GRANT UPDATE (break_type) ON TABLE public.reservations TO authenticated;

-- SELECT e INSERT se conservan intactos: leer y crear siguen pasando por RLS
-- como hasta hoy, y `create_booking_with_event` sigue insertando como definidor.
GRANT SELECT, INSERT ON TABLE public.reservations TO anon, authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
