-- ============================================================
-- sql/480_group_cancellation.sql
-- 🚨 CANCELACIÓN POR EL GRUPO ("No podré asistir") — con castigos.
--
-- Política (visible al grupo en la app antes de confirmar):
--   • El cliente recibe reembolso del 100% (tarjeta automático;
--     SPEI/efectivo entra a la cola manual del admin con comprobante).
--   • Strike automático (al 3º el grupo se SUSPENDE).
--   • Pierde la insignia de verificado (palomita azul).
--   • Menos visibilidad en el explorador por 30 días.
--
-- Piezas:
--   1. groups.visibility_penalty_until (nueva columna)
--   2. RPC settle_group_cancellation — espejo de settle_cancellation pero:
--      reembolso 100%, SIN compensación al grupo, strike + castigos.
--      La notificación a cliente e integrantes la dispara el trigger de
--      sql/478 (status → cancelled); aquí solo dueño y admin.
--   3. get_groups_ranked_by_city: grupos castigados se van AL FONDO
--      del explorador mientras dure el castigo (ni las pujas los suben).
-- ============================================================

BEGIN;

-- ────────────────────────────────────────────────────────────
-- 1) Columna de castigo de visibilidad
-- ────────────────────────────────────────────────────────────
ALTER TABLE public.groups
  ADD COLUMN IF NOT EXISTS visibility_penalty_until TIMESTAMPTZ;

COMMENT ON COLUMN public.groups.visibility_penalty_until IS
  'Mientras NOW() < este valor, el grupo aparece al fondo del explorador (castigo por cancelar un evento pagado).';

