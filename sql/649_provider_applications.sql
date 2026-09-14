-- ============================================================================
-- sql/649_provider_applications.sql
-- Parte 2 del pedido de conserjería: antes de que cualquiera pueda tener
-- cuenta de grupo/proveedor, manda una solicitud simple (nombre, teléfono,
-- categoría, años de trayectoria, horas mínimas de contratación). Daniel
-- (o el admin_ops de su país) la revisa, lo contacta por WhatsApp para
-- pedirle foto + hasta 3 videos (no hay subida anónima en la app — ver
-- Investigación previa del plan), y si aprueba, crea la cuenta real con
-- UN clic — mismo patrón manual usado para "Conjunto Inquebrantable"
-- (INSERT directo en auth.users con crypt(), handle_new_user() crea el
-- profiles base, se completa, se crea el groups). El grupo nace en modo
-- conserjería (sql/648) — Daniel maneja sus primeras cotizaciones hasta
-- que el grupo gane confianza.
--
-- Sandbox-probado (8 casos: T1-T8) antes de aplicar — ver commit.
-- ============================================================================

CREATE TABLE public.provider_applications (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  full_name text NOT NULL,
  phone text NOT NULL,
  category text NOT NULL,                    -- key de PROVIDER_CATEGORIES (grupo/dj/comida/etc.)
  years_experience integer,
  min_hours numeric,
  country text,
  state text,
  city text,
  notes text,
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','contacted','approved','rejected')),
  admin_notes text,
  linked_group_id uuid REFERENCES public.groups(id),
  reviewed_by uuid REFERENCES public.profiles(id),
  reviewed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);
-- RLS habilitado SIN políticas — acceso solo vía los RPCs de abajo, mismo
-- patrón que quotes/admin_ops (admin_ops no tiene RLS directo en quotes).
ALTER TABLE public.provider_applications ENABLE ROW LEVEL SECURITY;
CREATE INDEX idx_provider_applications_status ON public.provider_applications(status, created_at);

-- 'provider_application' nuevo tipo de notificación (aviso al admin cuando
-- alguien manda la solicitud).
ALTER TABLE public.notifications DROP CONSTRAINT notifications_type_check;
ALTER TABLE public.notifications ADD CONSTRAINT notifications_type_check CHECK (type = ANY (ARRAY['reservation'::text, 'payment'::text, 'review'::text, 'verification'::text, 'system'::text, 'financial'::text, 'admin_alert'::text, 'admin'::text, 'general'::text, 'booking'::text, 'booking_received'::text, 'booking_accepted'::text, 'booking_confirmed'::text, 'booking_rejected'::text, 'booking_auto_cancelled'::text, 'booking_expired_no_payment'::text, 'booking_cancelled'::text, 'deposit_received'::text, 'payment_released'::text, 'payment_received'::text, 'payment_mismatch'::text, 'payout'::text, 'wallet'::text, 'event_reminder_24h'::text, 'event_upcoming_24h'::text, 'event_reminder_morning'::text, 'event_reminder_1h'::text, 'event_reminder_3h'::text, 'event_reminder_2h'::text, 'event_reminder_15m'::text, 'event_completed'::text, 'event_started'::text, 'overtime_requested'::text, 'event_auto_started'::text, 'event_no_show_alert'::text, 'event_finalized'::text, 'break_starting_soon'::text, 'break_ending_soon'::text, 'break_started'::text, 'break_ended'::text, 'dispute_opened'::text, 'dispute_received'::text, 'dispute'::text, 'job_invitation'::text, 'new_quote_request'::text, 'quote_received'::text, 'quote_accepted'::text, 'quote_cancelled'::text, 'quote_sent_to_client'::text, 'quote_expired'::text, 'chat'::text, 'ad_space_available'::text, 'high_demand'::text, 'no_ads_in_city'::text, 'first_ad_reminder'::text, 'ad_payment_confirmed'::text, 'ad_approved'::text, 'ad_rejected'::text, 'ad_expiring_soon'::text, 'ad_expired'::text, 'new_city_groups'::text, 'group_nearby'::text, 'bid_displaced'::text, 'bid_expiring_soon'::text, 'bid_expiry_reminder'::text, 'zone_demand'::text, 'express_dispatch'::text, 'fraud_alert'::text, 'referral_reward'::text, 'request_expired_proximity'::text, 'quote_expired_proximity'::text, 'extra_hour_proposed'::text, 'extra_hour_approved_by_client'::text, 'extra_hour_payment_confirmed'::text, 'extra_hour_rejected_by_client'::text, 'extra_hour_requested'::text, 'extra_hour_rejected'::text, 'extra_hour_payment_required'::text, 'extra_hour_expired'::text, 'extra_hour_payment_expired'::text, 'review_received'::text, 'extra_hours_offer'::text, 'sound_coordination_needed'::text, 'engagement_inactive_group'::text, 'engagement_groups_available'::text, 'engagement_weekend_reminder'::text, 'engagement_activate_now'::text, 'provider_application'::text]));

