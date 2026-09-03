-- ============================================================
-- sql/547_fix_wallet_transactions_promo_income.sql
--
-- BUG CONFIRMADO (auditoría 2026-08-10): confirm_bid_payment,
-- confirm_recommendation_payment, mark_ad_payment,
-- renew_recommendation_subscription y renew_sponsored_subscription
-- intentan INSERT INTO wallet_transactions usando columnas status y
-- reference_id, que ya NO existen en la tabla real (sql/229a_schema_wallet
-- la reescribió hacia el modelo group_wallet_id/reservation_id/
-- balance_after sin conservarlas; sql/164 las había agregado). El INSERT
-- truena en cada ejecución real, y como ninguna de las 5 funciones tiene
-- EXCEPTION WHEN OTHERS, TODA la transacción revierte — incluida la
-- activación de la compra (bid_orders.status, recommendation_orders.status,
-- advertisements.status) que ya se había actualizado antes del INSERT roto.
-- Reachability confirmada: las 5 se llaman desde stripe-webhook y/o
-- conekta-webhook (proveedores activos) sobre eventos reales de pago
-- aprobado — no es un camino legado. Evidencia: bid_orders 0/23 'paid',
-- recommendation_orders 0/11 'paid', wallet_transactions type IN
-- ('bid_income','recommendation_income','ad_income') = 0 filas, suma $0.
-- El código del propio stripe-webhook documenta (comentario junto al
-- caller de mark_ad_payment) que este síntoma —"pago quedaba cobrado sin
-- registrar"— ya se había notado antes.
--
-- CORRECCIÓN (alcance exacto autorizado, solo estas 5 funciones):
--   1. Reemplaza el loop "FOR v_admin IN SELECT id FROM profiles WHERE
--      role='admin'" por public.get_platform_admin_id() (ya existe,
--      SELECT id FROM profiles WHERE role='admin' ORDER BY created_at
--      LIMIT 1) — mismo patrón que sql/544/545. De paso resuelve que el
--      loop acreditaría el monto COMPLETO a cada admin si algún día hay
--      más de uno (hoy hay exactamente 1, por eso no se manifestó).
--   2. INSERT a wallet_transactions con las columnas reales:
--      (user_id, type, amount, description, mp_payment_id, currency_code)
--      — mp_payment_id (columna que sí existe) sustituye a reference_id
--      como referencia de trazabilidad del pago; ya no se usa para
--      deduplicar (ver punto 3). currency_code='MXN' explícito — los 3
--      flujos de origen (create-bid-payment, create-recommendation-payment,
--      create-ad-payment) cobran siempre en MXN, sin excepción, verificado
--      en el edge function de bidding (currency: 'mxn' fijo).
--   3. Idempotencia: se apoya en el estado real de la fila bajo lock, no
--      en wallet_transactions:
--        - confirm_bid_payment: ya tenía FOR UPDATE OF bo + status='paid'
--          — sin cambios en ese guard.
--        - confirm_recommendation_payment: NO tenía FOR UPDATE — se
--          agrega (mismo patrón que confirm_bid_payment). Reenvíos
--          concurrentes del webhook ya no pueden pasar ambos el guard.
--        - mark_ad_payment: ya tenía FOR UPDATE OF a + status<>'pending_payment'
--          — sin cambios en ese guard.
--        - renew_recommendation_subscription: ya se apoyaba en el índice
--          único parcial idx_rec_orders_stripe/idx_rec_orders_mp sobre
--          recommendation_orders.stripe_payment_id — respaldo a nivel de
--          base de datos contra la carrera, sin cambios en ese guard.
--        - renew_sponsored_subscription: su guard ERA la única línea que
--          literalmente truena hoy (consulta reference_id en su propio
--          IF EXISTS antes de tocar cualquier otra cosa). Se reemplaza
--          por advertisements.mp_payment_id = p_payment_id, verificado
--          bajo el FOR UPDATE que la función ya tomaba sobre advertisements.
--          mp_payment_id ahora se actualiza en AMBAS ramas (alta Y
--          renovación) — antes solo se guardaba en la rama de alta.
--   4. Guard defensivo amount > 0 antes de acreditar en
--      confirm_recommendation_payment, renew_recommendation_subscription
--      y renew_sponsored_subscription — recommendation_orders.amount y
--      los parámetros p_amount no tienen CHECK > 0 a nivel de tabla (a
--      diferencia de bid_orders y de mark_ad_payment, que ya traía su
--      propio guard v_price > 0). Sin este guard, un monto 0 rompería
--      wallet_transactions_amount_check (amount > 0) en vez de
--      simplemente omitir el crédito.
--
-- NO CAMBIA:
--   - Firmas de las 5 funciones (mismos parámetros, mismo orden, mismos
--      tipos y defaults) — los GRANT existentes se conservan automáticamente
--      con CREATE OR REPLACE, no se necesita GRANT explícito.
--   - Toda la lógica de negocio fuera del bloque de acreditación: cálculo
--      de fechas/duración, actualización de groups.bid_amount/bid_ends_at,
--      sponsored_groups, notificaciones — byte idéntico salvo donde el
--      guard de idempotencia nuevo lo requirió (renew_sponsored_subscription).
--   - No se agrega financial_audit_logs (fuera del alcance autorizado).
--   - No se toca ningún archivo de frontend ni edge function.
--   - Los $8,570 históricos de anuncios pagados vía MercadoPago en abril
--     2026 (mp_payment_id real, nunca acreditados porque la versión
--     original de mark_ad_payment —sql/119— no tenía lógica de wallet en
--     absoluto) quedan explícitamente fuera de esta ronda — es un
--     incidente separado, no causado por el bug que este archivo corrige.
-- ============================================================