-- ────────────────────────────────────────────────────────────
-- 2) settle_group_cancellation
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.settle_group_cancellation(
  p_reservation_id UUID,
  p_refund_id      TEXT DEFAULT NULL,
  p_reason         TEXT DEFAULT 'group_cancelled'
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_res        RECORD;
  v_base       NUMERIC;
  v_wallet     RECORD;
  v_owner      UUID;
  v_gname      TEXT;
  v_strikes    INT;
  v_suspended  BOOLEAN := FALSE;
  v_admin_id   UUID;
BEGIN
  SELECT * INTO v_res FROM reservations WHERE id = p_reservation_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'not_found'); END IF;

  -- Idempotente
  IF v_res.status = 'cancelled' AND v_res.payout_status = 'refunded' THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'already_settled');
  END IF;

  IF v_res.payout_status NOT IN ('held', 'blocked') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_cancellable',
      'payout_status', v_res.payout_status);
  END IF;

  SELECT owner_id, name INTO v_owner, v_gname FROM groups WHERE id = v_res.group_id;

  -- Reversión COMPLETA del wallet del grupo (sin compensación — canceló él)
  v_base := COALESCE(v_res.group_earnings, v_res.base_price,
                     ROUND(v_res.total_price / 1.20, 2));

  PERFORM ensure_group_wallet(v_res.group_id);
  SELECT * INTO v_wallet FROM group_wallets WHERE group_id = v_res.group_id FOR UPDATE;

  UPDATE group_wallets SET
    pending_balance = GREATEST(0, pending_balance - v_base),
    total_earned    = GREATEST(0, total_earned - v_base),
    updated_at      = NOW()
  WHERE id = v_wallet.id;

  INSERT INTO wallet_transactions
    (group_wallet_id, group_id, type, amount, reservation_id, description, balance_after)
  VALUES (v_wallet.id, v_res.group_id, 'adjustment', -v_base, p_reservation_id,
    format('Reversión total — el grupo canceló la reserva %s', p_reservation_id),
    v_wallet.available_balance);

  -- Cancelar la reserva (el trigger de sql/478 notifica a cliente e integrantes)
  UPDATE reservations SET
    status            = 'cancelled',
    cancelled_by      = 'group',
    cancellation_type = 'group_initiated',
    cancel_reason     = p_reason,
    cancelled_at      = NOW(),
    payout_status     = 'refunded',
    updated_at        = NOW()
  WHERE id = p_reservation_id;

  -- ⚡ Strike + castigos
  INSERT INTO group_strikes (group_id, reservation_id, strike_type, issued_by, note)
  VALUES (v_res.group_id, p_reservation_id, 'late_cancel', COALESCE(v_owner, v_res.client_id),
          'Cancelación de evento pagado iniciada por el grupo (automático)');

  UPDATE groups SET
    strike_count             = COALESCE(strike_count, 0) + 1,
    last_strike_at           = NOW(),
    is_verified              = FALSE,
    visibility_penalty_until = NOW() + INTERVAL '30 days',
    updated_at               = NOW()
  WHERE id = v_res.group_id
  RETURNING strike_count INTO v_strikes;

  IF v_strikes >= 3 THEN
    UPDATE groups SET suspended_at = NOW(), is_active = FALSE WHERE id = v_res.group_id;
    UPDATE group_strikes SET auto_suspended = TRUE
    WHERE group_id = v_res.group_id AND reservation_id = p_reservation_id;
    v_suspended := TRUE;
  END IF;

  -- Auditoría
  INSERT INTO financial_audit_logs
    (entity_type, entity_id, action, actor_id, actor_role, amount, notes)
  VALUES ('reservation', p_reservation_id, 'group_cancellation_settle', v_owner, 'group',
    v_res.total_price,
    format('reembolso_total=%s strike=%s/3 suspendido=%s refund_id=%s',
      v_res.total_price, v_strikes, v_suspended, COALESCE(p_refund_id, 'n/a')));

  -- Al dueño: consecuencias claras
  IF v_owner IS NOT NULL THEN
    INSERT INTO notifications (user_id, type, title, body, data)
    VALUES (v_owner, 'reservation',
      CASE WHEN v_suspended THEN '🚫 Tu grupo fue SUSPENDIDO'
           ELSE format('⚡ Strike %s de 3 por cancelar', v_strikes) END,
      CASE WHEN v_suspended
        THEN 'Acumulaste 3 strikes y tu grupo quedó suspendido de la plataforma. Contacta a soporte.'
        ELSE format('Cancelaste un evento pagado. El cliente recibe su reembolso completo, perdiste tu insignia de verificado y tu grupo tendrá menos visibilidad por 30 días. Al strike 3 tu grupo se suspende. Strikes: %s/3.', v_strikes)
      END,
      jsonb_build_object('reservation_id', p_reservation_id, 'screen', 'GroupReservations'));
  END IF;

  -- Al admin
  SELECT id INTO v_admin_id FROM profiles WHERE role = 'admin' ORDER BY created_at LIMIT 1;
  IF v_admin_id IS NOT NULL THEN
    INSERT INTO notifications (user_id, type, title, body, data)
    VALUES (v_admin_id, 'admin',
      '🚨 Grupo canceló evento pagado',
      format('%s canceló la reserva %s. Reembolso 100%% al cliente ($%s). Strike %s/3%s.',
        COALESCE(v_gname, 'Grupo'), COALESCE(v_res.folio, p_reservation_id::text),
        to_char(v_res.total_price, 'FM999,999,990'), v_strikes,
        CASE WHEN v_suspended THEN ' — GRUPO SUSPENDIDO' ELSE '' END),
      jsonb_build_object('reservation_id', p_reservation_id, 'screen', 'AdminFinancial'));
  END IF;

  RETURN jsonb_build_object('ok', true,
    'refund_amount', v_res.total_price,
    'strikes', v_strikes,
    'suspended', v_suspended);
END;
$$;

GRANT EXECUTE ON FUNCTION public.settle_group_cancellation(UUID, TEXT, TEXT) TO authenticated, service_role;

