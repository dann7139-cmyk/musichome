-- ROLLBACK de sql/664 — regresa admin_grant_plus a como estaba antes
-- (sin tocar is_verified/admin_verified/verification_status).
-- NO revierte el backfill puntual de Miguel Aguilar y su Grupo Estilo —
-- des-verificar un grupo real a propósito sería un downgrade deliberado,
-- no un rollback de emergencia. Si de verdad hace falta, correr a mano:
--   UPDATE public.groups SET is_verified = FALSE, admin_verified = FALSE,
--     verification_status = 'pending'
--   WHERE id = 'abf37e26-7076-4ff3-a68b-71e21a441fd6';

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
  SELECT role INTO v_caller_role
    FROM public.profiles
   WHERE id = auth.uid();

  IF v_caller_role IS DISTINCT FROM 'admin' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Acceso denegado');
  END IF;

  SELECT owner_id, is_plus_active, plus_subscription_id, name
    INTO v_owner_id, v_current_active, v_current_sub_id, v_group_name
    FROM public.groups
   WHERE id = p_group_id;

  IF v_owner_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Grupo no encontrado');
  END IF;

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

  UPDATE public.groups
     SET is_plus_active       = TRUE,
         plus_expires_at      = v_expires,
         plus_subscription_id = v_sub_id
   WHERE id = p_group_id;

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