-- ----------------------------------------------------------------------------
-- submit_provider_application — ÚNICO RPC de todo el proyecto pensado para
-- llamarse SIN sesión (GRANT a anon). Solo inserta y notifica — nunca
-- expone lectura de nada existente. Valida categoría contra la lista real
-- de PROVIDER_CATEGORIES (providerCategories.ts) y limita 3 pendientes por
-- teléfono/24h como freno anti-spam mínimo.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.submit_provider_application(
  p_full_name text,
  p_phone text,
  p_category text,
  p_years_experience integer DEFAULT NULL,
  p_min_hours numeric DEFAULT NULL,
  p_country text DEFAULT NULL,
  p_state text DEFAULT NULL,
  p_city text DEFAULT NULL,
  p_notes text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_id uuid;
  v_cc text;
BEGIN
  IF p_full_name IS NULL OR trim(p_full_name) = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'missing_full_name');
  END IF;
  IF p_phone IS NULL OR trim(p_phone) = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'missing_phone');
  END IF;
  IF p_category IS NULL OR p_category NOT IN
     ('grupo','solista','dj','comediante','espectaculo','mc','luzSonido','comida','renta','fotografos') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_category');
  END IF;

  IF (SELECT count(*) FROM public.provider_applications
      WHERE phone = trim(p_phone) AND status = 'pending' AND created_at > now() - interval '1 day') >= 3 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'too_many_pending');
  END IF;

  INSERT INTO public.provider_applications
    (full_name, phone, category, years_experience, min_hours, country, state, city, notes)
  VALUES
    (LEFT(trim(p_full_name), 120), LEFT(trim(p_phone), 30), p_category,
     p_years_experience, p_min_hours,
     NULLIF(LEFT(trim(COALESCE(p_country,'')), 60), ''),
     NULLIF(LEFT(trim(COALESCE(p_state,'')), 60), ''),
     NULLIF(LEFT(trim(COALESCE(p_city,'')), 60), ''),
     NULLIF(LEFT(trim(COALESCE(p_notes,'')), 500), ''))
  RETURNING id INTO v_id;

  v_cc := public.country_code_of(p_country);
  INSERT INTO public.notifications (user_id, type, title, body, data)
  SELECT p.id, 'provider_application',
    '📝 Nueva solicitud de proveedor — ' || LEFT(trim(p_full_name), 120),
    format('%s pidió unirse (%s). Tel: %s.', LEFT(trim(p_full_name),120), p_category, LEFT(trim(p_phone),30)),
    jsonb_build_object('application_id', v_id, 'screen', 'AdminProviderApplications')
  FROM public.profiles p
  WHERE (p.role = 'admin' AND NOT public.admin_is_country_muted(p_country, p.id))
     OR (p.role = 'admin_ops' AND p.admin_country_scope = v_cc);

  RETURN jsonb_build_object('ok', true, 'application_id', v_id);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.submit_provider_application(text,text,text,integer,numeric,text,text,text,text) TO anon, authenticated;

