-- ════════════════════════════════════════════════════════════════════
-- 90_fix_member_payouts.sql
--
-- PROBLEMA:
--   generate_event_payouts solo incluye integrantes si están en
--   package_member_distribution. Si el dueño no configuró la distribución
--   del paquete (o es un evento express sin package_id), los integrantes
--   quedan fuera de event_payouts y no reciben pago.
--
-- SOLUCIÓN:
--   Si después de leer package_member_distribution no hay entradas
--   (v_allocated = 0), el trigger busca todos los integrantes activos
--   del grupo (job_invitations membership accepted) y divide el monto
--   total_price entre owner + todos los miembros en partes iguales.
--
-- Ejecutar después de 34_event_payouts.sql y 64_commission_distribution.sql.
-- ════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.generate_event_payouts()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_owner_id    UUID;
  v_group_id    UUID;
  v_package_id  UUID;
  v_event_id    UUID;
  v_total       NUMERIC(10,2);
  v_allocated   NUMERIC(10,2) := 0;
  v_member_cnt  INT := 0;
  v_share       NUMERIC(10,2);
  rec           RECORD;
BEGIN
  -- Solo actuar cuando el status cambia A 'confirmed'
  IF NEW.status != 'confirmed' OR OLD.status = 'confirmed' THEN
    RETURN NEW;
  END IF;

  -- Datos de la reserva
  SELECT g.owner_id, r.group_id, r.package_id, r.event_id, r.total_price
  INTO   v_owner_id, v_group_id, v_package_id, v_event_id, v_total
  FROM   public.reservations r
  JOIN   public.groups g ON g.id = r.group_id
  WHERE  r.id = NEW.id;

  -- Idempotente: si ya existen payouts, no duplicar
  IF EXISTS (SELECT 1 FROM public.event_payouts WHERE reservation_id = NEW.id) THEN
    RETURN NEW;
  END IF;

  -- ── A. Distribución de paquete (si está configurada) ──────────────────────
  FOR rec IN
    SELECT
      pmd.user_id,
      pmd.amount,
      CASE WHEN pmd.user_id = v_owner_id THEN 'owner' ELSE 'member' END AS role
    FROM public.package_member_distribution pmd
    WHERE pmd.package_id = v_package_id
  LOOP
    INSERT INTO public.event_payouts
      (reservation_id, event_id, user_id, role, amount)
    VALUES
      (NEW.id, v_event_id, rec.user_id, rec.role, rec.amount)
    ON CONFLICT (reservation_id, user_id) DO NOTHING;

    v_allocated := v_allocated + rec.amount;
  END LOOP;

  -- ── A.2. Fallback: sin distribución configurada → dividir entre owner + miembros activos
  IF v_allocated = 0 THEN
    -- Contar integrantes permanentes (excluye al owner)
    SELECT COUNT(*)
    INTO   v_member_cnt
    FROM   public.job_invitations ji
    WHERE  ji.group_id        = v_group_id
      AND  ji.invitation_type = 'membership'
      AND  ji.status          = 'accepted'
      AND  ji.invited_user_id != v_owner_id;

    IF v_member_cnt > 0 THEN
      -- Reparto igual: total ÷ (owner + N miembros)
      v_share := ROUND(v_total / (v_member_cnt + 1), 2);

      -- Insertar owner
      IF v_owner_id IS NOT NULL THEN
        INSERT INTO public.event_payouts
          (reservation_id, event_id, user_id, role, amount)
        VALUES
          (NEW.id, v_event_id, v_owner_id, 'owner', v_share)
        ON CONFLICT (reservation_id, user_id) DO NOTHING;
        v_allocated := v_allocated + v_share;
      END IF;

      -- Insertar cada integrante activo
      FOR rec IN
        SELECT ji.invited_user_id AS user_id
        FROM   public.job_invitations ji
        WHERE  ji.group_id        = v_group_id
          AND  ji.invitation_type = 'membership'
          AND  ji.status          = 'accepted'
          AND  ji.invited_user_id != v_owner_id
      LOOP
        INSERT INTO public.event_payouts
          (reservation_id, event_id, user_id, role, amount)
        VALUES
          (NEW.id, v_event_id, rec.user_id, 'member', v_share)
        ON CONFLICT (reservation_id, user_id) DO NOTHING;
        v_allocated := v_allocated + v_share;
      END LOOP;
    END IF;
  END IF;

  -- ── B. Talentos invitados para la tocada ──────────────────────────────────
  IF v_event_id IS NOT NULL THEN
    FOR rec IN
      SELECT
        ji.invited_user_id                       AS user_id,
        COALESCE(ji.proposed_payment_amount, 0)  AS amount
      FROM public.job_invitations ji
      WHERE ji.event_id = v_event_id
        AND ji.status   = 'accepted'
    LOOP
      INSERT INTO public.event_payouts
        (reservation_id, event_id, user_id, role, amount)
      VALUES
        (NEW.id, v_event_id, rec.user_id, 'invited', rec.amount)
      ON CONFLICT (reservation_id, user_id) DO NOTHING;

      v_allocated := v_allocated + rec.amount;
    END LOOP;
  END IF;

  -- ── C. Si el owner aún no fue incluido, añadirlo con el resto ────────────
  IF v_owner_id IS NOT NULL
     AND NOT EXISTS (
       SELECT 1 FROM public.event_payouts
       WHERE reservation_id = NEW.id AND user_id = v_owner_id
     )
  THEN
    INSERT INTO public.event_payouts
      (reservation_id, event_id, user_id, role, amount)
    VALUES
      (NEW.id, v_event_id, v_owner_id, 'owner',
       GREATEST(0, v_total - v_allocated))
    ON CONFLICT (reservation_id, user_id) DO NOTHING;
  END IF;

  RETURN NEW;