BEGIN;

-- ── 1. confirm_bid_payment ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.confirm_bid_payment(p_order_id uuid, p_mp_payment_id text DEFAULT NULL::text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_order    RECORD;
  v_ends_at  TIMESTAMPTZ;
  v_admin_id UUID;
BEGIN
  -- FOR UPDATE: reenvíos concurrentes del webhook se serializan aquí
  SELECT bo.*, g.city AS group_city, g.name AS group_name, g.state AS group_state
  INTO   v_order
  FROM   public.bid_orders bo
  LEFT JOIN public.groups g ON g.id = bo.group_id
  WHERE  bo.id = p_order_id
  FOR UPDATE OF bo;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'order_not_found');
  END IF;

  IF v_order.status = 'paid' THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true);  -- idempotente
  END IF;

  v_ends_at := NOW() + (v_order.duration_days || ' days')::INTERVAL;

  UPDATE public.groups
  SET
    bid_amount  = CASE
                    WHEN bid_ends_at IS NOT NULL AND bid_ends_at > NOW()
                    THEN GREATEST(bid_amount, v_order.amount)
                    ELSE v_order.amount
                  END,
    bid_ends_at = CASE
                    WHEN bid_ends_at IS NOT NULL AND bid_ends_at > NOW()
                         AND bid_amount >= v_order.amount
                    THEN bid_ends_at
                    ELSE v_ends_at
                  END
  WHERE id = v_order.group_id;

  UPDATE public.bid_orders
  SET status        = 'paid',
      mp_payment_id = p_mp_payment_id,
      state         = COALESCE(state, v_order.group_state),
      starts_at     = NOW(),
      ends_at       = v_ends_at,
      updated_at    = NOW()
  WHERE id = p_order_id;

  -- Acreditación al admin de plataforma — un solo destinatario
  -- (get_platform_admin_id), mismo patrón validado en sql/544/545.
  v_admin_id := public.get_platform_admin_id();
  IF v_admin_id IS NOT NULL THEN
    INSERT INTO public.wallets (user_id) VALUES (v_admin_id) ON CONFLICT (user_id) DO NOTHING;

    UPDATE public.wallets
    SET available_balance = available_balance + v_order.amount,
        total_earned      = total_earned      + v_order.amount,
        updated_at        = NOW()
    WHERE user_id = v_admin_id;

    INSERT INTO public.wallet_transactions
      (user_id, type, amount, description, mp_payment_id, currency_code)
    VALUES
      (v_admin_id, 'bid_income', v_order.amount,
       'Posicionamiento: ' || COALESCE(v_order.group_name, v_order.group_id::TEXT)
         || CASE WHEN v_order.group_state IS NOT NULL
                THEN ' (' || v_order.group_state || ')'
                ELSE '' END,
       p_mp_payment_id, 'MXN');
  END IF;

  RETURN jsonb_build_object(
    'ok',       true,
    'group_id', v_order.group_id,
    'ends_at',  v_ends_at,
    'amount',   v_order.amount,
    'state',    v_order.group_state
  );
