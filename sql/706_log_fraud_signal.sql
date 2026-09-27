-- ═══════════════════════════════════════════════════════════════════════════
-- 706 — crea `log_fraud_signal` con la firma que la app YA usa
-- ═══════════════════════════════════════════════════════════════════════════
-- CORRECCIÓN PRE-RELEASE, mínima. Crea UNA función. No toca tablas, ni datos, ni
-- policies, ni RLS, ni nada financiero.
--
-- ── EL PROBLEMA ────────────────────────────────────────────────────────────
-- `src/screens/shared/ChatScreen.tsx:164` llama
--   supabase.rpc('log_fraud_signal', { p_user_id, p_signal_type, p_details })
-- con `void` (fire-and-forget, sin manejo de error) cuando alguien intenta 3 veces
-- pasar un teléfono por el chat. Esa función **no existe en producción**, así que
-- la señal antifraude nunca se registra y el fallo es silencioso.
--
-- ── POR QUÉ NO SE COPIA sql/185 ────────────────────────────────────────────
-- Dos razones, ambas verificadas:
--   1. **La firma vieja no sirve.** `sql/185` define
--        log_fraud_signal(p_user_id, p_signal_type, p_severity DEFAULT 'low',
--                         p_description DEFAULT NULL, p_metadata DEFAULT '{}')
--      y **no tiene `p_details`**. Aplicarla tal cual dejaría la llamada de la app
--      igual de rota: PostgREST rechazaría `p_details` como parámetro desconocido.
--   2. `sql/185` además crea `verification_sessions`, `rate_limit_actions`,
--      `check_rate_limit`, `get_user_risk_score`, `submit_verification_session`,
--      `admin_review_verification`, índices y policies. Nada de eso se quiere
--      introducir ahora.
-- Así que se escribe una función nueva, adaptada al esquema y a la llamada reales.
--
-- ── ESQUEMA REAL DE `fraud_signals` (verificado) ───────────────────────────
--   id uuid PK default gen_random_uuid()
--   user_id uuid  → FK profiles(id) ON DELETE CASCADE   (nullable)
--   signal_type text NOT NULL
--   severity    text NOT NULL   ← sin default: hay que darle valor
--   description text
--   metadata    jsonb NOT NULL default '{}'
--   created_at  timestamptz NOT NULL default now()
-- Sin CHECK en `signal_type` ni en `severity`. RLS **habilitada** con una sola
-- policy, `fraud_signals_admin_select` (solo SELECT y solo admin) → **no hay
-- policy de INSERT**, así que un `authenticated` no puede insertar por sí mismo.
-- De ahí que la función tenga que ser SECURITY DEFINER.
-- Hoy la escriben 5 funciones internas: `guard_event_request_spam`,
-- `guard_quote_spam`, `handle_chargeback_created`, `open_dispute` y
-- `report_group_content`. Esta se suma con el mismo estilo.
--
-- ── DECISIONES DE SEGURIDAD ────────────────────────────────────────────────
-- · **No se puede atribuir una señal a otra persona**: se exige
--   `p_user_id = auth.uid()`. Verificado que en ChatScreen `senderId` sale de
--   `supabase.auth.getUser()`, o sea es exactamente `auth.uid()`, así que la
--   restricción no rompe el flujo real.
-- · **`anon` no puede ejecutarla** (REVOKE explícito de PUBLIC y anon).
-- · **El tipo de señal va en lista blanca.** Sin ella, cualquier usuario podría
--   llenar la tabla antifraude con tipos inventados. Hoy la app solo manda
--   'chat_phone_bypass'; ampliar la lista debe ser un acto deliberado.
-- · **`description` la pone el servidor**, no el cliente, para que nadie inyecte
--   texto libre en un registro que después lee un admin.
-- · `severity` queda en **'low'**, que es el default que ya traía la definición
--   original de `sql/185` para señales sin severidad explícita. No se inventa un
--   criterio nuevo.
-- · `metadata` sí recibe `p_details` tal cual: es justamente el contexto del
--   evento (reservation_id, attempts) y no se usa para autorizar nada.
-- · La app ignora el valor de retorno, así que devuelve `jsonb` al estilo de las
--   RPC nuevas del proyecto.
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

CREATE OR REPLACE FUNCTION public.log_fraud_signal(
  p_user_id     UUID,
  p_signal_type TEXT,
  p_details     JSONB DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid UUID;
  v_id  UUID;
  -- Lista blanca. Ampliarla es un cambio deliberado, no un descuido.
  TIPOS_PERMITIDOS TEXT[] := ARRAY['chat_phone_bypass'];
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_authenticated');
  END IF;

  -- Nadie registra señales a nombre de otro.
  IF p_user_id IS DISTINCT FROM v_uid THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_self');
  END IF;

  IF p_signal_type IS NULL OR NOT (p_signal_type = ANY (TIPOS_PERMITIDOS)) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_signal_type');
  END IF;

  INSERT INTO public.fraud_signals (user_id, signal_type, severity, description, metadata)
  VALUES (
    v_uid,
    p_signal_type,
    'low',
    'Intentos de compartir contacto por el chat (detectado en la app)',
    COALESCE(p_details, '{}'::jsonb)
  )
  RETURNING id INTO v_id;

  RETURN jsonb_build_object('ok', true, 'signal_id', v_id);
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.log_fraud_signal(UUID, TEXT, JSONB) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.log_fraud_signal(UUID, TEXT, JSONB) TO authenticated, service_role;

COMMENT ON FUNCTION public.log_fraud_signal(UUID, TEXT, JSONB) IS
  'sql/706 — registra una señal antifraude propia. Firma pensada para la llamada que ya hace ChatScreen (p_user_id, p_signal_type, p_details). Exige p_user_id = auth.uid() (nadie registra a nombre de otro), tipo en lista blanca, description fijada por el servidor y severity low. No ejecutable por anon. NO es la version de sql/185: esa no tiene p_details y no sirve para esta llamada.';

NOTIFY pgrst, 'reload schema';

COMMIT;
