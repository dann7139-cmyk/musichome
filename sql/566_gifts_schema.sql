-- ============================================================
-- sql/566_gifts_schema.sql — FASE 0: esquema de regalos/donaciones
--
-- Solo tablas nuevas + catálogo semilla. NO toca nada existente,
-- NO acredita wallets todavía (eso es Fase 1, junto con el cobro
-- real por Conekta — necesita revisar con cuidado el patrón vigente
-- de acreditación admin/plataforma antes de tocar dinero real).
--
-- Diseño acordado con el usuario:
--   - Comisión Daricefy 40% / grupo 60%.
--   - Precio por moneda (MXN/USD) — mismo criterio que currencyForCountry()
--     ya usa el resto de la app (México=MXN, todo lo demás=USD por ahora).
--   - El regalo puede ser a una publicación específica (post_id) o al
--     perfil del grupo en general (post_id NULL).
--   - Pago: solo tarjeta vía Conekta (cubre tarjetas prepagadas Visa/MC).
-- ============================================================

-- ── gift_catalog: los regalos disponibles ────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.gift_catalog (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  emoji       TEXT NOT NULL,
  name        TEXT NOT NULL,
  sort_order  INT NOT NULL DEFAULT 0,
  active      BOOLEAN NOT NULL DEFAULT TRUE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE public.gift_catalog ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS gift_catalog_public_read ON public.gift_catalog;
CREATE POLICY gift_catalog_public_read ON public.gift_catalog
  FOR SELECT USING (active = TRUE);

-- ── gift_catalog_prices: precio de cada regalo por moneda ────────────────────
CREATE TABLE IF NOT EXISTS public.gift_catalog_prices (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  gift_id        UUID NOT NULL REFERENCES public.gift_catalog(id) ON DELETE CASCADE,
  currency_code  TEXT NOT NULL CHECK (currency_code IN ('MXN', 'USD')),
  amount         NUMERIC NOT NULL CHECK (amount > 0),
  UNIQUE (gift_id, currency_code)
);

ALTER TABLE public.gift_catalog_prices ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS gift_catalog_prices_public_read ON public.gift_catalog_prices;
CREATE POLICY gift_catalog_prices_public_read ON public.gift_catalog_prices
  FOR SELECT USING (true);

-- ── group_gifts: cada regalo enviado (pendiente hasta que Conekta confirme) ──
CREATE TABLE IF NOT EXISTS public.group_gifts (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  group_id          UUID NOT NULL REFERENCES public.groups(id),
  post_id           UUID REFERENCES public.group_event_posts(id) ON DELETE SET NULL,
  sender_id         UUID NOT NULL REFERENCES public.profiles(id),
  gift_id           UUID NOT NULL REFERENCES public.gift_catalog(id),
  currency_code     TEXT NOT NULL CHECK (currency_code IN ('MXN', 'USD')),
  amount            NUMERIC NOT NULL CHECK (amount > 0),
  group_amount      NUMERIC NOT NULL CHECK (group_amount >= 0),
  platform_amount   NUMERIC NOT NULL CHECK (platform_amount >= 0),
  payment_provider  TEXT NOT NULL DEFAULT 'conekta',
  payment_ref       TEXT,
  status            TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'paid', 'failed')),
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  paid_at           TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_group_gifts_group  ON public.group_gifts(group_id);
CREATE INDEX IF NOT EXISTS idx_group_gifts_post   ON public.group_gifts(post_id);
CREATE INDEX IF NOT EXISTS idx_group_gifts_sender ON public.group_gifts(sender_id);

ALTER TABLE public.group_gifts ENABLE ROW LEVEL SECURITY;

-- Público ve solo los regalos YA pagados (para mostrar el badge/animación
-- en la publicación) — los "pending" no deben ser visibles a nadie más
-- que quien los mandó, para no exponer intentos de pago fallidos.
DROP POLICY IF EXISTS group_gifts_read ON public.group_gifts;
CREATE POLICY group_gifts_read ON public.group_gifts
  FOR SELECT USING (
    status = 'paid'
    OR sender_id = auth.uid()
    OR EXISTS (SELECT 1 FROM public.groups g WHERE g.id = group_gifts.group_id AND g.owner_id = auth.uid())
  );

-- El cliente crea la fila en 'pending' antes de pagar; el webhook de Conekta
-- (service_role, bypassa RLS) es quien la pasa a 'paid' — por eso no hay
-- policy de UPDATE para usuarios normales.
DROP POLICY IF EXISTS group_gifts_insert_own ON public.group_gifts;
CREATE POLICY group_gifts_insert_own ON public.group_gifts
  FOR INSERT WITH CHECK (sender_id = auth.uid());

GRANT SELECT, INSERT ON public.group_gifts TO authenticated;
GRANT SELECT ON public.gift_catalog, public.gift_catalog_prices TO authenticated, anon;

-- ── Catálogo semilla — 6 regalos aprobados ────────────────────────────────────
-- Precio USD en tiers redondos (no es conversión literal de FX, son montos
-- pensados para el mercado en dólares, igual que el resto de precios USD
-- de la app no son un simple cambio de divisa del precio en MXN).
DO $seed$
DECLARE
  v_id UUID;
BEGIN
  IF EXISTS (SELECT 1 FROM public.gift_catalog LIMIT 1) THEN
    RAISE NOTICE 'gift_catalog ya tiene datos — no se vuelve a sembrar.';
    RETURN;
  END IF;

  INSERT INTO public.gift_catalog (emoji, name, sort_order) VALUES ('🎵', 'Nota musical',   1) RETURNING id INTO v_id;
  INSERT INTO public.gift_catalog_prices (gift_id, currency_code, amount) VALUES (v_id, 'MXN', 10),  (v_id, 'USD', 1);

  INSERT INTO public.gift_catalog (emoji, name, sort_order) VALUES ('🎤', 'Micrófono',       2) RETURNING id INTO v_id;
  INSERT INTO public.gift_catalog_prices (gift_id, currency_code, amount) VALUES (v_id, 'MXN', 30),  (v_id, 'USD', 2);

  INSERT INTO public.gift_catalog (emoji, name, sort_order) VALUES ('🥁', 'Batería',         3) RETURNING id INTO v_id;
  INSERT INTO public.gift_catalog_prices (gift_id, currency_code, amount) VALUES (v_id, 'MXN', 80),  (v_id, 'USD', 5);

  INSERT INTO public.gift_catalog (emoji, name, sort_order) VALUES ('🎸', 'Guitarra',        4) RETURNING id INTO v_id;
  INSERT INTO public.gift_catalog_prices (gift_id, currency_code, amount) VALUES (v_id, 'MXN', 150), (v_id, 'USD', 10);

  INSERT INTO public.gift_catalog (emoji, name, sort_order) VALUES ('🏆', 'Trofeo de oro',   5) RETURNING id INTO v_id;
  INSERT INTO public.gift_catalog_prices (gift_id, currency_code, amount) VALUES (v_id, 'MXN', 350), (v_id, 'USD', 20);

  INSERT INTO public.gift_catalog (emoji, name, sort_order) VALUES ('🎆', 'Concierto VIP',   6) RETURNING id INTO v_id;
  INSERT INTO public.gift_catalog_prices (gift_id, currency_code, amount) VALUES (v_id, 'MXN', 700), (v_id, 'USD', 40);
END $seed$;

SELECT '566_gifts_schema.sql ejecutado ✅' AS status;
