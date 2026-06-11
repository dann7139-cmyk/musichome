-- ════════════════════════════════════════════════════════════════════
-- 301_fix_generate_event_payouts.sql
--
-- Reescribe generate_event_payouts() para el nuevo modelo:
--
-- MANTIENE:
--   ✅ INSERT en event_payouts para members (is_informational=TRUE)
--   ✅ INSERT en event_payouts para invited  (is_informational=TRUE)
--   ✅ INSERT en event_payouts para owner    (is_informational=FALSE)
--
-- ELIMINA:
--   ❌ Auto-split igualitario cuando no hay distribución configurada
--      (fallback que dividía total / (owner + N miembros))
--   ❌ backfill_missing_member_payouts
--      (función que acreditaba members en reservas pasadas)
--
-- RESULTADO:
--   - event_payouts sigue siendo el registro visual/estadístico completo
--   - Solo el owner tiene is_informational=FALSE (payout real)
--   - Members/invited tienen is_informational=TRUE (solo display)
--
-- Requiere: 300_simplify_wallet_model.sql aplicado (columna is_informational).
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
  v_allocated   NUMERIC(10,2) := 0;  -- suma de montos de members/invited (informativo)
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

  -- ── A. Distribución de paquete → members (INFORMATIVO) ───────────────────
  -- Solo integrantes (NO owner). El owner se inserta en C con el total.
  IF v_package_id IS NOT NULL THEN
    FOR rec IN
      SELECT pmd.user_id, pmd.amount
      FROM public.package_member_distribution pmd
      WHERE pmd.package_id = v_package_id
        AND pmd.user_id   != v_owner_id
    LOOP
      INSERT INTO public.event_payouts
        (reservation_id, event_id, user_id, role, amount, is_informational)
      VALUES
        (NEW.id, v_event_id, rec.user_id, 'member', rec.amount, TRUE)
      ON CONFLICT (reservation_id, user_id) DO NOTHING;

      v_allocated := v_allocated + rec.amount;
    END LOOP;
  END IF;

  -- ── B. Talentos invitados para la tocada (INFORMATIVO) ───────────────────
  IF v_event_id IS NOT NULL THEN
    FOR rec IN
      SELECT
        ji.invited_user_id                       AS user_id,
        COALESCE(ji.proposed_payment_amount, 0)  AS amount
      FROM public.job_invitations ji
      WHERE ji.event_id          = v_event_id
        AND ji.status            = 'accepted'
        AND ji.invited_user_id  != v_owner_id
    LOOP
      INSERT INTO public.event_payouts
        (reservation_id, event_id, user_id, role, amount, is_informational)
      VALUES
        (NEW.id, v_event_id, rec.user_id, 'invited', rec.amount, TRUE)
      ON CONFLICT (reservation_id, user_id) DO NOTHING;

      v_allocated := v_allocated + rec.amount;
    END LOOP;
  END IF;

  -- ── C. Owner: recibe TODO el total (is_informational=FALSE = payout REAL) ─
  -- El owner ve en event_payouts su ganancia neta total.
  -- Lo que pague a su equipo es responsabilidad del owner fuera de la app.
  IF v_owner_id IS NOT NULL THEN
    INSERT INTO public.event_payouts
      (reservation_id, event_id, user_id, role, amount, is_informational)
    VALUES
      (NEW.id, v_event_id, v_owner_id, 'owner',
       GREATEST(0, v_total - v_allocated),
       FALSE)
    ON CONFLICT (reservation_id, user_id) DO NOTHING;
  END IF;

  RETURN NEW;
END;
$$;

-- Recrear trigger
DROP TRIGGER IF EXISTS trigger_generate_event_payouts ON public.reservations;
CREATE TRIGGER trigger_generate_event_payouts
  AFTER UPDATE ON public.reservations
  FOR EACH ROW EXECUTE FUNCTION public.generate_event_payouts();

-- ── Eliminar backfill_missing_member_payouts ──────────────────────────────────
-- Esta función acreditaba members en reservas históricas con auto-split.
-- Con el nuevo modelo, solo el owner recibe dinero real.
DROP FUNCTION IF EXISTS public.backfill_missing_member_payouts();

-- ── Backfill datos existentes: corregir is_informational ─────────────────────
UPDATE public.event_payouts
SET is_informational = TRUE
WHERE role IN ('member', 'invited')
  AND is_informational = FALSE;

UPDATE public.event_payouts
SET is_informational = FALSE
WHERE role = 'owner';

-- ── Verificación ─────────────────────────────────────────────────────────────
SELECT
  '301_fix_generate_event_payouts aplicado ✅' AS status,
  (SELECT COUNT(*) FROM public.event_payouts WHERE is_informational = FALSE AND role = 'owner')
    AS owner_payouts_reales,
  (SELECT COUNT(*) FROM public.event_payouts WHERE is_informational = TRUE)
    AS payouts_informativos;