-- ────────────────────────────────────────────────────────────
-- 3) Explorador: castigados AL FONDO (ni pujas ni boost los suben)
--    (misma firma y cuerpo que sql/263, solo cambia el ORDER BY)
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.get_groups_ranked_by_city(
  p_city  TEXT,
  p_state TEXT DEFAULT NULL,
  p_limit INT  DEFAULT 50
)
RETURNS TABLE (
  id                    UUID,
  name                  TEXT,
  genre                 TEXT,
  city                  TEXT,
  state                 TEXT,
  service_cities        JSONB,
  profile_image         TEXT,
  photo_status          TEXT,
  price_from            NUMERIC,
  rating                NUMERIC,
  total_reviews         INT,
  is_verified           BOOLEAN,
  verification_status   TEXT,
  is_active             BOOLEAN,
  puntos_reputacion     INT,
  bid_amount            NUMERIC,
  bid_ends_at           TIMESTAMPTZ,
  boost_score           INT,
  boost_ends_at         TIMESTAMPTZ,
  trust_score           NUMERIC,
  search_penalty        NUMERIC,
  is_high_demand        BOOLEAN,
  recent_completions    INT,
  bid_active            BOOLEAN,
  is_local              BOOLEAN
)
LANGUAGE plpgsql
SECURITY DEFINER STABLE
SET search_path = public
AS $$
DECLARE
  v_city_norm  TEXT := CASE WHEN p_city  IS NULL THEN NULL ELSE normalize_city_name(p_city)  END;
  v_state_norm TEXT := CASE WHEN p_state IS NULL THEN NULL ELSE normalize_state_name(p_state) END;
BEGIN
  RETURN QUERY
  SELECT
    g.id, g.name, g.genre, g.city,
    g.state,
    COALESCE(g.service_cities, '[]'::JSONB),
    g.profile_image, g.photo_status, g.price_from,
    g.rating, g.total_reviews, g.is_verified, g.verification_status,
    g.is_active,
    COALESCE(g.puntos_reputacion, 0)::INT,
    COALESCE(g.bid_amount, 0::NUMERIC),
    g.bid_ends_at,
    COALESCE(g.boost_score, 0)::INT,
    g.boost_ends_at,
    COALESCE(g.trust_score, 0::NUMERIC),
    COALESCE(g.search_penalty, 0::NUMERIC),
    COALESCE(g.is_high_demand, false),
    COALESCE(g.recent_completions, 0)::INT,
    (
      g.bid_ends_at IS NOT NULL
      AND g.bid_ends_at > now()
      AND COALESCE(g.bid_amount, 0) > 0
    ) AS bid_active,
    (v_city_norm IS NULL OR normalize_city_name(g.city) = v_city_norm) AS is_local
  FROM public.groups g
  WHERE g.is_active = true
    AND (
      v_city_norm IS NULL
      OR normalize_city_name(g.city) = v_city_norm
      OR EXISTS (
        SELECT 1
        FROM jsonb_array_elements_text(COALESCE(g.service_cities, '[]'::JSONB)) sc(city_name)
        WHERE normalize_city_name(sc.city_name) = v_city_norm
      )
    )
    AND (
      v_state_norm IS NULL
      OR g.state IS NULL
      OR normalize_state_name(g.state) = v_state_norm
    )
  ORDER BY
    -- 🚨 Castigo por cancelar: al fondo mientras dure (ni pujas los suben)
    (g.visibility_penalty_until IS NOT NULL AND g.visibility_penalty_until > now()) ASC,
    (v_city_norm IS NULL OR normalize_city_name(g.city) = v_city_norm) DESC,
    (g.bid_ends_at IS NOT NULL AND g.bid_ends_at > now()
      AND COALESCE(g.bid_amount, 0) > 0) DESC,
    COALESCE(g.bid_amount, 0) DESC,
    COALESCE(g.boost_score, 0) DESC,
    COALESCE(g.rating, 0) DESC,
    COALESCE(g.total_reviews, 0) DESC,
    g.created_at DESC
  LIMIT p_limit;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_groups_ranked_by_city(TEXT, TEXT, INT) TO anon, authenticated;

COMMIT;

-- ── VERIFICACIÓN ──────────────────────────────────────────────────────────────
SELECT column_name FROM information_schema.columns
WHERE table_name = 'groups' AND column_name = 'visibility_penalty_until';
-- Esperado: 1 fila

SELECT proname FROM pg_proc WHERE proname = 'settle_group_cancellation';
-- Esperado: 1 fila

SELECT prosrc LIKE '%visibility_penalty_until%' AS ranking_castiga
FROM pg_proc WHERE proname = 'get_groups_ranked_by_city';
-- Esperado: true

SELECT '480_group_cancellation.sql ejecutado ✅' AS status;
