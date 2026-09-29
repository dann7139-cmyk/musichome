-- ═══════════════════════════════════════════════════════════════════════════
-- 718 — ETAPA 2: recordatorios de cotizaciones pendientes (12 h y 36 h)
-- ═══════════════════════════════════════════════════════════════════════════
-- Hoy una cotización pendiente muere en silencio a los 3 días (`expire_stale_quotes`)
-- sin que nadie le haya tocado el hombro al que debe responder. Esto agrega dos
-- recordatorios antes de esa muerte.
--
-- NO TOCA: `expire_stale_quotes` (sigue siendo la ÚNICA autoridad que expira, a los
-- 3 días / 72 h), `notify_quote_request`, `admin_respond_quote`, el margen/comisión,
-- el toggle de `concierge_mode`, Express, `extra_hours`, Stripe/Conekta/webhooks,
-- cancelaciones, cambio de fecha, RLS, 697/700. Cero cambios al CHECK de
-- `notifications.type`. Cero cambios a dinero.
--
-- ── QUÉ SE AGREGA ─────────────────────────────────────────────────────────
--   quotes.reminder_12h_at   timestamptz NULL
--   quotes.reminder_36h_at   timestamptz NULL
--   quotes.escalated_48h_at  timestamptz NULL   ← se crea pero NADIE la escribe
--   función notify_pending_quotes()
--   cron 'notify-pending-quotes' cada hora en el minuto 15
--
-- ── IDEMPOTENCIA ATÓMICA POR QUOTE ────────────────────────────────────────
-- Las columnas son la verdad de "esta etapa ya se procesó"; las notificaciones NO.
-- El reclamo es un UPDATE … WHERE reminder_12h_at IS NULL … RETURNING id dentro de
-- un CTE que escribe: es atómico, y si dos corridas se traslapan solo una se lleva
-- las filas (la otra ve cero y no manda nada). Además la función toma
-- `pg_try_advisory_xact_lock(8812345678)` — un número DISTINTO al 5566778899 de
-- `expire_stale_quotes`, para que las dos nunca se bloqueen entre sí.
-- El INSERT de la notificación va en la MISMA subtransacción que el UPDATE: si el
-- INSERT falla, las marcas se revierten y el siguiente ciclo lo reintenta. Nunca
-- queda una quote marcada sin aviso, ni un aviso sin marca.
--
-- ── VENTANA DE VIDA: 12 h … 3 días ────────────────────────────────────────
-- Solo se recuerda lo que todavía está vivo. Pasados los 3 días la quote le toca a
-- `expire_stale_quotes`, así que si ese cron se atrasa NO le insistimos al proveedor
-- por algo que está por cerrarse. Es una condición de lectura: no expira nada.
--
-- ── HORARIO SILENCIOSO: 8:00 AM – 9:00 PM ─────────────────────────────────
-- `EXTRACT(HOUR FROM now() AT TIME ZONE tz) BETWEEN 8 AND 20`, o sea el último push
-- puede salir 20:59. Si la quote cumple 12 h o 36 h de madrugada, las columnas
-- siguen en NULL y el siguiente ciclo del cron la recoge en cuanto abra la ventana:
-- no hace falta ningún estado extra ni una cola de pendientes.
--
-- ── ZONA HORARIA DEL DESTINATARIO (auditado, no inventado) ────────────────
-- Se usa `public.tz_for_event(g.state, g.country)` **del grupo**, que es el
-- resolvedor canónico del proyecto (el mismo que usa `set_reservation_busy_range`)
-- y cuyo ELSE ya es 'America/Mexico_City'.
--   · `profiles` NO tiene columna de zona horaria (verificado).
--   · `cities.timezone` está VACÍA (0 de 34 filas) → NO se usa.
--   · `states.timezone` sí está poblada (83/83) y `countries.timezone` (11/11), pero
--     el resolvedor vigente del proyecto es la función, no esas columnas.
--   · Los 17 grupos tienen `state`, así que hoy siempre resuelve.
-- NO se usa la ubicación del evento: el destinatario es el proveedor (o el admin que
-- cubre su país), no el cliente.
-- Por qué la zona del GRUPO también en el caso Admin: una cotización de conserjería
-- la atiende quien cubre ESE país — así lo decide ya `notify_quote_request` con
-- `admin_is_country_muted` / `admin_country_scope` — y un mismo aviso puede ir a
-- varios admins a la vez; si cada uno tuviera su propia ventana, el primero en
-- marcar la quote le quitaría el aviso a los demás. Una sola zona por quote es lo
-- que mantiene la idempotencia.
-- FALLBACK: 'America/Mexico_City', el de `tz_for_event`, el mismo que ya usan
-- `expire_stale_quotes` y `send_event_reminders`.
--
-- ── POR QUÉ SE REUTILIZA type='new_quote_request' ─────────────────────────
-- Verificado que ese tipo YA tiene la semántica correcta para un recordatorio, en
-- los dos públicos:
--   · grupo → `AppNavigator.tsx:829` (y :933 en arranque frío) y
--     `NotificationsScreen.tsx:472` abren el carrusel 📅 con ese `quote_id`.
--   · admin/admin_ops → con `data.screen='AdminManagedQuotes'` va a la cola de
--     "Cotizaciones que manejo" (`NotificationsScreen.tsx:477`).
-- Y `notify_quote_request` ya usa ese mismo tipo para los dos públicos. La etapa se
-- distingue con `data.reminder_stage` ('12h' | '36h'), igual que
-- `send_express_followups` distingue con `followup_level`. Así NO hay que tocar el
-- CHECK de `notifications.type`.
-- Cuando el aviso agrupa varias quotes, `quote_id` NO va en `data`
-- (`jsonb_strip_nulls`), así la app abre el carrusel completo en vez de una sola.
--
-- ── A QUIÉN SE LE AVISA ───────────────────────────────────────────────────
-- Exactamente el mismo conjunto que `notify_quote_request`, sin inventar otro:
--   · `concierge_mode = false` → el dueño del grupo y sus miembros aceptados
--     (invitaciones de tipo 'membership' y 'event' en estado 'accepted'). El dueño
--     recibe el texto en segunda persona; los miembros, el texto de grupo — la
--     misma distinción que ya hace `notify_quote_request`.
--   · `concierge_mode = true`  → admins no muteados para ese país + admin_ops con
--     `admin_country_scope` de ese país.
-- Si el grupo no tiene dueño y no está en conserjería, la quote NO se toca (no hay
-- a quién avisarle, y marcarla sería perder el recordatorio para siempre).
--
-- ── EL ESCALAMIENTO DE 48 h NO SE IMPLEMENTA AQUÍ ─────────────────────────
-- `party_proposals` todavía no existe (el armador es una etapa posterior), y NO se
-- va a suponer que cualquier `event_id` significa "Arma mi fiesta": `event_id` ya se
-- usa para cotizaciones sueltas agregadas a un evento (sql/585). Por eso
-- `escalated_48h_at` se crea pero **ninguna línea la escribe**.
-- Cuando exista `party_proposals`, el enganche va justo después del bloque de 36 h y
-- necesita: (1) filtrar solo quotes cuyo `event_id` pertenezca a una propuesta,
-- (2) agrupar por propuesta —no por grupo— para mandar UN aviso con el progreso
-- ("3 de 5 cotizados, faltan X y Y"), (3) marcar `escalated_48h_at` de cada quote
-- involucrada dentro de la misma subtransacción que el INSERT.
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

