-- ============================================================
-- sql/594_admin_event_review_notify_and_phones.sql
-- ✅ APLICADO A PRODUCCIÓN 2026-09-01. Probado en transacción
-- autorevertible: evento con 1 solo proveedor nunca notifica, 2do
-- proveedor califica dispara aviso a TODOS los admins (probado con 2),
-- 3er proveedor que se suma NO duplica el aviso, providers[] trae
-- teléfono real de cada uno.
--
-- PETICIÓN REAL DEL USUARIO (2026-09-01, probando la Fase 3 en vivo):
--   1. Que la cola "Eventos grandes por coordinar" del admin muestre el
--      teléfono de cada grupo del evento — por si algo sale mal aunque
--      se supone que los grupos se coordinan solos.
--   2. Que le llegue una notificación push cuando aparece un evento
--      nuevo en esa cola, en vez de tener que entrar a Reportes a
--      revisar manualmente.
--
-- ALCANCE
--   1. admin_get_events_needing_review(): +'providers' (nombre + teléfono
--      de CADA proveedor del evento, no solo los que declararon equipo
--      grande) — hash actual verificado antes de tocarla:
--      'd10c213d4d3cd8123c944ea93a0babd6' (2026-09-01).
--   2. event_needs_admin_review(event_id, exclude_quote_id): función
--      nueva, standalone — mismo criterio EXACTO que ya usan
--      admin_alerts()/admin_get_events_needing_review() (2+ proveedores,
--      alguien declaró nivel TOP, al menos 1 cotización sigue pending),
--      pero parametrizada para poder calcular "¿ya calificaba ANTES de
--      esta cotización?" excluyendo la fila recién insertada. No se
--      reescriben admin_alerts()/admin_get_events_needing_review() con
--      esta función para no re-tocar código ya probado y en producción
--      — se acepta la duplicación de criterio a cambio de menor riesgo.
--   3. Trigger AFTER INSERT en quotes — notifica a TODOS los admins
--      (mismo patrón ya usado en sql/164-176: `FOR v_admin IN SELECT id
--      FROM profiles WHERE role='admin' LOOP`) SOLO la primera vez que
--      un evento cruza el umbral de "necesita revisión" — si ya
--      calificaba antes de esta cotización, NO se repite el aviso
--      (evita saturar al admin con un push por cada grupo adicional que
--      se sume a un evento ya señalado). Reutiliza el tipo
--      'admin_alert' que YA está en el CHECK de `notifications.type` —
--      no se toca esa restricción. `data.screen='AdminReports'` — el
--      manejador genérico de NotificationsScreen.tsx (case default) ya
--      navega ahí solo, sin tocar ese archivo.
--      DEFENSIVO: mismo patrón que sql/591 — cualquier error se atrapa y
--      se ignora, jamás puede tumbar la inserción real de una cotización.
-- ============================================================

BEGIN;

-- ── 1. admin_get_events_needing_review(): +teléfonos de cada proveedor ──
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
        ), '[]'::jsonb) FROM public.quotes q4 JOIN public.groups g4 ON g4.id = q4.group_id WHERE q4.event_id = e.id),
      -- sql/594 — teléfono de CADA proveedor activo del evento (no solo
      -- quien declaró equipo grande), para que el admin pueda llamar a
      -- cualquiera si algo sale mal.
      'providers', (
        SELECT COALESCE(jsonb_agg(jsonb_build_object(
          'group_name', gg.name, 'phone', pp.phone
        ) ORDER BY gg.name), '[]'::jsonb)
        FROM (
          SELECT DISTINCT gid FROM (
            SELECT r.group_id AS gid FROM public.reservations r WHERE r.event_id = e.id AND r.status = ANY (public.estados_que_ocupan())
            UNION
            SELECT q.group_id AS gid FROM public.quotes q WHERE q.event_id = e.id AND q.status IN ('pending','quoted')
          ) u
        ) x8
        JOIN public.groups gg ON gg.id = x8.gid
        LEFT JOIN public.profiles pp ON pp.id = gg.owner_id
      )
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

