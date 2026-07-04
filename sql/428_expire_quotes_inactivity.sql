-- ============================================================
-- sql/428_expire_quotes_inactivity.sql
-- Expiración de cotizaciones por INACTIVIDAD del grupo (7 días)
--
-- HUECO: una quote 'pending' (el grupo nunca respondió) vivía hasta
--   que pasara la fecha del evento (sql/362) — para un evento a 3
--   meses, el cliente quedaba en visto 3 meses.
-- FIX: sección B nueva en expire_stale_quotes():
--   status = 'pending' AND COALESCE(updated_at, created_at) hace
--   más de 7 días → status='expired' + notif a ambos.
--   · SOLO 'pending': en 'quoted' el grupo YA respondió (la pelota
--     es del cliente) — esa sigue muriendo por fecha/proximidad.
--   · Sin dinero involucrado (el pago ocurre post-aceptación).
--
-- Sección A (por fecha del evento): de sql/362 con UN token corregido:
--   event_date < CURRENT_DATE  →  fecha local CDMX (familia sql/417).
--   Antes, después de las ~18:00 CDMX (00:00 UTC) una quote para un
--   evento de ESTA NOCHE se expiraba antes de que el evento ocurriera.
--   (America/Mexico_City hardcodeado a propósito — México es el
--   mercado; multi-timezone EE.UU. = proyecto aparte agendado.)
-- Mismo cron ('expire-stale-quotes', horario) y mismo advisory lock.
-- Types: reusa 'quote_expired' (reincorporado en sql/418).
--
-- ⚠️ PRE-CHECK (corre ANTES; si da false, corre sql/418 primero):
-- ============================================================

SELECT pg_get_constraintdef(c.oid) LIKE '%''quote_expired''%' AS quote_expired_ok
FROM   pg_constraint c
WHERE  c.conname  = 'notifications_type_check'
  AND  c.conrelid = 'public.notifications'::regclass;
-- Esperado: true


BEGIN;

CREATE OR REPLACE FUNCTION public.expire_stale_quotes()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_expired_count    INT := 0;
  v_inactive_count   INT := 0;
  v_notified_clients INT := 0;
  v_notified_groups  INT := 0;
  v_q                RECORD;
  v_event_label      TEXT;