DO $guard$
BEGIN
  IF to_regprocedure('public.tz_for_event(text, text)') IS NULL THEN
    RAISE EXCEPTION 'No existe tz_for_event(text,text). Abortando.';
  END IF;
  IF to_regprocedure('public.expire_stale_quotes()') IS NULL THEN
    RAISE EXCEPTION 'No existe expire_stale_quotes(). Abortando.';
  END IF;
  IF to_regprocedure('public.admin_is_country_muted(text, uuid)') IS NULL THEN
    RAISE EXCEPTION 'No existe admin_is_country_muted(text,uuid). Abortando.';
  END IF;
  IF to_regprocedure('public.country_code_of(text)') IS NULL THEN
    RAISE EXCEPTION 'No existe country_code_of(text). Abortando.';
  END IF;
  -- `expire_stale_quotes` debe estar EXACTAMENTE como la auditamos: si alguien la
  -- cambio, hay que releerla antes de meter recordatorios encima.
  IF (SELECT md5(prosrc) FROM pg_proc WHERE oid = to_regprocedure('public.expire_stale_quotes()'))
     <> '3c47a4175f7baf0b598c400664b13a36' THEN
    RAISE EXCEPTION 'expire_stale_quotes cambio (md5 distinto de 3c47a417...). Reauditar antes de aplicar 718.';
  END IF;
  -- 'new_quote_request' debe seguir siendo un type valido del CHECK
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.notifications'::regclass AND contype = 'c'
      AND pg_get_constraintdef(oid) LIKE '%new_quote_request%'
  ) THEN
    RAISE EXCEPTION 'El CHECK de notifications.type ya no admite new_quote_request. Reauditar.';
  END IF;