END;
$function$;

-- ── 2. confirm_recommendation_payment ───────────────────────────────────
CREATE OR REPLACE FUNCTION public.confirm_recommendation_payment(p_order_id uuid, p_mp_payment_id text DEFAULT NULL::text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_order    RECORD;
  v_ends     TIMESTAMPTZ;
  v_admin_id UUID;
  v_ref_id   TEXT;
BEGIN
  -- FOR UPDATE: antes esta función no bloqueaba la fila (a diferencia de
  -- confirm_bid_payment / mark_ad_payment) — reenvíos concurrentes del
  -- webhook podían pasar ambos el guard de idempotencia antes de que
  -- cualquiera de los dos confirmara. Se agrega el mismo lock.
  SELECT ro.*, g.name AS group_name, g.city AS group_city
  INTO   v_order
  FROM   public.recommendation_orders ro
  LEFT JOIN public.groups g ON g.id = ro.group_id
  WHERE  ro.id = p_order_id
  FOR UPDATE OF ro;

  IF NOT FOUND THEN
    RAISE NOTICE '[PAYMENT_REC] order_not_found order=%', p_order_id;
    RETURN jsonb_build_object('ok', false, 'error', 'order_not_found');
  END IF;

  -- Idempotencia
  IF v_order.status = 'paid' THEN
    RAISE NOTICE '[PAYMENT_REC] skip already_paid order=% amount=%', p_order_id, v_order.amount;
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'already_paid');
  END IF;

  v_ends   := NOW() + (v_order.duration_days || ' days')::INTERVAL;
  v_ref_id := COALESCE(NULLIF(p_mp_payment_id, ''), 'rec_' || p_order_id::TEXT);

  RAISE NOTICE '[PAYMENT_REC] confirm order=% amount=% city=% reference=%',
    p_order_id, v_order.amount, v_order.group_city, v_ref_id;

  -- Activar la orden
  UPDATE public.recommendation_orders
  SET status            = 'paid',
      stripe_payment_id = p_mp_payment_id,
      starts_at         = NOW(),
      ends_at           = v_ends,
      updated_at        = NOW()
  WHERE id = p_order_id;

  -- Acreditación al admin de plataforma (mismo patrón que confirm_bid_payment).
  -- Guard amount > 0: recommendation_orders.amount no tiene CHECK a nivel
  -- de tabla (a diferencia de bid_orders); sin este guard, un monto 0
  -- rompería wallet_transactions_amount_check en vez de omitir el crédito.
  IF COALESCE(v_order.amount, 0) > 0 THEN
    v_admin_id := public.get_platform_admin_id();
    IF v_admin_id IS NOT NULL THEN
      INSERT INTO public.wallets (user_id) VALUES (v_admin_id) ON CONFLICT (user_id) DO NOTHING;

      UPDATE public.wallets
      SET available_balance = available_balance + v_order.amount,
          total_earned      = total_earned      + v_order.amount,
          updated_at        = NOW()
      WHERE user_id = v_admin_id;

      INSERT INTO public.wallet_transactions
        (user_id, type, amount, description, mp_payment_id, currency_code)
      VALUES
        (v_admin_id, 'recommendation_income', v_order.amount,
         'Recomendación: ' || COALESCE(v_order.group_name, v_order.group_id::TEXT)
           || ' · ' || v_order.duration_days || 'd'
           || CASE WHEN v_order.group_city IS NOT NULL
                  THEN ' (' || v_order.group_city || ')'
                  ELSE '' END,
         p_mp_payment_id, 'MXN');
    END IF;
  END IF;

  RAISE NOTICE '[PAYMENT_REC] done order=% amount=% ends_at=%',
    p_order_id, v_order.amount, v_ends;

  RETURN jsonb_build_object(
    'ok',        true,
    'order_id',  p_order_id,
    'ends_at',   v_ends,
    'amount',    v_order.amount,
    'reference', v_ref_id
  );
END;
$function$;

