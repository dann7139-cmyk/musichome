-- ============================================================
-- sql/454_quotes_expiry_3days.sql
-- Cotizaciones PROGRAMADAS: expiración por TIEMPO DE RESPUESTA (3 días).
--
-- Antes (sql/362) solo expiraban cuando event_date < CURRENT_DATE (fecha ya
-- pasada). Ahora, además:
--   · 'pending' (grupo no ha cotizado): expira 3 días después de created_at
--     → el grupo no respondió a tiempo (p.ej. andaba fuera).
--   · 'quoted'  (grupo cotizó, cliente decide): expira 3 días después de
--     updated_at → el cliente no respondió la cotización.
-- Se conserva el criterio de event_date pasada y se arregla la zona horaria
-- (CURRENT_DATE UTC → fecha local MX).
--
-- Anclas: created_at (siempre = alta de la solicitud) y updated_at (se fija
-- cuando el grupo cotiza y NO cambia hasta que el cliente actúa → válido).
-- Solo redefine la FUNCIÓN — no toca el constraint de notifications.
-- México = UTC-6 fijo.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.expire_stale_quotes()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_expired_count    INT := 0;
  v_notified_clients INT := 0;
  v_notified_groups  INT := 0;
  v_q                RECORD;
  v_event_label      TEXT;
  v_reason           TEXT;
  v_body             TEXT;
  v_now              TIMESTAMPTZ := NOW();
  v_today_mx         DATE := (NOW() AT TIME ZONE 'America/Mexico_City')::date;  -- [454] fecha LOCAL
BEGIN
  IF NOT pg_try_advisory_xact_lock(5566778899) THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'lock_busy');
  END IF;

  FOR v_q IN
    SELECT q.id, q.client_id, q.group_id, q.status, q.event_date, q.event_type,
           q.created_at, q.updated_at
    FROM   public.quotes q
    WHERE  q.status IN ('pending', 'quoted')
      AND (
            q.event_date < v_today_mx                                            -- fecha ya pasó
        OR (q.status = 'pending' AND q.created_at < v_now - INTERVAL '3 days')   -- grupo no cotizó en 3 días
        OR (q.status = 'quoted'  AND q.updated_at < v_now - INTERVAL '3 days')   -- cliente no respondió en 3 días
      )
    ORDER BY q.event_date ASC
  LOOP
    -- Motivo (para el copy)
    v_reason := CASE
      WHEN v_q.event_date < v_today_mx THEN 'fecha_pasada'
      WHEN v_q.status = 'pending'      THEN 'grupo_no_respondio'
      ELSE                                  'cliente_no_respondio'
    END;

    UPDATE public.quotes
    SET    status = 'expired', updated_at = NOW()
    WHERE  id = v_q.id;

    v_event_label := CASE v_q.event_type
      WHEN 'fiesta_privada' THEN 'fiesta privada'
      WHEN 'boda'           THEN 'boda'
      WHEN 'cumpleanos'     THEN 'cumpleaños'
      WHEN 'graduacion'     THEN 'graduación'
      WHEN 'empresarial'    THEN 'evento empresarial'
      ELSE COALESCE(v_q.event_type, 'evento')
    END;

    -- Notificar al cliente (siempre — él envió la solicitud)
    IF v_q.client_id IS NOT NULL THEN
      BEGIN
        v_body := CASE v_reason
          WHEN 'fecha_pasada' THEN
            'Tu solicitud de ' || v_event_label || ' del ' || TO_CHAR(v_q.event_date, 'DD/MM/YYYY')
              || ' se cerró porque la fecha ya pasó.'
          WHEN 'grupo_no_respondio' THEN
            'Tu solicitud de ' || v_event_label || ' se cerró: el grupo no respondió en 3 días. Puedes pedir cotización a otro grupo.'
          ELSE
            'La cotización de ' || v_event_label || ' se cerró porque pasaron 3 días sin respuesta.'
        END;
        INSERT INTO public.notifications (user_id, type, title, body, data)
        VALUES (v_q.client_id, 'quote_expired', 'Solicitud cerrada', v_body,
          jsonb_build_object('quote_id', v_q.id, 'screen', 'Reservations'));
        v_notified_clients := v_notified_clients + 1;
      EXCEPTION WHEN OTHERS THEN NULL;
      END;
    END IF;

    -- Notificar al grupo solo si había cotizado (status='quoted')
    IF v_q.status = 'quoted' AND v_q.group_id IS NOT NULL THEN
      BEGIN
        v_body := CASE v_reason
          WHEN 'cliente_no_respondio' THEN
            'La cotización que enviaste para ' || v_event_label || ' expiró: el cliente no respondió en 3 días.'
          ELSE
            'La cotización que enviaste para ' || v_event_label || ' del ' || TO_CHAR(v_q.event_date, 'DD/MM/YYYY')
              || ' expiró.'
        END;
        INSERT INTO public.notifications (user_id, type, title, body, data)
        SELECT g.owner_id, 'quote_expired', 'Cotización sin respuesta', v_body,
          jsonb_build_object('quote_id', v_q.id, 'screen', 'GroupQuotes')
        FROM public.groups g WHERE g.id = v_q.group_id;
        v_notified_groups := v_notified_groups + 1;
      EXCEPTION WHEN OTHERS THEN NULL;
      END;
    END IF;

    v_expired_count := v_expired_count + 1;
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'expired', v_expired_count,
    'notified_clients', v_notified_clients, 'notified_groups', v_notified_groups, 'ran_at', NOW());

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.expire_stale_quotes() TO service_role;

COMMIT;

-- ── VERIFICACIONES ──────────────────────────────────────────────────────────────
-- V1: la función ya considera 3 días y fecha MX
SELECT
  prosrc LIKE '%3 days%'          AS usa_ventana_3dias,   -- true
  prosrc LIKE '%v_today_mx%'      AS usa_fecha_MX,         -- true
  prosrc LIKE '%grupo_no_respondio%' AS branch_pending,   -- true
  prosrc LIKE '%cliente_no_respondio%' AS branch_quoted   -- true
FROM pg_proc WHERE proname = 'expire_stale_quotes';
-- Esperado: true | true | true | true

-- V2 (read-only): qué cotizaciones se expirarían ahora
SELECT id, status, event_date, created_at, updated_at,
       CASE
         WHEN event_date < (now() AT TIME ZONE 'America/Mexico_City')::date THEN 'fecha_pasada'
         WHEN status='pending' AND created_at < now() - INTERVAL '3 days' THEN 'grupo_no_respondio'
         WHEN status='quoted'  AND updated_at < now() - INTERVAL '3 days' THEN 'cliente_no_respondio'
       END AS motivo
FROM quotes
WHERE status IN ('pending','quoted')
  AND ( event_date < (now() AT TIME ZONE 'America/Mexico_City')::date
     OR (status='pending' AND created_at < now() - INTERVAL '3 days')
     OR (status='quoted'  AND updated_at < now() - INTERVAL '3 days') );

SELECT '454_quotes_expiry_3days.sql ejecutado ✅' AS status;