-- ----------------------------------------------------------------------------
-- admin_get_provider_applications — cola de solicitudes, mismo filtro de
-- país que las demás colas admin. admin ve todas (el mute solo afecta
-- notificaciones, no las listas); admin_ops solo las de su país.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_get_provider_applications(p_status text DEFAULT 'pending')
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_role TEXT;
  v_result JSONB;
BEGIN
  SELECT role INTO v_caller_role FROM profiles WHERE id = auth.uid();
  IF v_caller_role NOT IN ('admin','admin_ops') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;

  SELECT jsonb_build_object(
    'ok', true,
    'items', COALESCE(jsonb_agg(x.item ORDER BY x.created_at ASC), '[]'::jsonb)
  )
  INTO v_result
  FROM (
    SELECT
      a.created_at,
      jsonb_build_object(
        'id', a.id, 'full_name', a.full_name, 'phone', a.phone, 'category', a.category,
        'years_experience', a.years_experience, 'min_hours', a.min_hours,
        'country', a.country, 'state', a.state, 'city', a.city, 'notes', a.notes,
        'status', a.status, 'admin_notes', a.admin_notes,
        'linked_group_id', a.linked_group_id, 'created_at', a.created_at
      ) AS item
    FROM public.provider_applications a
    WHERE (p_status IS NULL OR a.status = p_status)
      AND (v_caller_role = 'admin' OR country_code_of(a.country) = admin_ops_country())
    ORDER BY a.created_at ASC
  ) x;

  RETURN v_result;
END;
$function$;

-- ----------------------------------------------------------------------------
-- admin_reject_provider_application — cambio de estado simple.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_reject_provider_application(p_application_id uuid, p_reason text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_role TEXT;
  v_app RECORD;
BEGIN
  SELECT role INTO v_caller_role FROM public.profiles WHERE id = auth.uid();
  IF v_caller_role NOT IN ('admin','admin_ops') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;

  SELECT * INTO v_app FROM public.provider_applications WHERE id = p_application_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'application_not_found'); END IF;
  IF v_app.status IN ('approved','rejected') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'already_resolved', 'status', v_app.status);
  END IF;

  IF v_caller_role = 'admin_ops'
     AND public.country_code_of(v_app.country) <> public.admin_ops_country() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;

  UPDATE public.provider_applications SET
    status = 'rejected',
    admin_notes = p_reason,
    reviewed_by = auth.uid(),
    reviewed_at = NOW()
  WHERE id = p_application_id;

  RETURN jsonb_build_object('ok', true);
END;
$function$;

