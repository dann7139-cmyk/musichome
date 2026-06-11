-- ══════════════════════════════════════════════════════════════════════════════
-- 34_event_payouts.sql
-- Tabla de distribución de pagos por evento.
-- Se llena automáticamente cuando una reserva pasa a 'confirmed'.
-- Ejecutar en Supabase SQL Editor.
-- ══════════════════════════════════════════════════════════════════════════════

-- ── 1. Tabla event_payouts ────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.event_payouts (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  reservation_id UUID NOT NULL REFERENCES public.reservations(id) ON DELETE CASCADE,
  event_id       UUID REFERENCES public.events(id) ON DELETE SET NULL,
  user_id        UUID NOT NULL REFERENCES public.profiles(id),
  role           TEXT NOT NULL CHECK (role IN ('owner', 'member', 'invited')),
  amount         NUMERIC(10,2) NOT NULL CHECK (amount >= 0),
  payout_status  TEXT NOT NULL DEFAULT 'pending'
                   CHECK (payout_status IN ('pending', 'paid', 'failed')),
  created_at     TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  UNIQUE(reservation_id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_ep_reservation ON public.event_payouts(reservation_id);
CREATE INDEX IF NOT EXISTS idx_ep_user        ON public.event_payouts(user_id);
CREATE INDEX IF NOT EXISTS idx_ep_event       ON public.event_payouts(event_id);

-- ── 2. Trigger: generar payouts al confirmar reserva ─────────────────────────
CREATE OR REPLACE FUNCTION public.generate_event_payouts()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_owner_id   UUID;
  v_group_id   UUID;
  v_package_id UUID;
  v_event_id   UUID;
  v_total      NUMERIC(10,2);
  v_allocated  NUMERIC(10,2) := 0;
  rec          RECORD;
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

  -- ── A. Distribución de paquete (integrantes permanentes) ─────────────────
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

  -- ── B. Talentos invitados para la tocada ─────────────────────────────────
  IF v_event_id IS NOT NULL THEN
    FOR rec IN
      SELECT
        ji.invited_user_id                          AS user_id,
        COALESCE(ji.proposed_payment_amount, 0)     AS amount
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

  -- ── C. Si el owner no fue incluido en package_member_distribution,
  --       añadirlo con el monto restante ────────────────────────────────────
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

DROP TRIGGER IF EXISTS trigger_generate_event_payouts ON public.reservations;
CREATE TRIGGER trigger_generate_event_payouts
  AFTER UPDATE ON public.reservations
  FOR EACH ROW EXECUTE FUNCTION public.generate_event_payouts();

-- ── 3. RLS ────────────────────────────────────────────────────────────────────
ALTER TABLE public.event_payouts ENABLE ROW LEVEL SECURITY;

-- Dueño del grupo: ve todos los payouts de sus eventos
DROP POLICY IF EXISTS "ep_owner_select" ON public.event_payouts;
CREATE POLICY "ep_owner_select"
  ON public.event_payouts FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.reservations r
      JOIN   public.groups g ON g.id = r.group_id
      WHERE  r.id = reservation_id AND g.owner_id = auth.uid()
    )
  );

-- Cada usuario solo ve su propio payout
DROP POLICY IF EXISTS "ep_user_select" ON public.event_payouts;
CREATE POLICY "ep_user_select"
  ON public.event_payouts FOR SELECT
  USING (user_id = auth.uid());

-- Solo admins pueden hacer UPDATE (marcar pagos como paid/failed en el futuro)
DROP POLICY IF EXISTS "ep_admin_all" ON public.event_payouts;
CREATE POLICY "ep_admin_all"
  ON public.event_payouts FOR ALL
  USING (
    EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin')
  );

-- ── 4. Verificación ───────────────────────────────────────────────────────────
SELECT 'event_payouts + trigger + RLS creados ✅' AS status;