BEGIN
  -- Advisory lock: solo 1 instancia del cron a la vez
  IF NOT pg_try_advisory_xact_lock(5566778899) THEN
    RETURN jsonb_build_object(
      'ok', true, 'skipped', true, 'reason', 'lock_busy'
    );
  END IF;

  -- ══════════════════════════════════════════════════════════════
  -- SECCIÓN A (sql/362, sin cambios): fecha del evento ya pasó
  -- ══════════════════════════════════════════════════════════════
  FOR v_q IN
    SELECT q.id,
           q.client_id,
           q.group_id,
           q.status,
           q.event_date,
           q.event_type
    FROM   public.quotes q
    WHERE  q.status    IN ('pending', 'quoted')
      -- [428] fecha LOCAL CDMX (antes usaba la fecha UTC de sesión, familia sql/417)
      AND  q.event_date < (NOW() AT TIME ZONE 'America/Mexico_City')::date
    ORDER  BY q.event_date ASC
  LOOP
    UPDATE public.quotes
    SET    status     = 'expired',
           updated_at = NOW()
    WHERE  id = v_q.id;

    v_event_label := CASE v_q.event_type
      WHEN 'fiesta_privada' THEN 'fiesta privada'
      WHEN 'boda'           THEN 'boda'
      WHEN 'cumpleanos'     THEN 'cumpleaños'
      WHEN 'graduacion'     THEN 'graduación'
      WHEN 'empresarial'    THEN 'evento empresarial'
      ELSE COALESCE(v_q.event_type, 'evento')
    END;

    IF v_q.client_id IS NOT NULL THEN
      BEGIN
        INSERT INTO public.notifications (user_id, type, title, body, data)
        VALUES (
          v_q.client_id,
          'quote_expired',
          'Solicitud cerrada',
          'Tu solicitud de ' || v_event_label
            || ' del ' || TO_CHAR(v_q.event_date, 'DD/MM/YYYY')
            || ' fue cerrada automáticamente porque la fecha ya pasó.',
          jsonb_build_object(
            'quote_id', v_q.id,
            'screen',   'Reservations'
          )
        );
        v_notified_clients := v_notified_clients + 1;
      EXCEPTION WHEN OTHERS THEN
        NULL;
      END;
    END IF;

    IF v_q.status = 'quoted' AND v_q.group_id IS NOT NULL THEN
      BEGIN
        INSERT INTO public.notifications (user_id, type, title, body, data)
        SELECT
          g.owner_id,
          'quote_expired',
          'Cotización sin respuesta',
          'La cotización que enviaste para ' || v_event_label
            || ' del ' || TO_CHAR(v_q.event_date, 'DD/MM/YYYY')
            || ' expiró. El cliente no respondió antes del evento.',
          jsonb_build_object(
            'quote_id', v_q.id,
            'screen',   'GroupQuotes'
          )
        FROM public.groups g
        WHERE g.id = v_q.group_id;
        v_notified_groups := v_notified_groups + 1;
      EXCEPTION WHEN OTHERS THEN
        NULL;
      END;
    END IF;

    v_expired_count := v_expired_count + 1;
  END LOOP;

  -- ══════════════════════════════════════════════════════════════
  -- SECCIÓN B [428]: 'pending' con 7 días sin respuesta del grupo
  -- ══════════════════════════════════════════════════════════════
  FOR v_q IN
    SELECT q.id,
           q.client_id,
           q.group_id,
           q.event_date,
           q.event_type
    FROM   public.quotes q
    WHERE  q.status = 'pending'
      AND  COALESCE(q.updated_at, q.created_at) < NOW() - INTERVAL '7 days'
      -- Dedupe extra (cinturón): que no exista ya la notif de inactividad
      AND  NOT EXISTS (
        SELECT 1 FROM public.notifications n
        WHERE n.data->>'quote_id' = q.id::text
          AND n.data->>'reason'   = 'group_inactivity'
      )
    ORDER  BY COALESCE(q.updated_at, q.created_at) ASC
  LOOP
    UPDATE public.quotes
    SET    status     = 'expired',
           updated_at = NOW()
    WHERE  id = v_q.id;

    v_event_label := CASE v_q.event_type
      WHEN 'fiesta_privada' THEN 'fiesta privada'
      WHEN 'boda'           THEN 'boda'
      WHEN 'cumpleanos'     THEN 'cumpleaños'
      WHEN 'graduacion'     THEN 'graduación'
      WHEN 'empresarial'    THEN 'evento empresarial'
      ELSE COALESCE(v_q.event_type, 'evento')
    END;

    -- Cliente: que busque otro grupo
    IF v_q.client_id IS NOT NULL THEN
      BEGIN
        INSERT INTO public.notifications (user_id, type, title, body, data)
        VALUES (
          v_q.client_id,
          'quote_expired',
          '⏳ El grupo no respondió',
          'Tu solicitud de ' || v_event_label ||
            ' lleva 7 días sin respuesta y fue cerrada. ' ||
            'Explora otros grupos disponibles para tu evento.',
          jsonb_build_object(
            'quote_id', v_q.id,
            'reason',   'group_inactivity',
            'screen',   'ClientReservations'
          )
        );
        v_notified_clients := v_notified_clients + 1;
      EXCEPTION WHEN OTHERS THEN
        NULL;
      END;
    END IF;

    -- Grupo: presión sana de marketplace
    IF v_q.group_id IS NOT NULL THEN
      BEGIN
        INSERT INTO public.notifications (user_id, type, title, body, data)
        SELECT
          g.owner_id,
          'quote_expired',
          '😞 Perdiste una solicitud por no responder',
          'Una solicitud de ' || v_event_label ||
            ' expiró tras 7 días sin tu respuesta. ' ||
            'Responde a tiempo para no perder clientes.',
          jsonb_build_object(
            'quote_id', v_q.id,
            'reason',   'group_inactivity',
            'screen',   'GroupQuotes'
          )
        FROM public.groups g
        WHERE g.id = v_q.group_id;
        v_notified_groups := v_notified_groups + 1;
      EXCEPTION WHEN OTHERS THEN
        NULL;
      END;
    END IF;

    v_inactive_count := v_inactive_count + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'ok',                true,
    'expired',           v_expired_count,
    'expired_inactive',  v_inactive_count,
    'notified_clients',  v_notified_clients,
    'notified_groups',   v_notified_groups,
    'ran_at',            NOW()
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.expire_stale_quotes() TO service_role;
REVOKE EXECUTE ON FUNCTION public.expire_stale_quotes() FROM authenticated;

COMMIT;

-- (El cron 'expire-stale-quotes' horario ya existe — no se toca.)

-- ── Verificaciones ────────────────────────────────────────────────────────────
-- V1: ambas secciones presentes + timezone corregido
SELECT
  routine_definition NOT LIKE '%CURRENT_DATE%'                          AS sin_current_date,
  routine_definition LIKE '%AT TIME ZONE ''America/Mexico_City''%'      AS fecha_local_ok,
  routine_definition LIKE '%INTERVAL ''7 days''%'                       AS seccion_b_inactividad,
  routine_definition LIKE '%group_inactivity%'                          AS notifs_inactividad,
  routine_definition LIKE '%status = ''pending''%'                      AS solo_pending
FROM information_schema.routines
WHERE routine_schema = 'public' AND routine_name = 'expire_stale_quotes';
-- Esperado: true | true | true | true | true

SELECT '428_expire_quotes_inactivity.sql ejecutado ✅' AS status;
