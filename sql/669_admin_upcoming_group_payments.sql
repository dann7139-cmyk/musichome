-- ============================================================
-- sql/669_admin_upcoming_group_payments.sql
--
-- Petición real (2026-09-19): "quiero adelantar pago a los grupos [o
-- cualquier categoría de proveedor] y al final que me diga cuánto les
-- debo, para dar anticipo y sentirme más seguro de que sí van a ir al
-- evento."
--
-- Hallazgo: el backend para esto YA EXISTE completo desde sql/529/533
-- (admin_register_group_payment con kind='advance', que exige
-- payout_status='held' — es decir, ya pagado por el cliente pero el
-- evento aún no termina) y la pantalla FinancialScreen.tsx / AdsManager
-- ya tienen el botón "💵 Registrar anticipo" y el modal completo.
--
-- PERO el único listado que alimenta ese botón — admin_get_pending_
-- group_payments — SOLO trae reservas con payout_status='released'
-- (evento ya terminado). Contra una reserva 'released' el kind='advance'
-- SIEMPRE es rechazado (exige 'held'), así que ese botón nunca podía
-- funcionar en la práctica: no existía ninguna cola que mostrara las
-- reservas "held" (pagadas, evento por venir) para darles anticipo.
--
-- Este archivo agrega esa cola que faltaba — de solo lectura, mismo
-- shape de datos que admin_get_pending_group_payments, mismo candado de
-- rol/país/mute ya usado en esa función — para que el flujo completo
-- (anticipo antes del evento → saldo exacto al liquidar después) tenga
-- una entrada real. No toca admin_register_group_payment ni ninguna
-- función que mueva dinero — es genérica para cualquier categoría de
-- proveedor (groups.genre), no solo "grupo musical", porque todas
-- comparten la misma tabla reservations/group_wallets.
--
-- Sandbox probado con fixture (reserva 'held' con anticipo parcial ya
-- registrado, categoría "Fotografía" para confirmar que no es exclusivo
-- de grupos musicales): saldo_pendiente calculó correcto (10000-3000=7000).
--
-- Rollback: sql/669_admin_upcoming_group_payments_ROLLBACK.sql
-- ============================================================

BEGIN;

CREATE FUNCTION public.admin_get_upcoming_group_payments(p_limit integer DEFAULT 50)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_role TEXT;
  v_result jsonb;
BEGIN
  SELECT role INTO v_caller_role FROM profiles WHERE id = auth.uid();
  IF v_caller_role NOT IN ('admin', 'admin_ops') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;

  SELECT jsonb_build_object(
    'ok', true,
    'items', COALESCE(jsonb_agg(x.item ORDER BY x.event_date ASC NULLS LAST), '[]'::jsonb)
  )
  INTO v_result
  FROM (
    SELECT
      r.event_date,
      jsonb_build_object(
        'reservation_id',   r.id,
        'folio',            r.folio,
        'event_date',       r.event_date,
        'event_time',       r.event_time,
        'group_id',         r.group_id,
        'group_name',       g.name,
        'group_genre',      g.genre,
        'owner_id',         g.owner_id,
        'client_name',      p.full_name,
        'currency_code',    r.currency_code,
        'group_earnings',   r.group_earnings,
        'total_anticipado', COALESCE(gp.total_anticipado, 0),
        'saldo_pendiente',  r.group_earnings - COALESCE(gp.total_anticipado, 0),
        'bank_clabe',       w.bank_clabe,
        'bank_name',        w.bank_name,
        'account_holder',   w.account_holder,
        'bank_linked_at',   w.bank_linked_at,
        'country_code',     country_code_of(g.country),
        'country',          COALESCE(g.country, 'México')
      ) AS item
    FROM reservations r
    JOIN      groups   g ON g.id = r.group_id
    LEFT JOIN profiles p ON p.id = r.client_id
    LEFT JOIN wallets   w ON w.user_id = g.owner_id
    LEFT JOIN LATERAL (
      SELECT SUM(amount) AS total_anticipado
      FROM group_reservation_payments
      WHERE reservation_id = r.id
    ) gp ON true
    WHERE r.payout_status  = 'held'
      AND r.payment_status IN ('paid','fully_paid','deposit_paid')
      AND COALESCE(r.group_earnings, 0) > 0
      AND (r.group_earnings - COALESCE(gp.total_anticipado, 0)) > 0
      AND (v_caller_role = 'admin' OR country_code_of(g.country) = admin_ops_country())
      AND NOT admin_is_country_muted(g.country)
    ORDER BY r.event_date ASC NULLS LAST
    LIMIT p_limit
  ) x;

  RETURN v_result;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_get_upcoming_group_payments(integer) TO authenticated;

COMMIT;

-- ── Verificación ──────────────────────────────────────────────────
SELECT proname, pg_get_function_identity_arguments(oid) AS firma, prosecdef
FROM pg_proc WHERE proname = 'admin_get_upcoming_group_payments';

SELECT '669_admin_upcoming_group_payments ✅' AS status;