-- ── 3. mark_ad_payment ───────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.mark_ad_payment(p_ad_id uuid, p_mp_payment_id text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_ad       RECORD;
  v_price    NUMERIC(10,2);
  v_admin_id UUID;
BEGIN
  -- FOR UPDATE: serializa reenvíos concurrentes del webhook
  SELECT a.*, COALESCE(ap.price, 0) AS pkg_price
  INTO   v_ad
  FROM   public.advertisements a
  LEFT JOIN public.ad_packages ap ON ap.id = a.package_id
  WHERE  a.id = p_ad_id
  FOR UPDATE OF a;

  IF NOT FOUND THEN
    RAISE NOTICE '[PAYMENT_AD] ad_not_found ad=%', p_ad_id;
    RETURN jsonb_build_object('ok', false, 'error', 'ad_not_found');
  END IF;

  IF v_ad.is_free = TRUE THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'free_ad');
  END IF;

  -- Idempotencia POR STATUS (sin cambios respecto a sql/496)
  IF v_ad.status <> 'pending_payment' THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'already_processed');
  END IF;

  -- 💰 Acreditar lo que REALMENTE se cobró (effective_price), no el
  -- precio base del paquete
  v_price := COALESCE(NULLIF(v_ad.effective_price, 0), NULLIF(v_ad.total_price, 0), v_ad.pkg_price);

  UPDATE public.advertisements
  SET    mp_payment_id = p_mp_payment_id,
         status        = 'pending_review',
         updated_at    = now()
  WHERE  id = p_ad_id;

  IF v_price > 0 AND p_mp_payment_id IS NOT NULL AND p_mp_payment_id != '' THEN
    v_admin_id := public.get_platform_admin_id();
    IF v_admin_id IS NOT NULL THEN
      INSERT INTO public.wallets (user_id) VALUES (v_admin_id) ON CONFLICT (user_id) DO NOTHING;

      UPDATE public.wallets
      SET available_balance = available_balance + v_price,
          total_earned      = total_earned      + v_price,
          updated_at        = now()
      WHERE user_id = v_admin_id;

      INSERT INTO public.wallet_transactions
        (user_id, type, amount, description, mp_payment_id, currency_code)
      VALUES
        (v_admin_id, 'ad_income', v_price,
         'Publicidad pagada: ' || v_ad.title || ' (' || v_ad.type || ')',
         p_mp_payment_id, 'MXN');
    END IF;
  END IF;

  RETURN jsonb_build_object('ok', true, 'price', v_price, 'ad_id', p_ad_id);
END;
$function$;

-- ── 4. renew_recommendation_subscription ────────────────────────────────
CREATE OR REPLACE FUNCTION public.renew_recommendation_subscription(p_group_id uuid, p_payment_id text, p_amount numeric, p_days integer DEFAULT 7)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_group    RECORD;
  v_start    TIMESTAMPTZ;
  v_order_id UUID;
  v_admin_id UUID;
  v_days     INT := GREATEST(COALESCE(p_days, 7), 1);
