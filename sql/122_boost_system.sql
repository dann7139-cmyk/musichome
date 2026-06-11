-- ════════════════════════════════════════════════════════════════════════════
-- 122_boost_system.sql
-- Sistema de prioridad pagada (boost) para grupos en resultados de búsqueda.
--
--   1. Columnas boost_score / boost_ends_at en groups
--   2. Tabla boost_packages con 3 niveles
--   3. RPC purchase_boost() — el grupo owner activa su boost
--   4. RPC expire_boosts()  — resetea boosts vencidos (llamar desde pg_cron)
--   5. RLS para boost_packages (lectura pública)
--
-- No toca reservas, pagos ni flujos existentes.
-- Ejecutar DESPUÉS de 121_fix_sponsored_groups.sql
-- ════════════════════════════════════════════════════════════════════════════


-- ── 1. Columnas en groups ─────────────────────────────────────────────────

ALTER TABLE public.groups
  ADD COLUMN IF NOT EXISTS boost_score   INT          DEFAULT 0;

ALTER TABLE public.groups
  ADD COLUMN IF NOT EXISTS boost_ends_at TIMESTAMPTZ;


-- ── 2. Tabla boost_packages ───────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.boost_packages (
  id            UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
  name          TEXT         NOT NULL,
  description   TEXT,
  boost_score   INT          NOT NULL,          -- puntos que se suman al ranking
  duration_days INT          NOT NULL,
  price         NUMERIC(10,2) NOT NULL,
  is_active     BOOLEAN      DEFAULT true,
  created_at    TIMESTAMPTZ  DEFAULT now()
);

-- Paquetes iniciales
INSERT INTO public.boost_packages (name, description, boost_score, duration_days, price)
VALUES
  ('Boost Básico', 'Aparece más arriba en resultados durante 3 días',   10, 3,  299),
  ('Boost Medio',  'Impulso fuerte en resultados durante 7 días',        25, 7,  599),
  ('Boost Alto',   'Máxima visibilidad durante 15 días',                 60, 15, 999)
ON CONFLICT DO NOTHING;


-- ── 3. RPC: purchase_boost ────────────────────────────────────────────────
-- El dueño del grupo llama a esta función tras confirmar el pago.
-- Si ya tiene boost activo, extiende ends_at desde el valor actual.

DROP FUNCTION IF EXISTS public.purchase_boost(UUID);
CREATE OR REPLACE FUNCTION public.purchase_boost(p_package_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id  UUID := auth.uid();
  v_group_id UUID;
  v_pkg      RECORD;
BEGIN
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_session');
  END IF;

  -- Resolver el grupo del caller
  SELECT id INTO v_group_id
  FROM   public.groups
  WHERE  owner_id = v_user_id
  LIMIT  1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'group_not_found');
  END IF;

  -- Obtener el paquete
  SELECT * INTO v_pkg
  FROM   public.boost_packages
  WHERE  id = p_package_id AND is_active = true;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'package_not_found');
  END IF;

  -- Aplicar boost (extender si ya tiene uno activo)
  UPDATE public.groups
  SET
    boost_score   = v_pkg.boost_score,
    boost_ends_at = GREATEST(COALESCE(boost_ends_at, now()), now())
                    + (v_pkg.duration_days || ' days')::INTERVAL
  WHERE id = v_group_id;

  RETURN jsonb_build_object(
    'ok',          true,
    'group_id',    v_group_id,
    'boost_score', v_pkg.boost_score,
    'ends_at',     (SELECT boost_ends_at FROM public.groups WHERE id = v_group_id),
    'amount',      v_pkg.price
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.purchase_boost(UUID) TO authenticated;


-- ── 4. RPC: expire_boosts ─────────────────────────────────────────────────
-- Resetea boost_score = 0 para grupos cuyo boost_ends_at ya venció.
-- Agregar al pg_cron:
--   SELECT cron.schedule('expire-boosts-hourly', '30 * * * *', 'SELECT public.expire_boosts()');

DROP FUNCTION IF EXISTS public.expire_boosts();
CREATE OR REPLACE FUNCTION public.expire_boosts()
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE public.groups
  SET    boost_score   = 0,
         boost_ends_at = NULL
  WHERE  boost_ends_at IS NOT NULL
    AND  boost_ends_at < now();
END;
$$;

GRANT EXECUTE ON FUNCTION public.expire_boosts() TO authenticated, service_role;


-- ── 5. RLS para boost_packages ────────────────────────────────────────────

ALTER TABLE public.boost_packages ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "boost_packages_public_read" ON public.boost_packages;
CREATE POLICY "boost_packages_public_read"
  ON public.boost_packages FOR SELECT USING (true);


-- ── 6. RPC: get_boost_packages (conveniencia para el frontend) ───────────

DROP FUNCTION IF EXISTS public.get_boost_packages();
CREATE OR REPLACE FUNCTION public.get_boost_packages()
RETURNS TABLE (
  id            UUID,
  name          TEXT,
  description   TEXT,
  boost_score   INT,
  duration_days INT,
  price         NUMERIC
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT id, name, description, boost_score, duration_days, price
  FROM   public.boost_packages
  WHERE  is_active = true
  ORDER  BY price ASC;
$$;

GRANT EXECUTE ON FUNCTION public.get_boost_packages() TO authenticated;


SELECT '122_boost_system.sql ejecutado ✅' AS status;
SELECT 'Nuevo: boost_score, boost_ends_at en groups | RPCs: purchase_boost, expire_boosts, get_boost_packages' AS rpcs;
SELECT 'pg_cron sugerido: SELECT cron.schedule(''expire-boosts-hourly'', ''30 * * * *'', ''SELECT public.expire_boosts()'');' AS cron_hint;
