-- sql/664 — admin_grant_plus también verifica el grupo
--
-- Hallazgo real (2026-09-17): "activé un plus de regalo de Miguel Aguilar
-- pero verifica por qué no sale la insignia plus. cuando haga eso que no
-- falle." Miguel Aguilar y su Grupo Estilo quedó con is_plus_active=true
-- pero is_verified=false — y TODA la app (HomeScreen/GroupsScreen/etc.)
-- solo pinta el badge (VerifiedBadge, cheque azul o escudo verde de Plus)
-- cuando is_verified=true. Como is_verified es la condición, un grupo con
-- Plus pero sin verificar nunca muestra NADA — ni el cheque, ni el Plus.
--
-- Decisión: cuando Daniel otorga Plus de cortesía manualmente (no es
-- automático, es una decisión suya caso por caso), eso YA es una forma de
-- revisión/aval del grupo — así que admin_grant_plus ahora también marca
-- is_verified/admin_verified=true, igual que si lo hubiera verificado a
-- mano. admin_revoke_plus NO toca is_verified (revocar el regalo de Plus
-- no debe des-verificar un grupo que ya pasó revisión real).
--
-- Sandbox probado con BEGIN/ROLLBACK antes de aplicar en real.

CREATE OR REPLACE FUNCTION public.admin_grant_plus(p_group_id uuid, p_expires_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_role    TEXT;
  v_owner_id       UUID;
  v_current_sub_id TEXT;
  v_current_active BOOLEAN;
  v_sub_id         TEXT;
  v_expires        TIMESTAMPTZ;
  v_group_name     TEXT;
BEGIN
  -- Guard: solo admin puede llamar esta función
  SELECT role INTO v_caller_role
    FROM public.profiles
   WHERE id = auth.uid();

  IF v_caller_role IS DISTINCT FROM 'admin' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Acceso denegado');
  END IF;

  -- Verificar que el grupo existe y leer estado actual de Plus en una sola lectura
  SELECT owner_id, is_plus_active, plus_subscription_id, name
    INTO v_owner_id, v_current_active, v_current_sub_id, v_group_name
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

  -- Activar en groups. sql/664 — también marca verificado: un Plus de
  -- cortesía otorgado a mano ya es un aval del admin, y sin is_verified=
  -- true el badge (cheque/escudo) nunca se pinta en ningún lado de la app.
  UPDATE public.groups
     SET is_plus_active       = TRUE,
         plus_expires_at      = v_expires,
         plus_subscription_id = v_sub_id,
         is_verified           = TRUE,
         admin_verified         = TRUE,
         verification_status    = 'verified'
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

  -- 🔔 Avisar al dueño del grupo — antes no llegaba nada.
  INSERT INTO public.notifications (user_id, type, title, body, data)
  VALUES (
    v_owner_id, 'system',
    '🏆 ¡Te regalamos Plus!',
    'Daricefy te activó la insignia Plus en ' || COALESCE(v_group_name, 'tu grupo')
      || ' hasta el ' || to_char(v_expires, 'DD/MM/YYYY')
      || ' — ya puedes subir fotos de tus eventos, recibir regalos de tus fans y más.',
    jsonb_build_object('screen', 'Plus', 'group_id', p_group_id)
  );

  RETURN jsonb_build_object(
    'ok',         true,
    'sub_id',     v_sub_id,
    'expires_at', v_expires
  );
END;
$function$;

-- Backfill puntual: Miguel Aguilar y su Grupo Estilo ya recibió el grant
-- ANTES de este fix, así que se queda con is_verified=false para siempre
-- si no se corrige a mano una sola vez.
UPDATE public.groups
   SET is_verified = TRUE, admin_verified = TRUE, verification_status = 'verified'
 WHERE id = 'abf37e26-7076-4ff3-a68b-71e21a441fd6'
   AND is_plus_active = TRUE;
