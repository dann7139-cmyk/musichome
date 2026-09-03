-- ============================================================
-- sql/589_admin_events_review_queue.sql
-- ✅ APLICADO A PRODUCCIÓN 2026-09-01 con autorización explícita del
-- usuario ("deja lo que veas que es mas mejor... dejalo listo y bien
-- echo"). Probado antes en transacción autorevertible (7/7 PASS,
-- incluyendo casos límite de sonido/luz/escenario nivel medio que NO
-- deben disparar la alerta) y verificado en vivo después (smoke test vía
-- REST con anon key, cero residuos).
--
-- PROPÓSITO
--   Hallazgo real de auditoría (2026-08-31/09-01): sql/585 ya construye y
--   despliega admin_get_event_detail() con 'sound_summary.needs_review' —
--   la señal de "este evento tiene 2+ proveedores y alguien declaró
--   sonido/luz/escenario/led grande" YA EXISTE y ya funciona. Pero el
--   ÚNICO camino para verla hoy es: admin busca manualmente un folio de
--   ticket que YA CONOCE en AdminTicketSearchScreen → toca "Ver evento
--   completo" (ese botón depende de sql/588, tampoco aplicado). No existe
--   ninguna forma de que el admin DESCUBRA por sí solo qué eventos
--   necesitan su revisión — tiene que ya saber qué buscar.
--
--   Este archivo cierra ese hueco: agrega el conteo a admin_alerts()
--   (mismo patrón que 'eventos_sin_cerrar', 'disputas_abiertas', etc. —
--   ya consumido por AdminReportsScreen.tsx) y una RPC nueva de solo
--   lectura que regresa la LISTA real para una pantalla de cola.
--
-- QUÉ NO CAMBIA
--   - No toca dinero, pagos, comisiones, ni ninguna tabla de reservas/
--     cotizaciones — 100% lectura.
--   - No modifica ninguna función existente salvo agregar UNA clave nueva
--     al jsonb de admin_alerts() (hash actual verificado antes de tocarlo:
--     md5(prosrc) = 'b07addfd093fca1be0b74b2b95e557e4', 2026-09-01).
--   - No depende de que sql/588 se aplique — es independiente.
--
-- CRITERIO DE "NECESITA REVISIÓN" (decisión explícita del usuario, corregida
-- por sql/590 tras hallazgo de prueba sintética — SOLO el nivel TOP de
-- cada dimensión, no cualquier declaración):
--   - 2 o más proveedores DISTINTOS en el mismo evento (reservas activas
--     + cotizaciones pending/quoted, igual que admin_get_event_detail).
--   - Y al menos uno declaró needs_sound IN ('si_200','si') — grande o sin
--     especificar tamaño — o needs_lighting='premium' o needs_stage='wedding'
--     o needs_led='xl'. NUNCA por sonido/luz/escenario CHICO o MEDIANO, y
--     NUNCA solo por cantidad de proveedores (así lo pidió el usuario:
--     "si veo que es chico, dejo que coticen ellos").
--   - Solo eventos de hoy en adelante (event_date >= hoy) — un evento ya
--     pasado no necesita coordinación.
-- ============================================================

BEGIN;