END
$guard$;

-- ── 1. Columnas de control (aditivas, todas NULL) ──────────────────────────
ALTER TABLE public.quotes
  ADD COLUMN IF NOT EXISTS reminder_12h_at  timestamptz,
  ADD COLUMN IF NOT EXISTS reminder_36h_at  timestamptz,
  ADD COLUMN IF NOT EXISTS escalated_48h_at timestamptz;

COMMENT ON COLUMN public.quotes.reminder_12h_at  IS 'sql/718 — cuando se envio el primer recordatorio (12 h). NULL = todavia no se envia. Es la verdad de la idempotencia, no las notificaciones.';
COMMENT ON COLUMN public.quotes.reminder_36h_at  IS 'sql/718 — cuando se envio el segundo recordatorio (36 h). Si se manda el de 36 h sin haber mandado el de 12 h, ambas columnas se sellan a la vez para no soltar dos avisos seguidos.';
COMMENT ON COLUMN public.quotes.escalated_48h_at IS 'sql/718 — reservada para el escalamiento de 48 h de "Arma mi fiesta". HOY NINGUNA LINEA LA ESCRIBE: party_proposals aun no existe y event_id NO implica "Arma mi fiesta".';

-- Indice parcial para que el cron no recorra la tabla completa cada hora.
CREATE INDEX IF NOT EXISTS idx_quotes_pending_reminders
  ON public.quotes (created_at)
  WHERE status = 'pending' AND (reminder_12h_at IS NULL OR reminder_36h_at IS NULL);

-- ── 2. La función ──────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.notify_pending_quotes()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_now      TIMESTAMPTZ := NOW();
  -- Misma expresion de "hoy" que usa expire_stale_quotes, para que las dos
  -- funciones coincidan en cuando un evento ya paso.
  v_today_mx DATE := (NOW() AT TIME ZONE 'America/Mexico_City')::date;
  v_dest     RECORD;
  v_ids      UUID[];
  v_n        INT;
  v_title    TEXT;
  v_body     TEXT;
  v_body_m   TEXT;   -- mismo aviso, redactado para los miembros del grupo
  v_country  TEXT;
  v_sent_12  INT := 0;
  v_sent_36  INT := 0;
  v_push_12  INT := 0;
  v_push_36  INT := 0;
  v_skip_tz  INT := 0;
