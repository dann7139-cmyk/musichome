-- ════════════════════════════════════════════════════════════════════════════
-- 128_referral_system.sql
-- Sistema de referidos: grupos invitan clientes a la app.
--
-- FLUJO:
--   1. Grupo comparte su referral_code (ya existe en groups.referral_code).
--   2. Cliente nuevo lo ingresa al registrarse → llama register_referral().
--   3. Cuando ese cliente confirma su PRIMERA reserva (payment_status cambia
--      a deposit_paid / fully_paid) → trigger da bono al grupo en su wallet
--      y envía notificación.
--
-- LO QUE AGREGA ESTE ARCHIVO:
--   1. Tabla referral_events  (tracking de todos los referidos)
--   2. ADD COLUMN referred_by_group_id en profiles
--   3. register_referral()  — RPC llamado desde RegisterScreen
--   4. trg_referral_reward_on_payment — trigger en reservations
--   5. get_referral_stats()  — RPC para el dashboard del grupo
--
-- Ejecutar DESPUÉS de 127_contact_protection_extend.sql
-- ════════════════════════════════════════════════════════════════════════════


-- ── 1. Tabla referral_events ─────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.referral_events (
  id             UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  group_id       UUID        NOT NULL REFERENCES public.groups(id)       ON DELETE CASCADE,
  client_id      UUID        NOT NULL REFERENCES public.profiles(id)     ON DELETE CASCADE,
  reservation_id UUID        REFERENCES public.reservations(id)          ON DELETE SET NULL,
  referral_code  TEXT        NOT NULL,
  status         TEXT        NOT NULL DEFAULT 'registered'
                             CHECK (status IN ('registered', 'converted', 'rewarded')),
  reward_given   BOOLEAN     NOT NULL DEFAULT FALSE,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  converted_at   TIMESTAMPTZ,
  -- Un cliente solo puede tener un referido activo
  UNIQUE(client_id)
);

CREATE INDEX IF NOT EXISTS idx_referral_events_group  ON public.referral_events(group_id);
CREATE INDEX IF NOT EXISTS idx_referral_events_client ON public.referral_events(client_id);
CREATE INDEX IF NOT EXISTS idx_referral_events_code   ON public.referral_events(referral_code);

ALTER TABLE public.referral_events ENABLE ROW LEVEL SECURITY;

-- Grupos pueden ver sus propios referidos
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE tablename = 'referral_events' AND policyname = 'group_select_own_referrals'
  ) THEN
    CREATE POLICY "group_select_own_referrals"
      ON public.referral_events FOR SELECT
      USING (
        group_id IN (
          SELECT id FROM public.groups WHERE owner_id = auth.uid()
        )
      );
  END IF;
END $$;


-- ── 2. referred_by_group_id en profiles ──────────────────────────────────────

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS referred_by_group_id UUID
    REFERENCES public.groups(id) ON DELETE SET NULL;


-- ── 3. register_referral() ────────────────────────────────────────────────────
-- Llamado desde RegisterScreen inmediatamente después de que el cliente se crea.
-- Busca el grupo con ese código, guarda la relación y crea el evento de referido.

