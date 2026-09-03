-- ============================================================
-- sql/591_group_sound_coordination.sql
-- ✅ APLICADO A PRODUCCIÓN 2026-09-01 con autorización explícita del
-- usuario. Probado antes en transacción autorevertible (9+ escenarios,
-- incluye orden de llegada en ambos sentidos, criterio "resuelto" de
-- extremo a extremo, y bloqueo de un usuario ajeno). Corrección de
-- seguridad aplicada EN CALIENTE justo después del deploy — ver
-- hallazgo real en el punto 1 de abajo (REVOKE faltante, ya corregido
-- y verificado por REST).
--
-- PROPÓSITO (petición real del usuario, 2026-09-01)
--   Cuando 2+ grupos cotizan el mismo evento y el cliente pidió sonido/
--   luz/escenario/led GRANDE, hoy cada grupo cotiza a ciegas sin saber si
--   el otro proveedor YA tiene el equipo grande cubierto. El usuario NO
--   quiere ser el puente telefónico entre ambos grupos — quiere que la
--   app les avise DIRECTAMENTE entre ellos para que se coordinen (uno le
--   cobra al otro por hora, y el que no tiene sonido absorbe ese costo en
--   su propio precio al cliente — cada quien manda su cotización normal,
--   el admin solo observa si ya se resolvió o sigue pendiente).
--
-- SEÑAL CORRECTA (distinta de sql/589/590 — hallazgo de esta ronda)
--   sql/589/590 miden lo que el CLIENTE pidió (quotes.needs_sound, mismo
--   valor típicamente en las 2-3 cotizaciones del mismo evento — sirve
--   para que EL ADMIN sepa que hay que vigilar el evento).
--   Esto es DISTINTO: mide si CADA GRUPO ya tiene el equipo propio que
--   cubre lo pedido (groups.has_sound/sound_capacity_max, has_lighting/
--   lighting_level, has_stage/stage_sizes_available, has_led_screen/
--   led_sizes_available) — exactamente la misma lógica que ya usa
--   QuoteFormScreen.tsx (getInclusionLabel) para mostrar "incluido" vs
--   "cotización extra" al cliente. Aquí se reutiliza esa misma regla,
--   pero para decidir A QUIÉN avisarle que le falta coordinarse con quién.
--
-- ALCANCE
--   1. get_sound_coordination_partner(event_id, group_id) — función
--      INTERNA, SIN GRANT a authenticated/anon (evita que cualquiera
--      consulte el teléfono de un grupo ajeno probando IDs). Solo la
--      llaman el trigger y la RPC pública de abajo, ambas SECURITY
--      DEFINER propiedad del mismo owner — no necesitan GRANT explícito
--      para invocarla entre sí.
--   2. group_get_sound_coordination(p_quote_id) — RPC pública, para el
--      banner dentro de la pantalla del grupo. Verifica que quien pregunta
--      sea dueño del grupo dueño de esa cotización (o integrante aceptado,
--      o admin) ANTES de resolver nada — sin esto, cualquier usuario
--      autenticado podría filtrar el teléfono de cualquier grupo.
--   3. Trigger AFTER INSERT en quotes — notificación push automática
--      cuando un grupo cotiza y YA existe otro proveedor capaz en el
--      mismo evento (orden más común). El orden inverso (el grupo SIN
--      equipo cotiza primero, el capaz llega después) NO dispara push —
--      decisión deliberada para no complicar el trigger; ese caso lo
--      cubre igual el banner (RPC #2), que siempre calcula en vivo.
--      DEFENSIVO: cualquier error dentro del trigger se atrapa y se
--      IGNORA — jamás debe poder tumbar la inserción real de una
--      cotización, que es el flujo de dinero más importante de la app.
--   4. admin_alerts()/admin_get_events_needing_review() — refinamiento:
--      un evento deja de aparecer como "por revisar" en cuanto TODOS sus
--      proveedores ya mandaron su cotización (status ≠ 'pending') — así
--      lo pidió el usuario explícitamente: "si le mandaron la cotización
--      al cliente que me aparezca como evento resuelto". Hash verificado
--      antes de tocarlas: admin_alerts='ff6f4dde8e85624205e3fd082fec22df',
--      admin_get_events_needing_review='2c055fffebc036a778321e10fa8659f0'
--      (2026-09-01).
--
-- QUÉ NO CAMBIA
--   - Ningún trigger existente en `quotes` se toca (trg_guard_quote_spam
--     es BEFORE INSERT; el nuevo es AFTER INSERT — no interfieren).
--   - Cero cambios a precios, comisiones, ni al flujo de aceptar/pagar.
-- ============================================================

BEGIN;

-- ── 0. notifications.type CHECK — agregar el tipo nuevo ─────────────────
-- HALLAZGO DE LA PRUEBA (2026-09-01): sin esto, CADA inserción de una
-- cotización que necesite coordinación habría fallado el push (atrapado
-- por el EXCEPTION del trigger — la cotización SÍ se habría guardado bien,
-- pero el aviso nunca habría llegado, silenciosamente). Se agrega
-- 'sound_coordination_needed' a la lista existente — ningún valor viejo
-- se toca ni se quita.
ALTER TABLE public.notifications DROP CONSTRAINT IF EXISTS notifications_type_check;
ALTER TABLE public.notifications ADD CONSTRAINT notifications_type_check
  CHECK ((type = ANY (ARRAY[
    'reservation'::text, 'payment'::text, 'review'::text, 'verification'::text, 'system'::text,
    'financial'::text, 'admin_alert'::text, 'admin'::text, 'general'::text, 'booking'::text,
    'booking_received'::text, 'booking_accepted'::text, 'booking_confirmed'::text, 'booking_rejected'::text,
    'booking_auto_cancelled'::text, 'booking_expired_no_payment'::text, 'booking_cancelled'::text,
    'deposit_received'::text, 'payment_released'::text, 'payment_received'::text, 'payment_mismatch'::text,
    'payout'::text, 'wallet'::text, 'event_reminder_24h'::text, 'event_upcoming_24h'::text,
    'event_reminder_morning'::text, 'event_reminder_1h'::text, 'event_reminder_3h'::text,
    'event_reminder_2h'::text, 'event_reminder_15m'::text, 'event_completed'::text, 'event_started'::text,
    'overtime_requested'::text, 'event_auto_started'::text, 'event_no_show_alert'::text, 'event_finalized'::text,
    'break_starting_soon'::text, 'break_ending_soon'::text, 'break_started'::text, 'break_ended'::text,
    'dispute_opened'::text, 'dispute_received'::text, 'dispute'::text, 'job_invitation'::text,
    'new_quote_request'::text, 'quote_received'::text, 'quote_accepted'::text, 'quote_cancelled'::text,
    'quote_sent_to_client'::text, 'quote_expired'::text, 'chat'::text, 'ad_space_available'::text,
    'high_demand'::text, 'no_ads_in_city'::text, 'first_ad_reminder'::text, 'ad_payment_confirmed'::text,
    'ad_approved'::text, 'ad_rejected'::text, 'ad_expiring_soon'::text, 'ad_expired'::text,
    'new_city_groups'::text, 'group_nearby'::text, 'bid_displaced'::text, 'bid_expiring_soon'::text,
    'bid_expiry_reminder'::text, 'zone_demand'::text, 'express_dispatch'::text, 'fraud_alert'::text,
    'referral_reward'::text, 'request_expired_proximity'::text, 'quote_expired_proximity'::text,
    'extra_hour_proposed'::text, 'extra_hour_approved_by_client'::text, 'extra_hour_payment_confirmed'::text,
    'extra_hour_rejected_by_client'::text, 'extra_hour_requested'::text, 'extra_hour_rejected'::text,
    'extra_hour_payment_required'::text, 'extra_hour_expired'::text, 'extra_hour_payment_expired'::text,
    'review_received'::text, 'extra_hours_offer'::text,
    'sound_coordination_needed'::text
  ]))) NOT VALID;

-- ── 1. Función interna — NUNCA debe ser accesible a authenticated/anon ──
-- HALLAZGO DE SEGURIDAD REAL (2026-09-01, encontrado en producción DESPUÉS
-- de aplicar este archivo la primera vez): "no otorgar EXECUTE" NO es lo
-- mismo que "sin acceso" — Postgres otorga EXECUTE a PUBLIC por default en
-- cada CREATE FUNCTION, así que sin un REVOKE explícito esta función SÍ
-- quedó llamable directo vía /rest/v1/rpc/get_sound_coordination_partner
-- por cualquier usuario autenticado (confirmado explotable por curl: HTTP
-- 200 con event_id/group_id arbitrarios, sin la verificación de dueño que
-- solo tiene el wrapper de abajo) — filtraba el teléfono de cualquier
-- grupo. Corregido en caliente con REVOKE en cuanto se detectó; el REVOKE
-- de abajo ahora es parte del archivo para que quede reproducible.
CREATE OR REPLACE FUNCTION public.get_sound_coordination_partner(
  p_event_id UUID, p_group_id UUID
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE
  v_has_sound BOOLEAN; v_sound_cap INT;
  v_has_light BOOLEAN; v_light_lvl TEXT;
  v_has_stage BOOLEAN; v_stage_sizes TEXT[];
  v_has_led   BOOLEAN; v_led_sizes TEXT[];
  v_missing   TEXT;
  v_partner_name  TEXT;
  v_partner_phone TEXT;
BEGIN
  SELECT has_sound, sound_capacity_max, has_lighting, lighting_level,
         has_stage, stage_sizes_available, has_led_screen, led_sizes_available
  INTO v_has_sound, v_sound_cap, v_has_light, v_light_lvl,
       v_has_stage, v_stage_sizes, v_has_led, v_led_sizes
  FROM public.groups WHERE id = p_group_id;

  IF NOT FOUND THEN RETURN jsonb_build_object('needed', false); END IF;

  -- ¿Qué nivel TOP se pidió en este evento (mismo umbral que sql/590) y
  -- este grupo NO cubre con su propio equipo? Se revisa en orden de
  -- prioridad: sonido primero (el caso real que describió el usuario).
  IF EXISTS (SELECT 1 FROM public.quotes WHERE event_id = p_event_id AND needs_sound IN ('si_200','si'))
     AND NOT (COALESCE(v_has_sound, false) AND COALESCE(v_sound_cap, 0) >= 200) THEN
    v_missing := 'sound';
  ELSIF EXISTS (SELECT 1 FROM public.quotes WHERE event_id = p_event_id AND needs_lighting = 'premium')
     AND NOT (COALESCE(v_has_light, false) AND v_light_lvl = 'premium') THEN
    v_missing := 'lighting';
  ELSIF EXISTS (SELECT 1 FROM public.quotes WHERE event_id = p_event_id AND needs_stage = 'wedding')
     AND NOT (COALESCE(v_has_stage, false) AND 'wedding' = ANY(COALESCE(v_stage_sizes, ARRAY[]::text[]))) THEN
    v_missing := 'stage';
  ELSIF EXISTS (SELECT 1 FROM public.quotes WHERE event_id = p_event_id AND needs_led = 'xl')
     AND NOT (COALESCE(v_has_led, false) AND 'xl' = ANY(COALESCE(v_led_sizes, ARRAY[]::text[]))) THEN
    v_missing := 'led';
  ELSE
    RETURN jsonb_build_object('needed', false); -- este grupo ya cubre todo, o nadie pidió nivel grande
  END IF;

  -- Buscar OTRO proveedor activo del mismo evento que SÍ cubra esa pieza.
  SELECT g.name, p.phone INTO v_partner_name, v_partner_phone
  FROM (
    SELECT DISTINCT r.group_id AS gid FROM public.reservations r
    WHERE r.event_id = p_event_id AND r.status = ANY (public.estados_que_ocupan()) AND r.group_id <> p_group_id
    UNION
    SELECT DISTINCT q.group_id AS gid FROM public.quotes q
    WHERE q.event_id = p_event_id AND q.status IN ('pending','quoted') AND q.group_id <> p_group_id
  ) others
  JOIN public.groups g ON g.id = others.gid
  JOIN public.profiles p ON p.id = g.owner_id
  WHERE
    (v_missing = 'sound'    AND g.has_sound     AND COALESCE(g.sound_capacity_max, 0) >= 200) OR
    (v_missing = 'lighting' AND g.has_lighting   AND g.lighting_level = 'premium') OR
    (v_missing = 'stage'    AND g.has_stage      AND 'wedding' = ANY(COALESCE(g.stage_sizes_available, ARRAY[]::text[]))) OR
    (v_missing = 'led'      AND g.has_led_screen AND 'xl' = ANY(COALESCE(g.led_sizes_available, ARRAY[]::text[])))
  LIMIT 1;

  IF v_partner_name IS NULL THEN RETURN jsonb_build_object('needed', false); END IF;

  RETURN jsonb_build_object(
    'needed', true, 'missing', v_missing,
    'partner_name', v_partner_name, 'partner_phone', v_partner_phone
  );
END;
$function$;

-- CRÍTICO — sin esto, PUBLIC hereda EXECUTE por default de Postgres.
REVOKE EXECUTE ON FUNCTION public.get_sound_coordination_partner(UUID, UUID) FROM PUBLIC, anon, authenticated;

-- ── 2. RPC pública con verificación de dueño — para el banner del grupo ──
CREATE OR REPLACE FUNCTION public.group_get_sound_coordination(p_quote_id UUID)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE
  v_event_id UUID; v_group_id UUID; v_owner_id UUID;
BEGIN
  IF auth.uid() IS NULL THEN RETURN jsonb_build_object('needed', false); END IF;

  SELECT q.event_id, q.group_id, g.owner_id
  INTO v_event_id, v_group_id, v_owner_id
  FROM public.quotes q JOIN public.groups g ON g.id = q.group_id
  WHERE q.id = p_quote_id;

  IF v_group_id IS NULL THEN RETURN jsonb_build_object('needed', false); END IF;

  -- Mismo criterio de acceso que ya usa GroupQuoteDetailScreen: dueño del
  -- grupo, integrante aceptado, o admin. Sin esto, cualquier autenticado
  -- podría filtrar el teléfono de otro grupo pasando cualquier quote_id.
  IF v_owner_id <> auth.uid()
     AND NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin')
     AND NOT EXISTS (
       SELECT 1 FROM public.job_invitations
       WHERE group_id = v_group_id AND invited_user_id = auth.uid() AND status = 'accepted'
     ) THEN
    RETURN jsonb_build_object('needed', false);
  END IF;

  IF v_event_id IS NULL THEN RETURN jsonb_build_object('needed', false); END IF;

  RETURN public.get_sound_coordination_partner(v_event_id, v_group_id);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.group_get_sound_coordination(UUID) TO authenticated;

-- ── 3. Trigger AFTER INSERT — notificación push, 100% defensivo ─────────
CREATE OR REPLACE FUNCTION public.notify_sound_coordination()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE
  v_coord jsonb;
  v_owner_id UUID;
BEGIN
  BEGIN
    IF NEW.event_id IS NULL THEN RETURN NEW; END IF;

    v_coord := public.get_sound_coordination_partner(NEW.event_id, NEW.group_id);
    IF NOT COALESCE((v_coord->>'needed')::boolean, false) THEN RETURN NEW; END IF;

    SELECT owner_id INTO v_owner_id FROM public.groups WHERE id = NEW.group_id;
    IF v_owner_id IS NULL THEN RETURN NEW; END IF;

    PERFORM public.queue_push_notification(
      v_owner_id,
      'sound_coordination_needed',
      '🔊 Coordina con el otro proveedor',
      'Otro grupo en este mismo evento ya tiene ' ||
        CASE v_coord->>'missing'
          WHEN 'sound'    THEN 'sonido grande'
          WHEN 'lighting' THEN 'luz premium'
          WHEN 'stage'    THEN 'escenario grande'
          ELSE 'pantalla LED grande'
        END || ': ' || (v_coord->>'partner_name') ||
        '. Contáctalo para coordinar antes de cotizar.',
      jsonb_build_object('quote_id', NEW.id, 'event_id', NEW.event_id)
    );
  EXCEPTION WHEN OTHERS THEN
    -- NUNCA debe poder tumbar la inserción real de una cotización — es el
    -- flujo de dinero más importante de la app. Un fallo aquí es 100%
    -- silencioso: en el peor caso, el grupo simplemente no recibe el aviso
    -- push (el banner en su pantalla lo sigue calculando en vivo de todas
    -- formas, vía RPC #2, sin depender de este trigger).
    RAISE WARNING 'notify_sound_coordination falló (ignorado): %', SQLERRM;
  END;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_notify_sound_coordination ON public.quotes;
CREATE TRIGGER trg_notify_sound_coordination
AFTER INSERT ON public.quotes
FOR EACH ROW
EXECUTE FUNCTION public.notify_sound_coordination();

-- ── 4. admin_alerts() / admin_get_events_needing_review(): +criterio "resuelto" ──
CREATE OR REPLACE FUNCTION public.admin_alerts()
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;
  RETURN jsonb_build_object(
    'ok', true,
    'retiros_pendientes', (SELECT COUNT(*) FROM withdrawals WHERE status = 'pending'),
    'fees_no_capturados', (SELECT COUNT(*) FROM reservations WHERE payment_status IN ('paid','fully_paid','deposit_paid') AND stripe_fee_amount IS NULL),
    'sin_pais', ((SELECT COUNT(*) FROM groups WHERE country IS NULL) + (SELECT COUNT(*) FROM profiles WHERE role = 'talent' AND country IS NULL)),
    'grupos_suspendidos', (SELECT COUNT(*) FROM groups WHERE suspended_at IS NOT NULL),
    'disputas_abiertas', (SELECT COUNT(*) FROM disputes WHERE status IN ('open', 'under_review')),
    'reembolsos_pendientes', (SELECT COUNT(*) FROM manual_refunds WHERE status = 'pending'),
    'eventos_sin_cerrar', (SELECT COUNT(*) FROM reservations WHERE status = 'in_progress' AND event_date < (NOW() AT TIME ZONE 'America/Mexico_City')::date),
    'pagos_retenidos_viejos', (SELECT COUNT(*) FROM reservations WHERE payout_status = 'held' AND payment_status IN ('paid','fully_paid','deposit_paid') AND status = 'completed' AND held_at IS NOT NULL AND held_at < NOW() - INTERVAL '3 days'),
    -- sql/589+590 (umbral corregido) + sql/591 (criterio "resuelto" nuevo):
    -- deja de contar en cuanto NINGUNA cotización de ese evento sigue
    -- 'pending' — es decir, todos ya mandaron su precio al cliente.
    'eventos_multi_grupo_revisar', (
      SELECT COUNT(*) FROM (
        SELECT e.id FROM public.events e
        WHERE e.event_date >= (NOW() AT TIME ZONE 'America/Mexico_City')::date
          AND (SELECT COUNT(DISTINCT gid) FROM (
                SELECT r.group_id AS gid FROM public.reservations r WHERE r.event_id = e.id AND r.status = ANY (public.estados_que_ocupan())
                UNION
                SELECT q.group_id AS gid FROM public.quotes q WHERE q.event_id = e.id AND q.status IN ('pending','quoted')
              ) x) >= 2
          AND EXISTS (
            SELECT 1 FROM public.quotes q2 WHERE q2.event_id = e.id AND (
              q2.needs_sound IN ('si_200', 'si') OR
              q2.needs_lighting = 'premium' OR
              q2.needs_stage = 'wedding' OR
              q2.needs_led = 'xl'
            )
          )
          AND EXISTS (SELECT 1 FROM public.quotes q6 WHERE q6.event_id = e.id AND q6.status = 'pending')
      ) reviewable
    )
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_get_events_needing_review()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE v_result jsonb;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;
  SELECT jsonb_build_object('ok', true, 'items', COALESCE(jsonb_agg(x.item ORDER BY x.event_date ASC), '[]'::jsonb))
  INTO v_result
  FROM (
    SELECT e.event_date, jsonb_build_object(
      'event_id', e.id, 'event_date', e.event_date, 'address', e.address, 'client_name', p.full_name,
      'provider_count', (SELECT COUNT(DISTINCT gid) FROM (
          SELECT r.group_id AS gid FROM public.reservations r WHERE r.event_id = e.id AND r.status = ANY (public.estados_que_ocupan())
          UNION
          SELECT q.group_id AS gid FROM public.quotes q WHERE q.event_id = e.id AND q.status IN ('pending','quoted')
        ) x),
      'max_needs_sound', (SELECT (array_agg(q3.needs_sound ORDER BY
          CASE q3.needs_sound WHEN 'si_200' THEN 4 WHEN 'si_100' THEN 3 WHEN 'si_50' THEN 2 WHEN 'si' THEN 1 ELSE 0 END DESC NULLS LAST
        ) FILTER (WHERE q3.needs_sound IS NOT NULL))[1] FROM public.quotes q3 WHERE q3.event_id = e.id),
      'requested_by', (SELECT COALESCE(jsonb_agg(DISTINCT g4.name) FILTER (
          WHERE q4.needs_sound IN ('si_200', 'si') OR q4.needs_lighting = 'premium' OR q4.needs_stage = 'wedding' OR q4.needs_led = 'xl'
        ), '[]'::jsonb) FROM public.quotes q4 JOIN public.groups g4 ON g4.id = q4.group_id WHERE q4.event_id = e.id)
    ) AS item
    FROM public.events e
    LEFT JOIN public.profiles p ON p.id = e.client_id
    WHERE e.event_date >= (NOW() AT TIME ZONE 'America/Mexico_City')::date
      AND (SELECT COUNT(DISTINCT gid) FROM (
            SELECT r.group_id AS gid FROM public.reservations r WHERE r.event_id = e.id AND r.status = ANY (public.estados_que_ocupan())
            UNION
            SELECT q.group_id AS gid FROM public.quotes q WHERE q.event_id = e.id AND q.status IN ('pending','quoted')
          ) x2) >= 2
      AND EXISTS (
        SELECT 1 FROM public.quotes q5 WHERE q5.event_id = e.id AND (
          q5.needs_sound IN ('si_200', 'si') OR
          q5.needs_lighting = 'premium' OR
          q5.needs_stage = 'wedding' OR
          q5.needs_led = 'xl'
        )
      )
      AND EXISTS (SELECT 1 FROM public.quotes q6 WHERE q6.event_id = e.id AND q6.status = 'pending')
  ) x;
  RETURN v_result;
END;
$function$;

COMMIT;

SELECT '591_group_sound_coordination — APLICADO A PRODUCCIÓN 2026-09-01' AS status;