BEGIN
  -- Lock propio: NO es el 5566778899 de expire_stale_quotes.
  IF NOT pg_try_advisory_xact_lock(8812345678) THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'lock_busy');
  END IF;

  FOR v_dest IN
    SELECT g.id             AS group_id,
           g.name           AS group_name,
           g.owner_id       AS owner_id,
           g.country        AS country,
           g.concierge_mode AS concierge_mode,
           public.tz_for_event(g.state, g.country) AS tz
    FROM public.quotes q
    JOIN public.groups g ON g.id = q.group_id
    WHERE q.status = 'pending'
      AND q.event_date >= v_today_mx
      -- Una quote que ya paso los 3 dias le toca a expire_stale_quotes, no a un
      -- recordatorio: si el cron de expiracion se atraso, no le insistimos al
      -- proveedor por algo que esta por cerrarse.
      AND q.created_at > v_now - INTERVAL '3 days'
      -- Sin dueño y sin conserjería no hay a quién avisarle: no se toca, para no
      -- marcar una quote que nadie recibio.
      AND (g.concierge_mode OR g.owner_id IS NOT NULL)
      AND (
        (q.reminder_12h_at IS NULL AND q.created_at < v_now - INTERVAL '12 hours')
        OR
        (q.reminder_36h_at IS NULL AND q.created_at < v_now - INTERVAL '36 hours')
      )
    GROUP BY g.id, g.name, g.owner_id, g.country, g.concierge_mode
  LOOP
    -- ── Horario silencioso del destinatario ────────────────────────────────
    IF EXTRACT(HOUR FROM v_now AT TIME ZONE v_dest.tz) NOT BETWEEN 8 AND 20 THEN
      v_skip_tz := v_skip_tz + 1;
      CONTINUE;
    END IF;

    v_country := public.country_code_of(v_dest.country);

    -- ══════════════ ETAPA 36 h (primero: es la mas urgente) ══════════════
    BEGIN
      WITH reclamadas AS (
        UPDATE public.quotes q
        SET reminder_36h_at = v_now,
            -- Si nunca salio el de 12 h (cron caido, o ventana cerrada mucho
            -- tiempo), se sella tambien: un solo aviso en vez de dos seguidos.
            reminder_12h_at = COALESCE(q.reminder_12h_at, v_now)
        WHERE q.group_id = v_dest.group_id
          AND q.status = 'pending'
          AND q.event_date >= v_today_mx
          AND q.created_at > v_now - INTERVAL '3 days'
          AND q.reminder_36h_at IS NULL
          AND q.created_at < v_now - INTERVAL '36 hours'
        RETURNING q.id
      )
      SELECT COALESCE(array_agg(id), '{}'::uuid[]) INTO v_ids FROM reclamadas;

      v_n := COALESCE(array_length(v_ids, 1), 0);

      IF v_n > 0 THEN
        v_sent_36 := v_sent_36 + v_n;

        IF v_dest.concierge_mode THEN
          v_title := '⏰ Sin cotizar — ' || v_dest.group_name;
          v_body  := CASE WHEN v_n = 1
            THEN 'Una solicitud para ' || v_dest.group_name || ' lleva mas de 36 h sin precio. Se cierra sola a los 3 dias.'
            ELSE v_n || ' solicitudes para ' || v_dest.group_name || ' llevan mas de 36 h sin precio. Se cierran solas a los 3 dias.' END;
          INSERT INTO public.notifications (user_id, type, title, body, data)
          SELECT p.id, 'new_quote_request', v_title, v_body,
                 jsonb_strip_nulls(jsonb_build_object(
                   'reminder_stage', '36h',
                   'group_id',       v_dest.group_id,
                   'quote_id',       CASE WHEN v_n = 1 THEN v_ids[1] END,
                   'quote_ids',      to_jsonb(v_ids),
                   'screen',         'AdminManagedQuotes'))
          FROM public.profiles p
          WHERE (p.role = 'admin'     AND NOT public.admin_is_country_muted(v_dest.country, p.id))
             OR (p.role = 'admin_ops' AND p.admin_country_scope = v_country);
        ELSE
          v_title := '⏰ Ultimo aviso: cotizacion sin responder';
          v_body  := CASE WHEN v_n = 1
            THEN 'Una solicitud lleva mas de 36 h esperando tu precio. Si no respondes, se cierra sola a los 3 dias.'
            ELSE 'Tienes ' || v_n || ' solicitudes de cotizacion con mas de 36 h sin responder. Se cierran solas a los 3 dias.' END;
          v_body_m := CASE WHEN v_n = 1
            THEN 'Su grupo tiene una solicitud de cotizacion con mas de 36 h sin responder.'
            ELSE 'Su grupo tiene ' || v_n || ' solicitudes de cotizacion con mas de 36 h sin responder.' END;
          INSERT INTO public.notifications (user_id, type, title, body, data)
          SELECT r.uid, 'new_quote_request', v_title,
                 CASE WHEN r.uid = v_dest.owner_id THEN v_body ELSE v_body_m END,
                 jsonb_strip_nulls(jsonb_build_object(
                   'reminder_stage', '36h',
                   'group_id',       v_dest.group_id,
                   'quote_id',       CASE WHEN v_n = 1 THEN v_ids[1] END,
                   'quote_ids',      to_jsonb(v_ids)))
          FROM (
            -- Mismo conjunto que notify_quote_request: el dueño y los miembros
            -- aceptados (membresia y por evento). UNION deduplica si el dueño
            -- tambien aparece como miembro.
            SELECT v_dest.owner_id AS uid
            UNION
            SELECT ji.invited_user_id
            FROM public.job_invitations ji
            WHERE ji.group_id = v_dest.group_id
              AND ji.invitation_type IN ('membership', 'event')
              AND ji.status = 'accepted'
              AND ji.invited_user_id IS NOT NULL
          ) r;
        END IF;
        v_push_36 := v_push_36 + 1;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      -- La subtransaccion se revierte COMPLETA: las marcas vuelven a NULL y el
      -- siguiente ciclo lo reintenta. Nunca queda marcada sin aviso.
      RAISE WARNING '[notify_pending_quotes] 36h fallo para grupo %: %', v_dest.group_id, SQLERRM;
    END;

    -- ══════════════ ETAPA 12 h ══════════════
    -- Las que se acaban de sellar arriba ya tienen reminder_12h_at, asi que no
    -- vuelven a entrar aqui: no se manda doble aviso.
    BEGIN
      WITH reclamadas AS (
        UPDATE public.quotes q
        SET reminder_12h_at = v_now
        WHERE q.group_id = v_dest.group_id
          AND q.status = 'pending'
          AND q.event_date >= v_today_mx
          AND q.created_at > v_now - INTERVAL '3 days'
          AND q.reminder_12h_at IS NULL
          AND q.created_at < v_now - INTERVAL '12 hours'
        RETURNING q.id
      )
      SELECT COALESCE(array_agg(id), '{}'::uuid[]) INTO v_ids FROM reclamadas;

      v_n := COALESCE(array_length(v_ids, 1), 0);

      IF v_n > 0 THEN
        v_sent_12 := v_sent_12 + v_n;

        IF v_dest.concierge_mode THEN
          v_title := '📞 Falta cotizar — ' || v_dest.group_name;
          v_body  := CASE WHEN v_n = 1
            THEN 'Una solicitud para ' || v_dest.group_name || ' lleva 12 h sin precio. Contactalo para cotizar.'
            ELSE v_n || ' solicitudes para ' || v_dest.group_name || ' llevan 12 h sin precio. Contactalo para cotizar.' END;
          INSERT INTO public.notifications (user_id, type, title, body, data)
          SELECT p.id, 'new_quote_request', v_title, v_body,
                 jsonb_strip_nulls(jsonb_build_object(
                   'reminder_stage', '12h',
                   'group_id',       v_dest.group_id,
                   'quote_id',       CASE WHEN v_n = 1 THEN v_ids[1] END,
                   'quote_ids',      to_jsonb(v_ids),
                   'screen',         'AdminManagedQuotes'))
          FROM public.profiles p
          WHERE (p.role = 'admin'     AND NOT public.admin_is_country_muted(v_dest.country, p.id))
             OR (p.role = 'admin_ops' AND p.admin_country_scope = v_country);
        ELSE
          v_title := '📋 Tienes una cotizacion sin responder';
          v_body  := CASE WHEN v_n = 1
            THEN 'Un cliente espera tu precio desde hace 12 h. Responde para no perder el evento.'
            ELSE 'Tienes ' || v_n || ' solicitudes de cotizacion pendientes desde hace 12 h. Responde para no perder los eventos.' END;
          v_body_m := CASE WHEN v_n = 1
            THEN 'Su grupo tiene una solicitud de cotizacion sin responder desde hace 12 h.'
            ELSE 'Su grupo tiene ' || v_n || ' solicitudes de cotizacion sin responder desde hace 12 h.' END;
          INSERT INTO public.notifications (user_id, type, title, body, data)
          SELECT r.uid, 'new_quote_request', v_title,
                 CASE WHEN r.uid = v_dest.owner_id THEN v_body ELSE v_body_m END,
                 jsonb_strip_nulls(jsonb_build_object(
                   'reminder_stage', '12h',
                   'group_id',       v_dest.group_id,
                   'quote_id',       CASE WHEN v_n = 1 THEN v_ids[1] END,
                   'quote_ids',      to_jsonb(v_ids)))
          FROM (
            -- Mismo conjunto que notify_quote_request: el dueño y los miembros
            -- aceptados (membresia y por evento). UNION deduplica si el dueño
            -- tambien aparece como miembro.
            SELECT v_dest.owner_id AS uid
            UNION
            SELECT ji.invited_user_id
            FROM public.job_invitations ji
            WHERE ji.group_id = v_dest.group_id
              AND ji.invitation_type IN ('membership', 'event')
              AND ji.status = 'accepted'
              AND ji.invited_user_id IS NOT NULL
          ) r;
        END IF;
        v_push_12 := v_push_12 + 1;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING '[notify_pending_quotes] 12h fallo para grupo %: %', v_dest.group_id, SQLERRM;
    END;

    -- ══════════════ ETAPA 48 h ══════════════
    -- NO IMPLEMENTADA A PROPOSITO. Ver el encabezado de sql/718: requiere
    -- party_proposals, que todavia no existe, y event_id NO implica "Arma mi
    -- fiesta". `escalated_48h_at` queda sin escribir.
  END LOOP;

  RETURN jsonb_build_object(
    'ok',                   true,
    'quotes_12h',           v_sent_12,
    'quotes_36h',           v_sent_36,
    'pushes_12h',           v_push_12,
    'pushes_36h',           v_push_36,
    'omitidos_por_horario', v_skip_tz,
    'ran_at',               v_now
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$function$;

COMMENT ON FUNCTION public.notify_pending_quotes() IS
  'sql/718 — recordatorios de cotizaciones pendientes a las 12 h y 36 h. Idempotencia atomica con quotes.reminder_12h_at / reminder_36h_at (UPDATE ... RETURNING en un CTE, en la misma subtransaccion que el INSERT). Solo status=pending y evento no pasado. Destinatario resuelto AL ENVIAR segun concierge_mode (mismo patron que notify_quote_request). Ventana 8:00-21:00 en la zona del grupo (tz_for_event, fallback America/Mexico_City). Agrupa por grupo: un push por destinatario y etapa, marcando cada quote individualmente. NO expira nada: los 3 dias siguen siendo de expire_stale_quotes. El escalamiento de 48 h queda pendiente hasta que exista party_proposals.';

-- Solo el cron (postgres) y el backend pueden ejecutarla.
REVOKE ALL ON FUNCTION public.notify_pending_quotes() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.notify_pending_quotes() FROM anon;
REVOKE ALL ON FUNCTION public.notify_pending_quotes() FROM authenticated;
GRANT EXECUTE ON FUNCTION public.notify_pending_quotes() TO postgres, service_role;

-- ── 3. Cron: cada hora en el minuto 15 ─────────────────────────────────────
-- 15 minutos despues de 'expire-stale-quotes' (que corre en el minuto 0), para que
-- una quote que acaba de expirar NO reciba recordatorio.
DO $cron$
BEGIN
  PERFORM cron.unschedule('notify-pending-quotes')
  WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'notify-pending-quotes');

  PERFORM cron.schedule('notify-pending-quotes', '15 * * * *',
                        'SELECT public.notify_pending_quotes();');
