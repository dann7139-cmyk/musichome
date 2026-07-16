-- ============================================================
-- sql/494_video_limits_1_3.sql
-- 🎬 CORRECCIÓN de límites de videos (pedido 2026-07-16):
--    · GRATIS: 1 video.
--    · Con PLUS vigente: +2 → 3 en total.
--  (Antes estaba 3/5 por error. Reemplaza el trigger de sql/492/493.)
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.guard_group_videos_limit()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_count INT;
  v_plus  BOOLEAN;
  v_max   INT;
BEGIN
  v_plus := is_group_plus(NEW.group_id);
  v_max  := CASE WHEN v_plus THEN 3 ELSE 1 END;

  SELECT COUNT(*) INTO v_count FROM group_videos
  WHERE group_id = NEW.group_id AND status <> 'rejected';

  IF v_count >= v_max THEN
    IF v_plus THEN
      RAISE EXCEPTION 'Ya tienes % videos (el máximo con Plus es 3). Elimina uno para subir otro.', v_count;
    ELSE
      RAISE EXCEPTION 'Tu plan incluye 1 video. Con la insignia Plus desbloqueas 2 más (hasta 3).';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

-- ── activate_plus v2: al pagar, avisar "ya puedes subir 2 videos más" ─
CREATE OR REPLACE FUNCTION public.activate_plus(
  p_group_id   UUID,
  p_sub_id     TEXT,
  p_expires_at TIMESTAMPTZ,
  p_status     TEXT DEFAULT 'active'
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_owner    UUID;
  v_was_plus BOOLEAN;
BEGIN
  SELECT owner_id, COALESCE(is_plus_active, false)
  INTO v_owner, v_was_plus
  FROM groups WHERE id = p_group_id;

  UPDATE public.groups
     SET is_plus_active       = TRUE,
         plus_expires_at      = p_expires_at,
         plus_subscription_id = p_sub_id
   WHERE id = p_group_id;

  UPDATE public.plus_subscriptions
     SET status             = p_status,
         current_period_end = p_expires_at
   WHERE stripe_subscription_id = p_sub_id;

  -- 🏆 Solo en la ACTIVACIÓN (no en cada renovación): avisar beneficios
  IF v_owner IS NOT NULL AND NOT v_was_plus THEN
    INSERT INTO notifications (user_id, type, title, body, data)
    VALUES (v_owner, 'reservation',
      '🏆 ¡Tu insignia Plus está activa!',
      'Ya puedes subir 2 VIDEOS MÁS a tu perfil (3 en total) desde Editar perfil → Mis videos. Tu badge verde ya aparece en el explorador y tu perfil.',
      jsonb_build_object('screen', 'GroupReservations'));
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION public.activate_plus(UUID, TEXT, TIMESTAMPTZ, TEXT)
  TO service_role;

COMMIT;

-- 🧹 Limpieza de banderas fantasma de pruebas (Plus vencido que sigue en true):
UPDATE groups SET is_plus_active = FALSE
WHERE is_plus_active = TRUE
  AND plus_expires_at IS NOT NULL
  AND plus_expires_at < NOW();

-- ── VERIFICACIÓN ──────────────────────────────────────────────────────────────
SELECT prosrc LIKE '%WHEN v_plus THEN 3 ELSE 1%' AS limite_1_3
FROM pg_proc WHERE proname = 'guard_group_videos_limit';
-- Esperado: true

SELECT prosrc LIKE '%Plus está activa%' AS avisa_al_pagar
FROM pg_proc WHERE proname = 'activate_plus';
-- Esperado: true

SELECT '494_video_limits_1_3.sql ejecutado ✅' AS status;