-- ----------------------------------------------------------------------------
-- admin_approve_provider_application — automatiza EXACTAMENTE el alta
-- manual usada hoy para "Conjunto Inquebrantable": INSERT directo en
-- auth.users (crypt(), pgcrypto vive en el schema `extensions` — de ahí el
-- search_path extra) → handle_new_user() crea el profiles base → se
-- completa → se crea groups con concierge_mode=true por default. p_genre
-- es requerido (el admin ya habló con el proveedor y vio sus fotos/videos
-- por WhatsApp, así que sabe el género exacto — 'category' en la solicitud
-- es solo la categoría amplia de PROVIDER_CATEGORIES, no un groups.genre
-- válido). Devuelve el correo/contraseña para pasárselos al proveedor.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_approve_provider_application(
  p_application_id uuid,
  p_email text,
  p_genre text,
  p_temp_password text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_caller_role TEXT;
  v_app         RECORD;
  v_user_id     UUID;
  v_group_id    UUID;
  v_password    TEXT;
  v_country_id  UUID;
  v_cc          TEXT;
  v_description TEXT;
BEGIN
  SELECT role INTO v_caller_role FROM public.profiles WHERE id = auth.uid();
  IF v_caller_role NOT IN ('admin', 'admin_ops') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;

  IF p_email IS NULL OR trim(p_email) = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'missing_email');
  END IF;
  IF p_genre IS NULL OR trim(p_genre) = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'missing_genre');
  END IF;

  SELECT * INTO v_app FROM public.provider_applications WHERE id = p_application_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'application_not_found'); END IF;
  IF v_app.status = 'approved' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'already_approved', 'linked_group_id', v_app.linked_group_id);
  END IF;
  IF v_app.status = 'rejected' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'already_rejected');
  END IF;

  IF v_caller_role = 'admin_ops'
     AND public.country_code_of(v_app.country) <> public.admin_ops_country() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;

  IF EXISTS (SELECT 1 FROM auth.users WHERE lower(email) = lower(trim(p_email))) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'email_already_used');
  END IF;

  v_password := COALESCE(NULLIF(trim(p_temp_password), ''), substr(md5(random()::text || clock_timestamp()::text), 1, 10));

  INSERT INTO auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at,
    raw_app_meta_data, raw_user_meta_data,
    confirmation_token, email_change, email_change_token_new, recovery_token
  ) VALUES (
    '00000000-0000-0000-0000-000000000000',
    gen_random_uuid(),
    'authenticated',
    'authenticated',
    trim(p_email),
    extensions.crypt(v_password, extensions.gen_salt('bf')),
    NOW(), NOW(), NOW(),
    '{"provider":"email","providers":["email"]}',
    jsonb_build_object('full_name', v_app.full_name, 'role', 'group'),
    '', '', '', ''
  ) RETURNING id INTO v_user_id;

  -- handle_new_user() ya creó el profiles base a partir de raw_user_meta_data;
  -- lo completamos con lo que la solicitud sí tenía (teléfono, fecha de
  -- aceptación de términos implícita al enviar la solicitud).
  UPDATE public.profiles SET
    full_name         = v_app.full_name,
    phone             = v_app.phone,
    role              = 'group',
    terms_accepted_at = NOW()
  WHERE id = v_user_id;

  -- country_id es best-effort (solo para el join de moneda en
  -- client_accept_quote) — si no hay fila de countries que empate (ej.
  -- Canadá, sin fila propia todavía), queda NULL y ese join cae en su
  -- COALESCE a MXN existente — mismo riesgo ya aceptado en otras partes
  -- de la app para Canadá, no introducido aquí.
  v_cc := public.country_code_of(v_app.country);
  SELECT c.id INTO v_country_id FROM public.countries c
  WHERE (v_cc = 'US' AND c.currency_code = 'USD')
     OR (v_cc = 'MX' AND c.currency_code = 'MXN')
  LIMIT 1;

  v_description := trim(
    COALESCE(v_app.years_experience::text || ' años de trayectoria.', '') ||
    CASE WHEN v_app.min_hours IS NOT NULL THEN ' Contratación mínima: ' || v_app.min_hours::text || ' horas.' ELSE '' END
  );

  INSERT INTO public.groups (
    id, owner_id, name, genre, description,
    country_id, country, state, city, concierge_mode
  ) VALUES (
    gen_random_uuid(), v_user_id, v_app.full_name, p_genre, NULLIF(v_description, ''),
    v_country_id, v_app.country, v_app.state, v_app.city, true
  ) RETURNING id INTO v_group_id;

  UPDATE public.provider_applications SET
    status = 'approved',
    linked_group_id = v_group_id,
    reviewed_by = auth.uid(),
    reviewed_at = NOW()
  WHERE id = p_application_id;

  RETURN jsonb_build_object('ok', true, 'user_id', v_user_id, 'group_id', v_group_id, 'email', trim(p_email), 'temp_password', v_password);
END;
$function$;