BEGIN
  -- Idempotencia: este cobro ya generó su orden. recommendation_orders.
  -- stripe_payment_id tiene índice único parcial (idx_rec_orders_stripe /
  -- idx_rec_orders_mp) — respaldo a nivel de base de datos contra la
  -- carrera además de este chequeo. Sin cambios respecto al original.
  IF EXISTS (
    SELECT 1 FROM recommendation_orders WHERE stripe_payment_id = p_payment_id
  ) THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'already_processed');
  END IF;

  SELECT id, name, city, state, owner_id INTO v_group
  FROM groups WHERE id = p_group_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'group_not_found');
  END IF;

  -- El nuevo periodo arranca donde termina el actual (si sigue vivo)
  SELECT GREATEST(NOW(), COALESCE(MAX(ends_at), NOW()))
  INTO   v_start
  FROM   recommendation_orders
  WHERE  group_id = p_group_id AND status = 'paid' AND ends_at > NOW();

  INSERT INTO recommendation_orders
    (group_id, amount, price_per_day, duration_days, status,
     stripe_payment_id, starts_at, ends_at, city, state)
  VALUES
    (p_group_id, p_amount, ROUND(p_amount / v_days, 2), v_days, 'paid',
     p_payment_id, v_start, v_start + (v_days || ' days')::INTERVAL,
     v_group.city, v_group.state)
  RETURNING id INTO v_order_id;

  -- Acreditación al admin de plataforma (mismo patrón que confirm_bid_payment).
  -- Guard amount > 0: p_amount no tiene CHECK a nivel de función/tabla.
  IF COALESCE(p_amount, 0) > 0 THEN
    v_admin_id := public.get_platform_admin_id();
    IF v_admin_id IS NOT NULL THEN
      INSERT INTO wallets (user_id) VALUES (v_admin_id) ON CONFLICT (user_id) DO NOTHING;

      UPDATE wallets
      SET available_balance = available_balance + p_amount,
          total_earned      = total_earned      + p_amount,
          updated_at        = NOW()
      WHERE user_id = v_admin_id;

      INSERT INTO wallet_transactions
        (user_id, type, amount, description, mp_payment_id, currency_code)
      VALUES
        (v_admin_id, 'recommendation_income', p_amount,
         'Recomendado (suscripción ' || CASE WHEN v_days >= 30 THEN 'mensual' ELSE 'semanal' END
           || '): ' || COALESCE(v_group.name, p_group_id::TEXT),
         p_payment_id, 'MXN');
    END IF;
  END IF;

  -- Avisar al dueño
  IF v_group.owner_id IS NOT NULL THEN
    INSERT INTO notifications (user_id, type, title, body, data)
    VALUES (v_group.owner_id, 'reservation',
      '⭐ Recomendación renovada',
      'Tu grupo sigue en "Recomendado para ti" ' || v_days || ' días más. Se renueva solo — puedes cancelar cuando quieras.',
      jsonb_build_object('screen', 'GroupReservations'));
  END IF;

  RETURN jsonb_build_object('ok', true, 'order_id', v_order_id,
    'starts_at', v_start, 'days', v_days);
END;
$function$;

-- ── 5. renew_sponsored_subscription ─────────────────────────────────────
CREATE OR REPLACE FUNCTION public.renew_sponsored_subscription(p_ad_id uuid, p_payment_id text, p_amount numeric)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_ad       RECORD;
  v_admin_id UUID;
  v_base     TIMESTAMPTZ;
  v_first    BOOLEAN;
BEGIN
  SELECT * INTO v_ad FROM advertisements WHERE id = p_ad_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'ad_not_found');
  END IF;
  IF v_ad.type <> 'sponsored_group' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_sponsored');
  END IF;

  -- Idempotencia: antes consultaba wallet_transactions.reference_id
  -- (columna que ya no existe — esta era la línea que truena hoy en el
  -- primer statement de la función). Se reemplaza por el estado real de
  -- la fila, ya bajo el FOR UPDATE de arriba: mp_payment_id se actualiza
  -- en cada cobro exitoso (alta o renovación); un reenvío del mismo
  -- evento cae aquí antes de tocar cualquier otra cosa.
  IF v_ad.mp_payment_id = p_payment_id THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'already_processed');
  END IF;

  v_first := (v_ad.status = 'pending_payment');

  IF v_first THEN
    -- Primer cobro de la suscripción: pasa a revisión del admin
    -- (approve_ad lo activará respetando los 30 días pagados)
    UPDATE advertisements
    SET status = 'pending_review', mp_payment_id = p_payment_id, updated_at = NOW()
    WHERE id = p_ad_id;
  ELSE
    -- Renovación: extender 30 días desde donde termine el periodo actual.
    -- mp_payment_id ahora también se actualiza aquí (antes solo en la
    -- rama de alta) — necesario para que el guard de idempotencia de
    -- arriba funcione en renovaciones, no solo en el primer cobro.
    v_base := GREATEST(COALESCE(v_ad.ends_at, NOW()), NOW());
    UPDATE advertisements
    SET status        = 'active',
        starts_at     = COALESCE(starts_at, NOW()),
        ends_at       = v_base + INTERVAL '30 days',
        mp_payment_id = p_payment_id,
        updated_at    = NOW()
    WHERE id = p_ad_id;

    UPDATE sponsored_groups
    SET is_active = true,
        ends_at   = v_base + INTERVAL '30 days'
    WHERE advertiser_id = v_ad.advertiser_id
      AND id = (
        SELECT id FROM sponsored_groups
        WHERE advertiser_id = v_ad.advertiser_id
        ORDER BY created_at DESC LIMIT 1
      );
  END IF;

  -- Acreditación al admin de plataforma (mismo patrón que confirm_bid_payment).
  -- Guard amount > 0: p_amount no tiene CHECK a nivel de función/tabla.
  IF COALESCE(p_amount, 0) > 0 THEN
    v_admin_id := public.get_platform_admin_id();
    IF v_admin_id IS NOT NULL THEN
      INSERT INTO wallets (user_id) VALUES (v_admin_id) ON CONFLICT (user_id) DO NOTHING;

      UPDATE wallets
      SET available_balance = available_balance + p_amount,
          total_earned      = total_earned      + p_amount,
          updated_at        = NOW()
      WHERE user_id = v_admin_id;

      INSERT INTO wallet_transactions
        (user_id, type, amount, description, mp_payment_id, currency_code)
      VALUES
        (v_admin_id, 'ad_income', p_amount,
         'Destacado (suscripción mensual): ' || COALESCE(v_ad.title, p_ad_id::TEXT),
         p_payment_id, 'MXN');
    END IF;
  END IF;

  -- Avisar al dueño
  IF v_ad.advertiser_id IS NOT NULL THEN
    INSERT INTO notifications (user_id, type, title, body, data)
    VALUES (v_ad.advertiser_id, 'reservation',
      CASE WHEN v_first THEN '🌟 Pago recibido — Destacado en revisión'
           ELSE '🌟 Destacado renovado' END,
      CASE WHEN v_first THEN 'Tu pago se acreditó. Tu anuncio de Destacado pasa a revisión y se activa al aprobarse.'
           ELSE 'Tu grupo sigue Destacado 30 días más. Se renueva solo cada mes — puedes cancelar cuando quieras.' END,
      jsonb_build_object('screen', 'GroupReservations'));
  END IF;

  RETURN jsonb_build_object('ok', true, 'first', v_first);
