-- ─────────────────────────────────────────────────────────────────────────────
-- 185_kyc_antifraud.sql
-- Capa de abstracción KYC + infraestructura anti-fraude.
--
--  1.  verification_sessions — abstracción sobre proveedor KYC
--  2.  Migrar verification_requests existentes a verification_sessions
--  3.  fraud_signals — eventos de riesgo por usuario
--  4.  rate_limit_actions — control de frecuencia por acción
--  5.  RPC check_rate_limit — verifica y registra límite de velocidad
--  6.  RPC log_fraud_signal — registra señal de riesgo
--  7.  RPC get_user_risk_score — calcula score de riesgo (0-100)
--  8.  risk_score en profiles
--  9.  Índices de performance
-- ─────────────────────────────────────────────────────────────────────────────

-- ── 1. verification_sessions ──────────────────────────────────────────────────
--
-- Abstracción sobre el proveedor KYC real (hoy: manual/DARICEFY, futuro: Onfido/Veriff).
-- Mantiene el historial de intentos y permite migrar de proveedor sin cambiar el schema.

CREATE TABLE IF NOT EXISTS verification_sessions (
  id                UUID        DEFAULT gen_random_uuid() PRIMARY KEY,
  group_id          UUID        REFERENCES groups(id) ON DELETE CASCADE NOT NULL,
  provider          TEXT        DEFAULT 'daricefy'
    CONSTRAINT chk_vs_provider CHECK (
      provider IN ('daricefy', 'onfido', 'veriff', 'stripe_identity')
    ),
  status            TEXT        DEFAULT 'pending'
    CONSTRAINT chk_vs_status CHECK (
      status IN ('pending', 'submitted', 'under_review', 'approved', 'rejected', 'expired')
    ),
  -- Datos enviados por el grupo
  document_front_path TEXT,
  document_back_path  TEXT,
  selfie_path         TEXT,
  document_type       TEXT DEFAULT 'ine'
    CONSTRAINT chk_vs_doc_type CHECK (
      document_type IN ('ine', 'passport', 'cdl', 'other')
    ),
  -- Datos del proveedor externo (null para daricefy)
  provider_session_id TEXT,
  provider_report_id  TEXT,
  provider_result     JSONB,
  -- Revisión manual (para flujo daricefy)
  reviewed_by       UUID        REFERENCES auth.users(id),
  review_note       TEXT,
  reviewed_at       TIMESTAMPTZ,
  -- Expiración del documento
  document_expires_at DATE,
  -- Trazabilidad
  submitted_at      TIMESTAMPTZ,
  approved_at       TIMESTAMPTZ,
  rejected_at       TIMESTAMPTZ,
  created_at        TIMESTAMPTZ DEFAULT NOW(),
  updated_at        TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_vs_group_id ON verification_sessions(group_id);
CREATE INDEX IF NOT EXISTS idx_vs_status   ON verification_sessions(status);

ALTER TABLE verification_sessions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS vs_owner_select ON verification_sessions;
CREATE POLICY vs_owner_select ON verification_sessions
  FOR SELECT
  USING (
    group_id IN (SELECT id FROM groups WHERE owner_id = auth.uid())
    OR EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
  );

DROP POLICY IF EXISTS vs_owner_insert ON verification_sessions;
CREATE POLICY vs_owner_insert ON verification_sessions
  FOR INSERT
  WITH CHECK (
    group_id IN (SELECT id FROM groups WHERE owner_id = auth.uid())
  );

DROP POLICY IF EXISTS vs_no_update ON verification_sessions;
CREATE POLICY vs_no_update ON verification_sessions
  FOR UPDATE
  USING (FALSE);

-- ── RPC: submit_verification_session ──────────────────────────────────────────
--
-- El grupo carga los documentos y llama esta RPC para registrar la sesión.
-- Invalida sesiones anteriores pendientes/rechazadas.

CREATE OR REPLACE FUNCTION submit_verification_session(
  p_group_id            UUID,
  p_document_front_path TEXT,
  p_document_back_path  TEXT DEFAULT NULL,
  p_selfie_path         TEXT DEFAULT NULL,
  p_document_type       TEXT DEFAULT 'ine'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_id UUID := auth.uid();
  v_session_id UUID;
BEGIN
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'unauthorized: sesión requerida';
  END IF;

  -- Verificar ownership del grupo
  IF NOT EXISTS (SELECT 1 FROM groups WHERE id = p_group_id AND owner_id = v_caller_id) THEN
    RAISE EXCEPTION 'unauthorized: no eres dueño de este grupo';
  END IF;

  -- No permitir nueva sesión si ya hay una aprobada
  IF EXISTS (
    SELECT 1 FROM verification_sessions
    WHERE group_id = p_group_id AND status = 'approved'
  ) THEN
    RAISE EXCEPTION 'Este grupo ya tiene verificación aprobada';
  END IF;

  -- Expirar sesiones previas pendientes/rechazadas
  UPDATE verification_sessions
  SET status = 'expired', updated_at = NOW()
  WHERE group_id = p_group_id AND status IN ('pending', 'submitted', 'rejected');

  INSERT INTO verification_sessions (
    group_id, provider, status,
    document_front_path, document_back_path, selfie_path,
    document_type, submitted_at
  ) VALUES (
    p_group_id, 'daricefy', 'submitted',
    p_document_front_path, p_document_back_path, p_selfie_path,
    p_document_type, NOW()
  ) RETURNING id INTO v_session_id;

  -- Actualizar el grupo para reflejar que está en revisión
  UPDATE groups
  SET
    verification_status = 'pending',
    verification_level  = CASE WHEN verification_level = 'none' THEN 'basic' ELSE verification_level END,
    updated_at          = NOW()
  WHERE id = p_group_id;

  -- Notificar al admin
  INSERT INTO notifications (user_id, type, title, body, data)
  SELECT id, 'verification', '📋 Nueva solicitud de verificación',
    'Un grupo envió documentos para revisión.',
    jsonb_build_object('screen', 'Verifications', 'group_id', p_group_id, 'session_id', v_session_id)
  FROM profiles WHERE role = 'admin';

  RETURN jsonb_build_object('ok', true, 'session_id', v_session_id);
END;
$$;

-- ── RPC: admin_review_verification ────────────────────────────────────────────

CREATE OR REPLACE FUNCTION admin_review_verification(
  p_session_id  UUID,
  p_decision    TEXT,  -- 'approved' | 'rejected'
  p_review_note TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_id UUID := auth.uid();
  v_session   RECORD;
BEGIN
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'unauthorized: sesión requerida';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = v_caller_id AND role = 'admin') THEN
    RAISE EXCEPTION 'unauthorized: solo admins pueden revisar verificaciones';
  END IF;

  IF p_decision NOT IN ('approved', 'rejected') THEN
    RAISE EXCEPTION 'Decisión inválida: %', p_decision;
  END IF;

  SELECT * INTO v_session FROM verification_sessions WHERE id = p_session_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Sesión no encontrada'; END IF;

  IF v_session.status NOT IN ('submitted', 'under_review') THEN
    RAISE EXCEPTION 'Esta sesión no está en revisión (status: %)', v_session.status;
  END IF;

  UPDATE verification_sessions
  SET
    status      = p_decision,
    reviewed_by = v_caller_id,
    review_note = p_review_note,
    reviewed_at = NOW(),
    approved_at = CASE WHEN p_decision = 'approved' THEN NOW() ELSE NULL END,
    rejected_at = CASE WHEN p_decision = 'rejected' THEN NOW() ELSE NULL END,
    updated_at  = NOW()
  WHERE id = p_session_id;

  -- Actualizar grupo
  UPDATE groups
  SET
    verification_status = p_decision,
    verification_level  = CASE
      WHEN p_decision = 'approved' THEN 'verified'
      WHEN p_decision = 'rejected' THEN 'basic'
      ELSE verification_level
    END,
    verified_at = CASE WHEN p_decision = 'approved' THEN NOW() ELSE NULL END,
    updated_at  = NOW()
  WHERE id = v_session.group_id;

  -- Notificar al grupo
  INSERT INTO notifications (user_id, type, title, body, data)
  SELECT g.owner_id, 'verification',
    CASE p_decision WHEN 'approved' THEN '✅ Verificación aprobada' ELSE '❌ Verificación rechazada' END,
    CASE p_decision
      WHEN 'approved' THEN 'Tu grupo fue verificado exitosamente. Ahora aparecerás con el sello de verificado.'
      ELSE COALESCE('Tu verificación fue rechazada. Motivo: ' || p_review_note, 'Tu verificación fue rechazada. Revisa los documentos y vuelve a intentarlo.')
    END,
    jsonb_build_object('screen', 'Verification', 'group_id', v_session.group_id)
  FROM groups g WHERE g.id = v_session.group_id;

  RETURN jsonb_build_object('ok', true, 'group_id', v_session.group_id, 'decision', p_decision);
END;
$$;

-- ── 2. Migrar verification_requests existentes ───────────────────────────────
--
-- Si existe la tabla verification_requests, sincronizar aprobadas → verification_sessions.

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name = 'verification_requests'
  ) THEN
    INSERT INTO verification_sessions (
      group_id, provider, status,
      document_front_path, submitted_at, approved_at, created_at
    )
    SELECT
      vr.group_id,
      'daricefy',
      CASE vr.status
        WHEN 'approved' THEN 'approved'
        WHEN 'rejected' THEN 'rejected'
        WHEN 'pending'  THEN 'submitted'
        ELSE 'submitted'
      END,
      vr.document_url,
      vr.created_at,
      CASE WHEN vr.status = 'approved' THEN vr.updated_at ELSE NULL END,
      vr.created_at
    FROM verification_requests vr
    WHERE NOT EXISTS (
      SELECT 1 FROM verification_sessions vs WHERE vs.group_id = vr.group_id
    )
    ON CONFLICT DO NOTHING;
  END IF;
END;
$$;

-- ── 3. fraud_signals ──────────────────────────────────────────────────────────
--
-- Señales de riesgo registradas automáticamente por las funciones del sistema.
-- No hay INSERT público; solo SECURITY DEFINER funciones.

CREATE TABLE IF NOT EXISTS fraud_signals (
  id          UUID        DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id     UUID        REFERENCES auth.users(id),
  signal_type TEXT        NOT NULL,
  severity    TEXT        DEFAULT 'low'
    CONSTRAINT chk_fs_severity CHECK (severity IN ('low','medium','high','critical')),
  description TEXT,
  metadata    JSONB       DEFAULT '{}',
  ip_address  TEXT,
  resolved    BOOLEAN     DEFAULT FALSE,
  resolved_at TIMESTAMPTZ,
  created_at  TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_fs_user_id    ON fraud_signals(user_id);
CREATE INDEX IF NOT EXISTS idx_fs_type       ON fraud_signals(signal_type);
CREATE INDEX IF NOT EXISTS idx_fs_severity   ON fraud_signals(severity);
CREATE INDEX IF NOT EXISTS idx_fs_created_at ON fraud_signals(created_at DESC);

ALTER TABLE fraud_signals ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS fs_admin_only ON fraud_signals;
CREATE POLICY fs_admin_only ON fraud_signals
  FOR SELECT
  USING (EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin'));

-- ── 4. rate_limit_actions ─────────────────────────────────────────────────────
--
-- Ventana deslizante por usuario + acción. Cada RPC sensible llama check_rate_limit.

CREATE TABLE IF NOT EXISTS rate_limit_actions (
  id          UUID        DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id     UUID        REFERENCES auth.users(id),
  action      TEXT        NOT NULL,
  created_at  TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_rla_user_action ON rate_limit_actions(user_id, action);
CREATE INDEX IF NOT EXISTS idx_rla_created_at  ON rate_limit_actions(created_at DESC);

-- Limpiar registros viejos (> 1 día) para no crecer infinitamente
-- Este DELETE puede correr como cron cada hora
CREATE OR REPLACE FUNCTION cleanup_rate_limit_actions()
RETURNS VOID
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  DELETE FROM rate_limit_actions WHERE created_at < NOW() - INTERVAL '1 day';
$$;

ALTER TABLE rate_limit_actions ENABLE ROW LEVEL SECURITY;

-- Sin políticas públicas: solo funciones SECURITY DEFINER acceden
DROP POLICY IF EXISTS rla_no_access ON rate_limit_actions;
CREATE POLICY rla_no_access ON rate_limit_actions FOR ALL USING (FALSE);

-- ── 5. RPC: check_rate_limit ──────────────────────────────────────────────────
--
-- Verifica que el usuario no haya superado max_count en window_minutes.
-- Si está OK, registra el intento. Si superó el límite, retorna FALSE.
--
-- Ejemplo: check_rate_limit('create_reservation', 5, 60) → máx 5 reservas/hora.

CREATE OR REPLACE FUNCTION check_rate_limit(
  p_action         TEXT,
  p_max_count      INT,
  p_window_minutes INT DEFAULT 60
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_id UUID := auth.uid();
  v_count     INT;
  v_window    TIMESTAMPTZ := NOW() - (p_window_minutes || ' minutes')::INTERVAL;
BEGIN
  IF v_caller_id IS NULL THEN RETURN FALSE; END IF;

  SELECT COUNT(*) INTO v_count
  FROM rate_limit_actions
  WHERE user_id = v_caller_id
    AND action   = p_action
    AND created_at > v_window;

  IF v_count >= p_max_count THEN
    -- Registrar señal de fraude si es un abuso claro (3x el límite)
    IF v_count >= p_max_count * 3 THEN
      PERFORM log_fraud_signal(
        v_caller_id,
        'rate_limit_exceeded',
        'high',
        format('Acción "%s" superó 3x el límite: %s intentos en %s min', p_action, v_count, p_window_minutes),
        '{}'::JSONB
      );
    END IF;
    RETURN FALSE;
  END IF;

  -- Registrar intento
  INSERT INTO rate_limit_actions (user_id, action) VALUES (v_caller_id, p_action);
  RETURN TRUE;
END;
$$;

-- ── 6. RPC: log_fraud_signal ──────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION log_fraud_signal(
  p_user_id     UUID,
  p_signal_type TEXT,
  p_severity    TEXT DEFAULT 'low',
  p_description TEXT DEFAULT NULL,
  p_metadata    JSONB DEFAULT '{}'
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_signal_id UUID;
BEGIN
  INSERT INTO fraud_signals (user_id, signal_type, severity, description, metadata)
  VALUES (p_user_id, p_signal_type, p_severity, p_description, p_metadata)
  RETURNING id INTO v_signal_id;

  -- Si es crítico, notificar al admin inmediatamente
  IF p_severity = 'critical' THEN
    INSERT INTO notifications (user_id, type, title, body, data)
    SELECT id, 'fraud_alert', '🚨 Alerta de fraude crítica',
      format('Señal "%s" detectada para usuario %s', p_signal_type, p_user_id),
      jsonb_build_object('screen', 'FraudAlerts', 'signal_id', v_signal_id, 'user_id', p_user_id)
    FROM profiles WHERE role = 'admin';
  END IF;

  RETURN v_signal_id;
END;
$$;

-- ── 7. RPC: get_user_risk_score ───────────────────────────────────────────────
--
-- Calcula un score de riesgo de 0 a 100 basado en señales activas recientes.
-- Solo accesible para admins o el propio usuario (score propio, sin detalles).

CREATE OR REPLACE FUNCTION get_user_risk_score(p_user_id UUID DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_id  UUID := auth.uid();
  v_target_id  UUID;
  v_score      INT := 0;
  v_signals    INT;
  v_high       INT;
  v_critical   INT;
  v_recent_30d INT;
BEGIN
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'unauthorized: sesión requerida';
  END IF;

  -- Admin puede ver score de cualquier usuario; otros solo el propio
  IF p_user_id IS NOT NULL AND p_user_id != v_caller_id THEN
    IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = v_caller_id AND role = 'admin') THEN
      RAISE EXCEPTION 'unauthorized: solo admins pueden ver scores de otros usuarios';
    END IF;
    v_target_id := p_user_id;
  ELSE
    v_target_id := v_caller_id;
  END IF;

  SELECT
    COUNT(*)                                           AS total,
    COUNT(*) FILTER (WHERE severity = 'high')          AS high_count,
    COUNT(*) FILTER (WHERE severity = 'critical')      AS critical_count,
    COUNT(*) FILTER (WHERE created_at > NOW() - INTERVAL '30 days') AS recent_30d
  INTO v_signals, v_high, v_critical, v_recent_30d
  FROM fraud_signals
  WHERE user_id = v_target_id AND resolved = FALSE;

  -- Scoring simple: señales recientes pesan más
  v_score := LEAST(100,
    (v_recent_30d * 10) +
    (v_high * 15) +
    (v_critical * 30)
  );

  -- Actualizar risk_score en profiles
  UPDATE profiles SET risk_score = v_score WHERE id = v_target_id;

  RETURN jsonb_build_object(
    'user_id',        v_target_id,
    'risk_score',     v_score,
    'risk_level',     CASE
      WHEN v_score >= 70 THEN 'high'
      WHEN v_score >= 40 THEN 'medium'
      ELSE 'low'
    END,
    'total_signals',  v_signals,
    'recent_30d',     v_recent_30d
  );
END;
$$;

-- ── 8. risk_score en profiles ─────────────────────────────────────────────────

ALTER TABLE profiles
  ADD COLUMN IF NOT EXISTS risk_score INT DEFAULT 0
    CONSTRAINT chk_risk_score CHECK (risk_score BETWEEN 0 AND 100);

CREATE INDEX IF NOT EXISTS idx_profiles_risk_score ON profiles(risk_score)
  WHERE risk_score > 30;

-- ── 9. Señales automáticas en RPCs clave ──────────────────────────────────────
--
-- Agregar check de rate limit a create_booking_with_event si existe.
-- Si no, dejar como hook manual para agregar después de cada RPC relevante.

-- Verificar múltiples cuentas desde el mismo email domain (señal básica)
CREATE OR REPLACE FUNCTION check_multicuenta_signal()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_email_domain TEXT;
  v_count        INT;
BEGIN
  -- Extraer dominio del email del nuevo usuario
  v_email_domain := split_part(NEW.email, '@', 2);

  -- Dominios de correo gratuitos conocidos — no son señal de multicuenta
  IF v_email_domain IN ('gmail.com','hotmail.com','outlook.com','yahoo.com','icloud.com','live.com') THEN
    RETURN NEW;
  END IF;

  -- Para dominios corporativos: si hay más de 3 cuentas del mismo dominio, señal
  SELECT COUNT(*) INTO v_count
  FROM auth.users
  WHERE email LIKE '%@' || v_email_domain
    AND created_at > NOW() - INTERVAL '7 days';

  IF v_count > 3 THEN
    PERFORM log_fraud_signal(
      NEW.id,
      'multicuenta_domain',
      'medium',
      format('Dominio "%s" tiene %s cuentas en 7 días', v_email_domain, v_count),
      jsonb_build_object('domain', v_email_domain, 'count', v_count)
    );
  END IF;

  RETURN NEW;
END;
$$;

-- ── 10. Índices adicionales ───────────────────────────────────────────────────

CREATE INDEX IF NOT EXISTS idx_vs_provider ON verification_sessions(provider);
CREATE INDEX IF NOT EXISTS idx_fs_resolved ON fraud_signals(resolved) WHERE resolved = FALSE;
CREATE INDEX IF NOT EXISTS idx_fs_user_severity ON fraud_signals(user_id, severity);
