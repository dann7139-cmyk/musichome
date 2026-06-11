-- ============================================================
-- sql/327_admin_grant_plus.sql
--
-- Permite a admins activar/revocar Plus manualmente en un grupo
-- sin pasar por Stripe: patrocinios, embajadores, alianzas, pruebas.
--
-- Nuevos RPCs:
--   admin_grant_plus(p_group_id, p_expires_at, p_notes)
--   admin_revoke_plus(p_group_id, p_notes)
--
-- Diseño de seguridad:
--   • SECURITY DEFINER — solo authenticated puede llamarlo, pero el
--     cuerpo verifica que auth.uid() tenga role='admin' en profiles.
--   • stripe_subscription_id sintético: 'admin_grant_<uuid>'
--   • stripe_customer_id sintético: 'admin_grant'
--   • is_plus_active=TRUE se activa directamente en groups.
--   • plus_expires_at = p_expires_at (default: 1 año desde hoy).
--   • No afecta Stripe ni webhooks existentes. Si el grupo luego
--     paga Stripe, el webhook sobreescribe subscription_id con el
--     real y el grant se desactiva limpiamente.
--
-- Consumidor previsto:
--   Panel admin (GroupsScreen o nueva AdminPlusScreen) →
--   supabase.rpc('admin_grant_plus', {...})
-- ============================================================

-- ── 1. Columna source en plus_subscriptions ───────────────────────────────────
-- Permite distinguir grants manuales de suscripciones Stripe.

ALTER TABLE public.plus_subscriptions
  ADD COLUMN IF NOT EXISTS source TEXT NOT NULL DEFAULT 'stripe'
  CHECK (source IN ('stripe', 'admin_grant'));

ALTER TABLE public.plus_subscriptions
  ADD COLUMN IF NOT EXISTS admin_notes TEXT;

-- Relajar NOT NULL en stripe_customer_id para grants sin Stripe
ALTER TABLE public.plus_subscriptions
  ALTER COLUMN stripe_customer_id SET DEFAULT 'admin_grant';


-- ── 2. RPC admin_grant_plus ───────────────────────────────────────────────────

DROP FUNCTION IF EXISTS public.admin_grant_plus(UUID, TIMESTAMPTZ, TEXT);

CREATE OR REPLACE FUNCTION public.admin_grant_plus(
  p_group_id   UUID,
  p_expires_at TIMESTAMPTZ DEFAULT NULL,  -- NULL = 1 año desde hoy
  p_notes      TEXT        DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_role    TEXT;
  v_owner_id       UUID;
  v_current_sub_id TEXT;
  v_current_active BOOLEAN;
  v_sub_id         TEXT;
  v_expires        TIMESTAMPTZ;
BEGIN
  -- Guard: solo admin puede llamar esta función
  SELECT role INTO v_caller_role
    FROM public.profiles
   WHERE id = auth.uid();

  IF v_caller_role IS DISTINCT FROM 'admin' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Acceso denegado');
  END IF;

  -- Verificar que el grupo existe y leer estado actual de Plus en una sola lectura
  SELECT owner_id, is_plus_active, plus_subscription_id
    INTO v_owner_id, v_current_active, v_current_sub_id
    FROM public.groups
   WHERE id = p_group_id;

  IF v_owner_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Grupo no encontrado');
  END IF;

  -- Guard R2: bloquear si hay suscripción Stripe activa.
  -- IDs de Stripe empiezan con 'sub_'; IDs de grants empiezan con 'admin_grant_'.
  -- Si plus_subscription_id no es nulo y no es un grant, es una suscripción Stripe real.
  IF v_current_active = TRUE
     AND v_current_sub_id IS NOT NULL
     AND v_current_sub_id NOT LIKE 'admin_grant_%'
  THEN
    RETURN jsonb_build_object(
      'ok',    false,
      'error', 'El grupo tiene una suscripción Stripe activa. Ejecuta admin_revoke_plus primero o espera a que la suscripción expire en Stripe.'
    );
  END IF;

  v_expires := COALESCE(p_expires_at, NOW() + INTERVAL '1 year');
  v_sub_id  := 'admin_grant_' || gen_random_uuid()::text;

  -- Activar en groups
  UPDATE public.groups
     SET is_plus_active       = TRUE,
         plus_expires_at      = v_expires,
         plus_subscription_id = v_sub_id
   WHERE id = p_group_id;

  -- Insertar registro en plus_subscriptions (idempotente: si ya tiene
  -- un grant activo se cancela el anterior y se crea el nuevo)
  UPDATE public.plus_subscriptions
     SET status = 'cancelled'
   WHERE group_id = p_group_id
     AND source   = 'admin_grant'
     AND status  != 'cancelled';

  INSERT INTO public.plus_subscriptions (
    group_id, owner_id, stripe_subscription_id,
    stripe_customer_id, status, current_period_end,
    source, admin_notes
  ) VALUES (
    p_group_id, v_owner_id, v_sub_id,
    'admin_grant', 'active', v_expires,
    'admin_grant', p_notes
  );

  RETURN jsonb_build_object(
    'ok',         true,
    'sub_id',     v_sub_id,
    'expires_at', v_expires
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_grant_plus(UUID, TIMESTAMPTZ, TEXT)
  TO authenticated;


-- ── 3. RPC admin_revoke_plus ──────────────────────────────────────────────────

DROP FUNCTION IF EXISTS public.admin_revoke_plus(UUID, TEXT);

CREATE OR REPLACE FUNCTION public.admin_revoke_plus(
  p_group_id UUID,
  p_notes    TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_role TEXT;
BEGIN
  SELECT role INTO v_caller_role
    FROM public.profiles
   WHERE id = auth.uid();

  IF v_caller_role IS DISTINCT FROM 'admin' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Acceso denegado');
  END IF;

  -- Desactivar grupo
  UPDATE public.groups
     SET is_plus_active       = FALSE,
         plus_expires_at      = NULL,
         plus_subscription_id = NULL
   WHERE id = p_group_id;

  -- Cancelar suscripción activa (cualquier fuente)
  UPDATE public.plus_subscriptions
     SET status      = 'cancelled',
         admin_notes = COALESCE(p_notes, admin_notes)
   WHERE group_id = p_group_id
     AND status  != 'cancelled';

  RETURN jsonb_build_object('ok', true);
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_revoke_plus(UUID, TEXT)
  TO authenticated;


-- ── 4. Política RLS para admin ────────────────────────────────────────────────
-- Permite a admins leer todas las suscripciones (para panel de gestión).

DROP POLICY IF EXISTS "plus_subs_admin_all" ON public.plus_subscriptions;
CREATE POLICY "plus_subs_admin_all"
  ON public.plus_subscriptions FOR ALL
  USING (
    (SELECT role FROM public.profiles WHERE id = auth.uid()) = 'admin'
  );


SELECT '327_admin_grant_plus.sql ejecutado ✅' AS status;