END;
$$;

-- Recrear el trigger
DROP TRIGGER IF EXISTS trigger_generate_event_payouts ON public.reservations;
CREATE TRIGGER trigger_generate_event_payouts
  AFTER UPDATE ON public.reservations
  FOR EACH ROW EXECUTE FUNCTION public.generate_event_payouts();

-- ════════════════════════════════════════════════════════════════════
-- RPC de diagnóstico: ver event_payouts de una reserva
-- Uso: SELECT * FROM check_event_payouts('<uuid>');
-- ════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.check_event_payouts(p_reservation_id UUID)
RETURNS TABLE (
  user_id       UUID,
  full_name     TEXT,
  role          TEXT,
  amount        NUMERIC,
  payout_status TEXT
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT ep.user_id, p.full_name, ep.role, ep.amount, ep.payout_status
  FROM   public.event_payouts ep
  LEFT JOIN public.profiles p ON p.id = ep.user_id
  WHERE  ep.reservation_id = p_reservation_id
  ORDER BY ep.role, ep.amount DESC;
$$;

GRANT EXECUTE ON FUNCTION public.check_event_payouts(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.check_event_payouts(UUID) TO service_role;

-- ════════════════════════════════════════════════════════════════════
-- RPC para reparar event_payouts de reservas PASADAS donde los miembros
-- no fueron incluidos. Ejecutar UNA SOLA VEZ desde Supabase SQL Editor:
--   SELECT public.backfill_missing_member_payouts();
-- ════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.backfill_missing_member_payouts()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_res      RECORD;
  v_share    NUMERIC(10,2);
  v_cnt      INT := 0;
  v_member   RECORD;
  v_members  INT;
BEGIN
  FOR v_res IN
    SELECT r.id, r.group_id, r.total_price, r.event_id, g.owner_id
    FROM   public.reservations r
    JOIN   public.groups g ON g.id = r.group_id
    WHERE  r.status IN ('confirmed', 'in_progress', 'completed')
  LOOP
    -- Contar integrantes activos sin payout en esta reserva
    SELECT COUNT(*)
    INTO   v_members
    FROM   public.job_invitations ji
    WHERE  ji.group_id        = v_res.group_id
      AND  ji.invitation_type = 'membership'
      AND  ji.status          = 'accepted'
      AND  ji.invited_user_id != v_res.owner_id
      AND  NOT EXISTS (
        SELECT 1 FROM public.event_payouts ep
        WHERE ep.reservation_id = v_res.id
          AND ep.user_id = ji.invited_user_id
      );

    CONTINUE WHEN v_members = 0;

    -- Total de miembros activos (para calcular el reparto)
    SELECT COUNT(*)
    INTO   v_members
    FROM   public.job_invitations ji
    WHERE  ji.group_id        = v_res.group_id
      AND  ji.invitation_type = 'membership'
      AND  ji.status          = 'accepted'
      AND  ji.invited_user_id != v_res.owner_id;

    v_share := ROUND(v_res.total_price / (v_members + 1), 2);

    -- Actualizar payout del owner al nuevo share
    INSERT INTO public.event_payouts
      (reservation_id, event_id, user_id, role, amount)
    VALUES
      (v_res.id, v_res.event_id, v_res.owner_id, 'owner', v_share)
    ON CONFLICT (reservation_id, user_id)
    DO UPDATE SET amount = EXCLUDED.amount;

    -- Insertar payout de cada integrante
    FOR v_member IN
      SELECT ji.invited_user_id AS user_id
      FROM   public.job_invitations ji
      WHERE  ji.group_id        = v_res.group_id
        AND  ji.invitation_type = 'membership'
        AND  ji.status          = 'accepted'
        AND  ji.invited_user_id != v_res.owner_id
    LOOP
      INSERT INTO public.event_payouts
        (reservation_id, event_id, user_id, role, amount)
      VALUES
        (v_res.id, v_res.event_id, v_member.user_id, 'member', v_share)
      ON CONFLICT (reservation_id, user_id)
      DO UPDATE SET amount = EXCLUDED.amount;
    END LOOP;

    v_cnt := v_cnt + 1;
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'reservations_fixed', v_cnt);
END;
$$;

GRANT EXECUTE ON FUNCTION public.backfill_missing_member_payouts() TO service_role;

SELECT '90_fix_member_payouts: trigger + diagnóstico + backfill creados ✅' AS status;