-- ── 2. Función standalone: ¿este evento califica para revisión? ─────────
-- Mismo criterio EXACTO de admin_alerts()/admin_get_events_needing_review,
-- parametrizada para poder excluir una cotización (calcular "antes" de
-- que existiera esa fila). No requiere permisos de admin — es un helper
-- interno, sin GRANT a authenticated/anon (mismo cuidado que
-- get_sound_coordination_partner de sql/591 — no expone nada sensible
-- aquí, pero se mantiene la disciplina de no otorgar de más).
CREATE OR REPLACE FUNCTION public.event_needs_admin_review(
  p_event_id UUID, p_exclude_quote_id UUID DEFAULT NULL
) RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
  SELECT
    (SELECT COUNT(DISTINCT gid) FROM (
      SELECT r.group_id AS gid FROM public.reservations r
      WHERE r.event_id = p_event_id AND r.status = ANY (public.estados_que_ocupan())
      UNION
      SELECT q.group_id AS gid FROM public.quotes q
      WHERE q.event_id = p_event_id AND q.status IN ('pending','quoted')
        AND q.id IS DISTINCT FROM p_exclude_quote_id
    ) x) >= 2
    AND EXISTS (
      SELECT 1 FROM public.quotes q2
      WHERE q2.event_id = p_event_id AND q2.id IS DISTINCT FROM p_exclude_quote_id
        AND (
          q2.needs_sound IN ('si_200','si') OR q2.needs_lighting = 'premium'
          OR q2.needs_stage = 'wedding' OR q2.needs_led = 'xl'
        )
    )
    AND EXISTS (
      SELECT 1 FROM public.quotes q3
      WHERE q3.event_id = p_event_id AND q3.id IS DISTINCT FROM p_exclude_quote_id
        AND q3.status = 'pending'
    );
$function$;

REVOKE EXECUTE ON FUNCTION public.event_needs_admin_review(UUID, UUID) FROM PUBLIC, anon, authenticated;

-- ── 3. Trigger AFTER INSERT — avisa a admin SOLO la primera vez ─────────
CREATE OR REPLACE FUNCTION public.notify_admin_event_review()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE
  v_needed_before BOOLEAN;
  v_needed_now    BOOLEAN;
  v_address       TEXT;
  v_admin         RECORD;
BEGIN
  BEGIN
    IF NEW.event_id IS NULL THEN RETURN NEW; END IF;

    v_needed_before := public.event_needs_admin_review(NEW.event_id, NEW.id);
    IF v_needed_before THEN RETURN NEW; END IF; -- ya calificaba antes → no repetir aviso

    v_needed_now := public.event_needs_admin_review(NEW.event_id, NULL);
    IF NOT v_needed_now THEN RETURN NEW; END IF; -- todavía no califica

    SELECT address INTO v_address FROM public.events WHERE id = NEW.event_id;

    FOR v_admin IN SELECT id FROM public.profiles WHERE role = 'admin' LOOP
      PERFORM public.queue_push_notification(
        v_admin.id,
        'admin_alert',
        '🔊 Evento grande por coordinar',
        'Un evento con 2+ proveedores necesita revisión de sonido/luz/escenario: ' || COALESCE(v_address, 'ver detalle') || '.',
        jsonb_build_object('screen', 'AdminReports', 'event_id', NEW.event_id)
      );
    END LOOP;
  EXCEPTION WHEN OTHERS THEN
    -- Igual que sql/591: jamás debe poder tumbar la inserción real de
    -- una cotización — en el peor caso, el admin simplemente no recibe
    -- el push (la cola de Reportes → Alertas lo sigue mostrando igual).
    RAISE WARNING 'notify_admin_event_review falló (ignorado): %', SQLERRM;
  END;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_notify_admin_event_review ON public.quotes;
CREATE TRIGGER trg_notify_admin_event_review
AFTER INSERT ON public.quotes
FOR EACH ROW
EXECUTE FUNCTION public.notify_admin_event_review();

COMMIT;

SELECT '594_admin_event_review_notify_and_phones — APLICADO A PRODUCCIÓN 2026-09-01' AS status;
