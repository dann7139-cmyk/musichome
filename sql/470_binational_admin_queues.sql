-- ============================================================
-- sql/470_binational_admin_queues.sql
-- Panel admin BINACIONAL 🇲🇽/🇺🇸 (decisión 2026-07-11):
-- las 3 colas (retiros, reembolsos, no-shows) exponen país/estado/ciudad,
-- moneda y método de pago esperado. Cuando existan grupos de EE.UU. el
-- panel los separa AUTOMÁTICAMENTE — sin tocar código otra vez.
--
--   · Moneda/país derivados de datos que YA existen (groups.country/state,
--     profiles.country, reservations.currency_code).
--   · Método esperado: MX → 'spei' (CLABE manual) · US → 'stripe_ach'
--     (se muestra "Pendiente de integración" hasta activar Stripe US).
--   · Read-only: nada de esto toca wallets ni pagos.
-- ============================================================

BEGIN;

-- ── Helper: normalizar país a código ('MX' | 'US' | otro) ────────────────────
CREATE OR REPLACE FUNCTION public.country_code_of(p_country TEXT)
RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN p_country IS NULL THEN 'MX'   -- default de la plataforma
    WHEN LOWER(TRIM(p_country)) IN ('estados unidos','united states','usa','us','eeuu','ee.uu.','u.s.','united states of america')
      THEN 'US'
    WHEN LOWER(TRIM(p_country)) IN ('méxico','mexico','mx') THEN 'MX'
    ELSE UPPER(LEFT(TRIM(p_country), 2))
  END;
$$;

-- ═══════════════════════════════════════════════════════════════════
-- 1. RETIROS DE GRUPOS — admin_withdrawals_queue (nueva, reemplaza el
--    select directo del panel; agrega grupo + geografía + moneda)
-- ═══════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.admin_withdrawals_queue(p_limit INT DEFAULT 60)
RETURNS TABLE (
  id                 UUID,
  user_id            UUID,
  owner_name         TEXT,
  owner_phone        TEXT,
  group_name         TEXT,
  country_code       TEXT,
  country            TEXT,
  state              TEXT,
  city               TEXT,
  currency           TEXT,
  expected_method    TEXT,     -- 'spei' | 'stripe_ach'
  amount             NUMERIC,
  status             TEXT,
  bank_clabe         TEXT,
  bank_name          TEXT,
  account_holder     TEXT,
  transfer_reference TEXT,
  receipt_path       TEXT,
  created_at         TIMESTAMPTZ,
  processed_at       TIMESTAMPTZ
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM profiles pr WHERE pr.id = auth.uid() AND pr.role = 'admin') THEN
    RAISE EXCEPTION 'Solo administradores';
  END IF;
  RETURN QUERY
  SELECT
    w.id, w.user_id,
    p.full_name, p.phone,
    g.name,
    country_code_of(COALESCE(g.country, p.country)),
    COALESCE(g.country, p.country, 'México'),
    COALESCE(g.state,  p.state),
    COALESCE(g.city,   p.city),
    CASE WHEN country_code_of(COALESCE(g.country, p.country)) = 'US' THEN 'USD' ELSE 'MXN' END,
    CASE WHEN country_code_of(COALESCE(g.country, p.country)) = 'US' THEN 'stripe_ach' ELSE 'spei' END,
    w.amount, w.status,
    w.bank_clabe, w.bank_name, w.account_holder,
    w.transfer_reference, w.receipt_path,
    w.created_at, w.processed_at
  FROM withdrawals w
  JOIN profiles p ON p.id = w.user_id
  LEFT JOIN groups g ON g.owner_id = w.user_id
  ORDER BY (w.status IN ('pending','processing')) DESC, w.created_at DESC
  LIMIT p_limit;
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_withdrawals_queue(INT) TO authenticated;

-- ═══════════════════════════════════════════════════════════════════
-- 2. REEMBOLSOS — admin_manual_refund_queue v2 (agrega geografía+moneda
--    del CLIENTE; conserva todas las columnas existentes)
-- ═══════════════════════════════════════════════════════════════════
DROP FUNCTION IF EXISTS public.admin_manual_refund_queue(TEXT);

CREATE OR REPLACE FUNCTION public.admin_manual_refund_queue(p_status TEXT DEFAULT NULL)
RETURNS TABLE (
  id                 UUID,
  reservation_id     UUID,
  client_id          UUID,
  folio              TEXT,
  client_name        TEXT,
  client_phone       TEXT,
  country_code       TEXT,
  country            TEXT,
  state              TEXT,
  city               TEXT,
  currency           TEXT,
  payment_method     TEXT,
  amount             NUMERIC,
  clabe              TEXT,
  account_holder     TEXT,
  bank_name          TEXT,
  due_date           DATE,
  status             TEXT,
  transfer_reference TEXT,
  receipt_path       TEXT,
  api_error          TEXT,
  created_at         TIMESTAMPTZ,
  processed_at       TIMESTAMPTZ
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM profiles pr WHERE pr.id = auth.uid() AND pr.role = 'admin') THEN
    RAISE EXCEPTION 'Solo administradores';
  END IF;
  RETURN QUERY
  SELECT mr.id, mr.reservation_id, mr.client_id, mr.folio,
         p.full_name, p.phone,
         country_code_of(p.country),
         COALESCE(p.country, 'México'),
         p.state, p.city,
         COALESCE(r.currency_code, 'MXN'),
         mr.payment_method, mr.amount, mr.clabe, mr.account_holder, mr.bank_name,
         mr.due_date, mr.status, mr.transfer_reference, mr.receipt_path, mr.api_error,
         mr.created_at, mr.processed_at
  FROM manual_refunds mr
  JOIN profiles p ON p.id = mr.client_id
  LEFT JOIN reservations r ON r.id = mr.reservation_id
  WHERE (p_status IS NULL OR mr.status = p_status)
  ORDER BY (mr.status = 'sent'), mr.due_date, mr.created_at;
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_manual_refund_queue(TEXT) TO authenticated;

