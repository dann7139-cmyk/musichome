-- ============================================================
-- 549_start_event_server_clock.sql
--
-- PROPÓSITO
--   Corregir la desincronización del cronómetro de evento entre
--   grupo/cliente/talento: reservations.event_started_at se escribía
--   con la hora del PROPIO celular del grupo (`new Date()` en
--   EventTimerScreen.tsx, UPDATE directo desde el cliente), en vez
--   de con el reloj del servidor. Los otros dos caminos que existen
--   para iniciar un evento (inicio forzado por admin, sql/443;
--   arranque automático por cron, sql/344) ya usan NOW()/hora de
--   servidor — este es el único camino (el más común: el grupo
--   iniciando manualmente) que no lo hacía.
--
-- CAMBIO
--   Nueva función start_event(), que hace el mismo UPDATE que ya
--   hacía el cliente (status, event_started_at, break_type,
--   music_minutes) pero con NOW() del servidor, con autorización
--   (solo el owner del grupo dueño de la reserva) e idempotencia
--   (si event_started_at ya tiene valor, no lo vuelve a pisar).
--   No toca ninguna otra tabla, no toca notificaciones (esas se
--   quedan igual que hoy, del lado del cliente — fuera de alcance
--   de este fix, que es exclusivamente sobre el reloj del ancla).
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.start_event(
  p_reservation_id uuid,
  p_break_type text,
  p_music_minutes integer
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_res      RECORD;
  v_owner_id UUID;
  v_caller   UUID := auth.uid();
BEGIN
  IF v_caller IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unauthorized');
  END IF;

  SELECT r.*, g.owner_id AS group_owner_id
  INTO   v_res
  FROM   public.reservations r
  JOIN   public.groups g ON g.id = r.group_id
  WHERE  r.id = p_reservation_id
  FOR UPDATE OF r;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'reservation_not_found');
  END IF;

  v_owner_id := v_res.group_owner_id;
  IF v_caller <> v_owner_id THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unauthorized');
  END IF;

  -- Idempotencia: si el evento ya se marcó como iniciado, no volver a
  -- pisar el ancla (evita que un doble-tap mueva el cronómetro).
  IF v_res.event_started_at IS NOT NULL THEN
    RETURN jsonb_build_object(
      'ok', true, 'skipped', true,
      'event_started_at', v_res.event_started_at
    );
  END IF;

  UPDATE public.reservations
  SET    status            = 'in_progress',
         event_started_at  = NOW(),
         break_type        = p_break_type,
         music_minutes     = p_music_minutes
  WHERE  id = p_reservation_id
  RETURNING event_started_at INTO v_res.event_started_at;

  RETURN jsonb_build_object(
    'ok', true,
    'event_started_at', v_res.event_started_at
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.start_event(UUID, TEXT, INT) TO authenticated;

COMMIT;

-- ════════════════════════════════════════════════════════════════════
-- VERIFICACIONES (ejecutar por separado después del COMMIT)
-- ════════════════════════════════════════════════════════════════════

-- V1: función existe, SECURITY DEFINER activo
SELECT prosecdef AS is_security_definer
FROM   pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE  n.nspname = 'public' AND p.proname = 'start_event';
-- Esperado: true

-- V2: grant a authenticated
SELECT COUNT(*) > 0 AS grant_authenticated
FROM   information_schema.role_routine_grants
WHERE  routine_schema = 'public' AND routine_name = 'start_event'
  AND  grantee = 'authenticated';
-- Esperado: true

SELECT '549_start_event_server_clock ✅' AS status;