END
$cron$;

DO $verify$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname='notify-pending-quotes' AND active) THEN
    RAISE EXCEPTION 'El cron notify-pending-quotes no quedo activo. Abortando.';
  END IF;
  IF has_function_privilege('authenticated', 'public.notify_pending_quotes()', 'EXECUTE') THEN
    RAISE EXCEPTION 'authenticated puede ejecutar notify_pending_quotes. Abortando.';
  END IF;
  IF has_function_privilege('anon', 'public.notify_pending_quotes()', 'EXECUTE') THEN
    RAISE EXCEPTION 'anon puede ejecutar notify_pending_quotes. Abortando.';
  END IF;
  IF (SELECT COUNT(*) FROM pg_attribute WHERE attrelid='public.quotes'::regclass
      AND attname IN ('reminder_12h_at','reminder_36h_at','escalated_48h_at')
      AND NOT attisdropped) <> 3 THEN
    RAISE EXCEPTION 'Faltan columnas de recordatorio. Abortando.';
  END IF;
  IF (SELECT md5(prosrc) FROM pg_proc WHERE oid = to_regprocedure('public.expire_stale_quotes()'))
     <> '3c47a4175f7baf0b598c400664b13a36' THEN
    RAISE EXCEPTION '718 modifico expire_stale_quotes. Abortando.';
  END IF;
  -- Nadie debe escribir escalated_48h_at todavia.
  IF (SELECT prosrc FROM pg_proc WHERE oid = to_regprocedure('public.notify_pending_quotes()'))
     LIKE '%escalated_48h_at =%' THEN
    RAISE EXCEPTION 'notify_pending_quotes escribe escalated_48h_at y no deberia. Abortando.';
  END IF;
END
$verify$;

NOTIFY pgrst, 'reload schema';

COMMIT;