-- ═══════════════════════════════════════════════════════════════════
-- 3. NO-SHOWS — pendientes e historial con geografía + moneda
--    (base: definición VIVA de 447/388 — conserva teléfonos, has_strike
--     y filtros de resolución TAL CUAL; solo se agregan campos)
-- ═══════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.admin_get_no_shows(p_limit integer DEFAULT 50)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_role TEXT;
  v_result      JSONB;
BEGIN
  SELECT role INTO v_caller_role FROM profiles WHERE id = auth.uid();
  IF v_caller_role <> 'admin' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Acceso restringido a administradores');
  END IF;

  SELECT jsonb_build_object(
    'ok',    true,
    'items', COALESCE(
      jsonb_agg(
        jsonb_build_object(
          'id',            r.id,
          'folio',         r.folio,
          'event_date',    r.event_date,
          'event_time',    r.event_time,
          'total_price',   r.total_price,
          'payout_status', r.payout_status,
          'cancelled_at',  r.cancelled_at,
          'group_name',    g.name,
          'group_id',      r.group_id,
          'group_phone',   po.phone,
          'client_name',   p.full_name,
          'client_phone',  p.phone,
          'country_code',  country_code_of(g.country),          -- [470]
          'country',       COALESCE(g.country, 'México'),        -- [470]
          'state',         g.state,                              -- [470]
          'city',          g.city,                               -- [470]
          'currency',      COALESCE(r.currency_code, 'MXN'),     -- [470]
          'has_strike',    EXISTS (
            SELECT 1 FROM group_strikes gs
            WHERE gs.group_id      = r.group_id
              AND gs.strike_type   = 'no_show'
              AND gs.reservation_id = r.id
          )
        )
        ORDER BY r.cancelled_at DESC
      ),
      '[]'::jsonb
    )
  )
  INTO v_result
  FROM reservations r
  LEFT JOIN groups   g  ON g.id  = r.group_id
  LEFT JOIN profiles po ON po.id = g.owner_id
  LEFT JOIN profiles p  ON p.id  = r.client_id
  WHERE r.cancellation_type          = 'system_auto'
    AND r.cancel_reason              = 'no_show_grupo'
    AND r.admin_no_show_resolution   IS NULL
  LIMIT p_limit;

  RETURN v_result;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_get_no_shows(integer) TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_get_no_shows_history(p_limit INT DEFAULT 50)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_result JSONB;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Acceso restringido a administradores');
  END IF;

  SELECT jsonb_build_object(
    'ok',    true,
    'items', COALESCE(
      jsonb_agg(
        jsonb_build_object(
          'id',                        r.id,
          'folio',                     r.folio,
          'event_date',                r.event_date,
          'total_price',               r.total_price,
          'group_name',                g.name,
          'group_id',                  r.group_id,
          'client_name',               p.full_name,
          'country_code',              country_code_of(g.country),      -- [470]
          'country',                   COALESCE(g.country, 'México'),    -- [470]
          'state',                     g.state,                          -- [470]
          'city',                      g.city,                           -- [470]
          'currency',                  COALESCE(r.currency_code, 'MXN'), -- [470]
          'admin_no_show_resolution',  r.admin_no_show_resolution,
          'admin_no_show_resolved_at', r.admin_no_show_resolved_at,
          'admin_no_show_notes',       r.admin_no_show_notes,
          'resolver_name',             resolver.full_name,
          'has_strike',                EXISTS (
            SELECT 1 FROM group_strikes gs
            WHERE gs.group_id       = r.group_id
              AND gs.strike_type    = 'no_show'
              AND gs.reservation_id = r.id
          )
        )
        ORDER BY r.admin_no_show_resolved_at DESC
      ),
      '[]'::jsonb
    )
  )
  INTO v_result
  FROM reservations r
  LEFT JOIN groups   g        ON g.id = r.group_id
  LEFT JOIN profiles p        ON p.id = r.client_id
  LEFT JOIN profiles resolver ON resolver.id = r.admin_no_show_resolved_by
  WHERE r.cancellation_type        = 'system_auto'
    AND r.cancel_reason            = 'no_show_grupo'
    AND r.admin_no_show_resolution IS NOT NULL
  LIMIT p_limit;

  RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_get_no_shows_history(INT) TO authenticated;

COMMIT;

-- ── VERIFICACIONES ────────────────────────────────────────────────────────────
-- V1: helper de país
SELECT country_code_of('México') AS mx, country_code_of('Estados Unidos') AS us,
       country_code_of(NULL) AS defecto;
-- Esperado: MX | US | MX

-- V2: la cola de retiros regresa geografía y moneda
SELECT group_name, country_code, state, city, currency, expected_method, amount, status
FROM admin_withdrawals_queue();

-- V3: no-shows conserva teléfonos + trae país
SELECT prosrc LIKE '%group_phone%' AS conserva_telefonos,
       prosrc LIKE '%country_code%' AS trae_pais
FROM pg_proc WHERE proname = 'admin_get_no_shows';
-- Esperado: true | true

SELECT '470_binational_admin_queues.sql ejecutado ✅' AS status;
