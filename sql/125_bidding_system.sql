-- ════════════════════════════════════════════════════════════════════════════
-- 125_bidding_system.sql
-- Sistema de subasta (bidding) para posicionamiento de grupos en resultados.
--
--   1. bid_amount / bid_ends_at en groups       — datos de la puja activa
--   2. bid_packages                             — paquetes de visibilidad
--   3. place_bid(p_package_id, p_custom_amount, p_duration_days)
--   4. expire_bids()                            — resetea pujas vencidas
--   5. pg_cron: expire_bids cada hora
--
-- Lógica de ordenamiento (ejecutada en el cliente):
--   bid_activo DESC → bid_amount DESC → boost_score DESC → rating DESC
--
-- "Promocionado" badge: grupos con bid_amount > 0 y bid_ends_at futuro.
-- No afecta reservas ni pagos existentes.
--
-- Ejecutar DESPUÉS de 124_dynamic_pricing.sql
-- ════════════════════════════════════════════════════════════════════════════


-- ── 1. Campos en groups ───────────────────────────────────────────────────────

ALTER TABLE public.groups
  ADD COLUMN IF NOT EXISTS bid_amount  NUMERIC  DEFAULT 0,
  ADD COLUMN IF NOT EXISTS bid_ends_at TIMESTAMPTZ;

-- bid_amount = 0 y bid_ends_at = NULL → sin puja activa (grupos existentes ok)


-- ── 2. Tabla bid_packages ─────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.bid_packages (
  id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  name          TEXT        NOT NULL,
  duration_days INT         NOT NULL,
  min_bid       NUMERIC     NOT NULL,
  description   TEXT,
  is_active     BOOLEAN     NOT NULL DEFAULT true,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- RLS: solo lectura pública
ALTER TABLE public.bid_packages ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "bid_packages_select" ON public.bid_packages;
CREATE POLICY "bid_packages_select" ON public.bid_packages
  FOR SELECT USING (is_active = true);

-- Paquetes iniciales
INSERT INTO public.bid_packages (name, duration_days, min_bid, description)
VALUES
  ('Básico',   7,   99.00, 'Aparece más arriba en los resultados por 7 días'),
  ('Medio',    15, 159.00, 'Mayor visibilidad garantizada por 15 días'),
  ('Premium',  30, 249.00, 'Posición premium en todos los resultados por 30 días')
ON CONFLICT DO NOTHING;


-- ── 3. place_bid ──────────────────────────────────────────────────────────────
-- Registra una puja para el grupo del usuario autenticado.
--   p_package_id    : UUID del paquete (opcional)
--   p_custom_amount : monto manual; si hay paquete debe ser >= min_bid del mismo
--   p_duration_days : días si no hay paquete (mínimo 1)

DROP FUNCTION IF EXISTS public.place_bid(UUID, NUMERIC, INT);
CREATE OR REPLACE FUNCTION public.place_bid(
  p_package_id    UUID    DEFAULT NULL,
  p_custom_amount NUMERIC DEFAULT NULL,
  p_duration_days INT     DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id  UUID    := auth.uid();
  v_group_id UUID;
  v_pkg      RECORD;
  v_amount   NUMERIC;
  v_days     INT;
  v_ends_at  TIMESTAMPTZ;
BEGIN
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_session');
  END IF;

  -- Resolver grupo del usuario
  SELECT id INTO v_group_id
  FROM public.groups
  WHERE owner_id = v_user_id
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'group_not_found');
  END IF;

  -- ── Con paquete ───────────────────────────────────────────────────────────
  IF p_package_id IS NOT NULL THEN
    SELECT * INTO v_pkg
    FROM public.bid_packages
    WHERE id = p_package_id AND is_active = true;

    IF NOT FOUND THEN
      RETURN jsonb_build_object('ok', false, 'error', 'package_not_found');
    END IF;

    v_days   := v_pkg.duration_days;
    v_amount := COALESCE(p_custom_amount, v_pkg.min_bid);

    IF v_amount < v_pkg.min_bid THEN
      RETURN jsonb_build_object(
        'ok',      false,
        'error',   'bid_below_minimum',
        'min_bid', v_pkg.min_bid
      );
    END IF;

  -- ── Sin paquete (entrada libre) ───────────────────────────────────────────
  ELSE
    IF p_custom_amount IS NULL OR p_duration_days IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'error', 'missing_bid_params');
    END IF;

    IF p_custom_amount < 50 THEN
      RETURN jsonb_build_object('ok', false, 'error', 'bid_too_low', 'min_bid', 50);
    END IF;

    IF p_duration_days < 1 THEN
      RETURN jsonb_build_object('ok', false, 'error', 'invalid_duration');
    END IF;

    v_amount := p_custom_amount;
    v_days   := p_duration_days;
  END IF;

  v_ends_at := now() + (v_days || ' days')::INTERVAL;

  -- Actualizar grupo (acumula con puja anterior si aún está activa;
  -- si ya expiró, reemplaza)
  UPDATE public.groups
  SET
    bid_amount  = CASE
                    WHEN bid_ends_at IS NOT NULL AND bid_ends_at > now()
                    THEN GREATEST(bid_amount, v_amount)   -- mantiene el mayor
                    ELSE v_amount
                  END,
    bid_ends_at = CASE
                    WHEN bid_ends_at IS NOT NULL AND bid_ends_at > now()
                         AND bid_amount >= v_amount
                    THEN bid_ends_at                      -- conserva la más larga si hay bid mayor
                    ELSE v_ends_at
                  END
  WHERE id = v_group_id;

  RETURN jsonb_build_object(
    'ok',            true,
    'group_id',      v_group_id,
    'bid_amount',    v_amount,
    'ends_at',       v_ends_at,
    'duration_days', v_days
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.place_bid(UUID, NUMERIC, INT) TO authenticated;


-- ── 4. expire_bids ────────────────────────────────────────────────────────────
-- Resetea las pujas vencidas (bid_ends_at < now).
-- Diseñada para ser llamada por pg_cron cada hora.

DROP FUNCTION IF EXISTS public.expire_bids();
CREATE OR REPLACE FUNCTION public.expire_bids()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE public.groups
  SET bid_amount  = 0,
      bid_ends_at = NULL
  WHERE bid_ends_at IS NOT NULL
    AND bid_ends_at < now()
    AND bid_amount  > 0;
END;
$$;

GRANT EXECUTE ON FUNCTION public.expire_bids() TO authenticated, service_role;


-- ── 5. pg_cron: expirar pujas cada hora ──────────────────────────────────────

SELECT cron.schedule(
  'expire-bids-hourly',
  '0 * * * *',
  $$SELECT public.expire_bids()$$
);


SELECT '125_bidding_system.sql ejecutado ✅' AS status;
SELECT 'Nuevas columnas: bid_amount, bid_ends_at en groups' AS cols;
SELECT 'Nueva tabla: bid_packages (3 paquetes: Básico 7d, Medio 15d, Premium 30d)' AS pkgs;
SELECT 'RPC: place_bid(p_package_id, p_custom_amount, p_duration_days)' AS rpc;
SELECT 'Cron: expire-bids-hourly → expire_bids() cada hora' AS cron;