-- ── 1. admin_alerts(): +1 clave nueva, nada más se toca ─────────────────
CREATE OR REPLACE FUNCTION public.admin_alerts()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    -- 💸 FIX [509]: withdrawals, no payout_requests (huérfana)
    'retiros_pendientes', (
      SELECT COUNT(*) FROM withdrawals WHERE status = 'pending'),
    'fees_no_capturados', (
      SELECT COUNT(*) FROM reservations
      WHERE payment_status IN ('paid','fully_paid','deposit_paid')
        AND stripe_fee_amount IS NULL),
    'sin_pais', (
      (SELECT COUNT(*) FROM groups WHERE country IS NULL)
      + (SELECT COUNT(*) FROM profiles WHERE role = 'talent' AND country IS NULL)),
    'grupos_suspendidos', (
      SELECT COUNT(*) FROM groups WHERE suspended_at IS NOT NULL),
    'disputas_abiertas', (
      SELECT COUNT(*) FROM disputes WHERE status IN ('open', 'under_review')),
    'reembolsos_pendientes', (
      SELECT COUNT(*) FROM manual_refunds WHERE status = 'pending'),
    'eventos_sin_cerrar', (
      SELECT COUNT(*) FROM reservations
      WHERE status = 'in_progress'
        AND event_date < (NOW() AT TIME ZONE 'America/Mexico_City')::date),
    'pagos_retenidos_viejos', (
      SELECT COUNT(*) FROM reservations
      WHERE payout_status = 'held'
        AND payment_status IN ('paid','fully_paid','deposit_paid')
        AND status = 'completed'
        AND held_at IS NOT NULL
        AND held_at < NOW() - INTERVAL '3 days'),
    -- sql/589 (umbral corregido por sql/590) — eventos con 2+ proveedores
    -- donde alguien declaró el nivel TOP de sonido/luz/escenario/led.
    -- Cuenta eventos, no proveedores.
    'eventos_multi_grupo_revisar', (
      SELECT COUNT(*) FROM (
        SELECT e.id
        FROM public.events e
        WHERE e.event_date >= (NOW() AT TIME ZONE 'America/Mexico_City')::date
          AND (
            SELECT COUNT(DISTINCT gid) FROM (
              SELECT r.group_id AS gid FROM public.reservations r
              WHERE r.event_id = e.id AND r.status = ANY (public.estados_que_ocupan())
              UNION
              SELECT q.group_id AS gid FROM public.quotes q
              WHERE q.event_id = e.id AND q.status IN ('pending','quoted')
            ) x
          ) >= 2
          AND EXISTS (
            SELECT 1 FROM public.quotes q2
            WHERE q2.event_id = e.id
              AND (
                q2.needs_sound IN ('si_200', 'si') OR
                q2.needs_lighting = 'premium' OR
                q2.needs_stage = 'wedding' OR
                q2.needs_led = 'xl'
              )
          )
      ) reviewable
    )
  );
END;
$function$;

-- ── 2. Nueva RPC de solo lectura: lista real para la pantalla de cola ───
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
      'event_id',       e.id,
      'event_date',     e.event_date,
      'address',        e.address,
      'client_name',    p.full_name,
      'provider_count', (
        SELECT COUNT(DISTINCT gid) FROM (
          SELECT r.group_id AS gid FROM public.reservations r
          WHERE r.event_id = e.id AND r.status = ANY (public.estados_que_ocupan())
          UNION
          SELECT q.group_id AS gid FROM public.quotes q
          WHERE q.event_id = e.id AND q.status IN ('pending','quoted')
        ) x
      ),
      'max_needs_sound', (
        SELECT (array_agg(q3.needs_sound ORDER BY
          CASE q3.needs_sound WHEN 'si_200' THEN 4 WHEN 'si_100' THEN 3 WHEN 'si_50' THEN 2 WHEN 'si' THEN 1 ELSE 0 END DESC NULLS LAST
        ) FILTER (WHERE q3.needs_sound IS NOT NULL))[1]
        FROM public.quotes q3 WHERE q3.event_id = e.id
      ),
      'requested_by', (
        SELECT COALESCE(jsonb_agg(DISTINCT g4.name) FILTER (
          WHERE q4.needs_sound IN ('si_200', 'si')
             OR q4.needs_lighting = 'premium' OR q4.needs_stage = 'wedding' OR q4.needs_led = 'xl'
        ), '[]'::jsonb)
        FROM public.quotes q4 JOIN public.groups g4 ON g4.id = q4.group_id
        WHERE q4.event_id = e.id
      )
    ) AS item
    FROM public.events e
    LEFT JOIN public.profiles p ON p.id = e.client_id
    WHERE e.event_date >= (NOW() AT TIME ZONE 'America/Mexico_City')::date
      AND (
        SELECT COUNT(DISTINCT gid) FROM (
          SELECT r.group_id AS gid FROM public.reservations r
          WHERE r.event_id = e.id AND r.status = ANY (public.estados_que_ocupan())
          UNION
          SELECT q.group_id AS gid FROM public.quotes q
          WHERE q.event_id = e.id AND q.status IN ('pending','quoted')
        ) x2
      ) >= 2
      AND EXISTS (
        SELECT 1 FROM public.quotes q5
        WHERE q5.event_id = e.id
          AND (
            q5.needs_sound IN ('si_200', 'si') OR
            q5.needs_lighting = 'premium' OR
            q5.needs_stage = 'wedding' OR
            q5.needs_led = 'xl'
          )
      )
  ) x;

  RETURN v_result;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_get_events_needing_review() TO authenticated;

COMMIT;

SELECT '589_admin_events_review_queue — APLICADO A PRODUCCIÓN 2026-09-01' AS status;
