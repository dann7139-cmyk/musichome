-- ════════════════════════════════════════════════════════════════════════════
-- 152_bid_competition_triggers.sql
-- Triggers psicológicos para el sistema de bidding.
--
-- FUNCIONES:
--   · notify_bid_competition()         — trigger: notifica a grupos desplazados
--                                        cuando alguien sube su bid
--   · notify_visibility_fading()       — RPC cron: avisa a grupos con bid por
--                                        vencer que están perdiendo visibilidad
--
-- TRIGGER:
--   · trg_notify_bid_competition       — AFTER UPDATE OF bid_amount ON groups
--
-- Ejecutar DESPUÉS de 151_ranking_and_pricing.sql
-- ════════════════════════════════════════════════════════════════════════════


-- ── 1. notify_bid_competition() ───────────────────────────────────────────────
-- Se dispara cuando un grupo aumenta su bid_amount.
-- Notifica a los grupos que ahora están por debajo (desplazados).
-- Máx. 1 notificación por grupo cada 30 minutos (anti-spam).

CREATE OR REPLACE FUNCTION public.notify_bid_competition()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Solo actuar cuando el bid sube y el nuevo bid sigue activo
  IF TG_OP <> 'UPDATE'
    OR COALESCE(NEW.bid_amount, 0) <= COALESCE(OLD.bid_amount, 0)
    OR NEW.bid_ends_at IS NULL
    OR NEW.bid_ends_at <= now()
    OR NEW.is_active <> true
  THEN
    RETURN NEW;
  END IF;

  -- Insertar notificación para cada grupo desplazado (bid entre old y new)
  -- Anti-spam: no duplicar si ya se notificó en los últimos 30 min
  INSERT INTO public.notifications (user_id, type, title, body, data)
  SELECT
    g.owner_id,
    'bid_displaced',
    '📉 Perdiste una posición',
    'Otro grupo superó tu posicionamiento en ' || NEW.city ||
      '. Actúa ahora para recuperar tu lugar.',
    jsonb_build_object(
      'screen', 'Bidding',
      'city',   NEW.city
    )
  FROM public.groups g
  WHERE normalize_city_name(g.city) = normalize_city_name(NEW.city)
    AND g.id       <> NEW.id
    AND g.is_active = true
    AND g.bid_ends_at > now()
    AND COALESCE(g.bid_amount, 0) > 0
    AND COALESCE(g.bid_amount, 0) < COALESCE(NEW.bid_amount, 0)
    AND COALESCE(g.bid_amount, 0) >= COALESCE(OLD.bid_amount, 0)
    -- Anti-spam: no si ya notificamos en los últimos 30 min
    AND NOT EXISTS (
      SELECT 1 FROM public.notifications n
      WHERE n.user_id = g.owner_id
        AND n.type    = 'bid_displaced'
        AND n.created_at > now() - INTERVAL '30 minutes'
    );

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_notify_bid_competition ON public.groups;
CREATE TRIGGER trg_notify_bid_competition
  AFTER UPDATE OF bid_amount ON public.groups
  FOR EACH ROW EXECUTE FUNCTION public.notify_bid_competition();


-- ── 2. notify_visibility_fading() ────────────────────────────────────────────
-- RPC cron: identifica grupos con bid que vence en < 48h y sin puja renovada.
-- Insertar en cron job: cada 6 horas.
-- SELECT public.notify_visibility_fading();

CREATE OR REPLACE FUNCTION public.notify_visibility_fading()
RETURNS INT   -- número de notificaciones insertadas
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_count INT := 0;
BEGIN
  INSERT INTO public.notifications (user_id, type, title, body, data)
  SELECT
    g.owner_id,
    'bid_expiring_soon',
    '⚠️ Estás perdiendo visibilidad',
    'Tu posicionamiento en ' || g.city ||
      ' vence pronto. Renuévalo para no perder tu lugar.',
    jsonb_build_object('screen', 'Bidding', 'city', g.city)
  FROM public.groups g
  WHERE g.is_active  = true
    AND g.bid_ends_at BETWEEN now() AND now() + INTERVAL '48 hours'
    AND COALESCE(g.bid_amount, 0) > 0
    -- Solo si no hay otra notificación reciente del mismo tipo
    AND NOT EXISTS (
      SELECT 1 FROM public.notifications n
      WHERE n.user_id = g.owner_id
        AND n.type    = 'bid_expiring_soon'
        AND n.created_at > now() - INTERVAL '12 hours'
    );

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

REVOKE ALL ON FUNCTION public.notify_visibility_fading() FROM anon;
GRANT  EXECUTE ON FUNCTION public.notify_visibility_fading() TO authenticated;


SELECT '152_bid_competition_triggers.sql ejecutado ✅' AS status;
SELECT 'Trigger trg_notify_bid_competition: notifica a grupos desplazados' AS info;
SELECT 'RPC notify_visibility_fading(): cron cada 6h — bids por vencer' AS info;