END;
$function$;

COMMIT;

-- ════════════════════════════════════════════════════════════════════
-- VERIFICACIONES (ejecutar separado después del COMMIT)
-- ════════════════════════════════════════════════════════════════════

-- V1: las 5 funciones existen con la misma firma de siempre
SELECT p.proname, pg_get_function_identity_arguments(p.oid) AS args
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname IN (
  'confirm_bid_payment', 'confirm_recommendation_payment', 'mark_ad_payment',
  'renew_recommendation_subscription', 'renew_sponsored_subscription'
)
ORDER BY p.proname;
-- Esperado: 5 filas, firmas sin cambios respecto al archivo original

-- V2: ninguna referencia a reference_id (columna que ya no existe)
SELECT routine_name, routine_definition NOT LIKE '%reference_id%' AS sin_reference_id
FROM information_schema.routines
WHERE routine_schema = 'public' AND routine_name IN (
  'confirm_bid_payment', 'confirm_recommendation_payment', 'mark_ad_payment',
  'renew_recommendation_subscription', 'renew_sponsored_subscription'
)
ORDER BY routine_name;
-- Esperado: true en las 5

-- V3: todas usan get_platform_admin_id, ninguna itera sobre todos los admins
SELECT routine_name,
  routine_definition LIKE '%get_platform_admin_id%' AS usa_admin_unico,
  routine_definition NOT LIKE '%FOR v_admin IN%'      AS sin_loop_admins
FROM information_schema.routines
WHERE routine_schema = 'public' AND routine_name IN (
  'confirm_bid_payment', 'confirm_recommendation_payment', 'mark_ad_payment',
  'renew_recommendation_subscription', 'renew_sponsored_subscription'
)
ORDER BY routine_name;
-- Esperado: true | true en las 5

-- V4: confirm_recommendation_payment ahora bloquea la fila (antes no lo hacía)
SELECT routine_definition LIKE '%FOR UPDATE OF ro%' AS tiene_lock_nuevo
FROM information_schema.routines
WHERE routine_schema = 'public' AND routine_name = 'confirm_recommendation_payment';
-- Esperado: true

-- V5: renew_sponsored_subscription ya no depende de wallet_transactions
-- para su propio guard de idempotencia
SELECT routine_definition LIKE '%v_ad.mp_payment_id = p_payment_id%' AS guard_por_fila
FROM information_schema.routines
WHERE routine_schema = 'public' AND routine_name = 'renew_sponsored_subscription';
-- Esperado: true

SELECT '547_fix_wallet_transactions_promo_income ✅' AS status;
