-- sql/633_admin_ops_country_summary.sql
--
-- Resumen de ingresos SOLO de su país para admin_ops — el equivalente a
-- lo que el admin completo ya ve en admin_finance_summary, pero
-- IMPOSIBLE de usar para ver otro país: a diferencia de admin_finance_summary
-- (que no filtra por país en absoluto, pensado para el admin completo),
-- esta función nueva no recibe ningún parámetro de país — siempre usa
-- admin_ops_country() del que llama. Un admin_ops nunca puede pedir
-- el de otro país, ni cambiando el código de la app, porque el filtro
-- vive aquí adentro, no en la UI.
--
-- No toca admin_finance_summary (el admin completo sigue exactamente igual).
--
-- HALLAZGO REAL (no relacionado a admin_ops, encontrado al probar en
-- sandbox): admin_finance_summary usa `(r.created_at AT TIME ZONE
-- 'America/Mexico_City')::date` para agrupar por día — pero
-- reservations.created_at es `timestamp WITHOUT time zone` que en
-- realidad guarda hora UTC (el default es now(), sesión en UTC). Aplicar
-- "AT TIME ZONE" directo sobre un valor naive lo trata como si YA fuera
-- hora de CDMX, produciendo la fecha equivocada para cualquier evento
-- creado entre ~18:00 y 23:59 hora CDMX (se cuenta como "mañana"). Esta
-- función nueva corrige el patrón con `r.created_at::timestamptz AT TIME
-- ZONE 'America/Mexico_City'` (primero declara que es UTC, luego
-- convierte) — verificado en sandbox. admin_finance_summary NO se toca
-- aquí porque el usuario prefirió no arriesgar su panel ya en uso sin
-- revisarlo aparte primero.
BEGIN;

CREATE OR REPLACE FUNCTION public.admin_ops_country_summary(p_from date DEFAULT NULL::date, p_to date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_role TEXT;
  v_country     TEXT;
  v_from        DATE := COALESCE(p_from, '2000-01-01');
  v_to          DATE := COALESCE(p_to, (NOW() AT TIME ZONE 'America/Mexico_City')::date);
  v_result      JSONB;
BEGIN
  SELECT role INTO v_caller_role FROM profiles WHERE id = auth.uid();
  IF v_caller_role <> 'admin_ops' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin_ops');
  END IF;

  v_country := admin_ops_country();

  WITH base AS (
    SELECT r.*,
           COALESCE(r.currency_code, 'MXN')                        AS moneda,
           (COALESCE(r.total_price, 0) + COALESCE(r.msi_fee_amount, 0)) AS cobrado,
           COALESCE(r.group_earnings, r.base_price,
                    ROUND(COALESCE(r.total_price, 0) / 1.20, 2))   AS de_grupos,
           (COALESCE(r.service_fee_amount, r.commission_amount,
                     ROUND(COALESCE(r.total_price, 0) - COALESCE(r.group_earnings, r.base_price, ROUND(COALESCE(r.total_price,0)/1.20,2)), 2))
            + COALESCE(r.msi_fee_amount, 0))                       AS comision_bruta
    FROM reservations r
    JOIN groups g ON g.id = r.group_id
    WHERE (r.created_at::timestamptz AT TIME ZONE 'America/Mexico_City')::date BETWEEN v_from AND v_to
      AND country_code_of(g.country) = v_country
  ),
  pagadas AS (
    SELECT * FROM base WHERE payment_status IN ('paid', 'fully_paid', 'deposit_paid')
  )
  SELECT jsonb_build_object(
    'ok',      true,
    'country', v_country,
    'from',    v_from,
    'to',      v_to,
    'eventos_cobrados',  COUNT(*),
    'total_cobrado',     COALESCE(SUM(cobrado), 0),
    'dinero_grupos',     COALESCE(SUM(de_grupos), 0),
    'comision_daricefy', COALESCE(SUM(comision_bruta), 0)
  )
  INTO v_result
  FROM pagadas;

  RETURN v_result;
END;
$function$;

COMMIT;
