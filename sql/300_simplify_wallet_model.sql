-- ════════════════════════════════════════════════════════════════════
-- 300_simplify_wallet_model.sql
--
-- NUEVO MODELO FINANCIERO:
--   ✅ Solo owner/grupo tiene wallet real y retiros
--   ✅ Talento/integrantes/invitados = distribución INFORMATIVA únicamente
--   ✅ group_wallets es la fuente de verdad del dinero real
--
-- CAMBIOS:
--   1. Bloquear INSERT de withdrawals para talento/integrantes
--   2. Bloquear INSERT de payout_requests para no-owners
--   3. Agregar columna is_informational a event_payouts
--   4. Ajustar trigger de auto-creación de wallet (solo group/admin)
--   5. Backfill: marcar event_payouts existentes de members/invited como informativos
--
-- NO elimina datos históricos. Solo bloquea escritura futura.
-- Requiere: 59, 184a, 184c aplicados.
-- ════════════════════════════════════════════════════════════════════

-- ── 1. WITHDRAWALS: solo owners de grupo pueden crear retiros ─────────────────

DROP POLICY IF EXISTS "wd_owner_all"               ON public.withdrawals;
DROP POLICY IF EXISTS "wd_admin_all"               ON public.withdrawals;
DROP POLICY IF EXISTS "wd_service_all"             ON public.withdrawals;
DROP POLICY IF EXISTS "wd_group_owner_only_insert" ON public.withdrawals;
DROP POLICY IF EXISTS "wd_group_owner_insert"      ON public.withdrawals;
DROP POLICY IF EXISTS "wd_owner_select"            ON public.withdrawals;
DROP POLICY IF EXISTS "wd_owner_update"            ON public.withdrawals;

-- Todos pueden ver sus propias solicitudes (historial)
CREATE POLICY "wd_owner_select"
  ON public.withdrawals FOR SELECT
  USING (auth.uid() = user_id);

-- Solo role='group' puede insertar solicitudes de retiro
CREATE POLICY "wd_group_owner_insert"
  ON public.withdrawals FOR INSERT
  WITH CHECK (
    auth.uid() = user_id
    AND EXISTS (
      SELECT 1 FROM public.profiles
      WHERE id = auth.uid() AND role = 'group'
    )
  );

-- Owner puede actualizar solo su propia solicitud (ej. cambiar CLABE)
CREATE POLICY "wd_owner_update"
  ON public.withdrawals FOR UPDATE
  USING (
    auth.uid() = user_id
    AND EXISTS (
      SELECT 1 FROM public.profiles
      WHERE id = auth.uid() AND role = 'group'
    )
  )
  WITH CHECK (auth.uid() = user_id);

-- Admin puede hacer todo
CREATE POLICY "wd_admin_all"
  ON public.withdrawals FOR ALL
  USING (EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin'));

-- Service role (Edge Functions) puede operar sin restricción
CREATE POLICY "wd_service_all"
  ON public.withdrawals FOR ALL
  USING (true) WITH CHECK (true);

-- ── 2. PAYOUT_REQUESTS: solo owners de grupo ──────────────────────────────────

DO $$ BEGIN
  -- Intentar DROP de políticas que pudieran existir con distintos nombres
  EXECUTE 'DROP POLICY IF EXISTS "pr_owner_all"         ON public.payout_requests';
  EXECUTE 'DROP POLICY IF EXISTS "pr_owner_insert"      ON public.payout_requests';
  EXECUTE 'DROP POLICY IF EXISTS "pr_owner_select"      ON public.payout_requests';
  EXECUTE 'DROP POLICY IF EXISTS "pr_group_owner_select" ON public.payout_requests';
  EXECUTE 'DROP POLICY IF EXISTS "pr_group_owner_insert" ON public.payout_requests';
  EXECUTE 'DROP POLICY IF EXISTS "pr_admin_all"         ON public.payout_requests';
  EXECUTE 'DROP POLICY IF EXISTS "pr_service_all"       ON public.payout_requests';
EXCEPTION WHEN OTHERS THEN NULL;
END; $$;

-- Solo owner del grupo puede ver sus solicitudes
CREATE POLICY "pr_group_owner_select"
  ON public.payout_requests FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.groups g
      WHERE g.id = payout_requests.group_id
        AND g.owner_id = auth.uid()
    )
    OR EXISTS (
      SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin'
    )
  );

-- Solo owner del grupo puede crear solicitudes de retiro
CREATE POLICY "pr_group_owner_insert"
  ON public.payout_requests FOR INSERT
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.groups g
      WHERE g.id = payout_requests.group_id
        AND g.owner_id = auth.uid()
    )
  );

CREATE POLICY "pr_admin_all"
  ON public.payout_requests FOR ALL
  USING (EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin'));

-- ── 3. TRIGGER de auto-creación de wallet: solo group y admin ─────────────────
-- Talento/integrantes ya no necesitan wallet individual al registrarse.

DROP TRIGGER IF EXISTS on_new_profile_create_wallet ON public.profiles;

CREATE OR REPLACE FUNCTION public.create_wallet_for_new_profile()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Solo crear wallet automática para owners de grupo y admin
  -- Talento/integrantes usan distribución informativa (event_payouts), no wallet real
  IF NEW.role IN ('group', 'admin') THEN
    INSERT INTO public.wallets (user_id)
    VALUES (NEW.id)
    ON CONFLICT (user_id) DO NOTHING;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER on_new_profile_create_wallet
  AFTER INSERT ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION public.create_wallet_for_new_profile();

-- ── 4. COLUMNA is_informational en event_payouts ──────────────────────────────
-- TRUE  = solo para display/stats (members, invited). No mueve dinero real.
-- FALSE = payout real (owner únicamente).

ALTER TABLE public.event_payouts
  ADD COLUMN IF NOT EXISTS is_informational BOOLEAN NOT NULL DEFAULT FALSE;

COMMENT ON COLUMN public.event_payouts.is_informational IS
  'TRUE = solo display/estadísticas. No implica transferencia real. Solo role=owner tiene FALSE.';

-- Backfill datos existentes
UPDATE public.event_payouts
SET is_informational = TRUE
WHERE role IN ('member', 'invited')
  AND is_informational = FALSE;

UPDATE public.event_payouts
SET is_informational = FALSE
WHERE role = 'owner'
  AND is_informational = TRUE;

-- ── 5. Verificación ───────────────────────────────────────────────────────────

SELECT
  '300_simplify_wallet_model aplicado ✅' AS status,
  (SELECT COUNT(*) FROM public.event_payouts WHERE role IN ('member','invited') AND is_informational = TRUE)
    AS event_payouts_informativos,
  (SELECT COUNT(*) FROM public.event_payouts WHERE role = 'owner' AND is_informational = FALSE)
    AS event_payouts_owner_reales;