CREATE OR REPLACE FUNCTION public.register_referral(
  p_referral_code TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_client_id UUID := auth.uid();
  v_group     RECORD;
BEGIN
  IF v_client_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unauthenticated');
  END IF;

  -- Verificar que el cliente no haya sido referido antes
  IF EXISTS (SELECT 1 FROM public.referral_events WHERE client_id = v_client_id) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'already_referred');
  END IF;

  -- Buscar el grupo por código (case-insensitive)
  SELECT id, name INTO v_group
  FROM public.groups
  WHERE UPPER(TRIM(referral_code)) = UPPER(TRIM(p_referral_code))
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_code');
  END IF;

  -- No permitir auto-referido
  IF v_group.id IN (
    SELECT id FROM public.groups WHERE owner_id = v_client_id
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'self_referral');
  END IF;

  -- Guardar en profiles
  UPDATE public.profiles
  SET referred_by_group_id = v_group.id
  WHERE id = v_client_id AND referred_by_group_id IS NULL;

  -- Registrar evento de referido
  INSERT INTO public.referral_events (group_id, client_id, referral_code)
  VALUES (v_group.id, v_client_id, UPPER(TRIM(p_referral_code)))
  ON CONFLICT (client_id) DO NOTHING;

  RETURN jsonb_build_object(
    'ok',         true,
    'group_id',   v_group.id,
    'group_name', v_group.name
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.register_referral(TEXT) TO authenticated;


-- ── 4. Trigger: recompensar al grupo en la primera reserva del referido ───────
-- Se activa cuando payment_status de una reserva pasa a deposit_paid / fully_paid.
-- Solo premia la PRIMERA reserva del cliente referido (reward_given = false).

CREATE OR REPLACE FUNCTION public.trg_referral_reward_on_payment()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_ref        RECORD;
  v_owner_id   UUID;
  v_reward     NUMERIC := 100;   -- bono en pesos al grupo por referido convertido
BEGIN
  -- Solo reaccionar cuando cambia a estado de pago confirmado
  IF NEW.payment_status NOT IN ('deposit_paid', 'fully_paid') THEN
    RETURN NEW;
  END IF;
  IF OLD.payment_status IN ('deposit_paid', 'fully_paid') THEN
    RETURN NEW;  -- ya estaba pagado, no volver a premiar
  END IF;

  -- Buscar referido activo (sin recompensa) para este cliente
  SELECT re.id, re.group_id
  INTO   v_ref
  FROM   public.referral_events re
  WHERE  re.client_id    = NEW.client_id
    AND  re.reward_given = FALSE
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN NEW;
  END IF;

  -- Marcar como recompensado
  UPDATE public.referral_events
  SET    status         = 'rewarded',
         reward_given   = TRUE,
         reservation_id = NEW.id,
         converted_at   = NOW()
  WHERE  id = v_ref.id;

  -- Obtener owner del grupo
  SELECT owner_id INTO v_owner_id
  FROM   public.groups WHERE id = v_ref.group_id;

  -- Acreditar bono en wallet del dueño del grupo
  UPDATE public.wallets
  SET    available_balance = COALESCE(available_balance, 0) + v_reward
  WHERE  user_id = v_owner_id;

  -- Notificar al grupo
  INSERT INTO public.notifications (user_id, type, title, body, data)
  VALUES (
    v_owner_id,
    'referral_reward',
    '¡Referido convertido! 🎉',
    'Un cliente que invitaste realizó su primera reserva. Se acreditaron $'
      || v_reward::TEXT || ' a tu billetera.',
    jsonb_build_object(
      'screen',        'GroupDashboard',
      'referral_id',   v_ref.id,
      'reward_amount', v_reward
    )
  );

  RETURN NEW;

EXCEPTION WHEN OTHERS THEN
  RETURN NEW;  -- fallback silencioso — no bloquear el pago
END;
$$;

DROP TRIGGER IF EXISTS trg_referral_reward ON public.reservations;
CREATE TRIGGER trg_referral_reward
  AFTER UPDATE OF payment_status ON public.reservations
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_referral_reward_on_payment();


-- ── 5. get_referral_stats() ───────────────────────────────────────────────────
-- Estadísticas de referidos para el dashboard del grupo.

CREATE OR REPLACE FUNCTION public.get_referral_stats(p_group_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_total    INT;
  v_pending  INT;
  v_rewarded INT;
  v_earned   NUMERIC;
BEGIN
  -- Solo el dueño del grupo puede consultar sus stats
  IF NOT EXISTS (
    SELECT 1 FROM public.groups
    WHERE id = p_group_id AND owner_id = auth.uid()
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unauthorized');
  END IF;

  SELECT
    COUNT(*)                                   AS total,
    COUNT(*) FILTER (WHERE NOT reward_given)   AS pending,
    COUNT(*) FILTER (WHERE reward_given)       AS rewarded
  INTO v_total, v_pending, v_rewarded
  FROM public.referral_events
  WHERE group_id = p_group_id;

  -- $100 por cada referido recompensado (debe coincidir con el trigger)
  v_earned := v_rewarded * 100;

  RETURN jsonb_build_object(
    'ok',       true,
    'total',    v_total,
    'pending',  v_pending,
    'rewarded', v_rewarded,
    'earned',   v_earned
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_referral_stats(UUID) TO authenticated;


SELECT '128_referral_system.sql ejecutado ✅' AS status;
SELECT 'Tabla: referral_events' AS t1;
SELECT 'Columna: profiles.referred_by_group_id' AS t2;
SELECT 'RPC: register_referral, get_referral_stats' AS t3;
SELECT 'Trigger: trg_referral_reward en reservations' AS t4;
